#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# install.sh — Instalador maestro NAS S905X3 / Armbian
# Guía Maestra NAS V58
#
# ── USO ──────────────────────────────────────────────────────────────────
# 1. Editar config/nas.conf con tus valores reales
# 2. chmod +x install.sh && sudo ./install.sh
# Para usar otro perfil (por ejemplo WSL laboratorio):
#    sudo NAS_CONFIG_FILE=/ruta/al/perfil.conf ./install.sh
#
# ── IDEMPOTENCIA ─────────────────────────────────────────────────────────
# El script es seguro de re-ejecutar si algo falla a la mitad:
# - format_disk: omite discos que ya tienen ext4
# - add_fstab: no duplica entradas existentes
# - Docker: omite instalación si ya está presente
# - Scripts: sobreescribe con install -m 0755 (siempre la versión correcta)
# - Crontab: omite si ya tiene night-run configurado
#
# ── HARDWARE OBJETIVO ────────────────────────────────────────────────────
# TV Box: Amlogic S905X3, 4× Cortex-A55 @ 1.9 GHz, 4 GB DDR4
# eMMC:   128 GB interna (bus dedicado al SoC)
# USB 3.0: HDD 7200 RPM (fotos originales)
# USB 2.0: HDD backup
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colores para output legible ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step()  { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
log_ok()    { echo -e "  ${GREEN}✓${NC}  $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "  ${RED}✗${NC}  $1"; }
log_info()  { echo -e "     $1"; }
die()       { log_error "$1"; exit 1; }
wait_for_docker_api() {
    local attempt
    for attempt in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

docker_wsl_fallback() {
    if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_INTEROP:-}" ]; then
        return 1
    fi

    log_warn "Docker no respondió por systemd en WSL. Intentaré levantar dockerd de apoyo para el laboratorio."
    nohup dockerd >/var/log/dockerd-manual.log 2>&1 &
    wait_for_docker_api
}
partition_path() {
    case "$1" in
        /dev/loop*|/dev/nvme*|/dev/mmcblk*) echo "${1}p1" ;;
        *) echo "${1}1" ;;
    esac
}
wait_for_immich_postgres() {
    local db_user db_name attempt
    db_user="${DB_USERNAME:-immich}"
    db_name="${DB_DATABASE_NAME:-immich}"

    for attempt in $(seq 1 30); do
        if docker exec immich_postgres \
            psql -U "$db_user" -d "$db_name" -At -c 'select 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}
seed_immich_conservative_ai_defaults() {
    local db_user db_name
    db_user="${DB_USERNAME:-immich}"
    db_name="${DB_DATABASE_NAME:-immich}"
    IMMICH_CONFIG_PROFILE_CHANGED=0

    if docker exec -i immich_postgres \
        psql -U "$db_user" -d "$db_name" >/dev/null 2>&1 <<'SQL'
DO $$
DECLARE
    cfg jsonb := COALESCE(
        (SELECT value FROM system_metadata WHERE key = 'system-config'),
        '{}'::jsonb
    );
BEGIN
    IF NOT (cfg ? 'machineLearning') THEN
        cfg := jsonb_set(
            cfg,
            '{machineLearning}',
            '{"enabled":true,"clip":{"enabled":true},"duplicateDetection":{"enabled":false},"facialRecognition":{"enabled":false},"ocr":{"enabled":false}}'::jsonb,
            true
        );
    END IF;

    IF cfg #> '{machineLearning,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,enabled}', 'true'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,clip}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,clip}', '{"enabled":true}'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,clip,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,clip,enabled}', 'true'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,duplicateDetection}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,duplicateDetection}', '{"enabled":false}'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,duplicateDetection,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,duplicateDetection,enabled}', 'false'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,facialRecognition}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,facialRecognition}', '{"enabled":false}'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,facialRecognition,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,facialRecognition,enabled}', 'false'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,ocr}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,ocr}', '{"enabled":false}'::jsonb, true);
    END IF;
    IF cfg #> '{machineLearning,ocr,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{machineLearning,ocr,enabled}', 'false'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'map') THEN
        cfg := jsonb_set(cfg, '{map}', '{"enabled":true}'::jsonb, true);
    END IF;
    IF cfg #> '{map,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{map,enabled}', 'true'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'reverseGeocoding') THEN
        cfg := jsonb_set(cfg, '{reverseGeocoding}', '{"enabled":true}'::jsonb, true);
    END IF;
    IF cfg #> '{reverseGeocoding,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{reverseGeocoding,enabled}', 'true'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'nightlyTasks') THEN
        cfg := jsonb_set(cfg, '{nightlyTasks}', '{"clusterNewFaces":false}'::jsonb, true);
    END IF;
    IF cfg #> '{nightlyTasks,clusterNewFaces}' IS NULL THEN
        cfg := jsonb_set(cfg, '{nightlyTasks,clusterNewFaces}', 'false'::jsonb, true);
    END IF;
    IF cfg #> '{nightlyTasks,generateMemories}' IS NULL THEN
        cfg := jsonb_set(cfg, '{nightlyTasks,generateMemories}', 'false'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'backup') THEN
        cfg := jsonb_set(cfg, '{backup}', '{"database":{"enabled":false}}'::jsonb, true);
    END IF;
    IF cfg #> '{backup,database}' IS NULL THEN
        cfg := jsonb_set(cfg, '{backup,database}', '{"enabled":false}'::jsonb, true);
    END IF;
    IF cfg #> '{backup,database,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{backup,database,enabled}', 'false'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'library') THEN
        cfg := jsonb_set(cfg, '{library}', '{"scan":{"enabled":false}}'::jsonb, true);
    END IF;
    IF cfg #> '{library,scan}' IS NULL THEN
        cfg := jsonb_set(cfg, '{library,scan}', '{"enabled":false}'::jsonb, true);
    END IF;
    IF cfg #> '{library,scan,enabled}' IS NULL THEN
        cfg := jsonb_set(cfg, '{library,scan,enabled}', 'false'::jsonb, true);
    END IF;

    IF NOT (cfg ? 'ffmpeg') THEN
        cfg := jsonb_set(cfg, '{ffmpeg}', '{"transcode":"disabled"}'::jsonb, true);
    END IF;
    IF cfg #> '{ffmpeg,transcode}' IS NULL THEN
        cfg := jsonb_set(cfg, '{ffmpeg,transcode}', '"disabled"'::jsonb, true);
    END IF;

    INSERT INTO system_metadata(key, value)
    VALUES ('system-config', cfg)
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value;
END $$;
SQL
    then
        IMMICH_CONFIG_PROFILE_CHANGED=1
        log_ok "Perfil Immich aplicado: Smart Search activo; OCR/caras/duplicados apagados; transcode, backup DB, memories y scan externo desactivados"
    else
        log_warn "No se pudo sembrar el perfil IA conservador de Immich"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/config/nas.conf"
CONFIG="${NAS_CONFIG_FILE:-${NAS_CONFIG:-$DEFAULT_CONFIG}}"
LOG="/var/log/nas-install.log"

# ════════════════════════════════════════════════════════════════════════════
# 0. PRE-FLIGHT — Validaciones antes de tocar nada
# ════════════════════════════════════════════════════════════════════════════
log_step "Verificaciones previas"

[ "$EUID" -eq 0 ] || die "Ejecutar como root: sudo ./install.sh"
[ -f "$CONFIG" ]  || die "No se encontró el archivo de configuración: $CONFIG"

source "$CONFIG"

normalize_install_mode() {
    case "${1:-}" in
        new|nueva|nuevo|fresh|install|instalacion) echo "new" ;;
        restore|restauracion|restauración|recovery|recover) echo "restore" ;;
        *) echo "" ;;
    esac
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

INSTALL_MODE_RAW="${INSTALL_MODE:-${NAS_INSTALL_MODE:-}}"
if [ -n "$INSTALL_MODE_RAW" ]; then
    INSTALL_MODE="$(normalize_install_mode "$INSTALL_MODE_RAW")"
    [ -n "$INSTALL_MODE" ] || die "INSTALL_MODE inválido: $INSTALL_MODE_RAW (usar: new o restore)"
else
    echo ""
    echo "Modo de instalación:"
    echo "  1) Nueva instalación (puede formatear según ALLOW_FORMAT)"
    echo "  2) Restauración (NUNCA formatea; reutiliza discos existentes)"
    read -r -p "  Elige 1 o 2: " MODE_CHOICE
    case "$MODE_CHOICE" in
        1) INSTALL_MODE="new" ;;
        2) INSTALL_MODE="restore" ;;
        *) die "Opción inválida. Cancelado para proteger datos." ;;
    esac
fi

if [ "$INSTALL_MODE" = "restore" ]; then
    ALLOW_FORMAT="no"
    log_warn "Modo restauración activo: se desactiva cualquier formateo automático."
fi

INSTALL_ASSUME_YES="${INSTALL_ASSUME_YES:-0}"
INSTALL_FORCE_FORMAT="${INSTALL_FORCE_FORMAT:-0}"

# Validación previa del paquete y sintaxis de scripts críticos
if [ -x "$SCRIPT_DIR/precheck.sh" ]; then
    "$SCRIPT_DIR/precheck.sh" || die "precheck.sh falló; abortando instalación"
else
    die "precheck.sh no existe o no es ejecutable"
fi


# Campos obligatorios
[ -n "${DISK_PHOTOS:-}" ] || die "DISK_PHOTOS no definido en $CONFIG"
[ -n "${DISK_BACKUP:-}" ] || die "DISK_BACKUP no definido en $CONFIG"
[ -n "${DB_PASSWORD:-}" ] || die "DB_PASSWORD no definido en $CONFIG"
# Evitar instalación con contraseña por defecto — es un riesgo de seguridad
[[ "$DB_PASSWORD" != "CambiarEsto2024" ]] || die "Cambia DB_PASSWORD en $CONFIG antes de continuar"

# ── Perfil conservador de I/O (ajustable por nas.conf) ───────────────────
# HDD commit=120 reduce flush de journal sin llevar al extremo 300s.
# Root eMMC: noatime sí por defecto; commit tuning queda opcional.
STORAGE_COMMIT_INTERVAL_SEC="${STORAGE_COMMIT_INTERVAL_SEC:-120}"
ROOT_ENABLE_NOATIME="${ROOT_ENABLE_NOATIME:-1}"
ROOT_ENABLE_COMMIT_TUNING="${ROOT_ENABLE_COMMIT_TUNING:-0}"
ROOT_COMMIT_INTERVAL_SEC="${ROOT_COMMIT_INTERVAL_SEC:-300}"
HDD_APM_ENABLE="${HDD_APM_ENABLE:-1}"
HDD_APM_LEVEL="${HDD_APM_LEVEL:-254}"
ZRAM_ALGO="${ZRAM_ALGO:-zstd}"
ZRAM_PERCENT="${ZRAM_PERCENT:-30}"
ZRAM_USE_NAS_SERVICE="${ZRAM_USE_NAS_SERVICE:-1}"

# Verificar que los discos existen como block devices
for disk in "$DISK_PHOTOS" "$DISK_BACKUP"; do
    [ -b "$disk" ] || die "Disco no encontrado: $disk — verificar con: lsblk"
done

# Mostrar info de discos y pedir confirmación explícita
if [ "$INSTALL_MODE" = "restore" ]; then
    log_warn "Modo restauración: voy a reutilizar discos existentes sin formatear."
else
    log_warn "ADVERTENCIA: Los siguientes discos pueden ser particionados/formateados según ALLOW_FORMAT."
fi
for disk in "$DISK_PHOTOS" "$DISK_BACKUP"; do
    SIZE=$(lsblk -dn -o SIZE "$disk" 2>/dev/null || echo "?")
    MODEL=$(lsblk -dn -o MODEL "$disk" 2>/dev/null || echo "?")
    SERIAL=$(lsblk -dn -o SERIAL "$disk" 2>/dev/null || echo "sin-serial")
    log_info "  $disk — $MODEL ($SIZE) [SERIAL: $SERIAL]"
done
echo ""
if is_true "$INSTALL_ASSUME_YES"; then
    CONFIRM="si"
    log_warn "INSTALL_ASSUME_YES activo: se confirma continuidad automáticamente."
else
    read -r -p "  ¿Continuar? Escribe 'si' para confirmar: " CONFIRM
fi
[[ "$CONFIRM" == "si" ]] || die "Instalación cancelada por el usuario"

