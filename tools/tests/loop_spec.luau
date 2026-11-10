--!strict
-- Lune spec for the race loop wiring (TEST_LIST_LAUNCH L07, L18, L20-L23 groundwork):
--   1. item pickup -> use -> world effect through the REAL ItemService + kit/ItemEffects, with a stubbed world/context
--      (straight test course, scripted racer positions): missile hit, shield block, homing lock on the racer ahead,
--      ten-shot volley without stun-lock, boost/shield/magnet routing to players and to bots (setBotHitHandler,
--      setBotEffectHandler), trap arming and hit, module-level ItemService.pickup with the pod-taken handler, reset.
--   2. finish awards through the REAL RaceManager (awardFinish and completePlayerLap) against a REAL SaveService over a
--      memory store: rank 1 only, idempotent repeats (double finish, retry after a win), best time only improves,
--      nothing for abandoned or non-standard races, simulated finishes award only in Studio.
-- Run: tools/tests/run_lune_tests.sh tools/tests/loop_spec.luau   (standalone: plain `lune run` also works)
-- Modules load from source with Roblox-style stubs; FlightServer, AIRacers, SplineUtils, TrackRegistry and PlaneConfig
-- are fakes so this spec does not move when the AIRacers/vehicle lanes change those files.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any

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
local function countLogs(needle: string): number
	local n = 0
	for _, line in logs do
		if string.find(line, needle, 1, true) then
			n += 1
		end
	end
	return n
end
local function capture(...: any)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(logs, table.concat(parts, " "))
end

------------------------------------------------------------------------------------------------------------------------
-- Roblox-style stubs and a source loader
------------------------------------------------------------------------------------------------------------------------

local function signal(): any
	local s = { handlers = {} }
	function s.Connect(self: any, fn: any)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	return s
end

local function holder(base: any): any
	base.attrs = base.attrs or {}
	function base.SetAttribute(self: any, k: string, v: any)
		self.attrs[k] = v
	end
	function base.GetAttribute(self: any, k: string): any
		return self.attrs[k]
	end
	function base.GetAttributeChangedSignal(_self: any, _k: string): any
		return signal()
	end
	return base
end

local playersById: { [number]: any } = {}
local PlayersStub = holder({ PlayerAdded = signal(), PlayerRemoving = signal() })
function PlayersStub.GetPlayers(_self: any): { any }
	local out = {}
	for _, p in playersById do
		table.insert(out, p)
	end
	return out
end
function PlayersStub.GetPlayerByUserId(_self: any, id: number): any
	return playersById[id]
end

local studio = { value = true }
local RunServiceStub = { Heartbeat = signal() }
function RunServiceStub.IsStudio(_self: any): boolean
	return studio.value
end
function RunServiceStub.IsServer(_self: any): boolean
	return true
end

local guids = 0
local services: { [string]: any } = {
	Players = PlayersStub,
	RunService = RunServiceStub,
	DataStoreService = {
		GetDataStore = function()
			error("no DataStore under Lune")
		end,
		GetRequestBudgetForRequestType = function()
			return 100
		end,
	},
	HttpService = {
		GenerateGUID = function(): string
			guids += 1
			return "guid-" .. guids
		end,
	},
}
local workspaceStub = holder({ Name = "Workspace" })
function workspaceStub.FindFirstChild(_self: any, _n: string): any
	return nil
end

-- task stub: delays are recorded, not run, so a spec can fire a pod's respawn on purpose (RaceManager.startPodCooldown).
local delayed: { { seconds: number, fn: () -> () } } = {}
local taskStub = {
	delay = function(seconds: number, fn: () -> ())
		table.insert(delayed, { seconds = seconds, fn = fn })
	end,
	spawn = function(fn: (...any) -> (), ...: any)
		fn(...)
	end,
	defer = function(fn: (...any) -> (), ...: any)
		fn(...)
	end,
	wait = function(): number
		return 0
	end,
}

-- Module references are { __ref = "<dir>/<Name>" }; require() resolves them to a fake or loads the real source.
local fakes: { [string]: any } = {}
local cache: { [string]: any } = {}
local load: (string) -> any

local function folder(prefix: string, extra: { [string]: any }?): any
	local f: any = {}
	for k, v in pairs(extra or {}) do
		f[k] = v
	end
	f.WaitForChild = function(_self: any, name: string): any
		return f[name]
	end
	f.FindFirstChild = f.WaitForChild
	return setmetatable(f, {
		__index = function(_, k: string): any
			return { __ref = prefix .. k }
		end,
	})
end
local sharedFolder = folder("shared/")
local kitFolder = folder("server/kit/")
local serverFolder = folder("server/", { kit = kitFolder })
kitFolder.Parent = serverFolder
local ReplicatedStub = {
	WaitForChild = function(_self: any, name: string): any
		assert(name == "Shared", "ReplicatedStorage:WaitForChild(" .. name .. ")")
		return sharedFolder
	end,
}
ReplicatedStub.FindFirstChild = ReplicatedStub.WaitForChild
services.ReplicatedStorage = ReplicatedStub

local gameStub = {
	JobId = "",
	PlaceId = 0,
	PlaceVersion = 0,
	GetService = function(_self: any, name: string): any
		return services[name] or error("no stub service " .. name)
	end,
	BindToClose = function() end,
}

local function stubRequire(target: any): any
	local ref = type(target) == "table" and target.__ref
	assert(type(ref) == "string", "require of an unknown target")
	if fakes[ref] ~= nil then
		return fakes[ref]
	end
	return load("src/" .. ref .. ".luau")
end

load = function(rel: string): any
	if cache[rel] ~= nil then
		return cache[rel]
	end
	local dir = string.match(rel, "^src/(.*)/[^/]+$") or ""
	local parent = if dir == "server/kit" then kitFolder elseif dir == "server" then serverFolder else sharedFolder
	local env = {
		game = gameStub,
		workspace = workspaceStub,
		script = { Parent = parent, Name = string.match(rel, "([^/]+)%.luau$") },
		require = stubRequire,
		task = taskStub,
		Vector3 = V3,
		CFrame = CF,
		Color3 = C3,
		Enum = setmetatable({}, {
			__index = function(_, a: string)
				return setmetatable({}, {
					__index = function(_, b: string)
						return a .. "." .. b
					end,
				})
			end,
		}),
		print = capture,
		warn = capture,
	}
	local chunk = luau.load(fs.readFile(root .. "/" .. rel), { debugName = rel, environment = env })
	local result = chunk()
	cache[rel] = result
	return result
end

-- Fakes for the modules owned by other lanes (only what RaceManager touches at load and in the tested paths).
local FakeFlightServer: any = { records = {} }
function FakeFlightServer.getStartCFrame(_slot: number): any
	return CF.new(0, 100, 0)
end
function FakeFlightServer.spawnOrResetPlane(player: any, _slot: number): any
	local rec = {
		player = player,
		plane = { Name = "Plane_" .. player.Name },
		hull = { Parent = true, Position = V3.new(0, 100, 0) },
		lap = 1,
		station = 0,
		finished = false,
		finishTime = 0,
		finishRank = 0,
		orbs = 0,
		passedCheckpoints = {},
		lastCheckpointIdx = 1,
		lastCheckpointCF = CF.new(),
		speed = 110,
	}
	FakeFlightServer.records[player] = rec
	return rec
