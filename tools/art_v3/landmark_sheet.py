#!/usr/bin/env python3
"""preview.png (2x2: three-quarter, front, right, back) for a run_landmark.py output dir."""
import json, sys
from pathlib import Path
from PIL import Image, ImageDraw
d = Path(sys.argv[1]); name = sys.argv[2]
st = json.loads((d / "stats.json").read_text())
views = ["threeq", "front", "right", "back"]
ims = [Image.open(d / f"view_{v}.png").convert("RGB") for v in views]
W = ims[0].width; band = 30
sheet = Image.new("RGB", (W * 2, W * 2 + band), (24, 22, 26))
dr = ImageDraw.Draw(sheet)
sx, sy, sz = st["size_studs_xyz"]
dr.text((10, 9), f"SkyRally landmark '{name}'  {st['tris']} tris  {sx} x {sy} x {sz} studs (Roblox X,Y,Z)  tex "
        f"{st['textures'][0]['size'] if st['textures'] else '-'}", fill=(255, 220, 140))
for i, (im, lab) in enumerate(zip(ims, ["three-quarter", "front (-Z)", "right (+X)", "back (+Z)"])):
    x, y = (i % 2) * W, band + (i // 2) * W
    sheet.paste(im, (x, y)); dr.text((x + 8, y + 6), lab, fill=(255, 255, 255))
sheet.save(d / "preview.png")
