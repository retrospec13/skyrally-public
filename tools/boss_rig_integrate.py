#!/usr/bin/env python3
"""Upload a rigged boss GLB (assets/models/bosses/<key>/rig/out/rigged.glb, canonical frame: faces Roblox -Z, feet at 0)
through win/upload_model_skyrally.ps1 (validated Use grant) and point BossConfig at it with yawOffset 0.
Usage: boss_rig_integrate.py <key> <ZONE>"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

key, zone = sys.argv[1], sys.argv[2]
rel = f"assets/models/bosses/{key}/rig/out/rigged.glb"
lane.put(lane.ROOT / rel, rel)
pc = lane.PCWIN + "\\" + rel.replace("/", "\\")
log = lane.ssh(f"powershell -NoProfile -ExecutionPolicy Bypass -File {lane.PCWIN}\\win\\upload_model_skyrally.ps1 -Path {pc} -Name SkyRally_boss_{key}_rigged",
               check=False, timeout=1200)
mid = re.search(r"MODEL_ASSET_ID=(\d+)", log)
if not (mid and re.search(r"GRANT_STATUS=\d+ ok=True", log)):
    sys.exit("UPLOAD_FAILED " + log[-600:])
asset = mid.group(1)
cfg = lane.ROOT / "src/shared/BossConfig.luau"
s = cfg.read_text()
block = re.search(r"\n\t" + zone + r" = \{.*?\n\t\},", s, re.S)
if not block:
    sys.exit("no BossConfig block for " + zone)
b = block.group(0)
nb = re.sub(r"model = (nil|\d+),", f"model = {asset},", b)
nb = re.sub(r"yawOffset = -?\d+,", "yawOffset = 0,", nb)
cfg.write_text(s.replace(b, nb))
print(f"RIGGED {key} {zone} model={asset}")
