--!strict
-- Lune spec for the perf review v21 fixes (docs/audits/perf_review_v21.md, "Fixes applied"): shared/GraphicsLodRules
-- (map fx range and rates, post-processing per tier, frame histogram, governor decision, report cleaning), the
-- particle-scale hooks in FlameRules / SettingsRules / BoostRules, the frame events in OnboardingRules, shared/Prof, and
-- static wiring checks for the client modules and the server writes that cannot run under Lune.
-- Run: tools/tests/run_lune_tests.sh tools/tests/graphics_lod_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/GraphicsLodRules.luau")
	local Flame = h.require("src/shared/FlameRules.luau")
	local S = h.require("src/shared/SettingsRules.luau")
	local Boost = h.require("src/shared/BoostRules.luau")
	local O = h.require("src/shared/OnboardingRules.luau")
	local SetPiece = h.require("src/shared/SetPieceRules.luau")
	local Prof = h.require("src/shared/Prof.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	---------------------------------------------------------------------------------------------- PF-02 map fx

	h.test("map fx: range keeps any particle bigger than 2 points; desktop sees farther than a phone", function()
		local desk = R.pointsPerStud(1080, 70)
		local phone = R.pointsPerStud(390, 70)
		h.ok(near(desk, 1080 / (2 * math.tan(math.rad(35)))))
		-- a 1-stud particle: ~385 studs at 1080p, ~139 on a 390-point phone; a half-stud one hits the floor there
		h.ok(near(R.cullRange(1, 1080, 70), desk / R.MIN_PX))
		h.ok(near(R.cullRange(1, 390, 70), phone / R.MIN_PX))
		h.eq(R.cullRange(0.5, 390, 70), R.MIN_RANGE)
		-- at the range edge the particle is exactly MIN_PX tall
		local size = 6
		local range = R.cullRange(size, 1080, 70)
		h.ok(near(size * desk / range, R.MIN_PX))
		h.ok(R.cullRange(size, 1080, 70) > R.cullRange(size, 390, 70))
		-- bigger particles reach farther; junk sizes fall back to the floor
		h.ok(R.cullRange(20, 390, 70) > R.cullRange(3, 390, 70))
		h.eq(R.cullRange(0 / 0, 1080, 70), R.MIN_RANGE)
		h.eq(R.cullRange(-4, 1080, 70), R.MIN_RANGE)
		h.ok(R.MIN_RANGE >= 100, "never cull right next to the camera")
		h.eq(R.FX_TICK, 0.5)
	end)

	h.test("map fx: size from keypoints includes the envelope", function()
		h.eq(R.maxKeypoint({ { 0, 0 }, { 1.1, 0 }, { 0, 0 } }), 1.1)
		h.eq(R.maxKeypoint({ { 2, 0.5 }, { 2.2, 0 } }), 2.5)
		h.eq(R.maxKeypoint({}), 0)
	end)

	h.test("map fx: distance to a box is 0 inside and to the nearest face outside; segment distance clamps", function()
		h.eq(R.boxDistance(0, 0, 0, 10, 5, 10), 0)
		h.eq(R.boxDistance(9, -4, 9, 10, 5, 10), 0)
		h.eq(R.boxDistance(30, 0, 0, 10, 5, 10), 20)
		h.eq(R.boxDistance(-13, 9, 0, 10, 5, 10), 5) -- 3-4-5
		-- a weather box around the camera is never culled, whatever its centre's distance
		h.eq(R.boxDistance(400, 0, 0, 500, 60, 500), 0)
		h.eq(R.segmentDistance(5, 3, 0, 0, 0, 0, 10, 0, 0), 3)
		h.eq(R.segmentDistance(-4, 3, 0, 0, 0, 0, 10, 0, 0), 5)
		h.eq(R.segmentDistance(14, 0, 3, 0, 0, 0, 10, 0, 0), 5)
		h.ok(near(R.segmentDistance(1, 1, 0, 2, 2, 2, 2, 2, 2) ^ 2, 6)) -- zero-length beam
	end)

	h.test("map fx: rate is plan x particle scale in range, 0 beyond; Fire/Beam only switched off, never on", function()
		h.eq(R.emitterRate(26, 1, true), 26)
		h.ok(near(R.emitterRate(26, S.particleScale(false, true), true), 15.6))
		h.ok(near(R.emitterRate(26, S.particleScale(true, false), true), 10.4))
		h.eq(R.emitterRate(26, 1, false), 0)
		h.eq(R.solidOn(true, true, false), true)
		h.eq(R.solidOn(true, false, false), false)
		h.eq(R.solidOn(true, true, true), false)
		h.eq(R.solidOn(false, true, false), false, "a Fire built off stays off")
	end)

	---------------------------------------------------------------------------------------------- PF-05 post

	h.test("post: SunRays off on phone tier and LOW GRAPHICS, Bloom off only under LOW GRAPHICS, desktop unchanged", function()
		h.eq(R.postOn("SunRaysEffect", true, false, false), true)
		h.eq(R.postOn("SunRaysEffect", true, true, false), false)
		h.eq(R.postOn("SunRaysEffect", true, false, true), false)
		h.eq(R.postOn("BloomEffect", true, true, false), true)
		h.eq(R.postOn("BloomEffect", true, false, true), false)
		h.eq(R.postOn("ColorCorrectionEffect", true, true, true), true)
		h.eq(R.postOn("BloomEffect", false, false, false), false, "never switches on what the profile left off")
	end)

	---------------------------------------------------------------------------------------------- PF-03 flames, ambience

	h.test("flames: particle scale lowers the rate, MIN_RATE still holds, desktop is unchanged", function()
		local full = Flame.rate("core", 1, 1, 0, 1, 0, 0)
		h.eq(Flame.rate("core", 1, 1, 0, 1, 0, 0, 1), full)
		h.ok(near(Flame.rate("core", 1, 1, 0, 1, 0, 0, 0.6), full * 0.6))
		h.ok(Flame.rate("core", 0, 0, 0, 0.55, 0, 0, 0.4) >= Flame.MIN_RATE)
		h.eq(Flame.rate("sparks", 0, 0, 0, 1, 0, 0, 0.6), 0, "an off layer stays off")
	end)

	h.test("flames: a rival's flame on a phone stops at 120 studs; the local one and desktop keep 300", function()
		h.ok(Flame.active(Flame.CULL_DIST, false))
		h.ok(Flame.active(Flame.CULL_DIST, false, false))
		h.ok(Flame.active(Flame.PHONE_REMOTE_CULL_DIST, false, true))
		h.ok(not Flame.active(Flame.PHONE_REMOTE_CULL_DIST + 1, false, true))
		h.ok(not Flame.active(10, true, false))
		h.ok(Flame.PHONE_REMOTE_CULL_DIST < Flame.CULL_DIST)
	end)

	h.test("settings: the governor cap only ever lowers the particle scale", function()
		h.eq(S.cappedParticleScale(1, nil), 1)
		h.eq(S.cappedParticleScale(1, 0.4), 0.4)
		h.eq(S.cappedParticleScale(0.6, 0.4), 0.4)
		h.eq(S.cappedParticleScale(0.4, 0.6), 0.4)
	end)

	h.test("wiring: Vfx ambience, flames and the speed lines", function()
		local vfx = h.readFile("src/client/Vfx.luau")
		h.contains(vfx, "pe.Rate = AMBIENT_RATE * pscale")
		h.contains(vfx, "extra.rate * pscale")
		h.contains(vfx, 'key == "lowGraphics" or key == "particleScale"')
		h.contains(vfx, "f.phase, pscale)")
		h.contains(vfx, "rig.remote == true and Settings.phoneTier()")
		h.contains(vfx, "BoostRules.speedLinesVisible(intensity)")
		h.ok(not string.find(vfx, "l.img.Rotation = math.deg(l.angle)", 1, true), "rotation is written once at build")
		h.contains(h.readFile("src/client/AtmosphereFx.luau"), 'key == "lowGraphics" or key == "particleScale"')
	end)

	---------------------------------------------------------------------------------------------- PF-07 speed lines

	h.test("speed lines: hidden below 0.6% peak opacity, shown from the first visible intensity", function()
		h.eq(Boost.speedLinesVisible(0), false)
		h.eq(Boost.speedLinesVisible(0.019), false)
		h.eq(Boost.speedLinesVisible(Boost.SPEED_LINES_MIN), true)
		h.eq(Boost.speedLinesVisible(0.4), true)
		h.ok(Boost.SPEED_LINES_MIN * 0.32 < 0.01, "what is skipped is under 1% opaque")
	end)

	---------------------------------------------------------------------------------------------- PF-08 station

	h.test("station 10 Hz: the monorail crossing still registers at top speed and in a laggy burst", function()
		-- 260 studs/s (the server's speed clamp) sampled every 0.1 s: 26 studs a step, far under stationJump.
		local mark = SetPiece.MONORAIL.crossA.station
		local hits = 0
		local prev: number? = nil
		local st = mark - 100
		for _ = 1, 10 do
			st += 26
			if SetPiece.crossedStation(prev, st, mark) then
				hits += 1
			end
			prev = st
		end
		h.eq(hits, 1)
		-- three updates bunched by the network still read as one crossing
		h.ok(SetPiece.crossedStation(mark - 40, mark + 38, mark))
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "STATION_ATTR_INTERVAL = 0.1")
		h.contains(rm, "stationAttrAt[player] = now + STATION_ATTR_INTERVAL")
		h.contains(rm, "stationAttrAt[player] = nil")
		h.contains(rm, "rec.station = st")
	end)

	---------------------------------------------------------------------------------------------- PF-22 governor + report

	h.test("histogram: 1 ms bins, p50 and p95 from the bins, junk frames ignored", function()
		local hist = R.newHist()
		h.eq(R.percentile(hist, 0.95), 0)
		for _ = 1, 90 do
			R.addFrame(hist, 1 / 60) -- 16.7 ms -> bin 17
		end
		for _ = 1, 10 do
			R.addFrame(hist, 0.050)
		end
		R.addFrame(hist, 0 / 0)
		R.addFrame(hist, -1)
		R.addFrame(hist, 0)
		h.eq(hist.n, 100)
		h.eq(R.percentile(hist, 0.5), 17)
		h.eq(R.percentile(hist, 0.9), 17)
		h.eq(R.percentile(hist, 0.95), 50)
		R.addFrame(hist, 5) -- a 5 s stall lands in the last bin
		h.eq(R.percentile(hist, 1), R.HIST_BINS)
		R.clearHist(hist)
		h.eq(hist.n, 0)
		h.eq(R.percentile(hist, 0.5), 0)
		h.eq(#hist.counts, R.HIST_BINS)
	end)

	h.test("governor: two slow windows in a row act; a fast window resets; a stall window is not judged", function()
		local s, act = R.judge(0, 55, 300)
		h.eq(s, 1)
		h.eq(act, false)
		s, act = R.judge(s, 20, 400)
		h.eq(s, 0, "a fast window resets")
		s, act = R.judge(0, 45, 200)
		s, act = R.judge(s, 300, 10) -- a load stall: too few frames, no change
		h.eq(s, 1)
		h.eq(act, false)
		s, act = R.judge(s, 41, 190)
		h.eq(act, true)
		h.eq(R.judge(0, R.SLOW_P95_MS, 400), 0, "exactly the limit is not slow")
		h.eq(R.CAP_SCALE, S.LOW_GFX_PARTICLE_SCALE)
		h.ok(R.WINDOW * R.STRIKES >= 16)
	end)

	h.test("report: only sane ms values and known tier words get through", function()
		h.eq(R.tierWord(false, false), "desktop")
		h.eq(R.tierWord(true, false), "phone")
		h.eq(R.tierWord(true, true), "phone_low")
		local a, b, t = R.cleanReport(17, 33.4, "phone")
		h.eq(a, 17)
		h.eq(b, 33)
		h.eq(t, "phone")
		for _, bad in {
			{ 40, 20, "phone" }, -- p50 > p95
			{ 0, 20, "phone" },
			{ 17, 5000, "phone" },
			{ 0 / 0, 20, "phone" },
			{ "17", 20, "phone" },
			{ 17, 20, "PlayerName" },
			{ 17, 20, nil },
		} do
			h.eq((R.cleanReport(bad[1], bad[2], bad[3])), nil)
		end
	end)

	h.test("report: the tracker passes the frame fields through, and only for a known player", function()
		local got = {}
		local tracker = O.newTracker({
			onboarding = function() end,
			funnel = function() end,
			custom = function(player: any, name: string, value: number, fields: any)
				table.insert(got, { name = name, value = value, fields = fields })
			end,
		}, function(): string
			return "s"
		end)
		local p = {}
		tracker.custom(p, O.EVENT_FRAME_P95, 33, O.fields("DINO-4", "race", "phone"))
		h.eq(#got, 0, "no profile yet: nothing")
		tracker.begin(p, false)
		tracker.custom(p, O.EVENT_FRAME_P50, 17, O.fields("DINO-4", "race", "phone"))
		tracker.custom(p, O.EVENT_READY, 2)
		h.eq(got[#got - 1].name, "frame_p50_ms")
		h.eq(got[#got - 1].fields.detail, "phone")
		h.eq(got[#got - 1].fields.track, "DINO-4")
		h.eq(got[#got].fields.track, nil, "the old two-argument call still sends no fields")
		local f = h.readFile("src/server/Funnels.luau")
		h.contains(f, 'if action == "frame" then')
		h.contains(f, "GraphicsLodRules.cleanReport(p50, p95, tier)")
		h.contains(f, "FRAME_GAP")
		local g = h.readFile("src/client/FrameGovernor.luau")
		h.contains(g, 'FireServer("frame"')
		h.contains(g, "Settings.capParticleScale(Rules.CAP_SCALE)")
		h.ok(not string.find(g, "AnalyticsService", 1, true), "the client never logs analytics itself")
	end)

	---------------------------------------------------------------------------------------------- PF-10 labels

	h.test("prof: wrap is a pass-through outside Roblox and keeps the arguments", function()
		local seen = 0
		local fn = Prof.wrap("SR_Test", function(dt: number)
			seen += dt
		end)
		fn(0.5)
		fn(0.25)
		h.eq(seen, 0.75)
		local wrapped = 0
		for _, f in {
			"AtmosphereFx", "BossAnimator", "BossIntro", "CarController", "Cosmetics", "FlightController", "FrameGovernor",
			"Garage", "HudExtras", "HudPhase", "ItemClient", "Music", "Onboarding", "PortalPlunge", "RaceUI", "RacerView",
			"Soundscape", "StyleChain", "TrackFlow", "VehicleMotion", "WorldAnim",
		} do
			local src = h.readFile("src/client/" .. f .. ".luau")
			h.contains(src, 'Prof.wrap("SR_', f)
			wrapped += 1
		end
		h.eq(wrapped, 21)
	end)

	h.test("wiring: RaceUI writes HUD text only on change and no longer looks up TouchGui per frame", function()
		local ui = h.readFile("src/client/RaceUI.luau")
		h.contains(ui, "if text ~= timerTextCache then")
		h.contains(ui, "if lapLabel and lapTextChanged then") -- LapChipRules.step reports the change (V9 lap fix)
		h.contains(ui, 'tg:GetPropertyChangedSignal("Enabled")')
		h.ok(not string.find(ui, 'playerGui:FindFirstChild("TouchGui")', 1, true))
	end)

	h.test("wiring: MapAdapter tags its fx effects; the client LOD and governor are started", function()
		h.contains(h.readFile("src/server/MapAdapter.luau"), 'effect:SetAttribute("MapFx", true)')
		h.eq(R.FX_ATTR, "MapFx")
		local lod = h.readFile("src/client/MapFxLod.luau")
		h.contains(lod, "(inst :: ParticleEmitter).Rate = r")
		h.ok(not string.find(lod, "ParticleEmitter).Enabled", 1, true), "emitter Enabled stays with PortalWake / TrackFlow")
		h.contains(lod, "Lighting.ChildAdded:Connect(applyPost)")
		local init = h.readFile("src/shared/BootRules.luau") -- the client boot's order (audit T1-1)
		h.contains(init, '{ name = "MapFxLod" }')
		h.contains(init, '{ name = "FrameGovernor" }')
		h.contains(h.readFile("src/client/Settings.luau"), 'notify("particleScale", after)')
	end)
end
