#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

ORIG_ROOT="/mnt/storage-main/photos"
MERGED_ROOT="/mnt/merged"
CACHE_ROOT="/var/lib/immich/cache"
DB_ROOT="/var/lib/immich/db"
THUMBS_ROOT="/var/lib/immich/thumbs"
ENCODED_ROOT="/var/lib/immich/encoded-video"
PROFILE_ROOT="/var/lib/immich/profile"
BACKUP_ROOT="/mnt/storage-backup/snapshots"
POLICY_FILE="/etc/default/nas-video-policy"
HEALTH_DIR="/var/lib/nas-health"
BACKUP_PHOTOS_MODE="rsync_snapshot"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
BACKUP_PHOTOS_MODE="${BACKUP_PHOTOS_MODE:-rsync_snapshot}"

QUERY="${1:-}"
RESOLVED=""
REL=""

human_size() {
    du -sh "$1" 2>/dev/null | awk '{print $1}'
}

check_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [ "$state" = "running" ]; then
        ok "Contenedor $name en running"
    elif [ "$name" = "immich_machine_learning" ] && { [ "$state" = "exited" ] || [ "$state" = "created" ]; }; then
        warn "Contenedor $name apagado por horario; se encendera en la madrugada"
    else
        fail "Contenedor $name en estado: $state"
    fi
}

resolve_asset() {
    local query="$1"
    [ -n "$query" ] || return 0

    if [ -f "$ORIG_ROOT/$query" ]; then
        RESOLVED="$ORIG_ROOT/$query"
        REL="$query"
        return 0
    fi

    RESOLVED=$(find "$ORIG_ROOT" -type f \( -path "*$query*" -o -name "*$query*" \) -print -quit 2>/dev/null || true)
    if [ -n "$RESOLVED" ]; then
        REL="${RESOLVED#$ORIG_ROOT/}"
    fi
}

is_video() {
    case "${1,,}" in
        *.mp4|*.mov|*.mkv|*.avi|*.webm) return 0 ;;
        *) return 1 ;;
    esac
}

section "POST-UPLOAD CHECK"

section "Servicios"
for svc in docker nginx smbd cron; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "Servicio $svc activo"
    else
        warn "Servicio $svc no activo"
    fi
done

section "Contenedores"
check_container immich_server
check_container immich_machine_learning
check_container immich_postgres
check_container immich_redis

section "Montajes"
for mp in /mnt/storage-main /mnt/storage-backup /mnt/merged; do
    if mountpoint -q "$mp" 2>/dev/null; then
        ok "Mount listo: $mp"
    else
        fail "Mount no listo: $mp"
    fi
done

resolve_asset "$QUERY"

section "Asset"
if [ -n "$QUERY" ] && [ -z "$RESOLVED" ]; then
    warn "No encontre un archivo que coincida con: $QUERY"
elif [ -n "$RESOLVED" ]; then
    ok "Original localizado en HDD: $RESOLVED"

    if [ -f "$MERGED_ROOT/$REL" ]; then
        ok "Original visible via mergerfs: $MERGED_ROOT/$REL"
    else
        fail "No visible via mergerfs: $MERGED_ROOT/$REL"
    fi

    if is_video "$REL"; then
        CACHE_PATH="$CACHE_ROOT/${REL%.*}.mp4"
        if [ -f "$CACHE_PATH" ]; then
            ok "Cache de video presente: $CACHE_PATH"
        else
            warn "Cache de video aun no existe: $CACHE_PATH"
        fi

        if [ "$BACKUP_PHOTOS_MODE" = "restic" ]; then
            if command -v restic >/dev/null 2>&1 && [ -n "${BACKUP_RESTIC_REPO:-}" ] && [ -s "${BACKUP_RESTIC_PASSWORD_FILE:-}" ]; then
                export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPO"
                export RESTIC_PASSWORD_FILE="$BACKUP_RESTIC_PASSWORD_FILE"
                if restic snapshots --latest 1 >/tmp/post-upload-restic-snapshot.log 2>&1; then
                    ok "Hay snapshot restic reciente (modo deduplicado)"
                else
                    warn "No pude confirmar snapshot restic reciente"
                fi
            else
                warn "Backup restic configurado, pero faltan prerrequisitos locales para validarlo"
            fi
        else
            LATEST_SNAPSHOT=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name 'immich-db' | sort | tail -n 1)
            if [ -n "${LATEST_SNAPSHOT:-}" ] && [ -f "$LATEST_SNAPSHOT/$REL" ]; then
                ok "Original respaldado en snapshot: $LATEST_SNAPSHOT/$REL"
            else
                warn "Original aun no aparece en el ultimo snapshot"
            fi
        fi
    else
        warn "El asset localizado no parece video; se omiten checks de cache custom"
    fi
else
    warn "Sin argumento: mostrando solo estado global. Puedes pasar una ruta relativa o patron."
    find "$ORIG_ROOT" -type f 2>/dev/null | tail -n 5 | sed 's/^/  - /'
fi

section "Directorios eMMC"
for path in "$DB_ROOT" "$THUMBS_ROOT" "$ENCODED_ROOT" "$PROFILE_ROOT" "$CACHE_ROOT"; do
    if [ -d "$path" ]; then
        ok "$path existe (tamano $(human_size "$path"))"
    else
        fail "$path no existe"
    fi
done

section "Backups"
if [ "$BACKUP_PHOTOS_MODE" = "restic" ]; then
    if command -v restic >/dev/null 2>&1 && [ -n "${BACKUP_RESTIC_REPO:-}" ] && [ -s "${BACKUP_RESTIC_PASSWORD_FILE:-}" ]; then
        export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPO"
        export RESTIC_PASSWORD_FILE="$BACKUP_RESTIC_PASSWORD_FILE"
        if restic snapshots --latest 1 >/tmp/post-upload-restic-snapshot.log 2>&1; then
            ok "Último respaldo fotos/videos (restic): disponible"
        else
            warn "No pude leer snapshots restic (ver /tmp/post-upload-restic-snapshot.log)"
        fi
    else
        warn "Modo restic activo pero faltan credenciales/ruta para validación local"
    fi
else
    LATEST_SNAPSHOT=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name 'immich-db' | sort | tail -n 1)
    [ -n "${LATEST_SNAPSHOT:-}" ] && ok "Ultimo snapshot: $LATEST_SNAPSHOT" || warn "Sin snapshots aun"
fi
LATEST_DB_DUMP=$(find "$BACKUP_ROOT/immich-db" -type f -name '*.sql.gz' 2>/dev/null | sort | tail -n 1)
if [ -n "${LATEST_DB_DUMP:-}" ]; then
    DB_DUMP_BYTES=$(gzip -dc "$LATEST_DB_DUMP" 2>/dev/null | wc -c || true)
    DB_DUMP_BYTES=${DB_DUMP_BYTES//[[:space:]]/}
    if [ -n "${DB_DUMP_BYTES:-}" ] && [ "$DB_DUMP_BYTES" -gt 0 ]; then
        ok "Ultimo dump DB: $LATEST_DB_DUMP (${DB_DUMP_BYTES} bytes descomprimidos)"
    else
        warn "Dump DB vacio o invalido: $LATEST_DB_DUMP"
    fi
else
    warn "Sin dump DB aun"
fi

section "Health"
for f in mount-status.env smart-status.env storage-status.env db-status.env; do
    if [ -f "$HEALTH_DIR/$f" ]; then
        ok "Health presente: $HEALTH_DIR/$f"
    else
        warn "Health aun no generado: $HEALTH_DIR/$f"
    fi
done

exit 0
