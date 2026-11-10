#!/usr/bin/env python3
"""Studio-only QA steering (shared/QASteerRules): drives the LOCAL vehicle's AutoPilot along a named alternate line, or holds an
exact steer / throttle, by setting workspace attributes through lane.luau. Live servers clear and ignore them.

  qa_steer.py follow Alt2 [--dm=Server]   AutoPilot = true, QAFollowLine = "Alt2" (a line id, or its style: cliff, span, ...)
  qa_steer.py steer 0.4                   QASteer = 0.4   (-1..1; "off" clears)
  qa_steer.py throttle 1                  QAThrottle = 1  (-1..1; "off" clears)
  qa_steer.py off                         clears QAFollowLine, QASteer, QAThrottle and AutoPilot
  qa_steer.py                             prints the current values

Run during a Play session (attributes are on workspace; Server DataModel replicates them to the client). Watch the console for
"[SkyRally][QASTEER]" lines (join / rejoin per line) and read the RouteBranch player attribute / Station for the verdict."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ATTRS = ("QAFollowLine", "QASteer", "QAThrottle", "AutoPilot")


def build(args):
    """Returns the Luau snippet for argv-style args (pure, so it is testable without Studio)."""
    if not args:
        return "return " + " .. ' ' .. ".join(f"'{a}=' .. tostring(workspace:GetAttribute('{a}'))" for a in ATTRS)
    cmd, rest = args[0], args[1:]
    if cmd == "off":
        sets = "".join(f"workspace:SetAttribute('{a}', nil) " for a in ATTRS)
        return sets + "return 'qa_steer cleared'"
    if cmd == "follow" and len(rest) == 1 and rest[0].replace("_", "").isalnum():
        return (f"workspace:SetAttribute('AutoPilot', true) workspace:SetAttribute('QAFollowLine', '{rest[0]}') "
                "return 'QAFollowLine=' .. tostring(workspace:GetAttribute('QAFollowLine'))")
    if cmd in ("steer", "throttle") and len(rest) == 1:
        attr = "QASteer" if cmd == "steer" else "QAThrottle"
        if rest[0] == "off":
            val = "nil"
        else:
            val = repr(max(-1.0, min(1.0, float(rest[0]))))
        return f"workspace:SetAttribute('{attr}', {val}) return '{attr}=' .. tostring(workspace:GetAttribute('{attr}'))"
    raise SystemExit(__doc__)


if __name__ == "__main__":
    argv = [a for a in sys.argv[1:] if not a.startswith("--dm=")]
    dm = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--dm=")), "Server")
    code = build(argv)
    import lane  # noqa: E402
    print(lane.luau(code, dm=dm, name="qa_steer"))
