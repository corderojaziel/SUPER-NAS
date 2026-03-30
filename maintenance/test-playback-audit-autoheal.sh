#!/bin/bash
set -euo pipefail

if [ "${NAS_TEST_MODE:-0}" != "1" ]; then
  echo "Bloqueado por seguridad: este script de pruebas requiere NAS_TEST_MODE=1." >&2
  exit 2
fi
if [ "${NAS_TEST_ALLOW_PROD:-0}" != "1" ] && [ -d /mnt/storage-main/photos ] \
  && find /mnt/storage-main/photos -mindepth 1 -maxdepth 2 -print -quit 2>/dev/null | grep -q .; then
  echo "Entorno con datos productivos detectado. Para forzar, exporta NAS_TEST_ALLOW_PROD=1." >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/maintenance/playback-audit-autoheal.sh"
ROOT="/tmp/nas-playback-autoheal-tests"
MESSAGES_DIR="$ROOT/messages"
SUMMARIES_DIR="$ROOT/summaries"
REPORT_MD="$ROOT/report.md"
ORIG_DIR="$ROOT/orig"
BACKED_UP="$ROOT/backed-up.txt"

mkdir -p "$ROOT" "$MESSAGES_DIR" "$SUMMARIES_DIR" "$ORIG_DIR"
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
  backup_file "/usr/local/bin/nas-alert.sh"
  backup_file "/usr/local/bin/audit_video_playback.py"
  backup_file "/usr/local/bin/video-reprocess-manager.py"
  backup_file "/etc/default/nas-video-policy"
  backup_file "/etc/nas-secrets"
  backup_file "/var/lib/nas-health/playback-audit-summary.env"
  backup_file "/var/log/playback-audit-autoheal.log"

  write_exec "/usr/local/bin/nas-alert.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
ROOT="/tmp/nas-playback-autoheal-tests"
SCENARIO="${ALERT_SCENARIO:-unspecified}"
DIR="$ROOT/messages/$SCENARIO"
mkdir -p "$DIR"
STAMP="$(date +%s%N)-$$"
printf '%s\n' "$1" > "$DIR/$STAMP.txt"
EOF

  write_exec "/usr/local/bin/audit_video_playback.py" <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import os
import sys
from pathlib import Path

def arg_value(name: str, default: str = "") -> str:
    argv = sys.argv[1:]
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default

out_dir = Path(arg_value("--output-dir", "/var/lib/nas-health"))
out_dir.mkdir(parents=True, exist_ok=True)
scenario = os.environ.get("FAKE_AUDIT_SCENARIO", "all_ok")
csv_path = out_dir / f"playback-audit-{scenario}.csv"
json_path = out_dir / f"playback-audit-{scenario}.json"

rows = []
if scenario == "all_ok":
    rows = [
        {"asset_id": "ok1", "status": 206, "class": "playable"},
        {"asset_id": "ok2", "status": 206, "class": "playable"},
        {"asset_id": "proc1", "status": 206, "class": "placeholder_processing"},
    ]
elif scenario == "broken_no_candidates":
    rows = [
        {"asset_id": "ok1", "status": 206, "class": "playable"},
        {"asset_id": "miss1", "status": 206, "class": "placeholder_missing"},
        {"asset_id": "dam1", "status": 206, "class": "placeholder_damaged"},
        {"asset_id": "err1", "status": 206, "class": "placeholder_error"},
        {"asset_id": "nf1", "status": 404, "class": "not_found"},
    ]
elif scenario in ("broken_with_success", "broken_with_failed", "broken_run_rc_fail", "plan_fail"):
    rows = [
        {"asset_id": "ok1", "status": 206, "class": "playable"},
        {"asset_id": "a1", "status": 206, "class": "placeholder_missing"},
        {"asset_id": "a2", "status": 404, "class": "not_found"},
    ]
else:
    rows = [{"asset_id": "ok1", "status": 206, "class": "playable"}]

