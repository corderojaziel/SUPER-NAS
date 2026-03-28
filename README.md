# 🧠 NAS S905X3 – Sistema Multimedia Autónomo y Resiliente

Infraestructura NAS casera basada en TV Box S905X3, optimizada para ingestión, procesamiento y gestión eficiente de grandes volúmenes de fotos y videos usando hardware limitado.

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

### 🎬 Optimización diferida (pipeline nocturno)

```text
/library → video-reprocess-nightly.sh → /cache (proxy de reproducción)
```

* regla de decisión por red mínima: **40 MB/min**
* si el video ya cumple regla: no transcodifica y conserva calidad
* si excede regla: genera versión ligera para reproducción remota
* conversión GPU (`h264_nvenc`) con fallback CPU (`libx264`)
* control adaptativo por carga (CPU/RAM/temperatura/requests)
* evita reprocesar (verificación en cache)

👉 clave:
los videos pesados **no se optimizan en tiempo real**, pero el sistema puede procesar por slices durante el día cuando la caja está libre

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

* `video-reprocess-nightly.sh`
  👉 convierte videos pesados a formato optimizado (cache)

* `video-autopilot.sh`
  👉 ejecuta reproceso por slices y espera IML antes de video

* `iml-autopilot.sh`
  👉 drena colas IML por fases, pausando/reanudando por carga

* `playback-audit-autoheal.sh`
  👉 audita playback real y autocorrige faltantes/rotos

* `nas-alert.sh`
  👉 envía alertas a Telegram

---

### 🛡️ Protección

* `mount-guard.sh`
  👉 valida que los discos estén montados antes de operar

* `ml-temp-guard.sh`
  👉 controla carga/temperatura del sistema

* `retry-quarantine.sh`
  👉 reintenta archivos fallidos

---

### 💽 Mantenimiento

* `backup.sh`
  👉 sincroniza datos hacia el disco de respaldo

* `state-backup.sh`
  👉 respaldo de estado operativo (DB/config/cron/políticas)

* `state-restore.sh`
  👉 restauración rápida de estado ante contingencia

* `cache-clean.sh`
  👉 limpia archivos innecesarios del cache

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
* red mínima objetivo → ~6 Mbps

👉 sin cache: ❌ no reproducible
👉 con cache: ✅ estable
👉 regla aplicada: si el video está en **≤40 MB/min**, no se recomprime

---

### 3️⃣ Procesamiento desacoplado

* ingestión ≠ conversión
* optimización en background

👉 evita romper uploads

---

### 4️⃣ Control de carga

* pausa/reanuda automática por CPU/RAM/temperatura/requests
* procesamiento por lotes pequeños (slices)
* IML por fases con dependencias
* alerta por tendencia cuando el backlog de IML crece sostenidamente

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
* regla de 40 MB/min (skip inteligente de transcodificación)
* filtrado por tamaño
* detección de duplicados
* control de bitrate/resolución
* procesamiento diferido + modo adaptativo por carga
* rename atómico
* validación de mounts
* limpieza automática
* auditoría de playback con autocorrección
* resumen nocturno con estado corto + detalle

---

## ⚠️ Limitaciones

* sin transcodificación en tiempo real
* videos pesados dependen de ventanas de procesamiento (no inmediato)
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

* Regla de decisión por red: 40 MB/min
* Skip automático si el video ya es reproducible
* Conversión híbrida (GPU/CPU) para videos pesados
* Validación de salida y playback
* Limpieza automática y conciliación de cache

---

## ⚙️ Scripts del sistema

### 🧱 Instalación

* `install.sh` → instalación inicial del sistema
* `verify.sh` → validación post-instalación

---

### 🔁 Operación

* `night-run.sh` → orquestador principal (2:00 AM)
* `video-reprocess-nightly.sh` → reproceso de videos pesados
* `video-autopilot.sh` → reproceso por slices durante el día
* `iml-autopilot.sh` → drenado IML por fases con pausa/reanuda
* `playback-audit-autoheal.sh` → auditoría playback + autocorrección
* `nas-alert.sh` → envío de alertas

---

### 🛡️ Protección

* `mount-guard.sh` → valida discos montados
* `ml-temp-guard.sh` → controla carga/temperatura
* `retry-quarantine.sh` → reintentos de fallos

---

### 💽 Mantenimiento

* `backup.sh` → sincronización de datos
* `state-backup.sh` → snapshot de estado operativo
* `state-restore.sh` → restauración de estado
* `cache-clean.sh` → limpieza de cache
* `smart-check.sh` → salud de discos

---

## ⚡ Optimizaciones implementadas

* Filtrado por tamaño
* Detección de duplicados
* Conversión híbrida GPU/CPU
* Regla 40 MB/min con skip inteligente
* Reducción de resolución
* Control de bitrate
* Validación de archivos
* Skip automático de errores
* Fallback automático
* Control de carga (CPU/RAM/temperatura/requests)
* Validación de mounts
* Limpieza de temporales
* Alertas automáticas
* Alerta de tendencia de backlog IML
* Resumen nocturno corto + detallado

---

## ☁️ Integración con Immich

* Ingesta automática
* Procesamiento concurrente
* Drenado IML por fases (dependencias)
* No interfiere agresivamente con uploads

---

## 📡 Alertas

* Telegram (`nas-alert.sh`)
* Eventos críticos y fallos
* Detección de atascos por crecimiento sostenido en IML

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

* Afinar umbrales por perfil real de uso
* Dashboard de salud/playback para operación diaria
* Auditoría periódica de logs y tuning de rendimiento

---
