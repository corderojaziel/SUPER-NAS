# RUNBOOK DE FALLOS (TV BOX + PC)

Versión: `v2.1`  
Fecha: `2026-03-27`  
PDF versionado: `docs/RUNBOOK_FALLOS_v2.1_2026-03-27.pdf`

Este documento define qué hacer cuando llegue una alerta de Telegram.

Objetivo:
- saber **dónde correr** (TV Box o PC),
- saber si el **insumo** es automático o manual,
- y ejecutar rápido el comando correcto.

## Reglas rápidas
- Si la alerta menciona **disco / temperatura / montajes / backup / cache monitor**: correr en **TV Box**.
- Si la alerta menciona **videos pesados** o backlog grande de cache: correr en **PC** con GPU.
- Insumos de video (`light-latest.csv`, `heavy-latest.csv`, `broken-latest.csv`) se generan automático en:
  - `/var/lib/nas-health/reprocess`

## Matriz de acción
### 1) Reproceso nocturno no inicia
- Telegram esperado: `❌ Reproceso nocturno de videos no pudo iniciar`
- Dónde: TV Box
- Insumo: no aplica
- Correr:
```bash
/usr/local/bin/verify.sh
ls -lah /usr/local/bin/video-reprocess-manager.py
command -v python3
```

### 2) Falló planeación nocturna de video
- Telegram esperado: `❌ Falló la planeación de reproceso de video`
- Dónde: TV Box
- Insumo: automático
- Correr:
```bash
python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir /var/lib/nas-health/reprocess
```

### 3) Reproceso nocturno terminó con errores
- Telegram esperado: `⚠️ Reproceso nocturno de videos terminó con errores`
- Dónde:
  - TV Box para ligeros
  - PC para pesados
- Insumo:
  - TV Box: automático
  - PC: automático (se descarga desde server)
- Correr:
```bash
# TV Box (ligeros)
python3 /usr/local/bin/video-reprocess-manager.py run --class light --output-dir /var/lib/nas-health/reprocess --limit 0
```
```powershell
# PC (pesados)
powershell -ExecutionPolicy Bypass -File C:\Users\jazie\SUPERNAS\powershell\reprocess_heavy_from_server.ps1 -NoPlan -Limit 50
```

### 4) Placeholder excesivo / videos no reproducen
- Dónde: TV Box para auditoría, luego TV Box o PC según clase.
- Insumo:
  - auditoría: no aplica
  - plan de video: automático
- Correr:
```bash
python3 /usr/local/bin/audit_video_playback.py --email "TU_EMAIL" --password "TU_PASSWORD"
python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir /var/lib/nas-health/reprocess
```

### 4.1) Auditoría playback automática (nuevo)
- Script: `/usr/local/bin/playback-audit-autoheal.sh`
- Qué hace:
  - audita por HTTP todos los videos (`playable/processing/error`)
  - notifica resultado por Telegram
  - si detecta rotos, corre autocorrección automática en TV Box para candidatos ligeros
- Insumo:
  - automático
  - requiere `IMMICH_API_KEY` o `IMMICH_ADMIN_EMAIL` + `IMMICH_ADMIN_PASSWORD` en `/etc/nas-secrets`

### 5) Alerta SMART WARN / CRIT
- Telegram esperado: `⚠️ Conviene revisar ...` o `🚨 ... necesita atención`
- La alerta debe indicar: **disco exacto `/dev/...` + modelo/serial**.
- Dónde: TV Box
- Insumo: no aplica
- Correr:
```bash
smartctl -a /dev/sdX
/usr/local/bin/smart-check.sh daily
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
/usr/local/bin/verify.sh
```

### 6) Alerta de montaje caído
- Telegram esperado: `🔴 Detecté un problema con ...`
- La alerta debe indicar: punto de montaje y disco esperado.
- Dónde: TV Box
- Insumo: no aplica
- Correr:
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
mount | grep -E '/mnt/storage-main|/mnt/storage-backup|/mnt/merged'
/usr/local/bin/verify.sh
```

### 7) Alerta cache crítico
- Telegram esperado: `🔴 El cache de videos está muy grande`
- Dónde:
  - TV Box para limpieza/plan
  - PC para pesados
- Insumo:
  - TV Box: automático
  - PC: automático (pull desde server)
- Correr:
```bash
/usr/local/bin/cache-clean.sh
/usr/local/bin/rebuild-video-cache.sh prepare
```
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\jazie\SUPERNAS\powershell\reprocess_heavy_from_server.ps1 -NoPlan -Limit 50
```

### 8) Temperatura alta / crítica
- Telegram esperado: `🌡️ ...` o `🔴 Temperatura crítica ...`
- Dónde: TV Box
- Insumo: no aplica
- Correr:
```bash
/usr/local/bin/verify.sh
/usr/local/bin/immich-ml-window.sh day-off
cat /sys/class/thermal/thermal_zone*/temp
```

### 9) Backup falló o fue pospuesto
- Telegram esperado: `⏭️ Copia de seguridad pospuesta` o `❌ No se pudo completar...`
- Dónde: TV Box
- Insumo: no aplica
- Correr:
```bash
tail -n 120 /var/log/night-run.log
nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh
/usr/local/bin/verify.sh
```

## Recuperación total de cache (desastre)
- Script: `/usr/local/bin/rebuild-video-cache.sh`
- Modos:
```bash
/usr/local/bin/rebuild-video-cache.sh prepare
/usr/local/bin/rebuild-video-cache.sh light-only
/usr/local/bin/rebuild-video-cache.sh tvbox-all
```

Recomendación:
1. `prepare`
2. `light-only` (TV Box)
3. pesados por lotes en PC (`reprocess_heavy_from_server.ps1`)

## Validación final
```bash
/usr/local/bin/verify.sh
python3 /usr/local/bin/audit_video_playback.py --email "TU_EMAIL" --password "TU_PASSWORD"
```

## Cómo generar nueva versión del PDF
```bash
python3 tools/build_runbook_pdf.py --input docs/RUNBOOK_FALLOS.md --output docs/RUNBOOK_FALLOS_v2.1_2026-03-27.pdf --title "RUNBOOK DE FALLOS v2.1 (2026-03-27)"
```
