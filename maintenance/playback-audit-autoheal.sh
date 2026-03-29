#!/bin/bash
# Auditoria HTTP de playback + autocorreccion de videos rotos (perfil TV Box).

set -u

POLICY_FILE="/etc/default/nas-video-policy"
SECRETS_FILE="/etc/nas-secrets"
HEALTH_DIR="/var/lib/nas-health"
STATE_DIR="/var/lib/nas-retry"
LOG_FILE="/var/log/playback-audit-autoheal.log"
SUMMARY_FILE="$HEALTH_DIR/playback-audit-summary.env"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
AUDIT_BIN="${PLAYBACK_AUDIT_BIN:-/usr/local/bin/audit_video_playback.py}"
MANAGER_BIN="${VIDEO_REPROCESS_MANAGER_BIN:-/usr/local/bin/video-reprocess-manager.py}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
[ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"

PLAYBACK_AUDIT_ENABLED="${PLAYBACK_AUDIT_ENABLED:-1}"
PLAYBACK_AUDIT_AUTOHEAL_ENABLED="${PLAYBACK_AUDIT_AUTOHEAL_ENABLED:-1}"
PLAYBACK_AUDIT_IMMICH_API="${PLAYBACK_AUDIT_IMMICH_API:-http://127.0.0.1:2283}"
PLAYBACK_AUDIT_RESOLVER_BASE="${PLAYBACK_AUDIT_RESOLVER_BASE:-http://127.0.0.1:2284}"
PLAYBACK_AUDIT_BASE="${PLAYBACK_AUDIT_BASE:-http://127.0.0.1}"
PLAYBACK_AUDIT_OUTPUT_DIR="${PLAYBACK_AUDIT_OUTPUT_DIR:-$HEALTH_DIR}"
PLAYBACK_AUDIT_WORKERS="${PLAYBACK_AUDIT_WORKERS:-24}"
PLAYBACK_AUDIT_TIMEOUT_SEC="${PLAYBACK_AUDIT_TIMEOUT_SEC:-20}"
PLAYBACK_AUDIT_SAMPLE_BYTES="${PLAYBACK_AUDIT_SAMPLE_BYTES:-256}"
PLAYBACK_AUDIT_APPEND_TS="${PLAYBACK_AUDIT_APPEND_TS:-1}"
PLAYBACK_AUDIT_DEEP_FFPROBE="${PLAYBACK_AUDIT_DEEP_FFPROBE:-0}"
PLAYBACK_AUDIT_FFPROBE_WORKERS="${PLAYBACK_AUDIT_FFPROBE_WORKERS:-4}"
PLAYBACK_AUDIT_FFPROBE_TIMEOUT_SEC="${PLAYBACK_AUDIT_FFPROBE_TIMEOUT_SEC:-20}"
PLAYBACK_AUDIT_FFPROBE_SAMPLE_SEC="${PLAYBACK_AUDIT_FFPROBE_SAMPLE_SEC:-2}"
PLAYBACK_AUDIT_FFPROBE_RETRIES="${PLAYBACK_AUDIT_FFPROBE_RETRIES:-2}"
PLAYBACK_AUDIT_FFPROBE_RETRY_SLEEP_SEC="${PLAYBACK_AUDIT_FFPROBE_RETRY_SLEEP_SEC:-1.5}"
PLAYBACK_AUDIT_AUTOHEAL_CLASSES="${PLAYBACK_AUDIT_AUTOHEAL_CLASSES:-not_found http_error unexpected_content placeholder_missing placeholder_damaged placeholder_error}"
PLAYBACK_AUDIT_AUTOHEAL_LIMIT="${PLAYBACK_AUDIT_AUTOHEAL_LIMIT:-200}"
PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS="${PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS:-3}"
PLAYBACK_AUDIT_TRIGGER_WATCHDOG_ON_PROCESSING="${PLAYBACK_AUDIT_TRIGGER_WATCHDOG_ON_PROCESSING:-1}"
PLAYBACK_WATCHDOG_BIN="${PLAYBACK_WATCHDOG_BIN:-/usr/local/bin/playback-watchdog.sh}"

VIDEO_REPROCESS_OUTPUT_DIR="${VIDEO_REPROCESS_OUTPUT_DIR:-$HEALTH_DIR/reprocess}"
VIDEO_REPROCESS_CACHE_ROOT="${VIDEO_REPROCESS_CACHE_ROOT:-/var/lib/immich/cache}"
VIDEO_REPROCESS_LEGACY_ROOT="${VIDEO_REPROCESS_LEGACY_ROOT:-/mnt/storage-main/cache}"
VIDEO_REPROCESS_UPLOAD_ROOT="${VIDEO_REPROCESS_UPLOAD_ROOT:-/mnt/storage-main/photos}"
VIDEO_REPROCESS_IMMICH_ROOT="${VIDEO_REPROCESS_IMMICH_ROOT:-/var/lib/immich}"
VIDEO_STREAM_MAX_MB_PER_MIN="${VIDEO_STREAM_MAX_MB_PER_MIN:-40}"
VIDEO_REPROCESS_LOCAL_MAX_MB="${VIDEO_REPROCESS_LOCAL_MAX_MB:-220}"
VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC="${VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC:-150}"
VIDEO_REPROCESS_LOCAL_MAX_MB_MIN="${VIDEO_REPROCESS_LOCAL_MAX_MB_MIN:-120}"
VIDEO_REPROCESS_ATTEMPTS_DB="${VIDEO_REPROCESS_ATTEMPTS_DB:-$STATE_DIR/video-reprocess-light.attempts.tsv}"
VIDEO_REPROCESS_MANUAL_QUEUE="${VIDEO_REPROCESS_MANUAL_QUEUE:-$STATE_DIR/video-reprocess-manual.tsv}"
VIDEO_REPROCESS_AUDIO_BITRATE_K="${VIDEO_REPROCESS_AUDIO_BITRATE_K:-128}"
VIDEO_REPROCESS_TARGET_MAXRATE_K="${VIDEO_REPROCESS_TARGET_MAXRATE_K:-5200}"

IMMICH_ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-}"
IMMICH_ADMIN_PASSWORD="${IMMICH_ADMIN_PASSWORD:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"

