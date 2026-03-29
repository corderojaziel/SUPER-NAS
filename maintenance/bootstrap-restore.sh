#!/bin/bash
# bootstrap-restore.sh — Recuperación completa desde OS limpio.
#
# Hace dos fases:
#   1) install.sh en modo restore (sin formatear discos)
#   2) disaster-restore.sh (config + DB + cache)
#
# Uso:
#   bash maintenance/bootstrap-restore.sh --repo /root/proyecto --snapshot latest
#   bash maintenance/bootstrap-restore.sh --repo /root/proyecto --snapshot latest --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_DIR="$REPO_DEFAULT"
CONFIG_FILE=""
SNAPSHOT="latest"
WITH_CACHE_ARCHIVE=0
REBUILD_CACHE_LIGHT=0
SKIP_VERIFY=0
DRY_RUN=0
LOG_FILE="/var/log/bootstrap-restore.log"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO_DIR="${1:-}";;
    --config) shift; CONFIG_FILE="${1:-}";;
    --snapshot) shift; SNAPSHOT="${1:-latest}";;
    --with-cache-archive) WITH_CACHE_ARCHIVE=1 ;;
    --rebuild-cache-light) REBUILD_CACHE_LIGHT=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      echo "Uso: $0 [--repo DIR] [--config FILE] [--snapshot latest|DIR] [--with-cache-archive] [--rebuild-cache-light] [--skip-verify] [--dry-run]"
      exit 0
      ;;
    *) echo "Argumento no reconocido: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$EUID" -eq 0 ] || { echo "Ejecuta como root."; exit 1; }

INSTALL_SCRIPT="$REPO_DIR/install.sh"
DISASTER_SCRIPT_REPO="$REPO_DIR/maintenance/disaster-restore.sh"
DISASTER_SCRIPT_SYS="/usr/local/bin/disaster-restore.sh"

[ -f "$INSTALL_SCRIPT" ] || { echo "No encuentro install.sh en $INSTALL_SCRIPT" >&2; exit 1; }
[ -f "$DISASTER_SCRIPT_REPO" ] || { echo "No encuentro disaster-restore.sh en $DISASTER_SCRIPT_REPO" >&2; exit 1; }
[ -n "$CONFIG_FILE" ] || CONFIG_FILE="$REPO_DIR/config/nas.conf"
[ -f "$CONFIG_FILE" ] || { echo "No encuentro config: $CONFIG_FILE" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}

alert() {
  [ -x "$NAS_ALERT_BIN" ] || return 0
  "$NAS_ALERT_BIN" "$1" || true
}

build_disaster_args() {
  local args=("$SNAPSHOT")
  [ "$WITH_CACHE_ARCHIVE" = "1" ] && args+=("--with-cache-archive")
  [ "$REBUILD_CACHE_LIGHT" = "1" ] && args+=("--rebuild-cache-light")
  [ "$SKIP_VERIFY" = "1" ] && args+=("--skip-verify")
  [ "$DRY_RUN" = "1" ] && args+=("--dry-run")
  printf '%s\n' "${args[@]}"
}

log "BOOTSTRAP_RESTORE_START repo=$REPO_DIR snapshot=$SNAPSHOT dry_run=$DRY_RUN"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN: no se ejecutará install ni restauración real."
  log "DRY-RUN: validaría install.sh con INSTALL_MODE=restore e INSTALL_ASSUME_YES=1"
  log "DRY-RUN: luego correría disaster-restore con snapshot=$SNAPSHOT"

  mapfile -t DR_ARGS < <(build_disaster_args)
  if [ -x "$DISASTER_SCRIPT_SYS" ]; then
    "$DISASTER_SCRIPT_SYS" "${DR_ARGS[@]}" || true
  else
    bash "$DISASTER_SCRIPT_REPO" "${DR_ARGS[@]}" || true
  fi
  log "BOOTSTRAP_RESTORE_DRY_RUN_DONE"
  exit 0
fi

alert "🧩 Inicio restore bootstrap
Fase 1: instalación base en modo restauración.
Fase 2: recuperación integral desde snapshot."

INSTALL_ENV=(INSTALL_MODE=restore INSTALL_ASSUME_YES=1 NAS_CONFIG_FILE="$CONFIG_FILE")
(
  cd "$REPO_DIR"
  env "${INSTALL_ENV[@]}" bash "$INSTALL_SCRIPT"
)

if [ -f "$DISASTER_SCRIPT_REPO" ]; then
  install -m 0755 "$DISASTER_SCRIPT_REPO" /usr/local/bin/disaster-restore.sh
fi

mapfile -t DR_ARGS < <(build_disaster_args)
/usr/local/bin/disaster-restore.sh "${DR_ARGS[@]}"

alert "✅ Restore bootstrap completado
Caja base instalada y restauración aplicada.
Snapshot: $SNAPSHOT"
log "BOOTSTRAP_RESTORE_DONE snapshot=$SNAPSHOT"
