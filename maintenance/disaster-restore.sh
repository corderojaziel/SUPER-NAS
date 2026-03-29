#!/bin/bash
# disaster-restore.sh — Restauración integral en caja nueva con discos existentes.
#
# Flujo recomendado:
#   1) Ejecutar install.sh en modo restauración (sin formateo).
#   2) Ejecutar este script para recuperar configuración + DB + cache.
#
# Uso:
#   /usr/local/bin/disaster-restore.sh latest
#   /usr/local/bin/disaster-restore.sh latest --with-cache-archive
#   /usr/local/bin/disaster-restore.sh latest --rebuild-cache-light
#   /usr/local/bin/disaster-restore.sh /mnt/storage-backup/snapshots/system-state/20260329-013000 --skip-verify

set -euo pipefail

SNAP_INPUT="latest"
WITH_CACHE_ARCHIVE=0
REBUILD_CACHE_LIGHT=0
SKIP_VERIFY=0

for arg in "$@"; do
  case "$arg" in
    --with-cache-archive) WITH_CACHE_ARCHIVE=1 ;;
    --rebuild-cache-light) REBUILD_CACHE_LIGHT=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --help|-h)
      echo "Uso: $0 [latest|/ruta/snapshot] [--with-cache-archive] [--rebuild-cache-light] [--skip-verify]"
      exit 0
      ;;
    --*) echo "Argumento no reconocido: $arg" >&2; exit 2 ;;
    *) SNAP_INPUT="$arg" ;;
  esac
done

NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
STATE_RESTORE_BIN="${STATE_RESTORE_BIN:-/usr/local/bin/state-restore.sh}"
FAILOVER_SYNC_BIN="${FAILOVER_SYNC_BIN:-/usr/local/bin/failover-sync.sh}"
REBUILD_CACHE_BIN="${REBUILD_CACHE_BIN:-/usr/local/bin/rebuild-video-cache.sh}"
VERIFY_BIN="${VERIFY_BIN:-/usr/local/bin/verify.sh}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/immich-app}"
CACHE_ROOT="${CACHE_ROOT:-/var/lib/immich/cache}"
FAILOVER_CACHE_ROOT="${FAILOVER_CACHE_ROOT:-/mnt/storage-backup/failover-main/cache}"
MAIN_MOUNT="${MAIN_MOUNT:-/mnt/storage-main}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/storage-backup}"
LOG_FILE="${LOG_FILE:-/var/log/disaster-restore.log}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}

alert() {
  [ -x "$NAS_ALERT_BIN" ] || return 0
  "$NAS_ALERT_BIN" "$1" || true
}

has_files() {
  local d="$1"
  [ -d "$d" ] || return 1
  find "$d" -type f -print -quit 2>/dev/null | grep -q .
}

log "RESTORE_START snapshot=$SNAP_INPUT with_cache_archive=$WITH_CACHE_ARCHIVE rebuild_cache_light=$REBUILD_CACHE_LIGHT"
alert "🛠️ Inicio de restauración integral
Modo: recuperación en caja nueva con discos existentes.
Snapshot objetivo: $SNAP_INPUT"

mount -a >/dev/null 2>&1 || true
mountpoint -q "$MAIN_MOUNT" || { log "ERROR: $MAIN_MOUNT no está montado"; exit 1; }
mountpoint -q "$BACKUP_MOUNT" || { log "ERROR: $BACKUP_MOUNT no está montado"; exit 1; }
[ -x "$STATE_RESTORE_BIN" ] || { log "ERROR: falta $STATE_RESTORE_BIN"; exit 1; }

RESTORE_CMD=("$STATE_RESTORE_BIN" "$SNAP_INPUT" "--with-db")
if [ "$WITH_CACHE_ARCHIVE" = "1" ]; then
  RESTORE_CMD+=("--with-cache")
fi

"${RESTORE_CMD[@]}"

CACHE_RECOVERY="none"
if has_files "$FAILOVER_CACHE_ROOT"; then
  log "Recuperando cache desde failover-main/cache -> $CACHE_ROOT"
  mkdir -p "$CACHE_ROOT"
  nice -n 15 ionice -c2 -n7 rsync -a --numeric-ids --inplace "$FAILOVER_CACHE_ROOT"/ "$CACHE_ROOT"/
  CACHE_RECOVERY="failover_copy"
elif [ "$WITH_CACHE_ARCHIVE" = "1" ]; then
  CACHE_RECOVERY="snapshot_archive"
elif [ "$REBUILD_CACHE_LIGHT" = "1" ] && [ -x "$REBUILD_CACHE_BIN" ]; then
  log "No encontré cache en failover; reconstruyendo ligeros"
  "$REBUILD_CACHE_BIN" light-only
  CACHE_RECOVERY="rebuild_light"
fi

if [ -x "$FAILOVER_SYNC_BIN" ]; then
  FAILOVER_SYNC_PHOTOS_ENABLED=0 "$FAILOVER_SYNC_BIN" sync >/tmp/disaster-restore-failover-sync.log 2>&1 || true
fi

if [ -d "$COMPOSE_DIR" ]; then
  (
    cd "$COMPOSE_DIR"
    docker compose up -d >/dev/null 2>&1 || true
    docker compose restart immich-server >/dev/null 2>&1 || true
  )
fi

if [ "$SKIP_VERIFY" != "1" ] && [ -x "$VERIFY_BIN" ]; then
  "$VERIFY_BIN" >/tmp/disaster-restore-verify.log 2>&1 || true
fi

alert "✅ Restauración integral completada
Snapshot: $SNAP_INPUT
DB: restaurada
Cache: $CACHE_RECOVERY
Siguiente paso: validar en portal y revisar /tmp/disaster-restore-verify.log"

log "RESTORE_DONE snapshot=$SNAP_INPUT cache=$CACHE_RECOVERY"
