# UI direction v3 (docs/design/UI_V2.md section 4): the shared 9-slice frames, drawn with PIL at 4x and downsampled.
#   python3 tools/ui/make_v3_frames.py [outdir]      -> out/ui_v3/*.png and slices.json (SliceCenter per image)
# Every frame: dark navy fill (soft two-stop vertical gradient), a pale steel double edge (#C9D6EA outer, #7F93B8 inner),
# chamfered (cut) corners or skewed ends. Fill variants are separate images so the steel edge never takes a tint.
import json, os, sys
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "out", "ui_v3")
os.makedirs(OUT, exist_ok=True)
SS = 4
STEEL_OUT = (201, 214, 234, 255)
STEEL_IN = (127, 147, 184, 255)
FILLS = {
    "dark": ((26, 48, 107), (11, 21, 51)),
    "blue": ((46, 140, 240), (24, 96, 200)),
    "lime": ((214, 236, 52), (176, 204, 20)),
    "yellow": ((255, 222, 64), (246, 190, 16)),
    "light": ((228, 236, 248), (190, 204, 228)),
    "danger": ((236, 72, 72), (176, 32, 40)),
}
slices = {}


def grad(w, h, top, bot):
    g = Image.new("RGBA", (w, h))
    px = g.load()
    for y in range(h):
        k = y / max(1, h - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * k) for i in range(3)) + (255,)
        for x in range(w):
            px[x, y] = c
    return g


def shape_img(w, h, poly, fill, edge=True, outer=3, inner=2):
    """poly: list of (x, y) in final px. Draws steel outer edge, inner edge, then the fill inset. The canvas is padded
    while eroding, so the straight edges on the image border get their steel too."""
    P = 8 * SS
    W, H = w * SS + 2 * P, h * SS + 2 * P
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon([(x * SS + P, y * SS + P) for x, y in poly], fill=255)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    if edge:
        img.paste(Image.new("RGBA", (W, H), STEEL_OUT), (0, 0), mask)
        m2 = shrink(mask, outer * SS)
        img.paste(Image.new("RGBA", (W, H), STEEL_IN), (0, 0), m2)
        m3 = shrink(m2, inner * SS)
    else:
        m3 = mask
    img.paste(grad(W, H, fill[0], fill[1]), (0, 0), m3)
    img = img.crop((P, P, P + w * SS, P + h * SS))
    return img.resize((w, h), Image.LANCZOS)


def shrink(mask, px):
    from PIL import ImageFilter
    # erode by px (MinFilter needs an odd size)
    k = px * 2 + 1
    return mask.filter(ImageFilter.MinFilter(k)) if k <= 61 else mask


def save(name, img, center):
    p = os.path.join(OUT, name + ".png")
    img.save(p)
    slices[name] = {"size": list(img.size), "center": center}


# 1. chamfer frame (panels, cards): top-left and bottom-right corners cut 14 px
for v, fill in FILLS.items():
    w = h = 96
    c = 14
    poly = [(c, 0), (w, 0), (w, h - c), (w - c, h), (0, h), (0, c)]
    save("frame_" + v, shape_img(w, h, poly, fill), [24, 24, 72, 72])

# 2. skewed bar (list rows, menu keys, buttons): parallelogram, 12 px skew
for v, fill in FILLS.items():
    w, h, s = 128, 48, 12
    poly = [(s, 0), (w, 0), (w - s, h), (0, h)]
    save("bar_" + v, shape_img(w, h, poly, fill, inner=1), [28, 16, 100, 32])

# 3. skewed chip (counters): smaller parallelogram, thin edge
for v in ("dark", "blue"):
    w, h, s = 96, 32, 8
    poly = [(s, 0), (w, 0), (w - s, h), (0, h)]
    save("chip_" + v, shape_img(w, h, poly, FILLS[v], outer=2, inner=1), [20, 10, 76, 22])

# 4. tab (parallelogram, flat top): dark idle, light selected
for v in ("dark", "light", "yellow"):
    w, h, s = 112, 40, 10
    poly = [(s, 0), (w, 0), (w - s, h), (0, h)]
    save("tab_" + v, shape_img(w, h, poly, FILLS[v], outer=2, inner=1), [24, 12, 88, 28])

# 5. hazard stripe band texture (tile): faint diagonal white stripes on transparent
w = h = 32
st = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
d = ImageDraw.Draw(st)
for k in range(-2, 4):
    x0 = k * 16 * SS
    d.polygon([(x0, h * SS), (x0 + 8 * SS, h * SS), (x0 + 8 * SS + h * SS, 0), (x0 + h * SS, 0)], fill=(255, 255, 255, 40))
save("stripe_tile", st.resize((w, h), Image.LANCZOS), None)

# 6. triangle cursor (focused list row)
w, h = 32, 32
tri = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
ImageDraw.Draw(tri).polygon([(4 * SS, 2 * SS), (30 * SS, 16 * SS), (4 * SS, 30 * SS)], fill=(255, 255, 255, 255))
save("cursor_tri", tri.resize((w, h), Image.LANCZOS), None)

json.dump(slices, open(os.path.join(OUT, "slices.json"), "w"), indent=1)
print("wrote", len(slices), "images to", os.path.abspath(OUT))
