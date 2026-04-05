#!/usr/bin/env python3
"""
collage-template-refresh.py - refresca el banco de plantillas JSON via Gemini.

Genera plantillas reutilizables para collage-daily.py y las guarda en:
  /var/lib/immich/collage-templates/gemini
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import List, Optional, Tuple
from zoneinfo import ZoneInfo

SECRETS_FILE = "/etc/nas-secrets"
TEMPLATE_DIR = "/var/lib/immich/collage-templates/gemini"
TIMEZONE = "America/Mexico_City"
MAX_TEMPLATES_STORED = 60
TEMPLATE_SAFE_TOP = 165
TEMPLATE_SAFE_BOTTOM = 1280
TEMPLATE_MIN_SIZE = 80
TEMPLATE_CELL_GAP = 16
CANVAS_W = 1080
CANVAS_H = 1350
GEMINI_MODELS = [
    model.strip()
    for model in os.environ.get(
        "GEMINI_MODELS",
        "gemini-2.5-flash,gemini-2.0-flash,gemini-2.0-flash-lite",
    ).split(",")
    if model.strip()
]

MESES = {
    1: "enero", 2: "febrero", 3: "marzo", 4: "abril", 5: "mayo", 6: "junio",
    7: "julio", 8: "agosto", 9: "septiembre", 10: "octubre", 11: "noviembre", 12: "diciembre",
}
TEMPORADAS = {
    12: "invierno", 1: "invierno", 2: "invierno",
    3: "primavera", 4: "primavera", 5: "primavera",
    6: "verano", 7: "verano", 8: "verano",
    9: "otono", 10: "otono", 11: "otono",
}
LAYOUTS = {"columns", "story", "featured", "polaroid", "circle_hero", "grid"}
PALETTE_ALIASES = {
    "primavera": "primavera",
    "verano": "verano",
    "otono": "otono",
    "otoño": "otono",
    "invierno": "invierno",
    "default": "default",
}
HEX_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
ID_RE = re.compile(r"[^a-z0-9_-]+")


def read_secrets(path: str) -> dict:
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def normalize_palette_name(value: object) -> str:
    raw = str(value or "").strip().lower()
    return PALETTE_ALIASES.get(raw, "default")


def sanitize_id(value: object, fallback: str) -> str:
    raw = str(value or "").strip().lower().replace(" ", "-")
    raw = ID_RE.sub("-", raw).strip("-_")
    return raw[:48] or fallback


def extract_json_array_text(text: str) -> str:
    cleaned = (text or "").replace("```json", "").replace("```", "").strip()
    start = cleaned.find("[")
    end = cleaned.rfind("]")
    if start != -1 and end != -1 and end >= start:
        return cleaned[start:end + 1]
    return cleaned


def template_rects_overlap(a: Tuple[int, int, int, int], b: Tuple[int, int, int, int], gap: int=TEMPLATE_CELL_GAP) -> bool:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    return not (
        ax2 + gap <= bx1
        or bx2 + gap <= ax1
        or ay2 + gap <= by1
        or by2 + gap <= ay1
    )


def parse_cell(cell: object, max_photo_index: int=6) -> Optional[dict]:
    if not isinstance(cell, dict):
        return None
    try:
        x = int(cell["x"])
        y = int(cell["y"])
        w = int(cell["w"])
        h = int(cell["h"])
        photo_index = int(cell.get("photo_index", 0))
    except (KeyError, TypeError, ValueError):
        return None
    if photo_index < 0 or photo_index >= max_photo_index:
        return None
    shape = str(cell.get("shape", "rect")).strip().lower()
    if shape not in {"rect", "circle"}:
        shape = "rect"
    if shape == "circle":
        size = min(w, h)
        w = h = size
    if x < 0 or y < TEMPLATE_SAFE_TOP:
        return None
    if w < TEMPLATE_MIN_SIZE or h < TEMPLATE_MIN_SIZE:
        return None
    if x + w > CANVAS_W or y + h > TEMPLATE_SAFE_BOTTOM:
        return None
    radius = 20
    try:
        radius = int(cell.get("radius", 20) or 20)
    except (TypeError, ValueError):
        radius = 20
    return {
        "photo_index": photo_index,
        "x": x,
        "y": y,
        "w": w,
        "h": h,
        "shape": shape,
        "radius": max(0, min(radius, min(w, h) // 2)),
        "rect": (x, y, x + w, y + h),
    }


def normalize_layout_candidates(value: object) -> List[str]:
    if not isinstance(value, list):
        return []
    out: List[str] = []
    for raw in value:
        layout = str(raw or "").strip().lower()
        if layout in LAYOUTS and layout not in out:
            out.append(layout)
    return out


def infer_layout_candidates(cells: List[dict]) -> List[str]:
    circles = sum(1 for cell in cells if cell["shape"] == "circle")
    if circles:
        return ["circle_hero", "featured", "polaroid"]
    if len(cells) <= 2:
        return ["columns", "featured", "polaroid"]
    if len(cells) >= 5:
        return ["grid", "polaroid", "featured"]
    big_cells = sum(1 for cell in cells if cell["w"] >= 760 or cell["h"] >= 420)
    if big_cells:
        return ["featured", "polaroid", "grid"]
    return ["polaroid", "grid", "story"]


def normalize_decorations(value: object) -> List[dict]:
    if not isinstance(value, list):
        return []
    allowed = {"flower", "stem_flower", "wavy_line", "dots", "circle_deco"}
    out: List[dict] = []
    for raw in value[:10]:
        if not isinstance(raw, dict):
            continue
        deco_type = str(raw.get("type", "")).strip().lower()
        if deco_type not in allowed:
            continue
        deco = dict(raw)
        deco["type"] = deco_type
        out.append(deco)
    return out


def validate_template(template: object, index: int, today: str, season: str) -> Tuple[Optional[dict], str]:
    if not isinstance(template, dict):
        return None, "no es dict"
    raw_cells = template.get("cells")
    if not isinstance(raw_cells, list) or not raw_cells:
        return None, "sin celdas"

    cells: List[dict] = []
    used_rects: List[Tuple[int, int, int, int]] = []
    used_photo_indexes = set()
    for raw_cell in raw_cells:
        cell = parse_cell(raw_cell)
        if not cell:
            return None, "celda invalida"
        if cell["photo_index"] in used_photo_indexes:
            return None, "photo_index repetido"
        if any(template_rects_overlap(cell["rect"], rect) for rect in used_rects):
            return None, "celdas solapadas"
        used_photo_indexes.add(cell["photo_index"])
        used_rects.append(cell["rect"])
        cells.append(cell)

    template_id = sanitize_id(
        template.get("id"),
        f"gemini-{today}-{index:02d}-{hashlib.sha1(json.dumps(template, sort_keys=True, default=str).encode()).hexdigest()[:8]}",
    )
    try:
        min_photos_raw = int(template.get("min_photos", len(cells) or 1) or 1)
    except (TypeError, ValueError):
        min_photos_raw = len(cells) or 1
    min_photos = max(1, min(6, min_photos_raw))
    if len(cells) < min_photos:
        return None, "menos celdas que min_photos"

    background_color = str(template.get("background_color") or "").strip()
    if not HEX_COLOR_RE.fullmatch(background_color):
        background_color = "#FAF6F0"

    layout_candidates = normalize_layout_candidates(template.get("layout_candidates"))
    if not layout_candidates:
        layout_candidates = infer_layout_candidates(cells)

    normalized = {
        "id": template_id,
        "name": str(template.get("name") or template_id).strip()[:80] or template_id,
        "season": str(template.get("season") or season).strip().lower() or season,
        "mood": str(template.get("mood") or "familiar").strip().lower()[:40] or "familiar",
        "min_photos": min_photos,
        "background_color": background_color,
        "palette_name": normalize_palette_name(template.get("palette_name") or template.get("palette") or season),
        "cells": [
            {
                "photo_index": cell["photo_index"],
                "x": cell["x"],
                "y": cell["y"],
                "w": cell["w"],
                "h": cell["h"],
                "radius": cell["radius"],
                "shape": cell["shape"],
            }
            for cell in cells
        ],
        "decorations": normalize_decorations(template.get("decorations")),
        "layout_candidates": layout_candidates,
        "created_at": str(template.get("created_at") or today),
        "source": "gemini",
    }
    return normalized, "ok"


def ask_gemini_templates(api_key: str, month: int, count: int) -> List[dict]:
    season = TEMPORADAS[month]
    mes = MESES[month]
    prompt = f"""Eres un director de arte para collages familiares.

