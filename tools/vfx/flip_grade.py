#!/usr/bin/env python3
"""Grading recipes + packing for the flip_v2 set (called by tools/vfx/flipbooks.py pack).

Blender sources: out/vfx_flip/<effect>/frames.npz (linear, premultiplied, rendered by win/blender_vfx.py).
Procedural sources: tools/vfx/flip_procedural.py generators (straight alpha, display space).
Outputs: assets/vfx/flip_v2/<name>.png (sheet), <name>.gif (preview over sky / dark / ground), manifest.json,
contact_sheet.png.
"""
import json
import math
from pathlib import Path

import numpy as np

import flipbooks as fb
import flip_procedural as proc

# suggested = starting values for a Roblox ParticleEmitter using the sheet (studs, seconds); colour is the emitter Color
# that reproduces the authored look (white = use the texture's own colours).
RECIPES = {
    "explosion_8x8": dict(
        src="blender:explosion_puff", grid=8, loop=False, emissive=True,
        grade=dict(emissive=True, k_emit=0.9, exposure=1.0, shoulder=0.9, alpha_gain=1.1, alpha_gamma=0.9, sat=1.2),
        fill=0.92, tail=0.22,
        suggested=dict(lifetime=[0.9, 1.1], size=[8, 14], speed=[0, 2], lightEmission=0.35, color="#FFFFFF",
                       flipbookMode="OneShot", rotation=[0, 360], notes="fireball + rolling smoke; pair with spark_streak. LightEmission also makes the dark smoke partly additive (lighter, more see-through on sky); for heavier smoke use 0.15-0.2 or add a smoke_puff emitter")),
    "smoke_puff_8x8": dict(
        src="blender:smoke_puff", grid=8, loop=False, emissive=False,
        grade=dict(exposure=1.0, alpha_gain=1.1, alpha_gamma=0.95), fill=0.92, tail=0.3,
        suggested=dict(lifetime=[1.0, 1.4], size=[3, 7], speed=[1, 3], lightEmission=0, color="#FFFFFF",
                       flipbookMode="OneShot", rotation=[0, 360], notes="neutral grey-white; tint with Color")),
    "fire_loop_8x8": dict(
        src="blender:fire_loop", grid=8, loop=True, xfade=16, emissive=True,
        grade=dict(emissive=True, k_emit=1.6, exposure=1.0, alpha_gain=1.0, alpha_gamma=0.85, gmap_gain=0.55,
                   gmap=[(0.0, (0.55, 0.04, 0.02)), (0.12, (0.85, 0.12, 0.02)), (0.3, (1.0, 0.36, 0.04)),
                         (0.55, (1.0, 0.6, 0.1)), (0.85, (1.0, 0.84, 0.32)), (1.3, (1.0, 0.97, 0.78))]),
        fill=0.94, center="bbox",
        suggested=dict(lifetime=[0.5, 0.8], size=[2, 3.5], speed=[2, 4], lightEmission=0.45, color="#FFFFFF",
                       flipbookMode="Loop", flipbookFramerate=30, notes="boost flames, lava vents, fireball hazard")),
    "dust_burst_4x4": dict(
        src="blender:dust_burst", grid=4, loop=False, emissive=False,
        grade=dict(exposure=1.0, alpha_gain=1.1, alpha_gamma=0.95, sat=0.25), fill=0.94, tail=0.4,
        suggested=dict(lifetime=[0.6, 0.9], size=[3, 6], speed=[0, 1], lightEmission=0, color="#E6D2B4",
                       flipbookMode="OneShot", notes="ground kick: landings, drifts (Orientation FacingCamera)")),
    "snow_burst_4x4": dict(
        src="blender:snow_burst", grid=4, loop=False, emissive=False,
        grade=dict(exposure=1.0, alpha_gain=1.1, alpha_gamma=0.95), fill=0.92, tail=0.5,  # 0.5: hides the smoothed,
        # boxy silhouette the raw puff collapses to in its last 3 frames
        suggested=dict(lifetime=[0.7, 1.0], size=[4, 7], speed=[0, 2], lightEmission=0.2, color="#FFFFFF",
                       flipbookMode="OneShot", notes="powder puff with glints")),
    "water_splash_8x8": dict(
        src="blender:water_splash", grid=8, loop=False, emissive=False,
        grade=dict(exposure=1.35, alpha_gain=1.15, alpha_gamma=0.9, sat=0.6), fill=0.94, tail=0.12, retime=True,
        suggested=dict(lifetime=[0.8, 1.0], size=[6, 9], speed=[0, 0], lightEmission=0.1, color="#FFFFFF",
                       flipbookMode="OneShot", notes="crown splash; spawn at the water line, no rotation. Near-white ice blue, so Color tints it (white = clear water; e.g. #9FD8FF deep water, #C8F07A swamp, #FFB070 lava)")),
    "confetti_burst_4x4": dict(
        src="blender:confetti_burst", grid=4, loop=False, emissive=False,
        grade=dict(exposure=1.0, alpha_gain=1.0, alpha_gamma=1.0), fill=0.94, tail=0.25,
        suggested=dict(lifetime=[1.2, 1.6], size=[8, 10], speed=[0, 1], lightEmission=0.1, color="#FFFFFF",
                       flipbookMode="OneShot", notes="finish / key / token moments; already coloured")),
    "magic_swirl_8x8": dict(
        src="proc:magic_swirl_8x8", grid=8, loop=True, emissive=True, fill=None,
        suggested=dict(lifetime=[2, 2], size=[6, 6], speed=[0, 0], lightEmission=0.6, color="#FFFFFF",
                       flipbookMode="Loop", flipbookFramerate=30, notes="portals, boss auras, key glow. Authored violet/magenta/cyan: Color multiplies, so keep white or tint toward the same hues (a green/orange tint goes muddy)")),
    "electric_arc_4x4": dict(
        src="proc:electric_arc_4x4", grid=4, loop=True, emissive=True, fill=None,
        suggested=dict(lifetime=[0.4, 0.6], size=[3, 5], speed=[0, 0], lightEmission=0.6, color="#FFFFFF",
                       flipbookMode="Loop", flipbookFramerate=24, rotation=[0, 360],
                       notes="lightning hazard, coils, shock items")),
    "lightning_bolt_2x2": dict(
        src="proc:lightning_bolt_2x2", grid=2, loop=False, emissive=True, fill=None, variants=True,
        suggested=dict(lifetime=[0.15, 0.25], size=[12, 18], speed=[0, 0], lightEmission=0.7, color="#FFFFFF",
                       flipbookMode="Random", notes="4 bolt variants: FlipbookMode Random picks one per particle")),
    "shockwave_8x8": dict(
        src="proc:shockwave_8x8", grid=8, loop=False, emissive=True, fill=None,
        suggested=dict(lifetime=[0.45, 0.6], size=[10, 10], speed=[0, 0], lightEmission=0.7, color="#FFFFFF",
                       flipbookMode="OneShot", orientation="VelocityPerpendicular or FacingCamera",
                       notes="the ring grows inside the sheet; keep Size constant")),
    "sparkle_star_4x4": dict(
        src="proc:sparkle_star_4x4", grid=4, loop=True, emissive=True, fill=None,
        suggested=dict(lifetime=[0.6, 1.0], size=[1.5, 3], speed=[0, 0], lightEmission=0.8, color="#FFFFFF",
                       flipbookMode="Loop", flipbookFramerate=24, notes="token/coin glints, key twinkle")),
    "speed_streak": dict(
        src="proc:speed_streak", grid=1, loop=False, emissive=True, fill=None, size=(256, 1024),
        suggested=dict(lifetime=[0.15, 0.3], size=[0.3, 0.3], speed=[0, 0], lightEmission=1, color="#FFFFFF",
                       flipbookMode="None", squash="particles are square quads, so the 1:4 texture is squeezed to 1:1: use Orientation "
                       "VelocityParallel with Squash ~2-3 to stretch it along velocity. As a Trail/Beam texture rotate it "
                       "90 degrees first (their texture runs lengthwise along X); check in Studio")),
}


