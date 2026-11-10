#!/usr/bin/env python3
"""Bake a boss's authored Blender clips into a Luau data module for the client clip player (BossAnimator).

Usage:
    python3 tools/bake_boss_clips.py <key> [--glb PATH] [--meta PATH] [--rest PATH] [--out PATH] [--module NAME]
                                     [--root DIR]

--root DIR: asset folder holding <key>/anim/out (default assets/models/bosses; e.g. assets/models/vehicles_v4).

Reads assets/models/bosses/<key>/anim/out/anim.glb (skinned armature + one glTF animation per clip, sampled every frame)
and clips_meta.json from the same folder, and writes src/shared/bossclips/<Module>.luau:

    { fps, boss, bones = {joint names in skin order}, clips = { [name] = { frames, loop, speedRef?, mask?, channels } } }

channels[i] belongs to bones[i] and holds, per frame, the delta D = inverse(restTRS_local) * sampledTRS_local in glTF
node-local space: q = flat {x,y,z,w, ...} (4 per frame), t = flat {x,y,z, ...} (3 per frame, glTF units; omitted when the
bone never translates in that clip). A channel that is constant over the clip stores a single frame. The player sets
Bone.Transform = CFrame.new(D.t * BossScale) * rotation(D.q) (Studio-verified import convention: a non-root Bone's
local CFrame equals the glTF node's local TRS, and Transform applies in the bone's own frame).

Frame semantics: frame i is sampled at t0 + i / fps (t0 = the animation's first key). `frames` (clips_meta.json, else
inferred) is the number of distinct frames: a loop clip wraps from frame frames-1 back to frame 0, so an exporter's
closing duplicate frame (frame N == frame 0) is not stored; a one-shot holds its last frame.

Validation (exit 1 on failure): rest-pose delta is identity for every joint; every meta clip exists in the GLB; masks
name real bones; quaternions unit and hemisphere-continuous after baking; anim.glb rest matches the uploaded rest mesh
(rigged.glb next to it, or --rest) joint for joint; each module under 200 KB. Warnings: Wheel*/Prop bones keyed (the
client spins them procedurally), animated scale (Roblox bones cannot scale), visible loop seams.
Pure Python (stdlib only).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_BYTES = 200 * 1024
IDENTITY_Q = (0.0, 0.0, 0.0, 1.0)

COMPONENT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NORM_DIV = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}
TYPE_N = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class BakeError(Exception):
    pass


# ----------------------------------------------------------------------------------------------------------- quaternions
def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qnorm(q):
    n = math.sqrt(sum(c * c for c in q))
    if n < 1e-12:
        return IDENTITY_Q
    return tuple(c / n for c in q)


def qdot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]


def qrot(q, v):
    p = qmul(qmul(q, (v[0], v[1], v[2], 0.0)), qconj(q))
    return (p[0], p[1], p[2])


def qslerp(a, b, t):
    d = qdot(a, b)
    if d < 0:
        b = tuple(-c for c in b)
        d = -d
    if d > 0.9995:
        return qnorm(tuple(a[i] + (b[i] - a[i]) * t for i in range(4)))
    th = math.acos(min(1.0, d))
    s = math.sin(th)
    wa = math.sin((1 - t) * th) / s
    wb = math.sin(t * th) / s
    return qnorm(tuple(a[i] * wa + b[i] * wb for i in range(4)))


def qangle(a, b):
    """Rotation angle (radians) between two unit quaternions."""
    return 2.0 * math.acos(min(1.0, abs(qdot(a, b))))


def mat3_to_quat(m):
    """m[r][c] row-major rotation matrix -> (x,y,z,w)."""
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        return qnorm(((m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s, 0.25 * s))
    if m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        return qnorm((0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s, (m[2][1] - m[1][2]) / s))
    if m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        return qnorm(((m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s, (m[0][2] - m[2][0]) / s))
    s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
    return qnorm(((m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s, (m[1][0] - m[0][1]) / s))


def delta(rest_t, rest_q, t, q):
    """D = inverse(rest) * pose for TRS without scale: rotation rest_q^-1 * q, translation rest_q^-1 * (t - rest_t)."""
    inv = qconj(rest_q)
    dq = qnorm(qmul(inv, q))
    dt = qrot(inv, (t[0] - rest_t[0], t[1] - rest_t[1], t[2] - rest_t[2]))
    return dt, dq


# ------------------------------------------------------------------------------------------------------------------ GLB
class Glb:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            data = f.read()
        self.sha1 = hashlib.sha1(data).hexdigest()
        if len(data) < 20 or data[:4] != b"glTF":
            raise BakeError(f"{path}: not a GLB file")
        version, length = struct.unpack_from("<II", data, 4)
        if version != 2:
            raise BakeError(f"{path}: glTF version {version}, need 2")
        off = 12
        self.json = None
        self.bin = b""
        while off + 8 <= min(length, len(data)):
            clen, ctype = struct.unpack_from("<II", data, off)
            chunk = data[off + 8 : off + 8 + clen]
            if ctype == 0x4E4F534A:
                self.json = json.loads(chunk.decode("utf-8"))
            elif ctype == 0x004E4942 and not self.bin:
                self.bin = chunk
            off += 8 + clen
        if self.json is None:
            raise BakeError(f"{path}: no JSON chunk")
        self._cache = {}

    def accessor(self, index):
        """Accessor -> list of tuples (one per element), normalized ints converted to floats."""
        if index in self._cache:
            return self._cache[index]
        acc = self.json["accessors"][index]
        n = TYPE_N[acc["type"]]
        fmt, size = COMPONENT[acc["componentType"]]
        count = acc["count"]
        out = [tuple([0.0] * n) for _ in range(count)]
        if "bufferView" in acc:
            bv = self.json["bufferViews"][acc["bufferView"]]
            if bv.get("buffer", 0) != 0:
                raise BakeError("only the GLB BIN buffer is supported")
            base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            stride = bv.get("byteStride") or n * size
            unpack = struct.Struct("<" + fmt * n).unpack_from
            out = [unpack(self.bin, base + i * stride) for i in range(count)]
        sparse = acc.get("sparse")
        if sparse:
            idx_view = self.json["bufferViews"][sparse["indices"]["bufferView"]]
            ifmt, isize = COMPONENT[sparse["indices"]["componentType"]]
            ibase = idx_view.get("byteOffset", 0) + sparse["indices"].get("byteOffset", 0)
            val_view = self.json["bufferViews"][sparse["values"]["bufferView"]]
            vbase = val_view.get("byteOffset", 0) + sparse["values"].get("byteOffset", 0)
            vun = struct.Struct("<" + fmt * n).unpack_from
            for k in range(sparse["count"]):
                (i,) = struct.unpack_from("<" + ifmt, self.bin, ibase + k * isize)
                out[i] = vun(self.bin, vbase + k * n * size)
        if acc.get("normalized") and acc["componentType"] in NORM_DIV:
            div = NORM_DIV[acc["componentType"]]
            out = [tuple(max(c / div, -1.0) for c in v) for v in out]
        else:
            out = [tuple(float(c) for c in v) for v in out]
        self._cache[index] = out
        return out


def node_rest(node):
    """(t, q, s) of a node in its parent's space."""
    if "matrix" in node:
        m = node["matrix"]  # column-major
        cols = [m[0:3], m[4:7], m[8:11]]
        s = [math.sqrt(sum(c * c for c in col)) or 1.0 for col in cols]
        rot = [[cols[c][r] / s[c] for c in range(3)] for r in range(3)]
        return (m[12], m[13], m[14]), mat3_to_quat(rot), tuple(s)
    t = tuple(node.get("translation", (0.0, 0.0, 0.0)))
    q = qnorm(tuple(node.get("rotation", IDENTITY_Q)))
    s = tuple(node.get("scale", (1.0, 1.0, 1.0)))
    return t, q, s


