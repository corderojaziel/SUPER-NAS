#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cache-clean.sh — Limpieza de videos huérfanos en el cache
# Guía Maestra NAS V58
#
# ── QUÉ HACE ─────────────────────────────────────────────────────────────
# Busca videos en el cache eMMC que ya no tienen original en el HDD.
# Ocurre cuando alguien borra un video desde la app Immich:
#   1. Immich borra el original del HDD
#   2. El cache eMMC queda con un .mp4 720p sin original → huérfano
#   3. Este script detecta y elimina esos huérfanos
#
# ── CÓMO DETECTA HUÉRFANOS — LÓGICA CORRECTA PARA IMMICH ────────────────
# Immich nombra los archivos con UUIDs internos:
#   HDD:   /mnt/merged/library/{uuid-user}/{uuid-asset}.mp4
#   cache: /var/lib/immich/cache/library/{uuid-user}/{uuid-asset}.mp4
#
# La estructura de carpetas es la misma — el UUID del asset no cambia.
# Al borrar desde Immich, el archivo desaparece del HDD.
# Este script busca por UUID (nombre de archivo) en el árbol de originales:
#   - Si encuentra el UUID → original existe → conservar cache
#   - Si NO encuentra el UUID → original borrado → eliminar cache
#
# Buscar por UUID es robusto contra reorganizaciones de carpetas porque
# el UUID del asset es estable incluso si Immich mueve el archivo.
#
# ── LO QUE NO HACE ───────────────────────────────────────────────────────
# NO borra por antigüedad (mtime). Un video válido permanece en cache
# indefinidamente hasta que su original sea borrado desde Immich.
# ═══════════════════════════════════════════════════════════════════════════

CACHE="/var/lib/immich/cache"
PHOTOS="/mnt/storage-main/photos"   # Solo originales; no incluir el propio cache

[ -d "$CACHE" ]  || exit 0
[ -d "$PHOTOS" ] || exit 0

DELETED=0

# Importante: usar process substitution evita subshell en el while,
# para que DELETED se conserve fuera del bucle.
while IFS= read -r -d '' cached; do

    # Extraer UUID del asset (nombre del archivo sin extensión)
    # Immich nombra: {uuid-asset}.mp4
    ASSET_UUID=$(basename "$cached" .mp4)

    # Buscar el original por UUID en cualquier ruta de la biblioteca
    # El UUID es único — no habrá colisiones entre álbumes
    ORIGINAL_EXISTS=$(find "$PHOTOS" -type f -name "${ASSET_UUID}.*" -print -quit 2>/dev/null)

    if [ -z "$ORIGINAL_EXISTS" ]; then
        echo "Huérfano eliminado: $(basename "$cached") (UUID: $ASSET_UUID)"
        rm -f "$cached"
        DELETED=$((DELETED + 1))
        # Limpiar directorio vacío que quede tras borrar
        rmdir --ignore-fail-on-non-empty "$(dirname "$cached")" 2>/dev/null || true
    fi

done < <(find "$CACHE" \( -type f -o -type l \) -name "*.mp4" -print0)

if [ "$DELETED" -gt 0 ]; then
    /usr/local/bin/nas-alert.sh "🧹 Limpieza del cache terminada
Se borraron $DELETED videos temporales que ya no tenían archivo original.
Fecha: $(date +%F)"
fi
