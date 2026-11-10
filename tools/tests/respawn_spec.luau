--!strict
-- Lune spec for the way-out rules (shared/RespawnRules; trap audit G5, X-02, X-06, H0-05, G4, D4-02 fix 4, and the
-- stale-respawn finding from the ISLAND-2 water battle Studio run):
--   1. Manual respawn: the client cooldown, the gap after any respawn, the server floor between the two (never under
--      CarConfig.RESPAWN_MIN_INTERVAL, never over the client cooldown), the reasons the server counts as manual.
--   2. Stuck watchdog: offer at STUCK_OFFER, rescue at STUCK_AUTO (once), progress / idle / inactive reset it.
--   3. Water: the tide disk, and the deeper of terrain sea and tide (the X-02 case: dry to the sea, drowning in the tide).
--   4. Hub rescue frame from the REAL HUB-0 anchors: nearest anchor, the route frame within reach (lifted, level,
--      along the route), a route too far away ignored.
--   5. Crash-loop guard: same spot inside the window = loop; elsewhere or later = not.
--   6. Hub exchange from the REAL HUB-0 pads: which vehicle each pad swaps, the plane flyover box, the spawn frames.
--   7. Source guard (the stale-respawn root cause): the car, plane and HUD clients never give up waiting for the
--      remotes the server creates after its boot map build.
-- Run: tools/tests/run_lune_tests.sh tools/tests/respawn_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/RespawnRules.luau")
	local CarConfig = h.require("src/shared/CarConfig.luau")
	local hub = h.require("build/hub0/TrackData.luau").hub

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-3)
	end

	h.test("manual respawn: 3 s cooldown, a gap after any respawn, the server floor sits between the limits", function()
		h.eq(R.MANUAL_COOLDOWN, 3, "the owner's 3 s cooldown")
		h.ok(R.canManual(-math.huge, -math.huge, 100), "first press")
		h.ok(not R.canManual(100, -math.huge, 102.9), "inside the cooldown")
		h.ok(R.canManual(100, -math.huge, 103), "cooldown over")
		h.ok(not R.canManual(-math.huge, 100, 100.5), "right after a crash respawn")
		h.ok(R.canManual(-math.huge, 100, 100 + R.AFTER_RESPAWN_GAP), "after the gap")
		h.ok(near(R.cooldownLeft(100, 101), 2), "cooldown left")
		h.eq(R.cooldownLeft(100, 200), 0, "never negative")
		-- A press the client allows must never be one the server drops (the client would time out onto its cache).
		h.ok(R.SERVER_MANUAL_FLOOR < R.MANUAL_COOLDOWN, "server floor under the client cooldown")
		h.ok(R.SERVER_MANUAL_FLOOR >= CarConfig.RESPAWN_MIN_INTERVAL, "server floor at least the generic respawn interval")
		h.ok(R.AFTER_RESPAWN_GAP > CarConfig.RESPAWN_MIN_INTERVAL, "the client gap clears the server's generic interval")
		h.ok(R.isManualReason("Manual") and R.isManualReason("Stuck"), "manual reasons")
		h.ok(not R.isManualReason("Water") and not R.isManualReason(nil) and not R.isManualReason(5), "crash reasons are not manual")
		-- ISLAND-2 shallows: rescues and grounded off-track returns hold their height under the fade; falls and drowns sink
		for _, r in { "Manual", "Stuck", "Server", "OffTrack" } do
			h.ok(R.holdsUnderFade(r), r .. " holds under the fade")
		end
		for _, r in { "Water", "Fell", "LethalLava", "WallSpin", nil } do
			h.ok(not R.holdsUnderFade(r), tostring(r) .. " falls or sinks")
		end
		h.ok(string.find(h.readFile("src/client/CarController.luau"), "RespawnRules.holdsUnderFade(respawnReason)", 1, true) ~= nil, "the car applies it")
	end)

	h.test("stuck watchdog: offer at 3 s, rescue at 6 s once, reset by progress, letting go or a held car", function()
		local w = R.newWatch()
		local p = Vector3.new(10, 5, 10)
		local dt = 0.125 -- exact in binary: the timer lands on 3 and 6 exactly
		local verdicts = {}
		for i = 1, 60 do
			-- jitter inside the ball (a car grinding against a wall) is not progress
			local jiggle = Vector3.new(math.sin(i) * 2, 0, math.cos(i) * 2)
			verdicts[i] = R.stepWatch(w, p + jiggle, true, true, dt)
		end
		-- frame 1 sets the anchor; the timer then runs dt per frame (frame k: (k - 1) * dt)
		h.eq(verdicts[24], "none", "2.875 s")
		h.eq(verdicts[25], "offer", "3.0 s")
		h.eq(verdicts[48], "offer", "5.875 s")
		h.eq(verdicts[49], "auto", "6.0 s")
		h.eq(verdicts[50], "none", "the watch restarts after a rescue")
		local autos = 0
		for _, v in verdicts do
			autos += if v == "auto" then 1 else 0
		end
		h.eq(autos, 1, "one rescue per window")
		-- progress resets
		local w2 = R.newWatch()
		for _ = 1, 50 do
			R.stepWatch(w2, p, true, true, dt)
		end
		h.eq(R.stepWatch(w2, p + Vector3.new(R.STUCK_RADIUS + 1, 0, 0), true, true, dt), "none", "moved out of the ball")
		h.eq(w2.timer, 0, "timer reset on progress")
		-- letting go of the controls pauses the watch for STUCK_IDLE_GRACE (H0-05: a kid stuck on a kerb lifts a thumb and
		-- tries again), then resets it; an inactive car (grid, respawning, out) resets at once
		R.resetWatch(w2)
		for _ = 1, 30 do
			R.stepWatch(w2, p, true, true, dt) -- 29 x 0.125 = 3.625 s: offered
		end
		local before = w2.timer
		h.eq(R.stepWatch(w2, p, false, true, dt), "offer", "a short let-go keeps the offer up")
		h.eq(w2.timer, before, "a short let-go pauses: no time counts, nothing resets")
		for _ = 1, 6 do
			R.stepWatch(w2, p, false, true, dt) -- 7 x 0.125 = 0.875 s idle, inside the grace
		end
		h.eq(w2.timer, before, "still paused at 0.875 s idle")
		h.eq(R.stepWatch(w2, p, true, true, dt), "offer", "trying again resumes the same window")
		h.ok(near(w2.timer, before + dt), "the timer resumes")
		-- stop-and-go on a kerb (2 s trying, 0.5 s idle, repeated) still reaches the rescue
		local w3 = R.newWatch()
		local rescued = false
		for cycle = 1, 6 do
			for _ = 1, 16 do
				rescued = rescued or R.stepWatch(w3, p, true, true, dt) == "auto"
			end
			for _ = 1, 4 do
				R.stepWatch(w3, p, false, true, dt)
			end
			if rescued then
				h.ok(cycle >= 3, "no rescue before 6 s of trying")
				break
			end
		end
		h.ok(rescued, "stop-and-go driver rescued")
		for _ = 1, 9 do
			R.stepWatch(w2, p, false, true, dt) -- past the grace
		end
		h.eq(w2.timer, 0, "a long let-go resets (a parked car is not stuck)")
		-- a spin-out (hold) freezes the watch
		for _ = 1, 30 do
			R.stepWatch(w2, p, true, true, dt)
		end
		local held = w2.timer
		for _ = 1, 20 do
			R.stepWatch(w2, p + Vector3.new(R.STUCK_RADIUS + 3, 0, 0), true, true, dt, true)
		end
		h.eq(w2.timer, held, "a spin-out neither counts nor resets, even where the spin carried the hull")
		for _ = 1, 50 do
			R.stepWatch(w2, p, true, true, dt)
		end
		h.eq(R.stepWatch(w2, p, true, false, dt), "none", "inactive")
		h.eq(w2.timer, 0, "inactive resets")
		h.ok(R.isTrying(0.92, 0), "touch auto-gas counts as trying")
		h.ok(R.isTrying(0, -1), "steering counts as trying")
		h.ok(not R.isTrying(0.1, 0.1), "resting thumbs are not trying")
	end)

	h.test("water: the tide disk, and the deeper of sea and tide (X-02: dry to the sea, drowning in the tide)", function()
		local c = Vector3.new(-5300, 20, 4200)
		h.eq(R.tideAt(Vector3.new(-5300, 30, 4200), 23, c, 175), 23, "inside the disk")
		h.eq(R.tideAt(Vector3.new(-5300 + 176, 30, 4200), 23, c, 175), nil, "outside the disk")
		h.eq(R.tideAt(Vector3.new(0, 0, 0), 23, nil, nil), 23, "no disk given: everywhere")
		h.eq(R.tideAt(c, nil, c, 175), nil, "no tide")
		h.eq(R.tideAt(c, 0 / 0, c, 175), nil, "NaN level")
		-- A car on 20.8 ground (bottom 20.8): the terrain sea is at the base level 20.0, the tide has risen to 23.0.
		local bottom = 20.8
		local depthSea, srcSea = R.waterDepth(bottom, 20.0, nil)
		h.ok(depthSea < 0 and srcSea == "terrain", "the sea alone: dry")
		local depth, src = R.waterDepth(bottom, 20.0, 23.0)
		h.ok(near(depth, 2.2) and src == "tide", "the tide is the deeper water")
		local deep = R.waterDepth(20.3, 20.0, 23.0)
		h.ok(deep > CarConfig.WATER_SINK_DEPTH, "past the sink depth: the client drowns it with a splash")
		local d2, s2 = R.waterDepth(5, 12, 10)
		h.ok(near(d2, 7) and s2 == "terrain", "deep sea under a lower tide")
		local d3, s3 = R.waterDepth(5, nil, nil)
		h.ok(d3 == -math.huge and s3 == "none", "no water at all")
	end)

	h.test("hub rescue frame from the REAL HUB-0 anchors (H0-05)", function()
		local anchors = {}
		for _, a in hub.respawns do
			table.insert(anchors, { cf = a.cf, name = a.name })
		end
		h.ok(#anchors >= 7, "the data pass's seven anchors")
		-- Drowned off the long dock's end, no route nearby: the dock root anchor, not the plaza 650 studs away.
		local cf, name = R.pickHubFrame(Vector3.new(-8780, -2, 7869), anchors, nil, nil)
		h.eq(name, "DockRoot", "dock end")
		h.ok(cf ~= nil and (cf :: CFrame).Position == hub.respawns[4].cf.Position, "the anchor's own frame")
		-- In the town by the fountain: the plaza.
		local _, n2 = R.pickHubFrame(Vector3.new(-8170, 29, 8040), anchors, nil, nil)
		h.eq(n2, "Plaza", "plaza")
		-- Under the cliff road (old pit 1): the route frame 44 studs away beats every anchor.
		local pit = Vector3.new(-7968, 15, 7488)
		local routePoint = Vector3.new(-7968, 47.3, 7444)
		local tangent = Vector3.new(0.6, 0.2, -0.8).Unit
		local cf3, n3 = R.pickHubFrame(pit, anchors, routePoint, tangent)
		h.eq(n3, "route", "route frame")
		local f = cf3 :: CFrame
		h.ok(near(f.Position.Y, 47.3 + R.HUB_ROUTE_LIFT), "lifted over the ribbon")
		h.ok(math.abs(f.LookVector.Y) < 1e-3, "level heading (the car drops onto the deck)")
		h.ok(f.LookVector:Dot(Vector3.new(0.6, 0, -0.8).Unit) > 0.999, "faces along the route")
		-- The same route point 130 studs away is out of reach: the nearest anchor wins.
		local _, n4 = R.pickHubFrame(Vector3.new(-7968, 15, 7488 + 130 + 44), anchors, routePoint, tangent)
		h.ok(n4 ~= "route", "route beyond HUB_ROUTE_REACH ignored")
		-- No anchors and no route: nothing (the caller keeps its checkpoint).
		local cf5 = R.pickHubFrame(pit, {}, nil, nil)
		h.eq(cf5, nil, "nothing to pick")
		-- H0-05 stuck rescue: never back onto the spot it was stuck on.
		h.eq(R.hubClear("Stuck"), R.HUB_STUCK_CLEAR, "a stuck rescue keeps clear")
		h.eq(R.hubClear("Manual"), nil, "a button press may land next to the car")
		h.eq(R.hubClear("Water"), nil, "a drown may land next to the car")
		h.eq(R.stuckRouteAdvance("Stuck", 3), R.HUB_STUCK_ADVANCE, "stuck ON the route: the route frame moves ahead")
		h.eq(R.stuckRouteAdvance("Stuck", R.HUB_STUCK_CLEAR + 1), 0, "stuck beside the route: its projection is clear")
		h.eq(R.stuckRouteAdvance("Manual", 3), 0, "a manual press keeps the projection")
		h.ok(R.HUB_STUCK_ADVANCE > R.HUB_STUCK_CLEAR, "the advanced route frame clears the stuck spot")
		-- Stuck on a plaza kerb 4 studs from the Plaza anchor, far from the route: the Plaza anchor is the trap, the
		-- next-nearest anchor wins; a manual press there still gets the Plaza.
		local plazaCF = hub.respawns[1].cf
		h.eq(hub.respawns[1].name, "Plaza", "anchor 1 is the plaza")
		local kerb = plazaCF.Position + Vector3.new(4, 0, 0)
		local _, nStuck = R.pickHubFrame(kerb, anchors, nil, nil, R.hubClear("Stuck"))
		h.ok(nStuck ~= nil and nStuck ~= "Plaza", "stuck by the plaza anchor: another anchor (" .. tostring(nStuck) .. ")")
		local _, nManual = R.pickHubFrame(kerb, anchors, nil, nil, R.hubClear("Manual"))
		h.eq(nManual, "Plaza", "manual by the plaza anchor: the plaza")
		-- Stuck on the route itself: the advanced route point (HUB_STUCK_ADVANCE ahead) wins over a far anchor.
		local onRoute = Vector3.new(-7968, 47.3 + 2, 7444)
		local ahead = routePoint + tangent * R.HUB_STUCK_ADVANCE
		local cf6, n6 = R.pickHubFrame(onRoute, anchors, ahead, tangent, R.hubClear("Stuck"))
		h.eq(n6, "route", "stuck on the route: the route ahead")
		h.ok((Vector3.new((cf6 :: CFrame).X, 0, (cf6 :: CFrame).Z) - Vector3.new(onRoute.X, 0, onRoute.Z)).Magnitude >= R.HUB_STUCK_CLEAR, "clear of the stuck spot")
		-- Every candidate inside the clear radius: the nearest one anyway (never no frame at all).
		local lone = { { cf = plazaCF, name = "Plaza" } }
		local _, n7 = R.pickHubFrame(kerb, lone, nil, nil, R.hubClear("Stuck"))
		h.eq(n7, "Plaza", "the only anchor is used even inside the clear radius")
	end)

	h.test("respawn protection (G2, H0-07): one grace for server and client; the client drops only stale hits", function()
		local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
		h.eq(ItemEffects.RESPAWN_IMMUNE_SECONDS, R.RESPAWN_GRACE, "the server's item window is the shared grace")
		h.ok(R.RESPAWN_GRACE >= 2 and R.RESPAWN_GRACE <= 3, "about 2 s visible after the 0.3 s fade-out and 0.35 s fade-in")
		h.ok(R.HIT_STALE_WINDOW < R.RESPAWN_GRACE, "the stale window sits inside the server window")
		h.ok(R.clientIgnoresHit(true, math.huge, 0), "still respawning: a hit decided before the stamp")
		h.ok(R.clientIgnoresHit(false, 0.2, 0), "just placed: still in flight")
		h.ok(R.clientIgnoresHit(false, 5, 1.0), "under the server's bubble")
		h.ok(not R.clientIgnoresHit(false, 1.0, 0), "a hit the server sent after a rearm-refused respawn lands (no bubble)")
		h.ok(not R.clientIgnoresHit(false, 2.8, 0), "a hit after the window lands, even inside the 3 s LOOP_INVULN")
		h.ok(not R.clientIgnoresHit(false, math.huge, 0), "never respawned: lands")
		-- Wiring: both clients apply the rule, the car forces its spin past invulnTimer, the server pick sees the reason.
		local car = h.readFile("src/client/CarController.luau")
		local item = h.readFile("src/client/ItemClient.luau")
		local td = h.readFile("src/server/TrackDirector.luau")
		local cs = h.readFile("src/server/CarServer.luau")
		h.ok(string.find(car, "RespawnRules.clientIgnoresHit(", 1, true) ~= nil, "car applies the rule")
		h.ok(string.find(car, 'spinOut("ItemHit", math.clamp(tonumber(d.seconds) or 1.2, 0.2, 4), nil, nil, true)', 1, true) ~= nil, "car item spin is forced")
		h.ok(string.find(item, "RespawnRules.clientIgnoresHit(", 1, true) ~= nil, "ItemClient applies the rule")
		h.ok(string.find(item, "locallyInvulnerable", 1, true) == nil, "the invulnTimer gate is gone")
		h.ok(string.find(td, "RespawnRules.hubClear(reason)", 1, true) ~= nil, "hub pick keeps clear for a stuck rescue")
		h.ok(string.find(cs, "hubRespawnFrame(rec.hull.Position, reason)", 1, true) ~= nil, "CarServer passes the reason")
	end)

	h.test("crash-loop guard: the same spot inside the window is a loop", function()
		local g = R.newLoopGuard()
		local a = Vector3.new(70, 149, 90)
		h.ok(not R.noteCrash(g, a, 10), "first crash")
		h.ok(R.noteCrash(g, a + Vector3.new(20, 0, 10), 18), "second crash 22 studs away 8 s later")
		h.ok(not R.noteCrash(g, a + Vector3.new(300, 0, 0), 20), "somewhere else")
		h.ok(not R.noteCrash(g, a + Vector3.new(300, 0, 0), 20 + R.LOOP_WINDOW + 1), "same spot, too late")
	end)

	h.test("hub exchange from the REAL HUB-0 pads (G4): what swaps, where it appears", function()
		local planePad, carPad
		for _, pad in hub.exchange do
			if pad.vehicle == "plane" then
				planePad = pad
			elseif pad.vehicle == "car" then
				carPad = pad
			end
		end
		h.ok(planePad ~= nil and carPad ~= nil, "both pads in the data")
		local pp = planePad.cf.Position
		local cp = carPad.cf.Position
		-- A car parked on the plane pad (hull at ride height) swaps; on its own pad, or beside the plane pad, it does not.
		h.ok(R.exchangeHit("car", pp + Vector3.new(3, 1.2, -4), planePad), "car on the plane pad")
		h.ok(not R.exchangeHit("car", cp + Vector3.new(0, 1.2, 0), carPad), "car on the car pad: already a car")
		h.ok(not R.exchangeHit("car", pp + Vector3.new(planePad.radius + 1, 1.2, 0), planePad), "car beside the pad")
		h.ok(not R.exchangeHit("car", pp + Vector3.new(0, 12, 0), planePad), "car high above (a jump over it)")
		-- A plane flying low over the car pad swaps back; too high, or over the plane pad, it does not.
		h.ok(R.exchangeHit("plane", cp + Vector3.new(0, 30, 0), carPad), "plane 30 over the car pad")
		h.ok(R.exchangeHit("plane", cp + Vector3.new(carPad.radius + 3, 20, 0), carPad), "plane just outside the radius (slack)")
		h.ok(not R.exchangeHit("plane", cp + Vector3.new(0, R.EXCHANGE_PLANE_OVER + 5, 0), carPad), "plane too high")
		h.ok(not R.exchangeHit("plane", pp + Vector3.new(0, 20, 0), planePad), "plane over the plane pad")
		-- The plane appears lifted clear of the plane crash floor (Y 16), pitched up, heading as the pad faces.
		local f = R.exchangeFrame(planePad)
		h.ok(near(f.Position.Y, pp.Y + R.EXCHANGE_PLANE_LIFT) and f.Position.Y > 16 + 5, "plane lifted over the crash floor")
		h.ok(near(math.deg(math.asin(f.LookVector.Y)), R.EXCHANGE_PLANE_PITCH, 0.01), "climbing out of the bay")
		local padLook = Vector3.new(planePad.cf.LookVector.X, 0, planePad.cf.LookVector.Z).Unit
		h.ok(Vector3.new(f.LookVector.X, 0, f.LookVector.Z).Unit:Dot(padLook) > 0.999, "pad heading")
		local fc = R.exchangeFrame(carPad)
		h.ok(near(fc.Position.Y, cp.Y + R.EXCHANGE_CAR_LIFT) and math.abs(fc.LookVector.Y) < 1e-3, "car level over its pad")
		-- The respawn anchor between the pads is on neither (a rescued car never swaps by accident).
		for _, a in hub.respawns do
			if a.name == "ExchangeForecourt" then
				h.ok(not R.exchangeHit("car", a.cf.Position, planePad), "forecourt anchor off the plane pad")
			end
		end
		-- E1: dwell by vehicle. A plane braking (78) over the pad for two 0.2 s steps swaps; a fast fly-over does not;
		-- the pad chord at brake speed spans at least two 5 Hz steps; the car keeps the 0.5 s dwell.
		h.ok(R.exchangeReady("plane", 78, 0.2), "plane at brake speed swaps")
		h.ok(not R.exchangeReady("plane", 78, 0.0), "plane first sample waits")
		h.ok(not R.exchangeReady("plane", 140, 0.4), "fast fly-over does not swap")
		h.ok(not R.exchangeReady("plane", R.EXCHANGE_PLANE_MAX_SPEED + 1, 1), "just over the speed gate")
		h.ok(2 * (carPad.radius + R.EXCHANGE_PLANE_SLACK) / 78 >= 0.2 + 0.05, "brake pass spans two 0.2 s steps")
		h.ok(R.exchangeReady("car", 0, R.EXCHANGE_DWELL) and not R.exchangeReady("car", 0, R.EXCHANGE_DWELL - 0.1), "car dwell unchanged")
		h.ok(not R.exchangeReady("car", 300, 0.2), "car fast pass does not swap")
		h.ok(R.EXCHANGE_PLANE_DWELL <= 0.2 and R.EXCHANGE_COOLDOWN > R.EXCHANGE_DWELL, "a swap cannot bounce straight back")
	end)

	h.test("source guard: the clients never give up on the late remotes (stale-respawn root cause)", function()
		-- The server creates FlightStateRemote / RaceEventRemote after its boot map build (60-70 s under load) while
		-- SkyRallyRemotes exists early; a timed WaitForChild that gives up left the car caching the hub frame forever.
		for _, path in { "src/client/CarController.luau", "src/client/FlightController.luau", "src/client/RaceUI.luau" } do
			local src = h.readFile(path)
			for _, name in { "FlightStateRemote", "RaceEventRemote" } do
				local pattern = 'WaitForChild%("' .. name .. '", %d+%)%s*::%s*RemoteEvent%?'
				h.ok(string.find(src, pattern) == nil, path .. ": a one-shot timed wait for " .. name)
			end
		end
		local carSrc = h.readFile("src/client/CarController.luau")
		h.ok(string.find(carSrc, "fallbackTarget()", 1, true) ~= nil, "the car's timeout fallback checks the cache's map and race")
		local carServer = h.readFile("src/server/CarServer.luau")
		h.ok(string.find(carServer, "RespawnRules.isManualReason(reason)", 1, true) ~= nil, "the server checks manual requests")
		h.ok(string.find(carServer, "hubRespawnFrame", 1, true) ~= nil, "the hub rescue picks an anchor")
	end)
	h.test("owner rule: a climbing car keeps the stage-v21 watch (no idle grace, no spin freeze)", function()
		-- R: RespawnRules (top of the spec)
		h.ok(R.isClimbing(true, 0.5), "grounded on a steep wall is climbing")
		h.ok(not R.isClimbing(true, 0.99), "level ground is not climbing")
		h.ok(not R.isClimbing(false, 0.5), "airborne is not climbing")
		-- CarController's gate: active = ... and not (climbing and (spinning or not trying))
		local function carStep(w: any, p: Vector3, trying: boolean, climbing: boolean, spinning: boolean, dt: number): string
			local active = not (climbing and (spinning or not trying))
			return R.stepWatch(w, p, trying, active, dt, spinning)
		end
		local p, dt = Vector3.new(0, 50, 0), 0.125
		-- the stop-and-go pattern that rescues on level ground never rescues a climbing car (2 s gas, 0.5 s idle)
		local w = R.newWatch()
		local rescued = false
		for _ = 1, 10 do
			for _ = 1, 16 do
				rescued = rescued or carStep(w, p, true, true, false, dt) == "auto"
			end
			for _ = 1, 4 do
				carStep(w, p, false, true, false, dt)
			end
		end
		h.ok(not rescued, "rocking up a slope with short let-gos is never rescued (as before)")
		-- a spin-out on a slope resets the watch, as before
		local w2 = R.newWatch()
		for _ = 1, 20 do
			carStep(w2, p, true, true, false, dt)
		end
		carStep(w2, p, true, true, true, dt)
		h.eq(w2.timer, 0, "a spin on a climb resets the watch")
		local carSrc = h.readFile("src/client/CarController.luau")
		h.ok(string.find(carSrc, "RespawnRules.isClimbing(CarController.grounded, up.Y)", 1, true) ~= nil, "the car gates the watch on climbing")
	end)
end
