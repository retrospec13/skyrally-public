--!strict
-- Lune spec for the ISLAND water battle mode end to end (TEST_LIST_LAUNCH L73): the REAL server/battle/modes/Water,
-- composed with the REAL modes/Survival, over WaterRules / SurvivalRules / BattleRules and the REAL ISLAND-2 TrackData.
-- The world is the REAL plan: map/island2/plan.json's terrain heightmap, plus the galleon decks and gangway ramps in
-- the author script's ship frame (tools/map/author_island2.py). The battle context fakes BattleCore's ctx semantics
-- (entrants, positions, pods, HUD, board, toasts, eliminate, respawn, finish). It drives step() on a fake clock:
-- start (board, HUD, the dry-share log, the hidden water plane, pad grounds), the three tide steps (warn / rise /
-- settled toasts, the plane climbing), drowning (life, toast, a safe respawn off the decks, immunity), the dune that never
-- floods, out and last standing through Survival's result, item hits through Survival, leaving, the cap, bot goals,
-- arena bots respawning on the beach (never the deck) facing a dry run, and the wedged-bot watchdog.
-- Run: tools/tests/run_lune_tests.sh tools/tests/water_flow_spec.luau   (standalone: plain `lune run` also works)
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde") :: any

local V3 = roblox.Vector3
local CF = roblox.CFrame
local C3 = roblox.Color3

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd

------------------------------------------------------------------------------------------------------------------------
-- Tiny harness
------------------------------------------------------------------------------------------------------------------------

local logs: { string } = {}
local tests: { { name: string, fn: () -> () } } = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end
local function check(cond: any, msg: string)
	if not cond then
		error("check failed: " .. msg, 2)
	end