mkdir -p "$HEALTH_DIR" "$STATE_DIR" "$PLAYBACK_AUDIT_OUTPUT_DIR" "$VIDEO_REPROCESS_OUTPUT_DIR" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

alert() {
  [ -x "$ALERT_BIN" ] || return 0
  NAS_ALERT_SUPPRESS=0 "$ALERT_BIN" "$1" || true
}

write_summary() {
  local status="$1" total="$2" playable="$3" processing="$4" broken="$5" converted="$6" failed="$7" skipped="$8" candidates="$9"
  cat > "$SUMMARY_FILE" <<EOF
PLAYBACK_AUDIT_TS=$(date -Iseconds)
PLAYBACK_AUDIT_STATUS=$status
PLAYBACK_AUDIT_TOTAL=$total
PLAYBACK_AUDIT_PLAYABLE=$playable
PLAYBACK_AUDIT_PROCESSING=$processing
PLAYBACK_AUDIT_BROKEN=$broken
PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=$candidates
PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=$converted
PLAYBACK_AUDIT_AUTOHEAL_FAILED=$failed
PLAYBACK_AUDIT_AUTOHEAL_SKIPPED=$skipped
EOF
}

if [ "$PLAYBACK_AUDIT_ENABLED" != "1" ]; then
  log "SKIP: PLAYBACK_AUDIT_ENABLED=$PLAYBACK_AUDIT_ENABLED"
  write_summary "SKIPPED" 0 0 0 0 0 0 0 0
  exit 0
fi

if [ ! -f "$AUDIT_BIN" ]; then
  log "ERROR: no existe auditor: $AUDIT_BIN"
  alert "⚠️ No pude ejecutar la auditoría automática de playback
No encontré: $AUDIT_BIN
Qué correr (TV Box):
Insumo: no aplica.
1) ls -lah /usr/local/bin/audit_video_playback.py
2) /usr/local/bin/verify.sh"
  write_summary "FAIL" 0 0 0 0 0 0 0 0
  exit 1
fi

if [ ! -f "$MANAGER_BIN" ]; then
  log "ERROR: no existe manager: $MANAGER_BIN"
  alert "⚠️ No pude autocorregir videos rotos
