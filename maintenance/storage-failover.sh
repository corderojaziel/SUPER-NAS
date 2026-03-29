#!/bin/bash
# storage-failover.sh — Conmutación automática al disco de respaldo.
#
# Regla operativa:
#   - Solo switchea cuando el almacenamiento principal no puede continuar:
#       1) desmontado / sin source esperado
#       2) fallo grave de I/O en ruta principal (lectura básica falla)
#   - No switchea por advertencias leves.
#   - Si se activa failover, /mnt/storage-main pasa a apuntar por bind a:
#       /mnt/storage-backup/failover-main
#
# Uso:
#   /usr/local/bin/storage-failover.sh auto
#   /usr/local/bin/storage-failover.sh status
#   /usr/local/bin/storage-failover.sh activate <reason>
#   /usr/local/bin/storage-failover.sh deactivate

set -u
set -o pipefail

MODE="${1:-auto}"
REASON="${2:-manual}"

POLICY_FILE="/etc/default/nas-video-policy"
MOUNTS_FILE="/etc/nas-mounts"
DISKS_FILE="/etc/nas-disks"
STATE_DIR="/var/lib/nas-health"
STATE_FILE="$STATE_DIR/failover-state.env"
LOG_FILE="/var/log/storage-failover.log"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

MOUNT_MAIN="/mnt/storage-main"
MOUNT_BACKUP="/mnt/storage-backup"
FAILOVER_ROOT="/mnt/storage-backup/failover-main"
AUTO_FAILOVER_ENABLED=1
AUTO_FAILBACK_ENABLED=1
FAILOVER_IO_CHECK_ENABLED=1
FAILOVER_IO_TIMEOUT_SEC=8

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
[ -f "$MOUNTS_FILE" ] && . "$MOUNTS_FILE"

