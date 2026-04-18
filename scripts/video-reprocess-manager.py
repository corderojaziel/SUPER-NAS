#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


UPLOAD_PREFIX = "/usr/src/app/upload/"
UPLOAD_HOST_ROOT_DEFAULT = "/mnt/storage-main/photos"
IMMICH_LOCAL_ROOT_DEFAULT = "/var/lib/immich"
CACHE_ROOT_DEFAULT = "/var/lib/immich/cache"
OUTPUT_DIR_DEFAULT = "/var/lib/nas-health/reprocess"
ATTEMPTS_DB_DEFAULT = "/var/lib/nas-retry/video-reprocess-light.attempts.tsv"
MANUAL_QUEUE_DEFAULT = "/var/lib/nas-retry/video-reprocess-manual.tsv"
RUN_REPORT_LATEST = "run-light-latest.csv"
LIGHT_LATEST = "light-latest.csv"
HEAVY_LATEST = "heavy-latest.csv"
BROKEN_LATEST = "broken-latest.csv"
EXCLUDED_LATEST = "excluded-latest.csv"
SUMMARY_LATEST = "summary-latest.json"
DIRECT_COMPAT_CACHE: dict[str, bool] = {}

try:
    PROBE_TIMEOUT_DEFAULT = float(os.environ.get("VIDEO_PROBE_TIMEOUT_SEC", "3"))
except ValueError:
    PROBE_TIMEOUT_DEFAULT = 3.0
try:
    DIRECT_COMPAT_LEVEL_DEFAULT = int(os.environ.get("VIDEO_DIRECT_COMPAT_LEVEL", "41"))
except ValueError:
    DIRECT_COMPAT_LEVEL_DEFAULT = 41
try:
    DIRECT_COMPAT_MAX_LONG_EDGE_DEFAULT = int(
        os.environ.get("VIDEO_DIRECT_COMPAT_MAX_LONG_EDGE", "1920")
    )
except ValueError:
    DIRECT_COMPAT_MAX_LONG_EDGE_DEFAULT = 1920
try:
    DIRECT_COMPAT_MAX_FPS_DEFAULT = float(
        os.environ.get("VIDEO_DIRECT_COMPAT_MAX_FPS", "60")
    )
except ValueError:
    DIRECT_COMPAT_MAX_FPS_DEFAULT = 60.0


