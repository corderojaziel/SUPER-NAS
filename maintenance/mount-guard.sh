#!/bin/bash
# Monitor de montajes con alerta de desmontaje/montaje.
# - Si detecta un punto desmontado, intenta remontar.
# - Notifica por Telegram en cambios de estado (down -> up, up -> down).
# - Anti-ruido: alerta de desmontaje y recuperación solo si persiste 2 chequeos.

set -u

STATE_DIR="/var/lib/nas-mount-state"
STATE_FILE="$STATE_DIR/status.db"
MOUNTS_FILE="/etc/nas-mounts"
FAILOVER_BIN="${FAILOVER_BIN:-/usr/local/bin/storage-failover.sh}"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

MOUNT_MAIN="/mnt/storage-main"
MOUNT_BACKUP="/mnt/storage-backup"
MOUNT_MERGED="/mnt/merged"
DISK_LIST="/dev/sda /dev/sdb"
[ -f /etc/nas-disks ] && DISK_LIST=$(cat /etc/nas-disks)

if [ -f "$MOUNTS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$MOUNTS_FILE" 2>/dev/null || true
fi

get_prev() {
    local key="$1"
    awk -F'=' -v k="$key" '$1==k{print $2; found=1} END{if(!found) print "unknown"}' "$STATE_FILE"
}

get_prev_num() {
    local key="$1" value
    value="$(get_prev "$key")"
    case "$value" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$value" ;;
    esac
}

set_state() {
    local key="$1" value="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    awk -F'=' -v k="$key" '$1!=k' "$STATE_FILE" > "$tmp" 2>/dev/null || true
    echo "$key=$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

friendly_mount() {
    case "$1" in
        /mnt/storage-main) echo "disco principal de fotos" ;;
        /mnt/storage-backup) echo "disco de respaldo" ;;
        /mnt/merged) echo "biblioteca unificada" ;;
        *) echo "$1" ;;
    esac
}

device_for_mount() {
    local mountpoint="$1" first second
    first=$(echo "$DISK_LIST" | awk '{print $1}')
    second=$(echo "$DISK_LIST" | awk '{print $2}')
    case "$mountpoint" in
        /mnt/storage-main) echo "${first:-desconocido}" ;;
        /mnt/storage-backup) echo "${second:-desconocido}" ;;
        /mnt/merged) echo "usa $MOUNT_MAIN + $MOUNT_BACKUP (mergerfs)" ;;
        *) echo "desconocido" ;;
    esac
}

notify_transition() {
    local key="$1" mountpoint="$2" prev="$3" curr="$4"
    local label device_hint
    label="$(friendly_mount "$mountpoint")"
    device_hint="$(device_for_mount "$mountpoint")"

    # Primera ejecución: registrar estado sin alertar.
    if [ "$prev" = "unknown" ]; then
        return 0
    fi

    if [ "$prev" != "$curr" ]; then
        if [ "$curr" = "down" ]; then
            NAS_ALERT_KEY="mount_down:${mountpoint}" NAS_ALERT_TTL=1800 \
                /usr/local/bin/nas-alert.sh "🔴 Detecté un problema con el $label
Intenté recuperarlo, pero sigue sin responder.
Punto de montaje: $mountpoint
Disco esperado: $device_hint
Qué correr (TV Box):
Insumo: no aplica.
1) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
2) mount | grep -E '/mnt/storage-main|/mnt/storage-backup|/mnt/merged'
3) /usr/local/bin/verify.sh
Mientras tanto, algunas tareas del NAS quedarán en pausa para proteger tus datos."
        else
            NAS_ALERT_KEY="mount_up:${mountpoint}" NAS_ALERT_TTL=900 \
                /usr/local/bin/nas-alert.sh "✅ Se recuperó el $label
Punto de montaje: $mountpoint
Disco: $device_hint
Qué contexto aplica:
- Dónde correr: TV Box
- Insumo: no aplica
Volvió a estar disponible y el NAS puede seguir trabajando con normalidad."
        fi
    fi
}

check_and_recover_mount() {
    local key="$1" mountpoint="$2" expected_fs="${3:-}"
    local prev curr fs fail_key fail_count up_key up_count

    prev="$(get_prev "$key")"
    curr="down"
    fail_key="${key}_down_count"
    fail_count="$(get_prev_num "$fail_key")"
    up_key="${key}_up_count"
    up_count="$(get_prev_num "$up_key")"

    if mountpoint -q "$mountpoint" 2>/dev/null; then
        curr="up"
    else
        mount "$mountpoint" >/dev/null 2>&1 || true
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            curr="up"
        fi
    fi

    # Validación opcional de tipo de FS (útil para mergerfs).
    if [ "$curr" = "up" ] && [ -n "$expected_fs" ]; then
        fs="$(findmnt -n -o FSTYPE "$mountpoint" 2>/dev/null || echo "")"
        if [ "$fs" != "$expected_fs" ]; then
            curr="down"
        fi
    fi

    if [ "$curr" = "up" ]; then
        set_state "$fail_key" "0"

        # Si venía caído, exigir 2 checks estables antes de avisar recuperación.
        if [ "$prev" = "down" ]; then
            up_count=$((up_count + 1))
            set_state "$up_key" "$up_count"
            if [ "$up_count" -ge 2 ]; then
                notify_transition "$key" "$mountpoint" "$prev" "up"
                set_state "$key" "up"
                set_state "$up_key" "0"
            fi
            return 0
        fi

        set_state "$up_key" "0"
        set_state "$key" "up"
        set_state "$fail_key" "0"
        return 0
    fi

    # curr = down (ya intentó mount y no se recuperó)
    set_state "$up_key" "0"
    fail_count=$((fail_count + 1))
    set_state "$fail_key" "$fail_count"

    # Anti-ruido: solo alertar down al segundo chequeo consecutivo.
    if [ "$fail_count" -ge 2 ] && [ "$prev" != "down" ]; then
        notify_transition "$key" "$mountpoint" "$prev" "down"
        set_state "$key" "down"
    fi
}

# Orden importante: primero discos base, luego mergerfs.
check_and_recover_mount "storage_main" "$MOUNT_MAIN"
check_and_recover_mount "storage_backup" "$MOUNT_BACKUP"
check_and_recover_mount "storage_merged" "$MOUNT_MERGED" "fuse.mergerfs"

# Si la recuperación local no alcanza y el disco principal quedó en falla grave,
# este paso activa failover de emergencia al respaldo operativo.
if [ -x "$FAILOVER_BIN" ]; then
    "$FAILOVER_BIN" auto >/dev/null 2>&1 || true
fi

exit 0