def skin_joints(glb):
    skins = glb.json.get("skins") or []
    if not skins:
        raise BakeError(f"{glb.path}: no skin")
    joints = skins[0]["joints"]
    for other in skins[1:]:
        if other["joints"] != joints:
            raise BakeError(f"{glb.path}: several skins with different joints; the boss rig must have one armature")
    nodes = glb.json["nodes"]
    names = [nodes[j].get("name") or f"joint{j}" for j in joints]
    if len(set(names)) != len(names):
        raise BakeError(f"{glb.path}: duplicate joint names {names}")
    return joints, names


# ------------------------------------------------------------------------------------------------------------- sampling
class Channel:
    def __init__(self, glb, sampler, path):
        self.path = path
        self.interp = sampler.get("interpolation", "LINEAR")
        self.times = [v[0] for v in glb.accessor(sampler["input"])]
        out = glb.accessor(sampler["output"])
        if self.interp == "CUBICSPLINE":
            # triplets (in-tangent, value, out-tangent) per key
            self.inT = out[0::3]
            self.values = out[1::3]
            self.outT = out[2::3]
        else:
            self.values = out
        if len(self.values) != len(self.times):
            raise BakeError(f"sampler key count mismatch ({len(self.times)} times, {len(self.values)} values)")
        if self.interp not in ("LINEAR", "STEP", "CUBICSPLINE"):
            raise BakeError(f"unsupported interpolation {self.interp}")

    def sample(self, t):
        ts = self.times
        if t <= ts[0] or len(ts) == 1:
            return self.values[0]
        if t >= ts[-1]:
            return self.values[-1]
        lo, hi = 0, len(ts) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if ts[mid] <= t:
                lo = mid
            else:
                hi = mid
        a, b = self.values[lo], self.values[hi]
        span = ts[hi] - ts[lo]
        u = (t - ts[lo]) / span if span > 0 else 0.0
        if self.interp == "STEP":
            return a
        if self.interp == "CUBICSPLINE":
            u2, u3 = u * u, u * u * u
            h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
            m0, m1 = self.outT[lo], self.inT[hi]
            v = tuple(h00 * a[i] + h10 * span * m0[i] + h01 * b[i] + h11 * span * m1[i] for i in range(len(a)))
            return qnorm(v) if self.path == "rotation" else v
        if self.path == "rotation":
            return qslerp(qnorm(a), qnorm(b), u)
        return tuple(a[i] + (b[i] - a[i]) * u for i in range(len(a)))


