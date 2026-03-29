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
├── cache/            # videos optimizados (720p)
└── ...

# 🛡️ Disco secundario (respaldo)
/mnt/storage-backup/
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
/library → video-optimize.sh → /cache (720p)
```

* conversión GPU (`h264_nvenc`)
* fallback automático a CPU (`libx264`)
* reducción de resolución + bitrate
* evita reprocesar (verificación en cache)

👉 clave:
la conversión se prioriza en ventana nocturna, pero ahora también puede drenar por carga durante el día (pausa/reanuda automática)

---

### 📤 Consumo (read path)

#### 🎥 Videos

```text
Cliente → nginx → Immich → /cache (720p)
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
  👉 sincroniza datos hacia el disco de respaldo

* `cache-clean.sh`
  👉 audita huérfanos del cache (no borra)

* `cache-migrate-to-disk.sh`
  👉 migra cache de eMMC a HDD con symlinks (manual)

* `manual-retention.sh`
  👉 depura respaldos solo bajo decisión manual

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
* sin RAID
* limitado por RAM (4GB)

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
* ⚙️ en mejora continua

---

* 📥 Recepción masiva de multimedia (Immich)
* 🎬 Optimización automática de video
* 🧠 Decisiones inteligentes de procesamiento
* 💾 Separación de originales vs optimizados
* ⚙️ Protección ante fallos operativos

---

## 📂 Estructura de almacenamiento

```bash
# Sistema (eMMC)
/ (eMMC)
├── /opt/
├── /usr/local/bin/
├── /var/log/
└── ...

# Disco principal
/mnt/storage-main/
├── photos/upload
├── cache
├── .state
└── ...

# Disco backup
/mnt/storage-backup/
├── photos
├── cache
└── ...
```

---

## 🧠 Roles por almacenamiento

### ⚡ eMMC

* Sistema operativo
* Docker + Immich
* Scripts y logs

### 💾 storage-main

* Datos activos
* Cache optimizado

### 🛡️ storage-backup

* Respaldo

---

## 🔁 Flujo entre discos

* Entrada → `/storage-main/photos/upload`
* Procesamiento → `/storage-main/cache`
* Backup → `/storage-backup/`

---

## 🎬 Pipeline de video

* Filtrado por tamaño
* Detección de duplicados
* Conversión híbrida (GPU/CPU)
* Validación de salida
* Limpieza automática

---

## ⚙️ Scripts del sistema

### 🧱 Instalación

* `install.sh` → instalación inicial del sistema
* `verify.sh` → validación post-instalación

---

### 🔁 Operación

* `night-run.sh` → orquestador principal (2:00 AM)
* `video-optimize.sh` → conversión de videos
* `nas-alert.sh` → envío de alertas

---

### 🛡️ Protección

* `mount-guard.sh` → valida discos montados
* `ml-temp-guard.sh` → controla carga/temperatura
* `retry-quarantine.sh` → reintentos (WIP)

---

### 💽 Mantenimiento

* `backup.sh` → sincronización de datos
* `cache-clean.sh` → auditoría de cache (sin borrado)
* `cache-migrate-to-disk.sh` → migración manual de cache a HDD
* `manual-retention.sh` → depuración manual de respaldos
* `smart-check.sh` → salud de discos

👉 Regla operativa: no hay depuración automática de fotos/videos productivos.

---

## ⚡ Optimizaciones implementadas

* Filtrado por tamaño
* Detección de duplicados
* Conversión híbrida GPU/CPU
* Reducción de resolución
* Control de bitrate
* Validación de archivos
* Skip automático de errores
* Fallback automático
* Control de carga (secuencial)
* Validación de mounts
* Limpieza de temporales
* Alertas automáticas

---

## ☁️ Integración con Immich

* Ingesta automática
* Procesamiento concurrente
* No interfiere agresivamente con uploads

---

## 📡 Alertas

* Telegram (`nas-alert.sh`)
* Eventos críticos y fallos

---

## 📊 Monitoreo

* `btop`, `htop`
* `du`, `df`, `duf`
* `docker stats`

---

## 🎯 Filosofía

* Estabilidad > rendimiento
* Procesamiento progresivo
* Modularidad
* Tolerancia a fallos

---

## ⚠️ Limitaciones

* Hardware limitado
* Sin RAID
* Dependencia del disco principal

---

## 🧪 Estado

* ✔ Funcional
* ✔ Automatizado
* ⚙️ En optimización

---

## 🔮 Próximos pasos

* Control de concurrencia dinámico
* Integración completa de reintentos
* Mejor coordinación con Immich

---
