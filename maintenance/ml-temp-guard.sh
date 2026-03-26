#!/bin/bash
# ── ml-temp-guard.sh ─────────────────────────────────────────────────────
# Guardián térmico con 3 niveles de protección:
#
#   NIVEL 1 — Detección de falla de ventilador
#             CPU en reposo (< 20% uso) Y temp > 55°C
#             → aviso Telegram "posible falla de ventilador"
#
#   NIVEL 2 — Temperatura alta (≥ 75°C)
#             → detiene ML + aviso Telegram
#
#   NIVEL 3 — Temperatura crítica (≥ 85°C)
#             → detiene ML + ffmpeg + aviso urgente
#
# El arranque del ML lo gestiona night-run.sh, no este script.
# Corre cada 5 minutos via cron.

# ── Overrides opcionales para pruebas/tuning ──────────────────────────────
TEMP_FILE_GLOB="${TEMP_FILE_GLOB:-/sys/class/thermal/thermal_zone*/temp}"
PROC_STAT_FILE="${PROC_STAT_FILE:-/proc/stat}"
CPU_SAMPLE_INTERVAL_SEC="${CPU_SAMPLE_INTERVAL_SEC:-1}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
PKILL_BIN="${PKILL_BIN:-pkill}"
FAN_INTERVAL="${FAN_INTERVAL_SEC:-1800}"  # 30 minutos por defecto
FAN_IDLE_TEMP_C="${FAN_IDLE_TEMP_C:-55}"
FAN_IDLE_CPU_MAX_PCT="${FAN_IDLE_CPU_MAX_PCT:-20}"
ML_TEMP_HIGH_C="${ML_TEMP_HIGH_C:-75}"
ML_TEMP_CRIT_C="${ML_TEMP_CRIT_C:-85}"
TEMP_C_OVERRIDE="${TEMP_C_OVERRIDE:-}"
CPU_USAGE_OVERRIDE="${CPU_USAGE_OVERRIDE:-}"

# ── Buscar zona térmica válida ─────────────────────────────────────────────
TEMP_FILE=""
for zone in $TEMP_FILE_GLOB; do
  [ -f "$zone" ] && { TEMP_FILE="$zone"; break; }
done

if [ -n "$TEMP_C_OVERRIDE" ]; then
  TEMP_C="$TEMP_C_OVERRIDE"
else
  [ -z "$TEMP_FILE" ] && exit 0

  TEMP=$(cat "$TEMP_FILE" 2>/dev/null)
  [ -z "$TEMP" ] && exit 0

  TEMP_C=$(( TEMP / 1000 ))
fi

read_cpu_counters() {
  awk '/^cpu /{
    idle=$5+$6
    total=0
    for (i=2; i<=NF; i++) total+=$i
    printf "%s %s\n", total, idle
    exit
  }' "$PROC_STAT_FILE" 2>/dev/null
}

# ── NIVEL 1: Detección de falla de ventilador ─────────────────────────────
# Señal: CPU en reposo pero temperatura anormalmente alta
# Con ventilador 120mm funcionando el reposo es 32–38°C
# Sin ventilador el reposo sube a 45–55°C+
# Umbral 55°C en reposo = firma confiable de ventilador muerto
# Leer carga real con dos muestras cortas para evitar usar un promedio
# acumulado desde el boot, que no refleja el estado actual del equipo.
if [ -n "$CPU_USAGE_OVERRIDE" ]; then
  CPU_USAGE="$CPU_USAGE_OVERRIDE"
else
  read -r CPU_TOTAL_1 CPU_IDLE_1 < <(read_cpu_counters)
  sleep "$CPU_SAMPLE_INTERVAL_SEC"
  read -r CPU_TOTAL_2 CPU_IDLE_2 < <(read_cpu_counters)

  if [ -n "${CPU_TOTAL_1:-}" ] && [ -n "${CPU_IDLE_1:-}" ] && \
     [ -n "${CPU_TOTAL_2:-}" ] && [ -n "${CPU_IDLE_2:-}" ]; then
    TOTAL_DELTA=$((CPU_TOTAL_2 - CPU_TOTAL_1))
    IDLE_DELTA=$((CPU_IDLE_2 - CPU_IDLE_1))
    if [ "$TOTAL_DELTA" -gt 0 ]; then
      CPU_USAGE=$((100 - (IDLE_DELTA * 100 / TOTAL_DELTA)))
    else
      CPU_USAGE=50
    fi
  else
    CPU_USAGE=50
  fi
fi

if [ "$TEMP_C" -gt "$FAN_IDLE_TEMP_C" ] && [ "${CPU_USAGE:-50}" -lt "$FAN_IDLE_CPU_MAX_PCT" ]; then
  NAS_ALERT_KEY="fan_idle_hot" NAS_ALERT_TTL="$FAN_INTERVAL" \
    "$NAS_ALERT_BIN" "⚠️ El NAS está más caliente de lo normal estando casi en reposo
Temperatura: ${TEMP_C}°C
Uso de CPU: ${CPU_USAGE}%
Esto puede indicar un problema con el ventilador." || true
fi

# ── NIVEL 3: Temperatura crítica ≥ 85°C ───────────────────────────────────
# Actúa antes que el nivel 2 para no duplicar acciones
if [ "$TEMP_C" -ge "$ML_TEMP_CRIT_C" ]; then
  "$DOCKER_BIN" stop immich_machine_learning 2>/dev/null || true
  # Detener también ffmpeg si está corriendo
  "$PKILL_BIN" -15 -x ffmpeg 2>/dev/null || true
  NAS_ALERT_KEY="ml_temp_critical" "$NAS_ALERT_BIN" "🔴 Temperatura crítica en el NAS
Temperatura actual: ${TEMP_C}°C
Detuve el reconocimiento inteligente de Immich y cualquier conversión de video para proteger el equipo.
Conviene revisar ventilación o ventilador cuanto antes." || true
  exit 0
fi

# ── NIVEL 2: Temperatura alta ≥ 75°C ─────────────────────────────────────
if [ "$TEMP_C" -ge "$ML_TEMP_HIGH_C" ]; then
  "$DOCKER_BIN" stop immich_machine_learning 2>/dev/null || true
  NAS_ALERT_KEY="ml_temp_high" "$NAS_ALERT_BIN" "🌡️ El NAS se calentó más de lo normal
Temperatura actual: ${TEMP_C}°C
Detuve temporalmente el reconocimiento inteligente de Immich para que el equipo se enfríe solo." || true
fi
