#!/usr/bin/env python3
"""
Monitorea colas IML hasta terminar y cierra modo túnel remoto de forma segura.

Flujo:
1) vigilar colas objetivo y reactivar start/resume si hace falta
2) esperar a que queden en cero (doble confirmación)
3) regresar TV Box a modo normal:
   - immich-ml-window.sh day-off
   - machineLearning.urls => local immich-machine-learning:3003
   - restart immich-server
   - stop ml_tunnel_proxy
   - cerrar listeners reverse en 13003
4) notificar por Telegram y dejar log
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", default="http://127.0.0.1:2283/api")
    parser.add_argument("--secrets-file", default="/etc/nas-secrets")
    parser.add_argument("--log-file", default="/var/log/iml-drain-finalize.log")
    parser.add_argument("--sleep-sec", type=int, default=20)
    parser.add_argument("--timeout-min", type=int, default=360)
    parser.add_argument("--targets", default=",".join(DEFAULT_TARGETS))
    parser.add_argument("--alert-bin", default="/usr/local/bin/nas-alert.sh")
    return parser.parse_args()


def read_secrets(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip().strip('"')
    return out


def run_cmd(cmd: list[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed rc={p.returncode}: {' '.join(cmd)}\n{p.stdout}")
    return p


def log_line(path: str, msg: str) -> None:
    line = f"[{time.strftime('%F %T')}] {msg}"
    print(line, flush=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def send_alert(alert_bin: str, msg: str) -> None:
    if not alert_bin or not os.path.isfile(alert_bin):
        return
    run_cmd([alert_bin, msg], check=False)


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
    req = request.Request(url, method="GET", headers=headers)
    with request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


def auth_headers(api_url: str, secrets: dict[str, str]) -> dict[str, str]:
    api_key = secrets.get("IMMICH_API_KEY", "")
    if api_key:
        return {"x-api-key": api_key}

    email = secrets.get("IMMICH_ADMIN_EMAIL", "")
    password = secrets.get("IMMICH_ADMIN_PASSWORD", "")
    if not email or not password:
        raise RuntimeError("Faltan credenciales Immich en /etc/nas-secrets")

    data = post_json(f"{api_url}/auth/login", {"email": email, "password": password}, {})
    token = str(data.get("accessToken") or "")
    if not token:
        raise RuntimeError("No accessToken desde auth/login")
    return {"Authorization": f"Bearer {token}"}


def queue_map(api_url: str, headers: dict[str, str]) -> dict[str, dict[str, Any]]:
    payload = get_json(f"{api_url}/queues", headers)
    return {str(item.get("name") or ""): item for item in payload}


def queue_state_line(qm: dict[str, dict[str, Any]], targets: list[str]) -> str:
    chunks: list[str] = []
    for name in targets:
        item = qm.get(name)
        if not item:
            chunks.append(f"{name}[missing]")
            continue
        st = item.get("statistics") or {}
        chunks.append(
            f"{name}[a={int(st.get('active',0))},w={int(st.get('waiting',0))},"
            f"p={int(st.get('paused',0))},paused={bool(item.get('isPaused'))}]"
        )
    return " ".join(chunks)


def pending_total(qm: dict[str, dict[str, Any]], targets: list[str]) -> int:
    total = 0
    for name in targets:
        item = qm.get(name)
        if not item:
            continue
        st = item.get("statistics") or {}
        total += int(st.get("active", 0)) + int(st.get("waiting", 0)) + int(st.get("paused", 0))
    return total


def ensure_running(api_url: str, headers: dict[str, str], qm: dict[str, dict[str, Any]], targets: list[str]) -> None:
    for name in targets:
        item = qm.get(name)
        if not item:
            continue
        st = item.get("statistics") or {}
        active = int(st.get("active", 0))
        waiting = int(st.get("waiting", 0))
        paused = int(st.get("paused", 0))
        is_paused = bool(item.get("isPaused"))

        if is_paused and (waiting + paused) > 0:
            try:
                put_json(f"{api_url}/jobs/{name}", {"command": "resume"}, headers)
            except Exception:
                pass

        if active == 0 and waiting > 0:
            try:
                put_json(f"{api_url}/jobs/{name}", {"command": "start"}, headers)
            except Exception:
                pass


def set_ml_url_local(log_file: str) -> None:
    db_user = "immich"
    db_name = "immich"
    env_file = "/opt/immich-app/.env"
    if os.path.isfile(env_file):
        with open(env_file, "r", encoding="utf-8", errors="ignore") as fh:
            for raw in fh:
                line = raw.strip()
                if line.startswith("DB_USERNAME="):
                    db_user = line.split("=", 1)[1].strip() or db_user
                elif line.startswith("DB_DATABASE_NAME="):
                    db_name = line.split("=", 1)[1].strip() or db_name

    sql = r"""
DO $$
DECLARE
    cfg jsonb := COALESCE((SELECT value FROM system_metadata WHERE key = 'system-config'),'{}'::jsonb);
