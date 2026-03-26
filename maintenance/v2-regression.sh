#!/bin/bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/mnt/c/Users/jazie/OneDrive/Escritorio/proyecto}"
CONFIG_OUT="${CONFIG_OUT:-$REPO_ROOT/config/nas.wsl.generated.conf}"
API_BASE="${API_BASE:-http://127.0.0.1:2283}"
WEB_BASE="${WEB_BASE:-http://127.0.0.1}"
LIGHT_VIDEO="${LIGHT_VIDEO:-$REPO_ROOT/ligero.mp4}"
HEAVY_VIDEO="${HEAVY_VIDEO:-$REPO_ROOT/pesado.mp4}"
EMAIL="${IMMICH_EMAIL:-jazielcordero@live.com}"
PASSWORD="${IMMICH_PASSWORD:-S1santan}"
NAME="${IMMICH_NAME:-Jazz Test}"
RUN_INSTALL="${RUN_INSTALL:-0}"
RUN_ALERT_MATRIX="${RUN_ALERT_MATRIX:-1}"
REAL_TELEGRAM_TOKEN="${REAL_TELEGRAM_TOKEN:-7959933820:AAHFsPRji6Wocyvikh81qUButmCL5Fys0oQ}"
REAL_TELEGRAM_CHAT_ID="${REAL_TELEGRAM_CHAT_ID:-976424113}"
TMP_DIR="${TMP_DIR:-/tmp/nas-v2-regression}"
RUN_ID="${RUN_ID:-$(date +%s)}"

mkdir -p "$TMP_DIR"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILURES=""

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf 'WARN %s\n' "$1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$1" >&2
  if [ -n "$FAILURES" ]; then
    FAILURES="${FAILURES}\n- $1"
  else
    FAILURES="- $1"
  fi
}

telegram_direct() {
  local text="$1"
  curl -fsS \
    --connect-timeout 10 \
    --max-time 20 \
    -X POST "https://api.telegram.org/bot${REAL_TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${REAL_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    telegram_direct "⚠️ Prueba v2.0 interrumpida\nPASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}\nUltimo estado:\n${FAILURES:-- La ejecución terminó con un error antes del cierre.}" || true
  fi
}

trap on_exit EXIT

restore_test_telegram() {
  cat > /etc/nas-secrets <<EOF
TELEGRAM_TOKEN="${REAL_TELEGRAM_TOKEN}"
TELEGRAM_CHAT_ID="${REAL_TELEGRAM_CHAT_ID}"
EOF
  chmod 600 /etc/nas-secrets
}

sanitize_lab_docker_state() {
  systemctl stop docker docker.socket containerd >/dev/null 2>&1 || true
  pkill -f dockerd >/dev/null 2>&1 || true
  pkill -f containerd >/dev/null 2>&1 || true
  rm -f /var/run/docker.pid /var/run/docker.sock
  systemctl reset-failed docker docker.socket containerd >/dev/null 2>&1 || true
}

reset_runtime_tasks() {
  pkill -9 -f '/usr/local/bin/night-run.sh' >/dev/null 2>&1 || true
  pkill -9 -f '/usr/local/bin/video-optimize.sh' >/dev/null 2>&1 || true
  pkill -9 -f '/usr/local/bin/backup.sh' >/dev/null 2>&1 || true
  pkill -9 -f 'ffmpeg -y -i /mnt/storage-main/photos/' >/dev/null 2>&1 || true
  rm -f /var/lock/night-run.lock /var/lock/video-optimize.lock
}

wait_http() {
  local url="$1" attempt
  for attempt in $(seq 1 90); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

json_value() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
path = sys.argv[2].split(".")
obj = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for part in path:
    if isinstance(obj, dict):
        obj = obj.get(part)
    else:
        obj = None
        break
if obj is None:
    print("")
elif isinstance(obj, bool):
    print("true" if obj else "false")
else:
    print(obj)
PY
}

parse_upload_id() {
  python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], "r", encoding="utf-8"))

