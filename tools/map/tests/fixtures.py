"""Shared test data: a synthetic circular-route plan and the current DINO-4 builder control nodes."""
from __future__ import annotations

import copy
import math
import re
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
MAP_TOOLS = TESTS.parent
ROOT = MAP_TOOLS.parents[1]
for _p in (MAP_TOOLS, ROOT / "tools" / "course"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import route  # noqa: E402

CENTRE = (0.0, 100.0, -400.0)


def circle_nodes(radius: float = 400.0, n: int = 12, flex: float = 40.0) -> list[dict]:
    """Nodes on a horizontal circle through the origin, flex pointing radially outward."""
    out = []
    for k in range(n):
        a = 2 * math.pi * k / n
        dx, dz = math.sin(a), math.cos(a)
        out.append({"pos": [CENTRE[0] + radius * dx, CENTRE[1], CENTRE[2] + radius * dz],
                    "bank": -10 if k % 2 else 0, "flex": [flex * dx, 0, flex * dz]})
    return out


def circle_plan(radius: float = 400.0, target: float = 2700.0) -> dict:
    return copy.deepcopy({
        "prefabs": {
            "Pillar": {"parts": [["B", 0, 10, 0, 6, 20, 6, 0, 0, 0, "#c98a5a", "Sandstone"]]},
            "Glow#a": {"parts": [["S", 0, 2, 0, 4, 4, 4, 0, 0, 0, "#94e0ff", "Neon", {"nc": True}]]},
            "Spire": {"parts": [["K", 0, 15, 0, 10, 30, 10, None, None, None, "#5a4030", "Rock", {"n": 5}],
                                ["C", 0, 1, 0, 12, 2, 12, 0, 0, 90, "#5a4030", "Basalt"]]},
        },
        "groups": ["Landmarks", "Deco/Lamps"],
        "instances": [
            {"pf": "Pillar", "p": list(CENTRE), "g": 1, "r": 30},
            {"pf": "Spire", "p": [CENTRE[0] + 60, CENTRE[1], CENTRE[2]], "g": 1, "r": [0, 45, 10], "s": 1.5},
            # On the line but non-collidable: the corridor gate must ignore it
            {"pf": "Glow#a", "p": [0, 120, 0], "g": 2},
        ],
        "terrain": {"nx": 1, "nz": 1, "cell": 4},
        "markers": [],
        "labels": [],
        "skyrally": {
            "id": "TEST-1", "key": "test1", "zone": "TEST", "vehicle": "plane", "laps": 3, "lighting": "DINO-4",
            "guide": "none",
            "route": {"nodes": circle_nodes(radius), "closed": True, "samplesPerSegment": 9,
                      "targetLength": target, "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24,
                      "minRadius": 85, "radiusExceptions": [{"from": 10, "to": 20, "reason": "test"}]},
            "deck": {"style": "dino_paver", "width": 32, "zones": [{"from": 0, "to": 200, "width": 22}],
                     "curbHeights": [5.2, 4.4], "gaps": [], "piersEvery": 5},
            "flight": {"lineOffset": 14, "corridor": {"halfWidth": 34, "floor": 5, "ceiling": 44}},
            "gameplay": {
                "checkpoints": {"stations": [0, 600, 1300, 2000], "size": [56, 42, 6], "heightOffset": 18},
                "rings": [{"name": "Ring_1", "station": 300, "lateral": 4, "height": 14, "coin": True, "coinId": "c1"},
                          {"name": "Ring_2", "station": 900, "lateral": 0, "height": 14, "coin": False, "coinId": None}],
                "pads": [{"name": "Pad_1", "station": 450, "lateral": -3}],
                "pods": [{"name": "Pod_1", "station": 1500, "lateral": -6, "height": 12, "type": "Speed"}],
                "startGrid": {"station": 0, "height": 11, "rowSpacing": 28, "laneOffset": 12},
                "finish": {"station": 0, "radius": 58},
                "alternates": [{"id": "Alt1", "points": [[10, 110, -100], [40, 110, -200], [60, 110, -300]],
                                "style": "tunnel", "joinStation": 100, "rejoinStation": 400}],
                "key": None, "modes": {},
            },
            "shells": {"ops": [
                {"op": "Clear"},
                {"op": "SetMaterialColor", "mat": "Sandstone", "color": "#c98a5a"},
                {"op": "FillBlock", "cf": [0, 50, -400, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [100, 10, 100], "mat": "Sandstone"},
                {"op": "FillBall", "center": [0, 60, -400], "r": 26, "mat": "Air"},
                {"op": "RouteCavern", "every": 3, "fromStation": 100, "toStation": 2000, "wallOffset": 142,
                 "wallSize": [48, 136], "wallMat": "Sandstone", "roofMat": "Rock"},
            ]},
            "hazards": [{"name": "Lava", "kind": "LethalLava", "cf": [0, 20, -400, 1, 0, 0, 0, 1, 0, 0, 0, 1],
                         "size": [200, 4, 200], "visible": False, "group": "Hazards"}],
            "meshes": [{"name": "TestMesh", "model": 98086222919300,
                        "textureId": "rbxthumb://type=Asset&id=87703636628661&w=420&h=420", "parent": "Landmarks/Pillar",
                        "cf": [0, 120, -400, 1, 0, 0, 0, 1, 0, 0, 0, 1], "height": 84, "material": "SmoothPlastic",
                        "color": "#e0b688", "collide": False, "fallbackGroup": "Landmarks/Pillar/Fallback"}],
            "modelAttributes": [{"path": "Landmarks/Pillar", "attrs": {"BasePivotPos": [0, 100, -400], "BaseYawDeg": 30}}],
            "fx": [{"class": "SpotLight", "cf": [0, 150, -400, 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": "Landmarks",
                    "props": {"Brightness": 2, "Range": 60, "Angle": 45, "Color": "#94e0ff", "Face": "Bottom"}},
                   {"class": "Beam", "a0": [0, 110, 0], "a1": [0, 130, -50], "group": "Landmarks",
                    "props": {"Width0": 12, "Width1": 30, "FaceCamera": True, "Texture": ""}}],
            "framing": {"heroStation": 60, "note": "test"},
        },
    })


def builder_dino4_nodes() -> list[route.Node]:
    """The current controlNodes of builder_dino4.luau (the gameplay contract the plan must preserve)."""
    src = (ROOT / "builder_dino4.luau").read_text()
    block = src[src.index("local controlNodes"):src.index("local lowScale")]
    n = r"(-?[\d.]+)"
    pat = re.compile(r"pos = Vector3\.new\(%s, %s, %s\), bank = %s, flex = Vector3\.new\(%s, %s, %s\)" % ((n,) * 7))
    return [route.Node(tuple(map(float, m[0:3])), float(m[3]), tuple(map(float, m[4:7]))) for m in pat.findall(block)]
