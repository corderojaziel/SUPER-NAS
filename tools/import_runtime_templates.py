#!/usr/bin/env python3
"""
Importa plantillas PNG (con huecos checker/gray) al runtime de collage:
- genera PNG overlay con alpha real en los slots
- genera JSON seeded para collage-daily (render_mode=overlay_png)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from template_probe_people import detect_slots  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_DIR = ROOT / "assets" / "collage-templates" / "runtime-pack"
SEEDED_DIR = ROOT / "assets" / "collage-templates" / "seeded"

SRC_FILES: List[Tuple[str, str]] = [
    ("school", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_24_09 p.m..png"),
    ("neon", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_14_18 p.m..png"),
    ("dino", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_13_01 p.m..png"),
    ("carnival", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_10_17 p.m..png"),
    ("beach", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_09_04 p.m..png"),
    ("sky", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_07_49 p.m..png"),
    ("hiking", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 07_05_53 p.m..png"),
    ("pop", "/mnt/c/Users/jazie/Downloads/ChatGPT Image 11 abr 2026, 06_57_17 p.m..png"),
]

PRESETS: Dict[str, Dict[str, str]] = {
    "school": {"name": "School Board", "mood": "cotidiano", "palette_name": "default", "visual_system": "notebook"},
    "neon": {"name": "Neon Flow", "mood": "celebracion", "palette_name": "default", "visual_system": "confetti"},
    "dino": {"name": "Dino Park", "mood": "familiar", "palette_name": "verano", "visual_system": "travel"},
    "carnival": {"name": "Carnival Fun", "mood": "celebracion", "palette_name": "verano", "visual_system": "confetti"},
    "beach": {"name": "Beach Day", "mood": "aventura", "palette_name": "verano", "visual_system": "travel"},
    "sky": {"name": "Sky Adventure", "mood": "aventura", "palette_name": "primavera", "visual_system": "route"},
    "hiking": {"name": "Hiking Trail", "mood": "aventura", "palette_name": "otono", "visual_system": "route"},
    "pop": {"name": "Pop Colors", "mood": "celebracion", "palette_name": "verano", "visual_system": "confetti"},
}

# profile puntual para plantilla abstracta que no usa checkerboard clásico.
PROFILE_OVERRIDES = {
    "pop": "doodle_3slots",
}


def classify_shape(slot) -> str:
    ratio = max(slot.w, slot.h) / float(max(1, min(slot.w, slot.h)))
    fill_ratio = 1.0
    try:
        if slot.mask is not None:
            arr = np.array(slot.mask.convert("L"))
            if arr.size:
                fill_ratio = float((arr > 8).sum()) / float(max(1, slot.w * slot.h))
    except Exception:
        fill_ratio = 1.0

    # Hueco muy curvo y casi cuadrado -> círculo.
    if fill_ratio <= 0.90 and ratio <= 1.16:
        return "circle"
    # Hueco curvo alargado -> elipse.
    if fill_ratio <= 0.92 and ratio <= 3.20:
        return "ellipse"
    return "rect"


def infer_layout_candidates(cells: List[dict]) -> List[str]:
    slot_count = len(cells)
    has_round = any(c["shape"] in {"circle", "ellipse"} for c in cells)
    if slot_count <= 2:
        return ["columns", "featured", "polaroid"]
    if slot_count == 3:
        if has_round:
            return ["featured", "circle_hero", "polaroid"]
        return ["grid", "featured", "polaroid"]
    return ["grid", "story", "polaroid"]


def draw_cutout(draw: ImageDraw.ImageDraw, cell: dict) -> None:
    x, y, w, h = int(cell["x"]), int(cell["y"]), int(cell["w"]), int(cell["h"])
    shape = str(cell["shape"])
    if shape == "circle":
        d = min(w, h)
        ox = x + (w - d) // 2
        oy = y + (h - d) // 2
        draw.ellipse((ox, oy, ox + d - 1, oy + d - 1), fill=0)
        return
    if shape == "ellipse":
        draw.ellipse((x, y, x + w - 1, y + h - 1), fill=0)
        return
    radius = max(14, int(min(w, h) * 0.12))
    draw.rounded_rectangle((x, y, x + w - 1, y + h - 1), radius=radius, fill=0)


def build_cells(slots: list) -> Tuple[List[dict], List[object]]:
    ordered = sorted(slots, key=lambda s: (-int(s.area), int(s.y), int(s.x)))
    cells: List[dict] = []
    for idx, s in enumerate(ordered):
        shape = classify_shape(s)
        radius = max(14, int(min(s.w, s.h) * 0.12))
        if shape in {"circle", "ellipse"}:
            radius = min(s.w, s.h) // 2
        cells.append(
            {
                "photo_index": idx,
                "x": int(s.x),
                "y": int(s.y),
                "w": int(s.w),
                "h": int(s.h),
                "radius": int(radius),
                "shape": shape,
            }
        )
    return cells, ordered


def process_one(theme: str, src_file: str) -> Tuple[Path, Path, int]:
    src = Path(src_file)
    if not src.exists():
        raise RuntimeError(f"No existe {src}")

    profile = PROFILE_OVERRIDES.get(theme, "auto")
    slots, _ = detect_slots(str(src), template_profile=profile)
    if len(slots) < 2:
        raise RuntimeError(f"Slots insuficientes en {src.name}: {len(slots)}")

    cells, ordered_slots = build_cells(slots)
    preset = PRESETS.get(theme, {})

    runtime_name = f"template-runtime-{theme}.png"
    runtime_path = RUNTIME_DIR / runtime_name
    seeded_path = SEEDED_DIR / f"seeded-runtime-{theme}.json"
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    SEEDED_DIR.mkdir(parents=True, exist_ok=True)

    overlay = Image.open(src).convert("RGBA")
    alpha = Image.new("L", overlay.size, 255)
    for slot in ordered_slots:
        local_mask = slot.mask if slot.mask is not None else make_shape_mask(slot.w, slot.h, classify_shape(slot))
        if local_mask.size != (slot.w, slot.h):
            local_mask = local_mask.resize((slot.w, slot.h), Image.Resampling.NEAREST)
        # Apaga alpha exactamente donde el hueco real existe.
        alpha.paste(0, (int(slot.x), int(slot.y)), local_mask)
    overlay.putalpha(alpha)
    overlay.save(runtime_path)

    w, h = overlay.size
    template = {
        "id": f"runtime-{theme}",
        "name": preset.get("name", f"Runtime {theme}"),
        "season": "default",
        "mood": preset.get("mood", "familiar"),
        "min_photos": 2 if len(cells) >= 2 else 1,
        "background_color": "#F4F4F4",
        "palette_name": preset.get("palette_name", "default"),
        "visual_system": preset.get("visual_system", "editorial"),
        "decor_family": preset.get("visual_system", "editorial"),
        "header_style": "minimal",
        "footer_style": "minimal",
        "render_mode": "overlay_png",
        "template_png": f"runtime-pack/{runtime_name}",
        "canvas_w": int(w),
        "canvas_h": int(h),
        "total_slots": len(cells),
        "cells": cells,
        "decorations": [],
        "layout_candidates": infer_layout_candidates(cells),
        "created_at": "2026-04-11",
        "source": "seeded_runtime",
    }
    seeded_path.write_text(json.dumps(template, ensure_ascii=False, indent=2), encoding="utf-8")
    return runtime_path, seeded_path, len(cells)


def main() -> int:
    ok = 0
    for theme, src in SRC_FILES:
        runtime, seeded, slots = process_one(theme, src)
        print(f"OK {theme}: slots={slots} runtime={runtime} json={seeded}")
        ok += 1
    print(f"DONE imported={ok}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
