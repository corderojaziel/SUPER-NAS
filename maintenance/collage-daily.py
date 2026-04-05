#!/usr/bin/env python3
"""
collage-daily.py v2 — Collage diario para recuerdos Immich.

Flujo:
  1. Lee assets de las memories del día desde Immich
  2. Manda las fotos a Gemini Vision — él analiza y decide TODO:
       layout, paleta, título, qué fotos usar y en qué orden
  3. Pillow compone el collage con el layout elegido
  4. Sube a Immich y lo inserta como primera foto del recuerdo

Layouts disponibles (Gemini elige el más apropiado):
  - columns     : 2 fotos lado a lado 40/60
  - story       : 3 fotos apiladas verticales (1080x1920)
  - featured    : 1 grande arriba + 2 pequeñas abajo
  - polaroid    : fotos con leve rotación tipo polaroid
  - circle_hero : foto principal circular + 2 laterales
  - grid        : cuadrícula 2x2 o 2x3

Uso:
  collage-daily.py                    # memory de hoy
  collage-daily.py --dry-run          # sin subir
  collage-daily.py --days-offset -1   # ayer
  collage-daily.py --force            # regenerar aunque exista
"""

from __future__ import annotations

import argparse, base64, datetime as dt, hashlib, json, math
import os, subprocess, sys, unicodedata, urllib.error, urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps
try:
    import cv2  # type: ignore
except Exception:
    cv2 = None

# ── Configuración ──────────────────────────────────────────────────────────
SECRETS_FILE = "/etc/nas-secrets"
API_BASE     = "http://127.0.0.1:2283/api"
THUMBS_BASE  = "/var/lib/immich/thumbs"
COLLAGE_DIR  = "/var/lib/immich/collages"
TIMEZONE     = "America/Mexico_City"
DNN_PROTO_URL = "https://raw.githubusercontent.com/opencv/opencv/master/samples/dnn/face_detector/deploy.prototxt"
DNN_MODEL_URL = "https://raw.githubusercontent.com/opencv/opencv_3rdparty/dnn_samples_face_detector_20180205_fp16/res10_300x300_ssd_iter_140000_fp16.caffemodel"
NAS_ALERT_BIN = "/usr/local/bin/nas-alert.sh"
GEMINI_MODELS = [
    m.strip()
    for m in os.environ.get(
        "GEMINI_MODELS",
        "gemini-2.5-flash,gemini-2.0-flash,gemini-2.0-flash-lite",
    ).split(",")
    if m.strip()
]
MAX_PHOTOS   = max(1, int(os.environ.get("COLLAGE_MAX_PHOTOS", "10")))
PREVIEW_SIZE = max(128, int(os.environ.get("COLLAGE_PREVIEW_SIZE", "512")))
GEMINI_ALERT_TTL = max(60, int(os.environ.get("COLLAGE_GEMINI_ALERT_TTL", "21600")))
RECENT_DECISION_DAYS = max(1, int(os.environ.get("COLLAGE_RECENT_DECISION_DAYS", "2")))
PREVIEW_FACE_CACHE: Dict[str, int] = {}
FACE_CASCADES = None
DNN_FACE_NET = None

MESES = {
    1:"enero",2:"febrero",3:"marzo",4:"abril",5:"mayo",6:"junio",
    7:"julio",8:"agosto",9:"septiembre",10:"octubre",11:"noviembre",12:"diciembre"
}

# ── Paletas por temporada ─────────────────────────────────────────────────
PALETTES = {
    "primavera": dict(bg=(250,246,240), c1=(230,100,60),  c2=(80,170,90),
                      c3=(70,130,200),  c4=(240,190,50),   c5=(230,130,160)),
    "verano":    dict(bg=(240,250,255), c1=(30,140,200),   c2=(250,200,40),
                      c3=(40,190,140),  c4=(250,120,30),   c5=(100,200,220)),
    "otoño":     dict(bg=(250,243,230), c1=(200,90,30),    c2=(180,130,40),
                      c3=(150,60,40),   c4=(220,170,60),   c5=(180,100,60)),
    "invierno":  dict(bg=(240,245,255), c1=(60,100,180),   c2=(180,200,230),
                      c3=(100,150,200), c4=(220,230,245),  c5=(80,120,160)),
    "default":   dict(bg=(250,246,240), c1=(230,100,60),   c2=(80,170,90),
                      c3=(70,130,200),  c4=(240,190,50),   c5=(230,130,160)),
}

PALETTE_ALIASES = {
    "primavera": "primavera",
    "verano": "verano",
    "otono": "otoño",
    "otoño": "otoño",
    "invierno": "invierno",
    "default": "default",
}

LAYOUT_MIN_PHOTOS = {
    "columns": 2,
    "story": 3,
    "featured": 1,
    "polaroid": 2,
    "circle_hero": 3,
    "grid": 4,
}

# ── Helpers imagen ─────────────────────────────────────────────────────────
def open_img(path: str) -> Image.Image:
    return ImageOps.exif_transpose(Image.open(path).convert("RGB"))

def rounded_mask(size: Tuple, radius: int) -> Image.Image:
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0,0,size[0]-1,size[1]-1], radius=radius, fill=255)
    return m

def circle_mask(size: Tuple) -> Image.Image:
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse([0,0,size[0]-1,size[1]-1], fill=255)
    return m

def fit_crop(img: Image.Image, tw: int, th: int) -> Image.Image:
    iw, ih = img.size
    scale = max(tw/iw, th/ih)
    nw, nh = int(iw*scale), int(ih*scale)
    img = img.resize((nw,nh), Image.LANCZOS)
    x, y = (nw-tw)//2, (nh-th)//2
    return img.crop((x,y,x+tw,y+th))

def add_shadow(canvas: Image.Image, x:int, y:int, w:int, h:int, r:int=22):
    s = Image.new("RGBA", canvas.size, (0,0,0,0))
    ImageDraw.Draw(s).rounded_rectangle([x+6,y+6,x+w+6,y+h+6], radius=r, fill=(0,0,0,55))
    s = s.filter(ImageFilter.GaussianBlur(10))
    canvas.alpha_composite(s)

def place_rect(canvas: Image.Image, path:str, x:int, y:int, w:int, h:int, r:int=24):
    add_shadow(canvas, x, y, w, h, r)
    b = Image.new("RGBA", (w+6,h+6), (255,255,255,255))
    b.putalpha(rounded_mask((w+6,h+6), r+3))
    canvas.alpha_composite(b, (x-3,y-3))
    img = fit_crop(open_img(path), w, h).convert("RGBA")
    img.putalpha(rounded_mask((w,h), r))
    canvas.alpha_composite(img, (x,y))

def place_circle(canvas: Image.Image, path:str, cx:int, cy:int, r:int):
    x, y = cx-r, cy-r
    add_shadow(canvas, x, y, r*2, r*2, r)
    b = Image.new("RGBA", (r*2+6,r*2+6), (255,255,255,255))
    b.putalpha(circle_mask((r*2+6,r*2+6)))
    canvas.alpha_composite(b, (x-3,y-3))
    img = fit_crop(open_img(path), r*2, r*2).convert("RGBA")
    img.putalpha(circle_mask((r*2,r*2)))
    canvas.alpha_composite(img, (x,y))

