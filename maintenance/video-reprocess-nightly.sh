#!/bin/bash
# Planifica y reprocesa videos con control de carga (CPU/RAM).
# Comportamiento:
# - deja correr por lotes cuando la caja esta desocupada
# - pausa automaticamente cuando detecta carga alta
# - retoma cuando la carga baja
# - no obliga esperar a "otra noche": puede invocarse en cualquier hora

set -u

POLICY_FILE="/etc/default/nas-video-policy"
STATE_DIR="/var/lib/nas-retry"
HEALTH_DIR="/var/lib/nas-health"
LOG_FILE="/var/log/video-reprocess-nightly.log"
SUMMARY_FILE="$HEALTH_DIR/video-reprocess-summary.env"
LOCK_FILE="/var/lock/video-reprocess-nightly.lock"
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
VIDEO_REPROCESS_HEAVY_ENABLED="${VIDEO_REPROCESS_HEAVY_ENABLED:-1}"
VIDEO_REPROCESS_HEAVY_LIMIT="${VIDEO_REPROCESS_HEAVY_LIMIT:-0}"
VIDEO_REPROCESS_MAX_ATTEMPTS="${VIDEO_REPROCESS_MAX_ATTEMPTS:-3}"
VIDEO_REPROCESS_AUDIO_BITRATE_K="${VIDEO_REPROCESS_AUDIO_BITRATE_K:-128}"
VIDEO_REPROCESS_TARGET_MAXRATE_K="${VIDEO_REPROCESS_TARGET_MAXRATE_K:-5200}"
VIDEO_REPROCESS_ATTEMPTS_DB="${VIDEO_REPROCESS_ATTEMPTS_DB:-$STATE_DIR/video-reprocess-light.attempts.tsv}"
VIDEO_REPROCESS_MANUAL_QUEUE="${VIDEO_REPROCESS_MANUAL_QUEUE:-$STATE_DIR/video-reprocess-manual.tsv}"

# Nuevos controles por carga
VIDEO_REPROCESS_MAX_CPU_PCT="${VIDEO_REPROCESS_MAX_CPU_PCT:-72}"
VIDEO_REPROCESS_MAX_MEM_PCT="${VIDEO_REPROCESS_MAX_MEM_PCT:-82}"
VIDEO_REPROCESS_MAX_TEMP_C="${VIDEO_REPROCESS_MAX_TEMP_C:-75}"
VIDEO_REPROCESS_CPU_SAMPLE_SEC="${VIDEO_REPROCESS_CPU_SAMPLE_SEC:-2}"
VIDEO_REPROCESS_REQUEST_LOG_PATH="${VIDEO_REPROCESS_REQUEST_LOG_PATH:-/var/log/nginx/access.log}"
VIDEO_REPROCESS_REQUEST_WINDOW_SEC="${VIDEO_REPROCESS_REQUEST_WINDOW_SEC:-20}"
VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW="${VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW:-8}"
VIDEO_REPROCESS_BATCH_LIGHT="${VIDEO_REPROCESS_BATCH_LIGHT:-35}"
VIDEO_REPROCESS_BATCH_HEAVY="${VIDEO_REPROCESS_BATCH_HEAVY:-5}"
VIDEO_REPROCESS_MAX_RUNTIME_MIN="${VIDEO_REPROCESS_MAX_RUNTIME_MIN:-170}"
VIDEO_REPROCESS_IDLE_SLEEP_SEC="${VIDEO_REPROCESS_IDLE_SLEEP_SEC:-45}"
VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC="${VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC:-1800}"
VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED="${VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED:-1}"
VIDEO_NOTIFY_BACKLOG_THRESHOLD="${VIDEO_NOTIFY_BACKLOG_THRESHOLD:-10}"
VIDEO_NOTIFY_STUCK_MIN="${VIDEO_NOTIFY_STUCK_MIN:-20}"
VIDEO_NOTIFY_STATE_FILE="${VIDEO_NOTIFY_STATE_FILE:-$HEALTH_DIR/video-notify-state.env}"
VIDEO_NOTIFY_VERBOSE="${VIDEO_NOTIFY_VERBOSE:-0}"

mkdir -p "$STATE_DIR" "$HEALTH_DIR" "$VIDEO_REPROCESS_OUTPUT_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

