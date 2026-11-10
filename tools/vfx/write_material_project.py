#!/usr/bin/env python3
"""Write the MaterialService block of default.project.json from material sets (assets/materials/*/variants.json +
uploaded.json). MaterialVariants are static instances, so live game scripts never need to set texture properties.
Each variant also gets its engine TexturePack when assets/materials/texture_packs.json holds one for its exact
ColorMap|NormalMap pair (tools/vfx/capture_texture_packs.py): live clients load a MaterialVariant only through its pack,
and a rojo-built place has none unless it is written here (hunt:texpack 2026-10-19).
Usage: write_material_project.py"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
proj_p = ROOT / "default.project.json"
proj = json.loads(proj_p.read_text())
ms = {"$className": "MaterialService"}
packs_p = ROOT / "assets" / "materials" / "texture_packs.json"
packs = json.loads(packs_p.read_text()).get("packs", {}) if packs_p.exists() else {}
no_pack = []
# Variants a map uses as a terrain override get the neutral map (see below); found from the plans themselves.
terrain_variants = set()
for plan in sorted((ROOT / "map").glob("*/plan.json")):
    mats = (json.loads(plan.read_text()).get("skyrally") or {}).get("materials") or {}
    terrain_variants |= set((mats.get("terrainOverrides") or {}).values())
for vset in sorted((ROOT / "assets" / "materials").glob("*/variants.json")):
    up = vset.parent / "tiles" / "uploaded.json"
    if not up.exists():
        print("skip (textures not uploaded yet):", vset.parent.name)
        continue
    ids = json.loads(up.read_text())
    for name, v in json.loads(vset.read_text()).items():
        ms[name] = {"$className": "MaterialVariant", "$properties": {
            "BaseMaterial": v["base"],
            # Terrain variants use the neutral map (texture / tint, tools/vfx/neutralize.py): the terrain colour carries
            # the hue so low-graphics devices that drop terrain textures still show the right material colour.
            # An explicit `colorMap` (a tile name in the set's uploaded.json) overrides the derived choice.
            "ColorMap": f"rbxassetid://{ids[v['colorMap']]['id']}" if v.get('colorMap') in ids else
            f"rbxassetid://{ids[v['tex'] + ('_ncolor' if (v.get('neutral') or name in terrain_variants) and v['tex'] + '_ncolor' in ids else '_color')]['id']}",
            "NormalMap": f"rbxassetid://{ids[v['tex'] + '_normal']['id']}",
            "StudsPerTile": v["studsPerTile"],
        }}
        props = ms[name]["$properties"]
        pack = (packs.get(props["ColorMap"] + "|" + props["NormalMap"]) or {}).get("pack")
        if pack:
            props["TexturePack"] = pack
        else:
            no_pack.append(name)
proj["tree"]["MaterialService"] = ms
proj_p.write_text(json.dumps(proj, indent=2) + "\n")
print("MaterialService variants:", [k for k in ms if not k.startswith("$")])
if no_pack:
    print("WARN no TexturePack (live clients will not load these; open the place in the lane Studio, then run "
          "tools/vfx/capture_texture_packs.py):", no_pack)
