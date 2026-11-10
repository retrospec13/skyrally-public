--!strict
-- Lune spec for the battle framework end to end (TEST_LIST_LAUNCH L72, L75 groundwork): the REAL server/battle/BattleCore,
-- BattleBots and modes/Survival over the REAL SNOW-1 TrackData, with fakes for everything that needs Studio (instances,
-- FlightServer records, the item effects engine, saves, remotes, raycasts). It drives Heartbeat by hand on a fake
-- server clock: seating, pods, countdown, bot motion inside the arena, item hits through the arena hooks, elimination,
-- boundary return, results with the fragment award, the cap, leaving and late joining, and a clean stop.
-- Run: tools/tests/run_lune_tests.sh tools/tests/battle_flow_spec.luau   (standalone: plain `lune run` also works)
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
-- Fake instances: enough of the Instance API for BattleCore/BattleBots (names, parents, attributes, children)
------------------------------------------------------------------------------------------------------------------------

local IS_A: { [string]: { [string]: boolean } } = {
	Part = { BasePart = true, Part = true },
	Model = { Model = true, PVInstance = true },
	Folder = { Folder = true },
}

local function newInstance(className: string, name: string?): any
	local data: any = { ClassName = className, Name = name or className, __children = {}, __attrs = {}, __parent = nil }
	local proxy: any
	local methods: any = {}
	function methods.SetAttribute(_self: any, k: string, v: any)
		data.__attrs[k] = v
	end
	function methods.GetAttribute(_self: any, k: string): any
		return data.__attrs[k]
	end
	function methods.FindFirstChild(_self: any, n: string): any
		for _, c in data.__children do
			if c.Name == n then
				return c
			end
		end
		return nil
	end
	methods.WaitForChild = methods.FindFirstChild
	function methods.GetChildren(_self: any): { any }
		return table.clone(data.__children)
	end
	function methods.GetDescendants(_self: any): { any }
		local out = {}
		local function walk(n: any)
			for _, c in n:GetChildren() do
				table.insert(out, c)
				walk(c)
			end
		end
		walk(proxy)
		return out
	end
	function methods.IsA(_self: any, c: string): boolean
		return c == className or (IS_A[className] ~= nil and IS_A[className][c] == true) or c == "Instance"
	end
	function methods.Destroy(self: any)
		self.Parent = nil
		for _, c in table.clone(data.__children) do
			c:Destroy()
		end
	end
	function methods.IsDescendantOf(_self: any, other: any): boolean
		local p = data.__parent
		while p do
			if p == other then
				return true
			end
			p = p.Parent
		end
		return false
	end
	proxy = setmetatable({}, {
		__index = function(_, k: string): any
			if k == "Parent" then
				return data.__parent
			end
			local m = methods[k]
			if m then
				return m
			end
			return data[k]
		end,
		__newindex = function(self: any, k: string, v: any)
			if k == "Parent" then
				local old = data.__parent
				if old then
					local list = old.__childList
					local i = table.find(list, self)
					if i then
						table.remove(list, i)
					end
				end
				data.__parent = v
				if v then
					table.insert(v.__childList, self)
				end
			else
				data[k] = v
			end
		end,
	})
	data.__childList = data.__children
	return proxy
end

------------------------------------------------------------------------------------------------------------------------
-- Services and world
------------------------------------------------------------------------------------------------------------------------

local function signal(): any
	local s = { handlers = {} }
	function s.Connect(self: any, fn: any)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	function s.Fire(self: any, ...: any)
		for _, fn in self.handlers do
			fn(...)
		end
	end
	return s
end

local clock = { now = 5000 }
local playerList: { any } = {}
local PlayersStub: any = { PlayerAdded = signal(), PlayerRemoving = signal() }
function PlayersStub.GetPlayers(_self: any): { any }
	return table.clone(playerList)
end
function PlayersStub.GetPlayerByUserId(_self: any, id: number): any
	for _, p in playerList do
		if p.UserId == id then
			return p
		end
	end
	return nil
end

local RunServiceStub: any = { Heartbeat = signal() }
function RunServiceStub.IsStudio(): boolean
	return true
end
function RunServiceStub.IsServer(): boolean
	return true
end

local workspaceStub: any = newInstance("Folder", "Workspace")
local wsAttrs: { [string]: any } = {}
-- workspace:Raycast(origin, direction): nil (an open sky over a flat world) unless a case installs its own geometry.
local rayStub: ((origin: any, direction: any) -> any)? = nil
local wsProxy: any = setmetatable({}, {
	__index = function(_, k: string): any
		if k == "GetServerTimeNow" then
			return function(): number
				return clock.now
			end
		elseif k == "SetAttribute" then
			return function(_self: any, a: string, v: any)
				wsAttrs[a] = v
			end
		elseif k == "GetAttribute" then
			return function(_self: any, a: string): any
				return wsAttrs[a]
			end
		elseif k == "Raycast" then
			return function(_self: any, origin: any, direction: any): any
				local fn = rayStub
				return if fn then fn(origin, direction) else nil
			end
		end
		return (workspaceStub :: any)[k]
	end,
})
-- Children (Planes) live on the real fake folder; wsProxy forwards FindFirstChild etc. to it.
local mapRoot = newInstance("Folder", "SNOW-1")
local boosts = newInstance("Folder", "BoostsAndPods")
boosts.Parent = mapRoot

local fired: { { player: any, event: string, data: any } } = {}
local broadcast: { { event: string, data: any } } = {}
local TrackFlowRemote: any = { Name = "TrackFlowRemote" }
function TrackFlowRemote.IsA(_self: any, c: string): boolean
	return c == "RemoteEvent"
end
function TrackFlowRemote.FireClient(_self: any, player: any, event: string, data: any)
	table.insert(fired, { player = player, event = event, data = data })
end
function TrackFlowRemote.FireAllClients(_self: any, event: string, data: any)
	table.insert(broadcast, { event = event, data = data })