# Confirmación reforzada cuando ALLOW_FORMAT está activo.
# Evita borrado accidental por confusión de /dev/sdX.
if [ "$INSTALL_MODE" = "new" ] && [ "${ALLOW_FORMAT:-no}" = "yes" ]; then
    TOKEN="BORRAR-$(basename "$DISK_PHOTOS")-$(basename "$DISK_BACKUP")"
    log_warn "ALLOW_FORMAT=yes detectado."
    log_warn "Verifica modelo/serial con: lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT"
    echo ""
    if is_true "$INSTALL_ASSUME_YES"; then
        if is_true "$INSTALL_FORCE_FORMAT"; then
            FORMAT_CONFIRM="$TOKEN"
            log_warn "INSTALL_FORCE_FORMAT activo: se acepta confirmación destructiva no interactiva."
        else
            die "Modo no interactivo con ALLOW_FORMAT=yes requiere INSTALL_FORCE_FORMAT=1 para proteger datos."
        fi
    else
        read -r -p "  Confirmación destructiva: escribe '$TOKEN' para continuar: " FORMAT_CONFIRM
    fi
    [[ "$FORMAT_CONFIRM" == "$TOKEN" ]] || die "Confirmación destructiva inválida. Abortado para proteger discos."
fi

log_ok "Configuración válida"
log_info "Modo seleccionado: $INSTALL_MODE"
if [ "$INSTALL_MODE" = "new" ] && [ "${ALLOW_FORMAT:-no}" = "yes" ]; then
    log_warn "ALLOW_FORMAT=yes — los discos con particiones serán borrados con wipefs"
fi
# Redirigir todo el output al log de instalación para diagnóstico posterior
exec > >(tee -a "$LOG") 2>&1
echo "════ Instalación iniciada: $(date) ════" >> "$LOG"

# ════════════════════════════════════════════════════════════════════════════
# 1. SISTEMA BASE
# ════════════════════════════════════════════════════════════════════════════
log_step "Actualizando sistema"
apt-get update -q
apt-get upgrade -y -q
log_ok "Sistema actualizado"

# ════════════════════════════════════════════════════════════════════════════
# 2. DOCKER ENGINE OFICIAL
# ════════════════════════════════════════════════════════════════════════════
# IMPORTANTE: Instalar desde el repositorio oficial de Docker (docker.com),
# NO el paquete docker.io de Debian. Razones:
# - docker.io es una versión más antigua mantenida por Debian
# - No incluye docker compose v2 (plugin) — solo el legacy docker-compose v1
# - Las imágenes de Immich requieren docker compose v2
log_step "Instalando Docker Engine oficial"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log_ok "Docker ya instalado: $(docker --version)"
else
    # Limpiar versiones anteriores para evitar conflictos de paquetes
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    apt-get install -y -q ca-certificates curl gnupg

    DOCKER_REPO_DISTRO=$(. /etc/os-release && printf '%s' "${ID:-debian}")
    case "$DOCKER_REPO_DISTRO" in
        ubuntu|debian) ;;
        *) die "Distribución no soportada automáticamente para Docker: $DOCKER_REPO_DISTRO" ;;
    esac

    # GPG key oficial de Docker — garantiza que los paquetes son auténticos
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO_DISTRO/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Repositorio estable de Docker para la distro actual (Ubuntu o Debian)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/$DOCKER_REPO_DISTRO \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -q
    apt-get install -y -q \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin  # compose-plugin = v2

    log_ok "Docker instalado: $(docker --version)"
fi

# ── Límites de logs Docker ────────────────────────────────────────────────
# Sin límites, los logs de contenedores crecen indefinidamente en la eMMC.
# json-file con max-size=10m max-file=3: máximo 30 MB por contenedor.
# Para un NAS con 4 contenedores = máximo 120 MB de logs Docker en total.
log_step "Configurando límites de logs Docker"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKEREOF
if systemctl restart docker; then
    log_ok "Logs Docker limitados a 10 MB × 3 archivos por contenedor"
else
    log_warn "Docker dio un aviso al reiniciarse tras actualizar daemon.json. Verificando servicio..."
    systemctl start docker >/dev/null 2>&1 || true
    if systemctl is-active --quiet docker || wait_for_docker_api || docker_wsl_fallback; then
        log_ok "Docker siguió activo y tomó la configuración de logs"
    else
        die "Docker no quedó activo después de actualizar daemon.json"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 3. DEPENDENCIAS DEL STACK
# ════════════════════════════════════════════════════════════════════════════
log_step "Instalando dependencias"

# Nota: comentarios NO van en la misma línea que la continuación \
# Los comentarios de cada paquete están en la sección de documentación.
apt-get install -y -q \
    curl wget nano git htop \
    python3 \
    lm-sensors \
    zram-tools sysstat \
    smartmontools \
    hdparm \
    rsync \
    ffmpeg \
    ethtool \
    parted util-linux \
    nginx \
    libvips-tools \
    samba \
    mergerfs \
    libimage-exiftool-perl \
    bc

if apt-cache show linux-cpupower >/dev/null 2>&1; then
    apt-get install -y -q linux-cpupower
    log_ok "linux-cpupower instalado (control térmico/frecuencia recomendado)"
elif apt-cache show cpufrequtils >/dev/null 2>&1; then
    apt-get install -y -q cpufrequtils
    log_warn "cpufrequtils instalado como fallback legado"
else
    log_warn "No encontré linux-cpupower/cpufrequtils en esta distro; continúo sin ese ajuste"
fi

log_ok "Dependencias instaladas"

# ════════════════════════════════════════════════════════════════════════════
# 4. ZRAM — Swap comprimido en RAM
# ════════════════════════════════════════════════════════════════════════════
# ZRAM crea un dispositivo de swap que comprime los datos en RAM antes de
# "escribirlos al disco" (que en realidad es RAM comprimida).
# El resultado es RAM virtual adicional sin tocar el disco.
#
# Por qué es crítico con 4 GB:
# El stack Immich en carga usa ~3.2–3.7 GB (reposo ~2.4 GB).
# Sin ZRAM, si el sistema necesita más de 4 GB se va a swap real en disco
# (el HDD o la eMMC) — 100× más lento que RAM.
# Con ZRAM: ~1.2 GB de swap virtual adicional comprimido en RAM.
#
# Por qué zstd y no lz4:
# En ARM aarch64, zstd tiene rutas NEON optimizadas.
# zstd logra mejor ratio de compresión que lz4 a velocidad similar en A55.
# Más compresión = más RAM virtual por el mismo espacio.
#
# Por qué 30%:
# 30% de 4 GB = ~1.2 GB de swap virtual.
# Aumentar a 50% sería contraproducente: la RAM usada para el buffer ZRAM
# reduce la RAM disponible para los contenedores.
log_step "Configurando ZRAM"

cat > /etc/default/zramswap << EOF
ALGO=${ZRAM_ALGO}
PERCENT=${ZRAM_PERCENT}
EOF

if is_true "$ZRAM_USE_NAS_SERVICE" && [ -f "$SCRIPT_DIR/maintenance/zram-nas-apply.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/maintenance/zram-nas-apply.sh" /usr/local/bin/zram-nas-apply.sh
    cat > /etc/systemd/system/zram-nas.service << 'EOF'
[Unit]
Description=SUPER-NAS ZRAM bootstrap
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target armbian-zram-config.service zramswap.service
Before=swap.target multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-nas-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=swap.target
EOF

    if systemctl list-unit-files 2>/dev/null | grep -q '^zramswap\.service'; then
        systemctl disable --now zramswap.service >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable zram-nas.service >/dev/null 2>&1 || true
    if systemctl restart zram-nas.service; then
        log_ok "ZRAM configurado con zram-nas.service (${ZRAM_ALGO} ${ZRAM_PERCENT}%)"
    else
        log_warn "zram-nas.service no pudo iniciarse; aplico fallback con zramswap"
        systemctl restart zramswap 2>/dev/null || true
    fi
else
    log_warn "No encontré maintenance/zram-nas-apply.sh o ZRAM_USE_NAS_SERVICE=0; uso zramswap legado"
    systemctl restart zramswap 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════════════════════
# 5. OPTIMIZACIONES DE KERNEL
# ════════════════════════════════════════════════════════════════════════════
log_step "Aplicando optimizaciones de kernel"

cat > /etc/sysctl.d/99-nas.conf << 'EOF'
# ── TCP — BBR + cola fq ───────────────────────────────────────────────────
# BBR (Bottleneck Bandwidth and Round-trip propagation time):
#   Algoritmo de control de congestión de Google (2016).
#   En vez de reaccionar a pérdida de paquetes como CUBIC, BBR modela
#   el ancho de banda real del enlace y mantiene la ventana TCP llena.
#   Beneficio para el NAS: streaming de fotos/video más fluido,
#   especialmente sobre Tailscale/WireGuard donde hay variación de latencia.
#
# fq (Fair Queue):
#   Disciplina de cola que trabaja en pareja con BBR.
#   Distribuye el ancho de banda equitativamente entre conexiones.
#   Sin fq, BBR puede acaparar todo el ancho de banda de una conexión.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# ── Buffers de red ────────────────────────────────────────────────────────
# rmem_max / wmem_max: tamaño máximo de buffer por socket.
# 16 MB (16777216 bytes) permite ventanas TCP grandes para transferencias
# de fotos en LAN gigabit. Sin esto el kernel limita a 128 KB por defecto.
# tcp_rmem / tcp_wmem: rango dinámico [mínimo, inicial, máximo].
# El kernel escala automáticamente según la velocidad de la red.
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216   # recepción: mín 4KB, inicial 85KB, máx 16MB
net.ipv4.tcp_wmem=4096 65536 16777216   # envío:    mín 4KB, inicial 64KB, máx 16MB

# tcp_fastopen: eliminado deliberadamente.
# Beneficio real es pequeño para este perfil (Immich + nginx + Tailscale/WireGuard),
# y puede introducir incompatibilidades con algunos clientes móviles.
# BBR + buffers de 16 MB ya cubren el rendimiento TCP necesario.

# ── Memoria virtual ───────────────────────────────────────────────────────
# swappiness=10: el kernel prefiere usar RAM libre antes de hacer swap.
# Con ZRAM activo, bajar swappiness reduce el swap comprimido innecesario.
# Valor 0 = nunca swap (demasiado agresivo, puede causar OOM killer).
# Valor 10 = swap solo cuando la RAM está al 90%+.
vm.swappiness=10

# dirty_ratio=20: % máximo de RAM que puede tener escrituras pendientes.
# Al llegar al 20%, el kernel fuerza flush al disco bloqueando el proceso.
# dirty_background_ratio=10: % a partir del cual el kernel empieza a
# vaciar escrituras en segundo plano sin bloquear.
# Con estos valores: flush suave comienza al 10%, hard limit al 20%.
# Evita pausas largas al subir álbumes grandes desde el celular.
vm.dirty_ratio=20
vm.dirty_background_ratio=10

# ── TCP pacing ────────────────────────────────────────────────────────────
# tcp_low_latency=1: reduce la latencia de la cola de red.
#   Mejora el streaming de video sobre Tailscale donde cada ms cuenta.
#
# tcp_autocorking=1: agrupa paquetes pequeños antes de enviarlos.
#   Reduce interrupciones de CPU por paquete cuando Immich envía
#   metadatos pequeños frecuentemente.
#
# netdev_max_backlog=16384: cola de paquetes entrantes antes de que el kernel
#   los descarte. Valor conservador para NAS casero con 1 usuario en 1 Gbps.
#   250000 era excesivo para este hardware — innecesario y puede meter presión
#   de memoria en 4 GB RAM. 16384 es suficiente para ráfagas normales.
net.ipv4.tcp_autocorking=1
net.core.netdev_max_backlog=16384
EOF

sysctl -p /etc/sysctl.d/99-nas.conf > /dev/null
log_ok "Parámetros de kernel aplicados (BBR, buffers 16MB, swappiness=10)"

# ── noatime en raíz eMMC (modo conservador) ──────────────────────────────
# Default: activa solo noatime (bajo riesgo, menos escritura de metadatos).
# commit en "/" queda opcional para evitar ampliar demasiado la ventana de
# metadatos pendientes en caso de corte eléctrico.
if is_true "$ROOT_ENABLE_NOATIME"; then
    log_step "Aplicando tuning de atime en raíz eMMC"
    ROOT_REMOUNT_OPTS="remount,noatime"
    if is_true "$ROOT_ENABLE_COMMIT_TUNING"; then
        ROOT_REMOUNT_OPTS="${ROOT_REMOUNT_OPTS},commit=${ROOT_COMMIT_INTERVAL_SEC}"
    fi
    if mount -o "$ROOT_REMOUNT_OPTS" / >/dev/null 2>&1; then
        log_ok "Raíz remount con: $ROOT_REMOUNT_OPTS"
    else
        log_warn "No pude hacer remount de / con $ROOT_REMOUNT_OPTS (se mantiene configuración actual)"
    fi

    TMP_FSTAB=$(mktemp)
    awk -v add_commit="$(is_true "$ROOT_ENABLE_COMMIT_TUNING" && echo 1 || echo 0)" \
        -v commit_sec="$ROOT_COMMIT_INTERVAL_SEC" '
        function hasopt(opts, key) {
            n=split(opts, arr, ",")
            for (i=1; i<=n; i++) if (arr[i]==key) return 1
            return 0
        }
        function hasprefix(opts, prefix) {
            n=split(opts, arr, ",")
            for (i=1; i<=n; i++) if (index(arr[i], prefix)==1) return i
            return 0
        }
        $1 !~ /^#/ && $2=="/" {
            if (!hasopt($4, "noatime")) $4=$4 ",noatime"
            idx=hasprefix($4, "commit=")
            if (add_commit==1) {
                if (idx>0) {
                    n=split($4, arr, ",")
                    arr[idx]="commit=" commit_sec
                    $4=arr[1]
                    for (i=2; i<=n; i++) $4=$4 "," arr[i]
                } else {
                    $4=$4 ",commit=" commit_sec
                }
            }
        }
        { print }
    ' /etc/fstab > "$TMP_FSTAB"
    cat "$TMP_FSTAB" > /etc/fstab
    rm -f "$TMP_FSTAB"
    ROOT_FSTAB_SUFFIX=""
    if is_true "$ROOT_ENABLE_COMMIT_TUNING"; then
        ROOT_FSTAB_SUFFIX=",commit=$ROOT_COMMIT_INTERVAL_SEC"
    fi
    log_ok "fstab raíz actualizado (noatime${ROOT_FSTAB_SUFFIX})"
