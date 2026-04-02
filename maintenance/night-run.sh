#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# night-run.sh — Orquestador nocturno endurecido
#
# CAMBIOS CLAVE
#   - Cola secuencial con descansos explícitos entre tareas
#   - SMART pesado semanal (no diario)
#   - Lectura de estados persistentes: mounts, SMART, eMMC y DB
#   - Resumen nocturno por Telegram con emojis claros
#   - Si un estado queda en CRIT, se omiten tareas pesadas
# ═══════════════════════════════════════════════════════════════════════════

set -u
LOCK="/var/lock/night-run.lock"
LOG="/var/log/night-run.log"
HEALTH_DIR="/var/lib/nas-health"
VIDEO_SUMMARY_FILE="$HEALTH_DIR/video-optimize-summary.env"
PLAYBACK_AUDIT_SUMMARY_FILE="$HEALTH_DIR/playback-audit-summary.env"
NAS_ALERT_BIN="${NAS_ALERT_BIN:-/usr/local/bin/nas-alert.sh}"
EMMC_DF_TARGET="${EMMC_DF_TARGET:-/var/lib/immich}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/immich-app}"
IML_DRAIN_BIN="${IML_DRAIN_BIN:-/usr/local/bin/iml-backlog-drain.py}"
IML_AUTOPILOT_BIN="${IML_AUTOPILOT_BIN:-/usr/local/bin/iml-autopilot.sh}"
IML_API_URL="${IML_API_URL:-http://127.0.0.1:2283/api}"
IML_SECRETS_FILE="${IML_SECRETS_FILE:-/etc/nas-secrets}"
IML_TARGETS="${IML_TARGETS:-duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition}"
VIDEO_OPTIMIZE_MAX_MIN="${VIDEO_OPTIMIZE_MAX_MIN:-180}"
PLAYBACK_AUDIT_MAX_MIN="${PLAYBACK_AUDIT_MAX_MIN:-45}"
mkdir -p "$HEALTH_DIR" "$(dirname "$LOCK")"

MOUNT_ISSUE_SEEN=0
MOUNT_RECOVERED=0
LAST_BROKEN_FRIENDLY=""

exec 9>"$LOCK"
flock -n 9 || {
  "$NAS_ALERT_BIN" "⏭️ Ya había una rutina nocturna corriendo
No lancé otra para evitar trabajo duplicado."
  exit 1
}

log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG"; }
alert() { "$NAS_ALERT_BIN" "$1"; }
load_status_env() { [ -f "$1" ] && . "$1"; }
normalize_task_status() {
  case "$1" in
    OK|WARN|CRIT|FAIL|SKIPPED|WEEKLY_OK|WEEKLY_SKIPPED) echo "$1" ;;
    *) echo "" ;;
  esac
}

friendly_mount() {
  case "$1" in
    /mnt/storage-main) echo "disco principal de fotos" ;;
    /mnt/storage-backup) echo "disco de respaldo" ;;
    /mnt/merged) echo "biblioteca unificada" ;;
    *) echo "$1" ;;
  esac
}

friendly_mount_list() {
  local item result=""
  for item in "$@"; do
    [ -n "$item" ] || continue
    [ -n "$result" ] && result="$result, "
    result="${result}$(friendly_mount "$item")"
  done
  printf '%s\n' "$result"
}

task_label() {
  case "$1" in
    "Video optimize") echo "la optimización de videos" ;;
    "Playback audit") echo "la auditoría de reproducción de videos" ;;
    "SMART semanal") echo "la revisión profunda de los discos" ;;
    "Temp clean semanal") echo "la limpieza semanal de temporales" ;;
    "Backup") echo "la copia de seguridad" ;;
    "Cache monitor") echo "la revisión del tamaño del cache" ;;
    "Cache clean") echo "la auditoría del cache" ;;
    *) echo "$1" ;;
  esac
}

pretty_status() {
  case "$1" in
    OK) echo "Bien" ;;
    WARN) echo "Revisar" ;;
    CRIT) echo "Problema serio" ;;
    FAIL) echo "Falló" ;;
    SKIPPED) echo "Omitido" ;;
    WEEKLY_OK) echo "Hecho" ;;
    WEEKLY_SKIPPED) echo "Hoy no tocaba" ;;
    *) echo "$1" ;;
  esac
}

