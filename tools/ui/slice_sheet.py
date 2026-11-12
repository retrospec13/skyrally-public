#!/usr/bin/env python3
"""Cut a transparent 4x4 icon sheet into square PNGs: slice_sheet.py <sheet.png> <out_dir> <name1,name2,...> [size=256]
Finds each icon by alpha connected components (merged per grid cell), trims, pads to a square with a margin and resizes."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image
from scipy import ndimage

sheet, out, names = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3].split(",")
size = int(sys.argv[4]) if len(sys.argv) > 4 else 256
n = int(round(len(names) ** 0.5))
im = Image.open(sheet).convert("RGBA")
a = np.array(im)[:, :, 3] > 24
lab, cnt = ndimage.label(a)
H, W = a.shape
boxes = {}
for i, sl in enumerate(ndimage.find_objects(lab), 1):
    if sl is None or (lab[sl] == i).sum() < 400:
        continue
    cy, cx = (sl[0].start + sl[0].stop) / 2, (sl[1].start + sl[1].stop) / 2
    cell = (min(n - 1, int(cy * n / H)), min(n - 1, int(cx * n / W)))
    b = boxes.get(cell)
    y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
    boxes[cell] = (y0, y1, x0, x1) if b is None else (min(b[0], y0), max(b[1], y1), min(b[2], x0), max(b[3], x1))
out.mkdir(parents=True, exist_ok=True)
for k, name in enumerate(names):
    cell = (k // n, k % n)
    if cell not in boxes:
        print("MISSING", name)
        continue
    y0, y1, x0, x1 = boxes[cell]
    crop = im.crop((x0, y0, x1, y1))
    side = int(max(crop.size) * 1.08)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(crop, ((side - crop.width) // 2, (side - crop.height) // 2))
    sq.resize((size, size), Image.LANCZOS).save(out / f"{name}.png")
print("cut", len(boxes), "of", len(names))
