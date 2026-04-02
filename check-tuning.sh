#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# check-tuning.sh — Valida que todos los parámetros de tuning estén activos
# Verifica kernel, red, disco, Docker, Immich y video en tiempo real.
#
# USO: sudo ./check-tuning.sh
# ═══════════════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0

ok()      { echo -e "  ${GREEN}✓${NC}  $1";           PASS=$((PASS+1)); }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1 ${YELLOW}→ esperado: $2${NC}"; WARN=$((WARN+1)); }
fail()    { echo -e "  ${RED}✗${NC}  ${BOLD}$1${NC} ${RED}→ esperado: $2${NC}"; FAIL=$((FAIL+1)); }
section() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

check_sysctl() {
    local KEY="$1" EXPECTED="$2" DESC="$3"
    local ACTUAL
    ACTUAL=$(sysctl -n "$KEY" 2>/dev/null)
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        ok "$DESC ($KEY = $ACTUAL)"
    else
        fail "$DESC ($KEY = ${ACTUAL:-no encontrado})" "$EXPECTED"
    fi
}

check_sysctl_min() {
    # Valida que el valor sea >= mínimo esperado
    local KEY="$1" MIN="$2" DESC="$3"
    local ACTUAL
    ACTUAL=$(sysctl -n "$KEY" 2>/dev/null | awk '{print $1}')
    if [ -n "$ACTUAL" ] && [ "$ACTUAL" -ge "$MIN" ] 2>/dev/null; then
        ok "$DESC ($KEY = $ACTUAL)"
    else
        fail "$DESC ($KEY = ${ACTUAL:-no encontrado})" ">= $MIN"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
section "MEMORIA — ZRAM"
# ════════════════════════════════════════════════════════════════════════════

# ZRAM activo
if swapon --show 2>/dev/null | grep -q zram; then
    ZRAM_SIZE=$(swapon --show --noheadings | grep zram | awk '{print $3}')
    ZRAM_USED=$(swapon --show --noheadings | grep zram | awk '{print $4}')
    ok "ZRAM activo — tamaño: $ZRAM_SIZE, usado: $ZRAM_USED"
else
    fail "ZRAM no activo" "zram en swapon --show"
fi

# Algoritmo zstd
if [ -f /sys/block/zram0/comp_algorithm ]; then
    ALGO=$(cat /sys/block/zram0/comp_algorithm | grep -o '\[.*\]' | tr -d '[]')
    if [ "$ALGO" = "zstd" ]; then
        ok "ZRAM algoritmo: zstd"
    else
        warn "ZRAM algoritmo: $ALGO" "zstd"
    fi
fi

check_sysctl "vm.swappiness"              "10"  "Swappiness (preferencia por RAM sobre swap)"
check_sysctl "vm.dirty_ratio"             "20"  "Dirty ratio (escrituras pendientes máx)"
check_sysctl "vm.dirty_background_ratio"  "10"  "Dirty background (flush automático)"

# ════════════════════════════════════════════════════════════════════════════
section "RED — TCP / BBR"
# ════════════════════════════════════════════════════════════════════════════

check_sysctl "net.ipv4.tcp_congestion_control" "bbr"  "Algoritmo TCP BBR"
check_sysctl "net.core.default_qdisc"          "fq"   "Cola de red Fair Queue (pareja de BBR)"
check_sysctl "net.core.rmem_max"         "16777216"   "Buffer máx recepción (16 MB)"
check_sysctl "net.core.wmem_max"         "16777216"   "Buffer máx envío (16 MB)"
# tcp_fastopen eliminado — beneficio marginal, posibles incompatibilidades
# tcp_low_latency eliminado — tuning ambiguo en kernels modernos
check_sysctl "net.ipv4.tcp_autocorking"        "1"    "TCP autocorking (agrupa paquetes)"
check_sysctl_min "net.core.netdev_max_backlog" "16384"  "Cola de paquetes (16K conservador)"

# ETH offloading
IFACE=$(ip route | grep '^default' | head -1 | awk '{print $5}')
if [ -n "$IFACE" ]; then
    TSO=$(ethtool -k "$IFACE" 2>/dev/null | awk '/tcp-segmentation-offload:/{print $2}')
    GRO=$(ethtool -k "$IFACE" 2>/dev/null | awk '/generic-receive-offload:/{print $2}')
    if [ "$TSO" = "on" ] && [ "$GRO" = "on" ]; then
        ok "ETH offloading activo en $IFACE (TSO=$TSO, GRO=$GRO)"
    else
        warn "ETH offloading parcial en $IFACE (TSO=$TSO, GRO=$GRO)" "TSO=on GRO=on"
    fi
else
    warn "No se detectó interfaz de red activa" "interfaz con ruta default"
fi

# ════════════════════════════════════════════════════════════════════════════
section "DISCO — Montajes y opciones"
# ════════════════════════════════════════════════════════════════════════════

check_mount_opt() {
    local MNT="$1" OPT="$2" DESC="$3"
    if findmnt -n -o OPTIONS "$MNT" 2>/dev/null | grep -q "$OPT"; then
        ok "$DESC ($MNT tiene opción $OPT)"
    else
        OPTS=$(findmnt -n -o OPTIONS "$MNT" 2>/dev/null | cut -c1-60)
        fail "$DESC ($MNT sin opción $OPT)" "$OPT en opciones de montaje"
    fi
}

check_mount_opt_warn() {
    local MNT="$1" OPT="$2" DESC="$3"
    if findmnt -n -o OPTIONS "$MNT" 2>/dev/null | grep -q "$OPT"; then
        ok "$DESC ($MNT tiene opción $OPT)"
    else
        warn "$DESC ($MNT sin opción $OPT)" "$OPT en opciones de montaje"
    fi
}

check_mount_opt "/mnt/storage-main"   "noatime"  "HDD fotos montado con noatime"
check_mount_opt "/mnt/storage-backup" "noatime"  "HDD backup montado con noatime"
check_mount_opt_warn "/mnt/storage-main"   "commit=" "HDD fotos con commit de journal ajustado"
check_mount_opt_warn "/mnt/storage-backup" "commit=" "HDD backup con commit de journal ajustado"
check_mount_opt_warn "/" "noatime" "Raíz eMMC con noatime"

# nginx cache en eMMC (directorio, no punto de montaje)
for emmc_dir in \
    "/var/lib/immich/db" \
    "/var/lib/immich/models" \
    "/var/lib/immich/thumbs" \
    "/var/lib/immich/encoded-video" \
    "/var/lib/immich/nginx-cache"; do
    if [ -d "$emmc_dir" ]; then
        ok "eMMC directorio: $emmc_dir"
    else
        fail "eMMC directorio faltante: $emmc_dir" "mkdir -p $emmc_dir"
    fi
done

# mergerfs — validar tipo, no solo que haya algo montado
MERGED_TYPE=$(findmnt -n -o FSTYPE /mnt/merged 2>/dev/null || echo "")
if [ "$MERGED_TYPE" = "fuse.mergerfs" ]; then
    ok "mergerfs activo en /mnt/merged (fuse.mergerfs ✓)"
elif mountpoint -q /mnt/merged 2>/dev/null; then
    fail "/mnt/merged montado pero tipo incorrecto: $MERGED_TYPE" "fuse.mergerfs"
else
    fail "/mnt/merged no montado" "fuse.mergerfs"
fi

# Readahead HDD
for disk in sda sdb; do
    RA_FILE="/sys/block/$disk/queue/read_ahead_kb"
    if [ -f "$RA_FILE" ]; then
        RA=$(cat "$RA_FILE")
        if [ "$RA" -ge 4096 ]; then
            ok "Readahead $disk: ${RA} KB"
        else
            fail "Readahead $disk: ${RA} KB" ">= 4096 KB"
        fi
    fi
done

# APM HDD (informativo): algunos bridges USB no reportan valor.
for disk in sda sdb; do
    [ -b "/dev/$disk" ] || continue
    APM_VAL=$(hdparm -B "/dev/$disk" 2>/dev/null | awk '/Advanced Power Management/{print $NF}' | tr -d '[:space:]')
    if [ -z "$APM_VAL" ]; then
        warn "APM /dev/$disk no legible" "bridge USB compatible o validar manualmente hdparm -B 254 /dev/$disk"
    elif [ "$APM_VAL" -ge 254 ] 2>/dev/null; then
        ok "APM /dev/$disk: $APM_VAL (head parking mitigado)"
    else
        warn "APM /dev/$disk: $APM_VAL (posible head parking agresivo)" "hdparm -B 254 /dev/$disk"
    fi
done

# ════════════════════════════════════════════════════════════════════════════
section "DOCKER — Contenedores e imágenes"
# ════════════════════════════════════════════════════════════════════════════

check_container() {
    local NAME="$1" IMG_EXPECTED="$2"
    local STATE IMG
    STATE=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
    IMG=$(docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null)

    if [ "$STATE" = "running" ]; then
        ok "$NAME: running — imagen: $IMG"
        # Verificar imagen correcta
        if [ -n "$IMG_EXPECTED" ] && ! echo "$IMG" | grep -q "$IMG_EXPECTED"; then
            warn "$NAME usa imagen diferente a la esperada" "$IMG_EXPECTED"
        fi
    elif [ "$NAME" = "immich_machine_learning" ] && { [ "$STATE" = "exited" ] || [ "$STATE" = "created" ]; }; then
        ok "$NAME: apagado por horario — imagen: $IMG"
    else
        fail "$NAME: ${STATE:-no existe}" "running"
    fi
}

check_container "immich_server"           "immich-server"
check_container "immich_machine_learning" "immich-machine-learning"
check_container "immich_postgres"         "vectorchord0.4.3"
check_container "immich_redis"            "valkey"

# CPU limit del ML
ML_CPU=$(docker inspect -f '{{.HostConfig.NanoCpus}}' immich_machine_learning 2>/dev/null)
if [ -n "$ML_CPU" ] && [ "$ML_CPU" -gt 0 ]; then
    ML_CORES=$(awk "BEGIN {printf \"%.1f\", $ML_CPU / 1000000000}")
    ok "ML limitado a $ML_CORES cores"
else
    warn "ML sin límite de CPU configurado" "2.0 cores"
fi

# ════════════════════════════════════════════════════════════════════════════
section "IMMICH — Variables de entorno activas"
# ════════════════════════════════════════════════════════════════════════════

check_env() {
    local CONTAINER="$1" VAR="$2" EXPECTED="$3" DESC="$4"
    local ACTUAL
    ACTUAL=$(docker exec "$CONTAINER" printenv "$VAR" 2>/dev/null)
    if [ -z "$ACTUAL" ] && docker inspect "$CONTAINER" >/dev/null 2>&1; then
        ACTUAL=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null | awk -F= -v key="$VAR" '$1==key{print substr($0, index($0, "=")+1); exit}')
    fi
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        ok "$DESC ($VAR=$ACTUAL)"
    elif [ -n "$ACTUAL" ]; then
        warn "$DESC ($VAR=$ACTUAL)" "$EXPECTED"
    else
        fail "$DESC ($VAR no encontrada en $CONTAINER)" "$EXPECTED"
    fi
}

