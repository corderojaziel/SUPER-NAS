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


PLACEHOLDER_CLASS_MAP = {
    "placeholder-missing": "placeholder_missing",
    "placeholder-damaged": "placeholder_damaged",
    "placeholder-error": "placeholder_error",
    "placeholder-processing": "placeholder_processing",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Audit HTTP playback for all video asset IDs (resolver + media layer)."
    )
    p.add_argument("--email", default="")
    p.add_argument("--password", default="")
    p.add_argument("--api-key", default="")
    p.add_argument("--immich-api", default="http://127.0.0.1:2283")
    p.add_argument("--resolver-base", default="http://127.0.0.1:2284")
    p.add_argument("--playback-base", default="http://127.0.0.1")
    p.add_argument("--output-dir", default="/var/lib/nas-health")
    p.add_argument("--workers", type=int, default=20)
    p.add_argument("--timeout-sec", type=float, default=20.0)
    p.add_argument("--sample-bytes", type=int, default=256)
    p.add_argument("--compose-dir", default="/opt/immich-app")
    p.add_argument("--append-ts", action="store_true")
    p.add_argument(
        "--deep-ffprobe",
        action="store_true",
        help="Verifica decodificación real (como preview web) en cada playback playable.",
    )
    p.add_argument("--ffprobe-bin", default="ffprobe")
    p.add_argument("--ffprobe-workers", type=int, default=4)
    p.add_argument("--ffprobe-timeout-sec", type=float, default=20.0)
    p.add_argument("--ffprobe-sample-sec", type=float, default=2.0)
    p.add_argument("--ffprobe-retries", type=int, default=2)
    p.add_argument("--ffprobe-retry-sleep-sec", type=float, default=1.5)
    p.add_argument(
        "--ffprobe-classify-timeout-as-error",
        action="store_true",
        help="Marca timeout de ffprobe como decode_error en vez de advertencia.",
    )
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