end
-- Flight-path guide hooks (FLIGHT_GUIDE.md 4.6): the off-course clock and best progress, specced in flight_guide_spec.
function FakeFlightServer.stepGuide(_rec: any, _st: number, _point: any, _dt: number) end
function FakeFlightServer.guideNewLap(_rec: any) end
fakes["server/FlightServer"] = FakeFlightServer
fakes["server/AIRacers"] = {
	bots = {},
	resetBots = function() end,
	spawnBots = function() end,
	step = function() end,
	botsNeeded = function(): number
		return 0
	end,
}
fakes["shared/PlaneConfig"] = { TOTAL_LAPS = 3, BASE_SPEED = 110, BOOST_SPEED = 165, OVERCHARGE_SPEED = 210, CHECKPOINT_GATE_FRACTION = 0.55, AI_FIELD_SIZE = 8 }
fakes["shared/SplineUtils"] = {
	loadWaypoints = function(): ({ any }, number)
		return {}, 1000
	end,
	sampleAtStation = function(st: number): (any, any, number)
		return V3.new(0, 100, -st), V3.new(0, 0, -1), 0
	end,
	projectPosition = function(): (number, any, any, number)
		return 0, V3.new(0, 100, 0), V3.new(0, 0, -1), 0
	end,
}
fakes["shared/TrackRegistry"] = {
	getActiveId = function(): string
		return "DINO-4"
	end,
	getBoostsFolder = function(): any
		return nil
	end,
	getCheckpointsFolder = function(): any
		return nil
	end,
	getLandmarks = function(): any
		return nil
	end,
	finish = function(): any
		return nil
	end,
}

local ItemRules = load("src/shared/ItemRules.luau")
local Progression = load("src/shared/Progression.luau")
local ItemService = load("src/server/ItemService.luau")
local ItemEffects = load("src/server/kit/ItemEffects.luau")
local SaveService = load("src/server/SaveService.luau")
local RaceManager = load("src/server/RaceManager.luau")

------------------------------------------------------------------------------------------------------------------------
-- Item world: a straight course along -Z at y=100; racers fly 12 above it
------------------------------------------------------------------------------------------------------------------------

local P1 = ItemService.playerRacerId(101)
local P2 = ItemService.playerRacerId(202)
local B1 = ItemService.botRacerId(1)

type Racer = { id: string, station: number, lat: number, vert: number, speed: number, finished: boolean, isPlayer: boolean, botId: number? }

local function newWorld(clockStart: number?): any
	local w: any = {
		t = clockStart or 100,
		racers = {} :: { [string]: Racer },
		order = {} :: { string },
		sent = {},
		fx = {},
		used = {},
		visuals = 0,
		live = 0,
		published = {},
		pods = {},
		podsTaken = {},
	}
	local function posOf(r: Racer): any
		return V3.new(r.lat, 100 + r.vert, -r.station)
	end
	function w.add(id: string, station: number, lat: number, speed: number, botId: number?)
		w.racers[id] = { id = id, station = station, lat = lat, vert = 12, speed = speed, finished = false, isPlayer = botId == nil, botId = botId }
	end
	function w.sortOrder()
		local ids = {}
		for id in w.racers do
			table.insert(ids, id)
		end
		table.sort(ids, function(a: string, b: string): boolean
			return w.racers[a].station > w.racers[b].station
		end)
		w.order = ids
	end
	w.world = {
		now = function(): number
			return w.t
		end,
		racerPosition = function(id: string): any
			local r = w.racers[id]
			return if r then posOf(r) else nil
		end,
		findPod = function(name: string): any
			return w.pods[name]
		end,
		publish = function(id: string, state: any)
			table.insert(w.published, { id = id, label = ItemRules.label(state) })
		end,
		log = capture,
		canAct = function(id: string): (boolean, string?)
			local r = w.racers[id]
			if not r then
				return false, "no_record"
			end
			return not r.finished, "finished"
		end,
	}
	w.ctx = {
		now = function(): number
			return w.t
		end,
		order = function(): { string }
			return w.order
		end,
		racer = function(id: string): any
			local r = w.racers[id]
			if not r then
				return nil
			end
			return {
				pos = posOf(r),
				forward = V3.new(0, 0, -1),
				station = r.station,
				progress = r.station,
				active = not r.finished,
				isPlayer = r.isPlayer,
				botId = r.botId,
				plane = { Name = "Plane_" .. id },
			}
		end,
		course = function(st: number): (any, any)
			return V3.new(0, 100, -st), V3.new(0, 0, -1)
		end,
		isShielded = function(id: string): boolean
			return w.service.isShielded(id)
		end,
		sendPlayer = function(id: string, kind: string, payload: any)
			table.insert(w.sent, { id = id, kind = kind, payload = payload })
		end,
		broadcast = function(fx: string, payload: any)
			table.insert(w.fx, { fx = fx, payload = payload })
		end,
		notifyUsed = function(id: string, payload: any)
			table.insert(w.used, { id = id, payload = payload })
		end,
		applyToBot = function(botId: number, effect: any)
			ItemService.applyToBot(botId, effect) -- the real routing, so setBotHitHandler/EffectHandler are exercised
		end,
		spawnVisual = function(_kind: string, _cf: any, _info: any): any
			w.visuals += 1
			w.live += 1
			return { alive = true }
		end,
		moveVisual = function(_v: any, _cf: any) end,
		destroyVisual = function(v: any)
			if v.alive then
				v.alive = false
				w.live -= 1
			end
		end,
		log = capture,
	}
	w.effects = ItemEffects.new(w.ctx)
	w.service = ItemService.new(w.world, w.effects.hooks)
	function w.run(seconds: number, dt: number?)
		local step = dt or 1 / 30
		local n = math.floor(seconds / step + 0.5)
		for _ = 1, n do
			w.t += step
			for _, r in w.racers do
				if not r.finished then
					r.station += r.speed * step
				end
			end
			w.sortOrder()
			w.effects.step(step)
		end
	end
	-- Puts a pod of podType right at the racer and picks it up (the service checks distance and the pod ledger).
	function w.give(id: string, podType: string, times: number?)
		for i = 1, times or 1 do
			local name = string.format("Pod_%s_%d_%d", podType, math.floor(w.t * 1000), i)
			w.pods[name] = { position = w.world.racerPosition(id), podType = podType, respawnSeconds = 4 }
			-- The magnet is retired by config (ItemRules.MAGNET_ENABLED); its kept code path is still exercised here.
			local was = ItemRules.MAGNET_ENABLED
			if podType == "Rainbow" then
				ItemRules.MAGNET_ENABLED = true
			end
			local ok, outcome = w.service.requestPickup(id, name)
			ItemRules.MAGNET_ENABLED = was
			assert(ok, "pickup failed: " .. tostring(outcome))
		end
	end
	function w.sentTo(id: string, kind: string): { any }
		local out = {}
		for _, s in w.sent do
			if s.id == id and s.kind == kind then
				table.insert(out, s)
			end
		end
		return out
	end
	function w.fxCount(name: string): number
		local n = 0
		for _, f in w.fx do
			if f.fx == name then
				n += 1
			end
		end
		return n
	end
	return w
end

local function resetBotHandlers()
	ItemService.setBotHitHandler(nil)
	ItemService.setBotEffectHandler(nil)
	ItemService.setBotFallback(nil)
	ItemService.setPodTakenHandler(nil)
end

------------------------------------------------------------------------------------------------------------------------
-- 1. Items
------------------------------------------------------------------------------------------------------------------------

