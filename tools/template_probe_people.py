#!/usr/bin/env python3
"""
template_probe_people.py

Prueba de composición sobre plantilla PNG con huecos tipo checkerboard:
- Detecta slots automáticamente en la plantilla
- Prioriza fotos con personas (detección facial OpenCV)
- Recorta centrado en rostros para encajar en cada slot
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import numpy as np
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2  # type: ignore
from PIL import Image, ImageOps, ImageDraw, ImageChops


@dataclass
class Slot:
    x: int
    y: int
    w: int
    h: int
    shape: str  # rect|circle
    area: int
    mask: Optional[Image.Image] = None


@dataclass
class PhotoCandidate:
    path: str
    score: float
    faces: int
    face_center: Optional[Tuple[float, float]]
    face_ratio: float
    face_box: Optional[Tuple[float, float, float, float]] = None  # x,y,w,h normalizado


def load_secrets(path: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    p = Path(path)
    if not p.exists():
        return out
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def img_to_b64(path: str, max_px: int = 512) -> str:
    img = ImageOps.exif_transpose(Image.open(path).convert("RGB"))
    img.thumbnail((max_px, max_px), Image.Resampling.LANCZOS)
    from io import BytesIO

    bio = BytesIO()
    img.save(bio, format="JPEG", quality=88, optimize=True)
    return base64.b64encode(bio.getvalue()).decode("ascii")


def _parse_json_from_text(raw: str) -> dict:
    raw = (raw or "").strip()
    if not raw:
        return {}
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:].strip()
    try:
        return json.loads(raw)
    except Exception:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(raw[start : end + 1])
            except Exception:
                return {}
        return {}


def ask_gemini_photo_order(
    candidates: List[PhotoCandidate],
    slots_count: int,
    api_key: str,
    models: List[str],
) -> Tuple[List[int], str]:
    if not api_key:
        return [], "missing_api_key"
    if not candidates:
        return [], "no_candidates"

    meta_lines = []
    parts: List[dict] = []
    for idx, c in enumerate(candidates):
        meta_lines.append(
            f"- idx={idx} faces={c.faces} face_ratio={c.face_ratio:.4f} name={Path(c.path).name}"
        )
        try:
            b64 = img_to_b64(c.path, max_px=512)
            parts.append({"text": f"candidate_{idx}"})
            parts.append({"inlineData": {"mimeType": "image/jpeg", "data": b64}})
        except Exception:
            continue

    prompt = (
        "Eres curador visual de collage familiar.\n"
        f"Necesito exactamente {slots_count} fotos para un collage.\n"
        "Reglas:\n"
        "1) Prioriza fotos con personas visibles y rostros claros.\n"
        "2) Evita fotos borrosas o poco informativas.\n"
        "3) Busca variedad (no elegir fotos casi iguales).\n"
        "4) Devuelve índices únicos y válidos.\n\n"
        "Metadata de candidatos:\n"
        + "\n".join(meta_lines)
        + "\n\nResponde SOLO JSON con esta forma:\n"
        '{"photo_order":[0,1,2],"reason":"breve"}'
    )
    content_parts = [{"text": prompt}] + parts
    payload = {
        "contents": [{"role": "user", "parts": content_parts}],
        "generationConfig": {
            "temperature": 0.15,
            "responseMimeType": "application/json",
        },
    }

    body = json.dumps(payload).encode("utf-8")
    last_err = "unknown"
    for model in models:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=35) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            text = (
                data.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            parsed = _parse_json_from_text(text)
            order = parsed.get("photo_order", [])
            if not isinstance(order, list):
                return [], f"{model}:invalid_order"
            normalized: List[int] = []
            for x in order:
                try:
                    v = int(x)
                except Exception:
                    continue
                if 0 <= v < len(candidates) and v not in normalized:
                    normalized.append(v)
            if normalized:
                return normalized[:slots_count], model
            return [], f"{model}:empty_order"
        except urllib.error.HTTPError as exc:
            last_err = f"{model}:http_{exc.code}"
        except Exception as exc:
            last_err = f"{model}:{exc}"
    return [], last_err


def make_shape_mask(w: int, h: int, shape: str) -> Image.Image:
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    if shape == "circle":
        d.ellipse((0, 0, w - 1, h - 1), fill=255)
    else:
        d.rectangle((0, 0, w - 1, h - 1), fill=255)
    return m


def fixed_slots_for_template(width: int, height: int) -> List[Slot]:
    # Coordenadas base calibradas sobre plantilla 1024x1536.
    # Estas 3 zonas son los huecos reales para fotos:
    #  - círculo superior derecho
    #  - rectángulo vertical izquierdo
    #  - rectángulo grande inferior
    sx = width / 1024.0
    sy = height / 1536.0
    defs = [
        # El círculo se amplía para cubrir TODO el hueco checkerboard.
        ("circle", 396, 47, 528, 528),
        ("rect",   124, 372, 278, 385),
        # Reducimos alto del slot inferior para no invadir flores del borde inferior.
        ("rect",   124, 772, 783, 575),
    ]
    out: List[Slot] = []
    for shape, x, y, w, h in defs:
        xx = int(round(x * sx))
        yy = int(round(y * sy))
        ww = int(round(w * sx))
        hh = int(round(h * sy))
        slot_mask = make_shape_mask(ww, hh, shape)
        out.append(Slot(x=xx, y=yy, w=ww, h=hh, shape=shape, area=ww * hh, mask=slot_mask))
    return out


def apply_template_mask_to_slots(slots: List[Slot], template_mask: "cv2.typing.MatLike") -> List[Slot]:
    refined: List[Slot] = []
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    for slot in slots:
        crop = template_mask[slot.y : slot.y + slot.h, slot.x : slot.x + slot.w]
        use_geom = False
        if crop is None or crop.size == 0:
            use_geom = True
        else:
            local = cv2.morphologyEx(crop, cv2.MORPH_CLOSE, k, iterations=1)
            nz = int(cv2.countNonZero(local))
            # Si el detector se cayó en esa zona, revertimos a geometría pura.
            if nz < int(0.20 * slot.w * slot.h):
                use_geom = True
            else:
                local_mask = Image.fromarray(local, mode="L")
                if slot.shape == "circle":
                    local_mask = ImageChops.multiply(local_mask, make_shape_mask(slot.w, slot.h, "circle"))
        if use_geom:
            local_mask = make_shape_mask(slot.w, slot.h, slot.shape)
        refined.append(
            Slot(
                x=slot.x,
                y=slot.y,
                w=slot.w,
                h=slot.h,
                shape=slot.shape,
                area=slot.area,
                mask=local_mask,
            )
        )
    return refined


def build_placeholder_mask(width: int, height: int, slots: List[Slot]) -> Image.Image:
    mask = Image.new("L", (width, height), 0)
    for slot in slots:
        local_mask = slot.mask if slot.mask is not None else make_shape_mask(slot.w, slot.h, slot.shape)
        if local_mask.size != (slot.w, slot.h):
            local_mask = local_mask.resize((slot.w, slot.h), Image.Resampling.NEAREST)
        mask.paste(local_mask, (slot.x, slot.y), local_mask)
    return mask


def detect_slots(template_path: str, min_area: int = 12000, force_fixed_slots: bool = False) -> Tuple[List[Slot], Image.Image]:
    img = cv2.imread(template_path, cv2.IMREAD_COLOR)
    if img is None:
        raise RuntimeError(f"No pude leer plantilla: {template_path}")
    h_img, w_img = img.shape[:2]

    b, g, r = cv2.split(img)
    maxc = cv2.max(cv2.max(r, g), b)
    minc = cv2.min(cv2.min(r, g), b)
    sat = maxc - minc

    # Detecta gris checkerboard: baja saturación, brillo medio/alto, no blanco puro.
    mask = cv2.inRange(sat, 0, 18)
    vmask = cv2.inRange(maxc, 198, 242)
    mask = cv2.bitwise_and(mask, vmask)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)

    if force_fixed_slots:
        fixed_slots = fixed_slots_for_template(w_img, h_img)
        fixed_slots = apply_template_mask_to_slots(fixed_slots, mask)
        fixed_mask = build_placeholder_mask(w_img, h_img, fixed_slots)
        return fixed_slots, fixed_mask

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    slots: List[Slot] = []
    for c in contours:
        area = int(cv2.contourArea(c))
        if area < min_area:
            continue
        x, y, w, h = cv2.boundingRect(c)
        if w < 80 or h < 80:
            continue
        bbox_area = int(w * h)
        if bbox_area <= 0:
            continue
        fill_ratio = float(area) / float(bbox_area)
        # Descarta contornos "marco" muy grandes y huecos, típicos del borde
        # del checkerboard que no representan un slot real.
        if fill_ratio < 0.28:
            continue
        peri = cv2.arcLength(c, True)
        circularity = 0.0 if peri <= 0 else float(4 * math.pi * area / (peri * peri))
        is_circle = abs(w - h) / max(1, max(w, h)) < 0.18 and circularity > 0.67
        comp = cv2.drawContours(
            cv2.cvtColor(cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2GRAY) * 0,
            [c],
            -1,
            255,
            thickness=-1,
        )
        local = comp[y : y + h, x : x + w]
        slot_mask = Image.fromarray(local, mode="L")
        slots.append(
            Slot(
                x=x,
                y=y,
                w=w,
                h=h,
                shape="circle" if is_circle else "rect",
                area=w * h,
                mask=slot_mask,
            )
        )

    slots.sort(key=lambda s: s.area, reverse=True)
    global_mask_img = Image.fromarray(mask, mode="L")

    image_area = float(w_img * h_img)
    suspicious = (
        len(slots) < 3
        or len(slots) > 6
        or (slots and (slots[0].area / image_area) > 0.42)
    )
    if suspicious:
        fixed_slots = fixed_slots_for_template(w_img, h_img)
        fixed_slots = apply_template_mask_to_slots(fixed_slots, mask)
        fixed_mask = build_placeholder_mask(w_img, h_img, fixed_slots)
        return fixed_slots, fixed_mask
    return slots, global_mask_img


def load_face_detector() -> cv2.CascadeClassifier:
    candidates = []
    cv2_data = getattr(getattr(cv2, "data", None), "haarcascades", "")
    if cv2_data:
        candidates.append(str(Path(cv2_data) / "haarcascade_frontalface_default.xml"))
    candidates.extend(
        [
            "/usr/share/opencv4/haarcascades/haarcascade_frontalface_default.xml",
            "/usr/share/opencv/haarcascades/haarcascade_frontalface_default.xml",
        ]
    )
    for cascade_path in candidates:
        if not Path(cascade_path).exists():
            continue
        detector = cv2.CascadeClassifier(cascade_path)
        if not detector.empty():
            return detector
    raise RuntimeError("No pude cargar haarcascade frontalface en rutas conocidas.")


def score_photo(path: str, detector: cv2.CascadeClassifier) -> PhotoCandidate:
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        return PhotoCandidate(path=path, score=-1e9, faces=0, face_center=None, face_ratio=0.0, face_box=None)
    h0, w0 = img.shape[:2]
    scale = 1.0
    max_side = max(w0, h0)
    if max_side > 640:
        scale = 640.0 / float(max_side)
        img = cv2.resize(img, (int(w0 * scale), int(h0 * scale)), interpolation=cv2.INTER_AREA)
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    gray = cv2.equalizeHist(gray)

    faces = detector.detectMultiScale(gray, scaleFactor=1.08, minNeighbors=4, minSize=(28, 28))
    count = int(len(faces))
    best_area = 0.0
    fx = fy = 0.5
    best_box: Optional[Tuple[float, float, float, float]] = None
    if count > 0:
        # rostro más grande para centrar recorte
        bx, by, bw, bh = max(faces, key=lambda f: int(f[2]) * int(f[3]))
        best_area = (bw * bh) / float(max(1, w * h))
        fx = (bx + bw * 0.5) / float(w)
        fy = (by + bh * 0.5) / float(h)
        best_box = (
            float(bx) / float(max(1, w)),
            float(by) / float(max(1, h)),
            float(bw) / float(max(1, w)),
            float(bh) / float(max(1, h)),
        )

    # score favorece personas y rostros visibles
    score = count * 1000.0 + best_area * 50000.0
    return PhotoCandidate(
        path=path,
        score=score,
        faces=count,
        face_center=(fx, fy) if count > 0 else None,
        face_ratio=best_area,
        face_box=best_box,
    )


def collect_preview_paths(root: str, max_items: int = 1200) -> List[str]:
    files: List[Tuple[float, str]] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith("_preview.jpeg"):
                continue
            p = os.path.join(dirpath, name)
            try:
                mtime = os.path.getmtime(p)
            except OSError:
                continue
            files.append((mtime, p))
    files.sort(key=lambda x: x[0], reverse=True)
    return [p for _m, p in files[:max_items]]


def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def fit_face_aware(
    img: Image.Image,
    out_w: int,
    out_h: int,
    face_center: Optional[Tuple[float, float]],
    face_box: Optional[Tuple[float, float, float, float]] = None,
    safe_bottom_ratio: float = 1.0,
) -> Image.Image:
    iw, ih = img.size
    if iw <= 0 or ih <= 0:
        return img.resize((out_w, out_h), Image.Resampling.LANCZOS)
    target_ar = out_w / float(out_h)
    src_ar = iw / float(ih)

    fx, fy = face_center if face_center else (0.5, 0.45 if ih >= iw else 0.5)
    fx = clamp(fx, 0.08, 0.92)
    fy = clamp(fy, 0.08, 0.92)

    if src_ar > target_ar:
        crop_h = ih
        crop_w = int(round(crop_h * target_ar))
        cx = fx * iw
        left = int(round(clamp(cx - crop_w * 0.5, 0, iw - crop_w)))
        box = (left, 0, left + crop_w, ih)
    else:
        crop_w = iw
        crop_h = int(round(crop_w / target_ar))
        cy = fy * ih
        top = int(round(clamp(cy - crop_h * 0.52, 0, ih - crop_h)))

        # Regla dura de encuadre:
        # forzamos el recorte a mantener el rostro dentro de una banda vertical
        # segura del slot final para evitar caras demasiado arriba/abajo.
        top_min = 0.0
        top_max = float(max(0, ih - crop_h))

        # Si la máscara del slot tapa parte inferior (flores), asegura que la
        # parte baja del rostro quede por encima de esa zona.
        if face_box and safe_bottom_ratio < 0.995:
            _fx, fby, _fw, fbh = face_box
            face_bottom_src = (fby + fbh) * ih
            y_limit_ratio = clamp(safe_bottom_ratio - 0.03, 0.60, 0.98)
            top_min = max(top_min, face_bottom_src - (y_limit_ratio * crop_h))

        if face_center is not None:
            face_center_src = fy * ih
            min_face_y_out = 0.36 if safe_bottom_ratio < 0.995 else 0.32
            max_face_y_out = safe_bottom_ratio - 0.12 if safe_bottom_ratio < 0.995 else 0.68
            max_face_y_out = clamp(max_face_y_out, min_face_y_out + 0.08, 0.86)

            # Centro del rostro dentro de la banda [min_face_y_out, max_face_y_out].
            top_max = min(top_max, face_center_src - (min_face_y_out * crop_h))
            top_min = max(top_min, face_center_src - (max_face_y_out * crop_h))

            # Si hay box facial, añade restricciones de visibilidad del box.
            if face_box is not None:
                ftop_src = face_box[1] * ih
                fbot_src = (face_box[1] + face_box[3]) * ih
                min_face_top_out = 0.10
                max_face_bottom_out = clamp(safe_bottom_ratio - 0.04, 0.60, 0.96)
                top_max = min(top_max, ftop_src - (min_face_top_out * crop_h))
                top_min = max(top_min, fbot_src - (max_face_bottom_out * crop_h))

        if top_min <= top_max:
            top = float(clamp(top, top_min, top_max))
        else:
            # Si no hay solución exacta, usa el punto medio del conflicto y
            # clampa a límites físicos de la imagen.
            target = (top_min + top_max) * 0.5
            top = float(clamp(target, 0.0, float(max(0, ih - crop_h))))
        top = int(round(top))
        box = (0, top, iw, top + crop_h)

    return img.crop(box).resize((out_w, out_h), Image.Resampling.LANCZOS)


def paste_into_slot(canvas: Image.Image, slot: Slot, photo: Image.Image) -> None:
    fitted = fit_face_aware(
        photo,
        slot.w,
        slot.h,
        getattr(photo, "_face_center", None),
        getattr(photo, "_face_box", None),
        getattr(photo, "_safe_bottom_ratio", 1.0),
    )
    base_mask = slot.mask.copy() if slot.mask is not None else make_shape_mask(slot.w, slot.h, slot.shape)
    if base_mask.size != (slot.w, slot.h):
        base_mask = base_mask.resize((slot.w, slot.h), Image.Resampling.NEAREST)
    if slot.shape == "circle":
        circle = make_shape_mask(slot.w, slot.h, "circle")
        base_mask = ImageChops.multiply(base_mask, circle)
    canvas.paste(fitted, (slot.x, slot.y), base_mask)


def slot_safe_bottom_ratio(slot: Slot) -> float:
    """Devuelve hasta qué porcentaje vertical se ve bien el centro del slot.
    1.0 = sin oclusión; <1.0 = parte baja tapada por diseño (flores).
    """
    if slot.mask is None:
        return 1.0
    arr = np.array(slot.mask.convert("L"))
    h, w = arr.shape[:2]
    if h < 4 or w < 4:
        return 1.0
    x0 = int(round(w * 0.30))
    x1 = int(round(w * 0.70))
    core = arr[:, x0:x1] if x1 > x0 else arr
    row_cov = (core > 0).sum(axis=1) / float(max(1, core.shape[1]))
    safe_rows = [i for i, cov in enumerate(row_cov.tolist()) if cov >= 0.96]
    if not safe_rows:
        return 0.88
    return float(max(safe_rows)) / float(max(1, h - 1))


def assign_candidates_to_slots(slots: List[Slot], pool: List[PhotoCandidate]) -> List[PhotoCandidate]:
    """Asigna candidatos por slot minimizando riesgo de cara tapada."""
    assigned: List[PhotoCandidate] = []
    used: set[str] = set()
    for slot in slots:
        safe_bottom = slot_safe_bottom_ratio(slot)
        best: Optional[PhotoCandidate] = None
        best_score = -10e18
        for c in pool:
            if c.path in used:
                continue
            s = c.score
            if c.faces > 0 and c.face_center is not None:
                fy = c.face_center[1]
                # Penaliza caras que caen muy abajo cuando hay flores.
                if safe_bottom < 0.995:
                    overflow = fy - (safe_bottom - 0.10)
                    if overflow > 0:
                        s -= overflow * 14000.0
                    if c.face_box is not None:
                        fb = c.face_box[1] + c.face_box[3]
                        overflow_b = fb - (safe_bottom - 0.04)
                        if overflow_b > 0:
                            s -= overflow_b * 18000.0
                    # premio a caras altas/centradas en slots con oclusión inferior
                    s += max(0.0, (safe_bottom - 0.12) - fy) * 2200.0

                # En slots rectangulares grandes evita rostros excesivamente altos.
                # Si la cara viene muy arriba en la foto, el recorte suele verse "cortado".
                if slot.shape == "rect" and slot.area >= 250000:
                    high_gap = 0.36 - fy
                    if high_gap > 0:
                        s -= high_gap * 25000.0
                    # Favorece rostro algo más bajo/centrado en el slot grande inferior.
                    s -= abs(fy - 0.48) * 6000.0
                    if fy < 0.28:
                        s -= 30000.0
            else:
                # Si no hay caras, ligera penalización frente a candidatas humanas.
                s -= 350.0
            if s > best_score:
                best_score = s
                best = c
        if best is None:
            break
        used.add(best.path)
        assigned.append(best)
    return assigned


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--thumb-root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-candidates", type=int, default=800)
    ap.add_argument("--force-fixed-slots", action="store_true", help="Usa los 3 slots florales fijos y evita detección checkerboard.")
    ap.add_argument("--secrets-file", default="/etc/nas-secrets")
    ap.add_argument("--gemini-api-key", default=os.environ.get("GEMINI_API_KEY", ""))
    ap.add_argument("--gemini-models", default=os.environ.get("GEMINI_MODELS", "gemini-2.5-flash,gemini-2.0-flash,gemini-2.0-flash-lite"))
    ap.add_argument("--gemini-candidates", type=int, default=8, help="Cantidad máxima de candidatos enviados a Gemini.")
    ap.add_argument("--no-gemini", action="store_true", help="Desactiva Gemini y usa solo selección local.")
    args = ap.parse_args()

    template_name = Path(args.template).name.lower()
    force_fixed = args.force_fixed_slots
    # Los slots fijos están calibrados para plantilla floral 1024x1536.
    # En otras plantillas (doodle/birds/stars, etc.) degradan el resultado.
    if force_fixed and "floral" not in template_name:
        print(
            "INFO --force-fixed-slots está calibrado para floral; "
            "se usará detección automática de huecos para esta plantilla."
        )
        force_fixed = False

    slots, placeholder_mask = detect_slots(args.template, force_fixed_slots=force_fixed)
    if not slots:
        raise RuntimeError("No detecté huecos en la plantilla.")

    detector = load_face_detector()
    preview_paths = collect_preview_paths(args.thumb_root, max_items=args.max_candidates)
    if not preview_paths:
        raise RuntimeError(f"No encontré previews en {args.thumb_root}")

    scored = [score_photo(p, detector) for p in preview_paths]
    scored.sort(key=lambda c: c.score, reverse=True)

    # Prioriza personas; si no alcanza, rellena con lo demás (base local).
    people = [c for c in scored if c.faces > 0]
    rest = [c for c in scored if c.faces == 0]
    local_ranked = people + rest
    shortlist_size = max(len(slots) * 6, args.gemini_candidates, 24)
    shortlist = local_ranked[: shortlist_size]
    chosen = shortlist[: len(slots)]

    secrets = load_secrets(args.secrets_file)
    gemini_key = (args.gemini_api_key or secrets.get("GEMINI_API_KEY", "")).strip()
    gemini_models = [m.strip() for m in args.gemini_models.split(",") if m.strip()]
    if not args.no_gemini and gemini_key and shortlist:
        order, source = ask_gemini_photo_order(shortlist, len(slots), gemini_key, gemini_models)
        if order:
            chosen = [shortlist[i] for i in order]
            for c in shortlist:
                if len(chosen) >= len(slots):
                    break
                if c not in chosen:
                    chosen.append(c)
            print(f"INFO Gemini selección activa ({source})")
        else:
            print(f"WARN Gemini no eligió fotos ({source}); uso selección local.")

    # Garantiza prioridad humana mínima cuando sí existen fotos con personas.
    if people and all(c.faces <= 0 for c in chosen):
        chosen[-1] = people[0]

    if len(chosen) < len(slots):
        raise RuntimeError("No hay suficientes fotos para rellenar slots.")

    render_slots = sorted(slots, key=lambda s: (s.shape != "circle", -s.area))
    # Reordena selección para evitar que flores inferiores tapen rostros.
    slot_pool = shortlist if args.no_gemini else chosen
    slot_assigned = assign_candidates_to_slots(render_slots, slot_pool)
    if len(slot_assigned) == len(render_slots):
        chosen = slot_assigned
    else:
        # Fallback defensivo: completar con orden previo.
        for c in slot_pool:
            if len(slot_assigned) >= len(render_slots):
                break
            if c not in slot_assigned:
                slot_assigned.append(c)
        chosen = slot_assigned[: len(render_slots)]

    template = Image.open(args.template).convert("RGBA")
    overlay = template.copy()
    alpha = overlay.getchannel("A")
    alpha.paste(0, mask=placeholder_mask)
    overlay.putalpha(alpha)

    scene = Image.new("RGBA", template.size, (245, 245, 245, 255))
    photo_layer = Image.new("RGBA", template.size, (0, 0, 0, 0))
    used = set()
    for slot, candidate in zip(render_slots, chosen):
        if candidate.path in used:
            continue
        used.add(candidate.path)
        photo = ImageOps.exif_transpose(Image.open(candidate.path).convert("RGB"))
        setattr(photo, "_face_center", candidate.face_center)
        setattr(photo, "_face_box", candidate.face_box)
        setattr(photo, "_safe_bottom_ratio", slot_safe_bottom_ratio(slot))
        paste_into_slot(photo_layer, slot, photo)

    composed = Image.alpha_composite(scene, photo_layer)
    composed = Image.alpha_composite(composed, overlay)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    composed.convert("RGB").save(out, quality=95)

    print(f"OK template={args.template}")
    print(f"OK out={out}")
    for i, c in enumerate(chosen[:5], 1):
        print(f"  pick{i}: faces={c.faces} ratio={c.face_ratio:.4f} {c.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
