#!/usr/bin/env python3
"""
Drena colas IML de Immich con autorecuperacion y monitoreo.

Objetivo:
  - reanudar/iniciar colas IML relevantes
  - opcional: pausar automaticamente por carga (CPU/RAM/requests)
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
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
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

DEFAULT_PHASE_ORDER = (
    ("library", "sidecar", "metadataExtraction"),
    ("smartSearch", "duplicateDetection", "ocr", "faceDetection"),
    ("facialRecognition",),
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


def env_flag(name: str, default: int = 0) -> int:
    raw = os.environ.get(name, str(default)).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return 1
    if raw in {"0", "false", "no", "off"}:
        return 0
    return default


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
        "--phase-order",
        default=os.environ.get(
            "IML_PHASE_ORDER",
            "library|sidecar|metadataExtraction;"
            "smartSearch|duplicateDetection|ocr|faceDetection;"
            "facialRecognition",
        ),
        help=(
            "Fases separadas por ';' y colas por '|' para respetar dependencias. "
            "Solo se activa la primera fase con pendiente."
        ),
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
        "--timeout-soft",
        action="store_true",
        help="Si llega al timeout, salir en 0 para que continúe en la siguiente corrida.",
    )
    parser.add_argument(
        "--alert-bin",
        default=os.environ.get("NAS_ALERT_BIN", "/usr/local/bin/nas-alert.sh"),
        help="Ruta a nas-alert.sh.",
    )
    parser.add_argument(
        "--dynamic-load-enabled",
        type=int,
        default=env_flag("IML_DYNAMIC_LOAD_ENABLED", 0),
        help="1=pausar/reanudar por carga; 0=modo continuo clásico.",
    )
    parser.add_argument(
        "--max-cpu-pct",
        type=float,
        default=float(os.environ.get("IML_MAX_CPU_PCT", "72")),
        help="Umbral de CPU para pausar.",
    )
    parser.add_argument(
        "--max-mem-pct",
        type=float,
        default=float(os.environ.get("IML_MAX_MEM_PCT", "82")),
        help="Umbral de RAM para pausar.",
    )
    parser.add_argument(
        "--max-temp-c",
        type=float,
        default=float(os.environ.get("IML_MAX_TEMP_C", "75")),
        help="Umbral de temperatura CPU (°C) para pausar.",
    )
    parser.add_argument(
        "--cpu-sample-sec",
        type=int,
        default=int(os.environ.get("IML_CPU_SAMPLE_SEC", "2")),
        help="Ventana de muestreo CPU.",
    )
    parser.add_argument(
        "--request-log-path",
        default=os.environ.get("IML_REQUEST_LOG_PATH", "/var/log/nginx/access.log"),
        help="Ruta del access log de nginx para contar requests recientes.",
    )
    parser.add_argument(
        "--request-window-sec",
        type=int,
        default=int(os.environ.get("IML_REQUEST_WINDOW_SEC", "20")),
        help="Ventana de segundos para requests recientes.",
    )
    parser.add_argument(
        "--max-requests-window",
        type=int,
        default=int(os.environ.get("IML_MAX_REQUESTS_PER_WINDOW", "8")),
        help="Si requests en ventana superan este valor, pausa (<=0 desactiva).",
    )
    parser.add_argument(
        "--busy-alert-ttl-sec",
        type=int,
        default=int(os.environ.get("IML_BUSY_ALERT_TTL_SEC", "1800")),
        help="TTL para alertas repetidas de estado ocupado.",
    )
    parser.add_argument(
        "--print-pending-only",
        action="store_true",
        help="Solo imprime el total pendiente y termina (sin alerts).",
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


def send_alert_throttled(alert_bin: str, key: str, ttl_sec: int, message: str) -> None:
    if not alert_bin or not os.path.isfile(alert_bin):
        return
    env = os.environ.copy()
    env["NAS_ALERT_KEY"] = key
    env["NAS_ALERT_TTL"] = str(max(ttl_sec, 1))
    try:
        subprocess.run([alert_bin, message], check=False, env=env)
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


def cpu_snapshot() -> tuple[int, int]:
    with open("/proc/stat", "r", encoding="utf-8", errors="ignore") as fh:
        first = fh.readline().strip()
    chunks = first.split()
    if len(chunks) < 6 or chunks[0] != "cpu":
        return (0, 0)
    nums = [int(x) for x in chunks[1:9]]
    idle = nums[3] + nums[4]  # idle + iowait
    total = sum(nums)
    return (idle, total)


def cpu_busy_pct(sample_sec: int) -> float:
    idle1, total1 = cpu_snapshot()
    time.sleep(max(sample_sec, 1))
    idle2, total2 = cpu_snapshot()
    d_total = total2 - total1
    d_idle = idle2 - idle1
    if d_total <= 0:
        return 0.0
    busy = 100.0 * (d_total - d_idle) / d_total
    return max(0.0, min(100.0, busy))


def mem_used_pct() -> float:
    total = 0
    avail = 0
    with open("/proc/meminfo", "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            if raw.startswith("MemTotal:"):
                total = int(raw.split()[1])
            elif raw.startswith("MemAvailable:"):
                avail = int(raw.split()[1])
    if total <= 0:
        return 0.0
    used = 100.0 * (total - avail) / total
    return max(0.0, min(100.0, used))


def cpu_temp_c() -> float:
    for idx in range(16):
        path = f"/sys/class/thermal/thermal_zone{idx}/temp"
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                raw = fh.read().strip()
            val = float(raw)
        except (OSError, ValueError):
            continue
        if val > 1000:
            val = val / 1000.0
        if 0.0 < val < 130.0:
            return val

    try:
        out = subprocess.run(
            ["sensors"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout or ""
        m = re.search(r"([+-]?\d+(?:\.\d+)?)°C", out)
        if m:
            val = float(m.group(1))
            if 0.0 < val < 130.0:
                return val
    except Exception:
        pass
    return 0.0


def recent_requests_count(log_path: str, window_sec: int, max_lines: int = 1200) -> int:
    if window_sec <= 0 or not log_path or not os.path.isfile(log_path):
        return 0
    try:
        tail = subprocess.run(
            ["tail", "-n", str(max_lines), log_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        lines = (tail.stdout or "").splitlines()
    except Exception:
        return 0

    pattern = re.compile(r"\[(\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]")
    now_utc = datetime.now(timezone.utc)
    total = 0
    for line in lines:
        match = pattern.search(line)
        if not match:
            continue
        try:
            dt = datetime.strptime(match.group(1), "%d/%b/%Y:%H:%M:%S %z").astimezone(timezone.utc)
        except ValueError:
            continue
        if (now_utc - dt).total_seconds() <= window_sec:
            total += 1
    return total


def load_is_busy(args: argparse.Namespace) -> tuple[bool, str, float, float, int, float]:
    cpu = cpu_busy_pct(args.cpu_sample_sec)
    mem = mem_used_pct()
    req = recent_requests_count(args.request_log_path, args.request_window_sec)
    temp = cpu_temp_c()
    reasons: list[str] = []
    if cpu > args.max_cpu_pct:
        reasons.append(f"CPU {cpu:.1f}%>{args.max_cpu_pct:.1f}%")
    if mem > args.max_mem_pct:
        reasons.append(f"RAM {mem:.1f}%>{args.max_mem_pct:.1f}%")
    if temp > args.max_temp_c:
        reasons.append(f"TEMP {temp:.1f}C>{args.max_temp_c:.1f}C")
    if args.max_requests_window > 0 and req > args.max_requests_window:
        reasons.append(
            f"REQ {req}>{args.max_requests_window} ({args.request_window_sec}s)"
        )
    return (len(reasons) > 0, "; ".join(reasons), cpu, mem, req, temp)


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
            if exc.code == 400:
                return False
            raise


def ensure_running(client: ImmichClient, queue: QueueState) -> None:
    if queue.is_paused and (queue.waiting + queue.paused_jobs) > 0:
        client.queue_command(queue.name, "resume")
    if queue.active == 0 and queue.waiting > 0:
        client.queue_command(queue.name, "start")


def pause_queue(client: ImmichClient, queue: QueueState) -> bool:
    if queue.pending <= 0 or queue.is_paused:
        return False
    return client.queue_command(queue.name, "pause")


def format_target_summary(states: dict[str, QueueState], targets: list[str]) -> str:
    chunks = []
    for name in targets:
        q = states.get(name)
        if q is None:
            chunks.append(f"{name}[missing]")
        else:
            chunks.append(q.short())
    return " ".join(chunks)


def pending_total(states: dict[str, QueueState], targets: list[str]) -> int:
    total = 0
    for name in targets:
        q = states.get(name)
        if q is not None:
            total += q.pending
    return total


def parse_phase_order(raw: str, targets: list[str]) -> list[list[str]]:
    target_set = set(targets)
    phases: list[list[str]] = []
    seen: set[str] = set()

    if raw.strip():
        for group in raw.split(";"):
            names = []
            for name in group.split("|"):
                key = name.strip()
                if not key or key not in target_set or key in seen:
                    continue
                names.append(key)
                seen.add(key)
            if names:
                phases.append(names)

    if not phases:
        for default_group in DEFAULT_PHASE_ORDER:
            names = [name for name in default_group if name in target_set and name not in seen]
            if names:
                phases.append(names)
                seen.update(names)

    remaining = [name for name in targets if name not in seen]
    for name in remaining:
        phases.append([name])

    return phases


def phase_pending_total(states: dict[str, QueueState], phase: list[str]) -> int:
    total = 0
    for name in phase:
        q = states.get(name)
        if q is not None:
            total += q.pending
    return total


def enforce_phase_order(
    client: ImmichClient,
    states: dict[str, QueueState],
    phases: list[list[str]],
) -> tuple[str, list[str], list[str]]:
    active_phase_idx = -1
    for idx, phase in enumerate(phases):
        if phase_pending_total(states, phase) > 0:
            active_phase_idx = idx
            break
    if active_phase_idx < 0:
        return ("none", [], [])

    current_phase = phases[active_phase_idx]
    resumed_or_started: list[str] = []
    paused_other: list[str] = []

    for idx, phase in enumerate(phases):
        for name in phase:
            q = states.get(name)
            if q is None:
                continue
            if idx == active_phase_idx:
                before_paused = q.is_paused
                before_active = q.active
                ensure_running(client, q)
                if (before_paused and q.pending > 0) or (before_active == 0 and q.waiting > 0):
                    resumed_or_started.append(name)
            else:
                if pause_queue(client, q):
                    paused_other.append(name)

    phase_name = "/".join(current_phase)
    return (phase_name, resumed_or_started, paused_other)


def main() -> int:
    args = parse_args()
    secrets = read_secrets(args.secrets_file)

    email = args.email or secrets.get("IMMICH_ADMIN_EMAIL", "")
    password = args.password or secrets.get("IMMICH_ADMIN_PASSWORD", "")
    api_key = args.api_key or secrets.get("IMMICH_API_KEY", "")
    targets = [x.strip() for x in args.targets.split(",") if x.strip()]
    if not targets:
        targets = list(DEFAULT_TARGETS)
    phases = parse_phase_order(args.phase_order, targets)

    client = ImmichClient(args.api_url, email, password, api_key)
    dynamic_load = args.dynamic_load_enabled == 1

    loops = 0
    start_ts = time.time()
    last_print = ""

    try:
        states = {q.name: q for q in client.fetch_queues()}
    except Exception:
        client.token = ""
        states = {q.name: q for q in client.fetch_queues()}

    if args.print_pending_only:
        print(str(pending_total(states, targets)), flush=True)
        return 0

    if dynamic_load:
        mode_line = (
            f"Modo: adaptativo (CPU<={args.max_cpu_pct:.0f}% "
            f"RAM<={args.max_mem_pct:.0f}% "
            f"TEMP<={args.max_temp_c:.0f}C "
            f"REQ<={args.max_requests_window}/{args.request_window_sec}s)"
        )
    else:
        mode_line = "Modo: continuo clasico"
    phase_line = " -> ".join("/".join(phase) for phase in phases)

    send_alert(
        args.alert_bin,
        (
            "🔄 IML: inicio de procesamiento\n"
            f"Objetivo: {', '.join(targets)}\n"
            f"{mode_line}\n"
            f"Orden: {phase_line}\n"
            "Acción: reanuda y procesa hasta dejar pendiente en cero."
        ),
    )

    while True:
        loops += 1
        try:
            states = {q.name: q for q in client.fetch_queues()}
        except Exception:
            client.token = ""
            time.sleep(3)
            states = {q.name: q for q in client.fetch_queues()}

        total_pending = pending_total(states, targets)
        if total_pending == 0:
            mins = round((time.time() - start_ts) / 60.0, 1)
            done_line = format_target_summary(states, targets)
            print(time.strftime("%F %T"), "DONE", done_line, flush=True)
            send_alert(
                args.alert_bin,
                (
                    "✅ IML completado\n"
                    f"Pendiente en cero para: {', '.join(targets)}\n"
                    f"Duración: {mins} min."
                ),
            )
            return 0

        if dynamic_load:
            busy, reason, cpu, mem, req, temp = load_is_busy(args)
            if busy:
                paused_names: list[str] = []
                for name in targets:
                    q = states.get(name)
                    if q and pause_queue(client, q):
                        paused_names.append(name)
                states = {q.name: q for q in client.fetch_queues()}
                summary = format_target_summary(states, targets)
                line = (
                    f"BUSY {reason} cpu={cpu:.1f}% mem={mem:.1f}% "
                    f"temp={temp:.1f}C req={req}/{args.request_window_sec}s "
                    f"pause={','.join(paused_names) or '-'} "
                    f"{summary}"
                )
                if loops % max(args.log_every, 1) == 0 or line != last_print:
                    print(time.strftime("%F %T"), line, flush=True)
                    last_print = line
                send_alert_throttled(
                    args.alert_bin,
                    "iml_drain:busy",
                    args.busy_alert_ttl_sec,
                    (
                        "⏸️ IML en pausa por carga alta\n"
                        f"Motivo: {reason}\n"
                        f"CPU: {cpu:.1f}% | RAM: {mem:.1f}%\n"
                        f"Temp CPU: {temp:.1f}°C\n"
                        f"Requests: {req} en {args.request_window_sec}s\n"
                        "Se reanuda solo cuando la carga baje."
                    ),
                )
                time.sleep(max(args.sleep_sec, 1))
                continue

        phase_name, moved, paused = enforce_phase_order(client, states, phases)

        states = {q.name: q for q in client.fetch_queues()}
        if loops % max(args.log_every, 1) == 0:
            line = (
                f"PHASE={phase_name} moved={','.join(moved) or '-'} "
                f"paused={','.join(paused) or '-'} "
                f"{format_target_summary(states, targets)}"
            )
            if line != last_print:
                print(time.strftime("%F %T"), line, flush=True)
                last_print = line

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
                        "⚠️ IML sigue pendiente y llegó al tiempo máximo\n"
                        f"Timeout: {args.timeout_min} min\n"
                        f"Estado actual: {summary}\n"
                        "Continuará en el siguiente ciclo automático."
                    ),
                )
                return 0 if args.timeout_soft else 1

        time.sleep(max(args.sleep_sec, 1))


if __name__ == "__main__":
    raise SystemExit(main())
