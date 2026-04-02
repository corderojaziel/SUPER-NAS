#!/bin/bash
# Vigila playback (processing + rotos), reintenta reproceso y relanza resolver
# si detecta estancamiento.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
SECRETS_FILE="/etc/nas-secrets"
HEALTH_DIR="/var/lib/nas-health"
LOG_FILE="/var/log/playback-watchdog.log"
LOCK_FILE="/var/lock/playback-watchdog.lock"
SUMMARY_FILE="$HEALTH_DIR/playback-watchdog-summary.env"
AUDIT_BIN="${PLAYBACK_AUDIT_BIN:-/usr/local/bin/audit_video_playback.py}"
REPROCESS_BIN="${PLAYBACK_WATCHDOG_REPROCESS_BIN:-/usr/local/bin/video-reprocess-nightly.sh}"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"

PLAYBACK_AUDIT_IMMICH_API="${PLAYBACK_AUDIT_IMMICH_API:-http://127.0.0.1:2283}"
PLAYBACK_AUDIT_BASE="${PLAYBACK_AUDIT_BASE:-http://127.0.0.1}"
PLAYBACK_AUDIT_OUTPUT_DIR="${PLAYBACK_AUDIT_OUTPUT_DIR:-$HEALTH_DIR}"
PLAYBACK_AUDIT_WORKERS="${PLAYBACK_AUDIT_WORKERS:-24}"
PLAYBACK_AUDIT_TIMEOUT_SEC="${PLAYBACK_AUDIT_TIMEOUT_SEC:-20}"
PLAYBACK_AUDIT_SAMPLE_BYTES="${PLAYBACK_AUDIT_SAMPLE_BYTES:-256}"

PLAYBACK_WATCHDOG_ENABLED="${PLAYBACK_WATCHDOG_ENABLED:-1}"
PLAYBACK_WATCHDOG_MAX_CYCLES="${PLAYBACK_WATCHDOG_MAX_CYCLES:-4}"
PLAYBACK_WATCHDOG_INTERVAL_SEC="${PLAYBACK_WATCHDOG_INTERVAL_SEC:-180}"
PLAYBACK_WATCHDOG_STUCK_ROUNDS="${PLAYBACK_WATCHDOG_STUCK_ROUNDS:-2}"
PLAYBACK_WATCHDOG_REPROCESS_TIMEOUT_MIN="${PLAYBACK_WATCHDOG_REPROCESS_TIMEOUT_MIN:-240}"
PLAYBACK_WATCHDOG_NOTIFY="${PLAYBACK_WATCHDOG_NOTIFY:-0}"

IMMICH_ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-}"
IMMICH_ADMIN_PASSWORD="${IMMICH_ADMIN_PASSWORD:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"

mkdir -p "$HEALTH_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")" "$PLAYBACK_AUDIT_OUTPUT_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

alert() {
  [ "$PLAYBACK_WATCHDOG_NOTIFY" = "1" ] || return 0
  [ -x "$ALERT_BIN" ] || return 0
  NAS_ALERT_SUPPRESS=0 "$ALERT_BIN" "$1" || true
}

write_summary() {
  local status="${1:-SKIPPED}" total="${2:-0}" playable="${3:-0}" processing="${4:-0}" broken="${5:-0}" pending="${6:-0}"
  cat > "$SUMMARY_FILE" <<EOF
PLAYBACK_WATCHDOG_TS=$(date -Iseconds)
PLAYBACK_WATCHDOG_STATUS=$status
PLAYBACK_WATCHDOG_TOTAL=$total
PLAYBACK_WATCHDOG_PLAYABLE=$playable
PLAYBACK_WATCHDOG_PROCESSING=$processing
PLAYBACK_WATCHDOG_BROKEN=$broken
PLAYBACK_WATCHDOG_PENDING=$pending
EOF
}

if [ "$PLAYBACK_WATCHDOG_ENABLED" != "1" ]; then
  log "SKIP: PLAYBACK_WATCHDOG_ENABLED=$PLAYBACK_WATCHDOG_ENABLED"
  write_summary "SKIPPED" 0 0 0 0 0
  exit 0
fi

if [ ! -f "$AUDIT_BIN" ] || ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: auditor no disponible: $AUDIT_BIN"
  write_summary "FAIL" 0 0 0 0 0
  exit 1
fi

AUTH_ARGS=()
if [ -n "$IMMICH_API_KEY" ]; then
  AUTH_ARGS+=(--api-key "$IMMICH_API_KEY")
elif [ -n "$IMMICH_ADMIN_EMAIL" ] && [ -n "$IMMICH_ADMIN_PASSWORD" ]; then
  AUTH_ARGS+=(--email "$IMMICH_ADMIN_EMAIL" --password "$IMMICH_ADMIN_PASSWORD")
else
  log "SKIP: sin credenciales Immich para watchdog"
  write_summary "SKIPPED" 0 0 0 0 0
  exit 0