@dataclass
class Row:
    asset_id: str
    original_path: str
    duration_raw: str
    size_bytes: int
    duration_sec: float
    mb_per_min: float
    needs_cache: bool
    cache_path: str
    source_path: str
    classify: str
    reason: str
    width: int
    height: int
    is_motion: bool
    is_4k: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan and run video cache reprocess operations."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    common_plan = argparse.ArgumentParser(add_help=False)
    common_plan.add_argument("--cache-root", default=CACHE_ROOT_DEFAULT)
    common_plan.add_argument("--upload-host-root", default=UPLOAD_HOST_ROOT_DEFAULT)
    common_plan.add_argument("--immich-local-root", default=IMMICH_LOCAL_ROOT_DEFAULT)
    common_plan.add_argument("--output-dir", default=OUTPUT_DIR_DEFAULT)
    common_plan.add_argument("--max-mb-min", type=float, default=40.0)
    common_plan.add_argument("--local-max-mb", type=float, default=220.0)
    common_plan.add_argument("--local-max-duration-sec", type=float, default=150.0)
    common_plan.add_argument("--local-max-mb-min", type=float, default=120.0)
    common_plan.add_argument(
        "--probe-bin",
        default=os.environ.get("VIDEO_PROBE_BIN", "ffprobe"),
    )
    common_plan.add_argument(
        "--probe-timeout-sec",
        type=float,
        default=PROBE_TIMEOUT_DEFAULT,
    )
    common_plan.add_argument(
        "--direct-compat-video-codec",
        default=os.environ.get("VIDEO_DIRECT_COMPAT_VIDEO_CODEC", "h264"),
    )
    common_plan.add_argument(
        "--direct-compat-pix-fmt",
        default=os.environ.get("VIDEO_DIRECT_COMPAT_PIX_FMT", "yuv420p"),
    )
    common_plan.add_argument(
        "--direct-compat-level",
        type=int,
        default=DIRECT_COMPAT_LEVEL_DEFAULT,
    )
    common_plan.add_argument(
        "--direct-compat-max-long-edge",
        type=int,
        default=DIRECT_COMPAT_MAX_LONG_EDGE_DEFAULT,
    )
    common_plan.add_argument(
        "--direct-compat-max-fps",
        type=float,
        default=DIRECT_COMPAT_MAX_FPS_DEFAULT,
    )
    common_plan.add_argument(
        "--skip-motion-clips",
        type=int,
        default=int(os.environ.get("VIDEO_REPROCESS_SKIP_MOTION_CLIPS", "1")),
        help="1=excluir clips motion photo del reproceso; 0=permitir.",
    )
    common_plan.add_argument(
        "--skip-real-4k",
        type=int,
        default=int(os.environ.get("VIDEO_REPROCESS_SKIP_REAL_4K", "0")),
        help="1=excluir videos 4K reales del reproceso; 0=permitir.",
    )

    plan = sub.add_parser("plan", parents=[common_plan], help="Generate input CSVs.")
    plan.add_argument("--print-summary", action="store_true")

    run = sub.add_parser("run", parents=[common_plan], help="Run conversion from CSV.")
    run.add_argument("--class", dest="run_class", choices=["light", "heavy"], default="light")
    run.add_argument("--input-csv", default="")
    run.add_argument("--ffmpeg-bin", default="ffmpeg")
    run.add_argument("--limit", type=int, default=0)
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("--notify", action="store_true")
    run.add_argument("--attempts-db", default=ATTEMPTS_DB_DEFAULT)
    run.add_argument("--manual-queue", default=MANUAL_QUEUE_DEFAULT)
    run.add_argument("--max-attempts", type=int, default=3)
    run.add_argument("--audio-bitrate-k", type=int, default=128)
    run.add_argument("--target-maxrate-k", type=int, default=5200)
    run.add_argument(
        "--max-long-edge",
        type=int,
        default=int(os.environ.get("VIDEO_OPTIMIZE_MAX_LONG_EDGE", "1920")),
        help="Lado máximo del video de salida para compatibilidad (0 desactiva).",
    )
    run.add_argument(
        "--video-level",
        default=os.environ.get("VIDEO_OPTIMIZE_VIDEO_LEVEL", "4.1"),
        help="Nivel H.264 de salida para clientes móviles.",
    )
    run.add_argument(
        "--max-fps",
        type=float,
        default=float(os.environ.get("VIDEO_OPTIMIZE_MAX_FPS", "30")),
        help="FPS máximo del cache de salida para compatibilidad móvil (0 desactiva).",
    )
    run.add_argument(
        "--allow-remux-copy",
        type=int,
        default=-1,
        help=(
            "Controla si se permite remux (-c copy) antes de transcodificar. "
            "1=permitir, 0=forzar transcode, -1=auto (light=1, heavy=0)."
        ),
    )

    return parser.parse_args()


def run_db_query() -> list[tuple[str, str, str, str, str, str, str]]:
    sql = (
        "select a.id, a.\"originalPath\", coalesce(a.duration,''), "
        "coalesce(e.\"fileSizeInByte\",0)::text, "
        "coalesce(a.width,0)::text, coalesce(a.height,0)::text, "
        "case when exists ("
        "  select 1 from asset i "
        "  where i.\"livePhotoVideoId\"=a.id "
        "    and i.type='IMAGE' and i.status='active' and i.\"deletedAt\" is null"
        ") then '1' else '0' end "
        "from asset a "
        "left join asset_exif e on e.\"assetId\"=a.id "
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
        "-F",
        "|",
        "-c",
        sql,
    ]
    out = subprocess.check_output(cmd, cwd="/opt/immich-app", text=True)
    rows: list[tuple[str, str, str, str, str, str, str]] = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) == 7:
            rows.append((parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]))
    return rows


def parse_duration_seconds(value: str) -> float:
    if not value:
        return 0.0
    try:
        h, m, s = value.split(":")
        return int(h) * 3600 + int(m) * 60 + float(s)
    except Exception:
        return 0.0


def parse_int(value: str, default: int = 0) -> int:
    try:
        return int(value or default)
    except Exception:
        return default


def parse_frame_rate(value: str | None) -> float:
    if not value:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    try:
        if "/" in text:
            num, den = text.split("/", 1)
            den_v = float(den)
            if den_v == 0:
                return 0.0
            return float(num) / den_v
        return float(text)
    except Exception:
        return 0.0