def load_animations(glb):
    anims = {}
    for ai, anim in enumerate(glb.json.get("animations") or []):
        name = anim.get("name") or f"anim{ai}"
        chans = {}
        for ch in anim["channels"]:
            target = ch["target"]
            if "node" not in target or target["path"] not in ("translation", "rotation", "scale"):
                continue
            sampler = anim["samplers"][ch["sampler"]]
            chans[(target["node"], target["path"])] = Channel(glb, sampler, target["path"])
        if name in anims:
            raise BakeError(f"duplicate animation name {name}")
        anims[name] = chans
    return anims


def fmt_num(v, places):
    """Shortest fixed-point text: trailing zeros and the leading 0 of a fraction dropped (Luau reads .5 and -.5)."""
    s = f"{v:.{places}f}".rstrip("0").rstrip(".")
    if s in ("-0", "", "-"):
        return "0"
    if s.startswith("0."):
        s = s[1:]
    elif s.startswith("-0."):
        s = "-" + s[2:]
    return s


def quantize(vals, places):
    return [float(fmt_num(v, places)) for v in vals]


# --------------------------------------------------------------------------------------------------------------- baking
def bake(glb, meta, rest_glb=None, log=print):
    """Returns (module dict, warnings). module['clips'][name]['channels'][i] = {'q': [...], 't': [...]?} unquantized."""
    warnings = []
    joints, names = skin_joints(glb)
    nodes = glb.json["nodes"]
    rest = [node_rest(nodes[j]) for j in joints]
    fps = float(meta.get("fps", 30))
    if fps <= 0:
        raise BakeError("fps must be > 0")

    # 1. rest pose delta is identity
    for name, (t, q, _s) in zip(names, rest):
        dt, dq = delta(t, q, t, q)
        if qangle(dq, IDENTITY_Q) > 1e-6 or max(abs(c) for c in dt) > 1e-6:
            raise BakeError(f"rest delta of {name} is not identity: {dt} {dq}")

    # 2. the animation's rest equals the uploaded rest mesh
    if rest_glb is not None:
        rj, rnames = skin_joints(rest_glb)
        if rnames != names:
            raise BakeError(f"joint order differs from the rest mesh: {names} vs {rnames}")
        for name, j, (t, q, _s) in zip(names, rj, rest):
            t2, q2, _ = node_rest(rest_glb.json["nodes"][j])
            if qangle(q, q2) > math.radians(0.05) or max(abs(t[i] - t2[i]) for i in range(3)) > 1e-4:
                raise BakeError(f"rest of {name} differs between anim.glb and the rest mesh")

    anims = load_animations(glb)
    meta_clips = meta.get("clips") or {}
    for cname in meta_clips:
        if cname not in anims:
            raise BakeError(f"clip {cname} is in clips_meta.json but not in {glb.path} (has {sorted(anims)})")
    for aname in anims:
        if aname not in meta_clips:
            warnings.append(f"animation {aname} has no clips_meta entry: baked as a one-shot")

    clips = {}
    for cname, chans in anims.items():
        cm = meta_clips.get(cname, {})
        loop = bool(cm.get("loop", False))
        times = [t for ch in chans.values() for t in (ch.times[0], ch.times[-1])]
        t0 = min(times) if times else 0.0
        t1 = max(times) if times else 0.0
        span_frames = int(round((t1 - t0) * fps))
        frames = cm.get("frames")
        if frames is None:
            frames = span_frames if (loop and span_frames > 0) else span_frames + 1
        frames = int(frames)
        if frames < 1:
            raise BakeError(f"clip {cname}: frames must be >= 1")
        if frames > span_frames + 1:
            warnings.append(f"clip {cname}: meta frames={frames} but keys span {span_frames + 1} frames (held at the end)")
        mask = cm.get("mask")
        if mask is not None:
            bad = [m for m in mask if m not in names]
            if bad:
                raise BakeError(f"clip {cname}: mask names unknown bones {bad}")
        speed_ref = cm.get("speedRef")
        if speed_ref is not None and not (isinstance(speed_ref, (int, float)) and speed_ref > 0):
            raise BakeError(f"clip {cname}: speedRef must be a positive number or null")

        channels = []
        for bi, (j, name) in enumerate(zip(joints, names)):
            rt, rq, rs = rest[bi]
            ct = chans.get((j, "translation"))
            cr = chans.get((j, "rotation"))
            cs = chans.get((j, "scale"))
            qs, ts = [], []
            prev = None
            # one extra sample past the end for loops, for the seam check only
            for f in range(frames + (1 if loop else 0)):
                tt = t0 + f / fps
                pt = ct.sample(tt) if ct else rt
                pq = qnorm(cr.sample(tt)) if cr else rq
                if cs and f < frames:
                    ps = cs.sample(tt)
                    if max(abs(ps[i] - rs[i]) for i in range(3)) > 1e-3:
                        warnings.append(f"clip {cname}: bone {name} scales (ignored: Roblox bones cannot scale)")
                        cs = None
                dt, dq = delta(rt, rq, pt, pq)
                if prev is None:
                    if dq[3] < 0:
                        dq = tuple(-c for c in dq)
                elif qdot(prev, dq) < 0:
                    dq = tuple(-c for c in dq)
                prev = dq
                qs.append(dq)
                ts.append(dt)
            seam_q = qs.pop() if loop else None
            if loop:
                ts.pop()
            if loop and frames > 2 and seam_q is not None and span_frames >= frames:
                step = max(qangle(qs[i], qs[i + 1]) for i in range(frames - 1))
                seam = qangle(qs[-1], qs[0])
                closing = qangle(seam_q, qs[0])
                if closing > math.radians(1.0):
                    warnings.append(f"clip {cname}: bone {name} loop does not close (frame {frames} is "
                                    f"{math.degrees(closing):.1f} deg from frame 0)")
                elif seam > max(2.5 * step, math.radians(2.0)):
                    warnings.append(f"clip {cname}: bone {name} loop seam jump {math.degrees(seam):.1f} deg")
            moves_t = any(max(abs(c) for c in v) > 1e-5 for v in ts)
            keyed = any(qangle(q, IDENTITY_Q) > math.radians(0.01) for q in qs) or moves_t
            if keyed and (name.startswith("Wheel") or name == "Prop"):
                warnings.append(f"clip {cname}: {name} is keyed; the client spins it procedurally (leave it at rest)")
            channels.append({"q": qs, "t": ts if moves_t else None})
        blend = cm.get("blend")
        if blend not in (None, "additive"):
            raise BakeError(f"clip {cname}: blend must be null or \"additive\"")
        if blend == "additive" and not mask:
            raise BakeError(f"clip {cname}: an additive clip needs a mask")
        clips[cname] = {"frames": frames, "loop": loop, "speedRef": speed_ref, "mask": mask, "blend": blend,
                        "channels": channels}

    module = {"fps": fps, "bones": names, "clips": clips, "boss": meta.get("boss"), "module": meta.get("module")}
    return module, warnings