fi

# ── Límites de journal systemd ────────────────────────────────────────────
# Sin límite el journal puede consumir cientos de MB en la eMMC.
# 100M máximo persistente + 7 días de retención.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/nas.conf << 'EOF'
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald
log_ok "Journal systemd limitado a 100 MB / 7 días"

# ════════════════════════════════════════════════════════════════════════════
# 6. ETH OFFLOADING
# ════════════════════════════════════════════════════════════════════════════
# Ver scripts/eth-offload.sh para documentación completa.
# Se instala en if-up.d para activarse automáticamente en cada reinicio.
log_step "Configurando ETH offloading"

install -m 0755 "$SCRIPT_DIR/scripts/eth-offload.sh" \
    /etc/network/if-up.d/eth-offload
bash /etc/network/if-up.d/eth-offload || true  # Activar ahora también
log_ok "ETH offloading activado (TSO/GSO/GRO)"

# ════════════════════════════════════════════════════════════════════════════
# 7. PARTICIONES Y SISTEMA DE ARCHIVOS
# ════════════════════════════════════════════════════════════════════════════
log_step "Preparando discos"

format_disk() {
    local DISK="$1" LABEL="$2"
    local PART
    PART=$(partition_path "$DISK")

    if [ "$INSTALL_MODE" = "restore" ]; then
        if blkid "$PART" 2>/dev/null | grep -q 'TYPE="ext4"'; then
            log_ok "Restauración: $PART ya tiene ext4, se reutiliza sin formateo"
            return 0
        fi
        if blkid "$DISK" 2>/dev/null | grep -q 'TYPE="ext4"'; then
            log_ok "Restauración: $DISK tiene ext4 directo, se reutiliza sin formateo"
            return 0
        fi
        die "Modo restauración: no encontré ext4 válido en $DISK/$PART. Aborto para no planchar datos."
    fi

    # ── Caso 1: ya tiene ext4 — asumir que es la instalación correcta ────────
    if blkid "$PART" 2>/dev/null | grep -q "TYPE=\"ext4\""; then
        log_warn "$PART ya tiene ext4 — omitiendo formateo (idempotente)"
        return 0
    fi

    # ── Caso 2: disco con tabla de particiones existente (no vacío) ───────────
    # Distinguir "unknown" (vacío) de gpt/msdos/... (tiene tabla real).
    # "parted print" siempre muestra "Partition Table:" — hay que leer el valor.
    local PTABLE
    PTABLE=$({ parted -s "$DISK" print 2>/dev/null || true; } | \
        awk '/Partition Table:/{print $3}')

    if [ -n "$PTABLE" ] && [ "$PTABLE" != "unknown" ]; then
        # Tiene tabla de particiones real — verificar si tiene particiones activas
        local NPARTS
        NPARTS=$({ parted -s "$DISK" print 2>/dev/null || true; } | \
            awk '/^ *[0-9]/{count++} END{print count+0}')
        if [ "$NPARTS" -gt 0 ]; then
            if [ "${ALLOW_FORMAT:-no}" = "yes" ]; then
                log_warn "$DISK tiene $NPARTS partición(es) — ALLOW_FORMAT=yes, borrando..."
                # Desmontar todas las particiones del disco antes de wipefs
                for part in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
                    umount "/dev/$part" 2>/dev/null || true
                done
                wipefs -a "$DISK" > /dev/null 2>&1 || die "wipefs falló en $DISK"
                log_ok "$DISK limpiado con wipefs"
            else
                die "$DISK tiene $NPARTS partición(es). Para borrarlas agrega ALLOW_FORMAT=yes en $CONFIG"
            fi
        fi
        # Tiene tabla pero sin particiones — continuar es seguro
        log_warn "$DISK tiene tabla $PTABLE vacía — reparticionando"
    fi

    # ── Caso 3: filesystem directo sin tabla ─────────────────────────────────
    if blkid "$DISK" 2>/dev/null | grep -q "TYPE="; then
        if [ "${ALLOW_FORMAT:-no}" = "yes" ]; then
            log_warn "$DISK tiene filesystem directo — ALLOW_FORMAT=yes, borrando..."
            wipefs -a "$DISK" > /dev/null 2>&1 || die "wipefs falló en $DISK"
            log_ok "$DISK limpiado con wipefs"
        else
            die "$DISK tiene filesystem directo. Para borrarlo agrega ALLOW_FORMAT=yes en $CONFIG"
        fi
    fi

    # ── Solo llega aquí si el disco está vacío o fue limpiado ────────────────
    log_info "Particionando $DISK ($LABEL)"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary ext4 1MiB 100%  # 1MiB inicio = alineación correcta

    # udevadm settle: espera que el kernel registre /dev/sdX1
    # antes de intentar mkfs. Más robusto que sleep fijo.
    udevadm settle

    # Confirmar que la partición existe antes de formatear
    [ -b "$PART" ] || die "$PART no apareció tras parted — revisar el disco o probar udevadm trigger"

    mkfs.ext4 -L "$LABEL" "$PART" -q
    log_ok "$DISK formateado como $LABEL"
}

format_disk "$DISK_PHOTOS" "storage_main"
format_disk "$DISK_BACKUP" "storage_backup"

# ════════════════════════════════════════════════════════════════════════════
# 8. MONTAJE (fstab)
# ════════════════════════════════════════════════════════════════════════════
log_step "Configurando montajes"

mkdir -p "$MOUNT_PHOTOS" "$MOUNT_BACKUP" "$MOUNT_MERGED"

get_uuid() { blkid -s UUID -o value "$(partition_path "$1")"; }

UUID_PHOTOS=$(get_uuid "$DISK_PHOTOS")
UUID_BACKUP=$(get_uuid "$DISK_BACKUP")

[ -n "$UUID_PHOTOS" ] || die "No se pudo obtener UUID de $(partition_path "$DISK_PHOTOS")"
[ -n "$UUID_BACKUP" ] || die "No se pudo obtener UUID de $(partition_path "$DISK_BACKUP")"

# add_fstab: idempotente por punto de montaje, no por string completo.
# Busca el mountpoint (campo 2) para decidir si ya existe la entrada.
# Esto evita duplicar si se cambian opciones de montaje en una reinstalación.
add_fstab() {
    local ENTRY="$1"
    local MOUNTPOINT
    MOUNTPOINT=$(printf '%s\n' "$ENTRY" | awk '{print $2}')
    if awk -v mp="$MOUNTPOINT" '$1 !~ /^#/ && $2==mp {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then
        # Reemplazar la entrada existente para garantizar opciones correctas
        # Necesario en reinstalaciones donde las opciones pueden haber cambiado
        local TMP_FSTAB
        TMP_FSTAB=$(mktemp)
        awk -v mp="$MOUNTPOINT" -v entry="$ENTRY" '
            BEGIN { replaced=0 }
            $1 !~ /^#/ && $2==mp {
                if (!replaced) {
                    print entry
                    replaced=1
                }
                next
            }
            { print }
        ' /etc/fstab > "$TMP_FSTAB"
        cat "$TMP_FSTAB" > /etc/fstab
        rm -f "$TMP_FSTAB"
        log_warn "fstab: entrada para $MOUNTPOINT reemplazada (reinstalación)"
    else
        echo "$ENTRY" >> /etc/fstab
    fi
}

# ── HDD fotos — noatime + nodiratime + commit conservador ────────────────
# noatime: no actualizar el timestamp de acceso (atime) al leer un archivo.
#   Sin esto, cada lectura genera una escritura de metadatos en el HDD.
#   Con 20,000 fotos y accesos frecuentes = miles de escrituras innecesarias.
#   Ahorro: ~15% menos operaciones de escritura en el HDD.
# nodiratime: igual pero para directorios.
add_fstab "UUID=$UUID_PHOTOS $MOUNT_PHOTOS ext4 defaults,noatime,nodiratime,commit=${STORAGE_COMMIT_INTERVAL_SEC} 0 2"

# ── HDD backup — mismas optimizaciones ───────────────────────────────────
add_fstab "UUID=$UUID_BACKUP $MOUNT_BACKUP ext4 defaults,noatime,nodiratime,commit=${STORAGE_COMMIT_INTERVAL_SEC} 0 2"

# ── mergerfs — union de HDD/photos + eMMC/cache ──────────────────────────
# mergerfs presenta dos directorios como uno solo (/mnt/merged).
# UPLOAD_LOCATION apunta a /mnt/merged: Immich ve los originales del HDD
# y los videos cacheados de la eMMC en el mismo árbol de directorios.
#
# category.create=ff (first found with free space):
#   Las ESCRITURAS van al PRIMER branch con espacio disponible.
#   Orden: HDD/photos PRIMERO, eMMC/cache SEGUNDO.
#   ⚠ CRÍTICO: el orden importa. Si fuera eMMC:HDD, los uploads de fotos
#   irían a la eMMC llenándola con originales 4K en vez de solo al HDD.
#
# use_ino: preserva los inodos originales de cada branch.
#   Sin esto, dos archivos con el mismo nombre en branches distintos
#   podrían tener el mismo inodo virtual → bugs en Immich.
#
# allow_other: permite que el usuario de Docker (no-root) acceda al mount.
add_fstab "$MOUNT_PHOTOS/photos:$EMMC_IMMICH/cache $MOUNT_MERGED fuse.mergerfs defaults,allow_other,use_ino,category.create=ff 0 0"

# ── IMPORTANTE: crear branches ANTES de montar mergerfs ──────────────────
# mergerfs necesita que los directorios branch existan en el momento
# del montaje. Si no existen, puede fallar o comportarse de forma
# no consistente según la versión.
# El orden correcto es:
#   1) crear mountpoints y dirs de eMMC
#   2) montar HDD principal y HDD backup
#   3) crear dentro de esos mounts las carpetas reales del NAS
#   4) montar mergerfs

# ════════════════════════════════════════════════════════════════════════════
# 9. DIRECTORIOS (antes del mount -a)
# ════════════════════════════════════════════════════════════════════════════
log_step "Creando estructura de directorios"

