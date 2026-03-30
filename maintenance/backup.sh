#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# backup.sh — Backup incremental con snapshots
# Guía Maestra NAS V58
#
# ENDURECIMIENTO
#   Este script ahora obedece el estado de salud del sistema:
#   SMART, mounts, eMMC y DB. Si algún estado está en CRIT, el backup se
#   omite para no empeorar la situación. Además se ejecuta con nice+ionice.
#   Política de datos productivos:
#   - no usa --delete sobre fotos/videos de origen
#   - depuración automática solo de snapshots diarios (retención en días)
#   - NO depura automáticamente system-state ni immich-db
# ═══════════════════════════════════════════════════════════════════════════

SOURCE="/mnt/storage-main/photos/"
DEST="/mnt/storage-backup/snapshots"
HEALTH_DIR="/var/lib/nas-health"
TODAY=$(date +%F)
RETENTION_DAYS="$(cat /etc/nas-retention 2>/dev/null || echo 7)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
MANUAL_RETENTION_BIN="${MANUAL_RETENTION_BIN:-/usr/local/bin/manual-retention.sh}"
POLICY_FILE="/etc/default/nas-video-policy"
FAILOVER_ROOT="${FAILOVER_ROOT:-/mnt/storage-backup/failover-main}"
FAILOVER_SYNC_BIN="${FAILOVER_SYNC_BIN:-/usr/local/bin/failover-sync.sh}"
FAILOVER_SYNC_ENABLED="${FAILOVER_SYNC_ENABLED:-1}"
BACKUP_PHOTOS_MODE="${BACKUP_PHOTOS_MODE:-restic}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-0}"
BACKUP_RESTIC_REPO="${BACKUP_RESTIC_REPO:-/mnt/storage-backup/restic/photos}"
BACKUP_RESTIC_PASSWORD_FILE="${BACKUP_RESTIC_PASSWORD_FILE:-/etc/nas-restic-password}"
BACKUP_RESTIC_KEEP_DAILY="${BACKUP_RESTIC_KEEP_DAILY:-7}"
BACKUP_RESTIC_KEEP_WEEKLY="${BACKUP_RESTIC_KEEP_WEEKLY:-4}"
BACKUP_RESTIC_KEEP_MONTHLY="${BACKUP_RESTIC_KEEP_MONTHLY:-3}"

alert() { /usr/local/bin/nas-alert.sh "$1"; }
load_status_env() { [ -f "$1" ] && . "$1"; }
is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

restic_env() {
  export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPO"
  export RESTIC_PASSWORD_FILE="$BACKUP_RESTIC_PASSWORD_FILE"
}

restic_init_if_needed() {
  command -v restic >/dev/null 2>&1 || return 1
  [ -s "$BACKUP_RESTIC_PASSWORD_FILE" ] || return 1
  mkdir -p "$BACKUP_RESTIC_REPO"
  restic_env
  if restic cat config >/dev/null 2>&1; then
    return 0
  fi
  if is_true "$BACKUP_DRY_RUN"; then
    return 2
  fi
  restic init >/tmp/restic-init.log 2>&1
}

run_backup_rsync_snapshot() {
  mkdir -p "$DEST/$TODAY"
  RSYNC_OPTS=(-a)
  is_true "$BACKUP_DRY_RUN" && RSYNC_OPTS+=(-n)
  LINK_DEST="$(latest_snapshot_ref)"
  [ -n "$LINK_DEST" ] && [ -d "$LINK_DEST" ] && RSYNC_OPTS+=("--link-dest=$LINK_DEST")

  if nice -n 15 ionice -c2 -n7 rsync "${RSYNC_OPTS[@]}" "$SOURCE" "$DEST/$TODAY/"; then
    if is_true "$BACKUP_DRY_RUN"; then
      alert "🧪 Copia de seguridad (dry-run) completada
Motor: rsync_snapshot
Acción del NAS: validé el flujo sin escribir cambios."
      return 0
    fi
    alert "✅ Copia de seguridad terminada
El respaldo del día $TODAY se completó correctamente."
  else
    code=$?
    if [ "$code" -eq 24 ]; then
      alert "✅ Copia de seguridad terminada
El respaldo del día $TODAY se completó, aunque hubo archivos cambiando mientras copiaba.
Esto suele pasar si alguien estaba usando Immich al mismo tiempo."
      return 0
    fi
    alert "❌ No se pudo completar la copia de seguridad
Acción del NAS: el respaldo del día $TODAY terminó con error.
Qué hacer ahora (TV Box):
1) tail -n 120 /var/log/night-run.log   # ver causa
2) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh   # relanzar backup"
    return "$code"
  fi

  SNAPSHOT_COUNT="$(
    find "$DEST" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    | wc -l
  )"
  if [ "$RETENTION_DAYS" -gt 0 ] && [ -x "$MANUAL_RETENTION_BIN" ]; then
    if "$MANUAL_RETENTION_BIN" --apply --target snapshots --snapshots-keep "$RETENTION_DAYS" >/tmp/backup-retention.log 2>&1; then
      :
    else
      alert "⚠️ Falló la depuración automática de snapshots
