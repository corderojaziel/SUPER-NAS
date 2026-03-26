#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="${WSL_LAB_DIR:-/var/tmp/nas-test-disks}"
CONFIG_OUT="${WSL_LAB_CONFIG:-$REPO_ROOT/config/nas.wsl.generated.conf}"

umount_if_needed() {
    local target="$1"
    mountpoint -q "$target" 2>/dev/null && umount "$target" 2>/dev/null || true
}

detach_loop_if_any() {
    local img="$1" dev
    dev="$(losetup -j "$img" | awk -F: 'NR==1{print $1}')"
    [ -n "$dev" ] && losetup -d "$dev" 2>/dev/null || true
}

clean_lab_fstab_entries() {
    local tmp
    tmp="$(mktemp)"
    awk '
        $1 ~ /^#/ { print; next }
        $2=="/mnt/storage-main" { next }
        $2=="/mnt/storage-backup" { next }
        $2=="/mnt/merged" { next }
        { print }
    ' /etc/fstab > "$tmp"
    cat "$tmp" > /etc/fstab
    rm -f "$tmp"
}

[ "$EUID" -eq 0 ] || { echo "ERROR: ejecuta con sudo." >&2; exit 1; }

umount_if_needed /mnt/merged
umount_if_needed /mnt/storage-backup
umount_if_needed /mnt/storage-main

find /mnt/merged -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

rm -rf /opt/immich-app 2>/dev/null || true
rm -rf /var/lib/immich/db /var/lib/immich/models /var/lib/immich/thumbs /var/lib/immich/encoded-video /var/lib/immich/nginx-cache /var/lib/immich/profile /var/lib/immich/cache /var/lib/immich/static 2>/dev/null || true
mkdir -p /var/lib/immich /var/lib/nas-health /var/lib/nas-retry
find /var/lib/nas-health -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /var/lib/nas-retry -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

detach_loop_if_any "$LAB_DIR/photos.img"
detach_loop_if_any "$LAB_DIR/backup.img"
clean_lab_fstab_entries

rm -f "$CONFIG_OUT"

echo "Laboratorio WSL desmontado. Las imagenes siguen en $LAB_DIR."
