#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIGHT_RUN="$REPO_ROOT/maintenance/night-run.sh"
ROOT="/tmp/nas-night-playback-tests"
FAKEBIN="$ROOT/fakebin"
MESSAGES_DIR="$ROOT/messages"
REPORT_MD="$ROOT/report.md"
ORIG_DIR="$ROOT/orig"
BACKED_UP="$ROOT/backed-up.txt"

mkdir -p "$ROOT" "$FAKEBIN" "$MESSAGES_DIR" "$ORIG_DIR"
: > "$BACKED_UP"

backup_file() {
  local path="$1" backup="$ORIG_DIR$1"
  if grep -Fxq "$path" "$BACKED_UP" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$(dirname "$backup")"
  if [ -e "$path" ]; then
    cp -a "$path" "$backup"
  else
    : > "${backup}.absent"
  fi
  echo "$path" >> "$BACKED_UP"
}

restore_all() {
  [ -f "$BACKED_UP" ] || return 0
  tac "$BACKED_UP" 2>/dev/null | while IFS= read -r path; do
    [ -n "$path" ] || continue
    local backup="$ORIG_DIR$path"
    if [ -f "${backup}.absent" ]; then
      rm -f "$path"
    elif [ -e "$backup" ]; then
      mkdir -p "$(dirname "$path")"
      rm -rf "$path"
      cp -a "$backup" "$path"
    fi
  done
}

cleanup() {
  restore_all
}
trap cleanup EXIT

write_exec() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod +x "$path"
}

install_fakes() {
  local path
  for path in \
    /usr/local/bin/nas-alert.sh \
    /usr/local/bin/mount-guard.sh \
    /usr/local/bin/smart-check.sh \
    /usr/local/bin/video-optimize.sh \
    /usr/local/bin/video-reprocess-nightly.sh \
    /usr/local/bin/backup.sh \
    /usr/local/bin/cache-monitor.sh \
    /usr/local/bin/cache-clean.sh \
    /usr/local/bin/immich-ml-window.sh \
    /usr/local/bin/playback-audit-autoheal.sh \
    /etc/default/nas-video-policy \
    /var/log/night-run.log; do
    backup_file "$path"
  done

  write_exec "/usr/local/bin/nas-alert.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
ROOT="/tmp/nas-night-playback-tests"
SCENARIO="${ALERT_SCENARIO:-unspecified}"
DIR="$ROOT/messages/$SCENARIO"
mkdir -p "$DIR"
STAMP="$(date +%s%N)-$$"
printf '%s\n' "$1" > "$DIR/$STAMP.txt"
EOF

  write_exec "/usr/local/bin/mount-guard.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/smart-check.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/nas-health
cat > /var/lib/nas-health/smart-status.env <<OUT
GLOBAL_SMART_STATUS=OK
SMART_LAST_RUN=$(date -Iseconds)
RISKY_DISKS=""
OUT
exit 0
EOF
  write_exec "/usr/local/bin/video-optimize.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/video-reprocess-nightly.sh" <<'EOF'
#!/bin/bash
mkdir -p /var/lib/nas-health
cat > /var/lib/nas-health/video-optimize-summary.env <<OUT
VIDEO_TOTAL_COUNT=10
VIDEO_DIRECT_COUNT=3
VIDEO_READY_COUNT=2
VIDEO_OPTIMIZED_COUNT=4
VIDEO_PENDING_COUNT=1
VIDEO_MANUAL_REVIEW_COUNT=0
OUT
exit 0
EOF
  write_exec "/usr/local/bin/backup.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/cache-monitor.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/cache-clean.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/immich-ml-window.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "/usr/local/bin/playback-audit-autoheal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/nas-health
case "${FAKE_PLAYBACK_RES:-ok_none}" in
  ok_none)
    cat > /var/lib/nas-health/playback-audit-summary.env <<OUT
PLAYBACK_AUDIT_STATUS=OK
PLAYBACK_AUDIT_TOTAL=120
PLAYBACK_AUDIT_PLAYABLE=110
PLAYBACK_AUDIT_PROCESSING=10
PLAYBACK_AUDIT_BROKEN=0
PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=0
PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=0
PLAYBACK_AUDIT_AUTOHEAL_FAILED=0
PLAYBACK_AUDIT_AUTOHEAL_SKIPPED=0
OUT
    exit 0
    ;;
  ok_heal)
    cat > /var/lib/nas-health/playback-audit-summary.env <<OUT