fi

audit_once() {
  local stdout_file="$1"
  if ! python3 "$AUDIT_BIN" \
    "${AUTH_ARGS[@]}" \
    --immich-api "$PLAYBACK_AUDIT_IMMICH_API" \
    --playback-base "$PLAYBACK_AUDIT_BASE" \
    --output-dir "$PLAYBACK_AUDIT_OUTPUT_DIR" \
    --workers "$PLAYBACK_AUDIT_WORKERS" \
    --timeout-sec "$PLAYBACK_AUDIT_TIMEOUT_SEC" \
    --sample-bytes "$PLAYBACK_AUDIT_SAMPLE_BYTES" \
    > "$stdout_file" 2>> "$LOG_FILE"; then
    return 1
  fi

  local csv
  csv=$(awk -F= '/^OUTPUT_CSV=/{print $2}' "$stdout_file" | tail -1)
  if [ -z "$csv" ] || [ ! -f "$csv" ]; then
    csv=$(ls -1t "$PLAYBACK_AUDIT_OUTPUT_DIR"/playback-audit-*.csv 2>/dev/null | head -1)
  fi
  [ -n "$csv" ] && [ -f "$csv" ] || return 1

  python3 - "$csv" <<'PY'
import csv,sys
csv_path=sys.argv[1]
counts={}
total=0
for row in csv.DictReader(open(csv_path,"r",encoding="utf-8",newline="")):
    total+=1
    cls=(row.get("class") or "").strip()
    counts[cls]=counts.get(cls,0)+1
print(f"TOTAL={total}")
print(f"PLAYABLE={counts.get('playable',0)}")
print(f"PROCESSING={counts.get('placeholder_processing',0)}")
broken = total - counts.get('playable',0) - counts.get('placeholder_processing',0)
print(f"BROKEN={max(broken,0)}")
PY
}

alert "🛰️ Watchdog playback iniciado
Voy a vigilar que no queden videos atascados en procesamiento.
Si detecto estancamiento, relanzo reproceso y el resolver."

prev_pending=-1
stuck_rounds=0
cycle=1
ok=0

while [ "$cycle" -le "$PLAYBACK_WATCHDOG_MAX_CYCLES" ]; do
  OUT="$(mktemp)"
  PARSE="$(audit_once "$OUT" || true)"
  rm -f "$OUT"

  total=$(printf '%s\n' "$PARSE" | awk -F= '/^TOTAL=/{print $2+0}')
  playable=$(printf '%s\n' "$PARSE" | awk -F= '/^PLAYABLE=/{print $2+0}')
  processing=$(printf '%s\n' "$PARSE" | awk -F= '/^PROCESSING=/{print $2+0}')
  broken=$(printf '%s\n' "$PARSE" | awk -F= '/^BROKEN=/{print $2+0}')
  pending=$((processing + broken))

  log "cycle=$cycle total=$total playable=$playable processing=$processing broken=$broken pending=$pending"

  if [ "$pending" -le 0 ]; then
    ok=1
    break
  fi

  if [ "$prev_pending" -ge 0 ] && [ "$pending" -ge "$prev_pending" ]; then
    stuck_rounds=$((stuck_rounds + 1))
  else
    stuck_rounds=0
  fi
  prev_pending="$pending"

  if [ "$stuck_rounds" -ge "$PLAYBACK_WATCHDOG_STUCK_ROUNDS" ]; then
    log "stuck_detected: restarting resolver"
    systemctl restart immich-video-playback-resolver 2>/dev/null || true
    sleep 3
    stuck_rounds=0
  fi

  if [ -x "$REPROCESS_BIN" ]; then
    log "running reprocess bin: $REPROCESS_BIN"
    timeout $((PLAYBACK_WATCHDOG_REPROCESS_TIMEOUT_MIN * 60)) "$REPROCESS_BIN" >> "$LOG_FILE" 2>&1 || true
  fi

  sleep "$PLAYBACK_WATCHDOG_INTERVAL_SEC"
  cycle=$((cycle + 1))
done

if [ "$ok" -eq 1 ]; then
  write_summary "OK" "${total:-0}" "${playable:-0}" "${processing:-0}" "${broken:-0}" 0
  alert "✅ Watchdog playback completado
Total revisados: ${total:-0}
Playables: ${playable:-0}
En procesamiento normal: ${processing:-0}
Rotos: ${broken:-0}
Resultado: quedó estable."
  exit 0
fi

write_summary "WARN" "${total:-0}" "${playable:-0}" "${processing:-0}" "${broken:-0}" $(( ${processing:-0} + ${broken:-0} ))
alert "⚠️ Watchdog playback terminó con pendientes
Total revisados: ${total:-0}
Playables: ${playable:-0}
En procesamiento normal: ${processing:-0}
Rotos: ${broken:-0}
Acción recomendada: relanzar /usr/local/bin/playback-watchdog.sh o revisar cola manual."
exit 1