def place_rotated(canvas: Image.Image, path:str, cx:int, cy:int,
                  w:int, h:int, angle:float, r:int=16):
    img = fit_crop(open_img(path), w, h).convert("RGBA")
    # marco blanco
    frm = Image.new("RGBA", (w+20, h+30), (255,255,255,255))
    frm.paste(img, (10,10))
    frm = frm.rotate(angle, expand=True, resample=Image.BICUBIC)
    fw, fh = frm.size
    # sombra simple
    s = Image.new("RGBA", canvas.size, (0,0,0,0))
    s.alpha_composite(frm, (cx-fw//2+4, cy-fh//2+4))
    s = s.filter(ImageFilter.GaussianBlur(8))
    canvas.alpha_composite(s)
    canvas.alpha_composite(frm, (cx-fw//2, cy-fh//2))

# ── Decoraciones ───────────────────────────────────────────────────────────
def flower(draw, cx,cy, n=6, rp=13, rc=9, pc=(230,100,60), cc=(240,190,50)):
    for i in range(n):
        a = math.radians(i*(360/n))
        px = cx+int((rp+rc)*math.cos(a))
        py = cy+int((rp+rc)*math.sin(a))
        draw.ellipse([px-rp,py-rp,px+rp,py+rp], fill=pc)
    draw.ellipse([cx-rc,cy-rc,cx+rc,cy+rc], fill=cc)

def stem_flower(draw, x, y, h=70, sc=(80,170,90), pc=(230,100,60), cc=(240,190,50)):
    draw.line([(x,y),(x,y-h)], fill=sc, width=4)
    draw.ellipse([x-14,y-h//2-8,x,y-h//2+8], fill=sc)
    flower(draw, x, y-h, n=6, rp=11, rc=8, pc=pc, cc=cc)

def flower_row(draw, x, y, n=5, gap=44, colors=None, cc=(240,190,50)):
    colors = colors or [(230,100,60),(230,130,160),(70,130,200),(230,130,160),(230,100,60)]
    for i in range(n):
        flower(draw, x+i*gap, y, n=5, rp=9, rc=6, pc=colors[i%len(colors)], cc=cc)

def wavy_line(draw, x1,y,x2, amp=8, freq=35, color=(80,170,90), w=3):
    pts = [(x, y+int(amp*math.sin((x-x1)*2*math.pi/freq))) for x in range(x1,x2,3)]
    if len(pts)>1: draw.line(pts, fill=color, width=w)

def dots(draw, x,y, cols=5, rows=2, gap=20, color=(70,130,200,120)):
    for i in range(cols):
        for j in range(rows):
            cx,cy = x+i*gap, y+j*gap
            draw.ellipse([cx-4,cy-4,cx+4,cy+4], fill=color)

def draw_header(canvas, draw, title:str, subtitle:str, pal:dict,
                W:int, fonts:tuple):
    ft, fs = fonts
    draw.rounded_rectangle([36,44,340,58], radius=5, fill=pal["c1"])
    draw.text((36,62),  title,    font=ft, fill=(40,30,20))
    draw.text((36,126), subtitle, font=fs, fill=pal["c1"])
    # flores decorativas header derecha
    flower(draw, W-85, 58,  n=6, rp=17, rc=12, pc=pal["c3"], cc=pal["c4"])
    flower(draw, W-140,95,  n=5, rp=12, rc=8,  pc=pal["c5"], cc=pal["c1"])
    flower(draw, W-55, 106, n=5, rp=10, rc=7,  pc=pal["c2"], cc=pal["c4"])

def draw_footer(canvas, draw, W:int, H:int, pal:dict, bot:int):
    fy = bot+12
    draw.rounded_rectangle([20,fy,W-20,fy+5], radius=3, fill=pal["c2"])
    flower_row(draw, W//2-90, fy+28, n=5, gap=46,
               colors=[pal["c1"],pal["c5"],pal["c3"],pal["c5"],pal["c1"]],
               cc=pal["c4"])

def get_fonts(size_title=54, size_sub=28):
    try:
        ft = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size_title)
        fs = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size_sub)
    except Exception:
        ft = ImageFont.load_default(size=size_title)
        fs = ImageFont.load_default(size=size_sub)
    return ft, fs

# ── Layouts ────────────────────────────────────────────────────────────────
def layout_columns(photos, title, subtitle, pal):
    """2 fotos lado a lado 40/60"""
    W, H = 1080, 1350
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-200,-80,W+60,180], fill=(*pal["c2"],40))
    draw.ellipse([-60,H-200,180,H+60], fill=(*pal["c1"],40))
    fonts = get_fonts()
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 20, 168, H-65
    cw_l = int((W-PAD*3)*0.40)
    cw_r = int((W-PAD*3)*0.60)
    col_h = BOT-TOP
    place_rect(canvas, photos[0], PAD, TOP+10, cw_l, col_h-20, r=26)
    mx = PAD+cw_l+PAD//2
    stem_flower(draw, mx, TOP+col_h//3,   h=60, sc=pal["c2"], pc=pal["c1"], cc=pal["c4"])
    stem_flower(draw, mx, TOP+col_h*2//3, h=50, sc=pal["c2"], pc=pal["c5"], cc=pal["c4"])
    place_rect(canvas, photos[1], PAD*2+cw_l, TOP+10, cw_r, col_h-20, r=26)
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

def layout_story(photos, title, subtitle, pal):
    """3 fotos apiladas verticales 1080x1920"""
    W, H = 1080, 1920
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-240,-100,W+80,240], fill=(*pal["c2"],35))
    draw.ellipse([-80,H//2-200,200,H//2+200], fill=(*pal["c5"],25))
    draw.ellipse([-60,H-240,200,H+60], fill=(*pal["c1"],35))
    fonts = get_fonts(58, 30)
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 22, 180, H-75
    AREA = BOT-TOP
    ph   = int(AREA*0.30)
    pw   = W-PAD*2
    gap  = (AREA-ph*3)//2
    for i, photo in enumerate(photos[:3]):
        py = TOP + i*(ph+gap)
        place_rect(canvas, photo, PAD, py, pw, ph, r=28)
        if i < 2:
            sy = py+ph+gap//2
            wavy_line(draw, PAD+20, sy, W-PAD-20, amp=7, freq=40, color=pal["c2"])
            flower_row(draw, W//2-88, sy-22, n=5, gap=44,
                       colors=[pal["c1"],pal["c5"],pal["c3"],pal["c5"],pal["c1"]],
                       cc=pal["c4"])
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

def layout_featured(photos, title, subtitle, pal):
    """1 foto grande arriba + 2 pequeñas abajo, degradando elegante con 1-2 fotos"""
    W, H = 1080, 1350
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-220,-80,W+60,220], fill=(*pal["c3"],40))
    draw.ellipse([-60,H-200,180,H+60], fill=(*pal["c1"],40))
    fonts = get_fonts()
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 20, 168, H-65
    AREA = BOT-TOP
    ph1  = int(AREA*0.55)
    pw   = W-PAD*2
    place_rect(canvas, photos[0], PAD, TOP+10, pw, ph1-10, r=28)
    # flores separadoras
    flower_row(draw, W//2-90, TOP+ph1+16, n=5, gap=46,
               colors=[pal["c1"],pal["c5"],pal["c3"],pal["c5"],pal["c1"]], cc=pal["c4"])
    ph2  = AREA-ph1-55
    y2   = TOP+ph1+48
    if len(photos) == 1:
        wavy_line(draw, PAD+30, y2+ph2//2, W-PAD-30, amp=7, freq=40, color=pal["c2"])
        flower_row(draw, W//2-90, y2+ph2//2-20, n=5, gap=46,
                   colors=[pal["c1"],pal["c5"],pal["c3"],pal["c5"],pal["c1"]], cc=pal["c4"])
    elif len(photos) == 2:
        place_rect(canvas, photos[1], PAD, y2, pw, ph2, r=22)
    else:
        pw2  = (W-PAD*3)//2
        place_rect(canvas, photos[1], PAD,       y2, pw2, ph2, r=22)
        place_rect(canvas, photos[2], PAD*2+pw2, y2, pw2, ph2, r=22)
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

def layout_polaroid(photos, title, subtitle, pal):
    """Fotos con rotación tipo polaroid"""
    W, H = 1080, 1350
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-200,-80,W+60,180], fill=(*pal["c2"],40))
    draw.ellipse([-60,H-200,180,H+60], fill=(*pal["c1"],40))
    fonts = get_fonts()
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 20, 168, H-65
    AREA  = BOT-TOP
    pw, ph = 420, 480
    positions = [
        (W//2-20, TOP+ph//2+30,  -6.0),
        (W//4+20, TOP+ph+100,     5.0),
        (3*W//4-20, TOP+ph+120,  -4.0),
    ]
    for i, (cx, cy, angle) in enumerate(positions[:len(photos)]):
        place_rotated(canvas, photos[i%len(photos)], cx, cy, pw, ph, angle)
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

def layout_circle_hero(photos, title, subtitle, pal):
    """Foto principal circular + 2 rectangulares laterales"""
    W, H = 1080, 1350
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-240,-100,W+80,200], fill=(*pal["c3"],40))
    draw.ellipse([-80,H-200,180,H+60],  fill=(*pal["c5"],40))
    fonts = get_fonts()
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 20, 168, H-65
    AREA  = BOT-TOP
    # Círculo central
    r_circ = (W-PAD*4)//4
    cx_c   = W//2
    cy_c   = TOP+r_circ+20
    place_circle(canvas, photos[0], cx_c, cy_c, r_circ)
    # Flores alrededor del círculo
    flower(draw, cx_c-r_circ-20, cy_c, n=6, rp=15, rc=10, pc=pal["c1"], cc=pal["c4"])
    flower(draw, cx_c+r_circ+20, cy_c, n=6, rp=15, rc=10, pc=pal["c3"], cc=pal["c4"])
    # Línea ondulada
    wy = cy_c+r_circ+22
    wavy_line(draw, PAD+20, wy, W-PAD-20, amp=7, freq=40, color=pal["c2"])
    # 2 fotos laterales abajo
    pw2 = (W-PAD*3)//2
    ph2 = BOT-wy-55
    y2  = wy+30
    place_rect(canvas, photos[1%len(photos)], PAD,       y2, pw2, ph2, r=22)
    place_rect(canvas, photos[2%len(photos)], PAD*2+pw2, y2, pw2, ph2, r=22)
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

def layout_grid(photos, title, subtitle, pal):
    """Cuadrícula 2x2 o 2x3"""
    W, H = 1080, 1350
    canvas = Image.new("RGBA", (W,H), pal["bg"]+(255,))
    draw   = ImageDraw.Draw(canvas)
    draw.ellipse([W-200,-80,W+60,180], fill=(*pal["c2"],40))
    draw.ellipse([-60,H-200,180,H+60], fill=(*pal["c1"],40))
    fonts = get_fonts()
    draw_header(canvas, draw, title, subtitle, pal, W, fonts)
    PAD, TOP, BOT = 16, 168, H-65
    AREA  = BOT-TOP
    n     = min(len(photos), 6)
    cols  = 2
    rows  = math.ceil(n/cols)
    cw    = (W-PAD*(cols+1))//cols
    ch    = (AREA-PAD*(rows+1))//rows
    for i, photo in enumerate(photos[:n]):
        col = i%cols
        row = i//cols
        x   = PAD+col*(cw+PAD)
        y   = TOP+PAD+row*(ch+PAD)
        place_rect(canvas, photo, x, y, cw, ch, r=22)
    draw_footer(canvas, draw, W, H, pal, BOT)
    return canvas.convert("RGB"), W, H

LAYOUTS = {
    "columns":     layout_columns,
    "story":       layout_story,
    "featured":    layout_featured,
    "polaroid":    layout_polaroid,
    "circle_hero": layout_circle_hero,
    "grid":        layout_grid,
}

FALLBACK_TITLES = [
    "Risas de {month}",
    "Casa y familia",
    "Entre abrazos",
    "Luz de {month}",
    "Tarde querida",
    "Cerca de casa",
]

GENERIC_TITLE_PREFIXES = (
    "momento de",
    "momentos de",
    "recuerdo de",
    "recuerdos de",
    "instante de",
    "instantes de",
    "postal de",
    "postales de",
    "tarde de",
    "dia de",
    "dias de",
    "dia en",
    "dias en",
)

GENERIC_TITLE_EXACT = {
    "alegria compartida",
    "felicidad compartida",
    "amor compartido",
    "familia unida",
    "momento especial",
    "recuerdo especial",
    "buenos momentos",
    "gran alegria",
    "gran recuerdo",
}

GENERIC_TITLE_WORDS = {
    "abril",
    "alegria",
    "amor",
    "casa",
    "compartida",
    "compartido",
    "dia",
    "dias",
    "especial",
    "familia",
    "felicidad",
    "instante",
    "instantes",
    "juntos",
    "juntas",
    "luz",
    "momento",
    "momentos",
    "postal",
    "postales",
    "querida",
    "recuerdo",
    "recuerdos",
    "risa",
    "risas",
    "tarde",
}

# ── Gemini ─────────────────────────────────────────────────────────────────
def img_to_b64(path:str, max_px:int=PREVIEW_SIZE) -> str:
    img = ImageOps.exif_transpose(Image.open(path).convert("RGB"))
    iw, ih = img.size
    scale = min(max_px/iw, max_px/ih, 1.0)
    if scale < 1.0:
        img = img.resize((int(iw*scale), int(ih*scale)), Image.LANCZOS)
    import io
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=75)
    return base64.b64encode(buf.getvalue()).decode()

def choice_from_seed(options: List[str], seed: str) -> str:
    if not options:
        raise ValueError("No options to choose from")
    digest = hashlib.sha1(seed.encode("utf-8", "ignore")).digest()
    return options[digest[0] % len(options)]

def env_is_true(value: Optional[str], default: bool=False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}

def extract_json_text(text: str) -> str:
    text = (text or "").replace("```json", "").replace("```", "").strip()
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end >= start:
        return text[start:end + 1]
    return text

def is_screenshot_name(name: str) -> bool:
    low = (name or "").strip().lower()
    return (
        low.startswith("screenshot")
        or low.startswith("screen recording")
        or "screen_shot" in low
        or "screen-shot" in low
        or "captura de pantalla" in low
        or "screencap" in low
    )

def is_whatsapp_name(name: str) -> bool:
    low = (name or "").strip().lower()
    return "-wa" in low or "wa000" in low or low.startswith("img-")

def photo_shape_counts(photo_paths: List[str]) -> Tuple[int, int, int]:
    portrait = landscape = square = 0
    for path in photo_paths:
        try:
            w, h = open_img(path).size
        except Exception:
            continue
        if h > w:
            portrait += 1
        elif w > h:
            landscape += 1
        else:
            square += 1
    return portrait, landscape, square

def fallback_decision(n_photos:int, month:int, memory_key:str="", photo_paths:Optional[List[str]]=None,
                      avoid_layouts:Optional[List[str]]=None) -> dict:
    season = {12:"invierno",1:"invierno",2:"invierno",
              3:"primavera",4:"primavera",5:"primavera",
              6:"verano",7:"verano",8:"verano",
              9:"otoño",10:"otoño",11:"otoño"}.get(month,"default")
    photo_paths = photo_paths or []
    portrait, landscape, square = photo_shape_counts(photo_paths)
    seed = f"{memory_key}|{month}|{n_photos}|{portrait}|{landscape}|{square}"

    if n_photos <= 1:
        candidates = ["featured"]
    elif n_photos == 2:
        candidates = ["columns", "polaroid"]
    elif n_photos == 3:
        candidates = ["story", "circle_hero", "featured", "polaroid"] if portrait >= landscape else ["featured", "polaroid", "story", "circle_hero"]
    elif n_photos == 4:
        candidates = ["featured", "grid", "polaroid", "circle_hero"]
    else:
        candidates = ["grid", "polaroid", "featured", "story"]

    blocked = {layout for layout in (avoid_layouts or []) if layout in candidates}
    filtered = [layout for layout in candidates if layout not in blocked]
    if filtered:
        candidates = filtered

    layout = choice_from_seed(candidates, seed)
    title_template = choice_from_seed(FALLBACK_TITLES, seed + "|title")
    return {
        "layout": layout,
        "palette": season,
        "title": title_template.format(month=MESES[month]),
        "photo_order": list(range(n_photos)),
        "reason": "fallback automático por cuota o respuesta inválida"
    }

def send_nas_alert(message: str, key: str="", ttl: int=GEMINI_ALERT_TTL) -> None:
    if not message or not Path(NAS_ALERT_BIN).exists():
        return
    env = os.environ.copy()
    if key:
        env["NAS_ALERT_KEY"] = key
    env["NAS_ALERT_TTL"] = str(ttl)
    try:
        subprocess.run(
            [NAS_ALERT_BIN, message],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
    except Exception:
        pass

def local_asset_created_at(target_date: dt.date, zone: dt.tzinfo) -> str:
    local_dt = dt.datetime.combine(target_date, dt.time(12, 0, 1), tzinfo=zone)
    return local_dt.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")

def write_decision_sidecar(path: Path, payload: dict) -> None:
    try:
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True),
            encoding="utf-8",
        )
    except OSError:
        pass

