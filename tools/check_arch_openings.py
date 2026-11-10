#!/usr/bin/env python3
"""Does an arches_v3 mesh (or its colliders) close anything the ORIGINAL arch prefab left open?

For each swapped arch prefab the compiled builder's parts are projected onto the XY plane (the racing line runs along Z), the
original clear opening is the free space reachable from a seed inside it (gaps narrower than 2.5 studs are closed first, the
flood is sealed at the prefab's own bounding box), and then the mesh is placed exactly as src/shared/ArtSwapRules places it
(the CASES table below mirrors the rules: a fixed scale on the prefab origin, or the bbox fit for the DINO arches) and
  * no vertex of the new GLB may lie inside that opening (INTRUSION eroded), and
  * no collider box (manifest `colliders`, scaled and shrunk 0.25 each side) may overlap it by more than 0.5 sq stud above
    y -2 (a box under the ground can never block the road).
A case may clip the opening to the part that matters (the hub portal gate: the original round crown was never a requirement,
the veil and the zone sign are) and may ignore kept Glass (the portal veil is driven through, it is not structure).

Usage: python3 tools/check_arch_openings.py [repo root]      Exit 1 on any violation. Needs numpy and Pillow.
Why not trust the manifest's own opening check: that polygon is the author's reading of the prefab; this reads the prefab.
"""
import json
import math
import re
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
RES = 0.25  # studs per cell
GAP = 1.25  # gaps up to 2 * GAP are closed before the flood fill
X0, X1, Y0, Y1 = -240.0, 240.0, -100.0, 200.0
W, H = int((X1 - X0) / RES), int((Y1 - Y0) / RES)

# case -> asset, builder map, prefab key regex, seed inside the opening (prefab frame), placement, optional clip, glass flag.
# placement: ("fixed", scale) = ArtSwapRules align "origin"; ("bbox", slack) = align "bbox" fitted by height and width;
# ("bboxfixed", scale) = align "bbox" at a fixed scale (the SPACE skyway arches).
CASES = {
    "hub_portal": dict(asset="portal_gate", map="hub0", key=r"^PortalArch_\w+$", seed=(0, 10), place=("fixed", 1.0),
                       clip=(14.0, 30.5), ignore_glass=True),
    "cliff_tunnel_arch": dict(asset="stone_arch_v3", map="hub0", key=r"^CliffTunnelArch$", seed=(0, 20), place=("fixed", 1.0)),
    "cavern_rib": dict(asset="cavern_arch", map="island2", key=r"^CavernArchRib$", seed=(0, 20), place=("fixed", 1.0)),
    "cavern_mouth": dict(asset="cavern_arch", map="island2", key=r"^(CavernMouthArch|CavernExitArch)$", seed=(0, 20), place=("fixed", 1.07)),
    "mine_portal": dict(asset="mine_portal", map="snow1", key=r"^MineTunnelPortal$", seed=(0, 15), place=("fixed", 1.0)),
    "snow_finish_gantry": dict(asset="snow_finish_gantry", map="snow1", key=r"^FinishGantry$", seed=(0, 20), place=("fixed", 1.0)),
    # skyway arches: rule scale 1, align bbox (centred on the prefab's bounding box, sitting on its bottom); they never collided
    "skyway_arch": dict(asset="space_arch", map="space4", key=r"^SkywayArch_\d+$", seed=(0, 20), place=("bboxfixed", 1.0)),
    "mesa_portal": dict(asset="mesa_portal", map="space4", key=r"^MesaTunnelPortal$", seed=(0, 15), place=("fixed", 1.0)),
}


# Cases checked but NOT wired: portal_gate on the DINO course arches (bbox fit, slack 1.12). Their piers stand inside the original
# opening, so the rule stays on the world_v1 arches (expected to report violations; a note says so if that ever changes).
REFUSED = {
    "dino_arch": dict(asset="portal_gate", map="dino4", key=r"^(StoneArchway_S\d+|StartForegroundArch|FTUEFinishArch|StartFinishGate)$",
                      seed=(0, 0), place=("bbox", 1.12), ignore_glass=False),
}
INTRUSION = 0.75  # studs a vertex may sit inside the original opening: the originals step their jambs by up to 1 stud (the cavern mouth)