def find_id(obj):
    if isinstance(obj, dict):
        for key in ("id", "assetId"):
            val = obj.get(key)
            if isinstance(val, str) and val:
                return val
        for val in obj.values():
            found = find_id(val)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = find_id(item)
            if found:
                return found
    return ""

print(find_id(data))
PY
}

api_get() {
  local path="$1" out="$2"
  curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" "${API_BASE}${path}" -o "$out"
}

api_post_json() {
  local path="$1" body="$2" out="$3"
  curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    -X POST "${API_BASE}${path}" -d "$body" -o "$out"
}

ensure_admin_and_login() {
  local signup_json="$TMP_DIR/admin-signup.json"
  local login_json="$TMP_DIR/login.json"

  curl -sS -o "$signup_json" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -X POST "${API_BASE}/api/auth/admin-sign-up" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"name\":\"${NAME}\"}" > "$TMP_DIR/admin-signup.code" || true

  ACCESS_TOKEN="$(curl -fsS -H "Content-Type: application/json" \
    -X POST "${API_BASE}/api/auth/login" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" -o "$login_json" && \
    json_value "$login_json" "accessToken")"

  [ -n "$ACCESS_TOKEN" ] || { fail "No pude iniciar sesión en Immich"; return 1; }
  pass "Login Immich OK"
}

upload_video() {
  local file="$1"
  local tag="$2"
  local out="$TMP_DIR/upload-${tag}.json"
  local created modified device_asset_id
  created="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  modified="$created"
  device_asset_id="codex-${tag}-$(date +%s%N)"

  curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" \
    -F "assetData=@${file};type=video/mp4" \
    -F "deviceAssetId=${device_asset_id}" \
    -F "deviceId=codex-v2" \
    -F "fileCreatedAt=${created}" \
    -F "fileModifiedAt=${modified}" \
    -F "isFavorite=false" \
    -F "isArchived=false" \
    "${API_BASE}/api/assets" -o "$out"

  parse_upload_id "$out"
}

