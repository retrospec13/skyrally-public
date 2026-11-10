"""S2b: per-key approach lines for win/key_pilot.js (goal=qa route=...). Data in tools/key_approach.json."""
import json
from pathlib import Path

DATA = Path(__file__).resolve().parent / "key_approach.json"


def routes():
    return {k: v for k, v in json.loads(DATA.read_text()).items() if not k.startswith("_")}


def route_arg(track_id):
    """The pilot's ' route=x:y:z:vmax/...' argument for a track ('' when it has no approach line)."""
    entry = routes().get(track_id.upper())
    if not entry:
        return ""
    return " route=" + "/".join(":".join(f"{v:g}" for v in w) for w in entry["route"])
