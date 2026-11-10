--!strict
-- Lune spec for the dressing LOD (floating SNOW-1 dressing, owner play-test 2026-10-20; docs/design/DRESSING_LOD.md):
-- shared/DressingLodRules (radius per graphics level and under Automatic, hysteresis, ground grouping, the per-step
-- budget) and static checks on client/DressingLod (client-only LocalTransparencyModifier, never collision, terrain or
-- parenting), its wiring, and the SNOW skim VFX fix (texture gate, smaller puffs, camera clearance).
-- Run: tools/tests/run_lune_tests.sh tools/tests/dressing_lod_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/DressingLodRules.luau")

	h.test("renderLevel: slider 1..10 maps onto rendering levels 1..21", function()
		h.eq(R.renderLevel(1), 1)
		h.eq(R.renderLevel(5), 10)
		h.eq(R.renderLevel(10), 21)
		h.eq(R.renderLevel(0), 1, "clamped")
		h.eq(R.renderLevel(14), 21, "clamped")
	end)

	h.test("levelRadius: inside the measured terrain cut (L01 ~500, L05 600-800), rising, off from OFF_LEVEL", function()
		h.ok(R.levelRadius(1) < 500, "Level01 under 500")
		h.ok(R.levelRadius(5) < 600, "Level05 under 600")
		h.ok(R.levelRadius(1) >= 400, "Level01 not absurdly short")
		local prev = 0
		for l = 1, R.OFF_LEVEL - 1 do
			local r = R.levelRadius(l)
			h.ok(r > prev, "rises at level " .. l)
			prev = r
		end
		h.eq(R.levelRadius(R.OFF_LEVEL), math.huge)
		h.eq(R.levelRadius(21), math.huge)
	end)

	h.test("autoRadius: frame time -> radius between the Level01 and Level05 cuts, quantised; phones at Level01", function()
		h.eq(R.autoRadius(8, false), R.AUTO_MAX, "fast frames")
		h.eq(R.autoRadius(R.FAST_MS, false), R.AUTO_MAX)
		h.eq(R.autoRadius(R.SLOW_MS, false), R.AUTO_MIN, "slow frames")
		h.eq(R.autoRadius(120, false), R.AUTO_MIN, "very slow")
		local mid = R.autoRadius((R.FAST_MS + R.SLOW_MS) / 2, false)
		h.ok(mid > R.AUTO_MIN and mid < R.AUTO_MAX, "mid frame time in between: " .. mid)
		h.eq(mid % R.QUANT, 0, "quantised")
		h.eq(R.autoRadius(8, true), R.AUTO_MIN, "phone tier")
		h.ok(R.AUTO_MIN <= R.levelRadius(1) and R.AUTO_MAX <= R.levelRadius(5), "auto never wider than the Level05 cut")
		local prev = math.huge
		for ms = 10, 40 do
			local r = R.autoRadius(ms, false)
			h.ok(r <= prev, "monotonic at " .. ms)
			prev = r
		end
	end)

	h.test("targetRadius: forced > Studio level > slider > Automatic; phones capped on a manual level", function()
		h.eq(R.targetRadius(5, 10, 40, false, 300), 300, "forced")
		h.eq(R.targetRadius(1, 10, 8, false, nil), R.levelRadius(1), "Studio Level01 beats the slider")
		h.eq(R.targetRadius(0, 1, 8, false, nil), R.levelRadius(1), "slider 1")
		h.eq(R.targetRadius(0, 10, 40, false, nil), math.huge, "slider 10: off")
		h.eq(R.targetRadius(0, 10, 8, true, nil), R.AUTO_MAX, "phone on slider 10")
		h.eq(R.targetRadius(0, 0, 40, false, nil), R.AUTO_MIN, "Automatic, slow")
		h.eq(R.targetRadius(nil, nil, 8, false, nil), R.AUTO_MAX, "Automatic, fast")
		h.eq(R.targetRadius(0, 0, 8, false, 0), R.AUTO_MAX, "forced 0 ignored")
	end)

	h.test("stepRadius: drops at once, rises at most RISE per second, switches off at once", function()
		h.eq(R.stepRadius(560, 450, 0.2), 450)
		h.eq(R.stepRadius(450, 560, 0.2), 450 + R.RISE * 0.2)
		h.eq(R.stepRadius(550, 560, 1), 560, "no overshoot")
		h.eq(R.stepRadius(450, math.huge, 0.2), math.huge)
		h.eq(R.stepRadius(math.huge, 450, 0.2), 450)
		local r = 450
		for _ = 1, 15 do
			r = R.stepRadius(r, 560, 0.2)
		end
		h.ok(r < 560, "three seconds is not enough to climb 110 studs at 30/s")
	end)

	h.test("smoothFrame: converges on the frame time over a few seconds", function()
		local ms = 16
		for _ = 1, 600 do
			ms = R.smoothFrame(ms, 1 / 30)
		end
		h.ok(math.abs(ms - 33.3) < 1, "30 fps -> ~33 ms: " .. ms)
		local one = R.smoothFrame(16, 0.5) -- a single hitch moves it only part way
		h.ok(one > 16 and one < 500, "one hitch")
	end)

	h.test("wantVisible: hidden past the radius, shown only inside radius - HYST", function()
		h.eq(R.wantVisible(400, 450, true), true)
		h.eq(R.wantVisible(451, 450, true), false)
		h.eq(R.wantVisible(430, 450, false), false, "inside the band a hidden prop stays hidden")
		h.eq(R.wantVisible(450 - R.HYST, 450, false), true)
		h.eq(R.wantVisible(1e6, math.huge, false), true, "LOD off")
	end)

	h.test("grouping: terrain/none own, on another prop follows it, on any other part fixed", function()
		h.eq(R.groupKind("terrain"), "own")
		h.eq(R.groupKind("none"), "own")
		h.eq(R.groupKind("dressing"), "follow")
		h.eq(R.groupKind("part"), "fixed")
		h.eq(R.groupKind("anything"), "fixed")
	end)

	h.test("eligible: dressing or opt-in, never gameplay, never big", function()
		h.eq(R.eligible(true, false, false, 30), true)
		h.eq(R.eligible(false, true, false, 30), true)
		h.eq(R.eligible(false, false, false, 30), false)
		h.eq(R.eligible(true, false, true, 30), false, "gameplay")
		h.eq(R.eligible(true, false, false, R.MAX_EXTENT + 1), false, "too big")
	end)

	h.test("batch: hides first, within the part budget; a lone oversized group still goes", function()
		local want = { true, false, true, false, false }
		local visible = { false, true, true, true, true }
		local cost = { 100, 100, 5, 150, 120 }
		local out = R.batch(want, visible, cost, 5, 300)
		h.eq(out, { 2, 4 }, "two hides fit (250), the third (120) waits; the show waits")
		out = R.batch(want, visible, cost, 5, 1000)
		h.eq(out, { 2, 4, 5, 1 }, "all changes, hides before shows")
		out = R.batch({ false }, { true }, { 900 }, 1, 300)
		h.eq(out, { 1 }, "oversized first group")
		out = R.batch({ true, true }, { true, true }, { 1, 1 }, 2, 300)
		h.eq(#out, 0, "nothing to do")
		h.eq(R.MAX_PARTS_PER_STEP <= 400, true, "a few hundred parts per step at most")
	end)

	h.test("data: every SNOW-1 dressing prop is small enough to be managed", function()
		local Props = h.require("src/shared/PropLibrary.luau")
		local td = h.readFile("build/snow1/TrackData.luau")
		local keys = {}
		for key in string.gmatch(td, 'key = "(snow_[%w_]+)"') do
			keys[key] = true
		end
		local n = 0
		for key in keys do
			local p = Props[key]
			h.ok(p ~= nil, key .. " in PropLibrary")
			if p then
				n += 1
				h.ok(math.max(p.size.X, p.size.Y, p.size.Z) * 1.1 <= R.MAX_EXTENT, key .. " under MAX_EXTENT")
			end
		end
		h.ok(n >= 6, "found the SNOW-1 dressing keys (" .. n .. ")")
	end)

	h.test("static: DressingLod hides on this client only and never touches collision, terrain or parenting", function()
		local src = h.readFile("src/client/DressingLod.luau")
		h.contains(src, "LocalTransparencyModifier")
		h.contains(src, 'FindFirstChild(Rules.FOLDER)')
		h.contains(src, "TriggerRules.TAG")
		h.contains(src, '"Backdrop"')
		h.contains(src, "TrackReady")
		for _, bad in { ".CanCollide =", ".CanQuery =", ".CanTouch =", ".Parent =", ".Transparency =", "Terrain:", ":Destroy(", "FireServer" } do
			local plain = string.gsub(src, "LocalTransparencyModifier = ", "")
			plain = string.gsub(plain, "%-%-[^\n]*", "")
			h.ok(string.find(plain, bad, 1, true) == nil, "never " .. bad)
		end
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "DressingLod" }')
	end)

	h.test("static: SNOW skim puffs are small, short, camera-clear and wait for their texture; FlipFx never blank", function()
		local vfx = h.readFile("src/client/Vfx.luau")
		h.contains(vfx, "if not textureReady(pe.Texture) then")
		h.contains(vfx, "GetAssetFetchStatus")
		h.contains(vfx, "SKIM_CAM_CLEAR")
		local skim = string.match(vfx, "snowSkim = {(.-)\n\t},") or ""
		h.contains(skim, "{ 0, 2.5 }, { 1, 4.5 }")
		h.contains(skim, "NumberRange.new(0.5, 0.65)")
		local flip = h.readFile("src/shared/FlipFx.luau")
		h.contains(flip, "BLANK_STANDIN")
		h.contains(flip, 'if r.texture == "" then')
	end)

	---------------------------------------------------------------------------------------------- pump guard (QA V5A)

	-- Simulates the client: 60 fps frames feed the smoothed frame time, a 5 Hz tick reads the governed Automatic radius.
	-- frameDt(t) gives the frame length at time t. Returns the radius history as { t, radius } at every change.
	local function simulate(seconds: number, frameDt: (number) -> number, settleAt: { number }?): ({ { number } }, number)
		local ms, mutedUntil, t = 16, 0, 0
		local g = R.newGovernor()
		local nextTick = 0
		local changes: { { number } } = {}
		local last: number? = nil
		local settles = settleAt or {}
		local si = 1
		while t < seconds do
			while si <= #settles and settles[si] <= t do
				mutedUntil = R.settleUntil(t, nil, mutedUntil)
				si += 1
			end
			local dt = frameDt(t)
			ms = R.sampleFrame(ms, dt, t, mutedUntil)
			t += dt
			if t >= nextTick then
				nextTick += R.TICK
				local r = R.govern(g, R.autoRadius(ms, false), t, mutedUntil)
				if r ~= last then
					table.insert(changes, { t, r })
					last = r
				end
			end
		end
		return changes, ms
	end

	-- A frame-time series that would pump the old estimate: calm 60 fps with a burst of 120 ms frames every 2.5 s.
	local function spiky(t: number): number
		local phase = t % 2.5
		return if phase < 0.5 then 0.12 else 1 / 60
	end

	h.test("pump guard: sampleFrame ignores samples while settling and caps one hitch", function()
		h.eq(R.sampleFrame(16, 0.25, 1, 5), 16, "inside the settle window: ignored")
		h.ok(R.sampleFrame(16, 0.25, 6, 5) > 16, "after it: counted")
		local one = R.sampleFrame(16, 5, 6, 5) -- a 5 s stall
		h.ok(one < 16 + (R.SAMPLE_CAP_MS - 16) * 0.3, "a stall moves the average only a little: " .. one)
		local a = R.sampleFrame(16, 1 / 60, 6, 5)
		h.ok(math.abs(a - 16) < 0.2, "steady 60 fps stays put")
	end)

	h.test("pump guard: settleUntil extends, never shortens, and waits out the countdown", function()
		h.eq(R.settleUntil(100, nil, nil), 100 + R.SETTLE_S)
		h.eq(R.settleUntil(100, 4, nil), 100 + R.SETTLE_S + 4, "countdown 4 s to GO")
		h.eq(R.settleUntil(100, nil, 150), 150, "an earlier longer window stays")
		h.eq(R.settleUntil(100, -3, nil), 100 + R.SETTLE_S, "GO already passed")
	end)

	h.test("pump guard: governor takes the first value, then moves one QUANT step per hold", function()
		local g = R.newGovernor()
		h.eq(R.govern(g, 550, 0, 0), 550, "first call: as is")
		h.eq(R.govern(g, 450, 0.5, 0), 550, "inside the down hold")
		h.eq(R.govern(g, 450, R.STEP_DOWN_HOLD, 0), 550 - R.QUANT, "one step down")
		h.eq(R.govern(g, 450, R.STEP_DOWN_HOLD + 0.2, 0), 550 - R.QUANT, "held again")
		local t = R.STEP_DOWN_HOLD
		for _ = 1, 8 do
			t += R.STEP_DOWN_HOLD
			R.govern(g, 450, t, 0)
		end
		h.eq(R.govern(g, 450, t + 1, 0), 450, "reaches the target and stops")
		h.eq(R.govern(g, 550, t + 2, 0), 450, "widening starts its calm clock")
		h.eq(R.govern(g, 550, t + 2 + R.STEP_UP_HOLD - 0.1, 0), 450, "not yet")
		h.eq(R.govern(g, 450, t + 2 + R.STEP_UP_HOLD, 0), 450, "a dip back resets the clock")
		h.eq(R.govern(g, 550, t + 10, 0), 450)
		h.eq(R.govern(g, 550, t + 10 + R.STEP_UP_HOLD, 0), 450 + R.QUANT, "an unbroken calm stretch earns one step")
		h.eq(R.govern(g, 550, t + 10 + R.STEP_UP_HOLD + 1, 0), 450 + R.QUANT, "the next step needs another stretch")
		h.eq(R.govern(g, 100, t + 100, 1e9), 450 + R.QUANT, "frozen while settling")
		h.ok(R.STEP_UP_HOLD > R.STEP_DOWN_HOLD, "wide must be earned")
	end)

	h.test("pump guard: a synthetic spiky frame-time series never oscillates or changes faster than the hold", function()
		local changes = simulate(60, spiky)
		for i = 2, #changes do
			local gap = changes[i][1] - changes[i - 1][1]
			h.ok(gap >= R.STEP_DOWN_HOLD - R.TICK - 1e-6, string.format("step gap %.2f s at %.1f", gap, changes[i][1]))
			h.ok(math.abs(changes[i][2] - changes[i - 1][2]) <= R.QUANT + 1e-6, "one step at a time")
		end
		local reversals = 0
		for i = 3, #changes do
			local d1, d2 = changes[i - 1][2] - changes[i - 2][2], changes[i][2] - changes[i - 1][2]
			if d1 * d2 < 0 then
				reversals += 1
			end
		end
		h.ok(reversals <= 1, "reversals " .. reversals)
	end)

	h.test("pump guard: a worse spike pattern (every 1 s) cannot swing 450 -> 525 -> 450 -> 525 within 3 s", function()
		local function spikier(t: number): number
			return if t % 1 < 0.35 then 0.2 else 1 / 60
		end
		local changes = simulate(30, spikier)
		for i = 4, #changes do
			h.ok(changes[i][1] - changes[i - 3][1] >= 3 * R.STEP_DOWN_HOLD - 3 * R.TICK, "three moves take at least 3 holds")
		end
		-- also over the old pattern's 3 s window: at most 2 steps (>= 1.5 s each)
		for i = 1, #changes do
			local n = 0
			for j = i, #changes do
				if changes[j][1] - changes[i][1] <= 3 then
					n += 1
				end
			end
			h.ok(n <= 3, "at most one move per hold inside any 3 s window")
		end
	end)

	h.test("pump guard: the race-start spike is ignored entirely", function()
		-- Map load + countdown: 0.4 s frames for the first 5 s, then 60 fps. Settling from t = 0.
		local function load(t: number): number
			return if t < 5 then 0.4 else 1 / 60
		end
		local changes, ms = simulate(20, load, { 0 })
		h.eq(#changes, 1, "only the initial value")
		h.eq(changes[1][2], R.AUTO_MAX)
		h.ok(ms < 17, "the load never entered the frame time: " .. ms)
	end)

	h.test("static: DressingLod wires the settle window and the governor for the Automatic radius only", function()
		local src = h.readFile("src/client/DressingLod.luau")
		h.contains(src, "Rules.sampleFrame(")
		h.contains(src, "Rules.govern(governor, target")
		h.contains(src, "Rules.settleUntil(")
		h.contains(src, 'for _, name in { "RaceMode", "RaceGoTime" } do')
		h.contains(src, "if automatic and not phone then")
		local haze = h.readFile("src/client/AdaptiveHaze.luau")
		h.contains(haze, "DressingLod.estimate()", "the haze reads the governed radius")
	end)
end
