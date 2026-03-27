#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
import time
from pathlib import Path


UPLOAD_PREFIX = "/usr/src/app/upload/"
UPLOAD_HOST_ROOT = "/mnt/storage-main/photos"
IMMICH_LOCAL_ROOT = "/var/lib/immich"

VIDEO_EXTS = (".mp4", ".MP4", ".Mp4", ".mP4")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", default="/var/lib/immich/cache")
    parser.add_argument("--legacy-root", default="/mnt/storage-main/cache")
    parser.add_argument("--ffmpeg-bin", default="ffmpeg")
    parser.add_argument("--max-mb-min", type=float, default=40.0)
    parser.add_argument("--limit", type=int, default=0, help="0 = sin limite")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report-dir", default="/root/log-watch")
    return parser.parse_args()


def parse_duration_seconds(value: str) -> float:
    if not value:
        return 0.0
    try:
        h, m, s = value.split(":")
        return int(h) * 3600 + int(m) * 60 + float(s)
    except Exception:
        return 0.0


def db_rows() -> list[tuple[str, str, str, str]]:
    sql = (
        "select a.id, a.\"originalPath\", coalesce(a.duration,''), "
        "coalesce(e.\"fileSizeInByte\",0)::text "
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
    rows: list[tuple[str, str, str, str]] = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) == 4:
            rows.append((parts[0], parts[1], parts[2], parts[3]))
    return rows


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


def safe_join(root: Path, rel: str) -> Path:
    candidate = (root / rel).resolve()
    root_abs = root.resolve()
    if candidate != root_abs and root_abs not in candidate.parents:
        raise ValueError(f"ruta fuera de root permitido: {candidate}")
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
        for alt in VIDEO_EXTS:
            alt_rel = base + alt
            try:
                alt_candidate = safe_join(root, alt_rel)
            except ValueError:
                continue
            if alt_candidate.is_file() and alt_candidate.stat().st_size > 0:
                return alt_candidate
    return None


def iter_rel_variants(rel_mp4: str) -> list[str]:
    stripped = rel_mp4[len("upload/") :] if rel_mp4.startswith("upload/") else rel_mp4
    parts = rel_parts(rel_mp4)
    vals: list[str] = []

    def push(v: str) -> None:
        if v and v not in vals:
            vals.append(v)

    push(rel_mp4)
    push(stripped.replace("/", "_"))
    push(os.path.basename(rel_mp4))
    if parts:
        _, aa, bb, uuid = parts
        push(f"asset_{aa}_{bb}_{uuid}.mp4")
        push(f"{aa}_{bb}_{uuid}.mp4")
    push(stripped)
    return vals


def cache_exists(cache_root: Path, legacy_root: Path, rel_mp4: str) -> bool:
    variants = iter_rel_variants(rel_mp4)
    for rel in variants:
        if resolve_existing_variant(cache_root, rel):
            return True
        if resolve_existing_variant(legacy_root, rel):
            return True
    return False


def source_host_path(original_path: str) -> Path:
    rel = original_path[len(UPLOAD_PREFIX):].lstrip("/")
    base = Path(UPLOAD_HOST_ROOT)
    if rel.startswith("encoded-video/") or rel.startswith("thumbs/"):
        base = Path(IMMICH_LOCAL_ROOT)
    return (base / rel).resolve()


def transcode_to_cache(ffmpeg_bin: str, src: Path, dst: Path) -> tuple[bool, str]:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp.mp4")
    try:
        if tmp.exists():
            tmp.unlink()
    except OSError:
        pass

    # Objetivo: mantener calidad usable pero bajo el umbral de ~40 MB/min.
    cmd = [
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
        "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "22",
        "-maxrate",
        "5M",
        "-bufsize",
        "10M",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        str(tmp),
    ]
    result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        return False, "ffmpeg_failed"
    if not tmp.is_file() or tmp.stat().st_size <= 0:
        return False, "tmp_missing_or_empty"

    tmp.replace(dst)
    return True, "ok"


def main() -> int:
    args = parse_args()
    cache_root = Path(args.cache_root)
    legacy_root = Path(args.legacy_root)
    report_dir = Path(args.report_dir)
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"backfill-heavy-cache-{time.strftime('%Y%m%d-%H%M%S')}.csv"

    rows = db_rows()
    print(f"DB_ROWS={len(rows)}", flush=True)
    stats = {
        "total": 0,
        "invalid_original": 0,
        "light_skip": 0,
        "heavy_with_cache": 0,
        "heavy_missing": 0,
        "converted": 0,
        "convert_errors": 0,
    }

    processed_heavy_missing = 0
    with report_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "asset_id",
                "mb_per_min",
                "needs_cache",
                "had_cache",
                "action",
                "status",
                "source",
                "dest",
            ]
        )
        fh.flush()

        for i, (asset_id, original_path, duration_raw, size_raw) in enumerate(rows, start=1):
            stats["total"] += 1
            if not original_path.startswith(UPLOAD_PREFIX):
                stats["invalid_original"] += 1
                writer.writerow([asset_id, "", "", "", "skip", "invalid_original", original_path, ""])
                fh.flush()
                continue

            duration_sec = parse_duration_seconds(duration_raw)
            try:
                size_bytes = int(size_raw or "0")
            except Exception:
                size_bytes = 0

            mbpm = 0.0
            if duration_sec > 0 and size_bytes > 0:
                mbpm = (size_bytes / 1_000_000.0) / (duration_sec / 60.0)

            rel_mp4 = rel_mp4_for_original(original_path)
            needs_cache = mbpm > args.max_mb_min if mbpm > 0 else True
            has_cache = cache_exists(cache_root, legacy_root, rel_mp4)

            if not needs_cache:
                stats["light_skip"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "no", "yes" if has_cache else "no", "skip", "light", "", ""])
                fh.flush()
                continue

            if has_cache:
                stats["heavy_with_cache"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "yes", "skip", "already_cached", "", ""])
                fh.flush()
                continue

            stats["heavy_missing"] += 1
            processed_heavy_missing += 1

            parts = rel_parts(rel_mp4)
            if not parts:
                stats["convert_errors"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "no", "convert", "bad_rel_parts", original_path, ""])
                fh.flush()
                continue

            src = source_host_path(original_path)
            dst = cache_root / rel_mp4

            if args.limit and processed_heavy_missing > args.limit:
                break

            if args.dry_run:
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "no", "would_convert", "dry_run", str(src), str(dst)])
                fh.flush()
                continue

            if not src.is_file():
                stats["convert_errors"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "no", "convert", "missing_source", str(src), str(dst)])
                fh.flush()
                continue

            ok, status = transcode_to_cache(args.ffmpeg_bin, src, dst)
            if ok:
                stats["converted"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "no", "convert", "ok", str(src), str(dst)])
            else:
                stats["convert_errors"] += 1
                writer.writerow([asset_id, f"{mbpm:.2f}", "yes", "no", "convert", status, str(src), str(dst)])
            fh.flush()

            if (i % 25) == 0:
                print(
                    f"PROGRESO i={i}/{len(rows)} heavy_missing={stats['heavy_missing']} "
                    f"converted={stats['converted']} errors={stats['convert_errors']}",
                    flush=True,
                )

    print(f"REPORTE={report_path}")
    for key, value in stats.items():
        print(f"{key}={value}")
    return 0 if stats["convert_errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
