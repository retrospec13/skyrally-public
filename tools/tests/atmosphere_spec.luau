-- Atmosphere maths (shared/AtmosphereRules): zone-gated phone-scaled rates, camera speed to star streak, teleport-safe
-- smoothing, light easing, lava glow, distance culling. Plus static checks that AtmosphereFx never allocates per frame,
-- every layer it defines has a base rate, and the texture table falls back to existing VfxAssets keys.
return function(h)
	local R = h.require("src/shared/AtmosphereRules.luau")

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end

	h.test("rate: only the active zone's layers run, scaled by the phone particle scale", function()
		h.eq(R.rate("DINO.ash", "DINO", 1, nil), 16)
		h.ok(near(R.rate("DINO.ash", "DINO", 0.35, nil), 16 * 0.35))
		h.eq(R.rate("DINO.ash", "SNOW", 1, nil), 0)
		h.eq(R.rate("DINO.ash", nil, 1, nil), 0)
		h.eq(R.rate("NOPE.layer", "NOPE", 1, nil), 0)
	end)

	h.test("rate: a cull gate multiplies and clamps", function()
		h.ok(near(R.rate("ISLAND.glints", "ISLAND", 1, 0.5), 8))
		h.eq(R.rate("ISLAND.glints", "ISLAND", 1, 0), 0)
		h.eq(R.rate("ISLAND.glints", "ISLAND", 1, 7), 16)
	end)

	h.test("every layer name has a zone prefix and a positive base rate", function()
		for name, base in R.RATES do
			h.ok(R.zoneOf(name) ~= "", name)
			h.ok(base > 0, name)
		end
	end)

	h.test("speedFrac and the star streak grow with speed", function()
		h.eq(R.speedFrac(0), 0)
		h.eq(R.speedFrac(40), 0)
		h.eq(R.speedFrac(400), 1)
		h.ok(R.streakLength(0) < R.streakLength(0.5))
		h.ok(R.streakLength(0.5) < R.streakLength(1))
		h.ok(R.dustSpeed(0) < R.dustSpeed(1))
		h.ok(R.dustRateScale(0) < R.dustRateScale(1))
		h.ok(R.streakLength(1) <= 6.1)
	end)

	h.test("smoothSpeed eases toward the speed and a teleport never reads as warp", function()
		local s = 0
		for _ = 1, 120 do
			s = R.smoothSpeed(s, 100 / 60, 1 / 60)
		end
		h.ok(math.abs(s - 100) < 1)
		h.ok(R.smoothSpeed(100, 5000, 1 / 60) <= 50)
		h.eq(R.smoothSpeed(77, 3, 0), 77)
	end)

	h.test("approach moves at the rate and never overshoots", function()
		h.ok(near(R.approach(0, 1, 2, 0.25), 0.5))
		h.eq(R.approach(0.9, 1, 2, 0.25), 1)
		h.ok(near(R.approach(1, 0, 2, 0.25), 0.5))
		h.eq(R.approach(0.1, 0, 2, 0.25), 0)
	end)

	h.test("lava: only CrackedLava counts; the light needs a hit and stays under the cap", function()
		h.ok(R.isLava("CrackedLava"))
		h.ok(not R.isLava("Basalt"))
		h.eq(R.lavaTarget(0, 5, 3), 0)
		for t = 0, 20 do
			local v = R.lavaTarget(5, 5, t * 0.37)
			h.ok(v > 0 and v <= R.LAVA_LIGHT_MAX)
		end
		h.ok(R.lavaTarget(1, 5, 1) < R.lavaTarget(5, 5, 1))
	end)

	h.test("cullGate: full near, fading over the last 30% of the range, off beyond, off with no surface", function()
		h.eq(R.cullGate(10, 100), 1)
		h.eq(R.cullGate(70, 100), 1)
		h.ok(near(R.cullGate(85, 100), 0.5))
		h.eq(R.cullGate(100, 100), 0)
		h.eq(R.cullGate(500, 100), 0)
		h.eq(R.cullGate(nil, 100), 0)
	end)

	h.test("cells: side cells stay out of the middle of the view", function()
		for _, c in { "Left", "Right" } do
			local d = R.CELLS[c]
			h.ok(math.abs(d.right) - d.sx / 2 >= 20, c)
		end
	end)

	h.test("AtmosphereFx: no per-frame Instance.new, every layer has a base rate, own textures have a fallback", function()
		local src = h.readFile("src/client/AtmosphereFx.luau")
		local stepAt = string.find(src, "local function step(", 1, true)
		h.ok(stepAt ~= nil)
		h.ok(string.find(string.sub(src, stepAt :: number), "Instance.new", 1, true) == nil, "step must not allocate")
		h.contains(src, "Settings.particleScale()")
		for name in string.gmatch(src, 'name = "(%u+%.%w+)"') do
			h.ok(R.RATES[name] ~= nil, name)
		end
		local T = h.require("src/shared/AtmosTexAssets.luau")
		local V = h.require("src/shared/VfxAssets.luau")
		for k, id in T do
			if k ~= "FALLBACK" then
				h.ok(type(id) == "number" and id >= 0, "id is a number, 0 = not uploaded: " .. k)
				h.ok(V[T.FALLBACK[k]] ~= nil, "fallback for " .. k)
			end
		end
	end)

	h.test("map surface polish: SNOW-1 shade is less blue, FOREST-1 lake values ride the plan (per-map, builder default untouched)", function()
		local snow = h.readFile("src/shared/lighting/snow1.luau")
		h.contains(snow, 'kv("ColorShift_Bottom", Color3.fromRGB(126, 136, 158))')
		h.contains(snow, 'kv("OutdoorAmbient", Color3.fromRGB(125, 149, 200))') -- v28 1.5: #7d95c8 blue shadows
		local author = h.readFile("tools/map/author_forest1.py")
		h.contains(author, '"waterColor": "#3fb9d8", "waterTransparency": 0.5, "waterReflectance": 0.3')
		local builder = h.readFile("tools/map30/builder_template.luau")
		h.contains(builder, "(lw and lw.reflectance) or 0.45") -- every other map keeps 0.45
	end)
end
