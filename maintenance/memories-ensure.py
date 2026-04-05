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


def db_exec(sql: str) -> str:
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
        raise RuntimeError(proc.stderr.strip() or "psql exec failed")
    return proc.stdout.strip()


def dedupe_on_this_day(owner_id: str, dry_run: bool) -> Tuple[int, int]:
    """Deduplicate same (year, showAt) memories keeping the one with most assets."""
    owner_sql = owner_id.replace("'", "''")
    dup_rows = db_query(
        "with grp as ("
        "  select (m.data->>'year')::int as year, m.\"showAt\" as show_at, count(*) as c "
        "  from memory m "
        f"  where m.type='on_this_day' and m.\"ownerId\"='{owner_sql}' "
        "  group by 1,2 "
        ") select coalesce(sum(c-1),0)::text from grp where c>1;"
    )
    dup_count = int(dup_rows[0]) if dup_rows else 0
    if dup_count <= 0 or dry_run:
        return dup_count, 0

    result = db_query(
        "with scored as ( "
        "  select m.id, (m.data->>'year')::int as year, m.\"showAt\" as show_at, "
        "         m.\"updatedAt\" as updated_at, "
        "         (select count(*) from memory_asset ma where ma.\"memoriesId\"=m.id) as assets "
        "  from memory m "
        f"  where m.type='on_this_day' and m.\"ownerId\"='{owner_sql}' "
        "), ranked as ( "
        "  select *, row_number() over (partition by year, show_at order by assets desc, updated_at desc, id desc) as rn "
        "  from scored "
        "), keepers as ( "
        "  select year, show_at, id as keep_id from ranked where rn=1 "
        "), losers as ( "
        "  select year, show_at, id as lose_id from ranked where rn>1 "
        "), merged as ( "
        "  insert into memory_asset (\"memoriesId\", \"assetId\") "
        "  select k.keep_id, ma.\"assetId\" "
        "  from losers l "
        "  join keepers k on k.year=l.year and k.show_at=l.show_at "
        "  join memory_asset ma on ma.\"memoriesId\"=l.lose_id "
        "  left join memory_asset mk on mk.\"memoriesId\"=k.keep_id and mk.\"assetId\"=ma.\"assetId\" "
        "  where mk.\"assetId\" is null "
        "  returning 1 "
        "), del_map as ( "
        "  delete from memory_asset ma using losers l where ma.\"memoriesId\"=l.lose_id returning 1 "
        "), del_mem as ( "
        "  delete from memory m using losers l where m.id=l.lose_id returning 1 "
        ") "
        "select (select count(*) from del_mem)::text || '|' || (select count(*) from merged)::text;"
    )
    deleted_mem = 0
    merged_assets = 0
    if result and "|" in result[0]:
        a, b = result[0].split("|", 1)
        deleted_mem = int(a or 0)
        merged_assets = int(b or 0)
    return deleted_mem, merged_assets


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
    utc_midnight = dt.datetime.combine(target_local_date, dt.time.min, tzinfo=dt.timezone.utc)

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

    deduped, dedupe_merged_assets = dedupe_on_this_day(owner_id, args.dry_run)

    # Compatibilidad móvil: algunos clientes no muestran memories con hideAt NULL.
    # Backfill seguro: no borra nada, solo completa hideAt faltante.
    backfill_rows = db_query(
        "select count(*) from memory "
        f"where \"ownerId\"='{owner_id}' and type='on_this_day' "
        "and \"showAt\" is not null and \"hideAt\" is null;"
    )
    backfill_count = int(backfill_rows[0]) if backfill_rows else 0
    if backfill_count > 0 and not args.dry_run:
        db_exec(
            "update memory "
            "set \"hideAt\"=(\"showAt\" + interval '1 day' - interval '1 milliseconds') "
            f"where \"ownerId\"='{owner_id}' and type='on_this_day' "
            "and \"showAt\" is not null and \"hideAt\" is null;"
        )

    # Compatibilidad móvil (timeline): algunas apps filtran con día UTC estricto.
    # Si showAt no está a 00:00:00Z, las memories pueden quedar ocultas en app móvil.
    # Normalizamos únicamente las on_this_day del owner, sin borrar registros.
    normalize_rows = db_query(
        "select count(*) from memory "
        f"where \"ownerId\"='{owner_id}' and type='on_this_day' and \"showAt\" is not null "
        "and extract(hour from (\"showAt\" at time zone 'UTC'))::int <> 0;"
    )
    normalize_count = int(normalize_rows[0]) if normalize_rows else 0
    if normalize_count > 0 and not args.dry_run:
        db_exec(
            "update memory "
            "set \"showAt\" = ((date_trunc('day', (\"showAt\" at time zone 'UTC'))) at time zone 'UTC'), "
            "\"hideAt\" = (((date_trunc('day', (\"showAt\" at time zone 'UTC'))) at time zone 'UTC') + "
            "interval '1 day' - interval '1 milliseconds') "
            f"where \"ownerId\"='{owner_id}' and type='on_this_day' and \"showAt\" is not null "
            "and extract(hour from (\"showAt\" at time zone 'UTC'))::int <> 0;"
        )

    year_rows = db_query(
        "select y::text || '|' || string_agg(id_txt, ',' order by face_count desc, screen_rank asc, local_dt desc) "
        "from ("
        "select extract(year from a.\"localDateTime\")::int as y, "
        "a.id::text as id_txt, "
        "a.\"localDateTime\" as local_dt, "
        "count(af.\"assetId\")::int as face_count, "
        "case "
        "when lower(a.\"originalFileName\") like 'screenshot%' then 1 "
        "when lower(a.\"originalFileName\") like 'screen recording%' then 1 "
        "else 0 end as screen_rank "
        "from asset a "
        "left join asset_face af on af.\"assetId\"=a.id "
        f"where a.\"ownerId\"='{owner_id}' and a.\"deletedAt\" is null and a.status='active' and a.visibility='timeline' "
        f"and to_char(a.\"localDateTime\",'MM-DD')='{mmdd}' "
        "group by a.id"
        ") ranked group by y order by y;"
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
        show_date_utc = show_at.astimezone(dt.timezone.utc).date().isoformat()
        existing[(year, show_date_utc)] = m

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
        show_at = to_z(utc_midnight)
        hide_at = to_z(utc_midnight + dt.timedelta(days=1) - dt.timedelta(milliseconds=1))
        key = (year, target_local_date.isoformat())
        current = existing.get(key)

        if current is None:
            payload = {
                "type": "on_this_day",
                "data": {"year": year},
                "memoryAt": memory_at,
                "showAt": show_at,
                "hideAt": hide_at,
                "assetIds": ids,
            }
            if args.dry_run:
                print(f"DRYRUN create year={year} assets={len(ids)} showAt={show_at} hideAt={hide_at}")
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
        f"SUMMARY mmdd={mmdd} date={target_local_date.isoformat()} "
        f"backfilled_hideAt={backfill_count} normalized_showAt={normalize_count} "
        f"deduped={deduped} dedupe_merged_assets={dedupe_merged_assets} "
        f"created={created} patched={patched} kept={kept}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
