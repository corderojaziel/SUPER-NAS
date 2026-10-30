#!/usr/bin/env bash
# Nightly validation and atomic installation of the perfume SQLite backup.
set -euo pipefail

PHOTOS_MOUNT="${PERFUME_DB_PHOTOS_MOUNT:-/mnt/storage-main}"
BACKUP_MOUNT="${PERFUME_DB_BACKUP_MOUNT:-/mnt/storage-backup}"
INBOX_SUFFIX="/perfume-db/incoming"
DEST_DIR="${PERFUME_DB_STABLE_DIR:-/mnt/storage-backup/snapshots/perfume-db}"
STABLE_NAME="perfume-app.sqlite.gz"
LEGACY_STABLE_NAME="perfume-app.sqlite"
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
    if obj.get("database") != "perfume-app.sqlite":
        raise ValueError("base")
    if obj.get("disk") not in ("primary", "secondary"):
        raise ValueError("disco")
    name = obj.get("databaseFile", "")
    if not isinstance(obj.get("sizeBytes"), int) or obj["sizeBytes"] <= 0:
        raise ValueError("tamaño")
    if not re.fullmatch(r"[0-9a-f]{64}", obj.get("sha256", "")):
        raise ValueError("hash")
    fmt = obj.get("format")
    if fmt == "perfume-sqlite-backup-v1":
        if obj.get("compression") not in (None, ""):
            raise ValueError("compresión heredada")
        raw_size, raw_sha = obj["sizeBytes"], obj["sha256"]
        is_received = re.fullmatch(r"perfume-app-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.sqlite", name)
        stable = allow_stable and name == "perfume-app.sqlite"
    elif fmt == "perfume-sqlite-gzip-backup-v2":
        if obj.get("compression") != "gzip":
            raise ValueError("compresión")
        raw_size, raw_sha = obj.get("uncompressedSizeBytes"), obj.get("uncompressedSha256")
        is_received = re.fullmatch(r"perfume-app-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.sqlite\.gz", name)
        stable = allow_stable and name == "perfume-app.sqlite.gz"
        if not isinstance(raw_size, int) or raw_size <= 0 or not re.fullmatch(r"[0-9a-f]{64}", raw_sha or ""):
            raise ValueError("datos expandidos")
    else:
        raise ValueError("formato")
    if not is_received and not stable:
        raise ValueError("nombre")
    print(obj["disk"], name, obj["sizeBytes"], obj["sha256"], fmt, raw_size, raw_sha, sep="|")
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

gzip_sqlite_integrity_ok() {
  local archive="$1" expected_raw_size="$2" expected_raw_sha="$3" verify_dir="$4"
  local expanded actual_size actual_sha
  expanded="$(mktemp "$verify_dir/.perfume-db-verify.XXXXXX")" || return 1
  if ! gzip -t -- "$archive" || ! gzip -dc -- "$archive" > "$expanded"; then
    rm -f -- "$expanded"
    return 1
  fi
  actual_size="$(stat -c '%s' -- "$expanded")"
  actual_sha="$(sha256sum -- "$expanded" | awk '{print $1}')"
  if [[ "$actual_size" != "$expected_raw_size" || "$actual_sha" != "$expected_raw_sha" ]] || ! sqlite_integrity_ok "$expanded"; then
    rm -f -- "$expanded"
    return 1
  fi
  rm -f -- "$expanded"
}

verify_copy() {
  local file="$1" size="$2" sha="$3" fmt="$4" raw_size="$5" raw_sha="$6" verify_dir="$7" actual_size actual_sha
  [[ -f "$file" && ! -L "$file" ]] || return 1
  actual_size="$(stat -c '%s' -- "$file")"
  actual_sha="$(sha256sum -- "$file" | awk '{print $1}')"
  [[ "$actual_size" == "$size" && "$actual_sha" == "$sha" ]] || return 1
  if [[ "$fmt" == "perfume-sqlite-backup-v1" ]]; then
    sqlite_integrity_ok "$file"
  elif [[ "$fmt" == "perfume-sqlite-gzip-backup-v2" ]]; then
    gzip_sqlite_integrity_ok "$file" "$raw_size" "$raw_sha" "$verify_dir"
  else
    return 1
  fi
}

