#!/usr/bin/env python3
"""
Drena colas IML de Immich con autorecuperacion y monitoreo.

Objetivo:
  - reanudar/iniciar colas IML relevantes
  - esperar hasta que queden en cero (o hasta timeout)
  - notificar inicio y fin por Telegram (via nas-alert.sh)

Colas objetivo por defecto:
  duplicateDetection, ocr, sidecar, metadataExtraction, library,
  smartSearch, faceDetection, facialRecognition
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from dataclasses import dataclass
from typing import Any
from urllib import error, request


DEFAULT_TARGETS = (
    "duplicateDetection",
    "ocr",
    "sidecar",
    "metadataExtraction",
    "library",
    "smartSearch",
    "faceDetection",
    "facialRecognition",
)


@dataclass
class QueueState:
    name: str
    active: int
    waiting: int
    paused_jobs: int
    is_paused: bool

    @property
    def pending(self) -> int:
        return self.active + self.waiting + self.paused_jobs

    def short(self) -> str:
        return (
            f"{self.name}[a={self.active},w={self.waiting},"
            f"p={self.paused_jobs},paused={self.is_paused}]"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--api-url",
        default=os.environ.get("IMMICH_API_URL", "http://127.0.0.1:2283/api"),
        help="Base API de Immich (incluye /api).",
    )
    parser.add_argument(
        "--email",
        default=os.environ.get("IMMICH_ADMIN_EMAIL", "").strip(),
        help="Usuario admin de Immich (si no hay API key).",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("IMMICH_ADMIN_PASSWORD", "").strip(),
        help="Password admin de Immich (si no hay API key).",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("IMMICH_API_KEY", "").strip(),
        help="API key de Immich (preferido).",
    )
    parser.add_argument(
        "--secrets-file",
        default="/etc/nas-secrets",
        help="Archivo de secretos para completar credenciales faltantes.",
    )
    parser.add_argument(
        "--targets",
        default=",".join(DEFAULT_TARGETS),
        help="Lista separada por coma de colas objetivo.",
    )
    parser.add_argument(
        "--sleep-sec",
        type=int,
        default=int(os.environ.get("IML_DRAIN_SLEEP_SEC", "20")),
        help="Segundos entre revisiones.",
    )
    parser.add_argument(
        "--log-every",
        type=int,
        default=int(os.environ.get("IML_DRAIN_LOG_EVERY", "6")),
        help="Imprimir progreso cada N ciclos.",
    )
    parser.add_argument(
        "--timeout-min",
        type=int,
        default=int(os.environ.get("IML_DRAIN_TIMEOUT_MIN", "360")),
        help="Timeout maximo en minutos (0 = sin timeout).",
    )
    parser.add_argument(
        "--alert-bin",
        default=os.environ.get("NAS_ALERT_BIN", "/usr/local/bin/nas-alert.sh"),
        help="Ruta a nas-alert.sh.",
    )
    return parser.parse_args()


def read_secrets(path: str) -> dict[str, str]:
    if not path or not os.path.isfile(path):
        return {}
    out: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip().strip('"')
    except OSError:
        return {}
    return out


def send_alert(alert_bin: str, message: str) -> None:
    if not alert_bin or not os.path.isfile(alert_bin):
        return
    try:
        subprocess.run([alert_bin, message], check=False)
    except Exception:
        pass


def post_json(url: str, payload: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", **headers},
    )
    with request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


def put_json(url: str, payload: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="PUT",
        headers={"Content-Type": "application/json", **headers},
    )
    with request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_json(url: str, headers: dict[str, str]) -> Any:
    req = request.Request(url, headers=headers, method="GET")
    with request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


class ImmichClient:
    def __init__(self, api_url: str, email: str, password: str, api_key: str):
        self.api_url = api_url.rstrip("/")
        self.email = email
        self.password = password
        self.api_key = api_key
        self.token = ""

    def auth_headers(self) -> dict[str, str]:
        if self.api_key:
            return {"x-api-key": self.api_key}
        if not self.token:
            self.login()
        return {"Authorization": f"Bearer {self.token}"}

    def login(self) -> None:
        if not self.email or not self.password:
            raise RuntimeError("Faltan IMMICH_ADMIN_EMAIL/IMMICH_ADMIN_PASSWORD")
        body = {"email": self.email, "password": self.password}
        data = post_json(f"{self.api_url}/auth/login", body, {})
        token = str(data.get("accessToken") or "")
        if not token:
            raise RuntimeError("Immich auth/login no devolvio accessToken")
        self.token = token

    def fetch_queues(self) -> list[QueueState]:
        payload = get_json(f"{self.api_url}/queues", self.auth_headers())
        out: list[QueueState] = []
        for item in payload:
            stats = item.get("statistics") or {}
            out.append(
                QueueState(
                    name=str(item.get("name") or ""),
                    active=int(stats.get("active") or 0),
                    waiting=int(stats.get("waiting") or 0),
                    paused_jobs=int(stats.get("paused") or 0),
                    is_paused=bool(item.get("isPaused")),
                )
            )
        return out

    def queue_command(self, name: str, command: str) -> bool:
        try:
            put_json(
                f"{self.api_url}/jobs/{name}",
                {"command": command},
                self.auth_headers(),
            )
            return True
        except error.HTTPError as exc:
            # "already running" y similares no rompen el drenado.
            if exc.code == 400:
                return False
            raise


def ensure_running(client: ImmichClient, queue: QueueState) -> None:
    if queue.is_paused and (queue.waiting + queue.paused_jobs) > 0:
        client.queue_command(queue.name, "resume")
    if queue.active == 0 and queue.waiting > 0:
        client.queue_command(queue.name, "start")


def format_target_summary(states: dict[str, QueueState], targets: list[str]) -> str:
    chunks = []
    for name in targets:
        q = states.get(name)
        if q is None:
            chunks.append(f"{name}[missing]")
        else:
            chunks.append(q.short())
    return " ".join(chunks)


def main() -> int:
    args = parse_args()
    secrets = read_secrets(args.secrets_file)

    email = args.email or secrets.get("IMMICH_ADMIN_EMAIL", "")
    password = args.password or secrets.get("IMMICH_ADMIN_PASSWORD", "")
    api_key = args.api_key or secrets.get("IMMICH_API_KEY", "")
    targets = [x.strip() for x in args.targets.split(",") if x.strip()]
    if not targets:
        targets = list(DEFAULT_TARGETS)

    client = ImmichClient(args.api_url, email, password, api_key)

    start_ts = time.time()
    loops = 0
    last_print = ""
    send_alert(
        args.alert_bin,
        (
            "🔄 Inicio drenado IML multi-cola\n"
            f"Objetivo: {', '.join(targets)}\n"
            "Accion: resume/start automatico y monitoreo hasta cero."
        ),
    )

    while True:
        loops += 1
        try:
            states = {q.name: q for q in client.fetch_queues()}
        except Exception:
            # Reautenticacion simple en fallo temporal.
            client.token = ""
            time.sleep(3)
            states = {q.name: q for q in client.fetch_queues()}

        for name in targets:
            q = states.get(name)
            if q is not None:
                ensure_running(client, q)

        # refresco despues de comandos resume/start
        states = {q.name: q for q in client.fetch_queues()}

        pending_total = 0
        for name in targets:
            q = states.get(name)
            if q is not None:
                pending_total += q.pending

        if loops % max(args.log_every, 1) == 0:
            line = format_target_summary(states, targets)
            if line != last_print:
                print(time.strftime("%F %T"), line, flush=True)
                last_print = line

        if pending_total == 0:
            mins = round((time.time() - start_ts) / 60.0, 1)
            done_line = format_target_summary(states, targets)
            print(time.strftime("%F %T"), "DONE", done_line, flush=True)
            send_alert(
                args.alert_bin,
                (
                    "✅ Drenado IML completado\n"
                    f"Colas objetivo en cero: {', '.join(targets)}\n"
                    f"Duracion: {mins} min."
                ),
            )
            return 0

        if args.timeout_min > 0:
            elapsed_min = (time.time() - start_ts) / 60.0
            if elapsed_min >= args.timeout_min:
                summary = format_target_summary(states, targets)
                print(
                    time.strftime("%F %T"),
                    f"TIMEOUT after {args.timeout_min} min",
                    summary,
                    flush=True,
                )
                send_alert(
                    args.alert_bin,
                    (
                        "⚠️ Drenado IML alcanzó timeout\n"
                        f"Timeout: {args.timeout_min} min\n"
                        f"Estado actual: {summary}"
                    ),
                )
                return 1

        time.sleep(max(args.sleep_sec, 1))


if __name__ == "__main__":
    raise SystemExit(main())
