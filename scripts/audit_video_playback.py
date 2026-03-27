#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import subprocess
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Audit HTTP playback for all video asset IDs.")
    p.add_argument("--email", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--immich-api", default="http://127.0.0.1:2283")
    p.add_argument("--playback-base", default="http://127.0.0.1")
    p.add_argument("--output-dir", default="/var/lib/nas-health")
    p.add_argument("--workers", type=int, default=20)
    p.add_argument("--timeout-sec", type=float, default=20.0)
    p.add_argument("--sample-bytes", type=int, default=256)
    p.add_argument("--compose-dir", default="/opt/immich-app")
    return p.parse_args()


def login_token(api_base: str, email: str, password: str, timeout_sec: float) -> str:
    payload = json.dumps({"email": email, "password": password}).encode("utf-8")
    req = urllib.request.Request(
        f"{api_base.rstrip('/')}/api/auth/login",
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
        data = json.loads(resp.read().decode("utf-8", "ignore"))
    token = data.get("accessToken", "")
    if not token:
        raise RuntimeError("Login ok pero sin accessToken")
    return token


def fetch_video_ids(compose_dir: str) -> list[str]:
    sql = (
        "select a.id from asset a "
        "where a.type='VIDEO' and a.status='active' and a.\"deletedAt\" is null;"
    )
    cmd = [
        "docker",
        "compose",
        "exec",
        "-T",
        "database",
        "psql",
        "-U",
        "immich",
        "-d",
        "immich",
        "-At",
        "-c",
        sql,
    ]
    out = subprocess.check_output(cmd, cwd=compose_dir, text=True)
    return [line.strip() for line in out.splitlines() if line.strip()]


def classify(status: int, content_type: str, cache_control: str) -> str:
    if status in (200, 206):
        if "no-store" in cache_control:
            return "placeholder"
        if "video/mp4" in content_type.lower():
            return "playable"
        return "unexpected_content"
    if status in (401, 403):
        return "auth_error"
    if status == 404:
        return "not_found"
    return "http_error"


def probe_one(
    aid: str,
    playback_base: str,
    token: str,
    timeout_sec: float,
    sample_bytes: int,
) -> dict[str, str | int]:
    t = int(time.time())
    end_byte = max(sample_bytes - 1, 0)
    url = f"{playback_base.rstrip('/')}/api/assets/{aid}/video/playback?t={t}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Range": f"bytes=0-{end_byte}",
        },
    )

    status = 0
    content_type = ""
    cache_control = ""
    content_range = ""
    x_video_source = ""
    x_accel_redirect = ""
    error = ""
    sample_read = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            status = resp.status
            content_type = resp.headers.get("Content-Type", "")
            cache_control = ",".join(resp.headers.get_all("Cache-Control") or [])
            content_range = resp.headers.get("Content-Range", "")
            x_video_source = resp.headers.get("X-Video-Source", "")
            x_accel_redirect = resp.headers.get("X-Accel-Redirect", "")
            sample_read = len(resp.read(min(sample_bytes, 1024)))
    except urllib.error.HTTPError as exc:
        status = exc.code
        if exc.headers:
            content_type = exc.headers.get("Content-Type", "")
            cache_control = ",".join(exc.headers.get_all("Cache-Control") or [])
            content_range = exc.headers.get("Content-Range", "")
        error = exc.read(200).decode("utf-8", "ignore")
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"

    return {
        "asset_id": aid,
        "status": status,
        "class": classify(status, content_type, cache_control),
        "content_type": content_type,
        "cache_control": cache_control,
        "content_range": content_range,
        "x_video_source": x_video_source,
        "x_accel_redirect": x_accel_redirect,
        "sample_read_bytes": sample_read,
        "error": error,
    }


def main() -> int:
    args = parse_args()
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    out_csv = out_dir / f"playback-audit-{ts}.csv"
    out_json = out_dir / f"playback-audit-{ts}.json"

    token = login_token(args.immich_api, args.email, args.password, args.timeout_sec)
    ids = fetch_video_ids(args.compose_dir)

    rows: list[dict[str, str | int]] = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        futures = [
            ex.submit(
                probe_one,
                aid,
                args.playback_base,
                token,
                args.timeout_sec,
                args.sample_bytes,
            )
            for aid in ids
        ]
        for i, fut in enumerate(as_completed(futures), start=1):
            rows.append(fut.result())
            if i % 200 == 0:
                print(f"PROGRESS {i}/{len(ids)}", flush=True)

    rows.sort(key=lambda x: str(x["asset_id"]))
    with out_csv.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["asset_id"])
        writer.writeheader()
        writer.writerows(rows)

    by_class: dict[str, int] = {}
    by_status: dict[str, int] = {}
    for row in rows:
        cls = str(row["class"])
        st = str(row["status"])
        by_class[cls] = by_class.get(cls, 0) + 1
        by_status[st] = by_status.get(st, 0) + 1

    summary = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "total": len(rows),
        "by_class": by_class,
        "by_status": by_status,
        "output_csv": str(out_csv),
        "output_json": str(out_json),
    }
    out_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(f"OUTPUT_CSV={out_csv}")
    print(f"OUTPUT_JSON={out_json}")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
