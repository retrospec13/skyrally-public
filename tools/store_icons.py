#!/usr/bin/env python3
"""Build SkyRally's six 512x512 store icons from the generated base sheet (assets/store_icons/source/base_sheet.png,
GPT Image 2.5 via Higgsfield, references: our own approved 04_dino4_controls.png UI crops and 01_plane.png only) by
cutting the 3x2 tiles and compositing the crisp numerals / x2 / PREMIUM with Lilita One (OFL, tools/fonts/).
Also writes contact.png (512 and 60 px rows, plus a circle-cropped 60 px row as Roblox shows pass icons).

Run: python3 tools/store_icons.py
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, "assets", "store_icons")
SHEET = os.path.join(OUT, "source", "base_sheet.png")
FONT = os.path.join(HERE, "fonts", "LilitaOne-Regular.ttf")

# Tile boxes in the 2048x1360 sheet (cream gutters measured), trimmed to squares around each tile centre.
COLS = [(24, 666), (704, 1346), (1384, 2028)]
ROWS = [(18, 644), (681, 1309)]

CREAM = (247, 231, 196)
INK = (52, 30, 16)

# file, tile (col,row), text, text box in 512 space (x0, y0, x1, y1)
ICONS = [
    ("cash_500.png", (0, 0), "500", (70, 320, 442, 432)),
    ("cash_1200.png", (1, 0), "1,200", (70, 320, 442, 432)),
    ("cash_3500.png", (2, 0), "3,500", (70, 320, 442, 432)),
    ("cash_8000.png", (0, 1), "8,000", (70, 330, 442, 440)),
    ("cash_x2.png", (1, 1), "x2", (250, 95, 468, 335)),
    ("cash_x2.png", None, "CASH", (110, 362, 402, 430)),  # second stamp on the same icon's lower plank
    ("win_pass_premium.png", (2, 1), "PREMIUM", (78, 335, 434, 425)),
]


def tile(sheet, col, row):
    x0, x1 = COLS[col]
    y0, y1 = ROWS[row]
    side = min(x1 - x0, y1 - y0) - 12  # inset past the cream gutter's anti-aliased edge
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    box = (cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)
    return sheet.crop(box).resize((512, 512), Image.LANCZOS)


def fit_font(text, box, stroke):
    w, h = box[2] - box[0], box[3] - box[1]
    size = 300
    while size > 10:
        f = ImageFont.truetype(FONT, size)
        l, t, r, b = f.getbbox(text, stroke_width=stroke)
        if r - l <= w and b - t <= h:
            return f
        size -= 2
    return ImageFont.truetype(FONT, size)


def stamp(img, text, box):
    stroke = 9
    f = fit_font(text, box, stroke)
    l, t, r, b = f.getbbox(text, stroke_width=stroke)
    x = box[0] + ((box[2] - box[0]) - (r - l)) / 2 - l
    y = box[1] + ((box[3] - box[1]) - (b - t)) / 2 - t
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x + 5, y + 7), text, font=f, fill=INK + (170,), stroke_width=stroke, stroke_fill=INK + (170,))
    shadow = shadow.filter(ImageFilter.GaussianBlur(4))
    img = Image.alpha_composite(img, shadow)
    ImageDraw.Draw(img).text((x, y), text, font=f, fill=CREAM, stroke_width=stroke, stroke_fill=INK)
    return img


def build():
    sheet = Image.open(SHEET).convert("RGB")
    made = []
    work = {}
    for name, cell, text, box in ICONS:
        if cell is not None:
            work[name] = tile(sheet, *cell).convert("RGBA")
        work[name] = stamp(work[name], text, box)
    for name in work:
        out = work[name].convert("RGB")
        out.save(os.path.join(OUT, name), optimize=True)
        made.append((name, out))
    contact(made)
    return made


def contact(made):
    pad, n = 16, len(made)
    W = pad + n * (512 + pad)
    H = pad + 512 + pad + 60 + pad + 60 + pad + 28
    sheet = Image.new("RGB", (W, H), (36, 28, 34))
    d = ImageDraw.Draw(sheet)
    lab = ImageFont.truetype(FONT, 22)
    mask = Image.new("L", (60, 60), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, 59, 59), fill=255)
    for i, (name, img) in enumerate(made):
        x = pad + i * (512 + pad)
        sheet.paste(img, (x, pad))
        small = img.resize((60, 60), Image.LANCZOS)
        y60 = pad + 512 + pad
        sheet.paste(small, (x, y60))
        sheet.paste(small, (x + 76, y60 + 60 + pad), mask)
        d.text((x + 150, y60 + 18), name, font=lab, fill=CREAM)
    d.text((pad, H - 34), "512 px | 60 px square | 60 px circle (Roblox pass crop)", font=lab, fill=CREAM)
    sheet.save(os.path.join(OUT, "contact.png"), optimize=True)


if __name__ == "__main__":
    for name, _ in build():
        print("wrote assets/store_icons/" + name)
    print("wrote assets/store_icons/contact.png")