end

-- Module references: { __ref = "server/battle/BattleCore" }; folders resolve children from the repo tree.
local fakes: { [string]: any } = {}
local cache: { [string]: any } = {}
local load: (string) -> any

local function moduleRef(ref: string, parent: any): any
	local r: any = { __ref = ref, Name = string.match(ref, "([^/]+)$"), Parent = parent }
	function r.IsA(_self: any, c: string): boolean
		return c == "ModuleScript"
	end
	return r
end

-- The src/ tree indexed once up front: fs calls yield, and a yield inside the __index metamethods below is illegal.
local srcFiles: { [string]: boolean } = {}
local srcDirs: { [string]: boolean } = {}
local function indexTree(rel: string)
	for _, entry in fs.readDir(root .. "/src/" .. rel) do
		local path = if rel == "" then entry else rel .. "/" .. entry
		if fs.isDir(root .. "/src/" .. path) then
			srcDirs[path] = true
			indexTree(path)
		else
			local n = string.match(path, "^(.+)%.luau$")
			if n then
				srcFiles[n] = true
			end
		end
	end
end
indexTree("")

local folderRef: (string, any) -> any
folderRef = function(prefix: string, parent: any): any
	local f: any = { Name = string.match(prefix, "([^/]+)/?$"), Parent = parent, __prefix = prefix }
	local function child(name: string): any
		local ref = prefix .. name
		if fakes[ref] ~= nil or srcFiles[ref] then
			return moduleRef(ref, f)
		elseif srcDirs[ref] then
			return folderRef(ref .. "/", f)
		end
		return nil
	end
	function f.FindFirstChild(_self: any, name: string): any
		return child(name)
	end
	function f.WaitForChild(_self: any, name: string): any
		return child(name) or error("no child " .. name .. " under " .. prefix)
	end
	function f.GetChildren(_self: any): { any }
		local out = {}
		for ref in srcFiles do
			local n = string.match(ref, "^" .. string.gsub(prefix, "%W", "%%%0") .. "([^/]+)$")
			if n then
				table.insert(out, moduleRef(prefix .. n, f))
			end
		end
		table.sort(out, function(a: any, b: any): boolean
			return a.Name < b.Name
		end)
		return out
	end
	return setmetatable(f, {
		__index = function(_, k: string): any
			return child(k)
		end,
	})
end

local serverFolder = folderRef("server/", nil)
local sharedFolder = folderRef("shared/", nil)
local remotesFolder: any = {
	FindFirstChild = function(_self: any, n: string): any
		return if n == "TrackFlowRemote" then TrackFlowRemote else nil
	end,
}
local ReplicatedStub: any = {
	WaitForChild = function(_self: any, n: string): any
		return if n == "Shared" then sharedFolder else error("ReplicatedStorage:WaitForChild(" .. n .. ")")
	end,
	FindFirstChild = function(_self: any, n: string): any
		return if n == "SkyRallyRemotes" then remotesFolder elseif n == "Shared" then sharedFolder else nil
	end,
}
local HttpStub: any = {}
function HttpStub.JSONEncode(_self: any, v: any): string
	local serde = require("@lune/serde") :: any
	return serde.encode("json", v)
end

local services: { [string]: any } = {
	Players = PlayersStub,
	RunService = RunServiceStub,
	ReplicatedStorage = ReplicatedStub,
	HttpService = HttpStub,
}
local gameStub: any = {
	GetService = function(_self: any, n: string): any
		return services[n] or error("no stub service " .. n)
	end,
}

local function stubRequire(target: any): any
	local ref = type(target) == "table" and target.__ref
	assert(type(ref) == "string", "require of an unknown target")
	if fakes[ref] ~= nil then
		return fakes[ref]
	end
	local mod = load("src/" .. ref .. ".luau")
	if ref == "shared/PlaneConfig" and type(mod) == "table" then
		-- this spec pins the roster names ("HIT ACE AERO!"); the disguised names are specced in bot_names_spec / bot_looks_spec
		mod.BOT_DISGUISE = false
	end
	return mod
end

local EnumStub = setmetatable({}, {
	__index = function(_, a: string)
		return setmetatable({}, {
			__index = function(_, b: string)
				return a .. "." .. b
			end,
		})
	end,
})

load = function(rel: string): any
	if cache[rel] ~= nil then
		return cache[rel]
	end
	-- Data modules (build/<key>/TrackData.luau) sit outside src/: they get a parentless script.
	local ref = string.match(rel, "^src/(.*)%.luau$") or (string.match(rel, "^(.*)%.luau$") :: string)
	local dir = string.match(ref, "^(.*)/[^/]+$") or ""
	local parent = if dir == "" then serverFolder else folderRef(dir .. "/", nil)
	-- Give nested folders their real parents so script.Parent.Parent works (battle/modes -> battle -> server).
	if dir == "server/battle" then
		parent = folderRef("server/battle/", serverFolder)
	elseif dir == "server/battle/modes" then
		parent = folderRef("server/battle/modes/", folderRef("server/battle/", serverFolder))
	elseif dir == "server" then
		parent = serverFolder
	elseif dir == "shared" then
		parent = sharedFolder
	end
	local env = {
		game = gameStub,
		workspace = wsProxy,
		script = moduleRef(ref, parent),
		require = stubRequire,
		task = { spawn = function(fn: any, ...: any) fn(...) end, defer = function(fn: any, ...: any) fn(...) end, delay = function() end, wait = function() return 0 end },
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
	local chunk = luau.load(fs.readFile(root .. "/" .. rel), { debugName = rel, environment = env })
	local result = chunk()
	cache[rel] = result
	return result
end

------------------------------------------------------------------------------------------------------------------------
-- Fakes for the modules BattleCore touches
------------------------------------------------------------------------------------------------------------------------

local respawns: { any } = {}
local FakeFlightServer: any = { records = {}, startOverride = nil }
-- Mirrors FlightServer.respawnAtLastCheckpoint: the battle's respawn guard (a frame outside the arena becomes the seat,
-- an out player is not respawned), then the LastRespawnClock stamp a mode reads.
local respawnStamp = 0
function FakeFlightServer.respawnAtLastCheckpoint(player: any, clientDriven: boolean?, asked: boolean?): any
	local rec = FakeFlightServer.records[player]
	if not rec then
		return nil
	end
	local wasAsked = if asked ~= nil then asked else clientDriven == true
	local guard = FakeFlightServer.respawnGuard
	if guard then
		local fixed, blocked = guard(player, rec.lastCheckpointCF, wasAsked)
		if blocked then
			return nil
		end
		if fixed then
			rec.lastCheckpointCF = fixed
			clientDriven = false
		end
	end
	respawnStamp += 1
	player:SetAttribute("LastRespawnAsked", wasAsked)
	player:SetAttribute("LastRespawnClock", respawnStamp)
	table.insert(respawns, { player = player, cf = rec.lastCheckpointCF, clientDriven = clientDriven })
	rec.hull.Position = rec.lastCheckpointCF.Position
	return rec.lastCheckpointCF
