#!/bin/bash
# verify.sh — Verificación post-instalación NAS S905X3 + hardening
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0
ok(){ echo -e "  ${GREEN}✓${NC}  $1"; PASS=$((PASS+1)); }
warn(){ echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$((WARN+1)); }
fail(){ echo -e "  ${RED}✗${NC}  ${BOLD}$1${NC}"; FAIL=$((FAIL+1)); }
section(){ echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

section "SISTEMA"
if grep -qi armbian /etc/os-release 2>/dev/null || grep -qi armbian /etc/armbian-release 2>/dev/null; then ok "Armbian detectado"; else warn "No se detectó Armbian"; fi
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then ok "BBR TCP activo"; else fail "BBR TCP no activo"; fi
if swapon --show 2>/dev/null | grep -q zram; then ok "ZRAM activo"; else warn "ZRAM no activo"; fi
TEMP_FILE=""; for zone in /sys/class/thermal/thermal_zone*/temp; do [ -f "$zone" ] && { TEMP_FILE="$zone"; break; }; done
if [ -n "$TEMP_FILE" ]; then TEMP_C=$(( $(cat "$TEMP_FILE") / 1000 )); [ "$TEMP_C" -lt 70 ] && ok "Temperatura CPU: ${TEMP_C}°C" || warn "Temperatura CPU: ${TEMP_C}°C"; else warn "No se encontró sensor térmico"; fi

section "DOCKER"
command -v docker >/dev/null 2>&1 && ok "Docker instalado" || fail "Docker no instalado"
docker compose version >/dev/null 2>&1 && ok "Docker Compose plugin disponible" || fail "docker compose no disponible"
for c in immich_server immich_postgres immich_redis; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)
  [ "$state" = "running" ] && ok "$c corriendo" || fail "$c no está corriendo"
done
ml_state=$(docker inspect -f '{{.State.Status}}' immich_machine_learning 2>/dev/null || true)
case "$ml_state" in
  running) ok "immich_machine_learning corriendo" ;;
  exited|created) ok "immich_machine_learning preparado y apagado por horario" ;;
  *) fail "immich_machine_learning no está disponible" ;;
esac
ss -tlnp 2>/dev/null | grep -q ':2283' && ok "Puerto 2283 escuchando" || fail "Puerto 2283 no escucha"

section "ALMACENAMIENTO"
for m in /mnt/storage-main /mnt/storage-backup /mnt/merged; do
  mountpoint -q "$m" && ok "Mount listo: $m" || fail "Mount no listo: $m"
done
for d in /mnt/storage-main/photos /mnt/storage-main/cache /mnt/storage-backup/snapshots /mnt/storage-backup/snapshots/immich-db /opt/immich-app /var/lib/immich/db /var/lib/immich/models /var/lib/immich/cache /var/lib/immich/thumbs /var/lib/immich/encoded-video /var/lib/immich/nginx-cache /var/lib/immich/static; do
  [ -d "$d" ] && ok "Directorio existe: $d" || fail "Directorio faltante: $d"
done
for marker in /mnt/merged/.immich /mnt/merged/library/.immich /mnt/merged/backups/.immich /var/lib/immich/thumbs/.immich /var/lib/immich/encoded-video/.immich /var/lib/immich/profile/.immich; do
  [ -f "$marker" ] && ok "Marcador de integridad presente: $marker" || fail "Marcador de integridad faltante: $marker"
done

section "IMMICH CONFIGURACIÓN"
if [ -f /opt/immich-app/.env ]; then
  ok ".env existe"
  perms=$(stat -c '%a' /opt/immich-app/.env 2>/dev/null || echo '')
  [ "$perms" = "600" ] && ok ".env permisos correctos (600)" || warn ".env permisos: ${perms:-desconocidos}"
else
  fail ".env no existe"
fi
[ -f /opt/immich-app/docker-compose.yml ] && ok "docker-compose.yml existe" || fail "docker-compose.yml no existe"

db_env_value() {
  local key="$1" default="$2" value=""
  if [ -f /opt/immich-app/.env ]; then
    value=$(awk -F= -v key="$key" '$1==key{print substr($0, index($0, "=")+1); exit}' /opt/immich-app/.env)
  fi
  [ -n "$value" ] || value="$default"
  printf '%s\n' "$value"
}

SYSTEM_CFG_JSON=""
DB_USER_CFG="$(db_env_value DB_USERNAME immich)"
DB_NAME_CFG="$(db_env_value DB_DATABASE_NAME immich)"
SYSTEM_CFG_JSON=$(docker exec immich_postgres psql -U "$DB_USER_CFG" -d "$DB_NAME_CFG" -At -c "select value::text from system_metadata where key = 'system-config';" 2>/dev/null || true)

