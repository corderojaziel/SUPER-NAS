#!/usr/bin/env python3
"""
Small local API for the Depurar Android APK.

It verifies Android video candidates against Immich PostgreSQL and the INX
filesystem. Keep it on the trusted LAN/Tailscale network; do not expose it to
the public internet.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HOST = os.environ.get("DEPURAR_ANDROID_HOST", "0.0.0.0")
PORT = int(os.environ.get("DEPURAR_ANDROID_PORT", "8787"))
TOKEN = os.environ.get("DEPURAR_ANDROID_TOKEN", "")
DB_CONTAINER = os.environ.get("DEPURAR_ANDROID_DB_CONTAINER", "immich_postgres")
DB_USER = os.environ.get("DEPURAR_ANDROID_DB_USER", "immich")
DB_NAME = os.environ.get("DEPURAR_ANDROID_DB_NAME", "immich")
CONTAINER_UPLOAD_ROOT = os.environ.get("DEPURAR_ANDROID_CONTAINER_UPLOAD_ROOT", "/usr/src/app/upload")
HOST_UPLOAD_ROOT = os.environ.get("DEPURAR_ANDROID_HOST_UPLOAD_ROOT", "/mnt/merged")


@dataclass(frozen=True)
class ImmichAsset:
    asset_id: str
    original_file_name: str
    size_bytes: int
    host_path: str
    file_created_at: str
    device_id: str


def normalize_name(name: str) -> str:
    value = (name or "").strip()
    if not value.lower().endswith(".mp4"):
        value = f"{value}.mp4"
    return value.lower()


def host_path(container_path: str) -> str:
    if container_path.startswith(CONTAINER_UPLOAD_ROOT):
        return HOST_UPLOAD_ROOT + container_path[len(CONTAINER_UPLOAD_ROOT) :]
    return container_path


def load_immich_mp4_index() -> dict[tuple[str, int], ImmichAsset]:
    sql = r"""
select a.id, a."originalFileName", coalesce(e."fileSizeInByte",0), a."originalPath",
       coalesce(a."fileCreatedAt"::text,''), coalesce(a."deviceId",'')
from asset a left join asset_exif e on e."assetId"=a.id
where a."deletedAt" is null
  and a.type='VIDEO'
  and (lower(a."originalFileName") like '%.mp4' or lower(a."originalPath") like '%.mp4')
order by a."originalFileName", e."fileSizeInByte";
"""
    cmd = [
        "docker",
        "exec",
        DB_CONTAINER,
        "psql",
        "-U",
        DB_USER,
        "-d",
        DB_NAME,
        "-F",
        "\t",
        "-At",
        "-c",
        sql,
    ]
    result = subprocess.run(cmd, check=True, text=True, capture_output=True, timeout=90)
    index: dict[tuple[str, int], ImmichAsset] = {}
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        asset_id, original_name, size_raw, container_path, created_at, device_id = parts[:6]
        try:
            size = int(size_raw)
        except ValueError:
            continue
        hp = host_path(container_path)
        if not Path(hp).is_file():
            continue
        index[(normalize_name(original_name), size)] = ImmichAsset(
            asset_id=asset_id,
            original_file_name=original_name,
            size_bytes=size,
            host_path=hp,
            file_created_at=created_at,
            device_id=device_id,
        )
    return index


def response_json(handler: BaseHTTPRequestHandler, status: int, body: dict[str, Any]) -> None:
    payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)


class Handler(BaseHTTPRequestHandler):
    server_version = "depurar-android-api/1.0"

    def do_GET(self) -> None:
        if self.path == "/health":
            response_json(self, 200, {"ok": True, "service": "depurar-android-api"})
            return
        response_json(self, 404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/api/v1/audit":
            response_json(self, 404, {"ok": False, "error": "not_found"})
            return
        if TOKEN and self.headers.get("X-Depurar-Token") != TOKEN:
            response_json(self, 401, {"ok": False, "error": "unauthorized"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(length).decode("utf-8"))
            videos = data.get("videos", [])
            if not isinstance(videos, list):
                raise ValueError("videos must be a list")
            index = load_immich_mp4_index()
            results = []
            confirmed_count = 0
            confirmed_bytes = 0
            for video in videos:
                name = str(video.get("displayName", ""))
                size = int(video.get("sizeBytes", 0) or 0)
                key = (normalize_name(name), size)
                asset = index.get(key)
                confirmed = asset is not None
                if confirmed:
                    confirmed_count += 1
                    confirmed_bytes += size
                results.append(
                    {
                        "displayName": name,
                        "sizeBytes": size,
                        "relativePath": video.get("relativePath", ""),
                        "dateModifiedMs": video.get("dateModifiedMs", 0),
                        "confirmed": confirmed,
                        "assetId": asset.asset_id if asset else "",
                        "originalFileName": asset.original_file_name if asset else "",
                        "hostPath": asset.host_path if asset else "",
                        "reason": "confirmed_in_immich_and_inx" if confirmed else "no_exact_name_size_match_or_missing_physical",
                    }
                )
            response_json(
                self,
                200,
                {
                    "ok": True,
                    "received": len(videos),
                    "confirmedCount": confirmed_count,
                    "confirmedBytes": confirmed_bytes,
                    "results": results,
                },
            )
        except Exception as exc:  # noqa: BLE001 - API should return JSON errors.
            response_json(self, 500, {"ok": False, "error": str(exc)})

    def log_message(self, fmt: str, *args: Any) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"depurar-android-api listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
