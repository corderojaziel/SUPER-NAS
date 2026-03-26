# 🧠 NAS S905X3 – Sistema Multimedia Autónomo y Resiliente

Infraestructura NAS casera basada en TV Box S905X3, optimizada para ingestión, procesamiento y gestión eficiente de grandes volúmenes de fotos y videos usando hardware limitado.

---

## 🚀 Qué hace este sistema

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
* `cache-clean.sh` → limpieza de cache
* `smart-check.sh` → salud de discos

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