Inventa {count} plantillas MUY DIFERENTES entre si para fotos de {mes}.
Quiero variedad real: no repitas siempre featured o grid. Piensa en composiciones
editoriales, asimetricas, romanticas, casuales, de retrato, de grupo, de viaje
y de celebracion. La temporada {season} puede influir en color y decoracion,
pero no debe volver todas las plantillas iguales.

Canvas fijo: 1080x1350.
Header reservado: y < 165 no se toca con fotos.
Footer reservado: y+h debe quedar <= 1280.

Devuelve SOLO un JSON array, sin markdown:
[
  {{
    "id": "template_nombre_unico",
    "name": "Nombre corto",
    "season": "{season}",
    "mood": "familiar|aventura|celebracion|cotidiano|retrato",
    "min_photos": 2,
    "background_color": "#F8F2EA",
    "palette_name": "primavera|verano|otono|invierno|default",
    "cells": [
      {{"photo_index":0,"x":20,"y":175,"w":700,"h":460,"radius":28,"shape":"rect"}},
      {{"photo_index":1,"x":748,"y":210,"w":312,"h":380,"radius":24,"shape":"rect"}}
    ],
    "decorations": [
      {{"type":"flower","x":930,"y":85,"size":34,"color":"#E6641E"}},
      {{"type":"circle_deco","cx":980,"cy":88,"r":120,"alpha":40,"color":"#F0C544"}}
    ],
    "layout_candidates": ["featured","polaroid"]
  }}
]

