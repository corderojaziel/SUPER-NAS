#!/usr/bin/env bash
# Secure receiver for the Windows perfume app database.
set -euo pipefail

PHOTOS_MOUNT="${PERFUME_DB_PHOTOS_MOUNT:-/mnt/storage-main}"
BACKUP_MOUNT="${PERFUME_DB_BACKUP_MOUNT:-/mnt/storage-backup}"
INBOX_SUFFIX="/perfume-db/incoming"
DATABASE_NAME="perfume-app.sqlite"
READY_NAME="perfume-app.ready.json"
MIN_FREE_BYTES="${PERFUME_DB_MIN_FREE_BYTES:-268435456}"

json_error() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"ok": False, "error": sys.argv[1]}, separators=(",", ":")))
PY
}

valid_id() { [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
valid_size() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
valid_sha() { [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; }

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

is_real_external_mount() {
  local mount="$1" root_source source
  [[ -d "$mount" && ! -L "$mount" ]] || return 1
  mountpoint -q "$mount" 2>/dev/null || return 1
  source="$(mount_source "$mount")" || return 1
  root_source="$(mount_source /)" || return 1
  [[ -n "$source" && "$source" != "$root_source" ]] || return 1
  case "$source" in /dev/sd*|/dev/nvme*) ;; *) return 1 ;; esac
  case "$source" in
    rootfs|overlay|tmpfs|ramfs|/dev/mmcblk*|/dev/root) return 1 ;;
  esac
  return 0
}

disk_free_bytes() {
  df -B1 --output=avail "$1" 2>/dev/null | tail -n 1 | tr -d ' '
}

