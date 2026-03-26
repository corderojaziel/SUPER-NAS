#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="${WSL_LAB_DIR:-/var/tmp/nas-test-disks}"
PHOTOS_IMG="$LAB_DIR/photos.img"
BACKUP_IMG="$LAB_DIR/backup.img"
PHOTOS_SIZE="${WSL_PHOTOS_SIZE:-12G}"
BACKUP_SIZE="${WSL_BACKUP_SIZE:-8G}"
CONFIG_OUT="${WSL_LAB_CONFIG:-$REPO_ROOT/config/nas.wsl.generated.conf}"
DB_PASSWORD="${WSL_DB_PASSWORD:-WslLab2026}"
TIMEZONE_VALUE="${WSL_TIMEZONE:-America/Mexico_City}"
CACHE_WARN_GB="${WSL_CACHE_WARN_GB:-2}"
CACHE_CRIT_GB="${WSL_CACHE_CRIT_GB:-4}"
BACKUP_RETENTION_DAYS="${WSL_BACKUP_RETENTION_DAYS:-3}"

log() { printf '%s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Ejecuta este script con sudo en Ubuntu WSL."
command -v losetup >/dev/null 2>&1 || die "Falta losetup (paquete util-linux)."
command -v truncate >/dev/null 2>&1 || die "Falta truncate (paquete coreutils)."

mkdir -p "$LAB_DIR"

create_or_reuse_image() {
    local img="$1" size="$2"
    if [ ! -f "$img" ]; then
        truncate -s "$size" "$img"
        log "Imagen creada: $img ($size)"
    else
        log "Imagen reutilizada: $img"
    fi
}

ensure_loop() {
    local img="$1" dev
    dev="$(losetup -j "$img" | awk -F: 'NR==1{print $1}')"
    if [ -n "$dev" ]; then
        printf '%s\n' "$dev"
        return 0
    fi
    losetup -f --show "$img"
}

create_or_reuse_image "$PHOTOS_IMG" "$PHOTOS_SIZE"
create_or_reuse_image "$BACKUP_IMG" "$BACKUP_SIZE"

PHOTO_DEV="$(ensure_loop "$PHOTOS_IMG")"
BACKUP_DEV="$(ensure_loop "$BACKUP_IMG")"

cat > "$CONFIG_OUT" <<EOF
# Perfil generado para laboratorio WSL
DISK_PHOTOS="$PHOTO_DEV"
DISK_BACKUP="$BACKUP_DEV"

MOUNT_PHOTOS="/mnt/storage-main"
MOUNT_BACKUP="/mnt/storage-backup"
MOUNT_MERGED="/mnt/merged"
EMMC_IMMICH="/var/lib/immich"

DB_PASSWORD="$DB_PASSWORD"
TIMEZONE="$TIMEZONE_VALUE"

TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

CACHE_WARN_GB=$CACHE_WARN_GB
CACHE_CRIT_GB=$CACHE_CRIT_GB
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
ALLOW_FORMAT=yes
EOF

log ""
log "Perfil WSL generado: $CONFIG_OUT"
log "Disco fotos:  $PHOTO_DEV ($PHOTOS_IMG)"
log "Disco backup: $BACKUP_DEV ($BACKUP_IMG)"
log ""
log "Siguiente paso:"
log "  sudo NAS_CONFIG_FILE=$CONFIG_OUT bash $REPO_ROOT/install.sh"