section "IMMICH POLÍTICA"
if [ -n "$SYSTEM_CFG_JSON" ]; then
  python3 - "$SYSTEM_CFG_JSON" <<'PY'
import json, sys
cfg = json.loads(sys.argv[1])
checks = [
    ("backup.database.enabled", cfg.get("backup", {}).get("database", {}).get("enabled") is False),
    ("ffmpeg.transcode=disabled", cfg.get("ffmpeg", {}).get("transcode") == "disabled"),
    ("nightlyTasks.generateMemories=false", cfg.get("nightlyTasks", {}).get("generateMemories") is False),
    ("library.scan.enabled=false", cfg.get("library", {}).get("scan", {}).get("enabled") is False),
]
for label, ok in checks:
    print(("OK " if ok else "FAIL ") + label)
PY
else
  warn "No pude leer system-config desde PostgreSQL"
fi | while read -r line; do
  case "$line" in
    "OK "*) ok "${line#OK }" ;;
    "FAIL "*) warn "${line#FAIL }" ;;
  esac
done

section "PRECHECK"
if [ -x /usr/local/bin/precheck.sh ]; then
  bash -n /usr/local/bin/precheck.sh >/dev/null 2>&1 && ok "precheck.sh instalado y sintaxis válida" || fail "precheck.sh con errores de sintaxis"
else
  fail "precheck.sh ausente"
fi

section "SCRIPTS DE MANTENIMIENTO"
for f in /usr/local/bin/video-optimize.sh /usr/local/bin/video-reprocess-nightly.sh /usr/local/bin/video-autopilot.sh /usr/local/bin/iml-autopilot.sh /usr/local/bin/rebuild-video-cache.sh /usr/local/bin/backup.sh /usr/local/bin/manual-retention.sh /usr/local/bin/smart-check.sh /usr/local/bin/night-run.sh /usr/local/bin/nas-alert.sh /usr/local/bin/mount-guard.sh /usr/local/bin/playback-watchdog.sh /usr/local/bin/state-backup.sh /usr/local/bin/state-restore.sh /usr/local/bin/retry-quarantine.sh /usr/local/bin/post-upload-check.sh /usr/local/bin/precheck.sh; do
  if [ -x "$f" ]; then bash -n "$f" >/dev/null 2>&1 && ok "$f instalado y sintaxis válida" || fail "$f con errores de sintaxis"; else fail "$f ausente"; fi
done
[ -x /usr/local/bin/immich-video-playback-resolver.py ] && python3 -m py_compile /usr/local/bin/immich-video-playback-resolver.py >/dev/null 2>&1 && ok "/usr/local/bin/immich-video-playback-resolver.py instalado y sintaxis válida" || fail "/usr/local/bin/immich-video-playback-resolver.py ausente o inválido"
if [ -x /usr/local/bin/reconcile-emmc-cache.py ]; then
  python3 -m py_compile /usr/local/bin/reconcile-emmc-cache.py >/dev/null 2>&1 && ok "/usr/local/bin/reconcile-emmc-cache.py instalado y sintaxis válida" || fail "/usr/local/bin/reconcile-emmc-cache.py con errores de sintaxis"
else
  warn "/usr/local/bin/reconcile-emmc-cache.py no instalado"
fi

section "POLÍTICA FOTOS/VIDEOS"
if grep -E '^[[:space:]]*[^#].*--delete' /usr/local/bin/backup.sh 2>/dev/null; then
  fail "backup.sh aún usa --delete sobre respaldos de fotos/videos"
else
  ok "backup.sh no usa --delete (sin depuración automática de fotos/videos)"
fi
if grep -Eq 'rm -rf .*snapshots|head -n -[0-9]+' /usr/local/bin/backup.sh 2>/dev/null; then
  fail "backup.sh aún contiene poda automática de snapshots"
else
  ok "backup.sh no contiene poda automática de snapshots"
fi
if grep -q 'Huérfano eliminado' /usr/local/bin/cache-clean.sh 2>/dev/null; then
  fail "cache-clean.sh sigue en modo borrado automático"
else
  ok "cache-clean.sh está en modo auditoría (sin borrado automático)"
fi
if crontab -l 2>/dev/null | grep -q 'manual-retention.sh.*--apply'; then
  fail "Existe depuración automática manual-retention.sh --apply en crontab"
else
  ok "No hay depuración automática de fotos/videos vía crontab"
fi
if [ -x /usr/local/bin/video-reprocess-manager.py ]; then
  python3 -m py_compile /usr/local/bin/video-reprocess-manager.py >/dev/null 2>&1 && ok "/usr/local/bin/video-reprocess-manager.py instalado y sintaxis válida" || fail "/usr/local/bin/video-reprocess-manager.py con errores de sintaxis"