alert() {
  [ -x "$ALERT_BIN" ] || return 0
  "$ALERT_BIN" "$1" || true
}

alert_throttled() {
  local key="$1"
  local ttl="$2"
  local msg="$3"
  [ -x "$ALERT_BIN" ] || return 0
  NAS_ALERT_KEY="$key" NAS_ALERT_TTL="$ttl" "$ALERT_BIN" "$msg" || true
}

csv_count() {
  local file="$1"
  [ -f "$file" ] || { echo 0; return; }
  awk 'END{ if (NR>0) print NR-1; else print 0 }' "$file" 2>/dev/null
}

load_notify_state() {
  NOTIFY_LAST_PENDING=0
  NOTIFY_STUCK_SINCE=0
  NOTIFY_ALERT_OPEN=0
  [ -f "$VIDEO_NOTIFY_STATE_FILE" ] && . "$VIDEO_NOTIFY_STATE_FILE"
  NOTIFY_LAST_PENDING="${NOTIFY_LAST_PENDING:-0}"
  NOTIFY_STUCK_SINCE="${NOTIFY_STUCK_SINCE:-0}"
  NOTIFY_ALERT_OPEN="${NOTIFY_ALERT_OPEN:-0}"
}

save_notify_state() {
  local now_ts="$1"
  mkdir -p "$(dirname "$VIDEO_NOTIFY_STATE_FILE")"
  cat > "$VIDEO_NOTIFY_STATE_FILE" <<EOF
NOTIFY_LAST_PENDING=$NOTIFY_LAST_PENDING
NOTIFY_STUCK_SINCE=$NOTIFY_STUCK_SINCE
NOTIFY_ALERT_OPEN=$NOTIFY_ALERT_OPEN
NOTIFY_TS=$now_ts
EOF
}

if [ ! -f "$MANAGER_BIN" ]; then
  log "ERROR: no existe manager: $MANAGER_BIN"
  alert "❌ Reproceso de videos no pudo iniciar
No encontré el script del gestor en el NAS.
Dónde correr: TV Box
Insumo: no aplica.
Qué correr:
1) ls -lah /usr/local/bin/video-reprocess-manager.py
2) /usr/local/bin/verify.sh"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 no disponible"
  alert "❌ Reproceso de videos no pudo iniciar
Python3 no está disponible en el NAS.
Dónde correr: TV Box
Insumo: no aplica.
Qué correr:
1) command -v python3
2) /usr/local/bin/verify.sh"
  exit 1
fi

cpu_snapshot() {
  awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat
}

cpu_busy_pct() {
  local s1 s2
  s1="$(cpu_snapshot)"
  sleep "$VIDEO_REPROCESS_CPU_SAMPLE_SEC"
  s2="$(cpu_snapshot)"

  awk -v a="$s1" -v b="$s2" '
    BEGIN {
      split(a, x, " "); split(b, y, " ");
      idle1 = x[4] + x[5];
      idle2 = y[4] + y[5];
      total1 = 0; total2 = 0;
      for (i = 1; i <= 8; i++) {
        total1 += x[i];
        total2 += y[i];
      }
      d_total = total2 - total1;
      d_idle = idle2 - idle1;
      if (d_total <= 0) { print 0; exit; }
      busy = (100.0 * (d_total - d_idle)) / d_total;
      if (busy < 0) busy = 0;
      if (busy > 100) busy = 100;
      printf "%.1f\n", busy;
    }'
}

mem_used_pct() {
  awk '
    /^MemTotal:/ {total=$2}
    /^MemAvailable:/ {avail=$2}
    END {
      if (total <= 0 || avail < 0) { print 0; exit; }
      used = 100.0 * (total - avail) / total;
      if (used < 0) used = 0;
      if (used > 100) used = 100;
      printf "%.1f\n", used;
    }
  ' /proc/meminfo
}

