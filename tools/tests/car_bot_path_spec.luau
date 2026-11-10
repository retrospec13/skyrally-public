--!strict
-- Lune spec for car bots on the smoothed path (docs/audits/plane_stutter.md "Car bots"). AIRacers.renderCar places
-- the hull AT pos + rightOf(tan) * lateral every server step (no position ease), so the raw chord tangent, which
-- turns in one step at each waypoint, made a side-lane car bot hop sideways by lateral x corner angle there. renderCar
-- now takes pos/tan (and the 12-stud look-ahead) from RacerViewRules.pathFrame, like renderPlane.
--   1. Replay: renderCar's placement and eased heading on a car-map-like polyline (17-stud chords), old vs new.
--   2. Source guards: renderCar uses pathFrame; the jitter fix's server step is intact; the real-route twin
--      (tools/map/tests/test_car_bot_path.py) still models the same constants.
-- Real HUB-0 / ISLAND-2 / SPACE-4 numbers: tools/map/tests/test_car_bot_path.py.
-- Run: tools/tests/run_lune_tests.sh tools/tests/car_bot_path_spec.luau (SKYRALLY_TEST_VERBOSE=1 prints the table).

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/RacerViewRules.luau")

	local function pct(list: { number }, q: number): number
		local s = table.clone(list)
		table.sort(s)
		if #s == 0 then
			return 0
		end
		return s[math.clamp(math.floor(q * #s + 0.5), 1, #s)]
	end
	local function maxOf(list: { number }): number
		local m = 0
		for _, v in list do
			m = math.max(m, v)
		end
		return m
	end

	-- A closed road loop (corners up to ~8 deg like ISLAND-2's 9.8), cut into ~17-stud chords like the car maps' waypoints.
	local wps: { { pos: Vector3, station: number } } = {}
	local total = 0
	do
		local fine = {}
		for i = 0, 3600 do
			local a = i / 3600 * 2 * math.pi
			local r = 520 + 100 * math.sin(3 * a) + 12 * math.sin(7 * a)
			fine[i + 1] = Vector3.new(r * math.cos(a), 40 + 8 * math.sin(2 * a), r * math.sin(a))
		end
		local acc = 0
		table.insert(wps, { pos = fine[1], station = 0 })
		local last = fine[1]
		for i = 2, #fine do
			acc += (fine[i] - fine[i - 1]).Magnitude
			if acc >= 17.4 then
				total += (fine[i] - last).Magnitude
				table.insert(wps, { pos = fine[i], station = total })
				last = fine[i]
				acc = 0
			end
		end
		total += (fine[1] - last).Magnitude
		table.insert(wps, { pos = fine[1], station = total })
	end
	-- SplineUtils.sampleAtStation's algorithm (bisect, lerp, chord tangent; bank 0). Guarded in plane_stutter_spec 4.
	local function sample(station: number): (Vector3, Vector3, number)
		local s = station % total
		local low, high = 1, #wps
		while low < high - 1 do
			local mid = math.floor((low + high) * 0.5)
			if wps[mid].station <= s then
				low = mid
			else
				high = mid
			end
		end
		local w1, w2 = wps[low], wps[high]
		local alpha = math.clamp((s - w1.station) / math.max(0.01, w2.station - w1.station), 0, 1)
		return w1.pos:Lerp(w2.pos, alpha), (w2.pos - w1.pos).Unit, 0
	end
	local function rightOf(tan: Vector3): Vector3
		local r = tan:Cross(Vector3.new(0, 1, 0))
		return if r.Magnitude > 0.01 then r.Unit else Vector3.new(1, 0, 0)
	end

	-- renderCar's horizontal placement and eased heading at the fixed 1/60 s step (CAR_BOT.turnResponse 14, 12-stud
	-- look-ahead). Returns hull jerk (studs/step) and heading jerk (deg/step).
	local function runCar(new: boolean, lateral: number, speed: number): ({ number }, { number })
		local dt = 1 / 60
		local alpha = math.clamp(dt * 14, 0, 1)
		local frame = if new then function(st: number)
			return R.pathFrame(sample, st)
		end else sample
		local station = 0
		local yaw: number? = nil
		local ps: { Vector3 } = {}
		local ys: { number } = {}
		for _ = 1, math.floor(total / speed / dt) do
			station += speed * dt
			local pos, tan = frame(station)
			local aheadPos, aheadTan = frame(station + 12)
			local base = pos + rightOf(tan) * lateral
			local fwd = (aheadPos + rightOf(aheadTan) * lateral) - base
			local goal = math.deg(math.atan2(fwd.X, fwd.Z))
			if yaw == nil then
				yaw = goal
			else
				local y = yaw :: number
				yaw = y + ((goal - y + 180) % 360 - 180) * alpha
			end
			table.insert(ps, Vector3.new(base.X, 0, base.Z))
			table.insert(ys, yaw :: number)
		end
		local pj, yj = {}, {}
		for i = 3, #ps do
			table.insert(pj, (ps[i] - ps[i - 1] * 2 + ps[i - 2]).Magnitude)
			table.insert(yj, math.abs((ys[i] - ys[i - 1]) - (ys[i - 1] - ys[i - 2])))
		end
		return pj, yj
	end

	h.test("1. car bots: no sideways hop at waypoints", function()
		local angles = {}
		for i = 2, #wps - 1 do
			local a = (wps[i].pos - wps[i - 1].pos).Unit
			local b = (wps[i + 1].pos - wps[i].pos).Unit
			table.insert(angles, math.deg(math.acos(math.clamp(a:Dot(b), -1, 1))))
		end
		print(string.format("car polyline: %d waypoints, %.0f studs, corner p50 %.2f / max %.2f deg", #wps, total, pct(angles, 0.5), maxOf(angles)))
		print("car bot at 130 studs/s: hull jerk studs/step and heading jerk deg/step (p99 / max), old -> new")
		for _, lateral in { 0, 12, 16 } do
			local op, oy = runCar(false, lateral, 130)
			local np, ny = runCar(true, lateral, 130)
			print(string.format("  lateral %2d: pos %.3f / %.3f -> %.3f / %.3f   heading %.3f / %.3f -> %.3f / %.3f",
				lateral, pct(op, 0.99), maxOf(op), pct(np, 0.99), maxOf(np), pct(oy, 0.99), maxOf(oy), pct(ny, 0.99), maxOf(ny)))
			h.ok(maxOf(np) <= maxOf(op) + 1e-6, string.format("lateral %d: hull jerk max not worse", lateral))
			h.ok(maxOf(ny) <= maxOf(oy) + 1e-6, string.format("lateral %d: heading jerk max not worse", lateral))
			if lateral >= 12 then
				h.ok(maxOf(np) < maxOf(op) * 0.5, string.format("lateral %d: hop max %.3f (old %.3f)", lateral, maxOf(np), maxOf(op)))
				h.ok(maxOf(np) < 0.25, string.format("lateral %d: no hop over a quarter stud", lateral))
			end
		end
		local worst = 0
		for st = 0, total, 5 do
			local p = R.pathFrame(sample, st)
			local q = sample(st)
			worst = math.max(worst, Vector3.new(p.X - q.X, 0, p.Z - q.Z).Magnitude)
		end
		h.ok(worst < 1.5, string.format("lane 0 within %.2f studs of the line (44-wide road, lanes to +-18)", worst))
	end)

	h.test("2. source guards", function()
		local ai = h.readFile("src/server/AIRacers.luau")
		local s = string.find(ai, "local function renderCar(", 1, true)
		local e = string.find(ai, "local function renderPlane(", 1, true)
		h.ok(s ~= nil and e ~= nil and (s :: number) < (e :: number), "renderCar precedes renderPlane")
		local body = string.sub(ai, s :: number, (e :: number) - 1)
		h.ok(string.find(body, "local pos, tan, _ = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station)", 1, true) ~= nil,
			"renderCar takes pos/tan from pathFrame")
		h.ok(string.find(body, "RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station + 12)", 1, true) ~= nil,
			"and the 12-stud look-ahead")
		h.ok(string.find(body, "SplineUtils.sampleAtStation(bot.station", 1, true) == nil, "no raw chord frame left in renderCar")
		h.ok(string.find(body, "bot.hull.CFrame = CFrame.new(p) * turned", 1, true) ~= nil, "placed at its station, rotation eased (unchanged)")
		h.ok(string.find(body, "AIRacers.carRideTarget(", 1, true) ~= nil, "the ground ray ride is unchanged")
		h.ok(string.find(ai, "turnResponse = 14,", 1, true) ~= nil, "turnResponse 14 (the replays' value)")
		h.ok(string.find(ai, "RacerViewRules.serverSteps", 1, true) ~= nil, "the jitter fix's fixed bot step is intact")
		h.eq(R.PATH_HALF, 16, "pathFrame half width (the real-route twin's value)")
		local py = h.readFile("tools/map/tests/test_car_bot_path.py")
		for _, needle in { "PATH_HALF = 16.0", "AHEAD = 12.0", "TURN_RESPONSE = 14.0" } do
			h.ok(string.find(py, needle, 1, true) ~= nil, "real-route twin: " .. needle)
		end
	end)
end