else
  warn "/usr/local/bin/video-reprocess-manager.py no instalado"
fi
if [ -x /usr/local/bin/audit_video_playback.py ]; then
  python3 -m py_compile /usr/local/bin/audit_video_playback.py >/dev/null 2>&1 && ok "/usr/local/bin/audit_video_playback.py instalado y sintaxis válida" || fail "/usr/local/bin/audit_video_playback.py con errores de sintaxis"
else
  warn "/usr/local/bin/audit_video_playback.py no instalado"
fi
if [ -x /usr/local/bin/iml-backlog-drain.py ]; then
  python3 -m py_compile /usr/local/bin/iml-backlog-drain.py >/dev/null 2>&1 && ok "/usr/local/bin/iml-backlog-drain.py instalado y sintaxis válida" || fail "/usr/local/bin/iml-backlog-drain.py con errores de sintaxis"
else
  warn "/usr/local/bin/iml-backlog-drain.py no instalado"
fi
if [ -x /usr/local/bin/iml-drain-finalize.py ]; then
  python3 -m py_compile /usr/local/bin/iml-drain-finalize.py >/dev/null 2>&1 && ok "/usr/local/bin/iml-drain-finalize.py instalado y sintaxis válida" || fail "/usr/local/bin/iml-drain-finalize.py con errores de sintaxis"
else
  warn "/usr/local/bin/iml-drain-finalize.py no instalado"
fi

section "HEALTH STATES"
for f in /var/lib/nas-health/mount-status.env /var/lib/nas-health/smart-status.env /var/lib/nas-health/storage-status.env /var/lib/nas-health/db-status.env; do
  [ -f "$f" ] && ok "$f presente" || warn "$f aún no existe (se generará tras rutina/check)"
done

section "NGINX / PLAYBACK"
if [ -f /etc/nginx/sites-enabled/immich.conf ]; then
  grep -q 'video-processing.mp4' /etc/nginx/sites-enabled/immich.conf && ok "Placeholder de video cableado en nginx" || fail "Nginx no referencia video-processing.mp4"
  grep -q 'video-processing-portrait.mp4' /etc/nginx/sites-enabled/immich.conf && ok "Placeholder vertical cableado en nginx" || fail "Nginx no referencia video-processing-portrait.mp4"
  grep -q '__cache-video/' /etc/nginx/sites-enabled/immich.conf && ok "Alias interno del cache de video presente" || fail "Nginx no expone el cache de video interno"
  if grep -q 'alias /var/lib/immich/cache/' /etc/nginx/sites-enabled/immich.conf; then
    ok "Nginx sirve el cache de video desde eMMC"
  else
    fail "Nginx no apunta al cache canonico /var/lib/immich/cache"
  fi
  if grep -q 'location /__cache-video-legacy/' /etc/nginx/sites-enabled/immich.conf && grep -q 'alias /mnt/storage-main/cache/' /etc/nginx/sites-enabled/immich.conf; then
    ok "Compatibilidad con cache legado en HDD presente"
  else
    warn "No encontre el fallback opcional al cache legado en HDD"
  fi
  grep -q '__immich-direct/' /etc/nginx/sites-enabled/immich.conf && ok "Alias interno del playback directo presente" || fail "Nginx no expone el playback directo interno"
  grep -q '127.0.0.1:2284' /etc/nginx/sites-enabled/immich.conf && ok "Playback web pasa por el resolutor local" || fail "Playback web no pasa por el resolutor local"
  if grep -q '/api/socket.io/' /etc/nginx/sites-enabled/immich.conf && grep -q 'proxy_set_header Upgrade' /etc/nginx/sites-enabled/immich.conf; then
    ok "Proxy WebSocket de Immich presente"
  else
    warn "No encontre el proxy WebSocket de Immich en nginx"
  fi
else
  fail "immich.conf no existe en nginx"
fi
[ -f /var/lib/immich/static/video-processing.mp4 ] && ok "Placeholder MP4 presente" || warn "Placeholder MP4 no encontrado"
[ -f /var/lib/immich/static/video-processing-portrait.mp4 ] && ok "Placeholder MP4 vertical presente" || warn "Placeholder MP4 vertical no encontrado"
[ -f /var/lib/immich/static/video-damaged.mp4 ] && ok "Placeholder MP4 archivo danado presente" || warn "Placeholder archivo danado no encontrado"
[ -f /var/lib/immich/static/video-damaged-portrait.mp4 ] && ok "Placeholder MP4 archivo danado vertical presente" || warn "Placeholder archivo danado vertical no encontrado"
[ -f /var/lib/immich/static/video-missing.mp4 ] && ok "Placeholder MP4 archivo no encontrado presente" || warn "Placeholder archivo no encontrado no encontrado"
[ -f /var/lib/immich/static/video-missing-portrait.mp4 ] && ok "Placeholder MP4 archivo no encontrado vertical presente" || warn "Placeholder archivo no encontrado vertical no encontrado"
[ -f /var/lib/immich/static/video-error.mp4 ] && ok "Placeholder MP4 error temporal presente" || warn "Placeholder error temporal no encontrado"
[ -f /var/lib/immich/static/video-error-portrait.mp4 ] && ok "Placeholder MP4 error temporal vertical presente" || warn "Placeholder error temporal vertical no encontrado"
[ -f /etc/default/nas-video-policy ] && ok "Politica de video presente" || warn "No encontre /etc/default/nas-video-policy"
if [ -f /etc/default/nas-video-policy ] && grep -q '^VIDEO_PLAYBACK_BROWSER_CACHE_SEC=' /etc/default/nas-video-policy; then
  ok "Politica define VIDEO_PLAYBACK_BROWSER_CACHE_SEC"