def daily_sidecar_path(target_date: dt.date) -> Path:
    return Path(COLLAGE_DIR) / f"collage-daily-{target_date.isoformat()}.json"

def load_recent_daily_decisions(target_date: dt.date, days: int=RECENT_DECISION_DAYS) -> List[dict]:
    decisions: List[dict] = []
    for offset in range(1, max(1, days) + 1):
        sidecar = daily_sidecar_path(target_date - dt.timedelta(days=offset))
        if not sidecar.exists():
            continue
        try:
            payload = json.loads(sidecar.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(payload, dict) and payload.get("mode") == "daily":
            decisions.append(payload)
    return decisions

def strip_accents(value: str) -> str:
    return "".join(
        char for char in unicodedata.normalize("NFD", value)
        if unicodedata.category(char) != "Mn"
    )

def normalize_text_key(value: str) -> str:
    raw = strip_accents(str(value or "")).lower()
    return " ".join(raw.replace("\n", " ").replace("\r", " ").split())

def clean_title_candidate(value: object, max_len: int=60) -> str:
    if not isinstance(value, str):
        return ""
    cleaned = " ".join(value.replace("\n", " ").replace("\r", " ").split()).strip()
    cleaned = cleaned.strip("`'\".,;:- ")
    if not cleaned:
        return ""
    if cleaned == cleaned.lower():
        cleaned = cleaned[:1].upper() + cleaned[1:]
    return cleaned[:max_len]

def coerce_string_list(value: object, max_items: int=4) -> List[str]:
    if not isinstance(value, list):
        return []
    items: List[str] = []
    for raw in value:
        cleaned = clean_title_candidate(raw)
        if cleaned and cleaned not in items:
            items.append(cleaned)
        if len(items) >= max_items:
            break
    return items

def is_generic_title(title: str) -> bool:
    normalized = normalize_text_key(title)
    if not normalized:
        return True
    if normalized in GENERIC_TITLE_EXACT:
        return True
    if any(normalized.startswith(prefix) for prefix in GENERIC_TITLE_PREFIXES):
        return True
    words = [word for word in normalized.split() if len(word) > 1]
    if len(words) < 2:
        return True
    if set(words).issubset(GENERIC_TITLE_WORDS):
        return True
    return False

def title_candidates_from_decision(decision: dict) -> List[str]:
    candidates: List[str] = []
    for candidate in [decision.get("title")] + coerce_string_list(decision.get("title_options")) + [decision.get("theme")]:
        cleaned = clean_title_candidate(candidate)
        if cleaned and cleaned not in candidates:
            candidates.append(cleaned)
    return candidates

def layout_candidates_from_decision(decision: dict) -> List[str]:
    candidates: List[str] = []
    for candidate in coerce_string_list(decision.get("layout_candidates"), max_items=len(LAYOUTS)):
        layout = candidate.strip().lower()
        if layout in LAYOUTS and layout not in candidates:
            candidates.append(layout)
    return candidates

def first_valid_layout(candidates: List[str], n_photos: int, blocked: Optional[List[str]]=None) -> str:
    blocked_set = {layout for layout in (blocked or []) if layout}
    for layout in candidates:
        if layout in blocked_set:
            continue
        if layout in LAYOUTS and n_photos >= LAYOUT_MIN_PHOTOS.get(layout, 1):
            return layout
    return ""

def recent_collage_context(recent_daily_decisions: Optional[List[dict]]) -> str:
    recent_daily_decisions = recent_daily_decisions or []
    if not recent_daily_decisions:
        return "Sin collages recientes guardados."
    lines = []
    for item in recent_daily_decisions[:2]:
        lines.append(
            f"- {item.get('target_date', '?')}: layout={item.get('layout', '?')}, "
            f"paleta={item.get('palette', '?')}, título=\"{item.get('title', '')}\""
        )
    return "\n".join(lines)

def choose_title(decision: dict, fallback_title: str) -> Tuple[str, bool]:
    for candidate in title_candidates_from_decision(decision):
        if not is_generic_title(candidate):
            return candidate, False
    cleaned_fallback = clean_title_candidate(fallback_title)
    return cleaned_fallback or fallback_title, True

def choose_layout(layout_name: object, photo_count: int, fallback: dict,
                  decision: dict, recent_layouts: Optional[List[str]]=None) -> Tuple[str, str]:
    recent_layouts = [layout for layout in (recent_layouts or []) if layout in LAYOUTS]
    chosen = str(layout_name or "").strip().lower()
    alternatives = layout_candidates_from_decision(decision)
    if chosen not in alternatives and chosen:
        alternatives = [chosen] + alternatives

    note = ""
    if chosen not in LAYOUTS:
        chosen = fallback["layout"]
        note = f"layout inválido de Gemini, usando fallback={chosen}"
    elif photo_count < LAYOUT_MIN_PHOTOS.get(chosen, 1):
        alt = first_valid_layout(alternatives[1:], photo_count)
        chosen = alt or fallback["layout"]
        note = f"{layout_name} necesita {LAYOUT_MIN_PHOTOS.get(str(layout_name), 1)} fotos, usando {chosen}"

    if recent_layouts and chosen == recent_layouts[0]:
        alt = first_valid_layout(alternatives, photo_count, blocked=[chosen])
        if not alt:
            alt = first_valid_layout([fallback["layout"]], photo_count, blocked=[chosen])
        if alt and alt != chosen:
            note = (note + "; " if note else "") + f"evitando repetir layout de ayer ({chosen})"
            chosen = alt

    return chosen or fallback["layout"], note

def ask_gemini(api_key:str, photo_paths:List[str], month:int, memory_key:str="",
               allow_fallback:bool=False, alert_context:str="",
               recent_daily_decisions:Optional[List[dict]]=None) -> dict:
    """Manda las fotos a Gemini y él decide todo. Devuelve dict con decisiones."""
    layouts_desc = (
        "columns: usa las 2 mejores fotos lado a lado; funciona cuando hay un par fuerte. "
        "story: usa las 3 mejores fotos apiladas; funciona cuando hay secuencia o progresión. "
        "featured: usa 1 foto hero + 2 de apoyo; funciona cuando una imagen manda visualmente. "
        "polaroid: usa 3-4 fotos con gesto espontáneo o familiar. "
        "circle_hero: usa 3 fotos; un retrato principal con dos apoyos. "
        "grid: usa 4-6 fotos solo cuando varias merecen casi el mismo peso."
    )
    recent_context = recent_collage_context(recent_daily_decisions)

    parts = []
    for i, path in enumerate(photo_paths):
        parts.append({
            "inline_data": {
                "mime_type": "image/jpeg",
                "data": img_to_b64(path)
            }
        })

    n_photos = len(photo_paths)
    parts.append({"text": f"""Analiza estas {n_photos} fotos.

Layouts disponibles:
{layouts_desc}

Contexto reciente para no reciclar el mismo look si no hace falta:
{recent_context}

Responde SOLO con JSON válido (sin markdown, sin texto fuera del JSON):
{{
  "layout": "<nombre exacto del layout>",
  "palette": "primavera|verano|otoño|otono|invierno|default",
  "title": "<título corto en español, 2-4 palabras, específico>",
  "photo_order": [0,1,2,...],
  "reason": "<una línea>",
  "layout_candidates": ["<layout fuerte>", "<layout alterno>"],
  "title_options": ["<título mejor>", "<título alterno>"],
  "theme": "<tema visual corto>"
}}

Reglas estrictas:
- Decide TODO solo por el contenido visual de las fotos
- Prioriza fotos de personas, familia, retratos, momentos humanos y escenas emotivas
- Evita elegir screenshots, carreteras vacías, documentos, logos, objetos sueltos o fotos de pantallas si hay fotos humanas disponibles
- Piensa primero en la historia: vínculo visible, actividad, emoción, edad, celebración o gesto
- La paleta debe responder al ambiente visual; usa la temporada solo como desempate, no como regla ciega
- NO elijas grid solo por cantidad; si una o dos fotos dominan, usa un layout editorial y deja esas fotos al inicio de photo_order
- Si hay más fotos de las que el layout necesita, photo_order debe poner primero las que sí se usarán
- Si varias opciones funcionan parecido, evita repetir el mismo layout del collage de ayer
- El título debe sonar humano y concreto: por ejemplo relación, actividad o escena; evita frases comodín como "Momentos de...", "Recuerdo de..." o "Alegría compartida"
- Si ves una relación clara como padre e hijo, familia, amigas, fiesta o comida, nómbrala sin inventar nombres propios
- photo_order: lista de enteros 0..{n_photos-1}, sin repetir, sin strings
- palette: usa EXACTAMENTE una de estas palabras, no colores hex ni arrays
- layout_candidates: lista corta de layouts válidos, del más fuerte al más seguro
- title_options: 2 alternativas cortas y específicas
- columns necesita al menos 2 fotos
- story necesita al menos 3 fotos
- featured necesita al menos 1 foto
- polaroid necesita al menos 2 fotos
- circle_hero necesita al menos 3 fotos
- grid necesita al menos 4 fotos
- Si el layout ideal no tiene suficientes fotos, elige el siguiente apropiado
- El título debe ser emotivo y específico al contenido visual"""
    })

    last_error = "sin modelos configurados"
    for model in GEMINI_MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        generation_config = {
            "temperature": 0.2,
            "maxOutputTokens": 400,
        }
        if model.startswith("gemini-2.5"):
            generation_config["thinkingConfig"] = {"thinkingBudget": 0}
        body = {
            "contents": [{"parts": parts}],
            "generationConfig": generation_config,
        }
        try:
            req = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"}, method="POST"
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode())
                part = (((data.get("candidates") or [{}])[0].get("content") or {}).get("parts") or [{}])[0]
                text = extract_json_text(part.get("text") or "")
                parsed = json.loads(text)
                if isinstance(parsed, dict):
                    parsed["_gemini_model"] = model
                return parsed
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "ignore")
            last_error = f"{model}: HTTP {exc.code} {raw[:250]}"
            print(f"  WARN Gemini {model}: HTTP {exc.code} — probando siguiente modelo", file=sys.stderr)
            continue
        except Exception as exc:
            last_error = f"{model}: {exc}"
            print(f"  WARN Gemini {model}: {exc} — probando siguiente modelo", file=sys.stderr)
            continue

    alert_message = (
        f"[collage-daily] Gemini no respondió para {alert_context or memory_key}. "
        f"Error: {last_error}"
    )
    send_nas_alert(alert_message, key=f"collage-gemini:{memory_key or alert_context}")
    if allow_fallback:
        print(f"  WARN Gemini: {last_error} — usando fallback", file=sys.stderr)
        fallback = fallback_decision(len(photo_paths), month, memory_key=memory_key, photo_paths=photo_paths)
        fallback["_gemini_model"] = "fallback"
        fallback["_gemini_error"] = last_error
        return fallback
    raise RuntimeError(last_error)

