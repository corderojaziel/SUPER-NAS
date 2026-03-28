#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cache-migrate-to-disk.sh — Migración manual de cache eMMC -> HDD
# Guía Maestra NAS V58
#
# Objetivo:
#   Liberar eMMC SIN perder playback.
#   - Copia cache de /var/lib/immich/cache al HDD
#   - Reemplaza cada archivo movido por symlink en la ruta original
#   - El resolutor y Nginx siguen funcionando igual
#
# Uso:
#   /usr/local/bin/cache-migrate-to-disk.sh --plan
#   /usr/local/bin/cache-migrate-to-disk.sh --apply --target-free-gb 20
#   /usr/local/bin/cache-migrate-to-disk.sh --apply --target-free-gb 30 --max-files 400
# ═══════════════════════════════════════════════════════════════════════════

set -u

MODE="plan"
TARGET_FREE_GB="${TARGET_FREE_GB:-20}"
MAX_FILES="${MAX_FILES:-0}"
MIN_FILE_MB="${MIN_FILE_MB:-1}"
CACHE_ROOT="${CACHE_ROOT:-/var/lib/immich/cache}"
PHOTOS_ROOT="${PHOTOS_ROOT:-/mnt/storage-main/photos}"
HDD_CACHE_ROOT="${HDD_CACHE_ROOT:-/mnt/storage-main/cache-overflow}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE="plan" ;;
        --apply) MODE="apply" ;;
        --target-free-gb) shift; TARGET_FREE_GB="${1:-$TARGET_FREE_GB}" ;;
        --max-files) shift; MAX_FILES="${1:-$MAX_FILES}" ;;
        --min-file-mb) shift; MIN_FILE_MB="${1:-$MIN_FILE_MB}" ;;
        --cache-root) shift; CACHE_ROOT="${1:-$CACHE_ROOT}" ;;
        --photos-root) shift; PHOTOS_ROOT="${1:-$PHOTOS_ROOT}" ;;
        --hdd-cache-root) shift; HDD_CACHE_ROOT="${1:-$HDD_CACHE_ROOT}" ;;
        *)
            echo "Uso: $0 [--plan|--apply] [--target-free-gb N] [--max-files N] [--min-file-mb N] [--cache-root PATH] [--photos-root PATH] [--hdd-cache-root PATH]"
            exit 1
            ;;
    esac
    shift
done

[ -d "$CACHE_ROOT" ] || { echo "ERROR: no existe CACHE_ROOT=$CACHE_ROOT"; exit 1; }
[ -d "$PHOTOS_ROOT" ] || { echo "ERROR: no existe PHOTOS_ROOT=$PHOTOS_ROOT"; exit 1; }
mkdir -p "$HDD_CACHE_ROOT" || { echo "ERROR: no pude crear $HDD_CACHE_ROOT"; exit 1; }

to_int_mb() {
    awk "BEGIN{printf \"%d\", ($1)*1024*1024}"
}

current_free_gb() {
    df -BG "$CACHE_ROOT" | awk 'NR==2 {gsub("G","",$4); print $4+0}'
}