test("items: pure helpers (racer ahead, course lane round trip, segment distance, corridor clamp)", function()
	local order = { "bot:1", "player:101", "player:202" }
	eq(ItemEffects.targetAhead(order, "player:202"), "player:101", "racer directly ahead")
	eq(ItemEffects.targetAhead(order, "bot:1"), nil, "leader has nobody ahead")
	eq(ItemEffects.targetAhead(order, "ghost"), nil, "unknown racer")
	eq(ItemEffects.targetAhead(order, "player:202", function(id: string): boolean
		return id ~= "player:101"
	end), "bot:1", "inactive racer ahead is skipped")
	local cpos, tan = V3.new(10, 50, -200), V3.new(0, 0, -1)
	local p = ItemEffects.coursePoint(cpos, tan, 7, 12)
	local lat, vert = ItemEffects.courseOffset(p, cpos, tan)
	check(math.abs(lat - 7) < 1e-4 and math.abs(vert - 12) < 1e-4, "lane round trip")
	eq(ItemEffects.segmentDistance(V3.new(0, 0, 0), V3.new(0, 0, -10), V3.new(3, 0, -5)), 3, "segment distance")
	local cl, cv = ItemEffects.clampCorridor(99, -5)
	eq(cl, ItemRules.TUNING.corridorHalfWidth, "lateral clamp")
	eq(cv, ItemRules.TUNING.corridorFloor, "vertical clamp")
end)

