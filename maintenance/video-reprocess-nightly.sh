#!/bin/bash
# Planifica y reintenta solo videos "ligeros para TV Box" durante la noche.
# Los casos pesados se dejan en cola manual para reproceso en PC con GPU.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
STATE_DIR="/var/lib/nas-retry"
HEALTH_DIR="/var/lib/nas-health"
LOG_FILE="/var/log/video-reprocess-nightly.log"
SUMMARY_FILE="$HEALTH_DIR/video-reprocess-summary.env"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
MANAGER_BIN="${VIDEO_REPROCESS_MANAGER_BIN:-/usr/local/bin/video-reprocess-manager.py}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

VIDEO_REPROCESS_OUTPUT_DIR="${VIDEO_REPROCESS_OUTPUT_DIR:-$HEALTH_DIR/reprocess}"
VIDEO_REPROCESS_CACHE_ROOT="${VIDEO_REPROCESS_CACHE_ROOT:-/var/lib/immich/cache}"
VIDEO_REPROCESS_LEGACY_ROOT="${VIDEO_REPROCESS_LEGACY_ROOT:-/mnt/storage-main/cache}"
VIDEO_REPROCESS_UPLOAD_ROOT="${VIDEO_REPROCESS_UPLOAD_ROOT:-/mnt/storage-main/photos}"
VIDEO_REPROCESS_IMMICH_ROOT="${VIDEO_REPROCESS_IMMICH_ROOT:-/var/lib/immich}"
VIDEO_STREAM_MAX_MB_PER_MIN="${VIDEO_STREAM_MAX_MB_PER_MIN:-40}"
VIDEO_REPROCESS_LOCAL_MAX_MB="${VIDEO_REPROCESS_LOCAL_MAX_MB:-220}"
VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC="${VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC:-150}"
VIDEO_REPROCESS_LOCAL_MAX_MB_MIN="${VIDEO_REPROCESS_LOCAL_MAX_MB_MIN:-120}"
VIDEO_REPROCESS_LIGHT_LIMIT="${VIDEO_REPROCESS_LIGHT_LIMIT:-0}"
VIDEO_REPROCESS_MAX_ATTEMPTS="${VIDEO_REPROCESS_MAX_ATTEMPTS:-3}"
VIDEO_REPROCESS_AUDIO_BITRATE_K="${VIDEO_REPROCESS_AUDIO_BITRATE_K:-128}"
VIDEO_REPROCESS_TARGET_MAXRATE_K="${VIDEO_REPROCESS_TARGET_MAXRATE_K:-5200}"
VIDEO_REPROCESS_ATTEMPTS_DB="${VIDEO_REPROCESS_ATTEMPTS_DB:-$STATE_DIR/video-reprocess-light.attempts.tsv}"
VIDEO_REPROCESS_MANUAL_QUEUE="${VIDEO_REPROCESS_MANUAL_QUEUE:-$STATE_DIR/video-reprocess-manual.tsv}"

mkdir -p "$STATE_DIR" "$HEALTH_DIR" "$VIDEO_REPROCESS_OUTPUT_DIR" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

alert() {
  [ -x "$ALERT_BIN" ] || return 0
  "$ALERT_BIN" "$1" || true
}

csv_count() {
  local file="$1"
  [ -f "$file" ] || { echo 0; return; }
  awk 'END{ if (NR>0) print NR-1; else print 0 }' "$file" 2>/dev/null
}

if [ ! -f "$MANAGER_BIN" ]; then
  log "ERROR: no existe manager: $MANAGER_BIN"
  alert "❌ Reproceso nocturno de videos no pudo iniciar
No encontré el script del gestor en el NAS."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 no disponible"
  alert "❌ Reproceso nocturno de videos no pudo iniciar
Python3 no está disponible en el NAS."
  exit 1
fi

log "INICIO: plan de reproceso"
if ! python3 "$MANAGER_BIN" plan \
  --cache-root "$VIDEO_REPROCESS_CACHE_ROOT" \
  --legacy-root "$VIDEO_REPROCESS_LEGACY_ROOT" \
  --upload-host-root "$VIDEO_REPROCESS_UPLOAD_ROOT" \
  --immich-local-root "$VIDEO_REPROCESS_IMMICH_ROOT" \
  --output-dir "$VIDEO_REPROCESS_OUTPUT_DIR" \
  --max-mb-min "$VIDEO_STREAM_MAX_MB_PER_MIN" \
  --local-max-mb "$VIDEO_REPROCESS_LOCAL_MAX_MB" \
  --local-max-duration-sec "$VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC" \
  --local-max-mb-min "$VIDEO_REPROCESS_LOCAL_MAX_MB_MIN" \
  >> "$LOG_FILE" 2>&1; then
  alert "❌ Falló la planeación de reproceso de video