No encontré: $MANAGER_BIN
Qué correr (TV Box):
Insumo: no aplica.
1) ls -lah /usr/local/bin/video-reprocess-manager.py
2) /usr/local/bin/verify.sh"
  write_summary "FAIL" 0 0 0 0 0 0 0 0
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 no disponible"
  write_summary "FAIL" 0 0 0 0 0 0 0 0
  exit 1
fi

AUDIT_STDOUT="$(mktemp)"
BROKEN_IDS_FILE="$(mktemp)"
AUDIT_SUMMARY_JSON="$PLAYBACK_AUDIT_OUTPUT_DIR/playback-audit-summary-latest.json"
AUTOHEAL_CSV="$VIDEO_REPROCESS_OUTPUT_DIR/playback-autoheal-light.csv"
PLAN_STDOUT="$(mktemp)"
RUN_STDOUT="$(mktemp)"
trap 'rm -f "$AUDIT_STDOUT" "$BROKEN_IDS_FILE" "$PLAN_STDOUT" "$RUN_STDOUT"' EXIT

AUTH_ARGS=()
if [ -n "$IMMICH_API_KEY" ]; then
  AUTH_ARGS+=(--api-key "$IMMICH_API_KEY")
elif [ -n "$IMMICH_ADMIN_EMAIL" ] && [ -n "$IMMICH_ADMIN_PASSWORD" ]; then
  AUTH_ARGS+=(--email "$IMMICH_ADMIN_EMAIL" --password "$IMMICH_ADMIN_PASSWORD")
else
  alert "⚠️ Auditoría de playback sin credenciales de Immich
No pude autenticar para revisar playback de videos.
Dónde configurar:
- /etc/nas-secrets
Campos requeridos:
- IMMICH_API_KEY (recomendado) o IMMICH_ADMIN_EMAIL + IMMICH_ADMIN_PASSWORD"
  write_summary "SKIPPED" 0 0 0 0 0 0 0 0
  exit 0
fi

log "INICIO: auditoría HTTP playback"
AUDIT_ARGS=(
  --immich-api "$PLAYBACK_AUDIT_IMMICH_API"
  --resolver-base "$PLAYBACK_AUDIT_RESOLVER_BASE"
  --playback-base "$PLAYBACK_AUDIT_BASE"
  --output-dir "$PLAYBACK_AUDIT_OUTPUT_DIR"
  --workers "$PLAYBACK_AUDIT_WORKERS"
  --timeout-sec "$PLAYBACK_AUDIT_TIMEOUT_SEC"
  --sample-bytes "$PLAYBACK_AUDIT_SAMPLE_BYTES"
  --ffprobe-workers "$PLAYBACK_AUDIT_FFPROBE_WORKERS"
  --ffprobe-timeout-sec "$PLAYBACK_AUDIT_FFPROBE_TIMEOUT_SEC"
  --ffprobe-sample-sec "$PLAYBACK_AUDIT_FFPROBE_SAMPLE_SEC"
  --ffprobe-retries "$PLAYBACK_AUDIT_FFPROBE_RETRIES"
  --ffprobe-retry-sleep-sec "$PLAYBACK_AUDIT_FFPROBE_RETRY_SLEEP_SEC"
)
if [ "$PLAYBACK_AUDIT_APPEND_TS" = "1" ]; then
  AUDIT_ARGS+=(--append-ts)
fi
if [ "$PLAYBACK_AUDIT_DEEP_FFPROBE" = "1" ]; then
  AUDIT_ARGS+=(--deep-ffprobe)
fi

if ! python3 "$AUDIT_BIN" \
  "${AUTH_ARGS[@]}" \
  "${AUDIT_ARGS[@]}" \
  >> "$AUDIT_STDOUT" 2>> "$LOG_FILE"; then
 alert "⚠️ Falló la auditoría de playback
No pude completar el barrido HTTP de videos.
Qué correr (TV Box):
Insumo: no aplica.
1) python3 /usr/local/bin/audit_video_playback.py --immich-api $PLAYBACK_AUDIT_IMMICH_API --resolver-base $PLAYBACK_AUDIT_RESOLVER_BASE --playback-base $PLAYBACK_AUDIT_BASE --output-dir $PLAYBACK_AUDIT_OUTPUT_DIR --workers $PLAYBACK_AUDIT_WORKERS"
  write_summary "FAIL" 0 0 0 0 0 0 0 0
  exit 1
