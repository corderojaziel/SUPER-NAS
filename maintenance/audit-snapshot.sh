#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# audit-snapshot.sh — Bitácora periódica de auditoría operativa
#
# Objetivo:
# - Dejar evidencia histórica del comportamiento real del NAS
# - Ayudar a diagnóstico posterior (rendimiento, picos, cuellos de botella)
# - NO toca fotos/videos ni realiza depuración de contenido productivo
# ═══════════════════════════════════════════════════════════════════════════

set -u

POLICY_FILE="/etc/default/nas-video-policy"
HEALTH_DIR="/var/lib/nas-health"
LOG_FILE="${NAS_AUDIT_LOG_FILE:-/var/log/nas-audit.log}"
LOCK_FILE="${NAS_AUDIT_LOCK_FILE:-/var/lock/nas-audit.lock}"
MAX_LOG_MB="${NAS_AUDIT_LOG_MAX_MB:-300}"
MAX_LOG_FILES="${NAS_AUDIT_LOG_MAX_FILES:-6}"
CPU_SAMPLE_SEC="${NAS_AUDIT_CPU_SAMPLE_SEC:-1}"
REQUEST_LOG_PATH="${IML_REQUEST_LOG_PATH:-/var/log/nginx/access.log}"
REQUEST_WINDOW_SEC="${IML_REQUEST_WINDOW_SEC:-20}"

IML_DRAIN_BIN="${IML_DRAIN_BIN:-/usr/local/bin/iml-backlog-drain.py}"
IML_API_URL="${IML_API_URL:-http://127.0.0.1:2283/api}"
IML_SECRETS_FILE="${IML_SECRETS_FILE:-/etc/nas-secrets}"
IML_TARGETS="${IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
VIDEO_MANUAL_QUEUE="${VIDEO_REPROCESS_MANUAL_QUEUE:-/var/lib/nas-retry/video-reprocess-manual.tsv}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")" "$HEALTH_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

rotate_logs() {
  [ -f "$LOG_FILE" ] || return 0
  local size_bytes max_bytes
  size_bytes="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
  max_bytes=$((MAX_LOG_MB * 1024 * 1024))
  if [ "$size_bytes" -le "$max_bytes" ]; then
    return 0
  fi

  local rotated
  rotated="${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
  mv "$LOG_FILE" "$rotated" 2>/dev/null || return 0
  touch "$LOG_FILE"
  chmod 0644 "$LOG_FILE" 2>/dev/null || true

  ls -1t "${LOG_FILE}".20* 2>/dev/null | tail -n +"$((MAX_LOG_FILES + 1))" | while read -r old; do
    [ -n "$old" ] && rm -f "$old"
  done
}

cpu_snapshot() {
  awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat
}

cpu_busy_pct() {
  local s1 s2
  s1="$(cpu_snapshot)"
  sleep "$CPU_SAMPLE_SEC"
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
      if (d_total <= 0) { print "0.0"; exit; }
      busy = (100.0 * (d_total - d_idle)) / d_total;
      if (busy < 0) busy = 0;
      if (busy > 100) busy = 100;
      printf "%.1f", busy;
    }'
}

mem_used_pct() {
  awk '
    /^MemTotal:/ {total=$2}
    /^MemAvailable:/ {avail=$2}
    END {
      if (total <= 0 || avail < 0) { print "0.0"; exit; }
      used = 100.0 * (total - avail) / total;
      if (used < 0) used = 0;
      if (used > 100) used = 100;
      printf "%.1f", used;
    }' /proc/meminfo
}

cpu_temp_c() {
  local z raw max_t
  max_t=0
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$z" ] || continue
    raw="$(cat "$z" 2>/dev/null || true)"
    [ -n "$raw" ] || continue
    raw="$(awk -v t="$raw" 'BEGIN{v=t+0; if(v>1000){v=v/1000.0} printf "%.1f", v}')"
    awk -v cur="$raw" -v max="$max_t" 'BEGIN{exit !(cur > max && cur < 130)}'
    if [ $? -eq 0 ]; then
      max_t="$raw"
    fi
  done
  printf "%.1f" "$max_t"
}

recent_requests_count() {
  python3 - "$REQUEST_LOG_PATH" "$REQUEST_WINDOW_SEC" <<'PY'
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

iml_pending_count() {
  [ -f "$IML_DRAIN_BIN" ] || { echo 0; return; }
  timeout 20s python3 "$IML_DRAIN_BIN" \
    --api-url "$IML_API_URL" \
    --secrets-file "$IML_SECRETS_FILE" \
    --targets "$IML_TARGETS" \
    --print-pending-only 2>/dev/null || echo 0
}

mount_state() {
  if mountpoint -q "$1"; then
    echo "up"
  else
    echo "down"
  fi
}

df_metric() {
  local target="$1" col="$2"
  if [ ! -e "$target" ]; then
    echo "na"
    return
  fi
  df -P "$target" 2>/dev/null | awk -v c="$col" 'NR==2{print $c}'
}

strip_percent() {
  echo "$1" | tr -d '%'
}

count_manual_queue() {
  [ -f "$VIDEO_MANUAL_QUEUE" ] || { echo 0; return; }
  awk 'NR>1 && $0 !~ /^[[:space:]]*$/ {c++} END{print c+0}' "$VIDEO_MANUAL_QUEUE" 2>/dev/null
}

parse_env_value() {
  local file="$1" key="$2" def="$3"
  [ -f "$file" ] || { echo "$def"; return; }
  awk -F= -v k="$key" 'BEGIN{d=""} $1==k{d=$2} END{print d}' "$file" | tail -1 | awk -v def="$def" '{if($0=="") print def; else print $0}'
}

rotate_logs

TS="$(date -Iseconds)"
CPU_PCT="$(cpu_busy_pct)"
MEM_PCT="$(mem_used_pct)"
TEMP_C="$(cpu_temp_c)"
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
REQ_RECENT="$(recent_requests_count)"
IML_PENDING="$(iml_pending_count)"
case "$IML_PENDING" in
  ''|*[!0-9]*) IML_PENDING=0 ;;