Reglas:
- Cada plantilla debe servir para 2-6 fotos.
- Entre celdas debe haber al menos 16 px de separacion.
- No solapes celdas.
- Toda foto debe quedar dentro del canvas.
- Cada celda debe cumplir: x>=0, y>=165, x+w<=1080, y+h<=1280, w>=80, h>=80.
- Usa "circle" solo cuando una foto se presta claramente a retrato.
- Varia el peso visual: algunas plantillas con una hero, otras mas balanceadas.
- Mezcla estilos: featured, columns, polaroid, circle_hero, grid, story, pero tambien
  composiciones originales dentro de esas familias.
- layout_candidates debe listar 1-3 layouts hardcodeados que mas se parecen.
- No devuelvas explicacion fuera del JSON."""

    last_error = "sin modelos"
    for model in GEMINI_MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        generation_config = {"temperature": 0.8, "maxOutputTokens": 4096}
        if model.startswith("gemini-2.5"):
            generation_config["thinkingConfig"] = {"thinkingBudget": 0}
        body = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": generation_config,
        }
        try:
            request = urllib.request.Request(
                url,
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = json.loads(response.read().decode())
            text = (((payload.get("candidates") or [{}])[0].get("content") or {}).get("parts") or [{}])[0].get("text", "")
            parsed = json.loads(extract_json_array_text(text))
            if isinstance(parsed, list):
                return parsed
            last_error = f"{model}: respuesta no es lista"
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "ignore")
            last_error = f"{model}: HTTP {exc.code} {raw[:200]}"
            print(f"  WARN Gemini {model}: HTTP {exc.code}", file=sys.stderr)
        except Exception as exc:
            last_error = f"{model}: {exc}"
            print(f"  WARN Gemini {model}: {exc}", file=sys.stderr)
    raise RuntimeError(last_error)


def rotate_old(template_dir: Path, keep: int) -> int:
    removed = 0
    templates = sorted(
        template_dir.glob("*.json"),
        key=lambda path: path.stat().st_mtime if path.exists() else 0,
    )
    while len(templates) > keep:
        oldest = templates.pop(0)
        try:
            oldest.unlink()
            removed += 1
        except OSError:
            continue
    return removed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--secrets-file", default=SECRETS_FILE)
    parser.add_argument("--timezone", default=os.environ.get("MEMORIES_TIMEZONE", TIMEZONE))
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    count = max(1, min(12, int(args.count)))
    try:
        zone = ZoneInfo(args.timezone)
    except Exception:
        zone = dt.timezone.utc

    secrets = read_secrets(args.secrets_file)
    api_key = secrets.get("GEMINI_API_KEY", "")
    if not api_key:
        print("ERROR: falta GEMINI_API_KEY", file=sys.stderr)
        return 2

    now = dt.datetime.now(zone)
    today = now.date().isoformat()
    season = TEMPORADAS[now.month]
    print(f"INFO fecha={today} temporada={season} count={count}")

    try:
        templates = ask_gemini_templates(api_key, now.month, count)
    except RuntimeError as exc:
        print(f"ERROR Gemini: {exc}", file=sys.stderr)
        return 1

    print(f"INFO Gemini devolvio {len(templates)} plantilla(s)")
    valid: List[dict] = []
    skipped = 0
    for index, template in enumerate(templates):
        normalized, reason = validate_template(template, index, today, season)
        if not normalized:
            skipped += 1
            print(f"  SKIP plantilla {index}: {reason}")
            continue
        valid.append(normalized)
        print(
            f"  OK plantilla {index}: id={normalized['id']} "
            f"celdas={len(normalized['cells'])} "
            f"paleta={normalized['palette_name']} "
            f"layouts={','.join(normalized['layout_candidates'])}"
        )

    if args.dry_run:
        print(f"SUMMARY dry_run validas={len(valid)} saltadas={skipped}")
        return 0 if valid else 1

    template_dir = Path(TEMPLATE_DIR)
    template_dir.mkdir(parents=True, exist_ok=True)
    saved = 0
    for template in valid:
        output_path = template_dir / f"{today}_{template['id']}.json"
        output_path.write_text(
            json.dumps(template, ensure_ascii=False, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        saved += 1
        print(f"  Guardada: {output_path.name}")

    removed = rotate_old(template_dir, MAX_TEMPLATES_STORED)
    total = len(list(template_dir.glob("*.json")))
    print(f"SUMMARY guardadas={saved} saltadas={skipped} rotadas={removed} en_disco={total}")
    return 0 if saved else 1


if __name__ == "__main__":
    raise SystemExit(main())
