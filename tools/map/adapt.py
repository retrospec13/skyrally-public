#!/usr/bin/env python3
"""Plan -> generated artifacts (docs/MAP_PLAN_SCHEMA.md section 3).

usage: python3 tools/map/adapt.py map/<key>/plan.json [--no-compile] [--build-dir DIR] [--compiler PATH]

1. Validate the plan (30MAPS art half and the `skyrally` block).
2. Solve the route (tools/map/route.py, the builder_dino4 math) and run the compile gates: length within 1 stud of
   target, horizontal turn radius (tools/course/route_geometry.analyse) outside radiusExceptions, no collidable
   30MAPS part in the flight corridor of any route segment, every gameplay station in [0, length).
3. Unless --no-compile, run the vendored compiler (tools/map30/build_plan.py) into build/<key>/.
4. Write build/<key>/TrackData.luau, deterministic (fixed key order, %.4f floats) so two runs diff clean.

Any failed gate prints every finding and exits 1 before anything is written; a compiler failure exits 3.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, NamedTuple

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
for _p in (HERE, ROOT / "tools" / "course"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import backdrop as backdroplib  # noqa: E402
import route as routelib  # noqa: E402
import route_geometry  # noqa: E402

COMPILER = ROOT / "tools" / "map30" / "build_plan.py"

# Enum.Material names (tools/luau-types/globalTypes.d.luau); the compiler silently falls back to SmoothPlastic
MATERIALS = frozenset("""
Air Asphalt Basalt Brick Cardboard Carpet CeramicTiles ClayRoofTiles Cobblestone Concrete CorrodedMetal CrackedLava
DiamondPlate Fabric Foil ForceField Glacier Glass Granite Grass Ground Ice LeafyGrass Leather Limestone Marble Metal
Mud Neon Pavement Pebble Plaster Plastic Rock RoofShingles Rubber Salt Sand Sandstone Slate SmoothPlastic Snow Water
Wood WoodPlanks
""".split())
SHAPES = frozenset("BCSWK")
COLOUR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
SHELL_OPS = frozenset({"Clear", "SetMaterialColor", "FillBlock", "FillBall", "FillCylinder", "FillWedge", "RouteCavern",
                       "FillRouteBounds", "CarveRouteTube", "RouteFloorFill"})
EXTRA_KEYS = frozenset({"nc", "a", "l", "n"})
PAD_LIFT = 1.6  # pads sit just on the deck
GRID_SLOTS = 8
LUAU_KEYWORDS = frozenset(
    "and break do else elseif end false for function if in local nil not or repeat return then true until while".split())


class Issue(NamedTuple):
    code: str
    msg: str


class Report:
    def __init__(self) -> None:
        self.errors: list[Issue] = []
        self.warnings: list[Issue] = []

    def error(self, code: str, msg: str) -> None:
        self.errors.append(Issue(code, msg))

    def warn(self, code: str, msg: str) -> None:
        self.warnings.append(Issue(code, msg))

    def codes(self) -> set[str]:
        return {e.code for e in self.errors}


def is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_vec(v: Any, n: int = 3) -> bool:
    return isinstance(v, list) and len(v) == n and all(is_num(x) for x in v)


def named(v: Any, names) -> bool:
    """v is one of the string names (a list or dict in its place would make `in` raise)."""
    return isinstance(v, str) and v in names


# ---------------------------------------------------------------------------------------------- validation (art)

def validate_art(plan: dict, rep: Report) -> None:
    prefabs = plan.get("prefabs")
    if not isinstance(prefabs, dict):
        rep.error("plan.prefabs", "plan has no 'prefabs' object")
        prefabs = {}
    if not isinstance(plan.get("instances"), list):
        rep.error("plan.instances", "plan has no 'instances' list")
    terrain = plan.get("terrain")
    if not isinstance(terrain, dict) or not all(isinstance(terrain.get(k), int) for k in ("nx", "nz")):
        rep.error("plan.terrain", "plan needs 'terrain' with integer nx/nz (use {\"nx\":1,\"nz\":1,\"cell\":4} for none)")
    groups = plan.get("groups", [])
    if not isinstance(groups, list) or not all(isinstance(g, str) and g for g in groups):
        rep.error("plan.groups", "'groups' must be a list of non-empty slash paths")
        groups = []

    for key in sorted(prefabs):
        parts = prefabs[key].get("parts") if isinstance(prefabs[key], dict) else None
        if not isinstance(parts, list) or not parts:
            rep.error("prefab.parts", f"prefab {key}: no parts")
            continue
        for j, part in enumerate(parts, 1):
            where = f"prefab {key} part {j}"
            if not isinstance(part, list) or len(part) < 12:
                rep.error("part.fields", f"{where}: {len(part) if isinstance(part, list) else 0} fields, needs 12-13")
                continue
            if len(part) > 13:
                rep.error("part.fields", f"{where}: {len(part)} fields, 30MAPS reads at most 13")
            if not named(part[0], SHAPES):
                rep.error("part.shape", f"{where}: shape {part[0]!r} not in B,C,S,W,K (the compiler would make a block)")
            if not all(is_num(v) for v in part[1:7]):
                rep.error("part.number", f"{where}: position/size must be numbers")
            elif not all(v > 0 for v in part[4:7]):
                rep.error("part.size", f"{where}: size must be positive")
            if not all(v is None or is_num(v) for v in part[7:10]):
                rep.error("part.number", f"{where}: rotation must be numbers or null")
            if not (isinstance(part[10], str) and COLOUR_RE.match(part[10])):
                rep.error("part.colour", f"{where}: colour {part[10]!r} is not #rrggbb")
            if not named(part[11], MATERIALS):
                rep.error("part.material", f"{where}: material {part[11]!r} is not an Enum.Material name")
            extra = part[12] if len(part) > 12 else None
            if extra is not None and not isinstance(extra, dict):
                rep.error("part.extra", f"{where}: extra must be an object")
            elif extra:
                for k in sorted(set(extra) - EXTRA_KEYS):
                    rep.warn("part.extra", f"{where}: extra key {k!r} is ignored by the compiler")

    for i, inst in enumerate(plan.get("instances") or []):
        where = f"instance {i + 1}"
        if not isinstance(inst, dict):
            rep.error("instance.shape", f"{where}: not an object")
            continue
        if not named(inst.get("pf"), prefabs):
            rep.error("prefab.unknown", f"{where}: unknown prefab {inst.get('pf')!r}")
        if not is_vec(inst.get("p")):
            rep.error("instance.p", f"{where}: p must be [x,y,z]")
        g = inst.get("g", 0)
        # g is 1-based; missing/0 lands in the compiler's "Ungrouped" folder
        if not isinstance(g, int) or isinstance(g, bool) or not (0 <= g <= len(groups)):
            rep.error("instance.group", f"{where}: group index {g!r} outside 1..{len(groups)}")
        r = inst.get("r")
        if not (r is None or is_num(r) or (isinstance(r, list) and len(r) == 3 and all(x is None or is_num(x) for x in r))):
            rep.error("instance.r", f"{where}: r must be a yaw or [rx,ry,rz]")
        s = inst.get("s")
        if s is not None and not (is_num(s) and s > 0):
            rep.error("instance.s", f"{where}: scale must be a positive number")

    for m in plan.get("markers", []) or []:
        if isinstance(m, dict) and m.get("kind") in ("Spawn", "Checkpoint"):
            rep.warn("plan.marker", f"marker kind {m.get('kind')} is ignored; gameplay comes from skyrally.gameplay")
    if plan.get("lighting") is not None:
        rep.warn("plan.lighting", "plan 'lighting' is ignored; profiles live in src/shared/LightingProfiles.luau")


# ------------------------------------------------------------------------------------------ validation (skyrally)

# Flight allow-pockets (docs/design/FLIGHT_GUIDE.md 12, src/shared/FlightGuideRules.luau cleanPocket): world-space
# volumes where the default (Mario Kart) flight mode never resets a plane, for secret routes off the path. Optional;
# the runtime keeps at most POCKET_MAX of radius <= POCKET_MAX_R and drops anything malformed, so the gate refuses those.
POCKET_MAX = 16
POCKET_MAX_R = 200


def check_allow_pockets(rep: Report, pockets: Any) -> None:
    if pockets is None:
        return
    if not isinstance(pockets, list):
        rep.error("flight.allowPockets", "flight.allowPockets must be a list")
        return
    if len(pockets) > POCKET_MAX:
        rep.error("flight.allowPockets", f"flight.allowPockets: {len(pockets)} pockets, at most {POCKET_MAX}")
    for i, p in enumerate(pockets, 1):
        ok = isinstance(p, dict) and is_num(p.get("radius")) and 0 < p["radius"] <= POCKET_MAX_R
        if ok and p.get("kind") == "sphere":
            ok = is_vec(p.get("center"))
        elif ok and p.get("kind") == "capsule":
            ok = is_vec(p.get("a")) and is_vec(p.get("b"))
        else:
            ok = False
        if not ok:
            rep.error("flight.allowPockets", f"flight.allowPockets[{i}]: needs kind sphere {{center, radius}} or capsule "
                                             f"{{a, b, radius}}, radius in (0, {POCKET_MAX_R}]")


def _need(rep: Report, d: Any, key: str, check, code: str, where: str, what: str) -> bool:
    ok = isinstance(d, dict) and key in d and check(d[key])
    if not ok:
        rep.error(code, f"{where}.{key}: {what}")
    return ok


def _check_cfs(rep: Report, value: Any, where: str) -> None:
    """Every 'cf' anywhere in a block must be 12 numbers (it becomes CFrame.new)."""
    if isinstance(value, dict):
        for k, v in value.items():
            if k == "cf" and not is_vec(v, 12):
                rep.error("plan.cframe", f"{where}.cf must be 12 numbers")
            _check_cfs(rep, v, f"{where}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _check_cfs(rep, v, f"{where}[{i + 1}]")


def validate_skyrally(plan: dict, rep: Report) -> bool:
    """Returns False when the route block is too broken to solve."""
    sk = plan.get("skyrally")
    if not isinstance(sk, dict):
        rep.error("skyrally.missing", "plan has no 'skyrally' block")
        return False
    is_str = lambda v: isinstance(v, str) and v != ""  # noqa: E731
    for k in ("id", "key", "zone", "vehicle", "lighting"):
        _need(rep, sk, k, is_str, "skyrally.field", "skyrally", "non-empty string required")
    _need(rep, sk, "laps", lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 1,
          "skyrally.field", "skyrally", "positive integer required")
    if sk.get("botPace") is not None and not (is_num(sk["botPace"]) and 0 < sk["botPace"] < 3):
        rep.error("skyrally.field", "skyrally.botPace: optional number above 0 and below 3 (1.0 = today's pace)")

    rt = sk.get("route")
    route_ok = isinstance(rt, dict)
    if not route_ok:
        rep.error("route.field", "skyrally.route missing")
    else:
        nodes = rt.get("nodes")
        if not isinstance(nodes, list) or len(nodes) < 4:
            rep.error("route.nodes", "skyrally.route.nodes needs at least 4 nodes")
            route_ok = False
        else:
            for i, n in enumerate(nodes, 1):
                if not (isinstance(n, dict) and is_vec(n.get("pos")) and is_num(n.get("bank", 0))
                        and (n.get("flex") is None or is_vec(n.get("flex")))):
                    rep.error("route.nodes", f"route node {i}: needs pos [x,y,z], bank, optional flex [x,y,z]")
                    route_ok = False
        if rt.get("closed", True) is not True:
            rep.error("route.closed", "only closed routes are supported (the builder spline wraps around)")
            route_ok = False
        pos_int = lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 1  # noqa: E731
        route_ok &= _need(rep, rt, "targetLength", lambda v: is_num(v) and v > 0, "route.field", "route", "positive number")
        for k in ("samplesPerSegment", "bisectIterations"):
            if k in rt and not pos_int(rt[k]):
                rep.error("route.field", f"route.{k}: positive integer required")
                route_ok = False
        lo, hi = rt.get("flexScaleMin", 0.0), rt.get("flexScaleMax", 3.5)
        if not (is_num(lo) and is_num(hi) and lo <= hi):
            rep.error("route.field", "route.flexScaleMin/Max must be numbers with min <= max")
            route_ok = False
        route_ok &= _need(rep, rt, "minRadius", lambda v: is_num(v) and v >= 0, "route.field", "route", "number >= 0")
        exceptions = rt.get("radiusExceptions", []) or []
        if not isinstance(exceptions, list):
            rep.error("route.field", "route.radiusExceptions must be a list")
            exceptions, route_ok = [], False
        for i, ex in enumerate(exceptions, 1):
            if not (isinstance(ex, dict) and is_num(ex.get("from")) and is_num(ex.get("to")) and ex["from"] <= ex["to"]):
                rep.error("route.field", f"route.radiusExceptions[{i}]: needs from <= to")
                route_ok = False

    fl = sk.get("flight")
    if _need(rep, sk, "flight", lambda v: isinstance(v, dict), "flight.field", "skyrally", "object required"):
        cor = fl.get("corridor")
        if not (is_num(fl.get("lineOffset")) and isinstance(cor, dict)
                and all(is_num(cor.get(k)) for k in ("halfWidth", "floor", "ceiling"))
                and cor["halfWidth"] > 0 and cor["floor"] < cor["ceiling"]):
            rep.error("flight.field", "flight needs lineOffset and corridor {halfWidth > 0, floor < ceiling}")
        elif not (cor["floor"] < fl["lineOffset"] < cor["ceiling"]):
            rep.error("flight.corridor", f"flight line (+{fl['lineOffset']}) is outside its corridor "
                                         f"[{cor['floor']}, {cor['ceiling']}] above the ribbon")
        check_allow_pockets(rep, fl.get("allowPockets"))

    gp = sk.get("gameplay")
    if _need(rep, sk, "gameplay", lambda v: isinstance(v, dict), "gameplay.field", "skyrally", "object required"):
        cps = gp.get("checkpoints")
        if not (isinstance(cps, dict) and isinstance(cps.get("stations"), list) and cps["stations"]
                and all(is_num(s) for s in cps["stations"]) and is_vec(cps.get("size"))
                and is_num(cps.get("heightOffset", 0))):
            rep.error("gameplay.field", "gameplay.checkpoints needs stations[], size [x,y,z], heightOffset")
        for kind, fields in (("rings", ("lateral", "height")), ("pads", ("lateral",)), ("pods", ("lateral", "height"))):
            for i, it in enumerate(gp.get(kind, []) or [], 1):
                if not (isinstance(it, dict) and is_str(it.get("name")) and is_num(it.get("station"))
                        and all(is_num(it.get(f, 0)) for f in fields)):
                    rep.error("gameplay.field", f"gameplay.{kind}[{i}]: needs name, station, {', '.join(fields)}")
                fc = it.get("facing") if isinstance(it, dict) else None
                if fc is not None and not (kind == "pads" and is_vec(fc) and math.hypot(fc[0], fc[2]) > 1e-6):
                    rep.error("gameplay.field", f"gameplay.{kind}[{i}].facing: pads only, a horizontal direction [x, y, z]")
                sg = it.get("sailGate") if isinstance(it, dict) else None
                if sg is not None and not (kind == "rings" and isinstance(sg, dict) and is_num(sg.get("rpm")) and sg["rpm"] > 0
                                           and is_num(sg.get("ringDeg")) and is_num(sg.get("phaseDeg", 0))):
                    rep.error("gameplay.field", f"gameplay.{kind}[{i}].sailGate: rings only, needs rpm > 0, ringDeg, phaseDeg")
                ln = it.get("line") if isinstance(it, dict) else None
                if ln is not None:
                    alt_ids = {a.get("id") for a in gp.get("alternates") or [] if isinstance(a, dict)}
                    if not (kind == "rings" and is_str(ln) and ln in alt_ids and is_vec(it.get("pos"))
                            and is_vec(it.get("look")) and is_vec(it.get("up"))):
                        rep.error("gameplay.field", f"gameplay.{kind}[{i}].line: rings only, an alternates id, with pos, look and up [x,y,z]")
                elif isinstance(it, dict) and any(k in it for k in ("pos", "look", "up")):
                    rep.error("gameplay.field", f"gameplay.{kind}[{i}]: pos/look/up place a ring on an alternate line and need line")
        for i, g in enumerate(gp.get("geysers", []) or [], 1):
            if not (isinstance(g, dict) and is_str(g.get("id")) and is_vec(g.get("pos")) and is_num(g.get("phase", 0))
                    and g.get("cycle", 4.0) == 4.0 and is_num(g.get("radius", 12)) and is_num(g.get("height", 26))):
                rep.error("gameplay.field", f"gameplay.geysers[{i}]: needs id, pos [x,y,z], phase, radius, height; the cycle is a fixed 4 s")
        er = gp.get("eruption")
        if er is not None and not (isinstance(er, dict) and isinstance(er.get("lap"), int) and 1 <= er["lap"] <= sk.get("laps", 1)):
            rep.error("gameplay.field", "gameplay.eruption needs an integer lap within the lap count")
        sg = gp.get("startGrid")
        if not (isinstance(sg, dict) and all(is_num(sg.get(k)) for k in ("station", "height", "rowSpacing", "laneOffset"))):
            rep.error("gameplay.field", "gameplay.startGrid needs station, height, rowSpacing, laneOffset")
        fin = gp.get("finish")
        if not (isinstance(fin, dict) and is_num(fin.get("station")) and is_num(fin.get("radius"))):
            rep.error("gameplay.field", "gameplay.finish needs station and radius")
        for i, alt in enumerate(gp.get("alternates", []) or [], 1):
            if not (isinstance(alt, dict) and is_str(alt.get("id")) and isinstance(alt.get("points"), list)
                    and len(alt["points"]) >= 2 and all(is_vec(p) for p in alt["points"])
                    and all(alt.get(k) is None or is_num(alt[k]) for k in ("joinStation", "rejoinStation"))):
                rep.error("gameplay.field", f"gameplay.alternates[{i}]: needs id, points [[x,y,z]...] (2+), "
                                            f"join/rejoinStation number or null")

    shells = sk.get("shells", {}) or {}
    ops = shells.get("ops", []) if isinstance(shells, dict) else None
    if not isinstance(ops, list):
        rep.error("shells.op", "skyrally.shells must be {\"ops\": [...]}")
        ops = []
    for block in ("hazards", "meshes", "fx", "modelAttributes"):
        if not isinstance(sk.get(block, []) or [], list):
            rep.error(f"{block}.field", f"skyrally.{block} must be a list")
    for i, op in enumerate(ops, 1):
        if not (isinstance(op, dict) and named(op.get("op"), SHELL_OPS)):
            rep.error("shells.op", f"shells.ops[{i}]: op must be one of {', '.join(sorted(SHELL_OPS))}")
            continue
        for k in ("mat", "wallMat", "roofMat"):
            if k in op and not named(op[k], MATERIALS):
                rep.error("shells.material", f"shells.ops[{i}].{k}: {op[k]!r} is not an Enum.Material name")
    for i, m in enumerate(sk.get("meshes", []) or [], 1):
        # Asset ids stay integer literals in TrackData so tools/asset_preflight.py's static scan requires them
        if not (isinstance(m, dict) and isinstance(m.get("model"), int) and not isinstance(m.get("model"), bool)
                and m["model"] > 0):
            rep.error("mesh.model", f"meshes[{i}]: model must be a positive integer asset id")
    for i, d in enumerate(sk.get("setDressing", []) or [], 1):
        if not (isinstance(d, dict) and isinstance(d.get("key"), str) and is_vec(d.get("pos"), 3)
                and all(d.get(k) is None or is_num(d[k]) for k in ("yaw", "scale"))
                and all(d.get(k) is None or isinstance(d.get(k), bool) for k in ("snap", "collide"))):
            rep.error("setDressing.field", f"setDressing[{i}]: needs key (PropLibrary key), pos [x,y,z], "
                                           f"optional yaw/scale numbers and snap/collide bools")
    for block in ("shells", "hazards", "meshes", "fx", "modelAttributes"):
        _check_cfs(rep, sk.get(block), f"skyrally.{block}")
    bd = sk.get("backdrop")
    if bd is not None:
        if not isinstance(bd, dict) or set(bd) - {"shells", "floors", "rings", "cores", "peaks"}:
            rep.error("backdrop.field", "skyrally.backdrop must be {shells?, floors?, rings?, cores?, peaks?} (tools/map/backdrop.py)")
        else:
            for k, v in bd.items():
                if not (isinstance(v, list) and all(isinstance(e, dict) and is_str(e.get("name")) for e in v)):
                    rep.error("backdrop.field", f"backdrop.{k} must be a list of generator blocks with a name")
    return route_ok


# ------------------------------------------------------------------------------------------------- route gates

VARIETY_FIELDS = ("archetype", "signature", "signatureVerb")


def variety_gate(plan: dict, siblings: dict[str, dict], rep: Report) -> None:
    """Track variety gate (docs/design/TRACK_VARIETY.md section 4, acceptance rules 1 and 2).

    `plan` is the plan being compiled; `siblings` maps a map key to the `skyrally` block of every other plan in map/.
    The plan must carry a non-empty archetype, signature (one sentence) and signatureVerb. No other map anywhere may
    share its primary archetype (rule 1), and no other map in the same zone may share its signature verb (rule 2); both
    are compared without case or surrounding space. Maps in different zones may repeat a verb."""
    sk = plan.get("skyrally") or {}
    ok = True
    for f in VARIETY_FIELDS:
        v = sk.get(f)
        if not (isinstance(v, str) and v.strip()):
            rep.error("variety.field", f"skyrally.{f}: non-empty string required (TRACK_VARIETY section 4)")
            ok = False
    if not ok:
        return
    norm = lambda s: " ".join(s.casefold().split())  # noqa: E731
    for key, other in sorted(siblings.items()):
        if key == sk.get("key"):
            continue
        a = other.get("archetype")
        if isinstance(a, str) and norm(a) == norm(sk["archetype"]):
            rep.error("variety.duplicate",
                      f"{sk.get('id')} and {other.get('id', key)} share the archetype {sk['archetype']!r}; every map "
                      f"needs its own primary archetype (TRACK_VARIETY section 4, rule 1)")
        v = other.get("signatureVerb")
        if other.get("zone") == sk.get("zone") and isinstance(v, str) and norm(v) == norm(sk["signatureVerb"]):
            rep.error("variety.duplicate",
                      f"{sk.get('id')} and {other.get('id', key)} (zone {sk.get('zone')}) share the signature verb "
                      f"{sk['signatureVerb']!r}; every map in a zone needs its own (TRACK_VARIETY section 4, rule 2)")


def sibling_skyrally(plan_path: Path) -> dict[str, dict]:
    """The `skyrally` block of every other map/<key>/plan.json next to `plan_path`."""
    out: dict[str, dict] = {}
    for p in sorted(plan_path.parent.parent.glob("*/plan.json")):
        if p.resolve() == plan_path.resolve():
            continue
        try:
            sk = json.loads(p.read_text()).get("skyrally")
        except (OSError, ValueError):
            continue
        if isinstance(sk, dict):
            out[p.parent.name] = sk
    return out


def route_gates(rt: dict, route: routelib.Route, rep: Report) -> dict:
    target = float(rt["targetLength"])
    err = route.length - target
    if abs(err) > 1.0:
        rep.error("route.length", f"route length {route.length:.2f} is {err:+.2f} off target {target:g} "
                                  f"(flexScale bisected to {route.flex_scale:.4f} in "
                                  f"[{rt.get('flexScaleMin', 0.0)}, {rt.get('flexScaleMax', 3.5)}])")
    exceptions = [ex for ex in rt.get("radiusExceptions", []) or []]
    excepted = lambda st: any(ex["from"] <= st <= ex["to"] for ex in exceptions)  # noqa: E731
    rows, _ = route_geometry.analyse([list(w.pos) for w in route.waypoints], min_radius=rt["minRadius"])
    gated = [r for r in rows if not excepted(r["st"])]
    worst = min(gated, key=lambda r: r["r"]) if gated else {"r": math.inf, "st": 0}
    min_r = float(rt["minRadius"])
    for stretch in route_geometry.stretches(rows, lambda r: r["r"] < min_r and not excepted(r["st"])):
        m = min(stretch, key=lambda r: r["r"])
        rep.error("route.radius", f"turn radius {m['r']:.1f} < minRadius {min_r:g} at st {stretch[0]['st']}-"
                                  f"{stretch[-1]['st']} (min at st {m['st']}, pos {m['pos']})")
    return {"lengthError": err, "minRadius": float(worst["r"]), "minRadiusStation": worst["st"], "radiusExceptions": exceptions}


def grid_slot(sg: dict, k: int) -> tuple[float, float]:
    """(station, lateral) of 1-based start slot k, the legacy FlightServer grid: pole on the centre line at the grid
    station, then pairs (+lane, -lane) one rowSpacing further DOWN the route per row. No slot sits behind the line:
    RaceManager scores a player as (lap - 1) * length + station, so a slot at station ~length - 30 would lead the
    standings, and pace the bots, by a whole lap until it crossed the line."""
    if k == 1:
        return sg["station"], 0.0
    row = (k - 1) // 2
    return sg["station"] + row * sg["rowSpacing"], (sg["laneOffset"] if k % 2 == 0 else -sg["laneOffset"])


# Start-grid camera clearance (grid-order regression 2026-10-19: with the player seated mid-pack the chase camera sat
# inside the racer one row behind). Per vehicle: the chase camera's offset behind and above the vehicle
# (PlaneConfig.CAM_DISTANCE / CAM_HEIGHT, CarConfig.CAM_DISTANCE / CAM_HEIGHT at rest) and the vehicle's box half
# extents (lateral, up, along: the plane is AI_AVOID span 16 x clearHeight 5 x length 14; the car CarConfig HALF_WIDTH x
# a seated-pilot height x HALF_LENGTH). tools/tests/racer_view_spec.luau checks these against the Luau configs.
GRID_CAMERA = {
    "plane": {"camBack": 15.2, "camUp": 4.5, "half": (8.0, 2.5, 7.0)},
    "car": {"camBack": 14.5, "camUp": 5.4, "half": (3.15, 2.5, 5.25)},
}
# src/shared/RacerViewRules.luau NEAR_CLEAR / SIGHT_CLEAR / SIGHT_OWN_MARGIN: a neighbour on the grid must sit outside
# the camera-near fade and the camera -> vehicle sightline fade, so nothing on the grid fades at all.
GRID_NEAR_CLEAR = 6.0
GRID_SIGHT_CLEAR = 3.0
GRID_SIGHT_OWN_MARGIN = 6.0


def _box_distance(p: tuple[float, float, float], half: tuple[float, float, float]) -> float:
    return math.sqrt(sum(max(abs(c) - h, 0.0) ** 2 for c, h in zip(p, half)))


def grid_camera_clearance(sg: dict, vehicle: str) -> list[tuple[int, int, str, float]]:
    """Every (player slot, neighbour slot, kind, distance) where a neighbour on the start grid would fade on the player's
    screen: its box within GRID_NEAR_CLEAR of the chase camera (unless wholly behind the camera, where it cannot be seen)
    or within GRID_SIGHT_CLEAR of the camera -> vehicle sightline. Straight-start approximation in the grid's own frame
    (lateral, up, along the route); slots are at one height. Empty = the grid is clear for every player slot."""
    cam = GRID_CAMERA[vehicle]
    half = cam["half"]
    radius = math.sqrt(sum(h * h for h in half))
    sight = math.hypot(cam["camBack"], cam["camUp"])
    stop = max(0.0, (sight - GRID_SIGHT_OWN_MARGIN) / sight)
    slots = [grid_slot(sg, k) for k in range(1, GRID_SLOTS + 1)]
    out: list[tuple[int, int, str, float]] = []
    for k, (st_k, lat_k) in enumerate(slots, 1):
        cx, cy, cz = lat_k, cam["camUp"], st_k - cam["camBack"]
        for j, (st_j, lat_j) in enumerate(slots, 1):
            if j == k:
                continue
            if st_j - cz >= -radius:  # not wholly behind the camera (it looks along +station)
                d = _box_distance((cx - lat_j, cy, cz - st_j), half)
                if d < GRID_NEAR_CLEAR:
                    out.append((k, j, "near", d))
            best = math.inf  # sightline camera -> a point SIGHT_OWN_MARGIN short of the player's hull, sampled
            for i in range(41):
                t = stop * i / 40
                best = min(best, _box_distance((cx - lat_j, cy * (1 - t), cz + cam["camBack"] * t - st_j), half))
            if best < GRID_SIGHT_CLEAR:
                out.append((k, j, "sightline", best))
    return out


def grid_camera_gate(sk: dict, rep: Report) -> None:
    """The start grid keeps every neighbour out of the chase camera's near volume and sightline for the player in any
    slot, and every slot inside the space racers use at the start: a plane's wingtip inside the flight corridor (no
    collidable part there), a car's side on the deck (the start-zone width when deck.zones narrows it)."""
    gp, vehicle = sk.get("gameplay"), sk.get("vehicle")
    sg = gp.get("startGrid") if isinstance(gp, dict) else None
    if vehicle not in GRID_CAMERA or not isinstance(sg, dict) \
            or not all(is_num(sg.get(k)) for k in ("station", "rowSpacing", "laneOffset")):
        return
    for k, j, kind, d in grid_camera_clearance(sg, vehicle):
        rep.error("startGrid.camera", f"startGrid slot {j} is {d:.1f} studs from the chase camera {kind} of a player "
                                      f"in slot {k} (rowSpacing {sg['rowSpacing']}, laneOffset {sg['laneOffset']})")
    edge = abs(sg["laneOffset"]) + GRID_CAMERA[vehicle]["half"][0]
    if vehicle == "plane":
        fl = sk.get("flight")
        cor = fl.get("corridor") if isinstance(fl, dict) else None
        if isinstance(cor, dict) and is_num(cor.get("halfWidth")) and edge > cor["halfWidth"]:
            rep.error("startGrid.width", f"startGrid wingtip at lateral {edge:g} is outside the flight corridor "
                                         f"(halfWidth {cor['halfWidth']:g})")
        return
    deck = sk.get("deck") if isinstance(sk.get("deck"), dict) else {}
    width = deck.get("width")
    back, front = sg["station"], grid_slot(sg, GRID_SLOTS)[0]
    for z in deck.get("zones", []) or []:
        if isinstance(z, dict) and all(is_num(z.get(f)) for f in ("from", "to", "width")) \
                and z["from"] <= front and back <= z["to"]:
            width = min(width, z["width"]) if is_num(width) else z["width"]
    if is_num(width) and edge > width / 2:
        rep.error("startGrid.width", f"startGrid car side at lateral {edge:g} is off the {width:g}-wide deck")


