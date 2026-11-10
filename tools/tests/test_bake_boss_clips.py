"""Unit tests for tools/bake_boss_clips.py on a tiny synthetic two-joint skinned GLB.

Run: python3 -m unittest tools.tests.test_bake_boss_clips   (from the repo root)
  or python3 -m unittest discover -s tools/tests -p 'test_bake_boss_clips.py'
When Lune is on PATH (~/.local/bin), the baked module is also loaded through src/shared/bossclips/ClipMath.luau
(validate + sample) so the Python and Luau sides agree on the file format.
"""
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))

import bake_boss_clips as bake  # noqa: E402


def axis_angle(axis, deg):
    h = math.radians(deg) / 2
    s = math.sin(h)
    return [axis[0] * s, axis[1] * s, axis[2] * s, math.cos(h)]


ROOT_REST_T = [0.0, 1.0, 0.0]
CHILD_REST_T = [0.0, 0.5, 0.0]
CHILD_REST_Q = axis_angle((1, 0, 0), 90)  # child turned 90 deg about X at rest


class GlbBuilder:
    def __init__(self):
        self.bin = bytearray()
        self.views = []
        self.accessors = []

    def add(self, values, type_, comp=5126):
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        flat = [c for v in values for c in (v if isinstance(v, (list, tuple)) else [v])]
        fmt = {5126: "f", 5123: "H"}[comp]
        self.bin += struct.pack("<" + fmt * len(flat), *flat)
        self.views.append({"buffer": 0, "byteOffset": off, "byteLength": len(self.bin) - off})
        acc = {"bufferView": len(self.views) - 1, "componentType": comp, "count": len(values), "type": type_}
        if type_ == "SCALAR" and comp == 5126:
            acc["min"] = [min(values)]
            acc["max"] = [max(values)]
        self.accessors.append(acc)
        return len(self.accessors) - 1


def make_glb(path, animations=True, child_rest_q=None, extra_anims=None):
    """Two joints Root -> Child, one triangle skinned to them; animations 'turn' (LINEAR) and 'blink' (STEP)."""
    b = GlbBuilder()
    pos = b.add([(0, 0, 0), (1, 0, 0), (0, 1, 0)], "VEC3")
    joints = b.add([(0, 0, 0, 0), (1, 0, 0, 0), (1, 0, 0, 0)], "VEC4", comp=5123)
    weights = b.add([(1, 0, 0, 0)] * 3, "VEC4")
    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    ibm = b.add([ident, ident], "MAT4")
    nodes = [
        {"name": "Root", "translation": ROOT_REST_T, "children": [1]},
        {"name": "Child", "translation": CHILD_REST_T, "rotation": child_rest_q or CHILD_REST_Q},
        {"name": "Mesh", "mesh": 0, "skin": 0},
        {"name": "Rig", "children": [0, 2]},
    ]
    anims = []
    if animations:
        # turn: 31 frames at 30 fps; Root yaws 0 -> 90 deg about Y, Child slides from rest to rest + (0, 0, 2) in parent space.
        tin = b.add([0.0, 1.0], "SCALAR")
        rot = b.add([(0, 0, 0, 1), tuple(axis_angle((0, 1, 0), 90))], "VEC4")
        tra = b.add([tuple(CHILD_REST_T), (0.0, 0.5, 2.0)], "VEC3")
        anims.append({
            "name": "turn",
            "samplers": [{"input": tin, "output": rot, "interpolation": "LINEAR"},
                         {"input": tin, "output": tra, "interpolation": "LINEAR"}],
            "channels": [{"sampler": 0, "target": {"node": 0, "path": "rotation"}},
                         {"sampler": 1, "target": {"node": 1, "path": "translation"}}],
        })
        # blink: STEP keys on Child: rest until 0.5 s, then rest * Rz(90); keys span 0..1 s (31 frames incl. closing)
        q2 = bake.qmul(tuple(child_rest_q or CHILD_REST_Q), tuple(axis_angle((0, 0, 1), 90)))
        tin2 = b.add([0.0, 0.5, 1.0], "SCALAR")
        rot2 = b.add([tuple(CHILD_REST_Q), q2, tuple(CHILD_REST_Q)], "VEC4")
        anims.append({
            "name": "blink",
            "samplers": [{"input": tin2, "output": rot2, "interpolation": "STEP"}],
            "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}],
        })
    for a in extra_anims or []:
        tin = b.add(a["times"], "SCALAR")
        out = b.add([tuple(v) for v in a["values"]], "VEC4")
        anims.append({
            "name": a["name"],
            "samplers": [{"input": tin, "output": out, "interpolation": "LINEAR"}],
            "channels": [{"sampler": 0, "target": {"node": a["node"], "path": "rotation"}}],
        })
    gltf = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [3]}],
        "nodes": nodes,
        "meshes": [{"primitives": [{"attributes": {"POSITION": pos, "JOINTS_0": joints, "WEIGHTS_0": weights}}]}],
        "skins": [{"joints": [0, 1], "inverseBindMatrices": ibm}],
        "accessors": b.accessors,
        "bufferViews": b.views,
        "buffers": [{"byteLength": len(b.bin)}],
    }
    if anims:
        gltf["animations"] = anims
    js = json.dumps(gltf).encode()
    js += b" " * (-len(js) % 4)
    binb = bytes(b.bin) + b"\0" * (-len(b.bin) % 4)
    total = 12 + 8 + len(js) + 8 + len(binb)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(binb), 0x004E4942) + binb)


