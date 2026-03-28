# PERF REVIEW (2026-03-28)

## Hallazgos
1. `night-run` mostró timeouts repetidos en `Video optimize` (1h) y un timeout en `cache-clean`.
2. El túnel ML remoto reportó inestabilidad (`broken pipe` / `connection reset`).
3. Colas IML con backlog alto real:
   - `duplicateDetection` ~17k+
   - `ocr` ~20k+
   - `sidecar` con miles en momentos puntuales
4. `immich-video-reprocess` no está como servicio systemd (se opera por cron/scripts).

## Riesgos técnicos
- Cuello de botella CPU/RAM en TV Box durante picos de usuarios.
- Saturación de ventana nocturna por colas masivas.
- Dependencia del túnel ML (si cae, el backlog crece aunque Immich siga “activo”).
- Riesgo de colisión entre tareas pesadas simultáneas si no se segmentan por lotes.

## Mejoras aplicadas en esta iteración
1. Reproceso de video con modo dinámico opcional por carga (`VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=1`):
   - pausa/reanuda automática según CPU/RAM.
   - procesamiento por lotes.
2. Mantener compatibilidad:
   - modo legacy sigue por defecto (`VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=0`).
3. Autopiloto opcional (`video-autopilot.sh`) para drenar sin esperar exclusivamente la noche.
4. Drenador IML multi-cola (`iml-backlog-drain.py`):
   - OCR, duplicados, sidecar, metadata, library, smart search, caras.
5. Backup/restore rápido de estado:
   - `state-backup.sh` / `state-restore.sh`.
6. Menú de operación desde PC:
   - `nas-ops-menu.ps1` + `nas-ops.config.ps1`.

## Recomendación operativa
1. Flujo normal:
   - mantener modo legacy.
2. Evento masivo:
   - activar temporalmente:
     - `VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=1`
     - `VIDEO_AUTOPILOT_ENABLED=1`
3. IA masiva:
   - mantener túnel ML estable y monitorear cola con `nas-ops-menu.ps1`.
4. Antes de cambios sensibles:
   - correr `state-backup.sh`.
