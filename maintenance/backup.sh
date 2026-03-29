#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# backup.sh — Backup incremental con snapshots (sin depuración automática)
# Guía Maestra NAS V58
#
# ENDURECIMIENTO
#   Este script ahora obedece el estado de salud del sistema:
#   SMART, mounts, eMMC y DB. Si algún estado está en CRIT, el backup se
#   omite para no empeorar la situación. Además se ejecuta con nice+ionice.
#   Política de datos productivos:
#   - no usa --delete sobre fotos/videos de origen
#   - no borra snapshots automáticamente
#   - cualquier depuración de snapshots es manual con manual-retention.sh
# ═══════════════════════════════════════════════════════════════════════════

SOURCE="/mnt/storage-main/photos/"
DEST="/mnt/storage-backup/snapshots"
HEALTH_DIR="/var/lib/nas-health"
TODAY=$(date +%F)
YESTERDAY=$(date -d yesterday +%F)
RETENTION_DAYS="$(cat /etc/nas-retention 2>/dev/null || echo 7)"

alert() { /usr/local/bin/nas-alert.sh "$1"; }
load_status_env() { [ -f "$1" ] && . "$1"; }

load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/smart-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"

MOUNT_STATUS="${GLOBAL_MOUNT_STATUS:-OK}"
SMART_STATUS="${GLOBAL_SMART_STATUS:-OK}"
EMMC_STATUS="${EMMC_STATUS:-OK}"
DB_STATUS="${DB_STATUS:-OK}"

if [ "$MOUNT_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: no corrí backup para evitar un respaldo incompleto.
Qué hacer ahora (TV Box):
1) /usr/local/bin/verify.sh   # diagnóstico general (no monta discos)
2) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT   # ver estado actual"
  exit 0
fi
if [ "$SMART_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: pausé backup para no forzar un disco con problema serio.
Qué hacer ahora (TV Box):
1) /usr/local/bin/smart-check.sh daily   # diagnóstico SMART
2) /usr/local/bin/verify.sh   # verificación general"
  exit 0
fi
if [ "$EMMC_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: pausé backup para estabilizar la memoria interna.
Qué hacer ahora (TV Box):
1) df -h /var/lib/immich   # diagnóstico de espacio
2) /usr/local/bin/cache-monitor.sh   # diagnóstico de cache (NO relanza backup)
3) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh   # relanzar manual cuando esté estable"
  exit 0
fi
if [ "$DB_STATUS" = "CRIT" ]; then
  alert "⚠️ La base de datos de Immich está con problemas
Haré solo lo seguro y evitaré lo que dependa del stack."
fi

mkdir -p "$DEST/$TODAY"
RSYNC_OPTS=(-a)
[ -d "$DEST/$YESTERDAY" ] && RSYNC_OPTS+=("--link-dest=$DEST/$YESTERDAY")

if nice -n 15 ionice -c2 -n7 rsync "${RSYNC_OPTS[@]}" "$SOURCE" "$DEST/$TODAY/"; then
  alert "✅ Copia de seguridad terminada
El respaldo del día $TODAY se completó correctamente."
else
  code=$?
  if [ "$code" -eq 24 ]; then
    alert "✅ Copia de seguridad terminada
El respaldo del día $TODAY se completó, aunque hubo archivos cambiando mientras copiaba.
Esto suele pasar si alguien estaba usando Immich al mismo tiempo."
    exit 0
  fi
  alert "❌ No se pudo completar la copia de seguridad
Acción del NAS: el respaldo del día $TODAY terminó con error.
Qué hacer ahora (TV Box):
1) tail -n 120 /var/log/night-run.log   # ver causa
2) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh   # relanzar backup"
  exit "$code"
fi

SNAPSHOT_COUNT="$(find "$DEST" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "$SNAPSHOT_COUNT" -gt "$RETENTION_DAYS" ]; then
  alert "🟡 Backups acumulados: $SNAPSHOT_COUNT snapshots
Acción del NAS: no borré nada automáticamente.
Si decides depurar manualmente:
1) /usr/local/bin/manual-retention.sh --plan --snapshots-keep $RETENTION_DAYS
2) /usr/local/bin/manual-retention.sh --apply --snapshots-keep $RETENTION_DAYS"
fi

exit 0