def _lua_str(s):
    return json.dumps(s)


def _compact(rows, places):
    """Quantized rows; a channel constant over the clip collapses to one row."""
    q = [tuple(fmt_num(c, places) for c in r) for r in rows]
    if all(r == q[0] for r in q):
        return [q[0]]
    return q


def render_luau(module, src_desc, qplaces=5, tplaces=4):
    lines = [
        "--!strict",
        f"-- AUTO-GENERATED by tools/bake_boss_clips.py from {src_desc}. Do not edit; re-bake instead.",
        f"-- {module.get('module') or 'Boss'} boss clips for the client clip player (BossAnimator, ClipMath). channels[i] belongs to",
        "-- bones[i]: per frame the delta D = inverse(rest) * pose in glTF node-local space, q = flat {x,y,z,w,...},",
        "-- t = flat {x,y,z,...} in glTF units (scale by BossScale; omitted when the bone never translates). One row = constant.",
        "type Channel = { q: { number }, t: { number }? }",
        "type Clip = { frames: number, loop: boolean, speedRef: number?, mask: { string }?, blend: string?, channels: { Channel } }",
        "local clips: { fps: number, boss: string?, bones: { string }, clips: { [string]: Clip } } = {",
        f"\tfps = {fmt_num(module['fps'], 3)},",
    ]
    if module.get("boss"):
        lines.append(f"\tboss = {_lua_str(module['boss'])},")
    lines.append("\tbones = { " + ", ".join(_lua_str(n) for n in module["bones"]) + " },")
    lines.append("\tclips = {")
    for cname in sorted(module["clips"]):
        c = module["clips"][cname]
        lines.append(f"\t\t[{_lua_str(cname)}] = {{")
        lines.append(f"\t\t\tframes = {c['frames']},")
        lines.append(f"\t\t\tloop = {'true' if c['loop'] else 'false'},")
        if c["speedRef"] is not None:
            lines.append(f"\t\t\tspeedRef = {fmt_num(float(c['speedRef']), 3)},")
        if c["mask"] is not None:
            lines.append("\t\t\tmask = { " + ", ".join(_lua_str(m) for m in c["mask"]) + " },")
        if c.get("blend"):
            lines.append("\t\t\tblend = " + _lua_str(c["blend"]) + ",")
        lines.append("\t\t\tchannels = {")
        for bi, ch in enumerate(c["channels"]):
            qrows = _compact(ch["q"], qplaces)
            parts = ["q = { " + ", ".join(v for r in qrows for v in r) + " }"]
            if ch["t"] is not None:
                trows = _compact(ch["t"], tplaces)
                parts.append("t = { " + ", ".join(v for r in trows for v in r) + " }")
            lines.append(f"\t\t\t\t{{ {', '.join(parts)} }}, -- {module['bones'][bi]}")
        lines.append("\t\t\t},")
        lines.append("\t\t},")
    lines.append("\t},")
    lines.append("}")
    lines.append("return clips")
    return "\n".join(lines) + "\n"


