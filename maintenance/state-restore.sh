#!/bin/bash
# Restaura configuracion/DB desde un snapshot generado por state-backup.sh
#
# Uso:
#   /usr/local/bin/state-restore.sh /mnt/storage-backup/snapshots/system-state/20260328-010101 --with-db --with-cache
#   /usr/local/bin/state-restore.sh latest --with-db

set -euo pipefail

SNAP_INPUT="${1:-latest}"
WITH_DB=0
WITH_CACHE=0

for arg in "${@:2}"; do
  case "$arg" in
    --with-db) WITH_DB=1 ;;
    --with-cache) WITH_CACHE=1 ;;
    *) echo "Argumento no reconocido: $arg" >&2; exit 2 ;;
  esac
done

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/storage-backup/snapshots/system-state}"
DB_BACKUP_ROOT="${DB_BACKUP_ROOT:-/mnt/storage-backup/snapshots/immich-db}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/immich-app}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
ENV_FILE="${ENV_FILE:-/opt/immich-app/.env}"
SECRETS_FILE="${SECRETS_FILE:-/etc/nas-secrets}"
CACHE_ROOT="${CACHE_ROOT:-/var/lib/immich/cache}"

alert() {
  [ -x "$NAS_ALERT_BIN" ] || return 0
  "$NAS_ALERT_BIN" "$1" || true
}

if [ "$SNAP_INPUT" = "latest" ]; then
  SNAP_DIR="$(readlink -f "$BACKUP_ROOT/latest" 2>/dev/null || true)"
else
  SNAP_DIR="$SNAP_INPUT"
fi

[ -n "${SNAP_DIR:-}" ] || { echo "No se pudo resolver snapshot" >&2; exit 1; }
[ -d "$SNAP_DIR" ] || { echo "Snapshot no existe: $SNAP_DIR" >&2; exit 1; }

echo "[$(date '+%F %T')] RESTORE_START snapshot=$SNAP_DIR with_db=$WITH_DB with_cache=$WITH_CACHE"

# Restaurar configuraciones base
for item in .env docker-compose.yml; do
  src="$SNAP_DIR/config/$item"
  if [ -f "$src" ]; then
    cp -a "$src" "$COMPOSE_DIR/$item"
  fi
done
if [ -f "$SNAP_DIR/config/nas-video-policy" ]; then
  cp -a "$SNAP_DIR/config/nas-video-policy" /etc/default/nas-video-policy
fi
if [ -f "$SNAP_DIR/config/nas-disks" ]; then
  cp -a "$SNAP_DIR/config/nas-disks" /etc/nas-disks
fi
if [ -f "$SNAP_DIR/config/nas-retention" ]; then
  cp -a "$SNAP_DIR/config/nas-retention" /etc/nas-retention
fi
if [ -f "$SNAP_DIR/config/nas-mounts" ]; then
  cp -a "$SNAP_DIR/config/nas-mounts" /etc/nas-mounts
fi
if [ -f "$SNAP_DIR/config/fstab" ]; then
  cp -a "$SNAP_DIR/config/fstab" /etc/fstab
fi
if [ -f "$SNAP_DIR/config/nas-secrets" ]; then
  cp -a "$SNAP_DIR/config/nas-secrets" "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE" || true
fi
if [ -f "$SNAP_DIR/config/immich.conf" ]; then
  cp -a "$SNAP_DIR/config/immich.conf" /etc/nginx/sites-enabled/immich.conf
  nginx -t >/dev/null 2>&1 && systemctl restart nginx || true
fi
if [ -f "$SNAP_DIR/config/crontab" ]; then
  cp -a "$SNAP_DIR/config/crontab" /etc/crontab
fi
if [ -f "$SNAP_DIR/config/supernas" ]; then
  cp -a "$SNAP_DIR/config/supernas" /etc/logrotate.d/supernas
fi
if [ -f "$SNAP_DIR/config/immich-video-playback-resolver.service" ]; then
  cp -a "$SNAP_DIR/config/immich-video-playback-resolver.service" /etc/systemd/system/immich-video-playback-resolver.service
fi
if [ -f "$SNAP_DIR/config/80-usb-read-ahead.rules" ]; then
  cp -a "$SNAP_DIR/config/80-usb-read-ahead.rules" /etc/udev/rules.d/80-usb-read-ahead.rules
fi
if [ -f "$SNAP_DIR/config/99-nas.conf" ]; then
  cp -a "$SNAP_DIR/config/99-nas.conf" /etc/sysctl.d/99-nas.conf
  sysctl --system >/dev/null 2>&1 || true
fi
if [ -f "$SNAP_DIR/config/nas.conf" ]; then
  cp -a "$SNAP_DIR/config/nas.conf" /etc/systemd/journald.conf.d/nas.conf
  systemctl restart systemd-journald >/dev/null 2>&1 || true
fi
if [ -s "$SNAP_DIR/config/root-crontab" ]; then
  crontab "$SNAP_DIR/config/root-crontab" || true
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable immich-video-playback-resolver >/dev/null 2>&1 || true
systemctl restart immich-video-playback-resolver >/dev/null 2>&1 || true
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger >/dev/null 2>&1 || true
mount -a >/dev/null 2>&1 || true

# Reiniciar stack para tomar .env/docker-compose restaurados
(cd "$COMPOSE_DIR" && docker compose up -d) >/dev/null 2>&1 || true

if [ "$WITH_DB" = "1" ]; then
  db_dump="$SNAP_DIR/db/immich-db.sql.gz"
  if [ ! -f "$db_dump" ] && [ -d "$DB_BACKUP_ROOT" ]; then
    db_dump="$(ls -1t "$DB_BACKUP_ROOT"/immich-db-*.sql.gz 2>/dev/null | head -1 || true)"
  fi
  if [ -f "$db_dump" ]; then
    DB_USER="$(awk -F= '$1=="DB_USERNAME"{print substr($0, index($0, "=")+1); exit}' "$ENV_FILE" 2>/dev/null || true)"
    [ -n "$DB_USER" ] || DB_USER="immich"
    if timeout 40m bash -lc "set -o pipefail; gunzip -c '$db_dump' | $DOCKER_BIN exec -i immich_postgres psql -U '$DB_USER' postgres"; then
      echo "DB restore OK"
    else
      echo "WARN: DB restore fallo" >&2
      alert "⚠️ Restauración: falló la base de datos
Snapshot: $SNAP_DIR
Acción: revisar logs y relanzar state-restore con --with-db."
      exit 1
    fi
  else
    echo "WARN: snapshot sin DB dump ($db_dump)" >&2
  fi
fi

if [ "$WITH_CACHE" = "1" ]; then
  cache_archive="$SNAP_DIR/cache/cache.tar.gz"
  if [ -f "$cache_archive" ]; then
    mkdir -p "$CACHE_ROOT"
    tar -C "$CACHE_ROOT" -xzf "$cache_archive"
  else
    echo "WARN: snapshot sin cache.tar.gz" >&2
  fi
fi

(cd "$COMPOSE_DIR" && docker compose restart immich-server) >/dev/null 2>&1 || true

alert "♻️ Restauración aplicada
Snapshot: $SNAP_DIR
DB restaurada: $( [ "$WITH_DB" = "1" ] && echo sí || echo no )
Cache restaurada: $( [ "$WITH_CACHE" = "1" ] && echo sí || echo no )
Siguiente paso recomendado: /usr/local/bin/verify.sh"

echo "[$(date '+%F %T')] RESTORE_DONE snapshot=$SNAP_DIR"