# Mountpoints del host y eMMC local
mkdir -p "$MOUNT_PHOTOS" "$MOUNT_BACKUP" "$MOUNT_MERGED"
mkdir -p "$EMMC_IMMICH/cache"

# Directorios en eMMC (DB, modelos, thumbs — bus dedicado, 15,000 IOPS)
mkdir -p     "$EMMC_IMMICH/db"     "$EMMC_IMMICH/models"     "$EMMC_IMMICH/thumbs"     "$EMMC_IMMICH/encoded-video"     "$EMMC_IMMICH/nginx-cache"     "$EMMC_IMMICH/profile"

mkdir -p /opt/immich-app
log_ok "Directorios creados"

# fuse.mergerfs con allow_other requiere user_allow_other en /etc/fuse.conf
grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null ||     echo "user_allow_other" >> /etc/fuse.conf

# Montar explícitamente solo nuestros puntos — no mount -a global
# que puede fallar si hay entradas viejas rotas en fstab de otros sistemas
if mountpoint -q "$MOUNT_PHOTOS"; then
    log_warn "$MOUNT_PHOTOS ya estaba montado — omitiendo mount"
else
    mount "$MOUNT_PHOTOS" || die "No se pudo montar $MOUNT_PHOTOS"
fi

if mountpoint -q "$MOUNT_BACKUP"; then
    log_warn "$MOUNT_BACKUP ya estaba montado — omitiendo mount"
else
    mount "$MOUNT_BACKUP" || die "No se pudo montar $MOUNT_BACKUP"
fi

# Estas carpetas deben existir DENTRO de los discos ya montados.
# Si se crean antes del mount, quedan ocultas debajo del punto de montaje y
# mergerfs termina escribiendo todo en el branch de cache.
mkdir -p "$MOUNT_PHOTOS/photos" "$MOUNT_PHOTOS/cache"
mkdir -p "$MOUNT_BACKUP/snapshots" "$MOUNT_BACKUP/snapshots/immich-db" "$MOUNT_BACKUP/snapshots/system-state"

if ! mountpoint -q "$MOUNT_MERGED" && find "$MOUNT_MERGED" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    log_warn "$MOUNT_MERGED tenía contenido residual local — limpiándolo antes de montar mergerfs"
    find "$MOUNT_MERGED" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

if mountpoint -q "$MOUNT_MERGED"; then
    log_warn "$MOUNT_MERGED ya estaba montado — omitiendo mount"
else
    mount "$MOUNT_MERGED" || die "No se pudo montar $MOUNT_MERGED (mergerfs)"
fi

# Validar tipo fuse.mergerfs — no solo que haya algo montado
MERGED_TYPE=$(findmnt -n -o FSTYPE "$MOUNT_MERGED" 2>/dev/null || echo "")
if [ "$MERGED_TYPE" = "fuse.mergerfs" ]; then
    log_ok "mergerfs montado correctamente en $MOUNT_MERGED"
elif mountpoint -q "$MOUNT_MERGED"; then
    die "Hay algo montado en $MOUNT_MERGED pero no es mergerfs (tipo: $MERGED_TYPE) — revisar fstab"
else
    die "mergerfs no montó en $MOUNT_MERGED — verificar /etc/fuse.conf y branches"
fi

# Immich valida seis carpetas con marcadores .immich al arrancar.
# En reinstalaciones, restauraciones parciales o mounts recién recreados
# esos marcadores pueden faltar y provocar un loop de reinicio.
log_step "Sembrando marcadores de integridad de Immich"
for _dir in \
    "$MOUNT_MERGED" \
    "$MOUNT_MERGED/upload" \
    "$MOUNT_MERGED/library" \
    "$MOUNT_MERGED/backups" \
    "$EMMC_IMMICH/thumbs" \
    "$EMMC_IMMICH/encoded-video" \
    "$EMMC_IMMICH/profile"; do
    mkdir -p "$_dir"
    [ -f "$_dir/.immich" ] || touch "$_dir/.immich"
done
log_ok "Marcadores .immich sembrados para upload/library/backups/thumbs/encoded-video/profile"

# ════════════════════════════════════════════════════════════════════════════
# 10. READAHEAD HDD
# ════════════════════════════════════════════════════════════════════════════
# El kernel pre-lee datos del HDD antes de que la aplicación los pida.
# Con 4 KB (defecto): el kernel lee 4 KB adelante al acceder un archivo.
# Con 4 MB: el kernel lee 4 MB adelante.
#
# Beneficio para el NAS:
# Al navegar una galería, Immich lee thumbnails secuencialmente.
# Con readahead de 4 MB, el kernel ya tiene los próximos ~100 thumbnails
# en el buffer antes de que Immich los pida → galería fluida.
# Sin readahead alto, cada thumbnail genera un seek del cabezal.
#
# La regla udev persiste el valor entre reinicios.
# La asignación directa al sysfs lo aplica inmediatamente.
log_step "Configurando readahead HDD"

# Aplicar readahead solo a los discos definidos en nas.conf,
# no a sd[a]* genérico que podría afectar otros dispositivos USB.
DISK_PHOTOS_DEV=$(basename "$DISK_PHOTOS")
DISK_BACKUP_DEV=$(basename "$DISK_BACKUP")
cat > /etc/udev/rules.d/60-readahead.rules << EOF
ACTION=="add|change", KERNEL=="${DISK_PHOTOS_DEV}", ATTR{queue/read_ahead_kb}="4096"
ACTION=="add|change", KERNEL=="${DISK_BACKUP_DEV}", ATTR{queue/read_ahead_kb}="4096"
EOF

if is_true "$HDD_APM_ENABLE"; then
cat >> /etc/udev/rules.d/60-readahead.rules << EOF
ACTION=="add|change", KERNEL=="${DISK_PHOTOS_DEV}", RUN+="/sbin/hdparm -B ${HDD_APM_LEVEL} /dev/${DISK_PHOTOS_DEV}"
ACTION=="add|change", KERNEL=="${DISK_BACKUP_DEV}", RUN+="/sbin/hdparm -B ${HDD_APM_LEVEL} /dev/${DISK_BACKUP_DEV}"
EOF
fi

# Aplicar inmediatamente a AMBOS discos sin esperar reinicio
for _disk in "$DISK_PHOTOS" "$DISK_BACKUP"; do
    _dev=$(basename "$_disk")
    [ -f "/sys/block/${_dev}/queue/read_ahead_kb" ] &&         echo 4096 > "/sys/block/${_dev}/queue/read_ahead_kb" || true
done

log_ok "Readahead HDD: 4 MB en ambos discos (vía udev, persiste entre reinicios)"

# ════════════════════════════════════════════════════════════════════════════
# 10b. APM HDD (conservador)
# ════════════════════════════════════════════════════════════════════════════
# APM bajo puede aumentar head-parking (Load_Cycle). En modo conservador:
# - nivel 254 por defecto (muy compatible con bridges USB)
# - solo aplica a discos rotacionales
# - si el bridge no soporta APM, se deja como WARN (no bloqueo)
if is_true "$HDD_APM_ENABLE"; then
    log_step "Aplicando APM HDD (nivel ${HDD_APM_LEVEL})"
    if [ -x /sbin/hdparm ] || command -v hdparm >/dev/null 2>&1; then
        for _disk in "$DISK_PHOTOS" "$DISK_BACKUP"; do
            _dev=$(basename "$_disk")
            _rot_file="/sys/block/${_dev}/queue/rotational"
            if [ -f "$_rot_file" ] && [ "$(cat "$_rot_file" 2>/dev/null || echo 1)" = "1" ]; then
                if hdparm -B "$HDD_APM_LEVEL" "$_disk" >/dev/null 2>&1; then
                    log_ok "APM ${HDD_APM_LEVEL} aplicado en $_disk"
                else
                    log_warn "Bridge de $_disk no permitió ajustar APM (se mantiene operación normal)"
                fi
            else
                log_info "APM omitido en $_disk (no rotacional o sin telemetría rotational)"
            fi
        done
    else
        log_warn "hdparm no disponible; APM no aplicado"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 11. IMMICH — .env y docker-compose.yml
# ════════════════════════════════════════════════════════════════════════════
log_step "Configurando Immich"

cat > /opt/immich-app/.env << EOF
# Generado por install.sh — $(date)
# ── Almacenamiento ────────────────────────────────────────────────────────
# UPLOAD_LOCATION: mergerfs expone HDD+eMMC/cache como un volumen unificado.
# Immich escribe library/ y upload/ en el HDD (primer branch mergerfs).
UPLOAD_LOCATION=$MOUNT_MERGED

# Subdirectorios en eMMC — método oficial de Immich (documentado en immich.app).
# Immich valida estos paths al arrancar y crea .immich en cada uno.
# eMMC tiene bus dedicado al SoC: 15,000 IOPS vs 150 del HDD.
THUMB_LOCATION=$EMMC_IMMICH/thumbs
ENCODED_VIDEO_LOCATION=$EMMC_IMMICH/encoded-video
PROFILE_LOCATION=$EMMC_IMMICH/profile

# DB en eMMC: 150x más IOPS que HDD para queries random de metadatos.
DB_DATA_LOCATION=$EMMC_IMMICH/db
IMMICH_VERSION=release
TZ=$TIMEZONE

# ── Base de datos ────────────────────────────────────────────────────────
DB_USERNAME=immich
DB_PASSWORD=$DB_PASSWORD
DB_DATABASE_NAME=immich

# ── Rendimiento — calibrado para S905X3 4GB RAM ──────────────────────────
# WORKERS=2: hilos de trabajo del servidor Immich.
#   Más de 2 satura el A55 in-order y compite con PostgreSQL.
WORKERS=2

# MACHINE_LEARNING_BATCH_SIZE=4: fotos por lote de inferencia ML.
#   Lotes de 4 usan los 4 cores eficientemente sin sobrecalentar.
MACHINE_LEARNING_BATCH_SIZE=4

# MACHINE_LEARNING_MAX_CONCURRENT=2: trabajos ML simultáneos máximos.
#   Evita que el ML acapare todos los recursos del sistema.
MACHINE_LEARNING_MAX_CONCURRENT=2

# DB_POOL_SIZE=40: conexiones en el pool de PostgreSQL de Immich.
#   max_connections=50 en Postgres deja 10 para conexiones administrativas.
DB_POOL_SIZE=40

# VIPS_CONCURRENCY=2: hilos de libvips para procesar imágenes.
#   libvips usa NEON en aarch64 automáticamente. Más de 2 compite con Immich.
VIPS_CONCURRENCY=2

# VIPS_CACHE_MAX=128: caché interna de libvips en MB.
#   Reducido de 256 a 128 para liberar RAM (junto con la eliminación de tmpfs).
#   128 MB es suficiente para 1 usuario — reprocesamiento tarda ms.
VIPS_CACHE_MAX=128

# VIPS_DISC_THRESHOLD=512m: imágenes < 512 MB se procesan en RAM.
#   Las fotos del S23 FE son 4–8 MB → siempre en RAM, sin archivos temp.
VIPS_DISC_THRESHOLD=512m
EOF

# Permisos restrictivos: solo root puede leer el .env (contiene DB_PASSWORD)
chmod 600 /opt/immich-app/.env

cp "$SCRIPT_DIR/config/docker-compose.yml" /opt/immich-app/docker-compose.yml

log_ok "Immich configurado en /opt/immich-app/"

# ════════════════════════════════════════════════════════════════════════════
# 12. NGINX — Reverse proxy + cache de thumbnails
# ════════════════════════════════════════════════════════════════════════════
# nginx actúa como intermediario entre el celular e Immich.
# Cachea thumbnails en eMMC para servirlos sin pasar por Immich.
log_step "Configurando nginx"

rm -f /etc/nginx/sites-enabled/default  # Eliminar config por defecto

cat > /etc/nginx/sites-enabled/immich.conf << 'EOF'
# ── Cache de thumbnails en eMMC ───────────────────────────────────────────
# proxy_cache_path: directorio donde nginx guarda los thumbnails cacheados.
#   En eMMC: acceso rápido, bus dedicado, persiste entre reinicios del NAS.
# levels=1:2: estructura de subdirectorios del cache (evita directorios enormes).
# keys_zone=thumbcache:100m: 100 MB de memoria RAM para los metadatos del cache
#   (no el cache en sí — solo los índices). Soporta ~800,000 entradas.
# max_size=180m: tamaño máximo del cache en disco.
#   180 MB de 200 MB del directorio eMMC (20 MB de margen para metadatos).
# inactive=24h: thumbnails no accedidos en 24h se eliminan del cache.
# use_temp_path=off: nginx escribe directamente en el directorio final,
#   evitando una copia intermedia que duplicaría escrituras en eMMC.
proxy_cache_path /var/lib/immich/nginx-cache levels=1:2
  keys_zone=thumbcache:100m max_size=180m inactive=24h
  use_temp_path=off;