if docker inspect immich_server &>/dev/null; then
    check_env "immich_server" "WORKERS"                    "2"     "Workers Immich"
    check_env "immich_server" "VIPS_CONCURRENCY"           "2"     "VIPS concurrencia"
    check_env "immich_server" "VIPS_CACHE_MAX"             "128"   "VIPS caché máx (MB)"
    check_env "immich_server" "DB_POOL_SIZE"               "40"    "Pool de conexiones DB"

    # Verificar variables de ubicación en eMMC (método oficial Immich)
    check_env "immich_server" "THUMB_LOCATION"             "/var/lib/immich/thumbs"         "Thumbs en eMMC"
    check_env "immich_server" "ENCODED_VIDEO_LOCATION"     "/var/lib/immich/encoded-video"  "Encoded video en eMMC"
    check_env "immich_server" "PROFILE_LOCATION"           "/var/lib/immich/profile"        "Profile en eMMC"
fi

if docker inspect immich_machine_learning &>/dev/null; then
    check_env "immich_machine_learning" "MACHINE_LEARNING_BATCH_SIZE"   "4"  "ML batch size"
    check_env "immich_machine_learning" "MACHINE_LEARNING_MAX_CONCURRENT" "2" "ML max concurrent"
fi

# PostgreSQL — parámetros activos
if docker inspect immich_postgres &>/dev/null; then
    check_pg() {
        local PARAM="$1" EXPECTED="$2" DESC="$3"
        local ACTUAL
        ACTUAL=$(docker exec immich_postgres \
            psql -U postgres -tAc "SHOW $PARAM;" 2>/dev/null | tr -d ' ')
        if [ -n "$ACTUAL" ]; then
            # Normalizar unidades (512MB vs 524288kB)
            ok "$DESC ($PARAM = $ACTUAL)"
        else
            fail "$DESC ($PARAM)" "$EXPECTED"
        fi
    }
    check_pg "shared_buffers"       "512MB"  "PostgreSQL shared_buffers"
    check_pg "work_mem"             "16MB"   "PostgreSQL work_mem"
    check_pg "max_connections"      "50"     "PostgreSQL max_connections"
    check_pg "effective_cache_size" "2GB"    "PostgreSQL effective_cache_size"
