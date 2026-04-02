# 🧠 NAS S905X3 – Sistema Multimedia Autónomo y Resiliente

Infraestructura NAS casera basada en TV Box S905X3, optimizada para ingestión, procesamiento y gestión eficiente de grandes volúmenes de fotos y videos usando hardware limitado.

---

## ✅ Prerrequisitos de instalación

Antes de ejecutar `install.sh`, confirma lo siguiente:

* TV Box con Armbian/Ubuntu Linux (acceso por `root` o usuario con `sudo`)
* 2 discos detectados por el sistema (`DISK_PHOTOS` y `DISK_BACKUP`)
* Conectividad a internet (instalación de Docker, paquetes y Tailscale)
* Repositorio clonado localmente
* Archivo `config/nas.conf` editado con valores reales de discos (`/dev/sdX`), `DB_PASSWORD`, `TIMEZONE` y `ALLOW_FORMAT`
* Opcional: `TELEGRAM_TOKEN` y `TELEGRAM_CHAT_ID` para alertas

---

## 🚀 Instalación (paso a paso)

```bash
# 1) Clonar
git clone https://github.com/corderojaziel/SUPER-NAS.git
cd SUPER-NAS

# 2) Editar configuración
nano config/nas.conf

# 3) Validar discos y nombres reales
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT

# 4) Precheck (recomendado)
chmod +x precheck.sh install.sh verify.sh
sudo ./precheck.sh

# 5) Instalar
sudo ./install.sh

# 6) Verificación post-instalación
sudo /usr/local/bin/verify.sh
```

Si quieres usar otro perfil de configuración:

```bash
sudo NAS_CONFIG_FILE=/ruta/a/otro-perfil.conf ./install.sh
```

Para restaurar en caja nueva con discos existentes (sin formateo):

```bash
sudo INSTALL_MODE=restore ./install.sh
sudo /usr/local/bin/disaster-restore.sh latest
```

Previsualización sin riesgo (sin escribir nada):

```bash
sudo /usr/local/bin/disaster-restore.sh latest --dry-run
```

Flujo todo-en-uno desde OS limpio:

```bash
sudo bash maintenance/bootstrap-restore.sh --repo "$(pwd)" --snapshot latest --dry-run
sudo bash maintenance/bootstrap-restore.sh --repo "$(pwd)" --snapshot latest
```

---

## 🏗️ Arquitectura del sistema

El sistema está dividido en **3 capas físicas con roles definidos**:

```bash
# ⚡ eMMC (alta velocidad)
/ (sistema)
├── Docker (Immich, PostgreSQL, Redis)
├── thumbnails (lectura intensiva)
├── base de datos (PostgreSQL)
└── servicios

# 💾 Disco principal (datos activos)
/mnt/storage-main/
├── photos/upload     # ingestión (Immich)
├── library/          # archivos organizados
├── (sin cache activo legado)
└── ...

# 🛡️ Disco secundario (respaldo)
/mnt/storage-backup/
├── failover-main/    # espejo operativo para switch automático
└── snapshots/immich-db/  # respaldo lógico de DB (retención corta)
```

---

## 🔁 Flujo real del sistema

### 📥 Ingesta (write path)

```text
Celular → nginx → Immich → /upload → rename → /library
```

* subida concurrente desde múltiples usuarios
* escritura directa al disco principal
* `rename` atómico (sin copia de datos)

---

### ⚙️ Procesamiento inmediato (post-upload)

* generación de thumbnails (libvips)
* indexación en PostgreSQL (eMMC)
* extracción de metadata (EXIF)

👉 consumo típico:

* CPU: 60–80%
* RAM: ~70%
* duración: 3–5 min

---

### 🎬 Optimización diferida (pipeline nocturno + autopiloto por carga)

```text
/library → video-optimize.sh → /var/lib/immich/cache (canónico)
```

* conversión compatible móvil/tablet:
  `H.264 + yuv420p + faststart + lado largo máx. 1920 + level 4.1`
* fallback automático a CPU (`libx264`) en flujos shell
* reproceso pesado en PC/GPU con `powershell/reprocess_heavy_from_server.ps1`
* evita reprocesar (verificación en cache)

👉 clave:
la conversión se prioriza en ventana nocturna, pero ahora también puede drenar por carga durante el día (pausa/reanuda automática)

---

### 📤 Consumo (read path)

#### 🎥 Videos

```text
Cliente → nginx → resolver playback →
  - <= 40 MB/min: original directo (con link canónico en cache)
  - > 40 MB/min: cache canónico en eMMC (/var/lib/immich/cache)
  - exclusiones de reproceso: solo motion clips (política activa)
```

#### 🖼️ Fotos

```text
Cliente → nginx → cache eMMC (thumbnails)
```

👉 resultado:

* lecturas rápidas desde eMMC
* mínimo uso del disco principal
* baja latencia

---

## ⚙️ Scripts del sistema (shells)

### 🧱 Instalación

* `install.sh`
  👉 configura el sistema completo (cron, rutas, servicios)

* `verify.sh`
  👉 valida que todo esté correctamente instalado

---

### 🔁 Operación

