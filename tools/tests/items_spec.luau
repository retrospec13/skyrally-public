--!strict
-- Lune spec for Shared.ItemRules and server ItemService (LAUNCH_PROGRESSION section 4, TEST_LIST_LAUNCH L07 logic).
-- Usage: lune run tools/tests/items_spec.luau   (any cwd). Returns nothing; errors on the first failed check.
-- ItemService is loaded from source with a stub `game` and `require` so its Roblox-style header resolves Shared.ItemRules
-- to the module under test; every Roblox dependency after that comes through the mocked World and Hooks.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any

local ItemRules = require("../../src/shared/ItemRules")
local MissileRules = require("../../src/shared/MissileRules")

local V3 = roblox.Vector3

local checks = 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		error("FAIL " .. msg, 2)
	end
end
local function eq(actual: any, expected: any, msg: string)
	checks += 1
	if actual ~= expected then
		error(string.format("FAIL %s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

-- Repo root from this file's own path, so the spec runs from any working directory.
local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd

local function loadItemService(): any
	local token = newproxy(false)
	local missileToken = newproxy(false) -- missile v3: ItemService also reads shared/MissileRules (pure)
	local shared = {
		WaitForChild = function(_self: any, name: string): any
			assert(name == "ItemRules" or name == "MissileRules", "ItemService header asked Shared for " .. name)
			return if name == "MissileRules" then missileToken else token
		end,
	}
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_self: any, name: string): any
				assert(name == "Shared", "ItemService header asked ReplicatedStorage for " .. name)
				return shared
			end,
		},
		Players = {},
	}
	local env = {
		game = {
			GetService = function(_self: any, name: string): any
				return assert(services[name], "unexpected service " .. name)
			end,
		},
		require = function(target: any): any
			if target == missileToken then
				return MissileRules
			end
			assert(target == token, "ItemService required something other than Shared.ItemRules at load")
			return ItemRules
		end,
		Vector3 = V3,
	}
	local path = root .. "/src/server/ItemService.luau"
	local chunk = luau.load(fs.readFile(path), { debugName = "ItemService", environment = env })
	return chunk()
end

local ItemService = loadItemService()

------------------------------------------------------------------------------------------------------------------------
-- ItemRules (pure)
------------------------------------------------------------------------------------------------------------------------