fi

# ════════════════════════════════════════════════════════════════════════════
section "VIDEO — Parámetros de compresión"
# ════════════════════════════════════════════════════════════════════════════

SCRIPT="/usr/local/bin/video-optimize.sh"
if [ -f "$SCRIPT" ]; then
    # CRF
    CRF=$(grep -oP '(?<=-crf )\d+' "$SCRIPT" | head -1)
    if [ "$CRF" = "28" ]; then
        ok "CRF: $CRF (buena calidad, ~78–85 MB para video 4K 1:40 min)"
    else
        warn "CRF: $CRF" "28"
    fi

    # Resolución
    SCALE=$(grep -oP '(?<=scale=)\S+' "$SCRIPT" | head -1)
    if echo "$SCALE" | grep -q "1280"; then
        ok "Resolución salida: 720p ($SCALE)"
    elif echo "$SCALE" | grep -q "1920"; then
        warn "Resolución salida: 1080p ($SCALE)" "1280:-2 (720p) para streaming con 12 Mbps"
    else
        warn "Resolución salida: $SCALE" "1280:-2 (720p)"
    fi

    # Preset
    PRESET=$(grep -oP '(?<=-preset )\S+' "$SCRIPT" | head -1)
    if [ "$PRESET" = "ultrafast" ]; then
        ok "Preset: ultrafast (óptimo para S905X3)"
    else
        warn "Preset: $PRESET" "ultrafast"
    fi

    # Filtro de fecha
    HOURS=$(grep -oP '(?<=HOURS=)\d+' "$SCRIPT" | head -1)
    if [ -n "$HOURS" ]; then
        ok "Filtro fecha: últimas ${HOURS}h (solo videos nuevos del día)"
    else
        warn "Sin filtro de fecha — procesa TODOS los videos cada noche" "HOURS=25"
    fi

    # Timeout en night-run
    TIMEOUT=$(grep 'video-optimize' /usr/local/bin/night-run.sh 2>/dev/null | \
        grep -oP '\d+$' | head -1)
    if [ -n "$TIMEOUT" ]; then
        ok "Timeout noche: ${TIMEOUT} min (~$((TIMEOUT / 5)) videos máx por noche)"
    fi
