#!/usr/bin/env bash
# Nightly validation and atomic installation of the perfume SQLite backup.
set -euo pipefail

PHOTOS_MOUNT="${PERFUME_DB_PHOTOS_MOUNT:-/mnt/storage-main}"
BACKUP_MOUNT="${PERFUME_DB_BACKUP_MOUNT:-/mnt/storage-backup}"
INBOX_SUFFIX="/perfume-db/incoming"
DEST_DIR="${PERFUME_DB_STABLE_DIR:-/mnt/storage-backup/snapshots/perfume-db}"
STABLE_NAME="perfume-app.sqlite"
READY_NAME="perfume-app.ready.json"
MANIFEST_NAME="perfume-app.sqlite.json"

log() { printf '[perfume-db-backup] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

mount_source() { findmnt -n -o SOURCE --target "$1" 2>/dev/null; }

safe_incoming_dir() {
  local mount="$1" db_dir="$1/perfume-db" incoming="$1$INBOX_SUFFIX"
  local real_mount real_incoming
  [[ -d "$mount" && -d "$db_dir" && -d "$incoming" ]] || return 1
  [[ ! -L "$mount" && ! -L "$db_dir" && ! -L "$incoming" ]] || return 1
  real_mount="$(realpath -e -- "$mount" 2>/dev/null)" || return 1
  real_incoming="$(realpath -e -- "$incoming" 2>/dev/null)" || return 1
  [[ "$real_incoming" == "$real_mount/perfume-db/incoming" ]]
}

prepare_stable_dir() {
  local real_mount current relative component real_dest
  [[ "$DEST_DIR" == "$BACKUP_MOUNT/"* ]] || return 1
  real_mount="$(realpath -e -- "$BACKUP_MOUNT" 2>/dev/null)" || return 1
  relative="${DEST_DIR#"$BACKUP_MOUNT/"}"
  [[ -n "$relative" ]] || return 1
  current="$BACKUP_MOUNT"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
  mkdir -p "$DEST_DIR" || return 1
  [[ -d "$DEST_DIR" && ! -L "$DEST_DIR" ]] || return 1
  real_dest="$(realpath -e -- "$DEST_DIR" 2>/dev/null)" || return 1
  [[ "$real_dest" == "$real_mount/"* ]]
}
is_real_external_mount() {
  local mount="$1" source root_source
  [[ -d "$mount" && ! -L "$mount" ]] || return 1
  mountpoint -q "$mount" 2>/dev/null || return 1
  source="$(mount_source "$mount")" || return 1
  root_source="$(mount_source /)" || return 1
  [[ -n "$source" && "$source" != "$root_source" ]] || return 1
  case "$source" in /dev/sd*|/dev/nvme*) ;; *) return 1 ;; esac
  case "$source" in rootfs|overlay|tmpfs|ramfs|/dev/mmcblk*|/dev/root) return 1 ;; esac
  return 0
}

manifest_fields() {
  python3 - "$1" "${2:-incoming}" <<'PY'
import json, re, sys
try:
    obj = json.load(open(sys.argv[1], encoding="utf-8"))
    allow_stable = sys.argv[2] == "stable"
    if obj.get("format") != "perfume-sqlite-backup-v1":
        raise ValueError("formato")
    if obj.get("database") != "perfume-app.sqlite":
        raise ValueError("base")
    if obj.get("disk") not in ("primary", "secondary"):
        raise ValueError("disco")
    name = obj.get("databaseFile", "")
    is_received = re.fullmatch(r"perfume-app-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.sqlite", name)
    if not is_received and not (allow_stable and name == "perfume-app.sqlite"):
        raise ValueError("nombre")
    if not isinstance(obj.get("sizeBytes"), int) or obj["sizeBytes"] <= 0:
        raise ValueError("tamaño")
    if not re.fullmatch(r"[0-9a-f]{64}", obj.get("sha256", "")):
        raise ValueError("hash")
    print(obj["disk"], name, obj["sizeBytes"], obj["sha256"], sep="|")
except Exception:
    raise SystemExit(1)
PY
}

sqlite_integrity_ok() {
  python3 - "$1" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    rows = con.execute("PRAGMA integrity_check").fetchall()
    con.close()
    if rows != [("ok",)]:
        raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PY
}

