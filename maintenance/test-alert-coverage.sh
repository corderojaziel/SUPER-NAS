#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="/tmp/nas-alert-coverage"
FAKEBIN="$ROOT/fakebin"
MESSAGES_DIR="$ROOT/messages"
ORIG_DIR="$ROOT/orig"
BACKED_UP="$ROOT/backed-up.txt"
BLOCK_DEVICE_FILE="$ROOT/block-device.txt"
ALERT_MODE="${ALERT_MODE:-fake}"
ALERT_THROTTLE_SEC="${ALERT_THROTTLE_SEC:-1}"
REAL_TELEGRAM_TOKEN="${REAL_TELEGRAM_TOKEN:-}"
REAL_TELEGRAM_CHAT_ID="${REAL_TELEGRAM_CHAT_ID:-}"

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

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod +x "$path"
}

install_alert_backend() {
  backup_file "/usr/local/bin/nas-alert.sh"
  if [ "$ALERT_MODE" = "real" ]; then
    [ -n "$REAL_TELEGRAM_TOKEN" ] || { echo "REAL_TELEGRAM_TOKEN requerido para ALERT_MODE=real" >&2; exit 1; }
    [ -n "$REAL_TELEGRAM_CHAT_ID" ] || { echo "REAL_TELEGRAM_CHAT_ID requerido para ALERT_MODE=real" >&2; exit 1; }
    backup_file "/etc/nas-secrets"
    cat > /etc/nas-secrets <<EOF
TELEGRAM_TOKEN=$REAL_TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$REAL_TELEGRAM_CHAT_ID
EOF
    chmod 600 /etc/nas-secrets
    write_file "/usr/local/bin/nas-alert.sh" <<EOF
#!/bin/bash
set -euo pipefail
"$REPO_ROOT/scripts/nas-alert.sh" "\$@"
rc=\$?
sleep "$ALERT_THROTTLE_SEC"
exit \$rc
EOF
    return 0
  fi

  write_file "/usr/local/bin/nas-alert.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
ROOT="/tmp/nas-alert-coverage"
SCENARIO="${ALERT_SCENARIO:-unspecified}"
DIR="$ROOT/messages/$SCENARIO"
mkdir -p "$DIR"
STAMP="$(date +%s%N)-$$"
printf '%s\n' "$1" > "$DIR/$STAMP.txt"
printf '[%s] %s\n' "$SCENARIO" "$STAMP" >> "$ROOT/all.log"
EOF
}

install_fake_tools() {
  write_file "$FAKEBIN/rsync" <<'EOF'
#!/bin/bash
exit "${FAKE_RSYNC_RC:-0}"
EOF

  write_file "$FAKEBIN/df" <<'EOF'
#!/bin/bash
set -euo pipefail
mode="${1:-}"
target="${2:-/}"
case "$mode" in
  -P)
    avail_mb="${FAKE_DF_FREE_MB:-5000}"
    avail_kb=$((avail_mb * 1024))
    used_kb=1024
    total_kb=$((used_kb + avail_kb))
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
    echo "fakefs $total_kb $used_kb $avail_kb ${FAKE_DF_PCT:-10}% $target"
    ;;
  -Pm)
    avail_mb="${FAKE_DF_FREE_MB:-5000}"
    used_mb=1
    total_mb=$((used_mb + avail_mb))
    echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
    echo "fakefs $total_mb $used_mb $avail_mb ${FAKE_DF_PCT:-10}% $target"
    ;;
  -BG)
    free_gb="${FAKE_DF_FREE_GB:-100}"
    used_gb=1
    total_gb=$((used_gb + free_gb))
    echo "Filesystem 1G-blocks Used Available Use% Mounted on"
    echo "fakefs ${total_gb}G ${used_gb}G ${free_gb}G ${FAKE_DF_PCT:-10}% $target"
    ;;
  *)
    exec /bin/df "$@"
    ;;
esac
EOF

  write_file "$FAKEBIN/mountpoint" <<'EOF'
#!/bin/bash
target="${@: -1}"
case "${FAKE_MOUNT_MODE:-all_up}" in
  all_down) exit 1 ;;
  all_up) exit 0 ;;
  main_down) [ "$target" = "/mnt/storage-main" ] && exit 1 || exit 0 ;;
  backup_down) [ "$target" = "/mnt/storage-backup" ] && exit 1 || exit 0 ;;
  merged_down) [ "$target" = "/mnt/merged" ] && exit 1 || exit 0 ;;
  *) exit 0 ;;
