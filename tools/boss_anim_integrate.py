#!/usr/bin/env python3
"""Upload a re-rigged boss (assets/models/bosses/<key>/anim/out/rigged.glb: neutral-pose rest, the GLB that the baked
clip module src/shared/bossclips/<Name>.luau was made from) through win/upload_model_skyrally.ps1 (validated Use grant)
and point the zone's BossConfig row at it: model id, yawOffset 180 (rigged GLBs import turned round), pitch and length.
Usage: boss_anim_integrate.py <key> <ZONE> <pitch> <length>"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

key, zone, pitch, length = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
rel = f"assets/models/bosses/{key}/anim/out/rigged.glb"
lane.put(lane.ROOT / rel, rel)
pc = lane.PCWIN + "\\" + rel.replace("/", "\\")
log = lane.ssh(f"powershell -NoProfile -ExecutionPolicy Bypass -File {lane.PCWIN}\\win\\upload_model_skyrally.ps1 -Path {pc} -Name SkyRally_boss_{key}_anim",
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
nb = re.sub(r"yawOffset = -?\d+,", "yawOffset = 180,", nb)
nb = re.sub(r"length = [\d.]+,", f"length = {length:g},", nb)
if re.search(r"pitch = [-\d.]+,", nb):
    nb = re.sub(r"pitch = [-\d.]+,", f"pitch = {pitch:g},", nb)
else:
    nb = nb.replace("yawOffset = 180,", f"yawOffset = 180, pitch = {pitch:g},")
cfg.write_text(s.replace(b, nb))
print(f"INTEGRATED {key} {zone} model={asset} pitch={pitch:g} length={length:g}")