verify_copy() {
  local file="$1" size="$2" sha="$3" actual_size actual_sha
  [[ -f "$file" && ! -L "$file" ]] || return 1
  actual_size="$(stat -c '%s' -- "$file")"
  actual_sha="$(sha256sum -- "$file" | awk '{print $1}')"
  [[ "$actual_size" == "$size" && "$actual_sha" == "$sha" ]] || return 1
  sqlite_integrity_ok "$file"
}

recover_previous() {
  local stable="$DEST_DIR/$STABLE_NAME" manifest="$DEST_DIR/$MANIFEST_NAME"
  local prev="$DEST_DIR/.$STABLE_NAME.previous" prev_manifest="$DEST_DIR/.$MANIFEST_NAME.previous"
  [[ -f "$prev" ]] || return 0
  if [[ -f "$stable" && -f "$manifest" ]]; then
    local meta name size sha
    meta="$(manifest_fields "$manifest" stable 2>/dev/null || true)"
    if [[ -n "$meta" ]]; then
      IFS='|' read -r _ name size sha <<< "$meta"
      if verify_copy "$stable" "$size" "$sha"; then
        rm -f -- "$prev"
        rm -f -- "$prev_manifest"
        return 0
      fi
    fi
  fi
  if [[ -f "$prev_manifest" ]]; then
    local previous_meta previous_name previous_size previous_sha
    previous_meta="$(manifest_fields "$prev_manifest" stable 2>/dev/null || true)"
    if [[ -n "$previous_meta" ]]; then
      IFS='|' read -r _ previous_name previous_size previous_sha <<< "$previous_meta"
      if verify_copy "$prev" "$previous_size" "$previous_sha"; then
        mv -f -- "$prev" "$stable"
        mv -f -- "$prev_manifest" "$manifest"
        sync -f "$DEST_DIR"
        return 0
      fi
    fi
  elif [[ ! -f "$stable" ]] && sqlite_integrity_ok "$prev"; then
    mv -f -- "$prev" "$stable"
    rm -f -- "$manifest"
    sync -f "$DEST_DIR"
    return 0
  fi
  fail "hay una copia previa de recuperación, pero no se pudo verificar cuál conservar"
}