prepare_disk() {
  local disk="$1" mount="$2" id="$3" size="$4"
  local incoming avail probe
  is_real_external_mount "$mount" || return 1
  incoming="$mount$INBOX_SUFFIX"
  [[ ! -L "$mount/perfume-db" && ! -L "$incoming" ]] || return 1
  mkdir -p "$incoming" || return 1
  safe_incoming_dir "$mount" || return 1
  avail="$(disk_free_bytes "$mount")"
  [[ "$avail" =~ ^[0-9]+$ ]] || return 1
  (( avail >= size + MIN_FREE_BYTES )) || return 1
  probe="$(mktemp "$incoming/.write-check.XXXXXX")" || return 1
  rm -f -- "$probe" || return 1
  printf '{"ok":true,"disk":"%s","stagingPath":"%s/.%s.%s.partial"}\n' \
    "$disk" "$incoming" "$DATABASE_NAME" "$id"
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

safe_mount_for_partial() {
  local partial="$1"
  if [[ "$partial" == "$PHOTOS_MOUNT$INBOX_SUFFIX/."* ]] && is_real_external_mount "$PHOTOS_MOUNT" && safe_incoming_dir "$PHOTOS_MOUNT"; then
    printf 'primary|%s\n' "$PHOTOS_MOUNT"
    return 0
  fi
  if [[ "$partial" == "$BACKUP_MOUNT$INBOX_SUFFIX/."* ]] && is_real_external_mount "$BACKUP_MOUNT" && safe_incoming_dir "$BACKUP_MOUNT"; then
    printf 'secondary|%s\n' "$BACKUP_MOUNT"
    return 0
  fi
  return 1
}

read_previous_file() {
  local ready="$1"
  python3 - "$ready" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    name = data.get("databaseFile", "")
    if re.fullmatch(r"perfume-app-[0-9a-f-]{36}\.sqlite", name):
        print(name)
except Exception:
    pass
PY
}

prepare() {
  local id="$1" size="$2" sha="$3" preference="${4:-auto}"
  valid_id "$id" && valid_size "$size" && valid_sha "$sha" || { json_error "parámetros inválidos"; return 2; }
  if [[ "$preference" == "secondary" ]]; then
    prepare_disk secondary "$BACKUP_MOUNT" "$id" "$size" && return 0
    json_error "disco secundario ausente, sin espacio o no escribible"
    return 2
  fi
  if prepare_disk primary "$PHOTOS_MOUNT" "$id" "$size"; then return 0; fi
  if prepare_disk secondary "$BACKUP_MOUNT" "$id" "$size"; then return 0; fi
  json_error "ni el disco principal ni el secundario están montados, tienen espacio suficiente y son escribibles"
  return 2
}

commit() {
  local id="$1" expected_size="$2" expected_sha="$3" partial
  valid_id "$id" && valid_size "$expected_size" && valid_sha "$expected_sha" || { json_error "parámetros inválidos"; return 2; }

  local photos_partial="$PHOTOS_MOUNT$INBOX_SUFFIX/.$DATABASE_NAME.$id.partial"
  local backup_partial="$BACKUP_MOUNT$INBOX_SUFFIX/.$DATABASE_NAME.$id.partial"
  if [[ -f "$photos_partial" ]] && is_real_external_mount "$PHOTOS_MOUNT"; then
    partial="$photos_partial"
  elif [[ -f "$backup_partial" ]] && is_real_external_mount "$BACKUP_MOUNT"; then
    partial="$backup_partial"
  else
    json_error "no se encontró el temporal en un disco externo montado"
    return 2
  fi

  local mount_info disk mount incoming actual_size actual_sha database_file ready ready_tmp previous_file
  mount_info="$(safe_mount_for_partial "$partial")" || { json_error "el disco destino dejó de estar montado"; return 2; }
  disk="${mount_info%%|*}"
  mount="${mount_info#*|}"
  incoming="$mount$INBOX_SUFFIX"
  actual_size="$(stat -c '%s' -- "$partial")"
  actual_sha="$(sha256sum -- "$partial" | awk '{print $1}')"
  [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]] || { json_error "tamaño o SHA-256 no coincide"; return 2; }
  sqlite_integrity_ok "$partial" || { json_error "SQLite integrity_check falló"; return 2; }

  database_file="perfume-app-$id.sqlite"
  ready="$incoming/$READY_NAME"
  ready_tmp="$incoming/.$READY_NAME.$id.partial"
  previous_file="$(read_previous_file "$ready")"
  mv -- "$partial" "$incoming/$database_file"
  sync -f "$incoming/$database_file"
  python3 - "$ready_tmp" "$database_file" "$disk" "$actual_size" "$actual_sha" <<'PY'
import datetime, json, os, sys
path, database, disk, size, sha = sys.argv[1:]
obj = {
    "format": "perfume-sqlite-backup-v1",
    "database": "perfume-app.sqlite",
    "databaseFile": database,
    "disk": disk,
    "sizeBytes": int(size),
    "sha256": sha,
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "x", encoding="utf-8") as f:
    json.dump(obj, f, separators=(",", ":"))
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
PY
  mv -f -- "$ready_tmp" "$ready"
  sync -f "$incoming"
  if [[ -n "$previous_file" && "$previous_file" != "$database_file" ]]; then
    rm -f -- "$incoming/$previous_file"
  fi
  printf '{"ok":true,"disk":"%s","sizeBytes":%s,"sha256":"%s"}\n' "$disk" "$actual_size" "$actual_sha"
}

abort_transfer() {
  local id="$1"
  valid_id "$id" || { json_error "id inválido"; return 2; }
  local mount incoming committed
  for mount in "$PHOTOS_MOUNT" "$BACKUP_MOUNT"; do
    if is_real_external_mount "$mount" && safe_incoming_dir "$mount"; then
      incoming="$mount$INBOX_SUFFIX"
      rm -f -- "$incoming/.$DATABASE_NAME.$id.partial" "$incoming/.$READY_NAME.$id.partial"
      committed="perfume-app-$id.sqlite"
      if [[ "$(read_previous_file "$incoming/$READY_NAME")" != "$committed" ]]; then
        rm -f -- "$incoming/$committed"
      fi
    fi
  done
  printf '{"ok":true}\n'
}

case "${1:-}" in
  prepare)
    [[ $# -ge 4 && $# -le 5 ]] || { json_error "uso inválido de prepare"; exit 2; }
    prepare "$2" "$3" "$4" "${5:-auto}"
    ;;
  commit)
    [[ $# -eq 4 ]] || { json_error "uso inválido de commit"; exit 2; }
    commit "$2" "$3" "$4"
    ;;
  abort)
    [[ $# -eq 2 ]] || { json_error "uso inválido de abort"; exit 2; }
    abort_transfer "$2"
    ;;
  *)
    json_error "comando inválido"
    exit 2
    ;;
esac
