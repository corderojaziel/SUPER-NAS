#!/bin/bash
# Reconstrucción de cache de video después de pérdida parcial/total.
#
# Modos:
#   prepare      -> solo genera insumos (light/heavy/broken CSV)
#   light-only   -> genera insumos + procesa todos los ligeros en TV Box
#   tvbox-all    -> light-only + intenta pesados en TV Box (lento)
#
# Recomendado en producción:
#   1) prepare
#   2) light-only (TV Box)
#   3) pesados con PC/GPU usando powershell/reprocess_heavy_from_server.ps1

set -euo pipefail

MODE="${1:-prepare}"
POLICY_FILE="/etc/default/nas-video-policy"
[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

MANAGER_BIN="${VIDEO_REPROCESS_MANAGER_BIN:-/usr/local/bin/video-reprocess-manager.py}"
BACKFILL_BIN="${BACKFILL_HEAVY_CACHE_BIN:-/usr/local/bin/backfill-heavy-cache.py}"
OUTPUT_DIR="${VIDEO_REPROCESS_OUTPUT_DIR:-/var/lib/nas-health/reprocess}"
CACHE_ROOT="${VIDEO_REPROCESS_CACHE_ROOT:-/var/lib/immich/cache}"
LEGACY_ROOT="${VIDEO_REPROCESS_LEGACY_ROOT:-/mnt/storage-main/cache}"
UPLOAD_ROOT="${VIDEO_REPROCESS_UPLOAD_ROOT:-/mnt/storage-main/photos}"
IMMICH_ROOT="${VIDEO_REPROCESS_IMMICH_ROOT:-/var/lib/immich}"
MAX_MB_MIN="${VIDEO_STREAM_MAX_MB_PER_MIN:-40}"
LOCAL_MAX_MB="${VIDEO_REPROCESS_LOCAL_MAX_MB:-220}"
LOCAL_MAX_DURATION_SEC="${VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC:-150}"
LOCAL_MAX_MB_MIN="${VIDEO_REPROCESS_LOCAL_MAX_MB_MIN:-120}"
ATTEMPTS_DB="${VIDEO_REPROCESS_ATTEMPTS_DB:-/var/lib/nas-retry/video-reprocess-light.attempts.tsv}"
MANUAL_QUEUE="${VIDEO_REPROCESS_MANUAL_QUEUE:-/var/lib/nas-retry/video-reprocess-manual.tsv}"
MAX_ATTEMPTS="${VIDEO_REPROCESS_MAX_ATTEMPTS:-3}"
AUDIO_K="${VIDEO_REPROCESS_AUDIO_BITRATE_K:-128}"
MAXRATE_K="${VIDEO_REPROCESS_TARGET_MAXRATE_K:-5200}"

mkdir -p "$OUTPUT_DIR" /var/lib/nas-retry

run_plan() {
  python3 "$MANAGER_BIN" plan \
    --cache-root "$CACHE_ROOT" \
    --legacy-root "$LEGACY_ROOT" \
    --upload-host-root "$UPLOAD_ROOT" \
    --immich-local-root "$IMMICH_ROOT" \
    --output-dir "$OUTPUT_DIR" \
    --max-mb-min "$MAX_MB_MIN" \
    --local-max-mb "$LOCAL_MAX_MB" \
    --local-max-duration-sec "$LOCAL_MAX_DURATION_SEC" \
    --local-max-mb-min "$LOCAL_MAX_MB_MIN"
}

run_light() {
  python3 "$MANAGER_BIN" run \
    --class light \
    --cache-root "$CACHE_ROOT" \
    --legacy-root "$LEGACY_ROOT" \
    --upload-host-root "$UPLOAD_ROOT" \
    --immich-local-root "$IMMICH_ROOT" \
    --output-dir "$OUTPUT_DIR" \
    --input-csv "$OUTPUT_DIR/light-latest.csv" \
    --limit 0 \
    --attempts-db "$ATTEMPTS_DB" \
    --manual-queue "$MANUAL_QUEUE" \
    --max-attempts "$MAX_ATTEMPTS" \
    --audio-bitrate-k "$AUDIO_K" \
    --target-maxrate-k "$MAXRATE_K"
}

run_heavy_tvbox() {
  if [ ! -x "$BACKFILL_BIN" ]; then
    echo "WARN: no existe $BACKFILL_BIN, omito pesados en TV Box"
    return 0
  fi
  ionice -c3 nice -n 15 python3 "$BACKFILL_BIN" \
    --cache-root "$CACHE_ROOT" \
    --legacy-root "$LEGACY_ROOT" \
    --max-mb-min "$MAX_MB_MIN"
}

case "$MODE" in
  prepare)
    run_plan
    ;;
  light-only)
    run_plan
    run_light
    ;;
  tvbox-all)
    run_plan
    run_light
    run_heavy_tvbox
    ;;
  *)
    echo "Modo inválido: $MODE"
    echo "Uso: $0 [prepare|light-only|tvbox-all]"
    exit 1
    ;;
esac

echo "OK modo=$MODE output=$OUTPUT_DIR"
