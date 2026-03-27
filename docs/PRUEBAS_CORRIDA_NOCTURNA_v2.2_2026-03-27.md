# PRUEBAS CORRIDA NOCTURNA - VIDEO PLAYBACK

Versión: `v2.2`  
Fecha: `2026-03-27`  
Objetivo: validar corrida nocturna con casos nuevos de video y estados de auto-reparación.

## 1) Prueba real en Armbian (laboratorio)

Servidor: `root@192.168.100.89`  
Script ejecutado: `/usr/local/bin/playback-audit-autoheal.sh`  
Resultado real capturado en `/var/lib/nas-health/playback-audit-summary.env`:

- `PLAYBACK_AUDIT_STATUS=OK`
- `PLAYBACK_AUDIT_TOTAL=3045`
- `PLAYBACK_AUDIT_PLAYABLE=2891`
- `PLAYBACK_AUDIT_PROCESSING=154`
- `PLAYBACK_AUDIT_BROKEN=0`
- `PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=0`
- `PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=0`
- `PLAYBACK_AUDIT_AUTOHEAL_FAILED=0`

Conclusión real: en esta corrida no hubo videos rotos, por eso no se disparó auto-reparación.

## 2) Matriz de estados nuevos (prueba controlada del módulo autoheal)

Script de prueba: `maintenance/test-playback-audit-autoheal.sh`

| Caso | Status | Total | Playable | Processing | Broken | Candidates | Converted | Failed | Alerts | Primer mensaje |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| no_creds | SKIPPED | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | ⚠️ Auditoría de playback sin credenciales de Immich |
| all_ok | OK | 3 | 2 | 1 | 0 | 0 | 0 | 0 | 1 | ✅ Auditoría playback completada |
| broken_no_candidates | WARN | 5 | 1 | 0 | 4 | 0 | 0 | 0 | 1 | ⚠️ Auditoría playback: encontré rotos sin autocorrección local |
| broken_with_success | OK | 3 | 1 | 0 | 2 | 2 | 2 | 0 | 1 | 🎬 Auditoría playback + autocorrección |
| broken_with_failed | WARN | 3 | 1 | 0 | 2 | 2 | 1 | 1 | 1 | 🎬 Auditoría playback + autocorrección |
| plan_fail | FAIL | 3 | 1 | 0 | 2 | 0 | 0 | 0 | 1 | ⚠️ Detecté videos rotos pero falló el plan de autocorrección |
| broken_run_rc_fail | FAIL | 3 | 1 | 0 | 2 | 2 | 0 | 0 | 1 | 🎬 Auditoría playback + autocorrección |

Estados validados: `OK`, `WARN`, `FAIL`, `SKIPPED`, además de clases `playable`, `placeholder_processing`, `placeholder_missing`, `placeholder_damaged`, `placeholder_error`, `not_found`.

## 3) Integración en corrida nocturna (night-run)

Script de prueba: `maintenance/test-night-run-playback-states.sh`  
Validación: que `night-run` refleje el estado de auditoría en su resumen nocturno.

| Escenario | Playback Fake | Alerts | Línea en resumen nocturno |
|---|---|---:|---|
| night_playback_ok_none | ok_none | 2 | 🎥 Auditoría playback: Bien |
| night_playback_ok_heal | ok_heal | 2 | 🎥 Auditoría playback: Bien |
| night_playback_fail | fail | 2 | 🎥 Auditoría playback: Falló |

Conclusión integración: la corrida nocturna sí reporta correctamente el estado de auditoría de playback en el resumen final.

## 4) Versionado aplicado

- Se versionaron pruebas y reporte como `v2.2`.
- No se detectó un bug funcional nuevo en esta tanda; la lógica de estados y notificaciones quedó consistente.
