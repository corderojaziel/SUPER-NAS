# Flujo nocturno de copia de la base de perfumes

La app Windows envía el snapshot directamente a una carpeta `perfume-db/incoming` en un disco externo montado. El receptor no acepta rutas que no sean el montaje real de `/mnt/storage-main` o `/mnt/storage-backup`, rechaza carpetas anidadas con symlinks para evitar desvíos al almacenamiento interno y no publica el manifiesto `perfume-app.ready.json` hasta validar tamaño, SHA-256 e `integrity_check` de SQLite.

El receptor intenta el disco principal (`/mnt/storage-main`) y, ante ausencia, falta de espacio, falta de escritura o error de transferencia/validación, ofrece el disco secundario (`/mnt/storage-backup`). Si ninguno funciona, devuelve error y conserva la copia anterior.

`maintenance/perfume-db-backup.sh`, invocado por `night-run.sh`, procesa solo un manifiesto explícito en una de esas rutas. Revalida el origen, rechaza destinos estables con symlinks, escribe un temporal en el disco secundario y valida de nuevo. Reemplaza la copia estable con `mv` atómico, conserva el backup previo y manifiesto para rollback, y elimina el temporal recibido solo tras completar el commit.

## Instalación y verificación

`install.sh` instala ambos scripts bajo `/usr/local/bin`; `verify.sh` comprueba que existan y sean ejecutables. No se ha ejecutado el instalador ni el ciclo nocturno como parte de estas pruebas. El despliegue debe hacerse por el procedimiento autorizado del NAS y la primera copia real debe verificarse por separado.

`maintenance/test-perfume-db-backup.sh` ejecuta escenarios en directorios temporales: disco principal disponible, fallback al secundario, ambos discos ausentes, falta de espacio, hash inválido, rollback después de fallar la publicación del manifiesto, y rechazo de symlinks que redirijan la entrada o el destino estable. No accede a `/mnt/storage-main` ni `/mnt/storage-backup` reales.
