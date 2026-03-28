#!/bin/bash
# Ejecución continua por "rebanadas" del drenado IML.
# Se recomienda llamarlo por cron cada pocos minutos.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
IML_DRAIN_BIN="${IML_DRAIN_BIN:-/usr/local/bin/iml-backlog-drain.py}"
LOCK_FILE="/var/lock/iml-autopilot.lock"
LOG_FILE="/var/log/iml-autopilot.log"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

IML_AUTOPILOT_ENABLED="${IML_AUTOPILOT_ENABLED:-1}"
IML_AUTOPILOT_SLICE_MIN="${IML_AUTOPILOT_SLICE_MIN:-8}"
IML_AUTOPILOT_ALERT_TTL_SEC="${IML_AUTOPILOT_ALERT_TTL_SEC:-3600}"
IML_DYNAMIC_LOAD_ENABLED="${IML_DYNAMIC_LOAD_ENABLED:-1}"
IML_TARGETS="${IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
IML_PHASE_ORDER="${IML_PHASE_ORDER:-library|sidecar|metadataExtraction;smartSearch|duplicateDetection|ocr|faceDetection;facialRecognition}"
IML_API_URL="${IML_API_URL:-http://127.0.0.1:2283/api}"
IML_SECRETS_FILE="${IML_SECRETS_FILE:-/etc/nas-secrets}"
IML_SLEEP_SEC="${IML_SLEEP_SEC:-20}"
IML_LOG_EVERY="${IML_LOG_EVERY:-6}"
IML_MAX_CPU_PCT="${IML_MAX_CPU_PCT:-72}"
IML_MAX_MEM_PCT="${IML_MAX_MEM_PCT:-82}"
IML_MAX_TEMP_C="${IML_MAX_TEMP_C:-75}"
IML_CPU_SAMPLE_SEC="${IML_CPU_SAMPLE_SEC:-2}"
IML_REQUEST_LOG_PATH="${IML_REQUEST_LOG_PATH:-/var/log/nginx/access.log}"
IML_REQUEST_WINDOW_SEC="${IML_REQUEST_WINDOW_SEC:-20}"
IML_MAX_REQUESTS_PER_WINDOW="${IML_MAX_REQUESTS_PER_WINDOW:-8}"
IML_BUSY_ALERT_TTL_SEC="${IML_BUSY_ALERT_TTL_SEC:-1800}"
IML_AUTOPILOT_START_ML_IF_PENDING="${IML_AUTOPILOT_START_ML_IF_PENDING:-1}"
IML_AUTOPILOT_STOP_ML_WHEN_IDLE="${IML_AUTOPILOT_STOP_ML_WHEN_IDLE:-0}"
IML_ML_CONTAINER_NAME="${IML_ML_CONTAINER_NAME:-immich_machine_learning}"

if [ "$IML_AUTOPILOT_ENABLED" != "1" ]; then
  exit 0
fi

[ -f "$IML_DRAIN_BIN" ] || exit 1
command -v python3 >/dev/null 2>&1 || exit 1
command -v docker >/dev/null 2>&1 || exit 1

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

if [ -x "$ALERT_BIN" ]; then
  NAS_ALERT_KEY="iml_autopilot:tick" \
  NAS_ALERT_TTL="$IML_AUTOPILOT_ALERT_TTL_SEC" \
  "$ALERT_BIN" "🧠 Autopiloto IML activo
Modo: pausado/reanudado por CPU/RAM/requests.
Orden: library/sidecar/metadata -> smart/ocr/duplicados/caras -> reconocimiento facial." || true
fi

iml_pending_count() {
  python3 "$IML_DRAIN_BIN" \
    --api-url "$IML_API_URL" \
    --secrets-file "$IML_SECRETS_FILE" \
    --targets "$IML_TARGETS" \
    --print-pending-only 2>/dev/null || echo 0
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$IML_ML_CONTAINER_NAME"
}

wait_ml_ready() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec immich_server sh -lc 'curl -fsS --max-time 3 http://immich-machine-learning:3003/ping >/dev/null' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

pending_now="$(iml_pending_count)"
case "$pending_now" in
  ''|*[!0-9]*) pending_now=0 ;;
esac

if [ "$pending_now" -gt 0 ] && [ "$IML_AUTOPILOT_START_ML_IF_PENDING" = "1" ]; then
  if ! container_running; then
    docker start "$IML_ML_CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ -x "$ALERT_BIN" ]; then
      NAS_ALERT_KEY="iml_autopilot:ml_start" \
      NAS_ALERT_TTL=900 \
      "$ALERT_BIN" "⚙️ IML autopilot encendió Machine Learning para drenar colas pendientes (${pending_now})." || true
    fi
  fi
  if ! wait_ml_ready; then
    if [ -x "$ALERT_BIN" ]; then
      NAS_ALERT_KEY="iml_autopilot:ml_unreachable" \
      NAS_ALERT_TTL=900 \
      "$ALERT_BIN" "⚠️ IML autopilot detectó ML no disponible en este momento.
Acción: difiere el drenado y reintenta en el siguiente ciclo." || true
    fi
    exit 0
  fi
fi

cmd=(
  python3 "$IML_DRAIN_BIN"
  --api-url "$IML_API_URL"
  --secrets-file "$IML_SECRETS_FILE"
  --targets "$IML_TARGETS"
  --phase-order "$IML_PHASE_ORDER"
  --sleep-sec "$IML_SLEEP_SEC"
  --log-every "$IML_LOG_EVERY"
  --timeout-min "$IML_AUTOPILOT_SLICE_MIN"
  --timeout-soft
  --busy-alert-ttl-sec "$IML_BUSY_ALERT_TTL_SEC"
)

if [ "$IML_DYNAMIC_LOAD_ENABLED" = "1" ]; then
  cmd+=(
    --dynamic-load-enabled 1
    --max-cpu-pct "$IML_MAX_CPU_PCT"
    --max-mem-pct "$IML_MAX_MEM_PCT"
    --max-temp-c "$IML_MAX_TEMP_C"
    --cpu-sample-sec "$IML_CPU_SAMPLE_SEC"
    --request-log-path "$IML_REQUEST_LOG_PATH"
    --request-window-sec "$IML_REQUEST_WINDOW_SEC"
    --max-requests-window "$IML_MAX_REQUESTS_PER_WINDOW"
  )
else
  cmd+=(--dynamic-load-enabled 0)
fi

"${cmd[@]}" >> "$LOG_FILE" 2>&1
rc=$?

pending_after="$(iml_pending_count)"
case "$pending_after" in
  ''|*[!0-9]*) pending_after=0 ;;
esac

if [ "$pending_after" -eq 0 ] && [ "$IML_AUTOPILOT_STOP_ML_WHEN_IDLE" = "1" ]; then
  docker stop "$IML_ML_CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if [ "$rc" -ne 0 ] && [ -x "$ALERT_BIN" ]; then
  NAS_ALERT_KEY="iml_autopilot:fail" \
  NAS_ALERT_TTL=900 \
  "$ALERT_BIN" "⚠️ IML autopilot terminó con error (rc=$rc)
Revisa: /var/log/iml-autopilot.log" || true
fi

exit 0
