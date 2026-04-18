#!/bin/bash
# emmc-safe-monthly.sh — Limpieza segura de eMMC (ejecución semanal)
#
# Alcance:
# - Solo mantenimiento técnico (sin tocar biblioteca ni cache de playback).
# - Huérfanos de paquetes APT.
# - Artefactos de instaladores en /root, /tmp, /var/tmp (patrones permitidos).
# - Históricos de reproceso (/var/lib/nas-health/reprocess) conservando *latest*.

set -u

POLICY_FILE="/etc/default/nas-video-policy"
ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"

REPROCESS_DIR="${TEMP_CLEAN_REPROCESS_DIR:-/var/lib/nas-health/reprocess}"
REPROCESS_AGE_DAYS="${TEMP_CLEAN_REPROCESS_AGE_DAYS:-2}"
INSTALLER_AGE_DAYS="${EMMC_INSTALLER_RETENTION_DAYS:-30}"
LOG_FILE="${EMMC_MONTHLY_LOG_FILE:-/var/log/emmc-safe-monthly.log}"
EMMC_SAFE_NOTIFY="${EMMC_SAFE_NOTIFY:-0}"

case "$REPROCESS_AGE_DAYS" in
  ''|*[!0-9]*) REPROCESS_AGE_DAYS=2 ;;
esac
if [ "$REPROCESS_AGE_DAYS" -lt 1 ]; then REPROCESS_AGE_DAYS=1; fi

case "$INSTALLER_AGE_DAYS" in
  ''|*[!0-9]*) INSTALLER_AGE_DAYS=30 ;;
esac
if [ "$INSTALLER_AGE_DAYS" -lt 7 ]; then INSTALLER_AGE_DAYS=7; fi

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

bytes_dir() {
  local d="$1"
  if [ -d "$d" ]; then
    du -sb "$d" 2>/dev/null | awk '{print $1+0}'
  else
    echo 0
  fi
}

human_gb() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.2f", (b+0)/1073741824}'
}

find_installers() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth 2 -type f \
    \( \
      -name '*.deb' -o \
      -name '*super-nas*.zip' -o \
      -name '*supernas*.zip' -o \
      -name '*immich*install*.sh' -o \
      -name '*rclone*-linux*.zip' -o \
      -name '*rclone*arm*.zip' \
    \) \
    -mtime +"$INSTALLER_AGE_DAYS" -print
}

REPROCESS_BEFORE="$(bytes_dir "$REPROCESS_DIR")"

# 1) Podar históricos de reproceso (sin tocar *latest*).
if [ -d "$REPROCESS_DIR" ]; then
  find "$REPROCESS_DIR" -maxdepth 3 -type f \
    \( -name '*.csv' -o -name '*.json' -o -name '*.log' \) \
    -mtime +"$REPROCESS_AGE_DAYS" ! -name '*latest*' -delete 2>/dev/null || true
  find "$REPROCESS_DIR" -maxdepth 1 -type d -name 'chunks*' -mtime +"$REPROCESS_AGE_DAYS" -exec rm -rf {} + 2>/dev/null || true
fi

REPROCESS_AFTER="$(bytes_dir "$REPROCESS_DIR")"

# 2) Huérfanos APT + cache de paquetes.
APT_DONE=0
if command -v apt-get >/dev/null 2>&1; then
  if apt-get autoremove --purge -y >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1; then
    APT_DONE=1
  fi
fi

# 3) Journald (solo logs técnicos).
if command -v journalctl >/dev/null 2>&1; then
  journalctl --vacuum-time=7d >/dev/null 2>&1 || true
fi

# 4) Instaladores viejos (patrones acotados).
INSTALLERS_DELETED=0
INSTALLER_PATHS_TMP="$(mktemp /tmp/emmc-installers.XXXXXX)"
for d in /root /tmp /var/tmp; do
  find_installers "$d" >> "$INSTALLER_PATHS_TMP"
done

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    /root/*|/tmp/*|/var/tmp/*)
      if rm -f -- "$p" 2>/dev/null; then
        INSTALLERS_DELETED=$((INSTALLERS_DELETED + 1))
      fi
      ;;
  esac
done < "$INSTALLER_PATHS_TMP"
rm -f "$INSTALLER_PATHS_TMP"

REPROCESS_FREED=$((REPROCESS_BEFORE - REPROCESS_AFTER))
if [ "$REPROCESS_FREED" -lt 0 ]; then REPROCESS_FREED=0; fi

log "weekly-clean reprocess_keep_days=$REPROCESS_AGE_DAYS installers_keep_days=$INSTALLER_AGE_DAYS reprocess_freed_gb=$(human_gb "$REPROCESS_FREED") installers_deleted=$INSTALLERS_DELETED apt_done=$APT_DONE"

if [ "$EMMC_SAFE_NOTIFY" = "1" ] && [ -x "$ALERT_BIN" ]; then
  NAS_ALERT_KEY="emmc_safe_weekly:done" NAS_ALERT_TTL=21600 \
    "$ALERT_BIN" "🧹 Limpieza semanal segura eMMC completada
Acción del NAS:
- Reprocess depurado (conservando *latest* y sin tocar /var/lib/immich/cache)
- Huérfanos APT revisados
- Instaladores viejos depurados
Resultado:
- Liberado en reprocess: ~$(human_gb "$REPROCESS_FREED") GB
- Instaladores eliminados: $INSTALLERS_DELETED
- apt autoremove/clean: $([ "$APT_DONE" = "1" ] && echo OK || echo SKIPPED)" || true
fi

exit 0
