#!/usr/bin/env python3
"""Run one Tripo image-to-model task for a props_v3 asset on the PC (tripo_prop.py), fetch tripo_task.json + raw GLB.
Usage: tripo_props_v3.py <name> <face_limit> [texture_quality=standard]"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402
ROOT = Path(__file__).resolve().parents[2]
n, fl = sys.argv[1], sys.argv[2]
tq = sys.argv[3] if len(sys.argv) > 3 else "standard"
w = lane.PCWIN + "\\out\\props_v3"
d = ROOT / "assets/models/props_v3" / n
lane.ssh(f'cmd /c "if not exist {w}\\{n} mkdir {w}\\{n}"', check=False)
lane.put(d / "concept.png", f"out/props_v3/{n}/concept.png")
out = lane.ssh(f'cmd /c "cd /d {lane.PCWIN}\\out\\art_v3_arch && py tripo_prop.py model {n} {w}\\{n}\\concept.png {w}\\{n} face_limit={fl} texture_quality={tq} > {w}\\{n}\\tripo.log 2>&1 & type {w}\\{n}\\tripo.log"', check=False, timeout=3000)
print(out[-1500:])
for f in ("tripo_task.json", "model_url.glb", "rendered_image_url.webp"):
    try:
        lane.get(f"out/props_v3/{n}/{f}", d / ("tripo_raw.glb" if f.endswith("glb") else f))
    except Exception as e:  # noqa: BLE001
        print("FETCH_FAIL", f, str(e)[:150])