La copia sí terminó, pero no pude aplicar retención de $RETENTION_DAYS días.
Qué correr (TV Box):
1) /usr/local/bin/manual-retention.sh --plan --target snapshots --snapshots-keep $RETENTION_DAYS
2) /usr/local/bin/manual-retention.sh --apply --target snapshots --snapshots-keep $RETENTION_DAYS"
    fi
  fi

  if [ "$SNAPSHOT_COUNT" -gt "$RETENTION_DAYS" ]; then
    alert "🟡 Backups acumulados: $SNAPSHOT_COUNT snapshots
Acción del NAS: revisa si deseas ajustar retención en /etc/nas-retention (actual $RETENTION_DAYS)."
  fi
  return 0
}

run_backup_restic() {
  restic_init_if_needed
  init_rc=$?
  if [ "$init_rc" -eq 2 ]; then
    alert "🧪 Backup restic (dry-run) no ejecutado
No existe repositorio inicializado en $BACKUP_RESTIC_REPO.
Para validar dry-run sin escribir, primero ejecuta una corrida real inicial."
    return 0
  fi
  if [ "$init_rc" -ne 0 ]; then
    alert "❌ No pude iniciar backup deduplicado (restic)
Acción del NAS: faltan prerrequisitos de respaldo.
Qué revisar (TV Box):
1) command -v restic
2) ls -lah $BACKUP_RESTIC_PASSWORD_FILE
3) /usr/local/bin/verify.sh"
    return 1
  fi

  RESTIC_ARGS=(backup "$SOURCE" --tag supernas-photos)
  is_true "$BACKUP_DRY_RUN" && RESTIC_ARGS+=(--dry-run)

  if ! nice -n 15 ionice -c2 -n7 restic "${RESTIC_ARGS[@]}" >/tmp/restic-backup-last.log 2>&1; then
    alert "❌ No se pudo completar la copia de seguridad
Motor: restic
Acción del NAS: el respaldo terminó con error.
Qué hacer ahora (TV Box):
1) tail -n 120 /tmp/restic-backup-last.log
2) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh"
    return 1
  fi

  if is_true "$BACKUP_DRY_RUN"; then
    alert "🧪 Copia de seguridad (dry-run) completada
Motor: restic
Acción del NAS: validé el flujo sin escribir cambios."
    return 0
  fi

  SNAP_ID="$(restic snapshots --latest 1 --json 2>/dev/null | python3 -c "import json,sys; \
data=json.load(sys.stdin) if not sys.stdin.closed else []; \
print((data[-1] if data else {}).get('short_id',''))" 2>/dev/null || true)"
  [ -n "$SNAP_ID" ] || SNAP_ID="desconocido"

  FORGET_ARGS=(forget --prune --tag supernas-photos)
  [ "${BACKUP_RESTIC_KEEP_DAILY:-0}" -gt 0 ] && FORGET_ARGS+=("--keep-daily" "$BACKUP_RESTIC_KEEP_DAILY")
  [ "${BACKUP_RESTIC_KEEP_WEEKLY:-0}" -gt 0 ] && FORGET_ARGS+=("--keep-weekly" "$BACKUP_RESTIC_KEEP_WEEKLY")
  [ "${BACKUP_RESTIC_KEEP_MONTHLY:-0}" -gt 0 ] && FORGET_ARGS+=("--keep-monthly" "$BACKUP_RESTIC_KEEP_MONTHLY")

  if [ "${#FORGET_ARGS[@]}" -gt 3 ]; then
    if ! restic "${FORGET_ARGS[@]}" >/tmp/restic-retention.log 2>&1; then
      alert "⚠️ Backup restic completado, pero falló la retención
