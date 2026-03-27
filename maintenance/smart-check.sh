#!/bin/bash
# ── smart-check.sh ───────────────────────────────────────────────────────
# Salud SMART con estado persistente OK / WARN / CRIT.
# También actualiza Telegram con mensajes más claros y con emojis.
#
# MODOS:
#   daily   -> lectura rápida de health + temperatura + atributos
#   weekly  -> lectura más visible para resumen semanal
#   monthly -> test corto de superficie
# ═══════════════════════════════════════════════════════════════════════════
MODE="${1:-daily}"
DISK_LIST="/dev/sda /dev/sdb"
[ -f /etc/nas-disks ] && DISK_LIST=$(cat /etc/nas-disks)
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
STATE_DIR="/var/lib/nas-health"
mkdir -p "$STATE_DIR"
STATUS_FILE="$STATE_DIR/smart-status.env"
RISKY_FILE="$STATE_DIR/risky-disks.txt"
: > "$RISKY_FILE"
GLOBAL="OK"

alert() { /usr/local/bin/nas-alert.sh "$1"; }

friendly_disk() {
  local target="$1" idx=1 item
  for item in $DISK_LIST; do
    if [ "$item" = "$target" ]; then
      case "$idx" in
        1) echo "disco principal de fotos" ;;
        2) echo "disco de respaldo" ;;
        *) echo "disco adicional $idx" ;;
      esac
      return
    fi
    idx=$((idx + 1))
  done
  echo "uno de los discos configurados"
}

disk_detail() {
  local disk="$1" opts="$2" info model serial
  info=$("$SMARTCTL_BIN" $opts -i "$disk" 2>/dev/null || true)
  model=$(printf '%s' "$info" | awk -F: '/Device Model|Model Number|Product/{sub(/^[[:space:]]+/, "", $2); if(length($2)) {print $2; exit}}')
  serial=$(printf '%s' "$info" | awk -F: '/Serial Number|Unit serial number/{sub(/^[[:space:]]+/, "", $2); if(length($2)) {print $2; exit}}')
  if [ -n "$model" ] && [ -n "$serial" ]; then
    printf '%s (%s, S/N %s)\n' "$disk" "$model" "$serial"
  elif [ -n "$model" ]; then
    printf '%s (%s)\n' "$disk" "$model"
  else
    printf '%s\n' "$disk"
  fi
}

rank() {
  case "$1" in
    OK) echo 0 ;;
    WARN) echo 1 ;;
    CRIT) echo 2 ;;
    *) echo 1 ;;
  esac
}

merge_status() {
  local current="$1" new="$2"
  [ "$(rank "$new")" -gt "$(rank "$current")" ] && echo "$new" || echo "$current"
}

for disk in $DISK_LIST; do
  [ -b "$disk" ] || continue
  DISK_LABEL="$(friendly_disk "$disk")"

  SMART_DEV_OPTS=""
  if "$SMARTCTL_BIN" -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
    SMART_DEV_OPTS=""
  elif "$SMARTCTL_BIN" -d sat -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
    SMART_DEV_OPTS="-d sat"
  elif "$SMARTCTL_BIN" -d scsi -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
    SMART_DEV_OPTS="-d scsi"
  else
    DISK_DETAIL="$(disk_detail "$disk" "")"
    echo "$disk|WARN|SMART no disponible" >> "$RISKY_FILE"
    GLOBAL=$(merge_status "$GLOBAL" WARN)
    NAS_ALERT_KEY="smart_unavailable:${disk}" NAS_ALERT_TTL=21600 alert "⚠️ No pude leer la salud del $DISK_LABEL