cpu_temp_c() {
  local z raw
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$z" ] || continue
    raw="$(cat "$z" 2>/dev/null || true)"
    [ -n "$raw" ] || continue
    awk -v t="$raw" '
      BEGIN {
        v = t + 0
        if (v > 1000) v = v / 1000.0
        if (v > 0 && v < 130) { printf "%.1f\n", v; exit 0 }
        exit 1
      }' && return 0
  done
  if command -v sensors >/dev/null 2>&1; then
    raw="$(sensors 2>/dev/null | grep -Eo '[+-]?[0-9]+(\.[0-9]+)?°C' | head -1 | tr -d '+°C' || true)"
    if [ -n "$raw" ]; then
      awk -v t="$raw" 'BEGIN{v=t+0; if(v>0 && v<130){printf "%.1f\n", v; exit 0} exit 1}' && return 0
    fi
  fi
  echo "0.0"
}

recent_requests_count() {
  python3 - "$VIDEO_REPROCESS_REQUEST_LOG_PATH" "$VIDEO_REPROCESS_REQUEST_WINDOW_SEC" <<'PY'
import os
import re
import sys
import subprocess
from datetime import datetime, timezone

path = sys.argv[1]
window = int(float(sys.argv[2])) if len(sys.argv) > 2 else 0
if window <= 0 or not path or not os.path.isfile(path):
    print(0)
    raise SystemExit(0)

try:
    out = subprocess.run(
        ["tail", "-n", "1200", path],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout or ""
except Exception:
    print(0)
    raise SystemExit(0)

pat = re.compile(r"\[(\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]")
now = datetime.now(timezone.utc)
count = 0
for line in out.splitlines():
    m = pat.search(line)
    if not m:
        continue
    try:
        dt = datetime.strptime(m.group(1), "%d/%b/%Y:%H:%M:%S %z").astimezone(timezone.utc)
    except ValueError:
        continue
    if (now - dt).total_seconds() <= window:
        count += 1

print(count)
PY
}

is_busy_now() {
  local cpu mem req temp
  cpu="$(cpu_busy_pct)"
  mem="$(mem_used_pct)"
  temp="$(cpu_temp_c)"
  req="$(recent_requests_count)"
  LAST_CPU="$cpu"
  LAST_MEM="$mem"
  LAST_TEMP="$temp"
  LAST_REQ="$req"
  awk -v cpu="$cpu" -v mem="$mem" -v temp="$temp" -v req="$req" -v cmax="$VIDEO_REPROCESS_MAX_CPU_PCT" -v mmax="$VIDEO_REPROCESS_MAX_MEM_PCT" -v tmax="$VIDEO_REPROCESS_MAX_TEMP_C" -v rmax="$VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW" '
    BEGIN {
      if (cpu > cmax || mem > mmax) exit 0;
      if (temp > tmax) exit 0;
      if (rmax > 0 && req > rmax) exit 0;
      exit 1;
    }'
}

run_plan() {
  log "INICIO: plan de reproceso"
  python3 "$MANAGER_BIN" plan \
    --cache-root "$VIDEO_REPROCESS_CACHE_ROOT" \
    --legacy-root "$VIDEO_REPROCESS_LEGACY_ROOT" \
    --upload-host-root "$VIDEO_REPROCESS_UPLOAD_ROOT" \
    --immich-local-root "$VIDEO_REPROCESS_IMMICH_ROOT" \
    --output-dir "$VIDEO_REPROCESS_OUTPUT_DIR" \
    --max-mb-min "$VIDEO_STREAM_MAX_MB_PER_MIN" \
    --local-max-mb "$VIDEO_REPROCESS_LOCAL_MAX_MB" \
    --local-max-duration-sec "$VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC" \
    --local-max-mb-min "$VIDEO_REPROCESS_LOCAL_MAX_MB_MIN" \
    >> "$LOG_FILE" 2>&1
}

parse_counter() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo 0; return; }
  awk -F= -v k="$key" '$1==k{print $2+0}' "$file" | tail -1
}

LIGHT_CONVERTED=0
LIGHT_FAILED=0
LIGHT_SKIPPED=0
HEAVY_CONVERTED=0
HEAVY_FAILED=0
HEAVY_SKIPPED=0
RUN_STATUS="SKIPPED"