Snapshot nuevo: $SNAP_ID
Qué correr (TV Box):
1) tail -n 120 /tmp/restic-retention.log
2) restic forget --prune --tag supernas-photos --keep-daily $BACKUP_RESTIC_KEEP_DAILY --keep-weekly $BACKUP_RESTIC_KEEP_WEEKLY --keep-monthly $BACKUP_RESTIC_KEEP_MONTHLY"
    fi
  fi

  alert "✅ Copia de seguridad terminada
Motor: restic (deduplicado)
Snapshot: $SNAP_ID"
  return 0
}
is_failover_active() {
  local src rel
  src="$(findmnt -n -o SOURCE /mnt/storage-main 2>/dev/null | tail -n1 || true)"
  [ "$src" = "$FAILOVER_ROOT" ] && return 0
  rel="$FAILOVER_ROOT"
  case "$FAILOVER_ROOT" in
    /mnt/storage-backup/*) rel="${FAILOVER_ROOT#/mnt/storage-backup}" ;;
  esac
  [ -n "$rel" ] && printf '%s' "$src" | grep -Fq "[$rel]" && return 0
  return 1
}
latest_snapshot_ref() {
  local latest=""
  if [ -d "$DEST" ]; then
    latest="$(
      find "$DEST" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      | grep -v "^$TODAY$" \
      | sort \
      | tail -1
    )"
  fi
  [ -n "$latest" ] && printf '%s\n' "$DEST/$latest" || true
}

load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/smart-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"
[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
BACKUP_PHOTOS_MODE="$(printf '%s' "$BACKUP_PHOTOS_MODE" | tr '[:upper:]' '[:lower:]')"

MOUNT_STATUS="${GLOBAL_MOUNT_STATUS:-OK}"
SMART_STATUS="${GLOBAL_SMART_STATUS:-OK}"
EMMC_STATUS="${EMMC_STATUS:-OK}"
DB_STATUS="${DB_STATUS:-OK}"

if [ "$MOUNT_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: no corrí backup para evitar un respaldo incompleto.
Qué hacer ahora (TV Box):
1) /usr/local/bin/verify.sh   # diagnóstico general (no monta discos)
2) lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT   # ver estado actual"
  exit 0
fi
if [ "$SMART_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: pausé backup para no forzar un disco con problema serio.
Qué hacer ahora (TV Box):
1) /usr/local/bin/smart-check.sh daily   # diagnóstico SMART
2) /usr/local/bin/verify.sh   # verificación general"
  exit 0
fi
if [ "$EMMC_STATUS" = "CRIT" ]; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: pausé backup para estabilizar la memoria interna.
Qué hacer ahora (TV Box):
1) df -h /var/lib/immich   # diagnóstico de espacio
2) /usr/local/bin/cache-monitor.sh   # diagnóstico de cache (NO relanza backup)
3) nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh   # relanzar manual cuando esté estable"
  exit 0
fi
if [ "$DB_STATUS" = "CRIT" ]; then
  alert "⚠️ La base de datos de Immich está con problemas
Haré solo lo seguro y evitaré lo que dependa del stack."
fi

if is_failover_active; then
  alert "⏭️ Copia de seguridad pospuesta
Acción del NAS: detecté modo failover activo sobre respaldo.
Para evitar copiar respaldo sobre sí mismo, hoy no corrí snapshot.
Qué hacer ahora (TV Box):
1) /usr/local/bin/storage-failover.sh status
2) /usr/local/bin/verify.sh"
  exit 0
fi

case "$BACKUP_PHOTOS_MODE" in
  restic)
    run_backup_restic || exit $?
    ;;
  rsync_snapshot|snapshot)
    run_backup_rsync_snapshot || exit $?
    ;;
  *)
    alert "⚠️ Política de backup desconocida
BACKUP_PHOTOS_MODE=$BACKUP_PHOTOS_MODE
Acción del NAS: por seguridad no corrí backup."
    exit 1
    ;;
esac

if is_true "$FAILOVER_SYNC_ENABLED" && [ -x "$FAILOVER_SYNC_BIN" ]; then
  if nice -n 15 ionice -c2 -n7 "$FAILOVER_SYNC_BIN" sync >/tmp/failover-sync-last.log 2>&1; then
    :
  else
    alert "⚠️ Backup listo, pero no pude actualizar el espejo de failover
El snapshot de hoy sí quedó guardado, pero faltó sincronizar el respaldo operativo.
Qué correr (TV Box):
1) tail -n 120 /tmp/failover-sync-last.log
2) /usr/local/bin/failover-sync.sh sync
3) /usr/local/bin/storage-failover.sh status"
  fi
fi

exit 0
