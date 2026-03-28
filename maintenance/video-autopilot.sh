#!/bin/bash
# Ejecución continua por "rebanadas" del reproceso de video.
# Se recomienda llamarlo por cron cada N minutos.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
REPROCESS_BIN="${VIDEO_AUTOPILOT_REPROCESS_BIN:-/usr/local/bin/video-reprocess-nightly.sh}"
IML_DRAIN_BIN="${IML_DRAIN_BIN:-/usr/local/bin/iml-backlog-drain.py}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

VIDEO_AUTOPILOT_ENABLED="${VIDEO_AUTOPILOT_ENABLED:-1}"
VIDEO_AUTOPILOT_SLICE_MIN="${VIDEO_AUTOPILOT_SLICE_MIN:-8}"
VIDEO_AUTOPILOT_ALERT_TTL_SEC="${VIDEO_AUTOPILOT_ALERT_TTL_SEC:-3600}"
VIDEO_AUTOPILOT_REQUIRE_IML_DRAIN="${VIDEO_AUTOPILOT_REQUIRE_IML_DRAIN:-1}"
VIDEO_AUTOPILOT_IML_TARGETS="${VIDEO_AUTOPILOT_IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
VIDEO_AUTOPILOT_IML_API_URL="${VIDEO_AUTOPILOT_IML_API_URL:-http://127.0.0.1:2283/api}"
VIDEO_AUTOPILOT_IML_SECRETS_FILE="${VIDEO_AUTOPILOT_IML_SECRETS_FILE:-/etc/nas-secrets}"

if [ "$VIDEO_AUTOPILOT_ENABLED" != "1" ]; then
  exit 0
fi

[ -x "$REPROCESS_BIN" ] || exit 1

iml_pending_count() {
  [ -f "$IML_DRAIN_BIN" ] || { echo 0; return; }
  python3 "$IML_DRAIN_BIN" \
    --api-url "$VIDEO_AUTOPILOT_IML_API_URL" \
    --secrets-file "$VIDEO_AUTOPILOT_IML_SECRETS_FILE" \
    --targets "$VIDEO_AUTOPILOT_IML_TARGETS" \
    --print-pending-only 2>/dev/null || echo 0
}

if [ -x "$ALERT_BIN" ]; then
  NAS_ALERT_KEY="video_autopilot:tick" \
  NAS_ALERT_TTL="$VIDEO_AUTOPILOT_ALERT_TTL_SEC" \
  "$ALERT_BIN" "🎬 Video automático activo
Primero termina IML y luego procesa videos.
Si la caja se ocupa, pausa y retoma solo." || true
fi

if [ "$VIDEO_AUTOPILOT_REQUIRE_IML_DRAIN" = "1" ]; then
  pending="$(iml_pending_count)"
  case "$pending" in
    ''|*[!0-9]*) pending=0 ;;
  esac
  if [ "$pending" -gt 0 ]; then
    if [ -x "$ALERT_BIN" ]; then
      NAS_ALERT_KEY="video_autopilot:wait_iml" \
      NAS_ALERT_TTL="$VIDEO_AUTOPILOT_ALERT_TTL_SEC" \
      "$ALERT_BIN" "⏳ Video en espera
IML todavía tiene pendiente: $pending.
Reintento automático en el siguiente ciclo." || true
    fi
    exit 0
  fi
fi

VIDEO_REPROCESS_MAX_RUNTIME_MIN="$VIDEO_AUTOPILOT_SLICE_MIN" "$REPROCESS_BIN"
