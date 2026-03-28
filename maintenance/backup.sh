#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# backup.sh — Backup incremental con snapshots por hard-links
# Guía Maestra NAS V58
#
# ENDURECIMIENTO
#   Este script ahora obedece el estado de salud del sistema:
#   SMART, mounts, eMMC y DB. Si algún estado está en CRIT, el backup se
#   omite para no empeorar la situación. Además se ejecuta con nice+ionice.
# ═══════════════════════════════════════════════════════════════════════════

SOURCE="/mnt/storage-main/photos/"
DEST="/mnt/storage-backup/snapshots"
HEALTH_DIR="/var/lib/nas-health"
TODAY=$(date +%F)
YESTERDAY=$(date -d yesterday +%F)

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
No pude ver bien los discos montados del NAS.
Para evitar un respaldo incompleto, hoy no corrí la copia.
Qué correr (TV Box, sin insumo):
Insumo: no aplica.
1) /usr/local/bin/verify.sh
2) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT"
  exit 0
fi
if [ "$SMART_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Uno de los discos reportó un problema serio.
Para no forzarlo más, hoy no hice el respaldo.
Qué correr (TV Box, sin insumo):
Insumo: no aplica.
1) /usr/local/bin/smart-check.sh daily
2) /usr/local/bin/verify.sh"
  exit 0
fi
if [ "$EMMC_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
La memoria interna del NAS está casi llena.
Primero hay que estabilizar el equipo.
Qué correr (TV Box, sin insumo):
Insumo: no aplica.
1) df -h /var/lib/immich
2) /usr/local/bin/cache-monitor.sh"
  exit 0
fi
if [ "$DB_STATUS" = "CRIT" ]; then
  alert "⚠️ La base de datos de Immich está con problemas
Haré solo lo seguro y evitaré lo que dependa del stack."
fi

mkdir -p "$DEST/$TODAY"
LAST_LINK=""
[ -d "$DEST/$YESTERDAY" ] && LAST_LINK="--link-dest=$DEST/$YESTERDAY"

if nice -n 15 ionice -c2 -n7 rsync -a --delete $LAST_LINK "$SOURCE" "$DEST/$TODAY/"; then
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
El respaldo del día $TODAY terminó con un error.
Qué correr (TV Box, sin insumo):
Insumo: no aplica.
1) tail -n 120 /var/log/night-run.log
2) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh"
  exit "$code"
fi

find "$DEST" -mindepth 1 -maxdepth 1 -type d | sort | head -n -7 | xargs -r rm -rf
exit 0
