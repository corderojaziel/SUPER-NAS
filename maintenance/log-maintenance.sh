#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# log-maintenance.sh — Depuración mensual de logs técnicos
#
# Política:
# - Solo limpia/rota logs y archivos de estado técnicos
# - NO toca fotos/videos ni cache multimedia productivo
# - Mantiene evidencia suficiente para auditoría posterior
# ═══════════════════════════════════════════════════════════════════════════

set -u

LOGROTATE_BIN="${LOGROTATE_BIN:-/usr/sbin/logrotate}"
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/supernas}"
LOGROTATE_STATE="${LOGROTATE_STATE:-/var/lib/logrotate/status-supernas}"
JOURNALCTL_BIN="${JOURNALCTL_BIN:-/usr/bin/journalctl}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
REPROCESS_DIR="${TEMP_CLEAN_REPROCESS_DIR:-/var/lib/nas-health/reprocess}"
REPROCESS_AGE_DAYS="${TEMP_CLEAN_REPROCESS_AGE_DAYS:-2}"

case "$REPROCESS_AGE_DAYS" in
  ''|*[!0-9]*) REPROCESS_AGE_DAYS=2 ;;
esac
if [ "$REPROCESS_AGE_DAYS" -lt 1 ]; then REPROCESS_AGE_DAYS=1; fi

mkdir -p /var/lib/logrotate /var/lib/nas-alert-state /var/lib/nas-health/reprocess

if [ -x "$LOGROTATE_BIN" ] && [ -f "$LOGROTATE_CONF" ]; then
  "$LOGROTATE_BIN" -s "$LOGROTATE_STATE" "$LOGROTATE_CONF" >/dev/null 2>&1 || true
fi

if [ -x "$JOURNALCTL_BIN" ]; then
  "$JOURNALCTL_BIN" --vacuum-size=200M >/dev/null 2>&1 || true
fi

# Limpieza de históricos muy viejos (solo archivos técnicos rotados).
find /var/log -maxdepth 1 -type f \
  \( -name "night-run.log.*" -o -name "video-reprocess-nightly.log.*" -o -name "iml-autopilot.log.*" \
     -o -name "playback-audit-autoheal.log.*" -o -name "playback-watchdog.log.*" -o -name "nas-audit.log.*" \
     -o -name "nas-install.log.*" -o -name "dockerd-manual.log.*" \) \
  -mtime +180 -delete 2>/dev/null || true

# Estado anti-spam de Telegram muy antiguo.
find /var/lib/nas-alert-state -type f -name "*.ts" -mtime +180 -delete 2>/dev/null || true

# Planes/reportes transitorios de reproceso viejos.
# Conservar siempre *latest* para no romper consumidores del último estado.
if [ -d "$REPROCESS_DIR" ]; then
  find "$REPROCESS_DIR" -maxdepth 3 -type f \
    \( -name '*.csv' -o -name '*.json' -o -name '*.log' \) \
    -mtime +"$REPROCESS_AGE_DAYS" ! -name '*latest*' -delete 2>/dev/null || true
  find "$REPROCESS_DIR" -maxdepth 1 -type d -name 'chunks*' -mtime +"$REPROCESS_AGE_DAYS" -exec rm -rf {} + 2>/dev/null || true
fi

if [ -x "$NAS_ALERT_BIN" ]; then
  NAS_ALERT_KEY="logs_maintenance:monthly" NAS_ALERT_TTL=86400 \
    "$NAS_ALERT_BIN" "🧹 Mantenimiento mensual de logs completado
Acción del NAS: roté y depuré logs técnicos antiguos para cuidar espacio.
Importante: no se tocó contenido de fotos/videos." || true
fi

exit 0
