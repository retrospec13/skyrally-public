"""Item cubes v3: staggered set layout helpers shared by the author scripts and the map tests (docs/design/ITEM_BOXES.md).

The numbers live in tools/map/item_cubes.json (the Lune spec tools/tests/item_cubes_spec.luau reads the same file).
Owner, 2026-10-20: cubes are "Shared like Mario Kart, back for everyone in 1.0 s"; a "Second cube levels up the held
item (Diddy Kong Racing)"; "if we do the second cube level up then the cubes need to be staggered to take advantage of
that and then do we need to provide more cubes to be available in the air plane?". So every map gets sets of 5: a front
rank of 2 and a back rank of 3, rankDepth studs further on, laterally offset so a straight or gentle line (within
maxChainAngleDeg) runs through one cube of each rank; plane sets add height offsets. The runtime takes at most one cube
per rank per pass (ItemRules.rankLocked), so a set is one item plus one level-up, never a whole rank at once.

Speed/Air pods are never next to a set (owner: the winged coin beside the blocks "needs to be an actual block '?'"): the
set's fifth cube replaces the v2 single that sat 60 studs after the row, and the Speed pickup itself moves to the middle
of the gap before the next set (`gap_single`), where it is the mint boost block.

An author script calls `cube_set(...)` per set and `speed_single(...)` per Speed/Air pod, then `assert_layout(...)` on its
gameplay block before writing the plan, so a bad station fails at author time. `audit(...)` returns the problems as text.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

RULES = json.loads((Path(__file__).resolve().parent / "item_cubes.json").read_text())
ITEM_TYPES = tuple(RULES["itemTypes"])
SINGLE_TYPES = tuple(RULES["singleTypes"])


def vehicle_rules(vehicle: str) -> dict:
    return RULES["car" if vehicle == "car" else "plane"]


def _per_map(table: dict | None, key: str):
    if not table:
        return None
    return table.get(key, table.get("default"))


def ranks(vehicle: str, key: str) -> list[list[float]]:
    """Laterals per rank (front first)."""
    return _per_map(vehicle_rules(vehicle)["ranks"], key)


def rank_heights(vehicle: str, key: str) -> list[list[float]] | None:
    """Height offsets per rank (plane sets), or None (car sets sit at one height)."""
    return _per_map(vehicle_rules(vehicle).get("rankHeights"), key)


def set_size(vehicle: str, key: str) -> int:
    return sum(len(r) for r in ranks(vehicle, key))


def set_types(set_index: int, size: int) -> list[str]:
    """`size` plan colours for set `set_index`, rotating the start so sets differ. A race pod is a mystery cube, so the
    colour only picks the glass family (ItemArt.cubeFamily) and names the pod: a set of 5 shows five different glasses."""
    return [ITEM_TYPES[(set_index + j) % len(ITEM_TYPES)] for j in range(size)]


def cube_set(vehicle: str, key: str, set_index: int, station: float, height: float, name, tag: str,
             centre: float = 0.0) -> list[dict]:
    """One staggered set at `station` (the front rank; the back rank is rankDepth further on). name(type, j) -> pod name
    (j from 1, front rank first). Every pod carries cubeSet (`tag`) and cubeRank (1 front, 2 back); MapAdapter passes them
    to kit/Gameplay, which writes the CubeRank attribute the rank lock reads."""
    vr = vehicle_rules(vehicle)
    lat_ranks = ranks(vehicle, key)
    h_ranks = rank_heights(vehicle, key)
    types = set_types(set_index, set_size(vehicle, key))
    out = []
    j = 0
    for r, lats in enumerate(lat_ranks):
        st = station + r * vr["rankDepth"]
        for i, lat in enumerate(lats):
            typ = types[j]
            j += 1
            dh = h_ranks[r][i] if h_ranks else 0
            out.append({"name": name(typ, j), "station": round(float(st), 1), "lateral": round(centre + lat, 1),
                        "height": round(height + dh, 1), "type": typ, "cubeSet": tag, "cubeRank": r + 1})
    return out


def speed_single(name: str, station: float, height: float, typ: str = "Speed", lateral: float = 0.0) -> dict:
    """A Speed/Air pod on its own, away from every set (a mixed row diluted the item chance, and a coin beside cubes
    went ungrabbed)."""
    assert typ in SINGLE_TYPES, typ
    return {"name": name, "station": round(float(station), 1), "lateral": lateral, "height": height, "type": typ}


def gap_single(vehicle: str, set_stations: list[float], k: int, lap_length: float) -> float:
    """The middle of the gap after set k (its back rank) and before set k + 1 (wrapping): where a Speed pod that sat
    next to set k in v2 now stands on its own."""
    depth = vehicle_rules(vehicle)["rankDepth"]
    k %= len(set_stations)
    a = set_stations[k] + depth
    b = set_stations[(k + 1) % len(set_stations)] + (lap_length if k + 1 == len(set_stations) else 0)
    return round(((a + b) / 2) % lap_length, 1)


def item_sets(pods: list[dict]) -> list[list[dict]]:
    """Item pods grouped into sets by cubeSet, in lap order of the set's front rank (pods without a cubeSet each form
    their own set, so an old or hand-made plan still audits)."""
    by: dict[str, list[dict]] = {}
    order: list[str] = []
    for p in pods:
        if p["type"] not in ITEM_TYPES:
            continue
        tag = p.get("cubeSet") or ("_single_" + p["name"])
        if tag not in by:
            by[tag] = []
            order.append(tag)
        by[tag].append(p)
    sets = [sorted(by[t], key=lambda p: (p.get("cubeRank", 1), p["lateral"])) for t in order]
    sets.sort(key=lambda s: min(p["station"] for p in s))
    return sets


# v2 name kept for callers that only need the grouping
item_rows = item_sets


def set_station(s: list[dict]) -> float:
    return min(p["station"] for p in s)


def chain_problems(s: list[dict], max_angle_deg: float) -> list[str]:
    """A set must let a racer chain one cube of each rank: every front cube has a back cube within the chain angle (and
    every back cube a front one). Lateral and height offsets both count (a plane line is 3-D)."""
    front = [p for p in s if p.get("cubeRank") == 1]
    back = [p for p in s if p.get("cubeRank") == 2]
    if not front or not back:
        return ["no front and back rank"]
    tan = math.tan(math.radians(max_angle_deg))

    def off(a: dict, b: dict) -> float:
        return math.hypot(a["lateral"] - b["lateral"], a["height"] - b["height"])

    bad = []
    depth = back[0]["station"] - front[0]["station"]
    for a in front:
        if min(off(a, b) for b in back) > tan * depth:
            bad.append(f"front cube {a['name']} has no back cube within {max_angle_deg} deg")
    for b in back:
        if min(off(a, b) for a in front) > tan * depth:
            bad.append(f"back cube {b['name']} has no front cube within {max_angle_deg} deg")
    return bad


def audit(gameplay: dict, vehicle: str, key: str, lap_length: float) -> list[str]:
    """Every broken layout rule as a line of text (empty: the layout passes)."""
    vr = vehicle_rules(vehicle)
    pods = gameplay.get("pods", []) or []
    sets = item_sets(pods)
    bad: list[str] = []
    n_items = sum(len(s) for s in sets)
    lo, hi = vr["setsPerLap"]
    if not lo <= len(sets) <= hi:
        bad.append(f"{key}: {len(sets)} sets per lap, want {lo}..{hi}")
    if n_items > RULES["maxCubesPerMap"]:
        bad.append(f"{key}: {n_items} cubes, budget {RULES['maxCubesPerMap']}")
    if n_items * RULES["cubeParts"] > RULES["maxCubeParts"]:
        bad.append(f"{key}: {n_items * RULES['cubeParts']} cube parts, budget {RULES['maxCubeParts']}")
    want_ranks = [len(r) for r in ranks(vehicle, key)]
    d_lo, d_hi = RULES["rankDepthRange"]
    for s in sets:
        st = set_station(s)
        got = [sum(1 for p in s if p.get("cubeRank") == r + 1) for r in range(len(want_ranks))]
        if got != want_ranks or len(s) != sum(want_ranks):
            bad.append(f"{key}: set at {st} has ranks {got}, want {want_ranks}")
            continue
        for r in range(len(want_ranks)):
            rank = [p for p in s if p.get("cubeRank") == r + 1]
            if len({p["station"] for p in rank}) != 1:
                bad.append(f"{key}: set at {st} rank {r + 1} is not at one station")
            pts = [(p["lateral"], p["height"]) for p in rank]
            for i in range(len(pts)):
                for j in range(i + 1, len(pts)):
                    if math.dist(pts[i], pts[j]) < vr["minSpacing"]:
                        bad.append(f"{key}: set at {st} rank {r + 1} cubes closer than {vr['minSpacing']}")
        depth = s[-1]["station"] - s[0]["station"]
        if not d_lo <= depth <= d_hi:
            bad.append(f"{key}: set at {st} ranks {depth:.0f} apart, want {d_lo}..{d_hi}")
        bad += [f"{key}: set at {st}: {m}" for m in chain_problems(s, RULES["maxChainAngleDeg"])]
        types = [p["type"] for p in s]
        if len(set(types)) != len(types):
            bad.append(f"{key}: set at {st} repeats a glass colour")
    stations = [set_station(s) for s in sets]
    if stations:
        if stations[0] < vr["firstRowMin"]:
            bad.append(f"{key}: first set at {stations[0]} < {vr['firstRowMin']}")
        last_back = max(p["station"] for p in sets[-1])
        if last_back > lap_length - vr["lastRowMargin"]:
            bad.append(f"{key}: last set ends at {last_back} within {vr['lastRowMargin']} of the line")
        gaps = [b - a for a, b in zip(stations, stations[1:])] + [lap_length - stations[-1] + stations[0]]
        for g, st in zip(gaps, stations):
            if not vr["minGap"] <= g <= vr["maxGap"]:
                bad.append(f"{key}: gap {g:.0f} after the set at {st}, want {vr['minGap']}..{vr['maxGap']}")
    clear = RULES["singleClearOfSet"]
    cube_stations = [p["station"] for s in sets for p in s]
    for p in pods:
        if p["type"] in ITEM_TYPES:
            continue
        if p["type"] not in SINGLE_TYPES:
            bad.append(f"{key}: pod {p['name']} has unknown type {p['type']}")
        elif any(min(abs(p["station"] - c), lap_length - abs(p["station"] - c)) < clear for c in cube_stations):
            bad.append(f"{key}: {p['type']} pod {p['name']} sits next to a cube set")
    names = [p["name"] for p in pods]
    if len(set(names)) != len(names):
        bad.append(f"{key}: duplicate pod names")
    return bad


def assert_layout(gameplay: dict, vehicle: str, key: str, lap_length: float) -> None:
    bad = audit(gameplay, vehicle, key, lap_length)
    assert not bad, "item cube layout:\n  " + "\n  ".join(bad)