def crossfade_loop(prem, N, X):
    """prem has N + X frames; returns N frames where the first X blend in from the tail (seamless wrap)."""
    out = prem[:N].astype(np.float32).copy()
    for i in range(X):
        w = (i + 0.5) / X
        w = w * w * (3 - 2 * w)
        out[i] = prem[i] * w + prem[N + i] * (1 - w)
    return out


def tail_fade(frames, frac):
    """One-shot: alpha eases to exactly 0 over the last frac of the frames."""
    n = len(frames)
    k = max(1, int(round(n * frac)))
    out = frames.copy()
    for i in range(n - k, n):
        t = (i - (n - k) + 1) / k
        # smoothstep ease-out: no sudden alpha drop on the first tail frame (the old (1-t)^1.5 cut 28% in one frame)
        out[i, ..., 3] *= 1 - t * t * (3 - 2 * t)
    out[-1, ..., 3] = 0
    return out


def retime(raw, end_thresh=0.02):
    """Stretch a one-shot render whose content ends early over the full frame count, so no sheet cells are spent on
    empty or near-invisible frames. Linear blend of neighbouring (premultiplied) frames: at a 64-frame ~1 s one-shot
    the sub-frame blend reads as motion, not ghosting."""
    a = raw[..., 3].mean((1, 2))
    live = np.nonzero(a > end_thresh * a.max())[0]
    last = int(live[-1]) + 1 if len(live) else len(raw) - 1
    if last >= len(raw) - 1:
        return raw
    pos = np.linspace(0, last, len(raw))
    i0 = np.floor(pos).astype(int)
    i1 = np.minimum(i0 + 1, len(raw) - 1)
    f = (pos - i0)[:, None, None, None].astype(np.float32)
    return raw[i0] * (1 - f) + raw[i1] * f