META = {
    "fps": 30,
    "boss": "test_boss",
    "module": "TestBoss",
    "clips": {
        "turn": {"frames": 31, "loop": False, "speedRef": None, "mask": None},
        "blink": {"frames": 30, "loop": True, "speedRef": 40, "mask": ["Child"]},
    },
}


def frame_q(ch, f):
    return tuple(ch["q"][f])


class BakeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bake_test_")
        self.glb = os.path.join(self.tmp, "anim.glb")
        make_glb(self.glb)
        self.module, self.warnings = bake.bake(bake.Glb(self.glb), json.loads(json.dumps(META)))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def assertQ(self, got, want, places=5):
        if bake.qdot(got, want) < 0:
            want = [-c for c in want]
        for g, w in zip(got, want):
            self.assertAlmostEqual(g, w, places=places, msg=f"{got} != {want}")

    def test_bones_in_skin_order(self):
        self.assertEqual(self.module["bones"], ["Root", "Child"])
        self.assertEqual(self.module["fps"], 30)

    def test_rest_frame_is_identity(self):
        turn = self.module["clips"]["turn"]
        for ch in turn["channels"]:
            self.assertQ(frame_q(ch, 0), (0, 0, 0, 1))
        self.assertIsNone(turn["channels"][0]["t"], "Root never translates: t omitted")
        for c in turn["channels"][1]["t"][0]:
            self.assertAlmostEqual(c, 0.0, places=6)

    def test_known_rotation(self):
        root = self.module["clips"]["turn"]["channels"][0]
        self.assertEqual(len(root["q"]), 31)
        self.assertQ(frame_q(root, 30), axis_angle((0, 1, 0), 90))
        self.assertQ(frame_q(root, 15), axis_angle((0, 1, 0), 45))  # slerp halfway

    def test_translation_in_bone_frame(self):
        # parent-space slide (0, 0, 2) seen from a child turned 90 deg about X is (0, 2, 0) in its own frame
        child = self.module["clips"]["turn"]["channels"][1]
        for got, want in zip(child["t"][30], (0.0, 2.0, 0.0)):
            self.assertAlmostEqual(got, want, places=5)
        for got, want in zip(child["t"][15], (0.0, 1.0, 0.0)):
            self.assertAlmostEqual(got, want, places=5)
        self.assertQ(frame_q(child, 30), (0, 0, 0, 1))  # child rotation unanimated: identity delta

    def test_step_sampler_and_loop_frames(self):
        blink = self.module["clips"]["blink"]
        self.assertEqual(blink["frames"], 30)
        self.assertTrue(blink["loop"])
        self.assertEqual(blink["speedRef"], 40)
        self.assertEqual(blink["mask"], ["Child"])
        child = blink["channels"][1]
        self.assertEqual(len(child["q"]), 30, "the closing duplicate frame 30 is not stored")
        self.assertQ(frame_q(child, 14), (0, 0, 0, 1))
        self.assertQ(frame_q(child, 15), axis_angle((0, 0, 1), 90))
        self.assertQ(frame_q(child, 29), axis_angle((0, 0, 1), 90))
        # unanimated Root in this clip: identity every frame, no translation
        self.assertQ(frame_q(blink["channels"][0], 7), (0, 0, 0, 1))
        self.assertIsNone(blink["channels"][0]["t"])

    def test_hemisphere_continuity(self):
        # A 0 -> 340 deg spin about Y keyed as quaternions that cross w = 0: baked rows never flip sign.
        keys = [axis_angle((0, 1, 0), d) for d in (0, 120, 240, 340)]
        keys[2] = [-c for c in keys[2]]  # an exporter may emit either sign
        glb = os.path.join(self.tmp, "spin.glb")
        make_glb(glb, extra_anims=[{"name": "spin", "node": 0, "times": [0, 1, 2, 3], "values": keys}])
        meta = json.loads(json.dumps(META))
        meta["clips"]["spin"] = {"frames": 91, "loop": False}
        mod, _ = bake.bake(bake.Glb(glb), meta)
        rows = mod["clips"]["spin"]["channels"][0]["q"]
        for a, b in zip(rows, rows[1:]):
            self.assertGreaterEqual(bake.qdot(a, b), 0.0)
        self.assertGreaterEqual(rows[0][3], 0.0)

    def test_rest_mismatch_detected(self):
        other = os.path.join(self.tmp, "rigged.glb")
        make_glb(other, animations=False, child_rest_q=axis_angle((1, 0, 0), 60))
        with self.assertRaises(bake.BakeError):
            bake.bake(bake.Glb(self.glb), json.loads(json.dumps(META)), bake.Glb(other))
        same = os.path.join(self.tmp, "same.glb")
        make_glb(same, animations=False)
        bake.bake(bake.Glb(self.glb), json.loads(json.dumps(META)), bake.Glb(same))

    def test_bad_meta_rejected(self):
        meta = json.loads(json.dumps(META))
        meta["clips"]["fly"] = {"frames": 10, "loop": True}
        with self.assertRaises(bake.BakeError):
            bake.bake(bake.Glb(self.glb), meta)
        meta = json.loads(json.dumps(META))
        meta["clips"]["blink"]["mask"] = ["Nope"]
        with self.assertRaises(bake.BakeError):
            bake.bake(bake.Glb(self.glb), meta)

    def test_render_and_cli(self):
        meta_path = os.path.join(self.tmp, "clips_meta.json")
        with open(meta_path, "w") as f:
            json.dump(META, f)
        out = os.path.join(self.tmp, "TestBoss.luau")
        rc = bake.main(["test_boss", "--glb", self.glb, "--out", out])
        self.assertEqual(rc, 0)
        with open(out) as f:
            text = f.read()
        self.assertTrue(text.startswith("--!strict\n"))
        self.assertIn('bones = { "Root", "Child" }', text)
        self.assertIn("speedRef = 40,", text)
        self.assertIn('mask = { "Child" }', text)
        # constant channels collapse to a single row
        self.assertIn("{ q = { 0, 0, 0, 1 } }, -- Root", text)
        self.assertLess(len(text.encode()), bake.MAX_BYTES)
        lune = shutil.which("lune") or os.path.expanduser("~/.local/bin/lune")
        if not os.path.exists(lune):
            self.skipTest("lune not installed: skipped the Luau cross-check")
        script = os.path.join(self.tmp, "check.luau")
        clipmath = os.path.join(REPO, "src", "shared", "bossclips", "ClipMath.luau")
        with open(script, "w") as f:
            f.write(f"""
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local CM = luau.load(fs.readFile({json.dumps(clipmath)}))()
local mod = luau.load(fs.readFile({json.dumps(out)}))()
local ok, err = CM.validate(mod)
assert(ok, err)
local x, y, z, w = CM.sample(mod.clips.turn, 1, 0.5, mod.fps)
print(string.format("%.4f %.4f %.4f %.4f", x, y, z, w))
local _, _, _, _, tx, ty, tz = CM.sample(mod.clips.turn, 2, 1.0, mod.fps)
print(string.format("%.4f %.4f %.4f", tx, ty, tz))
""")
        res = subprocess.run([lune, "run", script], capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stderr + res.stdout)
        lines = res.stdout.split()
        want = axis_angle((0, 1, 0), 45)
        for got, w in zip(lines[0:4], want):
            self.assertAlmostEqual(float(got), w, places=3)
        for got, w in zip(lines[4:7], (0.0, 2.0, 0.0)):
            self.assertAlmostEqual(float(got), w, places=3)


if __name__ == "__main__":
    unittest.main()
