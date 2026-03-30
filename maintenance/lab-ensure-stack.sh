#!/bin/bash
set -euo pipefail

if [ "${NAS_LAB_MODE:-0}" != "1" ]; then
  echo "Bloqueado por seguridad: script de laboratorio (requiere NAS_LAB_MODE=1)." >&2
  exit 2
fi

COMPOSE_DIR="${COMPOSE_DIR:-/opt/immich-app}"
API_BASE="${API_BASE:-http://127.0.0.1:2283}"
DOCKER_LOG="${DOCKER_LOG:-/var/log/dockerd-manual.log}"

wait_for_docker() {
  local attempt
  for attempt in $(seq 1 45); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

reset_dead_docker_pid() {
  local pid=""
  [ -f /var/run/docker.pid ] || return 0
  pid="$(cat /var/run/docker.pid 2>/dev/null || true)"
  if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 2
  fi
  rm -f /var/run/docker.pid /var/run/docker.sock
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  reset_dead_docker_pid
  systemctl start docker >/dev/null 2>&1 || true
  service docker start >/dev/null 2>&1 || true
  if wait_for_docker; then
    return 0
  fi

  reset_dead_docker_pid
  nohup dockerd >"$DOCKER_LOG" 2>&1 &
  if wait_for_docker; then
    return 0
  fi

  echo "ERROR: Docker no pudo iniciar en el laboratorio WSL." >&2
  tail -n 80 "$DOCKER_LOG" 2>/dev/null >&2 || true
  return 1
}

wait_for_immich() {
  local attempt
  for attempt in $(seq 1 90); do
    if curl -fsS "$API_BASE/api/server/ping" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_docker
for attempt in $(seq 1 4); do
  if (cd "$COMPOSE_DIR" && docker compose up -d >/dev/null); then
    break
  fi
  if [ "$attempt" -eq 4 ]; then
    echo "ERROR: No pude levantar el stack de Immich tras varios intentos." >&2
    exit 1
  fi
  sleep 10
done
wait_for_immich

echo "STACK_OK"