def straight_to_prem(f):
    p = f.copy()
    p[..., :3] *= p[..., 3:4]
    return p


def prem_to_straight(p):
    a = p[..., 3:4]
    s = p.copy()
    s[..., :3] = np.where(a > 1e-4, p[..., :3] / np.maximum(a, 1e-4), 0)
    return np.clip(s, 0, 1)


def build(name):
    r = RECIPES[name]
    kind, key = r["src"].split(":")
    grid = r["grid"]
    cell = 1024 // grid
    if kind == "blender":
        raw = np.load(fb.RAW / key / "frames.npz")["rgba"].astype(np.float32)
        if r.get("retime"):
            raw = retime(raw)
        if r.get("loop"):
            X = r.get("xfade", 16)
            raw = crossfade_loop(raw, len(raw) - X, X)
        raw = fb.fit_frames(raw, fill=r.get("fill", 0.9), center=r.get("center", "bbox"))
        raw = fb.resize(raw, cell)
        raw[..., 3] = np.clip(raw[..., 3], 0, 1)
        raw[..., :3] = np.clip(raw[..., :3], 0, None)
        frames = fb.unpremult(raw, **r.get("grade", {}))
    else:
        frames = proc.GENERATORS[key]()
        if name != "speed_streak" and frames.shape[1] != cell:
            frames = prem_to_straight(fb.resize(straight_to_prem(frames), cell))
    if not r.get("loop") and r.get("tail"):
        frames = tail_fade(frames, r["tail"])
    frames = fb.edge_fade(frames, margin=0.05 if name != "speed_streak" else 0.02)
    frames = np.clip(frames, 0, 1)
    frames = fb.bleed(frames)
    return frames


def pack_all(names):
    fb.DEST.mkdir(parents=True, exist_ok=True)
    man_path = fb.DEST / "manifest.json"
    manifest = json.loads(man_path.read_text()) if man_path.exists() else {}
    entries = []
    for name in (names or list(RECIPES)):
        r = RECIPES[name]
        kind, key = r["src"].split(":")
        if kind == "blender" and not (fb.RAW / key / "frames.npz").exists():
            print("SKIP (no render)", name)
            continue
        frames = build(name)
        grid = r["grid"]
        if name == "speed_streak":
            sheet = frames[0]
        else:
            sheet = fb.pack(frames, grid)
        fb.to_img(sheet).save(fb.DEST / f"{name}.png", optimize=True)
        le = r["suggested"]["lightEmission"]
        life = float(np.mean(r["suggested"]["lifetime"]))
        fps = min(30, r["suggested"].get("flipbookFramerate") or max(8, len(frames) / life))  # GIF delays < 20 ms get clamped by viewers
        if name == "lightning_bolt_2x2":
            fps = 4
        if name == "speed_streak":
            gif_frames = np.stack([frames[0][::4, ::4]] * 1)
            gif_frames = np.pad(gif_frames, ((0, 0), (0, 0), (96, 96), (0, 0)))
            fb.preview_gif(name, fb.resize(gif_frames, 192), fb.DEST / f"{name}.gif", le, fps=fps)
        else:
            fb.preview_gif(name, frames, fb.DEST / f"{name}.gif", le, fps=fps)
        manifest[name] = {
            "file": f"assets/vfx/flip_v2/{name}.png",
            "size": list(fb.to_img(sheet).size),
            "grid": {1: "None", 2: "Grid2x2", 4: "Grid4x4", 8: "Grid8x8"}[grid],
            "frames": int(len(frames)) if grid > 1 else 1,
            "loop": bool(r.get("loop")),
            "emissive": bool(r.get("emissive")),
            "source": r["src"],
            "suggested": r["suggested"],
        }
        entries.append((name, frames if name != "speed_streak" else np.pad(frames[:, ::4, ::4], ((0, 0), (0, 0), (96, 96), (0, 0))), le, grid))
        print("packed", name, sheet.shape, "frames", len(frames))
    man_path.write_text(json.dumps(dict(sorted(manifest.items())), indent=1))
    if entries:
        allnames = [n for n in RECIPES if (fb.DEST / f"{n}.png").exists()]
        if names:  # rebuild the full contact sheet from every packed sheet
            entries = []
            for n in allnames:
                entries.append(sheet_entry(n))
        fb.contact_sheet(entries, fb.DEST / "contact_sheet.png")