def verify_rendered(module, qplaces):
    """Re-check baked quaternions after quantization: unit length and consecutive frames in one hemisphere."""
    for cname, c in module["clips"].items():
        for bi, ch in enumerate(c["channels"]):
            prev = None
            for q in ch["q"]:
                qq = [float(fmt_num(x, qplaces)) for x in q]
                n = math.sqrt(sum(x * x for x in qq))
                if abs(n - 1) > 5 * 10 ** (-qplaces + 1):
                    raise BakeError(f"clip {cname} bone {module['bones'][bi]}: quaternion norm {n}")
                if prev is not None and qdot(prev, qq) < 0:
                    raise BakeError(f"clip {cname} bone {module['bones'][bi]}: hemisphere flip")
                prev = qq


def protect_editable_source(out):
    """Never overwrite an authoritative hand-maintained release clip with a rebake."""
    if os.path.isfile(out):
        with open(out) as f:
            if "AUTHORITATIVE EDITABLE RELEASE SOURCE" in f.read():
                raise BakeError("output is authoritative editable source; use --out with a separate comparison path")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("key", help="boss key, e.g. dino_boss")
    ap.add_argument("--glb", help="anim.glb (default assets/models/bosses/<key>/anim/out/anim.glb)")
    ap.add_argument("--meta", help="clips_meta.json (default next to the GLB)")
    ap.add_argument("--rest", help="rest mesh GLB to compare (default rigged.glb next to the GLB, if present)")
    ap.add_argument("--out", help="output .luau (default src/shared/bossclips/<module>.luau)")
    ap.add_argument("--module", help="module name (default clips_meta.json 'module')")
    ap.add_argument("--root", default="assets/models/bosses", help="asset folder that holds <key>/ (repo-relative)")
    args = ap.parse_args(argv)

    outdir = os.path.join(REPO, *args.root.strip("/").split("/"), args.key, "anim", "out")
    glb_path = args.glb or os.path.join(outdir, "anim.glb")
    meta_path = args.meta or os.path.join(os.path.dirname(glb_path), "clips_meta.json")
    try:
        glb = Glb(glb_path)
        with open(meta_path) as f:
            meta = json.load(f)
        if meta.get("boss") and meta["boss"] != args.key:
            raise BakeError(f"clips_meta.json is for {meta['boss']}, not {args.key}")
        meta.setdefault("boss", args.key)
        rest_path = args.rest or os.path.join(os.path.dirname(glb_path), "rigged.glb")
        rest_glb = Glb(rest_path) if os.path.isfile(rest_path) else None
        if rest_glb is None:
            print(f"note: no rest mesh at {rest_path}; skipped the rest comparison")
        module, warnings = bake(glb, meta, rest_glb)
        name = args.module or meta.get("module")
        if not name:
            raise BakeError("no module name (clips_meta.json 'module' or --module)")
        module["module"] = name
        rel = os.path.relpath(glb_path, REPO)
        src_desc = f"{rel} (sha1 {glb.sha1[:12]})"
        text = None
        for qplaces, tplaces in ((5, 4), (4, 4), (4, 3)):
            text = render_luau(module, src_desc, qplaces, tplaces)
            if len(text.encode()) < MAX_BYTES:
                break
        verify_rendered(module, qplaces)
        size = len(text.encode())
        if size >= MAX_BYTES:
            raise BakeError(f"module is {size} bytes even at {qplaces} decimals (limit {MAX_BYTES}); shorten clips")
        out = args.out or os.path.join(REPO, "src", "shared", "bossclips", name + ".luau")
        protect_editable_source(out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w") as f:
            f.write(text)
    except (BakeError, OSError, KeyError, ValueError) as e:
        print(f"BAKE_FAILED {args.key}: {e}", file=sys.stderr)
        return 1
    for w in warnings:
        print("warning: " + w)
    summary = ", ".join(f"{n}({c['frames']}{'L' if c['loop'] else ''})" for n, c in sorted(module["clips"].items()))
    print(f"baked {args.key} -> {os.path.relpath(out, REPO)}: {len(module['bones'])} bones, clips {summary}, "
          f"{size} bytes ({size / 1024:.1f} KB, q {qplaces} dp)")
    rec = meta.get("recommend")
    if rec:
        print("recommend (BossConfig, applied by the integrator): " + json.dumps(rec))
    print("BAKE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