def station_gate(sk: dict, length: float, rep: Report) -> None:
    gp = sk.get("gameplay")
    if not isinstance(gp, dict):
        return
    obj = lambda v: v if isinstance(v, dict) else {}  # noqa: E731  (shape errors are reported by validation)
    lst = lambda v: [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []  # noqa: E731
    found: list[tuple[str, Any]] = []
    stations = obj(gp.get("checkpoints")).get("stations")
    for i, s in enumerate(stations if isinstance(stations, list) else [], 1):
        found.append((f"checkpoints.stations[{i}]", s))
    for kind in ("rings", "pads", "pods"):
        for it in lst(gp.get(kind)):
            found.append((f"{kind}.{it.get('name')}", it.get("station")))
    for kind in ("startGrid", "finish"):
        found.append((f"{kind}.station", obj(gp.get(kind)).get("station")))
    sg = obj(gp.get("startGrid"))
    if all(is_num(sg.get(k)) for k in ("station", "rowSpacing", "laneOffset")):
        # The back row must not wrap past the finish line either
        found.append((f"startGrid slot {GRID_SLOTS}", grid_slot(sg, GRID_SLOTS)[0]))
    for alt in lst(gp.get("alternates")):
        found.append((f"alternates.{alt.get('id')}.joinStation", alt.get("joinStation")))
        found.append((f"alternates.{alt.get('id')}.rejoinStation", alt.get("rejoinStation")))
    if isinstance(gp.get("key"), dict):
        found.append(("key.station", gp["key"].get("station")))
    for where, s in found:
        if is_num(s) and not (0 <= s < length):
            rep.error("gameplay.station", f"gameplay.{where} = {s} outside [0, {length:.2f})")


# ---------------------------------------------------------------------------------------------- corridor gate

def rot_yxz(rx: float, ry: float, rz: float) -> np.ndarray:
    """CFrame.fromEulerAnglesYXZ(rad rx, rad ry, rad rz) = Ry * Rx * Rz."""
    a, b, c = math.radians(rx), math.radians(ry), math.radians(rz)
    rx_m = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
    ry_m = np.array([[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]])
    rz_m = np.array([[math.cos(c), -math.sin(c), 0], [math.sin(c), math.cos(c), 0], [0, 0, 1]])
    return ry_m @ rx_m @ rz_m


def cone_bounds(n: int) -> tuple[float, float, float, float]:
    """builder_template coneBounds: footprint size and centre offset of the unit n-sided cone."""
    R = 0.5 / math.cos(math.pi / n)
    xs = [R * math.sin(math.pi / n + k * 2 * math.pi / n) for k in range(n)]
    zs = [R * math.cos(math.pi / n + k * 2 * math.pi / n) for k in range(n)]
    return max(xs) - min(xs), max(zs) - min(zs), (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2


def instance_rotation(r: Any) -> np.ndarray | None:
    """None for an invalid r (already reported by validation)."""
    if r is None:
        return np.eye(3)
    if is_num(r):
        return rot_yxz(0, r, 0)
    if isinstance(r, list) and len(r) == 3 and all(x is None or is_num(x) for x in r):
        return rot_yxz(*(x or 0 for x in r))
    return None


def collidable_parts(plan: dict) -> tuple[np.ndarray, np.ndarray, list[dict]]:
    """World AABBs (centre, half extent) of every collidable compiled part. World part CFrame =
    CFrame.new(p) * R(r) * [scale s about the pivot] * partCF, as builder_template places them."""
    # Entries that fail validation are skipped here (already reported), so the gate never raises on them
    prefabs = plan.get("prefabs") if isinstance(plan.get("prefabs"), dict) else {}
    instances = plan.get("instances") if isinstance(plan.get("instances"), list) else []
    centres, halves, meta = [], [], []
    for i, inst in enumerate(instances):
        if not isinstance(inst, dict) or not named(inst.get("pf"), prefabs) or not is_vec(inst.get("p")):
            continue
        pf = prefabs[inst["pf"]]
        r_inst = instance_rotation(inst.get("r"))
        s = inst.get("s") or 1
        if not isinstance(pf, dict) or r_inst is None or not is_num(s):
            continue
        p = np.array(inst["p"], float)
        parts = pf.get("parts")
        for j, part in enumerate(parts if isinstance(parts, list) else [], 1):
            if (not isinstance(part, list) or len(part) < 12 or not all(is_num(v) for v in part[1:7])
                    or not all(v is None or is_num(v) for v in part[7:10])):
                continue
            extra = part[12] if len(part) > 12 and isinstance(part[12], dict) else {}
            # Luau truthiness, as the template tests `extra.nc`: 0 or "" still means no-collide
            if extra.get("nc") is not None and extra.get("nc") is not False:
                continue
            r_part = rot_yxz(*(v or 0 for v in part[7:10]))
            local = np.array(part[1:4], float)
            size = np.array(part[4:7], float)  # B/W/S/C all fill (sx, sy, sz) in the part's own frame
            if part[0] == "K":
                n = min(24, max(3, int(math.floor(extra.get("n", 6) if is_num(extra.get("n", 6)) else 6))))
                bx, bz, cx, cz = cone_bounds(n)
                local = local + r_part @ np.array([cx * size[0], 0.0, cz * size[2]])
                size = np.array([bx * size[0], size[1], bz * size[2]])
            rot = r_inst @ r_part
            centres.append(p + r_inst @ (local * s))
            halves.append(np.abs(rot) @ (size * s * 0.5))
            meta.append({"prefab": inst["pf"], "instance": i + 1, "part": j})
    if not centres:
        return np.zeros((0, 3)), np.zeros((0, 3)), []
    return np.array(centres), np.array(halves), meta


def segment_box(a: routelib.Vec, b: routelib.Vec, half_width: float, floor: float, ceiling: float):
    """src/server/CourseCarve.luau segmentBox: floor/ceiling are measured above the ribbon (the waypoint), the
    box follows the chord's pitch and overlaps its neighbours by one half-width. None for chords < 0.5."""
    f = np.subtract(b, a)
    length = float(np.sqrt(f @ f))
    if length < 0.5:
        return None
    h = ceiling - floor
    mid = (np.add(a, b) * 0.5) + np.array([0.0, floor + h * 0.5, 0.0])
    look = f / length
    up_hint = np.array([1.0, 0.0, 0.0]) if abs(look[1]) > 0.98 else np.array([0.0, 1.0, 0.0])
    right = np.cross(look, up_hint)
    right /= np.linalg.norm(right)
    up = np.cross(right, look)
    axes = np.array([right, up, look])
    half = np.array([half_width, h * 0.5, (length + half_width) * 0.5])
    return mid, axes, half


def aabbs_hit_obb(centres: np.ndarray, halves: np.ndarray, mid: np.ndarray, axes: np.ndarray, half: np.ndarray) -> np.ndarray:
    """Separating-axis test of many AABBs against one OBB. Touching faces do not count as intrusion."""
    eps = 1e-6
    obb_half_aabb = np.abs(axes).T @ half
    hit = np.all(np.abs(centres - mid) < halves + obb_half_aabb - eps, axis=1)
    idx = np.nonzero(hit)[0]
    if idx.size == 0:
        return hit
    c, e = centres[idx], halves[idx]
    t = mid - c
    world = np.eye(3)
    cand = [axes[k] for k in range(3)]
    cand += [np.cross(world[i], axes[k]) for i in range(3) for k in range(3)]
    sep = np.zeros(idx.size, bool)
    for ax in cand:
        if ax @ ax < 1e-10:
            continue
        r_obb = float(np.sum(half * np.abs(axes @ ax)))
        r_aabb = e @ np.abs(ax)
        sep |= np.abs(t @ ax) >= r_aabb + r_obb - eps
    hit[idx] = ~sep
    return hit


def corridor_gate(plan: dict, sk: dict, route: routelib.Route, rep: Report) -> dict:
    cor = sk["flight"]["corridor"]
    centres, halves, meta = collidable_parts(plan)
    first: dict[int, tuple[int, int]] = {}  # part row -> (first station, segment count)
    segments = 0
    wps = route.waypoints
    for i in range(len(wps) - 1):
        box = segment_box(wps[i].pos, wps[i + 1].pos, cor["halfWidth"], cor["floor"], cor["ceiling"])
        if box is None:
            continue
        segments += 1
        if not meta:
            continue
        for k in np.nonzero(aabbs_hit_obb(centres, halves, *box))[0]:
            st, cnt = first.get(int(k), (math.floor(wps[i].station), 0))
            first[int(k)] = (st, cnt + 1)
    intrusions = sorted(({**meta[k], "station": st, "segments": cnt} for k, (st, cnt) in first.items()),
                        key=lambda m: (m["station"], m["prefab"], m["instance"], m["part"]))
    for m in intrusions:
        rep.error("corridor.intrusion", f"collidable part in flight corridor: prefab {m['prefab']} instance "
                                        f"{m['instance']} part P{m['part']} at st {m['station']} ({m['segments']} segment(s))")
    return {"corridorPartIntrusions": len(intrusions), "corridorSegments": segments, "collidableParts": len(meta),
            "intrusions": intrusions}


# ---------------------------------------------------------------------------------------------------- checks

class Checked(NamedTuple):
    report: Report
    route: routelib.Route | None
    gates: dict


def check(plan: dict) -> Checked:
    """Validation plus every compile gate. Never raises on bad plan data; read report.errors."""
    rep = Report()
    validate_art(plan, rep)
    route_ok = validate_skyrally(plan, rep)
    if not route_ok:
        return Checked(rep, None, {})
    sk = plan["skyrally"]
    route = routelib.solve_plan_route(sk["route"])
    gates = route_gates(sk["route"], route, rep)
    station_gate(sk, route.length, rep)
    grid_camera_gate(sk, rep)
    if not any(e.code.startswith("flight.") for e in rep.errors) and "flight" in sk:
        gates.update(corridor_gate(plan, sk, route, rep))
    if sk.get("backdrop") and not rep.errors:
        gates["backdrop"] = backdrop_gate(plan, route, rep)
    return Checked(rep, route, gates)


def backdrop_gate(plan: dict, route: routelib.Route, rep: Report) -> list[dict]:
    """Visibility v1 backdrop parts (tools/map/backdrop.py): generated from the plan's `backdrop` block, then audited
    (part count, size, clearance from every Air carve, corridor sample and battle arena; floors inside their slab)."""
    wps = [{"pos": list(w.pos), "station": w.station} for w in route.waypoints]
    try:
        parts = backdroplib.build(plan, wps)
    except (KeyError, IndexError, TypeError, ValueError, StopIteration) as e:
        rep.error("backdrop.field", f"backdrop generator failed: {e!r}")
        return []
    for msg in backdroplib.audit(plan, wps, parts):
        rep.error("backdrop.clearance", msg)
    return parts


# ------------------------------------------------------------------------------------------------ Luau output

class Raw(str):
    """A pre-rendered Luau expression (constructor call)."""


def num(v: float | int) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if math.isinf(v):
        return "math.huge" if v > 0 else "-math.huge"
    if math.isnan(v):
        raise ValueError("NaN in TrackData")
    s = "%.4f" % v
    return "0.0000" if s == "-0.0000" else s


def vec3(v) -> Raw:
    return Raw("Vector3.new(%s, %s, %s)" % tuple(num(x) for x in v))


def cframe(c) -> Raw:
    return Raw("CFrame.new(%s)" % ", ".join(num(x) for x in c))


def plain(value: Any) -> Any:
    """Plan data verbatim, dict keys sorted."""
    if isinstance(value, dict):
        return {k: plain(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [plain(v) for v in value]
    return value


def geo(value: Any, key: str | None = None) -> Any:
    """Plan data with 'cf' 12-arrays as CFrame.new and other 3-number arrays as Vector3.new; keys sorted.
    Instance `props` stay raw: MapAdapter converts each by the property's own type, and a NumberSequence keypoint
    [t, v, envelope] made into a Vector3 fails that conversion (a Beam then keeps Transparency 0, fully opaque)."""
    if key == "props":
        return plain(value)
    if isinstance(value, dict):
        return {k: geo(value[k], k) for k in sorted(value)}
    if isinstance(value, list):
        if key == "cf" and is_vec(value, 12):
            return cframe(value)
        if is_vec(value, 3):
            return vec3(value)
        return [geo(v) for v in value]
    return value


def lua_str(s: str) -> str:
    out = []
    for ch in s:
        o = ord(ch)
        if ch in '\\"':
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def lua_key(k: str) -> str:
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) and k not in LUAU_KEYWORDS:
        return k
    return "[" + lua_str(k) + "]"


def render(value: Any, depth: int = 0) -> str:
    if isinstance(value, Raw):
        return str(value)
    if value is None:
        return "nil"
    if isinstance(value, (bool, int, float)):
        return num(value)
    if isinstance(value, str):
        return lua_str(value)
    # One line for a record of scalars/constructors or a short list of plain scalars; otherwise one item per line
    if isinstance(value, dict):
        items = [f"{lua_key(k)} = {render(v, depth + 1)}" for k, v in value.items()]
        inline = not any(isinstance(v, (dict, list)) for v in value.values())
    elif isinstance(value, list):
        items = [render(v, depth + 1) for v in value]
        inline = len(items) <= 16 and not any(isinstance(v, (dict, list, Raw)) for v in value)
    else:
        raise TypeError(f"cannot render {type(value).__name__}")
    if not items:
        return "{}"
    if inline:
        return "{ " + ", ".join(items) + " }"
    pad = "\t" * (depth + 1)
    return "{\n" + "".join(f"{pad}{it},\n" for it in items) + "\t" * depth + "}"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rel(path: Path) -> str:
    path = path.resolve()
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def compiler_note(compiler: Path | None) -> str:
    if compiler is None:
        return "not run (--no-compile)"
    text = compiler.read_text(errors="replace")
    m = re.search(r"vendored from 30MAPS ([0-9a-f]{7,40})", text)
    base = f"{rel(compiler.parent)} @ {m.group(1)} + patches" if m else rel(compiler)
    return f"{base} (build_plan.py sha256 {sha256_file(compiler)[:12]})"


def variant_tints() -> dict:
    """MaterialVariant name -> terrain tint hex, from assets/materials/<set>/variants.json + tiles/tints.json."""
    out = {}
    for vs in sorted((ROOT / "assets" / "materials").glob("*/variants.json")):
        tp = vs.parent / "tiles" / "tints.json"
        if not tp.exists():
            continue
        tints = json.loads(tp.read_text())
        for name, v in json.loads(vs.read_text()).items():
            if v.get("tex") in tints:
                out[name] = tints[v["tex"]]
    return out


TERRAIN_RES = 4  # the compiled builder's voxel size


def terrain_bounds(plan: dict) -> dict:
    """The box the compiled builder writes terrain in (tools/map30/builder_template.luau buildTerrain): x0..x1 and
    z0..z1 snapped outward to 4 studs, Y from floor4(floor) - 4 to ceil4(top) + 8 with top raised to the roof and the
    water level. The server's map cache copies this box (unioned with the shell ops) as a TerrainRegion (L42,
    src/shared/MapCacheRules.luau). {"empty": True} for a plan without a height grid (the builder writes nothing)."""
    t = plan.get("terrain")
    if not isinstance(t, dict) or not isinstance(t.get("heights"), list):
        return {"empty": True}

    def r2(v):  # build_plan.py rounds the terrain block to 2 decimals before the builder sees it
        return round(float(v), 2)

    res = TERRAIN_RES
    cell = r2(t.get("cell") or 4)
    x0, z0 = r2(t["x0"]), r2(t["z0"])
    x1, z1 = x0 + (t["nx"] - 1) * cell, z0 + (t["nz"] - 1) * cell
    floor_y = r2(t["floor"]) if t.get("floor") is not None else -48.0
    top = r2(t["top"]) if t.get("top") is not None else 0.0
    if t.get("roof") is not None:
        top = max(top, r2(t["roof"]))
    water = t.get("water")
    if isinstance(water, dict) and not water.get("lava") and water.get("level") is not None:
        top = max(top, r2(water["level"]))
    lo = (math.floor(x0 / res) * res, math.floor(floor_y / res) * res - res, math.floor(z0 / res) * res)
    hi = (math.ceil(x1 / res) * res, math.ceil(top / res) * res + res * 2, math.ceil(z1 / res) * res)
    return {"min": vec3(lo), "max": vec3(hi)}


def build_trackdata(plan: dict, route: routelib.Route, gates: dict, source: dict) -> dict:
    sk = plan["skyrally"]
    gp = sk["gameplay"]
    line = float(sk["flight"]["lineOffset"])
    fr = route.frame_at

    waypoints = [{"pos": vec3(w.pos), "bank": w.bank, "station": w.station, "tangent": vec3(w.tangent)}
                 for w in route.waypoints]

    cps = gp["checkpoints"]
    checkpoints = []
    for i, st in enumerate(cps["stations"], 1):
        f = fr(st)
        checkpoints.append({"index": i, "station": st, "cf": cframe(f.cframe(f.offset(0, cps.get("heightOffset", 0)))),
                            "size": vec3(cps["size"])})

    rings = []
    for r in gp.get("rings", []) or []:
        f = fr(r["station"])
        if r.get("line") is not None:
            # A ring on an alternate line (ISLAND-2 Alt2): placed by world pos, travel direction and the surface up there;
            # the station is the line's mapped station. TrackData carries the line id (kit/Gameplay tags it for the bots).
            up = np.array(r["up"], float)
            up /= np.linalg.norm(up)
            look = np.array(r["look"], float)
            look -= up * float(look @ up)
            look /= np.linalg.norm(look)
            right = np.cross(look, up)
            ring_cf = [*r["pos"], right[0], up[0], -look[0], right[1], up[1], -look[1], right[2], up[2], -look[2]]
            ring = {"name": r["name"], "station": r["station"], "cf": cframe([round(float(v), 6) for v in ring_cf]),
                    "coin": bool(r.get("coin", False)), "coinId": r.get("coinId"), "line": r["line"]}
            rings.append(ring)
            continue
        ring = {"name": r["name"], "station": r["station"],
                "cf": cframe(f.cframe(f.offset(r.get("lateral", 0), r.get("height", 0)))),
                "coin": bool(r.get("coin", False)), "coinId": r.get("coinId")}
        if r.get("sailGate") is not None:  # FOREST-1 sail-gap timing ring (src/shared/SailGateRules.luau)
            sg = r["sailGate"]
            ring["sailGate"] = {"rpm": sg["rpm"], "phaseDeg": sg.get("phaseDeg", 0), "ringDeg": sg["ringDeg"]}
        rings.append(ring)

    pads = []
    for p in gp.get("pads", []) or []:
        f = fr(p["station"])
        comps = f.cframe(f.offset(p.get("lateral", 0), PAD_LIFT))
        if p.get("facing") is not None:  # a pad off the main route (an alternate line) faces its own line, not the main tangent
            look = np.array(p["facing"], float)
            look[1] = 0.0
            look /= np.linalg.norm(look)
            up = np.array([0.0, 1.0, 0.0])
            right = np.cross(look, up)
            comps = [*comps[:3], right[0], up[0], -look[0], right[1], up[1], -look[1], right[2], up[2], -look[2]]
            comps = [round(float(v), 6) for v in comps]
        pads.append({"name": p["name"], "station": p["station"], "cf": cframe(comps)})

    pods = []
    for p in gp.get("pods", []) or []:
        f = fr(p["station"])
        pod = {"name": p["name"], "station": p["station"],
               "pos": vec3(f.offset(p.get("lateral", 0), p.get("height", 0))), "type": p.get("type")}
        if p.get("cubeSet") is not None:  # item cubes v3: the staggered set and rank (kit/Gameplay CubeRank attribute)
            pod["cubeSet"], pod["cubeRank"] = p["cubeSet"], p.get("cubeRank", 1)
        pods.append(pod)

    sg = gp["startGrid"]
    grid = []
    for k in range(1, GRID_SLOTS + 1):
        st, lateral = grid_slot(sg, k)
        f = fr(st)
        grid.append(cframe(f.cframe(f.offset(lateral, sg["height"]))))

    fin = gp["finish"]
    # On the flight line: RaceManager compares the hull position against it
    finish = {"pos": vec3(fr(fin["station"]).offset(0, line)), "radius": fin["radius"], "station": fin["station"]}

    alternates = []
    for alt in gp.get("alternates", []) or []:
        a = {"id": alt["id"], "points": [vec3(p) for p in alt["points"]], "style": alt.get("style"),
             "joinStation": alt.get("joinStation"), "rejoinStation": alt.get("rejoinStation")}
        for k in sorted(set(alt) - set(a)):
            a[k] = geo(alt[k], k)
        alternates.append(a)

    def anchor(a: dict) -> dict:
        """A station anchor (coin, hidden key) with its world position: an explicit `pos` wins (off-line anchors such
        as a cellar or an alternate), else the route frame at station + lateral/height."""
        out = {k: geo(a[k], k) for k in sorted(a) if k != "pos"}
        if a.get("pos") is not None:
            out["pos"] = vec3(a["pos"])
        else:
            out["pos"] = vec3(fr(a["station"]).offset(a.get("lateral", 0), a.get("height", 0)))
        return out

    coins = [anchor(c) for c in gp.get("coins") or []]
    hidden_key = anchor(gp["key"]) if isinstance(gp.get("key"), dict) else None
    hub = {k: geo(gp[k], k) for k in ("portals", "finds", "spawn", "respawns", "exchange") if gp.get(k) is not None}

    materials = plain(sk.get("materials") or {})
    if materials.get("terrainOverrides") and not materials.get("terrainColors"):
        # Low-graphics clients render terrain with the material colour only; derive it from the texture tints
        # (tools/vfx/neutralize.py) so a plan that names variants never paints its terrain white.
        tints = variant_tints()
        materials["terrainColors"] = {base: tints[v] for base, v in materials["terrainOverrides"].items() if v in tints}
        materials.pop("terrainColor", None)

    shells = sk.get("shells") or {}
    td = {
        "id": sk["id"], "key": sk["key"], "zone": sk["zone"], "vehicle": sk["vehicle"], "laps": sk["laps"],
        "lighting": sk["lighting"],
        "length": route.length,
        "flexScale": route.flex_scale,
        "waypoints": waypoints,
        "deck": plain(sk.get("deck") or {}),
        "flight": plain(sk["flight"]),
        "checkpoints": checkpoints,
        "rings": rings,
        "pads": pads,
        "pods": pods,
        "startGrid": grid,
        "finish": finish,
        "alternates": alternates,
        "shells": [geo(op) for op in shells.get("ops", [])],
        # Visibility v1: plain non-colliding parts behind/inside far terrain (tools/map/backdrop.py, kit/Backdrop)
        "backdrop": [geo(p) for p in gates.get("backdrop") or []] or None,
        # L42: the builder's terrain box, for the server's map cache (MapCacheRules)
        "terrainBounds": terrain_bounds(plan),
        "hazards": geo(sk.get("hazards") or []),
        "meshes": geo(sk.get("meshes") or []),
        # Set dressing (props from src/shared/PropLibrary.luau placed by MapAdapter; key/pos/yaw/scale/snap)
        "setDressing": geo(sk["setDressing"]) if sk.get("setDressing") else None,
        "modelAttributes": geo(sk.get("modelAttributes") or []),
        "fx": geo(sk.get("fx") or []),
        "framing": plain(sk.get("framing") or {}),
        "materials": materials,
        # No block means no lights (an empty table used to light the whole route with the DINO default)
        "routeLights": plain(sk["routeLights"]) if sk.get("routeLights") else None,
        "coins": coins,
        # DINO-4 launch upgrade (TRACK_VARIETY 5a): geyser updraft vents (server/VolcanoVents, client/VolcanoMoments) and
        # the final-lap eruption. Absent from a plan = absent from the data.
        "geysers": [{k: (vec3(v) if k == "pos" else v) for k, v in g.items()} for g in gp.get("geysers") or []] or None,
        "eruption": plain(gp["eruption"]) if gp.get("eruption") else None,
        "hiddenKey": hidden_key,
        "modes": geo(gp.get("modes") or {}),
        "boss": geo(gp["boss"]) if gp.get("boss") else None,
        "hub": hub or None,
        "gates": {
            "lengthError": gates["lengthError"],
            "minRadius": gates["minRadius"],
            "minRadiusStation": gates["minRadiusStation"],
            "radiusExceptions": plain(gates["radiusExceptions"]),
            "corridorPartIntrusions": gates["corridorPartIntrusions"],
            "corridorSegments": gates["corridorSegments"],
            "collidableParts": gates["collidableParts"],
        },
        "source": source,
    }
    # M-5 (L7): optional per-track bot pace multiplier. Absent from the plan = absent from the data = 1.0 in the game.
    if sk.get("botPace") is not None:
        td["botPace"] = sk["botPace"]
    return td


def render_trackdata(td: dict) -> str:
    # nonstrict + any: the data arrays are heterogeneous by design (fx classes, optional fields), which strict mode
    # rejects; consumers cast the module to their own TrackData type
    head = (f"--!nonstrict\n-- GENERATED by tools/map/adapt.py from {td['source']['plan']}. Do not edit: change the "
            f"plan (or its author script) and rerun the adapter.\n")
    return head + "local trackData: any = " + render(td) + "\nreturn trackData\n"


# ----------------------------------------------------------------------------------------------------- driver

def run_compiler(compiler: Path, plan_path: Path, out_dir: Path, name: str) -> int:
    cmd = [sys.executable, str(compiler), str(plan_path), "--out", str(out_dir),
           "--project", str(out_dir / "map.project.json"), "--name", name]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        print(f"adapt: compiler failed (exit {proc.returncode}): {' '.join(cmd)}", file=sys.stderr)
        return proc.returncode or 1
    if not (out_dir / "builder.server.luau").is_file():
        print(f"adapt: compiler wrote no {out_dir / 'builder.server.luau'}", file=sys.stderr)
        return 1
    # Module form for the game: every launch map is mounted, so builders must not auto-run as Scripts; boot requires
    # only the active track's module (src/server/init.server.luau). The Script form stays for the P2 smoke test.
    src = (out_dir / "builder.server.luau").read_text(encoding="utf-8")
    write_atomic(out_dir / "builder_module.luau", src.rstrip("\n") + "\n\nreturn true\n")
    return 0


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan")
    ap.add_argument("--no-compile", action="store_true", help="skip the vendored compiler; gates and TrackData only")
    ap.add_argument("--build-dir", help="output directory (default build/<key>)")
    ap.add_argument("--compiler", help=f"compiler script (default {rel(COMPILER)})")
    a = ap.parse_args(argv)

    plan_path = Path(a.plan).resolve()
    try:
        raw = plan_path.read_bytes()
        plan = json.loads(raw)
    except (OSError, ValueError) as e:
        print(f"adapt: cannot read plan {a.plan}: {e}", file=sys.stderr)
        return 1
    if not isinstance(plan, dict):
        print("adapt: plan is not a JSON object", file=sys.stderr)
        return 1

    res = check(plan)
    if plan_path.parent.parent == ROOT / "map":  # a repo map: the variety gate reads its sibling plans
        variety_gate(plan, sibling_skyrally(plan_path), res.report)
    for w in res.report.warnings:
        print(f"WARN  {w.code}: {w.msg}")
    if res.report.errors:
        for e in res.report.errors:
            print(f"GATE  {e.code}: {e.msg}")
        sys.stdout.flush()
        print(f"adapt: {len(res.report.errors)} gate failure(s); nothing written", file=sys.stderr)
        return 1

    sk = plan["skyrally"]
    if plan_path.parent.name != sk["key"]:
        print(f"WARN  plan.path: plan folder {plan_path.parent.name!r} differs from skyrally.key {sk['key']!r}")
    out_dir = Path(a.build_dir).resolve() if a.build_dir else ROOT / "build" / sk["key"]
    out_dir.mkdir(parents=True, exist_ok=True)

    compiler = None
    if not a.no_compile:
        compiler = Path(a.compiler).resolve() if a.compiler else COMPILER
        if not compiler.is_file():
            print(f"adapt: vendored compiler {rel(compiler)} not found (rerun with --no-compile for gates and "
                  f"TrackData only)", file=sys.stderr)
            return 3
        rc = run_compiler(compiler, plan_path, out_dir, sk["id"])
        if rc != 0:
            return 3

    source = {"plan": rel(plan_path), "planSha256": hashlib.sha256(raw).hexdigest(), "compiler": compiler_note(compiler)}
    td = build_trackdata(plan, res.route, res.gates, source)
    out = out_dir / "TrackData.luau"
    write_atomic(out, render_trackdata(td))

    g = res.gates
    print(f"route      {len(res.route.waypoints)} waypoints, length {res.route.length:.4f} "
          f"(target {sk['route']['targetLength']}, flexScale {res.route.flex_scale:.4f})")
    print(f"gates      minRadius {g['minRadius']:.1f} at st {g['minRadiusStation']} (outside exceptions), "
          f"corridor {g['corridorSegments']} segments x {g['collidableParts']} collidable parts, 0 intrusions")
    print(f"trackdata  {rel(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
