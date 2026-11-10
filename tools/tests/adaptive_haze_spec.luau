--!strict
-- Lune spec for the adaptive haze (owner FOREST-1 report 2026-10-20: scenery waiting to load; docs/design/ADAPTIVE_HAZE.md):
-- shared/AdaptiveHazeRules (radius -> density curve, per-map clamps against the lighting profiles, smoothing, the
-- weighted look), the DressingLod fade levels and per-map scenery it shares the radius with, and static checks on
-- client/AdaptiveHaze (Atmosphere only, never Lighting fog, server or collision) and its wiring.
-- Run: tools/tests/run_lune_tests.sh tools/tests/adaptive_haze_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

local PROFILE_FILES = {
	["FOREST-1"] = "src/shared/lighting/forest1.luau",
	["SNOW-1"] = "src/shared/lighting/snow1.luau",
	["ISLAND-2"] = "src/shared/lighting/island2.luau",
	["DINO-4"] = "src/shared/lighting/dino4.luau",
}

return function(h: Harness)
	local R = h.require("src/shared/AdaptiveHazeRules.luau")
	local L = h.require("src/shared/DressingLodRules.luau")

	-- The art Atmosphere of a map, read from its lighting profile's source (DINO-4's profile requires its sky module,
	-- which the harness cannot resolve, so the values are read as text: { "Density", 0.17 } or kv("Density", 0.27)).
	local function artOf(id: string): any
		local src = h.readFile(PROFILE_FILES[id])
		local at = string.find(src, '"SkyRally_Atmosphere"', 1, true)
		if not at then
			return nil
		end
		local block = string.sub(src, at, at + 1600)
		local function num(key: string): number
			return tonumber(string.match(block, '"' .. key .. '",%s*([%d%.]+)')) :: number
		end
		local r, g, b = string.match(block, '"Color",%s*Color3%.fromRGB%((%d+),%s*(%d+),%s*(%d+)%)')
		return {
			density = num("Density"),
			offset = num("Offset"),
			haze = num("Haze"),
			color = Color3.fromRGB(tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number),
		}
	end

	local FOREST = R.MAPS["FOREST-1"]

	h.test("targetDensity: reach / R, never below the art value, never above maxDensity", function()
		h.eq(R.targetDensity(math.huge, 0.17, FOREST), 0.17, "LOD off: art")
		h.eq(R.targetDensity(100, 0.17, FOREST), FOREST.maxDensity, "very short: clamped")
		h.eq(R.targetDensity(1e5, 0.17, FOREST), 0.17, "very long: art")
		h.ok(math.abs(R.targetDensity(500, 0.17, FOREST) - FOREST.reach / 500) < 1e-9, "the curve")
		h.ok(math.abs(R.targetDensity(500, 0.17, FOREST, 200) - 0.4) < 1e-9, "reach override (Studio calibration)")
		h.eq(R.targetDensity(500, 0.17, FOREST, 0), R.targetDensity(500, 0.17, FOREST), "override 0 ignored")
		h.eq(R.targetDensity(0 / 0, 0.17, FOREST), 0.17, "NaN radius: art")
		local prev = math.huge
		for r = 300, 2000, 25 do
			local d = R.targetDensity(r, 0.17, FOREST)
			h.ok(d <= prev, "falls with the radius at " .. r)
			prev = d
		end
	end)

	h.test("per-map clamps: every map has a profile Atmosphere, thickens at Level01 and keeps the art look high", function()
		local n = 0
		for _, id in { "FOREST-1", "SNOW-1", "ISLAND-2", "DINO-4" } do
			local cfg = R.MAPS[id]
			h.ok(cfg ~= nil, id .. " listed")
			n += 1
			local art = artOf(id)
			h.ok(art ~= nil, id .. " profile has an Atmosphere")
			h.ok(cfg.maxDensity >= art.density, id .. " maxDensity at or above the art density")
			h.ok(cfg.maxDensity <= 0.45, id .. " maxDensity keeps the lap readable")
			h.ok(cfg.lowOffset <= art.offset, id .. " low Offset never above the art Offset")
			local l1 = R.targetDensity(L.levelRadius(1), art.density, cfg)
			h.ok(l1 > art.density + 0.03 or id == "DINO-4", id .. " thickens at Level01: " .. l1)
			h.ok(l1 <= cfg.maxDensity, id .. " clamped at Level01")
			h.eq(R.targetDensity(L.levelRadius(L.OFF_LEVEL), art.density, cfg), art.density, id .. " art look from OFF_LEVEL")
			h.eq(R.targetDensity(L.levelRadius(14), art.density, cfg), art.density, id .. " art look at Level14")
			h.ok(R.targetDensity(L.AUTO_MIN, art.density, cfg) >= R.targetDensity(L.AUTO_MAX, art.density, cfg), id .. " Automatic: slow frames thicker")
		end
		local listed = 0
		for _ in R.MAPS do
			listed += 1
		end
		h.eq(listed, n, "every hazed map checked against its profile")
		h.eq(R.forMap("SPACE-4"), nil, "SPACE-4 neon night never fogged")
		h.eq(R.forMap("HUB-0"), nil, "hub never fogged")
		h.eq(R.forMap(nil), nil)
	end)

	h.test("FOREST-1 curve: Level01 near max, Level05 between, Level10 near art, Level11+ art", function()
		local art = artOf("FOREST-1").density
		local d1 = R.targetDensity(L.levelRadius(1), art, FOREST)
		local d5 = R.targetDensity(L.levelRadius(5), art, FOREST)
		local d10 = R.targetDensity(L.levelRadius(10), art, FOREST)
		h.ok(d1 >= 0.28 and d1 <= FOREST.maxDensity, "L01 " .. d1)
		h.ok(d5 > art and d5 < d1, "L05 " .. d5)
		h.ok(d10 < d5 and d10 - art < 0.05, "L10 " .. d10)
		h.ok(R.targetDensity(L.levelRadius(11), art, FOREST) - art < 0.03, "L11 within 0.03 of art (v28 1.6: art 0.102, reach 130)")
		h.eq(R.targetDensity(L.levelRadius(14), art, FOREST), art, "L14")
		h.ok(R.targetDensity(L.AUTO_MIN, art, FOREST) == d1, "phone / slow Automatic = Level01")
	end)

	h.test("step: thickens at UP_RATE, clears at DOWN_RATE, never overshoots", function()
		h.ok(math.abs(R.step(0.17, 0.38, 1) - (0.17 + R.UP_RATE)) < 1e-9)
		h.ok(math.abs(R.step(0.38, 0.17, 1) - (0.38 - R.DOWN_RATE)) < 1e-9)
		h.eq(R.step(0.37, 0.38, 10), 0.38, "no overshoot up")
		h.eq(R.step(0.18, 0.17, 10), 0.17, "no overshoot down")
		h.eq(R.step(0.3, 0.3, 1), 0.3)
		h.ok(R.UP_RATE <= 0.05 and R.DOWN_RATE <= R.UP_RATE, "slow, clearing slower than thickening")
	end)

	h.test("smoothing: a target flipping every half second moves the haze only a little (no pumping)", function()
		local d = 0.31
		local lo, hi = math.huge, -math.huge
		local t = 0
		for _ = 1, 600 do
			t += R.TICK
			local target = if math.floor(t / 0.5) % 2 == 0 then 0.31 else 0.38
			d = R.step(d, target, R.TICK)
			if t > 20 then
				lo, hi = math.min(lo, d), math.max(hi, d)
			end
		end
		h.ok(hi - lo <= 0.016, "swing " .. (hi - lo))
	end)

	h.test("weight and look: art at weight 0, the map's low look at weight 1, hue kept by default", function()
		local art = artOf("FOREST-1")
		h.eq(R.weight(art.density, art.density, FOREST), 0)
		h.eq(R.weight(FOREST.maxDensity, art.density, FOREST), 1)
		h.eq(R.weight(1, art.density, FOREST), 1, "clamped")
		local a = R.look(art.density, art, FOREST)
		h.eq(a.density, art.density)
		h.eq(a.offset, art.offset)
		h.eq(a.haze, art.haze)
		h.ok(not R.colorDiffers(a.color, art.color))
		local b = R.look(FOREST.maxDensity, art, FOREST)
		h.ok(math.abs(b.offset - FOREST.lowOffset) < 1e-9)
		h.ok(math.abs(b.haze - FOREST.lowHaze) < 1e-9)
		h.ok(not R.colorDiffers(b.color, art.color), "colour from the profile")
		local mid = R.look((art.density + FOREST.maxDensity) / 2, art, FOREST)
		h.ok(mid.haze > art.haze and mid.haze < FOREST.lowHaze, "halfway")
		h.ok(R.weight(0.3, 0.3, { reach = 1, maxDensity = 0.3, lowOffset = 0, lowHaze = 0 }) == 0, "no span")
	end)

	h.test("differs: 32-bit read-back noise is not a foreign write", function()
		h.eq(R.differs(0.2, 0.2000000029), false)
		h.eq(R.differs(0.2, 0.25), true)
		h.eq(R.colorDiffers(Color3.fromRGB(238, 226, 200), Color3.new(238 / 255, 226 / 255, 200 / 255)), false)
		h.eq(R.colorDiffers(Color3.fromRGB(238, 226, 200), Color3.fromRGB(20, 20, 20)), true)
		h.eq(R.targetRadius, L.targetRadius, "one radius estimate shared with DressingLod")
	end)

	h.test("fadeLevel: steps through the last FADE studs, hidden past the radius, HYST before showing", function()
		local S = L.FADE_STEPS
		h.eq(L.fadeLevel(100, 450, 0), 0)
		h.eq(L.fadeLevel(451, 450, 0), S, "past the radius")
		h.eq(L.fadeLevel(1e6, math.huge, S), 0, "LOD off shows all")
		h.eq(L.fadeLevel(450 - L.HYST + 1, 450, S), S, "hidden stays hidden inside the HYST band")
		local shown = L.fadeLevel(450 - L.HYST - 1, 450, S)
		h.eq(shown, S - 1, "shows again at the faintest drawn level")
		-- coming back in from the haze: one level per pass, never a jump to nearly opaque
		local back = S
		for _ = 1, S + 2 do
			local nxt = L.fadeLevel(450 - L.FADE - 5, 450, back)
			h.ok(nxt >= back - 1, "fade-in one level per pass: " .. back .. " -> " .. nxt)
			back = nxt
		end
		h.eq(back, 0, "fully drawn after a few passes")
		h.eq(L.fadeLevel(449, 450, 0), S - 1, "the last step before the cut")
		-- walking out from the camera the level never falls, and every step is taken
		local cur, seen = 0, {}
		for d = 300, 460 do
			local nxt = L.fadeLevel(d, 450, cur)
			h.ok(nxt >= cur, "monotonic out at " .. d)
			cur = nxt
			seen[cur] = true
		end
		for l = 0, S do
			h.ok(seen[l], "level " .. l .. " reached")
		end
		-- no shimmer: a prop at a step edge does not flip on a one-stud wobble
		local edge = 450 - L.FADE + L.FADE / S * 1.5 -- raw 1.5
		local l0 = L.fadeLevel(edge, 450, 1)
		h.eq(L.fadeLevel(edge + 1, 450, l0), l0)
		h.eq(L.fadeLevel(edge - 1, 450, l0), l0)
		h.eq(L.levelAlpha(0), 0)
		h.eq(L.levelAlpha(S), 1)
	end)

	h.test("batchLevels: fading out first, within the part budget", function()
		local out = L.batchLevels({ 4, 0, 2, 1 }, { 0, 3, 1, 1 }, { 100, 100, 250, 5 }, 4, 300)
		h.eq(out, { 1 }, "the first rise (100) goes; the second (250) would pass the budget, so it and the fall wait")
		out = L.batchLevels({ 4, 0, 2, 1 }, { 0, 3, 1, 1 }, { 100, 100, 250, 5 }, 4, 1000)
		h.eq(out, { 1, 3, 2 }, "rises before falls")
		h.eq(#L.batchLevels({ 1 }, { 1 }, { 9 }, 1, 300), 0)
		h.eq(L.batchLevels({ 4 }, { 0 }, { 900 }, 1, 300), { 1 }, "oversized first group")
	end)

	h.test("MAP_SCENERY: FOREST-1 folders exist in the plan; caps; eligibility with a map cap", function()
		local plan = h.readFile("map/forest1/plan.json")
		for _, path in L.MAP_SCENERY["FOREST-1"].folders do
			h.contains(plan, '"' .. path, "FOREST-1 group " .. path)
		end
		for id, sc in L.MAP_SCENERY do
			h.ok(sc.maxExtent <= 100, id .. " cap keeps drivable landmarks out")
			h.ok(#sc.folders > 0, id)
		end
		h.eq(L.eligible(false, true, false, 90, 100), true, "map cap")
		h.eq(L.eligible(false, true, false, 90), false, "default cap")
		h.eq(L.eligible(false, true, true, 10, 100), false, "gameplay never")
	end)

	h.test("static: AdaptiveHaze writes the Atmosphere only, shares the radius, yields to the podium; wired", function()
		local src = h.readFile("src/client/AdaptiveHaze.luau")
		h.contains(src, "DressingLod.estimate()")
		h.contains(src, "FinishLighting.isActive()")
		h.contains(src, "Rules.OFF_ATTR")
		h.contains(src, "Rules.REACH_ATTR")
		h.contains(src, "Prof.wrap")
		local plain = string.gsub(src, "%-%-[^\n]*", "")
		for _, bad in { "FogEnd", "FogStart", "FireServer", "InvokeServer", ".CanCollide", ":Destroy(", "Instance.new", "Lighting.Brightness", "Lighting.ClockTime" } do
			h.ok(string.find(plain, bad, 1, true) == nil, "never " .. bad)
		end
		for line in string.gmatch(plain, "[^\n]+") do
			local lhs = string.match(line, "^%s*([%w_%.]+)%s*=[^=]")
			if lhs and string.find(lhs, ".", 1, true) then
				h.ok(string.match(lhs, "^a%.%a+$") ~= nil or string.match(lhs, "^base%.%a+$") ~= nil, "only Atmosphere property (or local art copy) writes: " .. lhs)
			end
		end
		-- The client boot starts modules from BootRules.INIT_ORDER (audit T1-1).
		local init = h.readFile("src/shared/BootRules.luau")
		h.contains(init, '{ name = "AdaptiveHaze" }')
		local i1 = string.find(init, '{ name = "DressingLod" }', 1, true) or 0
		local i2 = string.find(init, '{ name = "AdaptiveHaze" }', 1, true) or 0
		h.ok(i1 > 0 and i2 > i1, "after DressingLod")
		local lod = h.readFile("src/client/DressingLod.luau")
		h.contains(lod, "function DressingLod.estimate()")
		h.contains(lod, "Rules.fadeLevel(")
		h.contains(lod, "Rules.MAP_SCENERY[root.Name]")
	end)
end