esac
EOF

  write_file "$FAKEBIN/mount" <<'EOF'
#!/bin/bash
exit "${FAKE_MOUNT_RC:-0}"
EOF

  write_file "$FAKEBIN/findmnt" <<'EOF'
#!/bin/bash
echo "${FAKE_FINDMNT_FSTYPE:-fuse.mergerfs}"
EOF

  write_file "$FAKEBIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
state="${FAKE_DOCKER_STATE:-normal}"
case "${1:-}" in
  ps)
    if [ "${2:-}" = "--format" ] && [ "$state" != "missing" ]; then
      echo "immich_postgres"
    fi
    exit 0
    ;;
  inspect)
    if [ "$state" = "restart" ]; then
      echo "2"
    else
      echo "0"
    fi
    exit 0
    ;;
  exec)
    if [ "${3:-}" = "pg_isready" ]; then
      [ "$state" = "down" ] && exit 1 || exit 0
    fi
    if [ "${3:-}" = "pg_dumpall" ]; then
      [ "$state" = "dumpfail" ] && exit 1
      printf '%s\n' '-- fake dump' 'CREATE TABLE t();'
      exit 0
    fi
    exit 0
    ;;
  stop)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  write_file "$FAKEBIN/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

  write_file "$FAKEBIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

  write_file "$FAKEBIN/timeout" <<'EOF'
#!/bin/bash
set -euo pipefail
dur="$1"
shift
cmd_text="$*"
if [ -n "${FAKE_TIMEOUT_TARGET:-}" ] && [[ "$cmd_text" == *"$FAKE_TIMEOUT_TARGET"* ]]; then
  exit 124
fi
exec /usr/bin/timeout "$dur" "$@"
EOF

  write_file "$FAKEBIN/smartctl" <<'EOF'
#!/bin/bash
set -euo pipefail
mode="${FAKE_SMART_MODE:-ok}"
if [[ " $* " == *" -i "* ]]; then
  if [ "$mode" = "no-smart" ]; then
    echo "SMART support is: Unavailable"
  else
    echo "SMART support is: Enabled"
  fi
  exit 0
fi
if [[ " $* " == *" -t short "* ]]; then
  exit 0
fi
if [[ " $* " == *" -A "* ]] || [[ " $* " == *" -H "* ]] || [[ " $* " == *" -a "* ]]; then
  case "$mode" in
    ok)
      cat <<OUT
SMART overall-health self-assessment test result: PASSED
  5 Reallocated_Sector_Ct 100 100 036 Pre-fail Always - - 0
197 Current_Pending_Sector 100 100 000 Old_age Always - - 0
198 Offline_Uncorrectable 100 100 000 Old_age Offline - - 0
194 Temperature_Celsius 065 050 000 Old_age Always - - 36
# 1 Short offline Completed without error
OUT
      ;;
    warn)
      cat <<OUT
SMART overall-health self-assessment test result: PASSED
  5 Reallocated_Sector_Ct 100 100 036 Pre-fail Always - - 1
197 Current_Pending_Sector 100 100 000 Old_age Always - - 0
198 Offline_Uncorrectable 100 100 000 Old_age Offline - - 0
194 Temperature_Celsius 065 050 000 Old_age Always - - 52
# 1 Short offline Completed without error
OUT
      ;;
    crit)
      cat <<OUT
SMART overall-health self-assessment test result: PASSED
  5 Reallocated_Sector_Ct 100 100 036 Pre-fail Always - - 0
197 Current_Pending_Sector 100 100 000 Old_age Always - - 2
198 Offline_Uncorrectable 100 100 000 Old_age Offline - - 1
194 Temperature_Celsius 065 050 000 Old_age Always - - 42
# 1 Short offline Completed without error
OUT
      ;;
    failed)
      cat <<OUT
SMART overall-health self-assessment test result: FAILED
  5 Reallocated_Sector_Ct 100 100 036 Pre-fail Always - - 0
197 Current_Pending_Sector 100 100 000 Old_age Always - - 0
198 Offline_Uncorrectable 100 100 000 Old_age Offline - - 0
194 Temperature_Celsius 065 050 000 Old_age Always - - 42
# 1 Short offline Completed without error
OUT
      ;;
  esac
  exit 0
fi
exit 0
EOF
}

