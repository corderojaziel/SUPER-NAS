#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_OUT="${WSL_LAB_CONFIG:-$REPO_ROOT/config/nas.wsl.generated.conf}"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Ejecuta este script con sudo en Ubuntu WSL."

if [ ! -d /run/systemd/system ]; then
    die "Esta Ubuntu WSL no tiene systemd activo. Activalo en /etc/wsl.conf antes de correr el laboratorio."
fi

"$SCRIPT_DIR/wsl-lab-prepare.sh"

[ -f "$CONFIG_OUT" ] || die "No se genero el perfil WSL: $CONFIG_OUT"

DISK_PHOTOS="$(awk -F= '$1=="DISK_PHOTOS"{gsub(/"/,"",$2); print $2; exit}' "$CONFIG_OUT")"
DISK_BACKUP="$(awk -F= '$1=="DISK_BACKUP"{gsub(/"/,"",$2); print $2; exit}' "$CONFIG_OUT")"

[ -n "$DISK_PHOTOS" ] || die "DISK_PHOTOS vacio en $CONFIG_OUT"
[ -n "$DISK_BACKUP" ] || die "DISK_BACKUP vacio en $CONFIG_OUT"

TOKEN="BORRAR-$(basename "$DISK_PHOTOS")-$(basename "$DISK_BACKUP")"

printf 'si\n%s\n' "$TOKEN" | NAS_CONFIG_FILE="$CONFIG_OUT" bash "$REPO_ROOT/install.sh"