def sheet_entry(name):
    """Re-read a packed sheet into frames (for the contact sheet)."""
    from PIL import Image
    r = RECIPES[name]
    img = np.asarray(Image.open(fb.DEST / f"{name}.png").convert("RGBA"), np.float32) / 255
    g = r["grid"]
    if g == 1:
        f = img[None, ::4, ::4]
        f = np.pad(f, ((0, 0), (0, 0), (96, 96), (0, 0)))
        return name, f, r["suggested"]["lightEmission"], g
    n = img.shape[0] // g
    frames = np.stack([img[i // g * n:(i // g + 1) * n, i % g * n:(i % g + 1) * n] for i in range(g * g)])
    return name, frames, r["suggested"]["lightEmission"], g


def check_all():
    """QA of the packed sheets against the Roblox flipbook rules. Returns True when every sheet passes."""
    from PIL import Image
    ok_all = True
    for name, r in RECIPES.items():
        path = fb.DEST / f"{name}.png"
        if not path.exists():
            print(f"{name:20s} MISSING")
            ok_all = False
            continue
        im = Image.open(path)
        a = np.asarray(im.convert("RGBA"), np.float32) / 255
        g = r["grid"]
        probs = []
        if im.mode != "RGBA":
            probs.append(f"mode {im.mode}")
        if g == 1:
            if im.size != (256, 1024):
                probs.append(f"size {im.size}")
            border = max(a[0, :, 3].max(), a[-1, :, 3].max(), a[:, 0, 3].max(), a[:, -1, 3].max())
            info = f"border alpha {border:.3f}"
            if border > 2 / 255:
                probs.append("touches border")
        else:
            if im.size != (1024, 1024):
                probs.append(f"size {im.size}")
            n = 1024 // g
            cells = [a[i // g * n:(i // g + 1) * n, i % g * n:(i % g + 1) * n] for i in range(g * g)]
            border = max(max(c[0, :, 3].max(), c[-1, :, 3].max(), c[:, 0, 3].max(), c[:, -1, 3].max()) for c in cells)
            cover = [float((c[..., 3] > 0.05).mean()) for c in cells]
            info = f"border alpha {border:.3f}  coverage first/max/last {cover[0]:.2f}/{max(cover):.2f}/{cover[-1]:.2f}"
            if border > 2 / 255:
                probs.append("touches a cell border")
            if r.get("loop"):
                prem = [c[..., :3] * c[..., 3:] for c in cells]
                steps = [np.abs(prem[i + 1] - prem[i]).mean() for i in range(len(prem) - 1)]
                seam = np.abs(prem[0] - prem[-1]).mean()
                ratio = seam / (np.mean(steps) + 1e-9)
                info += f"  loop seam/step {ratio:.2f}"
                if ratio > 1.6:
                    probs.append("loop seam jumps")
            elif not r.get("variants"):
                if cells[-1][..., 3].max() > 2 / 255:
                    probs.append("one-shot does not end transparent")
                if cover[0] > 0.6 * max(cover) and max(cover) > 0:
                    probs.append("one-shot does not start small")
        status = "OK " if not probs else "FAIL " + "; ".join(probs)
        ok_all &= not probs
        print(f"{name:20s} {status:6s} {info}")
    return ok_all
