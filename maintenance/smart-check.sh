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
DISK_STATE_FILE="$STATE_DIR/smart-disk-state.tsv"
: > "$RISKY_FILE"
GLOBAL="OK"
NEXT_STATE_FILE="$(mktemp)"
trap 'rm -f "$NEXT_STATE_FILE"' EXIT

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

smart_data_readable() {
  local disk="$1" opts="$2" out rc
  out=$("$SMARTCTL_BIN" $opts -A -H "$disk" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | grep -Eq 'SMART overall-health|SMART Health Status|ATTRIBUTE_NAME|ID# ATTRIBUTE_NAME'
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

read_prev_state() {
  local disk="$1"
  [ -f "$DISK_STATE_FILE" ] || return 0
  grep -F "${disk}|" "$DISK_STATE_FILE" | tail -1 || true
}

to_int_or_default() {
  local value="$1" default="$2"
  case "$value" in
    ''|*[!0-9-]*) echo "$default" ;;
    *) echo "$value" ;;
  esac
}

for disk in $DISK_LIST; do
  [ -b "$disk" ] || continue
  DISK_LABEL="$(friendly_disk "$disk")"

  SMART_DEV_OPTS=""
  if smart_data_readable "$disk" ""; then
    SMART_DEV_OPTS=""
  elif smart_data_readable "$disk" "-d sat"; then
    SMART_DEV_OPTS="-d sat"
  elif smart_data_readable "$disk" "-d scsi"; then
    SMART_DEV_OPTS="-d scsi"
  else
    PREV_LINE="$(read_prev_state "$disk")"
    PREV_STATUS=""
    PREV_WARN_STREAK=0
    if [ -n "$PREV_LINE" ]; then
      IFS='|' read -r _ PREV_STATUS _ _ _ _ PREV_WARN_STREAK _ <<EOF
$PREV_LINE
EOF
    fi
    PREV_WARN_STREAK="$(to_int_or_default "$PREV_WARN_STREAK" 0)"
    WARN_STREAK=1
    [ "$PREV_STATUS" = "WARN" ] && WARN_STREAK=$((PREV_WARN_STREAK + 1))

    DISK_DETAIL="$(disk_detail "$disk" "")"
    echo "$disk|WARN|SMART no disponible" >> "$RISKY_FILE"
    echo "$disk|WARN|-1|-1|-1|0|$WARN_STREAK|$(date -Iseconds)" >> "$NEXT_STATE_FILE"
    GLOBAL=$(merge_status "$GLOBAL" WARN)
    NAS_ALERT_KEY="smart_unavailable:${disk}" NAS_ALERT_TTL=21600 alert "⚠️ No pude leer la salud del $DISK_LABEL
Acción del NAS: sigo en modo seguro.
Disco detectado: $DISK_DETAIL
Comandos sugeridos (diagnóstico):
1) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
2) /usr/local/bin/smart-check.sh daily"
    if [ "$WARN_STREAK" -ge 3 ]; then
      NAS_ALERT_KEY="smart_trend_unavailable:${disk}" NAS_ALERT_TTL=21600 alert "⚠️ Señal temprana persistente en $DISK_LABEL
No pude leer SMART en varios ciclos seguidos (racha: $WARN_STREAK).
Esto suele ser telemetría inestable por bridge/cable/puerto USB.
Acción sugerida:
1) reconectar cable/puerto USB
2) /usr/local/bin/smart-check.sh weekly"
    fi
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

  PREV_LINE="$(read_prev_state "$disk")"
  PREV_STATUS=""
  PREV_REALLOC=0
  PREV_PENDING=0
  PREV_OFFLINE=0
  PREV_TEMP=0
  PREV_WARN_STREAK=0
  if [ -n "$PREV_LINE" ]; then
    IFS='|' read -r _ PREV_STATUS PREV_REALLOC PREV_PENDING PREV_OFFLINE PREV_TEMP PREV_WARN_STREAK _ <<EOF
