#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# manual-retention.sh — Depuración manual de respaldos
# Guía Maestra NAS V58
#
# Alcance:
#   - snapshots de backup en /mnt/storage-backup/snapshots (solo carpetas YYYY-MM-DD)
#   - dumps DB en /mnt/storage-backup/snapshots/immich-db
#
# Seguridad:
#   - Por defecto: PLAN (no borra nada)
#   - Para borrar: --apply
#   - Nunca toca originales en /mnt/storage-main/photos
# ═══════════════════════════════════════════════════════════════════════════

set -u

MODE="plan"
SNAP_DIR="${SNAP_DIR:-/mnt/storage-backup/snapshots}"
DB_DIR="${DB_DIR:-/mnt/storage-backup/snapshots/immich-db}"
SNAP_KEEP="${SNAP_KEEP:-1}"
DB_KEEP="${DB_KEEP:-7}"
TARGET="${TARGET:-all}" # snapshots|db|all
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE="plan" ;;
        --apply) MODE="apply" ;;
        --snapshots-keep) shift; SNAP_KEEP="${1:-$SNAP_KEEP}" ;;
        --db-keep) shift; DB_KEEP="${1:-$DB_KEEP}" ;;
        --target) shift; TARGET="${1:-$TARGET}" ;;
        --snap-dir) shift; SNAP_DIR="${1:-$SNAP_DIR}" ;;
        --db-dir) shift; DB_DIR="${1:-$DB_DIR}" ;;
        *)
            echo "Uso: $0 [--plan|--apply] [--target snapshots|db|all] [--snapshots-keep N] [--db-keep N]"
            exit 1
            ;;
    esac
    shift
done

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_number "$SNAP_KEEP" || SNAP_KEEP=1
is_number "$DB_KEEP" || DB_KEEP=7
[ "$SNAP_KEEP" -ge 1 ] || SNAP_KEEP=1
[ "$DB_KEEP" -ge 1 ] || DB_KEEP=1

PLAN_COUNT=0
DELETE_COUNT=0
DELETE_SIZE_BYTES=0

delete_path() {
    local p="$1"
    local size
    size="$(du -sb "$p" 2>/dev/null | awk '{print $1+0}')"
    PLAN_COUNT=$((PLAN_COUNT + 1))
    if [ "$MODE" = "apply" ]; then
        rm -rf "$p"
        DELETE_COUNT=$((DELETE_COUNT + 1))
        DELETE_SIZE_BYTES=$((DELETE_SIZE_BYTES + size))
        echo "DELETED: $p"
    else
        echo "PLAN: $p"
    fi
}

if [ "$TARGET" = "snapshots" ] || [ "$TARGET" = "all" ]; then
    if [ -d "$SNAP_DIR" ]; then
        # Solo snapshots por fecha (YYYY-MM-DD). No toca system-state ni immich-db.
        mapfile -t snaps < <(
            find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
            | sort
        )
        total="${#snaps[@]}"
        if [ "$total" -gt "$SNAP_KEEP" ]; then
            limit=$((total - SNAP_KEEP))
            for ((i=0; i<limit; i++)); do
                delete_path "$SNAP_DIR/${snaps[$i]}"
            done
        fi
    fi
fi

if [ "$TARGET" = "db" ] || [ "$TARGET" = "all" ]; then
    if [ -d "$DB_DIR" ]; then
        mapfile -t dumps < <(find "$DB_DIR" -maxdepth 1 -type f -name '*.sql.gz' -printf '%f\n' | sort)
        total="${#dumps[@]}"
        if [ "$total" -gt "$DB_KEEP" ]; then
            limit=$((total - DB_KEEP))
            for ((i=0; i<limit; i++)); do
                delete_path "$DB_DIR/${dumps[$i]}"
            done
        fi
    fi
fi

freed_gb="$(awk "BEGIN{printf \"%.2f\", $DELETE_SIZE_BYTES/1024/1024/1024}")"
echo "manual-retention resumen: mode=$MODE target=$TARGET planned=$PLAN_COUNT deleted=$DELETE_COUNT freed_gb=$freed_gb"

if [ "$MODE" = "apply" ]; then
    "$NAS_ALERT_BIN" "🧰 Depuración manual aplicada
Target: $TARGET
Elementos borrados: $DELETE_COUNT
Espacio liberado: ${freed_gb} GB"
else
    "$NAS_ALERT_BIN" "📋 Plan manual de depuración listo
Target: $TARGET
Candidatos: $PLAN_COUNT
Sin borrados. Para aplicar usa --apply."
fi
