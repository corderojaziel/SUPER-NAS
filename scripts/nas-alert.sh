#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# nas-alert.sh — Envío de alertas a Telegram
# Guía Maestra NAS V58
#
# ── USO ──────────────────────────────────────────────────────────────────
# /usr/local/bin/nas-alert.sh "Mensaje de alerta"
#
# ── CUÁNDO SE LLAMA ──────────────────────────────────────────────────────
# night-run.sh:      resultado de cada tarea nocturna
# ml-temp-guard.sh:  temperatura crítica o falla de ventilador
# smart-check.sh:    problemas SMART en HDDs
# backup.sh:         resultado del backup diario
# cache-monitor.sh:  cache de video demasiado grande
# cache-clean.sh:    auditoría de huérfanos de cache (sin borrar)
#
# ── CREDENCIALES ─────────────────────────────────────────────────────────
# Se leen de /etc/nas-secrets (permisos 600 — solo root puede leer).
# Si el archivo no existe, el script falla con un mensaje claro en stderr.
# Esto evita que llamadas silenciosas sin configuración pasen desapercibidas.
#
# ── TIMEOUTS ─────────────────────────────────────────────────────────────
# connect-timeout 10s: si la API de Telegram no responde en 10s, falla.
# max-time 15s:        tiempo total máximo incluyendo transferencia.
# Estos timeouts evitan que el script se cuelgue y bloquee night-run.sh.
#
# ── --data-urlencode ─────────────────────────────────────────────────────
# Necesario para mensajes con espacios, emojis, saltos de línea y caracteres
# especiales. Sin esto, la API de Telegram rechaza el mensaje con error 400.
# ═══════════════════════════════════════════════════════════════════════════

case "${NAS_ALERT_SUPPRESS:-0}" in
    1|true|TRUE|yes|YES|on|ON) exit 0 ;;
esac

if [ ! -f /etc/nas-secrets ]; then
    echo "[nas-alert] ERROR: /etc/nas-secrets no encontrado" >&2
    exit 1
fi

source /etc/nas-secrets

# Salir silenciosamente si Telegram no está configurado
# (nas-alert.sh se llama desde muchos scripts — fallo silencioso es correcto)
[ -n "${TELEGRAM_TOKEN:-}" ]  || exit 0
[ -n "${TELEGRAM_CHAT_ID:-}" ] || exit 0

# Anti-spam opcional con cooldown por clave.
# Uso:
#   NAS_ALERT_KEY="mount_down:/mnt/storage-main" NAS_ALERT_TTL=1800 nas-alert.sh "..."
# Si no se define clave, usa hash del mensaje.
STATE_DIR="/var/lib/nas-alert-state"
mkdir -p "$STATE_DIR"
KEY_INPUT="${NAS_ALERT_KEY:-$1}"
TTL="${NAS_ALERT_TTL:-600}"
KEY=$(printf '%s' "$KEY_INPUT" | sha1sum | awk '{print $1}')
STAMP_FILE="$STATE_DIR/$KEY.ts"
NOW=$(date +%s)

if [ -f "$STAMP_FILE" ]; then
    LAST=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -lt "$TTL" ]; then
        exit 0
    fi
fi

if curl -fsS \
    --connect-timeout 10 \
    --max-time 15 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" \
    > /dev/null; then
    echo "$NOW" > "$STAMP_FILE"
else
    echo "[nas-alert] WARN: no se pudo enviar la alerta a Telegram" >&2
    exit 1
fi
