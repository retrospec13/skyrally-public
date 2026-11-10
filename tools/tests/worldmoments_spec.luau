--!strict
-- Lune spec for World Moments (docs/REMARKABLE.md items 10 and 11): the pure rules in src/shared/WorldMomentsRules.luau
-- (sneeze pose and once-per-race trigger, camera trauma, hatchling path, horn-answer pick, cooldown and the 6/6
-- session counter) plus static checks that the client and server halves stay visual-only and never touch the horn's
-- validation or a racer.
-- Run: tools/tests/run_lune_tests.sh tools/tests/worldmoments_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	readFile: (string) -> string,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
	stubs: any,
}

return function(h: Harness)
	local R = h.require("src/shared/WorldMomentsRules.luau")

	local function near(a: number, b: number, eps: number, msg: string)
		h.ok(math.abs(a - b) <= eps, string.format("%s: %.4f vs %.4f", msg, a, b))
	end

	---------------------------------------------------------------------------------------------- sneeze pose

	h.test("sneeze: phases run inhale 1.2 s -> sneeze 0.25 s -> recover 1.5 s, idle before and after", function()
		near(R.sequenceSec(), 2.95, 1e-9, "sequence length")
		h.eq((R.phase(nil)), "idle")
		h.eq((R.phase(-0.1)), "idle")
		h.eq((R.phase(0)), "inhale")
		h.eq((R.phase(1.19)), "inhale")
		h.eq((R.phase(1.21)), "sneeze")
		h.eq((R.phase(1.46)), "recover")
		h.eq((R.phase(2.94)), "recover")
		h.eq((R.phase(2.96)), "idle")
	end)

	h.test("sneeze: the pose rears back 8, snaps to -14 with a 3-stud lunge and lands exactly on rest", function()
		local p0, l0 = R.pose(0)
		near(p0, 0, 1e-9, "starts at rest (pitch)")
		near(l0, 0, 1e-9, "starts at rest (lunge)")
		local pIn, lIn = R.pose(1.2 - 1e-6)
		near(pIn, 8, 0.01, "end of inhale pitch")
		near(lIn, -0.6, 0.01, "end of inhale draws back")
		local pSn, lSn = R.pose(1.45 - 1e-6)
		near(pSn, -14, 0.01, "end of snap pitch")
		near(lSn, 3, 0.01, "end of snap lunge")
		local pEnd, lEnd = R.pose(2.95 - 1e-6)
		near(pEnd, 0, 0.01, "recovers to 0 pitch")
		near(lEnd, 0, 0.01, "recovers to 0 lunge")
		local pIdle, lIdle = R.pose(3.5)
		h.eq(pIdle, 0)
		h.eq(lIdle, 0)
	end)

	h.test("sneeze: the pose is continuous (no pops between frames at 60 Hz) and stays inside +8.5 / -14", function()
		local prevP, prevL = R.pose(0)
		local maxStep = 0
		for i = 1, math.floor(2.95 * 240) do
			local t = i / 240
			local p, l = R.pose(t)
			h.ok(p <= 8.5 and p >= -14.01, string.format("pitch %.2f out of range at %.3f", p, t))
			h.ok(l <= 3.01 and l >= -0.61, string.format("lunge %.2f out of range at %.3f", l, t))
			if math.abs(p - prevP) > maxStep then
				maxStep = math.abs(p - prevP)
			end
			h.ok(math.abs(l - prevL) < 0.2, string.format("lunge jump at %.3f", t))
			prevP, prevL = p, l
		end
		-- the snap is fast on purpose (22 degrees in 0.25 s) but has no discontinuity: < 1 degree per 1/240 s
		h.ok(maxStep < 1, string.format("largest pitch step %.3f", maxStep))
	end)

	h.test("sneeze: a positive pitch about the head axis raises the head and moves it back over the body", function()
		for _, off in { Vector3.new(-33, 57, 0), Vector3.new(33, 57, 0), Vector3.new(10, 40, -25) } do
			local dir, axis = R.headFrame(off)
			near(dir.Y, 0, 1e-9, "head direction is horizontal")
			near(dir.Magnitude, 1, 1e-6, "unit direction")
			local back = CFrame.fromAxisAngle(axis, math.rad(8)) * off
			h.ok(back.Y > off.Y, "inhale lifts the head")
			h.ok(back:Dot(dir) < off:Dot(dir), "inhale pulls the head back")
			local fwd = CFrame.fromAxisAngle(axis, math.rad(-14)) * off
			h.ok(fwd:Dot(dir) > off:Dot(dir), "sneeze throws the head forward")
		end
		local dir = R.headFrame(Vector3.new(0, 50, 0))
		h.eq(dir, Vector3.new(-1, 0, 0), "a head straight above the pivot falls back to the build's -X")
	end)

	h.test("sneeze: the nose sits at the front top of the mesh box (head at -X in the build)", function()
		local n = R.noseLocal(Vector3.new(73, 62, 20))
		h.ok(n.X < -30 and n.Y > 20 and n.Z == 0, tostring(n))
	end)

	h.test("sneeze: camera trauma is 0.4 at the nose, falls off linearly and is 0 from 150 studs", function()
		near(R.trauma(0), 0.4, 1e-9, "at the nose")
		near(R.trauma(75), 0.2, 1e-9, "halfway")
		h.eq(R.trauma(150), 0)
		h.eq(R.trauma(400), 0)
		near(R.trauma(-5), 0.4, 1e-9, "never above the cap")
	end)

	---------------------------------------------------------------------------------------------- once per race

	h.test("trigger: the sneeze lap is 2 or 3 (clamped to short races) and both values occur", function()
		local seen = {}
		local seed = 7
		for _ = 1, 200 do
			local p = R.newPlan(3, 100, function(a: number, b: number): number
				seed = (seed * 1103515245 + 12345) % 2147483648 -- deterministic LCG (no Random under Lune)
				return a + seed % (b - a + 1)
			end)
			h.ok(p.lap == 2 or p.lap == 3, "lap " .. p.lap)
			seen[p.lap] = true
		end
		h.ok(seen[2] and seen[3], "both laps drawn")
		h.eq(R.newPlan(1, 0, math.random).lap, 1, "one-lap race sneezes on lap 1")
		h.eq(R.newPlan(2, 0, math.random).lap, 2, "two-lap race sneezes on lap 2")
	end)

	h.test("trigger: the station leads the statue by 220 studs, stays inside the lap, and a plan value wins", function()
		h.eq(R.sneezeStation(1000), 780)
		h.eq(R.sneezeStation(160), 20, "statue near the start line: clamped to just after it")
		h.eq(R.sneezeStation(1000, 444), 444)
	end)

	local function simulateRace(lapPlan: number, statueStation: number, totalLen: number, stepStuds: number, jumps: { [number]: number }?): { { lap: number, station: number } }
		local plan = R.newPlan(3, R.sneezeStation(statueStation), function(): number
			return lapPlan
		end)
		local fired = {}
		local progress = -300 -- the grid sits behind the line
		local step = 0
		while progress < 3 * totalLen do
			step += 1
			progress += stepStuds + ((jumps and jumps[step]) or 0)
			local lap = math.max(1, math.floor(progress / totalLen) + 1)
			local station = progress % totalLen
			if R.planDue(plan, lap, station, totalLen) then
				plan.done = true
				table.insert(fired, { lap = lap, station = station })
			end
		end
		return fired
	end

	h.test("trigger: exactly one sneeze per race, on the planned lap, at the station (DINO-4 sized race)", function()
		for _, lapPlan in { 2, 3 } do
			for _, stepStuds in { 2.3, 4.7, 9 } do -- 140..540 studs/s at 60 Hz
				local fired = simulateRace(lapPlan, 160, 5450, stepStuds)
				h.eq(#fired, 1, string.format("lap %d step %.1f", lapPlan, stepStuds))
				h.eq(fired[1].lap, lapPlan)
				h.ok(fired[1].station >= 20 and fired[1].station < 20 + stepStuds + 1, "at the station " .. fired[1].station)
			end
		end
		local mid = simulateRace(2, 2600, 5450, 4)
		h.eq(#mid, 1)
		h.ok(mid[1].station >= 2380 and mid[1].station < 2385, "mid-lap statue " .. mid[1].station)
	end)

	h.test("trigger: a leader who jumps past the window still gets the one sneeze on the next lap", function()
		-- lap 2 window at 20..420: a 600-stud jump (respawn ahead) right before it skips the window
		local fired = simulateRace(2, 160, 5450, 4, { [math.floor((5450 + 300) / 4)] = 600 })
		h.eq(#fired, 1)
		h.eq(fired[1].lap, 3, "moved to lap 3")
		local plan = R.newPlan(3, 20, function(): number
			return 3
		end)
		h.eq(R.planDue(plan, 4, 30, 5450), false, "past the last lap: no sneeze")
		h.ok(plan.done, "and the plan closes")
		local again = R.newPlan(3, 20, function(): number
			return 2
		end)
		h.eq(R.planDue(again, 1, 30, 5450), false, "not on lap 1")
		h.eq(R.planDue(again, 2, 10, 5450), false, "not before the station")
		h.eq(R.planDue(again, 2, 30, 5450), true, "inside the window")
		again.done = true
		h.eq(R.planDue(again, 2, 31, 5450), false, "never twice")
	end)

	h.test("hatchling: one race in 20; the flight leaves the nose, tumbles out forward and climbs 120 studs", function()
		h.eq(R.HATCHLING_ODDS, 20)
		h.eq(R.HATCHLING_SEC, 4)
		local nose, fwd, side = Vector3.new(50, 200, -158), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)
		h.eq(R.hatchlingPoint(0, nose, fwd, side), nose)
		local last = R.hatchlingPoint(1, nose, fwd, side)
		near(last.Y - nose.Y, 120, 1e-6, "climbs to the roof")
		h.ok((R.hatchlingPoint(0.15, nose, fwd, side) - nose):Dot(fwd) > 5, "first out of the nose, forward")
		local prevY = -math.huge
		for i = 3, 10 do
			local y = R.hatchlingPoint(i / 10, nose, fwd, side).Y
			h.ok(y > prevY, "keeps climbing after the tumble")
			prevY = y
		end
	end)

	---------------------------------------------------------------------------------------------- horn answers

	h.test("horn: six landmarks, one per launch map, six distinct answers, reach 70, delay 0.45, cooldown 4", function()
		h.eq(R.ANSWER_KINDS, 6)
		local maps, answers = {}, {}
		for _, d in R.LANDMARKS do
			maps[d.map] = true
			answers[d.answer] = true
		end
		for _, m in { "ISLAND-2", "HUB-0", "FOREST-1", "SNOW-1", "SPACE-4", "DINO-4" } do
			h.ok(maps[m], "map " .. m)
		end
		for _, a in { "foghorn", "fountain", "cuckoo", "puff", "chime", "honk" } do
			h.ok(answers[a], "answer " .. a)
		end
		h.eq(R.HORN_REACH, 70)
		h.eq(R.HORN_DELAY, 0.45)
		h.eq(R.HORN_COOLDOWN, 4)
	end)

	h.test("horn: distance is measured to the landmark's box (0 inside, rotated boxes too)", function()
		local cf = CFrame.new(100, 10, 0) * CFrame.Angles(0, math.rad(45), 0)
		local size = Vector3.new(40, 20, 10)
		h.eq(R.distToBox(cf, size, Vector3.new(100, 10, 0)), 0)
		near(R.distToBox(cf, size, cf * Vector3.new(0, 0, 5 + 70)), 70, 1e-3, "70 off the narrow face")
		near(R.distToBox(cf, size, cf * Vector3.new(20 + 30, 10 + 40, 0)), 50, 1e-3, "corner distance")
	end)

	h.test("horn: within 70 studs answers, from 100 nothing; nearest wins; each landmark cools down for 4 s", function()
		local fountain = { cf = CFrame.new(0, 0, 0), size = Vector3.new(40, 24, 40), reach = 70, readyAt = -math.huge }
		local lodge = { cf = CFrame.new(150, 0, 0), size = Vector3.new(60, 60, 44), reach = 70, readyAt = -math.huge }
		local cands = { fountain, lodge }
		h.eq(R.pickLandmark(cands, Vector3.new(0, 0, 20 + 69), 0), 1, "69 studs off the fountain")
		h.eq(R.pickLandmark(cands, Vector3.new(0, 0, 20 + 100), 0), nil, "100 studs: nothing")
		h.eq(R.pickLandmark(cands, Vector3.new(85, 0, 0), 0), 2, "between them: the lodge box is nearer (35 vs 65)")
		fountain.readyAt = 10 + R.HORN_COOLDOWN
		h.eq(R.pickLandmark(cands, Vector3.new(0, 0, 30), 12), nil, "fountain cooling down, lodge out of reach")
		h.eq(R.pickLandmark(cands, Vector3.new(0, 0, 30), 14), 1, "ready again after 4 s")
		h.eq(R.pickLandmark({}, Vector3.zero, 0), nil)
	end)

	h.test("horn: the session counter counts distinct kinds and fires the 6/6 toast exactly once", function()
		local heard = {}
		local fired = 0
		local last = 0
		for _, a in { "fountain", "fountain", "chime", "nonsense", "honk", "puff", "cuckoo", "chime", "foghorn", "honk" } do
			local n, complete = R.markHeard(heard, a)
			last = n
			if complete then
				fired += 1
			end
		end
		h.eq(last, 6)
		h.eq(fired, 1)
		h.eq(R.SESSION_TOAST, "The world talks back (6/6)")
	end)

	h.test("horn: the smoke ring has evenly spaced unit directions tilted up", function()
		local dirs = R.ringDirections(16, 0.7)
		h.eq(#dirs, 16)
		local sum = Vector3.zero
		for _, d in dirs do
			near(d.Magnitude, 1, 1e-6, "unit")
			h.ok(d.Y > 0.5, "tilted up")
			sum += Vector3.new(d.X, 0, d.Z)
		end
		h.ok(sum.Magnitude < 1e-6, "balanced ring")
	end)

	---------------------------------------------------------------------------------------------- static guards

	h.test("static: the client listens to the horn relay but never fires it and never changes a vehicle", function()
		local src = h.readFile("src/client/WorldMoments.luau")
		h.ok(not string.find(src, "FireServer", 1, true), "no FireServer")
		h.ok(not string.find(src, "AssemblyLinearVelocity", 1, true), "no physics")
		h.ok(not string.find(src, ":SetAttribute(\"Speed\"", 1, true), "no speed writes")
		h.contains(src, "OnClientEvent")
		h.contains(src, "kind == \"Horn\"")
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "WorldMoments" }')
	end)

	h.test("static: the server sneeze only poses the statue and publishes attributes; RaceManager calls it", function()
		local src = h.readFile("src/server/SauropodSneeze.luau")
		h.ok(not string.find(src, "%.speed%s*="), "no speed writes")
		h.ok(not string.find(src, "%.station%s*="), "no progress writes")
		h.ok(not string.find(src, "%.lap%s*=[^=]"), "no lap writes")
		h.ok(not string.find(src, "CanCollide = true", 1, true), "nothing collides")
		for _, attr in { "SauropodInhaleAt", "SauropodSneezeAt", "SauropodHatchling", "TriggerSauropodSneeze" } do
			h.contains(src, attr)
		end
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "SauropodSneeze.apply(dino, swayCF")
		local svc = h.readFile("src/server/CosmeticService.luau")
		h.ok(not string.find(svc, "WorldMoments", 1, true), "horn validation untouched")
	end)
end