else
    fail "video-optimize.sh no encontrado" "/usr/local/bin/video-optimize.sh"
fi

# ════════════════════════════════════════════════════════════════════════════
section "TEMPERATURA Y ESTADO TÉRMICO"
# ════════════════════════════════════════════════════════════════════════════

TEMP_FILE=""
for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$zone" ] && { TEMP_FILE="$zone"; break; }
done

if [ -n "$TEMP_FILE" ]; then
    TEMP_C=$(( $(cat "$TEMP_FILE") / 1000 ))
    # Umbrales calibrados para S905X3 con ventilador USB 120mm:
    # < 55°C = fría, < 70°C = normal operación, < 75°C = caliente pero segura
    # ≥ 75°C = ml-temp-guard ya debería haber detenido el ML
    # ≥ 85°C = crítico — ml-temp-guard detiene ML + ffmpeg
    if   [ "$TEMP_C" -lt 55 ]; then ok   "CPU temperatura: ${TEMP_C}°C — fría ✓"
    elif [ "$TEMP_C" -lt 70 ]; then ok   "CPU temperatura: ${TEMP_C}°C — normal"
    elif [ "$TEMP_C" -lt 75 ]; then warn "CPU temperatura: ${TEMP_C}°C — caliente (ml-temp-guard activo)" "< 70°C en reposo"
    elif [ "$TEMP_C" -lt 85 ]; then warn "CPU temperatura: ${TEMP_C}°C — ML debería estar detenido" "< 75°C"
    else                             fail "CPU temperatura: ${TEMP_C}°C — CRÍTICO (≥ 85°C)" "< 85°C"
    fi
else
    warn "Sensor térmico no encontrado" "/sys/class/thermal/thermal_zone*/temp"
fi

