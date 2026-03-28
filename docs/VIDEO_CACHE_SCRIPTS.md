# Scripts de Cache de Video (qué hace cada uno)

## 1) Auditoría de playback por todos los IDs
- Script: `scripts/audit_video_playback.py`
- Uso: valida respuesta HTTP real de `/api/assets/<id>/video/playback` para **todos** los videos en DB.
- Salida: CSV + JSON en `/var/lib/nas-health/`.
- Comando:
```bash
python3 /usr/local/bin/audit_video_playback.py \
  --email "TU_EMAIL" \
  --password "TU_PASSWORD"
```

## 2) Generar insumos (light/heavy/broken)
- Script: `scripts/video-reprocess-manager.py`
- Uso: clasifica todos los videos por regla de MB/min y estado de cache.
- Salida:
  - `light-latest.csv` (aptos para TV Box)
  - `heavy-latest.csv` (recomendado reproceso en PC/GPU)
  - `broken-latest.csv`
- Comando:
```bash
python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir /var/lib/nas-health/reprocess
```

## 3) Reproceso nocturno (TV Box)
- Script: `maintenance/video-reprocess-nightly.sh` (`/usr/local/bin/video-reprocess-nightly.sh`)
- Uso: corre en noche, procesa ligeros, mantiene cola manual para casos que fallen.
- Integración: lo invoca `night-run.sh`.

## 4) Recuperación total de cache (desastre)
- Script: `maintenance/rebuild-video-cache.sh`
- Uso: reconstruir cache tras pérdida total/parcial.
- Modos:
  - `prepare`: solo insumos.
  - `light-only`: insumos + todos los ligeros en TV Box.
  - `tvbox-all`: además intenta pesados en TV Box (más lento).
- Comandos:
```bash
/usr/local/bin/rebuild-video-cache.sh prepare
/usr/local/bin/rebuild-video-cache.sh light-only
/usr/local/bin/rebuild-video-cache.sh tvbox-all
```

## 5) Reproceso pesado manual con PC/GPU
- Script: `powershell/reprocess_heavy_from_server.ps1`
- Uso: descarga pesados desde server, convierte en PC, regresa cache al NAS.
- Comandos:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\jazie\SUPERNAS\powershell\reprocess_heavy_from_server.ps1 -PlanOnly
powershell -ExecutionPolicy Bypass -File C:\Users\jazie\SUPERNAS\powershell\reprocess_heavy_from_server.ps1 -NoPlan -Limit 50
```

## 6) Modo por carga CPU/RAM (opcional, sin romper flujo base)
- Script base: `maintenance/video-reprocess-nightly.sh`
- Bandera de activación: `VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=1`
- Qué hace:
  - procesa por lotes pequeños,
  - se pausa si CPU/RAM superan umbral,
  - reanuda cuando baja carga.
- Default: `0` (legacy, mismo comportamiento actual).

## 7) Autopiloto continuo opcional
- Script: `maintenance/video-autopilot.sh`
- Uso recomendado: cron cada 10 min.
- Bandera: `VIDEO_AUTOPILOT_ENABLED=1`
- Nota: solo activa slices cortos de reproceso; no reemplaza el flujo nocturno.

## 8) Menú operativo desde PC
- Script: `powershell/nas-ops-menu.ps1`
- Config: `powershell/nas-ops.config.ps1`
- Permite:
  - drenar IML por cola,
  - lanzar playback audit,
  - correr autopiloto,
  - backup/restore de estado,
  - abrir/cerrar túnel ML PC→NAS.

## 9) Backup/restore rápido de estado
- Backup: `maintenance/state-backup.sh`
- Restore: `maintenance/state-restore.sh`
- Incluye: DB (dump lógico), política, secretos, compose/.env, inventario.
- Cache completa: opcional (`INCLUDE_CACHE=1` / `--with-cache`).

## Recomendación operativa
1. Noche diaria: dejar `night-run.sh` (ya integrado con `video-reprocess-nightly.sh`).
2. Si hay backlog grande:
   1. `plan`
   2. `light-only` en TV Box
   3. `heavy` con PowerShell en PC/GPU.
3. Si se pierde cache completo: `rebuild-video-cache.sh light-only` + pesado en PC.