select_ready() {
  local candidates=() marker mount
  for mount in "$PHOTOS_MOUNT" "$BACKUP_MOUNT"; do
    is_real_external_mount "$mount" || continue
    safe_incoming_dir "$mount" || continue
    marker="$mount$INBOX_SUFFIX/$READY_NAME"
    [[ -f "$marker" && ! -L "$marker" ]] && candidates+=("$marker")
  done
  [[ ${#candidates[@]} -gt 0 ]] || return 2
  if [[ ${#candidates[@]} -eq 1 ]]; then printf '%s\n' "${candidates[0]}"; return 0; fi
  python3 - "${candidates[@]}" <<'PY'
import datetime, json, sys
valid = []
for path in sys.argv[1:]:
    try:
        obj = json.load(open(path, encoding="utf-8"))
        captured = datetime.datetime.fromisoformat(obj["capturedAt"].replace("Z", "+00:00"))
        valid.append((captured.timestamp(), path))
    except Exception:
        continue
if not valid:
    raise SystemExit(1)
print(max(valid)[1])
PY
}

marker="$(select_ready)" || {
  rc=$?
  [[ "$rc" -eq 2 ]] && { log "SKIPPED: no hay una copia nueva esperando en los discos externos"; exit 2; }
  fail "no se pudo leer el manifiesto de recepción"
}
source_mount=""
case "$marker" in
  "$PHOTOS_MOUNT$INBOX_SUFFIX/"*) source_mount="$PHOTOS_MOUNT" ;;
  "$BACKUP_MOUNT$INBOX_SUFFIX/"*) source_mount="$BACKUP_MOUNT" ;;
  *) fail "el marcador no pertenece a una ruta permitida" ;;
esac
is_real_external_mount "$source_mount" || fail "el disco de origen dejó de estar montado"
safe_incoming_dir "$source_mount" || fail "la carpeta de recepción ya no es una ruta directa del disco externo"
meta="$(manifest_fields "$marker")" || fail "el manifiesto de recepción no es válido"
IFS='|' read -r declared_disk database_file expected_size expected_sha <<< "$meta"
expected_mount="primary"
[[ "$source_mount" == "$BACKUP_MOUNT" ]] && expected_mount="secondary"
[[ "$declared_disk" == "$expected_mount" ]] || fail "el manifiesto no coincide con el disco que lo contiene"
source_file="$(dirname "$marker")/$database_file"
verify_copy "$source_file" "$expected_size" "$expected_sha" || fail "la copia recibida no coincide en tamaño, SHA-256 o SQLite integrity_check"

is_real_external_mount "$BACKUP_MOUNT" || fail "el disco secundario de respaldo no está montado; se conserva el origen para reintentar"
prepare_stable_dir || fail "el destino estable no es una ruta directa segura dentro del disco secundario"
recover_previous

stable="$DEST_DIR/$STABLE_NAME"
manifest="$DEST_DIR/$MANIFEST_NAME"
tmp="$DEST_DIR/.$STABLE_NAME.new.$$"
manifest_tmp="$DEST_DIR/.$MANIFEST_NAME.new.$$"
previous="$DEST_DIR/.$STABLE_NAME.previous"
previous_manifest="$DEST_DIR/.$MANIFEST_NAME.previous"
had_previous=0
installed_new=0

cleanup() {
  local rc=$?
  rm -f -- "$tmp" "$manifest_tmp"
  if [[ $rc -ne 0 ]]; then
    if [[ "$had_previous" -eq 1 && -f "$previous" && -f "$previous_manifest" ]]; then
      mv -f -- "$previous" "$stable"
      mv -f -- "$previous_manifest" "$manifest"
      sync -f "$DEST_DIR" || true
    elif [[ "$installed_new" -eq 1 ]]; then
      rm -f -- "$stable" "$manifest"
      sync -f "$DEST_DIR" || true
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

cp --reflink=never -- "$source_file" "$tmp" || fail "no se pudo copiar al temporal del disco secundario"
sync -f "$tmp" || fail "no se pudo sincronizar la copia temporal"
verify_copy "$tmp" "$expected_size" "$expected_sha" || fail "la copia temporal no pasó tamaño, hash e integridad"

if [[ -e "$stable" ]]; then
  [[ -f "$stable" && ! -L "$stable" ]] || fail "la copia estable previa no es un archivo regular"
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail "la copia estable previa no tiene manifiesto verificable"
  old_meta="$(manifest_fields "$manifest" stable)" || fail "el manifiesto estable previo no es válido"
  IFS='|' read -r _ old_name old_size old_sha <<< "$old_meta"
  verify_copy "$stable" "$old_size" "$old_sha" || fail "la copia estable previa no coincide con su manifiesto"
  [[ ! -e "$previous" ]] || fail "hay un respaldo de recuperación previo que requiere revisión"
  [[ ! -e "$previous_manifest" ]] || fail "hay un manifiesto de recuperación previo que requiere revisión"
  ln -- "$stable" "$previous" || fail "no se pudo preservar la última copia válida"
  ln -- "$manifest" "$previous_manifest" || { rm -f -- "$previous"; fail "no se pudo preservar el manifiesto anterior"; }
  had_previous=1
fi

mv -f -- "$tmp" "$stable" || fail "no se pudo reemplazar atómicamente la copia estable"
installed_new=1
sync -f "$DEST_DIR" || fail "no se pudo sincronizar el directorio de destino"
python3 - "$manifest_tmp" "$expected_size" "$expected_sha" "$declared_disk" "$marker" <<'PY'
import datetime, json, os, sys
path, size, sha, disk, source_marker = sys.argv[1:]
obj = {
    "format": "perfume-sqlite-backup-v1",
    "database": "perfume-app.sqlite",
    "databaseFile": "perfume-app.sqlite",
    "sizeBytes": int(size),
    "sha256": sha,
    "disk": "secondary",
    "sourceDisk": disk,
    "sourceMarker": source_marker,
    "backedUpAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "x", encoding="utf-8") as f:
    json.dump(obj, f, separators=(",", ":"))
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
PY
sync -f "$manifest_tmp" || fail "no se pudo sincronizar el manifiesto nuevo"
mv -f -- "$manifest_tmp" "$manifest" || fail "no se pudo publicar el manifiesto estable"
sync -f "$DEST_DIR" || fail "no se pudo sincronizar el manifiesto estable"
had_previous=0
rm -f -- "$previous"
rm -f -- "$previous_manifest"

rm -f -- "$marker"
rm -f -- "$source_file"
sync -f "$(dirname "$marker")" || true
trap - EXIT INT TERM
log "OK: base validada y respaldada en $stable (origen $declared_disk)"
exit 0