fi

cat "$AUDIT_STDOUT" >> "$LOG_FILE"

AUDIT_CSV=$(awk -F= '/^OUTPUT_CSV=/{print $2}' "$AUDIT_STDOUT" | tail -1)
if [ -z "$AUDIT_CSV" ] || [ ! -f "$AUDIT_CSV" ]; then
  AUDIT_CSV=$(ls -1t "$PLAYBACK_AUDIT_OUTPUT_DIR"/playback-audit-*.csv 2>/dev/null | head -1)
fi

if [ -z "$AUDIT_CSV" ] || [ ! -f "$AUDIT_CSV" ]; then
  log "ERROR: no se encontró CSV de auditoría"
  write_summary "FAIL" 0 0 0 0 0 0 0 0
  exit 1
fi

AUDIT_PARSE_OUT="$(python3 - "$AUDIT_CSV" "$BROKEN_IDS_FILE" "$AUDIT_SUMMARY_JSON" "$PLAYBACK_AUDIT_AUTOHEAL_CLASSES" <<'PY'
import csv
import json
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
broken_ids_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
classes = {x.strip() for x in sys.argv[4].split() if x.strip()}

counts = {}
broken_ids = set()
total = 0
for row in csv.DictReader(csv_path.open("r", encoding="utf-8", newline="")):
    total += 1
    cls = (row.get("class") or "").strip()
    counts[cls] = counts.get(cls, 0) + 1
    aid = (row.get("asset_id") or "").strip()
    if cls in classes and aid:
        broken_ids.add(aid)

broken_sorted = sorted(broken_ids)
broken_ids_path.write_text("\n".join(broken_sorted) + ("\n" if broken_sorted else ""), encoding="utf-8")

summary = {
    "generated_at": __import__("time").strftime("%Y-%m-%d %H:%M:%S"),
    "csv": str(csv_path),
    "total": total,
    "counts": counts,
    "broken_classes": sorted(classes),
    "broken_total": len(broken_sorted),
}
summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")

playable = counts.get("playable", 0)
processing = counts.get("placeholder_processing", 0)
print(f"TOTAL={total}")
print(f"PLAYABLE={playable}")
print(f"PROCESSING={processing}")
print(f"BROKEN={len(broken_sorted)}")
PY
)"
echo "$AUDIT_PARSE_OUT" >> "$LOG_FILE"

total=$(printf '%s\n' "$AUDIT_PARSE_OUT" | awk -F= '/^TOTAL=/{print $2+0}')
playable=$(printf '%s\n' "$AUDIT_PARSE_OUT" | awk -F= '/^PLAYABLE=/{print $2+0}')
processing=$(printf '%s\n' "$AUDIT_PARSE_OUT" | awk -F= '/^PROCESSING=/{print $2+0}')
broken=$(printf '%s\n' "$AUDIT_PARSE_OUT" | awk -F= '/^BROKEN=/{print $2+0}')

BROKEN_META="$(python3 - "$AUDIT_CSV" <<'PY'
import csv
import sys

classes = {}
with open(sys.argv[1], "r", encoding="utf-8", newline="") as fh:
    for row in csv.DictReader(fh):
        cls = (row.get("class") or "").strip()
        if cls and cls != "playable":
            classes[cls] = classes.get(cls, 0) + 1

keys = sorted(classes.keys())
print("BROKEN_CLASSES=" + ",".join(keys))
print("BROKEN_ONLY_DAMAGED=" + ("1" if keys == ["placeholder_damaged"] else "0"))
print("BROKEN_ONLY_PLACEHOLDER=" + ("1" if keys and all(k.startswith("placeholder_") for k in keys) else "0"))
PY
)"
echo "$BROKEN_META" >> "$LOG_FILE"
broken_classes=$(printf '%s\n' "$BROKEN_META" | awk -F= '/^BROKEN_CLASSES=/{print $2}' | tail -1)
broken_only_damaged=$(printf '%s\n' "$BROKEN_META" | awk -F= '/^BROKEN_ONLY_DAMAGED=/{print $2+0}' | tail -1)
broken_only_placeholder=$(printf '%s\n' "$BROKEN_META" | awk -F= '/^BROKEN_ONLY_PLACEHOLDER=/{print $2+0}' | tail -1)
[ -n "$broken_only_damaged" ] || broken_only_damaged=0
[ -n "$broken_only_placeholder" ] || broken_only_placeholder=0