def normalize_palette_name(name: str) -> str:
    if not isinstance(name, str):
        return "default"
    return PALETTE_ALIASES.get(name.strip().lower(), "default")

def memory_asset_ids(memory: dict) -> List[str]:
    assets = memory.get("assets", []) if isinstance(memory, dict) else []
    return [
        a.get("id") for a in assets
        if isinstance(a, dict) and a.get("id")
    ]

def is_collage_asset(asset: dict) -> bool:
    if not isinstance(asset, dict):
        return False
    name = (asset.get("originalFileName") or "").strip()
    return name.startswith("collage-")

def fetch_memory(api_base:str, headers:dict, memory_id:str) -> Optional[dict]:
    c, body = http_json("GET", f"{api_base}/memories/{memory_id}", headers=headers)
    if c == 200 and isinstance(body, dict):
        return body
    return None

def original_assets(memory: dict) -> List[dict]:
    annotated = memory.get("_original_assets")
    if isinstance(annotated, list):
        return annotated
    return [
        a for a in (memory.get("assets") or [])
        if isinstance(a, dict) and a.get("id") and not is_collage_asset(a)
    ]

def timeline_asset_id_set(asset_ids: List[str]) -> set[str]:
    valid = [aid for aid in asset_ids if aid]
    if not valid:
        return set()
    ids_sql = ",".join("'" + aid.replace("'", "''") + "'::uuid" for aid in valid)
    rows = db_query(
        "select id::text from asset "
        f"where id in ({ids_sql}) and visibility='timeline' and status='active' and \"deletedAt\" is null;"
    )
    return set(rows)

