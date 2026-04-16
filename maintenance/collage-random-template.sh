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
MAX_PREVIEW_CANDIDATES="${MAX_PREVIEW_CANDIDATES:-800}"
TEMPLATE_COOLDOWN_DAYS="${TEMPLATE_COOLDOWN_DAYS:-3}"
PHOTO_HISTORY_DAYS="${PHOTO_HISTORY_DAYS:-7}"

mkdir -p "$OUT_DIR"
STATE_DIR="${COLLAGE_STATE_DIR:-${OUT_DIR}/.state}"
mkdir -p "$STATE_DIR"
TEMPLATE_HISTORY_FILE="${TEMPLATE_HISTORY_FILE:-${STATE_DIR}/template-history.tsv}"
PHOTO_HISTORY_FILE="${PHOTO_HISTORY_FILE:-${STATE_DIR}/photo-history.tsv}"

if [[ -z "$IMMICH_EMAIL" || -z "$IMMICH_PASSWORD" ]]; then
  echo "Faltan credenciales de Immich (IMMICH_EMAIL/IMMICH_PASSWORD) en ${SECRETS_FILE}" >&2
  exit 1
fi

mapfile -t templates < <(find "$TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.PNG" \) | sort)
if [[ "${#templates[@]}" -lt 1 ]]; then
  echo "No hay plantillas PNG en ${TEMPLATE_DIR}" >&2
  exit 1
fi

