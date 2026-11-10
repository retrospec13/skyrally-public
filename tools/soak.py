#!/usr/bin/env python3
"""Soak test driver (audit T1-12), for the lane's OWN Studio window only. Needs the owner's per-task order for a Studio
run (Win PC policy); nothing here runs unless you invoke it, and `analyze` is offline.

Loops hub -> race -> results -> hub across maps for N cycles with bots (AutoPilot) and samples, at every step, the SERVER
(memory, instance counts, memory tags incl. Signals, heartbeat, data kbps, error lines) and every CLIENT (frame time
mean/p95/worst, memory, instances, kbps, error lines). Leak detection (monotonic growth after warm-up) and the JSON +
markdown report are in tools/soak_analysis.py. The Studio side is server/QASoak (workspace attribute QASoakRun, Studio
only; protocol names in shared/SoakRules) and the QASoak branch of client/QAMultiplayerClient.

  soak.py solo [--cycles 6] [--maps dino4,snow1,island2,forest1,space4] [--race-secs 0] [--race-timeout 420]
               [--frame-secs 3] [--timeout S]
        Play in the lane window (one client), UnlockAll + AutoPilot, runs the loop, polls the samples, stops Play.
  soak.py mp   [--players 2] (same options)
        StudioTestService:ExecuteMultiplayerTestAsync with N real clients (server/QAMultiplayer scenario "soak"); the
        samples come back in the EndTest JSON, so connection and traffic figures include real remote clients.
  soak.py analyze <soak.json> [--thresholds file.json]    re-judge a saved run, rewrite its report.

--race-secs 0 plays each race through to the results (the real hub -> race -> results -> hub loop); a value >0 leaves
the race that many seconds after GO (faster, skips the results sample). Output: evidence/soak/soak_<mode>_<commit>.json
and .md. Exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE/error. Stop Play first; do not run during filming or next to other lanes.
Storm Cup is not part of this loop (launch-switch territory); run a cup by hand between soaks and compare the hub rows."""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import soak_analysis  # noqa: E402

RUN_ATTR = "QASoakRun"
PROGRESS_ATTR = "QASoakProgress"
SAMPLE_ATTR_PREFIX = "QASoakS"
DEFAULT_MAPS = ["dino4", "snow1", "island2", "forest1", "space4"]


def lane_mod():
    import lane  # lazy: analyze must work on a machine with no lane tooling
    return lane


def build_config(a):
    return {"cycles": a.cycles, "maps": [m for m in a.maps.split(",") if m], "raceSecs": a.race_secs,
            "raceTimeout": a.race_timeout, "frameSecs": a.frame_secs}


def lua_table(v):
    """Python dict/list/str/number -> Luau literal (for the multiplayer test args)."""
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (k, lua_table(x)) for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "{" + ",".join(lua_table(x) for x in v) + "}"
    if isinstance(v, str):
        return json.dumps(v)
    return str(v)


def write_report(mode, cfg, samples, extra=None):
    lane = None
    try:
        lane = lane_mod()
        commit, utc, root = lane.git_head(), lane.utc(), lane.ROOT
    except Exception:  # offline analysis
        commit, utc, root = "offline", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), Path(__file__).resolve().parents[1]
    report = {"meta": {"mode": mode, "commit": commit, "utc": utc}, "config": cfg, "samples": samples}
    report.update(extra or {})
    report["analysis"] = soak_analysis.analyze(samples, maps=cfg.get("maps"))
    out = root / "evidence" / "soak" / ("soak_%s_%s.json" % (mode, str(commit)[:7]))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1))
    out.with_suffix(".md").write_text(soak_analysis.markdown(report))
    print(soak_analysis.markdown(report).split("## Per-step table")[0])
    print(out)
    print(out.with_suffix(".md"))
    return report


def exit_code(report):
    return {"PASS": 0, "FAIL": 1}.get(report["analysis"]["verdict"], 2)


POLL = r"""
local out, i = {}, %d
while true do
  local v = workspace:GetAttribute('QASoakS' .. i)
  if v == nil then break end
  table.insert(out, v)
  i += 1
end
return game:GetService('HttpService'):JSONEncode({ progress = workspace:GetAttribute('QASoakProgress'), next = i, samples = out })
"""


def parse_json(s):
    s = str(s)
    i, j = s.find("{"), s.rfind("}")
    return json.loads(s[i:j + 1]) if i >= 0 and j > i else None


