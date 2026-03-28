# MENÚ OPERATIVO DESDE PC

Script:
- `powershell/nas-ops-menu.ps1`

Config:
- `powershell/nas-ops.config.ps1`

## Uso
```powershell
powershell -ExecutionPolicy Bypass -File .\powershell\nas-ops-menu.ps1
```

## Qué cubre
- Estado general del NAS.
- Estado de colas Immich.
- Drenado IML por grupos:
  - completo
  - OCR
  - duplicados
  - sidecar
  - metadata extraction
  - library
  - smart search
  - face detection
  - facial recognition
- Monitoreo IML hasta terminar + cierre de túnel y normalización (`iml-drain-finalize.py`).
- Ejecución manual de:
  - `video-autopilot.sh`
  - `playback-audit-autoheal.sh`
- Backup/restore de estado:
  - `state-backup.sh`
  - `state-restore.sh`
- Túnel ML desde PC para usar GPU local:
  - inicia/detiene túnel `ssh -R`.
  - al iniciar, puede levantar automáticamente el contenedor ML local (configurable).
  - al detener, limpia PID + procesos `ssh` huérfanos en PC, corta residuos remotos (`13003/13031` + `ml_tunnel_proxy`) y apaga el contenedor ML local para que la GPU descanse.
- Descanso local forzado:
  - opción `21` del menú.
  - apaga túneles, contenedores ML locales y procesos de cómputo (GPU/CPU) que coincidan con patrones configurados en `nas-ops.config.ps1`.

## Nota importante
- El flujo normal de video se mantiene igual.
- El modo por carga (`VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=1`) y el autopiloto (`VIDEO_AUTOPILOT_ENABLED=1`) son opcionales.