utc_day="$(date -u +%F)"
today_days="$(( $(date -u -d "$utc_day" +%s) / 86400 ))"
start_idx=$(( today_days % ${#templates[@]} ))
template=""
today_template_name=""
if [[ -f "$TEMPLATE_HISTORY_FILE" ]]; then
  while IFS=$'\t' read -r used_day used_name; do
    if [[ "$used_day" == "$utc_day" && -n "$used_name" ]]; then
      today_template_name="$used_name"
    fi
  done < "$TEMPLATE_HISTORY_FILE"
fi
if [[ -n "$today_template_name" ]]; then
  for candidate in "${templates[@]}"; do
    if [[ "$(basename "$candidate")" == "$today_template_name" ]]; then
      template="$candidate"
      break
    fi
  done
fi
declare -A recent_template_names=()
if [[ -z "$template" && "${TEMPLATE_COOLDOWN_DAYS}" -gt 0 && -f "$TEMPLATE_HISTORY_FILE" ]]; then
  while IFS=$'\t' read -r used_day used_name; do
    [[ -z "${used_day}" || -z "${used_name}" ]] && continue
    used_epoch="$(date -u -d "$used_day" +%s 2>/dev/null || true)"
    [[ -z "${used_epoch}" ]] && continue
    delta_days="$(( (today_days * 86400 - used_epoch) / 86400 ))"
    if (( delta_days >= 0 && delta_days < TEMPLATE_COOLDOWN_DAYS )); then
      recent_template_names["$used_name"]=1
    fi
  done < "$TEMPLATE_HISTORY_FILE"
fi
for (( step=0; step<${#templates[@]}; step++ )); do
  idx=$(( (start_idx + step) % ${#templates[@]} ))
  candidate="${templates[$idx]}"
  candidate_name="$(basename "$candidate")"
  if [[ -z "${recent_template_names[$candidate_name]:-}" ]]; then
    template="$candidate"
    break
  fi
done
if [[ -z "$template" ]]; then
  template="${templates[$start_idx]}"
fi
if [[ -z "$template" ]]; then
  echo "No pude seleccionar plantilla" >&2
  exit 1
fi

stamp="$(date +%Y%m%d_%H%M%S)"
out_file="${OUT_DIR}/collage-template-random-${stamp}.jpg"
preview_list_file="/tmp/collage-random-preview-list-${stamp}.txt"
picked_list_file="/tmp/collage-random-picked-${stamp}.txt"

token="$(curl -fsS -X POST "${IMMICH_API}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${IMMICH_EMAIL}\",\"password\":\"${IMMICH_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))")"

if [[ -z "$token" ]]; then
  echo "No pude obtener token de Immich" >&2
  exit 1
fi

preview_meta="0,0,0"
if ! preview_meta="$(python3 - "$IMMICH_API" "$token" "$THUMB_ROOT" "$preview_list_file" "$MIN_DAILY_PREVIEWS" "$PHOTO_HISTORY_FILE" "$PHOTO_HISTORY_DAYS" "$utc_day" "$MAX_PREVIEW_CANDIDATES" <<'PY'
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

api, token, thumb_root, output_path, min_daily_raw, history_file, history_days_raw, day_raw, max_candidates_raw = sys.argv[1:10]
min_daily = max(1, int(min_daily_raw or "3"))
history_days = max(1, int(history_days_raw or "7"))
max_candidates = max(50, int(max_candidates_raw or "800"))

today = dt.date.fromisoformat(day_raw)
cutoff = today - dt.timedelta(days=history_days)
headers = {"Authorization": f"Bearer {token}"}

req = urllib.request.Request(f"{api}/memories", headers=headers, method="GET")
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        memories = json.loads(resp.read().decode("utf-8", errors="ignore"))
except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
    memories = []

if not isinstance(memories, list):
    memories = []

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
    if show_at_utc_date(memory) != today:
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

memory_paths: list[str] = []
seen = set()
for aid in asset_ids:
    path = thumb_path(aid)
    if not os.path.exists(path):
        continue
    if path in seen:
        continue
    seen.add(path)
    memory_paths.append(path)

last_used: dict[str, dt.date] = {}
if os.path.exists(history_file):
    with open(history_file, "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            parts = raw.rstrip("\n").split("\t", 1)
            if len(parts) != 2:
                continue
            d_raw, path = parts
            try:
                d = dt.date.fromisoformat(d_raw)
            except ValueError:
                continue
            prev = last_used.get(path)
            if prev is None or d > prev:
                last_used[path] = d

def is_recent(path: str) -> bool:
    d = last_used.get(path)
    # No penaliza selecciones de hoy para mantener reintentos estables por día.
    return d is not None and cutoff <= d < today

def stable_hash(path: str) -> int:
    return int(hashlib.sha256(f"{day_raw}|{path}".encode("utf-8", errors="ignore")).hexdigest()[:16], 16)

fallback_paths: list[str] = []
if len(memory_paths) < min_daily:
    files: list[tuple[float, str]] = []
    for dirpath, _dirnames, filenames in os.walk(thumb_root):
        for name in filenames:
            if not name.endswith("_preview.jpeg"):
                continue
            path = os.path.join(dirpath, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            files.append((mtime, path))
    files.sort(key=lambda x: x[0], reverse=True)
    cap = max_candidates * 6
    for _m, path in files[:cap]:
        if path in seen:
            continue
        seen.add(path)
        fallback_paths.append(path)

combined: list[tuple[str, str]] = []
for p in memory_paths:
    combined.append((p, "memory"))
for p in fallback_paths:
    combined.append((p, "fallback"))

def rank(item: tuple[str, str]) -> tuple[int, int, int]:
    path, source = item
    recent = is_recent(path)
    if source == "memory" and not recent:
        cls = 0
    elif source == "fallback" and not recent:
        cls = 1
    elif source == "memory" and recent:
        cls = 2
    else:
        cls = 3
    age_ord = last_used.get(path, dt.date(1970, 1, 1)).toordinal()
    return (cls, age_ord, stable_hash(path))

combined.sort(key=rank)
selected = [p for p, _src in combined[:max_candidates]]

with open(output_path, "w", encoding="utf-8") as fh:
    for p in selected:
        fh.write(p + "\n")

fallback_used = 1 if fallback_paths else 0
print(f"{len(memory_paths)},{len(selected)},{fallback_used}")
PY
)"; then
  preview_meta="0,0,0"
fi

IFS=',' read -r memory_count preview_count fallback_used <<< "$preview_meta"
memory_count="$(printf '%s' "${memory_count:-0}" | tr -cd '0-9' | head -c 9)"
preview_count="$(printf '%s' "${preview_count:-0}" | tr -cd '0-9' | head -c 9)"
fallback_used="$(printf '%s' "${fallback_used:-0}" | tr -cd '0-9' | head -c 1)"
[[ -z "$memory_count" ]] && memory_count="0"
[[ -z "$preview_count" ]] && preview_count="0"
[[ -z "$fallback_used" ]] && fallback_used="0"

probe_args=(
  --template "$template"
  --thumb-root "$THUMB_ROOT"
  --out "$out_file"
  --max-candidates "$MAX_PREVIEW_CANDIDATES"
  --picked-list-out "$picked_list_file"
)

if [[ "$preview_count" -gt 0 ]]; then
  probe_args+=(--preview-list "$preview_list_file")
fi

if [[ "$fallback_used" -eq 1 ]]; then
  echo "INFO daily memories candidates=${memory_count}; completando con fallback no repetido (7d)."
else
  echo "INFO daily memories candidates=${memory_count}; pool final=${preview_count}."
fi

probe_output="$(python3 "$PROBE_BIN" "${probe_args[@]}")"
printf '%s\n' "$probe_output"

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

python3 - "$TEMPLATE_HISTORY_FILE" "$utc_day" "$(basename "$template")" <<'PY'
import datetime as dt
import pathlib
import sys

history_file, day_raw, template_name = sys.argv[1:4]
today = dt.date.fromisoformat(day_raw)
retention_days = 180
entries: list[tuple[dt.date, str]] = []
hp = pathlib.Path(history_file)
if hp.exists():
    for raw in hp.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = raw.split("\t", 1)
        if len(parts) != 2:
            continue
        d_raw, name = parts
        try:
            d = dt.date.fromisoformat(d_raw)
        except ValueError:
            continue
        if (today - d).days <= retention_days:
            entries.append((d, name.strip()))
if (today, template_name) not in entries:
    entries.append((today, template_name))
entries.sort(key=lambda x: x[0])
hp.parent.mkdir(parents=True, exist_ok=True)
hp.write_text("".join(f"{d.isoformat()}\t{name}\n" for d, name in entries), encoding="utf-8")
PY

if [[ -s "$picked_list_file" ]]; then
  python3 - "$PHOTO_HISTORY_FILE" "$utc_day" "$PHOTO_HISTORY_DAYS" "$picked_list_file" <<'PY'
import datetime as dt
import pathlib
import sys

history_file, day_raw, history_days_raw, picks_file = sys.argv[1:5]
today = dt.date.fromisoformat(day_raw)
history_days = max(1, int(history_days_raw or "7"))
retention_days = max(60, history_days + 30)
cutoff = today - dt.timedelta(days=retention_days)

latest: dict[str, dt.date] = {}
hp = pathlib.Path(history_file)
if hp.exists():
    for raw in hp.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = raw.split("\t", 1)
        if len(parts) != 2:
            continue
        d_raw, path = parts
        try:
            d = dt.date.fromisoformat(d_raw)
        except ValueError:
            continue
        if d < cutoff:
            continue
        prev = latest.get(path)
        if prev is None or d > prev:
            latest[path] = d

for raw in pathlib.Path(picks_file).read_text(encoding="utf-8", errors="ignore").splitlines():
    p = raw.strip()
    if not p:
        continue
    latest[p] = today

rows = sorted(((d, p) for p, d in latest.items()), key=lambda x: (x[0], x[1]))
hp.parent.mkdir(parents=True, exist_ok=True)
hp.write_text("".join(f"{d.isoformat()}\t{p}\n" for d, p in rows), encoding="utf-8")
PY
fi

if [[ -x "$ALERT_BIN" ]]; then
  "$ALERT_BIN" "🖼️ Collage por plantilla generado: $(basename "$template") (asset ${asset_id})"
fi

echo "OK template=$(basename "$template") asset_id=${asset_id} out=${out_file}"