converted=0
failed=0
skipped=0
candidates=0

if [ "$broken" -le 0 ]; then
  action_msg="no hizo falta autocorrección."
  if [ "$processing" -gt 0 ] && [ "$PLAYBACK_AUDIT_TRIGGER_WATCHDOG_ON_PROCESSING" = "1" ] && [ -x "$PLAYBACK_WATCHDOG_BIN" ]; then
    log "processing_detected=$processing -> lanzando watchdog"
    if timeout 900 "$PLAYBACK_WATCHDOG_BIN" >> "$LOG_FILE" 2>&1; then
      action_msg="se lanzó watchdog de playback para vigilar/reintentar pendientes."
    else
      action_msg="intenté lanzar watchdog de playback, revisar /var/log/playback-watchdog.log."
    fi
  fi

  alert "✅ Auditoría playback completada
Total revisados: $total
Playables: $playable
En procesamiento normal: $processing
Rotos detectados: 0
Acción: $action_msg"
  write_summary "OK" "$total" "$playable" "$processing" 0 0 0 0 0
  exit 0
fi

if [ "$PLAYBACK_AUDIT_AUTOHEAL_ENABLED" != "1" ]; then
  alert "⚠️ Auditoría playback detectó videos rotos
Total revisados: $total
Rotos detectados: $broken
Autocorrección: desactivada por política (PLAYBACK_AUDIT_AUTOHEAL_ENABLED=$PLAYBACK_AUDIT_AUTOHEAL_ENABLED)."
  write_summary "WARN" "$total" "$playable" "$processing" "$broken" 0 0 0 0
  exit 0
fi

log "INICIO: plan de reproceso para autocorrección"
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
  >> "$PLAN_STDOUT" 2>> "$LOG_FILE"; then
  alert "⚠️ Detecté videos rotos pero falló el plan de autocorrección
Rotos detectados: $broken
Qué correr (TV Box):
Insumo: automático.
1) python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir $VIDEO_REPROCESS_OUTPUT_DIR"
  write_summary "FAIL" "$total" "$playable" "$processing" "$broken" 0 0 0 0
  exit 1
fi

LIGHT_FILE="$VIDEO_REPROCESS_OUTPUT_DIR/light-latest.csv"
if [ ! -f "$LIGHT_FILE" ]; then
  alert "⚠️ Detecté videos rotos pero no encontré candidatos ligeros
Rotos detectados: $broken
Archivo esperado: $LIGHT_FILE
Acción: revisar cola pesada/manual."
  write_summary "WARN" "$total" "$playable" "$processing" "$broken" 0 0 0 0
  exit 0
fi

FILTER_OUT="$(python3 - "$BROKEN_IDS_FILE" "$LIGHT_FILE" "$AUTOHEAL_CSV" <<'PY'
import csv
import sys
from pathlib import Path

broken_file = Path(sys.argv[1])
light_csv = Path(sys.argv[2])
out_csv = Path(sys.argv[3])
broken = {line.strip() for line in broken_file.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()}

rows = []
with light_csv.open("r", encoding="utf-8", newline="") as fh:
    reader = csv.DictReader(fh)
    headers = reader.fieldnames or []
    for row in reader:
        aid = (row.get("asset_id") or "").strip()
        if aid and aid in broken:
            rows.append(row)

out_csv.parent.mkdir(parents=True, exist_ok=True)
with out_csv.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=headers)
    writer.writeheader()
    writer.writerows(rows)

print(f"CANDIDATES={len(rows)}")
PY
)"
echo "$FILTER_OUT" >> "$LOG_FILE"
candidates=$(printf '%s\n' "$FILTER_OUT" | awk -F= '/^CANDIDATES=/{print $2+0}')

