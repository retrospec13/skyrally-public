#!/usr/bin/env python3
"""Multiplayer check (TEST_LIST L30-L32) in the lane's own Studio window: starts StudioTestService
ExecuteMultiplayerTestAsync from the edit DataModel (one local server + N real client DataModels), which runs
server/QAMultiplayer with the scenario, and waits for its EndTest JSON. Writes evidence/L30/mp_<scenario>_<key>.json.
Usage: mp_check.py <scenario: race|join_mid|leave_mid|hub|jitter|pergroup|join_countdown|leave_lobby|leave_countdown|solo_start> [key=dino4] [players=2] [timeout_s=900] [name=value ...]
Extra name=value pairs (lobbySecs=45, trackId=DINO-4, raceTimeout=420, jitterSecs=10) go into the test args.
join_countdown / leave_lobby / leave_countdown / solo_start are the L31 scenarios (TG-3; see server/QAMultiplayer; players default
1, 2, 2, 1; solo_start shows the 20 s lobby only with the QAPerGroup switch on). pergroup needs per-group races on in the lane's place: run tools/qa_pergroup.py on first (Studio QAPerGroup switch)."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

scenario = sys.argv[1]
key = sys.argv[2] if len(sys.argv) > 2 else "dino4"
DEFAULT_PLAYERS = {"join_mid": 1, "join_countdown": 1, "solo_start": 1}
players = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_PLAYERS.get(scenario, 2)
timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 900
EXTRA = ""
for pair in sys.argv[5:]:
    k, _, v = pair.partition("=")
    if not k.isalnum():
        sys.exit(f"bad extra arg name: {pair}")
    try:
        EXTRA += f", {k} = {float(v):g}"
    except ValueError:
        EXTRA += f", {k} = {json.dumps(v)}"

START = r"""
local SS = game:GetService('ServerStorage')
if SS:GetAttribute('QAMPToken') == '%s' then return 'started (already)' end
SS:SetAttribute('QAMPToken', '%s')
SS:SetAttribute('QAMPResult', nil)
task.spawn(function()
  local sts = game:GetService('StudioTestService')
  local ok, r = pcall(function()
    return sts:ExecuteMultiplayerTestAsync(%d, { qa = 'mp', scenario = '%s', key = '%s', players = %d, token = '%s'%s })
  end)
  SS:SetAttribute('QAMPResult', if ok then tostring(r) else ('{"verdict":"ERROR","token":"%s","why":' .. string.format('%%q', tostring(r)) .. '}'))
end)
return 'started'
"""
# A run token comes back in the result: a start that never reached Studio (the bridge drops under load) must not read
# the previous run's QAMPResult as its own.
token = f"{scenario}-{key}-{int(time.time())}"
for attempt in range(8):
    # The token goes in first: a start whose answer timed out but ran is not started twice (the retry sees it).
    started = lane.luau(START % (token, token, players, scenario, key, players, token, EXTRA, token), dm="Edit", name="mp_start")
    print(started)
    if "started" in str(started):
        break
    time.sleep(20)
else:
    sys.exit("NOT STARTED: the Studio bridge did not take the start call")
t0 = time.time()
raw = None
while time.time() - t0 < timeout:
    time.sleep(20)
    try:
        out = lane.luau("return tostring(game:GetService('ServerStorage'):GetAttribute('QAMPResult'))", dm="Edit", name="mp_poll")
    except Exception as e:  # the bridge drops under load; keep polling
        print("poll error", e)
        continue
    s = str(out).strip()
    i = s.find("{")
    if i >= 0 and token in s:
        raw = s[i:]
        break
    if i >= 0:
        print("ignoring a result without this run's token")
    print(f"{int(time.time() - t0)} s: waiting")
if raw is None:
    sys.exit("TIMEOUT: no EndTest result")
try:
    res = json.loads(raw)
except json.JSONDecodeError:
    res = {"verdict": "UNPARSED", "raw": raw}
out = lane.ROOT / "evidence" / "L30" / f"mp_{scenario}_{key}.json"
out.parent.mkdir(parents=True, exist_ok=True)
res["commit"] = lane.git_head()
res["utc"] = lane.utc()
out.write_text(json.dumps(res, indent=1))
print(json.dumps({k: res.get(k) for k in ("verdict", "why", "ranks", "seconds", "lateJoiner", "lobby", "countdown", "solo", "hubA", "hubB", "hubPortal", "pergroup", "curtain", "build")}, indent=1))
for k in ("errors", "clientErrors"):
    for line in res.get(k, [])[:15]:
        print(k, line)
print(out)