recover_previous() {
  local stable="$DEST_DIR/$STABLE_NAME" manifest="$DEST_DIR/$MANIFEST_NAME"
  local prev="$DEST_DIR/.$STABLE_NAME.previous" prev_manifest="$DEST_DIR/.$MANIFEST_NAME.previous"
  [[ -e "$prev" || -e "$prev_manifest" ]] || return 0
  [[ -f "$prev" && ! -L "$prev" && -f "$prev_manifest" && ! -L "$prev_manifest" ]] || fail "hay una recuperación previa incompleta que requiere revisión"

  local previous_meta previous_name previous_size previous_sha previous_fmt previous_raw_size previous_raw_sha
  previous_meta="$(manifest_fields "$prev_manifest" stable 2>/dev/null || true)"
  [[ -n "$previous_meta" ]] || fail "el manifiesto de recuperación anterior no es válido"
  IFS='|' read -r _ previous_name previous_size previous_sha previous_fmt previous_raw_size previous_raw_sha <<< "$previous_meta"
  verify_copy "$prev" "$previous_size" "$previous_sha" "$previous_fmt" "$previous_raw_size" "$previous_raw_sha" "$DEST_DIR" || fail "la copia previa de recuperación no coincide con su manifiesto"

  local current_meta current_name current_size current_sha current_fmt current_raw_size current_raw_sha
  current_meta="$(manifest_fields "$manifest" stable 2>/dev/null || true)"
  if [[ -n "$current_meta" ]]; then
    IFS='|' read -r _ current_name current_size current_sha current_fmt current_raw_size current_raw_sha <<< "$current_meta"
    if [[ "$current_name" == "$STABLE_NAME" ]] \
      && ! cmp -s -- "$manifest" "$prev_manifest" \
      && verify_copy "$DEST_DIR/$current_name" "$current_size" "$current_sha" "$current_fmt" "$current_raw_size" "$current_raw_sha" "$DEST_DIR"; then
      rm -f -- "$prev" "$prev_manifest"
      [[ "$previous_name" != "$LEGACY_STABLE_NAME" ]] || rm -f -- "$DEST_DIR/$LEGACY_STABLE_NAME"
      return 0
    fi
  fi

  if [[ "$previous_name" == "$STABLE_NAME" ]]; then
    mv -f -- "$prev" "$stable"
  else
    [[ -f "$DEST_DIR/$previous_name" && ! -L "$DEST_DIR/$previous_name" ]] || fail "falta la copia anterior indicada por su manifiesto"
    verify_copy "$DEST_DIR/$previous_name" "$previous_size" "$previous_sha" "$previous_fmt" "$previous_raw_size" "$previous_raw_sha" "$DEST_DIR" || fail "la copia anterior no pasó su verificación"
    rm -f -- "$prev"
    rm -f -- "$stable"
  fi
  mv -f -- "$prev_manifest" "$manifest"
  sync -f "$DEST_DIR"
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
IFS='|' read -r declared_disk database_file expected_size expected_sha expected_format expected_raw_size expected_raw_sha <<< "$meta"
expected_mount="primary"
[[ "$source_mount" == "$BACKUP_MOUNT" ]] && expected_mount="secondary"
[[ "$declared_disk" == "$expected_mount" ]] || fail "el manifiesto no coincide con el disco que lo contiene"
source_file="$(dirname "$marker")/$database_file"
verify_copy "$source_file" "$expected_size" "$expected_sha" "$expected_format" "$expected_raw_size" "$expected_raw_sha" "$(dirname "$marker")" || fail "la copia recibida no coincide en tamaño, SHA-256 o SQLite integrity_check"

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
old_name=""

cleanup() {
  local rc=$?
  rm -f -- "$tmp" "$manifest_tmp"
  if [[ $rc -ne 0 ]]; then
    if [[ "$had_previous" -eq 1 && -f "$previous" && -f "$previous_manifest" ]]; then
      local saved_meta saved_name
      saved_meta="$(manifest_fields "$previous_manifest" stable 2>/dev/null || true)"
      saved_name="$(cut -d'|' -f2 <<< "$saved_meta")"
      if [[ "$saved_name" == "$STABLE_NAME" ]]; then
        mv -f -- "$previous" "$stable"
      else
        rm -f -- "$previous" "$stable"
      fi
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
verify_copy "$tmp" "$expected_size" "$expected_sha" "$expected_format" "$expected_raw_size" "$expected_raw_sha" "$DEST_DIR" || fail "la copia temporal no pasó tamaño, hash e integridad"

if [[ -e "$manifest" ]]; then
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail "el manifiesto estable previo no es un archivo regular"
  old_meta="$(manifest_fields "$manifest" stable)" || fail "el manifiesto estable previo no es válido"
  IFS='|' read -r _ old_name old_size old_sha old_fmt old_raw_size old_raw_sha <<< "$old_meta"
  old_file="$DEST_DIR/$old_name"
  [[ -f "$old_file" && ! -L "$old_file" ]] || fail "falta la copia estable indicada por su manifiesto"
  verify_copy "$old_file" "$old_size" "$old_sha" "$old_fmt" "$old_raw_size" "$old_raw_sha" "$DEST_DIR" || fail "la copia estable previa no coincide con su manifiesto"
  if [[ "$old_name" != "$STABLE_NAME" && -e "$stable" ]]; then
    fail "hay una copia comprimida sin manifiesto estable; requiere revisión"
  fi
  [[ ! -e "$previous" ]] || fail "hay un respaldo de recuperación previo que requiere revisión"
  [[ ! -e "$previous_manifest" ]] || fail "hay un manifiesto de recuperación previo que requiere revisión"
  ln -- "$old_file" "$previous" || fail "no se pudo preservar la última copia válida"
  ln -- "$manifest" "$previous_manifest" || { rm -f -- "$previous"; fail "no se pudo preservar el manifiesto anterior"; }
  had_previous=1
elif [[ -e "$stable" || -e "$DEST_DIR/$LEGACY_STABLE_NAME" ]]; then
  fail "hay una copia estable sin manifiesto verificable; no se reemplazará"
fi

mv -f -- "$tmp" "$stable" || fail "no se pudo reemplazar atómicamente la copia estable"
installed_new=1
sync -f "$DEST_DIR" || fail "no se pudo sincronizar el directorio de destino"
python3 - "$manifest_tmp" "$expected_size" "$expected_sha" "$expected_raw_size" "$expected_raw_sha" "$declared_disk" "$marker" <<'PY'
import datetime, json, os, sys
path, size, sha, raw_size, raw_sha, disk, source_marker = sys.argv[1:]
obj = {
    "format": "perfume-sqlite-gzip-backup-v2",
    "database": "perfume-app.sqlite",
    "databaseFile": "perfume-app.sqlite.gz",
    "compression": "gzip",
    "sizeBytes": int(size),
    "uncompressedSizeBytes": int(raw_size),
    "sha256": sha,
    "uncompressedSha256": raw_sha,
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
if [[ "$old_name" == "$LEGACY_STABLE_NAME" ]]; then
  rm -f -- "$DEST_DIR/$LEGACY_STABLE_NAME"
  sync -f "$DEST_DIR"
fi

rm -f -- "$marker"
rm -f -- "$source_file"
sync -f "$(dirname "$marker")" || true
trap - EXIT INT TERM
log "OK: base validada y respaldada en $stable (origen $declared_disk)"
exit 0
