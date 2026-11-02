"""Builds the sponsor decal atlas for the car liveries (plain Python + Pillow).

    python3 modules/graphics/tools/build_decals.py

Every sponsor is invented for the game (no real brands). Outputs:
  modules/graphics/textures/decals.png   the atlas: 4 columns x 16 rows of
                                         512x128 cells
  modules/graphics/data/sponsors.json    one entry per cell: name, cell,
                                         kind (title, minor, contingency) and
                                         the brand's own colours

Channels (the paint shader colours them per car):
  R = the logo's lettering (foreground colour)
  G = the sticker panel behind it (panel colour; 0 = no panel, paint shows)
  B = the logo's second colour (emblem, stripe)
  A = coverage (max of R, G, B)
"""

import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.dirname(HERE)
OUT_PNG = os.path.join(GFX, "textures", "decals.png")
OUT_JSON = os.path.join(GFX, "data", "sponsors.json")
OUT_DIGITS = os.path.join(GFX, "textures", "digits.png")   # race numbers: 0-9, 128x192 each

COLS, ROWS = 4, 16
CW, CH = 512, 128
PAD = 10
SS = 2  # supersampling

FONT_DIRS = ["/usr/share/fonts/opentype/inter", "/usr/share/fonts/truetype/dejavu",
             "/usr/share/fonts/truetype/freefont", "/usr/share/fonts/truetype/liberation",
             "/usr/share/fonts/truetype/crosextra", "/usr/share/fonts/truetype/jetbrains-mono"]


def font(name, size):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