AUTO_FAILOVER_ENABLED="${AUTO_FAILOVER_ENABLED:-1}"
AUTO_FAILBACK_ENABLED="${AUTO_FAILBACK_ENABLED:-0}"
FAILOVER_IO_CHECK_ENABLED="${FAILOVER_IO_CHECK_ENABLED:-1}"
FAILOVER_IO_TIMEOUT_SEC="${FAILOVER_IO_TIMEOUT_SEC:-8}"
FAILOVER_ROOT="${FAILOVER_ROOT:-/mnt/storage-backup/failover-main}"
FAILOVER_REL="$FAILOVER_ROOT"
case "$FAILOVER_ROOT" in
  "$MOUNT_BACKUP"/*) FAILOVER_REL="${FAILOVER_ROOT#$MOUNT_BACKUP}" ;;
esac

PRIMARY_DISK="/dev/sda"
if [ -f "$DISKS_FILE" ]; then
  PRIMARY_DISK="$(awk '{print $1}' "$DISKS_FILE")"
fi
[ -n "$PRIMARY_DISK" ] || PRIMARY_DISK="/dev/sda"

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

primary_source_expected() {
  local src="$1"
  [ -n "$src" ] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^${PRIMARY_DISK}([0-9]+)?$ ]] && return 0
  done <<< "$src"
  return 1
}

primary_partition() {
  local part=""
  if [ -b "${PRIMARY_DISK}1" ]; then
    part="${PRIMARY_DISK}1"
  elif [ -b "${PRIMARY_DISK}p1" ]; then
    part="${PRIMARY_DISK}p1"
  elif [ -b "$PRIMARY_DISK" ]; then
    part="$PRIMARY_DISK"
  fi
  [ -n "$part" ] && printf '%s\n' "$part" || return 1
}

primary_probe_ok() {
  local part probe mp srcs
  srcs="$(mount_sources "$MOUNT_MAIN")"
  if primary_source_expected "$srcs"; then
    return 0
  fi

  part="$(primary_partition || true)"
  [ -n "$part" ] || return 1

  probe="/mnt/.nas-primary-probe"
  mkdir -p "$probe"
  if ! mount -o ro "$part" "$probe" >/dev/null 2>&1; then
    return 1
  fi

  mp=0
  [ -d "$probe/photos" ] && mp=1
  umount "$probe" >/dev/null 2>&1 || umount -l "$probe" >/dev/null 2>&1 || true
  [ "$mp" -eq 1 ]
}

is_failover_active() {
  local src
  src="$(mount_source "$MOUNT_MAIN")"
  [ "$src" = "$FAILOVER_ROOT" ] && return 0
  [ -n "$FAILOVER_REL" ] && printf '%s' "$src" | grep -Fq "[$FAILOVER_REL]" && return 0
  return 1
}

main_io_ok() {
  local target="$MOUNT_MAIN/photos"
  [ -d "$target" ] || return 1
  timeout "$FAILOVER_IO_TIMEOUT_SEC" bash -c "ls '$target' >/dev/null 2>&1"
}

save_state() {
  local mode="$1" reason="$2"
  cat > "$STATE_FILE" <<EOF
FAILOVER_MODE=$mode
FAILOVER_REASON="$reason"
FAILOVER_UPDATED_AT=$(date -Iseconds)
FAILOVER_MAIN_SOURCE="$(mount_source "$MOUNT_MAIN")"
EOF
}

grave_reason() {
  local src
  if ! mountpoint -q "$MOUNT_MAIN"; then
    echo "main_unmounted"
    return 0
  fi

  src="$(mount_sources "$MOUNT_MAIN")"
  if ! primary_source_expected "$src"; then
    echo "main_source_invalid"
    return 0
  fi

  if is_true "$FAILOVER_IO_CHECK_ENABLED"; then
    if ! main_io_ok; then
      echo "main_io_unhealthy"
      return 0
    fi
  fi

  echo ""
}

activate_failover() {
  local why="$1"
  local src=""

  if ! mountpoint -q "$MOUNT_BACKUP"; then
    log "FAILOVER_ABORT: backup no montado ($MOUNT_BACKUP)"
    alert "🚨 Falla grave en disco principal pero no pude switchear
Razón: $why
El disco de respaldo no está montado.
Qué correr (TV Box):
1) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
2) /usr/local/bin/verify.sh"
    return 1
  fi

  if [ ! -d "$FAILOVER_ROOT/photos" ] || [ ! -d "$FAILOVER_ROOT/cache" ]; then
    log "FAILOVER_ABORT: failover-root incompleto ($FAILOVER_ROOT)"
    alert "🚨 Falla grave en disco principal pero no pude switchear
Razón: $why
No encontré el espejo operativo completo en respaldo.
Qué correr (TV Box):
1) /usr/local/bin/failover-sync.sh
2) /usr/local/bin/verify.sh"
    return 1
  fi

  if is_failover_active; then
    save_state "backup" "$why"
    return 0
  fi

  if mountpoint -q "$MOUNT_MAIN"; then
    src="$(mount_source "$MOUNT_MAIN")"
    if ! umount "$MOUNT_MAIN" >/dev/null 2>&1; then
      umount -l "$MOUNT_MAIN" >/dev/null 2>&1 || {
        log "FAILOVER_ABORT: no pude desmontar $MOUNT_MAIN (src=$src)"
        return 1
      }
    fi
  fi

  mkdir -p "$MOUNT_MAIN"
  mount --bind "$FAILOVER_ROOT" "$MOUNT_MAIN" || {
    log "FAILOVER_ABORT: fallo mount --bind $FAILOVER_ROOT -> $MOUNT_MAIN"
    return 1
  }

  if ! is_failover_active; then
    log "FAILOVER_ABORT: bind no quedó activo"
    return 1
  fi

  save_state "backup" "$why"
  log "FAILOVER_ON: reason=$why source=$(mount_source "$MOUNT_MAIN")"
  NAS_ALERT_KEY="storage_failover:on" NAS_ALERT_TTL=1800 alert "🚨 Switcheé al disco de respaldo
Detecté una falla grave del disco principal.
Razón técnica: $why
Acción automática: ahora /mnt/storage-main apunta al respaldo operativo.
El NAS seguirá trabajando sobre respaldo hasta revisión manual."
  return 0
}

deactivate_failover() {
  if ! is_failover_active; then
    save_state "primary" "already_primary"
    return 0
  fi

  umount "$MOUNT_MAIN" >/dev/null 2>&1 || umount -l "$MOUNT_MAIN" >/dev/null 2>&1 || true
  mount "$MOUNT_MAIN" >/dev/null 2>&1 || true

  if mountpoint -q "$MOUNT_MAIN" && primary_source_expected "$(mount_source "$MOUNT_MAIN")"; then
    save_state "primary" "manual_or_auto_recovery"
    log "FAILOVER_OFF: restored source=$(mount_source "$MOUNT_MAIN")"
    NAS_ALERT_KEY="storage_failover:off" NAS_ALERT_TTL=900 alert "✅ Regresé al disco principal
El almacenamiento principal volvió a estar disponible.
Modo actual: operación normal sobre disco principal."
    return 0
  fi

  # Seguridad: si no pude volver al principal, regreso al failover para no quedar caído.
  mount --bind "$FAILOVER_ROOT" "$MOUNT_MAIN" >/dev/null 2>&1 || true
  save_state "backup" "failback_failed"
  log "FAILOVER_OFF_ABORT: no pude volver al principal, se mantiene backup"
  return 1
}

status_cmd() {
  local src reason mode
  src="$(mount_source "$MOUNT_MAIN")"
  reason="$(grave_reason)"
  mode="unknown"
  if [ -f "$STATE_FILE" ]; then
    mode="$(awk -F= '$1=="FAILOVER_MODE"{print $2}' "$STATE_FILE" | tail -1)"
    [ -n "$mode" ] || mode="unknown"
  fi
  echo "mode=$mode"
  echo "main_source=${src:-none}"
  echo "main_is_mountpoint=$(mountpoint -q "$MOUNT_MAIN" && echo 1 || echo 0)"
  echo "failover_active=$(is_failover_active && echo 1 || echo 0)"
  echo "backup_mounted=$(mountpoint -q "$MOUNT_BACKUP" && echo 1 || echo 0)"
  echo "grave_reason=${reason:-none}"
  echo "primary_disk=$PRIMARY_DISK"
}

auto_cmd() {
  local why

  if ! is_true "$AUTO_FAILOVER_ENABLED"; then
    log "AUTO_SKIP: AUTO_FAILOVER_ENABLED=$AUTO_FAILOVER_ENABLED"
    return 0
  fi

  if is_failover_active; then
    if is_true "$AUTO_FAILBACK_ENABLED" && primary_probe_ok; then
      deactivate_failover || true
    fi
    if is_failover_active; then
      save_state "backup" "active_no_failback"
    else
      save_state "primary" "healthy_after_failback"
    fi
    return 0
  fi

  why="$(grave_reason)"
  if [ -n "$why" ]; then
    activate_failover "$why"
    return $?
  fi

  save_state "primary" "healthy"
  return 0
}

case "$MODE" in
  auto) auto_cmd ;;
  status) status_cmd ;;
  activate) activate_failover "$REASON" ;;
  deactivate) deactivate_failover ;;
  *)
    echo "Uso: $0 {auto|status|activate <reason>|deactivate}" >&2
    exit 1
    ;;
esac
