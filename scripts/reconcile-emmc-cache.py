#!/usr/bin/env python3
"""
Reconcilia el cache legado de videos hacia la estructura canónica del eMMC.

Casos que cubre:
  - cache legado con nombre plano: uuid.mp4
  - cache legado "aplastado": asset_aa_bb_uuid.mp4
  - originales con extensión .mp4 o .MP4 (u otras variantes)

La salida canónica siempre queda en:
  /var/lib/immich/cache/upload/<asset>/<aa>/<bb>/<uuid>.mp4

Además remuxa con "-c copy -movflags +faststart" para que el MP4 sirva bien
desde navegador/app sin re-encode costoso.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp"}
UNDERSCORED_STEM_RE = re.compile(
    r"^([0-9a-f-]+)_([0-9a-f]{2})_([0-9a-f]{2})_([0-9a-f-]+)$",
    re.IGNORECASE,
)
ASSET_PREFIX_STEM_RE = re.compile(
    r"^asset_([0-9a-f]{2})_([0-9a-f]{2})_([0-9a-f-]+)$",
    re.IGNORECASE,
)
PAIR_UUID_STEM_RE = re.compile(
    r"^([0-9a-f]{2})_([0-9a-f]{2})_([0-9a-f-]+)$",
    re.IGNORECASE,
)
FLAT_STEM_RE = re.compile(r"^([0-9a-f-]+)$", re.IGNORECASE)
DAMAGED_LIST = Path("/var/lib/nas-health/damaged-videos.txt")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--legacy-root",
        default="/mnt/storage-main/cache",
        help="cache legado fuente",
    )
    parser.add_argument(
        "--upload-root",
        default="/mnt/storage-main/photos/upload",
        help="raiz de originales de Immich",
    )
    parser.add_argument(
        "--cache-root",
        default="/var/lib/immich/cache",
        help="cache canonico destino",
    )
    parser.add_argument(
        "--ffmpeg-bin",
        default="ffmpeg",
        help="binario ffmpeg para remux faststart",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="limita cuantos archivos procesa (0 = sin limite)",
    )
    return parser.parse_args()


def load_original_index(upload_root: Path) -> dict[str, Path]:
    index: dict[str, Path] = {}
    for path in upload_root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in VIDEO_EXTS:
            continue
        if path.name.lower().endswith(".xmp"):
            continue
        index.setdefault(path.stem.lower(), path)
    return index


def has_faststart(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            head = fh.read(1024 * 1024)
    except OSError:
        return False
    moov = head.find(b"moov")
    mdat = head.find(b"mdat")
    return moov != -1 and (mdat == -1 or moov < mdat)


def canonical_rel_from_legacy(path: Path, upload_root: Path, index: dict[str, Path]) -> str | None:
    if path.suffix.lower() not in VIDEO_EXTS:
        return None

    stem = path.stem
    match = UNDERSCORED_STEM_RE.match(stem)
    if match:
        asset, a1, a2, uuid = match.groups()
        folder = upload_root / asset / a1 / a2
        if not folder.is_dir():
            return None
        matches = sorted(folder.glob(uuid + ".*"))
        if not matches:
            return None
        return f"upload/{asset}/{a1}/{a2}/{uuid}.mp4"

    match = ASSET_PREFIX_STEM_RE.match(stem)
    if match:
        _, _, uuid = match.groups()
        original = index.get(uuid.lower())
        if not original:
            return None
        rel = original.relative_to(upload_root)
        return "upload/" + str(rel.with_suffix(".mp4")).replace(os.sep, "/")

    match = PAIR_UUID_STEM_RE.match(stem)
    if match:
        _, _, uuid = match.groups()
        original = index.get(uuid.lower())
        if not original:
            return None
        rel = original.relative_to(upload_root)
        return "upload/" + str(rel.with_suffix(".mp4")).replace(os.sep, "/")

    match = FLAT_STEM_RE.match(stem)
    if match:
        uuid = match.group(1).lower()
        original = index.get(uuid)
        if not original:
            return None
        rel = original.relative_to(upload_root)
        return "upload/" + str(rel.with_suffix(".mp4")).replace(os.sep, "/")

    return None


def remux_faststart(src: Path, dst: Path, ffmpeg_bin: str) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    # Keep a .mp4 extension on temp output so ffmpeg can infer muxer.
    tmp = dst.with_name(dst.name + ".tmp.mp4")
    if tmp.exists():
        tmp.unlink()

    cmd = [
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
    result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
        tmp.replace(dst)
        return True

    # Fallback para contenedores/códecs no compatibles con copy->mp4.
    transcode_cmd = [
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
        "23",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        str(tmp),
    ]
    transcode_result = subprocess.run(
        transcode_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if transcode_result.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
        tmp.replace(dst)
        return True

    try:
        if tmp.exists():
            tmp.unlink()
    except OSError:
        pass

    if src.suffix.lower() == ".mp4":
        try:
            shutil.copy2(src, dst)
            return True
        except OSError:
            return False

    return False


def main() -> int:
    args = parse_args()
    legacy_root = Path(args.legacy_root)
    upload_root = Path(args.upload_root)
    cache_root = Path(args.cache_root)

    if not legacy_root.is_dir():
        print(f"SKIP: legacy root no existe: {legacy_root}")
        return 0
    if not upload_root.is_dir():
        print(f"ERROR: upload root no existe: {upload_root}", file=sys.stderr)
        return 1

    index = load_original_index(upload_root)
    stats = {
        "processed": 0,
        "copied": 0,
        "updated": 0,
        "skipped_ready": 0,
        "missing_original": 0,
        "errors": 0,
    }

    DAMAGED_LIST.parent.mkdir(parents=True, exist_ok=True)
    existing_damaged: set[str] = set()
    if DAMAGED_LIST.is_file():
        try:
            existing_damaged = {
                line.strip() for line in DAMAGED_LIST.read_text(encoding="utf-8").splitlines() if line.strip()
            }
        except OSError:
            existing_damaged = set()

    legacy_files = sorted(
        path
        for path in legacy_root.iterdir()
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS
    )

    for src in legacy_files:
        if args.limit and stats["processed"] >= args.limit:
            break
        stats["processed"] += 1

        rel = canonical_rel_from_legacy(src, upload_root, index)
        if not rel:
            stats["missing_original"] += 1
            continue

        dst = cache_root / Path(rel)
        if dst.is_file() and dst.stat().st_size > 0 and has_faststart(dst):
            stats["skipped_ready"] += 1
            continue

        ok = remux_faststart(src, dst, args.ffmpeg_bin)
        if not ok:
            # Si el cache legado está dañado/incompleto, intentamos reconstruir
            # desde el original del árbol upload usando el UUID del nombre final.
            original_fallback = index.get(dst.stem.lower())
            if original_fallback and original_fallback != src:
                ok = remux_faststart(original_fallback, dst, args.ffmpeg_bin)
        if ok:
            existing_damaged.discard(str(src))
            existing_damaged.discard(src.name)
            if dst.exists() and dst.stat().st_size > 0:
                if has_faststart(dst):
                    stats["updated"] += 1
                else:
                    stats["copied"] += 1
            else:
                stats["errors"] += 1
        else:
            existing_damaged.add(str(src))
            existing_damaged.add(src.name)
            stats["errors"] += 1

    try:
        DAMAGED_LIST.write_text(
            "\n".join(sorted(existing_damaged)) + ("\n" if existing_damaged else ""),
            encoding="utf-8",
        )
    except OSError:
        pass

    print("RESUMEN")
    for key, value in stats.items():
        print(f"{key}={value}")
    return 0 if stats["errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