def euler_yxz(rx, ry, rz):
    rx, ry, rz = map(math.radians, (rx, ry, rz))
    ax = np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
    ay = np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
    az = np.array([[math.cos(rz), -math.sin(rz), 0], [math.sin(rz), math.cos(rz), 0], [0, 0, 1]])
    return ay @ ax @ az


def hull(points):
    pts = sorted(map(tuple, points.tolist()))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    half = []
    for chain in (pts, list(reversed(pts))):
        out = []
        for p in chain:
            while len(out) >= 2 and cross(out[-2], out[-1], p) <= 0:
                out.pop()
            out.append(p)
        half.append(out[:-1])
    return half[0] + half[1]


_builders = {}


def builder_data(map_name):
    if map_name not in _builders:
        text = (ROOT / "build" / map_name / "builder_module.luau").read_text()
        start = text.index("JSONDecode([==[") + len("JSONDecode([==[")
        _builders[map_name] = json.loads(text[start:text.index("]==])", start)])
    return _builders[map_name]


def glb_vertices(path):
    blob = path.read_bytes()
    json_len = struct.unpack("<I", blob[12:16])[0]
    gltf = json.loads(blob[20:20 + json_len])
    bin_at = 20 + json_len
    bin_len = struct.unpack("<I", blob[bin_at:bin_at + 4])[0]
    data = blob[bin_at + 8:bin_at + 8 + bin_len]
    chunks = []
    for mesh in gltf["meshes"]:
        for prim in mesh["primitives"]:
            acc = gltf["accessors"][prim["attributes"]["POSITION"]]
            view = gltf["bufferViews"][acc["bufferView"]]
            offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
            stride = view.get("byteStride", 12)
            raw = np.frombuffer(data, dtype=np.uint8, count=acc["count"] * stride, offset=offset)
            chunks.append(raw.reshape(acc["count"], stride)[:, :12].copy().view("<f4").reshape(acc["count"], 3))
    return np.concatenate(chunks)


def cell(x, y):
    return (x - X0) / RES, H - (y - Y0) / RES