def annotate_usable_assets(memories: List[dict]) -> None:
    all_ids = [
        a.get("id")
        for memory in memories
        for a in (memory.get("assets") or [])
        if isinstance(a, dict) and a.get("id")
    ]
    allowed = timeline_asset_id_set(all_ids)
    for memory in memories:
        memory["_original_assets"] = [
            a for a in (memory.get("assets") or [])
            if isinstance(a, dict)
            and a.get("id") in allowed
            and not is_collage_asset(a)
        ]
    if not allowed:
        return
    ids_sql = ",".join("'" + aid.replace("'", "''") + "'::uuid" for aid in allowed)
    rows = db_query(
        "select a.id::text || '|' || count(af.\"assetId\")::text "
        "from asset a "
        "left join asset_face af on af.\"assetId\"=a.id "
        f"where a.id in ({ids_sql}) "
        "group by a.id;"
    )
    face_counts: Dict[str, int] = {}
    for row in rows:
        aid, count = row.split("|", 1)
        face_counts[aid] = int(count or "0")
    for memory in memories:
        for asset in memory.get("_original_assets", []):
            asset["_face_count"] = face_counts.get(asset.get("id", ""), 0)

def asset_selection_priority(asset: dict) -> Tuple[int, int, int, int, str]:
    name = asset.get("originalFileName", "")
    face_count = asset_face_score(asset)
    is_video = 1 if str(asset.get("type", "")).upper() == "VIDEO" else 0
    is_screen = 1 if is_screenshot_name(name) else 0
    is_wa = 0 if is_whatsapp_name(name) else 1
    is_hdr = 1 if "hdr" in name.lower() else 0
    # Menor es mejor: caras primero, luego fotos tipo chat/album, y al final HDR/videos/screenshots.
    return (-face_count, is_wa, is_hdr + is_video + is_screen, is_screen + is_video, name.lower())

def is_collage_rejected_asset(asset: dict) -> bool:
    if not isinstance(asset, dict):
        return True
    return is_screenshot_name(asset.get("originalFileName", ""))

def memory_collage_assets(memory: dict, people_only: bool=False) -> List[dict]:
    ranked = [
        asset for asset in sorted(original_assets(memory), key=asset_selection_priority)
        if not is_collage_rejected_asset(asset)
    ]
    if people_only:
        people = [a for a in ranked if asset_face_score(a) > 0]
        if people:
            return people
    return ranked

def should_prefer_people(memories: List[dict]) -> bool:
    return any(
        asset_face_score(asset) > 0
        for memory in memories
        for asset in original_assets(memory)
    )

def pick_target_memory(memories: List[dict]) -> Optional[dict]:
    people_only = should_prefer_people(memories)
    candidates = []
    for memory in memories:
        year = (memory.get("data") or {}).get("year", 0)
        originals = memory_collage_assets(memory, people_only=people_only)
        if originals:
            candidates.append((len(originals), year, memory))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return candidates[0][2]

def collect_daily_preview_paths(memories: List[dict], user_id: str, limit: int) -> Tuple[List[str], int]:
    people_only = should_prefer_people(memories)
    buckets: List[List[Tuple[str, str]]] = []
    seen_ids = set()
    missing = 0
    for memory in sorted(
        memories,
        key=lambda m: len(memory_collage_assets(m, people_only=people_only)),
        reverse=True,
    ):
        bucket = []
        originals = memory_collage_assets(memory, people_only=people_only)
        for asset in originals:
            aid = asset.get("id")
            if not aid or aid in seen_ids:
                continue
            path = asset.get("_thumb_path") or thumb_path(user_id, aid)
            if path:
                asset["_thumb_path"] = path
                bucket.append((aid, path))
                seen_ids.add(aid)
            else:
                missing += 1
        if bucket:
            buckets.append(bucket)

    selected: List[str] = []
    while buckets and len(selected) < limit:
        next_buckets = []
        for bucket in buckets:
            if len(selected) >= limit:
                break
            if bucket:
                _, path = bucket.pop(0)
                selected.append(path)
            if bucket:
                next_buckets.append(bucket)
        buckets = next_buckets
    return selected, missing

def remove_collage_assets(api_base:str, headers:dict, memories:List[dict], dry_run:bool) -> int:
    collage_ids: List[str] = []
    by_memory: Dict[str, List[str]] = {}
    for memory in memories:
        mid = memory.get("id")
        ids = [a.get("id") for a in (memory.get("assets") or []) if is_collage_asset(a) and a.get("id")]
        if ids:
            by_memory[mid] = ids
            collage_ids.extend(ids)

    collage_ids = list(dict.fromkeys(collage_ids))
    if not collage_ids:
        return 0

    if dry_run:
        print(f"  DRYRUN: limpiaría {len(collage_ids)} collage(s) previos del día")
        return len(collage_ids)

    for mid, ids in by_memory.items():
        c, body = http_json("DELETE", f"{api_base}/memories/{mid}/assets", {"ids": ids}, headers=headers)
        if c != 200:
            print(f"  WARN: no se pudieron despegar collages previos de memory {mid}: {c} {body}", file=sys.stderr)
    c, body = http_json("DELETE", f"{api_base}/assets", {"ids": collage_ids, "force": True}, headers=headers)
    if c not in (200, 204):
        print(f"  WARN: no se pudieron borrar collage(s) previos: {c} {body}", file=sys.stderr)
    else:
        print(f"  Limpieza: {len(collage_ids)} collage(s) previo(s) eliminados")
    return len(collage_ids)

