#!/bin/bash
# Sube el dump lógico de Immich a una ruta fija de Google Drive usando rclone.
# El archivo remoto es siempre el mismo para evitar acumulación de respaldos.

set -Eeuo pipefail

POLICY_FILE="${POLICY_FILE:-/etc/default/nas-cloud-backup}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
HEALTH_DIR="${HEALTH_DIR:-/var/lib/nas-health}"
STATE_FILE="${STATE_FILE:-$HEALTH_DIR/cloud-db-upload.env}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/root/.config/rclone/rclone.conf}"
CLOUD_DB_UPLOAD_ENABLED="${CLOUD_DB_UPLOAD_ENABLED:-1}"
CLOUD_DB_UPLOAD_REMOTE="${CLOUD_DB_UPLOAD_REMOTE:-gdrive-supernas}"
CLOUD_DB_UPLOAD_REMOTE_DIR="${CLOUD_DB_UPLOAD_REMOTE_DIR:-SUPER-NAS}"
CLOUD_DB_UPLOAD_REMOTE_FILE="${CLOUD_DB_UPLOAD_REMOTE_FILE:-immich-db-latest.sql.gz}"
CLOUD_DB_NOTIFY_SUCCESS="${CLOUD_DB_NOTIFY_SUCCESS:-0}"
CLOUD_DB_ALERT_TTL_SEC="${CLOUD_DB_ALERT_TTL_SEC:-43200}"
CLOUD_DB_UPLOAD_MAX_SECONDS="${CLOUD_DB_UPLOAD_MAX_SECONDS:-600}"

LOCAL_FILE="${1:-}"
UPLOAD_CONTEXT="${2:-nightly}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trim_slashes() {
  printf '%s' "${1:-}" | sed 's#^/*##; s#/*$##'
}

alert_once() {
  local key_suffix="$1"
  local message="$2"
  [ -x "$NAS_ALERT_BIN" ] || return 0
  NAS_ALERT_KEY="cloud-db-upload:${UPLOAD_CONTEXT}:${key_suffix}" \
  NAS_ALERT_TTL="$CLOUD_DB_ALERT_TTL_SEC" \
    "$NAS_ALERT_BIN" "$message" || true
}

write_state() {
  local status="$1"
  local detail="$2"
  local remote_path="$3"
  mkdir -p "$HEALTH_DIR"
  cat > "$STATE_FILE" <<EOF
CLOUD_DB_UPLOAD_STATUS=$status
CLOUD_DB_UPLOAD_DETAIL=$(printf '%s' "$detail" | tr '\n' ' ' | tr -d '\r')
CLOUD_DB_UPLOAD_REMOTE_PATH=$remote_path
CLOUD_DB_UPLOAD_LOCAL_FILE=$LOCAL_FILE
CLOUD_DB_UPLOAD_CONTEXT=$UPLOAD_CONTEXT
CLOUD_DB_UPLOAD_TS=$(date -Iseconds)
EOF
}

if [ -f "$POLICY_FILE" ]; then
  . "$POLICY_FILE"
fi

# Un único presupuesto para toda la operación, incluidos los reintentos internos.
if [ "${CLOUD_DB_UPLOAD_BOUNDED_WORKER:-0}" != "1" ]; then
  case "$CLOUD_DB_UPLOAD_MAX_SECONDS" in
    ''|*[!0-9]*|0) echo "CLOUD_DB_UPLOAD_MAX_SECONDS debe ser un entero positivo" >&2; exit 1 ;;
  esac
  rc=0
  timeout --kill-after=10s "${CLOUD_DB_UPLOAD_MAX_SECONDS}s" \
    env CLOUD_DB_UPLOAD_BOUNDED_WORKER=1 bash "$0" "$@" || rc=$?
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    write_state "FAIL" "upload-timeout" ""
    echo "Respaldo cloud cancelado al alcanzar ${CLOUD_DB_UPLOAD_MAX_SECONDS}s; siguiente intento en la próxima ejecución nocturna." >&2
  fi
  exit "$rc"
fi

on_upload_error() {
  local rc=$?
  trap - ERR
  write_state "FAIL" "upload-error-rc-$rc" "${REMOTE_FILE_SPEC:-}"
  exit "$rc"
}
trap on_upload_error ERR

rclone_run() {
  "$RCLONE_BIN" "$@" --retries 2 --low-level-retries 3 \
    --retries-sleep 10s --contimeout 10s --timeout 60s
}

if [ -z "$LOCAL_FILE" ]; then
  write_state "FAIL" "missing-local-file-argument" ""
  echo "Uso: $0 /ruta/al/dump.sql.gz [contexto]" >&2
  exit 1
fi

