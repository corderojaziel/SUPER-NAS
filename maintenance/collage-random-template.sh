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

DEFAULT_TEMPLATE_DIR="/var/lib/immich/collage-templates"
LEGACY_TEMPLATE_DIR="/var/lib/immich/collage-templates/runtime"
if [[ -z "${TEMPLATE_DIR:-}" ]]; then
  if [[ -d "$LEGACY_TEMPLATE_DIR" ]] && find "$LEGACY_TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.PNG" \) | grep -q .; then
    TEMPLATE_DIR="$LEGACY_TEMPLATE_DIR"
  else
    TEMPLATE_DIR="$DEFAULT_TEMPLATE_DIR"
  fi
fi
THUMB_ROOT="${THUMB_ROOT:-/var/lib/immich/thumbs/${IMMICH_USER_ID}}"
OUT_DIR="${OUT_DIR:-/var/lib/immich/collages}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/template_probe_people.py}"
ALERT_BIN="${ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
MIN_DAILY_PREVIEWS="${MIN_DAILY_PREVIEWS:-3}"

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
preview_list_file="/tmp/collage-random-preview-list-${stamp}.txt"

token="$(curl -fsS -X POST "${IMMICH_API}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${IMMICH_EMAIL}\",\"password\":\"${IMMICH_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))")"

if [[ -z "$token" ]]; then
  echo "No pude obtener token de Immich" >&2
  exit 1
fi

preview_count="0"
if ! preview_count="$(python3 - "$IMMICH_API" "$token" "$THUMB_ROOT" "$preview_list_file" "$MIN_DAILY_PREVIEWS" <<'PY'
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

api, token, thumb_root, output_path, min_daily = sys.argv[1:6]
today_utc = dt.datetime.now(dt.timezone.utc).date()
headers = {"Authorization": f"Bearer {token}"}
req = urllib.request.Request(f"{api}/memories", headers=headers, method="GET")
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        memories = json.loads(resp.read().decode("utf-8", errors="ignore"))
except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
    print("0")
    raise SystemExit(0)

if not isinstance(memories, list):
    print("0")
    raise SystemExit(0)

def show_at_utc_date(memory: dict) -> dt.date | None:
    raw = str(memory.get("showAt") or "").strip()
    if not raw:
        return None
    try:
        show_at = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return show_at.date()

def thumb_path(asset_id: str) -> str:
    clean = asset_id.replace("-", "")
    p1 = clean[:2]
    p2 = clean[2:4]
    return os.path.join(thumb_root, p1, p2, f"{asset_id}_preview.jpeg")

asset_ids: list[str] = []
for memory in memories:
    if not isinstance(memory, dict):
        continue
    if show_at_utc_date(memory) != today_utc:
        continue
    for asset in (memory.get("assets") or []):
        if not isinstance(asset, dict):
            continue
        asset_id = str(asset.get("id") or "").strip()
        if not asset_id:
            continue
        original_name = str(asset.get("originalFileName") or "").strip().lower()
        if original_name.startswith("collage-"):
            continue
        if asset_id not in asset_ids:
            asset_ids.append(asset_id)

paths: list[str] = []
for aid in asset_ids:
    path = thumb_path(aid)
    if os.path.exists(path):
        paths.append(path)

with open(output_path, "w", encoding="utf-8") as fh:
    for path in paths:
        fh.write(path + "\n")

if len(paths) < max(1, int(min_daily or "3")):
    # No abortamos: el caller hará fallback al pool global.
    print(str(len(paths)))
    raise SystemExit(0)

print(str(len(paths)))
PY
)"; then
  preview_count="0"
fi

preview_count="$(printf '%s' "$preview_count" | tr -cd '0-9' | head -c 9)"
if [[ -z "$preview_count" ]]; then
  preview_count="0"
fi

probe_args=(
  --template "$template"
  --thumb-root "$THUMB_ROOT"
  --out "$out_file"
)

if [[ "$preview_count" -ge "$MIN_DAILY_PREVIEWS" ]]; then
  probe_args+=(--preview-list "$preview_list_file")
  echo "INFO daily memories candidates=${preview_count} (utc-day)"
else
  echo "WARN daily memories candidates insuficientes (${preview_count}); fallback a pool global"
fi

python3 "$PROBE_BIN" "${probe_args[@]}"

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