BEGIN
    IF NOT (cfg ? 'machineLearning') THEN
        cfg := jsonb_set(cfg, '{machineLearning}', '{}'::jsonb, true);
    END IF;
    cfg := jsonb_set(cfg, '{machineLearning,urls}', '["http://immich-machine-learning:3003"]'::jsonb, true);
    INSERT INTO system_metadata(key, value)
    VALUES ('system-config', cfg)
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value;
END $$;
"""
    proc = subprocess.Popen(
        ["docker", "exec", "-i", "immich_postgres", "psql", "-U", db_user, "-d", db_name],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    out, _ = proc.communicate(sql)
    if proc.returncode != 0:
        raise RuntimeError(f"No pude actualizar machineLearning.urls: {out}")
    log_line(log_file, "machineLearning.urls actualizado a local")


def stop_reverse_13003(log_file: str) -> int:
    p = run_cmd(["bash", "-lc", "ss -ltnp | grep ':13003' || true"], check=False)
    text = p.stdout or ""
    pids = sorted({int(x) for x in re.findall(r"pid=(\d+)", text)})
    for pid in pids:
        run_cmd(["kill", "-TERM", str(pid)], check=False)
    time.sleep(2)
    log_line(log_file, f"reverse tunnel pids stopped on 13003: {pids}")
    return len(pids)


def port_listening(port: int) -> bool:
    p = run_cmd(["bash", "-lc", f"ss -ltn | grep ':{port} ' || true"], check=False)
    return bool((p.stdout or "").strip())


def main() -> int:
    args = parse_args()
    targets = [x.strip() for x in args.targets.split(",") if x.strip()]
    if not targets:
        targets = list(DEFAULT_TARGETS)

    secrets = read_secrets(args.secrets_file)
    log_line(args.log_file, f"START targets={targets}")
    send_alert(
        args.alert_bin,
        "🛠️ Monitoreo final IML iniciado\n"
        "Voy a vigilar hasta terminar y luego cerrar túnel/GPU para volver a modo normal.",
    )

    headers = auth_headers(args.api_url, secrets)
    start_ts = time.time()
    zero_rounds = 0

    while True:
        elapsed_min = (time.time() - start_ts) / 60.0
        if args.timeout_min > 0 and elapsed_min >= args.timeout_min:
            qm = queue_map(args.api_url, headers)
            state = queue_state_line(qm, targets)
            log_line(args.log_file, f"TIMEOUT after {args.timeout_min} min {state}")
            send_alert(args.alert_bin, f"⚠️ Monitoreo IML llegó a timeout\nEstado actual:\n{state}")
            return 1

        try:
            qm = queue_map(args.api_url, headers)
        except Exception:
            headers = auth_headers(args.api_url, secrets)
            qm = queue_map(args.api_url, headers)

        ensure_running(args.api_url, headers, qm, targets)
        qm = queue_map(args.api_url, headers)
        total = pending_total(qm, targets)
        state = queue_state_line(qm, targets)
        log_line(args.log_file, f"PENDING={total} {state}")

        if total == 0:
            zero_rounds += 1
        else:
            zero_rounds = 0

        if zero_rounds >= 2:
            break

        time.sleep(max(args.sleep_sec, 1))

    log_line(args.log_file, "Queues drained. Starting tunnel shutdown/normalization")
    send_alert(args.alert_bin, "✅ IML terminó de procesar\nInicio cierre de túnel y regreso a modo normal.")

    run_cmd(["/usr/local/bin/immich-ml-window.sh", "day-off"], check=False)
    set_ml_url_local(args.log_file)
    run_cmd(["bash", "-lc", "cd /opt/immich-app && docker compose restart immich-server"], check=False)
    run_cmd(["docker", "stop", "ml_tunnel_proxy"], check=False)
    killed = stop_reverse_13003(args.log_file)

    headers = None
    qm_final: dict[str, dict[str, Any]] = {}
    final_pending = -1
    final_state = "unavailable"
    for attempt in range(1, 13):
        try:
            headers = auth_headers(args.api_url, secrets)
            qm_final = queue_map(args.api_url, headers)
            final_pending = pending_total(qm_final, targets)
            final_state = queue_state_line(qm_final, targets)
            break
        except Exception as exc:
            log_line(
                args.log_file,
                f"retry_final_state attempt={attempt}/12 waiting_api err={type(exc).__name__}: {exc}",
            )
            time.sleep(5)

    p13003 = port_listening(13003)
    p13031 = port_listening(13031)

    log_line(
        args.log_file,
        f"FINAL pending={final_pending} p13003={p13003} p13031={p13031} killed={killed} {final_state}",
    )

    send_alert(
        args.alert_bin,
        "🏁 Cierre IML/túnel completado\n"
        f"Pendiente colas objetivo: {final_pending}\n"
        f"Puerto 13003 activo: {p13003}\n"
        f"Puerto 13031 activo: {p13031}\n"
        f"PIDs de túnel cerrados: {killed}\n"
        "TV Box en modo normal y logs guardados.",
    )
    if final_pending < 0:
        return 1
    print("DONE", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
