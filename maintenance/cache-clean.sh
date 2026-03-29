#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cache-clean.sh — Auditoría de huérfanos en cache (NO BORRA)
# Guía Maestra NAS V58
#
# Política operativa:
#   - El cache de video NO se elimina automáticamente.
#   - Este script solo detecta posibles huérfanos y avisa.
#   - Si falta espacio en eMMC, el usuario decide migrar cache a HDD con:
#       /usr/local/bin/cache-migrate-to-disk.sh --plan
#       /usr/local/bin/cache-migrate-to-disk.sh --apply --target-free-gb 20
# ═══════════════════════════════════════════════════════════════════════════

set -u

CACHE_ROOT="${CACHE_DIR:-${CACHE_ROOT:-/var/lib/immich/cache}}"
LEGACY_CACHE_ROOTS="${LEGACY_CACHE_ROOTS:-/mnt/storage-main/cache}"
PHOTOS="${PHOTOS_DIR:-/mnt/storage-main/photos}"
DETAIL_LIMIT="${CACHE_AUDIT_DETAIL_LIMIT:-40}"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"

if [ ! -d "$PHOTOS" ] && [ -d "/mnt/merged" ]; then
    PHOTOS="/mnt/merged"
fi
[ -d "$PHOTOS" ] || exit 0

declare -A SCAN_ROOT_SEEN=()
SCAN_ROOTS=()

add_scan_root() {
    local root="$1"
    root="${root//[$'\t\r\n ']}"
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0
    if [ -z "${SCAN_ROOT_SEEN[$root]:-}" ]; then
        SCAN_ROOT_SEEN[$root]=1
        SCAN_ROOTS+=("$root")
    fi
}

add_scan_root "$CACHE_ROOT"
IFS=',' read -r -a LEGACY_ROOT_ARR <<< "$LEGACY_CACHE_ROOTS"
for r in "${LEGACY_ROOT_ARR[@]}"; do
    add_scan_root "$r"
done

[ "${#SCAN_ROOTS[@]}" -gt 0 ] || exit 0

declare -A PHOTO_TOPS=()
while IFS= read -r d; do
    [ -n "$d" ] && PHOTO_TOPS["$d"]=1
done < <(find "$PHOTOS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

declare -A PHOTO_STEMS=()
while IFS= read -r -d '' src; do
    stem="$(basename "${src%.*}")"
    [ -n "$stem" ] && PHOTO_STEMS["${stem,,}"]=1
done < <(find "$PHOTOS" -type f \
    \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.webm" -o -iname "*.3gp" \) \
    -print0 2>/dev/null)

is_uuid() {
    [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

extract_uuid() {
    local stem="${1,,}"
    local c=""
    if is_uuid "$stem"; then
        printf '%s\n' "$stem"
        return 0
    fi
    if [[ "$stem" =~ ^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-[a-z0-9]+$ ]]; then
        c="${BASH_REMATCH[1]}"
        if is_uuid "$c"; then
            printf '%s\n' "$c"
            return 0
        fi
    fi
    if [[ "$stem" =~ _([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]]; then
        c="${BASH_REMATCH[1]}"
        if is_uuid "$c"; then
            printf '%s\n' "$c"
            return 0
        fi
    fi
    if [[ "$stem" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ]]; then
        c="${BASH_REMATCH[1]}"
        if is_uuid "$c"; then
            printf '%s\n' "$c"
            return 0
        fi
    fi
    return 1
}

original_exists_by_rel() {
    local rel_mp4="$1"
    local rel_no_ext="${rel_mp4%.mp4}"
    local rel_dir rel_base abs_dir
    rel_dir="$(dirname "$rel_no_ext")"
    rel_base="$(basename "$rel_no_ext")"
    abs_dir="$PHOTOS/$rel_dir"
    [ -d "$abs_dir" ] || return 1
    find "$abs_dir" -maxdepth 1 -type f -name "${rel_base}.*" -print -quit 2>/dev/null | grep -q .
}

TOTAL=0
MANAGED=0
KEPT=0
ORPHAN=0
SKIPPED_UNMANAGED=0
DETAIL_SHOWN=0

for scan_root in "${SCAN_ROOTS[@]}"; do
    while IFS= read -r -d '' cached; do
        TOTAL=$((TOTAL + 1))

        local_rel="${cached#"$scan_root"/}"
        stem="$(basename "$cached" .mp4)"
        stem_l="${stem,,}"
        managed=0
        exists=0

        if [ "$scan_root" = "$CACHE_ROOT" ]; then
            if [[ "$local_rel" == encoded-video/* ]] || [[ "$stem_l" =~ -mp$ ]]; then
                SKIPPED_UNMANAGED=$((SKIPPED_UNMANAGED + 1))
                continue
            fi
            top="${local_rel%%/*}"
            if [ -n "${PHOTO_TOPS[$top]:-}" ]; then
                managed=1
                if original_exists_by_rel "$local_rel"; then
                    exists=1
                fi
            fi
        else
            managed=1
        fi

        if [ "$managed" -eq 0 ]; then
            SKIPPED_UNMANAGED=$((SKIPPED_UNMANAGED + 1))
            continue
        fi

        MANAGED=$((MANAGED + 1))

        if [ "$exists" -eq 0 ]; then
            uuid=""
            if uuid="$(extract_uuid "$stem_l")"; then
                if [ -n "${PHOTO_STEMS[$uuid]:-}" ]; then
                    exists=1
                fi
            fi
        fi

        if [ "$exists" -eq 1 ]; then
            KEPT=$((KEPT + 1))
            continue
        fi

        ORPHAN=$((ORPHAN + 1))
        if [ "$DETAIL_SHOWN" -lt "$DETAIL_LIMIT" ]; then
            echo "ORPHAN-CANDIDATE: $cached"
            DETAIL_SHOWN=$((DETAIL_SHOWN + 1))
        fi
    done < <(find "$scan_root" \( -type f -o -type l \) -name "*.mp4" -print0 2>/dev/null)
done

echo "Cache-audit resumen: total=$TOTAL managed=$MANAGED kept=$KEPT orphan_candidates=$ORPHAN skipped_unmanaged=$SKIPPED_UNMANAGED"

if [ "$ORPHAN" -gt 0 ]; then
  "$NAS_ALERT_BIN" "🟡 Auditoría del cache terminada: detecté $ORPHAN posibles huérfanos
Acción del NAS: no borré nada automáticamente.
Si quieres actuar:
1) /usr/local/bin/cache-migrate-to-disk.sh --plan   # solo revisar, sin cambios
2) /usr/local/bin/cache-migrate-to-disk.sh --apply --target-free-gb 20   # sí migra cache al HDD conservando playback"
fi
