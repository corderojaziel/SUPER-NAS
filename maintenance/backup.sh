#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# backup.sh — Respaldo operativo (sin snapshots/restic de fotos/videos)
# Guía Maestra NAS V58
#
# Política vigente:
#   - Fotos/videos NO usan snapshots ni restic.
#   - Se mantiene espejo operativo de failover (failover-sync).
#   - Backups de DB/estado siguen en sus scripts dedicados.
# ═══════════════════════════════════════════════════════════════════════════

set -u

HEALTH_DIR="/var/lib/nas-health"
POLICY_FILE="/etc/default/nas-video-policy"
FAILOVER_ROOT="${FAILOVER_ROOT:-/mnt/storage-backup/failover-main}"
FAILOVER_SYNC_BIN="${FAILOVER_SYNC_BIN:-/usr/local/bin/failover-sync.sh}"
FAILOVER_SYNC_ENABLED="${FAILOVER_SYNC_ENABLED:-1}"
BACKUP_PHOTOS_MODE="${BACKUP_PHOTOS_MODE:-disabled}"

alert() { /usr/local/bin/nas-alert.sh "$1" || true; }
load_status_env() { [ -f "$1" ] && . "$1"; }
is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_failover_active() {
  local src rel
  src="$(findmnt -n -o SOURCE /mnt/storage-main 2>/dev/null | tail -n1 || true)"
  [ "$src" = "$FAILOVER_ROOT" ] && return 0
  rel="$FAILOVER_ROOT"
  case "$FAILOVER_ROOT" in
    /mnt/storage-backup/*) rel="${FAILOVER_ROOT#/mnt/storage-backup}" ;;
  esac
  [ -n "$rel" ] && printf '%s' "$src" | grep -Fq "[$rel]" && return 0
  return 1
}

load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/smart-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"
[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
BACKUP_PHOTOS_MODE="$(printf '%s' "$BACKUP_PHOTOS_MODE" | tr '[:upper:]' '[:lower:]')"

MOUNT_STATUS="${GLOBAL_MOUNT_STATUS:-OK}"
SMART_STATUS="${GLOBAL_SMART_STATUS:-OK}"
EMMC_STATUS="${EMMC_STATUS:-OK}"
DB_STATUS="${DB_STATUS:-OK}"

if [ "$MOUNT_STATUS" = "CRIT" ]; then
  alert "⏭️ Respaldo operativo pospuesto
Acción del NAS: no corrí sincronización para evitar un estado incompleto.
Qué hacer ahora (TV Box):
1) /usr/local/bin/verify.sh
2) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT"
  exit 0
fi

if [ "$SMART_STATUS" = "CRIT" ]; then
  alert "⏭️ Respaldo operativo pospuesto
Acción del NAS: pausé sincronización para no forzar discos con problema serio.
Qué hacer ahora (TV Box):
1) /usr/local/bin/smart-check.sh daily
2) /usr/local/bin/verify.sh"
  exit 0
fi

if [ "$EMMC_STATUS" = "CRIT" ]; then
  alert "⏭️ Respaldo operativo pospuesto
Acción del NAS: pausé sincronización para estabilizar memoria interna.
Qué hacer ahora (TV Box):
1) df -h /var/lib/immich
2) /usr/local/bin/cache-monitor.sh
3) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh"
  exit 0
fi

if [ "$DB_STATUS" = "CRIT" ]; then
  alert "⚠️ Base de datos de Immich con problemas
Acción del NAS: hago solo tareas seguras y sigo monitoreando."
fi

if is_failover_active; then
  alert "⏭️ Respaldo operativo pospuesto
Acción del NAS: detecté modo failover activo; hoy no sincronicé para evitar auto-copia.
Qué correr (TV Box):
1) /usr/local/bin/storage-failover.sh status
2) /usr/local/bin/verify.sh"
  exit 0
fi

if [ "$BACKUP_PHOTOS_MODE" != "disabled" ] && [ "$BACKUP_PHOTOS_MODE" != "none" ] && [ "$BACKUP_PHOTOS_MODE" != "off" ]; then
  NAS_ALERT_KEY="backup:legacy_mode_forced_disabled" NAS_ALERT_TTL=86400 alert "ℹ️ Modo legado detectado: $BACKUP_PHOTOS_MODE
Acción del NAS: snapshots/restic de fotos/videos ya no forman parte del flujo y se omiten."
else
  NAS_ALERT_KEY="backup:photos_disabled" NAS_ALERT_TTL=86400 alert "ℹ️ Fotos/videos sin snapshots/restic por política
Acción del NAS: mantengo solo respaldo operativo por espejo (failover-sync)."
fi

if is_true "$FAILOVER_SYNC_ENABLED" && [ -x "$FAILOVER_SYNC_BIN" ]; then
  if nice -n 15 ionice -c2 -n7 "$FAILOVER_SYNC_BIN" sync >/tmp/failover-sync-last.log 2>&1; then
    exit 0
  fi

  alert "⚠️ No pude actualizar el espejo de failover
Qué correr (TV Box):
1) tail -n 120 /tmp/failover-sync-last.log
2) /usr/local/bin/failover-sync.sh sync
3) /usr/local/bin/storage-failover.sh status"
  exit 1
fi

NAS_ALERT_KEY="backup:sync_disabled" NAS_ALERT_TTL=86400 alert "ℹ️ Sincronización de failover desactivada
Acción del NAS: no corrí failover-sync porque está deshabilitado por política."
exit 0
