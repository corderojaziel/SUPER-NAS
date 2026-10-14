#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SRC="$SCRIPT_DIR/depurar-android-api.py"
SERVICE_SRC="$SCRIPT_DIR/depurar-android-api.service"

if [ ! -f "$API_SRC" ] || [ ! -f "$SERVICE_SRC" ]; then
  echo "ERROR: run from the SUPER-NAS repository with maintenance/ files present." >&2
  exit 1
fi

install -m 0755 "$API_SRC" /usr/local/bin/depurar-android-api.py
install -m 0644 "$SERVICE_SRC" /etc/systemd/system/depurar-android-api.service

if [ -n "${DEPURAR_ANDROID_TOKEN:-}" ]; then
  mkdir -p /etc/systemd/system/depurar-android-api.service.d
  cat > /etc/systemd/system/depurar-android-api.service.d/token.conf <<EOF
[Service]
Environment=DEPURAR_ANDROID_TOKEN=${DEPURAR_ANDROID_TOKEN}
EOF
  chmod 0600 /etc/systemd/system/depurar-android-api.service.d/token.conf
fi

systemctl daemon-reload
systemctl enable --now depurar-android-api.service
systemctl status depurar-android-api.service --no-pager
