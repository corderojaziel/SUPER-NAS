#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="${SECRETS_FILE:-/etc/nas-secrets}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi

IMMICH_BASE="${IMMICH_BASE:-http://127.0.0.1:2283}"
IMMICH_API="${IMMICH_API:-${IMMICH_BASE}/api}"
IMMICH_EMAIL="${IMMICH_EMAIL:-${IMMICH_ADMIN_EMAIL:-}}"
IMMICH_PASSWORD="${IMMICH_PASSWORD:-${IMMICH_ADMIN_PASSWORD:-}}"
IMMICH_USER_ID="${IMMICH_USER_ID:-${COLLAGE_USER_ID:-38176398-2a83-433e-b966-01f9665d471b}}"

TEMPLATE_DIR="${TEMPLATE_DIR:-/var/lib/immich/collage-templates/runtime}"
THUMB_ROOT="${THUMB_ROOT:-/var/lib/immich/thumbs/${IMMICH_USER_ID}}"
OUT_DIR="${OUT_DIR:-/var/lib/immich/collages}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/template_probe_people.py}"
ALERT_BIN="${ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

mkdir -p "$OUT_DIR"

if [[ -z "$IMMICH_EMAIL" || -z "$IMMICH_PASSWORD" ]]; then
  echo "Faltan credenciales de Immich (IMMICH_EMAIL/IMMICH_PASSWORD) en ${SECRETS_FILE}" >&2
  exit 1
fi

mapfile -t templates < <(find "$TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.PNG" \) | sort)
if [[ "${#templates[@]}" -lt 1 ]]; then
  echo "No hay plantillas PNG en ${TEMPLATE_DIR}" >&2
  exit 1
fi

pick_idx=$(( RANDOM % ${#templates[@]} ))
template="${templates[$pick_idx]}"
stamp="$(date +%Y%m%d_%H%M%S)"
out_file="${OUT_DIR}/collage-template-random-${stamp}.jpg"

python3 "$PROBE_BIN" \
  --template "$template" \
  --thumb-root "$THUMB_ROOT" \
  --out "$out_file" \
  --no-gemini

token="$(curl -fsS -X POST "${IMMICH_API}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${IMMICH_EMAIL}\",\"password\":\"${IMMICH_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))")"

if [[ -z "$token" ]]; then
  echo "No pude obtener token de Immich" >&2
  exit 1
fi

created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
upload_resp="$(curl -fsS -X POST "${IMMICH_API}/assets" \
  -H "Authorization: Bearer ${token}" \
  -F "deviceAssetId=collage-template-random-${stamp}" \
  -F "deviceId=supernas-collage-template-bot" \
  -F "fileCreatedAt=${created_at}" \
  -F "fileModifiedAt=${created_at}" \
  -F "isFavorite=false" \
  -F "isArchived=false" \
  -F "assetData=@${out_file};type=image/jpeg")"

asset_id="$(printf "%s" "$upload_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")"
if [[ -z "$asset_id" ]]; then
  echo "Upload sin asset id: ${upload_resp}" >&2
  exit 1
fi

if [[ -x "$ALERT_BIN" ]]; then
  "$ALERT_BIN" "🖼️ Collage por plantilla generado: $(basename "$template") (asset ${asset_id})"
fi

echo "OK template=$(basename "$template") asset_id=${asset_id} out=${out_file}"
