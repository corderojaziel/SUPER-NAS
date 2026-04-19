import csv
import json
import os
import zipfile
from pathlib import Path

base = Path('/mnt/c/Users/jazie/Downloads/takeout-immich-cross')
imm = set()
for line in (base / 'immich-names-current.txt').read_text(encoding='utf-8', errors='ignore').splitlines():
    s = line.strip().lower()
    if s:
        imm.add(s)

img = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.webp', '.gif', '.bmp', '.tif', '.tiff', '.avif', '.dng', '.cr2', '.nef', '.arw', '.raw'}
vid = {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.3gp', '.webm', '.mpeg', '.mpg', '.wmv', '.mts', '.m2ts', '.hevc', '.ts', '.mxf', '.flv'}

print('part,media_records,missing_total,missing_photos,missing_videos,bad_json')

for part in ['001', '002', '003']:
    zp = Path(f'/mnt/c/Users/jazie/Downloads/takeout-20260418T191452Z-3-{part}.zip')
    records = {}
    bad = 0
    with zipfile.ZipFile(zp, 'r') as z:
        for info in z.infolist():
            if info.is_dir() or not info.filename.lower().endswith('.json'):
                continue
            try:
                raw = z.read(info).decode('utf-8', errors='ignore').strip()
                if not raw:
                    continue
                obj = json.loads(raw)
            except Exception:
                bad += 1
                continue
            title = str(obj.get('title') or '').strip()
            if not title:
                continue
            ext = os.path.splitext(title)[1].lower()
            if ext not in img and ext not in vid:
                continue
            key = title.lower()
            if key in records:
                continue
            records[key] = {
                'filename': title,
                'media_type': 'video' if ext in vid else 'photo',
                'takeout_json': info.filename,
            }

    missing = [v for k, v in records.items() if k not in imm]
    missing.sort(key=lambda x: (x['media_type'], x['filename'].lower()))
    photos = sum(1 for m in missing if m['media_type'] == 'photo')
    videos = sum(1 for m in missing if m['media_type'] == 'video')
    print(f"{part},{len(records)},{len(missing)},{photos},{videos},{bad}")

    out = base / f'missing-mediaonly-3-{part}.csv'
    with out.open('w', encoding='utf-8', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['filename', 'media_type', 'takeout_json'])
        w.writeheader()
        w.writerows(missing)