add_summary_note() {
  local note="$1"
  [ -n "$note" ] || return 0
  if [ -n "${SUMMARY_NOTES:-}" ]; then
    SUMMARY_NOTES="${SUMMARY_NOTES}
- $note"
  else
    SUMMARY_NOTES="- $note"
  fi
}

build_summary_notes() {
  SUMMARY_NOTES=""
  local smart_hint=""
  smart_hint=$(printf '%s' "${RISKY_DISKS:-}" | awk -F';' '
    {
      for (i = 1; i <= NF; i++) {
        split($i, a, "|")
        if (a[1] != "") {
          if (out != "") out = out ", "
          out = out a[1]
        }
      }
    }
    END { print out }
  ')

  if [ "$MOUNT_RECOVERED" -eq 1 ] && [ "${GLOBAL_MOUNT_STATUS:-OK}" = "OK" ]; then
    add_summary_note "Hubo una pérdida temporal de acceso a ${LAST_BROKEN_FRIENDLY:-uno o más discos}, pero logré recuperarla y el NAS terminó estable."
  elif [ "${GLOBAL_MOUNT_STATUS:-OK}" = "CRIT" ]; then
    add_summary_note "Sigo viendo un problema con ${LAST_BROKEN_FRIENDLY:-uno o más discos}. Por eso pausé tareas pesadas para proteger tus datos."
  fi

  case "${GLOBAL_SMART_STATUS:-OK}" in
    WARN)
      if [ -n "$smart_hint" ]; then
        add_summary_note "Señal temprana en discos: $smart_hint. Conviene revisarlos pronto."
      else
        add_summary_note "Uno de los discos mostró una señal temprana de desgaste o temperatura alta. Conviene revisarlo pronto."
      fi
      ;;
    CRIT)
      if [ -n "$smart_hint" ]; then
        add_summary_note "Problema serio en discos: $smart_hint. Mantengo tareas pesadas en pausa hasta revisarlos."
      else
        add_summary_note "Uno de los discos mostró señales serias de salud. Mantengo las tareas pesadas en pausa hasta revisarlo."
      fi
      ;;
  esac

  case "${EMMC_STATUS:-OK}" in
    WARN)
      add_summary_note "La memoria interna va justa. Todavía puede seguir trabajando, pero conviene liberar espacio pronto."
      ;;
    CRIT)
      add_summary_note "La memoria interna del NAS está casi llena. Pausé tareas pesadas para no empeorar la situación."
      ;;
  esac

  case "${DB_STATUS:-OK}" in
    WARN)
      add_summary_note "La base de datos respondió, pero vi reinicios recientes. La seguiré vigilando."
      ;;
    CRIT)
      add_summary_note "La base de datos de Immich no estuvo disponible. Varias tareas quedaron en pausa para no forzar el sistema."
      ;;
  esac

  [ "$VIDEO_RES" = "FAIL" ] && add_summary_note "La optimización de videos no pudo terminar esta noche."
  [ "$PLAYBACK_AUDIT_RES" = "FAIL" ] && add_summary_note "La auditoría de playback falló y no pude autocorregir videos rotos."
  [ "$BACKUP_RES" = "FAIL" ] && add_summary_note "La copia de seguridad del día no pudo completarse."
  [ "$CACHE_MONITOR_RES" = "FAIL" ] && add_summary_note "No pude revisar el tamaño del cache de videos."
  [ "$CACHE_CLEAN_RES" = "FAIL" ] && add_summary_note "No pude auditar el cache de videos."
  [ "$TEMP_CLEAN_RES" = "FAIL" ] && add_summary_note "No pude completar la limpieza semanal de temporales."
  if [ "$ML_RES" = "FAIL" ]; then
    if [ "${ML_PENDING_COUNT:-0}" -gt 0 ]; then
      add_summary_note "La IA por disponibilidad (24/7) no pudo avanzar bien en este ciclo y quedaron ${ML_PENDING_COUNT} pendientes de IML. Se reintentará automáticamente."
    else
      add_summary_note "La IA por disponibilidad reportó un error transitorio, pero no quedaron pendientes de IML."
    fi
    [ -n "${ML_FAIL_REASON:-}" ] && add_summary_note "Detalle IA por disponibilidad: ${ML_FAIL_REASON}."
  elif [ "$ML_RES" = "SKIPPED" ] && [ "${ML_PENDING_COUNT:-0}" -gt 0 ]; then
    add_summary_note "La IA por disponibilidad quedó temporalmente en pausa por seguridad de carga; quedan ${ML_PENDING_COUNT} pendientes y se retomarán automáticamente."
  elif [ "$ML_RES" = "SKIPPED" ] && [ "${ML_PENDING_COUNT:-0}" -eq 0 ]; then
    add_summary_note "IA por disponibilidad: sin pendientes al cierre de esta corrida."
  fi
  [ "$DBDUMP_RES" = "FAIL" ] && add_summary_note "No pude guardar la copia lógica de la base de datos."

  if [ "$VIDEO_RES" = "OK" ] && [ -f "$VIDEO_SUMMARY_FILE" ]; then
    load_status_env "$VIDEO_SUMMARY_FILE"
    if [ "${VIDEO_TOTAL_COUNT:-0}" -eq 0 ]; then
      add_summary_note "No vi videos pendientes por revisar esta noche."
    else
      local parts=""
      [ "${VIDEO_DIRECT_COUNT:-0}" -gt 0 ] && parts="${parts}${VIDEO_DIRECT_COUNT} ya eran ligeros y se dejaron tal cual; "
      [ "${VIDEO_READY_COUNT:-0}" -gt 0 ] && parts="${parts}${VIDEO_READY_COUNT} ya estaban listos en cache; "
      [ "${VIDEO_OPTIMIZED_COUNT:-0}" -gt 0 ] && parts="${parts}${VIDEO_OPTIMIZED_COUNT} pesados quedaron listos para verse mañana; "
      [ "${VIDEO_PENDING_COUNT:-0}" -gt 0 ] && parts="${parts}${VIDEO_PENDING_COUNT} siguen pendientes para otra noche; "
      [ "${VIDEO_MANUAL_REVIEW_COUNT:-0}" -gt 0 ] && parts="${parts}${VIDEO_MANUAL_REVIEW_COUNT} necesitan revisión manual; "
      parts="${parts%%; }"
      [ -n "$parts" ] && add_summary_note "En videos: $parts."
    fi
  fi

  if [ "$PLAYBACK_AUDIT_RES" = "OK" ] && [ -f "$PLAYBACK_AUDIT_SUMMARY_FILE" ]; then
    load_status_env "$PLAYBACK_AUDIT_SUMMARY_FILE"
    local playback_scope_raw playback_scope
    playback_scope_raw="${PLAYBACK_AUDIT_SCOPE:-all}"
    if [ "$playback_scope_raw" = "new_only" ]; then
      playback_scope="videos nuevos"
    else
      playback_scope="catálogo completo"
    fi
    if [ "${PLAYBACK_AUDIT_TOTAL:-0}" -eq 0 ] && [ "$playback_scope_raw" = "new_only" ]; then
      add_summary_note "Auditoría playback: no hubo videos nuevos para revisar en esta corrida."
    else
      add_summary_note "Auditoría playback ($playback_scope): ${PLAYBACK_AUDIT_PLAYABLE:-0}/${PLAYBACK_AUDIT_TOTAL:-0} playables; en proceso ${PLAYBACK_AUDIT_PROCESSING:-0}; rotos detectados ${PLAYBACK_AUDIT_BROKEN:-0}; autocorregidos ${PLAYBACK_AUDIT_AUTOHEAL_CONVERTED:-0}."
    fi
  fi

  [ -n "$SUMMARY_NOTES" ] || add_summary_note "El NAS terminó estable y las tareas principales salieron como se esperaba."
  printf '%s\n' "$SUMMARY_NOTES"
}