No pude generar los insumos de noche."
  exit 1
fi

LIGHT_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/light-latest.csv"
HEAVY_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/heavy-latest.csv"
BROKEN_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/broken-latest.csv"
RUN_REPORT="$VIDEO_REPROCESS_OUTPUT_DIR/run-light-latest.csv"

light_total=$(csv_count "$LIGHT_FILE")
heavy_total=$(csv_count "$HEAVY_FILE")
broken_total=$(csv_count "$BROKEN_FILE")

log "Plan listo: light=$light_total heavy=$heavy_total broken=$broken_total"

run_status="SKIPPED"
if [ "$light_total" -gt 0 ]; then
  log "INICIO: reproceso ligero"
  if python3 "$MANAGER_BIN" run \
    --class light \
    --cache-root "$VIDEO_REPROCESS_CACHE_ROOT" \
    --legacy-root "$VIDEO_REPROCESS_LEGACY_ROOT" \
    --upload-host-root "$VIDEO_REPROCESS_UPLOAD_ROOT" \
    --immich-local-root "$VIDEO_REPROCESS_IMMICH_ROOT" \
    --output-dir "$VIDEO_REPROCESS_OUTPUT_DIR" \
    --input-csv "$LIGHT_FILE" \
    --limit "$VIDEO_REPROCESS_LIGHT_LIMIT" \
    --attempts-db "$VIDEO_REPROCESS_ATTEMPTS_DB" \
    --manual-queue "$VIDEO_REPROCESS_MANUAL_QUEUE" \
    --max-attempts "$VIDEO_REPROCESS_MAX_ATTEMPTS" \
    --audio-bitrate-k "$VIDEO_REPROCESS_AUDIO_BITRATE_K" \
    --target-maxrate-k "$VIDEO_REPROCESS_TARGET_MAXRATE_K" \
    >> "$LOG_FILE" 2>&1; then
    run_status="OK"
  else
    run_status="FAIL"
  fi
else
  log "SKIP: no hay candidatos ligeros"
fi

converted=0
failed=0
skipped=0
if [ -f "$RUN_REPORT" ]; then
  converted=$(awk -F, 'NR>1 && ($5=="remux_copy" || $5=="transcode_x264"){c++} END{print c+0}' "$RUN_REPORT")
  failed=$(awk -F, 'NR>1 && ($5=="ffmpeg_failed" || $5=="missing_source" || $5=="invalid_destination" || $5=="bad_row"){c++} END{print c+0}' "$RUN_REPORT")
  skipped=$(awk -F, 'NR>1 && ($5=="dry_run" || $5=="max_attempts_reached"){c++} END{print c+0}' "$RUN_REPORT")
fi

manual_total=$(csv_count "$VIDEO_REPROCESS_MANUAL_QUEUE")

cat > "$SUMMARY_FILE" <<EOF
VIDEO_REPROCESS_TS=$(date -Iseconds)
VIDEO_REPROCESS_LIGHT_TOTAL=$light_total
VIDEO_REPROCESS_HEAVY_TOTAL=$heavy_total
VIDEO_REPROCESS_BROKEN_TOTAL=$broken_total
VIDEO_REPROCESS_CONVERTED=$converted
VIDEO_REPROCESS_FAILED=$failed
VIDEO_REPROCESS_SKIPPED=$skipped
VIDEO_REPROCESS_MANUAL_TOTAL=$manual_total
VIDEO_REPROCESS_STATUS=$run_status
EOF

if [ "$run_status" = "FAIL" ]; then
  alert "⚠️ Reproceso nocturno de videos terminó con errores
Ligeros convertidos: $converted
Fallidos: $failed
Pendientes manuales: $manual_total
Insumos: $VIDEO_REPROCESS_OUTPUT_DIR"
  exit 1
fi

alert "🌙 Reproceso nocturno de videos completado
Ligeros evaluados: $light_total
Ligeros convertidos: $converted
Pendientes para PC (pesados): $heavy_total
Fuentes dañadas/faltantes: $broken_total
Pendientes manuales acumulados: $manual_total"
exit 0
