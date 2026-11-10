#!/usr/bin/env python3
"""Studio-only QA hooks for the systems verification campaign (docs/VERIFY_CAMPAIGN_V33.md TG-1, TG-2, TG-4, TG-6;
shared/QAHooksRules, server/SaveService, server/LiveOps, server/QAClock). Needs a Play session in the lane's own Studio
window; every hook is a workspace attribute read only when RunService:IsStudio() (a live server ignores them all).

  qa_hooks.py fault load|save|none [count]   TG-1: the mock/DataStore profile load or save fails (count = fail N calls, then
                                             recover on its own). Watch player attributes SaveState/SaveMessage, [SkyRally][SAVE]
  qa_hooks.py saveas <id>                    TG-4: the NEXT player to join loads (and saves) as stored profile id <id>, one-shot
                                             (mock backend only). Join, leave, set it again, rejoin: the same profile
  qa_hooks.py liveops memory on|off          TG-2: LiveOps flags in an in-memory row (automatic when the Studio probe fails)
  qa_hooks.py utc <epoch|ISO|HH:MM:SS>       TG-6: the economy and the Storm Cup read UTC as that moment (time then runs on);
                                             HH:MM:SS = today's UTC date at that time, e.g. utc 12:29:50 -> cup due at :30
  qa_hooks.py utc off                        back to the real clock
  qa_hooks.py timing [label]                 TG-6: print this server's schedule+stock signature, save it to
                                             evidence/timing/<label>.txt; with two saved labels use  timing-compare A B
  qa_hooks.py timing-compare A B             exits 0 when the two saved signatures are byte-identical
  qa_hooks.py status                         the current values of all hooks

Equivalent lane snippets (dm="Server"): workspace:SetAttribute('QASaveFault','load'), ('QASaveFaultCount',2),
('QASaveAs',123456), ('QALiveOpsMemory',true), ('QAUtcAt',1766923790), ('QATimingDump',true) then read
workspace:GetAttribute('QATimingSignature')."""
import datetime as dt
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVID = ROOT / "evidence" / "timing"


def parse_utc(text, today=None):
    """epoch seconds | ISO 8601 | HH:MM[:SS] (today's UTC date) -> epoch seconds (int). ValueError on junk."""
    t = text.strip()
    if re.fullmatch(r"\d{9,11}(\.\d+)?", t):
        return int(float(t))
    m = re.fullmatch(r"(\d{1,2}):(\d{2})(?::(\d{2}))?", t)
    if m:
        h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
        if h > 23 or mi > 59 or s > 59:
            raise ValueError("bad time of day: " + text)
        day = today or dt.datetime.now(dt.timezone.utc)
        return int(day.replace(hour=h, minute=mi, second=s, microsecond=0).timestamp())
    try:
        d = dt.datetime.fromisoformat(t.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError("not an epoch, ISO time or HH:MM:SS: " + text)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return int(d.timestamp())


def build(argv, today=None):
    """argv -> list of (attribute, value) pairs to set on workspace (value None clears). SystemExit(msg) on bad input."""
    if not argv:
        raise SystemExit(__doc__)
    cmd, rest = argv[0], argv[1:]
    if cmd == "fault":
        if not rest or rest[0] not in ("load", "save", "none"):
            raise SystemExit("fault needs load, save or none")
        out = [("QASaveFault", None if rest[0] == "none" else rest[0]), ("QASaveFaultCount", None)]
        if len(rest) > 1:
            if not rest[1].isdigit() or not 1 <= int(rest[1]) <= 1000:
                raise SystemExit("count must be a whole number 1..1000")
            out[1] = ("QASaveFaultCount", int(rest[1]))
        return out
    if cmd == "saveas":
        if len(rest) != 1 or not re.fullmatch(r"-?\d{1,15}", rest[0]) or int(rest[0]) == 0:
            raise SystemExit("saveas needs a non-zero whole profile id")
        return [("QASaveAs", int(rest[0]))]
    if cmd == "liveops":
        if len(rest) != 2 or rest[0] != "memory" or rest[1] not in ("on", "off"):
            raise SystemExit("liveops memory on|off")
        return [("QALiveOpsMemory", True if rest[1] == "on" else None)]
    if cmd == "utc":
        if len(rest) != 1:
            raise SystemExit("utc needs <epoch|ISO|HH:MM:SS> or off")
        if rest[0] == "off":
            return [("QAUtcAt", None)]
        try:
            return [("QAUtcAt", parse_utc(rest[0], today))]
        except ValueError as e:
            raise SystemExit(str(e))
    raise SystemExit("unknown command " + cmd)


def lua_literal(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "\\'") + "'"


def lua_for(pairs):
    return "; ".join("workspace:SetAttribute('%s', %s)" % (a, lua_literal(v)) for a, v in pairs) + "; return 'ok'"


def same_signature(a, b):
    return a.strip() == b.strip()


STATUS = ("local t = {} for _, n in {'QASaveFault','QASaveFaultCount','QASaveAs','QALiveOpsMemory','QAUtcAt','SaveBackend',"
          "'QATimingSignature'} do table.insert(t, n .. '=' .. tostring(workspace:GetAttribute(n))) end return table.concat(t, ' ')")


def main(argv):
    import lane  # noqa: E402  (only needed when talking to Studio)
    if argv and argv[0] == "timing-compare":
        if len(argv) != 3:
            raise SystemExit("timing-compare needs two labels")
        a, b = (EVID / (argv[1] + ".txt")).read_text(), (EVID / (argv[2] + ".txt")).read_text()
        ok = same_signature(a, b)
        print("IDENTICAL" if ok else "DIFFERENT\n  A: %s\n  B: %s" % (a.strip(), b.strip()))
        return 0 if ok else 1
    if argv and argv[0] == "status":
        print(lane.luau(STATUS, dm="Server", name="qa_status"))
        return 0
    if argv and argv[0] == "timing":
        label = argv[1] if len(argv) > 1 else "run"
        lane.luau("workspace:SetAttribute('QATimingDump', true) task.wait(0.5) return 'ok'", dm="Server", name="qa_dump")
        sig = lane.luau("return tostring(workspace:GetAttribute('QATimingSignature'))", dm="Server", name="qa_sig").strip()
        EVID.mkdir(parents=True, exist_ok=True)
        (EVID / (label + ".txt")).write_text(sig + "\n")
        print(sig)
        return 0
    pairs = build(argv)
    print(lane.luau(lua_for(pairs), dm="Server", name="qa_hooks"))
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main(sys.argv[1:]))
