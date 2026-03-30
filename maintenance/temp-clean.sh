#!/bin/bash
# temp-clean.sh — Depuración segura de temporales (NO toca fotos/videos productivos)
#
# Objetivo:
# - Limpiar artefactos temporales y de trabajo que crecen con auditorías/reprocesos.
# - Nunca borrar biblioteca productiva (upload/library) ni cache válida de videos.
#
# Uso:
#   /usr/local/bin/temp-clean.sh --dry-run
#   /usr/local/bin/temp-clean.sh --apply
#
# Integración esperada:
# - Corrida semanal desde night-run.sh
# - En modo resumen nocturno se reporta estado WEEKLY_OK/WEEKLY_SKIPPED/FAIL

set -u

POLICY_FILE="/etc/default/nas-video-policy"
[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

MODE="dry-run"
AGE_DAYS="${TEMP_CLEAN_AGE_DAYS:-7}"
LOG_FILE="${TEMP_CLEAN_LOG_FILE:-/var/log/temp-clean.log}"
LOCK_FILE="${TEMP_CLEAN_LOCK_FILE:-/var/lock/temp-clean.lock}"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

REPROCESS_DIR="${TEMP_CLEAN_REPROCESS_DIR:-/var/lib/nas-health/reprocess}"
CACHE_ROOT="${CACHE_DIR:-${CACHE_ROOT:-/var/lib/immich/cache}}"
TMP_DIRS="${TEMP_CLEAN_TMP_DIRS:-/tmp /var/tmp}"

for arg in "$@"; do
    case "$arg" in
        --dry-run) MODE="dry-run" ;;
        --apply) MODE="apply" ;;
        --age-days=*) AGE_DAYS="${arg#*=}" ;;
        --age-days) shift; AGE_DAYS="${1:-$AGE_DAYS}" ;;
        *)
            echo "Uso: $0 [--dry-run|--apply] [--age-days N]"
            exit 1
            ;;
    esac
done

case "$AGE_DAYS" in
    ''|*[!0-9]*) AGE_DAYS=7 ;;
esac
if [ "$AGE_DAYS" -lt 1 ]; then AGE_DAYS=1; fi

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}

to_human_mb() {
    awk -v b="${1:-0}" 'BEGIN{printf "%.1f", (b+0)/1048576}'
}

should_notify() {
    [ "${NAS_ALERT_SUPPRESS:-0}" = "1" ] && return 1
    [ -x "$ALERT_BIN" ] || return 1
    return 0
}

declare -A SEEN
declare -a CANDIDATES

add_candidate() {
    local p="$1"
    [ -n "$p" ] || return 0
    [ -e "$p" ] || return 0
    if [ -n "${SEEN[$p]+x}" ]; then
        return 0
    fi
    SEEN["$p"]=1
    CANDIDATES+=("$p")
}

reprocess_busy=0
if pgrep -fa 'video-reprocess|rebuild-video-cache|video-optimize|video-autopilot|backfill-heavy-cache' >/dev/null 2>&1; then
    reprocess_busy=1
fi

if [ -d "$REPROCESS_DIR" ]; then
    # Archivos históricos de insumos/reportes/reproceso (solo timestampados por prefijo).
    while IFS= read -r -d '' f; do add_candidate "$f"; done < <(
        find "$REPROCESS_DIR" -maxdepth 2 -type f \
            \( -name 'reprocess-*' -o -name 'heavy-latest-*' -o -name 'light-latest-*' -o -name 'broken-latest-*' -o -name 'launcher-*' -o -name 'watcher*.log' \) \
            -mtime +"$AGE_DAYS" -print0 2>/dev/null
    )

    # Directorios de chunks viejos (si no hay reproceso en curso).
    if [ "$reprocess_busy" -eq 0 ]; then
        while IFS= read -r -d '' d; do add_candidate "$d"; done < <(
            find "$REPROCESS_DIR" -maxdepth 1 -type d -name 'chunks*' -mtime +"$AGE_DAYS" -print0 2>/dev/null
        )
    else
        log "INFO: reproceso activo detectado; omito limpieza de chunks para no interferir."
    fi
fi

# Temporales de herramientas del stack en /tmp y /var/tmp (prefijos conocidos).
for td in $TMP_DIRS; do
    [ -d "$td" ] || continue
    while IFS= read -r -d '' f; do add_candidate "$f"; done < <(
        find "$td" -maxdepth 1 -type f \
            \( -name 'cache-migrate-list.*' -o -name 'cache-migrate-sorted.*' -o -name 'nas-ext-*' -o -name 'supernas-*' -o -name 'v2-*.log' -o -name 'v2-*.json' \) \
            -mtime +"$AGE_DAYS" -print0 2>/dev/null
    )
done

# Temporales incompletos de cache (nunca toca .mp4 válidos).
if [ -d "$CACHE_ROOT" ]; then
    while IFS= read -r -d '' f; do add_candidate "$f"; done < <(
        find "$CACHE_ROOT" -type f \
            \( -name '*.tmp.pc.mp4' -o -name '*.tmp-copy' \) \
            -mtime +2 -print0 2>/dev/null
    )
fi

total=0
total_bytes=0
deleted=0
freed_bytes=0

for p in "${CANDIDATES[@]}"; do
    [ -e "$p" ] || continue
    total=$((total + 1))
    size=0
    if [ -f "$p" ]; then
        size="$(stat -c%s "$p" 2>/dev/null || echo 0)"
    elif [ -d "$p" ]; then
        size="$(du -sb "$p" 2>/dev/null | awk '{print $1+0}')"
    fi
    total_bytes=$((total_bytes + size))

    if [ "$MODE" = "apply" ]; then
        if rm -rf -- "$p" 2>/dev/null; then
            deleted=$((deleted + 1))
            freed_bytes=$((freed_bytes + size))
        fi
    fi
done

status="OK"
if [ "$MODE" = "apply" ] && [ "$deleted" -lt "$total" ]; then
    status="WARN"
fi

log "temp-clean mode=$MODE age_days=$AGE_DAYS candidates=$total candidate_mb=$(to_human_mb "$total_bytes") deleted=$deleted freed_mb=$(to_human_mb "$freed_bytes") status=$status"

if should_notify; then
    msg="🧽 Limpieza semanal de temporales (${MODE})
Candidatos: ${total} (~$(to_human_mb "$total_bytes") MB)
Eliminados: ${deleted}
Liberado: ~$(to_human_mb "$freed_bytes") MB
Regla: solo temporales (sin tocar fotos/videos productivos)."
    NAS_ALERT_KEY="temp_clean:weekly:${MODE}" NAS_ALERT_TTL=1800 "$ALERT_BIN" "$msg" || true
fi

exit 0
