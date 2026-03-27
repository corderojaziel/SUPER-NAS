#!/usr/bin/env python3
"""
Drena colas IML de Immich (faceDetection + facialRecognition) con autorecuperacion.

Uso:
  IMMICH_API_URL=http://127.0.0.1:2283/api \
  IMMICH_ADMIN_EMAIL=admin@example.com \
  IMMICH_ADMIN_PASSWORD=secret \
  /usr/local/bin/iml-backlog-drain.py

Comportamiento:
  - Reanuda cola pausada si tiene pendientes.
  - Si waiting>0 y active=0, ejecuta command=start.
  - Finaliza cuando ambas colas quedan en cero.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from urllib import request


API_URL = os.environ.get("IMMICH_API_URL", "http://127.0.0.1:2283/api")
EMAIL = os.environ.get("IMMICH_ADMIN_EMAIL", "jazielcordero@live.com")
PASSWORD = os.environ.get("IMMICH_ADMIN_PASSWORD", "S1santan")
SLEEP_SEC = int(os.environ.get("IML_DRAIN_SLEEP_SEC", "20"))
LOG_EVERY = int(os.environ.get("IML_DRAIN_LOG_EVERY", "15"))


def _post_json(url: str, data: dict, token: str | None = None) -> dict:
    payload = json.dumps(data).encode("utf-8")
    req = request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _put_json(url: str, data: dict, token: str) -> dict:
    payload = json.dumps(data).encode("utf-8")
    req = request.Request(url, data=payload, method="PUT")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {token}")
    with request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get_json(url: str, token: str) -> list[dict]:
    req = request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    with request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _alert(msg: str) -> None:
    try:
        subprocess.run(["/usr/local/bin/nas-alert.sh", msg], check=False)
    except Exception:
        pass


def _auth() -> str:
    data = _post_json(f"{API_URL}/auth/login", {"email": EMAIL, "password": PASSWORD})
    token = data.get("accessToken")
    if not token:
        raise RuntimeError("No accessToken from login")
    return token


def _ensure_queue_running(name: str, queue: dict, token: str) -> None:
    waiting = int(queue["statistics"]["waiting"])
    paused = int(queue["statistics"]["paused"])
    active = int(queue["statistics"]["active"])
    if queue["isPaused"] and (waiting + paused) > 0:
        try:
            _put_json(f"{API_URL}/jobs/{name}", {"command": "resume"}, token)
        except Exception:
            pass
    if active == 0 and waiting > 0:
        try:
            _put_json(f"{API_URL}/jobs/{name}", {"command": "start"}, token)
        except Exception:
            pass


def main() -> int:
    token = _auth()
    started = time.time()
    loops = 0
    last_line = ""
    _alert("🔄 Inicio drenado automático IML (faceDetection/facialRecognition).")

    while True:
        loops += 1
        try:
            queues = _get_json(f"{API_URL}/queues", token)
        except Exception:
            time.sleep(4)
            token = _auth()
            queues = _get_json(f"{API_URL}/queues", token)

        qmap = {q["name"]: q for q in queues}
        fd = qmap.get("faceDetection")
        fr = qmap.get("facialRecognition")
        if not fd or not fr:
            print(time.strftime("%F %T"), "queues missing", flush=True)
            time.sleep(SLEEP_SEC)
            continue

        _ensure_queue_running("faceDetection", fd, token)
        _ensure_queue_running("facialRecognition", fr, token)

        fd_active = int(fd["statistics"]["active"])
        fd_wait = int(fd["statistics"]["waiting"])
        fd_pause = int(fd["statistics"]["paused"])
        fr_active = int(fr["statistics"]["active"])
        fr_wait = int(fr["statistics"]["waiting"])
        fr_pause = int(fr["statistics"]["paused"])

        line = f"fd[a={fd_active},w={fd_wait},p={fd_pause}] fr[a={fr_active},w={fr_wait},p={fr_pause}]"
        if loops % LOG_EVERY == 0 and line != last_line:
            print(time.strftime("%F %T"), line, flush=True)
            last_line = line

        if (fd_active + fd_wait + fd_pause) == 0 and (fr_active + fr_wait + fr_pause) == 0:
            mins = round((time.time() - started) / 60.0, 1)
            _alert(f"✅ IML backlog drenado: faceDetection/facialRecognition en cero ({mins} min).")
            print(time.strftime("%F %T"), "DONE", flush=True)
            return 0

        time.sleep(SLEEP_SEC)


if __name__ == "__main__":
    raise SystemExit(main())