db_username() {
  local env_file="/opt/immich-app/.env" user=""
  if [ -f "$env_file" ]; then
    user=$(awk -F= '$1=="DB_USERNAME"{sub(/^[^=]*=/,""); print $2; exit}' "$env_file")
  fi
  [ -n "$user" ] || user="immich"
  printf '%s\n' "$user"
}

write_mount_status() {
  local status="OK" broken="" friendly_broken
  for mp in /mnt/storage-main /mnt/storage-backup /mnt/merged; do
    if ! mountpoint -q "$mp"; then
      status="CRIT"
      broken="$broken $mp"
    fi
  done
  cat > "$HEALTH_DIR/mount-status.env" <<EOF
GLOBAL_MOUNT_STATUS=$status
BROKEN_MOUNTS="${broken# }"
MOUNT_LAST_RUN=$(date -Iseconds)
EOF

  if [ "$status" = "CRIT" ]; then
    friendly_broken="$(friendly_mount_list $broken)"
    LAST_BROKEN_FRIENDLY="${friendly_broken:-los discos configurados}"
    MOUNT_ISSUE_SEEN=1
  elif [ "$MOUNT_ISSUE_SEEN" -eq 1 ]; then
    MOUNT_RECOVERED=1
  fi
}

write_storage_status() {
  local pct free_mb status
  pct=$(df -P "$EMMC_DF_TARGET" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')
  free_mb=$(df -Pm "$EMMC_DF_TARGET" 2>/dev/null | awk 'NR==2{print $4+0}')
  status="OK"
  [ -z "$pct" ] && pct=0
  [ -z "$free_mb" ] && free_mb=0

  if [ "$pct" -ge 90 ] || [ "$free_mb" -lt 1500 ]; then
    status="CRIT"
  elif [ "$pct" -ge 80 ] || [ "$free_mb" -lt 3000 ]; then
    status="WARN"
  fi

  cat > "$HEALTH_DIR/storage-status.env" <<EOF
EMMC_STATUS=$status
EMMC_USED_PCT=$pct
EMMC_FREE_MB=$free_mb
EMMC_LAST_RUN=$(date -Iseconds)
EOF
}

write_db_status() {
  local status="OK" reason="healthy" db_user
  db_user=$(db_username)
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^immich_postgres$'; then
    if docker exec immich_postgres pg_isready -U "$db_user" >/dev/null 2>&1; then
      if docker inspect -f '{{.State.RestartCount}}' immich_postgres 2>/dev/null | awk '{exit !($1>0)}'; then
        status="WARN"
        reason="reinicios detectados"
      fi
    else
      status="CRIT"
      reason="pg_isready falló"
    fi
  else
    status="CRIT"
    reason="contenedor ausente"
  fi

  cat > "$HEALTH_DIR/db-status.env" <<EOF
DB_STATUS=$status
DB_LAST_RUN=$(date -Iseconds)
DB_REASON="$reason"
EOF
}

run_task() {
  local NAME="$1" CMD="$2" MAX_MIN="$3" LABEL rc
  LABEL="$(task_label "$NAME")"
  log "INICIO: $NAME"
  if timeout $((MAX_MIN * 60)) env NAS_ALERT_SUPPRESS=1 bash -c "$CMD"; then
    log "OK: $NAME"
    return 0
  else
    rc=$?
  fi

  if [ "$rc" -eq 124 ]; then
    log "TIMEOUT: $LABEL"
  else
    log "ERROR: $LABEL"
  fi
  log "FAIL: $NAME rc=$rc"
  return "$rc"
}

should_skip_heavy() {
  load_status_env "$HEALTH_DIR/mount-status.env"
  load_status_env "$HEALTH_DIR/smart-status.env"
  load_status_env "$HEALTH_DIR/storage-status.env"
  load_status_env "$HEALTH_DIR/db-status.env"
  [ "${GLOBAL_MOUNT_STATUS:-OK}" = "CRIT" ] && return 0
  [ "${GLOBAL_SMART_STATUS:-OK}" = "CRIT" ] && return 0
  [ "${EMMC_STATUS:-OK}" = "CRIT" ] && return 0
  [ "${DB_STATUS:-OK}" = "CRIT" ] && return 0
  return 1
}

start_night_ml() {
  local rc pending_before pending_after

  ML_FAIL_REASON=""

  pending_before="$(iml_pending_count)"
  ML_PENDING_COUNT="$pending_before"
  if [ "$pending_before" -le 0 ]; then
    log "SKIP: IA 24/7 por disponibilidad sin pendientes de IML"
    ML_FAIL_REASON="sin pendientes"
    return 2
  fi

  if should_skip_heavy; then
    log "SKIP: IML pausado por estado crítico del NAS"
    ML_FAIL_REASON="pausa por estado crítico del NAS"
    return 2
  fi

  if [ ! -x "$IML_AUTOPILOT_BIN" ]; then
    log "FAIL: Falta $IML_AUTOPILOT_BIN"
    ML_FAIL_REASON="falta script de autopiloto IML"
    return 1
  fi

  if timeout 15m "$IML_AUTOPILOT_BIN" >>"$LOG" 2>&1; then
    pending_after="$(iml_pending_count)"
    ML_PENDING_COUNT="$pending_after"
    if [ "$pending_after" -lt "$pending_before" ]; then
      log "OK: IML 24/7 avanzó en esta corrida ($pending_before -> $pending_after)"
    else
      log "OK: IML 24/7 ejecutó ciclo sin reducción visible ($pending_before -> $pending_after)"
    fi
    return 0
  else
    rc=$?
    ML_FAIL_REASON="iml-autopilot devolvió rc=$rc"
    pending_after="$(iml_pending_count)"
    ML_PENDING_COUNT="$pending_after"
    if [ "$pending_after" -eq 0 ]; then
      log "SKIP: iml-autopilot devolvió rc=$rc, pero no quedaron pendientes de IML"
      ML_FAIL_REASON="sin pendientes"
      return 2
    fi
  fi

  pending_after="$(iml_pending_count)"
  ML_PENDING_COUNT="$pending_after"
  log "FAIL: IML 24/7 no pudo avanzar en este ciclo"
  return 1
}

iml_pending_count() {
  local out
  if [ ! -x "$IML_DRAIN_BIN" ] || ! command -v python3 >/dev/null 2>&1; then
    echo 0
    return 0
  fi
  out=$(timeout 45s python3 "$IML_DRAIN_BIN" \
    --api-url "$IML_API_URL" \
    --secrets-file "$IML_SECRETS_FILE" \
    --targets "$IML_TARGETS" \
    --print-pending-only 2>/dev/null || echo 0)
  case "$out" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$out" ;;
  esac
}

alert "🌙 Empezó la rutina nocturna
Voy a revisar el NAS y, si todo está bien, haré mantenimiento y copias de seguridad."
write_mount_status
load_status_env "$HEALTH_DIR/mount-status.env"
[ "${GLOBAL_MOUNT_STATUS:-OK}" = "CRIT" ] && NAS_ALERT_SUPPRESS=1 /usr/local/bin/mount-guard.sh >/dev/null 2>&1 || true
write_mount_status
load_status_env "$HEALTH_DIR/mount-status.env"
write_storage_status
write_db_status
NAS_ALERT_SUPPRESS=1 /usr/local/bin/smart-check.sh daily >/dev/null 2>&1 || true
load_status_env "$HEALTH_DIR/smart-status.env"

VIDEO_RES="SKIPPED"
PLAYBACK_AUDIT_RES="SKIPPED"
BACKUP_RES="SKIPPED"
SMART_RES="OK"
DBDUMP_RES="SKIPPED"
CACHE_MONITOR_RES="SKIPPED"
CACHE_CLEAN_RES="SKIPPED"
TEMP_CLEAN_RES="WEEKLY_SKIPPED"
ML_RES="SKIPPED"
ML_PENDING_COUNT=0
ML_FAIL_REASON=""

if should_skip_heavy; then
  log "SKIP: Se pausaron tareas pesadas por estado crítico del NAS"
else
  VIDEO_OPTIMIZE_CMD="/usr/local/bin/video-optimize.sh"
  if [ -x /usr/local/bin/video-reprocess-nightly.sh ]; then
    VIDEO_OPTIMIZE_CMD="/usr/local/bin/video-reprocess-nightly.sh"
  fi
  run_task "Video optimize" "$VIDEO_OPTIMIZE_CMD" "$VIDEO_OPTIMIZE_MAX_MIN" && VIDEO_RES="OK" || VIDEO_RES="FAIL"
  sleep 180

  if [ -x /usr/local/bin/playback-audit-autoheal.sh ]; then
    run_task "Playback audit" "/usr/local/bin/playback-audit-autoheal.sh" "$PLAYBACK_AUDIT_MAX_MIN" && PLAYBACK_AUDIT_RES="OK" || PLAYBACK_AUDIT_RES="FAIL"
    if [ -f "$PLAYBACK_AUDIT_SUMMARY_FILE" ]; then
      load_status_env "$PLAYBACK_AUDIT_SUMMARY_FILE"
      PLAYBACK_AUDIT_STATUS_REAL="$(normalize_task_status "${PLAYBACK_AUDIT_STATUS:-}")"
      [ -n "$PLAYBACK_AUDIT_STATUS_REAL" ] && PLAYBACK_AUDIT_RES="$PLAYBACK_AUDIT_STATUS_REAL"
    fi
    sleep 60
  fi

  DOW=$(date +%u)
  if [ "$DOW" -eq 7 ]; then
    run_task "SMART semanal" "/usr/local/bin/smart-check.sh weekly" 20 && SMART_RES="WEEKLY_OK" || SMART_RES="FAIL"
    sleep 120
  else
    SMART_RES="WEEKLY_SKIPPED"
  fi

  run_task "Backup" "nice -n 15 ionice -c2 -n7 /usr/local/bin/backup.sh" 180 && BACKUP_RES="OK" || BACKUP_RES="FAIL"
  sleep 120
fi

write_mount_status
load_status_env "$HEALTH_DIR/mount-status.env"
write_storage_status
load_status_env "$HEALTH_DIR/storage-status.env"

if [ "${GLOBAL_MOUNT_STATUS:-OK}" != "CRIT" ] && [ "${EMMC_STATUS:-OK}" != "CRIT" ]; then
  if [ -x /usr/local/bin/cache-monitor.sh ]; then
    run_task "Cache monitor" "/usr/local/bin/cache-monitor.sh" 5 && CACHE_MONITOR_RES="OK" || CACHE_MONITOR_RES="FAIL"
  fi
  if [ -x /usr/local/bin/cache-clean.sh ]; then
    run_task "Cache clean" "/usr/local/bin/cache-clean.sh" 10 && CACHE_CLEAN_RES="OK" || CACHE_CLEAN_RES="FAIL"
  fi
fi

DOW_WEEKLY=$(date +%u)
if [ "$DOW_WEEKLY" -eq 7 ]; then
  if [ -x /usr/local/bin/temp-clean.sh ]; then
    run_task "Temp clean semanal" "/usr/local/bin/temp-clean.sh --apply" 20 && TEMP_CLEAN_RES="WEEKLY_OK" || TEMP_CLEAN_RES="FAIL"
  else
    TEMP_CLEAN_RES="FAIL"
  fi
else
  TEMP_CLEAN_RES="WEEKLY_SKIPPED"
fi

write_mount_status
write_storage_status
write_db_status
load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"

start_night_ml
ML_RC=$?
case "$ML_RC" in
  0)
    ML_RES="OK"
    ;;
  2)
    ML_RES="SKIPPED"
    ;;
  *)
    ML_RES="FAIL"
    ;;