# name, font, style, brand fg, brand bg, brand accent
# styles: plain, panel, emblem_circle, emblem_diamond, chevrons, slash, boxed,
#         underline, wing, star, wave
SPONSORS = [
    ("VOLTRIX", "InterDisplay-BlackItalic.otf", "slash", "#111111", "#c6ff00", "#111111"),
    ("KESTREL OIL", "Inter-ExtraBold.otf", "emblem_circle", "#111111", "#ffcc00", "#d40000"),
    ("NORDHAVN", "InterDisplay-Bold.otf", "wave", "#ffffff", "#0b2e59", "#5ec8f2"),
    ("PYRAXIS", "FreeSansBoldOblique.ttf", "chevrons", "#ffffff", "#e4002b", "#ffd100"),
    ("HALCYON TYRES", "LiberationSans-BoldItalic.ttf", "underline", "#ffffff", "#111111", "#f5a300"),
    ("BRISKA", "InterDisplay-Black.otf", "panel", "#ffffff", "#ff5a00", "#ffffff"),
    ("ORBITAL", "Inter-SemiBold.otf", "emblem_circle", "#1f2a44", "#ffffff", "#00a3e0"),
    ("MARLOWE & FINCH", "DejaVuSerif-Bold.ttf", "plain", "#c9a646", "#101820", "#c9a646"),
    ("QUANTEX", "JetBrainsMono-ExtraBold.ttf", "boxed", "#ffffff", "#5b2c83", "#00e5a0"),
    ("SOLENNE", "InterDisplay-ExtraBoldItalic.otf", "star", "#ffffff", "#c8102e", "#ffffff"),
    ("TIDEWATER BANK", "Carlito-Bold.ttf", "wave", "#003b5c", "#ffffff", "#00a499"),
    ("ZEPHYRA", "InterDisplay-BlackItalic.otf", "wing", "#ffffff", "#00838f", "#ffffff"),
    ("IRONVALE", "LiberationSans-Bold.ttf", "emblem_diamond", "#ffffff", "#2b2b2b", "#e10600"),
    ("COPPERLINE", "Inter-Bold.otf", "underline", "#b5651d", "#ffffff", "#b5651d"),
    ("AURELIO", "DejaVuSerif-Bold.ttf", "panel", "#111111", "#f2c94c", "#111111"),
    ("CINDRA FUELS", "FreeSansBoldOblique.ttf", "slash", "#ffffff", "#d62828", "#fcbf49"),
    ("FALKENRIDGE", "InterDisplay-ExtraBold.otf", "chevrons", "#ffffff", "#14213d", "#fca311"),
    ("lumio", "InterDisplay-Black.otf", "emblem_circle", "#ffffff", "#7b2ff7", "#ffd60a"),
    ("RAPTEC", "JetBrainsMono-ExtraBoldItalic.ttf", "slash", "#111111", "#ffffff", "#e10600"),
    ("BLUEWICK", "Inter-ExtraBold.otf", "panel", "#ffffff", "#1565c0", "#ffffff"),
    ("OKTANO", "InterDisplay-BlackItalic.otf", "boxed", "#ffffff", "#111111", "#ff6f00"),
    ("STRATA DATA", "Inter-SemiBold.otf", "emblem_diamond", "#263238", "#ffffff", "#00bfa5"),
    ("AEROLUNA", "InterDisplay-BoldItalic.otf", "wing", "#0d47a1", "#ffffff", "#e53935"),
    ("TORVIK", "LiberationSans-Bold.ttf", "underline", "#ffffff", "#37474f", "#ffeb3b"),
    ("HEXAFIN", "JetBrainsMono-Bold.ttf", "emblem_diamond", "#ffffff", "#00695c", "#a5d6a7"),
    ("GLACIA", "InterDisplay-ExtraBold.otf", "wave", "#ffffff", "#4fc3f7", "#ffffff"),
    ("REDMOOR", "DejaVuSerif-Bold.ttf", "plain", "#ffffff", "#7f0000", "#ffffff"),
    ("NOVACELL", "Inter-Black.otf", "star", "#111111", "#00e676", "#111111"),
    ("BRIGHTFORGE", "InterDisplay-Bold.otf", "chevrons", "#212121", "#ffab00", "#212121"),
    ("KYRELL", "FreeSansBoldOblique.ttf", "panel", "#ffffff", "#ad1457", "#ffffff"),
    ("ONDINE", "InterDisplay-Medium.otf", "wave", "#1a237e", "#e3f2fd", "#1a237e"),
    ("GRAVITON", "InterDisplay-BlackItalic.otf", "slash", "#ffffff", "#212121", "#76ff03"),
    ("VELOCITA", "LiberationSans-BoldItalic.ttf", "underline", "#ffffff", "#c62828", "#ffffff"),
    ("MOSSGATE", "Carlito-Bold.ttf", "emblem_circle", "#ffffff", "#2e7d32", "#c5e1a5"),
    ("SIGNAL ONE", "Inter-ExtraBold.otf", "boxed", "#111111", "#ffffff", "#ff3d00"),
    ("ATLASPAY", "InterDisplay-Bold.otf", "emblem_diamond", "#ffffff", "#283593", "#ffca28"),
    ("BRAKEMASTER", "FreeSansBoldOblique.ttf", "chevrons", "#ffffff", "#111111", "#ff1744"),
    ("PELLARO", "DejaVuSerif-Bold.ttf", "panel", "#ffffff", "#4e342e", "#ffffff"),
    ("TRIDENTA", "InterDisplay-Black.otf", "star", "#ffffff", "#006064", "#ffffff"),
    ("WREN SYSTEMS", "Inter-SemiBold.otf", "underline", "#212121", "#ffffff", "#7c4dff"),
    ("FUSELINK", "JetBrainsMono-ExtraBold.ttf", "slash", "#ffffff", "#0277bd", "#ffee58"),
    ("CASTELLAN", "DejaVuSerif-Bold.ttf", "emblem_circle", "#ffffff", "#1b1b1b", "#d4af37"),
    ("ZINNIA", "InterDisplay-ExtraBoldItalic.otf", "wave", "#ffffff", "#ec407a", "#ffffff"),
    ("PROVANT", "Inter-Black.otf", "boxed", "#ffffff", "#455a64", "#80deea"),
    ("RUSTICA", "LiberationSans-Bold.ttf", "plain", "#ffffff", "#bf360c", "#ffffff"),
    ("ECHOVIA", "InterDisplay-Bold.otf", "wing", "#ffffff", "#6a1b9a", "#ffffff"),
    ("TALONTECH", "FreeSansBoldOblique.ttf", "emblem_diamond", "#111111", "#cfd8dc", "#d50000"),
    ("SKARA", "InterDisplay-BlackItalic.otf", "chevrons", "#ffffff", "#ff6d00", "#111111"),
    ("BLACKFEN", "Inter-ExtraBold.otf", "panel", "#ffffff", "#111111", "#ffffff"),
    ("HELIOR", "InterDisplay-ExtraBold.otf", "star", "#ff8f00", "#ffffff", "#ff8f00"),
    ("NEXORA", "JetBrainsMono-Bold.ttf", "underline", "#ffffff", "#00897b", "#ffffff"),
    ("ALDERTON", "DejaVuSerif-Bold.ttf", "boxed", "#ffffff", "#1a237e", "#ff5252"),
    ("SPEEDWELL", "LiberationSans-BoldItalic.ttf", "slash", "#111111", "#ffeb3b", "#111111"),
    ("CORVANE", "InterDisplay-Black.otf", "emblem_circle", "#ffffff", "#c2185b", "#ffffff"),
    ("TERRAFIX", "Inter-Bold.otf", "chevrons", "#ffffff", "#5d4037", "#ffb300"),
    ("FLUXWORKS", "InterDisplay-BoldItalic.otf", "wave", "#ffffff", "#304ffe", "#82b1ff"),
    ("OBERLAND", "Carlito-Bold.ttf", "plain", "#111111", "#ffffff", "#111111"),
    ("MAGNIS", "InterDisplay-ExtraBoldItalic.otf", "emblem_diamond", "#ffffff", "#b71c1c", "#ffffff"),
    ("QUILLON", "DejaVuSerif-Bold.ttf", "underline", "#ffffff", "#263238", "#ffc107"),
    ("VIRELLO", "Inter-Black.otf", "wing", "#111111", "#ffffff", "#00b0ff"),
]
N_CONTINGENCY = 4   # the last cells: clusters of small stickers


