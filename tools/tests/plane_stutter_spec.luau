--!strict
-- Lune spec for the plane stutter pass (docs/audits/plane_stutter.md). Offline replays of the three plane-only causes
-- the opponent jitter fix (docs/audits/opponent_jitter.md) did not cover, each run with the old and the new code:
--   1. C1 chase camera: the plane's position in camera space, frame to frame, for straight flight and a turn, under
--      steady, jittery, Studio-like and 144 fps frame times. The old dt * 18 lerp left a frame-time-dependent gap.
--   2. C2 ring pull: a plane flying through a ring's pull window. The old fixed-speed pull crossed the axis every frame.
--   3. C5 plane bots: a bot on a DINO-4-like polyline (27-stud chords). The chord tangent stepped at every waypoint.
--   4. Source guards: FlightController, AIRacers and SplineUtils still match what the replays model.
-- Run: tools/tests/run_lune_tests.sh tools/tests/plane_stutter_spec.luau (SKYRALLY_TEST_VERBOSE=1 prints the tables).

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local P = h.require("src/shared/PlaneConfig.luau")
	local AI = h.require("src/shared/RacerViewRules.luau") -- pathFrame (AIRacers.renderPlane)

	-- Deterministic frame times.
	local seed = 1
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local function frameTimes(kind: string, n: number): { number }
		seed = 7
		local out = {}
		local i = 0
		while i < n do
			i += 1
			if kind == "steady60" then
				out[i] = 1 / 60
			elseif kind == "jitter60" then
				out[i] = (1 / 60) * (0.92 + 0.16 * rand())
			elseif kind == "studio60" then
				-- +-30 % and 4 % hitches of 2-3 frames (the opponent jitter harness's "studio" server, on the client).
				out[i] = if rand() < 0.04 then (1 / 60) * (2 + math.floor(rand() * 2)) else (1 / 60) * (0.7 + 0.6 * rand())
			elseif kind == "jitter144" then
				out[i] = (1 / 144) * (0.92 + 0.16 * rand())
			else
				out[i] = 1 / 30
			end
		end
		return out
	end
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
	local function report(line: string)
		print(line) -- echoed with SKYRALLY_TEST_VERBOSE=1
	end
	-- Roblox's lookAt, built by hand: the @lune/roblox one flips the look for some downward directions.
	local function lookAt(eye: Vector3, target: Vector3): CFrame
		local look = (target - eye).Unit
		local right = look:Cross(Vector3.new(0, 1, 0)).Unit
		return CFrame.fromMatrix(eye, right, right:Cross(look), -look)
	end

	-- ------------------------------------------------------------------ 1. chase camera
	-- The plane at time t: straight (yawRate 0) or a level turn, at `speed`. Returns position and look.
	local function planeAt(t: number, speed: number, yawRate: number): (Vector3, Vector3)
		if yawRate == 0 then
			return Vector3.new(0, 150, -speed * t), Vector3.new(0, 0, -1)
		end
		local w = math.rad(yawRate)
		local r = speed / w
		local a = w * t
		return Vector3.new(r * (1 - math.cos(a)), 150, -r * math.sin(a)), Vector3.new(math.sin(a), 0, -math.cos(a))
	end
	-- updateChaseCamera's goal without the lead and bank (both are eased separately and do not depend on the follow).
	local function goalOf(pos: Vector3, look: Vector3): CFrame
		local flat = Vector3.new(look.X, look.Y * 0.55, look.Z).Unit
		local camPos = pos - flat * P.CAM_DISTANCE + Vector3.new(0, P.CAM_HEIGHT, 0)
		return lookAt(camPos, pos + look * 32 + Vector3.new(0, 1.2, 0))
	end
	-- Per-frame change of the plane's camera-space position (studs) after a 1 s warm-up, and its mean.
	local function runCamera(kind: string, speed: number, yawRate: number, new: boolean): ({ number }, Vector3)
		local dts = frameTimes(kind, 900)
		local t = 0
		local cam: CFrame? = nil
		local lastPos: Vector3? = nil
		local prevRel: Vector3? = nil
		local deltas = {}
		local sum, n = Vector3.zero, 0
		for _, dt in dts do
			t += dt
			local pos, look = planeAt(t, speed, yawRate)
			if new then
				local goal = goalOf(pos, look) - P.camTrail(look * speed)
				cam = if cam and lastPos then P.camFollow(cam, pos - lastPos, goal, dt) else goal
			else
				local goal = goalOf(pos, look)
				cam = if cam then cam:Lerp(goal, math.clamp(dt * 18, 0, 1)) else goal
			end
			lastPos = pos
			local rel = (cam :: CFrame):PointToObjectSpace(pos)
			if t > 1 then
				if prevRel then
					table.insert(deltas, (rel - prevRel).Magnitude)
				end
				sum += rel
				n += 1
			end
			prevRel = rel
		end
		return deltas, sum / math.max(n, 1)
	end

	h.test("1. C1 chase camera: no frame-time term on a straight flight, same framing at 60 fps", function()
		report("C1 camera: plane jerk in camera space, studs per frame (p95 / max), old -> new")
		for _, speed in { 128, 165, 224 } do
			for _, kind in { "steady60", "jitter60", "studio60", "jitter144" } do
				local od, om = runCamera(kind, speed, 0, false)
				local nd, nm = runCamera(kind, speed, 0, true)
				report(string.format("  straight %3d studs/s %-9s %.3f / %.3f -> %.4f / %.4f", speed, kind, pct(od, 0.95), maxOf(od), pct(nd, 0.95), maxOf(nd)))
				h.ok(pct(nd, 0.95) < 0.002 and maxOf(nd) < 0.01, string.format("straight %d %s: new jerk ~0 (p95 %.4f)", speed, kind, pct(nd, 0.95)))
				if kind == "steady60" then
					h.ok((nm - om).Magnitude < 0.05, string.format("straight %d: framing unchanged at 60 fps (%.3f)", speed, (nm - om).Magnitude))
				elseif kind == "studio60" or kind == "jitter60" then
					h.ok(pct(od, 0.95) > 0.03, string.format("straight %d %s: the old follow jittered (p95 %.3f)", speed, kind, pct(od, 0.95)))
				end
			end
		end
		for _, kind in { "steady60", "studio60", "jitter144" } do
			local od, om = runCamera(kind, 128, 75, false)
			local nd, nm = runCamera(kind, 128, 75, true)
			report(string.format("  turn 75 deg/s 128     %-9s %.3f / %.3f -> %.4f / %.4f", kind, pct(od, 0.95), maxOf(od), pct(nd, 0.95), maxOf(nd)))
			h.ok(pct(nd, 0.95) <= pct(od, 0.95) * 0.5 + 1e-3, string.format("turn %s: new jerk at most half the old", kind))
			if kind == "steady60" then
				h.ok((nm - om).Magnitude < 0.6, string.format("turn: framing within 0.6 studs of the old at 60 fps (%.3f)", (nm - om).Magnitude))
			end
		end
	end)

	h.test("1b. C1 follow pieces", function()
		h.ok(math.abs((1 - math.exp(-P.CAM_FOLLOW_RATE / 60)) - 0.3) < 0.002, "follow rate = the old dt * 18 at 60 fps")
		h.ok(math.abs(P.CAM_SPEED_TRAIL_S * 128 - 128 * 0.7 / 18) < 1e-9, "trail = the old 60 fps gap")
		local goal = CFrame.new(0, 10, 0)
		local out = P.camFollow(CFrame.new(0, 10, 5), Vector3.new(0, 0, -5), goal, 1 / 60)
		h.ok((out.Position - goal.Position).Magnitude < 1e-6, "a carry that lands on the goal stays on it")
	end)

	-- ------------------------------------------------------------------ 2. ring pull
	-- Lateral offset (signed, one axis) of a plane flying at `speed` from 90 studs before a ring to 6 past it.
	local function runRing(start: number, speed: number, dt: number, new: boolean): (number, number, boolean)
		local lat, fwd = start, 90
		local flips, worstStep = 0, 0
		local monotone = true
		while fwd > -6 do
			local pull = P.ringPull(fwd, math.abs(lat))
			local step = 0
			if pull > 0 and math.abs(lat) > 1e-3 then
				local side = if new then P.ringPullLateral(pull, math.abs(lat), dt) else pull
				step = side * dt
			end
			local nextLat = lat - (if lat >= 0 then 1 else -1) * step
			if (nextLat > 0) ~= (lat > 0) and math.abs(lat) > 1e-3 then
				flips += 1
				worstStep = math.max(worstStep, math.abs(nextLat))
			end
			if math.abs(nextLat) > math.abs(lat) + 1e-9 then
				monotone = false
			end
			lat = nextLat
			fwd -= speed * dt
		end
		return flips, worstStep, monotone
	end

	h.test("2. C2 ring pull settles onto the axis instead of crossing it every frame", function()
		report("C2 ring pull: axis crossings / worst overshoot (studs), old -> new")
		for _, fps in { 30, 60, 144 } do
			for _, start in { 2, 8, 20 } do
				local of, ow = runRing(start, 128, 1 / fps, false)
				local nf, nw, mono = runRing(start, 128, 1 / fps, true)
				report(string.format("  %3d fps start %2d: %3d / %.2f -> %d / %.2f", fps, start, of, ow, nf, nw))
				h.eq(nf, 0, string.format("%d fps start %d: never crosses the axis", fps, start))
				h.ok(mono, string.format("%d fps start %d: the offset only shrinks", fps, start))
				if start <= 8 then
					h.ok(of >= 2, string.format("%d fps start %d: the old pull chattered (%d crossings)", fps, start, of))
				end
			end
		end
		-- The catch (flight_feel_spec 7) with the settle: the widest start that still passes inside the trigger.
		local best = 0
		for start = 0, 40, 0.5 do
			local lat, fwd, dt = start, P.RING_PULL_DISTANCE + 20, 1 / 60
			local hit = false
			while fwd > -6 do
				if math.sqrt(lat * lat + fwd * fwd) <= P.RING_TRIGGER_RADIUS then
					hit = true
					break
				end
				lat = math.max(0, lat - P.ringPullLateral(P.ringPull(fwd, lat), lat, dt) * dt)
				fwd -= 110 * dt
			end
			if hit then
				best = start
			end
		end
		h.ok(best >= 27, string.format("catch still %.1f studs (>= 27)", best))
		h.eq(P.ringPullLateral(26, 0, 1 / 60), 0, "nothing on the axis")
		h.ok(P.ringPullLateral(26, 0.2, 1 / 60) * (1 / 60) <= 0.2, "one frame never passes the axis")
		h.ok(P.ringPullLateral(26, 0.1, 0.25) * 0.25 <= 0.1, "nor does a long frame")
		h.eq(P.ringPullLateral(26, 20, 1 / 60), 26, "full strength off the axis")
	end)

	-- ------------------------------------------------------------------ 3. plane bots on a polyline
	-- A closed loop shaped like a race course (radius 450-950), cut into ~27-stud chords like DINO-4's waypoints.
	local wps: { { pos: Vector3, station: number } } = {}
	local total = 0
	do
		local fine = {}
		for i = 0, 3600 do
			local a = i / 3600 * 2 * math.pi
			local r = 700 + 220 * math.sin(3 * a) + 40 * math.sin(7 * a)
			fine[i + 1] = Vector3.new(r * math.cos(a), 150 + 20 * math.sin(2 * a), r * math.sin(a))
		end
		local acc = 0
		table.insert(wps, { pos = fine[1], station = 0 })
		local last = fine[1]
		for i = 2, #fine do
			acc += (fine[i] - fine[i - 1]).Magnitude
			if acc >= 27.4 then
				total += (fine[i] - last).Magnitude
				table.insert(wps, { pos = fine[i], station = total })
				last = fine[i]
				acc = 0
			end
		end
		total += (fine[1] - last).Magnitude
		table.insert(wps, { pos = fine[1], station = total })
	end
	-- SplineUtils.sampleAtStation's algorithm (bisect, lerp, chord tangent; bank 0 here). Guarded in test 4.
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
	-- renderPlane at the fixed 1/60 s server step: returns per-step hull position jerk (studs) and roll jerk (deg).
	local function runBot(new: boolean, lateral: number, speed: number): ({ number }, { number }, number)
		local dt = 1 / 60
		local station = 0
		local hull: CFrame? = nil
		local hist: { CFrame } = {}
		local posJerk, rollJerk = {}, {}
		local bankSum, bankN = 0, 0
		for step = 1, math.floor(total / speed / dt) do
			station += speed * dt
			local pos, tan = sample(station)
			local aheadPos, aheadTan = sample(station + 28)
			if new then
				pos, tan = AI.pathFrame(sample, station)
				aheadPos, aheadTan = AI.pathFrame(sample, station + 28)
			end
			local right = rightOf(tan)
			local worldPos = pos + right * lateral
			local lookTarget = aheadPos + right * lateral
			local lookDir = (lookTarget - worldPos).Unit
			local dynamicBank = math.clamp(-tan:Cross(aheadTan).Y * 180, -52, 52)
			bankSum += math.abs(dynamicBank)
			bankN += 1
			local goal = lookAt(worldPos, worldPos + lookDir) * CFrame.Angles(0, 0, math.rad(dynamicBank))
			hull = if hull then hull:Lerp(goal, math.clamp(dt * 12, 0, 1)) else goal
			table.insert(hist, hull :: CFrame)
			local n = #hist
			if step > 60 and n >= 3 then
				local a, b, c = hist[n - 2], hist[n - 1], hist[n]
				table.insert(posJerk, (c.Position - b.Position * 2 + a.Position).Magnitude)
				local function roll(cf: CFrame): number
					return math.deg(math.asin(math.clamp(cf.RightVector.Y, -1, 1)))
				end
				table.insert(rollJerk, math.abs(roll(c) - 2 * roll(b) + roll(a)))
			end
		end
		return posJerk, rollJerk, bankSum / math.max(bankN, 1)
	end

	h.test("3. C5 plane bots: a continuous path frame on the polyline", function()
		local angles = {}
		for i = 2, #wps - 1 do
			local a = (wps[i].pos - wps[i - 1].pos).Unit
			local b = (wps[i + 1].pos - wps[i].pos).Unit
			table.insert(angles, math.deg(math.acos(math.clamp(a:Dot(b), -1, 1))))
		end
		report(string.format("C5 polyline: %d waypoints, %.0f studs, corner p50 %.1f / max %.1f deg", #wps, total, pct(angles, 0.5), maxOf(angles)))
		report("C5 plane bot: hull jerk studs/step and roll jerk deg/step (p95 / max), old -> new")
		for _, lateral in { 0, 6, 12 } do
			local op, orr, ob = runBot(false, lateral, 150)
			local np, nr, nb = runBot(true, lateral, 150)
			report(string.format("  lateral %2d: pos %.3f / %.3f -> %.3f / %.3f   roll %.2f / %.2f -> %.3f / %.3f   mean |bank| %.1f -> %.1f",
				lateral, pct(op, 0.95), maxOf(op), pct(np, 0.95), maxOf(np), pct(orr, 0.95), maxOf(orr), pct(nr, 0.95), maxOf(nr), ob, nb))
			h.ok(pct(nr, 0.95) < pct(orr, 0.95) * 0.25, string.format("lateral %d: roll jerk p95 under a quarter of the old", lateral))
			h.ok(maxOf(nr) < maxOf(orr) * 0.2, string.format("lateral %d: roll jerk max %.3f deg/step (old %.2f)", lateral, maxOf(nr), maxOf(orr)))
			h.ok(maxOf(np) < maxOf(op) * 0.75, string.format("lateral %d: hull jerk max %.4f studs/step (old %.3f)", lateral, maxOf(np), maxOf(op)))
			if lateral == 12 then
				h.ok(pct(op, 0.95) > pct(np, 0.95) * 3, "lateral 12: the old frame hopped sideways at waypoints")
			end
			h.ok(math.abs(nb - ob) < 0.15 * ob + 0.3, string.format("lateral %d: the same bank on average (%.1f vs %.1f)", lateral, nb, ob))
		end
		-- The central difference is continuous across a waypoint.
		local w = wps[40]
		local p0, t0 = AI.pathFrame(sample, w.station - 1e-3)
		local p1, t1 = AI.pathFrame(sample, w.station + 1e-3)
		h.ok((t0 - t1).Magnitude < 1e-3 and (p0 - p1).Magnitude < 1e-2, "no step at a waypoint")
		-- Close to the line: the box filter sits inside a bend, most at the sharpest corners (24 deg here).
		local worst = 0
		for st = 0, total, 7 do
			worst = math.max(worst, (AI.pathFrame(sample, st) - sample(st)).Magnitude)
		end
		h.ok(worst < 2.0, string.format("within %.2f studs of the polyline (lanes are +-12)", worst))
	end)

	h.test("4. source guards", function()
		local fc = h.readFile("src/client/FlightController.luau")
		for _, needle in { "PlaneConfig.camFollow(", "PlaneConfig.camTrail(", "PlaneConfig.ringPullLateral(", "local here = simPos",
			"updateChaseCamera(finalCF, clampedDt, velocityVec)", "evaluateRingsAndPads(here, lookVec, clampedDt)" } do
			h.ok(string.find(fc, needle, 1, true) ~= nil, needle)
		end
		h.ok(string.find(fc, "dt * 18", 1, true) == nil, "the old frame-rate lerp is gone")
		h.ok(string.find(fc, "evaluateRingsAndPads(hull.Position", 1, true) == nil, "no physics-drifted position in the pulls")
		local ai = h.readFile("src/server/AIRacers.luau")
		h.ok(string.find(ai, "local pos, tan, bank = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station)", 1, true) ~= nil, "renderPlane uses the smooth tangent")
		local su = h.readFile("src/shared/SplineUtils.luau")
		h.ok(string.find(su, "local rawTan = w2.pos - w1.pos", 1, true) ~= nil, "SplineUtils still returns the chord tangent (the replay's model)")
		h.ok(string.find(ai, "RacerViewRules.serverSteps", 1, true) ~= nil, "the jitter fix's fixed bot step is intact")
	end)
end