esac

load_status_env "$HEALTH_DIR/db-status.env"
if [ "${DB_STATUS:-OK}" != "CRIT" ] && [ "${GLOBAL_MOUNT_STATUS:-OK}" != "CRIT" ]; then
  DB_DEST="/mnt/storage-backup/snapshots/immich-db"
  DB_DATE=$(date +%F)
  DB_FILE="$DB_DEST/immich-db-$DB_DATE.sql.gz"
  DB_TMP="$DB_FILE.tmp"
  DB_USER=$(db_username)
  mkdir -p "$DB_DEST"
if timeout 20m bash -lc "set -o pipefail; \"$DOCKER_BIN\" exec immich_postgres pg_dumpall --clean --if-exists --username='$DB_USER' | gzip > '$DB_TMP'"; then
    mv -f "$DB_TMP" "$DB_FILE"
    find "$DB_DEST" -name '*.sql.gz' -mtime +7 -delete
    DBDUMP_RES="OK"
  else
    rm -f "$DB_TMP"
    DBDUMP_RES="FAIL"
  fi
else
  DBDUMP_RES="SKIPPED"
fi

load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/smart-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"

SUMMARY_NOTES="$(build_summary_notes)"

alert "🌙 Resumen de la noche
🗂️ Discos montados: $(pretty_status "${GLOBAL_MOUNT_STATUS:-OK}")
🩺 Salud de los discos: $(pretty_status "${GLOBAL_SMART_STATUS:-OK}")
💽 Memoria interna: $(pretty_status "${EMMC_STATUS:-OK}")
🐘 Base de datos de Immich: $(pretty_status "${DB_STATUS:-OK}")
🎬 Optimización de videos: $(pretty_status "${VIDEO_RES}")
🎥 Auditoría playback: $(pretty_status "${PLAYBACK_AUDIT_RES}")
💾 Copia de seguridad: $(pretty_status "${BACKUP_RES}")
📦 Revisión del cache: $(pretty_status "${CACHE_MONITOR_RES}")
🧹 Auditoría del cache: $(pretty_status "${CACHE_CLEAN_RES}")
🧽 Temporales semanales: $(pretty_status "${TEMP_CLEAN_RES}")
🧠 IA 24/7 por disponibilidad: $(pretty_status "${ML_RES}") (pendientes: ${ML_PENDING_COUNT})
🔬 Revisión profunda de discos: $(pretty_status "${SMART_RES}")
🗄️ Copia de la base de datos: $(pretty_status "${DBDUMP_RES}")
📝 Lo más importante:
${SUMMARY_NOTES}"
exit 0
