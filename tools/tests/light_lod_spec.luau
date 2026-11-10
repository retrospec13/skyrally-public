--!strict
-- Lune spec for the PF-01 map light cap (docs/audits/perf_review_v21.md): shared/LightLodRules (budget per tier, the
-- quality slider, which lights are managed, nearest-K selection, hysteresis, the half-brightness step) and static
-- wiring checks for client/LightLod and the MapAdapter tag that cannot run under Lune.
-- Run: tools/tests/run_lune_tests.sh tools/tests/light_lod_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/LightLodRules.luau")

	h.test("budget: 24 desktop, 12 phone, 8 low graphics on any device", function()
		h.eq(R.budget(false, false), 24)
		h.eq(R.budget(true, false), 12)
		h.eq(R.budget(false, true), 8)
		h.eq(R.budget(true, true), 8)
		h.eq(R.TICK, 0.25)
	end)

	h.test("quality slider: levels 1-3 are low, Automatic (0) and 4-10 are not", function()
		h.eq(R.lowQuality(0), false)
		h.eq(R.lowQuality(1), true)
		h.eq(R.lowQuality(3), true)
		h.eq(R.lowQuality(4), false)
		h.eq(R.lowQuality(10), false)
		h.eq(R.lowQuality(nil), false)
	end)

	h.test("managed: only decor lights that were built on, never under a gameplay ancestor", function()
		h.eq(R.managed(true, true, false, false), true) -- route / fx light
		h.eq(R.managed(true, false, true, false), true) -- prefab light
		h.eq(R.managed(true, false, false, false), false) -- untagged (pods, coins, keys, pads, battle props)
		h.eq(R.managed(true, true, true, true), false) -- tagged but under a trigger / pod / hazard
		h.eq(R.managed(false, true, false, false), false) -- built off (lights.on = false): stays off, never switched on
		h.ok(table.find(R.GAMEPLAY_ATTRS, "TriggerType") ~= nil)
		h.ok(table.find(R.GAMEPLAY_ATTRS, "ItemPodSpawn") ~= nil)
		h.ok(table.find(R.GAMEPLAY_ATTRS, "HazardType") ~= nil)
	end)

	h.test("select: keeps exactly the k lowest ranks, matching a full sort", function()
		local rank, order, want = {}, {}, {}
		local seed = 12345
		local function rnd(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		for trial = 1, 20 do
			local n = 5 + trial * 7
			for i = 1, n do
				rank[i] = rnd() * 1000
				order[i] = n + 1 - i
			end
			local k = trial % 30
			R.select(rank, order, n, k, want)
			local sorted = table.clone(rank)
			for i = n + 1, #sorted do
				sorted[i] = nil
			end
			table.sort(sorted)
			local count = 0
			for i = 1, n do
				if want[i] then
					count += 1
					h.ok(k > 0 and rank[i] <= sorted[math.min(k, n)], "kept a light beyond the k-th")
				end
			end
			h.eq(count, math.min(k, n))
			for i = 2, n do
				h.ok(rank[order[i - 1]] <= rank[order[i]], "order is sorted")
			end
		end
	end)

	h.test("select: k >= n keeps every light", function()
		local want = {}
		R.select({ 5, 1, 3 }, { 1, 2, 3 }, 3, 24, want)
		h.eq(want[1] and want[2] and want[3], true)
	end)

	h.test("rank: inside the light's range is 0; a lit light ranks nearer", function()
		h.eq(R.rankDistance(30, 60, false), 0)
		h.eq(R.rankDistance(160, 60, false), 100)
		h.ok(R.rankDistance(160, 60, true) < 100)
		h.eq(R.rankDistance(160, 60, true), 100 * R.HYST_SCALE - R.HYST_MARGIN)
	end)

	h.test("step: on and off go through half brightness for one pass", function()
		h.eq(R.step(R.OFF, true), R.HALF)
		h.eq(R.step(R.HALF, true), R.FULL)
		h.eq(R.step(R.FULL, true), R.FULL)
		h.eq(R.step(R.FULL, false), R.HALF)
		h.eq(R.step(R.HALF, false), R.OFF)
		h.eq(R.step(R.OFF, false), R.OFF)
		local on, br = R.apply(R.HALF, 2)
		h.eq(on, true)
		h.eq(br, 1)
		on, br = R.apply(R.OFF, 2)
		h.eq(on, false)
		h.eq(br, 2, "an off light keeps its built brightness for when it comes back")
		on, br = R.apply(R.FULL, 2)
		h.eq(on, true)
		h.eq(br, 2)
	end)

	-- The client loop in miniature: DINO-4's 142 lights on a line every 20 studs, range 55.
	local function sim(k: number, camAt: (number) -> number, passes: number): ({ number }, number, number)
		local n = 142
		local xs, rank, order, want, levels = {}, {}, {}, {}, {}
		for i = 1, n do
			xs[i] = i * 20
			order[i] = i
			levels[i] = R.FULL
		end
		local changes, maxLit = 0, 0
		for p = 1, passes do
			local cx = camAt(p)
			for i = 1, n do
				rank[i] = R.rankDistance(math.abs(xs[i] - cx), 55, levels[i] ~= R.OFF)
			end
			R.select(rank, order, n, k, want)
			local lit = 0
			for i = 1, n do
				local nv = R.step(levels[i], want[i])
				if nv ~= levels[i] then
					levels[i] = nv
					if p > 4 then
						changes += 1
					end
				end
				if levels[i] ~= R.OFF then
					lit += 1
				end
			end
			if p > 4 then
				maxLit = math.max(maxLit, lit)
			end
		end
		return levels, changes, maxLit
	end

	h.test("sim: a still camera settles on k lights and never flickers", function()
		for _, k in { 24, 12, 8 } do
			for _, x in { 700, 710, 1415.5, 1420 } do
				local levels, changes, maxLit = sim(k, function()
					return x
				end, 40)
				h.eq(changes, 0, "no change after settling, k=" .. k .. " x=" .. x)
				local full = 0
				for _, lv in levels do
					if lv == R.FULL then
						full += 1
					end
				end
				h.eq(full, k)
				h.eq(maxLit, k)
			end
		end
	end)

	h.test("sim: a camera jittering 3 studs around a boundary does not toggle lights", function()
		local _, changes = sim(12, function(p: number)
			return 1410 + (if p % 2 == 0 then 3 else -3)
		end, 60)
		h.eq(changes, 0)
	end)

	h.test("sim: at race speed the lit set follows the camera, lit count stays near k", function()
		-- 260 studs/s at 4 Hz = 65 studs a pass; a light fades through HALF so at most a few extra are lit
		local _, changes, maxLit = sim(12, function(p: number)
			return 100 + p * 65
		end, 40)
		h.ok(changes > 0)
		h.ok(maxLit <= 12 + 8, "lit lights during a pass: " .. maxLit)
	end)

	h.test("wiring: MapAdapter tags route lights; LightLod is opt-in, skips gameplay and is started", function()
		h.contains(h.readFile("src/server/MapAdapter.luau"), 'l:SetAttribute("MapLight", true)')
		local lod = h.readFile("src/client/LightLod.luau")
		h.contains(lod, 'light:GetAttribute("MapLight") == true or light:GetAttribute("MapFx") == true')
		h.contains(lod, "CollectionService:HasTag(a, TriggerRules.TAG)")
		h.contains(lod, "Rules.managed(orig.on, tagged, inPrefab, gameplay)")
		h.contains(lod, "task.wait(Rules.TICK)")
		h.ok(not string.find(lod, "RenderStepped", 1, true), "no per-frame callback")
		h.ok(not string.find(lod, "workspace:GetDescendants", 1, true), "never scans the whole workspace")
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "LightLod" }')
	end)
end