def check(case, prefab_key, entry):
    spec = CASES.get(case) or REFUSED[case]
    prefab = next(p for p in builder_data(spec["map"])["prefabs"] if p["key"] == prefab_key)
    solid = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(solid)
    lo = np.array([1e9, 1e9])
    hi = -lo
    collided = False
    for q in prefab["parts"]:
        x, y, z, sx, sy, sz = q[1:7]
        rot = euler_yxz(q[7], q[8], q[9])
        corners = [rot @ np.array([i * sx, j * sy, k * sz]) + np.array([x, y, z]) for i in (-.5, .5) for j in (-.5, .5) for k in (-.5, .5)]
        xy = np.array([c[:2] for c in corners])
        lo, hi = np.minimum(lo, xy.min(0)), np.maximum(hi, xy.max(0))
        if not (len(q) > 12 and q[12].get("nc")):
            collided = True
        if spec.get("ignore_glass") and q[11] == "Glass":
            continue
        # every other part is solid in the original, and the kept ones (Neon strips, banners, lanterns) stay in place
        draw.polygon([cell(*p) for p in hull(xy)], fill=255)
    xs = X0 + np.arange(W) * RES
    ys = Y1 - np.arange(H) * RES
    sealed = (xs[None, :] < lo[0]) | (xs[None, :] > hi[0]) | (ys[:, None] > hi[1]) | (ys[:, None] < lo[1])
    free = ~((np.array(solid) > 0) | sealed)
    k = int(GAP / RES)
    eroded = Image.fromarray((free * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(2 * k + 1))
    sx, sy = cell(*spec["seed"])
    if eroded.getpixel((int(sx), int(sy))) == 0:
        return [f"{case} {prefab_key}: seed {spec['seed']} is not in free space"]
    ImageDraw.floodfill(eroded, (int(sx), int(sy)), 128)
    flooded = Image.fromarray(((np.array(eroded) == 128) * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(2 * k + 1))
    opening = (np.array(flooded) > 0) & free
    if spec.get("clip"):
        hw, top = spec["clip"]
        opening &= (np.abs(xs[None, :]) <= hw) & (ys[:, None] <= top) & (ys[:, None] >= 0)
    problems = []

    # Where ArtSwapRules puts the mesh: scale s and the mesh origin (x, y) in the prefab frame.
    size, bmin, bmax = entry["size_studs_xyz"], np.array(entry["bbox_min"]), np.array(entry["bbox_max"])
    centre = (bmin + bmax) / 2
    bury = -bmin[1]
    mode, param = spec["place"]
    if mode == "fixed":
        s, ox, oy = param, 0.0, 0.0
    elif mode == "bboxfixed":
        s = param
        ox = (lo[0] + hi[0]) / 2 - centre[0] * s
        oy = lo[1] + bury * s
    else:
        s = max(0.05, min((hi[1] - lo[1]) / size[1], param * (hi[0] - lo[0]) / size[0]))
        ox = (lo[0] + hi[0]) / 2 - centre[0] * s
        oy = lo[1] + bury * s

    verts = glb_vertices(ROOT / "assets" / "models" / "arches_v3" / entry["name"] / f"{entry['name']}.glb")
    vx, vy = verts[:, 0] * s + ox, verts[:, 1] * s + oy
    inner = np.array(Image.fromarray((opening * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(2 * int(INTRUSION / RES) + 1))) > 0
    cx = ((vx - X0) / RES).astype(int)
    cy = (H - (vy - Y0) / RES).astype(int)
    ok = (cx >= 0) & (cx < W) & (cy >= 0) & (cy < H)
    inside = int(inner[cy[ok], cx[ok]].sum())
    if inside:
        problems.append(f"{case} {prefab_key}: {inside} mesh vertices inside the original opening (scale {s:.3f})")

    cols = (entry.get("colliders") or []) if collided else []
    for i, c in enumerate(cols):
        (px, py, _), (sx_, sy_, _) = c["centre"], c["size"]
        px, py, sx_, sy_ = px * s + ox, py * s + oy, sx_ * s, sy_ * s
        a0, a1 = int((px - sx_ / 2 + 0.25 - X0) / RES), int((px + sx_ / 2 - 0.25 - X0) / RES)
        b0, b1 = int((Y1 - (py + sy_ / 2 - 0.25)) / RES), int((Y1 - (py - sy_ / 2 + 0.25)) / RES)
        above_ground = ys[b0:b1] > -2.0
        area = float(opening[b0:b1, a0:a1][above_ground].sum()) * RES * RES
        if area > 0.5:
            problems.append(f"{case} {prefab_key}: collider {i} {c['centre']} {c['size']} overlaps the original opening by {area:.1f} sq studs")
    print(f"{case:18s} {prefab_key:22s} scale {s:6.3f} opening {opening.sum() * RES * RES:9.1f} sq studs, "
          f"mesh vertices inside {inside}, colliders {len(cols)}{'' if collided else ' (original did not collide)'}")
    return problems


def main():
    manifest = {e["name"]: e for e in json.loads((ROOT / "assets/models/arches_v3/manifest.json").read_text())["files"]}
    problems = []
    for case, spec in CASES.items():
        keys = sorted({p["key"] for p in builder_data(spec["map"])["prefabs"] if re.search(spec["key"], p["key"])})
        if not keys:
            problems.append(f"{case}: no prefab matches {spec['key']} in {spec['map']}")
        for key in keys:
            problems += check(case, key, manifest[spec["asset"]])
    for case, spec in REFUSED.items():
        bad = []
        for key in sorted({p["key"] for p in builder_data(spec["map"])["prefabs"] if re.search(spec["key"], p["key"])}):
            bad += check(case, key, manifest[spec["asset"]])
        print(f"REFUSED {case}: {len(bad)} prefabs where {spec['asset']} does not keep the original opening" if bad else
              f"NOTE {case} now keeps the original opening: the portal_gate rule could be enabled")
    for p in problems:
        print("VIOLATION", p)
    print("ARCH_OPENINGS=" + ("FAIL" if problems else "PASS"))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