test("items: red pickup -> use -> missile flies the course and hits the bot ahead (bot hit handler)", function()
	resetBotHandlers()
	local hits = {}
	ItemService.setBotHitHandler(function(botId: number, stun: number, source: string)
		table.insert(hits, { botId = botId, stun = stun, source = source })
	end)
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(B1, 300, 0, 120, 1)
	w.sortOrder()
	w.give(P1, "Red")
	eq(ItemRules.label(w.service.getState(P1)), "red:1", "held red:1")
	w.t += 1
	local ok, why = w.service.handleRemote(P1, "Use")
	check(ok and why == "used", "remote Use accepted")
	eq(#w.used, 1, "shooter told it fired (HUD)")
	eq(w.used[1].payload.color, "red", "ItemUsed colour")
	local m = w.effects.counts()
	eq(m, 1, "one missile in flight")
	w.run(3)
	eq(#hits, 1, "bot hit exactly once")
	eq(hits[1].botId, 1, "bot id")
	eq(hits[1].source, "missile", "hit source")
	eq(hits[1].stun, ItemRules.PARAMS.missile[1].stunSeconds, "stun seconds from ItemRules")
	eq(w.fxCount("explode"), 1, "explosion broadcast")
	eq(select(1, w.effects.counts()), 0, "missile consumed by the hit")
	eq(w.live, 0, "every visual destroyed")
	check(countLogs("[SkyRally][ITEM] hit racer=bot:1 by=player:101 source=missile") >= 1, "hit logged")
end)

test("items: a missile never hits its shooter and fizzles at end of life when nobody is in its path", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.sortOrder()
	w.give(P1, "Red")
	w.t += 1
	w.service.requestUse(P1)
	w.run(4)
	eq(#w.sentTo(P1, "hit"), 0, "shooter never hit")
	eq(w.fxCount("fizzle"), 1, "expired missile fizzles")
	eq(w.live, 0, "visual cleaned up")
end)

test("items: yellow shield blocks a missile (no stun), and expires", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(P2, 300, 0, 100)
	w.sortOrder()
	w.give(P2, "Yellow")
	w.t += 1
	w.service.requestUse(P2)
	eq(#w.sentTo(P2, "shield"), 1, "shield effect to the user")
	eq(w.fxCount("shield"), 1, "bubble broadcast to everyone")
	check(w.service.isShielded(P2), "shielded")
	w.give(P1, "Red")
	w.t += 0.5
	w.service.requestUse(P1)
	w.run(2)
	eq(#w.sentTo(P2, "hit"), 0, "shielded racer not stunned")
	eq(w.fxCount("blocked"), 1, "block shown")
	check(countLogs("result=blocked") >= 1, "block logged")
	w.run(ItemRules.PARAMS.shield[1].seconds)
	check(not w.service.isShielded(P2), "shield expired")
end)

test("items: level-two homing missile locks the racer directly ahead and crosses lanes to hit it", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, -20, 110)
	w.add(P2, 260, 22, 115) -- directly ahead, opposite side of the corridor
	w.add(B1, 600, 0, 125, 1) -- further ahead: must not be the target
	w.sortOrder()
	w.give(P1, "Red", 2)
	eq(ItemRules.label(w.service.getState(P1)), "red:2", "upgraded to homing")
	w.t += 1
	w.service.requestUse(P1)
	check(countLogs("fx missile racer=player:101 level=2 count=1 target=player:202") == 1, "locked on the racer ahead")
	w.run(3)
	local hits = w.sentTo(P2, "hit")
	eq(#hits, 1, "homing missile hit the target")
	eq(hits[1].payload.source, "missile", "player hit payload source")
end)

test("items: level-three volley fires ten shots, stuns the racer ahead once (no stun-lock)", function()
	resetBotHandlers()
	local hits = 0
	ItemService.setBotHitHandler(function()
		hits += 1
	end)
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(B1, 260, 0, 115, 1)
	w.sortOrder()
	w.give(P1, "Red", 3)
	w.t += 1
	w.service.requestUse(P1)
	local m, _, pending = w.effects.counts()
	eq(m, 1, "first shot leaves on the press")
	eq(pending, 9, "nine queued in the burst")
	w.run(5) -- last shot leaves 1.35 s after the first and lives 3 s
	eq(w.visuals, 10, "ten missiles launched")
	eq(hits, 1, "one stun from the volley while the target is immune")
	eq(w.live, 0, "all visuals cleaned up")
end)

test("items: blue boost goes to the player's client; bots get boost and magnet through the effect handler", function()
	resetBotHandlers()
	local botEffects = {}
	ItemService.setBotEffectHandler(function(botId: number, effect: any)
		table.insert(botEffects, { botId = botId, kind = effect.kind, seconds = effect.seconds, target = effect.targetRacerId })
	end)
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(B1, 50, 0, 120, 1)
	w.add(P2, 200, 0, 110)
	w.sortOrder()
	w.give(P1, "Blue", 3)
	w.t += 1
	w.service.requestUse(P1)
	local boosts = w.sentTo(P1, "boost")
	eq(#boosts, 1, "boost sent to the user's client")
	eq(boosts[1].payload.speed, ItemRules.PARAMS.boost[3].speed, "level-three boost speed")
	eq(boosts[1].payload.seconds, ItemRules.PARAMS.boost[3].seconds, "level-three boost seconds")
	w.give(B1, "Blue")
	w.t += 1
	w.service.requestUse(B1)
	w.give(B1, "Rainbow")
	w.t += 1
	w.service.requestUse(B1)
	eq(#botEffects, 2, "bot got two effects")
	eq(botEffects[1].kind, "boost", "bot boost")
	eq(botEffects[2].kind, "magnet", "bot magnet")
	eq(botEffects[2].target, P1, "bot magnet pulls toward the racer directly ahead")
end)

test("items: magnet v2 locks the closest racer in range (a near-tie goes ahead); nobody in range fizzles", function()
	resetBotHandlers()
	local w = newWorld()
	local P3 = ItemService.playerRacerId(303)
	w.add(P1, 100, 0, 0)
	w.add(P2, 180, 0, 0) -- 80 ahead
	w.add(P3, 60, 0, 0) -- 40 behind: closer by more than the tie
	w.sortOrder()
	w.give(P1, "Rainbow")
	w.t += 1
	w.service.requestUse(P1)
	local mags = w.sentTo(P1, "magnet")
	eq(#mags, 1, "magnet to the user's client")
	eq(mags[1].payload.target.Name, "Plane_" .. P3, "closest overall, even behind")
	eq(mags[1].payload.pull, ItemRules.PARAMS.magnet[1].pull, "pull from ItemRules")
	eq(mags[1].payload.range, ItemRules.PARAMS.magnet[1].range, "range from ItemRules")
	eq(w.fxCount("magnet"), 1, "beam broadcast")
	-- Near-tie: 25 ahead against 8 behind goes forward.
	w.racers[P2].station, w.racers[P3].station = 125, 92
	w.give(P1, "Rainbow")
	w.t += 1
	w.service.requestUse(P1)
	mags = w.sentTo(P1, "magnet")
	eq(mags[2].payload.target.Name, "Plane_" .. P2, "near-tie prefers the racer ahead")
	-- Leader with the pack 160 back at level 1 (range 140 + slack 12): fizzle and say so.
	w.racers[P2].station, w.racers[P3].station = 250, 20
	w.racers[P1].station = 90
	w.give(P2, "Rainbow")
	w.t += 1
	w.service.requestUse(P2)
	eq(#w.sentTo(P2, "magnet"), 0, "nobody within range: no lock")
	eq(w.fxCount("fizzle"), 1, "out-of-range magnet fires a pulse burst")
	eq(ItemRules.label(w.service.getState(P2)), "none", "the press spends the magnet")
	w.run(ItemRules.TUNING.magnetPulseSeconds + 0.3)
	eq(#w.sentTo(P2, "magnet"), 0, "an empty pulse never locks")
	eq(#w.sentTo(P2, "magnetMiss"), 1, "the holder hears it ended")
	-- Same gap at level 2 (range 210): locks, behind the leader.
	w.give(P2, "Rainbow", 2)
	w.t += 1
	w.service.requestUse(P2)
	local l2 = w.sentTo(P2, "magnet")
	eq(#l2, 1, "level-2 reach locks 160 studs back")
	eq(l2[1].payload.target.Name, "Plane_" .. P1, "the leader is pulled to the closest racer")
	eq(l2[1].payload.seconds, ItemRules.PARAMS.magnet[2].seconds, "level-2 seconds")
end)

test("items: magnet pulse with nobody in range locks a racer who comes into range, else ends", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 0)
	w.add(P2, 400, 0, 0) -- far ahead
	w.sortOrder()
	w.give(P1, "Rainbow")
	w.t += 1
	w.service.requestUse(P1)
	eq(#w.sentTo(P1, "magnet"), 0, "no lock on the press")
	eq(ItemRules.label(w.service.getState(P1)), "none", "magnet spent on the press")
	w.run(0.3)
	w.racers[P2].station = 180 -- enters range inside the pulse
	w.run(0.2)
	local mags = w.sentTo(P1, "magnet")
	eq(#mags, 1, "locks the racer who came into range")
	eq(mags[1].payload.target.Name, "Plane_" .. P2, "the new racer is the target")
	w.run(ItemRules.TUNING.magnetPulseSeconds + 0.3)
	eq(#w.sentTo(P1, "magnetMiss"), 0, "a pulse that locked does not end as a miss")
	eq(w.fxCount("magnet"), 1, "one beam")
end)

test("items: magnet v2 contact pops for everyone with no stun; a bot's pull ends there; a bot never pulls backward", function()
	resetBotHandlers()
	local botEffects = {}
	ItemService.setBotEffectHandler(function(botId: number, effect: any)
		table.insert(botEffects, { botId = botId, kind = effect.kind })
	end)
	local w = newWorld()
	w.add(P1, 100, 0, 0)
	w.add(P2, 160, 0, 0)
	w.sortOrder()
	w.give(P1, "Rainbow")
	w.t += 1
	w.service.requestUse(P1)
	eq(#w.sentTo(P1, "magnet"), 1, "locked")
	w.run(0.2)
	eq(w.fxCount("magnetArrive"), 0, "no pop while apart")
	w.racers[P1].station = 160 - ItemRules.TUNING.magnetArrive + 2
	w.run(0.1)
	eq(w.fxCount("magnetArrive"), 1, "contact pops once")
	w.run(0.5)
	eq(w.fxCount("magnetArrive"), 1, "and only once")
	eq(#w.sentTo(P2, "hit"), 0, "the target is never stunned")
	-- Bot: ahead target in range, then contact ends its pull.
	w.add(B1, 120, 0, 0, 1)
	w.racers[P1].station, w.racers[P2].station = 0, 170
	w.sortOrder()
	w.give(B1, "Rainbow")
	w.t += 1
	w.service.requestUse(B1)
	eq(botEffects[#botEffects].kind, "magnet", "bot pull applied")
	w.racers[B1].station = 165
	w.run(0.1)
	eq(botEffects[#botEffects].kind, "magnetEnd", "contact ends the bot's pull")
	-- Bot whose closest racer is behind it: a bot's pull is added speed, so it fizzles instead.
	local before = #botEffects
	w.racers[B1].station, w.racers[P1].station, w.racers[P2].station = 300, 280, 400
	w.give(B1, "Rainbow")
	w.t += 1
	w.service.requestUse(B1)
	eq(#botEffects, before, "no pull toward a racer behind the bot")
end)

test("items: green trap drops behind, arms, and spins out the next racer through it", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 300, 0, 0) -- holds position while dropping
	w.add(P2, 230, 0, 0)
	w.sortOrder()
	w.give(P1, "Green")
	w.t += 1
	w.service.requestUse(P1)
	local _, traps = w.effects.counts()
	eq(traps, 1, "one trap placed")
	-- Put P2 inside the trap before it arms: nothing happens.
	w.racers[P2].station = 300 - ItemRules.TUNING.trapDropBehind
	w.run(ItemRules.TUNING.trapArmSeconds * 0.5)
	eq(#w.sentTo(P2, "hit"), 0, "unarmed trap is harmless")
	w.run(ItemRules.TUNING.trapArmSeconds)
	local hits = w.sentTo(P2, "hit")
	eq(#hits, 1, "armed trap hits")
	eq(hits[1].payload.source, "trap", "trap source")
	eq(hits[1].payload.seconds, ItemRules.PARAMS.trap[1].stunSeconds, "trap stun from ItemRules")
	eq(#w.sentTo(P1, "hit"), 0, "dropper unharmed")
	eq(select(2, w.effects.counts()), 0, "trap consumed")
end)

test("items: finished racers are never targeted or hit", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(P2, 200, 0, 0)
	w.sortOrder()
	w.racers[P2].finished = true
	w.give(P1, "Red", 2)
	w.t += 1
	w.service.requestUse(P1)
	check(countLogs("count=1 target=none") >= 1, "no target when the only racer ahead finished")
	w.run(3)
	eq(#w.sentTo(P2, "hit"), 0, "finished racer untouched")
end)

test("items: module API pickup/use with the pod-taken handler; bot fallback when AIRacers registered nothing", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.add(B1, 300, 0, 120, 1)
	w.sortOrder()
	local taken = {}
	ItemService.setPodTakenHandler(function(podName: string, racerId: string)
		table.insert(taken, podName .. "@" .. racerId)
	end)
	local fallback = {}
	ItemService.setBotFallback(function(botId: number, effect: any)
		table.insert(fallback, effect.kind .. ":" .. botId)
	end)
	local okBefore, whyBefore = ItemService.pickup(P1, "X")
	check(not okBefore and whyBefore == "not_started", "module API before start")
	ItemService.active = w.service
	w.pods.PodA = { position = w.world.racerPosition(P1), podType = "Red", respawnSeconds = 4 }
	local ok, outcome = ItemService.pickup(P1, "PodA")
	check(ok and outcome == "new", "module pickup grants")
	eq(taken[1], "PodA@" .. P1, "pod-taken handler told which pod to hide")
	local again = ItemService.pickup(P1, "PodA")
	check(not again, "pod on cooldown")
	eq(#taken, 1, "no hide for a refused pickup")
	w.t += 1
	check((ItemService.use(P1)), "module use fires")
	w.run(3)
	eq(fallback[1], "hit:1", "bot hit reached the fallback")
	ItemService.reset()
	eq(ItemRules.label(ItemService.getState(P1)), "none", "module reset clears items")
	ItemService.active = nil
	resetBotHandlers()
end)

test("items: race reset clears projectiles, traps, queued shots and held items", function()
	resetBotHandlers()
	local w = newWorld()
	w.add(P1, 100, 0, 110)
	w.sortOrder()
	w.give(P1, "Red", 3)
	w.t += 1
	w.service.requestUse(P1)
	w.give(P1, "Green")
	w.t += 1
	w.service.requestUse(P1)
	w.give(P1, "Blue")
	w.service.resetAll()
	w.effects.clear()
	local m, t, pending = w.effects.counts()
	eq(m + t + pending, 0, "nothing left in flight")
	eq(w.live, 0, "every visual destroyed")
	eq(ItemRules.label(w.service.getState(P1)), "none", "held item cleared")
end)

test("items: missile hits do not depend on the server frame rate (10, 30, 240 Hz; unguided and homing)", function()
	for _, hz in { 10, 30, 240 } do
		resetBotHandlers()
		local hits = 0
		ItemService.setBotHitHandler(function()
			hits += 1
		end)
		local w = newWorld()
		w.add(P1, 100, 0, 110)
		w.add(B1, 300, 0, 120, 1)
		w.sortOrder()
		w.give(P1, "Red")
		w.t += 1
		w.service.requestUse(P1)
		w.run(3, 1 / hz)
		eq(hits, 1, string.format("unguided shot hits the bot ahead once at %d Hz", hz))

		local w2 = newWorld()
		w2.add(P1, 100, -20, 110)
		w2.add(P2, 260, 22, 115)
		w2.sortOrder()
		w2.give(P1, "Red", 2)
		w2.t += 1
		w2.service.requestUse(P1)
		w2.run(3, 1 / hz)
		eq(#w2.sentTo(P2, "hit"), 1, string.format("homing shot crosses lanes and hits once at %d Hz", hz))
	end
end)

test("items: a trap catches a racer that steps over it on a slow server frame, but not across a teleport", function()
	resetBotHandlers()
	-- Dropper hovers at station 314, so the trap sits at station 300 on the centre line. The victim flies 9 studs off
	-- centre (inside the 11-stud radius) at 210 studs/s; at 10 Hz its samples land at 290 and 311, both outside the
	-- sphere, so only a swept test sees the pass.
	local w = newWorld()
	w.add(P1, 314, 0, 0)
	w.add(P2, 122, 9, 210)
	w.sortOrder()
	w.give(P1, "Green")
	w.t += 1
	w.service.requestUse(P1)
	w.run(1.5, 0.1)
	local hits = w.sentTo(P2, "hit")
	eq(#hits, 1, "swept test catches the 21-stud step through the trap")
	eq(hits[1].payload.source, "trap", "trap source")

	local w2 = newWorld()
	w2.add(P1, 314, 0, 0)
	w2.add(P2, 200, 0, 0)
	w2.sortOrder()
	w2.give(P1, "Green")
	w2.t += 1
	w2.service.requestUse(P1)
	w2.run(1, 0.1) -- armed, and P2's position recorded every step
	w2.racers[P2].station = 400 -- respawn/reset teleport straight through the trap's position
	w2.run(0.1, 0.1)
	eq(#w2.sentTo(P2, "hit"), 0, "a teleport line is not a flown path")
	eq(select(2, w2.effects.counts()), 1, "trap still armed")
end)

------------------------------------------------------------------------------------------------------------------------
-- 2. Finish awards
------------------------------------------------------------------------------------------------------------------------

local nextUser = 900
local function newPlayer(): any
	nextUser += 1
	local p = holder({ UserId = nextUser, Name = "Racer" .. nextUser, Parent = PlayersStub })
	playersById[nextUser] = p
	return p
end

-- Real SaveService over a memory store; spawn runs inline and writes have no cooldown, so nothing yields.
local function newSave(): any
	local clock = 1000
	return SaveService.new({
		store = SaveService.newMemoryStore(),
		sessionId = "spec",
		newToken = function(): string
			guids += 1
			return "tok-" .. guids
		end,
		now = function(): number
			return clock
		end,
		clock = function(): number
			return clock
		end,
		sleep = function(s: number)
			clock += s
		end,
		spawn = function(fn: () -> ())
			fn()
		end,
		log = capture,
		random = function(): number
			return 0.5
		end,
		config = { writeCooldown = 0 },
	})
end

-- Counts every award call, so "nothing awarded" is a fact, not an absence of log lines.
local function counting(svc: any): any
	local c = { calls = 0 }
	function c.award(player: any, kind: any, id: string, source: string, value: number?): (string, { string })
		c.calls += 1
		return svc.award(player, kind, id, source, value)
	end
	return c
end

local function finish(player: any, rank: number, time: number, mode: string?, extra: { [string]: any }?): any
	local info: any = { trackId = "DINO-4", mode = mode or "race", rank = rank, time = time, finished = true }
	for k, v in pairs(extra or {}) do
		info[k] = v
	end
	return RaceManager.awardFinish(player, info)
end

test("awards: rank 1 in a standard race awards race:DINO-4; rank 2 awards no token", function()
	local svc = newSave()
	RaceManager.saver = svc
	local p = newPlayer()
	svc.load(p)
	local lose = finish(p, 2, 150.2)
	eq(lose.tokenResult, "skip", "rank 2 gets no token")
	eq(lose.token, Progression.raceTokenId("DINO-4"), "token id still reported")
	eq(lose.bestTimeResult, "awarded", "first finish sets the best time")
	eq(lose.bestTimeMs, 150200, "best time in ms")
	eq(p:GetAttribute("SkyTokens"), 0, "no token after a loss")
	local win = finish(p, 1, 148.5)
	eq(win.tokenResult, "awarded", "win awards the token")
	eq(win.bestTimeResult, "awarded", "faster time improves the best")
	eq(win.tokens, 1, "HUD count after the win")
	eq(p:GetAttribute("SkyTokens"), 1, "SkyTokens replicated")
	check(svc.get(p).tokens["race:DINO-4"] == true, "profile holds the token")
	check(countLogs("[SkyRally][AWARD] user=" .. p.UserId .. " player=" .. p.Name .. " kind=token id=race:DINO-4 track=DINO-4 mode=race rank=1 result=awarded") == 1, "award log line")
	check(#win.unlocked > 0, "the first token reports what it opened (SNOW portal)")
	RaceManager.saver = nil
end)

test("awards: double finish and retry after a win are no-ops; best time only improves", function()
	local svc = newSave()
	RaceManager.saver = svc
	local p = newPlayer()
	svc.load(p)
	eq(finish(p, 1, 140).tokenResult, "awarded", "first win")
	local again = finish(p, 1, 140)
	eq(again.tokenResult, "noop", "same finish again is a no-op")
	eq(again.bestTimeResult, "noop", "same time is not a new best")
	local slower = finish(p, 1, 160)
	eq(slower.tokenResult, "noop", "retry win is a no-op")
	eq(slower.bestTimeResult, "noop", "slower retry keeps the best")
	local faster = finish(p, 1, 130.25)
	eq(faster.tokenResult, "noop", "token still held once")
	eq(faster.bestTimeResult, "awarded", "faster retry improves the best")
	eq(svc.get(p).bestTimes["DINO-4"], 130250, "stored best time")
	eq(p:GetAttribute("SkyTokens"), 1, "exactly one token")
	check(countLogs("[SkyRally][SAVE] noop user=" .. p.UserId .. " kind=token id=race:DINO-4") == 3, "every repeat logged as noop")
	RaceManager.saver = nil
end)

test("awards: abandoned, non-standard, hub and simulated finishes", function()
	local svc = newSave()
	local c = counting(svc)
	RaceManager.saver = c
	local p = newPlayer()
	svc.load(p)
	local abandoned = finish(p, 1, 120, "race", { finished = false })
	eq(abandoned.tokenResult, "skip", "abandoned: no token")
	eq(abandoned.bestTimeResult, "skip", "abandoned: no time")
	eq(c.calls, 0, "abandoned race calls SaveService not at all")
	local tt = finish(p, 1, 120, "timetrial")
	eq(tt.token, nil, "time trial has no token")
	eq(tt.tokenResult, "skip", "time trial token skip")
	eq(tt.bestTimeResult, "awarded", "time trial sets the best time")
	local coin = finish(p, 1, 110, "coin")
	eq(coin.tokenResult, "skip", "coin challenge awards through its own event, not the race finish")
	eq(coin.bestTimeResult, "skip", "coin run is not a timed lap record")
	local hub = RaceManager.awardFinish(p, { trackId = "HUB-0", mode = "race", rank = 1, time = 90, finished = true })
	eq(hub.tokenResult, "skip", "no race token on the hub")
	eq(c.calls, 1, "only the time trial reached SaveService")
	studio.value = false
	local simLive = finish(p, 1, 100, "race", { simulated = true })
	eq(simLive.tokenResult, "skip", "simulated finish outside Studio awards nothing")
	eq(c.calls, 1, "still no call")
	studio.value = true
	local simStudio = finish(p, 1, 100, "race", { simulated = true })
	eq(simStudio.tokenResult, "awarded", "simulated finish in Studio awards the token (QA path)")
	eq(simStudio.bestTimeResult, "skip", "a simulated time never becomes a best time")
	eq(svc.get(p).bestTimes["DINO-4"], 120000, "best time unchanged by the simulated finish")
	RaceManager.saver = nil
end)

test("awards: a Storm Cup finish awards no token and no best time (Gears and Win Pass are Economy's)", function()
	local svc = newSave()
	local c = counting(svc)
	RaceManager.saver = c
	local p = newPlayer()
	svc.load(p)
	local cup = finish(p, 1, 95, "stormcup")
	eq(cup.token, nil, "no token id in a cup")
	eq(cup.tokenResult, "skip", "first place in a cup is not a race token")
	eq(cup.bestTimeResult, "skip", "modifiers change the course: a cup time is not a track record")
	eq(c.calls, 0, "a cup finish never reaches SaveService through awardFinish")
	eq(p:GetAttribute("SkyTokens"), 0, "SkyTokens still 0 after a cup win")
	RaceManager.saver = nil
end)

test("awards: a finish with no save session is rejected, never written to a stand-in profile", function()
	local svc = newSave()
	RaceManager.saver = svc
	local p = newPlayer()
	-- No load yet: SaveService has no state for this player, so the award is rejected, not invented.
	local early = finish(p, 1, 140)
	eq(early.tokenResult, "rejected", "no session yet -> rejected (never a fresh-profile write)")
	RaceManager.saver = nil
end)

test("awards: RaceManager.completePlayerLap awards on the real finish path once per race; replay is a no-op", function()
	local svc = newSave()
	RaceManager.saver = svc
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	local p = newPlayer()
	svc.load(p)
	local rec = FakeFlightServer.spawnOrResetPlane(p, 1)
	rec.lap = 3
	RaceManager.raceStartClock = os.clock() - 95
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	check(rec.finished, "finished")
	eq(rec.finishRank, 1, "rank 1")
	eq(p:GetAttribute("SkyTokens"), 1, "token awarded on the finish")
	check(countLogs("[SkyRally][RACE] finish rank=1 name=" .. p.Name .. " player=true") == 1, "race finish log line kept")
	-- A second completion call for the same record does nothing (rec.finished).
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	eq(countLogs("kind=token id=race:DINO-4 track=DINO-4 mode=race rank=1 result="), 1, "one award attempt per finished race")
	-- Play again: new race, win again -> token no-op.
	RaceManager.resetRaceForAll()
	local rec2 = FakeFlightServer.records[p]
	check(rec2 ~= rec and not rec2.finished, "fresh record after reset")
	rec2.lap = 3
	RaceManager.completePlayerLap(rec2, os.clock(), 1000)
	eq(p:GetAttribute("SkyTokens"), 1, "still one token after the replay win")
	check(countLogs("kind=token id=race:DINO-4 track=DINO-4 mode=race rank=1 result=noop") == 1, "replay logged as noop")
	table.clear(FakeFlightServer.records)
	RaceManager.saver = nil
end)

test("economy hook: one raceFinished per real finish with mode/rank/laps; an unfinished racer in a reset race abandons", function()
	local svc = newSave()
	RaceManager.saver = svc
	local calls: { any } = {}
	local abandoned: { any } = {}
	RaceManager.economy = {
		raceFinished = function(player: any, info: any): any
			table.insert(calls, { user = player.UserId, mode = info.mode, rank = info.rank, laps = info.laps, rings = info.rings, simulated = info.simulated })
			return { gears = 59 }
		end,
		raceAbandoned = function(player: any)
			table.insert(abandoned, player.UserId)
		end,
	}
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	local p = newPlayer()
	svc.load(p)
	RaceManager.resetRaceForAll() -- arms the "last race mode" the abandon check reads
	local rec = FakeFlightServer.spawnOrResetPlane(p, 1)
	rec.lap = 3
	RaceManager.raceStartClock = os.clock() - 95
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	eq(#calls, 1, "one economy call per finished race")
	local c1 = calls[1]
	eq(c1.user, p.UserId, "finish info: player")
	eq(c1.mode .. "/" .. c1.rank .. "/" .. c1.laps .. "/" .. c1.rings .. "/" .. tostring(c1.simulated), "race/1/3/0/false", "finish info")
	eq(p:GetAttribute("SkyTokens"), 1, "race result and token untouched by the hook")
	-- A racer still flying when a running race is reset abandons it (Rally Streak reset); a finisher does not.
	RaceManager.resetRaceForAll()
	eq(#abandoned, 0, "finished racer did not abandon")
	RaceManager.raceStartClock = os.clock() - 30
	RaceManager.resetRaceForAll()
	eq(#abandoned, 1, "unfinished racer abandoned")
	eq(abandoned[1], p.UserId, "the right racer")
	-- A throwing hook never breaks the finish.
	RaceManager.economy = {
		raceFinished = function(): any
			error("economy down")
		end,
		raceAbandoned = function() end,
	}
	local rec3 = FakeFlightServer.records[p]
	rec3.lap = 3
	RaceManager.completePlayerLap(rec3, os.clock(), 1000)
	check(rec3.finished, "finish still lands")
	check(countLogs("[SkyRally][ECON] finish hook error") == 1, "hook error logged")
	RaceManager.economy = nil
	table.clear(FakeFlightServer.records)
	RaceManager.saver = nil
end)

test("social lane: finishHook gets the finish info, the award and the spline length once per real finish; a throwing hook never breaks it", function()
	local svc = newSave()
	RaceManager.saver = svc
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	local p = newPlayer()
	svc.load(p)
	local seen: { any } = {}
	RaceManager.finishHook = function(player: any, info: any, award: any, ctx: any)
		table.insert(seen, { user = player.UserId, track = info.trackId, mode = info.mode, rank = info.rank, finished = info.finished, time = info.time, token = award and award.tokenResult, totalLen = ctx.totalLen, laps = ctx.laps })
	end
	local rec = FakeFlightServer.spawnOrResetPlane(p, 1)
	rec.lap = 3
	RaceManager.raceStartClock = os.clock() - 95
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	eq(#seen, 1, "one hook call per finished race")
	local s1 = seen[1]
	eq(s1.user .. "/" .. s1.track .. "/" .. s1.mode .. "/" .. s1.rank .. "/" .. tostring(s1.finished), p.UserId .. "/DINO-4/race/1/true", "finish info")
	check(s1.time >= 94 and s1.time <= 97, "time comes from the server race clock: " .. tostring(s1.time))
	eq(s1.token, "awarded", "the hook sees the saved award")
	eq(s1.totalLen, 1000, "spline length for the lower bound")
	eq(s1.laps, 3, "laps")
	RaceManager.resetRaceForAll()
	RaceManager.finishHook = function()
		error("leaderboard down")
	end
	local rec2 = FakeFlightServer.records[p]
	rec2.lap = 3
	RaceManager.completePlayerLap(rec2, os.clock(), 1000)
	check(rec2.finished, "finish still lands")
	check(countLogs("[SkyRally][RACE] finish hook error") == 1, "hook error logged")
	RaceManager.finishHook = nil
	table.clear(FakeFlightServer.records)
	RaceManager.saver = nil
end)

test("awards L30: boss, rematch and final boss go to every human who finished ahead of the boss, not only rank 1", function()
	local calls: { string } = {}
	RaceManager.saver = {
		award = function(_player: any, kind: any, id: string, _source: string, _value: number?): (string, { string })
			table.insert(calls, tostring(kind) .. ":" .. id)
			return "awarded", {}
		end,
	}
	local p = newPlayer()
	eq(finish(p, 2, 150, "boss", { beatBoss = true }).tokenResult, "awarded", "second human, boss behind: beaten")
	eq(finish(p, 2, 150, "boss", { beatBoss = false }).tokenResult, "skip", "boss crossed first: not beaten")
	eq(finish(p, 3, 150, "rematch", { beatBoss = true }).tokenResult, "awarded", "rematch: third human, boss last")
	eq(finish(p, 2, 150, "rematch").tokenResult, "skip", "no beatBoss (old callers): the rank 1 rule")
	local final = RaceManager.awardFinish(p, { trackId = "HUB-0", mode = "boss", rank = 2, time = 90, finished = true, beatBoss = true })
	eq(final.tokenResult, "awarded", "final boss: a second human ahead of Thunderwright opens SPACE too")
	eq(finish(p, 2, 150, "race", { beatBoss = true }).tokenResult, "skip", "a race token still needs rank 1")
	eq(table.concat(calls, ","), "bossFirst:DINO-4,bossRematch:DINO-4,finalBoss:HUB-BOSS-1,bestTime:DINO-4", "award calls")
	RaceManager.saver = nil
end)

test("L30: completePlayerLap marks beatBoss from the bots already home; a DNF never finishes late and keeps the streak", function()
	local svc = newSave()
	RaceManager.saver = svc
	local abandoned: { number } = {}
	RaceManager.economy = {
		raceFinished = function(): any
			return nil
		end,
		raceAbandoned = function(player: any)
			table.insert(abandoned, player.UserId)
		end,
	}
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	workspaceStub:SetAttribute("RaceMode", "boss")
	local a, b, c, d = newPlayer(), newPlayer(), newPlayer(), newPlayer()
	for i, p in { a, b, c, d } do
		svc.load(p)
		FakeFlightServer.spawnOrResetPlane(p, i)
	end
	RaceManager.resetRaceForAll()
	table.clear(abandoned) -- the reset above closed whatever an earlier case left running
	local recA = FakeFlightServer.records[a]
	local recB = FakeFlightServer.records[b]
	local recC = FakeFlightServer.records[c]
	RaceManager.raceStartClock = os.clock() - 95
	recA.lap, recB.lap = 3, 3
	RaceManager.completePlayerLap(recA, os.clock(), 1000)
	RaceManager.completePlayerLap(recB, os.clock(), 1000)
	check(countLogs("kind=bossFirst id=DINO-4 track=DINO-4 mode=boss rank=1") == 1, "first human beat the boss")
	check(countLogs("kind=bossFirst id=DINO-4 track=DINO-4 mode=boss rank=2") == 1, "second human beat it too (not 'the boss won')")
	check(countLogs("the boss won") == 0, "nobody was told the boss won")
	-- The boss crosses, then a third human: that one lost to the boss.
	table.insert(RaceManager.finishOrder, { name = "Boss", isPlayer = false, time = 99, rank = 3 })
	check(not RaceManager.allPlayersFinished(), "C and D still racing")
	RaceManager.markDnf(c)
	check(recC.dnf == true and not recC.finished, "C is DNF, not finished")
	d.Parent = nil -- D quits mid-race
	check(RaceManager.allPlayersFinished(), "a DNF counts as done for the return timer")
	recC.lap = 3
	RaceManager.completePlayerLap(recC, os.clock(), 1000)
	check(not recC.finished, "a crossing after the deadline is no finish")
	check(countLogs("player=" .. c.Name .. " kind=bossFirst") == 0, "and no award")
	RaceManager.resetRaceForAll()
	eq(table.concat(abandoned, ","), tostring(d.UserId), "only the quitter loses the Rally Streak; the DNF keeps it")
	check(FakeFlightServer.records[c].dnf == nil, "the next race starts clean")
	workspaceStub:SetAttribute("RaceMode", nil)
	RaceManager.economy = nil
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	RaceManager.saver = nil
end)

------------------------------------------------------------------------------------------------------------------------
-- 3. Client pickup claims (RaceManager.handlePickup: "PickupCollected" is a claim, never a grant)
------------------------------------------------------------------------------------------------------------------------

local function fakePod(name: string, podType: string, pos: any): any
	-- A mystery cube's frame parts are children of the glass core: the cooldown hides and restores the whole subtree.
	local edge = { Name = "CubeEdge_1", Transparency = 0, Parent = true }
	function edge.IsA(_self: any, cls: string): boolean
		return cls == "BasePart"
	end
	local core = { Name = name .. "_CoreVisual", Transparency = 0.15, Parent = true, edge = edge }
	function core.GetDescendants(_self: any): { any }
		return { edge }
	end
	local pod = holder({ Name = name, Position = pos, Parent = true })
	pod.attrs.ItemPodSpawn = true
	pod.attrs.PodType = podType
	pod.attrs.RespawnSeconds = 4
	pod.attrs.OnCooldown = false
	function pod.IsA(_self: any, cls: string): boolean
		return cls == "BasePart"
	end
	function pod.FindFirstChild(_self: any, child: string): any
		return if child == core.Name then core else nil
	end
	return pod, core
end

test("pickup claims: forged names and far claims change nothing; item pods grant only through ItemService", function()
	resetBotHandlers()
	table.clear(delayed)
	local registry = fakes["shared/TrackRegistry"]
	local originalBoosts = registry.getBoostsFolder
	local podsByName: { [string]: any } = {}
	registry.getBoostsFolder = function(): any
		return {
			FindFirstChild = function(_self: any, name: string): any
				return podsByName[name]
			end,
		}
	end

	local p = newPlayer()
	local rid = ItemService.playerRacerId(p.UserId)
	local w = newWorld()
	w.add(rid, 100, 0, 0)
	w.sortOrder()
	ItemService.active = w.service
	-- The pod-taken handler RaceManager.init registers (init itself needs remotes this spec does not stub).
	ItemService.setPodTakenHandler(function(podName: string)
		local pod = podsByName[podName]
		if pod then
			RaceManager.startPodCooldown(pod)
		end
	end)
	local hullPos = w.world.racerPosition(rid)
	local rec = { player = p, hull = { Parent = true, Position = hullPos } }

	-- Item pod at the hull: granted by ItemService, hidden for everyone.
	local redPod, redCore = fakePod("Pod_Red", "Red", hullPos)
	podsByName.Pod_Red = redPod
	w.pods.Pod_Red = { position = hullPos, podType = "Red", respawnSeconds = 4 }
	RaceManager.handlePickup(p, rec, "Pod_Red")
	eq(ItemRules.label(w.service.getState(rid)), "red:1", "item pod granted")
	eq(redPod:GetAttribute("OnCooldown"), true, "taken pod hidden")
	eq(redCore.Transparency, 1, "core visual hidden")
	eq(redCore.edge.Transparency, 1, "cube frame hidden with the core")
	RaceManager.handlePickup(p, rec, "Pod_Red")
	eq(ItemRules.label(w.service.getState(rid)), "red:1", "a repeat claim on a cooling pod upgrades nothing")

	-- Item pod across the map: ItemService refuses (distance from the server's hull), the pod stays visible.
	local farPos = hullPos + V3.new(0, 0, -900)
	local farPod = fakePod("Pod_FarRed", "Red", farPos)
	podsByName.Pod_FarRed = farPod
	w.pods.Pod_FarRed = { position = farPos, podType = "Red", respawnSeconds = 4 }
	RaceManager.handlePickup(p, rec, "Pod_FarRed")
	eq(ItemRules.label(w.service.getState(rid)), "red:1", "far item claim grants nothing")
	eq(farPod:GetAttribute("OnCooldown"), false, "far item pod not hidden")

	-- Speed pod: no item, but the shared visual flips only for a claim the hull can back.
	local farSpeed = fakePod("Pod_FarSpeed", "Speed", farPos)
	podsByName.Pod_FarSpeed = farSpeed
	RaceManager.handlePickup(p, rec, "Pod_FarSpeed")
	eq(farSpeed:GetAttribute("OnCooldown"), false, "far speed claim rejected")
	check(countLogs("[SkyRally][RACE] pickup reject user=" .. p.UserId .. " reason=too_far") == 1, "too_far logged")
	local nearSpeed = fakePod("Pod_Speed", "Speed", hullPos + V3.new(0, 0, -20))
	podsByName.Pod_Speed = nearSpeed
	RaceManager.handlePickup(p, rec, "Pod_Speed")
	eq(nearSpeed:GetAttribute("OnCooldown"), true, "near speed claim hides the pod")
	eq(ItemRules.label(w.service.getState(rid)), "red:1", "a speed pod is not an item")

	-- Forged payloads: wrong type, control characters, unknown names. Nothing changes.
	for _, bad in { 42, "", string.rep("x", 65), "Pod_Red\n[SkyRally][ITEM] pickup fake", "NoSuchPod" } do
		RaceManager.handlePickup(p, rec, bad)
	end
	eq(ItemRules.label(w.service.getState(rid)), "red:1", "forged claims grant nothing")

	-- Respawn: the delayed task shows the pod again.
	local respawned = 0
	for _, d in delayed do
		eq(d.seconds, 4, "RespawnSeconds from the pod")
		d.fn()
		respawned += 1
	end
	eq(respawned, 2, "one respawn per hidden pod (red, near speed)")
	eq(redPod:GetAttribute("OnCooldown"), false, "red pod back")
	eq(redCore.Transparency, 0.15, "core visual back")
	eq(redCore.edge.Transparency, 0, "cube frame back at its own transparency")

	registry.getBoostsFolder = originalBoosts
	ItemService.active = nil
	resetBotHandlers()
	table.clear(delayed)
end)

test("X-04: a lap rollover moves the respawn frame to CP1 (never the previous lap's last checkpoint)", function()
	table.clear(FakeFlightServer.records)
	table.clear(RaceManager.finishOrder)
	local saved = table.clone(RaceManager.checkpoints)
	table.clear(RaceManager.checkpoints)
	local cp1 = CF.new(0, 112, -10)
	local cp12 = CF.new(0, 112, -950)
	table.insert(RaceManager.checkpoints, { index = 1, station = 10, part = {}, respawnCF = cp1 })
	table.insert(RaceManager.checkpoints, { index = 2, station = 400, part = {}, respawnCF = CF.new(0, 112, -400) })
	table.insert(RaceManager.checkpoints, { index = 12, station = 950, part = {}, respawnCF = cp12 })
	local p = newPlayer()
	local rec = FakeFlightServer.spawnOrResetPlane(p, 1)
	rec.lap = 1
	rec.lastCheckpointIdx = 12
	rec.lastCheckpointCF = cp12
	RaceManager.raceStartClock = os.clock() - 60
	RaceManager.completePlayerLap(rec, os.clock(), 1000)
	eq(rec.lap, 2, "lap 2 started")
	eq(rec.lastCheckpointIdx, 1, "checkpoint index back to 1")
	check(rec.lastCheckpointCF == cp1, "respawn frame is CP1's, not CP12's behind the line")
	check(not rec.finished, "a rollover is not a finish")
	table.clear(RaceManager.checkpoints)
	for _, cp in saved do
		table.insert(RaceManager.checkpoints, cp)
	end
	table.clear(FakeFlightServer.records)
end)

------------------------------------------------------------------------------------------------------------------------

local passed, failed = 0, 0
for _, t in tests do
	table.clear(logs)
	local ok, err = pcall(t.fn)
	if ok then
		passed += 1
		print("  PASS " .. t.name)
	else
		failed += 1
		print("  FAIL " .. t.name .. "\n       " .. tostring(err))
		for _, line in logs do
			print("       | " .. line)
		end
	end
end
print(string.format("loop_spec: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