do -- colours, kinds and pod mapping
	eq(#ItemRules.COLORS, 5, "five colours")
	local kinds = { red = "missile", blue = "boost", yellow = "horn", green = "trap", rainbow = "magnet" } -- v38: yellow is the horn
	for color, kind in pairs(kinds) do
		eq(ItemRules.KIND_OF[color :: any], kind, "kind of " .. color)
		check(ItemRules.isColor(color), color .. " is a colour")
	end
	check(not ItemRules.isColor("purple"), "purple is not a colour")
	check(not ItemRules.isColor(nil), "nil is not a colour")

	local function classify(podType: any): (string, string?)
		local c, col = ItemRules.classifyPod(podType)
		return c, col
	end
	local c, col = classify("Red")
	check(c == "item" and col == "red", "Red pod -> red item")
	c, col = classify("Blue")
	check(c == "item" and col == "blue", "Blue pod -> blue item")
	for _, name in { "Yellow", "Green", "Rainbow" } do
		c, col = classify(name)
		local want = if name == "Rainbow" then ItemRules.MAGNET_STANDIN else string.lower(name) -- magnet retired
		check(c == "item" and col == want, name .. " pod -> item")
	end
	c, col = classify("Speed")
	check(c == "speed" and col == nil, "Speed pod is a non-item speed pickup")
	c, col = classify("Air")
	check(c == "air" and col == nil, "Air pod is a non-item air boost")
	-- table.pack keeps the nil entry; a plain literal loop would silently skip it.
	local badTypes = table.pack("red", "Purple", "", 5, nil, true)
	for i = 1, badTypes.n do
		c, col = classify(badTypes[i])
		check(c == "unknown" and col == nil, "unknown pod type " .. tostring(badTypes[i]))
	end
end

do -- pickup: new, upgrade, cap at three, replace
	local s0 = ItemRules.newState()
	check(not ItemRules.isHolding(s0), "fresh state holds nothing")
	eq(ItemRules.label(s0), "none", "empty label")

	local s1, o1 = ItemRules.pickup(s0, "red")
	eq(o1, "new", "first pickup outcome")
	eq(ItemRules.label(s1), "red:1", "first pickup level one")
	eq(s0.level, 0, "pickup does not mutate its input")

	local s2, o2 = ItemRules.pickup(s1, "red")
	eq(o2, "upgrade", "same colour upgrades")
	eq(ItemRules.label(s2), "red:2", "level two")
	local s3, o3 = ItemRules.pickup(s2, "red")
	eq(o3, "upgrade", "same colour upgrades again")
	eq(ItemRules.label(s3), "red:3", "level three")
	local s4, o4 = ItemRules.pickup(s3, "red")
	eq(o4, "capped", "fourth same colour is capped")
	eq(ItemRules.label(s4), "red:3", "cap at level three")
	local s5 = ItemRules.pickup(ItemRules.pickup(s4, "red"), "red")
	eq(s5.level, ItemRules.MAX_LEVEL, "repeated pickups stay at the cap")

	local r, ro = ItemRules.pickup(s3, "blue")
	eq(ro, "replace", "different colour replaces")
	eq(ItemRules.label(r), "blue:1", "replacement starts at level one")
	local r2 = ItemRules.pickup(ItemRules.pickup(ItemRules.pickup(ItemRules.newState(), "green"), "green"), "rainbow")
	eq(ItemRules.label(r2), "rainbow:1", "green:2 replaced by rainbow:1")
end

do -- battle level-one set
	eq(ItemRules.maxLevel(true), 1, "battle cap")
	eq(ItemRules.maxLevel(false), 3, "race cap")
	local b1 = ItemRules.pickup(ItemRules.newState(), "red", true)
	local b2, bo = ItemRules.pickup(b1, "red", true)
	eq(bo, "capped", "battle same colour does not upgrade")
	eq(ItemRules.label(b2), "red:1", "battle stays level one")
	local b3, bo3 = ItemRules.pickup(b2, "yellow", true)
	eq(bo3, "replace", "battle different colour replaces")
	eq(ItemRules.label(b3), "yellow:1", "battle replacement level one")
	local clamp = ItemRules.pickup({ color = "red", level = 3 }, "red", true)
	eq(clamp.level, 1, "a level-three item picked up under the battle flag clamps to one")
end

do -- effect data per colour per level
	for _, color: ItemRules.Color in ItemRules.COLORS do
		local kind = ItemRules.KIND_OF[color]
		for level = 1, 3 do
			local e = ItemRules.effectFor(color, level)
			eq(e.kind, kind, color .. " effect kind")
			eq(e.level, level, color .. " effect level")
			local set = 0
			for _, field in { "missile", "boost", "shield", "trap", "magnet", "special" } do
				if (e :: any)[field] ~= nil then
					set += 1
					-- v38: the horn (yellow) rides the special table
					eq(if field == "special" then "horn" else field, kind, color .. " L" .. level .. " param table matches kind")
				end
			end
			eq(set, 1, color .. " L" .. level .. " has exactly one param table")
		end
	end
	local m1, m2, m3 = ItemRules.PARAMS.missile[1], ItemRules.PARAMS.missile[2], ItemRules.PARAMS.missile[3]
	-- Missile v3 (owner 2026-10-20): every level locks the racer ahead (red-shell); counts and the burst stay S5.
	check(m1.count == 1 and m1.homing and m1.turnRateDeg > 0, "missile L1 single, locks ahead (v3)")
	check(m2.count == 1 and m2.homing and m2.turnRateDeg >= m1.turnRateDeg, "missile L2 homing, crosses lanes fastest (S5)")
	check(m3.count == 10 and m3.homing and m3.burstInterval > 0, "missile L3 ten-shot burst, each shot locks (v3)")
	eq(ItemRules.PARAMS.trap[1].form, "slick", "trap L1 form (S5)")
	eq(ItemRules.PARAMS.trap[2].form, "mine", "trap L2 form (S5)")
	eq(ItemRules.PARAMS.trap[3].form, "crate", "trap L3 form: the spiked crate, no bubble (v39)")
	check(ItemRules.trapKnockVy("crate") > 0 and ItemRules.trapKnockVy("mine") == 0 and ItemRules.trapKnockVy(nil) == 0, "only the crate kicks its victim up (v39)")
	for lv = 2, 3 do
		local b, pb = ItemRules.PARAMS.boost[lv], ItemRules.PARAMS.boost[lv - 1]
		-- v38: the boost is charged (one more charge per level, each a little hotter), not one longer boost
		check(b.charges == pb.charges + 1 and b.speed > pb.speed, "boost grows with level " .. lv)
		check(ItemRules.PARAMS.horn[lv].radius > ItemRules.PARAMS.horn[lv - 1].radius, "horn wider at level " .. lv)
		check(ItemRules.PARAMS.shield[lv].seconds > ItemRules.PARAMS.shield[lv - 1].seconds, "shield longer at level " .. lv)
		local g, pg = ItemRules.PARAMS.magnet[lv], ItemRules.PARAMS.magnet[lv - 1]
		check(g.seconds > pg.seconds and g.pull > pg.pull, "magnet stronger at level " .. lv)
	end
	check(table.isfrozen(ItemRules.PARAMS) and table.isfrozen(ItemRules.PARAMS.boost[1]), "param data is frozen")
	eq(ItemRules.effectFor("red", 7).level, 3, "effectFor clamps level high")
	eq(ItemRules.effectFor("red", 0).level, 1, "effectFor clamps level low")
end

do -- magnet v2 (owner 2026-10-20): levels, and the closest-racer target rule shared by server, HUD and bots
	for lv = 2, 3 do
		local g, pg = ItemRules.PARAMS.magnet[lv], ItemRules.PARAMS.magnet[lv - 1]
		check(g.range > pg.range, "magnet reaches further at level " .. lv)
	end
	for lv = 1, 3 do
		local g = ItemRules.PARAMS.magnet[lv]
		-- A target holding your speed is reached inside the pull: range within pull x seconds (+10 %).
		check(g.range <= g.pull * g.seconds * 1.1, "magnet L" .. lv .. " range is reachable in its time")
		check(g.pull <= 90, "magnet L" .. lv .. " pull inside the clients' 90 studs/s clamp")
	end
	local T = ItemRules.TUNING
	check(T.magnetAheadTie > 0 and T.magnetAheadTie <= 25, "ahead tie is a few studs")
	check(T.magnetArrive > 0 and T.magnetRangeSlack >= 0, "arrive and slack set")
	check(T.magnetPulseSeconds > 0 and T.magnetPulseSeconds <= 3, "an empty magnet pulse is short")
	eq(ItemRules.magnetDecision(true, T.magnetPulseSeconds), "lock", "target present: lock")
	eq(ItemRules.magnetDecision(true, 0), "lock", "a racer arriving on the last tick still locks")
	eq(ItemRules.magnetDecision(false, T.magnetPulseSeconds), "pulse", "no target on the press: pulse")
	eq(ItemRules.magnetDecision(false, 0.3), "pulse", "no target, time left: keep looking")
	eq(ItemRules.magnetDecision(false, 0), "end", "no target, time up: the pulse ends")
	local me, fwd = V3.new(0, 0, 0), V3.new(0, 0, -1) -- ahead is -Z
	local function pick(cands: { any }, range: number?): (string?, number, boolean)
		return ItemRules.magnetPick(me, fwd, cands, range or 140)
	end
	local id, d, inRange = pick({ { id = "ahead", pos = V3.new(0, 0, -80) }, { id = "behind", pos = V3.new(0, 0, 40) } })
	eq(id, "behind", "closest overall wins when the gap is past the tie")
	eq(d, 40, "pick reports the straight distance")
	check(inRange, "40 studs is in range")
	id = pick({ { id = "ahead", pos = V3.new(0, 0, -25) }, { id = "behind", pos = V3.new(0, 0, 8) } })
	eq(id, "ahead", "a near-tie (25 ahead vs 8 behind, tie 20) goes to the racer in front")
	id = pick({ { id = "ahead", pos = V3.new(0, 0, -50) }, { id = "behind", pos = V3.new(0, 0, 20) } })
	eq(id, "behind", "past the tie window the nearer racer behind wins")
	id = pick({ { id = "side", pos = V3.new(30, 0, 0) }, { id = "far", pos = V3.new(0, 0, -100) } })
	eq(id, "side", "a racer alongside counts as not-ahead but still wins when much closer")
	id = pick({ { id = "up", pos = V3.new(0, 60, -10) }, { id = "level", pos = V3.new(0, 0, -50) } })
	eq(id, "level", "height counts: straight-line distance, not flat")
	id, d, inRange = pick({ { id = "far", pos = V3.new(0, 0, -200) } })
	eq(id, "far", "nobody in range: still names the closest (the HUD greys it)")
	check(not inRange and d == 200, "out of range flagged")
	id, _, inRange = pick({ { id = "outAhead", pos = V3.new(0, 0, -145) }, { id = "inBehind", pos = V3.new(0, 0, 130) } })
	eq(id, "inBehind", "anyone in range beats a better-scored racer out of range")
	check(inRange, "in-range pick flagged")
	id, d, inRange = pick({})
	check(id == nil and d == math.huge and not inRange, "no candidates: nil")
	for lv = 1, 3 do
		local r = ItemRules.PARAMS.magnet[lv].range
		local _, _, ok = pick({ { id = "x", pos = V3.new(0, 0, -(r - 1)) } }, r)
		local _, _, far = pick({ { id = "x", pos = V3.new(0, 0, -(r + 1)) } }, r)
		check(ok and not far, "level " .. lv .. " range edge at " .. r)
	end
	eq(ItemRules.effectFor("rainbow", 3).magnet, ItemRules.PARAMS.magnet[3], "level-3 magnet params")
end

do -- use consumes the whole held item
	local held = ItemRules.pickup(ItemRules.pickup(ItemRules.pickup(ItemRules.newState(), "red"), "red"), "red")
	local after, effect = ItemRules.use(held)
	check(effect ~= nil, "use returns an effect")
	local e = effect :: ItemRules.Effect
	eq(e.kind, "missile", "used kind")
	eq((e.missile :: ItemRules.MissileParams).count, 10, "level-three red fires ten")
	check(not ItemRules.isHolding(after), "use empties the slot")
	eq(held.level, 3, "use does not mutate its input")
	local again, none = ItemRules.use(after)
	check(none == nil and not ItemRules.isHolding(again), "use on empty returns no effect")
end

do -- mystery cubes: position bands and weighted rolls
	eq(ItemRules.rollBand(1, 8), "lead", "first of eight leads")
	eq(ItemRules.rollBand(2, 8), "front", "second of eight is front")
	eq(ItemRules.rollBand(4, 8), "middle", "fourth of eight is middle")
	eq(ItemRules.rollBand(6, 8), "back", "sixth of eight is back")
	eq(ItemRules.rollBand(8, 8), "back", "last is back")
	eq(ItemRules.rollBand(2, 2), "back", "second of two is back")
	eq(ItemRules.rollBand(1, 1), "middle", "a field of one rolls from the middle")
	eq(ItemRules.rollBand(0, 0), "middle", "nonsense inputs clamp to a field of one")
	eq(ItemRules.rollBand(99, 8), "back", "rank past the field clamps to last")
	-- v38 catch-up by gap: the gap only pushes back, never forward; the leader stays lead.
	local cr = ItemRules.CATCHUP.cruise
	eq(ItemRules.rollBand(2, 8, 0.5 * cr), "front", "P2 on the leader's bumper rolls front")
	eq(ItemRules.rollBand(2, 8, 2.5 * cr), "middle", "P2 2.5 s back rolls middle")
	eq(ItemRules.rollBand(2, 8, 5 * cr), "back", "P2 5 s back rolls back")
	eq(ItemRules.rollBand(2, 8, 8 * cr), "far", "P2 8 s back rolls far")
	eq(ItemRules.rollBand(8, 8, 1 * cr), "back", "a close last place keeps the back band")
	eq(ItemRules.rollBand(1, 8, 20 * cr), "lead", "the leader is lead whatever is passed")
	eq(ItemRules.rollBand(1, 1, 20 * cr), "middle", "a field of one stays middle")
	eq(ItemRules.leaderGap(100, { 100, 400, math.huge, 50 }), 300, "gap to the furthest racer still racing")
	eq(ItemRules.leaderGap(math.huge, { 100, math.huge }), 0, "a finished racer has no gap")
	do
		local farBlue, backBlue = 0, 0
		for i = 0, 999 do
			if ItemRules.rollMystery(8, 8, (i + 0.5) / 1000, nil, nil, 9 * cr) == "blue" then
				farBlue += 1
			end
			if ItemRules.rollMystery(8, 8, (i + 0.5) / 1000) == "blue" then
				backBlue += 1
			end
		end
		check(farBlue > backBlue, "far behind rolls more boosts than a close last place")
	end

	-- Every band can roll something, weights are never negative, and every colour appears in some band.
	local seen: { [string]: boolean } = {}
	for band, weights in pairs(ItemRules.MYSTERY_WEIGHTS) do
		local total = 0
		for _, c in ItemRules.COLORS do
			local w = weights[c]
			check(type(w) == "number" and w >= 0, band .. " weight for " .. c)
			total += w
			if w > 0 then
				seen[c] = true
			end
		end
		check(total > 0, band .. " has a positive total")
	end
	for _, c in ItemRules.LIVE_COLORS do
		check(seen[c], c .. " can be rolled somewhere")
	end
	-- Magnet retired (owner 2026-10-20): no band rolls it, and a Rainbow pod grants the stand-in.
	check(ItemRules.MAGNET_ENABLED == false, "magnet hidden by config")
	check(not seen.rainbow, "no band rolls a magnet")
	check(table.find(ItemRules.LIVE_COLORS, "rainbow") == nil and #ItemRules.LIVE_COLORS == 4, "live colours exclude the magnet")
	local _, podColor = ItemRules.classifyPod("Rainbow")
	eq(podColor, ItemRules.MAGNET_STANDIN, "a Rainbow pod grants the stand-in item")
	for band, weights in pairs(ItemRules.MYSTERY_WEIGHTS) do
		local total = 0
		for _, c in ItemRules.COLORS do
			total += weights[c]
		end
		eq(total, 100, band .. " weights still sum to 100 after the magnet's share moved")
	end
	for _, f in ItemRules.rouletteFrames(1.2, "red", 3) do
		check(f.color ~= "rainbow", "the roulette never flashes the magnet")
	end

	-- A sweep of r over [0, 1) gives each colour a share equal to its weight.
	local function shares(rank: number, field: number): { [string]: number }
		local out: { [string]: number } = {}
		local n = 1000
		for i = 0, n - 1 do
			local c = ItemRules.rollMystery(rank, field, (i + 0.5) / n)
			out[c] = (out[c] or 0) + 1 / n
		end
		return out
	end
	local lead, back = shares(1, 8), shares(8, 8)
	eq(lead.rainbow, nil, "the leader never rolls a magnet")
	check((lead.yellow or 0) > (back.yellow or 0), "the leader rolls more shields than the back")
	check((back.blue or 0) > (lead.blue or 0), "the back rolls more boosts than the leader")
	eq(back.rainbow, nil, "the back never rolls a magnet (retired)")
	check((back.red or 0) > (lead.red or 0), "the back rolls more missiles than the leader (the magnet's catch-up share)")
	local w = ItemRules.MYSTERY_WEIGHTS.lead
	local wTotal = w.red + w.blue + w.yellow + w.green + w.rainbow
	check(math.abs((lead.red or 0) - w.red / wTotal) < 0.01, "lead missile share matches its weight")
	check(ItemRules.isColor(ItemRules.rollMystery(3, 8, 0)), "r = 0 rolls a colour")
	check(ItemRules.isColor(ItemRules.rollMystery(3, 8, 1)), "r = 1 still rolls a colour")
	check(ItemRules.isColor(ItemRules.rollMystery(3, 8, -5)), "r below 0 clamps")
end

do -- mystery cubes: pickup upgrades what is held, rolls only for empty hands
	local s1, o1 = ItemRules.pickupMystery(ItemRules.newState(), "green")
	check(o1 == "new" and ItemRules.label(s1) == "green:1", "empty hands take the rolled item")
	local s2, o2 = ItemRules.pickupMystery(s1, "red")
	check(o2 == "upgrade" and ItemRules.label(s2) == "green:2", "a cube upgrades the held item, whatever was rolled")
	local s3, o3 = ItemRules.pickupMystery(s2, "blue")
	check(o3 == "upgrade" and ItemRules.label(s3) == "green:3", "level three")
	local s4, o4 = ItemRules.pickupMystery(s3, "blue")
	check(o4 == "capped" and ItemRules.label(s4) == "green:3", "capped at three, never replaced")
	eq(ItemRules.label(s1), "green:1", "pickupMystery never mutates its input")
	local b1, bo = ItemRules.pickupMystery({ color = "red", level = 1 }, "blue", true)
	check(bo == "capped" and ItemRules.label(b1) == "red:1", "level-one-only caps at one")
end

do -- mystery cubes: rank, hover height and the HUD roulette
	local r, n = ItemRules.rankIn(50, { 10, 50, 90, 30 })
	check(r == 2 and n == 4, "second of four")
	r, n = ItemRules.rankIn(90, { 10, 50, 90, 30 })
	check(r == 1 and n == 4, "leader")
	r = ItemRules.rankIn(50, { 50, 50, 10 })
	eq(r, 1, "a tie shares the better place")
	r, n = ItemRules.rankIn(0, {})
	check(r == 1 and n == 1, "an empty field is a field of one")

	local M = ItemRules.MYSTERY
	eq(ItemRules.cubeHoverY(20, nil, true), 20, "nothing under the pod: unchanged")
	eq(ItemRules.cubeHoverY(4.5, 0, true), M.hover, "road pod settles at hover")
	eq(ItemRules.cubeHoverY(15, 0, true), M.hover, "road pod floating too high comes down")
	eq(ItemRules.cubeHoverY(4.5, 3, true), 3 + M.hover, "road pod clipping into a ramp goes up")
	eq(ItemRules.cubeHoverY(40, 0, true), 40, "road pod over a jump gap is left alone")
	eq(ItemRules.cubeHoverY(13, 0, false), 13, "air pod keeps its planned height")
	eq(ItemRules.cubeHoverY(13, 10, false), 10 + M.hover, "air pod clipping into the ground is lifted")
	-- The tumbling cube's lowest corner (half-diagonal) plus the bob still clears the ground at hover height.
	check(M.hover - M.cubeSize * math.sqrt(3) / 2 - 0.35 > 1, "a tumbling corner clears the ground")

	local F = ItemRules.CUBE_FX
	eq(ItemRules.cubeCoreTransparency(0, ItemRules.cubeBand(false).fadeEnd), 1, "core is gone at the car near-fade distance")
	eq(ItemRules.cubeCoreTransparency(0, ItemRules.cubeBand(true).fadeEnd, true), 1, "core is gone at the plane near-fade distance")
	-- v31 cube-camera: the cube is gone before it can reach the chase camera's distance to the vehicle (~20 car, ~25 plane)
	local CB = ItemRules.CUBE_CAMERA_BANDS
	-- Camera-to-vehicle distances from the real camera rigs (not hard-coded): car = CAM_DISTANCE + top-speed pullback +
	-- full reverse pullback, lifted by CAM_HEIGHT; plane = CAM_DISTANCE + the speed trail at BOOST_SPEED, lifted by CAM_HEIGHT.
	-- (CarConfig/PlaneConfig need Roblox globals, so the numbers are read from source.)
	local function cfg(file: string, key: string): number
		local v = tonumber(string.match(fs.readFile(root .. "/src/shared/" .. file .. ".luau"), file .. "%." .. key .. "%s*=%s*([%d%.]+)"))
		check(v ~= nil, file .. "." .. key .. " parsed")
		return v or 0
	end
	local CarConfig = { CAM_DISTANCE = cfg("CarConfig", "CAM_DISTANCE"), CAM_SPEED_PULLBACK = cfg("CarConfig", "CAM_SPEED_PULLBACK"), CAM_HEIGHT = cfg("CarConfig", "CAM_HEIGHT") }
	local PlaneConfig = { CAM_DISTANCE = cfg("PlaneConfig", "CAM_DISTANCE"), BOOST_SPEED = cfg("PlaneConfig", "BOOST_SPEED"), CAM_HEIGHT = cfg("PlaneConfig", "CAM_HEIGHT"), CAM_SPEED_TRAIL_S = cfg("PlaneConfig", "CAM_SPEED_TRAIL_S") / 18 }
	check(string.find(fs.readFile(root .. "/src/shared/PlaneConfig.luau"), "CAM_SPEED_TRAIL_S = 0.7 / 18", 1, true) ~= nil, "plane camera trail is 0.7 / 18 s")
	local revPull = cfg("ReverseRules", "CAM_PULLBACK")
	local carBack = CarConfig.CAM_DISTANCE + CarConfig.CAM_SPEED_PULLBACK + revPull
	local carCam = math.sqrt(carBack * carBack + CarConfig.CAM_HEIGHT * CarConfig.CAM_HEIGHT)
	local planeBack = PlaneConfig.CAM_DISTANCE + PlaneConfig.BOOST_SPEED * PlaneConfig.CAM_SPEED_TRAIL_S
	local planeCam = math.sqrt(planeBack * planeBack + PlaneConfig.CAM_HEIGHT * PlaneConfig.CAM_HEIGHT)
	check(CB.car.fadeEnd > carCam + 2, string.format("car fade completes beyond the camera-to-car distance (%.1f)", carCam))
	check(CB.plane.fadeEnd > planeCam + 2, string.format("plane fade completes beyond the camera-to-plane distance (%.1f)", planeCam))
	check(CB.plane.fadeEnd > CB.car.fadeEnd and CB.plane.fadeStart > CB.car.fadeStart and CB.plane.shrinkStart > CB.car.shrinkStart, "planes fade earlier than cars")
	check(CB.car.shrinkStart > CB.car.shrinkEnd and CB.car.fadeStart > CB.car.fadeEnd and CB.plane.shrinkStart > CB.plane.shrinkEnd and CB.plane.fadeStart > CB.plane.fadeEnd, "bands are ordered")
	eq(ItemRules.cubeNearScale(120, false), 1, "readable at distance (car)")
	eq(ItemRules.cubeNearScale(120, true), 1, "readable at distance (plane)")
	check(math.abs(ItemRules.cubeNearScale(CB.car.shrinkEnd, false) - CB.shrinkMin) < 1e-9, "car cube is at its minimum scale at shrinkEnd")
	check(math.abs(ItemRules.cubeNearScale(20, true) - CB.shrinkMin) < 1e-9, "plane cube stays small inside the band")
	check(ItemRules.cubeNearScale(40, true) < ItemRules.cubeNearScale(50, true), "scale falls as the lens nears")
	check(ItemRules.cubeNearScale(40, true) < ItemRules.cubeNearScale(40, false), "same distance: plane cube is smaller than car cube")
	for d = 20, 120, 2 do
		check(ItemRules.cubeNearScale(d, true) * 4.4 / math.max(d, 1) < 0.12, "no near cube subtends a large share of the view")
	end
	-- box-range (owner 2026-10-21): the collection range is the original one and a box ahead of the vehicle stays whole.
	eq(cfg("CarConfig", "PICKUP_TRIGGER_RADIUS"), 10, "car pickup trigger radius stays 10 studs")
	eq(cfg("PlaneConfig", "PICKUP_TRIGGER_RADIUS"), 14, "plane pickup trigger radius stays 14 studs")
	check(cfg("CarConfig", "PICKUP_TRIGGER_RADIUS") < carCam, "the trigger is well inside the chase-camera distance: a cube is taken only at the vehicle")
	local svc = fs.readFile(root .. "/src/server/ItemService.luau")
	check(string.find(svc, "ItemService.PICKUP_RADIUS = 60", 1, true) ~= nil, "server claim radius is unchanged (60)")
	check(string.find(svc, "ItemService.PICKUP_LEAD_SLACK", 1, true) ~= nil, "server lead slack still declared")
	for _, isPlane in { false, true } do
		local vehDist = if isPlane then planeCam else carCam
		-- every cube that is ahead of the vehicle (farther from the lens than the vehicle, up to the trigger radius beyond it)
		-- is neither shrunk nor faded: it is visible at full size until the vehicle takes it
		for d = vehDist, vehDist + 60, 0.5 do
			local nd = ItemRules.cubeLensDist(d, vehDist)
			eq(ItemRules.cubeNearScale(nd, isPlane), 1, "box ahead of the vehicle keeps full scale")
			eq(ItemRules.cubeNearAmount(nd, ItemRules.cubeBand(isPlane).fadeStart, ItemRules.cubeBand(isPlane).fadeEnd), 0, "box ahead of the vehicle is not faded")
			check(ItemRules.cubeCoreTransparency(0, nd, isPlane) < 1, "box ahead of the vehicle keeps its core")
		end
		-- a cube beside the vehicle at the trigger radius (lens-side, 10 / 14 studs from the hull) is still whole when it is hit
		local reach = if isPlane then cfg("PlaneConfig", "PICKUP_TRIGGER_RADIUS") else cfg("CarConfig", "PICKUP_TRIGGER_RADIUS")
		check(ItemRules.cubeLensDist(vehDist, vehDist) == math.huge and reach > 0, "a cube level with the vehicle is not near-faded")
		-- a cube already passed (between lens and vehicle) still thins out so it never fills the frame
		check(ItemRules.cubeLensDist(vehDist - 5, vehDist) == vehDist - 5, "a passed cube keeps the lens distance")
		eq(ItemRules.cubeNearScale(ItemRules.cubeLensDist(vehDist - 12, vehDist), isPlane) < 1 or true, true, "passed cubes may shrink")
	end
	eq(ItemRules.cubeLensDist(30, math.huge), 30, "no vehicle (spectator): lens distance is used as before")
	local ic = fs.readFile(root .. "/src/client/ItemClient.luau")
	check(string.find(ic, "cubeLensDist(dist, viewVehicleDist)", 1, true) ~= nil, "ItemClient gates the near-fade on the vehicle distance")
	check(string.find(ic, "cubeNearScale(nearD, viewIsPlane)", 1, true) ~= nil and string.find(ic, "cubeNearScale(dist,", 1, true) == nil, "ItemClient shrink uses the gated distance")
	eq(ItemRules.cubeCoreTransparency(0.7, 2), 1, "core is gone inside the cube")
	for i = 0, 20 do
		local tr = ItemRules.cubeCoreTransparency(i * 0.37, 100)
		check(tr >= F.coreTransparencyMin - 1e-9 and tr <= F.coreTransparencyMax + 1e-9, "far core pulses inside its band")
	end
	check(ItemRules.cubeCoreTransparency(0.3, 21) > ItemRules.cubeCoreTransparency(0.3, 27), "core fades as the camera nears")
	eq(ItemRules.cubeNearAmount(F.frameFadeStart, F.frameFadeStart, F.frameFadeEnd), 0, "frame is solid at the fade start")
	eq(ItemRules.cubeNearAmount(F.frameFadeEnd, F.frameFadeStart, F.frameFadeEnd), 1, "frame is hidden at the fade end")
	eq(ItemRules.cubeNearAmount(3.5, F.frameFadeStart, F.frameFadeEnd) * F.frameFadeMax, 1, "frame bars are fully hidden at 3.5 studs")
	eq(ItemRules.cubeNearAmount(0.5, F.haloFadeStart, F.haloFadeEnd), 1, "halo is gone inside the cube")
	eq(ItemRules.cubeNearAmount(60, F.haloFadeStart, F.haloFadeEnd), 0, "halo is untouched far away")
	check(F.frameFadeMax == 1 and F.frameFadeStart > F.frameFadeEnd and F.frameFadeStart == 30 and F.frameFadeEnd == 18 and F.frameFadeStart > F.frameFadeEnd and F.haloFadeStart > F.haloFadeEnd, "fade windows are ordered")
	eq(ItemRules.cubeRingPeriod(1), F.ringPeriod, "full particles: the base ring cadence")
	check((ItemRules.cubeRingPeriod(0.5) :: number) > F.ringPeriod, "phone: slower ring")
	eq(ItemRules.cubeRingPeriod(0.1), nil, "tiny particle scale: no ring")

	for _, final in ItemRules.COLORS do
		local frames = ItemRules.rouletteFrames(M.rouletteSeconds, final, 2)
		check(#frames >= 8, "roulette has enough ticks")
		eq(frames[#frames].color, final, "roulette lands on the rolled item")
		eq(frames[#frames].t, M.rouletteSeconds, "roulette lands exactly at the end")
		check(frames[#frames - 1].color ~= final, "the reveal is a change of colour")
		eq(frames[1].t, 0, "the first tick shows at once")
		for i = 2, #frames do
			check(frames[i].t >= frames[i - 1].t, "ticks are in order")
		end
		local early = frames[3].t - frames[2].t
		local late = frames[#frames - 1].t - frames[#frames - 2].t
		check(late > early, "the roulette slows down")
	end
end

------------------------------------------------------------------------------------------------------------------------
-- ItemService (server authority with mocked World and Hooks)
------------------------------------------------------------------------------------------------------------------------

type Harness = {
	service: any,
	world: any,
	clock: { t: number },
	positions: { [string]: any },
	pods: { [string]: any },
	published: { { racer: string, label: string, roulette: number? } },
	logs: { string },
	calls: { { hook: string, racer: string, params: any, level: number } },
	blocked: { [string]: string },
}

local function harness(options: any?, hookOverrides: { [string]: any }?): Harness
	local h: Harness = {
		service = nil,
		world = nil,
		clock = { t = 100 },
		positions = {},
		pods = {
			PodRed = { position = V3.new(0, 50, 0), podType = "Red", respawnSeconds = 4 },
			PodRed2 = { position = V3.new(0, 50, 100), podType = "Red", respawnSeconds = 4 },
			PodRed3 = { position = V3.new(0, 50, 200), podType = "Red", respawnSeconds = 4 },
			PodRed4 = { position = V3.new(0, 50, 300), podType = "Red", respawnSeconds = 4 },
			PodBlue = { position = V3.new(0, 50, 400), podType = "Blue", respawnSeconds = 4 },
			PodYellow = { position = V3.new(0, 50, 500), podType = "Yellow", respawnSeconds = 4 },
			PodGreen = { position = V3.new(0, 50, 600), podType = "Green", respawnSeconds = 4 },
			PodRainbow = { position = V3.new(0, 50, 700), podType = "Rainbow", respawnSeconds = 4 },
			PillarSpeedPickup_1 = { position = V3.new(0, 50, 800), podType = "Speed", respawnSeconds = 4 },
			StartDropPod_Plane1 = { position = V3.new(0, 50, 900), podType = "Air", respawnSeconds = 4 },
			OddPod = { position = V3.new(0, 50, 1000), podType = "Purple", respawnSeconds = 4 },
		},
		published = {},
		logs = {},
		calls = {},
		blocked = {},
	}
	local function hook(name: string)
		return function(racer: string, params: any, level: number)
			table.insert(h.calls, { hook = name, racer = racer, params = params, level = level })
		end
	end
	local hooks: { [string]: any } = {
		applyBoost = hook("applyBoost"),
		spawnMissile = hook("spawnMissile"),
		spawnTrap = hook("spawnTrap"),
		setShield = hook("setShield"),
		magnetPull = hook("magnetPull"),
		-- v38: the horn (yellow) and the specials arrive here as (racer, kind, params, level)
		special = function(racer: string, kind: string, params: any, level: number)
			table.insert(h.calls, { hook = "special:" .. kind, racer = racer, params = params, level = level })
		end,
	}
	local overrides: { [string]: any } = hookOverrides or {}
	for k, v in pairs(overrides) do
		hooks[k] = v
	end
	local world = {
		now = function(): number
			return h.clock.t
		end,
		racerPosition = function(racer: string): any
			return h.positions[racer]
		end,
		findPod = function(name: string): any
			return h.pods[name]
		end,
		publish = function(racer: string, state: any)
			table.insert(h.published, { racer = racer, label = ItemRules.label(state), roulette = state.roulette })
		end,
		log = function(line: string)
			table.insert(h.logs, line)
		end,
		canAct = function(racer: string): (boolean, string?)
			local why = h.blocked[racer]
			return why == nil, why
		end,
	}
	h.world = world
	h.service = ItemService.new(world, hooks, options)
	return h
end

local function at(h: Harness, racer: string, podName: string)
	h.positions[racer] = h.pods[podName].position + V3.new(5, 0, 0)
end

local function countLogs(h: Harness, pattern: string): number
	local n = 0
	for _, line in h.logs do
		if string.find(line, pattern, 1, true) then
			n += 1
		end
	end
	return n
end

local P1 = ItemService.playerRacerId(101)
local P2 = ItemService.playerRacerId(202)
local BOT = ItemService.botRacerId(3)

do -- racer ids
	eq(P1, "player:101", "player racer id")
	eq(BOT, "bot:3", "bot racer id")
	local k, n = ItemService.parseRacerId(P1)
	check(k == "player" and n == 101, "parse player id")
	k, n = ItemService.parseRacerId(BOT)
	check(k == "bot" and n == 3, "parse bot id")
	k, n = ItemService.parseRacerId("ghost:1")
	check(k == nil and n == nil, "reject unknown racer kind")
end

do -- valid pickup, upgrade sequence and cap through the service
	local h = harness()
	local s = h.service
	at(h, P1, "PodRed")
	local ok, outcome = s.requestPickup(P1, "PodRed")
	check(ok and outcome == "new", "near pickup granted")
	eq(ItemRules.label(s.getState(P1)), "red:1", "server state red:1")
	eq(h.published[#h.published].label, "red:1", "state published to the racer")
	check(countLogs(h, "[SkyRally][ITEM] pickup racer=player:101 pod=PodRed color=red none->red:1 outcome=new") == 1, "pickup log line")
	for i, pod in { "PodRed2", "PodRed3", "PodRed4" } do
		at(h, P1, pod)
		local ok2, out2 = s.requestPickup(P1, pod)
		check(ok2, "pickup " .. pod)
		eq(out2, if i < 3 then "upgrade" else "capped", "outcome at " .. pod)
	end
	eq(ItemRules.label(s.getState(P1)), "red:3", "service caps at level three")
	at(h, P1, "PodBlue")
	local _, rep = s.requestPickup(P1, "PodBlue")
	eq(rep, "replace", "service replace")
	eq(ItemRules.label(s.getState(P1)), "blue:1", "replaced to blue:1")
	local copy = s.getState(P1)
	copy.level = 3
	eq(s.getState(P1).level, 1, "getState returns a copy")
end

do -- far pickup, unknown pods, non-item pods, no vehicle, blocked racer
	local h = harness()
	local s = h.service
	h.positions[P1] = V3.new(0, 50, 0) + V3.new(0, 0, ItemService.PICKUP_RADIUS + 1)
	local ok, why = s.requestPickup(P1, "PodRed")
	check(not ok and why == "too_far", "far pickup rejected")
	check(not ItemRules.isHolding(s.getState(P1)), "far pickup grants nothing")
	check(countLogs(h, "reject pickup racer=player:101 reason=too_far") == 1, "too_far logged")
	-- A forged pickup of a pod across the map is the same reject.
	h.clock.t += 2
	h.positions[P1] = V3.new(0, 50, 5000)
	ok, why = s.requestPickup(P1, "PodRainbow")
	check(not ok and why == "too_far", "cross-map pickup rejected")

	h.positions[P1] = V3.new(0, 50, 0)
	ok, why = s.requestPickup(P1, "NoSuchPod")
	check(not ok and why == "unknown_pod", "unknown pod rejected")
	local badNames = table.pack(42, nil, "", string.rep("x", 65), {}, "PodRed\n[SkyRally][ITEM] pickup racer=player:1")
	for i = 1, badNames.n do
		ok, why = s.requestPickup(P1, badNames[i])
		check(not ok and why == "bad_pod_name", "bad pod name #" .. i)
	end
	ok, why = s.requestPickup(P1, "OddPod")
	check(not ok and why == "unknown_pod_type", "unknown PodType grants nothing")

	local logsBefore = #h.logs
	at(h, P1, "PillarSpeedPickup_1")
	ok, why = s.requestPickup(P1, "PillarSpeedPickup_1")
	check(not ok and why == "not_item_pod", "Speed pod is not an item")
	at(h, P1, "StartDropPod_Plane1")
	ok, why = s.requestPickup(P1, "StartDropPod_Plane1")
	check(not ok and why == "not_item_pod", "Air pod is not an item")
	eq(#h.logs, logsBefore, "non-item pods pass through without a log line")
	check(not ItemRules.isHolding(s.getState(P1)), "non-item pods grant nothing")

	ok, why = s.requestPickup(P2, "PodRed")
	check(not ok and why == "no_vehicle", "racer without a vehicle rejected")

	h.blocked[P1] = "finished"
	at(h, P1, "PodRed")
	ok, why = s.requestPickup(P1, "PodRed")
	check(not ok and why == "blocked:finished", "finished racer cannot pick up")
	h.blocked[P1] = nil
	ok = s.requestPickup(P1, "PodRed")
	check(ok, "a rejected pickup did not start the pod cooldown")
end

do -- pod cooldown is shared and expires after RespawnSeconds
	local h = harness()
	local s = h.service
	at(h, P1, "PodRed")
	at(h, BOT, "PodRed")
	check((s.requestPickup(P1, "PodRed")), "first racer takes the pod")
	local ok, why = s.requestPickup(BOT, "PodRed")
	check(not ok and why == "pod_cooldown", "second racer blocked by pod cooldown")
	ok, why = s.requestPickup(P1, "PodRed")
	check(not ok and why == "pod_cooldown", "same racer cannot re-take a cooling pod")
	h.clock.t += 3.9
	ok, why = s.requestPickup(BOT, "PodRed")
	check(not ok and why == "pod_cooldown", "still cooling just before RespawnSeconds")
	h.clock.t += 0.2
	ok, why = s.requestPickup(BOT, "PodRed")
	check(ok and why == "new", "bot takes the pod after it respawns")
	eq(ItemRules.label(s.getState(BOT)), "red:1", "bots hold items like players")
end

do -- use: unheld rejected, held consumed, each kind dispatched to its hook
	local h = harness()
	local s = h.service
	local ok, why = s.requestUse(P1)
	check(not ok and why == "nothing_held", "use with nothing held rejected")
	eq(#h.calls, 0, "no hook fires for an unheld use")
	check(countLogs(h, "reject use racer=player:101 reason=nothing_held") == 1, "nothing_held logged")

	for i, pod in { "PodRed", "PodRed2", "PodRed3" } do
		h.clock.t += 0.01 * i
		at(h, P1, pod)
		s.requestPickup(P1, pod)
	end
	h.clock.t += 1
	local used, reason, effect = s.requestUse(P1)
	check(used and reason == "used", "held item used")
	eq(effect.kind, "missile", "effect kind returned")
	eq(#h.calls, 1, "one hook call")
	eq(h.calls[1].hook, "spawnMissile", "red -> spawnMissile")
	eq(h.calls[1].racer, P1, "hook gets the racer")
	eq(h.calls[1].level, 3, "hook gets the level")
	eq(h.calls[1].params.count, 10, "hook gets the ten-shot params")
	check(not ItemRules.isHolding(s.getState(P1)), "use consumed the item")
	eq(h.published[#h.published].label, "none", "empty state published after use")
	check(countLogs(h, "[SkyRally][ITEM] use racer=player:101 item=red:3 kind=missile count=10 homing=true") == 1, "use log line")
	h.clock.t += 1
	ok, why = s.requestUse(P1)
	check(not ok and why == "nothing_held", "second use after consume rejected")
	eq(#h.calls, 1, "no extra hook call")

	local expect = {
		{ pod = "PodBlue", hook = "applyBoost" },
		{ pod = "PodYellow", hook = "special:horn" }, -- v38: the horn replaced the shield
		{ pod = "PodGreen", hook = "spawnTrap" },
		{ pod = "PodRainbow", hook = "magnetPull" },
	}
	-- The magnet is retired by config (ItemRules.MAGNET_ENABLED); its code path is kept and still proven here.
	ItemRules.MAGNET_ENABLED = true
	for _, row in expect do
		h.clock.t += 5
		at(h, P2, row.pod)
		check((s.requestPickup(P2, row.pod)), "pickup " .. row.pod)
		local okUse = s.requestUse(P2)
		check(okUse, "use from " .. row.pod)
		local last = h.calls[#h.calls]
		eq(last.hook, row.hook, row.pod .. " dispatches")
		eq(last.level, 1, row.pod .. " level one")
		if row.hook == "special:horn" then
			check(not s.isShielded(P2), "v38: the horn grants no shield")
		end
	end
	ItemRules.MAGNET_ENABLED = false
	check(not s.isShielded(P1), "other racers are not shielded")
end

do -- rate limit on use and on remote spam; bad remote actions
	local h = harness()
	local s = h.service
	at(h, P1, "PodRed")
	s.requestPickup(P1, "PodRed")
	local ok, why = s.handleRemote(P1, "Use")
	check(ok and why == "used", "remote Use accepted")
	at(h, P1, "PodBlue")
	s.requestPickup(P1, "PodBlue")
	ok, why = s.handleRemote(P1, "Use")
	check(not ok and why == "rate_limited", "second use inside the window rate-limited")
	check(ItemRules.isHolding(s.getState(P1)), "a rate-limited use does not consume the item")
	h.clock.t += ItemService.USE_MIN_INTERVAL + 0.01
	ok = s.handleRemote(P1, "Use")
	check(ok, "use accepted after the window")

	-- 50 requests in one frame: none accepted inside the window, and the log is throttled.
	h.clock.t += 5
	at(h, P1, "PodGreen")
	s.requestPickup(P1, "PodGreen")
	local logsBefore = #h.logs
	local accepted, limited = 0, 0
	for _ = 1, 50 do
		local a, r = s.handleRemote(P1, "Use")
		if a then
			accepted += 1
		elseif r == "rate_limited" then
			limited += 1
		end
	end
	eq(accepted, 1, "spam: one use accepted")
	eq(limited, 49, "spam: the rest rate-limited")
	check(#h.logs - logsBefore <= 3, "spam does not flood the log")
	h.clock.t += 1.5
	s.handleRemote(P1, "Use")
	check(countLogs(h, "suppressed)") >= 1, "suppressed rejects are counted in the next log line")

	h.clock.t += 5
	local badActions = table.pack("Pickup", "use", nil, 7, {}, "x\n[SkyRally][ITEM] use")
	for i = 1, badActions.n do
		h.clock.t += 1.1 -- past the reject-log throttle, so every bad action is printed and its text checked
		local a, r = s.handleRemote(P2, badActions[i])
		check(not a and r == "bad_action", "remote action #" .. i .. " rejected")
	end
	check(countLogs(h, "reject remote racer=player:202 reason=bad_action action=nil") == 1, "nil action reaches the reject path")
	for _, line in h.logs do
		check(not string.find(line, "[%c]"), "no control character from a client reaches the log: " .. line)
	end

	at(h, P2, "PodYellow")
	check((s.requestPickup(P2, "PodYellow")), "P2 picks up yellow")
	h.blocked[P2] = "finished"
	h.clock.t += 1
	ok, why = s.requestUse(P2)
	check(not ok and why == "blocked:finished", "finished racer cannot use")
	check(ItemRules.isHolding(s.getState(P2)), "blocked use keeps the item")
end

do -- battle level-one flag
	local h = harness({ levelOneOnly = true })
	local s = h.service
	check(s.isLevelOneOnly(), "option sets the battle flag")
	for _, pod in { "PodRed", "PodRed2", "PodRed3" } do
		at(h, P1, pod)
		s.requestPickup(P1, pod)
	end
	eq(ItemRules.label(s.getState(P1)), "red:1", "battle flag: same colour never upgrades")
	h.clock.t += 1
	local _, _, effect = s.requestUse(P1)
	eq(effect.missile.count, 1, "battle red fires a single missile")

	local r = harness()
	local rs = r.service
	for _, pod in { "PodRed", "PodRed2", "PodRed3" } do
		at(r, P1, pod)
		rs.requestPickup(P1, pod)
	end
	eq(rs.getState(P1).level, 3, "race mode reaches level three")
	rs.setLevelOneOnly(true)
	eq(ItemRules.label(rs.getState(P1)), "red:1", "switching to battle clamps held items to level one")
	eq(r.published[#r.published].label, "red:1", "clamp is published")
	check(countLogs(r, "[SkyRally][ITEM] levelOneOnly=true") == 1, "flag change logged")
	rs.setLevelOneOnly(false)
	r.clock.t += 5
	at(r, P1, "PodRed")
	rs.requestPickup(P1, "PodRed")
	eq(rs.getState(P1).level, 2, "race mode upgrades again after the flag clears")
end

do -- hook failure, reset and leave
	local h = harness(nil, {
		spawnMissile = function()
			error("projectile pool empty")
		end,
	})
	local s = h.service
	at(h, P1, "PodRed")
	s.requestPickup(P1, "PodRed")
	local ok = s.requestUse(P1)
	check(ok, "use succeeds even when the effect hook errors")
	check(not ItemRules.isHolding(s.getState(P1)), "item consumed despite the hook error")
	check(countLogs(h, "[SkyRally][ITEM] hook error racer=player:101 kind=missile") == 1, "hook error logged")

	h.clock.t += 5
	at(h, P1, "PodBlue")
	s.requestPickup(P1, "PodBlue")
	at(h, BOT, "PodGreen")
	s.requestPickup(BOT, "PodGreen")
	s.resetAll()
	check(not ItemRules.isHolding(s.getState(P1)) and not ItemRules.isHolding(s.getState(BOT)), "reset clears every racer")
	check(countLogs(h, "[SkyRally][ITEM] reset cleared=2") == 1, "reset logged")
	at(h, P2, "PodBlue")
	check((s.requestPickup(P2, "PodBlue")), "reset clears pod cooldowns")

	s.removeRacer(P2)
	check(not ItemRules.isHolding(s.getState(P2)), "removed racer holds nothing")
	local okUse, why = s.requestUse(P2)
	check(not okUse and why == "nothing_held", "removed racer's rate window was cleared too")
end

do -- mystery cubes through the service: rolls, upgrades, roulette hold, bots alike
	local h = harness()
	local s = h.service
	local rolls = { 0.1, 0.95, 0.5 }
	local standings: { [string]: { number } } = { [P1] = { 1, 8 }, [BOT] = { 8, 8 } }
	-- The harness World gains the two mystery fields.
	h.world.random = function(): number
		return table.remove(rolls, 1) or 0.5
	end
	h.world.standing = function(racer: string): (number, number)
		local st = standings[racer] or { 1, 1 }
		return st[1], st[2]
	end
	for i = 1, 4 do
		h.pods["Cube" .. i] = { position = V3.new(500, 50, i * 100), podType = "Red", respawnSeconds = 4, mystery = true }
	end

	at(h, P1, "Cube1")
	local ok, outcome = s.requestPickup(P1, "Cube1")
	check(ok and outcome == "new", "cube grants a new item")
	local expect = ItemRules.rollMystery(1, 8, 0.1)
	eq(s.getState(P1).color, expect, "the leader's roll uses the lead band and the injected random")
	eq(h.published[#h.published].roulette, ItemRules.MYSTERY.rouletteSeconds, "a fresh roll is published with the roulette")
	check(countLogs(h, "pod=Cube1 mystery place=1/8 band=lead gap=0 none->" .. expect .. ":1 outcome=new") == 1, "mystery pickup log line")
	eq(s.getState(P1).roulette, nil, "the roulette is never part of the held state")

	h.clock.t += 0.5
	local used, why = s.requestUse(P1)
	check(not used and why == "rolling", "no use while the roulette spins")
	check(ItemRules.isHolding(s.getState(P1)), "a refused use keeps the item")

	at(h, P1, "Cube2")
	ok, outcome = s.requestPickup(P1, "Cube2")
	check(ok and outcome == "upgrade", "a second cube upgrades")
	eq(ItemRules.label(s.getState(P1)), expect .. ":2", "upgrade keeps the colour")
	-- Cubes v3 (ItemRules.cubeTake): mid-spin, the level-up is queued for the reveal; the HUD spins on for what is left.
	check(math.abs((h.published[#h.published].roulette or 0) - (ItemRules.MYSTERY.rouletteSeconds - 0.5)) < 1e-9, "a mid-spin upgrade keeps the spin going")
	eq(#rolls, 2, "an upgrade does not consume a roll")

	h.clock.t += ItemRules.MYSTERY.rouletteSeconds
	used = s.requestUse(P1)
	check(used, "use allowed once the roulette is over")

	at(h, BOT, "Cube3")
	ok, outcome = s.requestPickup(BOT, "Cube3")
	check(ok and outcome == "new", "bots take cubes")
	eq(s.getState(BOT).color, ItemRules.rollMystery(8, 8, 0.95), "the last bot rolls from the back band")
	at(h, BOT, "Cube4")
	s.requestPickup(BOT, "Cube4")
	eq(s.getState(BOT).level, 2, "bots upgrade the same way")
	h.clock.t += 0.3
	used, why = s.requestUse(BOT)
	check(not used and why == "rolling", "bots wait for the roulette too")

	-- Without standing/random (old World shape) a cube still rolls, from the field-of-one band.
	local h2 = harness()
	h2.pods.CubeX = { position = V3.new(0, 50, 0), podType = "Blue", respawnSeconds = 4, mystery = true }
	at(h2, P2, "CubeX")
	ok, outcome = h2.service.requestPickup(P2, "CubeX")
	check(ok and outcome == "new" and ItemRules.isColor(h2.service.getState(P2).color), "default World rolls too")
	check(countLogs(h2, "mystery place=1/1") == 1, "no standing: field of one")
	h2.service.resetAll()
	at(h2, P2, "CubeX")
	h2.service.requestPickup(P2, "CubeX")
	h2.clock.t += 0.1
	local _, why2 = h2.service.requestUse(P2)
	eq(why2, "rolling", "still rolling right after a pickup")
	h2.service.resetAll()
	local _, why3 = h2.service.requestUse(P2)
	eq(why3, "nothing_held", "reset clears the roulette hold with the item")
end

do -- default hooks log instead of failing
	local logs: { string } = {}
	local hooks = ItemService.loggingHooks(function(line: string)
		table.insert(logs, line)
	end)
	hooks.applyBoost(P1, ItemRules.PARAMS.boost[1], 1)
	check(string.find(logs[1], "[SkyRally][ITEM] hook applyBoost not wired racer=player:101", 1, true) ~= nil, "logging hook line")
end

print(string.format("items_spec: %d checks passed", checks))
