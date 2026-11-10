#!/usr/bin/env python3
"""Studio-only QA: give the local player an item, or put a bot ahead of the player (server/QATools, shared/QAToolRules).
Needs a Play session in the lane's own Studio window (RunService:IsStudio() on the server: the helpers do not exist in a
live server). Sets a workspace attribute from the Server context; QATools applies it to the first player, clears it and
writes the answer to workspace attribute QAResult ("ok:red:3", "ok:<bot name>:60" or "error:<reason>").

  give_item.py red:3          the player now holds a level-3 red item (color[:level], level 1..3, default 1)
  give_item.py green          a level-1 green (trap) item
  give_item.py yellow:3       level-3 yellow (shield); blue = boost, red = missile, rainbow = magnet
  give_item.py storm_bolt:2   items v4 specials by id (docs/design/ITEMS_V4.md): rocket_rush, golden_wings,
                              orbit_missiles, storm_bolt, boom_bomb, gift_box, frost_shot, coin_burst, bubble_guard
  give_item.py ahead 60       a bot 60 studs ahead of the player on the line (15..2000)
  give_item.py ahead 120:-8   120 studs ahead, placed 8 studs left (first frame only; the bot returns to its lane)

Colors: red, blue, yellow, green, rainbow, plus the nine special ids above. Equivalent lane.luau snippet (dm="Server"):
  workspace:SetAttribute('QAGiveItem', 'red:3')   or   workspace:SetAttribute('QABotAhead', '60')
then read workspace:GetAttribute('QAResult'). Never touches the race, walls, adhesion, barriers, kill volumes or rescue."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

COLORS = {"red", "blue", "yellow", "green", "rainbow"}
SPECIALS = {"rocket_rush", "golden_wings", "orbit_missiles", "storm_bolt", "boom_bomb", "gift_box", "frost_shot",
            "coin_burst", "bubble_guard"}


def build(argv):
    if not argv:
        raise SystemExit(__doc__)
    if argv[0] == "ahead":
        if len(argv) < 2:
            raise SystemExit("ahead needs a distance in studs, e.g. ahead 60")
        return "QABotAhead", argv[1]
    spec = argv[0].lower()
    if spec.split(":")[0] not in COLORS | SPECIALS:
        raise SystemExit("unknown item %r (red, blue, yellow, green, rainbow, or a special: %s)"
                         % (spec, ", ".join(sorted(SPECIALS))))
    return "QAGiveItem", spec


def main(argv):
    attr, value = build(argv)
    code = (
        "workspace:SetAttribute('QAResult', nil)\n"
        "workspace:SetAttribute('%s', '%s')\n"
        "task.wait(0.5)\n"
        "return tostring(workspace:GetAttribute('QAResult'))\n" % (attr, value)
    )
    res = lane.luau(code, dm="Server", name="give_item")
    print(res)
    return 0 if str(res).strip().startswith("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
