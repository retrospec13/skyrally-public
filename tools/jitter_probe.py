#!/usr/bin/env python3
"""Opponent jitter probe (docs/audits/opponent_jitter.md) in the lane's own Studio window. Measures, every render frame
after the camera and RacerView have moved, each other racer's hull offset from the camera and its viewport pixel, and
reports the frame-to-frame second differences (Shared.JitterProbe): p50/p95/p99/max in studs and pixels per kind
(bot/player x plane/car x anchored/physics). A racer moving smoothly relative to the chase camera scores near 0.

  bots  Play solo; request `key` from the hub (UnlockAll, AutoPilot drive the player's vehicle), wait for GO + 20 s, record
        on the client for --secs. Opponents are the 7 bots.
  mp    StudioTestService multiplayer test (as tools/mp_check.py): one local server + `players` real clients race `key`;
        20 s after GO every client records for --secs and sends its summary (server/QAMultiplayer scenario "jitter").
        Each client sees the other player(s) and the bots.

Run it on the build before the fix (stage-v21) and after (jitter-fix) with the same key and compare the p95/p99 rows.
Pass mark proposed in the audit: bot rows p95 < 0.05 studs and p99 < 0.3 studs at 60 fps; player rows recorded for
the remote-player decision. Since remote-smooth (docs/audits/opponent_stream.md "Remote players") the mp mode also
prints each client's remote-player row (player_<plane|car>_physics: the other human as this client draws him) with the
client's remote stream counters (drawn / blend / engine frames, packets, cuts, own poses sent) and the server's relay
counters (accepted, relayed, culled, refused by reason); pass mark: remote fit p95 < 0.05 with drawn >> engine.
Since opp-smooth the bot pass mark reads the `fit` and studsT columns (the raw studs
columns also count frame pacing, see docs/audits/opponent_stream.md), and `stream draws` must show the bots drawn from
the stamped stream (stream >> fallback). Writes evidence/jitter/jitter_<mode>_<key>_<commit>.json and prints a table.
Usage: jitter_probe.py bots|mp [key=dino4] [--secs=10] [--players=2] [--timeout=600]"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
mode = args[0] if args else "bots"
key = args[1] if len(args) > 1 else "dino4"
secs = int(opts.get("secs", "10"))
players = int(opts.get("players", "2"))
timeout = int(opts.get("timeout", "600"))
TRACK_ID = {"dino4": "DINO-4", "snow1": "SNOW-1", "island2": "ISLAND-2", "forest1": "FOREST-1", "space4": "SPACE-4"}

SAMPLE = r"""
local JitterProbe = require(game:GetService('ReplicatedStorage'):WaitForChild('Shared'):WaitForChild('JitterProbe'))
return game:GetService('HttpService'):JSONEncode(JitterProbe.run(%d))
"""

START_MP = r"""
local SS = game:GetService('ServerStorage')
if SS:GetAttribute('QAMPToken') == '%s' then return 'started (already)' end
SS:SetAttribute('QAMPToken', '%s')
SS:SetAttribute('QAMPResult', nil)
task.spawn(function()
  local sts = game:GetService('StudioTestService')
  local ok, r = pcall(function()
    return sts:ExecuteMultiplayerTestAsync(%d, { qa = 'mp', scenario = 'jitter', key = '%s', players = %d, token = '%s', jitterSecs = %d })
  end)
  SS:SetAttribute('QAMPResult', if ok then tostring(r) else ('{"verdict":"ERROR","token":"%s","why":' .. string.format('%%q', tostring(r)) .. '}'))
end)
return 'started'
"""


def json_of(text):
    s = str(text)
    i, j = s.find("{"), s.rfind("}")
    return json.loads(s[i:j + 1]) if i >= 0 else {"raw": s[:300]}


def wait_race_go():
    """Solo: from the hub, request `key` and wait until it is loaded and GO has passed."""
    lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{TRACK_ID[key]}','race') return 1",
              dm="Client", name="jp_req")
    t0 = time.time()
    while time.time() - t0 < 180:
        time.sleep(5)
        st = lane.luau("return tostring(workspace:GetAttribute('ActiveTrackId')) .. ' ' .. tostring(workspace:GetAttribute('TrackSwitching'))"
                       " .. ' ' .. tostring((workspace:GetAttribute('RaceGoTime') or 0) < workspace:GetServerTimeNow())",
                       dm="Client", name="jp_state")
        if TRACK_ID[key] in str(st) and "false true" in str(st):
            return True
    return False


def run_bots():
    lane.luau("workspace:SetAttribute('UnlockAll', true) workspace:SetAttribute('AutoPilot', true) return 1", dm="Edit", name="jp_flags")
    lane.play(True)
    try:
        time.sleep(30)
        if not wait_race_go():
            sys.exit(f"race {key} did not reach GO")
        time.sleep(20)  # the field strung out, the grid merge done
        return {"client": json_of(lane.luau(SAMPLE % secs, dm="Client", name="jp_sample", timeout=secs + 120))}
    finally:
        lane.play(False)


def run_mp():
    token = f"jitter-{key}-{int(time.time())}"
    for _ in range(8):
        started = lane.luau(START_MP % (token, token, players, key, players, token, secs, token), dm="Edit", name="jp_mp_start")
        print(started)
        if "started" in str(started):
            break
        time.sleep(20)
    else:
        sys.exit("NOT STARTED: the Studio bridge did not take the start call")
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(20)
        try:
            out = str(lane.luau("return tostring(game:GetService('ServerStorage'):GetAttribute('QAMPResult'))", dm="Edit", name="jp_mp_poll"))
        except Exception as e:  # the bridge drops under load; keep polling
            print("poll error", e)
            continue
        i = out.find("{")
        if i >= 0 and token in out:
            res = json.loads(out[i:out.rfind("}") + 1])
            print("verdict", res.get("verdict"), res.get("why"))
            return res.get("jitter") or {}, res.get("relay")
    sys.exit("TIMEOUT: no multiplayer result")


def remote_rows(clients, relay):
    """The remote-player rows (mp): each client's view of the other human(s), with the stream counters."""
    rows = []
    for name, r in clients.items():
        for kind, k in sorted((r.get("kinds") or {}).items()):
            if kind.startswith("player_"):
                ft, st, s = k.get("fit") or {}, k.get("studsT") or {}, k.get("studs") or {}
                rows.append(f"{name:10} REMOTE {kind:22} fit p95 {ft.get('p95', 0):.3f} p99 {ft.get('p99', 0):.3f} | studsT p95 "
                            f"{st.get('p95', 0):.3f} p99 {st.get('p99', 0):.3f} | raw p95 {s.get('p95', 0):.3f} p99 {s.get('p99', 0):.3f}"
                            f" | {'PASS' if ft.get('n', 0) and ft.get('p95', 1) < 0.05 else 'FAIL'} (fit p95 < 0.05)")
        rm = r.get("remote")
        if rm is not None:
            rows.append(f"{name:10} remote stream {rm}")
    if relay is not None:
        rows.append(f"server     relay {relay}")
    return rows


