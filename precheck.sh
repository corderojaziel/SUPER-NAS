#!/bin/bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
fail(){ echo -e "${RED}✗${NC} $1"; exit 1; }
section(){ echo -e "\n${CYAN}${BOLD}$1${NC}"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/config/nas.conf"
CONFIG="${NAS_CONFIG_FILE:-${NAS_CONFIG:-$DEFAULT_CONFIG}}"
section "PRECHECK NAS"
[ "$EUID" -eq 0 ] || fail "Ejecutar como root: sudo ./precheck.sh"
[ -f "$CONFIG" ] || fail "No se encontró el archivo de configuración: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"
for v in DISK_PHOTOS DISK_BACKUP DB_PASSWORD; do [ -n "${!v:-}" ] || fail "$v no definido en $CONFIG"; done
for disk in "$DISK_PHOTOS" "$DISK_BACKUP"; do [ -b "$disk" ] && ok "Disco detectado: $disk" || fail "Disco no encontrado: $disk"; done
for cmd in docker ffmpeg rsync smartctl mergerfs nginx awk sed grep findmnt; do command -v "$cmd" >/dev/null 2>&1 && ok "Comando disponible: $cmd" || warn "Comando no disponible aún: $cmd"; done
for f in maintenance/mount-guard.sh maintenance/retry-quarantine.sh maintenance/night-run.sh maintenance/video-optimize.sh maintenance/backup.sh maintenance/smart-check.sh maintenance/post-upload-check.sh scripts/nas-alert.sh verify.sh; do [ -f "$SCRIPT_DIR/$f" ] && ok "Archivo presente: $f" || fail "Archivo faltante: $f"; done
for f in maintenance/mount-guard.sh maintenance/retry-quarantine.sh maintenance/night-run.sh maintenance/video-optimize.sh maintenance/backup.sh maintenance/smart-check.sh maintenance/post-upload-check.sh scripts/nas-alert.sh verify.sh install.sh; do [ -f "$SCRIPT_DIR/$f" ] && bash -n "$SCRIPT_DIR/$f" >/dev/null 2>&1 && ok "Sintaxis OK: $f" || fail "Error de sintaxis: $f"; done
mkdir -p /var/lib/nas-health /var/lib/nas-retry
ok "Precheck completado"