def is_direct_compatible_source(
    source_path: str,
    *,
    probe_bin: str,
    probe_timeout_sec: float,
    video_codec: str,
    pix_fmt: str,
    max_level: int,
    max_long_edge: int,
    max_fps: float,
) -> bool:
    cached = DIRECT_COMPAT_CACHE.get(source_path)
    if cached is not None:
        return cached

    cmd = [
        probe_bin,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_type,codec_name,pix_fmt,level,width,height,avg_frame_rate,r_frame_rate",
        "-of",
        "json",
        source_path,
    ]
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=max(probe_timeout_sec, 0.5),
        )
    except (OSError, subprocess.TimeoutExpired):
        DIRECT_COMPAT_CACHE[source_path] = False
        return False

    if result.returncode != 0:
        DIRECT_COMPAT_CACHE[source_path] = False
        return False

    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        DIRECT_COMPAT_CACHE[source_path] = False
        return False

    streams = payload.get("streams") if isinstance(payload, dict) else None
    if not isinstance(streams, list) or not streams:
        DIRECT_COMPAT_CACHE[source_path] = False
        return False

    stream = None
    for item in streams:
        if str(item.get("codec_type") or "").lower() == "video":
            stream = item
            break
    if stream is None:
        stream = streams[0]

    codec = str(stream.get("codec_name") or "").lower()
    stream_pix_fmt = str(stream.get("pix_fmt") or "").lower()
    width = parse_int(str(stream.get("width") or "0"), 0)
    height = parse_int(str(stream.get("height") or "0"), 0)
    level = parse_int(str(stream.get("level") or "0"), 0)
    fps = parse_frame_rate(stream.get("avg_frame_rate")) or parse_frame_rate(
        stream.get("r_frame_rate")
    )

    compatible = True
    video_codec = (video_codec or "").strip().lower()
    pix_fmt = (pix_fmt or "").strip().lower()
    if video_codec and codec != video_codec:
        compatible = False
    if pix_fmt and stream_pix_fmt != pix_fmt:
        compatible = False
    if max_level > 0 and level > max_level:
        compatible = False
    if max_long_edge > 0 and max(width, height) > max_long_edge:
        compatible = False
    if max_fps > 0 and fps > max_fps:
        compatible = False

    DIRECT_COMPAT_CACHE[source_path] = compatible
    return compatible


def is_real_4k(width: int, height: int) -> bool:
    return (width, height) in {
        (3840, 2160),
        (2160, 3840),
        (4096, 2160),
        (2160, 4096),
    }


def rel_mp4_for_original(original_path: str) -> str:
    rel = original_path[len(UPLOAD_PREFIX):].lstrip("/")
    return str(Path(rel).with_suffix(".mp4")).replace("\\", "/")


def rel_parts(rel_mp4: str) -> tuple[str, str, str, str] | None:
    stripped = rel_mp4[len("upload/") :] if rel_mp4.startswith("upload/") else rel_mp4
    parts = stripped.split("/")
    if len(parts) < 4:
        return None
    owner = parts[-4]
    aa = parts[-3]
    bb = parts[-2]
    uuid = Path(parts[-1]).stem
    if not owner or not aa or not bb or not uuid:
        return None
    return owner, aa, bb, uuid


def safe_join(root: Path, rel_path: str) -> Path:
    root_abs = root.resolve()
    candidate = (root / rel_path).resolve()
    if candidate != root_abs and root_abs not in candidate.parents:
        raise ValueError(f"path outside root: {candidate}")
    return candidate


def resolve_existing_variant(root: Path, rel_variant: str) -> Path | None:
    try:
        candidate = safe_join(root, rel_variant)
    except ValueError:
        return None
    if candidate.is_file() and candidate.stat().st_size > 0:
        return candidate

    base, ext = os.path.splitext(rel_variant)
    if ext.lower() == ".mp4":
        for alt_ext in (".MP4", ".Mp4", ".mP4"):
            alt = base + alt_ext
            try:
                alt_candidate = safe_join(root, alt)
            except ValueError:
                continue
            if alt_candidate.is_file() and alt_candidate.stat().st_size > 0:
                return alt_candidate
    return None