end
-- FlightServer.setRespawnFrame: the battle seat as the record's and the client's respawn frame (no respawn).
local seatFrames: { any } = {}
function FakeFlightServer.setRespawnFrame(player: any, cf: any)
	local rec = FakeFlightServer.records[player]
	if rec then
		rec.lastCheckpointCF = cf
	end
	table.insert(seatFrames, { player = player, cf = cf })
end
fakes["server/FlightServer"] = FakeFlightServer
fakes["server/CarServer"] = {
	activeVehicle = function(): string
		return "plane"
	end,
	isCar = function(): boolean
		return false
	end,
	expectTeleport = function() end,
}
fakes["server/kit/Gameplay"] = {
	buildItemPodSpawn = function(name: string, pos: any, podType: string, _station: number, parent: any): any
		local p = newInstance("Part", name)
		p.Position = pos
		p:SetAttribute("ItemPodSpawn", true)
		p:SetAttribute("PodType", podType)
		p:SetAttribute("OnCooldown", false)
		p.Parent = parent
		return p
	end,
}
fakes["server/kit/ItemEffects"] = {
	paintPods = function() end,
}
local function fakeVehicle(name: string, cf: any): any
	local m = newInstance("Model", name)
	local hull = newInstance("Part", "Hull")
	hull.CFrame = cf
	hull.Parent = m
	m.PrimaryPart = hull
	return m
end
fakes["server/PlaneBuilder"] = {
	createPlane = function(name: string, _c: any, _a: any, cf: any, _ai: boolean?): any
		return fakeVehicle(name, cf)
	end,
}
fakes["server/kit/RacerPaint"] = { -- cosmetic palette + pennant: fake models have no descendants API
	paintBot = function() end,
	paintPlayer = function() end,
}
fakes["server/kit/CarBuilder"] = {
	createCar = function(name: string, _c: any, _a: any, cf: any, _ai: boolean?): any
		return fakeVehicle(name, cf)
	end,
}
fakes["shared/TrackRegistry"] = {
	getRoot = function(): any
		return mapRoot
	end,
	getBoostsFolder = function(): any
		return boosts
	end,
}
local awards: { string } = {}
fakes["server/SaveService"] = {
	award = function(player: any, kind: string, id: string, source: string): (string, { string })
		table.insert(awards, string.format("%s|%s|%s|%s", player.Name, kind, id, source))
		local held = #awards > 1
		player:SetAttribute("BattleFragments", 1)
		return if held then "noop" else "awarded", if held then {} else { "battleAmulet" }
	end,
}

-- Planes folder lives on the fake workspace.
local planes = newInstance("Folder", "Planes")
planes.Parent = workspaceStub

local snow = load("build/snow1/TrackData.luau")
local BattleRules = load("src/shared/battle/BattleRules.luau")
local ItemService = load("src/server/ItemService.luau")
local BattleCore = load("src/server/battle/BattleCore.luau")
local BattleBots = load("src/server/battle/BattleBots.luau")

-- The deps BattleCore gets from the boot script: an effects engine that records setArena and routes hit() to the
-- arena's onHit like the real engine does for a landed hit.
local arenaRules: any = nil
local arenaCalls = 0
local replays = 0
local fakeEffects: any = {}
function fakeEffects.setArena(rules: any)
	arenaRules = rules
	arenaCalls += 1
end
function fakeEffects.hit(victim: string, attacker: string, source: string, _stun: number, pos: any): string
	if arenaRules and arenaRules.onHit then
		arenaRules.onHit(victim, attacker, source, pos)
	end
	return "hit"