end
local function eq(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end
local function near(a: number, b: number, eps: number): boolean
	return math.abs(a - b) <= eps
end
local function capture(...: any)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(logs, table.concat(parts, " "))
end
local function findLog(needle: string): string?
	for _, line in logs do
		if string.find(line, needle, 1, true) then
			return line
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- The world: the plan's terrain plus the galleon's walkable surfaces
------------------------------------------------------------------------------------------------------------------------

local plan = serde.decode("json", fs.readFile(root .. "/map/island2/plan.json"))
local terr = plan.terrain
local HEIGHTS: { number } = terr.heights
local NX, NZ, X0, Z0, CELL = terr.nx, terr.nz, terr.x0, terr.z0, terr.cell

-- Bilinear, as the author script's Terrain.height (world heights: the plan stores them with the sea level added).
local function terrainAt(x: number, z: number): number
	local fx = (math.clamp(x, X0, X0 + (NX - 1) * CELL) - X0) / CELL
	local fz = (math.clamp(z, Z0, Z0 + (NZ - 1) * CELL) - Z0) / CELL
	local ix = math.clamp(math.floor(fx), 0, NX - 2)
	local iz = math.clamp(math.floor(fz), 0, NZ - 2)
	local tx, tz = fx - ix, fz - iz
	local function hAt(i: number, j: number): number
		return HEIGHTS[j * NX + i + 1]
	end
	local u = hAt(ix, iz) + (hAt(ix + 1, iz) - hAt(ix, iz)) * tx
	local v = hAt(ix, iz + 1) + (hAt(ix + 1, iz + 1) - hAt(ix, iz + 1)) * tx
	return u + (v - u) * tz
end

-- Ship frame (author_island2.py prefab_galleon_*): hull centre on the waterline, starboard +X = (0.8, 0.6), stern
-- +Z = (-0.6, 0.8). Main deck y 32 (|x| <= 15.7, z -35..36), forecastle 37, quarterdeck 40; gangways from the
-- starboard side (x 16.2, deck height) down to the foot over 48 onto the Plank Dune, at z -20 (fore) and 22 (aft),
-- 16 wide (trap audit G1; the foot height is read from the TrackData gangways).
local SHIP = V3.new(-5370.0, 20, 4128.0)
local GANGWAY_FOOT, GANGWAY_HALF = 20.6, 4.5 -- set from the TrackData gangways once it is loaded (below)
local EX, EZ = V3.new(0.8, 0, 0.6), V3.new(-0.6, 0, 0.8)
local function surfacesAt(x: number, z: number): { number }
	local out = { terrainAt(x, z) }
	local d = V3.new(x - SHIP.X, 0, z - SHIP.Z)
	local sx, sz = d:Dot(EX), d:Dot(EZ)
	if math.abs(sx) <= 15.7 and sz >= -35 and sz <= 36 then
		table.insert(out, 32)
	elseif math.abs(sx) <= 14.5 and sz >= -55 and sz < -35 then
		table.insert(out, 37)
	elseif math.abs(sx) <= 16.3 and sz > 36 and sz <= 58 then
		table.insert(out, 40)
	end
	for _, zoff in { -20, 22 } do
		if math.abs(sz - zoff) <= GANGWAY_HALF and sx >= 16.2 and sx <= 64.2 then
			table.insert(out, 32 - (32 - GANGWAY_FOOT) * (sx - 16.2) / 48)
		end
	end
	return out
end

local rays = 0
local function raycast(_self: any, origin: any, dir: any, _params: any): any
	rays += 1
	local lo = origin.Y + dir.Y
	local best: number? = nil
	for _, h in surfacesAt(origin.X, origin.Z) do
		if h <= origin.Y and h >= lo and (best == nil or h > (best :: number)) then
			best = h
		end
	end
	if best == nil then
		return nil
	end
	return { Position = V3.new(origin.X, best, origin.Z), Normal = V3.new(0, 1, 0), Material = "Enum.Material.Sand" }
end

------------------------------------------------------------------------------------------------------------------------
-- Module loader: the real modules, Roblox-style requires resolved onto the repo
------------------------------------------------------------------------------------------------------------------------

local cache: { [string]: any } = {}
local sources: { [string]: string } = {}
local load: (string) -> any

local function ref(rel: string): any
	return { __rel = rel, Name = string.match(rel, "([^/]+)%.luau$") }
end
local function folder(children: { [string]: any }): any
	local f: any = {}
	function f.WaitForChild(_self: any, name: string): any
		local c = children[name]
		if type(c) == "string" then
			return ref(c)
		end
		return c or error("fake folder: no child " .. name)
	end
	f.FindFirstChild = f.WaitForChild
	return f
end
local battleShared = folder({
	BattleRules = "src/shared/battle/BattleRules.luau",
	SurvivalRules = "src/shared/battle/SurvivalRules.luau",
	WaterRules = "src/shared/battle/WaterRules.luau",
})
local sharedFolder = folder({ battle = battleShared, CarConfig = "src/shared/CarConfig.luau" })
local services: { [string]: any } = {
	ReplicatedStorage = folder({ Shared = sharedFolder }),
	Players = { GetPlayers = function(): { any }
		return {}
	end },
}
local gameStub = {
	GetService = function(_self: any, name: string): any
		return services[name] or error("no stub service " .. name)
	end,
}
local workspaceStub = {
	Raycast = raycast,
	FindFirstChild = function(): any
		return nil
	end,
}
-- server/battle/modes/<Name>: script.Parent is the modes folder (Survival beside it), its Parent the battle folder.
local modesFolder = {
	Survival = ref("src/server/battle/modes/Survival.luau"),
	Parent = { BattleCore = ref("src/server/battle/BattleCore.luau") },
}
local EnumStub = setmetatable({}, {
	__index = function(_, a: string)
		return setmetatable({}, {
			__index = function(_, b: string)
				return "Enum." .. a .. "." .. b
			end,
		})
	end,
})
local function newInstance(className: string): any
	local inst: any = { ClassName = className, attrs = {} }
	function inst.SetAttribute(self: any, k: string, v: any)
		self.attrs[k] = v
	end
	function inst.GetAttribute(self: any, k: string): any
		return self.attrs[k]
	end
	return inst
end

local function stubRequire(target: any): any
	local rel = type(target) == "table" and target.__rel
	assert(type(rel) == "string", "require of an unknown target")
	if rel == "src/server/battle/BattleCore.luau" then
		return {} -- modes only take its types
	end
	return load(rel)
end

load = function(rel: string): any
	if cache[rel] ~= nil then
		return cache[rel]
	end
	local text = sources[rel] or fs.readFile(root .. "/" .. rel)
	sources[rel] = text
	local env = {
		game = gameStub,
		workspace = workspaceStub,
		script = if string.find(rel, "src/server/battle/modes/", 1, true) then { Parent = modesFolder } else { Parent = battleShared },
		require = stubRequire,
		Vector3 = V3,
		CFrame = CF,
		Color3 = C3,
		Enum = EnumStub,
		Instance = { new = newInstance },
		RaycastParams = { new = function(): any
			return {}
		end },
		print = capture,
		warn = function(...: any)
			capture("WARN", ...)
		end,
	}
	local chunk = luau.load(text, { debugName = rel, environment = env })
	local result = chunk()
	cache[rel] = result
	return result
end

local island = load("build/island2/TrackData.luau")
-- The rule flows run on the v27 arena (deck pad, deck pods, the 150 disc; tools/tests/fixtures/island2_v27_battle.luau):
-- the live arena has no deck seat or deck pod since owner 2026-10-21, but the mode still handles both. The last test
-- starts the LIVE arena.
local LIVE_BATTLE = island.modes.battle
local V27_BATTLE = load("tools/tests/fixtures/island2_v27_battle.luau")(LIVE_BATTLE)
do -- the world's gangway ramps follow the plan's (author_island2.py: 16 wide, the foot on the Plank Dune)
	local g = island.modes.battle.gangways[1]
	GANGWAY_FOOT, GANGWAY_HALF = g.foot.Y, (g.width or 9) / 2
end
local BattleRules = load("src/shared/battle/BattleRules.luau")
local SurvivalRules = load("src/shared/battle/SurvivalRules.luau")
local WaterRules = load("src/shared/battle/WaterRules.luau")
local Water = load("src/server/battle/modes/Water.luau")
local Survival = load("src/server/battle/modes/Survival.luau")

------------------------------------------------------------------------------------------------------------------------
-- Fake battle context (BattleCore.newCtx semantics)
------------------------------------------------------------------------------------------------------------------------

local RIDE = 1.9 -- CarConfig.RIDE_HEIGHT

-- ISLAND-2 pads by role (tools/map/author_island2.py, trap audit G1 seat order): 1 crest B (the player's seat),
-- 2 the Plank Dune by the fore gangway foot, 3 the shallows, 4 the beach dune, 5 spit pad A, 6 the deck (last).
local PAD = { crest = 1, plank = 2, shallows = 3, dune = 4, spit = 5, deck = 6 }

type World = {
	ctx: any,
	clock: { t: number, os: number },
	pos: { [string]: any },
	fwd: { [string]: any },
	held: { [string]: string? },
	toasts: { { id: string?, text: string, tone: string? } },
	respawns: { { id: string, cf: any, t: number } },
	finished: { any },
	podParts: { any },
}

-- Field: the player on the shallows pad, bots on the deck pad, the Plank Dune pad and the beach dune pad.
local function newBattle(live: boolean?): World
	table.clear(logs)
	local battle = if live then LIVE_BATTLE else V27_BATTLE
	local arena = BattleRules.arena(battle)
	local w: World = {
		ctx = nil,
		clock = { t = -3, os = 100 },
		pos = {},
		fwd = {},
		held = {},
		toasts = {},
		respawns = {},
		finished = {},
		podParts = {},
	}
	local seats = {
		{ id = "player:1", name = "Tester", isPlayer = true, slot = PAD.shallows },
		{ id = "bot:101", name = "Ace", isPlayer = false, slot = PAD.deck },
		{ id = "bot:102", name = "Blaze", isPlayer = false, slot = PAD.plank },
		{ id = "bot:103", name = "Comet", isPlayer = false, slot = PAD.dune },
	}
	if live then -- the live field: the player on seat 1 and seven bots on the other sand pads (BattleRules.FIELD)
		seats = { { id = "player:1", name = "Tester", isPlayer = true, slot = 1 } }
		for i = 2, BattleRules.FIELD do
			table.insert(seats, { id = "bot:" .. tostring(99 + i), name = "Bot" .. tostring(i), isPlayer = false, slot = i })
		end
	end
	local entrants, byId = {}, {}
	for _, s in seats do
		local e = {
			id = s.id,
			name = s.name,
			isPlayer = s.isPlayer,
			player = if s.isPlayer then { Name = s.name, UserId = 1 } else nil,
			bot = nil,
			slot = s.slot,
			out = false,
			spectator = false,
			left = false,
			score = 0,
			scoreText = "",
			hud = "",
		}
		table.insert(entrants, e)
		byId[e.id] = e
		local pad = arena.spawns[s.slot]
		w.pos[e.id] = V3.new(pad.X, terrainAt(pad.X, pad.Z) + RIDE, pad.Z)
		w.fwd[e.id] = V3.new(1, 0, 0)
	end
	-- The deck pad stands on the deck, not on the basin floor under it.
	if not live then
		local deckPad = arena.spawns[PAD.deck]
		w.pos["bot:101"] = V3.new(deckPad.X, 32 + RIDE, deckPad.Z)
	end
	local pods = {}
	for i, spec in BattleRules.podSpecs(battle, Water.podTypes) do
		local part = newInstance("Part")
		part.Parent = true
		part:SetAttribute("OnCooldown", false)
		table.insert(w.podParts, part)
		table.insert(pods, { name = "BattlePod_" .. i, part = part, pos = spec.pos, podType = spec.podType })
	end
	local ctx: any = {
		td = island,
		battle = battle,
		rules = {},
		arena = arena,
		folder = newInstance("Folder"),
		zone = island.zone,
		trackId = island.id,
		vehicle = "car",
		entrants = entrants,
		byId = byId,
	}
	local function inPlay(e: any): boolean
		return not e.out and not e.spectator
	end
	function ctx.now(): number
		return w.clock.os
	end
	function ctx.elapsed(): number
		return w.clock.t
	end
	function ctx.timeLeft(): number
		return math.max(0, 180 - w.clock.t)
	end
	function ctx.position(id: string): any
		return w.pos[id]
	end
	function ctx.forward(id: string): any
		return w.fwd[id]
	end
	function ctx.alive(): { any }
		local out = {}
		for _, e in entrants do
			if inPlay(e) then
				table.insert(out, e)
			end
		end
		return out
	end
	function ctx.pods(): { any }
		return pods
	end
	function ctx.holding(id: string): (string?, number)
		local c = w.held[id]
		return c, if c then 1 else 0
	end
	function ctx.setHud(id: string, text: string)
		local e = byId[id]
		if e then
			e.hud = text
		end
	end
	function ctx.setScore(id: string, score: number, text: string)
		local e = byId[id]
		if e then
			e.score, e.scoreText = score, text
		end
	end
	function ctx.toast(id: string?, text: string, tone: string?)
		table.insert(w.toasts, { id = id, text = text, tone = tone })
	end
	function ctx.eliminate(id: string, _why: string)
		local e = byId[id]
		if e then
			e.out = true
		end
	end
	function ctx.respawn(id: string, cf: any)
		local e = byId[id]
		local frame = cf or BattleRules.spawnCFrame(arena, e.slot)
		table.insert(w.respawns, { id = id, cf = frame, t = w.clock.t })
		w.pos[id] = frame.Position
	end
	function ctx.finish(result: any)
		table.insert(w.finished, result)
	end
	function ctx.log(fmt: string, ...: any)
		capture("[SkyRally][BATTLE] " .. string.format(fmt, ...))
	end
	function ctx.nearestOpponent(): (any, number)
		return nil, math.huge
	end
	function ctx.nearestPod(): any
		return nil
	end
	function ctx.hit(): string
		return "inactive"
	end
	w.ctx = ctx
	return w
end

-- Advances the fake clock to t (seconds after GO), stepping the mode at 30 Hz like Heartbeat after GO.
local function runTo(w: World, st: any, t: number)
	local dt = 1 / 30
	while w.clock.t < t - 1e-9 do
		local stepDt = math.min(dt, t - w.clock.t)
		w.clock.t += stepDt
		w.clock.os += stepDt
		if w.clock.t >= 0 and #w.finished == 0 then
			Water.step(w.ctx, st, stepDt)
		end
	end
	w.clock.t = t -- no float drift in what the next call reads
end

local function toastsMatching(w: World, needle: string): { any }
	local out = {}
	for _, t in w.toasts do
		if string.find(t.text, needle, 1, true) then
			table.insert(out, t)
		end
	end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------------------------------------------------------

test("registration: kind water, title, survival's pod colours, a car-bot water depth under the drown depth", function()
	eq(Water.kind, "water", "kind = TrackData.modes.battle.kind")
	eq(island.modes.battle.kind, "water", "ISLAND-2 runs it")
	eq(Water.title, "WATER BATTLE", "title")
	eq(Water.podTypes, Survival.podTypes, "item combat as SNOW")
	check(Water.maxWaterDepth < WaterRules.tide(island.modes.battle).drownDepth, "bots keep off water near the drown depth")
	for _, fn in { "start", "step", "onHit", "onLeave", "botGoal", "resolve" } do
		check(type(Water[fn]) == "function", fn)
	end
end)

test("start: survival seats with 3 lives, the tide HUD, the hidden water plane, pad grounds and the dry-share log", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	for _, e in w.ctx.entrants do
		eq(e.score, 3, e.name .. " lives on the board")
		eq(e.scoreText, "3 LIVES", e.name .. " board text")
		eq(e.hud, "LIVES 3  -  TIDE 1/3 IN 0:50", e.name .. " HUD")
	end
	check(findLog("survival start entrants=4 lives=3"), "Survival seated the field")
	local line = findLog("water start ") :: string
	check(line, "start log")
	check(string.find(line, "steps=50s:21.5,100s:23.0,140s:24.5", 1, true), "steps in the log: " .. line)
	local shares = {}
	for pct in string.gmatch(string.match(line, "dry=([%d%%/]+)") or "", "(%d+)%%") do
		table.insert(shares, tonumber(pct))
	end
	eq(#shares, 4, "a dry share per level")
	for i = 2, 4 do
		check(shares[i] < shares[i - 1], string.format("the dry area shrinks every step (%s)", line))
	end
	-- (the Plank Dune and its spit, dry at every step since the trap audit G1, keep high tide a little over a third)
	check(shares[1] >= 60 and shares[4] <= 40, "most of the cove is drivable at first, ~a third at high tide: " .. line)
	eq(#w.ctx.arena.spawns, 6, "six pads")
	eq(st.spawnGround[PAD.deck], 32, "the deck pad stands on the deck")
	check(near(st.spawnGround[PAD.crest], terrainAt(-5215, 4195), 1e-3), "crest pad B, the player's seat")
	check(near(st.spawnGround[PAD.plank], 24.6, 0.05), "the Plank Dune pad")
	check(near(st.spawnGround[PAD.shallows], terrainAt(-5350, 4320), 1e-3), "the shallows pad")
	check(near(st.spawnGround[PAD.dune], 23.25, 0.05), "the dune pad")
	check(near(st.spawnGround[PAD.spit], 24.6, 0.05), "spit pad A")
	for i = 1, 4 do
		check(not st.deckPads[i], "seat " .. i .. " is off the galleon")
	end
	local water = st.water
	eq(water.Parent, w.ctx.folder, "the plane lives in the battle folder")
	eq(water.CanQuery, false, "no ray ever lands on the plane")
	eq(water.CanCollide, false, "drive through it")
	eq(water.Transparency, 1, "hidden at the base level")
	check(near(water.CFrame.Position.Y + water.Size.X / 2, 20, 1e-6), "top face at the base level")
	check(near(water.Size.Y, w.ctx.arena.returnRadius * 2, 1e-6), "covers the arena and its soft band")
	check(rays > 1500, "the arena grid was sampled: " .. rays)
end)

test("tide: warn, rise and settled toasts per step; the plane climbs and fades in; the HUD counts down", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	-- Keep everyone dry for this test: all on the dune pad.
	local dune = w.ctx.arena.spawns[4]
	for id in w.pos do
		w.pos[id] = V3.new(dune.X, 23.25 + RIDE, dune.Z)
	end
	runTo(w, st, 41)
	eq(#toastsMatching(w, "TIDE 1/3"), 0, "nothing before the warning")
	runTo(w, st, 43)
	eq(#toastsMatching(w, "TIDE 1/3 IN 8 - HEAD FOR HIGH GROUND"), 1, "warned 8 s ahead")
	runTo(w, st, 52)
	eq(#toastsMatching(w, "TIDE 1/3 RISING"), 1, "rise toast")
	local mid = st.water.CFrame.Position.Y + st.water.Size.X / 2
	check(mid > 20.2 and mid < 21.3, "half way up: " .. mid)
	check(st.water.Transparency < 1 and st.water.Transparency > 0.45, "fading in")
	eq(w.ctx.byId["player:1"].hud, "LIVES 3  -  TIDE 1/3 RISING", "HUD while rising")
	runTo(w, st, 55)
	check(near(st.water.CFrame.Position.Y + st.water.Size.X / 2, 21.5, 1e-6), "settled at 21.5")
	check(near(st.water.Transparency, 0.45, 1e-6), "risen water")
	local settled = toastsMatching(w, "TIDE 1/3 IS UP - DRY LAND LEFT")
	eq(#settled, 1, "settled toast")
	check(findLog("water tide step=1/3 level=21.5 dry="), "settled log with the dry share")
	local hud = w.ctx.byId["player:1"].hud
	check(hud == "LIVES 3  -  TIDE 2/3 IN 0:45" or hud == "LIVES 3  -  TIDE 2/3 IN 0:46", "next step countdown (4 Hz HUD): " .. hud)
	runTo(w, st, 150)
	check(near(st.water.CFrame.Position.Y + st.water.Size.X / 2, 24.5, 1e-6), "high tide 24.5")
	eq(#toastsMatching(w, "IS UP - DRY LAND LEFT"), 3, "three steps")
	eq(w.ctx.byId["player:1"].hud, "LIVES 3  -  HIGH TIDE", "high tide HUD")
	eq(#w.respawns, 0, "nobody on the dune drowned")
	for _, e in w.ctx.entrants do
		eq(e.score, 3, e.name .. " kept every life on the dune")
	end
end)

test("drowning: the shallows go under at step 1; a life, a toast, a safe beach pad (never the deck), then immunity", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	local dune = w.ctx.arena.spawns[4]
	for _, id in { "bot:101", "bot:102", "bot:103" } do
		w.pos[id] = V3.new(dune.X, 23.25 + RIDE, dune.Z)
	end
	local shallows = w.pos["player:1"]
	runTo(w, st, 44)
	check(string.find(w.ctx.byId["player:1"].hud, "HIGH GROUND!", 1, true), "the nudge: " .. w.ctx.byId["player:1"].hud)
	runTo(w, st, 50.5)
	eq(#w.respawns, 0, "not yet: the water climbs over the rise")
	runTo(w, st, 54)
	eq(#w.respawns, 1, "caught by the tide")
	local r = w.respawns[1]
	local drownLevel = WaterRules.levelAt(st.tide, r.t)
	local depth = drownLevel - (shallows.Y - RIDE)
	check(depth > 2.2 and depth < 2.4, string.format("caught as the water passed the drown depth (%.2f at %.2f s)", depth, r.t))
	eq(r.id, "player:1", "the player")
	-- Trap audit G1: never the galleon (the owner's "teleported back onto the ship"). The safe pad is dry through the
	-- coming step, at least SAFE_CLEAR from where he went under and farthest from the bots on the dune: the Plank Dune
	-- (139 studs from them; crest B is 86, spit pad A 81).
	check(r.cf.Position ~= w.ctx.arena.spawns[PAD.deck], "never back on the deck pad")
	check(r.cf.Position == w.ctx.arena.spawns[PAD.plank], "on the Plank Dune pad, away from the bots")
	check(BattleRules.horizontal(r.cf.Position, shallows) >= WaterRules.SAFE_CLEAR, "away from where he drowned")
	check(WaterRules.isDry(st.spawnGround[PAD.plank], WaterRules.levelAhead(st.tide, r.t, st.tide.rise + WaterRules.WARN_SECONDS), 2.2), "dry through the coming step")
	eq(w.ctx.byId["player:1"].score, 2, "a life lost")
	eq(w.ctx.byId["player:1"].scoreText, "2 LIVES", "board")
	eq(#toastsMatching(w, "SWAMPED! 2 lives left"), 1, "toast to the player")
	check(findLog("water drown Tester (player:1)"), "drown log")
	check(SurvivalRules.livesOf(st.survival.rules, "player:1") == 2, "SurvivalRules counts it")
	eq(st.survival.rules.entries["player:1"].hitsTaken, 1, "one life lost")
	-- The respawn has not replicated yet: the server still sees the car in the water. Immune.
	w.pos["player:1"] = shallows
	runTo(w, st, r.t + WaterRules.IMMUNE - 0.1)
	eq(#w.respawns, 1, "immune while the teleport replicates")
	runTo(w, st, r.t + WaterRules.IMMUNE + WaterRules.GRACE + 0.2)
	eq(#w.respawns, 2, "still in the water after the immunity: a second life")
	eq(w.ctx.byId["player:1"].score, 1, "one life left")
	check(w.respawns[2].cf.Position ~= w.ctx.arena.spawns[PAD.deck], "the second respawn is not the deck either")
	local plank = w.ctx.arena.spawns[PAD.plank]
	w.pos["player:1"] = V3.new(plank.X, st.spawnGround[PAD.plank] + RIDE, plank.Z)
	runTo(w, st, 150)
	eq(w.ctx.byId["player:1"].score, 1, "safe on the Plank Dune pad through high tide")
	eq(#w.finished, 0, "the battle goes on")
end)

test("out and last standing: the tide takes the last lives; Survival's result ranks the field", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	-- The player sits on the dune; the three bots wait in the shallows and keep drowning (each respawn, back in).
	local dune = w.ctx.arena.spawns[4]
	w.pos["player:1"] = V3.new(dune.X, 23.25 + RIDE, dune.Z)
	local shallows = V3.new(-5350, terrainAt(-5350, 4320) + RIDE, 4320)
	for _, id in { "bot:101", "bot:102", "bot:103" } do
		w.pos[id] = shallows
	end
	local t = 50
	while #w.finished == 0 and t < 120 do
		t += 0.5
		runTo(w, st, t)
		for _, id in { "bot:101", "bot:102", "bot:103" } do
			if not w.ctx.byId[id].out then
				w.pos[id] = shallows
			end
		end
	end
	eq(#w.finished, 1, "the battle ended")
	local result = w.finished[1]
	eq(result.winner, "player:1", "the last car with lives")
	eq(result.reason, "last one standing", "Survival's reason text")
	eq(result.ranking[1], "player:1", "ranked first")
	eq(#result.ranking, 4, "everyone ranked")
	eq(result.texts["player:1"], "3 LIVES", "results text")
	eq(result.texts["bot:101"], "OUT", "out text")
	for _, id in { "bot:101", "bot:102", "bot:103" } do
		check(w.ctx.byId[id].out, id .. " eliminated")
	end
	eq(#toastsMatching(w, "is OUT"), 3, "everyone hears each elimination")
	check(findLog("water over reason=last standing winner=player:1"), "over log")
	local n = #w.respawns
	runTo(w, st, t + 5)
	eq(#w.respawns, n, "nothing more after the end")
end)

test("item hits are survival's: a life, the HIT toast, the tide HUD put back; a final hit ends it", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	runTo(w, st, 10)
	local p, ace = w.ctx.byId["player:1"], w.ctx.byId["bot:101"]
	Water.onHit(w.ctx, st, p, ace, "missile", w.pos["player:1"])
	eq(p.score, 2, "a life")
	eq(#toastsMatching(w, "HIT! 2 lives left"), 1, "survival's toast")
	eq(#toastsMatching(w, "HIT TESTER!"), 0, "no attacker toast for a bot")
	eq(p.hud, "LIVES 2  -  TIDE 1/3 IN 0:40", "the tide HUD after survival's refresh")
	eq(st.survival.rules.entries["bot:101"].hitsLanded, 1, "credited")
	-- A second hit while the life-loss grace runs (Water LIFE_GRACE, 6 s) costs nothing.
	runTo(w, st, 12)
	Water.onHit(w.ctx, st, p, ace, "trap", w.pos["player:1"])
	eq(p.score, 2, "no second life inside the grace")
	eq(st.survival.rules.entries["bot:101"].hitsLanded, 1, "and no credit")
	local t = 12
	for _ = 1, 3 do
		t += 6.2 -- past the grace, still before the first tide step
		runTo(w, st, t)
		for _, id in { "bot:102", "bot:103" } do
			Water.onHit(w.ctx, st, w.ctx.byId[id], p, "missile", w.pos[id])
		end
	end
	eq(#w.finished, 0, "two left")
	for _ = 1, 3 do
		t += 6.2 -- past the grace, still before the first tide step
		runTo(w, st, t)
		Water.onHit(w.ctx, st, ace, p, "missile", w.pos["bot:101"])
	end
	eq(#w.finished, 1, "the last hit ends it through Survival")
	eq(w.finished[1].winner, "player:1", "winner")
	check(st.over, "the mode knows")
	Water.onHit(w.ctx, st, p, nil, "trap", w.pos["player:1"])
	eq(p.score, 2, "hits after the end change nothing")
end)

test("leaving and the cap: a leaver forfeits through Survival; at the cap the most lives win", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	runTo(w, st, 20)
	local p = w.ctx.byId["player:1"]
	Water.onHit(w.ctx, st, w.ctx.byId["bot:102"], p, "missile", w.pos["bot:102"])
	Water.onHit(w.ctx, st, w.ctx.byId["bot:103"], p, "missile", w.pos["bot:103"])
	runTo(w, st, 27) -- past the life-loss grace
	Water.onHit(w.ctx, st, w.ctx.byId["bot:103"], p, "missile", w.pos["bot:103"])
	local result = Water.resolve(w.ctx, st, "time")
	eq(result.reason, "time up - most lives wins", "cap reason")
	check(result.winner == "player:1" or result.winner == "bot:101", "a car with 3 lives wins")
	eq(result.ranking[4], "bot:103", "fewest lives last")
	check(st.over, "resolved")

	local w2 = newBattle()
	local st2 = Water.start(w2.ctx)
	runTo(w2, st2, 5)
	local bot = w2.ctx.byId["bot:101"]
	bot.out = true -- BattleCore marks a leaver out before onLeave
	Water.onLeave(w2.ctx, st2, bot)
	check(SurvivalRules.isOut(st2.survival.rules, "bot:101"), "forfeit")
	eq(bot.scoreText, "OUT", "board")
	eq(#w2.finished, 0, "three still in")
end)

test("bot goals: flee the shallows before step 1, pods early, stay on the deck, and a fresh gangway waypoint", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	local blaze = w.ctx.byId["bot:102"]
	local shallows = V3.new(-5340, terrainAt(-5340, 4300) + RIDE, 4300)
	w.pos["bot:102"] = shallows
	runTo(w, st, 5)
	local early = Water.botGoal(w.ctx, st, blaze)
	-- Early on: a pod, unless the shallows it stands in are already deeper than the bots' safe margin allows (then it
	-- first drives out of them).
	local here = shallows.Y - RIDE
	local safeHere = WaterRules.isDry(here, 20, 2.2, WaterRules.SAFE_MARGIN)
	check(early.reason == "pod" or early.reason == "pod deck" or (early.reason == "flee" and not safeHere),
		"early on: a pod, or out of the deep shallows (" .. tostring(early.reason) .. ")")
	w.clock.os += 1
	runTo(w, st, 44)
	w.pos["bot:102"] = shallows
	local flee = Water.botGoal(w.ctx, st, blaze)
	eq(flee.reason, "flee", "step 1 is coming")
	local ground = WaterRules.heightAt(st.course.grid, flee.pos.X, flee.pos.Z)
	check(ground and WaterRules.isDry(ground, 21.5, 2.2), "to ground that stays dry")

	local ace = w.ctx.byId["bot:101"]
	w.clock.os += 1
	local deckGoal = Water.botGoal(w.ctx, st, ace)
	local dg = WaterRules.heightAt(st.course.grid, deckGoal.pos.X, deckGoal.pos.Z)
	check(dg and dg >= 31, "the deck bot keeps to the decks (" .. tostring(deckGoal.reason) .. ")")

	-- A bot on the fore gangway heading up: the waypoint follows it every call, without a new decision.
	local g = st.course.gangways[1]
	local comet = w.ctx.byId["bot:103"]
	local onRamp = g.foot:Lerp(g.top, 0.3)
	w.pos["bot:103"] = onRamp
	w.fwd["bot:103"] = g.axis
	w.clock.os += 1
	local first = Water.botGoal(w.ctx, st, comet)
	eq(first.reason, "board", "on the ramp: board")
	local s1 = WaterRules.rampCoords(g, first.pos)
	w.pos["bot:103"] = g.foot:Lerp(g.top, 0.6)
	local second = Water.botGoal(w.ctx, st, comet)
	local s2 = WaterRules.rampCoords(g, second.pos)
	check(s2 > s1, "the waypoint moved up with the bot")
end)

-- The respawn frame Water builds: the pad, facing WaterRules.dryHeading (compared through the same CFrame.lookAt, so
-- the check does not depend on how a CFrame library orders its look vector).
local function expectFrame(st: any, w: World, slot: number, level: number, bot: boolean): any
	local arena = w.ctx.arena
	local p = arena.spawns[slot]
	local skip = if bot
		then function(x: number, z: number, h: number): boolean
			return WaterRules.offBeach(st.course, x, z, h)
		end
		else nil
	local dir = WaterRules.respawnHeadings(st.course.grid, p, level, st.tide.drownDepth, 60, arena.center, skip, arena.looks[slot])[1]
	return CF.lookAt(p, p + dir), dir
end

test("respawns: the player and a bot on safe pads apart (never the deck), each facing its authored heading or a dry run", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	check(st.course.grid.radius >= w.ctx.arena.returnRadius, "the grid covers the boundary band bots still roam")
	for i = 1, #w.ctx.arena.spawns do
		check((st.deckPads[i] == true) == (i == PAD.deck), "only the last pad is a deck pad (" .. i .. ")")
	end
	local dune = w.ctx.arena.spawns[PAD.dune]
	for _, id in { "bot:101", "bot:103" } do
		w.pos[id] = V3.new(dune.X, 23.25 + RIDE, dune.Z)
	end
	-- The player (shallows pad) and Blaze both wait in the shallows: step 1 takes a life from each, the player first.
	-- pickSafeSpawn spreads them (trap audit I2-10): the player to the Plank Dune (farthest from the bots on the dune),
	-- then Blaze to crest B (the Plank Dune now has the player on it). Neither goes to the deck.
	local shallows = w.pos["player:1"]
	w.pos["bot:102"] = shallows
	runTo(w, st, 54)
	eq(#w.respawns, 2, "both caught by step 1")
	local want = { ["player:1"] = PAD.plank, ["bot:102"] = PAD.crest }
	for _, r in w.respawns do
		local isBot = r.id ~= "player:1"
		local slot = want[r.id]
		check(r.cf.Position == w.ctx.arena.spawns[slot], r.id .. " back on pad " .. slot)
		check(not st.deckPads[slot], r.id .. " never on the deck")
		check(BattleRules.horizontal(r.cf.Position, shallows) >= WaterRules.SAFE_CLEAR, r.id .. " away from where it drowned")
		local level = WaterRules.levelAhead(st.tide, r.t, st.tide.rise + WaterRules.WARN_SECONDS)
		local frame, dir = expectFrame(st, w, slot, level, isBot)
		check((r.cf.LookVector - frame.LookVector).Magnitude < 1e-4, r.id .. " faces the authored heading or the longest dry run")
		local ahead = w.ctx.arena.spawns[slot] + dir * 20
		local ground = WaterRules.heightAt(st.course.grid, ahead.X, ahead.Z) :: number
		check(WaterRules.isDry(ground, level, st.tide.drownDepth, WaterRules.SAFE_MARGIN), string.format("%s: 20 studs on is dry (%.1f at %.1f)", r.id, ground, level))
	end
	check(w.respawns[1].cf.Position ~= w.respawns[2].cf.Position, "two respawns at once never share a pad")
	eq(w.ctx.byId["bot:102"].score, 2, "Blaze lost a life")
	check(findLog("water drown Blaze (bot:102)") and string.find(findLog("water drown Blaze") :: string, "respawn=pad" .. PAD.crest, 1, true), "logged to pad " .. PAD.crest)
	-- The player's pad keeps its authored heading (crest pads face along the dune, down the gangway for the deck).
	local look = w.ctx.arena.looks[PAD.plank]
	local plankPad = w.ctx.arena.spawns[PAD.plank]
	check(look ~= nil and (w.respawns[1].cf.LookVector - CF.lookAt(plankPad, plankPad + look).LookVector).Magnitude < 1e-4, "the Plank Dune pad faces its authored heading")
end)

test("watchdog: a wedged arena bot is set down on a beach pad away from where it froze; no life, immune", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	-- Real arena bots (BattleBots records); the test world never moves them, so every one of them is wedged.
	for _, id in { "bot:101", "bot:102", "bot:103" } do
		w.ctx.byId[id].bot = { stunTimer = 0 }
	end
	w.ctx.byId["bot:103"].bot.stunTimer = 5 -- spinning out: allowed to crawl
	runTo(w, st, WaterRules.STUCK_SECONDS - 0.1)
	eq(#w.respawns, 0, "not yet")
	runTo(w, st, WaterRules.STUCK_SECONDS + 0.1)
	local moved: { [string]: any } = {}
	for _, r in w.respawns do
		moved[r.id] = r
	end
	eq(#w.respawns, 2, "the two wedged bots")
	check(moved["player:1"] == nil, "a player may park")
	check(moved["bot:103"] == nil, "a stunned bot is left alone")
	-- Ace froze on the deck pad: down to the beach pad farthest from the others (crest B: the player sits on the
	-- shallows pad, Blaze on the Plank Dune, Comet on the beach dune). Blaze froze on the Plank Dune: away from it, and
	-- from Ace now on crest B, onto spit pad A (trap audit I2-10: the bots no longer stack on one pad).
	local aceSlot = PAD.crest
	local blazeSlot = PAD.spit
	check(moved["bot:101"].cf.Position == w.ctx.arena.spawns[aceSlot], "Ace off the deck onto pad " .. aceSlot)
	check(moved["bot:102"].cf.Position == w.ctx.arena.spawns[blazeSlot], "Blaze onto pad " .. blazeSlot)
	check(aceSlot ~= PAD.deck and blazeSlot ~= PAD.plank, "never the deck, never where it froze")
	for _, e in w.ctx.entrants do
		eq(e.score, 3, e.name .. " lost no life")
	end
	check(findLog("water unstick Ace (bot:101)"), "unstick log")
	-- Wedged again right where it was set down: the next pad is a different one.
	runTo(w, st, 2 * WaterRules.STUCK_SECONDS + 0.2)
	local again = w.respawns[#w.respawns]
	check(again.id == "bot:101" or again.id == "bot:102", "reported again")
	local frozeOn = w.ctx.arena.spawns[if again.id == "bot:101" then aceSlot else blazeSlot]
	check(again.cf.Position ~= frozeOn, "not the pad it froze on")
	check(again.cf.Position ~= w.ctx.arena.spawns[PAD.deck], "never the deck while a beach pad is dry")
	-- Immune to the tide after a move: dropped in deep water at once, no drown before the immunity ends.
	local n = #w.respawns
	local t0 = w.clock.t
	local deep = V3.new(-5390, 2 + RIDE, 4110)
	w.pos[again.id] = deep
	runTo(w, st, t0 + 0.5)
	eq(#w.respawns, n, "immune right after the move")
	eq(w.ctx.byId[again.id].score, 3, "no life lost while immune")
end)

local function padIndex(w: World, pos: any): number?
	for i, p in w.ctx.arena.spawns do
		if (p - pos).Magnitude < 1e-3 then
			return i
		end
	end
	return nil
end

test("boundary return (BattleCore returnFrame): the safe pad nearest the exit, never the deck; tide-immune after", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	runTo(w, st, 105)
	local player = w.ctx.byId["player:1"]
	local lives = player.score
	-- Off the arena down the cavern-mouth road (trap audit I2-05: the nearest pad by 3-D distance was the shallows pad,
	-- flooded from t = 100, so the put-back drowned him).
	local cavern = V3.new(-5176, 28, 4150)
	local cf = Water.returnFrame(w.ctx, st, player, cavern)
	check(cf ~= nil, "a frame")
	local slot = padIndex(w, (cf :: any).Position) :: number
	check(slot ~= nil and not st.deckPads[slot], "a pad, never the deck")
	local level = WaterRules.levelAhead(st.tide, 105, st.tide.rise + WaterRules.WARN_SECONDS)
	check(WaterRules.isDry(st.spawnGround[slot], level, 2.2), "dry through the coming step")
	eq(slot, PAD.crest, "crest B, the safe pad nearest the cavern mouth")
	check(findLog("water return Tester"), "logged")
	-- The put-back has not replicated: the server still sees the car somewhere deep. The tide immunity covers it.
	w.pos["player:1"] = V3.new(-5390, 2 + RIDE, 4110)
	runTo(w, st, 106)
	eq(player.score, lives, "no life lost while the put-back replicates")
end)

test("frameSafe (asked respawns): the deck pad never; a pad the coming step floods no; a pad dry through it yes", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	local pads = w.ctx.arena.spawns
	runTo(w, st, 1)
	eq(Water.frameSafe(w.ctx, st, pads[PAD.deck]), false, "the deck pad is never a respawn (G1)")
	eq(Water.frameSafe(w.ctx, st, pads[PAD.crest]), true, "crest B")
	eq(Water.frameSafe(w.ctx, st, pads[PAD.plank]), true, "the Plank Dune")
	eq(Water.frameSafe(w.ctx, st, w.ctx.arena.center + V3.new(0, 0, 500)), true, "not a pad: left alone")
	-- Step 1's look-ahead takes the shallows pad: the frame a drown left there is no longer safe.
	local shallowsGround = st.spawnGround[PAD.shallows]
	local t = 0
	while t < 200 and WaterRules.isDry(shallowsGround, WaterRules.levelAhead(st.tide, t, st.tide.rise + WaterRules.WARN_SECONDS), st.tide.drownDepth) do
		t += 1
	end
	check(t < 200, "the shallows pad floods at some step")
	runTo(w, st, math.max(t, 2))
	eq(Water.frameSafe(w.ctx, st, pads[PAD.shallows]), false, string.format("the shallows pad at %.0f s", t))
end)

test("doomed pods sink at their step's warning; pods on ground that stays dry (the dune, the decks) stay", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	local pods = w.ctx.pods()
	runTo(w, st, 41.5) -- step 1 is warned at 42
	for _, pod in pods do
		check(pod.part:GetAttribute("Sinking") == nil, pod.name .. " still up before the warning")
	end
	local sunkAt1 = 0
	runTo(w, st, 42.5)
	for _, pod in pods do
		local doomed = not WaterRules.isDry(st.podGround[pod.name], 21.5, 2.2)
		eq(pod.part:GetAttribute("Sinking") == true, doomed, pod.name .. " sinks at step 1 iff its ground floods")
		if doomed then
			sunkAt1 += 1
		end
	end
	check(sunkAt1 >= 2, "the two shallows pods go at step 1 (" .. sunkAt1 .. ")")
	runTo(w, st, 150)
	local deckPods = 0
	for _, pod in pods do
		local doomed = not WaterRules.isDry(st.podGround[pod.name], 24.5, 2.2)
		eq(st.sunk[pod.name] == true, doomed, pod.name .. " gone iff high tide floods its ground")
		if WaterRules.onDeck(st.course, pod.pos, st.podGround[pod.name]) then
			deckPods += 1
			check(not st.sunk[pod.name], pod.name .. ": a deck pod stays")
		end
	end
	eq(deckPods, 3, "three deck pods")
	eq(#st.sinking, 0, "every sink finished")
	check(findLog("water pod sinks BattlePod_"), "logged")
end)

test("targeting: a beach bot never locks a human on the decks; any bot locks a human once per HUMAN_SHOT_GAP", function()
	local w = newBattle()
	local st = Water.start(w.ctx)
	runTo(w, st, 1)
	local player, ace, blaze = w.ctx.byId["player:1"], w.ctx.byId["bot:101"], w.ctx.byId["bot:102"]
	local deck = w.ctx.arena.spawns[PAD.deck]
	-- On the deck: Blaze (on the Plank Dune) may not lock him, Ace (on the deck too) may.
	w.pos["player:1"] = V3.new(deck.X + 3, 32 + RIDE, deck.Z)
	eq(Water.targetable(w.ctx, st, blaze, player), false, "beach bot -> human on the deck")
	eq(Water.targetable(w.ctx, st, ace, player), true, "deck bot -> human on the deck")
	eq(Water.targetable(w.ctx, st, blaze, ace), true, "bots are always fair game")
	eq(Water.targetable(w.ctx, st, player, blaze), true, "the human shoots anyone")
	local g = Water.botGoal(w.ctx, st, blaze)
	check(g.attack ~= "player:1", "Blaze's goal does not aim at him: " .. tostring(g.attack))
	-- Back on the beach: one lock, then none for HUMAN_SHOT_GAP.
	local crest = w.ctx.arena.spawns[PAD.crest]
	w.pos["player:1"] = V3.new(crest.X, st.spawnGround[PAD.crest] + RIDE, crest.Z)
	eq(Water.targetable(w.ctx, st, blaze, player), true, "on the beach he can be locked")
	Water.locked(w.ctx, st, blaze, player)
	eq(Water.targetable(w.ctx, st, blaze, player), false, "not again right away")
	eq(Water.targetable(w.ctx, st, ace, player), true, "the cooldown is per bot")
	runTo(w, st, 1 + WaterRules.HUMAN_SHOT_GAP + 0.1)
	eq(Water.targetable(w.ctx, st, blaze, player), true, "after HUMAN_SHOT_GAP")
end)

test("LIVE arena (owner 2026-10-21): eight cars on eight sand pads, the whole cove, no pod lost to the tide or on the ship", function()
	local w = newBattle(true)
	local st = Water.start(w.ctx)
	eq(#w.ctx.entrants, BattleRules.FIELD, "a race field of eight")
	check(findLog("survival start entrants=8 lives=3"), "Survival seated all eight")
	eq(#w.ctx.arena.spawns, BattleRules.FIELD, "a pad per seat")
	eq(w.ctx.arena.radius, 250, "the whole drivable cove")
	for i = 1, #w.ctx.arena.spawns do
		check(not st.deckPads[i], "pad " .. i .. " is on the sand, not the galleon")
		check(WaterRules.isDry(st.spawnGround[i], 24.5, 2.2, WaterRules.SAFE_MARGIN), "pad " .. i .. " stays dry at the last step")
	end
	local line = findLog("water start ") :: string
	local shares = {}
	for pct in string.gmatch(string.match(line, "dry=([%d%%/]+)") or "", "(%d+)%%") do
		table.insert(shares, tonumber(pct))
	end
	eq(#shares, 4, "a dry share per level")
	check(shares[1] >= 75 and shares[4] >= 40, "the cove stays a battle ground at high tide: " .. line)
	local pods = w.ctx.pods()
	check(#pods >= 12, "a dozen pods or more for eight cars")
	for _, pod in pods do
		check(not WaterRules.onDeck(st.course, pod.pos, st.podGround[pod.name]), pod.name .. " is on the sand")
	end
	runTo(w, st, 150)
	for _, pod in pods do
		check(not st.sunk[pod.name], pod.name .. " is on sand the tide never takes")
	end
end)

------------------------------------------------------------------------------------------------------------------------
-- Run
------------------------------------------------------------------------------------------------------------------------

local passed, failed = 0, 0
for _, t in tests do
	local ok, err = pcall(t.fn)
	if ok then
		passed += 1
		print("  PASS " .. t.name)
	else
		failed += 1
		print("  FAIL " .. t.name .. "\n       " .. tostring(err))
		if process.env.SKYRALLY_TEST_VERBOSE == "1" then
			for _, line in logs do
				print("    | " .. line)
			end
		end
	end
end
print(string.format("water_flow_spec: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