def iter_rel_variants(rel_mp4: str) -> Iterable[str]:
    stripped = rel_mp4[len("upload/") :] if rel_mp4.startswith("upload/") else rel_mp4
    parts = rel_parts(rel_mp4)
    seen: set[str] = set()

    def push(value: str) -> None:
        if value and value not in seen:
            seen.add(value)
            yield_value.append(value)

    yield_value: list[str] = []
    push(rel_mp4)
    push(stripped.replace("/", "_"))
    push(os.path.basename(rel_mp4))
    if parts:
        _, aa, bb, uuid = parts
        push(f"asset_{aa}_{bb}_{uuid}.mp4")
        push(f"{aa}_{bb}_{uuid}.mp4")
    push(stripped)
    return yield_value


def find_cache_path(rel_mp4: str, cache_root: Path) -> str:
    variants = list(iter_rel_variants(rel_mp4))
    for rel in variants:
        found = resolve_existing_variant(cache_root, rel)
        if found:
            return str(found)
    return ""


def source_host_path(
    original_path: str,
    upload_host_root: Path,
    immich_local_root: Path,
) -> str:
    rel = original_path[len(UPLOAD_PREFIX):].lstrip("/")
    base = upload_host_root
    if rel.startswith("encoded-video/") or rel.startswith("thumbs/"):
        base = immich_local_root
    return str((base / rel).resolve())


def classify_row(
    asset_id: str,
    original_path: str,
    duration_raw: str,
    size_raw: str,
    width_raw: str,
    height_raw: str,
    motion_raw: str,
    *,
    cache_root: Path,
    upload_host_root: Path,
    immich_local_root: Path,
    max_mb_min: float,
    local_max_mb: float,
    local_max_duration_sec: float,
    local_max_mb_min: float,
    skip_motion_clips: bool,
    skip_real_4k: bool,
    probe_bin: str,
    probe_timeout_sec: float,
    direct_compat_video_codec: str,
    direct_compat_pix_fmt: str,
    direct_compat_level: int,
    direct_compat_max_long_edge: int,
    direct_compat_max_fps: float,
) -> Row | None:
    if not original_path.startswith(UPLOAD_PREFIX):
        return None

    duration_sec = parse_duration_seconds(duration_raw)
    try:
        size_bytes = int(size_raw or "0")
    except Exception:
        size_bytes = 0
    width = parse_int(width_raw, 0)
    height = parse_int(height_raw, 0)
    is_motion = str(motion_raw).strip() in {"1", "true", "TRUE", "yes", "YES"}
    video_is_4k = is_real_4k(width, height)

    mb_per_min = 0.0
    if duration_sec > 0 and size_bytes > 0:
        mb_per_min = (size_bytes / 1_000_000.0) / (duration_sec / 60.0)

    needs_cache = mb_per_min > max_mb_min if mb_per_min > 0 else True
    rel_mp4 = rel_mp4_for_original(original_path)
    cache_path = find_cache_path(rel_mp4, cache_root)
    source_path = source_host_path(original_path, upload_host_root, immich_local_root)

    if skip_motion_clips and is_motion:
        return Row(
            asset_id=asset_id,
            original_path=original_path,
            duration_raw=duration_raw,
            size_bytes=size_bytes,
            duration_sec=duration_sec,
            mb_per_min=mb_per_min,
            needs_cache=False,
            cache_path=cache_path,
            source_path=source_path,
            classify="excluded_motion",
            reason="policy_skip_motion",
            width=width,
            height=height,
            is_motion=is_motion,
            is_4k=video_is_4k,
        )

    if skip_real_4k and video_is_4k:
        return Row(
            asset_id=asset_id,
            original_path=original_path,
            duration_raw=duration_raw,
            size_bytes=size_bytes,
            duration_sec=duration_sec,
            mb_per_min=mb_per_min,
            needs_cache=False,
            cache_path=cache_path,
            source_path=source_path,
            classify="excluded_4k",
            reason="policy_skip_real_4k",
            width=width,
            height=height,
            is_motion=is_motion,
            is_4k=video_is_4k,
        )

    if cache_path:
        return Row(
            asset_id=asset_id,
            original_path=original_path,
            duration_raw=duration_raw,
            size_bytes=size_bytes,
            duration_sec=duration_sec,
            mb_per_min=mb_per_min,
            needs_cache=True,
            cache_path=cache_path,
            source_path=source_path,
            classify="already_cached",
            reason="cache_exists",
            width=width,
            height=height,
            is_motion=is_motion,
            is_4k=video_is_4k,
        )

    src = Path(source_path)
    if not src.is_file() or src.stat().st_size <= 0:
        return Row(
            asset_id=asset_id,
            original_path=original_path,
            duration_raw=duration_raw,
            size_bytes=size_bytes,
            duration_sec=duration_sec,
            mb_per_min=mb_per_min,
            needs_cache=True,
            cache_path=str((cache_root / rel_mp4).resolve()),
            source_path=source_path,
            classify="broken_source",
            reason="source_missing_or_empty",
            width=width,
            height=height,
            is_motion=is_motion,
            is_4k=video_is_4k,
        )

    if not needs_cache:
        if is_direct_compatible_source(
            source_path,
            probe_bin=probe_bin,
            probe_timeout_sec=probe_timeout_sec,
            video_codec=direct_compat_video_codec,
            pix_fmt=direct_compat_pix_fmt,
            max_level=direct_compat_level,
            max_long_edge=direct_compat_max_long_edge,
            max_fps=direct_compat_max_fps,
        ):
            return Row(
                asset_id=asset_id,
                original_path=original_path,
                duration_raw=duration_raw,
                size_bytes=size_bytes,
                duration_sec=duration_sec,
                mb_per_min=mb_per_min,
                needs_cache=False,
                cache_path=cache_path,
                source_path=source_path,
                classify="direct_ok",
                reason="light_video_direct_compatible",
                width=width,
                height=height,
                is_motion=is_motion,
                is_4k=video_is_4k,
            )
        needs_cache = True

    src_mb = src.stat().st_size / (1024 * 1024)
    local_candidate = (
        src_mb <= local_max_mb
        and (duration_sec <= local_max_duration_sec if duration_sec > 0 else False)
        and (mb_per_min <= local_max_mb_min if mb_per_min > 0 else False)
    )

    return Row(
        asset_id=asset_id,
        original_path=original_path,
        duration_raw=duration_raw,
        size_bytes=size_bytes,
        duration_sec=duration_sec,
        mb_per_min=mb_per_min,
        needs_cache=True,
        cache_path=str((cache_root / rel_mp4).resolve()),
        source_path=source_path,
        classify="light_candidate" if local_candidate else "manual_heavy",
        reason="local_nightly_retry" if local_candidate else "manual_gpu_recommended",
        width=width,
        height=height,
        is_motion=is_motion,
        is_4k=video_is_4k,
    )


