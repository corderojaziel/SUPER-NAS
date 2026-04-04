#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/immich-app}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"

usage() {
  cat <<'EOF'
Uso:
  immich-ml-window.sh night-on
  immich-ml-window.sh day-off
  immich-ml-window.sh thermal-off
  immich-ml-window.sh status
EOF
}

db_value() {
  local key="$1" default="$2"
  local value=""
  if [ -f "$ENV_FILE" ]; then
    value=$(awk -F= -v key="$key" '$1==key{print substr($0, index($0, "=")+1); exit}' "$ENV_FILE")
  fi
  [ -n "$value" ] || value="$default"
  printf '%s\n' "$value"
}

wait_for_postgres() {
  local attempt
  for attempt in $(seq 1 30); do
    if "$DOCKER_BIN" exec immich_postgres \
      psql -U "$DB_USER" -d "$DB_NAME" -At -c 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

apply_policy() {
  local duplicate="$1" faces="$2" ocr="$3" cluster="$4"
  "$DOCKER_BIN" exec -i immich_postgres psql -U "$DB_USER" -d "$DB_NAME" >/dev/null <<SQL
DO \$\$
DECLARE
    cfg jsonb := COALESCE(
        (SELECT value FROM system_metadata WHERE key = 'system-config'),
        '{}'::jsonb
    );
BEGIN
    IF NOT (cfg ? 'machineLearning') THEN
        cfg := jsonb_set(
            cfg,
            '{machineLearning}',
            '{"enabled":true,"clip":{"enabled":true},"duplicateDetection":{"enabled":false},"facialRecognition":{"enabled":false},"ocr":{"enabled":false}}'::jsonb,
            true
        );
    END IF;

    cfg := jsonb_set(cfg, '{machineLearning,enabled}', 'true'::jsonb, true);
    cfg := jsonb_set(cfg, '{machineLearning,clip,enabled}', 'true'::jsonb, true);
    cfg := jsonb_set(cfg, '{machineLearning,duplicateDetection,enabled}', '${duplicate}'::jsonb, true);
    cfg := jsonb_set(cfg, '{machineLearning,facialRecognition,enabled}', '${faces}'::jsonb, true);
    cfg := jsonb_set(cfg, '{machineLearning,ocr,enabled}', '${ocr}'::jsonb, true);

    IF NOT (cfg ? 'map') THEN
        cfg := jsonb_set(cfg, '{map}', '{"enabled":true}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{map,enabled}', 'true'::jsonb, true);

    IF NOT (cfg ? 'reverseGeocoding') THEN
        cfg := jsonb_set(cfg, '{reverseGeocoding}', '{"enabled":true}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{reverseGeocoding,enabled}', 'true'::jsonb, true);

    IF NOT (cfg ? 'nightlyTasks') THEN
        cfg := jsonb_set(cfg, '{nightlyTasks}', '{"clusterNewFaces":false,"generateMemories":true}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{nightlyTasks,clusterNewFaces}', '${cluster}'::jsonb, true);
    cfg := jsonb_set(cfg, '{nightlyTasks,generateMemories}', 'true'::jsonb, true);

    IF NOT (cfg ? 'backup') THEN
        cfg := jsonb_set(cfg, '{backup}', '{"database":{"enabled":false}}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{backup,database,enabled}', 'false'::jsonb, true);

    IF NOT (cfg ? 'library') THEN
        cfg := jsonb_set(cfg, '{library}', '{"scan":{"enabled":false}}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{library,scan,enabled}', 'false'::jsonb, true);

    IF NOT (cfg ? 'ffmpeg') THEN
        cfg := jsonb_set(cfg, '{ffmpeg}', '{"transcode":"disabled"}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{ffmpeg,transcode}', '"disabled"'::jsonb, true);

    INSERT INTO system_metadata(key, value)
    VALUES ('system-config', cfg)
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value;
END \$\$;
SQL
}

restart_server() {
  (cd "$COMPOSE_DIR" && docker compose restart immich-server >/dev/null)
}

wait_for_server_ready() {
  local attempt status health
  for attempt in $(seq 1 30); do
    status=$("$DOCKER_BIN" inspect -f '{{.State.Status}}' immich_server 2>/dev/null || echo "")
    health=$("$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' immich_server 2>/dev/null || echo "")
    if [ "$status" = "running" ] && { [ -z "$health" ] || [ "$health" = "healthy" ]; }; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_ml_container() {
  (cd "$COMPOSE_DIR" && docker compose up -d immich-machine-learning >/dev/null)
}

stop_ml_container() {
  "$DOCKER_BIN" stop immich_machine_learning >/dev/null 2>&1 || true
}

print_status() {
  "$DOCKER_BIN" exec immich_postgres \
    psql -U "$DB_USER" -d "$DB_NAME" -At -c \
    "select value::text from system_metadata where key = 'system-config';"
}

[ -n "$ACTION" ] || { usage; exit 1; }

DB_USER="$(db_value DB_USERNAME immich)"
DB_NAME="$(db_value DB_DATABASE_NAME immich)"

case "$ACTION" in
  night-on)
    wait_for_postgres
    apply_policy true true true true
    restart_server
    wait_for_server_ready
    start_ml_container
    ;;
  day-off)
    wait_for_postgres
    apply_policy false false false false
    restart_server
    wait_for_server_ready
    # Modo diurno: desactiva colas pesadas de IA, pero mantiene el
    # servicio ML disponible para Smart Search bajo demanda.
    start_ml_container
    ;;
  thermal-off)
    wait_for_postgres
    apply_policy false false false false
    restart_server
    wait_for_server_ready
    stop_ml_container
    ;;
  status)
    wait_for_postgres
    print_status
    ;;
  *)
    usage
    exit 1
    ;;
esac
