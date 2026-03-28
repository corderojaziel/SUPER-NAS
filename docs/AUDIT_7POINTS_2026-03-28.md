# AUDITORÍA 7 PUNTOS (2026-03-28)

## 1) IML en PC (GPU local)
- Estado actual: colas objetivo en `0` (`duplicateDetection`, `ocr`, `sidecar`, `metadataExtraction`, `library`, `smartSearch`, `faceDetection`, `facialRecognition`).
- Validación: `iml-backlog-drain.py` corrió y confirmó `DONE ... all queues 0`.
- Cobertura manual: menú PowerShell ahora permite ejecutar cada cola por separado y también cierre final automático.

## 2) Scripts manuales + menú + config
- Confirmado:
  - `powershell/nas-ops-menu.ps1`
  - `powershell/nas-ops.config.ps1`
  - `maintenance/iml-backlog-drain.py`
  - `maintenance/iml-drain-finalize.py`
  - `maintenance/video-autopilot.sh`
  - `maintenance/playback-audit-autoheal.sh`
  - `maintenance/state-backup.sh`
  - `maintenance/state-restore.sh`
- Mejora aplicada:
  - Menú con opciones individuales por cola IML.
  - Opción de “monitorear hasta fin + apagar túnel + volver a normalidad”.

## 3) Transformación por carga CPU/RAM
- Confirmado en política:
  - `VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED`
  - `VIDEO_REPROCESS_MAX_CPU_PCT`
  - `VIDEO_REPROCESS_MAX_MEM_PCT`
  - lotes `VIDEO_REPROCESS_BATCH_LIGHT/HEAVY`
- Confirmado en scripts:
  - `video-reprocess-nightly.sh` implementa pausa/reanuda automática por carga.
  - `video-autopilot.sh` ejecuta por slices sin depender solo de la noche.
- Estado por defecto seguro:
  - `VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=0`
  - `VIDEO_AUTOPILOT_ENABLED=0`

## 4) Pantalla de restore rápido
- Confirmado:
  - Menú incluye backup y restore.
  - Scripts operativos en TV Box.
- Corrección aplicada:
  - `state-restore.sh` restauraba `nas-disks` y `nas-retention` en ruta incorrecta.
  - Se corrigió a `/etc/nas-disks` y `/etc/nas-retention`.
  - Se agregó respaldo/restauración de `root crontab`.

## 5) Logs y performance (hallazgos)
- Logs clave auditados:
  - `/var/log/night-run.log`
  - `/var/log/video-reprocess-nightly.log`
  - `/var/log/playback-audit-autoheal.log`
  - `/var/log/playback-watchdog.log`
  - `docker logs immich_server`
  - `docker logs immich_postgres`
  - `dmesg -T`
- Hallazgos principales:
  - `night-run`: timeouts recurrentes en `video optimize` y `cache clean`.
  - `immich_server`: errores OCR al caer endpoint ML remoto (`:13031`) durante túnel.
  - `dmesg`: eventos reales de I/O/EXT4 en `sda1` (riesgo de estabilidad en disco principal).
  - PostgreSQL: errores por consultas manuales sobre tablas/columnas no vigentes + duplicados de checksum en cargas simultáneas.
- Recomendación operativa:
  - Mantener uso de túnel ML solo en ventanas controladas.
  - Ejecutar `smart-check.sh daily` y revisión SMART extendida.
  - Revisar salud de `sda1` antes de nuevas cargas masivas.

## 6) Cruce server vs Git
- Se detectó deriva real entre servidor y repo.
- Ajuste aplicado:
  - Se subieron a Git mejoras que solo estaban en servidor para auditoría avanzada de playback (`scripts/audit_video_playback.py` + wiring en `playback-audit-autoheal.sh`).
  - Se mantuvo como fuente de verdad Git para restore/ops scripts.

## 7) Estado final de la auditoría
- Integridad base: `verify.sh` en TV Box -> `PASS 90 / WARN 0 / FAIL 0`.
- Túnel ML: apagado y caja en modo normal al cierre de prueba.
- Logs: activos y listos para auditoría diferida.

## 8) Notificaciones Telegram (ajuste de tono + ruido)
- Mensajes simplificados:
  - `iml-autopilot.sh`, `video-autopilot.sh`, `iml-backlog-drain.py`, `iml-drain-finalize.py`.
  - Se redujo texto técnico y se dejó formato corto: estado + acción esperada.
- Regla nueva de alerta temprana IML:
  - Si el pendiente crece sostenidamente en varias corridas (no baja), dispara alerta de atasco.
  - Variables nuevas: `IML_TREND_WINDOW_SAMPLES`, `IML_TREND_MIN_GROWTH`, `IML_TREND_MIN_UP_STEPS`, `IML_TREND_ALERT_TTL_SEC`.
- Resumen nocturno:
  - `night-run.sh` ahora incluye `Resumen corto` antes del detalle completo.