def run_solo(a):
    lane = lane_mod()
    cfg = build_config(a)
    steps = a.cycles * len(cfg["maps"])
    budget = a.timeout or (steps * (a.race_timeout + 240) + 600)
    lane.luau("workspace:SetAttribute('UnlockAll', true) workspace:SetAttribute('AutoPilot', true) return 1", dm="Edit", name="soak_flags")
    lane.play(True)
    samples, nxt, progress = [], 1, ""
    try:
        time.sleep(40)  # hub boot; QASoak itself waits for the hub before the baseline
        started = lane.luau("workspace:SetAttribute('%s', '%s') return 'set'" % (RUN_ATTR, json.dumps(cfg)), dm="Server", name="soak_start")
        print(started)
        t0 = time.time()
        while time.time() - t0 < budget:
            time.sleep(15)
            try:
                got = parse_json(lane.luau(POLL % nxt, dm="Server", name="soak_poll"))
            except Exception as e:  # the Studio bridge drops under load: keep polling
                print("poll error", e)
                continue
            if not got:
                continue
            for raw in got["samples"]:
                samples.append(json.loads(raw))
            nxt = got["next"]
            progress = str(got.get("progress"))
            print("%ds %s (%d samples)" % (time.time() - t0, progress, len(samples)), flush=True)
            if progress.startswith("done") or progress.startswith("error"):
                break
        else:
            progress = "error:driver_timeout"
    finally:
        lane.play(False)
    extra = {"progress": progress}
    if progress.startswith("error"):
        print("SOAK ERROR:", progress)
    return write_report("solo", cfg, samples, extra)


MP_START = r"""
local SS = game:GetService('ServerStorage')
if SS:GetAttribute('QAMPToken') == '%(token)s' then return 'started (already)' end
SS:SetAttribute('QAMPToken', '%(token)s')
SS:SetAttribute('QAMPResult', nil)
task.spawn(function()
  local sts = game:GetService('StudioTestService')
  local ok, r = pcall(function()
    return sts:ExecuteMultiplayerTestAsync(%(players)d, { qa = 'mp', scenario = 'soak', key = 'hub0', players = %(players)d, token = '%(token)s', soak = %(soak)s })
  end)
  SS:SetAttribute('QAMPResult', if ok then tostring(r) else ('{"verdict":"ERROR","token":"%(token)s","why":' .. string.format('%%q', tostring(r)) .. '}'))
end)
return 'started'
"""


def run_mp(a):
    lane = lane_mod()
    cfg = build_config(a)
    steps = a.cycles * len(cfg["maps"])
    budget = a.timeout or (steps * (a.race_timeout + 240) + 900)
    token = "soak-%d" % int(time.time())
    code = MP_START % {"token": token, "players": a.players, "soak": lua_table(cfg)}
    for _ in range(8):
        started = lane.luau(code, dm="Edit", name="soak_mp_start")
        print(started)
        if "started" in str(started):
            break
        time.sleep(20)
    else:
        sys.exit("NOT STARTED: the Studio bridge did not take the start call")
    t0, raw = time.time(), None
    while time.time() - t0 < budget:
        time.sleep(30)
        try:
            out = str(lane.luau("return tostring(game:GetService('ServerStorage'):GetAttribute('QAMPResult'))", dm="Edit", name="soak_mp_poll")).strip()
        except Exception as e:
            print("poll error", e)
            continue
        i = out.find("{")
        if i >= 0 and token in out:
            raw = out[i:]
            break
        print("%ds waiting" % (time.time() - t0), flush=True)
    if raw is None:
        sys.exit("TIMEOUT: no EndTest result")
    res = json.loads(raw)
    print("EndTest:", res.get("verdict"), res.get("why"))
    cfg["players"] = a.players
    return write_report("mp", cfg, res.get("soak") or [], {"endTest": {k: res.get(k) for k in ("verdict", "why", "seconds", "errors", "warnings", "clientErrors", "build")}})


def run_analyze(a):
    data = json.loads(Path(a.file).read_text())
    thresholds = json.loads(Path(a.thresholds).read_text()) if a.thresholds else None
    data["analysis"] = soak_analysis.analyze(data["samples"], maps=data.get("config", {}).get("maps"), thresholds=thresholds)
    out = Path(a.file)
    out.write_text(json.dumps(data, indent=1))
    out.with_suffix(".md").write_text(soak_analysis.markdown(data))
    print(soak_analysis.markdown(data).split("## Per-step table")[0])
    return data


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("solo", "mp"):
        s = sub.add_parser(name)
        s.add_argument("--cycles", type=int, default=6)
        s.add_argument("--maps", default=",".join(DEFAULT_MAPS))
        s.add_argument("--race-secs", type=float, default=0)
        s.add_argument("--race-timeout", type=float, default=420)
        s.add_argument("--frame-secs", type=float, default=3)
        s.add_argument("--timeout", type=int, default=0, help="driver wall-clock budget in seconds (default derived)")
        if name == "mp":
            s.add_argument("--players", type=int, default=2)
    an = sub.add_parser("analyze")
    an.add_argument("file")
    an.add_argument("--thresholds")
    a = p.parse_args(argv)
    rep = {"solo": run_solo, "mp": run_mp, "analyze": run_analyze}[a.cmd](a)
    return exit_code(rep)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