* `night-run.sh`
  👉 orquestador principal (ejecuta tareas nocturnas)

* `iml-autopilot.sh`
  👉 drena colas IML cuando CPU/RAM/temperatura/requests lo permiten

* `video-autopilot.sh`
  👉 drena cola de video sin esperar a la noche, con pausado automático por carga

* `playback-audit-autoheal.sh`
  👉 audita playback y autocorrige rotos ligeros (por defecto audita solo videos nuevos)

* `playback-watchdog.sh`
  👉 vigila estancamiento de playback y publica estado en resumen nocturno (sin spam suelto)

* `video-optimize.sh`
  👉 convierte videos a formato optimizado (cache)

* `nas-alert.sh`
  👉 envía alertas a Telegram

---

### 🛡️ Protección

* `mount-guard.sh`
  👉 valida que los discos estén montados antes de operar

* `ml-temp-guard.sh`
  👉 controla carga/temperatura del sistema

* `retry-quarantine.sh` *(en integración)*
  👉 reintenta archivos fallidos

---

### 💽 Mantenimiento

* `backup.sh`
  👉 flujo de respaldo operativo (sin snapshots/restic de fotos/videos)
  👉 mantiene espejo de failover vía `failover-sync.sh`

* `failover-sync.sh`
  👉 sincroniza espejo operativo de fotos + cache a `/mnt/storage-backup/failover-main`
  👉 no borra fotos/videos automáticamente

* `cache-clean.sh`
  👉 audita huérfanos del cache (no borra)

* `temp-clean.sh`
  👉 depura solo temporales técnicos (reprocess/tmp/cache incompleto), con `--dry-run` y `--apply`
  👉 incluye guardas de ruta: si detecta objetivo no seguro, lo salta y lo reporta

* `cache-migrate-to-disk.sh`
  👉 migra cache de eMMC a HDD con symlinks (manual)

* `manual-retention.sh`
  👉 depura respaldos de soporte (DB/estado) solo bajo decisión manual
  👉 `--apply` requiere confirmación explícita:
  `--confirm BORRAR_RESPALDOS_SUPERNAS`

* `smart-check.sh`
  👉 monitorea salud de discos

---

## ⚡ Decisiones de arquitectura (clave)

### 1️⃣ Separación eMMC vs disco

* eMMC → lecturas intensivas (DB, thumbnails)
* disco → almacenamiento masivo

👉 evita cuellos de botella en I/O

---

### 2️⃣ Cache de video obligatorio

* 4K original → 40–60 Mbps
* red disponible → ~12 Mbps

👉 sin cache: ❌ no reproducible
👉 con cache: ✅ estable

---

### 3️⃣ Procesamiento desacoplado

* ingestión ≠ conversión
* optimización en background

👉 evita romper uploads

---

### 4️⃣ Control de carga

* procesamiento secuencial
* workers limitados
* colas IML/video pausadas por carga
* Smart Search disponible en horario diurno

---

### 5️⃣ RAIT de discos (espejo + failover automático)

* Esquema implementado: espejo operativo en disco backup + switch automático por falla grave
* `storage-failover.sh auto` conmutará a `/mnt/storage-backup/failover-main` solo ante condición crítica real
* `failover-sync.sh` mantiene actualizado el espejo sin borrar productivo
* retorno a principal cuando vuelve sano (según política `AUTO_FAILBACK_ENABLED`)

👉 nota técnica:
esto es **RAIT operativo a nivel de flujo**, no RAID de bloque (`mdadm`/ZFS mirror).

---

## 📊 Comportamiento bajo carga

### 👥 2 usuarios concurrentes

* RAM: ~52–72%
* CPU:

  * normal: 25–35%
  * ingesta: hasta 80%
* temperatura: 42–62°C

👉 sistema estable

---

## ⚠️ Cuellos de botella reales

* 🎥 videos nuevos sin cache
* 💾 presión de RAM en ingesta
* 🔥 picos de CPU (thumbnails)

---

## ⚡ Optimizaciones implementadas

* separación física de I/O
* cache en eMMC
* conversión GPU + fallback CPU
* filtrado por tamaño
* detección de duplicados
* control de bitrate/resolución
* procesamiento diferido
* rename atómico
* validación de mounts
* auditoría sin borrado automático de fotos/videos

---

## ⚠️ Limitaciones

* sin transcodificación en tiempo real
* los lotes grandes siguen siendo más eficientes en ventana nocturna
* no usa RAID de bloque clásico (`mdadm`/ZFS)
* limitado por RAM (4GB)
* el espejo/failover depende de que `failover-sync` esté al día

---

## 🎯 Objetivo

Mantener ingestión estable y reproducción eficiente mediante:

* cache inteligente
* separación de cargas
* procesamiento progresivo
* control de recursos

---

## 🧪 Estado

* ✔ arquitectura estable
* ✔ pipeline funcional
* ✔ validado bajo carga real
* ✔ RAIT operativo (espejo + failover + restore de estado)
* ⚙️ en mejora continua

---

## 🔮 Próximos pasos

* Control de concurrencia dinámico
* Integración completa de reintentos
* Métricas históricas de backlog IML/video con tendencia
* Mejor coordinación con Immich

---