def fit_font(draw, text, fname, max_w, max_h):
    size = max_h
    while size > 8:
        f = font(fname, size)
        b = draw.textbbox((0, 0), text, font=f)
        if b[2] - b[0] <= max_w and b[3] - b[1] <= max_h:
            return f, b
        size -= 2
    f = font(fname, size)
    return f, draw.textbbox((0, 0), text, font=f)


def draw_logo(name, fname, style):
    """Returns (R, G, B) layers of one cell (CW*SS x CH*SS, mode L)."""
    W, H = CW * SS, CH * SS
    p = PAD * SS
    R = Image.new("L", (W, H), 0)
    G = Image.new("L", (W, H), 0)
    B = Image.new("L", (W, H), 0)
    dr, dg, db = ImageDraw.Draw(R), ImageDraw.Draw(G), ImageDraw.Draw(B)
    x0, y0, x1, y1 = p, p, W - p, H - p
    text_box = [x0 + 18 * SS, y0 + 10 * SS, x1 - 18 * SS, y1 - 10 * SS]
    panel = style in ("panel", "boxed", "emblem_circle", "emblem_diamond", "chevrons", "slash", "star", "wing", "wave", "underline")
    if style == "plain":
        panel = False
    if panel:
        if style == "slash":
            sk = (y1 - y0) * 0.35
            dg.polygon([(x0 + sk, y0), (x1, y0), (x1 - sk, y1), (x0, y1)], fill=255)
        else:
            dg.rounded_rectangle([x0, y0, x1, y1], radius=14 * SS, fill=255)
    hb = (y1 - y0)
    if style in ("emblem_circle", "emblem_diamond", "star"):
        cx = x0 + hb * 0.62
        cy = (y0 + y1) / 2
        r = hb * 0.36
        if style == "emblem_circle":
            db.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
            dg.ellipse([cx - r * 0.55, cy - r * 0.55, cx + r * 0.55, cy + r * 0.55], fill=255)
            db.ellipse([cx - r * 0.55, cy - r * 0.55, cx + r * 0.55, cy + r * 0.55], fill=0)
            db.ellipse([cx - r * 0.3, cy - r * 0.3, cx + r * 0.3, cy + r * 0.3], fill=255)
        elif style == "emblem_diamond":
            db.polygon([(cx, cy - r * 1.1), (cx + r, cy), (cx, cy + r * 1.1), (cx - r, cy)], fill=255)
            db.polygon([(cx, cy - r * 0.5), (cx + r * 0.45, cy), (cx, cy + r * 0.5), (cx - r * 0.45, cy)], fill=0)
        else:
            pts = []
            for k in range(10):
                a = -math.pi / 2 + k * math.pi / 5
                rr = r * (1.15 if k % 2 == 0 else 0.48)
                pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
            db.polygon(pts, fill=255)
        text_box[0] = cx + r * 1.4
    elif style == "chevrons":
        for k in range(3):
            xx = x0 + 18 * SS + k * hb * 0.22
            db.polygon([(xx, y0 + hb * 0.18), (xx + hb * 0.14, y0 + hb * 0.18), (xx + hb * 0.34, y0 + hb * 0.5),
                        (xx + hb * 0.14, y0 + hb * 0.82), (xx, y0 + hb * 0.82), (xx + hb * 0.2, y0 + hb * 0.5)], fill=255)
        text_box[0] = x0 + 18 * SS + hb * 0.95
    elif style == "wing":
        cx = x0 + hb * 0.7
        cy = (y0 + y1) / 2
        for k in range(3):
            w = hb * (0.55 - k * 0.12)
            yy = cy - hb * 0.22 + k * hb * 0.17
            db.polygon([(cx - w, yy), (cx + w * 0.4, yy), (cx + w * 0.55, yy + hb * 0.1), (cx - w * 0.8, yy + hb * 0.1)], fill=255)
        text_box[0] = cx + hb * 0.62
    elif style == "boxed":
        db.rectangle([x1 - hb * 0.32, y0, x1, y1], fill=255)
        dg.rectangle([x1 - hb * 0.32, y0, x1, y1], fill=0)
        text_box[2] = x1 - hb * 0.4
    elif style == "slash":
        sk = (y1 - y0) * 0.35
        db.polygon([(x1 - sk * 0.9, y0), (x1 - sk * 0.5, y0), (x1 - sk * 1.4, y1), (x1 - sk * 1.8, y1)], fill=255)
        text_box = [x0 + sk + 8 * SS, y0 + 10 * SS, x1 - sk * 1.9, y1 - 10 * SS]
    elif style == "underline":
        db.rectangle([x0 + 18 * SS, y1 - hb * 0.2, x1 - 18 * SS, y1 - hb * 0.12], fill=255)
        text_box[3] = y1 - hb * 0.24
    elif style == "wave":
        pts = []
        for k in range(41):
            u = k / 40
            pts.append((lerp(x0 + 14 * SS, x1 - 14 * SS, u), y1 - hb * 0.2 + math.sin(u * math.tau * 1.5) * hb * 0.06))
        db.line(pts, fill=255, width=int(hb * 0.07))
        text_box[3] = y1 - hb * 0.3
    tw, th = text_box[2] - text_box[0], text_box[3] - text_box[1]
    f, b = fit_font(dr, name, fname, tw, th)
    tx = text_box[0] + (tw - (b[2] - b[0])) / 2 - b[0]
    ty = text_box[1] + (th - (b[3] - b[1])) / 2 - b[1]
    dr.text((tx, ty), name, font=f, fill=255)
    # lettering knocks out the second colour, never the panel
    B.paste(0, mask=R)
    return R, G, B