$PREV_LINE
EOF
  fi
  PREV_REALLOC="$(to_int_or_default "$PREV_REALLOC" 0)"
  PREV_PENDING="$(to_int_or_default "$PREV_PENDING" 0)"
  PREV_OFFLINE="$(to_int_or_default "$PREV_OFFLINE" 0)"
  PREV_TEMP="$(to_int_or_default "$PREV_TEMP" 0)"
  PREV_WARN_STREAK="$(to_int_or_default "$PREV_WARN_STREAK" 0)"

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

  WARN_STREAK=0
  [ "$STATUS" = "WARN" ] && WARN_STREAK=1
  [ "$STATUS" = "WARN" ] && [ "$PREV_STATUS" = "WARN" ] && WARN_STREAK=$((PREV_WARN_STREAK + 1))

  REALLOC_UP=0
  PENDING_UP=0
  OFFLINE_UP=0
  [ "$REALLOC" -gt "$PREV_REALLOC" ] && REALLOC_UP=1
  [ "$PENDING" -gt "$PREV_PENDING" ] && PENDING_UP=1
  [ "$OFFLINE" -gt "$PREV_OFFLINE" ] && OFFLINE_UP=1

  TEMP_SUSTAINED=0
  if [ "$TEMP" -ge 50 ] && [ "$PREV_TEMP" -ge 50 ] && [ "$STATUS" = "WARN" ]; then
    TEMP_SUSTAINED=1
  fi

  echo "$disk|$STATUS|$REASON" >> "$RISKY_FILE"
  echo "$disk|$STATUS|$REALLOC|$PENDING|$OFFLINE|$TEMP|$WARN_STREAK|$(date -Iseconds)" >> "$NEXT_STATE_FILE"
  GLOBAL=$(merge_status "$GLOBAL" "$STATUS")

  case "$STATUS" in
    WARN)
      NAS_ALERT_KEY="smart_warn:${disk}" NAS_ALERT_TTL=21600 alert "⚠️ Conviene revisar el $DISK_LABEL
Detecté una señal temprana de desgaste o temperatura alta.
Detalle: $USER_REASON.
Disco exacto: $DISK_DETAIL
Comandos sugeridos (diagnóstico):
1) smartctl $SMART_DEV_OPTS -a $disk
2) /usr/local/bin/smart-check.sh weekly"
      if [ "$WARN_STREAK" -ge 3 ] || [ "$REALLOC_UP" -eq 1 ] || [ "$PENDING_UP" -eq 1 ] || [ "$OFFLINE_UP" -eq 1 ] || [ "$TEMP_SUSTAINED" -eq 1 ]; then
        TREND_MSG="⚠️ Tendencia de riesgo en $DISK_LABEL
Señal WARN repetida o en aumento (racha WARN: $WARN_STREAK)."
        [ "$REALLOC_UP" -eq 1 ] && TREND_MSG="$TREND_MSG
- Reallocated subió: $PREV_REALLOC -> $REALLOC"
        [ "$PENDING_UP" -eq 1 ] && TREND_MSG="$TREND_MSG
- Pending subió: $PREV_PENDING -> $PENDING"
        [ "$OFFLINE_UP" -eq 1 ] && TREND_MSG="$TREND_MSG
- OfflineUncorrectable subió: $PREV_OFFLINE -> $OFFLINE"
        [ "$TEMP_SUSTAINED" -eq 1 ] && TREND_MSG="$TREND_MSG
- Temperatura alta sostenida: ${PREV_TEMP}°C -> ${TEMP}°C"
        TREND_MSG="$TREND_MSG
Acción sugerida: programar revisión/reemplazo preventivo."
        NAS_ALERT_KEY="smart_trend:${disk}" NAS_ALERT_TTL=21600 alert "$TREND_MSG"
      fi
      ;;
    CRIT)
      NAS_ALERT_KEY="smart_crit:${disk}" NAS_ALERT_TTL=21600 alert "🚨 El $DISK_LABEL necesita atención
Detecté un problema serio.
Detalle: $USER_REASON.
Disco exacto: $DISK_DETAIL
Acción del NAS: pauso tareas pesadas para proteger datos.
Importante: estos comandos no reparan sectores, solo confirman estado.
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

mv -f "$NEXT_STATE_FILE" "$DISK_STATE_FILE"

cat > "$STATUS_FILE" <<EOF
GLOBAL_SMART_STATUS=$GLOBAL
SMART_LAST_RUN=$(date -Iseconds)
RISKY_DISKS="$(tr '\n' ';' < "$RISKY_FILE" | sed 's/;$/ /')"
EOF

exit 0
