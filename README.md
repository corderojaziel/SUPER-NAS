# 🧠 NAS S905X3 – Sistema Multimedia Autónomo y Resiliente

Infraestructura NAS casera basada en TV Box S905X3, optimizada para ingestión, procesamiento y gestión eficiente de grandes volúmenes de fotos y videos usando hardware limitado.

---

## 🚀 Qué hace este sistema

Este NAS no solo almacena archivos, sino que:

* 📥 **Recibe contenido multimedia masivo** (principalmente desde Immich)
* 🎬 **Optimiza videos automáticamente** para reducir peso y carga
* 🧠 **Decide qué procesar y qué ignorar** (evita reprocesos)
* 💾 **Mantiene separación entre originales y versiones optimizadas**
* ⚙️ **Se protege a sí mismo contra fallos comunes (mounts, temperatura, carga)**

---

## 📂 Estructura de almacenamiento

```
/mnt/storage-main/
├── photos/upload     # Entrada principal (Immich)
├── cache             # Videos optimizados
└── ...

/mnt/storage-backup/  # Respaldo
```

---

## 🎬 Pipeline de video

### 🔁 Flujo real:

1. Archivos llegan a:

   ```
   /mnt/storage-main/photos/upload
   ```

2. Detección inteligente:

   * Filtrado por tamaño (ej: >40MB)
   * Evita duplicados en cache

3. Conversión híbrida:

   **GPU (NVENC):**

   * Compresión eficiente
   * Control de bitrate
   * Reducción de resolución

   **Fallback CPU:**

   * CRF optimizado
   * Preset rápido para hardware limitado

4. Resultado:

   ```
   /mnt/storage-main/cache
   ```

---

## ⚙️ Automatización

### 🕑 Orquestador

* `night-run.sh` → 2:00 AM

### 🛡️ Protección

* `mount-guard.sh`
* `ml-temp-guard.sh`
* `retry-quarantine.sh` *(en integración)*

### 💽 Mantenimiento

* `backup.sh`
* `cache-clean.sh`
* `smart-check.sh`

---

## ☁️ Integración con Immich

* Ingesta automática desde móvil
* Procesamiento paralelo (rostros, metadata)
* Manejo de cargas pesadas con tolerancia a fallos

---

## 📡 Alertas

* `nas-alert.sh`
* Integración con Telegram

---

## 🧠 Problemas reales considerados

* Timeouts en subida
* Saturación de CPU
* Cuellos de botella en almacenamiento
* Concurrencia alta
* Archivos problemáticos

---

## 📊 Monitoreo

* `btop`, `htop`
* `du`, `df`, `duf`
* `docker stats`

---

## 🎯 Filosofía

* Estabilidad sobre rendimiento bruto
* Procesamiento progresivo
* Automatización modular
* Tolerancia a fallos

---

## ⚠️ Limitaciones

* Hardware limitado (TV Box)
* Sin RAID tradicional
* Rendimiento condicionado por el medio de almacenamiento (no dependiente de USB)
* Procesamiento intensivo puede impactar ingestión si no se controla

---

## 🧪 Estado

* ✔ Pipeline funcional
* ✔ Conversión híbrida activa
* ✔ Automatización operativa
* ⚙️ En mejora continua

---

## 🔮 Próximos pasos

* Control de concurrencia inteligente
* Integración total de reintentos
* Optimización de ingestión vs procesamiento

---

## 🧩 Caso de uso

* Biblioteca multimedia personal
* Ingesta continua desde móvil
* Infraestructura eficiente y autónoma

---
