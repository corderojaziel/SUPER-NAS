#!/usr/bin/env python3
import argparse
import csv
import json
import os
import zipfile
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser(description='Build missing-from-immich CSV from a Takeout zip metadata set')
    p.add_argument('--zip-path', required=True)
    p.add_argument('--immich-names', required=True)
    p.add_argument('--out-csv', required=True)
    p.add_argument('--out-summary', required=True)
    return p.parse_args()


def media_type_from_name(name: str) -> str:
    ext = os.path.splitext(name)[1].lower()
    if ext in {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.3gp', '.webm', '.mpeg', '.mpg', '.wmv', '.mts', '.m2ts', '.hevc', '.ts', '.gif'}:
        return 'video' if ext != '.gif' else 'photo'
    return 'photo'


def main():
    args = parse_args()
    zip_path = Path(args.zip_path)
    immich_path = Path(args.immich_names)
    out_csv = Path(args.out_csv)
    out_summary = Path(args.out_summary)

    immich = set()
    for line in immich_path.read_text(encoding='utf-8', errors='ignore').splitlines():
        s = line.strip().lower()
        if s:
            immich.add(s)

    records = {}
    bad_json = 0

    with zipfile.ZipFile(zip_path, 'r') as zf:
        for info in zf.infolist():
            if info.is_dir() or not info.filename.lower().endswith('.json'):
                continue
            try:
                raw = zf.read(info).decode('utf-8', errors='ignore').strip()
                if not raw:
                    continue
                obj = json.loads(raw)
            except Exception:
                bad_json += 1
                continue

            title = str(obj.get('title') or '').strip()
            if not title:
                title = Path(info.filename).stem
            if not title:
                continue

            key = title.lower()
            if key in records:
                continue

            ts = ''
            pt = obj.get('photoTakenTime') or {}
            ct = obj.get('creationTime') or {}
            if isinstance(pt, dict) and pt.get('timestamp'):
                ts = str(pt.get('timestamp'))
            elif isinstance(ct, dict) and ct.get('timestamp'):
                ts = str(ct.get('timestamp'))

            size = obj.get('size')
            size_str = str(size) if size is not None else ''

            records[key] = {
                'filename': title,
                'media_type': media_type_from_name(title),
                'size_bytes': size_str,
                'timestamp_epoch': ts,
                'takeout_json': info.filename,
            }

    missing = [r for k, r in records.items() if k not in immich]
    missing.sort(key=lambda x: (x['media_type'], x['filename'].lower()))

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open('w', encoding='utf-8', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['filename', 'media_type', 'size_bytes', 'timestamp_epoch', 'takeout_json'])
        w.writeheader()
        w.writerows(missing)

    photos = sum(1 for r in missing if r['media_type'] == 'photo')
    videos = sum(1 for r in missing if r['media_type'] == 'video')
    summary = {
        'zip_path': str(zip_path),
        'metadata_unique_media': len(records),
        'metadata_bad_json': bad_json,
        'missing_total': len(missing),
        'missing_photos': photos,
        'missing_videos': videos,
        'out_csv': str(out_csv),
    }

    with out_summary.open('w', encoding='utf-8') as sf:
        for k, v in summary.items():
            sf.write(f'{k}={v}\n')

    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()