Algunos adaptadores no dejan pasar esta información.
Disco detectado: $DISK_DETAIL
Qué correr (TV Box):
Insumo: no aplica.
1) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
2) /usr/local/bin/smart-check.sh daily
3) /usr/local/bin/verify.sh"
    continue
  fi

  OUT=$("$SMARTCTL_BIN" $SMART_DEV_OPTS -A -H "$disk" 2>/dev/null)
  DISK_DETAIL="$(disk_detail "$disk" "$SMART_DEV_OPTS")"
  HEALTH=$(printf '%s' "$OUT" | grep -E 'SMART overall-health|SMART Health Status' || true)
  REALLOC=$(printf '%s' "$OUT" | awk '/Reallocated_Sector_Ct/{print $10}' | head -1)
  PENDING=$(printf '%s' "$OUT" | awk '/Current_Pending_Sector/{print $10}' | head -1)
  OFFLINE=$(printf '%s' "$OUT" | awk '/Offline_Uncorrectable/{print $10}' | head -1)
  TEMP=$(printf '%s' "$OUT" | awk '/Temperature_Celsius|Temperature_Internal/{print $10}' | head -1)
  STATUS="OK"
  REASON="healthy"
  USER_REASON="sin señales preocupantes"

  [ -z "$REALLOC" ] && REALLOC=0
  [ -z "$PENDING" ] && PENDING=0
  [ -z "$OFFLINE" ] && OFFLINE=0
  [ -z "$TEMP" ] && TEMP=0

  if printf '%s' "$HEALTH" | grep -qi 'FAILED'; then
    STATUS="CRIT"
    REASON="SMART overall FAILED"
    USER_REASON="el propio disco reporta un fallo interno"
  elif [ "$PENDING" -gt 0 ] || [ "$OFFLINE" -gt 0 ]; then
    STATUS="CRIT"
    REASON="Pending=$PENDING OfflineUncorrectable=$OFFLINE"
    USER_REASON="el disco tiene sectores problemáticos que ya no se están leyendo bien"
  elif [ "$REALLOC" -gt 0 ] || [ "$TEMP" -ge 50 ]; then
    STATUS="WARN"
    REASON="Reallocated=$REALLOC Temp=${TEMP}C"
    if [ "$REALLOC" -gt 0 ] && [ "$TEMP" -ge 50 ]; then
      USER_REASON="el disco ya muestra desgaste y además está más caliente de lo normal"
    elif [ "$REALLOC" -gt 0 ]; then
      USER_REASON="el disco ya muestra señales tempranas de desgaste"
    else
      USER_REASON="el disco está más caliente de lo normal"
    fi
  fi

  if [ "$MODE" = "monthly" ]; then
    "$SMARTCTL_BIN" $SMART_DEV_OPTS -t short "$disk" >/dev/null 2>&1
    sleep 150
    TEST=$("$SMARTCTL_BIN" $SMART_DEV_OPTS -a "$disk" 2>/dev/null | grep '# 1' | head -1)
    if printf '%s' "$TEST" | grep -qv 'Completed without error'; then
      STATUS="CRIT"
      REASON="Self-test con errores"
      USER_REASON="la prueba interna del disco encontró errores"
    fi
  fi

  echo "$disk|$STATUS|$REASON" >> "$RISKY_FILE"
  GLOBAL=$(merge_status "$GLOBAL" "$STATUS")

  case "$STATUS" in
    WARN)
      NAS_ALERT_KEY="smart_warn:${disk}" NAS_ALERT_TTL=21600 alert "⚠️ Conviene revisar el $DISK_LABEL
Detecté una señal temprana de desgaste o temperatura alta.
Detalle: $USER_REASON.
Disco exacto: $DISK_DETAIL
Qué correr (TV Box):
Insumo: no aplica.
1) smartctl $SMART_DEV_OPTS -a $disk
2) /usr/local/bin/smart-check.sh weekly"
      ;;
    CRIT)
      NAS_ALERT_KEY="smart_crit:${disk}" NAS_ALERT_TTL=21600 alert "🚨 El $DISK_LABEL necesita atención
Detecté un problema serio.
Detalle: $USER_REASON.
Disco exacto: $DISK_DETAIL
Para cuidarlo, el NAS va a pausar tareas pesadas.
Qué correr ahora (TV Box):
Insumo: no aplica.
1) smartctl $SMART_DEV_OPTS -a $disk
2) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
3) /usr/local/bin/verify.sh"
      ;;
    *)
      if [ "$MODE" = "weekly" ]; then
        alert "✅ Revisión del $DISK_LABEL sin problemas
Temperatura actual: ${TEMP}°C
Por ahora no veo señales preocupantes."
      fi
      ;;
  esac
done

cat > "$STATUS_FILE" <<EOF
GLOBAL_SMART_STATUS=$GLOBAL
SMART_LAST_RUN=$(date -Iseconds)
RISKY_DISKS="$(tr '\n' ';' < "$RISKY_FILE" | sed 's/;$/ /')"
EOF

exit 0
