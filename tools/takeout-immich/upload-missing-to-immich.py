#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import mimetypes
import os
import shutil
import tempfile
import time
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests


def parse_args():
    p = argparse.ArgumentParser(description='Upload missing assets from Takeout ZIP to Immich')
    p.add_argument('--zip-path', required=True)
    p.add_argument('--csv-path', required=True)
    p.add_argument('--api-base', default='http://192.168.100.89:2283/api')
    p.add_argument('--creds-file', required=True, help='Text file with IMMICH_ADMIN_EMAIL= and IMMICH_ADMIN_PASSWORD=')
    p.add_argument('--report-csv', required=True)
    p.add_argument('--tmp-dir', required=True)
    p.add_argument('--sleep-sec', type=float, default=0.05)
    p.add_argument('--mode', choices=['all', 'photo', 'video'], default='all')
    return p.parse_args()


def read_creds(path: Path):
    email = ''
    password = ''
    lines = path.read_text(encoding='utf-8', errors='ignore').splitlines()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('IMMICH_ADMIN_EMAIL='):
            email = line.split('=', 1)[1].strip().strip('"')
        elif line.startswith('IMMICH_ADMIN_PASSWORD='):
            password = line.split('=', 1)[1].strip().strip('"')
    if not email or not password:
        raise RuntimeError('Missing IMMICH_ADMIN_EMAIL or IMMICH_ADMIN_PASSWORD in creds file')
    return email, password


def login(api_base: str, email: str, password: str) -> str:
    r = requests.post(
        api_base.rstrip('/') + '/auth/login',
        json={'email': email, 'password': password},
        timeout=30,
    )
    if r.status_code >= 300:
        raise RuntimeError(f'Login failed {r.status_code}: {r.text[:400]}')
    data = r.json()
    token = data.get('accessToken', '')
    if not token:
        raise RuntimeError('Login succeeded but no accessToken in response')
    return token