def auth_headers(token: str, api_key: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    if api_key:
        headers["X-API-Key"] = api_key
    else:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_resolver_probe(
    url: str, headers: dict[str, str], timeout_sec: float
) -> tuple[int, dict[str, str], str]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            return (
                resp.status,
                {
                    "content_type": resp.headers.get("Content-Type", ""),
                    "cache_control": ",".join(resp.headers.get_all("Cache-Control") or []),
                    "x_video_source": resp.headers.get("X-Video-Source", ""),
                    "x_accel_redirect": resp.headers.get("X-Accel-Redirect", ""),
                },
                "",
            )
    except urllib.error.HTTPError as exc:
        info = {"content_type": "", "cache_control": "", "x_video_source": "", "x_accel_redirect": ""}
        if exc.headers:
            info["content_type"] = exc.headers.get("Content-Type", "")
            info["cache_control"] = ",".join(exc.headers.get_all("Cache-Control") or [])
            info["x_video_source"] = exc.headers.get("X-Video-Source", "")
            info["x_accel_redirect"] = exc.headers.get("X-Accel-Redirect", "")
        return exc.code, info, exc.read(200).decode("utf-8", "ignore")
    except Exception as exc:  # noqa: BLE001
        return 0, {"content_type": "", "cache_control": "", "x_video_source": "", "x_accel_redirect": ""}, f"{type(exc).__name__}: {exc}"


def fetch_media_probe(
    url: str, headers: dict[str, str], timeout_sec: float, sample_bytes: int
) -> tuple[int, dict[str, str], int, str]:
    req_headers = dict(headers)
    end_byte = max(sample_bytes - 1, 0)
    req_headers["Range"] = f"bytes=0-{end_byte}"
    req = urllib.request.Request(url, headers=req_headers, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            info = {
                "content_type": resp.headers.get("Content-Type", ""),
                "cache_control": ",".join(resp.headers.get_all("Cache-Control") or []),
                "content_range": resp.headers.get("Content-Range", ""),
                "x_video_source": resp.headers.get("X-Video-Source", ""),
                "x_accel_redirect": resp.headers.get("X-Accel-Redirect", ""),
            }
            sample_read = len(resp.read(min(sample_bytes, 1024 * 1024)))
            return resp.status, info, sample_read, ""
    except urllib.error.HTTPError as exc:
        info = {"content_type": "", "cache_control": "", "content_range": "", "x_video_source": "", "x_accel_redirect": ""}
        if exc.headers:
            info["content_type"] = exc.headers.get("Content-Type", "")
            info["cache_control"] = ",".join(exc.headers.get_all("Cache-Control") or [])
            info["content_range"] = exc.headers.get("Content-Range", "")
            info["x_video_source"] = exc.headers.get("X-Video-Source", "")
            info["x_accel_redirect"] = exc.headers.get("X-Accel-Redirect", "")
        return exc.code, info, 0, exc.read(200).decode("utf-8", "ignore")
    except Exception as exc:  # noqa: BLE001
        return 0, {"content_type": "", "cache_control": "", "content_range": "", "x_video_source": "", "x_accel_redirect": ""}, 0, f"{type(exc).__name__}: {exc}"


def classify_result(
    resolver_status: int,
    resolver_source: str,
    media_status: int,
    media_content_type: str,
) -> str:
    src = (resolver_source or "").strip().lower()
    for key, cls in PLACEHOLDER_CLASS_MAP.items():
        if src.startswith(key):
            return cls

    if resolver_status in (401, 403):
        return "auth_error"
    if resolver_status == 404:
        return "not_found"
    if resolver_status and resolver_status >= 500:
        return "resolver_error"

    if media_status in (200, 206):
        if "video/" in media_content_type.lower():
            return "playable"
        return "unexpected_content"
    if media_status in (401, 403):
        return "auth_error"
    if media_status == 404:
        return "not_found"
    return "http_error"


def ffprobe_http(
    url: str,
    token: str,
    api_key: str,
    ffprobe_bin: str,
    timeout_sec: float,
    sample_sec: float,
) -> tuple[str, str]:
    if api_key:
        hdr = f"X-API-Key: {api_key}\r\n"
    else:
        hdr = f"Authorization: Bearer {token}\r\n"

    cmd = [
        ffprobe_bin,
        "-v",
        "error",
        "-headers",
        hdr,
        "-read_intervals",
        f"0%+{sample_sec}",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "default=nokey=1:noprint_wrappers=1",
        url,
    ]
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=max(timeout_sec, 1.0),
        )
    except subprocess.TimeoutExpired as exc:
        return "timeout", f"{type(exc).__name__}: {exc}"
    except OSError as exc:
        return "error", f"{type(exc).__name__}: {exc}"

    if result.returncode == 0 and (result.stdout or "").strip():
        return "ok", ""
    err = (result.stderr or result.stdout or "").strip()
    return "error", err[:400]


def probe_one(
    aid: str,
    resolver_base: str,
    playback_base: str,
    token: str,
    api_key: str,
    timeout_sec: float,
    sample_bytes: int,
    append_ts: bool,
) -> dict[str, str | int]:
    ts_q = f"?t={int(time.time())}" if append_ts else ""
    resolver_url = f"{resolver_base.rstrip('/')}/api/assets/{aid}/video/playback{ts_q}"
    media_url = f"{playback_base.rstrip('/')}/api/assets/{aid}/video/playback{ts_q}"
    headers = auth_headers(token, api_key)

    resolver_status, resolver_info, resolver_error = fetch_resolver_probe(
        resolver_url, headers, timeout_sec
    )
    media_status, media_info, sample_read, media_error = fetch_media_probe(
        media_url, headers, timeout_sec, sample_bytes
    )
    klass = classify_result(
        resolver_status,
        resolver_info.get("x_video_source", ""),
        media_status,
        media_info.get("content_type", ""),
    )

    return {
        "asset_id": aid,
        "class": klass,
        "resolver_status": resolver_status,
        "resolver_source": resolver_info.get("x_video_source", ""),
        "resolver_internal_uri": resolver_info.get("x_accel_redirect", ""),
        "resolver_cache_control": resolver_info.get("cache_control", ""),
        "resolver_content_type": resolver_info.get("content_type", ""),
        "resolver_error": resolver_error,
        "media_status": media_status,
        "media_content_type": media_info.get("content_type", ""),
        "media_cache_control": media_info.get("cache_control", ""),
        "media_content_range": media_info.get("content_range", ""),
        "media_sample_read_bytes": sample_read,
        "media_error": media_error,
        "decode_status": "skipped",
        "decode_error": "",
    }


def main() -> int:
    args = parse_args()
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    out_csv = out_dir / f"playback-audit-{ts}.csv"
    out_json = out_dir / f"playback-audit-{ts}.json"

    token = ""
    if not args.api_key:
        if not args.email or not args.password:
            raise SystemExit("ERROR: usar --api-key o bien --email + --password")
        token = login_token(args.immich_api, args.email, args.password, args.timeout_sec)

    ids = fetch_video_ids(args.compose_dir)

    rows: list[dict[str, str | int]] = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        futures = [
            ex.submit(
                probe_one,
                aid,
                args.resolver_base,
                args.playback_base,
                token,
                args.api_key,
                args.timeout_sec,
                args.sample_bytes,
                args.append_ts,
            )
            for aid in ids
        ]
        for i, fut in enumerate(as_completed(futures), start=1):
            rows.append(fut.result())
            if i % 200 == 0:
                print(f"PROGRESS {i}/{len(ids)}", flush=True)

    if args.deep_ffprobe:
        playable_rows = [row for row in rows if row.get("class") == "playable"]
        ff_workers = max(1, min(args.ffprobe_workers, len(playable_rows) or 1))

        def decode_job(row: dict[str, str | int]) -> tuple[str, str, str]:
            aid = str(row["asset_id"])
            ts_q = f"?t={int(time.time())}"
            url = (
                f"{args.playback_base.rstrip('/')}/api/assets/{aid}/video/playback{ts_q}"
            )
            last_status = "error"
            last_error = ""
            max_tries = max(args.ffprobe_retries, 0) + 1
            for attempt in range(max_tries):
                status, err = ffprobe_http(
                    url=url,
                    token=token,
                    api_key=args.api_key,
                    ffprobe_bin=args.ffprobe_bin,
                    timeout_sec=args.ffprobe_timeout_sec,
                    sample_sec=args.ffprobe_sample_sec,
                )
                if status == "ok":
                    return aid, "ok", ""
                last_status = status
                last_error = err
                if status != "timeout":
                    break
                if attempt < max_tries - 1 and args.ffprobe_retry_sleep_sec > 0:
                    time.sleep(args.ffprobe_retry_sleep_sec)
            return aid, last_status, last_error

        by_id = {str(row["asset_id"]): row for row in rows}
        with ThreadPoolExecutor(max_workers=ff_workers) as ex:
            futures = [ex.submit(decode_job, row) for row in playable_rows]
            for i, fut in enumerate(as_completed(futures), start=1):
                aid, status, err = fut.result()
                row = by_id.get(aid)
                if not row:
                    continue
                if status == "ok":
                    row["decode_status"] = "ok"
                    row["decode_error"] = ""
                else:
                    row["decode_status"] = status
                    row["decode_error"] = err
                    if status == "timeout" and not args.ffprobe_classify_timeout_as_error:
                        row["class"] = "playable"
                    else:
                        row["class"] = "decode_error"
                if i % 200 == 0:
                    print(f"DECODE_PROGRESS {i}/{len(playable_rows)}", flush=True)

    rows.sort(key=lambda x: str(x["asset_id"]))

    with out_csv.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=list(rows[0].keys()) if rows else ["asset_id"],
        )
        writer.writeheader()
        writer.writerows(rows)

    by_class: dict[str, int] = {}
    by_media_status: dict[str, int] = {}
    by_resolver_status: dict[str, int] = {}
    by_decode_status: dict[str, int] = {}
    for row in rows:
        cls = str(row.get("class", ""))
        mst = str(row.get("media_status", ""))
        rst = str(row.get("resolver_status", ""))
        dst = str(row.get("decode_status", ""))
        by_class[cls] = by_class.get(cls, 0) + 1
        by_media_status[mst] = by_media_status.get(mst, 0) + 1
        by_resolver_status[rst] = by_resolver_status.get(rst, 0) + 1
        by_decode_status[dst] = by_decode_status.get(dst, 0) + 1

    summary = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "total": len(rows),
        "by_class": by_class,
        "by_media_status": by_media_status,
        "by_resolver_status": by_resolver_status,
        "by_decode_status": by_decode_status,
        "output_csv": str(out_csv),
        "output_json": str(out_json),
        "deep_ffprobe": bool(args.deep_ffprobe),
    }
    out_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(f"OUTPUT_CSV={out_csv}")
    print(f"OUTPUT_JSON={out_json}")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
