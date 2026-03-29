#!/bin/bash
# failover-sync.sh — Mantiene espejo operativo para failover en disco respaldo.
#
# Política:
#   - Nunca borra fotos/videos automáticamente.
#   - Sincroniza fotos (HDD principal -> respaldo operativo) y cache de video
#     (eMMC -> respaldo operativo) para poder switchear sin romper flujo.
#   - Si el sistema ya está en modo failover, NO sincroniza para evitar
#     copiar respaldo sobre sí mismo.
#
# Uso:
#   /usr/local/bin/failover-sync.sh sync
#   /usr/local/bin/failover-sync.sh status

set -u
set -o pipefail

MODE="${1:-sync}"
POLICY_FILE="/etc/default/nas-video-policy"
MOUNTS_FILE="/etc/nas-mounts"
DISKS_FILE="/etc/nas-disks"
STATE_DIR="/var/lib/nas-health"
STATE_FILE="$STATE_DIR/failover-sync.env"
LOG_FILE="/var/log/failover-sync.log"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

MOUNT_MAIN="/mnt/storage-main"
MOUNT_BACKUP="/mnt/storage-backup"
FAILOVER_ROOT="/mnt/storage-backup/failover-main"
CACHE_SRC_DEFAULT="/var/lib/immich/cache"
SYNC_PHOTOS_ENABLED=1
SYNC_CACHE_ENABLED=1
SYNC_NOTIFY_ON_SUCCESS=0
SYNC_MAX_RUNTIME_MIN=240
SYNC_IO_NICE=1

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
[ -f "$MOUNTS_FILE" ] && . "$MOUNTS_FILE"