PLAYBACK_AUDIT_STATUS=OK
PLAYBACK_AUDIT_TOTAL=120
PLAYBACK_AUDIT_PLAYABLE=100
PLAYBACK_AUDIT_PROCESSING=8
PLAYBACK_AUDIT_BROKEN=12
PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=9
PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=7
PLAYBACK_AUDIT_AUTOHEAL_FAILED=2
PLAYBACK_AUDIT_AUTOHEAL_SKIPPED=0
OUT
    exit 0
    ;;
  fail)
    cat > /var/lib/nas-health/playback-audit-summary.env <<OUT
PLAYBACK_AUDIT_STATUS=FAIL
PLAYBACK_AUDIT_TOTAL=120
PLAYBACK_AUDIT_PLAYABLE=90
PLAYBACK_AUDIT_PROCESSING=6
PLAYBACK_AUDIT_BROKEN=24
PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=0
PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=0
PLAYBACK_AUDIT_AUTOHEAL_FAILED=0
PLAYBACK_AUDIT_AUTOHEAL_SKIPPED=0
OUT
    exit 1
    ;;
esac
EOF

  cat > /etc/default/nas-video-policy <<'EOF'
VIDEO_OPTIMIZE_MAX_MIN=5
PLAYBACK_AUDIT_MAX_MIN=5
EOF

  # fakebin para dependencias del host
  write_exec "$FAKEBIN/mountpoint" <<'EOF'
#!/bin/bash
exit 0
EOF
  write_exec "$FAKEBIN/df" <<'EOF'
#!/bin/bash
set -euo pipefail
mode="${1:-}"
target="${2:-/}"
case "$mode" in
  -P)
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
    echo "fakefs 100000000 10000 99990000 1% $target"
    ;;
  -Pm)
    echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
    echo "fakefs 100000 10 99990 1% $target"
    ;;
  *)
    /bin/df "$@"
    ;;
esac
EOF
  write_exec "$FAKEBIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  ps)
    echo "immich_postgres"
    ;;
  exec)
    if [ "${3:-}" = "pg_isready" ]; then
      exit 0
    fi
    if [ "${3:-}" = "pg_dumpall" ]; then
      printf '%s\n' '-- fake dump'
      exit 0
    fi
    ;;
  inspect)
    echo "0"
    ;;
  stop)
    exit 0
    ;;
esac
exit 0
EOF
  write_exec "$FAKEBIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
}

latest_msg_file() {
  local scenario="$1"
  find "$MESSAGES_DIR/$scenario" -type f 2>/dev/null | sort | tail -1
}

extract_playback_line() {
  local file="$1"
  grep -F "Auditoría playback:" "$file" | head -1 | sed 's/|/\\|/g' || true
}

run_case() {
  local scenario="$1" fake_res="$2"
  local msg_file playback_line notes_line alerts
  rm -rf "$MESSAGES_DIR/$scenario"
  mkdir -p "$MESSAGES_DIR/$scenario" /var/lib/nas-health /var/log /mnt/storage-backup/snapshots/immich-db
  : > /var/log/night-run.log

  ALERT_SCENARIO="$scenario" FAKE_PLAYBACK_RES="$fake_res" PATH="$FAKEBIN:$PATH" bash "$NIGHT_RUN" || true

  msg_file="$(latest_msg_file "$scenario")"
  if [ -n "$msg_file" ] && [ -f "$msg_file" ]; then
    playback_line="$(extract_playback_line "$msg_file")"
    notes_line="$(grep -F "Auditoría playback:" "$msg_file" | head -1 | sed 's/|/\\|/g' || true)"
  else
    playback_line="(sin resumen)"
    notes_line="(sin nota)"
  fi
  alerts="$(find "$MESSAGES_DIR/$scenario" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"

  printf '| %s | %s | %s | %s |\n' "$scenario" "$fake_res" "${alerts:-0}" "${playback_line:-"(sin línea)"}" >> "$REPORT_MD"
  if [ -n "${notes_line:-}" ]; then
    printf '| %s-note | %s | %s | %s |\n' "$scenario" "$fake_res" "${alerts:-0}" "$notes_line" >> "$REPORT_MD"
  fi
}

main() {
  install_fakes

  cat > "$REPORT_MD" <<'EOF'
# Pruebas: Corrida Nocturna (Integración con estados nuevos de video)

| Escenario | Playback Fake | Alerts | Línea en resumen nocturno |
|---|---|---:|---|
EOF

  run_case "night_playback_ok_none" "ok_none"
  run_case "night_playback_ok_heal" "ok_heal"
  run_case "night_playback_fail" "fail"

  echo "REPORT_MD=$REPORT_MD"
  cat "$REPORT_MD"
}

main "$@"