run_batch() {
  local klass="$1"
  local input_csv="$2"
  local limit="$3"
  local tmp

  [ -f "$input_csv" ] || return 0
  tmp="$(mktemp)"
  if python3 "$MANAGER_BIN" run \
    --class "$klass" \
    --cache-root "$VIDEO_REPROCESS_CACHE_ROOT" \
    --legacy-root "$VIDEO_REPROCESS_LEGACY_ROOT" \
    --upload-host-root "$VIDEO_REPROCESS_UPLOAD_ROOT" \
    --immich-local-root "$VIDEO_REPROCESS_IMMICH_ROOT" \
    --output-dir "$VIDEO_REPROCESS_OUTPUT_DIR" \
    --input-csv "$input_csv" \
    --limit "$limit" \
    --attempts-db "$VIDEO_REPROCESS_ATTEMPTS_DB" \
    --manual-queue "$VIDEO_REPROCESS_MANUAL_QUEUE" \
    --max-attempts "$VIDEO_REPROCESS_MAX_ATTEMPTS" \
    --audio-bitrate-k "$VIDEO_REPROCESS_AUDIO_BITRATE_K" \
    --target-maxrate-k "$VIDEO_REPROCESS_TARGET_MAXRATE_K" \
    > "$tmp" 2>> "$LOG_FILE"; then
    RUN_STATUS="OK"
  else
    RUN_STATUS="FAIL"
  fi

  cat "$tmp" >> "$LOG_FILE"
  local converted failed skipped
  converted="$(parse_counter "$tmp" converted)"
  failed="$(parse_counter "$tmp" failed)"
  skipped="$(parse_counter "$tmp" skipped)"
  rm -f "$tmp"

  if [ "$klass" = "light" ]; then
    LIGHT_CONVERTED=$((LIGHT_CONVERTED + converted))
    LIGHT_FAILED=$((LIGHT_FAILED + failed))
    LIGHT_SKIPPED=$((LIGHT_SKIPPED + skipped))
  else
    HEAVY_CONVERTED=$((HEAVY_CONVERTED + converted))
    HEAVY_FAILED=$((HEAVY_FAILED + failed))
    HEAVY_SKIPPED=$((HEAVY_SKIPPED + skipped))
  fi

  log "BATCH $klass: converted=$converted failed=$failed skipped=$skipped"
}

if ! run_plan; then
  alert "❌ Falló la planeación de reproceso de video
No pude generar los insumos.
Dónde correr: TV Box
Insumo: automático (se genera solo en $VIDEO_REPROCESS_OUTPUT_DIR).
Qué correr:
1) python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir $VIDEO_REPROCESS_OUTPUT_DIR
2) /usr/local/bin/verify.sh"
  exit 1
fi

LIGHT_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/light-latest.csv"
HEAVY_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/heavy-latest.csv"
BROKEN_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/broken-latest.csv"

light_total="$(csv_count "$LIGHT_FILE")"
heavy_total="$(csv_count "$HEAVY_FILE")"
broken_total="$(csv_count "$BROKEN_FILE")"
log "Plan listo: light=$light_total heavy=$heavy_total broken=$broken_total"

MODE_LABEL="legacy"
if [ "$light_total" -le 0 ] && { [ "$VIDEO_REPROCESS_HEAVY_ENABLED" != "1" ] || [ "$heavy_total" -le 0 ]; }; then
  log "SKIP: no hay candidatos para reproceso"
  RUN_STATUS="SKIPPED"
elif [ "$VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED" != "1" ]; then
  log "MODO LEGACY: procesamiento tradicional (sin pausa por carga)"
  if [ "$light_total" -gt 0 ]; then
    run_batch "light" "$LIGHT_FILE" "$VIDEO_REPROCESS_LIGHT_LIMIT"
  fi
  if [ "$VIDEO_REPROCESS_HEAVY_ENABLED" = "1" ] && [ "$heavy_total" -gt 0 ]; then
    run_batch "heavy" "$HEAVY_FILE" "$VIDEO_REPROCESS_HEAVY_LIMIT"
  fi
else
  MODE_LABEL="dynamic_load"
  log "MODO CARGA DINAMICA: pausará/reanudará por CPU/RAM"
  start_epoch="$(date +%s)"
  loop_count=0
  while true; do
    loop_count=$((loop_count + 1))

    current_epoch="$(date +%s)"
    elapsed_min=$(( (current_epoch - start_epoch) / 60 ))
    if [ "$VIDEO_REPROCESS_MAX_RUNTIME_MIN" -gt 0 ] && [ "$elapsed_min" -ge "$VIDEO_REPROCESS_MAX_RUNTIME_MIN" ]; then
      log "STOP: max runtime alcanzado (${VIDEO_REPROCESS_MAX_RUNTIME_MIN} min)"
      alert_throttled \
        "video_reprocess:max_runtime" \
        1800 \
        "⏱️ Reproceso de videos pausado por tiempo máximo