fi
if [ -f /etc/default/nas-video-policy ] && grep -q '^VIDEO_REPROCESS_LIGHT_LIMIT=' /etc/default/nas-video-policy; then
  ok "Politica define VIDEO_REPROCESS_LIGHT_LIMIT"
else
  warn "Politica no define VIDEO_REPROCESS_LIGHT_LIMIT"
fi
if [ -f /etc/default/nas-video-policy ] && grep -q '^VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED=' /etc/default/nas-video-policy; then
  ok "Politica define VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED"
else
  warn "Politica no define VIDEO_REPROCESS_DYNAMIC_LOAD_ENABLED"
fi
if [ -f /etc/default/nas-video-policy ] && grep -q '^VIDEO_AUTOPILOT_ENABLED=' /etc/default/nas-video-policy; then
  ok "Politica define VIDEO_AUTOPILOT_ENABLED"
else
  warn "Politica no define VIDEO_AUTOPILOT_ENABLED"
fi
if [ -f /etc/default/nas-video-policy ] && grep -q '^IML_AUTOPILOT_ENABLED=' /etc/default/nas-video-policy; then
  ok "Politica define IML_AUTOPILOT_ENABLED"
else
  warn "Politica no define IML_AUTOPILOT_ENABLED"
fi
if [ -f /etc/default/nas-video-policy ] && grep -q '^VIDEO_REPROCESS_MANUAL_QUEUE=' /etc/default/nas-video-policy; then
  ok "Politica define VIDEO_REPROCESS_MANUAL_QUEUE"
else
  warn "Politica no define VIDEO_REPROCESS_MANUAL_QUEUE"
fi
if systemctl is-active --quiet immich-video-playback-resolver 2>/dev/null; then
  ok "Resolutor de playback web activo"
else
  fail "Resolutor de playback web no activo"
fi
if systemctl cat immich-video-playback-resolver 2>/dev/null | grep -q 'Environment=CACHE_ROOT=/var/lib/immich/cache'; then
  ok "Resolutor usa el cache de video en eMMC"
else
  fail "No pude confirmar el CACHE_ROOT del resolutor"
fi
if systemctl cat immich-video-playback-resolver 2>/dev/null | grep -q 'Environment=LEGACY_CACHE_ROOTS=/mnt/storage-main/cache'; then
  ok "Resolutor tiene fallback al cache legado en HDD"
else
  warn "No encontre fallback al cache legado en HDD en el resolutor"
fi

section "CRONTAB"
crontab -l 2>/dev/null | grep -q 'night-run.sh' && ok "Cron night-run presente" || fail "Cron night-run ausente"
crontab -l 2>/dev/null | grep -q 'immich-ml-window.sh day-off' && ok "Cron day-off IA visual presente" || warn "Cron day-off IA visual ausente"
crontab -l 2>/dev/null | grep -q 'iml-autopilot.sh' && ok "Cron iml-autopilot presente" || warn "Cron iml-autopilot ausente"
crontab -l 2>/dev/null | grep -q 'video-autopilot.sh' && ok "Cron video-autopilot presente" || warn "Cron video-autopilot ausente"
crontab -l 2>/dev/null | grep -q 'ml-temp-guard' && ok "Cron ml-temp-guard presente" || warn "Cron ml-temp-guard ausente"
crontab -l 2>/dev/null | grep -q 'playback-watchdog.sh' && ok "Cron playback-watchdog presente" || warn "Cron playback-watchdog ausente"
crontab -l 2>/dev/null | grep -q 'smart-check.sh monthly' && ok "Cron SMART mensual presente" || warn "Cron SMART mensual ausente"

section "RESUMEN"
echo -e "\n${BOLD}PASS:${NC} $PASS  ${BOLD}WARN:${NC} $WARN  ${BOLD}FAIL:${NC} $FAIL"
exit 0
