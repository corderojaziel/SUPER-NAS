#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cache-monitor.sh — Vigilancia del cache de videos comprimidos
# Guía Maestra NAS V58
#
# ── QUÉ HACE ─────────────────────────────────────────────────────────────
# Mide el tamaño del cache de videos 720p en la eMMC y avisa por Telegram
# si supera los umbrales configurados. NO borra nada — solo observa.
# La limpieza automática la hace cache-clean.sh (videos > 7 días).
#
# ── POR QUÉ NO BORRA AUTOMÁTICAMENTE ─────────────────────────────────────
# El cache es valiosos: representa horas de procesamiento ffmpeg nocturno.
# Una limpieza agresiva automática podría borrar videos que el usuario
# acaba de ver o está por ver. Mejor avisar y dejar que el usuario decida.
# cache-clean.sh borra solo los videos que llevan > 7 días sin acceso.
#
# ── UMBRALES (configurados desde nas.conf vía install.sh) ────────────────
# WARN_GB=20:    El cache está creciendo — normal si hay muchos videos nuevos
# CRIT_GB=40:    El cache es muy grande — considerar ajustar cache-clean.sh
# RATIO_WARN=30: El cache representa >30% del espacio de fotos — inusual
#
# ── CACHE EN eMMC (128 GB) ───────────────────────────────────────────────
# Con ~32 GB usados por el sistema, quedan ~96 GB libres.
# A 80 MB por video de 1:40 min, CRIT_GB=40 equivale a ~500 videos.
# Con 200–500 videos en biblioteca y retención de 7 días, este umbral
# raramente se alcanza en uso normal.
#
# ── ANTI-SPAM ────────────────────────────────────────────────────────────
# Si el cache ya está al límite, no repetir la alerta crítica cada noche.
# Intervalo: máximo una alerta crítica cada 12 horas.
# ═══════════════════════════════════════════════════════════════════════════

if [ ! -f /etc/nas-secrets ]; then exit 0; fi
source /etc/nas-secrets

NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
CACHE="${CACHE_DIR:-/var/lib/immich/cache}"      # Cache de videos en eMMC (ruta directa)
PHOTOS="${PHOTOS_DIR:-/mnt/merged}"              # Via mergerfs — ve toda la biblioteca (igual que cache-clean.sh)
FREE_MOUNT="${FREE_MOUNT_DIR:-/mnt/storage-main}"

# Umbrales configurables desde nas.conf
WARN_GB="${CACHE_WARN_GB:-20}"
CRIT_GB="${CACHE_CRIT_GB:-40}"
RATIO_WARN="${CACHE_RATIO_WARN:-30}"

# Anti-spam para alertas críticas: máximo 1 alerta cada 12 horas
LAST_CRIT="${CACHE_CRIT_STAMP_FILE:-/tmp/nas_cache_crit_alert}"
INTERVAL="${CACHE_CRIT_INTERVAL_SEC:-43200}"

# Medición de tamaños reales
CACHE_GB=$(du -sb "$CACHE" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
PHOTOS_GB=$(du -sb "$PHOTOS" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
CACHE_FILES=$(find "$CACHE" -type f | wc -l)
FREE_GB=$(df -BG "$FREE_MOUNT" | awk 'NR==2 {gsub("G","",$4); print $4}')

# Ratio cache/fotos — proteger división por cero al inicio (fotos vacías)
if [ "$(echo "$PHOTOS_GB > 0" | bc)" -eq 1 ]; then
    RATIO=$(awk "BEGIN {printf \"%d\", ($CACHE_GB / $PHOTOS_GB) * 100}")
else
    RATIO=0
fi

# Evaluar de mayor a menor severidad
if [ "$(echo "$CACHE_GB >= $CRIT_GB" | bc)" -eq 1 ]; then
    # Anti-spam: no repetir si ya se alertó en las últimas 12h
    SHOULD_ALERT=1
    if [ -f "$LAST_CRIT" ]; then
        LAST=$(cat "$LAST_CRIT" 2>/dev/null || echo 0)
        DIFF=$(( $(date +%s) - LAST ))
        [ "$DIFF" -lt "$INTERVAL" ] && SHOULD_ALERT=0
    fi
    if [ "$SHOULD_ALERT" -eq 1 ]; then
        if "$NAS_ALERT_BIN" "🔴 El cache de videos está muy grande
Ahora ocupa ${CACHE_GB} GB y guarda ${CACHE_FILES} videos temporales.
Eso equivale al ${RATIO}% del tamaño de tu biblioteca y quedan ${FREE_GB} GB libres en el disco principal.
Qué correr:
- TV Box: /usr/local/bin/cache-clean.sh
  Insumo: no aplica.
- TV Box (si sigue alto): /usr/local/bin/rebuild-video-cache.sh prepare
  Insumo: automático (genera listas en /var/lib/nas-health/reprocess).
- PC (pesados): powershell -ExecutionPolicy Bypass -File C:\\Users\\jazie\\SUPERNAS\\powershell\\reprocess_heavy_from_server.ps1 -NoPlan -Limit 50
  Insumo: automático (descarga plan desde TV Box)."; then
            date +%s > "$LAST_CRIT"
        fi
    fi

elif [ "$(echo "$CACHE_GB >= $WARN_GB" | bc)" -eq 1 ]; then
    "$NAS_ALERT_BIN" "🟡 El cache de videos va creciendo
Ahora ocupa ${CACHE_GB} GB y guarda ${CACHE_FILES} videos temporales.
Todavía no borro nada, pero conviene vigilar el espacio.
Qué correr (TV Box): /usr/local/bin/cache-monitor.sh
Insumo: no aplica."

elif [ "$RATIO" -ge "$RATIO_WARN" ]; then
    "$NAS_ALERT_BIN" "🟠 El cache ya es grande comparado con tu biblioteca
Cache: ${CACHE_GB} GB
Biblioteca: ${PHOTOS_GB} GB
Relación actual: ${RATIO}%
Qué correr (TV Box): /usr/local/bin/cache-clean.sh
Insumo: no aplica."
fi