wait_asset_ready() {
  local asset_id="$1" out="$2" attempt
  for attempt in $(seq 1 60); do
    if api_get "/api/assets/${asset_id}" "$out" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

playback_source() {
  local asset_id="$1"
  local header_file="$TMP_DIR/playback-${asset_id}.headers"
  curl -sS -D "$header_file" -o /dev/null \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${WEB_BASE}/api/assets/${asset_id}/video/playback" >/dev/null 2>&1 || true
  awk -F': ' '
    BEGIN{IGNORECASE=1}
    /^X-Video-Source:/{gsub("\r","",$2); source=$2}
    /^HTTP\//{status=$2}
    END{
      if (source != "") print source
      else if (status != "") print "http-" status
      else print ""
    }
  ' "$header_file"
}

playback_length() {
  local asset_id="$1"
  local header_file="$TMP_DIR/playback-${asset_id}.headers"
  awk -F': ' 'BEGIN{IGNORECASE=1} /^Content-Length:/{gsub("\r","",$2); print $2; exit}' "$header_file"
}

placeholder_size_for_asset() {
  local asset_json="$1"
  python3 - "$asset_json" <<'PY'
import json, os, sys
obj = json.load(open(sys.argv[1], "r", encoding="utf-8"))
land = "/var/lib/immich/static/video-processing.mp4"
portrait = "/var/lib/immich/static/video-processing-portrait.mp4"
width = int(obj.get("width") or 0)
height = int(obj.get("height") or 0)
target = portrait if width > 0 and height > 0 and height >= width else land
print(os.path.getsize(target) if os.path.exists(target) else 0)
PY
}

cache_path_from_original() {
  python3 - "$1" <<'PY'
import os, sys
prefix = "/usr/src/app/upload/"
orig = sys.argv[1]
rel = orig[len(prefix):].lstrip("/")
print(os.path.join("/var/lib/immich/cache", os.path.splitext(rel)[0] + ".mp4"))
PY
}

host_path_from_original() {
  python3 - "$1" <<'PY'
import os, sys
prefix = "/usr/src/app/upload/"
orig = sys.argv[1]
if not orig.startswith(prefix):
    print("")
    raise SystemExit
rel = orig[len(prefix):].lstrip("/")
print(os.path.join("/mnt/storage-main/photos", rel))
PY
}

delete_asset() {
  local asset_id="$1"
  local code
  local out="$TMP_DIR/delete-${asset_id}.json"
  code=$(curl -sS -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X DELETE "${API_BASE}/api/assets" \
    -d "{\"ids\":[\"${asset_id}\"],\"force\":true}" || true)
  if [[ "$code" =~ ^20 ]]; then
    return 0
  fi

  code=$(curl -sS -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -X DELETE "${API_BASE}/api/assets/${asset_id}" || true)
  [[ "$code" =~ ^20 ]]
}

list_previous_test_asset_ids() {
  docker exec immich_postgres psql -U immich -d immich -At -c "
    select id
    from asset
    where \"deletedAt\" is null
      and (
        \"originalFileName\" like 'light-%'
        or \"originalFileName\" like 'heavy-%'
        or \"originalFileName\" like 'heavy-sample-%'
        or \"originalFileName\" in ('ligero.mp4', 'pesado.mp4', 'pesado-remux.mp4')
      )
    order by \"createdAt\";
  " 2>/dev/null || true
}

cleanup_previous_test_assets() {
  local ids id deleted_any=0
  ids="$(list_previous_test_asset_ids)"
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if delete_asset "$id"; then
      deleted_any=1
    fi
  done <<EOF
$ids
EOF
  if [ "$deleted_any" -eq 1 ]; then
    /usr/local/bin/cache-clean.sh >/dev/null 2>&1 || true
  fi
}

wait_path_gone() {
  local path="$1" attempt
  for attempt in $(seq 1 30); do
    [ ! -e "$path" ] && return 0
    sleep 2
  done
  return 1
}

make_unique_copy() {
  local src="$1"
  local label="$2"
  local out="$TMP_DIR/${label}-${RUN_ID}.mp4"
  if ffmpeg -y -v error -i "$src" -map 0 -c copy \
      -metadata comment="codex-${label}-${RUN_ID}" \
      -movflags +faststart "$out" >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return 0
  fi
  cp -f "$src" "$out"
  printf '%s\n' "$out"
}

make_heavy_test_copy() {
  local src="$1"
  local out="$TMP_DIR/heavy-sample-${RUN_ID}.mp4"
  if ffmpeg -y -v error -ss 0 -t 4 -i "$src" -map 0 -c copy \
      -metadata comment="codex-heavy-sample-${RUN_ID}" \
      -movflags +faststart "$out" >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return 0
  fi
  make_unique_copy "$src" "heavy"
}

wait_path_exists() {
  local path="$1" attempt
  for attempt in $(seq 1 30); do
    [ -e "$path" ] && return 0
    sleep 2
  done
  return 1
}

prepare_install() {
  sanitize_lab_docker_state
  if docker info >/dev/null 2>&1 && [ -d /opt/immich-app ]; then
    (cd /opt/immich-app && docker compose down --remove-orphans -v >/dev/null 2>&1) || true
  fi
  crontab -r 2>/dev/null || true
  bash "$REPO_ROOT/scripts/wsl-lab-clean.sh" || true
  bash "$REPO_ROOT/scripts/wsl-lab-prepare.sh"
  restore_test_telegram
  printf 'si\nBORRAR-loop0-loop1\n' | NAS_CONFIG_FILE="$CONFIG_OUT" bash "$REPO_ROOT/install.sh"
  restore_test_telegram
}

run_functional_flow() {
  local light_asset heavy_asset light_json heavy_json
  local light_orig heavy_orig light_cache heavy_cache
  local light_size heavy_size heavy_cache_size heavy_source light_source
  local light_play_len heavy_play_len heavy_placeholder_len
  local light_upload heavy_upload

  bash "$REPO_ROOT/maintenance/lab-ensure-stack.sh" >/tmp/v2-stack.log 2>&1
  wait_http "${API_BASE}/api/server/ping" || { fail "Immich no respondió tras instalar"; return 1; }
  reset_runtime_tasks
  telegram_direct "🎬 Inicio de bloque funcional v2.0\nObjetivo: subir un video ligero y uno pesado, validar playback diurno, transformación nocturna y borrado limpio en HDD + cache." || true
  ensure_admin_and_login || return 1
  cleanup_previous_test_assets

  light_upload="$(make_unique_copy "$LIGHT_VIDEO" "light")"
  heavy_upload="$(make_heavy_test_copy "$HEAVY_VIDEO")"

  light_asset="$(upload_video "$light_upload" "light")"
  heavy_asset="$(upload_video "$heavy_upload" "heavy")"
  [ -n "$light_asset" ] || { fail "No pude subir ligero.mp4"; return 1; }
  [ -n "$heavy_asset" ] || { fail "No pude subir pesado.mp4"; return 1; }
  pass "Uploads de ligero y pesado OK"

  light_json="$TMP_DIR/asset-${light_asset}.json"
  heavy_json="$TMP_DIR/asset-${heavy_asset}.json"
  wait_asset_ready "$light_asset" "$light_json" || { fail "ligero.mp4 no quedó disponible en API"; return 1; }
  wait_asset_ready "$heavy_asset" "$heavy_json" || { fail "pesado.mp4 no quedó disponible en API"; return 1; }

  light_orig="$(host_path_from_original "$(json_value "$light_json" "originalPath")")"
  heavy_orig="$(host_path_from_original "$(json_value "$heavy_json" "originalPath")")"
  light_cache="$(cache_path_from_original "$(json_value "$light_json" "originalPath")")"
  heavy_cache="$(cache_path_from_original "$(json_value "$heavy_json" "originalPath")")"

  [ -n "$light_orig" ] && wait_path_exists "$light_orig" && pass "Original ligero quedó en HDD" || fail "Original ligero no apareció en HDD"
  [ -n "$heavy_orig" ] && wait_path_exists "$heavy_orig" && pass "Original pesado quedó en HDD" || fail "Original pesado no apareció en HDD"

  light_source="$(playback_source "$light_asset")"
  heavy_source="$(playback_source "$heavy_asset")"
  light_play_len="$(playback_length "$light_asset")"
  heavy_play_len="$(playback_length "$heavy_asset")"
  heavy_placeholder_len="$(placeholder_size_for_asset "$heavy_json")"

  light_size="$(stat -Lc '%s' "$light_orig")"
  if [ "$light_play_len" = "$light_size" ]; then
    pass "ligero.mp4 se reproduce directo de día"
  else
    fail "ligero.mp4 no salió directo de día (len=$light_play_len esperado=$light_size source=$light_source)"
  fi
  if [ "$heavy_play_len" = "$heavy_placeholder_len" ]; then
    pass "pesado.mp4 mostró placeholder de día"
  else
    fail "pesado.mp4 no mostró placeholder de día (len=$heavy_play_len esperado=$heavy_placeholder_len source=$heavy_source)"
  fi

  if [ -L "$light_cache" ] || [ -f "$light_cache" ]; then
    pass "ligero.mp4 dejó referencia/copia en cache"
  else
    fail "ligero.mp4 no dejó referencia/copia en cache"
  fi

  if [ -e "$heavy_cache" ]; then
    warn "pesado.mp4 ya tenía cache antes de la noche"
  else
    pass "pesado.mp4 aún no tenía cache optimizado de día"
  fi

  NAS_CURRENT_HOUR=12 ML_WINDOW_HOUR=12 /usr/local/bin/night-run.sh >/tmp/v2-night-day.log 2>&1 || true
  heavy_source="$(playback_source "$heavy_asset")"
  heavy_play_len="$(playback_length "$heavy_asset")"
  if [ "$heavy_play_len" = "$heavy_placeholder_len" ]; then
    pass "pesado.mp4 siguió en placeholder cuando forcé horario diurno"
  else
    fail "pesado.mp4 dejó de estar en placeholder en horario diurno (len=$heavy_play_len esperado=$heavy_placeholder_len source=$heavy_source)"
  fi

  NAS_CURRENT_HOUR=02 ML_WINDOW_HOUR=02 /usr/local/bin/night-run.sh >/tmp/v2-night-night.log 2>&1
  heavy_source="$(playback_source "$heavy_asset")"
  heavy_play_len="$(playback_length "$heavy_asset")"
  if [ -e "$heavy_cache" ] && [ "$heavy_play_len" = "$(stat -Lc '%s' "$heavy_cache")" ]; then
    pass "pesado.mp4 pasó a cache optimizado tras la noche"
  else
    fail "pesado.mp4 no salió desde cache optimizado tras la noche (len=$heavy_play_len source=$heavy_source)"
  fi

  [ -e "$heavy_cache" ] && pass "Cache optimizado pesado presente" || fail "Cache optimizado pesado ausente"
  heavy_size="$(stat -Lc '%s' "$heavy_orig")"
  heavy_cache_size="$(stat -Lc '%s' "$heavy_cache")"
  if [ "$heavy_cache_size" -lt "$heavy_size" ]; then
    pass "Cache pesado quedó más ligero que el original"
  else
    fail "Cache pesado no quedó más ligero que el original"
  fi

  if delete_asset "$light_asset"; then
    pass "Borrado API de ligero.mp4 OK"
  else
    fail "No pude borrar ligero.mp4 por API"
  fi
  if delete_asset "$heavy_asset"; then
    pass "Borrado API de pesado.mp4 OK"
  else
    fail "No pude borrar pesado.mp4 por API"
  fi

  /usr/local/bin/cache-clean.sh >/tmp/v2-cache-clean.log 2>&1 || true
  wait_path_gone "$light_orig" && pass "Original ligero eliminado del HDD" || fail "Original ligero sigue en HDD"
  wait_path_gone "$heavy_orig" && pass "Original pesado eliminado del HDD" || fail "Original pesado sigue en HDD"
  wait_path_gone "$light_cache" && pass "Cache ligero limpiado" || fail "Cache ligero sigue presente"
  wait_path_gone "$heavy_cache" && pass "Cache pesado limpiado" || fail "Cache pesado sigue presente"
}

send_final_summary() {
  local text
  if [ "$FAIL_COUNT" -eq 0 ]; then
    text="✅ Prueba v2.0 terminada\nPASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}\nTodo lo crítico quedó en verde."
  else
    text="⚠️ Prueba v2.0 terminada con hallazgos\nPASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}\n${FAILURES}"
  fi
  telegram_direct "$text" || true
}

main() {
  if [ "$RUN_INSTALL" = "1" ]; then
    telegram_direct "🧪 Inicio de ejecución v2.0 real\nObjetivo: instalación limpia + flujos funcionales + matriz completa de mensajes Telegram." || true
  else
    telegram_direct "🧪 Inicio de ejecución v2.0 real\nObjetivo: reutilizar el entorno ya instalado para correr flujos funcionales, alternos, negativos y la matriz completa de mensajes Telegram." || true
  fi

  if [ "$RUN_INSTALL" = "1" ]; then
    prepare_install
    pass "Instalación limpia desde install.sh OK"
  fi

  run_functional_flow || true

  if [ "$RUN_ALERT_MATRIX" = "1" ]; then
    restore_test_telegram
    telegram_direct "📣 Inicio de matriz de mensajes v2.0\nObjetivo: disparar los mensajes de Telegram reales del sistema, incluyendo alternos y negativos, para revisar texto y cobertura." || true
    (cd "$REPO_ROOT" && REAL_TELEGRAM_TOKEN="$REAL_TELEGRAM_TOKEN" REAL_TELEGRAM_CHAT_ID="$REAL_TELEGRAM_CHAT_ID" ALERT_MODE=real bash maintenance/test-alert-coverage.sh) || fail "La matriz de mensajes reales falló"
    pass "Matriz completa de mensajes reales enviada a Telegram"
  fi

  send_final_summary

  printf '\nRESUMEN V2\nPASS=%s WARN=%s FAIL=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