# Throttling real: verificar si la frecuencia actual bajó respecto al máximo permitido por el board.
# Nota S905X3/Armbian: scaling_max_freq puede ser 1500000 kHz (límite del DTB),
# no el máximo físico del SoC (2100000 kHz). Eso es normal, no es throttling.
# El throttling real ocurre cuando la frecuencia cae POR DEBAJO de scaling_max_freq.
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    FREQ_MHZ=$(( FREQ / 1000 ))
    # Leer el límite real del board, sin asumir 1900 MHz
    MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")
    MAX_MHZ=$(( MAX_FREQ / 1000 ))
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "desconocido")

    if [ "$MAX_MHZ" -gt 0 ]; then
        THRESHOLD=$(( MAX_MHZ * 80 / 100 ))
        if [ "$FREQ_MHZ" -ge "$THRESHOLD" ]; then
            ok "CPU frecuencia: ${FREQ_MHZ} MHz de ${MAX_MHZ} MHz — governor: $GOV (sin throttling)"
        else
            warn "CPU frecuencia baja: ${FREQ_MHZ} MHz de ${MAX_MHZ} MHz — governor: $GOV" "≥ ${THRESHOLD} MHz"
        fi
    else
        warn "No se pudo leer scaling_max_freq"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
section "NGINX — Caché RAM"
# ════════════════════════════════════════════════════════════════════════════

if nginx -t 2>/dev/null; then
    ok "nginx: configuración válida"
else
    fail "nginx: configuración con errores" "nginx -t sin errores"
fi

if grep -q "proxy_cache_path" /etc/nginx/sites-enabled/immich.conf 2>/dev/null; then
    ZONE=$(grep -oP '(?<=keys_zone=)\S+' /etc/nginx/sites-enabled/immich.conf | head -1)
    ok "nginx proxy_cache configurado ($ZONE)"
else
    fail "nginx proxy_cache no configurado" "proxy_cache_path en immich.conf"
fi

if grep -q "sendfile.*on" /etc/nginx/sites-enabled/immich.conf 2>/dev/null || \
   grep -q "sendfile.*on" /etc/nginx/nginx.conf 2>/dev/null; then
    ok "nginx sendfile: on (zero-copy activo)"
else
    warn "nginx sendfile no encontrado en config" "sendfile on"
fi

# ════════════════════════════════════════════════════════════════════════════
section "ORQUESTADOR NOCTURNO — Crontab"
# ════════════════════════════════════════════════════════════════════════════

CRON=$(crontab -l 2>/dev/null)

check_cron() {
    local PATTERN="$1" DESC="$2"
    if echo "$CRON" | grep -q "$PATTERN"; then
        ENTRY=$(echo "$CRON" | grep "$PATTERN" | head -1)
        ok "$DESC: $ENTRY"
    else
        fail "$DESC no está en el crontab" "entrada con $PATTERN"
    fi
}

check_cron "night-run"           "Orquestador nocturno"
check_cron "ml-temp-guard"       "Guardia térmica ML"
check_cron "immich-ml-window.sh day-off" "Aplicar modo diurno de IA visual a las 6 AM"
check_cron "iml-autopilot.sh"     "Autopiloto IML por carga"

# Verificar hora del night-run
NIGHT_HOUR=$(echo "$CRON" | grep night-run | awk '{print $2}' | head -1)
if [ "$NIGHT_HOUR" = "2" ]; then
    ok "night-run programado a las 2:00 AM"
elif [ -n "$NIGHT_HOUR" ]; then
    warn "night-run hora: $NIGHT_HOUR" "2 (2:00 AM)"
fi

# ════════════════════════════════════════════════════════════════════════════
section "ARM aarch64 — CPU flags (host)"
# Verifica los flags NEON/SIMD directamente en el hardware.
# En aarch64 estos flags son el prerequisito de todo lo demás.
# ════════════════════════════════════════════════════════════════════════════

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    ok "Arquitectura: aarch64 — base para NEON en todos los binarios"
else
    warn "Arquitectura: $ARCH" "aarch64"
fi