esac
MANUAL_QUEUE="$(count_manual_queue)"
HTTP_ESTAB="$(ss -Htan 2>/dev/null | awk '$1=="ESTAB" && ($4 ~ /:80$/ || $4 ~ /:2283$/ || $4 ~ /:3003$/){c++} END{print c+0}')"

MOUNT_MAIN="$(mount_state /mnt/storage-main)"
MOUNT_BACKUP="$(mount_state /mnt/storage-backup)"
MOUNT_MERGED="$(mount_state /mnt/merged)"

EMMC_USED="$(strip_percent "$(df_metric /var/lib/immich 5)")"
EMMC_FREE_KB="$(df_metric /var/lib/immich 4)"
MAIN_USED="$(strip_percent "$(df_metric /mnt/storage-main 5)")"
MAIN_FREE_KB="$(df_metric /mnt/storage-main 4)"
BACKUP_USED="$(strip_percent "$(df_metric /mnt/storage-backup 5)")"
BACKUP_FREE_KB="$(df_metric /mnt/storage-backup 4)"

EMMC_FREE_GB="$(awk -v kb="${EMMC_FREE_KB:-0}" 'BEGIN{if(kb ~ /^[0-9]+$/){printf "%.1f", kb/1048576}else{printf "na"}}')"
MAIN_FREE_GB="$(awk -v kb="${MAIN_FREE_KB:-0}" 'BEGIN{if(kb ~ /^[0-9]+$/){printf "%.1f", kb/1048576}else{printf "na"}}')"
BACKUP_FREE_GB="$(awk -v kb="${BACKUP_FREE_KB:-0}" 'BEGIN{if(kb ~ /^[0-9]+$/){printf "%.1f", kb/1048576}else{printf "na"}}')"

VIDEO_SUMMARY_FILE="$HEALTH_DIR/video-reprocess-summary.env"
PLAYBACK_SUMMARY_FILE="$HEALTH_DIR/playback-audit-summary.env"
VIDEO_STATUS="$(parse_env_value "$VIDEO_SUMMARY_FILE" "VIDEO_REPROCESS_STATUS" "na")"
VIDEO_MANUAL_TOTAL_SUMMARY="$(parse_env_value "$VIDEO_SUMMARY_FILE" "VIDEO_REPROCESS_MANUAL_TOTAL" "0")"
PLAYBACK_BROKEN="$(parse_env_value "$PLAYBACK_SUMMARY_FILE" "PLAYBACK_AUDIT_BROKEN" "0")"
PLAYBACK_PLAYABLE="$(parse_env_value "$PLAYBACK_SUMMARY_FILE" "PLAYBACK_AUDIT_PLAYABLE" "0")"
PLAYBACK_TOTAL="$(parse_env_value "$PLAYBACK_SUMMARY_FILE" "PLAYBACK_AUDIT_TOTAL" "0")"

IMMICH_UP="$(docker ps --format '{{.Names}}' 2>/dev/null | awk '/^immich_/ {c++} END{print c+0}')"
IMMICH_ALL="$(docker ps -a --format '{{.Names}}' 2>/dev/null | awk '/^immich_/ {c++} END{print c+0}')"

echo "[$TS] cpu=${CPU_PCT}% mem=${MEM_PCT}% temp=${TEMP_C}C load=${LOAD1}/${LOAD5}/${LOAD15} req_${REQUEST_WINDOW_SEC}s=${REQ_RECENT} estab_http=${HTTP_ESTAB} iml_pending=${IML_PENDING} video_manual_queue=${MANUAL_QUEUE} mount_main=${MOUNT_MAIN} mount_backup=${MOUNT_BACKUP} mount_merged=${MOUNT_MERGED} emmc_used=${EMMC_USED}% emmc_free=${EMMC_FREE_GB}GB main_used=${MAIN_USED}% main_free=${MAIN_FREE_GB}GB backup_used=${BACKUP_USED}% backup_free=${BACKUP_FREE_GB}GB video_status=${VIDEO_STATUS} video_manual_summary=${VIDEO_MANUAL_TOTAL_SUMMARY} playback=${PLAYBACK_PLAYABLE}/${PLAYBACK_TOTAL} playback_broken=${PLAYBACK_BROKEN} immich_containers=${IMMICH_UP}/${IMMICH_ALL}" >> "$LOG_FILE"

exit 0