install_night_stubs() {
  local path
  for path in \
    /usr/local/bin/mount-guard.sh \
    /usr/local/bin/smart-check.sh \
    /usr/local/bin/video-optimize.sh \
    /usr/local/bin/backup.sh \
    /usr/local/bin/cache-monitor.sh \
    /usr/local/bin/cache-clean.sh; do
    backup_file "$path"
  done

  write_file "/usr/local/bin/mount-guard.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

  write_file "/usr/local/bin/smart-check.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/nas-health
cat > /var/lib/nas-health/smart-status.env <<OUT
GLOBAL_SMART_STATUS=${FAKE_NIGHT_SMART_STATUS:-OK}
SMART_LAST_RUN=$(date -Iseconds)
RISKY_DISKS=""
OUT
exit 0
EOF

  write_file "/usr/local/bin/video-optimize.sh" <<'EOF'
#!/bin/bash
exit "${FAKE_VIDEO_RC:-0}"
EOF

  write_file "/usr/local/bin/backup.sh" <<'EOF'
#!/bin/bash
exit "${FAKE_BACKUP_RC:-0}"
EOF

  write_file "/usr/local/bin/cache-monitor.sh" <<'EOF'
#!/bin/bash
exit "${FAKE_CACHE_MONITOR_RC:-0}"
EOF

  write_file "/usr/local/bin/cache-clean.sh" <<'EOF'
#!/bin/bash
exit "${FAKE_CACHE_CLEAN_RC:-0}"
EOF
}

detect_block_device() {
  if [ -f "$BLOCK_DEVICE_FILE" ]; then
    cat "$BLOCK_DEVICE_FILE"
    return 0
  fi
  local dev
  dev="$(lsblk -ndo PATH,TYPE | awk '$2=="disk" || $2=="loop"{print $1; exit}')"
  [ -n "$dev" ] || dev="/dev/loop0"
  printf '%s\n' "$dev" > "$BLOCK_DEVICE_FILE"
  printf '%s\n' "$dev"
}

prepare_block_device() {
  local dev
  dev="$(detect_block_device)"
  backup_file "/etc/nas-disks"
  printf '%s\n' "$dev" > /etc/nas-disks
}

prepare_night_env() {
  install_night_stubs
  mkdir -p /var/lib/nas-health
  rm -f /var/lib/nas-health/mount-status.env /var/lib/nas-health/storage-status.env /var/lib/nas-health/db-status.env /var/lib/nas-health/smart-status.env
}

prepare_basic_state() {
  mkdir -p /var/lib/nas-health /var/lib/nas-retry /var/lib/nas-mount-state /var/lib/immich/cache /mnt/merged
  : > /var/lib/nas-retry/video-optimize.attempts
  : > /var/lib/nas-retry/video-optimize-manual-review.txt
  : > /var/lib/nas-mount-state/status.db
}

write_health() {
  local mount_status="$1" smart_status="$2" emmc_status="$3" db_status="$4"
  mkdir -p /var/lib/nas-health
  cat > /var/lib/nas-health/mount-status.env <<EOF
GLOBAL_MOUNT_STATUS=$mount_status
BROKEN_MOUNTS=""
MOUNT_LAST_RUN=$(date -Iseconds)
EOF
  cat > /var/lib/nas-health/smart-status.env <<EOF
GLOBAL_SMART_STATUS=$smart_status
SMART_LAST_RUN=$(date -Iseconds)
RISKY_DISKS=""
EOF
  cat > /var/lib/nas-health/storage-status.env <<EOF
EMMC_STATUS=$emmc_status
EMMC_USED_PCT=10
EMMC_FREE_MB=5000
EMMC_LAST_RUN=$(date -Iseconds)
EOF
  cat > /var/lib/nas-health/db-status.env <<EOF
DB_STATUS=$db_status
DB_LAST_RUN=$(date -Iseconds)
DB_REASON="test"
EOF
}

start_scenario() {
  export ALERT_SCENARIO="$1"
  rm -rf "$MESSAGES_DIR/$1"
  mkdir -p "$MESSAGES_DIR/$1"
}

