#!/bin/bash
# Ejecución continua por "rebanadas" del reproceso de video.
# Se recomienda llamarlo por cron cada N minutos.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
REPROCESS_BIN="${VIDEO_AUTOPILOT_REPROCESS_BIN:-/usr/local/bin/video-reprocess-nightly.sh}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

VIDEO_AUTOPILOT_ENABLED="${VIDEO_AUTOPILOT_ENABLED:-1}"
VIDEO_AUTOPILOT_SLICE_MIN="${VIDEO_AUTOPILOT_SLICE_MIN:-8}"
VIDEO_AUTOPILOT_ALERT_TTL_SEC="${VIDEO_AUTOPILOT_ALERT_TTL_SEC:-3600}"

if [ "$VIDEO_AUTOPILOT_ENABLED" != "1" ]; then
  exit 0
fi

[ -x "$REPROCESS_BIN" ] || exit 1

if [ -x "$ALERT_BIN" ]; then
  NAS_ALERT_KEY="video_autopilot:tick" \
  NAS_ALERT_TTL="$VIDEO_AUTOPILOT_ALERT_TTL_SEC" \
  "$ALERT_BIN" "🤖 Autopiloto de video activo
Modo: ejecución continua por carga (CPU/RAM) en slices de ${VIDEO_AUTOPILOT_SLICE_MIN} min.
Se pausa solo si la caja se ocupa y retoma automáticamente." || true
fi

VIDEO_REPROCESS_MAX_RUNTIME_MIN="$VIDEO_AUTOPILOT_SLICE_MIN" "$REPROCESS_BIN"