def rebuild_memory_assets_order(api_base:str, headers:dict, memory_id:str,
                                ordered_ids:List[str], original_ids:List[str]) -> bool:
    cd, body = http_json("DELETE", f"{api_base}/memories/{memory_id}/assets",
                         {"ids": original_ids}, headers=headers)
    if cd != 200:
        print(f"  WARN: no se pudo vaciar la memory {memory_id} para reordenar: {cd} {body}", file=sys.stderr)
        return False

    ca, body = http_json("PUT", f"{api_base}/memories/{memory_id}/assets",
                         {"ids": ordered_ids}, headers=headers)
    if ca in (200, 201):
        return True

    print(f"  WARN: no se pudo reconstruir el orden de memory {memory_id}: {ca} {body}", file=sys.stderr)
    rr, restore_body = http_json("PUT", f"{api_base}/memories/{memory_id}/assets",
                                 {"ids": original_ids}, headers=headers)
    if rr not in (200, 201):
        print(f"  WARN: tampoco se pudo restaurar la memory {memory_id}: {rr} {restore_body}", file=sys.stderr)
    return False

def ensure_collage_first(api_base:str, headers:dict, memory_id:str, asset_id:str) -> bool:
    current = fetch_memory(api_base, headers, memory_id)
    if not current:
        print(f"  WARN: collage agregado pero no se pudo leer memory {memory_id}", file=sys.stderr)
        return False

    current_ids = memory_asset_ids(current)
    if current_ids and current_ids[0] == asset_id:
        print(f"  OK: collage insertado como primera foto en memory {memory_id}")
        return True

    reordered_ids = [asset_id] + [aid for aid in current_ids if aid != asset_id]
    cp, _ = http_json("PATCH", f"{api_base}/memories/{memory_id}",
                      {"assetIds": reordered_ids}, headers=headers)
    if cp in (200, 201, 204):
        updated = fetch_memory(api_base, headers, memory_id)
        updated_ids = memory_asset_ids(updated or {})
        if updated_ids and updated_ids[0] == asset_id:
            print(f"  OK: collage insertado como primera foto en memory {memory_id}")
            return True
    else:
        print(f"  WARN: el servidor no aceptó PATCH reorden (status={cp}); probando reconstrucción", file=sys.stderr)

    if rebuild_memory_assets_order(api_base, headers, memory_id, reordered_ids, current_ids):
        rebuilt = fetch_memory(api_base, headers, memory_id)
        rebuilt_ids = memory_asset_ids(rebuilt or {})
        if rebuilt_ids and rebuilt_ids[0] == asset_id:
            print(f"  OK: collage insertado como primera foto en memory {memory_id}")
            return True

    print(f"  WARN: collage agregado a memory {memory_id}, pero no quedó como primera foto", file=sys.stderr)
    return False

# ── HTTP / DB helpers ──────────────────────────────────────────────────────
def http_json(method, url, body=None, headers=None):
    payload = None if body is None else json.dumps(body).encode()
    h = {"Content-Type":"application/json"}
    if headers: h.update(headers)
    req = urllib.request.Request(url, data=payload, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8","ignore")
            return resp.getcode(), json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8","ignore")
        try: bj = json.loads(raw) if raw else {}
        except: bj = {"raw":raw}
        return exc.code, bj

def db_query(sql:str) -> List[str]:
    cmd = ["docker","exec","immich_postgres","psql","-U","immich","-d","immich","-At","-c",sql]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "psql failed")
    return [x.strip() for x in proc.stdout.splitlines() if x.strip()]