Duración máxima alcanzada: ${VIDEO_REPROCESS_MAX_RUNTIME_MIN} min.
Acción: continuará en la siguiente ventana automática."
      break
    fi

    if ! run_plan; then
      RUN_STATUS="FAIL"
      break
    fi

    light_total="$(csv_count "$LIGHT_FILE")"
    heavy_total="$(csv_count "$HEAVY_FILE")"
    broken_total="$(csv_count "$BROKEN_FILE")"
    log "Loop $loop_count: light=$light_total heavy=$heavy_total broken=$broken_total"

    if [ "$light_total" -le 0 ] && { [ "$VIDEO_REPROCESS_HEAVY_ENABLED" != "1" ] || [ "$heavy_total" -le 0 ]; }; then
      break
    fi

    if is_busy_now; then
      log "BUSY: cpu=${LAST_CPU}% mem=${LAST_MEM}% temp=${LAST_TEMP}C req=${LAST_REQ}/${VIDEO_REPROCESS_REQUEST_WINDOW_SEC}s -> pausa"
      alert_throttled \
        "video_reprocess:busy" \
        "$VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC" \
        "⏸️ Reproceso de videos en pausa automática por carga
CPU: ${LAST_CPU}% (umbral ${VIDEO_REPROCESS_MAX_CPU_PCT}%)
RAM: ${LAST_MEM}% (umbral ${VIDEO_REPROCESS_MAX_MEM_PCT}%)
Temp CPU: ${LAST_TEMP}°C (umbral ${VIDEO_REPROCESS_MAX_TEMP_C}°C)
Requests: ${LAST_REQ}/${VIDEO_REPROCESS_REQUEST_WINDOW_SEC}s (umbral ${VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW})
Reanuda solo cuando baje la carga."
      sleep "$VIDEO_REPROCESS_IDLE_SLEEP_SEC"
      continue
    fi

    # Procesar lotes pequeños para poder pausar/reanudar rápido.
    if [ "$light_total" -gt 0 ]; then
      limit_light="$VIDEO_REPROCESS_BATCH_LIGHT"
      if [ "$VIDEO_REPROCESS_LIGHT_LIMIT" -gt 0 ] && [ "$VIDEO_REPROCESS_LIGHT_LIMIT" -lt "$limit_light" ]; then
        limit_light="$VIDEO_REPROCESS_LIGHT_LIMIT"
      fi
      run_batch "light" "$LIGHT_FILE" "$limit_light"
    fi

    if [ "$VIDEO_REPROCESS_HEAVY_ENABLED" = "1" ] && [ "$heavy_total" -gt 0 ]; then
      if is_busy_now; then
        log "BUSY antes de heavy: cpu=${LAST_CPU}% mem=${LAST_MEM}% temp=${LAST_TEMP}C req=${LAST_REQ}/${VIDEO_REPROCESS_REQUEST_WINDOW_SEC}s -> se difiere heavy"
      else
        limit_heavy="$VIDEO_REPROCESS_BATCH_HEAVY"
        if [ "$VIDEO_REPROCESS_HEAVY_LIMIT" -gt 0 ] && [ "$VIDEO_REPROCESS_HEAVY_LIMIT" -lt "$limit_heavy" ]; then
          limit_heavy="$VIDEO_REPROCESS_HEAVY_LIMIT"
        fi
        run_batch "heavy" "$HEAVY_FILE" "$limit_heavy"
      fi
    fi

    sleep 2
  done
fi

TOTAL_CONVERTED=$((LIGHT_CONVERTED + HEAVY_CONVERTED))
TOTAL_FAILED=$((LIGHT_FAILED + HEAVY_FAILED))
TOTAL_SKIPPED=$((LIGHT_SKIPPED + HEAVY_SKIPPED))
MANUAL_TOTAL="$(csv_count "$VIDEO_REPROCESS_MANUAL_QUEUE")"