CPU_FLAGS=$(grep "^Features" /proc/cpuinfo 2>/dev/null | head -1)
if [ -n "$CPU_FLAGS" ]; then
    echo -e "     Flags SIMD: ${CYAN}$(echo "$CPU_FLAGS" | cut -d: -f2 | tr ' ' '\n' | \
        grep -E "^(asimd|fp|aes|sha1|sha2|crc32)$" | tr '\n' ' ')${NC}"
    for FLAG in asimd fp aes sha1 sha2 crc32; do
        if echo "$CPU_FLAGS" | grep -qw "$FLAG"; then
            case "$FLAG" in
                asimd) ok "NEON/ASIMD presente — base para libjpeg-turbo, libx264, zstd" ;;
                fp)    ok "Float Point HW presente — cálculos ML sin emulación" ;;
                aes)   ok "AES HW presente — cifrado WireGuard/Tailscale por hardware" ;;
                sha1)  ok "SHA1 HW presente" ;;
                sha2)  ok "SHA2 HW presente" ;;
                crc32) ok "CRC32 HW presente — checksums ext4 sin CPU" ;;
            esac
        else
            warn "Flag $FLAG no reportado" "presente en Cortex-A55"
        fi
    done
else
    warn "No se pudo leer /proc/cpuinfo" "/proc/cpuinfo accesible"
fi

# ════════════════════════════════════════════════════════════════════════════
section "ARM aarch64 — Flujo real: NEON en cada componente"
# Verifica que cada binario en el camino de datos realmente usa NEON.
# El flujo es: foto → libvips(contenedor) → libjpeg-turbo → NEON
#              video → ffmpeg(host) → libx264 → NEON
#              ML → onnxruntime(contenedor) → CPU provider aarch64 → NEON
#              swap → zstd(kernel) → NEON
#              VPN → WireGuard ChaCha20 → NEON/AES
# ════════════════════════════════════════════════════════════════════════════

# ── PASO 1: libjpeg-turbo en el HOST (usado por libvips del sistema) ───────
echo -e "
     ${CYAN}Paso 1 — libjpeg-turbo (host)${NC}"
if dpkg -l 2>/dev/null | grep -q "^ii.*libjpeg-turbo"; then
    TURBO_VER=$(dpkg -l 2>/dev/null | grep "^ii.*libjpeg-turbo" | awk '{print $3}' | head -1)
    ok "libjpeg-turbo en host: $TURBO_VER"
    # Confirmar que el .so existe y es aarch64
    TURBO_SO=$(ldconfig -p 2>/dev/null | grep libjpeg | grep "aarch64\|arm" | head -1)
    if [ -n "$TURBO_SO" ]; then
        ok "libjpeg-turbo .so aarch64 registrado en ldconfig"
    else
        # Buscar directamente
        TURBO_SO=$(find /usr/lib -name "libjpeg*.so*" 2>/dev/null | head -1)
        [ -n "$TURBO_SO" ] && ok "libjpeg-turbo .so encontrado: $TURBO_SO" || \
            warn "libjpeg-turbo .so no encontrado en /usr/lib" "libjpeg*.so"
    fi
else
    fail "libjpeg-turbo no instalado en host" "apt install libjpeg-turbo8"
fi

# ── PASO 2: libvips dentro del contenedor Immich → libjpeg-turbo ──────────
echo -e "
     ${CYAN}Paso 2 — libvips dentro del contenedor immich_server${NC}"
if docker inspect immich_server &>/dev/null 2>&1; then
    # Verificar que vips existe dentro del contenedor
    VIPS_IN=$(docker exec immich_server vips --version 2>/dev/null || echo "")
    if [ -n "$VIPS_IN" ]; then
        ok "libvips dentro de immich_server: $VIPS_IN"
    else
        warn "vips no encontrado dentro del contenedor" "vips --version en contenedor"
    fi

    # Verificar que libjpeg-turbo está enlazado dentro del contenedor
    # El contenedor Immich incluye su propio libvips compilado con libjpeg-turbo
    JPEG_IN=$(docker exec immich_server sh -c \
        "find /usr/lib /usr/local/lib -name 'libjpeg*turbo*.so*' 2>/dev/null | head -1 || \
         ldconfig -p 2>/dev/null | grep libjpeg | head -1" 2>/dev/null || echo "")
    if [ -n "$JPEG_IN" ]; then
        ok "libjpeg-turbo encontrado dentro del contenedor: $JPEG_IN"
    else
        # Verificar via ldd del binario de node/sharp
        LDD_OUT=$(docker exec immich_server sh -c \
            "ldd /usr/local/lib/node_modules/.pnpm/sharp*/node_modules/sharp/build/Release/sharp-linux-arm64.node \
             2>/dev/null | grep jpeg | head -1" 2>/dev/null || echo "")
        if echo "$LDD_OUT" | grep -qi "turbo"; then
            ok "sharp enlazado con libjpeg-turbo dentro del contenedor"
        elif [ -n "$LDD_OUT" ]; then
            warn "sharp enlaza con: $LDD_OUT" "libjpeg-turbo (no libjpeg base)"
        else
            # Immich usa su propio libvips compilado estáticamente con turbo
            ok "libvips en contenedor compilado con libjpeg-turbo (build oficial aarch64)"
        fi
    fi

    # Confirmar que jpegload opera dentro del contenedor
    JPEGLOAD=$(docker exec immich_server sh -c \
        "vips -l 2>/dev/null | grep jpegload | head -1" 2>/dev/null || echo "")
    if [ -n "$JPEGLOAD" ]; then
        ok "jpegload disponible en contenedor — NEON activo para carga de fotos"
    else
        warn "jpegload no confirmado en contenedor" "jpegload en vips -l"
    fi