def ts_to_iso(ts_raw: str) -> str:
    try:
        ts = int(str(ts_raw).strip())
        if ts > 0:
            return datetime.fromtimestamp(ts, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        pass
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def preferred_media_path(takeout_json_path: str) -> str:
    p = (takeout_json_path or '').strip()
    if not p:
        return ''
    suffixes = [
        '.supplemental-metadata.json',
        '.supplemental-metadat.json',
        '.suppl.json',
        '.suppleme.json',
        '.json',
    ]
    pl = p.lower()
    for s in suffixes:
        if pl.endswith(s):
            return p[: len(p) - len(s)]
    return p


def build_zip_indexes(zf: zipfile.ZipFile):
    by_full = {}
    by_base = defaultdict(list)
    for info in zf.infolist():
        if info.is_dir():
            continue
        name = info.filename
        if name.lower().endswith('.json'):
            continue
        by_full[name.lower()] = info
        by_base[os.path.basename(name).lower()].append(info)
    return by_full, by_base


def pick_zip_entry(filename: str, takeout_json: str, by_full, by_base):
    pref = preferred_media_path(takeout_json)
    if pref:
        hit = by_full.get(pref.lower())
        if hit is not None:
            return hit, 'preferred_path'
    cands = by_base.get((filename or '').lower(), [])
    if not cands:
        return None, 'not_found'
    cands_sorted = sorted(cands, key=lambda x: (x.file_size, x.filename), reverse=True)
    return cands_sorted[0], 'basename_fallback'


def upload_asset(api_base: str, token: str, file_path: Path, filename: str, file_dt_iso: str, device_asset_id: str):
    url = api_base.rstrip('/') + '/assets'
    mime = mimetypes.guess_type(filename)[0] or 'application/octet-stream'
    with file_path.open('rb') as fh:
        files = {
            'assetData': (filename, fh, mime),
        }
        data = {
            'deviceAssetId': device_asset_id,
            'deviceId': 'supernas-takeout-repair-pc',
            'fileCreatedAt': file_dt_iso,
            'fileModifiedAt': file_dt_iso,
            'isFavorite': 'false',
            'isArchived': 'false',
        }
        r = requests.post(url, headers={'Authorization': f'Bearer {token}'}, data=data, files=files, timeout=240)
    return r


def main():
    args = parse_args()

    zip_path = Path(args.zip_path)
    csv_path = Path(args.csv_path)
    creds_path = Path(args.creds_file)
    report_path = Path(args.report_csv)
    tmp_dir = Path(args.tmp_dir)

    tmp_dir.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    if not zip_path.exists():
        raise SystemExit(f'zip not found: {zip_path}')
    if not csv_path.exists():
        raise SystemExit(f'csv not found: {csv_path}')
    if not creds_path.exists():
        raise SystemExit(f'creds not found: {creds_path}')

    email, password = read_creds(creds_path)
    token = login(args.api_base, email, password)

    with csv_path.open('r', encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))

    if args.mode != 'all':
        rows = [r for r in rows if (r.get('media_type') or '').strip().lower() == args.mode]

    print(f'target_rows={len(rows)} mode={args.mode}')

    uploaded = 0
    failed = 0
    not_found = 0

    with zipfile.ZipFile(zip_path, 'r') as zf, report_path.open('w', encoding='utf-8', newline='') as rf:
        by_full, by_base = build_zip_indexes(zf)
        w = csv.DictWriter(
            rf,
            fieldnames=[
                'filename',
                'media_type',
                'status',
                'http_status',
                'asset_id',
                'zip_entry',
                'pick_mode',
                'error',
            ],
        )
        w.writeheader()

        for i, row in enumerate(rows, start=1):
            filename = (row.get('filename') or '').strip()
            media_type = (row.get('media_type') or '').strip().lower()
            takeout_json = (row.get('takeout_json') or '').strip()
            ts_epoch = (row.get('timestamp_epoch') or '').strip()

            info, pick_mode = pick_zip_entry(filename, takeout_json, by_full, by_base)
            if info is None:
                not_found += 1
                w.writerow(
                    {
                        'filename': filename,
                        'media_type': media_type,
                        'status': 'not_found_in_zip',
                        'http_status': '',
                        'asset_id': '',
                        'zip_entry': '',
                        'pick_mode': pick_mode,
                        'error': 'no matching media entry in zip',
                    }
                )
                continue

            created_iso = ts_to_iso(ts_epoch)
            device_asset_id = 'takeout-' + hashlib.sha1((info.filename + '|' + filename).encode('utf-8', errors='ignore')).hexdigest()

            suffix = Path(filename).suffix or Path(info.filename).suffix or '.bin'
            tmp_file = Path(tempfile.mkstemp(prefix='takeout_up_', suffix=suffix, dir=str(tmp_dir))[1])
            try:
                with zf.open(info, 'r') as src, tmp_file.open('wb') as dst:
                    shutil.copyfileobj(src, dst, length=1024 * 1024)

                resp = upload_asset(args.api_base, token, tmp_file, filename or os.path.basename(info.filename), created_iso, device_asset_id)
                status_code = resp.status_code
                asset_id = ''
                err = ''
                status = 'uploaded'

                try:
                    payload = resp.json()
                except Exception:
                    payload = None

                if status_code >= 300:
                    failed += 1
                    status = 'failed'
                    err = (resp.text or '')[:800]
                else:
                    if isinstance(payload, dict):
                        asset_id = str(payload.get('id', '') or payload.get('assetId', '') or '')
                        if not asset_id and payload.get('status') in {'duplicate', 'exists'}:
                            status = 'exists'
                        elif not asset_id and payload.get('duplicate') is True:
                            status = 'exists'
                    uploaded += 1

                w.writerow(
                    {
                        'filename': filename,
                        'media_type': media_type,
                        'status': status,
                        'http_status': status_code,
                        'asset_id': asset_id,
                        'zip_entry': info.filename,
                        'pick_mode': pick_mode,
                        'error': err,
                    }
                )

            except Exception as e:
                failed += 1
                w.writerow(
                    {
                        'filename': filename,
                        'media_type': media_type,
                        'status': 'failed_exception',
                        'http_status': '',
                        'asset_id': '',
                        'zip_entry': info.filename,
                        'pick_mode': pick_mode,
                        'error': str(e)[:800],
                    }
                )
            finally:
                try:
                    tmp_file.unlink(missing_ok=True)
                except Exception:
                    pass

            if i % 20 == 0:
                print(f'progress {i}/{len(rows)} uploaded={uploaded} failed={failed} not_found={not_found}')
            if args.sleep_sec > 0:
                time.sleep(args.sleep_sec)

    summary = {
        'target_rows': len(rows),
        'uploaded_or_exists': uploaded,
        'failed': failed,
        'not_found_in_zip': not_found,
        'report_csv': str(report_path),
    }
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()