if [ "$RUN_STATUS" = "SKIPPED" ] && [ "$TOTAL_CONVERTED" -gt 0 ]; then
  RUN_STATUS="OK"
fi

PENDING_TOTAL=$((light_total + heavy_total + MANUAL_TOTAL))
NOW_TS="$(date +%s)"
load_notify_state

if [ "$PENDING_TOTAL" -ge "$VIDEO_NOTIFY_BACKLOG_THRESHOLD" ]; then
  if [ "$NOTIFY_LAST_PENDING" -le 0 ] || [ "$PENDING_TOTAL" -lt "$NOTIFY_LAST_PENDING" ] || [ "$NOTIFY_STUCK_SINCE" -le 0 ]; then
    NOTIFY_STUCK_SINCE="$NOW_TS"
  fi
  STUCK_MIN=$(( (NOW_TS - NOTIFY_STUCK_SINCE) / 60 ))
  if [ "$STUCK_MIN" -ge "$VIDEO_NOTIFY_STUCK_MIN" ]; then
    alert_throttled \
      "video_reprocess:queue_stuck" \
      "$VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC" \
      "⚠️ Cola de video alta y sin bajar
Pendientes: $PENDING_TOTAL (ligeros $light_total, pesados $heavy_total, manuales $MANUAL_TOTAL).
Lleva ~${STUCK_MIN} min sin mejora.
Acción del NAS: sigue reintentando en segundo plano."
    NOTIFY_ALERT_OPEN=1
  fi
else
  if [ "$NOTIFY_ALERT_OPEN" -eq 1 ]; then
    alert "✅ Cola de video volvió a nivel normal
Pendientes actuales: $PENDING_TOTAL (umbral ${VIDEO_NOTIFY_BACKLOG_THRESHOLD})."
  fi
  NOTIFY_ALERT_OPEN=0
  NOTIFY_STUCK_SINCE="$NOW_TS"
fi

NOTIFY_LAST_PENDING="$PENDING_TOTAL"
save_notify_state "$NOW_TS"

cat > "$SUMMARY_FILE" <<EOF
VIDEO_REPROCESS_TS=$(date -Iseconds)
VIDEO_REPROCESS_LIGHT_TOTAL=$light_total
VIDEO_REPROCESS_HEAVY_TOTAL=$heavy_total
VIDEO_REPROCESS_BROKEN_TOTAL=$broken_total
VIDEO_REPROCESS_CONVERTED_LIGHT=$LIGHT_CONVERTED
VIDEO_REPROCESS_FAILED_LIGHT=$LIGHT_FAILED
VIDEO_REPROCESS_SKIPPED_LIGHT=$LIGHT_SKIPPED
VIDEO_REPROCESS_CONVERTED_HEAVY=$HEAVY_CONVERTED
VIDEO_REPROCESS_FAILED_HEAVY=$HEAVY_FAILED
VIDEO_REPROCESS_SKIPPED_HEAVY=$HEAVY_SKIPPED
VIDEO_REPROCESS_CONVERTED=$TOTAL_CONVERTED
VIDEO_REPROCESS_FAILED=$TOTAL_FAILED
VIDEO_REPROCESS_SKIPPED=$TOTAL_SKIPPED
VIDEO_REPROCESS_MANUAL_TOTAL=$MANUAL_TOTAL
VIDEO_REPROCESS_STATUS=$RUN_STATUS
EOF

if [ "$RUN_STATUS" = "FAIL" ]; then
  alert "⚠️ Reproceso de video con errores
Acción del NAS: el ciclo terminó incompleto.
Resultado: convertidos $TOTAL_CONVERTED, fallidos $TOTAL_FAILED, manuales $MANUAL_TOTAL.
Si quieres relanzar ahora: /usr/local/bin/video-reprocess-nightly.sh"
  exit 1
fi

if [ "$VIDEO_NOTIFY_VERBOSE" = "1" ] && [ "$TOTAL_CONVERTED" -gt 0 ]; then
  alert "🎬 Reproceso de video ejecutado
Convertidos: $TOTAL_CONVERTED (ligeros $LIGHT_CONVERTED, pesados $HEAVY_CONVERTED).
Pendientes actuales: $PENDING_TOTAL."
fi
exit 0
