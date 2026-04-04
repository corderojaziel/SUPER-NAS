#!/usr/bin/env python3
"""Ensure Immich on-this-day memories exist (with assets) for a target local date."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Dict, List, Tuple
from zoneinfo import ZoneInfo


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--api-base", default="http://127.0.0.1:2283/api")
    p.add_argument("--secrets-file", default="/etc/nas-secrets")
    p.add_argument("--timezone", default=os.environ.get("MEMORIES_TIMEZONE", "America/Mexico_City"))
    p.add_argument("--days-offset", type=int, default=0)
    p.add_argument("--max-assets", type=int, default=25)
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def read_secrets(path: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def http_json(method: str, url: str, body=None, headers=None):
    payload = None if body is None else json.dumps(body).encode("utf-8")
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=payload, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="ignore")
            return resp.getcode(), json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore")
        try:
            body_json = json.loads(raw) if raw else {}
        except Exception:
            body_json = {"raw": raw}
        return exc.code, body_json


def db_query(sql: str) -> List[str]:
    cmd = [
        "docker",
        "exec",
        "immich_postgres",
        "psql",
        "-U",
        "immich",
        "-d",
        "immich",
        "-At",
        "-c",
        sql,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "psql query failed")
    return [x.strip() for x in proc.stdout.splitlines() if x.strip()]


def parse_iso(iso_text: str):
    if not iso_text:
        return None
    return dt.datetime.fromisoformat(iso_text.replace("Z", "+00:00"))


def to_z(ts: dt.datetime) -> str:
    return ts.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def main() -> int:
    args = parse_args()
    try:
        zone = ZoneInfo(args.timezone)
    except Exception:
        print(f"WARN timezone inválida ({args.timezone}), uso zona local del sistema", file=sys.stderr)
        zone = dt.datetime.now().astimezone().tzinfo
        if zone is None:
            zone = dt.timezone.utc

    secrets = read_secrets(args.secrets_file)
    email = secrets.get("IMMICH_ADMIN_EMAIL", "")
    password = secrets.get("IMMICH_ADMIN_PASSWORD", "")
    if not email or not password:
        print("ERROR faltan IMMICH_ADMIN_EMAIL/IMMICH_ADMIN_PASSWORD en secrets", file=sys.stderr)
        return 2

    now_local = dt.datetime.now(zone)
    target_local_date = (now_local + dt.timedelta(days=args.days_offset)).date()
    mmdd = target_local_date.strftime("%m-%d")
    local_midnight = dt.datetime.combine(target_local_date, dt.time.min, tzinfo=zone)

    c, login = http_json("POST", f"{args.api_base}/auth/login", {"email": email, "password": password})
    if c not in (200, 201) or "accessToken" not in login:
        print(f"ERROR login immich: status={c} body={login}", file=sys.stderr)
        return 2
    headers = {"Authorization": f"Bearer {login['accessToken']}"}

    c, memories = http_json("GET", f"{args.api_base}/memories", headers=headers)
    if c != 200 or not isinstance(memories, list):
        print(f"ERROR /memories status={c} body={memories}", file=sys.stderr)
        return 2

    email_sql = email.replace("'", "''")
    owner_lines = db_query(f"select id::text from \"user\" where email='{email_sql}' limit 1;")
    if not owner_lines:
        print("ERROR no encontré ownerId para email admin", file=sys.stderr)
        return 2
    owner_id = owner_lines[0]

    year_rows = db_query(
        "select y::text || '|' || ids from ("
        "select extract(year from \"localDateTime\")::int as y, "
        "string_agg(id::text, ',' order by \"localDateTime\" desc) as ids "
        "from asset "
        f"where \"ownerId\"='{owner_id}' and \"deletedAt\" is null and status='active' "
        f"and to_char(\"localDateTime\",'MM-DD')='{mmdd}' "
        "group by 1"
        ") t order by y;"
    )

    if not year_rows:
        print(f"OK no hay assets para MM-DD={mmdd} (offset={args.days_offset})")
        return 0

    existing: Dict[Tuple[int, str], dict] = {}
    for m in memories:
        if not isinstance(m, dict):
            continue
        if m.get("type") != "on_this_day":
            continue
        year = (m.get("data") or {}).get("year")
        show_at = parse_iso(m.get("showAt", ""))
        if not isinstance(year, int) or show_at is None:
            continue
        show_date_local = show_at.astimezone(zone).date().isoformat()
        existing[(year, show_date_local)] = m

    created = 0
    patched = 0
    kept = 0

    for row in year_rows:
        year_txt, ids_txt = row.split("|", 1)
        year = int(year_txt)
        ids = [x for x in ids_txt.split(",") if x][: args.max_assets]
        if not ids:
            continue

        memory_at = to_z(local_midnight.replace(year=year))
        show_at = to_z(local_midnight)
        key = (year, target_local_date.isoformat())
        current = existing.get(key)

        if current is None:
            payload = {
                "type": "on_this_day",
                "data": {"year": year},
                "memoryAt": memory_at,
                "showAt": show_at,
                "assetIds": ids,
            }
            if args.dry_run:
                print(f"DRYRUN create year={year} assets={len(ids)} showAt={show_at}")
            else:
                c, body = http_json("POST", f"{args.api_base}/memories", payload, headers=headers)
                if c == 201:
                    created += 1
                    print(f"CREATED year={year} assets={len(ids)} id={body.get('id')}")
                else:
                    print(f"WARN create failed year={year} status={c} body={body}", file=sys.stderr)
            continue

        current_assets = current.get("assets") or []
        if len(current_assets) == 0:
            if args.dry_run:
                print(f"DRYRUN patch-assets memory={current.get('id')} year={year} assets={len(ids)}")
            else:
                c, body = http_json(
                    "PUT",
                    f"{args.api_base}/memories/{current.get('id')}/assets",
                    {"ids": ids},
                    headers=headers,
                )
                if c == 200:
                    patched += 1
                    print(f"PATCHED memory={current.get('id')} year={year} assets={len(ids)}")
                else:
                    print(
                        f"WARN patch failed memory={current.get('id')} year={year} status={c} body={body}",
                        file=sys.stderr,
                    )
        else:
            kept += 1

    print(
        f"SUMMARY mmdd={mmdd} date={target_local_date.isoformat()} created={created} patched={patched} kept={kept}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