def main():
    relay = None
    if mode == "bots":
        clients = run_bots()
    else:
        clients, relay = run_mp()
    out = lane.ROOT / "evidence" / "jitter" / f"jitter_{mode}_{key}_{lane.git_head()[:7]}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"commit": lane.git_head(), "utc": lane.utc(), "mode": mode, "key": key, "secs": secs,
                               "clients": clients, "relay": relay}, indent=1))
    # studs/px: raw second difference (includes frame pacing: relative speed x frame-time change). studsT/pxT: the
    # same with each frame at its own time (Shared.JitterProbe.secondDiffT): no frame pacing, but the true relative
    # acceleration of racer and camera is still in it. fit: the racer's world position off a parabola through its own
    # last 7 frames (JitterProbe.fitResidual): the opponent's own jitter alone (docs/audits/opponent_stream.md).
    print(f"{'client':10} {'kind':26} {'n':>6} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}  studs | studsT p95  p99    max"
          f" | px p95  p99 | pxT p95  p99 | frame ms p95 | own-path fit (studs)")
    for name, r in clients.items():
        fm = (r.get("frameMs") or {})
        for kind, k in sorted((r.get("kinds") or {}).items()):
            s, p = k.get("studs", {}), k.get("px") or {}
            st, pt, ft = k.get("studsT") or {}, k.get("pxT") or {}, k.get("fit") or {}
            print(f"{name:10} {kind:26} {s.get('n', 0):>6} {s.get('p50', 0):>7.3f} {s.get('p95', 0):>7.3f} {s.get('p99', 0):>7.3f} "
                  f"{s.get('max', 0):>7.2f}        {st.get('p95', 0):>7.3f} {st.get('p99', 0):>6.3f} {st.get('max', 0):>6.2f}"
                  f"   {p.get('p95', 0):>5.1f} {p.get('p99', 0):>5.1f}   {pt.get('p95', 0):>5.1f} {pt.get('p99', 0):>5.1f}"
                  f"    {fm.get('p95', 0):>6.1f}   fit p95 {ft.get('p95', 0):.3f} p99 {ft.get('p99', 0):.3f} max {ft.get('max', 0):.2f}")
        if r.get("stream") is not None:
            print(f"{name:10} stream draws {r['stream']}")
    if mode == "mp":
        for row in remote_rows(clients, relay):
            print(row)
    print(out)


if __name__ == "__main__":
    main()