def draw_contingency(seed):
    """A cluster of small stickers in rows, like the manufacturer
    contingency decals on the sills and front wings of a race car."""
    W, H = CW * SS, CH * SS
    R = Image.new("L", (W, H), 0)
    G = Image.new("L", (W, H), 0)
    B = Image.new("L", (W, H), 0)
    dr, dg, db = ImageDraw.Draw(R), ImageDraw.Draw(G), ImageDraw.Draw(B)
    rnd = random.Random(seed)
    names = [s[0] for s in SPONSORS]
    rnd.shuffle(names)
    p = PAD * SS
    rows = 2
    rh = (H - 2 * p - 6 * SS) / rows
    k = 0
    for r in range(rows):
        x = p
        y = p + r * (rh + 6 * SS)
        while x < W - p - 40 * SS:
            w = rnd.uniform(70, 150) * SS
            w = min(w, W - p - x)
            kind = rnd.random()
            if kind < 0.45:
                dg.rectangle([x, y, x + w, y + rh], fill=255)
                target = dr
            elif kind < 0.75:
                db.rectangle([x, y, x + w, y + rh], fill=255)
                target = dg
            else:
                target = dr
                db.rectangle([x, y + rh * 0.78, x + w, y + rh], fill=255)
            name = names[k % len(names)]
            k += 1
            f, b = fit_font(target, name, "Inter-ExtraBold.otf", w - 10 * SS, rh * 0.62)
            tx = x + (w - (b[2] - b[0])) / 2 - b[0]
            ty = y + (rh * 0.8 - (b[3] - b[1])) / 2 - b[1]
            target.text((tx, ty), name, font=f, fill=255)
            if target is dg:
                db.text((tx, ty), name, font=f, fill=0)
            x += w + 6 * SS
    B.paste(0, mask=R)
    return R, G, B


