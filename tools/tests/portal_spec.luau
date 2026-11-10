-- Portal Plunge rules (REMARKABLE Batch 2 item 20, trap audit H0-09; shared/PortalRules): an arch only counts when a
-- vehicle drives THROUGH its opening from the plaza side, the warp holds unless the car backs out or swings away, a
-- locked arch spits only a car that is about to touch the veil, the spit is never faster than the car's reverse, and
-- the FOV and iris curves stay in range. The hub's real arches come from build/hub0/TrackData.
return function(h)
	local R = h.require("src/shared/PortalRules.luau")

	-- PortalArch_SNOW as authored (bearing -40 on the r 118 ring; LookVector points out of the plaza).
	local SNOW = CFrame.new(-8225.8489, 37.0, 7909.6068, 0.7660, 0.0, 0.6428, 0.0, 1.0, 0.0, -0.6428, 0.0, 0.7660)
	local HULL_DROP = Vector3.new(0, -9, 0) -- a car hull rides ~28, the cf is at 37

	local function at(cf: CFrame, side: number, lateral: number, up: number?): Vector3
		return cf.Position + cf.LookVector * side + cf.RightVector * lateral + (if up then Vector3.new(0, up, 0) else HULL_DROP)
	end

	h.test("frame: the authored SNOW arch looks out of the plaza (centre -8150, 8000)", function()
		local plaza = Vector3.new(-8150, 37, 8000)
		h.ok(R.side(plaza, SNOW) < -100, "the plaza centre is on the negative side")
	end)

	h.test("crossed: driving straight through from the plaza counts", function()
		h.ok(R.crossed(at(SNOW, -10, 0), at(SNOW, 10, 0), SNOW))
		h.ok(R.crossed(at(SNOW, -2, 9), at(SNOW, 3, 10), SNOW), "near a pillar, still inside the opening")
	end)

	h.test("crossed: a 0.2 s server sample at full speed (25 studs) is judged where it met the veil", function()
		h.ok(R.crossed(at(SNOW, -20, 2), at(SNOW, 5.6, 4), SNOW))
	end)

	h.test("crossed: driving out of the arch toward the plaza never counts", function()
		h.ok(not R.crossed(at(SNOW, 10, 0), at(SNOW, -10, 0), SNOW))
	end)

	h.test("crossed H0-09 probe 1: a tangential pass 8 studs outside the arch plane is not a crossing", function()
		h.ok(not R.crossed(at(SNOW, 8, -30), at(SNOW, 8, 30), SNOW))
		h.ok(not R.crossed(at(SNOW, -8, -30), at(SNOW, -8, 30), SNOW), "or 8 studs in front of it")
	end)

	h.test("crossed: through the plane beside the arch (outside the opening) does not count", function()
		h.ok(not R.crossed(at(SNOW, -10, 20), at(SNOW, 10, 20), SNOW))
		h.ok(not R.crossed(at(SNOW, -10, -16), at(SNOW, 10, -16), SNOW))
	end)

	h.test("crossed: a plane flying over the arch, or a respawn jump across it, does not count", function()
		h.ok(not R.crossed(at(SNOW, -10, 0, 25), at(SNOW, 10, 0, 25), SNOW), "over the top")
		h.ok(R.crossed(at(SNOW, -10, 0, 12), at(SNOW, 10, 0, 12), SNOW), "a plane through the round top does")
		h.ok(not R.crossed(at(SNOW, -90, 0), at(SNOW, 10, 0), SNOW), "a 100-stud jump is a teleport")
	end)

	h.test("warpHolds: anywhere beyond the veil holds; only backing out onto the plaza cancels", function()
		h.ok(R.warpHolds(at(SNOW, 1, 0), SNOW))
		h.ok(R.warpHolds(at(SNOW, 90, 6), SNOW))
		h.ok(R.warpHolds(at(SNOW, -2, 0), SNOW), "a nose bump back is inside the slack")
		h.ok(not R.warpHolds(at(SNOW, -5, 0), SNOW), "reversed out onto the plaza")
		h.ok(R.warpHolds(at(SNOW, 30, 50), SNOW), "portal-load: steering away after the veil no longer cancels")
	end)

	h.test("portal-load: a fast pass at an angle holds for the whole 1.5 s warp (the owner's failed loads)", function()
		-- 150 studs/s, 25 degrees off the arch's axis, sampled at 60 Hz for the full countdown: never cancelled.
		local dir = SNOW.LookVector * math.cos(math.rad(25)) + SNOW.RightVector * math.sin(math.rad(25))
		local start = at(SNOW, 0.5, 0)
		for i = 0, 90 do
			local pos = start + dir * (150 * i / 60)
			h.ok(R.warpHolds(pos, SNOW), "sample " .. i)
		end
	end)

	h.test("maxStep: a long gap between samples scales the teleport guard; a short one keeps MAX_STEP", function()
		h.eq(R.maxStep(0.2), R.MAX_STEP)
		h.eq(R.maxStep(nil), R.MAX_STEP)
		h.eq(R.maxStep(0.5), 160)
		h.ok(R.MAX_RATE > 210, "faster than any boost (overcharge / item level 3 = 210)")
		-- 300 studs/s with a 0.5 s server hitch: a 150-stud segment through the veil still counts with the dt guard.
		h.ok(not R.crossed(at(SNOW, -75, 0), at(SNOW, 75, 0), SNOW), "the bare guard calls it a teleport")
		h.ok(R.crossed(at(SNOW, -75, 0), at(SNOW, 75, 0), SNOW, R.maxStep(0.5)), "the dt guard does not")
		h.ok(not R.crossed(at(SNOW, -300, 0), at(SNOW, 10, 0), SNOW, R.maxStep(0.2)), "a 310-stud jump in 0.2 s is a respawn")
	end)

	-- Feeds a straight run (studs/s, Hz) from `from` to `to` studs of side through `cf` into a fresh watch.
	local function run(cf: CFrame, speed: number, hz: number, from: number, to: number, lateral: number, up: number?): number
		local w = R.newWatch()
		local fired = 0
		local t, side = 0, from
		while side <= to do
			if R.watchStep(w, at(cf, side, lateral, up), t, { cf }) then
				fired += 1
			end
			t += 1 / hz
			side += speed / hz
		end
		return fired
	end

	h.test("watchStep: 300 studs/s at 10 Hz (30-stud samples) through the opening fires exactly once", function()
		for _, lat in { -12, -6, 0, 6, 12 } do
			h.eq(run(SNOW, 300, 10, -150, 150, lat), 1, "lateral " .. lat)
		end
		h.eq(run(SNOW, 300, 10, -150, 150, 0, 8), 1, "a plane through the round top")
		-- every phase of the 30-stud sample grid against the veil
		for off = 0, 29 do
			h.eq(run(SNOW, 300, 10, -150 + off, 150, 0), 1, "phase " .. off)
		end
	end)

	h.test("watchStep: car, hovercraft, plane and boost speeds at 5 / 10 / 30 / 60 Hz all fire exactly once", function()
		for _, speed in { 8, 34, 78, 128, 165, 210, 300 } do
			for _, hz in { 5, 10, 30, 60 } do
				h.eq(run(SNOW, speed, hz, -100, 100, 3), 1, speed .. " studs/s at " .. hz .. " Hz")
			end
		end
	end)

	h.test("watchStep: beside the arch, over it, or driving out of it never fires", function()
		h.eq(run(SNOW, 300, 10, -150, 150, 20), 0, "beside")
		h.eq(run(SNOW, 300, 10, -150, 150, 0, 25), 0, "over the top")
		local w = R.newWatch()
		local fired = 0
		for i = 0, 20 do
			if R.watchStep(w, at(SNOW, 100 - i * 10, 0), i * 0.1, { SNOW }) then
				fired += 1
			end
		end
		h.eq(fired, 0, "out of the arch toward the plaza")
	end)

	h.test("watchStep: no double trigger nosing back and forth on the veil; backing out onto the plaza re-arms", function()
		local w = R.newWatch()
		local t = 0
		local fired = 0
		local function feed(side: number)
			t += 1 / 60
			if R.watchStep(w, at(SNOW, side, 0), t, { SNOW }) then
				fired += 1
			end
		end
		feed(-10)
		feed(1)
		h.eq(fired, 1, "the pass")
		for _ = 1, 20 do
			feed(-2) -- inside the CANCEL_BACK slack
			feed(1)
		end
		h.eq(fired, 1, "jitter on the veil never fires again")
		feed(-10) -- backed out onto the plaza
		feed(5)
		h.eq(fired, 2, "a new pass after backing out fires again")
		for _ = 1, 30 do
			feed(5) -- parked in the veil
		end
		h.eq(fired, 2, "parked inside never fires")
	end)

	h.test("watchStep: several arches, the one driven through is reported; a reset never fakes a crossing", function()
		local td = h.require("build/hub0/TrackData.luau")
		local cfs = {}
		for _, p in td.hub.portals do
			table.insert(cfs, p.cf)
		end
		for i, cf in cfs do
			local w = R.newWatch()
			local got = nil
			for k = 0, 10 do
				local hit = R.watchStep(w, at(cf, -100 + k * 20, 2), k * 0.1, cfs)
				if hit then
					h.ok(got == nil, "once")
					got = hit
				end
			end
			h.eq(got, i, td.hub.portals[i].zone)
		end
		local w = R.newWatch()
		R.watchStep(w, at(SNOW, -10, 0), 0, { SNOW })
		R.resetWatch(w)
		h.eq(R.watchStep(w, at(SNOW, 10, 0), 0.1, { SNOW }), nil, "a set-down past the veil is not a drive")
	end)

	h.test("inSpitZone: only a car about to touch a locked veil, inside the opening, moving toward it", function()
		local toward = SNOW.LookVector * 40
		h.ok(R.inSpitZone(at(SNOW, -4, 0), toward, SNOW))
		h.ok(R.inSpitZone(at(SNOW, 0.5, -10), toward, SNOW), "at the veil near a pillar")
		h.ok(not R.inSpitZone(at(SNOW, -4, 0), Vector3.zero, SNOW), "parked in front")
		h.ok(not R.inSpitZone(at(SNOW, -4, 0), -toward, SNOW), "reversing away")
		h.ok(not R.inSpitZone(at(SNOW, -10, 0), toward, SNOW), "still far off")
		h.ok(not R.inSpitZone(at(SNOW, -4, 22), toward, SNOW), "beside the arch")
		h.ok(not R.inSpitZone(at(SNOW, 4, 0), toward, SNOW), "already through (the server's PortalLocked covers that)")
	end)

	h.test("spitSpeed: backwards, a fraction of the way in, never past the car's reverse top speed", function()
		h.eq(R.spitSpeed(128, 34), -34, "full speed is capped at reverse top")
		h.eq(R.spitSpeed(40, 34), -24, "0.6 of 40")
		h.eq(R.spitSpeed(5, 34), -16, "a crawl still gets a visible spit")
		h.eq(R.spitSpeed(5, 10), -10, "the cap wins over the minimum")
		h.ok(R.spitSpeed(80, 0) == 0, "no reverse, no spit speed")
		for s = 0, 200, 7 do
			local v = R.spitSpeed(s, 34)
			h.ok(v <= 0 and v >= -34, "speed " .. s)
		end
	end)

	h.test("fovAt: starts at the base, stretches 45 by the end of the warp, capped at 118", function()
		h.eq(R.fovAt(0, 68), 68)
		h.ok(math.abs(R.fovAt(R.WARP_SECONDS, 68) - 113) < 1e-9)
		h.eq(R.fovAt(5, 68), 113, "holds after the warp")
		h.eq(R.fovAt(R.WARP_SECONDS, 90), 118, "capped")
		local last = 0
		for i = 0, 30 do
			local f = R.fovAt(i * 0.05, 68)
			h.ok(f >= last, "never shrinks")
			last = f
		end
	end)

	h.test("irisClose: 1 -> pause on the car at about IRIS_HOLD -> 0; irisOpen pops past 1 then settles", function()
		h.eq(R.irisClose(0), 1)
		h.eq(R.irisClose(1), 0)
		local mid = R.irisClose((R.IRIS_HOLD_FROM + R.IRIS_HOLD_TO) / 2)
		h.ok(mid >= R.IRIS_HOLD and mid <= R.IRIS_HOLD * 1.13, "the hold frames the car")
		for i = 0, 100 do
			local v = R.irisClose(i / 100)
			h.ok(v >= 0 and v <= 1, "in range at " .. i)
		end
		h.eq(R.irisOpen(0), 0)
		h.eq(R.irisOpen(1), 1)
		local over = false
		for i = 1, 99 do
			if R.irisOpen(i / 100) > 1 then
				over = true
			end
		end
		h.ok(over, "overshoots for the pop")
	end)

	h.test("bubbleText: the server's reason, shouted", function()
		h.eq(R.bubbleText("needs 2 Sky Tokens"), "NOT YET! NEEDS 2 SKY TOKENS")
		h.eq(R.bubbleText("opens after the final boss"), "LOCKED! OPENS AFTER THE FINAL BOSS")
		h.eq(R.bubbleText(nil), "LOCKED! LOCKED")
	end)

	h.test("hub data: every authored arch is crossable straight through and a graze of each is not", function()
		local td = h.require("build/hub0/TrackData.luau")
		local portals = td.hub.portals
		h.eq(#portals, 5)
		for _, p in portals do
			h.ok(R.crossed(at(p.cf, -12, 0), at(p.cf, 12, 0), p.cf), p.zone .. " straight through")
			h.ok(not R.crossed(at(p.cf, 8, -40), at(p.cf, 8, 40), p.cf), p.zone .. " tangential graze")
			h.ok(R.side(Vector3.new(-8150, 37, 8000), p.cf) < 0, p.zone .. " faces out of the plaza")
		end
	end)

	h.test("static: the server triggers on PortalRules.crossed (not the old 15-stud sphere) and warps with a cancel", function()
		local src = h.readFile("src/server/TrackDirector.luau")
		h.contains(src, "PortalRules.watchStep(watch.w, pos, now, cfs)")
		h.contains(src, "PortalRules.warpHolds(pos, w.cf)")
		h.contains(src, "stepPortals() -- portal-load: every frame", "the crossing watch runs every Heartbeat")
		h.contains(src, "why = \"backed out\"", "a cancel says why")
		h.contains(src, "\"PortalWarp\"")
		h.contains(src, "\"PortalWarpCancel\"")
		h.ok(not string.find(src, "Magnitude < TrackDirector.PORTAL_RADIUS", 1, true), "the radius trigger is gone")
	end)

	h.test("static: the client plunge is visual only; the only speed it writes is the capped spit", function()
		local src = h.readFile("src/client/PortalPlunge.luau")
		h.ok(not string.find(src, "FireServer", 1, true), "never asks the server for anything")
		h.ok(not string.find(src, "triggerBoost", 1, true), "never boosts")
		local writes = 0
		for line in string.gmatch(src, "[^\n]+") do
			if string.find(line, "CarController.speed =", 1, true) then
				writes += 1
				h.contains(line, "PortalRules.spitSpeed(", "a speed write goes through spitSpeed")
				h.contains(line, "CarConfig.REVERSE_SPEED", "capped at the car's reverse top speed")
			end
		end
		h.eq(writes, 1)
	end)
end