count_messages() {
  local scenario="$1"
  find "$MESSAGES_DIR/$scenario" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

run_backup_scenarios() {
  local script="$REPO_ROOT/maintenance/backup.sh"
  write_health CRIT OK OK OK
  start_scenario "backup_mount_crit"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=0 bash "$script" || true

  write_health OK CRIT OK OK
  start_scenario "backup_smart_crit"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=0 bash "$script" || true

  write_health OK OK CRIT OK
  start_scenario "backup_emmc_crit"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=0 bash "$script" || true

  write_health OK OK OK CRIT
  start_scenario "backup_db_warn"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=0 bash "$script" || true

  write_health OK OK OK OK
  start_scenario "backup_success"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=0 bash "$script" || true

  write_health OK OK OK OK
  start_scenario "backup_live_changes"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=24 bash "$script" || true

  write_health OK OK OK OK
  start_scenario "backup_fail"
  PATH="$FAKEBIN:$PATH" FAKE_RSYNC_RC=23 bash "$script" || true
}

run_cache_scenarios() {
  local clean="$REPO_ROOT/maintenance/cache-clean.sh"
  local monitor="$REPO_ROOT/maintenance/cache-monitor.sh"
  local cache_root="$ROOT/cache"
  local photos_root="$ROOT/photos"
  local orphan_name="alert-coverage-$(date +%s%N).mp4"

  mkdir -p /var/lib/immich/cache/coverage
  find /mnt/merged -type f -name "$orphan_name" -delete 2>/dev/null || true
  rm -f "/var/lib/immich/cache/coverage/$orphan_name"
  touch "/var/lib/immich/cache/coverage/$orphan_name"
  start_scenario "cache_clean"
  bash "$clean" || true

  rm -rf "$cache_root" "$photos_root"
  mkdir -p "$cache_root" "$photos_root"
  fallocate -l 110M "$cache_root/video.mp4"
  fallocate -l 220M "$photos_root/library.bin"

  start_scenario "cache_monitor_crit"
  rm -f "$ROOT/cache-monitor-crit.stamp"
  PATH="$FAKEBIN:$PATH" \
    CACHE_WARN_GB=0.05 CACHE_CRIT_GB=0.1 CACHE_RATIO_WARN=10 \
    CACHE_CRIT_STAMP_FILE="$ROOT/cache-monitor-crit.stamp" \
    CACHE_DIR="$cache_root" PHOTOS_DIR="$photos_root" FREE_MOUNT_DIR="/mnt/storage-main" \
    bash "$monitor" || true

  start_scenario "cache_monitor_warn"
  PATH="$FAKEBIN:$PATH" \
    CACHE_WARN_GB=0.05 CACHE_CRIT_GB=0.2 CACHE_RATIO_WARN=90 \
    CACHE_DIR="$cache_root" PHOTOS_DIR="$photos_root" FREE_MOUNT_DIR="/mnt/storage-main" \
    bash "$monitor" || true

  start_scenario "cache_monitor_ratio"
  PATH="$FAKEBIN:$PATH" \
    CACHE_WARN_GB=9 CACHE_CRIT_GB=10 CACHE_RATIO_WARN=30 \
    CACHE_DIR="$cache_root" PHOTOS_DIR="$photos_root" FREE_MOUNT_DIR="/mnt/storage-main" \
    bash "$monitor" || true
}

run_ml_scenarios() {
  local script="$REPO_ROOT/maintenance/ml-temp-guard.sh"
  local procstat="$ROOT/procstat"
  local tempdir="$ROOT/thermal/thermal_zone0"
  mkdir -p "$tempdir"

  run_ml_case() {
    local scenario="$1" temp="$2" proc1="$3" proc2="$4"
    printf '%s\n' "$temp" > "$tempdir/temp"
    printf '%s\n' "$proc1" > "$procstat"
    ( sleep 0.05; printf '%s\n' "$proc2" > "$procstat" ) &
    start_scenario "$scenario"
    TEMP_FILE_GLOB="$ROOT/thermal/thermal_zone*/temp" \
      PROC_STAT_FILE="$procstat" \
      CPU_SAMPLE_INTERVAL_SEC=0.1 \
      DOCKER_BIN="$FAKEBIN/docker" \
      PKILL_BIN="$FAKEBIN/pkill" \
      bash "$script" || true
    wait || true
  }

  run_ml_case "ml_fan" 60000 "cpu 100 0 0 900 0 0 0 0 0 0" "cpu 110 0 0 990 0 0 0 0 0 0"
  run_ml_case "ml_high" 76000 "cpu 100 0 0 900 0 0 0 0 0 0" "cpu 180 0 0 920 0 0 0 0 0 0"
  run_ml_case "ml_crit" 86000 "cpu 100 0 0 900 0 0 0 0 0 0" "cpu 180 0 0 920 0 0 0 0 0 0"
}

run_mount_scenarios() {
  local script="$REPO_ROOT/maintenance/mount-guard.sh"
  mkdir -p /var/lib/nas-mount-state
  cat > /var/lib/nas-mount-state/status.db <<'EOF'
storage_main=up
storage_main_down_count=1
storage_backup=up
storage_backup_down_count=1
storage_merged=up
storage_merged_down_count=1
EOF

  start_scenario "mount_down"
  PATH="$FAKEBIN:$PATH" FAKE_MOUNT_MODE=all_down bash "$script" || true

  start_scenario "mount_up"
  PATH="$FAKEBIN:$PATH" FAKE_MOUNT_MODE=all_up FAKE_FINDMNT_FSTYPE=fuse.mergerfs bash "$script" || true
  PATH="$FAKEBIN:$PATH" FAKE_MOUNT_MODE=all_up FAKE_FINDMNT_FSTYPE=fuse.mergerfs bash "$script" || true
}

run_retry_scenarios() {
  local script="$REPO_ROOT/maintenance/retry-quarantine.sh"
  mkdir -p /var/lib/nas-retry

  cat > /var/lib/nas-retry/video-optimize.attempts <<'EOF'
dummy|2
EOF
  cat > /var/lib/nas-retry/video-optimize-manual-review.txt <<'EOF'
dummy|/mnt/storage-main/photos/library/demo/test-video.mp4|library/demo/test-video.mp4|ffmpeg
EOF
  start_scenario "retry_one"
  bash "$script" retry "library/demo/test-video.mp4" || true

  cat > /var/lib/nas-retry/video-optimize.attempts <<'EOF'
dummy|2
EOF
  cat > /var/lib/nas-retry/video-optimize-manual-review.txt <<'EOF'
dummy|/mnt/storage-main/photos/library/demo/test-video.mp4|library/demo/test-video.mp4|ffmpeg
EOF
  start_scenario "retry_all"
  bash "$script" retry-all || true
}

run_smart_scenarios() {
  local script="$REPO_ROOT/maintenance/smart-check.sh"
  prepare_block_device

  start_scenario "smart_no_smart"
  PATH="$FAKEBIN:$PATH" FAKE_SMART_MODE=no-smart bash "$script" daily || true

  start_scenario "smart_warn"
  PATH="$FAKEBIN:$PATH" FAKE_SMART_MODE=warn bash "$script" daily || true

  start_scenario "smart_crit"
  PATH="$FAKEBIN:$PATH" FAKE_SMART_MODE=crit bash "$script" daily || true

  start_scenario "smart_ok"
  PATH="$FAKEBIN:$PATH" FAKE_SMART_MODE=ok bash "$script" weekly || true
}

run_video_scenarios() {
  local script="$REPO_ROOT/maintenance/video-optimize.sh"
  local current start end

  current=$((10#$(date +%H)))
  start=$(printf '%02d' $(((current + 1) % 24)))
  end=$(printf '%02d' $(((current + 2) % 24)))

  write_health OK OK OK OK
  start_scenario "video_window"
  VIDEO_OPTIMIZE_WINDOW_START="$start" VIDEO_OPTIMIZE_WINDOW_END="$end" bash "$script" || true

  write_health CRIT OK OK OK
  start_scenario "video_mount_crit"
  VIDEO_OPTIMIZE_WINDOW_START=00 VIDEO_OPTIMIZE_WINDOW_END=00 bash "$script" || true

  write_health OK CRIT OK OK
  start_scenario "video_smart_crit"
  VIDEO_OPTIMIZE_WINDOW_START=00 VIDEO_OPTIMIZE_WINDOW_END=00 bash "$script" || true

  write_health OK OK CRIT OK
  start_scenario "video_emmc_crit"
  VIDEO_OPTIMIZE_WINDOW_START=00 VIDEO_OPTIMIZE_WINDOW_END=00 bash "$script" || true

  write_health OK OK OK CRIT
  start_scenario "video_db_crit"
  VIDEO_OPTIMIZE_WINDOW_START=00 VIDEO_OPTIMIZE_WINDOW_END=00 bash "$script" || true

  write_health OK OK OK OK
  mkdir -p /var/lock
  start_scenario "video_lock"
  (
    exec 9>/var/lock/video-optimize.lock
    flock -n 9
    sleep 5
  ) &
  lock_pid=$!
  sleep 0.1
  VIDEO_OPTIMIZE_WINDOW_START=00 VIDEO_OPTIMIZE_WINDOW_END=00 bash "$script" || true
  wait "$lock_pid" || true
}

run_night_scenarios() {
  local script="$REPO_ROOT/maintenance/night-run.sh"
  prepare_night_env

  start_scenario "night_lock"
  (
    exec 9>/var/lock/night-run.lock
    flock -n 9
    sleep 5
  ) &
  lock_pid=$!
  sleep 0.1
  PATH="$FAKEBIN:$PATH" bash "$script" || true
  wait "$lock_pid" || true

  start_scenario "night_mount_crit"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_down \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=normal \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_emmc_crit"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=91 FAKE_DF_FREE_MB=1000 \
    FAKE_DOCKER_STATE=normal \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_emmc_warn"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=81 FAKE_DF_FREE_MB=2500 \
    FAKE_DOCKER_STATE=normal \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_db_restart"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=restart \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_db_down"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=down \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_db_missing"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=missing \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_task_timeout"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=normal \
    FAKE_TIMEOUT_TARGET="/usr/local/bin/video-optimize.sh" \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_task_fail"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=normal \
    FAKE_VIDEO_RC=1 \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_dbdump_fail"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=dumpfail \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true

  start_scenario "night_ok"
  PATH="$FAKEBIN:$PATH" \
    FAKE_MOUNT_MODE=all_up \
    FAKE_DF_PCT=10 FAKE_DF_FREE_MB=5000 \
    FAKE_DOCKER_STATE=normal \
    FAKE_NIGHT_SMART_STATUS=OK \
    bash "$script" || true
}

check_pattern() {
  local key="$1" pattern="$2"
  if grep -Rqs --fixed-strings "$pattern" "$MESSAGES_DIR"; then
    echo "COVERED $key"
    return 0
  fi
  echo "MISSING $key -> $pattern"
  return 1
}

main() {
  prepare_basic_state
  install_alert_backend
  install_fake_tools

  run_backup_scenarios
  run_cache_scenarios
  run_ml_scenarios
  run_mount_scenarios
  run_retry_scenarios
  run_smart_scenarios
  run_video_scenarios
  run_night_scenarios

  local total=0 covered=0
  while IFS='|' read -r key pattern; do
    [ -n "$key" ] || continue
    total=$((total + 1))
    if check_pattern "$key" "$pattern"; then
      covered=$((covered + 1))
    fi
  done <<'EOF'
backup_mount|No pude ver bien los discos montados del NAS.
backup_smart|Uno de los discos reportó un problema serio.
backup_emmc|La memoria interna del NAS está casi llena.
backup_db|La base de datos de Immich está con problemas
backup_ok|se completó correctamente.
backup_live|hubo archivos cambiando mientras copiaba
backup_fail|No se pudo completar la copia de seguridad
cache_clean|Auditoría del cache terminada
cache_crit|El cache de videos está muy grande
cache_warn|El cache de videos va creciendo
cache_ratio|El cache ya es grande comparado con tu biblioteca
ml_fan|más caliente de lo normal estando casi en reposo
ml_high|El NAS se calentó más de lo normal
ml_crit|Temperatura crítica en el NAS
mount_down|Detecté un problema con el
mount_up|Se recuperó el
night_lock|Ya había una rutina nocturna corriendo
night_mount_crit|Sigo viendo un problema con
night_emmc_crit|Pausé tareas pesadas para no empeorar la situación.
night_emmc_warn|La memoria interna va justa.
night_db_restart|vi reinicios recientes
night_db_down|La base de datos de Immich no está disponible
night_db_missing|La base de datos de Immich no estuvo disponible
night_task_timeout|no pudo terminar esta noche.
night_task_fail|no pudo terminar esta noche.
night_start|Empezó la rutina nocturna
night_heavy_skipped|pausé tareas pesadas
night_dbdump_fail|No pude guardar la copia lógica de la base de datos.
night_summary|Resumen de la noche
retry_one|Un video volverá a intentarse
retry_all|Todos los videos pausados volverán a intentarse
smart_no|No pude leer la salud del disco
smart_warn|Conviene revisar el disco
smart_crit|necesita atención
smart_ok|Revisión del disco
video_window|La optimización de videos quedó pospuesta
video_mount|No pude ver bien los discos del NAS.
video_smart|Uno de los discos reportó un problema serio.
video_emmc|La memoria interna del NAS está casi llena.
video_db|La base de datos de Immich no está disponible.
video_lock|Ya había una optimización de videos en marcha
EOF

  printf 'TOTAL=%s\n' "$total"
  printf 'COVERED=%s\n' "$covered"
  printf 'MISSING=%s\n' "$((total - covered))"
  printf 'SCENARIOS=%s\n' "$(find "$MESSAGES_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
}

main "$@"