FAILOVER_ROOT="${FAILOVER_ROOT:-/mnt/storage-backup/failover-main}"
FAILOVER_REL="$FAILOVER_ROOT"
case "$FAILOVER_ROOT" in
  "$MOUNT_BACKUP"/*) FAILOVER_REL="${FAILOVER_ROOT#$MOUNT_BACKUP}" ;;
esac
CACHE_SRC="${VIDEO_REPROCESS_CACHE_ROOT:-$CACHE_SRC_DEFAULT}"
SYNC_PHOTOS_ENABLED="${FAILOVER_SYNC_PHOTOS_ENABLED:-$SYNC_PHOTOS_ENABLED}"
SYNC_CACHE_ENABLED="${FAILOVER_SYNC_CACHE_ENABLED:-$SYNC_CACHE_ENABLED}"
SYNC_NOTIFY_ON_SUCCESS="${FAILOVER_SYNC_NOTIFY_ON_SUCCESS:-$SYNC_NOTIFY_ON_SUCCESS}"
SYNC_MAX_RUNTIME_MIN="${FAILOVER_SYNC_MAX_RUNTIME_MIN:-$SYNC_MAX_RUNTIME_MIN}"
SYNC_IO_NICE="${FAILOVER_SYNC_IO_NICE:-$SYNC_IO_NICE}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

alert() {
  [ -x "$ALERT_BIN" ] || return 0
  "$ALERT_BIN" "$1" || true
}

is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

mount_source() {
  findmnt -n -o SOURCE "$1" 2>/dev/null | tail -n1 || true
}

mount_sources() {
  findmnt -n -o SOURCE "$1" 2>/dev/null || true
}

is_failover_active() {
  local src
  src="$(mount_source "$MOUNT_MAIN")"
  [ "$src" = "$FAILOVER_ROOT" ] && return 0
  [ -n "$FAILOVER_REL" ] && printf '%s' "$src" | grep -Fq "[$FAILOVER_REL]" && return 0
  return 1
}

source_is_primary() {
  local src primary_disk
  primary_disk="/dev/sda"
  [ -f "$DISKS_FILE" ] && primary_disk="$(awk '{print $1}' "$DISKS_FILE")"
  src="$(mount_sources "$MOUNT_MAIN")"
  [ -n "$src" ] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^${primary_disk}([0-9]+)?$ ]] && return 0
  done <<< "$src"
  return 1
}

save_state() {
  local st="$1" msg="$2"
  cat > "$STATE_FILE" <<EOF
FAILOVER_SYNC_STATUS=$st
FAILOVER_SYNC_MESSAGE="$msg"
FAILOVER_SYNC_UPDATED_AT=$(date -Iseconds)
FAILOVER_SYNC_MAIN_SOURCE="$(mount_source "$MOUNT_MAIN")"
FAILOVER_SYNC_BACKUP_SOURCE="$(mount_source "$MOUNT_BACKUP")"
FAILOVER_SYNC_ROOT="$FAILOVER_ROOT"
EOF
}

sync_dir() {
  local src="$1" dst="$2" label="$3"
  mkdir -p "$dst"

  # Sin --delete: nunca borrar contenido productivo automáticamente.
  if timeout "$((SYNC_MAX_RUNTIME_MIN * 60))" \
      nice -n "$SYNC_IO_NICE" ionice -c2 -n7 \
      rsync -a --numeric-ids --partial --inplace "$src/" "$dst/"; then
    log "SYNC_OK: $label src=$src dst=$dst"
    return 0
  fi

  log "SYNC_FAIL: $label src=$src dst=$dst"
  return 1
}

latest_snapshot_dir() {
  local base="/mnt/storage-backup/snapshots" latest=""
  [ -d "$base" ] || return 1
  latest="$(
    find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      | sort \
      | tail -1
  )"
  [ -n "$latest" ] || return 1
  printf '%s\n' "$base/$latest"
}

seed_photos_from_latest_snapshot() {
  local dst="$1" snap=""
  mkdir -p "$dst"
  if [ "$(find "$dst" -mindepth 1 -maxdepth 1 | wc -l)" -gt 0 ]; then
    return 0
  fi
  snap="$(latest_snapshot_dir || true)"
  [ -n "$snap" ] || return 0
  if cp -al "$snap"/. "$dst"/ >/dev/null 2>&1; then
    log "SEED_OK: fotos iniciales hardlink desde snapshot $snap"
  else
    log "SEED_WARN: no pude sembrar desde snapshot $snap"
  fi
}

sync_cmd() {
  local photos_src photos_dst cache_src cache_dst
  photos_src="$MOUNT_MAIN/photos"
  photos_dst="$FAILOVER_ROOT/photos"
  cache_src="$CACHE_SRC"
  cache_dst="$FAILOVER_ROOT/cache"

  if ! mountpoint -q "$MOUNT_BACKUP"; then
    save_state "FAIL" "backup_not_mounted"
    alert "⚠️ No pude actualizar el respaldo operativo
No encontré montado el disco de respaldo.
Qué correr (TV Box):
1) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
2) /usr/local/bin/verify.sh"
    return 1
  fi

  if is_failover_active; then
    save_state "SKIPPED" "failover_active"
    log "SYNC_SKIP: failover activo, se evita auto-copia"
    return 0
  fi

  if ! mountpoint -q "$MOUNT_MAIN" || ! source_is_primary; then
    save_state "SKIPPED" "main_not_primary"
    log "SYNC_SKIP: principal no disponible/estable"
    return 0
  fi

  mkdir -p "$FAILOVER_ROOT"
  save_state "RUNNING" "sync_in_progress"
  local failed=0

  if is_true "$SYNC_PHOTOS_ENABLED"; then
    if [ -d "$photos_src" ]; then
      seed_photos_from_latest_snapshot "$photos_dst"
      sync_dir "$photos_src" "$photos_dst" "photos" || failed=1
    else
      log "SYNC_WARN: photos src ausente ($photos_src)"
      failed=1
    fi
  fi

  if is_true "$SYNC_CACHE_ENABLED"; then
    if [ -d "$cache_src" ]; then
      sync_dir "$cache_src" "$cache_dst" "cache" || failed=1
    else
      log "SYNC_WARN: cache src ausente ($cache_src)"
      failed=1
    fi
  fi

  if [ "$failed" -ne 0 ]; then
    save_state "FAIL" "sync_failed"
    alert "⚠️ El respaldo operativo quedó incompleto
Intenté sincronizar fotos/cache para failover y algo falló.
Qué correr (TV Box):
1) tail -n 120 /var/log/failover-sync.log
2) /usr/local/bin/failover-sync.sh sync
3) /usr/local/bin/verify.sh"
    return 1
  fi

  save_state "OK" "sync_complete"
  log "SYNC_DONE: failover-root actualizado"

  if is_true "$SYNC_NOTIFY_ON_SUCCESS"; then
    NAS_ALERT_KEY="failover_sync:ok" NAS_ALERT_TTL=3600 alert "✅ Respaldo operativo actualizado
Ya está listo el espejo para switch de emergencia.
Ruta operativa: $FAILOVER_ROOT"
  fi
  return 0
}

status_cmd() {
  echo "main_mount=$(mountpoint -q "$MOUNT_MAIN" && echo 1 || echo 0)"
  echo "backup_mount=$(mountpoint -q "$MOUNT_BACKUP" && echo 1 || echo 0)"
  echo "main_source=$(mount_source "$MOUNT_MAIN")"
  echo "backup_source=$(mount_source "$MOUNT_BACKUP")"
  echo "failover_active=$(is_failover_active && echo 1 || echo 0)"
  echo "failover_root=$FAILOVER_ROOT"
  echo "photos_ready=$( [ -d "$FAILOVER_ROOT/photos" ] && echo 1 || echo 0 )"
  echo "cache_ready=$( [ -d "$FAILOVER_ROOT/cache" ] && echo 1 || echo 0 )"
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "FAILOVER_SYNC_STATUS=unknown"
  fi
}

case "$MODE" in
  sync) sync_cmd ;;
  status) status_cmd ;;
  *)
    echo "Uso: $0 {sync|status}" >&2
    exit 1
    ;;
esac
