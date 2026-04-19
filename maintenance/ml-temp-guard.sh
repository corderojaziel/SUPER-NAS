#!/bin/bash
# ── ml-temp-guard.sh ─────────────────────────────────────────────────────
# Guardián térmico y de CPU con 4 niveles de protección:
#
#   NIVEL 1 — Detección de falla de ventilador
#             CPU en reposo (< 20% uso) y temp > 55°C
#             → aviso Telegram "posible falla de ventilador"
#
#   NIVEL 2 — CPU sostenida muy alta (>= ML_CPU_MAX_PCT durante ML_CPU_DURATION_MIN min)
#             → detiene ML + aviso Telegram
#
#   NIVEL 3 — Temperatura alta (>= 75°C)
#             → detiene ML + aviso Telegram
#
#   NIVEL 4 — Temperatura crítica (>= 85°C)
#             → detiene ML + ffmpeg + aviso urgente
#
# El arranque del ML lo gestiona night-run.sh, no este script.
# Corre cada 5 minutos via cron.

# Carga defaults persistentes (si existen) sin romper overrides por entorno.
[ -f /etc/default/nas-ml-guard ] && . /etc/default/nas-ml-guard

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
# CPU sostenida: si el ML lleva CPU_USAGE >= ML_CPU_MAX_PCT durante
# ML_CPU_DURATION_MIN minutos consecutivos -> se pausa.
# Intervalo del cron = 5 min, así que el contador se incrementa en 5 cada vez.
ML_CPU_MAX_PCT="${ML_CPU_MAX_PCT:-90}"
ML_CPU_DURATION_MIN="${ML_CPU_DURATION_MIN:-60}"
ML_CPU_COUNTER_FILE="${ML_CPU_COUNTER_FILE:-/run/ml-cpu-overload-min}"
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

# ── Medir CPU actual ───────────────────────────────────────────────────────
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

# ── NIVEL 1: Detección de falla de ventilador ─────────────────────────────
if [ "$TEMP_C" -gt "$FAN_IDLE_TEMP_C" ] && [ "${CPU_USAGE:-50}" -lt "$FAN_IDLE_CPU_MAX_PCT" ]; then
  NAS_ALERT_KEY="fan_idle_hot" NAS_ALERT_TTL="$FAN_INTERVAL" \
    "$NAS_ALERT_BIN" "⚠️ El NAS está más caliente de lo normal estando casi en reposo
Temperatura: ${TEMP_C}°C
Uso de CPU: ${CPU_USAGE}%
Acción del NAS: te aviso para revisión preventiva.
Comandos sugeridos (diagnóstico):
1) /usr/local/bin/verify.sh
2) cat /sys/class/thermal/thermal_zone*/temp" || true
fi

# ── NIVEL 2: CPU sostenida alta con ML activo ─────────────────────────────
ML_RUNNING=0
"$DOCKER_BIN" inspect immich_machine_learning --format '{{.State.Running}}' 2>/dev/null | grep -q "true" && ML_RUNNING=1

if [ "$ML_RUNNING" -eq 1 ] && [ "${CPU_USAGE:-0}" -ge "$ML_CPU_MAX_PCT" ]; then
  CURRENT_MIN=0
  [ -f "$ML_CPU_COUNTER_FILE" ] && CURRENT_MIN=$(cat "$ML_CPU_COUNTER_FILE" 2>/dev/null || echo 0)
  CURRENT_MIN=$(( CURRENT_MIN + 5 ))
  echo "$CURRENT_MIN" > "$ML_CPU_COUNTER_FILE"

  if [ "$CURRENT_MIN" -ge "$ML_CPU_DURATION_MIN" ]; then
    "$DOCKER_BIN" stop immich_machine_learning 2>/dev/null || true
    rm -f "$ML_CPU_COUNTER_FILE"
    NAS_ALERT_KEY="ml_cpu_overload" NAS_ALERT_TTL="3600" \
      "$NAS_ALERT_BIN" "⚠️ IML pausada por CPU sostenida alta
CPU: ${CPU_USAGE}% | Temp: ${TEMP_C}°C | Sobrecarga: ${CURRENT_MIN}/${ML_CPU_DURATION_MIN} min
Acción del NAS: pausa IML y reanuda automáticamente cuando baje la carga." || true
  fi
else
  rm -f "$ML_CPU_COUNTER_FILE"
fi

# ── NIVEL 4: Temperatura crítica >= 85°C ──────────────────────────────────
if [ "$TEMP_C" -ge "$ML_TEMP_CRIT_C" ]; then
  "$DOCKER_BIN" stop immich_machine_learning 2>/dev/null || true
  "$PKILL_BIN" -15 -x ffmpeg 2>/dev/null || true
  rm -f "$ML_CPU_COUNTER_FILE"
  NAS_ALERT_KEY="ml_temp_critical" "$NAS_ALERT_BIN" "🔴 Temperatura crítica en el NAS
Temperatura actual: ${TEMP_C}°C
Acción del NAS: detuve IML y conversión de video para proteger el equipo.
Comandos sugeridos:
1) /usr/local/bin/verify.sh
2) /usr/local/bin/immich-ml-window.sh thermal-off" || true
  exit 0
fi

# ── NIVEL 3: Temperatura alta >= 75°C ─────────────────────────────────────
if [ "$TEMP_C" -ge "$ML_TEMP_HIGH_C" ]; then
  "$DOCKER_BIN" stop immich_machine_learning 2>/dev/null || true
  rm -f "$ML_CPU_COUNTER_FILE"
  NAS_ALERT_KEY="ml_temp_high" "$NAS_ALERT_BIN" "🌡️ El NAS se calentó más de lo normal
Temperatura actual: ${TEMP_C}°C
Acción del NAS: pausé IML temporalmente para enfriar el equipo.
Comando opcional (TV Box): /usr/local/bin/immich-ml-window.sh thermal-off" || true
fi