def write_csv(path: Path, rows: list[Row]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "asset_id",
                "original_path",
                "source_path",
                "dest_cache_path",
                "size_bytes",
                "duration_sec",
                "mb_per_min",
                "needs_cache",
                "width",
                "height",
                "is_motion",
                "is_4k",
                "class",
                "reason",
            ]
        )
        for r in rows:
            writer.writerow(
                [
                    r.asset_id,
                    r.original_path,
                    r.source_path,
                    r.cache_path,
                    r.size_bytes,
                    f"{r.duration_sec:.3f}",
                    f"{r.mb_per_min:.3f}",
                    "yes" if r.needs_cache else "no",
                    r.width,
                    r.height,
                    "yes" if r.is_motion else "no",
                    "yes" if r.is_4k else "no",
                    r.classify,
                    r.reason,
                ]
            )


def write_latest_copy(src: Path, latest_name: str, out_dir: Path) -> Path:
    latest = out_dir / latest_name
    shutil.copy2(src, latest)
    return latest


def run_plan(args: argparse.Namespace) -> int:
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    cache_root = Path(args.cache_root)
    upload_host_root = Path(args.upload_host_root)
    immich_local_root = Path(args.immich_local_root)

    rows_db = run_db_query()
    direct_ok: list[Row] = []
    already_cached: list[Row] = []
    light_candidates: list[Row] = []
    heavy_manual: list[Row] = []
    broken_sources: list[Row] = []
    excluded_policy: list[Row] = []
    invalid_original = 0

    for asset_id, original_path, duration_raw, size_raw, width_raw, height_raw, motion_raw in rows_db:
        row = classify_row(
            asset_id,
            original_path,
            duration_raw,
            size_raw,
            width_raw,
            height_raw,
            motion_raw,
            cache_root=cache_root,
            upload_host_root=upload_host_root,
            immich_local_root=immich_local_root,
            max_mb_min=args.max_mb_min,
            local_max_mb=args.local_max_mb,
            local_max_duration_sec=args.local_max_duration_sec,
            local_max_mb_min=args.local_max_mb_min,
            skip_motion_clips=bool(args.skip_motion_clips),
            skip_real_4k=bool(args.skip_real_4k),
            probe_bin=args.probe_bin,
            probe_timeout_sec=args.probe_timeout_sec,
            direct_compat_video_codec=args.direct_compat_video_codec,
            direct_compat_pix_fmt=args.direct_compat_pix_fmt,
            direct_compat_level=args.direct_compat_level,
            direct_compat_max_long_edge=args.direct_compat_max_long_edge,
            direct_compat_max_fps=args.direct_compat_max_fps,
        )
        if row is None:
            invalid_original += 1
            continue
        if row.classify == "direct_ok":
            direct_ok.append(row)
        elif row.classify in {"excluded_motion", "excluded_4k"}:
            excluded_policy.append(row)
        elif row.classify == "already_cached":
            already_cached.append(row)
        elif row.classify == "light_candidate":
            light_candidates.append(row)
        elif row.classify == "manual_heavy":
            heavy_manual.append(row)
        elif row.classify == "broken_source":
            broken_sources.append(row)

    light_file = out_dir / f"reprocess-light-{ts}.csv"
    heavy_file = out_dir / f"reprocess-heavy-{ts}.csv"
    broken_file = out_dir / f"reprocess-broken-{ts}.csv"
    excluded_file = out_dir / f"reprocess-excluded-{ts}.csv"
    summary_file = out_dir / f"reprocess-summary-{ts}.json"

    write_csv(light_file, light_candidates)
    write_csv(heavy_file, heavy_manual)
    write_csv(broken_file, broken_sources)
    write_csv(excluded_file, excluded_policy)
    excluded_motion_count = sum(1 for r in excluded_policy if r.classify == "excluded_motion")
    excluded_4k_count = sum(1 for r in excluded_policy if r.classify == "excluded_4k")

    summary = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "total_videos": len(rows_db),
        "invalid_original": invalid_original,
        "direct_ok": len(direct_ok),
        "already_cached": len(already_cached),
        "light_candidates": len(light_candidates),
        "heavy_manual": len(heavy_manual),
        "broken_sources": len(broken_sources),
        "excluded_policy": len(excluded_policy),
        "excluded_motion": excluded_motion_count,
        "excluded_4k": excluded_4k_count,
        "skip_motion_clips": bool(args.skip_motion_clips),
        "skip_real_4k": bool(args.skip_real_4k),
        "max_mb_min": args.max_mb_min,
        "local_max_mb": args.local_max_mb,
        "local_max_duration_sec": args.local_max_duration_sec,
        "local_max_mb_min": args.local_max_mb_min,
        "files": {
            "light": str(light_file),
            "heavy": str(heavy_file),
            "broken": str(broken_file),
            "excluded": str(excluded_file),
        },
    }
    summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    write_latest_copy(light_file, LIGHT_LATEST, out_dir)
    write_latest_copy(heavy_file, HEAVY_LATEST, out_dir)
    write_latest_copy(broken_file, BROKEN_LATEST, out_dir)
    write_latest_copy(excluded_file, EXCLUDED_LATEST, out_dir)
    write_latest_copy(summary_file, SUMMARY_LATEST, out_dir)

    print(f"OUTPUT_DIR={out_dir}")
    print(f"SUMMARY_FILE={summary_file}")
    print(f"LIGHT_FILE={light_file}")
    print(f"HEAVY_FILE={heavy_file}")
    print(f"BROKEN_FILE={broken_file}")
    print(f"total_videos={summary['total_videos']}")
    print(f"direct_ok={summary['direct_ok']}")
    print(f"already_cached={summary['already_cached']}")
    print(f"excluded_policy={summary['excluded_policy']}")
    print(f"excluded_motion={summary['excluded_motion']}")
    print(f"excluded_4k={summary['excluded_4k']}")
    print(f"light_candidates={summary['light_candidates']}")
    print(f"heavy_manual={summary['heavy_manual']}")
    print(f"broken_sources={summary['broken_sources']}")

    if args.print_summary:
        print(json.dumps(summary, indent=2))
    return 0