headers = ["asset_id", "status", "class", "content_type", "cache_control", "content_range", "x_video_source", "x_accel_redirect", "sample_read_bytes", "error"]
with csv_path.open("w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=headers)
    w.writeheader()
    for row in rows:
        base = {
            "asset_id": row["asset_id"],
            "status": row["status"],
            "class": row["class"],
            "content_type": "video/mp4",
            "cache_control": "private,max-age=300",
            "content_range": "",
            "x_video_source": "",
            "x_accel_redirect": "",
            "sample_read_bytes": 256,
            "error": "",
        }
        if str(row["class"]).startswith("placeholder_"):
            base["cache_control"] = "no-store"
            base["x_video_source"] = row["class"].replace("placeholder_", "placeholder-")
        if row["class"] == "not_found":
            base["content_type"] = "text/html"
            base["cache_control"] = "private,max-age=86400,no-transform"
        w.writerow(base)

json_path.write_text(json.dumps({"scenario": scenario, "total": len(rows)}), encoding="utf-8")
print(f"OUTPUT_CSV={csv_path}")
print(f"OUTPUT_JSON={json_path}")
EOF

  write_exec "/usr/local/bin/video-reprocess-manager.py" <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import csv
import os
import sys
from pathlib import Path

def arg_value(name: str, default: str = "") -> str:
    argv = sys.argv[1:]
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
out_dir = Path(arg_value("--output-dir", "/var/lib/nas-health/reprocess"))
out_dir.mkdir(parents=True, exist_ok=True)

if cmd == "plan":
    if int(os.environ.get("FAKE_PLAN_RC", "0")) != 0:
        raise SystemExit(int(os.environ.get("FAKE_PLAN_RC", "1")))
    plan_scenario = os.environ.get("FAKE_PLAN_SCENARIO", "with_candidates")
    light = out_dir / "light-latest.csv"
    heavy = out_dir / "heavy-latest.csv"
    broken = out_dir / "broken-latest.csv"
    headers = ["asset_id", "original_path", "source_path", "dest_cache_path", "size_bytes", "duration_sec", "mb_per_min", "needs_cache", "class", "reason"]
    with light.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=headers)
        w.writeheader()
        if plan_scenario != "no_candidates":
            w.writerow({
                "asset_id": "a1",
                "original_path": "/usr/src/app/upload/a1.mov",
                "source_path": "/mnt/storage-main/photos/upload/a1.mov",
                "dest_cache_path": "/var/lib/immich/cache/upload/a1.mp4",
                "size_bytes": "100000000",
                "duration_sec": "30",
                "mb_per_min": "200",
                "needs_cache": "yes",
                "class": "light_candidate",
                "reason": "local_nightly_retry",
            })
            w.writerow({
                "asset_id": "a2",
                "original_path": "/usr/src/app/upload/a2.mov",
                "source_path": "/mnt/storage-main/photos/upload/a2.mov",
                "dest_cache_path": "/var/lib/immich/cache/upload/a2.mp4",
                "size_bytes": "100000000",
                "duration_sec": "30",
                "mb_per_min": "200",
                "needs_cache": "yes",
                "class": "light_candidate",
                "reason": "local_nightly_retry",
            })
    for p in (heavy, broken):
        with p.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(headers)
    print(f"OUTPUT_DIR={out_dir}")
    raise SystemExit(0)

if cmd == "run":
    run_rc = int(os.environ.get("FAKE_RUN_RC", "0"))
    print(f"converted={int(os.environ.get('FAKE_RUN_CONVERTED', '0'))}")
    print(f"failed={int(os.environ.get('FAKE_RUN_FAILED', '0'))}")
    print(f"skipped={int(os.environ.get('FAKE_RUN_SKIPPED', '0'))}")
    raise SystemExit(run_rc)

raise SystemExit(0)
EOF
}

write_policy() {
  cat > /etc/default/nas-video-policy <<'EOF'
PLAYBACK_AUDIT_ENABLED=1
PLAYBACK_AUDIT_IMMICH_API=http://127.0.0.1:2283
PLAYBACK_AUDIT_BASE=http://127.0.0.1
PLAYBACK_AUDIT_OUTPUT_DIR=/var/lib/nas-health
PLAYBACK_AUDIT_WORKERS=4
PLAYBACK_AUDIT_TIMEOUT_SEC=5
PLAYBACK_AUDIT_SAMPLE_BYTES=64
PLAYBACK_AUDIT_AUTOHEAL_ENABLED=1
PLAYBACK_AUDIT_AUTOHEAL_LIMIT=200
PLAYBACK_AUDIT_AUTOHEAL_MAX_ATTEMPTS=3
PLAYBACK_AUDIT_AUTOHEAL_CLASSES="not_found http_error unexpected_content placeholder_missing placeholder_damaged placeholder_error"
VIDEO_REPROCESS_MANAGER_BIN=/usr/local/bin/video-reprocess-manager.py
VIDEO_REPROCESS_OUTPUT_DIR=/var/lib/nas-health/reprocess
VIDEO_REPROCESS_CACHE_ROOT=/var/lib/immich/cache
VIDEO_REPROCESS_UPLOAD_ROOT=/mnt/storage-main/photos
VIDEO_REPROCESS_IMMICH_ROOT=/var/lib/immich
VIDEO_STREAM_MAX_MB_PER_MIN=40
VIDEO_REPROCESS_LOCAL_MAX_MB=220
VIDEO_REPROCESS_LOCAL_MAX_DURATION_SEC=150
VIDEO_REPROCESS_LOCAL_MAX_MB_MIN=120
VIDEO_REPROCESS_ATTEMPTS_DB=/var/lib/nas-retry/video-reprocess-light.attempts.tsv
VIDEO_REPROCESS_MANUAL_QUEUE=/var/lib/nas-retry/video-reprocess-manual.tsv
VIDEO_REPROCESS_AUDIO_BITRATE_K=128
VIDEO_REPROCESS_TARGET_MAXRATE_K=5200
EOF
  chmod 644 /etc/default/nas-video-policy
}

write_secrets() {
  local mode="$1"
  case "$mode" in
    with_creds)
      cat > /etc/nas-secrets <<'EOF'