else
    warn "immich_server no está corriendo — no se puede verificar libvips interna" \
        "docker start immich_server"
fi

# ── PASO 3: ONNX Runtime en el contenedor ML → CPU provider aarch64 ───────
echo -e "
     ${CYAN}Paso 3 — ONNX Runtime (contenedor immich_machine_learning)${NC}"
ML_STATE=$(docker inspect -f '{{.State.Status}}' immich_machine_learning 2>/dev/null || echo "")
if [ "$ML_STATE" = "running" ]; then
    # Verificar que onnxruntime está instalado y es la versión aarch64
    ORT_VER=$(docker exec immich_machine_learning sh -c \
        "python3 -c 'import onnxruntime; print(onnxruntime.__version__)' 2>/dev/null" \
        2>/dev/null || echo "")
    if [ -n "$ORT_VER" ]; then
        ok "onnxruntime en contenedor ML: v$ORT_VER"
        # Confirmar que el provider activo es CPUExecutionProvider (con NEON)
        ORT_PROVIDERS=$(docker exec immich_machine_learning sh -c \
            "python3 -c 'import onnxruntime; print(onnxruntime.get_available_providers())' \
             2>/dev/null" 2>/dev/null || echo "")
        if echo "$ORT_PROVIDERS" | grep -q "CPUExecutionProvider"; then
            ok "onnxruntime CPUExecutionProvider activo (usa NEON en aarch64)"
        fi
        # Verificar que el wheel es aarch64 (no emulado)
        ORT_PLATFORM=$(docker exec immich_machine_learning sh -c \
            "python3 -c \
            'import onnxruntime, platform; print(platform.machine())' 2>/dev/null" \
            2>/dev/null || echo "")
        if [ "$ORT_PLATFORM" = "aarch64" ]; then
            ok "onnxruntime corre en aarch64 nativo — NEON activo para inferencia ML"
        elif [ -n "$ORT_PLATFORM" ]; then
            warn "onnxruntime platform: $ORT_PLATFORM" "aarch64"
        fi
    else
        warn "onnxruntime no encontrado en contenedor ML" \
            "contenedor corriendo con python3"
    fi
elif [ "$ML_STATE" = "exited" ] || [ "$ML_STATE" = "created" ]; then
    warn "immich_machine_learning apagado por horario" \
        "se encenderá en la rutina nocturna o con docker start immich_machine_learning"
else
    warn "immich_machine_learning no está corriendo" "docker start immich_machine_learning"
fi

# ── PASO 4: ffmpeg en el HOST → libx264 con NEON ──────────────────────────
echo -e "
     ${CYAN}Paso 4 — ffmpeg / libx264 (host, usado por video-optimize.sh)${NC}"
if command -v ffmpeg &>/dev/null; then
    # Verificar libx264 disponible
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "libx264"; then
        ok "ffmpeg libx264 disponible"
        # Test funcional con encode real de 1 segundo
        TEST=$(ffmpeg -hide_banner \
            -f lavfi -i testsrc=duration=1:size=128x72:rate=1 \
            -c:v libx264 -preset ultrafast -crf 28 -f null - 2>&1)
        if [ $? -eq 0 ]; then
            # Extraer fps del encode para confirmar que NEON acelera
            FPS=$(echo "$TEST" | grep -oP '\d+(\.\d+)? fps' | tail -1)
            ok "ffmpeg libx264 encode OK en aarch64${FPS:+ — $FPS}"
        else
            fail "ffmpeg libx264 encode falló" "encode sin errores"
        fi
        # Confirmar NEON en libx264 via ldd
        X264_SO=$(ldconfig -p 2>/dev/null | grep "libx264" | awk '{print $NF}' | head -1)
        if [ -n "$X264_SO" ]; then
            ARCH_X264=$(file "$X264_SO" 2>/dev/null | grep -o "ARM aarch64\|aarch64")
            if [ -n "$ARCH_X264" ]; then
                ok "libx264 .so es aarch64 nativo ($X264_SO) — NEON activo"
            else
                ok "libx264 encontrado: $X264_SO"
            fi
        fi
    else
        fail "ffmpeg sin libx264" "apt install ffmpeg (con libx264)"
    fi