if [ ! -f "$LOCAL_FILE" ]; then
  write_state "FAIL" "local-file-not-found" ""
  alert_once "missing-local-file" "⚠️ Respaldo DB cloud falló
No encontré el dump local para subir a Google Drive.
Archivo esperado: $LOCAL_FILE
Contexto: $UPLOAD_CONTEXT"
  exit 1
fi

if ! is_true "$CLOUD_DB_UPLOAD_ENABLED"; then
  write_state "SKIPPED" "disabled-by-policy" ""
  exit 2
fi

if [ ! -x "$RCLONE_BIN" ]; then
  write_state "FAIL" "missing-rclone" ""
  alert_once "missing-rclone" "⚠️ Respaldo DB cloud no configurado
Falta rclone en la TV Box.
Contexto: $UPLOAD_CONTEXT"
  exit 1
fi

if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
  write_state "FAIL" "missing-rclone-config" ""
  alert_once "missing-rclone-config" "⚠️ Respaldo DB cloud no configurado
No encontré la configuración de rclone.
Ruta esperada: $RCLONE_CONFIG_FILE
Contexto: $UPLOAD_CONTEXT"
  exit 1
fi

if ! rclone_run listremotes --config "$RCLONE_CONFIG_FILE" 2>/dev/null | grep -Fxq "${CLOUD_DB_UPLOAD_REMOTE}:"; then
  write_state "FAIL" "missing-remote" ""
  alert_once "missing-remote" "⚠️ Respaldo DB cloud no configurado
No existe el remoto de rclone '${CLOUD_DB_UPLOAD_REMOTE}:'.
Contexto: $UPLOAD_CONTEXT"
  exit 1
fi

REMOTE_DIR="$(trim_slashes "$CLOUD_DB_UPLOAD_REMOTE_DIR")"
REMOTE_FILE="$(basename "$CLOUD_DB_UPLOAD_REMOTE_FILE")"
REMOTE_DIR_SPEC="${CLOUD_DB_UPLOAD_REMOTE}:"
REMOTE_FILE_SPEC="${CLOUD_DB_UPLOAD_REMOTE}:$REMOTE_FILE"
if [ -n "$REMOTE_DIR" ]; then
  REMOTE_DIR_SPEC="${CLOUD_DB_UPLOAD_REMOTE}:$REMOTE_DIR"
  REMOTE_FILE_SPEC="${REMOTE_DIR_SPEC}/$REMOTE_FILE"
fi

LOCAL_SIZE="$(stat -c '%s' "$LOCAL_FILE")"

rclone_run mkdir "$REMOTE_DIR_SPEC" --config "$RCLONE_CONFIG_FILE" >/dev/null

# Antes de subir, limpia cualquier copia visible del mismo nombre para que quede
# exactamente un archivo remoto "latest" y no se acumulen dumps históricos.
rclone_run delete "$REMOTE_DIR_SPEC" \
  --config "$RCLONE_CONFIG_FILE" \
  --include "$REMOTE_FILE" >/dev/null 2>&1 || true

rclone_run copyto "$LOCAL_FILE" "$REMOTE_FILE_SPEC" \
  --config "$RCLONE_CONFIG_FILE" >/dev/null

REMOTE_INFO="$(rclone_run ls "$REMOTE_DIR_SPEC" --config "$RCLONE_CONFIG_FILE" 2>/dev/null \
  | awk -v name="$REMOTE_FILE" '$2==name {count++; size=$1} END {printf "%d:%s", count+0, size+0}')"
REMOTE_COUNT="${REMOTE_INFO%%:*}"
REMOTE_SIZE="${REMOTE_INFO#*:}"

if [ "$REMOTE_COUNT" != "1" ] || [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
  write_state "FAIL" "remote-verification-failed" "$REMOTE_FILE_SPEC"
  alert_once "verification-failed" "⚠️ Respaldo DB cloud falló
Subí el dump, pero la verificación remota no coincidió.
Local: $LOCAL_SIZE bytes
Remoto: ${REMOTE_SIZE:-0} bytes
Ruta remota: $REMOTE_FILE_SPEC
Contexto: $UPLOAD_CONTEXT"
  exit 1
fi

write_state "OK" "uploaded" "$REMOTE_FILE_SPEC"

if is_true "$CLOUD_DB_NOTIFY_SUCCESS"; then
  alert_once "success-${UPLOAD_CONTEXT}-$(date +%F)" "☁️ Respaldo DB subido a Google Drive
Archivo remoto: $REMOTE_FILE_SPEC
Tamaño: $LOCAL_SIZE bytes
Contexto: $UPLOAD_CONTEXT"
fi

printf '%s\n' "$REMOTE_FILE_SPEC"