TELEGRAM_TOKEN="fake"
TELEGRAM_CHAT_ID="fake"
IMMICH_ADMIN_EMAIL="admin@example.com"
IMMICH_ADMIN_PASSWORD="pass123"
EOF
      ;;
    no_creds)
      cat > /etc/nas-secrets <<'EOF'
TELEGRAM_TOKEN="fake"
TELEGRAM_CHAT_ID="fake"
IMMICH_ADMIN_EMAIL=""
IMMICH_ADMIN_PASSWORD=""
IMMICH_API_KEY=""
EOF
      ;;
  esac
  chmod 600 /etc/nas-secrets
}

first_alert_line() {
  local scenario="$1"
  local file
  file="$(find "$MESSAGES_DIR/$scenario" -type f 2>/dev/null | sort | head -1 || true)"
  if [ -n "$file" ] && [ -f "$file" ]; then
    head -1 "$file"
  else
    echo "(sin alerta)"
  fi
}

run_case() {
  local name="$1" creds="$2" audit_s="$3" plan_s="$4" plan_rc="$5" run_rc="$6" run_conv="$7" run_fail="$8" run_skip="$9"
  local rc=0 status total playable processing broken candidates converted failed skipped alerts first_line

  export ALERT_SCENARIO="$name"
  export FAKE_AUDIT_SCENARIO="$audit_s"
  export FAKE_PLAN_SCENARIO="$plan_s"
  export FAKE_PLAN_RC="$plan_rc"
  export FAKE_RUN_RC="$run_rc"
  export FAKE_RUN_CONVERTED="$run_conv"
  export FAKE_RUN_FAILED="$run_fail"
  export FAKE_RUN_SKIPPED="$run_skip"

  rm -rf "$MESSAGES_DIR/$name"
  rm -f /var/lib/nas-health/playback-audit-summary.env
  mkdir -p /var/lib/nas-health /var/lib/nas-health/reprocess /var/lib/nas-retry

  write_policy
  write_secrets "$creds"

  if ! bash "$SCRIPT_UNDER_TEST"; then
    rc=$?
  fi

  status="$(awk -F= '/^PLAYBACK_AUDIT_STATUS=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  total="$(awk -F= '/^PLAYBACK_AUDIT_TOTAL=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  playable="$(awk -F= '/^PLAYBACK_AUDIT_PLAYABLE=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  processing="$(awk -F= '/^PLAYBACK_AUDIT_PROCESSING=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  broken="$(awk -F= '/^PLAYBACK_AUDIT_BROKEN=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  candidates="$(awk -F= '/^PLAYBACK_AUDIT_AUTOHEAL_CANDIDATES=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  converted="$(awk -F= '/^PLAYBACK_AUDIT_AUTOHEAL_CONVERTED=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  failed="$(awk -F= '/^PLAYBACK_AUDIT_AUTOHEAL_FAILED=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  skipped="$(awk -F= '/^PLAYBACK_AUDIT_AUTOHEAL_SKIPPED=/{print $2}' /var/lib/nas-health/playback-audit-summary.env 2>/dev/null | tail -1)"
  alerts="$(find "$MESSAGES_DIR/$name" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
  first_line="$(first_alert_line "$name" | sed 's/|/\\|/g')"

  cp -f /var/lib/nas-health/playback-audit-summary.env "$SUMMARIES_DIR/$name.env" 2>/dev/null || true

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$name" "${status:-NA}" "${total:-0}" "${playable:-0}" "${processing:-0}" "${broken:-0}" "${candidates:-0}" "${converted:-0}" "${failed:-0}" "${alerts:-0}" "$first_line" >> "$REPORT_MD"

  echo "CASE $name rc=$rc status=${status:-NA} total=${total:-0} broken=${broken:-0} candidates=${candidates:-0} converted=${converted:-0} failed=${failed:-0} alerts=${alerts:-0}"
}

main() {
  install_fakes
  mkdir -p /var/lib/nas-health /var/lib/nas-retry /var/log
  : > /var/log/playback-audit-autoheal.log

  cat > "$REPORT_MD" <<'EOF'
# Pruebas: Corrida Nocturna de Video (Estados nuevos)

| Caso | Status | Total | Playable | Processing | Broken | Candidates | Converted | Failed | Alerts | Primer mensaje |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
EOF

  run_case "no_creds" "no_creds" "all_ok" "with_candidates" "0" "0" "0" "0" "0"
  run_case "all_ok" "with_creds" "all_ok" "with_candidates" "0" "0" "0" "0" "0"
  run_case "broken_no_candidates" "with_creds" "broken_no_candidates" "no_candidates" "0" "0" "0" "0" "0"
  run_case "broken_with_success" "with_creds" "broken_with_success" "with_candidates" "0" "0" "2" "0" "0"
  run_case "broken_with_failed" "with_creds" "broken_with_failed" "with_candidates" "0" "0" "1" "1" "0"
  run_case "plan_fail" "with_creds" "plan_fail" "with_candidates" "2" "0" "0" "0" "0"
  run_case "broken_run_rc_fail" "with_creds" "broken_run_rc_fail" "with_candidates" "0" "3" "0" "0" "0"

  echo ""
  echo "REPORT_MD=$REPORT_MD"
  cat "$REPORT_MD"
}

main "$@"