if [ "$candidates" -le 0 ]; then
  if [ "$broken_only_placeholder" -eq 1 ]; then
    watchdog_msg="no fue necesario relanzar watchdog."
    if [ -x "$PLAYBACK_WATCHDOG_BIN" ]; then
      log "broken_placeholder_detected -> lanzando watchdog"
      if timeout 900 "$PLAYBACK_WATCHDOG_BIN" >> "$LOG_FILE" 2>&1; then
        watchdog_msg="relancé watchdog para confirmar recuperación automática."
      else
        watchdog_msg="intenté relanzar watchdog; revisar /var/log/playback-watchdog.log."
      fi
    fi

    detail_line="Detalle: placeholders detectados (${broken_classes:-placeholder})."
    [ "$broken_only_damaged" -eq 1 ] && detail_line="Detalle: placeholders de dañado (pueden ser transitorios bajo carga)."

    alert "⚠️ Playback con estado temporal
Total revisados: $total
Rotos detectados: $broken
$detail_line
Acción del NAS: reintento automático en siguientes ciclos.
Qué hacer ahora: no corras nada manual por el momento.
Seguimiento: $watchdog_msg"
  else
    alert "⚠️ Auditoría playback: encontré rotos sin autocorrección local
Total revisados: $total
Rotos detectados: $broken
Clases detectadas: ${broken_classes:-desconocido}
Candidatos TV Box: 0
Acción: quedan para cola pesada/manual (PC o revisión de fuente)."
  fi
  write_summary "WARN" "$total" "$playable" "$processing" "$broken" 0 0 0 0
  exit 0
fi

log "INICIO: autocorrección de candidatos ligeros ($candidates)"
run_rc=0
if python3 "$MANAGER_BIN" run \
  --class light \
  --cache-root "$VIDEO_REPROCESS_CACHE_ROOT" \
  --legacy-root "$VIDEO_REPROCESS_LEGACY_ROOT" \
  --upload-host-root "$VIDEO_REPROCESS_UPLOAD_ROOT" \
  --immich-local-root "$VIDEO_REPROCESS_IMMICH_ROOT" \
  --output-dir "$VIDEO_REPROCESS_OUTPUT_DIR" \
  --input-csv "$AUTOHEAL_CSV" \
  --limit "$PLAYBACK_AUDIT_AUTOHEAL_LIMIT" \
  --attempts-db "$VIDEO_REPROCESS_ATTEMPTS_DB" \
  --manual-queue "$VIDEO_REPROCESS_MANUAL_QUEUE" \
  --max-attempts "$PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS" \
  --audio-bitrate-k "$VIDEO_REPROCESS_AUDIO_BITRATE_K" \
  --target-maxrate-k "$VIDEO_REPROCESS_TARGET_MAXRATE_K" \
  --allow-remux-copy 0 \
  >> "$RUN_STDOUT" 2>> "$LOG_FILE"; then
  run_rc=0
else
  run_rc=$?
  log "WARN: run manager regresó error en autoheal"
fi

cat "$RUN_STDOUT" >> "$LOG_FILE"
converted=$(awk -F= '/^converted=/{print $2+0}' "$RUN_STDOUT" | tail -1)
failed=$(awk -F= '/^failed=/{print $2+0}' "$RUN_STDOUT" | tail -1)
skipped=$(awk -F= '/^skipped=/{print $2+0}' "$RUN_STDOUT" | tail -1)
[ -n "$converted" ] || converted=0
[ -n "$failed" ] || failed=0
[ -n "$skipped" ] || skipped=0

if [ "$run_rc" -ne 0 ]; then
  status="FAIL"
elif [ "$failed" -gt 0 ]; then
  status="WARN"
else
  status="OK"
fi

alert "🎬 Auditoría playback + autocorrección
Total revisados: $total
Playables: $playable
En procesamiento normal: $processing
Rotos detectados: $broken
Candidatos autocorrección TV Box: $candidates
Convertidos: $converted
Fallidos: $failed
Omitidos: $skipped
Insumo: automático.
Rutas:
- Auditoría: $AUDIT_CSV
- Cola reproceso: $VIDEO_REPROCESS_OUTPUT_DIR"

write_summary "$status" "$total" "$playable" "$processing" "$broken" "$converted" "$failed" "$skipped" "$candidates"
exit 0
