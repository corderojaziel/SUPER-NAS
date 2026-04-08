#!/bin/bash
# Backup rapido de estado operativo (config + DB + opcional cache).

set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/storage-backup/snapshots/system-state}"
INCLUDE_CACHE="${INCLUDE_CACHE:-0}"
CACHE_ROOT="${CACHE_ROOT:-/var/lib/immich/cache}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
SECRETS_FILE="${SECRETS_FILE:-/etc/nas-secrets}"
ENV_FILE="${ENV_FILE:-/opt/immich-app/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/immich-app/docker-compose.yml}"
POLICY_FILE="${POLICY_FILE:-/etc/default/nas-video-policy}"
CLOUD_POLICY_FILE="${CLOUD_POLICY_FILE:-/etc/default/nas-cloud-backup}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/root/.config/rclone/rclone.conf}"
DB_CLOUD_UPLOAD_BIN="${DB_CLOUD_UPLOAD_BIN:-/usr/local/bin/cloud-db-upload.sh}"
RESOLVER_SERVICE_FILE="${RESOLVER_SERVICE_FILE:-/etc/systemd/system/immich-video-playback-resolver.service}"

db_value() {
  local key="$1" default="$2" value=""
  if [ -f "$ENV_FILE" ]; then
    value=$(awk -F= -v key="$key" '$1==key{print substr($0, index($0, "=")+1); exit}' "$ENV_FILE")
  fi
  [ -n "$value" ] || value="$default"
  printf '%s\n' "$value"
}

alert() {
  [ -x "$NAS_ALERT_BIN" ] || return 0
  "$NAS_ALERT_BIN" "$1" || true
}

[ -f "$CLOUD_POLICY_FILE" ] && . "$CLOUD_POLICY_FILE"

ts="$(date +%Y%m%d-%H%M%S)"
snap_dir="$BACKUP_ROOT/$ts"
mkdir -p "$snap_dir"/{db,config,inventory,cache}

echo "[$(date '+%F %T')] BACKUP_START dir=$snap_dir"

# Archivos clave de configuracion
for src in \
  "$ENV_FILE" \
  "$COMPOSE_FILE" \
  "$POLICY_FILE" \
  "$CLOUD_POLICY_FILE" \
  /etc/nas-disks \
  /etc/nas-retention \
  /etc/nas-mounts \
  /etc/fstab \
  /etc/nginx/sites-enabled/immich.conf \
  /etc/crontab \
  /etc/logrotate.d/supernas \
  "$RESOLVER_SERVICE_FILE" \
  /etc/udev/rules.d/80-usb-read-ahead.rules \
  /etc/sysctl.d/99-nas.conf \
  /etc/systemd/journald.conf.d/nas.conf; do
  if [ -f "$src" ]; then
    cp -a "$src" "$snap_dir/config/"
  fi
done
crontab -l > "$snap_dir/config/root-crontab" 2>/dev/null || true
if [ -f "$SECRETS_FILE" ]; then
  cp -a "$SECRETS_FILE" "$snap_dir/config/"
  chmod 600 "$snap_dir/config/$(basename "$SECRETS_FILE")" || true
fi
if [ -f "$RCLONE_CONFIG_FILE" ]; then
  cp -a "$RCLONE_CONFIG_FILE" "$snap_dir/config/rclone.conf"
  chmod 600 "$snap_dir/config/rclone.conf" || true
fi

# Inventario rapido para diagnostico
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT > "$snap_dir/inventory/lsblk.txt" || true
df -h > "$snap_dir/inventory/df.txt" || true
mount > "$snap_dir/inventory/mount.txt" || true
crontab -l > "$snap_dir/inventory/crontab.txt" 2>/dev/null || true
$DOCKER_BIN ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' > "$snap_dir/inventory/docker-ps.txt" || true
find /var/lib/nas-health -maxdepth 1 -type f -name '*.env' -o -name '*.json' -o -name '*.csv' 2>/dev/null \
  | sort > "$snap_dir/inventory/health-files.txt" || true
for svc in docker tailscaled smbd immich-video-playback-resolver; do
  systemctl is-enabled "$svc" > "$snap_dir/inventory/systemctl-${svc}-enabled.txt" 2>&1 || true
  systemctl is-active "$svc" > "$snap_dir/inventory/systemctl-${svc}-active.txt" 2>&1 || true
done

# Dump logico DB (seguro para restaurar en otro equipo)
DB_USER="$(db_value DB_USERNAME immich)"
db_dump="$snap_dir/db/immich-db.sql.gz"
CLOUD_DB_UPLOAD_STATUS="SKIPPED"
CLOUD_DB_REMOTE_PATH=""
if timeout 25m bash -lc "set -o pipefail; $DOCKER_BIN exec immich_postgres pg_dumpall --clean --if-exists --username='$DB_USER' | gzip > '$db_dump'"; then
  if [ -x "$DB_CLOUD_UPLOAD_BIN" ]; then
    set +e
    cloud_out="$("$DB_CLOUD_UPLOAD_BIN" "$db_dump" state-backup 2>&1)"
    cloud_rc=$?
    set -e
    case "$cloud_rc" in
      0)
        CLOUD_DB_UPLOAD_STATUS="OK"
        CLOUD_DB_REMOTE_PATH="$cloud_out"
        ;;
      2)
        CLOUD_DB_UPLOAD_STATUS="SKIPPED"
        ;;
      *)
        CLOUD_DB_UPLOAD_STATUS="FAIL"
        echo "WARN: no pude subir dump de DB a Google Drive: $cloud_out" >&2
        ;;
    esac
  fi
else
  rm -f "$db_dump"
  echo "WARN: no pude generar dump de DB" >&2
  CLOUD_DB_UPLOAD_STATUS="SKIPPED"
fi

# Opcional: cache completo (puede pesar mucho)
if [ "$INCLUDE_CACHE" = "1" ] && [ -d "$CACHE_ROOT" ]; then
  tar -C "$CACHE_ROOT" -czf "$snap_dir/cache/cache.tar.gz" . || true
fi

# Metadatos de respaldo
{
  echo "timestamp=$ts"
  echo "snapshot_dir=$snap_dir"
  echo "include_cache=$INCLUDE_CACHE"
  echo "db_dump=$( [ -f "$db_dump" ] && echo yes || echo no )"
  echo "cloud_db_upload_status=$CLOUD_DB_UPLOAD_STATUS"
  echo "cloud_db_remote_path=$CLOUD_DB_REMOTE_PATH"
  echo "rclone_config=$( [ -f "$snap_dir/config/rclone.conf" ] && echo yes || echo no )"
  echo "cache_archive=$( [ -f "$snap_dir/cache/cache.tar.gz" ] && echo yes || echo no )"
  echo "root_crontab=$( [ -s "$snap_dir/config/root-crontab" ] && echo yes || echo no )"
} > "$snap_dir/manifest.env"

ln -sfn "$snap_dir" "$BACKUP_ROOT/latest"

alert "🧰 Backup de estado NAS creado
Ruta: $snap_dir
Incluye DB: $( [ -f "$db_dump" ] && echo sí || echo no )
DB en Google Drive: $CLOUD_DB_UPLOAD_STATUS
Incluye cache completo: $( [ -f "$snap_dir/cache/cache.tar.gz" ] && echo sí || echo no )"

echo "[$(date '+%F %T')] BACKUP_DONE dir=$snap_dir"
echo "$snap_dir"