server {
  listen 80;
  server_name _;

  # ── Cache de thumbnails ─────────────────────────────────────────────────
  location /api/asset/thumbnail/ {
    proxy_pass http://localhost:2283;
    proxy_set_header Host          $host;
    proxy_set_header Authorization $http_authorization;

    # proxy_cache: usar la zona thumbcache definida arriba.
    proxy_cache           thumbcache;

    # proxy_cache_lock: si 10 clientes piden el mismo thumbnail nuevo,
    #   solo UNO va al backend. Los otros esperan el resultado cacheado.
    #   Evita thundering herd en la primera carga de la galería.
    proxy_cache_lock      on;

    # proxy_cache_use_stale: si Immich está ocupado o reiniciando,
    #   servir el thumbnail cacheado aunque esté "vencido".
    #   Mejor una thumbnail vieja que un error 502.
    proxy_cache_use_stale error timeout updating;

    # sendfile: zero-copy — el kernel transfiere el archivo directamente
    #   desde eMMC al socket de red sin pasar por el espacio de usuario.
    #   Elimina una copia de memoria por request. ~20% menos CPU en nginx.
    sendfile    on;

    # tcp_nopush: acumula datos hasta llenar un paquete TCP antes de enviar.
    #   Reduce el número de paquetes para thumbnails pequeños.
    tcp_nopush  on;

    # tcp_nodelay: para el último fragmento, enviar inmediatamente sin esperar.
    #   Combinado con tcp_nopush: paquetes llenos + último fragmento inmediato.
    tcp_nodelay on;
  }

  # ── Placeholder local para videos aún no optimizados ───────────────────
  location = /__static/video-processing.mp4 {
    alias /var/lib/immich/static/video-processing.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-processing-portrait.mp4 {
    alias /var/lib/immich/static/video-processing-portrait.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-damaged.mp4 {
    alias /var/lib/immich/static/video-damaged.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-damaged-portrait.mp4 {
    alias /var/lib/immich/static/video-damaged-portrait.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-missing.mp4 {
    alias /var/lib/immich/static/video-missing.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-missing-portrait.mp4 {
    alias /var/lib/immich/static/video-missing-portrait.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-error.mp4 {
    alias /var/lib/immich/static/video-error.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  location = /__static/video-error-portrait.mp4 {
    alias /var/lib/immich/static/video-error-portrait.mp4;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "public, max-age=300";
    sendfile on;
  }

  # ── Videos optimizados por la rutina nocturna ──────────────────────────
  location /__cache-video/ {
    internal;
    alias /var/lib/immich/cache/;
    types { video/mp4 mp4; }
    default_type video/mp4;
    add_header Cache-Control "private, max-age=3600, no-transform";
    sendfile on;
    aio threads;
    directio 4m;
  }

  location /__immich-direct/ {
    internal;
    rewrite ^/__immich-direct(/.*)$ $1 break;
    proxy_pass http://localhost:2283;
    proxy_set_header Host $host;
    proxy_set_header Cookie $http_cookie;
    proxy_set_header Authorization $http_authorization;
    proxy_buffering off;
  }

  # ── Upload robusto para app móvil (evita timeouts en /api/assets) ─────
  # Para videos grandes por Tailscale/datos móviles:
  # - desactiva buffering de request para stream directo al backend
  # - extiende timeouts para evitar cortes prematuros
  location = /api/assets {
    proxy_pass http://localhost:2283;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 50G;
    client_body_timeout 3600s;
    send_timeout 3600s;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_connect_timeout 60s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }

  # ── Rutas de video/playback ─────────────────────────────────────────────
  # El portal NO debe reproducir a ciegas el original pesado desde el HDD.
  # En su lugar, un resolutor local decide:
  #   - si ya existe /var/lib/immich/cache/...mp4  -> servir version ligera
  #   - si el video ya es ligero                   -> servir directo
  #   - si aun no existe y sigue pesado            -> servir placeholder
  location ~ ^/api/assets/[0-9a-f-]+/video/playback$ {
    proxy_pass http://127.0.0.1:2284;
    proxy_set_header Host $host;
    proxy_set_header Cookie $http_cookie;
    proxy_set_header Authorization $http_authorization;
    proxy_buffering off;
    client_max_body_size 50G;
  }

  # WebSocket de Immich (socket.io) para eventos del portal.
  # Sin upgrade HTTP/1.1 la UI muestra errores repetidos en consola.
  location /api/socket.io/ {
    proxy_pass http://localhost:2283;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header Cookie $http_cookie;
    proxy_set_header Authorization $http_authorization;
    proxy_read_timeout 86400;
    proxy_buffering off;
  }

  # ── Resto de la API ─────────────────────────────────────────────────────
  location / {
    proxy_pass http://localhost:2283;
    proxy_set_header Host $host;
    # 50G: permite subir videos 4K grandes desde el S23 FE sin error 413.
    client_max_body_size 50G;
  }
}
EOF

mkdir -p /var/lib/immich/static

nginx -t && systemctl restart nginx
log_ok "nginx configurado (cache eMMC, sendfile, proxy_cache_lock, placeholder de video)"

# ════════════════════════════════════════════════════════════════════════════
# 13. SCRIPTS DE MANTENIMIENTO
# ════════════════════════════════════════════════════════════════════════════
# install -m 0755: copia el archivo y establece permisos ejecutables en
# una sola operación. Más atómico que cp + chmod.
log_step "Instalando scripts de mantenimiento"

SCRIPTS=(
    "nas-alert.sh"       # Alertas Telegram — prerequisito de todos los demás
    "ml-temp-guard.sh"   # Guardia térmica 3 niveles (ventilador, throttle, crítico)
    "zram-nas-apply.sh"  # Reconfigura zram0 con secuencia robusta (reset + zstd)
    "smart-check.sh"     # Monitoreo SMART diario + test mensual de superficie
    "cache-clean.sh"     # Auditoría de huérfanos de cache (no borra)
    "temp-clean.sh"      # Depuración semanal de temporales técnicos (sin tocar fotos/videos)
    "cache-migrate-to-disk.sh" # Migración manual de cache eMMC -> HDD (sin perder playback)
    "immich-ml-window.sh" # Enciende/apaga IA visual de Immich según horario
    "backup.sh"          # Backup incremental rsync con hard-links
    "failover-sync.sh"   # Sincroniza espejo operativo para switch de emergencia
    "storage-failover.sh" # Switch automático/manual al respaldo en falla grave
    "video-optimize.sh"  # Compresión 4K→720p CRF28 ultrafast NEON
    "retry-quarantine.sh" # Reactiva videos en cuarentena (fallo 3/3)
    "cache-monitor.sh"   # Vigilancia de tamaño del cache (no borra)
    "night-run.sh"       # Orquestador nocturno (cola + cool_down + flock)
    "iml-autopilot.sh"   # Drenado continuo de colas IML según carga/requsts/temperatura
    "video-autopilot.sh" # Reproceso continuo por carga CPU/RAM (pausa/reanuda)
    "video-reprocess-nightly.sh" # Reproceso nocturno ligero y cola manual para pesados
    "playback-audit-autoheal.sh" # Auditoria HTTP playback + autocorreccion automatica
    "playback-watchdog.sh" # Vigilancia activa de playback para detectar estancamientos
    "iml-drain-finalize.py" # Monitorea fin de IML y deja el sistema en estado normal
    "rebuild-video-cache.sh" # Recuperacion total de cache (prepare/light-only/tvbox-all)
    "state-backup.sh"    # Backup rapido de estado (DB + config + inventario)
    "state-restore.sh"   # Restauracion rapida desde snapshot de estado
    "disaster-restore.sh" # Restauracion integral en caja nueva (discos existentes)
    "bootstrap-restore.sh" # Flujo todo-en-uno desde OS limpio (install restore + restore total)
    "manual-retention.sh" # Depuracion manual de respaldos (sin auto-borrado)
    "log-maintenance.sh"  # Rotacion/depuracion mensual de logs tecnicos
    "mount-guard.sh"     # Detecta desmontajes/remontajes y notifica Telegram
    "post-upload-check.sh" # Verificacion puntual del flujo tras subir un asset
    "audit-snapshot.sh"  # Bitacora operativa periodica (CPU/RAM/colas/montajes)
)

for script in "${SCRIPTS[@]}"; do
    src=""
    [ -f "$SCRIPT_DIR/maintenance/$script" ] && src="$SCRIPT_DIR/maintenance/$script"
    [ -f "$SCRIPT_DIR/scripts/$script"     ] && src="$SCRIPT_DIR/scripts/$script"
    if [ -n "$src" ]; then
        install -m 0755 "$src" "/usr/local/bin/$script"
        log_ok "Instalado: /usr/local/bin/$script"
    else
        log_warn "No encontrado: $script"
    fi
done

install -m 0755 "$SCRIPT_DIR/precheck.sh" /usr/local/bin/precheck.sh
log_ok "Instalado: /usr/local/bin/precheck.sh"

install -m 0755 "$SCRIPT_DIR/verify.sh" /usr/local/bin/verify.sh
log_ok "Instalado: /usr/local/bin/verify.sh"

install -m 0755 "$SCRIPT_DIR/scripts/immich-video-playback-resolver.py" \
    /usr/local/bin/immich-video-playback-resolver.py
log_ok "Instalado: /usr/local/bin/immich-video-playback-resolver.py"

if [ -f "$SCRIPT_DIR/scripts/reconcile-emmc-cache.py" ]; then
    install -m 0755 "$SCRIPT_DIR/scripts/reconcile-emmc-cache.py" \
        /usr/local/bin/reconcile-emmc-cache.py
    log_ok "Instalado: /usr/local/bin/reconcile-emmc-cache.py"
fi

if [ -f "$SCRIPT_DIR/scripts/video-reprocess-manager.py" ]; then
    install -m 0755 "$SCRIPT_DIR/scripts/video-reprocess-manager.py" \
        /usr/local/bin/video-reprocess-manager.py
    log_ok "Instalado: /usr/local/bin/video-reprocess-manager.py"
else
    log_warn "No encontrado: scripts/video-reprocess-manager.py"
fi

if [ -f "$SCRIPT_DIR/scripts/backfill-heavy-cache.py" ]; then
    install -m 0755 "$SCRIPT_DIR/scripts/backfill-heavy-cache.py" \
        /usr/local/bin/backfill-heavy-cache.py
    log_ok "Instalado: /usr/local/bin/backfill-heavy-cache.py"
fi

if [ -f "$SCRIPT_DIR/scripts/audit_video_playback.py" ]; then
    install -m 0755 "$SCRIPT_DIR/scripts/audit_video_playback.py" \
        /usr/local/bin/audit_video_playback.py
    log_ok "Instalado: /usr/local/bin/audit_video_playback.py"
fi

if [ -f "$SCRIPT_DIR/maintenance/iml-backlog-drain.py" ]; then
    install -m 0755 "$SCRIPT_DIR/maintenance/iml-backlog-drain.py" \
        /usr/local/bin/iml-backlog-drain.py
    log_ok "Instalado: /usr/local/bin/iml-backlog-drain.py"
fi

cat > /etc/default/nas-video-policy <<EOF
VIDEO_STREAM_MAX_MB_PER_MIN=${VIDEO_STREAM_MAX_MB_PER_MIN:-40}
VIDEO_STREAM_TARGET_MB_PER_MIN=${VIDEO_STREAM_TARGET_MB_PER_MIN:-38}
VIDEO_STREAM_LIGHT_REENCODE_MAX_MB_PER_MIN=${VIDEO_STREAM_LIGHT_REENCODE_MAX_MB_PER_MIN:-55}
VIDEO_OPTIMIZE_MAX_LONG_EDGE=${VIDEO_OPTIMIZE_MAX_LONG_EDGE:-1920}
VIDEO_OPTIMIZE_VIDEO_LEVEL=${VIDEO_OPTIMIZE_VIDEO_LEVEL:-4.1}
VIDEO_PLAYBACK_BROWSER_CACHE_SEC=${VIDEO_PLAYBACK_BROWSER_CACHE_SEC:-3600}
VIDEO_CORRUPT_CACHE_TTL_OK_SEC=${VIDEO_CORRUPT_CACHE_TTL_OK_SEC:-3600}
VIDEO_CORRUPT_CACHE_TTL_FAIL_SEC=${VIDEO_CORRUPT_CACHE_TTL_FAIL_SEC:-300}
VIDEO_DIRECT_COMPAT_CACHE_TTL_SEC=${VIDEO_DIRECT_COMPAT_CACHE_TTL_SEC:-300}
VIDEO_REPROCESS_MANAGER_BIN=${VIDEO_REPROCESS_MANAGER_BIN:-/usr/local/bin/video-reprocess-manager.py}
VIDEO_REPROCESS_OUTPUT_DIR=${VIDEO_REPROCESS_OUTPUT_DIR:-/var/lib/nas-health/reprocess}
VIDEO_REPROCESS_CACHE_ROOT=${VIDEO_REPROCESS_CACHE_ROOT:-/var/lib/immich/cache}
CACHE_VIDEOS_CANONICAL_ONLY=${CACHE_VIDEOS_CANONICAL_ONLY:-1}
VIDEO_REPROCESS_UPLOAD_ROOT=${VIDEO_REPROCESS_UPLOAD_ROOT:-/mnt/storage-main/photos}
VIDEO_REPROCESS_IMMICH_ROOT=${VIDEO_REPROCESS_IMMICH_ROOT:-/var/lib/immich}
FAILOVER_ROOT=${FAILOVER_ROOT:-/mnt/storage-backup/failover-main}
AUTO_FAILOVER_ENABLED=${AUTO_FAILOVER_ENABLED:-1}
AUTO_FAILBACK_ENABLED=${AUTO_FAILBACK_ENABLED:-1}
FAILOVER_IO_CHECK_ENABLED=${FAILOVER_IO_CHECK_ENABLED:-1}
FAILOVER_IO_TIMEOUT_SEC=${FAILOVER_IO_TIMEOUT_SEC:-8}
FAILOVER_SYNC_ENABLED=${FAILOVER_SYNC_ENABLED:-1}
FAILOVER_SYNC_PHOTOS_ENABLED=${FAILOVER_SYNC_PHOTOS_ENABLED:-1}
FAILOVER_SYNC_CACHE_ENABLED=${FAILOVER_SYNC_CACHE_ENABLED:-1}
FAILOVER_SYNC_NOTIFY_ON_SUCCESS=${FAILOVER_SYNC_NOTIFY_ON_SUCCESS:-0}
FAILOVER_SYNC_MAX_RUNTIME_MIN=${FAILOVER_SYNC_MAX_RUNTIME_MIN:-240}
FAILOVER_SYNC_IO_NICE=${FAILOVER_SYNC_IO_NICE:-15}
BACKUP_PHOTOS_MODE=${BACKUP_PHOTOS_MODE:-disabled}
VIDEO_REPROCESS_LOCAL_MAX_MB=${VIDEO_REPROCESS_LOCAL_MAX_MB:-220}
VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC=${VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC:-150}
VIDEO_REPROCESS_LOCAL_MAX_MB_MIN=${VIDEO_REPROCESS_LOCAL_MAX_MB_MIN:-120}
VIDEO_REPROCESS_LIGHT_LIMIT=${VIDEO_REPROCESS_LIGHT_LIMIT:-0}
VIDEO_REPROCESS_MAX_ATTEMPTS=${VIDEO_REPROCESS_MAX_ATTEMPTS:-3}
VIDEO_REPROCESS_AUDIO_BITRATE_K=${VIDEO_REPROCESS_AUDIO_BITRATE_K:-128}
VIDEO_REPROCESS_TARGET_MAXRATE_K=${VIDEO_REPROCESS_TARGET_MAXRATE_K:-5200}
VIDEO_REPROCESS_ALLOW_REMUX_LIGHT=${VIDEO_REPROCESS_ALLOW_REMUX_LIGHT:-0}
VIDEO_REPROCESS_SKIP_MOTION_CLIPS=${VIDEO_REPROCESS_SKIP_MOTION_CLIPS:-1}
VIDEO_REPROCESS_SKIP_REAL_4K=${VIDEO_REPROCESS_SKIP_REAL_4K:-0}
VIDEO_REPROCESS_ATTEMPTS_DB=${VIDEO_REPROCESS_ATTEMPTS_DB:-/var/lib/nas-retry/video-reprocess-light.attempts.tsv}
VIDEO_REPROCESS_MANUAL_QUEUE=${VIDEO_REPROCESS_MANUAL_QUEUE:-/var/lib/nas-retry/video-reprocess-manual.tsv}
VIDEO_REPROCESS_HEAVY_ENABLED=${VIDEO_REPROCESS_HEAVY_ENABLED:-1}
VIDEO_REPROCESS_HEAVY_LIMIT=${VIDEO_REPROCESS_HEAVY_LIMIT:-0}
VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=${VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED:-1}
VIDEO_REPROCESS_MAX_CPU_PCT=${VIDEO_REPROCESS_MAX_CPU_PCT:-72}
VIDEO_REPROCESS_MAX_MEM_PCT=${VIDEO_REPROCESS_MAX_MEM_PCT:-82}
VIDEO_REPROCESS_MAX_TEMP_C=${VIDEO_REPROCESS_MAX_TEMP_C:-75}
VIDEO_REPROCESS_CPU_SAMPLE_SEC=${VIDEO_REPROCESS_CPU_SAMPLE_SEC:-2}
VIDEO_REPROCESS_REQUEST_LOG_PATH=${VIDEO_REPROCESS_REQUEST_LOG_PATH:-/var/log/nginx/access.log}
VIDEO_REPROCESS_REQUEST_WINDOW_SEC=${VIDEO_REPROCESS_REQUEST_WINDOW_SEC:-20}
VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW=${VIDEO_REPROCESS_MAX_REQUESTS_PER_WINDOW:-8}
VIDEO_REPROCESS_BATCH_LIGHT=${VIDEO_REPROCESS_BATCH_LIGHT:-35}
VIDEO_REPROCESS_BATCH_HEAVY=${VIDEO_REPROCESS_BATCH_HEAVY:-5}
VIDEO_REPROCESS_MAX_RUNTIME_MIN=${VIDEO_REPROCESS_MAX_RUNTIME_MIN:-170}
VIDEO_REPROCESS_IDLE_SLEEP_SEC=${VIDEO_REPROCESS_IDLE_SLEEP_SEC:-45}
VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC=${VIDEO_REPROCESS_BUSY_ALERT_TTL_SEC:-1800}
VIDEO_AUTOPILOT_ENABLED=${VIDEO_AUTOPILOT_ENABLED:-1}
VIDEO_AUTOPILOT_SLICE_MIN=${VIDEO_AUTOPILOT_SLICE_MIN:-8}
VIDEO_AUTOPILOT_ALERT_TTL_SEC=${VIDEO_AUTOPILOT_ALERT_TTL_SEC:-3600}
VIDEO_AUTOPILOT_REQUIRE_IML_DRAIN=${VIDEO_AUTOPILOT_REQUIRE_IML_DRAIN:-1}
VIDEO_AUTOPILOT_IML_TARGETS="${VIDEO_AUTOPILOT_IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
VIDEO_AUTOPILOT_IML_API_URL=${VIDEO_AUTOPILOT_IML_API_URL:-http://127.0.0.1:2283/api}
VIDEO_AUTOPILOT_IML_SECRETS_FILE=${VIDEO_AUTOPILOT_IML_SECRETS_FILE:-/etc/nas-secrets}
IML_AUTOPILOT_ENABLED=${IML_AUTOPILOT_ENABLED:-1}
IML_AUTOPILOT_SLICE_MIN=${IML_AUTOPILOT_SLICE_MIN:-8}
IML_AUTOPILOT_ALERT_TTL_SEC=${IML_AUTOPILOT_ALERT_TTL_SEC:-3600}
IML_DYNAMIC_LOAD_ENABLED=${IML_DYNAMIC_LOAD_ENABLED:-1}
IML_TARGETS="${IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
IML_PHASE_ORDER="${IML_PHASE_ORDER:-library|sidecar|metadataExtraction;smartSearch|duplicateDetection|ocr|faceDetection;facialRecognition}"
IML_API_URL=${IML_API_URL:-http://127.0.0.1:2283/api}
IML_SECRETS_FILE=${IML_SECRETS_FILE:-/etc/nas-secrets}
IML_SLEEP_SEC=${IML_SLEEP_SEC:-20}
IML_LOG_EVERY=${IML_LOG_EVERY:-6}
IML_MAX_CPU_PCT=${IML_MAX_CPU_PCT:-72}
IML_MAX_MEM_PCT=${IML_MAX_MEM_PCT:-82}
IML_MAX_TEMP_C=${IML_MAX_TEMP_C:-75}
IML_CPU_SAMPLE_SEC=${IML_CPU_SAMPLE_SEC:-2}
IML_REQUEST_LOG_PATH=${IML_REQUEST_LOG_PATH:-/var/log/nginx/access.log}
IML_REQUEST_WINDOW_SEC=${IML_REQUEST_WINDOW_SEC:-20}
IML_MAX_REQUESTS_PER_WINDOW=${IML_MAX_REQUESTS_PER_WINDOW:-8}
IML_BUSY_ALERT_TTL_SEC=${IML_BUSY_ALERT_TTL_SEC:-1800}
IML_AUTOPILOT_START_ML_IF_PENDING=${IML_AUTOPILOT_START_ML_IF_PENDING:-1}
IML_AUTOPILOT_STOP_ML_WHEN_IDLE=${IML_AUTOPILOT_STOP_ML_WHEN_IDLE:-0}
IML_ML_CONTAINER_NAME=${IML_ML_CONTAINER_NAME:-immich_machine_learning}
IML_NOTIFY_BACKLOG_THRESHOLD=${IML_NOTIFY_BACKLOG_THRESHOLD:-10}
IML_NOTIFY_STUCK_MIN=${IML_NOTIFY_STUCK_MIN:-20}
IML_NOTIFY_STATE_FILE=${IML_NOTIFY_STATE_FILE:-/var/lib/nas-health/iml-notify-state.json}
TEMP_CLEAN_AGE_DAYS=${TEMP_CLEAN_AGE_DAYS:-7}
PLAYBACK_AUDIT_ENABLED=${PLAYBACK_AUDIT_ENABLED:-1}
PLAYBACK_AUDIT_MAX_MIN=${PLAYBACK_AUDIT_MAX_MIN:-45}
PLAYBACK_AUDIT_IMMICH_API=${PLAYBACK_AUDIT_IMMICH_API:-http://127.0.0.1:2283}
PLAYBACK_AUDIT_BASE=${PLAYBACK_AUDIT_BASE:-http://127.0.0.1}
PLAYBACK_AUDIT_OUTPUT_DIR=${PLAYBACK_AUDIT_OUTPUT_DIR:-/var/lib/nas-health}
PLAYBACK_AUDIT_WORKERS=${PLAYBACK_AUDIT_WORKERS:-24}
PLAYBACK_AUDIT_TIMEOUT_SEC=${PLAYBACK_AUDIT_TIMEOUT_SEC:-20}
PLAYBACK_AUDIT_SAMPLE_BYTES=${PLAYBACK_AUDIT_SAMPLE_BYTES:-256}
PLAYBACK_AUDIT_SCOPE=${PLAYBACK_AUDIT_SCOPE:-new_only}
PLAYBACK_AUDIT_SINCE_FILE=${PLAYBACK_AUDIT_SINCE_FILE:-/var/lib/nas-health/playback-audit.since}
PLAYBACK_AUDIT_FIRST_RUN_HOURS=${PLAYBACK_AUDIT_FIRST_RUN_HOURS:-24}
PLAYBACK_AUDIT_AUTOHEAL_ENABLED=${PLAYBACK_AUDIT_AUTOHEAL_ENABLED:-1}
PLAYBACK_AUDIT_AUTOHEAL_LIMIT=${PLAYBACK_AUDIT_AUTOHEAL_LIMIT:-200}
PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS=${PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS:-3}
PLAYBACK_AUDIT_DEEP_FFPROBE=${PLAYBACK_AUDIT_DEEP_FFPROBE:-1}
PLAYBACK_AUDIT_FFPROBE_TIMEOUT_IS_ERROR=${PLAYBACK_AUDIT_FFPROBE_TIMEOUT_IS_ERROR:-1}
PLAYBACK_AUDIT_AUTOHEAL_CLASSES="${PLAYBACK_AUDIT_AUTOHEAL_CLASSES:-not_found http_error resolver_error unexpected_content decode_error placeholder_missing placeholder_damaged placeholder_error}"
PLAYBACK_WATCHDOG_ENABLED=${PLAYBACK_WATCHDOG_ENABLED:-1}
PLAYBACK_WATCHDOG_NOTIFY=${PLAYBACK_WATCHDOG_NOTIFY:-0}
PLAYBACK_WATCHDOG_MAX_CYCLES=${PLAYBACK_WATCHDOG_MAX_CYCLES:-4}
PLAYBACK_WATCHDOG_INTERVAL_SEC=${PLAYBACK_WATCHDOG_INTERVAL_SEC:-180}
PLAYBACK_WATCHDOG_STUCK_ROUNDS=${PLAYBACK_WATCHDOG_STUCK_ROUNDS:-2}
PLAYBACK_WATCHDOG_REPROCESS_TIMEOUT_MIN=${PLAYBACK_WATCHDOG_REPROCESS_TIMEOUT_MIN:-240}
VIDEO_OPTIMIZE_MAX_MIN=${VIDEO_OPTIMIZE_MAX_MIN:-180}
VIDEO_NOTIFY_BACKLOG_THRESHOLD=${VIDEO_NOTIFY_BACKLOG_THRESHOLD:-10}
VIDEO_NOTIFY_STOP_MIN=${VIDEO_NOTIFY_STOP_MIN:-1440}
VIDEO_NOTIFY_STUCK_MIN=${VIDEO_NOTIFY_STUCK_MIN:-$VIDEO_NOTIFY_STOP_MIN}
VIDEO_NOTIFY_STATE_FILE=${VIDEO_NOTIFY_STATE_FILE:-/var/lib/nas-health/video-notify-state.env}
VIDEO_NOTIFY_VERBOSE=${VIDEO_NOTIFY_VERBOSE:-0}
EOF
chmod 0644 /etc/default/nas-video-policy
log_ok "Politica de video instalada (/etc/default/nas-video-policy)"

log_ok "Snapshots/restic de fotos/videos desactivados por diseño (BACKUP_PHOTOS_MODE=${BACKUP_PHOTOS_MODE:-disabled})"

cat > /etc/logrotate.d/supernas << 'EOF'
/var/log/night-run.log
/var/log/iml-autopilot.log
/var/log/video-reprocess-nightly.log
/var/log/playback-audit-autoheal.log
/var/log/playback-watchdog.log
/var/log/temp-clean.log
/var/log/nas-audit.log
/var/log/storage-failover.log
/var/log/failover-sync.log
/var/log/nas-install.log
/var/log/dockerd-manual.log
{
    monthly
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 0644 /etc/logrotate.d/supernas
log_ok "Rotación mensual de logs SUPER-NAS configurada (/etc/logrotate.d/supernas)"

cat > /etc/systemd/system/immich-video-playback-resolver.service << 'EOF'
[Unit]
Description=Immich video playback resolver
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /usr/local/bin/immich-video-playback-resolver.py
Restart=always
RestartSec=2
EnvironmentFile=-/etc/default/nas-video-policy
Environment=LISTEN_HOST=127.0.0.1
Environment=LISTEN_PORT=2284
Environment=IMMICH_API_BASE=http://127.0.0.1:2283
Environment=CACHE_ROOT=/var/lib/immich/cache
Environment=UPLOAD_HOST_ROOT=/mnt/storage-main/photos
Environment=IMMICH_LOCAL_ROOT=/var/lib/immich
Environment=PLACEHOLDER_LANDSCAPE_URI=/__static/video-processing.mp4
Environment=PLACEHOLDER_PORTRAIT_URI=/__static/video-processing-portrait.mp4
Environment=PLACEHOLDER_DAMAGED_LANDSCAPE_URI=/__static/video-damaged.mp4
Environment=PLACEHOLDER_DAMAGED_PORTRAIT_URI=/__static/video-damaged-portrait.mp4
Environment=PLACEHOLDER_MISSING_LANDSCAPE_URI=/__static/video-missing.mp4
Environment=PLACEHOLDER_MISSING_PORTRAIT_URI=/__static/video-missing-portrait.mp4
Environment=PLACEHOLDER_ERROR_LANDSCAPE_URI=/__static/video-error.mp4
Environment=PLACEHOLDER_ERROR_PORTRAIT_URI=/__static/video-error-portrait.mp4
Environment=DIRECT_PLAY_INTERNAL_PREFIX=/__immich-direct/
Environment=CACHE_INTERNAL_PREFIX=/__cache-video/
Environment=UPLOAD_PREFIX=/usr/src/app/upload/

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable immich-video-playback-resolver >/dev/null 2>&1
systemctl restart immich-video-playback-resolver
log_ok "Resolutor de playback web instalado (placeholder de dia, cache nocturno)"

# ════════════════════════════════════════════════════════════════════════════
# 14. SECRETOS DE TELEGRAM
# ════════════════════════════════════════════════════════════════════════════
# /etc/nas-secrets se crea con permisos 600 (solo root).
# Contiene el token del bot y el chat_id — credenciales que no deben
# estar en el .env de Docker ni en variables de entorno públicas.
log_step "Configurando secretos Telegram"

EXISTING_TELEGRAM_TOKEN="$(awk -F= '$1=="TELEGRAM_TOKEN"{gsub(/"/,"",$2); print $2}' /etc/nas-secrets 2>/dev/null | head -1)"
EXISTING_TELEGRAM_CHAT_ID="$(awk -F= '$1=="TELEGRAM_CHAT_ID"{gsub(/"/,"",$2); print $2}' /etc/nas-secrets 2>/dev/null | head -1)"
EXISTING_IMMICH_API_KEY="$(awk -F= '$1=="IMMICH_API_KEY"{sub(/^[^=]*=/,""); gsub(/^[[:space:]]*"/,"",$0); gsub(/"$/,"",$0); print $0}' /etc/nas-secrets 2>/dev/null | head -1)"
EXISTING_IMMICH_ADMIN_EMAIL="$(awk -F= '$1=="IMMICH_ADMIN_EMAIL"{gsub(/"/,"",$2); print $2}' /etc/nas-secrets 2>/dev/null | head -1)"
EXISTING_IMMICH_ADMIN_PASSWORD="$(awk -F= '$1=="IMMICH_ADMIN_PASSWORD"{sub(/^[^=]*=/,""); gsub(/^[[:space:]]*"/,"",$0); gsub(/"$/,"",$0); print $0}' /etc/nas-secrets 2>/dev/null | head -1)"

FINAL_TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-$EXISTING_TELEGRAM_TOKEN}"
FINAL_TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$EXISTING_TELEGRAM_CHAT_ID}"
FINAL_IMMICH_API_KEY="${IMMICH_API_KEY:-$EXISTING_IMMICH_API_KEY}"
FINAL_IMMICH_ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-$EXISTING_IMMICH_ADMIN_EMAIL}"
FINAL_IMMICH_ADMIN_PASSWORD="${IMMICH_ADMIN_PASSWORD:-$EXISTING_IMMICH_ADMIN_PASSWORD}"

if [ -n "$FINAL_TELEGRAM_TOKEN" ] && [ -n "$FINAL_TELEGRAM_CHAT_ID" ]; then
    cat > /etc/nas-secrets << EOF
TELEGRAM_TOKEN="$FINAL_TELEGRAM_TOKEN"
TELEGRAM_CHAT_ID="$FINAL_TELEGRAM_CHAT_ID"
IMMICH_API_KEY="$FINAL_IMMICH_API_KEY"
IMMICH_ADMIN_EMAIL="$FINAL_IMMICH_ADMIN_EMAIL"
IMMICH_ADMIN_PASSWORD="$FINAL_IMMICH_ADMIN_PASSWORD"
EOF
    chmod 600 /etc/nas-secrets
    log_ok "Secretos Telegram/Immich guardados en /etc/nas-secrets"
else
    cat > /etc/nas-secrets << 'EOF'
# Completar para activar alertas Telegram
# Obtener TOKEN: crear bot con @BotFather en Telegram
# Obtener CHAT_ID: enviar mensaje al bot y consultar /getUpdates
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# Para auditoría/autocorrección de playback:
# Opción recomendada:
# IMMICH_API_KEY="..."
#
# Opción alternativa:
# IMMICH_ADMIN_EMAIL="..."
# IMMICH_ADMIN_PASSWORD="..."
IMMICH_API_KEY=""
IMMICH_ADMIN_EMAIL=""
IMMICH_ADMIN_PASSWORD=""
EOF
    chmod 600 /etc/nas-secrets
    log_warn "Secretos incompletos — editar /etc/nas-secrets para activar Telegram y auditoría playback"
fi

# Inyectar umbrales de cache desde nas.conf en cache-monitor.sh
# sed -i modifica el archivo en lugar (in-place)
sed -i "s/^WARN_GB=.*/WARN_GB=${CACHE_WARN_GB}/" /usr/local/bin/cache-monitor.sh
sed -i "s/^CRIT_GB=.*/CRIT_GB=${CACHE_CRIT_GB}/" /usr/local/bin/cache-monitor.sh

# Persistir valor heredado (compatibilidad histórica; ya no gobierna fotos/videos)
echo "${BACKUP_RETENTION_DAYS}" > /etc/nas-retention
log_ok "Retención heredada guardada en /etc/nas-retention (${BACKUP_RETENTION_DAYS} días)"

# Persistir rutas de discos para que smart-check.sh use los discos correctos
# Evita hardcodear /dev/sdX que puede cambiar según orden de detección USB
echo "${DISK_PHOTOS} ${DISK_BACKUP}" > /etc/nas-disks
log_ok "Discos registrados → /etc/nas-disks (${DISK_PHOTOS} ${DISK_BACKUP})"

# Persistir puntos de montaje para mount-guard.sh
cat > /etc/nas-mounts << EOF
MOUNT_MAIN="$MOUNT_PHOTOS"
MOUNT_BACKUP="$MOUNT_BACKUP"
MOUNT_MERGED="$MOUNT_MERGED"
EOF
chmod 644 /etc/nas-mounts
log_ok "Montajes registrados → /etc/nas-mounts"

# Preparar espejo operativo para failover desde instalación.
mkdir -p "${MOUNT_BACKUP}/failover-main/photos" "${MOUNT_BACKUP}/failover-main/cache"
if [ -x /usr/local/bin/failover-sync.sh ]; then
    if nice -n 15 ionice -c2 -n7 /usr/local/bin/failover-sync.sh sync >/tmp/failover-sync-install.log 2>&1; then
        log_ok "Espejo de failover inicial sincronizado"
    else
        log_warn "No pude completar el espejo inicial de failover (ver /tmp/failover-sync-install.log)"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 15. CRONTAB
# ════════════════════════════════════════════════════════════════════════════
log_step "Configurando crontab"

CRON_CONTENT="# NAS S905X3 — generado por install.sh $(date +%F)

# ── Secuencia nocturna ────────────────────────────────────────────────────
# Cola: video → SMART semanal → backup → cache → IML 24/7 (estado) → DB backup
# Razón del horario 2 AM: CPU frío (35°C), sin usuarios activos,
# 4 horas de margen antes de las 6 AM para completar todo.
0 2 * * * /usr/local/bin/night-run.sh

# ── Guardia térmica reactiva ──────────────────────────────────────────────
# Independiente de night-run.sh: detecta sobrecalentamiento en cualquier
# momento del día, no solo durante la secuencia nocturna.
# 3 niveles: falla ventilador (55°C en reposo), ML stop (75°C), crítico (85°C).
*/5 * * * * /usr/local/bin/ml-temp-guard.sh

# ── Guardia de montajes ────────────────────────────────────────────────────
# Vigila desmontajes inesperados y notifica transiciones:
#   down -> alerta crítica
#   up   -> alerta de recuperación
*/3 * * * * /usr/local/bin/mount-guard.sh

# ── IML continuo por carga (activo por default) ───────────────────────────
# Drena colas de IML cuando la caja está libre y se pausa en picos de uso.
*/10 * * * * /usr/local/bin/iml-autopilot.sh

# ── Reproceso continuo por carga (activo por default) ─────────────────────
# Convierte videos pendientes sin esperar a la noche y se pausa/reanuda
# automáticamente según CPU/RAM/temperatura/requests.
*/10 * * * * /usr/local/bin/video-autopilot.sh

# ── Auditoría operativa continua ───────────────────────────────────────────
# Deja traza histórica para diagnóstico (sin depurar fotos/videos).
*/5 * * * * /usr/local/bin/audit-snapshot.sh

# ── Mantenimiento mensual — día 1: SMART short ────────────────────────────
# Test corto no destructivo (~2 min). Verifica electrónica básica.
0 3 1 * * /usr/local/bin/smart-check.sh monthly

# ── Mantenimiento trimestral — SMART long (sin bloquear pipeline) ─────────
# Día 15 de enero/abril/julio/octubre. El script solo inicia la prueba y
# reporta ETA; el resultado se revisa en corridas posteriores.
0 3 15 1,4,7,10 * /usr/local/bin/smart-check.sh extended

# ── Mantenimiento mensual — día 2: limpieza apt ───────────────────────────
# autoremove: elimina librerías huérfanas y kernels viejos post-upgrade.
# clean: elimina paquetes .deb descargados en /var/cache/apt/archives/.
# Libera ~800 MB – 2 GB en la eMMC sin afectar ningún servicio activo.
# Día 2 para no coincidir con el SMART del día 1.
0 3 2 * * apt-get autoremove -y && apt-get clean

# ── Mantenimiento mensual — día 3: limpieza journal ───────────────────────
# journald.conf ya limita a 100 MB, esto aplica la retención activamente.
0 3 3 * * journalctl --vacuum-time=7d

# ── Mantenimiento mensual — día 4: rotación y depuración de logs técnicos ─
0 3 4 * * /usr/local/bin/log-maintenance.sh

# ── Watchdog playback: evita backlog atascado ─────────────────────────────
30 4 * * * /usr/local/bin/playback-watchdog.sh
"

# Instalar sin sobreescribir configuración manual existente
if crontab -l 2>/dev/null | grep -q "night-run"; then
    log_warn "Crontab ya tiene night-run — omitiendo (revisar manualmente con: crontab -e)"
else
    { crontab -l 2>/dev/null || true; echo "$CRON_CONTENT"; } | crontab -
    log_ok "Crontab configurado (bloque NAS instalado)"
fi

# ════════════════════════════════════════════════════════════════════════════
# 16. TAILSCALE — VPN para acceso remoto seguro
# ════════════════════════════════════════════════════════════════════════════
# WireGuard con cifrado ChaCha20-Poly1305.
# En aarch64: ChaCha20 usa NEON, AES hardware del A55 acelera el handshake.
# Permite acceder al NAS desde el celular con datos móviles sin abrir puertos.
log_step "Instalando Tailscale"

if command -v tailscale &>/dev/null; then
    log_ok "Tailscale ya instalado: $(tailscale version | head -1)"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    log_ok "Tailscale instalado"
    log_info "Ejecutar 'tailscale up' para conectar al network"
fi

# ════════════════════════════════════════════════════════════════════════════
# 17. SAMBA — Acceso en red local (Windows/macOS)
# ════════════════════════════════════════════════════════════════════════════
log_step "Configurando Samba"

if ! grep -q "\[NAS\]" /etc/samba/smb.conf 2>/dev/null; then
    cat >> /etc/samba/smb.conf << EOF

[NAS]
   path = $MOUNT_PHOTOS/photos
   browseable = yes
   guest ok = yes
   read only = no
EOF
fi

if ! id nas &>/dev/null; then
    useradd -M -s /sbin/nologin nas
    log_info "Usuario 'nas' creado — establecer contraseña con: smbpasswd -a nas"
fi

systemctl enable smbd
systemctl restart smbd
log_ok "Samba configurado"

# ════════════════════════════════════════════════════════════════════════════
# 18. ARRANCAR IMMICH
# ════════════════════════════════════════════════════════════════════════════
log_step "Iniciando Immich"

cd /opt/immich-app
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d database redis

log_info "Esperando que PostgreSQL de Immich esté listo..."
wait_for_immich_postgres || die "PostgreSQL de Immich no respondió tras 60 segundos"
log_ok "PostgreSQL listo"

# Sembrar un perfil conservador antes del primer arranque del servidor:
# Smart Search queda disponible, pero OCR, caras y duplicados no consumen
# CPU por defecto. Si luego el usuario cambia estos valores en Immich,
# una re-ejecución del instalador no los sobreescribe.
seed_immich_conservative_ai_defaults

docker compose up -d immich-server database redis

if docker compose create immich-machine-learning >/dev/null 2>&1; then
    log_ok "Contenedor ML preparado para la madrugada (queda apagado al instalar)"
elif docker inspect immich_machine_learning >/dev/null 2>&1; then
    log_ok "Contenedor ML ya estaba preparado"
else
    log_warn "No se pudo preparar el contenedor ML en modo apagado"
fi

docker compose stop immich-machine-learning >/dev/null 2>&1 || true

if [ "${IMMICH_CONFIG_PROFILE_CHANGED:-0}" -eq 1 ]; then
    log_info "Recargando immich_server para aplicar el perfil IA..."
    docker compose restart immich-server >/dev/null 2>&1 || true
fi

log_info "Esperando que los contenedores estén listos..."
sleep 15
docker compose ps

log_ok "Immich iniciado"

# ════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ════════════════════════════════════════════════════════════════════════════
TAILSCALE_IP=$(tailscale ip 2>/dev/null | head -1 || echo "no conectado")
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "desconocida")

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✓  INSTALACIÓN COMPLETADA${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Immich (red local):  ${BOLD}http://${LOCAL_IP}:2283${NC}"
echo -e "  Immich (Tailscale):  ${BOLD}http://${TAILSCALE_IP}:2283${NC}"
echo ""
echo -e "  Perfil IA inicial:   ${BOLD}Smart Search sí · OCR/caritas/duplicados no${NC}"
echo -e "  Mapa y lugares:      ${BOLD}activos${NC}"
echo -e "  IA 24/7 disponible:  ${BOLD}activa por carga (CPU/RAM/temp/requests)${NC}"
echo ""
echo -e "  Logs de instalación: ${BOLD}$LOG${NC}"
echo -e "  Log nocturno:        ${BOLD}/var/log/night-run.log${NC}"
echo ""
echo -e "  ${YELLOW}Pasos manuales pendientes:${NC}"
echo    "  1. Conectar VPN:     tailscale up"
[ -z "${TELEGRAM_TOKEN:-}" ] && \
echo    "  2. Telegram:         editar /etc/nas-secrets"
echo    "  3. Contraseña Samba: smbpasswd -a nas"
echo    "  4. Crear usuario:    http://${LOCAL_IP}:2283"
echo ""
echo "════ Instalación finalizada: $(date) ════" >> "$LOG"


# ─────────────────────────────────────────────────────────────────────────────
# PARCHE: placeholder de video para Immich/nginx
# Si Immich responde 404 en rutas de video sin derivado listo, nginx servirá
# /var/lib/immich/static/video-processing.mp4 usando el poster oficial del NAS.
# AYUDA PARA REVISIÓN POR IA:
#   validar proxy_intercept_errors, error_page 404 y que no haya fallback al
#   original HDD mientras no exista caché optimizado.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /var/lib/immich/static
PLACEHOLDER_POSTER_SOURCE="$SCRIPT_DIR/assets/video-processing-poster-source.png"
if [ -f "$PLACEHOLDER_POSTER_SOURCE" ]; then
  ffmpeg -y -loop 1 -i "$PLACEHOLDER_POSTER_SOURCE" -t 4 \
    -vf "scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2:0x0b1535,format=yuv420p" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    /var/lib/immich/static/video-processing.mp4 >/dev/null 2>&1 || true
  ffmpeg -y -loop 1 -i "$PLACEHOLDER_POSTER_SOURCE" -t 4 \
    -vf "scale=720:1280:force_original_aspect_ratio=decrease:flags=lanczos,pad=720:1280:(ow-iw)/2:(oh-ih)/2:0x0b1535,format=yuv420p" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    /var/lib/immich/static/video-processing-portrait.mp4 >/dev/null 2>&1 || true
else
  ffmpeg -y -f lavfi -i color=c=0x111827:s=1280x720:d=4 \
    -vf "drawbox=x=80:y=70:w=1120:h=170:color=0x0f172acc:t=fill,drawbox=x=80:y=495:w=1120:h=135:color=0x1d4ed8cc:t=fill,drawtext=text='VIDEO AUN NO DISPONIBLE':fontcolor=white:fontsize=54:x=(w-text_w)/2:y=108,drawtext=text='Vuelve manana':fontcolor=white:fontsize=72:x=(w-text_w)/2:y=168,drawtext=text='El NAS lo esta preparando para verlo sin trabas':fontcolor=white:fontsize=34:x=(w-text_w)/2:y=535" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart /var/lib/immich/static/video-processing.mp4 >/dev/null 2>&1 || true
  ffmpeg -y -f lavfi -i color=c=0x111827:s=720x1280:d=4 \
    -vf "drawbox=x=40:y=120:w=640:h=210:color=0x0f172acc:t=fill,drawbox=x=40:y=905:w=640:h=150:color=0x1d4ed8cc:t=fill,drawtext=text='VIDEO AUN NO DISPONIBLE':fontcolor=white:fontsize=42:x=(w-text_w)/2:y=170,drawtext=text='Vuelve manana':fontcolor=white:fontsize=58:x=(w-text_w)/2:y=235,drawtext=text='El NAS lo esta preparando':fontcolor=white:fontsize=28:x=(w-text_w)/2:y=950,drawtext=text='para verlo sin trabas':fontcolor=white:fontsize=28:x=(w-text_w)/2:y=995" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart /var/lib/immich/static/video-processing-portrait.mp4 >/dev/null 2>&1 || true
fi

make_landscape_variant() {
  local src="$1" out="$2" title="$3" subtitle="$4"
  ffmpeg -y -i "$src" \
    -vf "drawbox=x=80:y=500:w=1120:h=150:color=0x0f172add:t=fill,drawtext=text='$title':fontcolor=white:fontsize=56:x=(w-text_w)/2:y=535,drawtext=text='$subtitle':fontcolor=white:fontsize=36:x=(w-text_w)/2:y=605" \
    -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$out" >/dev/null 2>&1 || true
}

make_portrait_variant() {
  local src="$1" out="$2" title="$3" subtitle="$4"
  ffmpeg -y -i "$src" \
    -vf "drawbox=x=40:y=900:w=640:h=220:color=0x0f172add:t=fill,drawtext=text='$title':fontcolor=white:fontsize=48:x=(w-text_w)/2:y=950,drawtext=text='$subtitle':fontcolor=white:fontsize=30:x=(w-text_w)/2:y=1020" \
    -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$out" >/dev/null 2>&1 || true
}

make_landscape_variant \
  /var/lib/immich/static/video-processing.mp4 \
  /var/lib/immich/static/video-damaged.mp4 \
  "ARCHIVO DANADO" \
  "No se puede reproducir este video"
make_portrait_variant \
  /var/lib/immich/static/video-processing-portrait.mp4 \
  /var/lib/immich/static/video-damaged-portrait.mp4 \
  "ARCHIVO DANADO" \
  "No se puede reproducir"

make_landscape_variant \
  /var/lib/immich/static/video-processing.mp4 \
  /var/lib/immich/static/video-missing.mp4 \
  "ARCHIVO NO ENCONTRADO" \
  "El original no esta en el NAS"
make_portrait_variant \
  /var/lib/immich/static/video-processing-portrait.mp4 \
  /var/lib/immich/static/video-missing-portrait.mp4 \
  "ARCHIVO NO ENCONTRADO" \
  "El original no esta en NAS"

make_landscape_variant \
  /var/lib/immich/static/video-processing.mp4 \
  /var/lib/immich/static/video-error.mp4 \
  "ERROR TEMPORAL" \
  "Intenta de nuevo en unos minutos"
make_portrait_variant \
  /var/lib/immich/static/video-processing-portrait.mp4 \
  /var/lib/immich/static/video-error-portrait.mp4 \
  "ERROR TEMPORAL" \
  "Intenta de nuevo"