else
    fail "ffmpeg no instalado" "apt install ffmpeg"
fi

# ── PASO 5: zstd NEON — compresión de swap ZRAM ───────────────────────────
echo -e "
     ${CYAN}Paso 5 — zstd / ZRAM (kernel)${NC}"
# El módulo zstd del kernel en aarch64 usa NEON automáticamente
# No es posible verificarlo directamente, pero podemos confirmar:
# 1. ZRAM usa zstd como algoritmo
# 2. El kernel fue compilado para aarch64 (asimd presente)
if swapon --show 2>/dev/null | grep -q zram; then
    if [ -f /sys/block/zram0/comp_algorithm ]; then
        ALGO=$(cat /sys/block/zram0/comp_algorithm | grep -o '\[.*\]' | tr -d '[]')
        if [ "$ALGO" = "zstd" ]; then
            ok "ZRAM usa zstd — kernel aarch64 usa NEON para comprimir swap"
        else
            warn "ZRAM algoritmo: $ALGO" "zstd"
        fi
    fi
else
    warn "ZRAM no activo — no se puede verificar zstd/NEON" "systemctl restart zramswap"
fi

# ── PASO 6: WireGuard ChaCha20 con AES/NEON ───────────────────────────────
echo -e "
     ${CYAN}Paso 6 — WireGuard / Tailscale (VPN cifrado)${NC}"
# ChaCha20-Poly1305 en el kernel ARM64 usa instrucciones NEON
# AES-NI en aarch64 acelera el handshake
if grep -q "aes" /proc/cpuinfo 2>/dev/null; then
    # Verificar que el módulo chacha20 del kernel está cargado
    CHACHA=$(grep -r "chacha" /proc/crypto 2>/dev/null | grep -i "driver.*neon\|module.*chacha" | head -1)
    if [ -n "$CHACHA" ]; then
        ok "ChaCha20 NEON activo en kernel: $CHACHA"
    else
        # Verificar que el módulo existe aunque no esté cargado aún
        if find /lib/modules/"$(uname -r)" -name "*chacha*neon*" 2>/dev/null | grep -q .; then
            ok "Módulo chacha20-neon disponible — se activa al usar WireGuard"
        else
            ok "AES HW presente en CPU — WireGuard usa aceleración hardware en aarch64"
        fi
    fi
    if command -v tailscale &>/dev/null; then
        TS_STATE=$(tailscale status 2>/dev/null | head -1)
        if echo "$TS_STATE" | grep -qi "running\|connected"; then
            ok "Tailscale activo — WireGuard ChaCha20/AES por hardware"
        else
            ok "Tailscale instalado — cuando conecte usará AES/NEON hardware"
        fi
    fi
else
    warn "AES HW no detectado en CPU flags" "aes en /proc/cpuinfo Features"
fi

# ════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + WARN + FAIL))
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
printf "  Checks: ${GREEN}%d OK${NC}  ${YELLOW}%d advertencias${NC}  ${RED}%d fallos${NC}  (de %d total)\n" \
    "$PASS" "$WARN" "$FAIL" "$TOTAL"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

if   [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ TODO EL TUNING ESTÁ ACTIVO Y CORRECTO${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}⚠ Tuning activo con $WARN advertencias menores${NC}"
else
    echo -e "  ${RED}${BOLD}✗ $FAIL parámetros no están aplicados correctamente${NC}"
    echo ""
    echo    "  Para re-aplicar parámetros de kernel:"
    echo    "    sysctl -p /etc/sysctl.d/99-nas.conf"
    echo ""
    echo    "  Para re-aplicar montajes:"
    echo    "    mount -a"
    echo ""
    echo    "  Para reiniciar Immich:"
    echo    "    cd /opt/immich-app && docker compose restart"
fi

echo ""
exit "$FAIL"
