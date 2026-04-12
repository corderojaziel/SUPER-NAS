#!/usr/bin/env python3
"""
split_template_sheet.py

Separa plantillas desde un mosaico 3x3 y genera PNG con transparencia real en los huecos.
También permite escalar cada tarjeta para uso en runtime.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable, List, Set, Tuple

import cv2  # type: ignore
import numpy as np
from PIL import Image, ImageDraw, ImageFilter


THEME_MAP = {
    (1, 1): "floral",
    (1, 2): "space",
    (1, 3): "snoopy_oil",
    (2, 1): "carebears",
    (2, 2): "birds",
    (2, 3): "snoopy_western",
    (3, 1): "baby_shower",
    (3, 2): "forest",
    (3, 3): "lego",
}


def parse_omit(value: str) -> Set[Tuple[int, int]]:
    out: Set[Tuple[int, int]] = set()
    raw = (value or "").strip()
    if not raw:
        return out
    for token in raw.split(";"):
        token = token.strip()
        if not token:
            continue
        parts = [x.strip() for x in token.split(",")]
        if len(parts) != 2:
            continue
        try:
            r = int(parts[0])
            c = int(parts[1])
        except ValueError:
            continue
        if 1 <= r <= 3 and 1 <= c <= 3:
            out.add((r, c))
    return out


def grid_cells(width: int, height: int) -> List[Tuple[int, int, int, int, int, int]]:
    xs = [round(width * i / 3.0) for i in range(4)]
    ys = [round(height * i / 3.0) for i in range(4)]
    cells = []
    for r in range(1, 4):
        for c in range(1, 4):
            x0, x1 = xs[c - 1], xs[c]
            y0, y1 = ys[r - 1], ys[r]
            cells.append((r, c, x0, y0, x1, y1))
    return cells


def find_card_bbox(cell_bgr: np.ndarray) -> Tuple[int, int, int, int]:
    h, w = cell_bgr.shape[:2]
    hsv = cv2.cvtColor(cell_bgr, cv2.COLOR_BGR2HSV)
    sat = hsv[:, :, 1]
    val = hsv[:, :, 2]

    # Fondo de tarjeta: bajo saturation + alto brillo
    mask = np.where((sat < 50) & (val > 170), 255, 0).astype(np.uint8)
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (7, 7))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k, iterations=2)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, k, iterations=1)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    best = None
    best_area = -1
    min_area = int(0.16 * w * h)
    for c in contours:
        x, y, bw, bh = cv2.boundingRect(c)
        area = bw * bh
        if area < min_area:
            continue
        ar = bw / float(max(1, bh))
        if ar < 0.50 or ar > 0.90:
            continue
        if area > best_area:
            best_area = area
            best = (x, y, bw, bh)

    if best is None:
        # Fallback conservador centrado.
        mx = int(round(w * 0.07))
        my = int(round(h * 0.05))
        return (mx, my, w - 2 * mx, h - 2 * my)

    x, y, bw, bh = best
    pad = 2
    x0 = max(0, x - pad)
    y0 = max(0, y - pad)
    x1 = min(w, x + bw + pad)
    y1 = min(h, y + bh + pad)
    return (x0, y0, x1 - x0, y1 - y0)


def checker_holes_alpha(card_bgr: np.ndarray, max_holes: int = 3) -> np.ndarray:
    h, w = card_bgr.shape[:2]
    hsv = cv2.cvtColor(card_bgr, cv2.COLOR_BGR2HSV)
    sat = hsv[:, :, 1]
    val = hsv[:, :, 2]

    # Checkerboard típico: gris medio, baja saturación.
    raw = np.where((sat < 38) & (val >= 160) & (val <= 246), 255, 0).astype(np.uint8)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    raw = cv2.morphologyEx(raw, cv2.MORPH_OPEN, k, iterations=1)

    # Selección estable: tomar los componentes más grandes del checkerboard.
    num, labels, stats, _ = cv2.connectedComponentsWithStats(raw, 8)
    holes = np.zeros_like(raw)
    min_area = int(0.012 * w * h)
    comps = []
    for idx in range(1, num):
        area = int(stats[idx, cv2.CC_STAT_AREA])
        if area < min_area:
            continue
        x = int(stats[idx, cv2.CC_STAT_LEFT])
        y = int(stats[idx, cv2.CC_STAT_TOP])
        bw = int(stats[idx, cv2.CC_STAT_WIDTH])
        bh = int(stats[idx, cv2.CC_STAT_HEIGHT])
        ar = bw / float(max(1, bh))
        if ar > 6.0 or ar < 0.16:
            continue
        comps.append((area, idx))

    comps.sort(reverse=True)
    selected = comps[:max_holes]
    for _, idx in selected:
        holes[labels == idx] = 255

    # Fallback robusto para tarjetas de esta familia (3 slots):
    # círculo arriba-derecha + rect vertical + rect grande inferior.
    if len(selected) < max_holes:
        pil = Image.new("L", (w, h), 0)
        draw = ImageDraw.Draw(pil)

        d = int(round(min(w, h) * 0.37))
        cx = int(round(w * 0.67))
        cy = int(round(h * 0.21))
        draw.ellipse((cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2), fill=255)

        rx = int(round(w * 0.12))
        ry = int(round(h * 0.30))
        rw = int(round(w * 0.27))
        rh = int(round(h * 0.25))
        rr = int(round(min(rw, rh) * 0.18))
        draw.rounded_rectangle((rx, ry, rx + rw, ry + rh), radius=rr, fill=255)

        bx = int(round(w * 0.11))
        by = int(round(h * 0.57))
        bw = int(round(w * 0.77))
        bh = int(round(h * 0.33))
        br = int(round(min(bw, bh) * 0.10))
        draw.rounded_rectangle((bx, by, bx + bw, by + bh), radius=br, fill=255)

        holes = np.array(pil, dtype=np.uint8)

    alpha = np.full((h, w), 255, dtype=np.uint8)
    alpha[holes > 0] = 0
    return alpha


def upscale_png(card_bgra: np.ndarray, scale: float, target_height: int = 0) -> Image.Image:
    pil = Image.fromarray(cv2.cvtColor(card_bgra, cv2.COLOR_BGRA2RGBA))

    if target_height > 0:
        used_scale = float(target_height) / float(max(1, pil.height))
    else:
        used_scale = scale
    if used_scale <= 1.0:
        return pil

    nw = max(1, int(round(pil.width * used_scale)))
    nh = max(1, int(round(pil.height * used_scale)))

    # Calidad: escalar RGB y alpha por separado evita bordes sucios o semitransparencias borrosas.
    rgb = pil.convert("RGB").resize((nw, nh), Image.Resampling.LANCZOS)
    alpha = pil.getchannel("A").resize((nw, nh), Image.Resampling.NEAREST)
    out = Image.merge("RGBA", (*rgb.split(), alpha))

    # Enfoque moderado para recuperar detalle visual tras upscaling.
    out = out.filter(ImageFilter.UnsharpMask(radius=1.3, percent=140, threshold=2))
    out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=100, threshold=1))
    return out


def process_sheet(
    src: Path,
    out_dir: Path,
    scale: float,
    omit: Iterable[Tuple[int, int]],
    target_height: int = 0,
) -> List[Path]:
    img = cv2.imread(str(src), cv2.IMREAD_UNCHANGED)
    if img is None:
        raise RuntimeError(f"No pude leer: {src}")
    if img.shape[2] == 4:
        bgr = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
    else:
        bgr = img.copy()

    h, w = bgr.shape[:2]
    out_dir.mkdir(parents=True, exist_ok=True)
    omit_set = set(omit)
    outputs: List[Path] = []

    for (r, c, x0, y0, x1, y1) in grid_cells(w, h):
        if (r, c) in omit_set:
            continue
        cell = bgr[y0:y1, x0:x1]
        cx, cy, cw, ch = find_card_bbox(cell)
        card = cell[cy : cy + ch, cx : cx + cw]
        alpha = checker_holes_alpha(card, max_holes=3)
        card_bgra = cv2.cvtColor(card, cv2.COLOR_BGR2BGRA)
        card_bgra[:, :, 3] = alpha

        out_img = upscale_png(card_bgra, scale=scale, target_height=target_height)
        theme = THEME_MAP.get((r, c), f"r{r}c{c}")
        out = out_dir / f"template-sheet-{theme}.png"
        out_img.save(out)
        outputs.append(out)
    return outputs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", required=True, help="Ruta al mosaico 3x3")
    ap.add_argument("--out-dir", required=True, help="Directorio destino")
    ap.add_argument("--scale", type=float, default=4.0, help="Escala final por plantilla (ej. 4.0)")
    ap.add_argument(
        "--target-height",
        type=int,
        default=0,
        help="Altura final por plantilla (px). Si se usa, tiene prioridad sobre --scale.",
    )
    ap.add_argument(
        "--omit",
        default="1,1;1,3",
        help=(
            "Celdas a omitir en formato 'r,c;r,c' "
            "(por defecto omite floral arriba izquierda y snoopy_oil arriba derecha)."
        ),
    )
    args = ap.parse_args()

    omit = parse_omit(args.omit)
    out = process_sheet(
        Path(args.sheet),
        Path(args.out_dir),
        args.scale,
        omit,
        target_height=max(0, int(args.target_height)),
    )
    print(f"OK generated={len(out)}")
    for p in out:
        print(p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