def load_attempts(path: Path) -> dict[str, int]:
    data: dict[str, int] = {}
    if not path.is_file():
        return data
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        asset_id, raw = parts
        try:
            data[asset_id] = int(raw)
        except Exception:
            continue
    return data


def save_attempts(path: Path, attempts: dict[str, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}\t{v}" for k, v in sorted(attempts.items()) if v > 0]
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def append_manual_queue(path: Path, row: dict[str, str], reason: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.is_file()
    with path.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh, delimiter="\t")
        if not exists:
            writer.writerow(["asset_id", "source_path", "dest_cache_path", "reason", "ts"])
        writer.writerow(
            [
                row.get("asset_id", ""),
                row.get("source_path", ""),
                row.get("dest_cache_path", ""),
                reason,
                time.strftime("%Y-%m-%d %H:%M:%S"),
            ]
        )


def send_alert(text: str) -> None:
    alert_bin = Path("/usr/local/bin/nas-alert.sh")
    if not alert_bin.is_file():
        return
    try:
        subprocess.run([str(alert_bin), text], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def safe_dest(path_str: str, cache_root: Path) -> Path:
    p = Path(path_str).resolve()
    c = cache_root.resolve()
    if p != c and c not in p.parents:
        raise ValueError(f"destination outside cache root: {p}")
    return p


def convert_file(
    src: Path,
    dst: Path,
    *,
    ffmpeg_bin: str,
    audio_bitrate_k: int,
    target_maxrate_k: int,
    allow_remux_copy: bool,
    max_long_edge: int,
    video_level: str,
    max_fps: float,
) -> tuple[bool, str]:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp.mp4")
    try:
        if tmp.exists():
            tmp.unlink()
    except OSError:
        pass

    if allow_remux_copy:
        remux = [
            ffmpeg_bin,
            "-y",
            "-i",
            str(src),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            str(tmp),
        ]
        r1 = subprocess.run(remux, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r1.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
            tmp.replace(dst)
            return True, "remux_copy"

    vf_filters = []
    if max_long_edge > 0:
        vf_filters.append(
            f"scale={max_long_edge}:{max_long_edge}:force_original_aspect_ratio=decrease"
        )
    vf_filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
    if max_fps > 0:
        vf_filters.append(f"fps={max_fps:.3f}")

    transcode = [
        ffmpeg_bin,
        "-y",
        "-err_detect",
        "ignore_err",
        "-fflags",
        "+genpts+discardcorrupt",
        "-i",
        str(src),
        "-map",
        "0:v:0?",
        "-map",
        "0:a:0?",
        "-vf",
        ",".join(vf_filters),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "22",
        "-profile:v",
        "high",
        "-level:v",
        video_level,
        "-maxrate",
        f"{target_maxrate_k}k",
        "-bufsize",
        f"{target_maxrate_k * 2}k",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        f"{audio_bitrate_k}k",
        "-movflags",
        "+faststart",
        str(tmp),
    ]
    r2 = subprocess.run(transcode, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r2.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
        tmp.replace(dst)
        return True, "transcode_x264"

    try:
        if tmp.exists():
            tmp.unlink()
    except OSError:
        pass
    return False, "ffmpeg_failed"


def run_reprocess(args: argparse.Namespace) -> int:
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_root = Path(args.cache_root)
    attempts_db = Path(args.attempts_db)
    manual_queue = Path(args.manual_queue)

    if args.input_csv:
        input_csv = Path(args.input_csv)
    else:
        input_csv = out_dir / (LIGHT_LATEST if args.run_class == "light" else HEAVY_LATEST)

    if not input_csv.is_file():
        print(f"ERROR: input csv not found: {input_csv}", file=sys.stderr)
        return 1
    if args.allow_remux_copy not in (-1, 0, 1):
        print("ERROR: --allow-remux-copy debe ser -1, 0 o 1", file=sys.stderr)
        return 1

    allow_remux_copy = (
        bool(args.allow_remux_copy)
        if args.allow_remux_copy in (0, 1)
        else (args.run_class == "light" and args.max_long_edge <= 0)
    )

    attempts = load_attempts(attempts_db)
    ts = time.strftime("%Y%m%d-%H%M%S")
    run_report = out_dir / f"run-{args.run_class}-{ts}.csv"

    total = 0
    converted = 0
    skipped = 0
    failed = 0

    if args.notify:
        send_alert(
            "Reproceso nocturno de video: inicio\n"
            f"Clase: {args.run_class}\n"
            f"Entrada: {input_csv}"
        )

    with input_csv.open("r", newline="", encoding="utf-8") as src_fh, run_report.open(
        "w", newline="", encoding="utf-8"
    ) as rep_fh:
        reader = csv.DictReader(src_fh)
        writer = csv.writer(rep_fh)
        writer.writerow(
            [
                "asset_id",
                "source_path",
                "dest_cache_path",
                "action",
                "status",
                "attempts",
                "ts",
            ]
        )

        for row in reader:
            if args.limit and total >= args.limit:
                break
            total += 1
            asset_id = row.get("asset_id", "").strip()
            source_path = row.get("source_path", "").strip()
            dest_path = row.get("dest_cache_path", "").strip()

            if not asset_id or not source_path or not dest_path:
                failed += 1
                writer.writerow([asset_id, source_path, dest_path, "skip", "bad_row", "", time.strftime("%Y-%m-%d %H:%M:%S")])
                continue

            current_attempts = attempts.get(asset_id, 0)
            if args.run_class == "light" and current_attempts >= args.max_attempts:
                skipped += 1
                writer.writerow(
                    [asset_id, source_path, dest_path, "skip", "max_attempts_reached", current_attempts, time.strftime("%Y-%m-%d %H:%M:%S")]
                )
                continue

            src = Path(source_path)
            try:
                dst = safe_dest(dest_path, cache_root)
            except ValueError:
                failed += 1
                writer.writerow([asset_id, source_path, dest_path, "convert", "invalid_destination", current_attempts, time.strftime("%Y-%m-%d %H:%M:%S")])
                continue

            if not src.is_file() or src.stat().st_size <= 0:
                failed += 1
                new_attempts = current_attempts + 1
                attempts[asset_id] = new_attempts
                if args.run_class == "light" and new_attempts >= args.max_attempts:
                    append_manual_queue(manual_queue, row, "missing_source")
                writer.writerow([asset_id, source_path, dest_path, "convert", "missing_source", new_attempts, time.strftime("%Y-%m-%d %H:%M:%S")])
                continue

            if args.dry_run:
                skipped += 1
                writer.writerow([asset_id, source_path, dest_path, "convert", "dry_run", current_attempts, time.strftime("%Y-%m-%d %H:%M:%S")])
                continue

            ok, method = convert_file(
                src,
                dst,
                ffmpeg_bin=args.ffmpeg_bin,
                audio_bitrate_k=args.audio_bitrate_k,
                target_maxrate_k=args.target_maxrate_k,
                allow_remux_copy=allow_remux_copy,
                max_long_edge=args.max_long_edge,
                video_level=args.video_level,
                max_fps=args.max_fps,
            )
            if ok:
                converted += 1
                attempts.pop(asset_id, None)
                writer.writerow([asset_id, source_path, dest_path, "convert", method, 0, time.strftime("%Y-%m-%d %H:%M:%S")])
            else:
                failed += 1
                new_attempts = current_attempts + 1
                attempts[asset_id] = new_attempts
                if args.run_class == "light" and new_attempts >= args.max_attempts:
                    append_manual_queue(manual_queue, row, method)
                writer.writerow([asset_id, source_path, dest_path, "convert", method, new_attempts, time.strftime("%Y-%m-%d %H:%M:%S")])

            if total % 25 == 0:
                print(
                    f"PROGRESS total={total} converted={converted} failed={failed} skipped={skipped}",
                    flush=True,
                )

    save_attempts(attempts_db, attempts)
    latest_name = RUN_REPORT_LATEST if args.run_class == "light" else f"run-{args.run_class}-latest.csv"
    write_latest_copy(run_report, latest_name, out_dir)

    print(f"RUN_REPORT={run_report}")
    print(f"input_csv={input_csv}")
    print(f"processed={total}")
    print(f"converted={converted}")
    print(f"failed={failed}")
    print(f"skipped={skipped}")
    print(f"allow_remux_copy={int(allow_remux_copy)}")
    print(f"attempts_db={attempts_db}")
    print(f"manual_queue={manual_queue}")

    if args.notify:
        send_alert(
            "Reproceso nocturno de video: fin\n"
            f"Clase: {args.run_class}\n"
            f"Procesados: {total}\n"
            f"Convertidos: {converted}\n"
            f"Fallidos: {failed}\n"
            f"Omitidos: {skipped}"
        )
    return 0


def main() -> int:
    args = parse_args()
    if args.command == "plan":
        return run_plan(args)
    if args.command == "run":
        return run_reprocess(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
