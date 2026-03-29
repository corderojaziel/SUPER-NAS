#!/usr/bin/env python3
"""
immich-video-playback-resolver.py

Decide qué debe entregar el portal cuando el usuario pide reproducir un video:
  - Si ya existe la versión ligera en /var/lib/immich/cache, servirla.
  - Si el original ya es lo bastante ligero, dejar un enlace ligero en cache.
  - Si todavía no existe y sigue pesado, servir el MP4 genérico.

El script valida la sesión del usuario reutilizando las cookies o el header
Authorization del request original contra la API local de Immich.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterable, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "2284"))
IMMICH_API_BASE = os.environ.get("IMMICH_API_BASE", "http://127.0.0.1:2283").rstrip("/")
UPLOAD_PREFIX = os.environ.get("UPLOAD_PREFIX", "/usr/src/app/upload/")
UPLOAD_HOST_ROOT = os.path.abspath(
    os.environ.get("UPLOAD_HOST_ROOT", "/mnt/storage-main/photos")
)
IMMICH_LOCAL_ROOT = os.path.abspath(
    os.environ.get("IMMICH_LOCAL_ROOT", "/var/lib/immich")
)
CACHE_ROOT = os.path.abspath(os.environ.get("CACHE_ROOT", "/var/lib/immich/cache"))
PLACEHOLDER_LANDSCAPE_URI = os.environ.get(
    "PLACEHOLDER_LANDSCAPE_URI", "/__static/video-processing.mp4"
)
PLACEHOLDER_PORTRAIT_URI = os.environ.get(
    "PLACEHOLDER_PORTRAIT_URI", "/__static/video-processing-portrait.mp4"
)
PLACEHOLDER_DAMAGED_LANDSCAPE_URI = os.environ.get(
    "PLACEHOLDER_DAMAGED_LANDSCAPE_URI", "/__static/video-damaged.mp4"
)
PLACEHOLDER_DAMAGED_PORTRAIT_URI = os.environ.get(
    "PLACEHOLDER_DAMAGED_PORTRAIT_URI", "/__static/video-damaged-portrait.mp4"
)
PLACEHOLDER_MISSING_LANDSCAPE_URI = os.environ.get(
    "PLACEHOLDER_MISSING_LANDSCAPE_URI", "/__static/video-missing.mp4"
)
PLACEHOLDER_MISSING_PORTRAIT_URI = os.environ.get(
    "PLACEHOLDER_MISSING_PORTRAIT_URI", "/__static/video-missing-portrait.mp4"
)
PLACEHOLDER_ERROR_LANDSCAPE_URI = os.environ.get(
    "PLACEHOLDER_ERROR_LANDSCAPE_URI", "/__static/video-error.mp4"
)
PLACEHOLDER_ERROR_PORTRAIT_URI = os.environ.get(
    "PLACEHOLDER_ERROR_PORTRAIT_URI", "/__static/video-error-portrait.mp4"
)
DIRECT_PLAY_INTERNAL_PREFIX = os.environ.get(
    "DIRECT_PLAY_INTERNAL_PREFIX", "/__immich-direct/"
)
CACHE_INTERNAL_PREFIX = os.environ.get("CACHE_INTERNAL_PREFIX", "/__cache-video/")
try:
    VIDEO_STREAM_MAX_MB_PER_MIN = float(
        os.environ.get("VIDEO_STREAM_MAX_MB_PER_MIN", "40")
    )
except ValueError:
    VIDEO_STREAM_MAX_MB_PER_MIN = 40.0
try:
    VIDEO_PLAYBACK_BROWSER_CACHE_SEC = int(
        os.environ.get("VIDEO_PLAYBACK_BROWSER_CACHE_SEC", "300")
    )
except ValueError:
    VIDEO_PLAYBACK_BROWSER_CACHE_SEC = 300
VIDEO_PROBE_BIN = os.environ.get("VIDEO_PROBE_BIN", "ffprobe")
try:
    VIDEO_PROBE_TIMEOUT_SEC = float(os.environ.get("VIDEO_PROBE_TIMEOUT_SEC", "3"))
except ValueError:
    VIDEO_PROBE_TIMEOUT_SEC = 3.0
try:
    VIDEO_CORRUPT_CACHE_TTL_SEC = float(
        os.environ.get("VIDEO_CORRUPT_CACHE_TTL_SEC", "300")
    )
except ValueError:
    VIDEO_CORRUPT_CACHE_TTL_SEC = 300.0
DAMAGED_LIST_PATH = os.path.abspath(
    os.environ.get("DAMAGED_VIDEO_LIST_PATH", "/var/lib/nas-health/damaged-videos.txt")
)
ASSET_PLAYBACK_RE = re.compile(r"^/api/assets/([0-9a-f-]+)/video/playback$")
CORRUPT_CACHE: dict[str, Tuple[float, bool]] = {}


def rel_mp4_for_original(original_path: str) -> str:
    if not original_path.startswith(UPLOAD_PREFIX):
        raise ValueError(f"originalPath fuera del upload esperado: {original_path}")

    rel_path = original_path[len(UPLOAD_PREFIX):].lstrip("/")
    return os.path.splitext(rel_path)[0] + ".mp4"


def safe_join(root: str, rel_path: str) -> str:
    candidate = os.path.abspath(os.path.join(root, rel_path))
    if candidate != root and not candidate.startswith(root + os.sep):
        raise ValueError(f"ruta fuera de root permitido: {candidate}")
    return candidate


def rel_parts(rel_mp4: str) -> Tuple[str, str, str, str] | None:
    stripped = rel_mp4[len("upload/") :] if rel_mp4.startswith("upload/") else rel_mp4
    parts = stripped.split("/")
    if len(parts) < 4:
        return None

    asset_owner = parts[-4]
    aa = parts[-3]
    bb = parts[-2]
    uuid = os.path.splitext(parts[-1])[0]
    if not asset_owner or not aa or not bb or not uuid:
        return None

    return asset_owner, aa, bb, uuid


def resolve_existing_variant(root: str, rel_variant: str) -> Tuple[str, str] | None:
    candidate = safe_join(root, rel_variant)
    if os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
        return rel_variant, candidate

    base, ext = os.path.splitext(rel_variant)
    if ext.lower() == ".mp4":
        for alt_ext in (".MP4", ".Mp4", ".mP4"):
            alt_rel = base + alt_ext
            alt_candidate = safe_join(root, alt_rel)
            if os.path.isfile(alt_candidate) and os.path.getsize(alt_candidate) > 0:
                return alt_rel, alt_candidate

    return None


def iter_rel_variants(rel_mp4: str, variant_order: Iterable[str]) -> Iterable[str]:
    seen: set[str] = set()
    stripped = rel_mp4[len("upload/") :] if rel_mp4.startswith("upload/") else rel_mp4
    parts = rel_parts(rel_mp4)
    for variant in variant_order:
        rel_variant = ""
        if variant == "rel":
            rel_variant = rel_mp4
        elif variant == "stripped":
            rel_variant = stripped
        elif variant == "underscored":
            rel_variant = stripped.replace("/", "_")
        elif variant == "legacy_asset_prefix" and parts:
            _, aa, bb, uuid = parts
            rel_variant = f"asset_{aa}_{bb}_{uuid}.mp4"
        elif variant == "legacy_pair_uuid" and parts:
            _, aa, bb, uuid = parts
            rel_variant = f"{aa}_{bb}_{uuid}.mp4"
        elif variant == "flat":
            rel_variant = os.path.basename(rel_mp4)
        if rel_variant and rel_variant not in seen:
            seen.add(rel_variant)
            yield rel_variant


def safe_cache_path(original_path: str) -> Tuple[str, str, str]:
    rel_mp4 = rel_mp4_for_original(original_path)

    search_locations = [
        (
            CACHE_INTERNAL_PREFIX,
            CACHE_ROOT,
            (
                "rel",
                "underscored",
                "flat",
                "legacy_asset_prefix",
                "legacy_pair_uuid",
                "stripped",
            ),
        ),
    ]

    for internal_prefix, root, variant_order in search_locations:
        for rel_variant in iter_rel_variants(rel_mp4, variant_order):
            resolved = resolve_existing_variant(root, rel_variant)
            if resolved:
                found_rel_variant, candidate = resolved
                return internal_prefix, found_rel_variant, candidate

    return CACHE_INTERNAL_PREFIX, rel_mp4, safe_join(CACHE_ROOT, rel_mp4)


def safe_original_host_path(original_path: str) -> str:
    if not original_path.startswith(UPLOAD_PREFIX):
        raise ValueError(f"originalPath fuera del upload esperado: {original_path}")

    rel_path = original_path[len(UPLOAD_PREFIX):].lstrip("/")
    base_root = UPLOAD_HOST_ROOT
    if rel_path.startswith("encoded-video/") or rel_path.startswith("thumbs/"):
        base_root = IMMICH_LOCAL_ROOT

    candidate = os.path.abspath(os.path.join(base_root, rel_path))
    if candidate != base_root and not candidate.startswith(base_root + os.sep):
        raise ValueError(f"ruta fuera de root permitido ({base_root}): {candidate}")
    return candidate


def parse_duration_seconds(value: str | None) -> float:
    if not value:
        return 0.0

    try:
        hours, minutes, seconds = str(value).split(":")
        return (int(hours) * 3600) + (int(minutes) * 60) + float(seconds)
    except (TypeError, ValueError):
        return 0.0


def get_asset_size_bytes(asset: dict) -> int:
    exif_info = asset.get("exifInfo") or {}
    for value in (exif_info.get("fileSizeInByte"), asset.get("size")):
        try:
            size = int(value or 0)
        except (TypeError, ValueError):
            size = 0
        if size > 0:
            return size
    return 0


def get_allowed_bytes(duration_seconds: float) -> float:
    if duration_seconds <= 0:
        return 0.0
    return (duration_seconds * VIDEO_STREAM_MAX_MB_PER_MIN * 1_000_000) / 60.0


def is_missing_asset_response(status: int, payload: dict) -> bool:
    if status != 400:
        return False

    message = str(payload.get("message") or "").lower()
    error = str(payload.get("error") or "").lower()
    combined = f"{message} {error}"
    return "not found" in combined or "asset.read" in combined


def ensure_direct_cache_link(original_path: str, cache_path: str) -> bool:
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    try:
        original_size = os.path.getsize(original_path)
    except OSError:
        return False

    if os.path.islink(cache_path):
        if os.readlink(cache_path) == original_path:
            return True
        os.unlink(cache_path)
    elif os.path.isfile(cache_path):
        try:
            if os.path.getsize(cache_path) == original_size:
                return True
        except OSError:
            pass
        return False
    elif os.path.exists(cache_path):
        return False

    try:
        os.symlink(original_path, cache_path)
        return os.path.islink(cache_path)
    except OSError:
        pass

    tmp_copy = f"{cache_path}.tmp-copy"
    try:
        shutil.copy2(original_path, tmp_copy)
        os.replace(tmp_copy, cache_path)
        return os.path.isfile(cache_path) and os.path.getsize(cache_path) == original_size
    except OSError:
        try:
            if os.path.exists(tmp_copy) or os.path.islink(tmp_copy):
                os.unlink(tmp_copy)
        except OSError:
            pass
        return False


def has_video_stream(path: str) -> bool:
    cmd = [
        VIDEO_PROBE_BIN,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "default=nokey=1:noprint_wrappers=1",
        path,
    ]
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=max(VIDEO_PROBE_TIMEOUT_SEC, 0.5),
        )
    except (OSError, subprocess.TimeoutExpired):
        return False

    return result.returncode == 0 and bool((result.stdout or "").strip())


def is_probably_corrupt(path: str) -> bool:
    now = time.time()
    cached = CORRUPT_CACHE.get(path)
    if cached and (now - cached[0]) < VIDEO_CORRUPT_CACHE_TTL_SEC:
        return cached[1]

    corrupt = not has_video_stream(path)
    CORRUPT_CACHE[path] = (now, corrupt)
    return corrupt


def is_marked_damaged(path: str) -> bool:
    if not os.path.isfile(DAMAGED_LIST_PATH):
        return False
    try:
        with open(DAMAGED_LIST_PATH, "r", encoding="utf-8") as fh:
            markers = {line.strip() for line in fh if line.strip()}
    except OSError:
        return False
    basename = os.path.basename(path)
    return path in markers or basename in markers


class PlaybackResolverHandler(BaseHTTPRequestHandler):
    server_version = "ImmichPlaybackResolver/1.0"

    def do_GET(self) -> None:  # noqa: N802
        self.handle_request()

    def do_HEAD(self) -> None:  # noqa: N802
        self.handle_request()

    def handle_request(self) -> None:
        parsed = urlparse(self.path)
        match = ASSET_PLAYBACK_RE.match(parsed.path)
        if not match:
            self.send_error(404, "Ruta no soportada")
            return

        asset_id = match.group(1)
        status, asset = self.fetch_asset(asset_id)

        missing_asset = is_missing_asset_response(status, asset)
        if status in (401, 403, 404) or missing_asset:
            self.send_response(404 if missing_asset else status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            return

        if status != 200:
            self.send_response(200)
            self.send_header("X-Accel-Redirect", PLACEHOLDER_ERROR_LANDSCAPE_URI)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Video-Source", "placeholder-error")
            self.end_headers()
            return

        if asset.get("type") != "VIDEO" or asset.get("isTrashed"):
            self.send_error(404, "Asset no reproducible")
            return

        original_path = asset.get("originalPath") or ""
        try:
            cache_internal_prefix, rel_mp4, cache_path = safe_cache_path(original_path)
            host_original_path = safe_original_host_path(original_path)
        except ValueError as exc:
            self.send_error(500, str(exc))
            return

        if self.can_stream_original(asset, host_original_path):
            if ensure_direct_cache_link(host_original_path, cache_path):
                internal_uri = cache_internal_prefix + quote(rel_mp4, safe="/")
                source = "direct-cache-link"
            elif os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
                internal_uri = cache_internal_prefix + quote(rel_mp4, safe="/")
                source = "optimized-cache-fallback"
            else:
                internal_uri = DIRECT_PLAY_INTERNAL_PREFIX + parsed.path.lstrip("/")
                source = "original-direct"
            cache_control = (
                f"private, max-age={VIDEO_PLAYBACK_BROWSER_CACHE_SEC}, no-transform"
            )
        elif os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
            internal_uri = cache_internal_prefix + quote(rel_mp4, safe="/")
            source = "optimized-cache"
            cache_control = (
                f"private, max-age={VIDEO_PLAYBACK_BROWSER_CACHE_SEC}, no-transform"
            )
        else:
            if not os.path.isfile(host_original_path):
                reason = "missing"
            elif is_marked_damaged(host_original_path):
                reason = "damaged"
            elif is_probably_corrupt(host_original_path):
                reason = "damaged"
            else:
                reason = "processing"

            internal_uri = self.placeholder_for_reason(asset, reason)
            source = f"placeholder-{reason}"
            cache_control = "no-store"

        self.send_response(200)
        self.send_header("X-Accel-Redirect", internal_uri)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Cache-Control", cache_control)
        self.send_header("X-Video-Source", source)
        self.end_headers()

    def placeholder_for_reason(self, asset: dict, reason: str) -> str:
        width = int(asset.get("width") or 0)
        height = int(asset.get("height") or 0)
        # Para celular conviene priorizar la variante vertical cuando el asset
        # no es claramente horizontal. Eso cubre videos verticales y cuadrados.
        is_portrait = width > 0 and height > 0 and height >= width
        if reason == "missing":
            return PLACEHOLDER_MISSING_PORTRAIT_URI if is_portrait else PLACEHOLDER_MISSING_LANDSCAPE_URI
        if reason == "damaged":
            return PLACEHOLDER_DAMAGED_PORTRAIT_URI if is_portrait else PLACEHOLDER_DAMAGED_LANDSCAPE_URI
        if reason == "error":
            return PLACEHOLDER_ERROR_PORTRAIT_URI if is_portrait else PLACEHOLDER_ERROR_LANDSCAPE_URI
        return PLACEHOLDER_PORTRAIT_URI if is_portrait else PLACEHOLDER_LANDSCAPE_URI

    def can_stream_original(self, asset: dict, original_host_path: str) -> bool:
        if not os.path.isfile(original_host_path):
            return False
        if is_probably_corrupt(original_host_path):
            return False

        size_bytes = get_asset_size_bytes(asset)
        if size_bytes <= 0:
            size_bytes = os.path.getsize(original_host_path)
        duration_seconds = parse_duration_seconds(asset.get("duration"))
        if size_bytes <= 0 or duration_seconds <= 0:
            return False

        return size_bytes <= get_allowed_bytes(duration_seconds)

    def fetch_asset(self, asset_id: str) -> Tuple[int, dict]:
        request = Request(
            f"{IMMICH_API_BASE}/api/assets/{asset_id}",
            headers={"Accept": "application/json"},
        )

        cookie = self.headers.get("Cookie")
        if cookie:
            request.add_header("Cookie", cookie)

        authorization = self.headers.get("Authorization")
        if authorization:
            request.add_header("Authorization", authorization)
        x_api_key = self.headers.get("X-API-Key")
        if x_api_key:
            request.add_header("X-API-Key", x_api_key)

        try:
            with urlopen(request, timeout=10) as response:
                return response.status, json.load(response)
        except HTTPError as exc:
            try:
                payload = json.loads(exc.read().decode("utf-8") or "{}")
            except Exception:
                payload = {}
            return exc.code, payload
        except (URLError, TimeoutError, OSError, ConnectionError):
            return 502, {}
        except Exception:
            # Bajo carga (auditorias masivas) urllib puede propagar errores
            # de socket sin envolver. Mejor degradar a 502 controlado.
            return 502, {}

    def log_message(self, fmt: str, *args: object) -> None:
        print(
            "%s - - [%s] %s"
            % (self.address_string(), self.log_date_time_string(), fmt % args),
            flush=True,
        )


def main() -> None:
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), PlaybackResolverHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