def build_digits():
    """Race-number digits 0-9 in one strip (alpha = digit), bold italic."""
    dw, dh = 128, 192
    img = Image.new("L", (dw * 10 * SS, dh * SS), 0)
    d = ImageDraw.Draw(img)
    for k in range(10):
        f, b = fit_font(d, str(k), "InterDisplay-Black.otf", (dw - 12) * SS, (dh - 20) * SS)
        x = k * dw * SS + (dw * SS - (b[2] - b[0])) / 2 - b[0]
        y = (dh * SS - (b[3] - b[1])) / 2 - b[1]
        d.text((x, y), str(k), font=f, fill=255)
    img = img.resize((dw * 10, dh), Image.LANCZOS)
    white = Image.new("L", img.size, 255)
    Image.merge("RGBA", (white, white, white, img)).save(OUT_DIGITS, optimize=True)


def lerp(a, b, k):
    return a + (b - a) * k


def main():
    atlas = Image.new("RGBA", (COLS * CW, ROWS * CH), (0, 0, 0, 0))
    entries = []
    cells = len(SPONSORS) + N_CONTINGENCY
    assert cells <= COLS * ROWS, "too many sponsors for the atlas"
    for i in range(cells):
        if i < len(SPONSORS):
            name, fname, style, fg, bg, ac = SPONSORS[i]
            R, G, B = draw_logo(name, fname, style)
            kind = "title" if style not in ("plain",) else "minor"
            entries.append({"name": name, "cell": i, "kind": kind, "style": style,
                            "fg": fg, "bg": bg, "accent": ac, "panel": style != "plain"})
        else:
            R, G, B = draw_contingency(i)
            entries.append({"name": "contingency %d" % (i - len(SPONSORS) + 1), "cell": i, "kind": "contingency",
                            "style": "contingency", "fg": "#111111", "bg": "#ffffff", "accent": "#e10600", "panel": True})
        R, G, B = (L.resize((CW, CH), Image.LANCZOS) for L in (R, G, B))
        A = Image.merge("RGB", (R, G, B)).convert("L")
        # alpha = max of the three
        A = Image.fromarray(__import__("numpy").maximum.reduce([
            __import__("numpy").asarray(R), __import__("numpy").asarray(G), __import__("numpy").asarray(B)]))
        cell = Image.merge("RGBA", (R, G, B, A))
        atlas.paste(cell, ((i % COLS) * CW, (i // COLS) * CH))
    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    atlas.save(OUT_PNG, optimize=True)
    with open(OUT_JSON, "w") as fh:
        json.dump({"_doc": "Invented sponsors for car liveries (none are real brands). cell = index in "
                           "textures/decals.png (4 x 16 cells of 512x128). Built by tools/build_decals.py.",
                   "columns": COLS, "rows": ROWS, "sponsors": entries}, fh, indent=1)
    build_digits()
    print("decals: %d cells -> %s" % (cells, OUT_PNG))


if __name__ == "__main__":
    main()
