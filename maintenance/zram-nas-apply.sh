#!/bin/bash
set -euo pipefail

# Reconfigura zram0 con secuencia segura:
# swapoff -> reset -> algoritmo -> tamaño -> mkswap -> swapon
# Funciona tanto en boot como en ejecución manual.

DEFAULT_ALGO="zstd"
DEFAULT_PERCENT="30"
CONF_FILE="/etc/default/zramswap"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE" || true
fi

ALGO="${ALGO:-${ZRAM_ALGO:-$DEFAULT_ALGO}}"
PERCENT="${PERCENT:-${ZRAM_PERCENT:-$DEFAULT_PERCENT}}"

if ! [[ "$PERCENT" =~ ^[0-9]+$ ]] || [ "$PERCENT" -lt 1 ] || [ "$PERCENT" -gt 95 ]; then
    PERCENT="$DEFAULT_PERCENT"
fi

modprobe zram >/dev/null 2>&1 || true
if [ ! -b /dev/zram0 ]; then
    modprobe zram num_devices=1 >/dev/null 2>&1 || true
fi
[ -b /dev/zram0 ] || { echo "zram0 no disponible en este kernel"; exit 1; }

if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/dev/zram0'; then
    swapoff /dev/zram0 || true
fi

if [ -w /sys/block/zram0/reset ]; then
    echo 1 > /sys/block/zram0/reset
fi

if [ -f /sys/block/zram0/comp_algorithm ]; then
    if grep -qw "$ALGO" /sys/block/zram0/comp_algorithm; then
        echo "$ALGO" > /sys/block/zram0/comp_algorithm
    elif grep -qw "zstd" /sys/block/zram0/comp_algorithm; then
        ALGO="zstd"
        echo "$ALGO" > /sys/block/zram0/comp_algorithm
    else
        ALGO="$(awk -F'[][]' '{print $2}' /sys/block/zram0/comp_algorithm | awk '{print $1}')"
    fi
fi

MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
SIZE_BYTES=$(( MEM_KB * 1024 * PERCENT / 100 ))
if [ "$SIZE_BYTES" -lt 134217728 ]; then
    SIZE_BYTES=134217728
fi
echo "$SIZE_BYTES" > /sys/block/zram0/disksize

mkswap -f /dev/zram0 >/dev/null
swapon -p 100 /dev/zram0

if command -v numfmt >/dev/null 2>&1; then
    SIZE_HR="$(numfmt --to=iec "$SIZE_BYTES")"
else
    SIZE_HR="${SIZE_BYTES}B"
fi

ACTIVE_ALGO="$ALGO"
if [ -f /sys/block/zram0/comp_algorithm ]; then
    ACTIVE_ALGO="$(grep -o '\[[^]]*\]' /sys/block/zram0/comp_algorithm | tr -d '[]')"
fi

echo "zram0 OK | algo=${ACTIVE_ALGO} | percent=${PERCENT}% | size=${SIZE_HR}"