end
-- Respawn shields the core grants itself (a bot's respawn has no FlightServer stamp).
local granted: { string } = {}
function fakeEffects.grantImmunity(id: string, _seconds: number?, _asked: boolean?)
	table.insert(granted, id)
end

local function newPlayer(userId: number, name: string): any
	local p: any = { UserId = userId, Name = name, Parent = PlayersStub, attrs = {} }
	function p.SetAttribute(self: any, k: string, v: any)
		self.attrs[k] = v
	end
	function p.GetAttribute(self: any, k: string): any
		return self.attrs[k]
	end
	return p
end

local function seat(player: any, cf: any)
	table.insert(playerList, player)
	FakeFlightServer.records[player] = {
		player = player,
		hull = { Parent = true, Position = cf.Position, CFrame = cf },
		plane = { Name = "Plane_" .. player.Name },
		lastCheckpointCF = cf,
		finished = false,
	}
end

local function unseat(player: any)
	local i = table.find(playerList, player)
	if i then
		table.remove(playerList, i)
	end
	FakeFlightServer.records[player] = nil
	player.Parent = nil
end

local function heartbeat(seconds: number, dt: number?)
	local step = dt or 1 / 30
	local t = 0
	while t < seconds - 1e-9 do
		clock.now += step
		RunServiceStub.Heartbeat:Fire(step)
		t += step
	end
end

local function resetWorld()
	BattleCore.stop()
	for _, p in table.clone(playerList) do
		unseat(p)
	end
	table.clear(fired)
	table.clear(broadcast)
	table.clear(awards)
	table.clear(respawns)
	table.clear(logs)
	for _, c in boosts:GetChildren() do
		c:Destroy()
	end
end

local function lastFired(event: string, player: any?): any
	for i = #fired, 1, -1 do
		local f = fired[i]
		if f.event == event and (player == nil or f.player == player) then
			return f.data
		end
	end
	return nil
end

BattleCore.init({
	itemEffects = fakeEffects,
	trackData = function(): any
		return snow
	end,
	replay = function()
		replays += 1
	end,
})

------------------------------------------------------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------------------------------------------------------

local arena = BattleRules.arena(snow.modes.battle)

test("init registers the survival mode and the spawn override seats players on the pads in battle", function()
	check(BattleCore.kinds().survival, "survival registered from battle/modes")
	check(BattleCore.kinds().template == nil, "ModeTemplate (outside modes/) is not registered")
	eq(FakeFlightServer.startOverride, BattleCore.startCFrame, "override installed")
	wsAttrs.RaceMode = "race"
	eq(BattleCore.startCFrame(2), nil, "races keep their grid")
	wsAttrs.RaceMode = "battle"
	eq(BattleCore.startCFrame(2).Position, arena.spawns[2], "pad 2")
end)

test("start: player on its pad + seven bots (a race field of 8), battle pods replace race item pods, hooks and HUD armed", function()
	resetWorld()
	-- A race item pod and a speed pod on the track before the battle.
	local racePod = newInstance("Part", "Pod_Red_1")
	racePod:SetAttribute("ItemPodSpawn", true)
	racePod:SetAttribute("PodType", "Red")
	racePod.Parent = boosts
	local speed = newInstance("Part", "Pod_Speed_1")
	speed:SetAttribute("ItemPodSpawn", true)
	speed:SetAttribute("PodType", "Speed")
	speed.Parent = boosts
	local p = newPlayer(101, "Pilot")
	seat(p, BattleRules.spawnCFrame(arena, 2))
	wsAttrs.RaceMode = "battle"
	wsAttrs.RaceGoTime = clock.now + 4
	BattleCore.start(snow)
	eq(BattleCore.phase(), "countdown", "phase")
	eq(#BattleBots.bots, BattleRules.FIELD - 1, "seven arena bots: the field is 8, like a race")
	eq(BattleBots.bots[1].racerId, "bot:101", "arena bot ids start past the race roster")
	eq(BattleBots.bots[1].slot, 1, "bots take the free pads")
	eq(BattleBots.bots[2].slot, 3, "")
	eq(racePod.Parent, nil, "race item pod removed")
	eq(speed.Parent, boosts, "speed pod kept")
	local battlePods = 0
	for _, c in boosts:GetChildren() do
		if string.sub(c.Name, 1, 10) == "BattlePod_" then
			battlePods += 1
		end
	end
	eq(battlePods, 8, "SNOW-1 battle pods")
	eq(wsAttrs.BattleKind, "survival", "BattleKind")
	eq(wsAttrs.BattleEndsAt, wsAttrs.RaceGoTime + 180, "3-minute cap from GO")
	check(ItemService.arena() ~= nil, "ItemService arena hooks")
	check(arenaRules ~= nil, "ItemEffects arena rules")
	eq(p:GetAttribute("BattleHud"), "LIVES 3  -  7 RIVALS LEFT", "objective line")
	eq(p:GetAttribute("BattleOut"), false, "in play")
	check(string.find(wsAttrs.BattleBoard, "3 LIVES", 1, true) ~= nil, "board JSON")
	eq(mapRoot:GetAttribute("CarOffTrackDrop"), 0, "no stranded respawns in the arena")
end)

test("countdown holds the bots on their pads; after GO they move, stay inside, and the arena targets the nearest", function()
	heartbeat(1)
	eq(BattleBots.bots[1].pos, arena.spawns[1], "held on pad 1")
	heartbeat(4)
	eq(BattleCore.phase(), "running", "GO")
	heartbeat(6)
	local moved = 0
	for _, b in BattleBots.bots do
		if (b.pos - BattleRules.spawnPosition(arena, b.slot)).Magnitude > 50 then
			moved += 1
		end
		check(BattleRules.horizontal(b.pos, arena.center) <= arena.returnRadius, b.name .. " inside the boundary")
		check(b.pos.Y <= arena.ceiling, b.name .. " under the ceiling")
	end
	eq(moved, #BattleBots.bots, "all seven bots are flying")
	local target = arenaRules.target("player:101")
	check(target ~= nil and string.sub(target, 1, 4) == "bot:", "the player's shot locks a bot")
	local order = arenaRules.order()
	eq(#order, BattleRules.FIELD, "all eight entrants can be hit")
end)

test("hits cost lives through the arena hooks; at zero a bot is out and can no longer act or be hit", function()
	local p = playerList[1]
	for _ = 1, 2 do
		fakeEffects.hit("bot:101", "player:101", "missile", 1.2, arena.center)
	end
	local bot = BattleBots.find(101)
	eq(bot.out, false, "two hits: still in")
	eq(lastFired("BattleToast", p).text, "HIT ACE AERO!", "attacker toast")
	fakeEffects.hit("bot:101", "player:101", "missile", 1.2, arena.center)
	eq(bot.out, true, "third hit: out")
	eq((ItemService.arena().canAct("bot:101")), false, "out entrants hold and fire nothing")
	eq(#arenaRules.order(), BattleRules.FIELD - 1, "and are no longer hittable")
	eq(p:GetAttribute("BattleHud"), "LIVES 3  -  6 RIVALS LEFT", "HUD updated")
	-- A hit on the out bot changes nothing (the core filters it before the mode).
	fakeEffects.hit("bot:101", "player:101", "missile", 1.2, arena.center)
	eq(countLogs("survival hit victim=Ace Aero"), 3, "three scored hits")
end)

test("a player in the warn band gets a toast; past the boundary band it is put back on its own seat (G6)", function()
	local p = playerList[1]
	local rec = FakeFlightServer.records[p]
	local before = #respawns
	rec.hull.Position = arena.center + V3.new(0, 0, arena.radius + 10)
	heartbeat(0.3)
	eq(lastFired("BattleToast", p).text, "ARENA EDGE - turn back", "warn band")
	eq(#respawns, before, "no respawn in the warn band")
	-- Out on the WEST side, by pad 1 (a bot's seat): back on its own seat (pad 2, east), never the nearest pad (F6).
	rec.hull.Position = arena.center + V3.new(-(arena.returnRadius + 30), 0, 0)
	heartbeat(0.3)
	eq(#respawns, before + 1, "one server respawn")
	local r = respawns[#respawns]
	eq(r.clientDriven, false, "server-driven CheckpointRespawn")
	eq(r.cf.Position, arena.spawns[2], "its own seat, not the nearest pad")
	eq(lastFired("BattleToast", p).text, "Back into the arena!", "toast")
	eq(p:GetAttribute("BoundaryReturnClock"), p:GetAttribute("LastRespawnClock"), "the put-back is marked (not a crash)")
	eq(p:GetAttribute("LastRespawnAsked"), true, "player-caused: the respawn shield's rearm time applies")
	check(countLogs("via=seat") >= 1, "logged as a seat return")
	eq(wsAttrs.BattlePullStart, BattleRules.pullStart(arena, "plane"), "the pull band is published")
	eq(wsAttrs.BattleCeiling, arena.ceiling, "the ceiling is published")
	rec.hull.Position = arena.center
end)

test("a respawn frame from another map is replaced by the seat; an out player is not respawned (stale fix, X-03)", function()
	local p = playerList[1]
	local rec = FakeFlightServer.records[p]
	check(FakeFlightServer.respawnGuard ~= nil, "the guard is installed while the battle runs")
	-- The client's own respawn request with the record holding the hub plaza (the Studio stale frame).
	rec.lastCheckpointCF = CF.new(-8162, 30, 8028)
	local cf = FakeFlightServer.respawnAtLastCheckpoint(p, true)
	eq(cf.Position, arena.spawns[2], "the seat instead")
	eq(rec.lastCheckpointCF.Position, arena.spawns[2], "the record follows")
	eq(respawns[#respawns].clientDriven, false, "sent to the client (its cache was stale too)")
	check(countLogs("stale respawn frame for Pilot") >= 1, "logged")
	-- A frame in the arena is left alone.
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 3)
	eq(FakeFlightServer.respawnAtLastCheckpoint(p, true).Position, arena.spawns[3], "an arena frame stands")
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 2)
	rec.hull.Position = arena.center
end)

test("last entrant with lives wins: results, fragment award once, records finished", function()
	local p = playerList[1]
	for _, id in { "bot:102", "bot:103", "bot:104", "bot:105", "bot:106", "bot:107" } do
		for _ = 1, 3 do
			fakeEffects.hit(id, "player:101", "missile", 1.2, arena.center)
		end
	end
	eq(BattleCore.phase(), "over", "over")
	eq(wsAttrs.BattleState, "over", "state attribute")
	eq(FakeFlightServer.records[p].finished, true, "record finished: return-to-hub timer and items stop")
	local res = lastFired("BattleResults", p)
	check(res ~= nil, "results sent")
	eq(res.youWon, true, "victory")
	eq(res.reason, "last one standing", "reason")
	eq(res.rows[1].name, "Pilot", "winner first")
	eq(res.rows[1].text, "3 LIVES", "row text")
	eq(#res.rows, BattleRules.FIELD, "eight rows")
	eq(res.award.result, "awarded", "fragment")
	eq(res.award.amulet, true, "amulet moment passed through")
	eq(#awards, 1, "one award call")
	eq(awards[1], "Pilot|battle|SNOW|battle_win:SNOW-1", "award args")
	eq((ItemService.arena().canAct("player:101")), false, "nobody acts after the end")
	fakeEffects.hit("player:101", "bot:102", "missile", 1.2, arena.center)
	eq(#awards, 1, "no second result")
	heartbeat(1)
	eq(BattleBots.bots[2].speed, 0, "bots hover once it is over")
end)

test("stop clears bots, pods, hooks and attributes", function()
	BattleCore.stop()
	eq(#BattleBots.bots, 0, "bots gone")
	eq(planes:FindFirstChild("AI_Ace_Aero"), nil, "bot models destroyed")
	eq(ItemService.arena(), nil, "ItemService hooks cleared")
	eq(arenaRules, nil, "ItemEffects arena cleared")
	for _, c in boosts:GetChildren() do
		check(string.sub(c.Name, 1, 10) ~= "BattlePod_", "battle pod left behind: " .. c.Name)
	end
	eq(wsAttrs.BattleKind, nil, "BattleKind cleared")
	eq(playerList[1]:GetAttribute("BattleHud"), nil, "HUD cleared")
end)

test("under the ceiling a player gets a TOO HIGH warning and is not put back (G6); once out, never respawned (X-03)", function()
	resetWorld()
	local p = newPlayer(212, "Climber")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	eq(BattleCore.phase(), "running", "running")
	local before = #respawns
	FakeFlightServer.records[p].hull.Position = V3.new(arena.center.X, arena.ceiling - 10, arena.center.Z)
	heartbeat(0.3)
	eq(lastFired("BattleToast", p).text, "TOO HIGH - nose down", "ceiling warn band")
	eq(#respawns, before, "no put-back under the ceiling")
	-- Out of lives (X-03): no respawn of any kind, the spectator stays where it went out.
	for _ = 1, 3 do
		fakeEffects.hit("player:212", "bot:101", "missile", 1.2, arena.center)
		clock.now += 1
	end
	eq(p:GetAttribute("BattleOut"), true, "out")
	eq(FakeFlightServer.respawnAtLastCheckpoint(p, true), nil, "its respawn request is refused")
	eq(#respawns, before, "no respawn after the last life")
	BattleCore.stop()
	eq(wsAttrs.BattlePullStart, nil, "pull band cleared on stop")
	eq(FakeFlightServer.respawnGuard, nil, "guard removed on stop")
end)

test("start seats from a stale frame: pads in order, the vehicle put on its seat, the client told", function()
	resetWorld()
	local p = newPlayer(222, "Hubber")
	-- The record still holds the hub plaza (a reset that has not reached it): not a hint for a seat.
	seat(p, CF.new(-8162, 30, 8028))
	wsAttrs.RaceGoTime = clock.now + 4
	local before = #respawns
	BattleCore.start(snow)
	local e = BattleBots.bots[1]
	check(e.slot ~= 1, "the player took pad 1 (in order), the bots the rest")
	local rec = FakeFlightServer.records[p]
	eq(rec.lastCheckpointCF.Position, arena.spawns[1], "the record's respawn frame is the seat")
	eq(#respawns, before + 1, "the vehicle off its seat is put on it")
	eq(respawns[#respawns].clientDriven, false, "by a server CheckpointRespawn")
	eq(rec.hull.Position, arena.spawns[1], "on the seat")
	check(countLogs("seat Hubber put on seat 1") >= 1, "logged")
	BattleCore.stop()
	-- On its seat already: the frame is only sent (setRespawnFrame), no respawn.
	resetWorld()
	local q = newPlayer(223, "Seated")
	seat(q, BattleRules.spawnCFrame(arena, 2))
	local n = #respawns
	BattleCore.start(snow)
	eq(#respawns, n, "no respawn for a seated vehicle")
	BattleCore.stop()
end)

test("the cap resolves by lives; a replay win is still offered to SaveService (which no-ops it)", function()
	resetWorld()
	local p = newPlayer(202, "Capper")
	seat(p, BattleRules.spawnCFrame(arena, 3))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	eq(BattleCore.phase(), "running", "running")
	-- Everyone ends on 2 lives; the player lost its life first, so it has been hit-free the longest.
	fakeEffects.hit("player:202", "bot:102", "trap", 1.0, arena.center)
	clock.now += 1
	fakeEffects.hit("bot:101", "bot:103", "missile", 1.2, arena.center)
	clock.now += 1
	fakeEffects.hit("bot:102", "bot:101", "missile", 1.2, arena.center)
	clock.now += 1
	fakeEffects.hit("bot:103", "bot:102", "missile", 1.2, arena.center)
	for _, id in { "bot:104", "bot:105", "bot:106", "bot:107" } do
		clock.now += 1
		fakeEffects.hit(id, "bot:101", "missile", 1.2, arena.center)
	end
	clock.now = wsAttrs.BattleEndsAt - 0.01
	heartbeat(0.1)
	eq(BattleCore.phase(), "over", "the cap ended it")
	local res = lastFired("BattleResults", p)
	eq(res.reason, "time up - most lives wins", "cap reason")
	eq(res.youWon, true, "everyone at 2 lives: the player has been hit-free the longest")
	eq(res.rows[2].name, "Ace Aero", "then bot:101 (second loss)")
	eq(awards[1], "Capper|battle|SNOW|battle_win:SNOW-1", "award offered")
	BattleCore.stop()
end)

test("leaving: a lone player who leaves sets the battle waiting; a new player triggers a fresh countdown", function()
	resetWorld()
	local p = newPlayer(303, "Leaver")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	unseat(p)
	heartbeat(0.1)
	eq(BattleCore.phase(), "waiting", "waits for players")
	eq(#awards, 0, "nothing awarded for an abandoned battle")
	local before = replays
	local q = newPlayer(404, "Joiner")
	seat(q, BattleRules.spawnCFrame(arena, 2))
	heartbeat(0.1)
	eq(replays, before + 1, "the boot script's replay runs (reset + startMode)")
	BattleCore.stop()
end)

test("a player who joins a running battle spectates and is never scored", function()
	resetWorld()
	local p = newPlayer(505, "Racer")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	local late = newPlayer(606, "Late")
	seat(late, BattleRules.spawnCFrame(arena, 5))
	heartbeat(0.1)
	eq(late:GetAttribute("BattleOut"), true, "spectating")
	eq((ItemService.arena().canAct("player:606")), false, "holds and fires nothing")
	check(not string.find(wsAttrs.BattleBoard, "Late", 1, true), "not on the board")
	BattleCore.stop()
end)

test("a player who leaves during the countdown forfeits: its lives never hold the battle open or top the ranking", function()
	resetWorld()
	local stayer = newPlayer(711, "Stayer")
	local quitter = newPlayer(712, "Quitter")
	seat(stayer, BattleRules.spawnCFrame(arena, 1))
	seat(quitter, BattleRules.spawnCFrame(arena, 2))
	wsAttrs.RaceGoTime = clock.now + 2
	BattleCore.start(snow)
	heartbeat(0.5)
	eq(BattleCore.phase(), "countdown", "still counting down")
	unseat(quitter)
	heartbeat(0.1)
	check(string.find(wsAttrs.BattleBoard, '"o":true', 1, true) ~= nil, "the leaver shows out on the board")
	heartbeat(2)
	eq(BattleCore.phase(), "running", "GO for the rest")
	for _ = 1, 3 do
		fakeEffects.hit("player:711", "bot:101", "missile", 1.2, arena.center)
		clock.now += 3
	end
	eq(BattleCore.phase(), "over", "the last player out ends it (the leaver holds no lives)")
	local res = lastFired("BattleResults", stayer)
	eq(res.reason, "every player is out - ranked by lives", "reason")
	eq(string.sub(res.rows[1].name, 1, 2) ~= "Qu", true, "a bot wins, never the absent leaver")
	eq(res.rows[#res.rows].name, "Quitter", "the earliest exit ranks last")
	eq(lastFired("BattleResults", quitter), nil, "nothing is sent to a player who left")
	eq(#awards, 0, "no fragment without a win")
	BattleCore.stop()
end)

test("the last seated player leaving with a spectator present: the battle waits and the replay seats the spectator", function()
	resetWorld()
	local p = newPlayer(721, "Seated")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	local late = newPlayer(722, "Watcher")
	seat(late, BattleRules.spawnCFrame(arena, 5))
	heartbeat(0.1)
	eq(late:GetAttribute("BattleOut"), true, "spectating")
	local before = replays
	unseat(p)
	heartbeat(0.1)
	eq(BattleCore.phase(), "waiting", "a spectator alone does not keep the bots' battle going")
	heartbeat(0.1)
	eq(replays, before + 1, "the replay seats the watcher")
	eq(#awards, 0, "nothing awarded")
	BattleCore.stop()
end)

test("a player who leaves and rejoins mid-battle watches the rest: spectator HUD, no seat, results, no award", function()
	resetWorld()
	local a = newPlayer(731, "Anchor")
	local b = newPlayer(732, "Bouncer")
	seat(a, BattleRules.spawnCFrame(arena, 1))
	seat(b, BattleRules.spawnCFrame(arena, 2))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	unseat(b)
	heartbeat(0.1)
	local back = newPlayer(732, "Bouncer") -- a rejoin is a new Player object with no attributes
	seat(back, BattleRules.spawnCFrame(arena, 2))
	heartbeat(0.1)
	eq(back:GetAttribute("BattleOut"), true, "the client holds the plane as a spectator")
	eq(back:GetAttribute("BattleHud"), "SPECTATING - next battle seats you", "HUD line on the new object")
	eq((ItemService.arena().canAct("player:732")), false, "its seat stays forfeited")
	eq(BattleCore.phase(), "running", "the battle goes on for the seated player")
	wsAttrs.TriggerBattleEnd = true
	heartbeat(0.1)
	eq(BattleCore.phase(), "over", "QA end")
	local res = lastFired("BattleResults", back)
	check(res ~= nil, "the rejoined player sees the results")
	eq(res.spectator, true, "worded as a spectator's panel")
	eq(res.youWon, false, "never the winner")
	eq(res.award.result, "skip", "no award")
	for _, line in awards do
		check(not string.find(line, "Bouncer", 1, true), "no award for the rejoined leaver")
	end
	BattleCore.stop()
end)

test("an arena bot's shots lock the opponent its mode hunts, not just the nearest ahead", function()
	resetWorld()
	local p = newPlayer(741, "Prey")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	-- No pod ready: Survival's bots hunt; the hunted id rides on the bot.
	for _, c in boosts:GetChildren() do
		c:SetAttribute("OnCooldown", true)
	end
	heartbeat(1 / 30)
	local shooter = BattleBots.bots[1]
	check(shooter.attack ~= nil, "the mode's Goal.attack is kept on the bot")
	eq(arenaRules.target(shooter.racerId), shooter.attack, "its shot locks the hunted one")
	-- Another opponent dead ahead and nearer than the hunted player: the shot still goes to the player.
	local rec = FakeFlightServer.records[p]
	shooter.pos = arena.center
	shooter.forward = V3.new(1, 0, 0)
	BattleBots.bots[2].pos = arena.center + V3.new(40, 0, 0)
	rec.hull.Position = arena.center + V3.new(150, 0, 0)
	shooter.attack = "player:741"
	eq(arenaRules.target(shooter.racerId), "player:741", "hunted beats nearest")
	shooter.attack = nil
	eq(arenaRules.target(shooter.racerId), BattleBots.bots[2].racerId, "no hunt: nearest ahead")
	shooter.attack = "player:741"
	rec.hull.Position = arena.center + V3.new(600, 0, 0)
	eq(arenaRules.target(shooter.racerId), BattleBots.bots[2].racerId, "a hunted one out of range falls back")
	BattleCore.stop()
end)

test("a plane bot meeting a roof or rock lip ahead dives under it instead of climbing into it", function()
	resetWorld()
	local p = newPlayer(751, "Caver")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(snow)
	heartbeat(1.5)
	-- Forward probes meet a downward-facing surface; ground probes (straight down) still find open air.
	rayStub = function(origin: any, direction: any): any
		if math.abs(direction.X) + math.abs(direction.Z) < 1 then
			return nil
		end
		return { Position = origin + direction * 0.5, Normal = V3.new(0, -1, 0), Material = "Enum.Material.Rock" }
	end
	local ok, err = pcall(heartbeat, 0.2)
	rayStub = nil
	check(ok, tostring(err))
	for _, b in BattleBots.bots do
		check(b.avoidDir.Y < 0, b.name .. " dives (avoidDir.Y=" .. tostring(b.avoidDir.Y) .. ")")
	end
	-- A wall (normal facing back at the bot) still climbs and turns away.
	rayStub = function(origin: any, direction: any): any
		if math.abs(direction.X) + math.abs(direction.Z) < 1 then
			return nil
		end
		return { Position = origin + direction * 0.5, Normal = -direction.Unit, Material = "Enum.Material.Rock" }
	end
	ok, err = pcall(heartbeat, 0.2)
	rayStub = nil
	check(ok, tostring(err))
	for _, b in BattleBots.bots do
		check(b.avoidDir.Y > 0, b.name .. " climbs away from a wall")
	end
	BattleCore.stop()
end)

test("a track without battle data or with an unknown kind refuses with a toast", function()
	resetWorld()
	local p = newPlayer(801, "Stranded")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	BattleCore.start({ id = "DINO-4", zone = "DINO", modes = {} })
	eq(BattleCore.isRunning(), false, "no battle")
	eq(broadcast[#broadcast].data.text, "This battle is coming soon", "toast")
	eq(FakeFlightServer.records[p].finished, true, "finished: the return-to-hub timer brings the player back")
	FakeFlightServer.records[p].finished = false
	BattleCore.start({ id = "X", zone = "DINO", modes = { battle = { kind = "nope", center = V3.new(0, 0, 0), radius = 10 } } })
	eq(BattleCore.isRunning(), false, "unknown kind")
	eq(FakeFlightServer.records[p].finished, true, "released again")
end)

test("a mode whose start() throws is stopped cleanly and the players are released to the hub", function()
	resetWorld()
	local p = newPlayer(802, "Unlucky")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	BattleCore.register({
		kind = "broken_spec",
		title = "BROKEN",
		start = function(): any
			error("boom")
		end,
		resolve = function(): any
			return { ranking = {}, reason = "none" }
		end,
	} :: any)
	local td = table.clone(snow)
	td.modes = { battle = table.clone(snow.modes.battle) }
	td.modes.battle.kind = "broken_spec"
	BattleCore.start(td)
	eq(BattleCore.isRunning(), false, "no battle")
	eq(#BattleBots.bots, 0, "its bots are gone")
	eq(ItemService.arena(), nil, "its item hooks are gone")
	eq(wsAttrs.BattleKind, nil, "HUD attributes cleared")
	eq(broadcast[#broadcast].data.text, "The battle failed to start", "toast")
	eq(FakeFlightServer.records[p].finished, true, "released to the hub timer")
	check(countLogs("mode start error") == 1, "the error is logged once")
	table.clear(logs) -- the expected start error is the only warning here
end)

test("an asked respawn onto an unsafe frame goes through the mode's returnFrame; a server-ordered one and a safe one stand; a bot's gets the shield", function()
	resetWorld()
	local p = newPlayer(803, "Rescued")
	seat(p, BattleRules.spawnCFrame(arena, 1))
	local safe = BattleRules.spawnCFrame(arena, 4)
	local flooded = arena.spawns[1] -- the mode calls pad 1 unsafe (the water battle's flooded pad)
	local modeCtx: any = nil
	local asks = 0
	BattleCore.register({
		kind = "return_spec",
		title = "RETURN",
		start = function(ctx: any): any
			modeCtx = ctx
			return {}
		end,
		returnFrame = function(_ctx: any, _st: any, e: any, _pos: any): any
			asks += 1
			return if e.isPlayer then safe else nil
		end,
		frameSafe = function(_ctx: any, _st: any, pos: any): boolean
			return (pos - flooded).Magnitude > 1
		end,
		resolve = function(): any
			return { ranking = {}, reason = "none" }
		end,
	} :: any)
	local td = table.clone(snow)
	td.modes = { battle = table.clone(snow.modes.battle) }
	td.modes.battle.kind = "return_spec"
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(td)
	heartbeat(1.5)
	eq(BattleCore.phase(), "running", "running")
	local rec = FakeFlightServer.records[p]
	-- The plane client's own request (a crash, the RESPAWN button): the mode's safe frame, not the record's pad (the
	-- water battle's last pad may have flooded since).
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 1)
	eq(FakeFlightServer.respawnAtLastCheckpoint(p, true).Position, safe.Position, "the mode's safe frame")
	eq(asks, 1, "asked once")
	eq(respawns[#respawns].clientDriven, false, "sent to the client")
	eq(p:GetAttribute("LastRespawnAsked"), true, "stamped as asked (the shield's rearm time applies)")
	check(countLogs("asked respawn Rescued") >= 1, "logged")
	-- A car's request (CarServer: server-driven, asked) as well.
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 1)
	eq(FakeFlightServer.respawnAtLastCheckpoint(p, false, true).Position, safe.Position, "a car's request too")
	-- A frame the mode still calls safe stands (it is what the client has cached).
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 3)
	eq(FakeFlightServer.respawnAtLastCheckpoint(p, true).Position, arena.spawns[3], "a safe frame stands")
	eq(asks, 2, "returnFrame not consulted for a safe frame")
	-- A respawn the server orders (a drown's chosen pad, a boundary return) keeps its own frame.
	modeCtx.respawn("player:803", BattleRules.spawnCFrame(arena, 2))
	eq(respawns[#respawns].cf.Position, arena.spawns[2], "the server's choice stands")
	rec.lastCheckpointCF = BattleRules.spawnCFrame(arena, 1)
	modeCtx.respawn("player:803")
	eq(asks, 2, "returnFrame never consulted for a server-ordered respawn")
	eq(p:GetAttribute("LastRespawnAsked"), false, "stamped as server-ordered (always shielded)")
	-- A bot set down by the mode gets the respawn shield from the core.
	local botId: string? = nil
	for _, e in modeCtx.alive() do
		if not e.isPlayer then
			botId = e.id
			break
		end
	end
	check(botId ~= nil, "a bot in the field")
	table.clear(granted)
	modeCtx.respawn(botId :: string, BattleRules.spawnCFrame(arena, 3))
	eq(#granted, 1, "one respawn shield")
	eq(granted[1], botId, "on the bot")
	BattleCore.stop()
end)

------------------------------------------------------------------------------------------------------------------------

local passed, failed = 0, 0
for _, t in tests do
	table.clear(logs)
	local ok, err = pcall(t.fn)
	if ok and countLogs("WARN") > 0 then
		-- A mode or bot error is swallowed by BattleCore's guard in a live server; here it fails the case.
		ok, err = false, "warnings logged"
	end
	if ok then
		passed += 1
		print("  PASS " .. t.name)
	else
		failed += 1
		print("  FAIL " .. t.name .. "\n       " .. tostring(err))
		for _, line in logs do
			if string.find(line, "WARN", 1, true) then
				print("       | " .. line)
			end
		end
	end
end
print(string.format("battle_flow_spec: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