is_candidate() {
    local rel="$1"
    local stem="$2"

    if [[ "$rel" == encoded-video/* ]]; then
        return 1
    fi
    if [[ "${stem,,}" =~ -mp$ ]]; then
        return 1
    fi

    local top="${rel%%/*}"
    [ -d "$PHOTOS_ROOT/$top" ] || return 1
    return 0
}

LIST_FILE="$(mktemp /tmp/cache-migrate-list.XXXXXX)"
trap 'rm -f "$LIST_FILE"' EXIT

MIN_FILE_BYTES="$(to_int_mb "$MIN_FILE_MB")"

while IFS= read -r -d '' src; do
    [ -L "$src" ] && continue
    [ -f "$src" ] || continue
    rel="${src#"$CACHE_ROOT"/}"
    stem="$(basename "$src" .mp4)"

    is_candidate "$rel" "$stem" || continue

    size="$(stat -Lc '%s' "$src" 2>/dev/null || echo 0)"
    [ "$size" -ge "$MIN_FILE_BYTES" ] || continue
    mtime="$(stat -Lc '%Y' "$src" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\n' "$mtime" "$size" "$rel" >> "$LIST_FILE"
done < <(find "$CACHE_ROOT" -type f -name "*.mp4" -print0 2>/dev/null)

if [ ! -s "$LIST_FILE" ]; then
    echo "No hay candidatos para migrar."
    exit 0
fi

SORTED_FILE="$(mktemp /tmp/cache-migrate-sorted.XXXXXX)"
trap 'rm -f "$LIST_FILE" "$SORTED_FILE"' EXIT
sort -n "$LIST_FILE" > "$SORTED_FILE"

FREE_BEFORE="$(current_free_gb)"
MOVED_FILES=0
MOVED_BYTES=0
FAILED=0
PLANNED=0
PLANNED_BYTES=0

while IFS=$'\t' read -r _mtime size rel; do
    [ -n "$rel" ] || continue

    if [ "$(current_free_gb)" -ge "$TARGET_FREE_GB" ]; then
        break
    fi

    if [ "$MODE" = "apply" ] && [ "$MAX_FILES" -gt 0 ] && [ "$MOVED_FILES" -ge "$MAX_FILES" ]; then
        break
    fi

    src="$CACHE_ROOT/$rel"
    dst="$HDD_CACHE_ROOT/$rel"
    dst_dir="$(dirname "$dst")"

    PLANNED=$((PLANNED + 1))
    PLANNED_BYTES=$((PLANNED_BYTES + size))

    if [ "$MAX_FILES" -gt 0 ] && [ "$MODE" = "plan" ] && [ "$PLANNED" -gt "$MAX_FILES" ]; then
        PLANNED=$((PLANNED - 1))
        PLANNED_BYTES=$((PLANNED_BYTES - size))
        break
    fi

    if [ "$MODE" = "plan" ]; then
        echo "PLAN: $src -> $dst"
        continue
    fi

    mkdir -p "$dst_dir"
    tmp_dst="$dst.tmp.$$"

    if ! rsync -a --inplace "$src" "$tmp_dst" >/dev/null 2>&1; then
        FAILED=$((FAILED + 1))
        rm -f "$tmp_dst"
        continue
    fi
    mv -f "$tmp_dst" "$dst"

    if ! cmp -s "$src" "$dst"; then
        FAILED=$((FAILED + 1))
        continue
    fi

    backup_src="$src.migrate.$$"
    if ! mv -f "$src" "$backup_src"; then
        FAILED=$((FAILED + 1))
        continue
    fi

    if ln -s "$dst" "$src"; then
        rm -f "$backup_src"
        MOVED_FILES=$((MOVED_FILES + 1))
        MOVED_BYTES=$((MOVED_BYTES + size))
        echo "MIGRADO: $src -> $dst"
    else
        mv -f "$backup_src" "$src"
        FAILED=$((FAILED + 1))
    fi
done < "$SORTED_FILE"

FREE_AFTER="$(current_free_gb)"
MOVED_GB="$(awk "BEGIN{printf \"%.2f\", $MOVED_BYTES/1024/1024/1024}")"
PLANNED_GB="$(awk "BEGIN{printf \"%.2f\", $PLANNED_BYTES/1024/1024/1024}")"

echo "Resumen migración cache:"
echo "modo=$MODE planned_files=$PLANNED planned_gb=$PLANNED_GB moved_files=$MOVED_FILES moved_gb=$MOVED_GB failed=$FAILED free_before=${FREE_BEFORE}G free_after=${FREE_AFTER}G target=${TARGET_FREE_GB}G"

if [ "$MODE" = "apply" ]; then
    "$NAS_ALERT_BIN" "📦 Migración de cache ejecutada
Modo: apply
Movidos: $MOVED_FILES archivos (${MOVED_GB} GB)
Fallos: $FAILED
Libre eMMC: ${FREE_BEFORE}G -> ${FREE_AFTER}G
Destino HDD: $HDD_CACHE_ROOT"
else
    "$NAS_ALERT_BIN" "📋 Plan de migración de cache listo
Candidatos: $PLANNED archivos (~${PLANNED_GB} GB)
Sin cambios aplicados.
Para ejecutar: /usr/local/bin/cache-migrate-to-disk.sh --apply --target-free-gb $TARGET_FREE_GB"
fi
