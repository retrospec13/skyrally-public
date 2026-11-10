// SkyRally keyboard pilot (TEST_LIST_LAUNCH L02/T01-T03 real-input runs). Runs on the PC next to Studio's MCP server and
// flies the local plane ONLY through real key events (user_keyboard_input keyDown/keyUp) into the lane's own window
// (skyrally_1.rbxlx). Each tick a small client-side decision function reads the plane and the spline and returns the
// keys a player would hold; the pilot sends only the transitions. Optional: turn the course assist off first by clicking
// the HUD position plank with real mouse input.
// Usage: node key_pilot.js <outJsonl> <seconds> [assist=on|off] [skill=0..1] [goal=spline|qa|verify] [route=x:y:z:vmax/x:y:z:vmax/...] [boost=1]
// goal=qa (battle modes): steer to the player attribute QAGoal that BattleCore publishes in Studio QA (the mode's bot
// brain), and tap F (fire the held item) while QAFire is set.
// route= (S2b, goal=qa): ordered approach waypoints in world studs plus a speed cap each (the pilot brakes above it).
// While the plane is within 220 studs of the first waypoint (before that it flies the spline) the pilot steers waypoint
// to waypoint and then to QAGoal; it re-arms after a missed pass. tools/key_approach.json holds the per-key lines and
// tools/key_check.py passes them. Not read from anywhere in the game: the line only exists in this harness.
// goal=verify (S1, any race/boss/coin mode, Studio QA only, client-side only, no server hook): flies the spline like
// goal=spline, but (a) chases the nearest uncollected challenge coin ahead (workspace.Maps.<id>.ChallengeCoins minus
// the player's CoinsHeld) so a coin-challenge run can reach 8/8, and (b) taps F to fire a held item when a rival is
// ahead within 140 studs (or after 8 s of holding it). boost=1 forces the skilled booster-ring throttle release at
// any skill (skill>=0.9 already does it). The pilot stays a real-key player: no seeding, no attribute writes.
const { spawn } = require('child_process');
const fs = require('fs');
const [, , outPath, secondsArg, assistArg, skillArg] = process.argv;
const extra = process.argv.slice(6);
const argOf = (k) => { const a = extra.find((x) => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : ''; };
const GOAL = argOf('goal') || 'spline';
const GOAL_QA = GOAL === 'qa';
const GOAL_VERIFY = GOAL === 'verify';
const BOOST = argOf('boost') === '1';
// route=x:y:z:v/x:y:z:v -> Lua table literal (numbers only; anything else is dropped)
const ROUTE_LUA = '{' + argOf('route').split('/').filter(Boolean).map((w) => {
  const n = w.split(':').map(Number);
  return n.length >= 3 && n.every((v) => Number.isFinite(v)) ? `{${n[0]},${n[1]},${n[2]},${Number.isFinite(n[3]) ? n[3] : 9999}}` : null;
}).filter(Boolean).join(',') + '}';
const SECONDS = Number(secondsArg || 180);
const ASSIST_OFF = (assistArg || 'assist=off') === 'assist=off';
const SKILL = Number((skillArg || 'skill=1').split('=')[1] || 1);
const PLACE = process.env.SKYRALLY_STUDIO_PLACE || 'skyrally_1.rbxlx';

const mcp = process.env.SKYRALLY_PILOT_ENABLED === '1'
  ? spawn('cmd.exe', ['/c', 'mcp.bat'], { cwd: process.env.LOCALAPPDATA + '\\Roblox' })
  : { stdout: { on() {} } }; // extraction-only mode; async runner refuses use
let buf = '';
const waiters = {};
mcp.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    try { const m = JSON.parse(line); if (m.id !== undefined && waiters[m.id]) { waiters[m.id](m); delete waiters[m.id]; } } catch (e) { }
  }
});
let nextId = 1;
function rpc(method, params, timeoutS) {
  const id = nextId++;
  return new Promise((resolve) => {
    const t = setTimeout(() => { delete waiters[id]; resolve({ error: { message: 'TIMEOUT' } }); }, (timeoutS || 30) * 1000);
    waiters[id] = (m) => { clearTimeout(t); resolve(m); };
    mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
const text = (r) => (r.result && r.result.content || []).filter((p) => p.type === 'text').map((p) => p.text).join('\n');

const DECIDE_DEF = `
_G.PilotDecide = nil -- E2: never reuse a previous run's decider (a later goal=qa run kept flying the spline)
_G.PilotRouteIdx, _G.PilotRouteAt, _G.PilotRouteDone, _G.PilotCoins, _G.PilotItemSince = nil, nil, nil, nil, nil
if not _G.PilotDecide then
	local Players = game:GetService('Players')
	local RS = game:GetService('ReplicatedStorage')
	local Spline = require(RS:WaitForChild('Shared'):WaitForChild('SplineUtils'))
	local lp = Players.LocalPlayer
	local SKILL = ${SKILL}
	local ROUTE = ${ROUTE_LUA}
	local VERIFY = ${GOAL_VERIFY ? 'true' : 'false'}
	local BOOST = ${BOOST ? 'true' : 'false'}
	local function yawPitch(v)
		return math.deg(math.atan2(-v.X, -v.Z)), math.deg(math.asin(math.clamp(v.Y, -0.98, 0.98)))
	end
	_G.PilotDecide = function()
		local planes = workspace:FindFirstChild('Planes')
		local hull
		if planes then for _, m in planes:GetChildren() do if m.Name:find(lp.Name, 1, true) and m:FindFirstChild('Hull') then hull = m.Hull end end end
		if not hull then return 'nohull' end
		local spd = lp:GetAttribute('Speed') or 110
		local isCar = hull.Parent:GetAttribute('VehicleType') == 'car'
		local st, _, _, dist = Spline.projectPosition(hull.Position, lp:GetAttribute('Station'))
		-- look further ahead on straights, nearer in bends (a player reads the next corner)
		local la = if isCar then 18 + spd * 0.3 else 40 + spd * 0.32
		local p1 = Spline.sampleAtStation(st + la * 0.5)
		local p2 = Spline.sampleAtStation(st + la)
		local p0 = Spline.sampleAtStation(st)
		local a, b = p1 - p0, p2 - p1
		if a.Magnitude > 1 and b.Magnitude > 1 then
			local turn = math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
			if turn > 15 then la = math.max(28, la * 15 / turn) end
		end
		local target = Spline.sampleAtStation(st + la) + Vector3.new(0, if isCar then 0 else 14, 0)
		local qaGoal = lp:GetAttribute('QAGoal')
		local goalPos = nil -- the point the QA/verify pilot chases instead of the spline lookahead
		local vmax = 9999
		if ${GOAL_QA ? 'true' : 'false'} and typeof(qaGoal) == 'Vector3' then goalPos = qaGoal end
		if ${GOAL_QA ? 'true' : 'false'} and #ROUTE > 0 and goalPos then
			-- S2b: fly the approach line (under the arch, into the notch) before the final QAGoal
			local now = os.clock()
			local ri = _G.PilotRouteIdx or 1
			if ri > #ROUTE then
				_G.PilotRouteDone = _G.PilotRouteDone or now
				if now - _G.PilotRouteDone > 25 then ri, _G.PilotRouteIdx, _G.PilotRouteDone, _G.PilotRouteAt = 1, 1, nil, nil end
			elseif ri > 1 and now - (_G.PilotRouteAt or now) > 22 then
				ri, _G.PilotRouteIdx, _G.PilotRouteAt = 1, 1, nil -- missed a waypoint: back to the line start next pass
			end
			if ri <= #ROUTE then
				local w = ROUTE[ri]
				local wp = Vector3.new(w[1], w[2], w[3])
				local dh = ((wp - hull.Position) * Vector3.new(1, 0, 1)).Magnitude
				if ri == 1 and dh > 220 then
					-- not at the line yet: the spline carries the plane under the arch
					goalPos = nil
				else
					if dh < 16 then
						ri += 1
						_G.PilotRouteIdx, _G.PilotRouteAt = ri, now
					end
					if ri <= #ROUTE then
						w = ROUTE[ri]
						goalPos = Vector3.new(w[1], w[2], w[3])
						vmax = w[4]
						_G.PilotRouteAt = _G.PilotRouteAt or now
					end
				end
			end
			if goalPos == qaGoal then vmax = 9999 end
		end
		local fireNow = lp:GetAttribute('QAFire') == true
		if VERIFY then
			-- S1: nearest uncollected challenge coin ahead along the route; fire a held item at a rival ahead.
			local okA, RaceAttr = pcall(function() return require(RS.Shared.RaceAttr) end)
			local tid = if okA then RaceAttr.mine('ActiveTrackId') else workspace:GetAttribute('ActiveTrackId')
			local maps = workspace:FindFirstChild('Maps')
			local root = maps and maps:FindFirstChild(tostring(tid))
			local folder = root and root:FindFirstChild('ChallengeCoins')
			if folder then
				local held = {}
				local raw = lp:GetAttribute('CoinsHeld')
				if type(raw) == 'string' then
					local ok, t = pcall(function() return game:GetService('HttpService'):JSONDecode(raw) end)
					if ok and type(t) == 'table' then for _, id in t do held[tostring(id)] = true end end
				end
				local _, totalLen = Spline.loadWaypoints()
				local best, bestD = nil, 1e9
				for _, m in folder:GetChildren() do
					if not held[m.Name] then
						local cp = m:GetPivot().Position
						local cs = Spline.projectPosition(cp, st)
						local delta = (cs - st) % totalLen
						if delta < 700 and delta < bestD then best, bestD = cp, delta end
					end
				end
				if best then goalPos = best + Vector3.new(0, 1, 0) end
			end
			fireNow = false
			if (lp:GetAttribute('ItemColor') or '') ~= '' then
				_G.PilotItemSince = _G.PilotItemSince or os.clock()
				local lv = hull.CFrame.LookVector
				if planes then
					for _, m in planes:GetChildren() do
						local h = m:FindFirstChild('Hull')
						if h and not m.Name:find(lp.Name, 1, true) then
							local to = h.Position - hull.Position
							if to.Magnitude < 140 and to.Magnitude > 4 and to.Unit:Dot(lv) > 0.75 then fireNow = true end
						end
					end
				end
				if os.clock() - _G.PilotItemSince > 8 then fireNow = true end
			else
				_G.PilotItemSince = nil
			end
		end
		if goalPos then target = goalPos + Vector3.new(0, if isCar then 0 else (if VERIFY then 2 else 4), 0) end
		local ty, tp = yawPitch((target - hull.Position).Unit)
		local cy, cp = yawPitch(hull.CFrame.LookVector)
		local yawErr = ((ty - cy + 540) % 360) - 180
		local pitchErr = tp - cp
		local keys = {}
		local dead = (if isCar then 2.5 else 4) + (1 - SKILL) * 10
		if yawErr > dead then table.insert(keys, 'A') elseif yawErr < -dead then table.insert(keys, 'D') end
		if not isCar then
			local qa = goalPos ~= nil
			if qa and math.abs(yawErr) > 40 then
				-- Level turn first (hold the goal's height), then pitch onto it: a banked pull-up spirals.
				pitchErr = math.deg(math.asin(math.clamp((goalPos.Y + 8 - hull.Position.Y) / 60, -0.5, 0.5))) - cp
			end
			if pitchErr > dead * 0.8 then table.insert(keys, 'Up') elseif pitchErr < -dead * 0.8 then table.insert(keys, 'Down') end
			if math.abs(yawErr) > 34 and not qa then table.insert(keys, 'LeftShift') end
		end
		-- QA goals sit close (pods, eggs, rivals): brake into a tight turn instead of orbiting the goal at full speed.
		if goalPos then
			if not isCar and ((goalPos - hull.Position).Magnitude < 170 and math.abs(yawErr) > 45 or spd > vmax + 8) then
				table.insert(keys, 'S')
			elseif isCar then
				-- Wedged against a crate or rail: back off with the wheel turned the other way, as a player would.
				local now = os.clock()
				if spd < 4 then _G.PilotSlowSince = _G.PilotSlowSince or now else _G.PilotSlowSince = nil end
				if _G.PilotSlowSince and now - _G.PilotSlowSince > 1.5 then
					_G.PilotReverseUntil = now + 1.2
					_G.PilotSlowSince = nil
				end
				if (_G.PilotReverseUntil or 0) > now then
					keys = { if yawErr > 0 then 'D' else 'A', 'S' }
				end
			end
		end
		-- Skilled technique: release the throttle just before a booster ring so the ring fires an Overcharge.
		local release = false
		if SKILL >= 0.9 or BOOST then
			if not _G.PilotRings then
				_G.PilotRings = {}
				for _, d in workspace:GetDescendants() do
					if d:IsA('BasePart') and d:GetAttribute('TriggerType') == 'BoosterRing' then table.insert(_G.PilotRings, d.Position) end
				end
			end
			local lv = hull.CFrame.LookVector
			for _, rp in _G.PilotRings do
				local to = rp - hull.Position
				local ahead = to:Dot(lv)
				if ahead > 0 and ahead < 22 + spd * 0.45 and (to - lv * ahead).Magnitude < 30 then release = true break end
			end
		end
		return string.format('%s|%d|%d|%d|%d|%.1f|%.1f|%.1f|%s|%s|%d|%s|%s', table.concat(keys, ','), math.floor(st), lp:GetAttribute('Lap') or 0,
			lp:GetAttribute('Checkpoint') or 0, lp:GetAttribute('CrashCount') or 0, yawErr, pitchErr, dist or -1,
			tostring(lp:GetAttribute('RaceFinished')), tostring(lp:GetAttribute('LastCrashReason')), math.floor(spd),
			tostring(release), tostring(lp:GetAttribute('FinishRank'))) .. '|' .. tostring(isCar) .. '|' .. tostring(fireNow) .. '|' .. tostring(lp:GetAttribute('Coins') or 0)
	end
end
return _G.PilotDecide()`;

(async () => {
  if (process.env.SKYRALLY_PILOT_ENABLED !== "1") throw new Error("Pilot disabled: explicit local Studio opt-in required");
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'skyrally-pilot', version: '1' } });
  mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const ls = JSON.parse(text(await rpc('tools/call', { name: 'list_roblox_studios', arguments: {} })));
  const studio = (ls.studios || []).find((s) => s.name === PLACE);
  if (!studio) { console.log('NO_OWN_STUDIO'); process.exit(2); }
  const sid = studio.id;
  const call = (name, args, t) => rpc('tools/call', { name, arguments: Object.assign({ studio_id: sid }, args) }, t);
  const out = fs.createWriteStream(outPath);
  const held = new Set();
  const send = async (actions) => { if (actions.length) await call('user_keyboard_input', { datamodel_type: 'Client', actions }, 10); };

  if (ASSIST_OFF) {
    // Real mouse click on the HUD position plank toggles the assist (and auto throttle) off, as a player would.
    const r = await call('user_mouse_input', { datamodel_type: 'Client', actions: [
      { action: 'moveTo', instance_path: 'LocalPlayer.PlayerGui.SkyRallyHUD.PositionBadge' },
      { action: 'mouseButtonClick', mouse_button: 'left' }] }, 10);
    out.write(JSON.stringify({ t: 0, event: 'assist_toggle', result: text(r).slice(0, 200) }) + '\n');
    await send([{ action: 'keyDown', key_code: 'W' }]);
    held.add('W');
  }
  const t0 = Date.now();
  let ticks = 0;
  while ((Date.now() - t0) / 1000 < SECONDS) {
    const r = await call('execute_luau', { datamodel_type: 'Client', code: DECIDE_DEF }, 10);
    const s = text(r);
    ticks++;
    if (!s.includes('|')) { out.write(JSON.stringify({ t: (Date.now() - t0) / 1000, raw: s.slice(0, 200) }) + '\n'); await new Promise((z) => setTimeout(z, 200)); continue; }
    const [keyStr, st, lap, cp, crashes, yawErr, pitchErr, dist, fin, why, spd, release, rank, car, qaFire, coins] = s.split('|');
    const want = new Set(keyStr ? keyStr.split(',').filter(Boolean) : []);
    // Fire is a tap: press on a tick where QAFire is set and F is not already held, release on the next tick.
    if ((GOAL_QA || GOAL_VERIFY) && qaFire === 'true' && !held.has('F')) want.add('F');
    if ((ASSIST_OFF || car === 'true') && release !== 'true' && !want.has('S')) want.add('W');
    const actions = [];
    for (const k of held) if (!want.has(k)) { actions.push({ action: 'keyUp', key_code: k }); }
    for (const k of want) if (!held.has(k)) { actions.push({ action: 'keyDown', key_code: k }); }
    await send(actions);
    held.clear(); for (const k of want) held.add(k);
    out.write(JSON.stringify({ t: (Date.now() - t0) / 1000, keys: [...want], st: +st, lap: +lap, cp: +cp, crashes: +crashes,
      yawErr: +yawErr, pitchErr: +pitchErr, dist: +dist, fin: fin === 'true', why, spd: +spd, release: release === 'true', rank, coins: +coins }) + '\n');
    if (fin === 'true' && !GOAL_QA) break;
  }
  await send([...held].map((k) => ({ action: 'keyUp', key_code: k })));
  out.write(JSON.stringify({ t: (Date.now() - t0) / 1000, event: 'end', ticks, hz: ticks / ((Date.now() - t0) / 1000) }) + '\n');
  out.end();
  setTimeout(() => { mcp.kill(); process.exit(0); }, 300);
})();