def read_secrets(path:str) -> dict:
    out = {}
    try:
        with open(path,"r",encoding="utf-8",errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line: continue
                k,v = line.split("=",1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError: pass
    return out

def thumb_path(user_id:str, asset_id:str) -> Optional[str]:
    a = asset_id.replace("-","")
    p1, p2 = a[0:2], a[0:4]
    path = Path(THUMBS_BASE)/user_id/p1/p2/f"{asset_id}_preview.jpeg"
    if path.exists(): return str(path)
    try:
        r = subprocess.run(["find",f"{THUMBS_BASE}/{user_id}","-name",f"{asset_id}_preview.jpeg"],
                           capture_output=True,text=True,timeout=10)
        lines = [l.strip() for l in r.stdout.splitlines() if l.strip()]
        if lines: return lines[0]
    except: pass
    return None

def ensure_dnn_face_model() -> Optional[Tuple[Path, Path]]:
    model_dir = Path(COLLAGE_DIR) / "models"
    proto_path = model_dir / "deploy.prototxt"
    model_path = model_dir / "res10_300x300_ssd_iter_140000_fp16.caffemodel"
    if proto_path.exists() and model_path.exists():
        return proto_path, model_path
    try:
        model_dir.mkdir(parents=True, exist_ok=True)
        if not proto_path.exists():
            urllib.request.urlretrieve(DNN_PROTO_URL, proto_path)
        if not model_path.exists():
            urllib.request.urlretrieve(DNN_MODEL_URL, model_path)
        if proto_path.exists() and model_path.exists():
            return proto_path, model_path
    except Exception as exc:
        print(f"  WARN DNN rostros: no se pudo descargar modelo ({exc})", file=sys.stderr)
    return None

def load_dnn_face_net():
    global DNN_FACE_NET
    if DNN_FACE_NET is not None:
        return None if DNN_FACE_NET is False else DNN_FACE_NET
    if cv2 is None:
        DNN_FACE_NET = False
        return None
    model_files = ensure_dnn_face_model()
    if not model_files:
        DNN_FACE_NET = False
        return None
    proto_path, model_path = model_files
    try:
        DNN_FACE_NET = cv2.dnn.readNetFromCaffe(str(proto_path), str(model_path))
    except Exception as exc:
        print(f"  WARN DNN rostros: no se pudo cargar modelo ({exc})", file=sys.stderr)
        DNN_FACE_NET = False
    return None if DNN_FACE_NET is False else DNN_FACE_NET

def preview_face_count(path:str) -> int:
    global FACE_CASCADES
    if not path:
        return 0
    cached = PREVIEW_FACE_CACHE.get(path)
    if cached is not None:
        return cached
    if cv2 is None:
        PREVIEW_FACE_CACHE[path] = 0
        return 0
    if FACE_CASCADES is None:
        cascade_dirs = []
        cv2_data = getattr(getattr(cv2, "data", None), "haarcascades", "")
        if cv2_data:
            cascade_dirs.append(cv2_data)
        cascade_dirs.extend([
            "/usr/share/opencv4/haarcascades",
            "/usr/share/opencv/haarcascades",
        ])
        cascade_names = [
            "haarcascade_frontalface_default.xml",
            "haarcascade_frontalface_alt2.xml",
            "haarcascade_profileface.xml",
        ]
        loaded = []
        seen_paths = set()
        for base in cascade_dirs:
            for name in cascade_names:
                cascade_path = str(Path(base) / name)
                if cascade_path in seen_paths or not Path(cascade_path).exists():
                    continue
                seen_paths.add(cascade_path)
                cascade = cv2.CascadeClassifier(cascade_path)
                if not getattr(cascade, "empty", lambda: True)():
                    loaded.append(cascade)
        FACE_CASCADES = loaded or False
    if FACE_CASCADES is False:
        PREVIEW_FACE_CACHE[path] = 0
        return 0
    try:
        img = cv2.imread(path)
        if img is None:
            PREVIEW_FACE_CACHE[path] = 0
            return 0
        count = 0
        net = load_dnn_face_net()
        if net is not None:
            h, w = img.shape[:2]
            blob = cv2.dnn.blobFromImage(cv2.resize(img, (300, 300)), 1.0, (300, 300), (104.0, 177.0, 123.0))
            net.setInput(blob)
            detections = net.forward()
            for i in range(detections.shape[2]):
                confidence = float(detections[0, 0, i, 2])
                if confidence < 0.60:
                    continue
                x1, y1, x2, y2 = detections[0, 0, i, 3:7]
                bw = max(0.0, (x2 - x1) * w)
                bh = max(0.0, (y2 - y1) * h)
                if bw >= w * 0.04 and bh >= h * 0.04:
                    count += 1
        if count <= 0:
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            gray = cv2.equalizeHist(gray)
            for cascade in FACE_CASCADES:
                faces = cascade.detectMultiScale(gray, scaleFactor=1.08, minNeighbors=3, minSize=(24, 24))
                count = max(count, int(len(faces)))
        if count > 6:
            count = 0
    except Exception:
        count = 0
    PREVIEW_FACE_CACHE[path] = count
    return count

def asset_face_score(asset:dict) -> int:
    return max(
        int(asset.get("_face_count", 0) or 0),
        int(asset.get("_preview_face_count", 0) or 0),
    )

def annotate_preview_faces(memories:List[dict], user_id:str) -> None:
    for memory in memories:
        for asset in memory.get("_original_assets", []):
            aid = asset.get("id")
            if not aid:
                continue
            path = asset.get("_thumb_path") or thumb_path(user_id, aid)
            if not path:
                continue
            asset["_thumb_path"] = path
            if int(asset.get("_face_count", 0) or 0) <= 0:
                asset["_preview_face_count"] = preview_face_count(path)

def upload_collage(api_base:str, headers:dict, file_path:Path,
                   created_at:str) -> Optional[str]:
    with open(file_path,"rb") as f: data = f.read()
    boundary = "ImmichCollageBoundary"
    def field(name, value):
        return (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode()
    parts = [
        field("deviceAssetId", f"collage-{file_path.stem}"),
        field("deviceId",      "supernas-collage"),
        field("fileCreatedAt", created_at),
        field("fileModifiedAt",created_at),
        field("isFavorite",    "false"),
        (f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; '
         f'filename="{file_path.name}"\r\nContent-Type: image/jpeg\r\n\r\n').encode()
        + data + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    payload = b"".join(parts)
    h = dict(headers)
    h["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    req = urllib.request.Request(f"{api_base}/assets", data=payload, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode()).get("id")
    except urllib.error.HTTPError as exc:
        print(f"  ERROR upload: {exc.code} {exc.read().decode()[:200]}", file=sys.stderr)
        return None

# ── Core ───────────────────────────────────────────────────────────────────
def process_memory(memory:dict, user_id:str, target_date:dt.date,
                   gemini_key:str, api_base:str, headers:dict,
                   dry_run:bool, force:bool, allow_fallback:bool,
                   zone:dt.tzinfo) -> bool:
    mid   = memory["id"]
    year  = (memory.get("data") or {}).get("year", target_date.year)
    assets = memory_collage_assets(memory, people_only=True)
    if not assets:
        print(f"  [skip] {mid} year={year}: sin assets")
        return False

    if not force:
        rows = db_query(f"SELECT id FROM asset WHERE \"deviceId\"='supernas-collage' "
                        f"AND \"originalFileName\" LIKE 'collage-{mid}%' LIMIT 1;")
        if rows:
            print(f"  [skip] {mid} year={year}: collage ya existe")
            return False

    # Obtener paths de previews disponibles para análisis visual (hasta MAX_PHOTOS)
    paths = []
    for a in assets:
        aid = a.get("id") or a
        p = a.get("_thumb_path") or thumb_path(user_id, aid)
        if p: paths.append(p)
        if len(paths) >= MAX_PHOTOS:
            break

    if not paths:
        print(f"  [skip] {mid} year={year}: sin previews en disco")
        return False

    print(f"  memory={mid} year={year} fotos={len(paths)}")

    # Gemini decide todo
    decision = ask_gemini(
        gemini_key,
        paths,
        target_date.month,
        memory_key=f"{mid}:{year}",
        allow_fallback=allow_fallback,
        alert_context=f"memory {mid} ({target_date.isoformat()})",
    )

    layout_name  = decision.get("layout", "")
    palette_name = decision.get("palette", "default")
    order_raw    = decision.get("photo_order", [])
    reason       = decision.get("reason", "")
    fallback = fallback_decision(len(paths), target_date.month, memory_key=f"{mid}:{year}", photo_paths=paths)
    layout_name, layout_note = choose_layout(layout_name, len(paths), fallback, decision)
    if layout_note:
        print(f"  WARN: {layout_note}")

    # Validar palette
    palette_name = normalize_palette_name(palette_name)

    # Validar title
    title, used_title_fallback = choose_title(decision, fallback.get("title", f"{MESES[target_date.month].capitalize()} {year}"))
    if used_title_fallback:
        print(f"  WARN: título genérico o vacío de Gemini, usando fallback='{title}'")

    # Validar photo_order: enteros, en rango, sin repetir
    if not isinstance(order_raw, list):
        order_raw = []
    valid_order = []
    seen = set()
    for idx in order_raw:
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            continue
        if 0 <= idx < len(paths) and idx not in seen:
            valid_order.append(idx)
            seen.add(idx)
    # Agregar índices faltantes al final
    for i in range(len(paths)):
        if i not in seen:
            valid_order.append(i)

    model_used = decision.get("_gemini_model", "fallback")
    print(f"  Gemini[{model_used}] → layout={layout_name} paleta={palette_name} título='{title}'")
    print(f"  Razón: {reason}")

    ordered_paths = [paths[i] for i in valid_order]
    pal      = PALETTES.get(palette_name, PALETTES["default"])
    subtitle = f"{MESES[target_date.month].capitalize()} {year}"
    layout_fn = LAYOUTS[layout_name]

    if dry_run:
        print(f"  DRYRUN: generaría collage con layout={layout_name}")
        return True

    # Generar collage
    Path(COLLAGE_DIR).mkdir(parents=True, exist_ok=True)
    out_path = Path(COLLAGE_DIR) / f"collage-{mid}-{year}.jpg"
    sidecar_path = out_path.with_suffix(".json")
    write_decision_sidecar(sidecar_path, {
        "mode": "single_memory",
        "memory_id": mid,
        "memory_year": year,
        "target_date": target_date.isoformat(),
        "gemini_model": model_used,
        "gemini_error": decision.get("_gemini_error"),
        "layout": layout_name,
        "palette": palette_name,
        "title": title,
        "theme": clean_title_candidate(decision.get("theme")),
        "layout_candidates": layout_candidates_from_decision(decision),
        "title_options": coerce_string_list(decision.get("title_options")),
        "photo_order": valid_order,
        "reason": reason,
        "allow_fallback": allow_fallback,
    })
    print(f"  Decisión guardada: {sidecar_path}")

    try:
        img, W, H = layout_fn(ordered_paths, title, subtitle, pal)
        img.save(str(out_path), "JPEG", quality=94)
        print(f"  Collage: {out_path} ({out_path.stat().st_size//1024} KB) {W}x{H}")
    except Exception as e:
        print(f"  ERROR generando collage: {e}", file=sys.stderr)
        return False

    # Subir a Immich
    created_at = local_asset_created_at(target_date, zone)

    asset_id = upload_collage(api_base, headers, out_path, created_at)
    if not asset_id:
        print(f"  ERROR: falló la subida", file=sys.stderr)
        return False

    print(f"  Subido: asset_id={asset_id}")

    # Agregar el collage a la memory y verificar si realmente quedó primero.
    c, body = http_json("PUT", f"{api_base}/memories/{mid}/assets",
                        {"ids": [asset_id]}, headers=headers)
    if c not in (200, 201):
        print(f"  WARN: subido pero no insertado en memory: {c}", file=sys.stderr)
        return False

    return ensure_collage_first(api_base, headers, mid, asset_id)

def process_day(memories:List[dict], user_id:str, target_date:dt.date,
                gemini_key:str, api_base:str, headers:dict,
                dry_run:bool, force:bool, allow_fallback:bool,
                zone:dt.tzinfo) -> bool:
    people_only = should_prefer_people(memories)
    target_memory = pick_target_memory(memories)
    if not target_memory:
        print(f"INFO: sin memories con fotos originales para {target_date}")
        return False

    target_mid = target_memory["id"]
    target_year = (target_memory.get("data") or {}).get("year", target_date.year)
    target_originals = len(memory_collage_assets(target_memory, people_only=people_only))

    if not force:
        total_existing = sum(1 for m in memories for a in (m.get("assets") or []) if is_collage_asset(a))
        if total_existing:
            print(f"  [skip] fecha={target_date}: ya existe collage diario ({total_existing} asset(s) collage)")
            return False

    daily_paths, missing = collect_daily_preview_paths(memories, user_id, MAX_PHOTOS)
    if not daily_paths:
        print(f"  [skip] fecha={target_date}: sin previews utilizables para collage diario")
        return False

    total_originals = sum(len(memory_collage_assets(m, people_only=people_only)) for m in memories)
    print(
        f"INFO collage diario fecha={target_date} memories={len(memories)} "
        f"fotos_originales={total_originals} previews={len(daily_paths)} missing_previews={missing}"
    )
    print(
        f"  target_memory={target_mid} year={target_year} "
        f"fotos_target={target_originals} "
        f"selección={'solo_personas' if people_only else 'mixta'}"
    )

    recent_daily_decisions = load_recent_daily_decisions(target_date)
    recent_layouts = [
        item.get("layout")
        for item in recent_daily_decisions
        if isinstance(item, dict) and item.get("layout") in LAYOUTS
    ]
    if recent_daily_decisions:
        print(f"  Historial reciente: {recent_collage_context(recent_daily_decisions)}")

    decision = ask_gemini(
        gemini_key,
        daily_paths,
        target_date.month,
        memory_key=f"daily:{target_date.isoformat()}",
        allow_fallback=allow_fallback,
        alert_context=f"collage diario {target_date.isoformat()}",
        recent_daily_decisions=recent_daily_decisions,
    )
    layout_name  = decision.get("layout", "")
    palette_name = decision.get("palette", "default")
    order_raw    = decision.get("photo_order", [])
    reason       = decision.get("reason", "")
    fallback = fallback_decision(
        len(daily_paths),
        target_date.month,
        memory_key=f"daily:{target_date.isoformat()}",
        photo_paths=daily_paths,
        avoid_layouts=recent_layouts[:1],
    )
    layout_name, layout_note = choose_layout(layout_name, len(daily_paths), fallback, decision, recent_layouts=recent_layouts)
    if layout_note:
        print(f"  WARN: {layout_note}")

    palette_name = normalize_palette_name(palette_name)
    title, used_title_fallback = choose_title(decision, fallback.get("title", f"Recuerdo del {target_date.isoformat()}"))
    if used_title_fallback:
        print(f"  WARN: título genérico o vacío de Gemini, usando fallback='{title}'")

    if not isinstance(order_raw, list):
        order_raw = []
    valid_order = []
    seen = set()
    for idx in order_raw:
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            continue
        if 0 <= idx < len(daily_paths) and idx not in seen:
            valid_order.append(idx)
            seen.add(idx)
    for i in range(len(daily_paths)):
        if i not in seen:
            valid_order.append(i)

    model_used = decision.get("_gemini_model", "fallback")
    subtitle = f"{target_date.day} {MESES[target_date.month]} {target_date.year}"
    print(f"  Gemini[{model_used}] → layout={layout_name} paleta={palette_name} título='{title}'")
    print(f"  Razón: {reason}")

    ordered_paths = [daily_paths[i] for i in valid_order]
    pal = PALETTES.get(palette_name, PALETTES["default"])
    layout_fn = LAYOUTS[layout_name]

    if force:
        remove_collage_assets(api_base, headers, memories, dry_run)

    if dry_run:
        print(f"  DRYRUN: generaría collage diario único para {target_date} en memory {target_mid}")
        return True

    Path(COLLAGE_DIR).mkdir(parents=True, exist_ok=True)
    out_path = Path(COLLAGE_DIR) / f"collage-daily-{target_date.isoformat()}.jpg"
    sidecar_path = out_path.with_suffix(".json")
    write_decision_sidecar(sidecar_path, {
        "mode": "daily",
        "target_date": target_date.isoformat(),
        "target_memory": target_mid,
        "target_memory_year": target_year,
        "gemini_model": model_used,
        "gemini_error": decision.get("_gemini_error"),
        "layout": layout_name,
        "palette": palette_name,
        "title": title,
        "theme": clean_title_candidate(decision.get("theme")),
        "layout_candidates": layout_candidates_from_decision(decision),
        "title_options": coerce_string_list(decision.get("title_options")),
        "recent_layouts": recent_layouts[:2],
        "photo_order": valid_order,
        "reason": reason,
        "allow_fallback": allow_fallback,
        "selected_paths": [Path(p).name for p in ordered_paths],
    })
    print(f"  Decisión guardada: {sidecar_path}")
    try:
        img, W, H = layout_fn(ordered_paths, title, subtitle, pal)
        img.save(str(out_path), "JPEG", quality=94)
        print(f"  Collage diario: {out_path} ({out_path.stat().st_size//1024} KB) {W}x{H}")
    except Exception as e:
        print(f"  ERROR generando collage diario: {e}", file=sys.stderr)
        return False

    created_at = local_asset_created_at(target_date, zone)

    asset_id = upload_collage(api_base, headers, out_path, created_at)
    if not asset_id:
        print(f"  ERROR: falló la subida del collage diario", file=sys.stderr)
        return False

    print(f"  Subido collage diario: asset_id={asset_id}")
    c, body = http_json("PUT", f"{api_base}/memories/{target_mid}/assets", {"ids": [asset_id]}, headers=headers)
    if c not in (200, 201):
        print(f"  WARN: subido pero no insertado en memory destino {target_mid}: {c} {body}", file=sys.stderr)
        return False
    return ensure_collage_first(api_base, headers, target_mid, asset_id)

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--api-base",     default=API_BASE)
    p.add_argument("--secrets-file", default=SECRETS_FILE)
    p.add_argument("--timezone",     default=os.environ.get("MEMORIES_TIMEZONE", TIMEZONE))
    p.add_argument("--days-offset",  type=int, default=0)
    p.add_argument("--memory-id",    default=None)
    p.add_argument("--dry-run",      action="store_true")
    p.add_argument("--force",        action="store_true")
    p.add_argument("--allow-fallback", action="store_true",
                   default=env_is_true(os.environ.get("COLLAGE_ALLOW_FALLBACK"), False))
    return p.parse_args()

def main() -> int:
    args = parse_args()
    try: zone = ZoneInfo(args.timezone)
    except: zone = dt.timezone.utc

    secrets    = read_secrets(args.secrets_file)
    email      = secrets.get("IMMICH_ADMIN_EMAIL","")
    password   = secrets.get("IMMICH_ADMIN_PASSWORD","")
    gemini_key = secrets.get("GEMINI_API_KEY","")

    now_local   = dt.datetime.now(zone)
    target_date = (now_local + dt.timedelta(days=args.days_offset)).date()
    print(f"INFO fecha={target_date} mes={MESES[target_date.month]}")
    print(f"INFO Gemini requerido={'no' if args.allow_fallback else 'sí'} modelos={','.join(GEMINI_MODELS)}")

    if not email or not password:
        print("ERROR: faltan credenciales Immich", file=sys.stderr); return 2
    if not gemini_key:
        if args.allow_fallback:
            print("WARN: sin GEMINI_API_KEY — usando fallback local", file=sys.stderr)
        else:
            send_nas_alert(
                f"[collage-daily] GEMINI_API_KEY ausente para {target_date.isoformat()}",
                key=f"collage-gemini-missing:{target_date.isoformat()}",
            )
            print("ERROR: falta GEMINI_API_KEY y el fallback está desactivado", file=sys.stderr)
            return 2

    c, login = http_json("POST", f"{args.api_base}/auth/login",
                         {"email":email,"password":password})
    if c not in (200,201) or "accessToken" not in login:
        print(f"ERROR login: {c}", file=sys.stderr); return 2
    headers = {"Authorization": f"Bearer {login['accessToken']}"}

    email_safe = email.replace("'", "''")
    rows = db_query(f"SELECT id::text FROM \"user\" WHERE email='{email_safe}' LIMIT 1;")
    if not rows: print("ERROR: usuario no encontrado", file=sys.stderr); return 2
    user_id = rows[0]

    if args.memory_id:
        c, m = http_json("GET", f"{args.api_base}/memories/{args.memory_id}", headers=headers)
        if c != 200: print(f"ERROR: memory no encontrada", file=sys.stderr); return 2
        annotate_usable_assets([m])
        annotate_preview_faces([m], user_id)
        try:
            ok = process_memory(m, user_id, target_date, gemini_key,
                                args.api_base, headers, args.dry_run, args.force,
                                args.allow_fallback, zone)
        except Exception as e:
            print(f"  ERROR {m.get('id')}: {e}", file=sys.stderr)
            ok = False
        print(f"\nSUMMARY fecha={target_date} memory={args.memory_id} ok={1 if ok else 0}/1")
        return 0 if ok else 1

    c, all_mem = http_json("GET", f"{args.api_base}/memories", headers=headers)
    if c != 200 or not isinstance(all_mem, list):
        print(f"ERROR GET /memories: {c}", file=sys.stderr); return 2
    utc_today = dt.datetime.combine(target_date, dt.time.min, tzinfo=dt.timezone.utc)
    memories = [
        m for m in all_mem
        if isinstance(m,dict)
        and m.get("showAt","")
        and dt.datetime.fromisoformat(m["showAt"].replace("Z","+00:00")).date() == utc_today.date()
        and len(m.get("assets",[])) > 0
    ]
    annotate_usable_assets(memories)
    annotate_preview_faces(memories, user_id)

    if not memories:
        print(f"INFO: sin memories con assets para {target_date}"); return 0

    print(f"INFO: {len(memories)} memories")
    try:
        ok = process_day(memories, user_id, target_date, gemini_key,
                         args.api_base, headers, args.dry_run, args.force,
                         args.allow_fallback, zone)
    except Exception as e:
        print(f"ERROR collage diario: {e}", file=sys.stderr)
        ok = False

    print(f"\nSUMMARY fecha={target_date} ok={1 if ok else 0}/1")
    return 0 if ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
