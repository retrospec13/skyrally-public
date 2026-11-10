#!/usr/bin/env python3
"""Studio-only QA switch for per-group races (economy v3 phase 2b): sets or clears the workspace attribute QAPerGroup
in the lane Studio's EDIT DataModel. shared/RaceFlowRules reads it ONCE, when first required (server boot, each
client's first require), and only when RunService:IsStudio(): the next Play / multiplayer test runs with
RaceFlowRules.PER_GROUP on, no source edit. A live server ignores it. Stop Play first; the change applies to the next
session only. The server logs "[SkyRally][GROUPS] per-group races ON (Studio QA switch QAPerGroup)" and sets
workspace.PerGroupLive; a client that read the flag differently warns "[SkyRally][GROUPS] PER_GROUP mismatch".

  qa_pergroup.py on        QAPerGroup = true  (next Play: per-group races)
  qa_pergroup.py off       QAPerGroup cleared (next Play: the single race, as shipped)
  qa_pergroup.py           print the current value

Then the two-client check: python3 tools/mp_check.py pergroup dino4 2  (docs/STUDIO_ROUND_V22.md section 1)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

arg = sys.argv[1] if len(sys.argv) > 1 else ""
if arg not in ("", "on", "off"):
    raise SystemExit(__doc__)
if arg == "on":
    code = "workspace:SetAttribute('QAPerGroup', true) return 'QAPerGroup=' .. tostring(workspace:GetAttribute('QAPerGroup'))"
elif arg == "off":
    code = "workspace:SetAttribute('QAPerGroup', nil) return 'QAPerGroup=' .. tostring(workspace:GetAttribute('QAPerGroup'))"
else:
    code = "return 'QAPerGroup=' .. tostring(workspace:GetAttribute('QAPerGroup'))"
print(lane.luau(code, dm="Edit", name="qa_pergroup"))
