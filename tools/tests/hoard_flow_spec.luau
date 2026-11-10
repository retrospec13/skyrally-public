--!strict
-- Lune spec for the FOREST hoard battle end to end (TEST_LIST_LAUNCH L74): the REAL server/battle/BattleCore, BattleBots,
-- ItemService and modes/Hoard over the REAL FOREST-1 TrackData, with fakes for what needs Studio (instances, FlightServer
-- records, the item effects engine, saves, remotes, a flat grass world for raycasts). Heartbeat is driven by hand on a
-- fake server clock: registration, pods kept off the acorn anchors, acorns and tinted home rings, collecting along a
-- flight path, the carry cap, banking through the own ring only (burst, "+N"), hit drops that fall and can be taken,
-- the arena bots playing the objective on their own through Mode.botGoal (they collect and bank), first to 20, the cap,
-- a leaver's sack, and a clean stop.
-- Run: tools/tests/run_lune_tests.sh tools/tests/hoard_flow_spec.luau   (standalone: plain `lune run` also works)
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
-- Fake instances: names, parents, attributes, children, properties, PivotTo
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
	function methods.IsA(_self: any, c: string): boolean
		return c == className or (IS_A[className] ~= nil and IS_A[className][c] == true) or c == "Instance"
	end
	function methods.Destroy(self: any)
		self.Parent = nil
		data.__destroyed = true
		for _, c in table.clone(data.__children) do
			c:Destroy()
		end
	end
	function methods.PivotTo(_self: any, cf: any)
		data.__pivot = cf
	end
	function methods.GetPivot(_self: any): any
		return data.__pivot
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

local RunServiceStub: any = { Heartbeat = signal() }
function RunServiceStub.IsStudio(): boolean
	return true
end
function RunServiceStub.IsServer(): boolean
	return true
end

-- A flat grass field at GROUND_Y under the whole arena: straight-down rays hit it, every other ray is open sky.
local GROUND_Y = 66
local workspaceStub: any = newInstance("Folder", "Workspace")
local wsAttrs: { [string]: any } = {}
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
				local flatLen = math.sqrt(direction.X * direction.X + direction.Z * direction.Z)
				if direction.Y < 0 and flatLen < 1e-6 and origin.Y >= GROUND_Y and origin.Y + direction.Y <= GROUND_Y then
					return { Position = V3.new(origin.X, GROUND_Y, origin.Z), Normal = V3.new(0, 1, 0), Material = "Material.Grass" }
				end
				return nil
			end
		end
		return (workspaceStub :: any)[k]
	end,
})
local mapRoot = newInstance("Folder", "FOREST-1")
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
	return load("src/" .. ref .. ".luau")
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

-- task.delay runs on the fake clock (the deposit burst switches itself off).
local delayed: { { at: number, fn: () -> () } } = {}
local function runDelayed()
	local i = 1
	while i <= #delayed do
		local d = delayed[i]
		if clock.now >= d.at then
			table.remove(delayed, i)
			d.fn()
		else
			i += 1
		end
	end
end
local taskStub = {
	spawn = function(fn: any, ...: any)
		fn(...)
	end,
	defer = function(fn: any, ...: any)
		fn(...)
	end,
	delay = function(seconds: number, fn: any, ...: any)
		local args = table.pack(...)
		table.insert(delayed, { at = clock.now + seconds, fn = function()
			fn(table.unpack(args, 1, args.n))
		end })
	end,
	wait = function(): number
		return 0
	end,
}

load = function(rel: string): any
	if cache[rel] ~= nil then
		return cache[rel]
	end
	local ref = string.match(rel, "^src/(.*)%.luau$") or (string.match(rel, "^(.*)%.luau$") :: string)
	local dir = string.match(ref, "^(.*)/[^/]+$") or ""
	local parent = if dir == "" then serverFolder else folderRef(dir .. "/", nil)
	-- Nested folders get their real parents so script.Parent.Parent works (battle/modes -> battle -> server).
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
		task = taskStub,
		Vector3 = V3,
		CFrame = CF,
		Color3 = C3,
		Vector2 = roblox.Vector2,
		UDim2 = roblox.UDim2,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		NumberRange = roblox.NumberRange,
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

local FakeFlightServer: any = { records = {}, startOverride = nil }
-- Mirrors FlightServer.respawnAtLastCheckpoint: the battle's respawn guard (a frame outside the arena becomes the seat,
-- an out player is not respawned), then the LastRespawnClock stamp a mode reads.
local respawnStamp = 0
local respawns: { any } = {}
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
		player:SetAttribute("BattleFragments", 1)
		return "awarded", {}
	end,
}

local planes = newInstance("Folder", "Planes")
planes.Parent = workspaceStub

local forest = load("build/forest1/TrackData.luau")
local BattleRules = load("src/shared/battle/BattleRules.luau")
local HoardRules = load("src/shared/battle/HoardRules.luau")
local BattleCore = load("src/server/battle/BattleCore.luau")
local BattleBots = load("src/server/battle/BattleBots.luau")
local Hoard = load("src/server/battle/modes/Hoard.luau")

-- The mode state of the running battle, for assertions (BattleCore keeps it private).
local live: { ctx: any, st: any }? = nil
local realStart = Hoard.start
Hoard.start = function(ctx: any): any
	local st = realStart(ctx)
	live = { ctx = ctx, st = st }
	return st
end
local function S(): any
	local l = live
	assert(l, "no hoard state captured")
	return l.st
end

-- The effects engine BattleCore gets from the boot script: records setArena and routes hit() to the arena's onHit like
-- the real engine does for a landed hit.
local arenaRules: any = nil
local fakeEffects: any = {}
function fakeEffects.setArena(rules: any)
	arenaRules = rules
end
function fakeEffects.hit(victim: string, attacker: string, source: string, _stun: number, pos: any): string
	if arenaRules and arenaRules.onHit then
		arenaRules.onHit(victim, attacker, source, pos)
	end
	return "hit"
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
	player.Parent = PlayersStub
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
		runDelayed()
		RunServiceStub.Heartbeat:Fire(step)
		t += step
	end
end

-- Moves a player's hull through `points`, one Heartbeat per point.
local function fly(player: any, points: { any })
	local rec = FakeFlightServer.records[player]
	for _, p in points do
		rec.hull.Position = p
		heartbeat(1 / 30)
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
	table.clear(logs)
	table.clear(delayed)
	live = nil
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

local function toasts(player: any): { string }
	local out = {}
	for _, f in fired do
		if f.event == "BattleToast" and f.player == player then
			table.insert(out, f.data.text)
		end
	end
	return out
end

local function hasToast(player: any, needle: string): boolean
	for _, text in toasts(player) do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end

local function overlay(name: string): any
	local o = mapRoot:FindFirstChild("BattleOverlay")
	return o and o:FindFirstChild(name)
end

-- Bots sit still (out of play) so a case controls every acorn; the battle itself keeps running.
local function parkBots()
	for _, b in BattleBots.bots do
		b.out = true
	end
end

BattleCore.init({
	itemEffects = fakeEffects,
	trackData = function(): any
		return forest
	end,
	replay = function() end,
})

local battle = forest.modes.battle
local arena = BattleRules.arena(battle)
local anchors = battle.pickupAnchors
local function ringOf(i: number): any
	return HoardRules.ringFromPlan(battle.homeRings[i], i)
end

local function startWith(player: any, slot: number, goIn: number)
	resetWorld()
	seat(player, BattleRules.spawnCFrame(arena, slot))
	wsAttrs.RaceMode = "battle"
	wsAttrs.RaceGoTime = clock.now + goIn
	BattleCore.start(forest)
end

------------------------------------------------------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------------------------------------------------------

test("init registers the hoard mode by its kind", function()
	check(BattleCore.kinds().hoard, "hoard registered from battle/modes")
	check(BattleCore.kinds().survival, "survival still registered")
	eq(battle.kind, "hoard", "FOREST-1 battle kind")
end)

local pilot = newPlayer(101, "Pilot")

test("start: player on pad 2 + three bots; six weapon pods above every third anchor; 18 acorns; four tinted rings", function()
	startWith(pilot, 2, 3)
	eq(BattleCore.phase(), "countdown", "phase")
	eq(#BattleBots.bots, 3, "three arena bots")
	local pods = {}
	for _, c in boosts:GetChildren() do
		if string.sub(c.Name, 1, 10) == "BattlePod_" then
			table.insert(pods, c)
		end
	end
	eq(#pods, 6, "pods kept off the acorn anchors")
	for k, pod in pods do
		local a = anchors[k * 3]
		check((pod.Position - (a + V3.new(0, 22, 0))).Magnitude < 1e-3, "pod " .. k .. " rides anchor " .. k * 3)
	end
	eq(pods[1]:GetAttribute("PodType"), "Red", "level-one set: red first")
	eq(pods[5]:GetAttribute("PodType"), "Red", "level-one set cycles four colours (magnet retired): red again fifth")
	eq(#overlay("HoardAcorns"):GetChildren(), 18, "one acorn per anchor")
	local acorn = overlay("HoardAcorns"):FindFirstChild("Acorn_01")
	check(acorn:FindFirstChild("Nut") and acorn:FindFirstChild("Cap") and acorn:FindFirstChild("Glint"), "cap, nut, glint")
	local rings = overlay("HoardRings"):GetChildren()
	eq(#rings, 4, "four home rings")
	local colours = {}
	for i, r in rings do
		eq(r:GetAttribute("HomeRing"), i, "ring index")
		local rim = r:FindFirstChild("Rim_1")
		check(rim ~= nil and r:FindFirstChild("Beacon") ~= nil, "rim and beacon")
		colours[tostring(rim.Color)] = true
	end
	local distinct = 0
	for _ in colours do
		distinct += 1
	end
	eq(distinct, 4, "each seat's ring has its own tint")
	eq(rings[2]:GetAttribute("RingColour"), "RED", "pad 2 -> ring 2")
	eq(rings[2]:FindFirstChild("Core"):FindFirstChild("Owner"):FindFirstChild("TextLabel").Text, "HOME  PILOT", "owner label")
	eq(pilot:GetAttribute("BattleHud"), "GRAB ACORNS  -  YOUR HOME: RED RING", "objective line")
	eq(wsAttrs.BattleKind, "hoard", "BattleKind")
	eq(wsAttrs.BattleTitle, "HOARD", "plank title")
	eq(wsAttrs.BattleEndsAt, wsAttrs.RaceGoTime + 180, "3-minute cap from the plan's timeCapSeconds")
	check(countLogs("hoard start entrants=4 anchors=18 rings=4 carry=10 win=20") == 1, "start log")
end)

test("countdown: flying through an acorn before GO takes nothing", function()
	fly(pilot, { anchors[1] })
	eq(S().rules.entries["player:101"].carried, 0, "nothing before GO")
	FakeFlightServer.records[pilot].hull.Position = arena.spawns[2] -- back on the pad for GO
	heartbeat(3.1)
	eq(BattleCore.phase(), "running", "GO")
end)

test("collect: a fly-through takes the acorn (hidden, regrows on its timer); the HUD and board count it", function()
	parkBots()
	local before = anchors[2] + V3.new(0, 0, 30)
	fly(pilot, { before, anchors[2] + V3.new(0, 0, -30) }) -- a 60-stud hop straight through it
	local entry = S().rules.entries["player:101"]
	eq(entry.carried, 1, "swept through")
	local model = S().models[2]
	eq(model.Parent, nil, "taken acorn hidden")
	eq(pilot:GetAttribute("BattleHud"), "BANKED 0/20 - CARRY 1/10 - RED RING", "HUD")
	heartbeat(0.3)
	check(string.find(wsAttrs.BattleBoard, '"s":"0 +1"', 1, true) ~= nil, "board shows banked +carried")
	heartbeat(S().cfg.respawn)
	eq(model.Parent, overlay("HoardAcorns"), "regrown at its anchor")
end)

test("carry cap: ten at most; a full sack leaves acorns hanging and says so once", function()
	local entry = S().rules.entries["player:101"]
	local hops = {}
	for i = 3, 14 do
		table.insert(hops, anchors[i])
	end
	fly(pilot, hops)
	eq(entry.carried, 10, "capped")
	local hanging = 0
	for i = 3, 14 do
		if S().models[i].Parent ~= nil then
			hanging += 1
		end
	end
	eq(hanging, 3, "the last ones stay for someone else")
	check(hasToast(pilot, "SACK FULL - fly through your RED ring!"), "full toast")
	eq(pilot:GetAttribute("BattleHud"), "SACK FULL - FLY THROUGH THE RED RING", "HUD")
end)

test("foreign ring: flying a sack through ring 1 banks nothing and reminds the player which ring is theirs", function()
	local r1 = ringOf(1)
	fly(pilot, { r1.pos + r1.axis * 25, r1.pos - r1.axis * 25 })
	eq(S().rules.entries["player:101"].deposited, 0, "nothing banked")
	check(hasToast(pilot, "Not yours - your home is the RED ring"), "reminder")
end)

test("bank: through the own ring: +10, burst and '+10' over the ring, then the ring settles", function()
	local r2 = ringOf(2)
	fly(pilot, { r2.pos + r2.axis * 25, r2.pos - r2.axis * 25 })
	local entry = S().rules.entries["player:101"]
	eq(entry.deposited, 10, "banked")
	eq(entry.carried, 0, "sack empty")
	check(hasToast(pilot, "+10 BANKED  -  10/20"), "bank toast")
	local core = overlay("HoardRings"):GetChildren()[2]:FindFirstChild("Core")
	eq(core:FindFirstChild("DepositBurst").Enabled, true, "glint burst")
	eq(core:FindFirstChild("Owner"):FindFirstChild("TextLabel").Text, "+10", "+N over the ring")
	heartbeat(0.5)
	eq(core:FindFirstChild("DepositBurst").Enabled, false, "burst off")
	heartbeat(1.3)
	eq(core:FindFirstChild("Owner"):FindFirstChild("TextLabel").Text, "HOME  PILOT", "label back")
	eq(pilot:GetAttribute("BattleHud"), "BANKED 10/20  -  GRAB ACORNS", "HUD")
	check(countLogs("hoard bank Pilot +10 total=10/20 ring=2") == 1, "bank log")
end)

test("hit: half the sack (rounded up) drops, falls to the grass, and can be picked up again once landed", function()
	local entry = S().rules.entries["player:101"]
	entry.carried = 7
	local at = arena.center + V3.new(40, 60, 20)
	FakeFlightServer.records[pilot].hull.Position = at
	heartbeat(1 / 30)
	fakeEffects.hit("player:101", "bot:102", "missile", 1.2, at)
	eq(entry.carried, 3, "7 -> 3")
	eq(S().rules.entries["bot:102"].hitsLanded, 1, "attacker credited")
	check(hasToast(pilot, "HIT! You dropped 4 acorns"), "victim toast")
	local dropped = {}
	for _, m in overlay("HoardAcorns"):GetChildren() do
		if string.sub(m.Name, 1, 8) == "Dropped_" then
			table.insert(dropped, m)
		end
	end
	eq(#dropped, 4, "four dropped acorns in the world")
	-- Still falling: not takeable yet even by flying right through the spot.
	local loose = {}
	for _, a in S().rules.acorns do
		if a.anchor == nil then
			table.insert(loose, a)
		end
	end
	eq(#loose, 4, "four loose acorns")
	eq(loose[1].state, "falling", "falling")
	check(math.abs(loose[1].pos.Y - (GROUND_Y + 2.2)) < 1e-3, "they land on the grass (Vector3 is float32)")
	heartbeat(2)
	eq(loose[1].state, "ready", "landed")
	local pivot = dropped[1]:GetPivot()
	check(math.abs(pivot.Position.Y - (GROUND_Y + 2.2)) < 1e-3, "the model came to rest on the grass")
	-- Skim the grass over all four.
	local path = {}
	for _, a in loose do
		table.insert(path, a.pos + V3.new(0, 8, 0))
	end
	fly(pilot, path)
	eq(entry.carried, 7, "all four picked back up")
	for _, m in dropped do
		eq(m.Parent, nil, "taken dropped acorns are gone")
	end
end)

test("crash: a wreck beside the own ring respawning on its pad banks nothing (the respawn jump is not flight)", function()
	-- FOREST-1 lays each spawn pad on its home ring's axis, 40 studs toward the yard (traps_forest1 F1: the axis is
	-- the line home from the field), so a crash on the ring's run-out respawns the plane across the ring in a jump
	-- shorter than maxStep.
	local entry = S().rules.entries["player:101"]
	entry.carried = 5
	local r2 = ringOf(2)
	local out = V3.new(r2.pos.X - arena.center.X, 0, r2.pos.Z - arena.center.Z).Unit
	local wreck = r2.pos + out * 35
	fly(pilot, { wreck + out * 30, wreck })
	eq(entry.deposited, 10, "flying in beside the ring banks nothing")
	-- The crash tumbles in place for RESPAWN_DELAY (1 s), then the client puts the plane back on its pad.
	heartbeat(1)
	local pad = arena.spawns[2]
	check((pad - wreck).Magnitude < S().cfg.maxStep, "the respawn jump is shorter than maxStep")
	check(HoardRules.segmentDistance(wreck, pad, r2.pos) <= r2.radius + S().cfg.ringCore, "and crosses the ring")
	fly(pilot, { pad, pad + (arena.center - pad).Unit * 3 })
	eq(entry.deposited, 10, "the respawn jump banks nothing")
	eq(entry.carried, 5, "the sack is still full")
	-- Flying on from the pad sweeps again: straight through the own ring banks as usual.
	fly(pilot, { r2.pos + r2.axis * 25, r2.pos - r2.axis * 25 })
	eq(entry.deposited, 15, "a real pass banks after the respawn")
	entry.deposited = 10
end)

test("first to 20 banked wins: results, fragment award, records finished", function()
	local entry = S().rules.entries["player:101"]
	entry.carried = 10
	local r2 = ringOf(2)
	fly(pilot, { r2.pos - r2.axis * 25, r2.pos + r2.axis * 25 })
	eq(BattleCore.phase(), "over", "over at 20")
	local res = lastFired("BattleResults", pilot)
	check(res ~= nil, "results sent")
	eq(res.youWon, true, "victory")
	eq(res.title, "HOARD", "title")
	eq(res.reason, "first to 20 acorns banked", "reason")
	eq(res.rows[1].name, "Pilot", "winner first")
	eq(res.rows[1].text, "20 BANKED", "row text")
	eq(#res.rows, 4, "four rows")
	eq(res.award.result, "awarded", "fragment")
	eq(awards[1], "Pilot|battle|FOREST|battle_win:FOREST-1", "award args")
	eq(FakeFlightServer.records[pilot].finished, true, "record finished")
	BattleCore.stop()
	eq(mapRoot:FindFirstChild("BattleOverlay"), nil, "overlay removed with the battle")
end)

test("bots play the objective on their own: they collect, fly home and bank", function()
	local watcher = newPlayer(202, "Watcher")
	startWith(watcher, 1, 1)
	-- The player hangs high over the yard, out of everyone's way.
	FakeFlightServer.records[watcher].hull.Position = arena.center + V3.new(0, 150, 0)
	heartbeat(1.2)
	eq(BattleCore.phase(), "running", "running")
	local reasons: { [string]: boolean } = {}
	local firstBank: number? = nil
	local t = 0
	while t < 120 and BattleCore.phase() == "running" do
		heartbeat(0.5)
		t += 0.5
		for _, b in BattleBots.bots do
			local r = b.plane:GetAttribute("BattleGoal")
			if r then
				reasons[string.match(r, "^%a+")] = true
			end
			check(BattleRules.horizontal(b.pos, arena.center) <= arena.returnRadius, b.name .. " inside the boundary")
			check(b.pos.Y >= GROUND_Y + 8 and b.pos.Y <= arena.ceiling, b.name .. " between the grass and the ceiling")
		end
		if not firstBank and countLogs("hoard bank ") > 0 then
			firstBank = t
		end
	end
	local collected, banked = 0, 0
	for _, b in BattleBots.bots do
		local e = S().rules.entries[b.racerId]
		collected += e.collected
		banked += e.deposited
	end
	print(string.format("    | bots after %.0f s: collected=%d banked=%d first bank at %s s, goals seen: %s", t, collected, banked, tostring(firstBank), (function()
		local list = {}
		for k in reasons do
			table.insert(list, k)
		end
		table.sort(list)
		return table.concat(list, ",")
	end)()))
	check(reasons.acorn, "bots chase acorns")
	check(reasons.home, "bots fly home")
	check(collected >= 15, "bots collected at least 15 acorns (got " .. collected .. ")")
	check(banked >= 10, "bots banked at least 10 acorns (got " .. banked .. ")")
	check(firstBank ~= nil and firstBank <= 60, "a bot banked within the first minute")
	eq(S().rules.entries["player:202"].deposited, 0, "the idle player banked nothing")
	BattleCore.stop()
end)

test("the cap: most banked wins with the tie rule; nobody banked means no winner", function()
	local p = newPlayer(303, "Capper")
	startWith(p, 3, 1)
	parkBots()
	heartbeat(1.2)
	local e = S().rules.entries
	e["player:303"].deposited, e["player:303"].reachedAt, e["player:303"].carried = 9, 40, 3
	e["bot:101"].deposited, e["bot:101"].reachedAt = 9, 25
	S().rules.entries["bot:102"].deposited = 4
	-- A landed hit refreshes the board (bot:103 drops one of its two).
	e["bot:103"].carried = 2
	fakeEffects.hit("bot:103", "bot:102", "missile", 1.2, arena.center)
	heartbeat(0.3)
	local board = serde.decode("json", wsAttrs.BattleBoard)
	eq(board[1].n, BattleBots.bots[1].name, "the board shows bot:101 (reached 9 first) above the player's 9 +3")
	eq(board[2].n, "Capper", "then the player")
	wsAttrs.TriggerBattleEnd = true
	heartbeat(0.1)
	eq(BattleCore.phase(), "over", "QA end")
	local res = lastFired("BattleResults", p)
	eq(res.youWon, false, "bot:101 reached 9 first")
	eq(res.rows[1].name, BattleBots.bots[1].name, "bot:101 first")
	eq(res.rows[2].name, "Capper", "then the player")
	for i, row in res.rows do
		eq(row.name, board[i].n, "results row " .. i .. " matches the board at the end")
	end
	eq(res.rows[2].text, "9 BANKED", "row text")
	eq(res.reason, "ended early (QA) - ranked by acorns banked", "QA reason")
	eq(#awards, 0, "a loss awards nothing")
	-- Nobody banked by the cap.
	startWith(p, 3, 1)
	parkBots()
	heartbeat(1.2)
	clock.now = wsAttrs.BattleEndsAt - 0.01
	heartbeat(0.1)
	eq(BattleCore.phase(), "over", "the cap ended it")
	local none = lastFired("BattleResults", p)
	eq(none.winnerName, nil, "no winner")
	eq(none.reason, "time up - nobody banked an acorn", "cap reason")
	BattleCore.stop()
end)

test("a leaver forfeits and drops its sack where it was last seen; the other player plays on", function()
	resetWorld()
	local a = newPlayer(404, "Stayer")
	local b = newPlayer(505, "Leaver")
	seat(a, BattleRules.spawnCFrame(arena, 1))
	seat(b, BattleRules.spawnCFrame(arena, 4))
	wsAttrs.RaceMode = "battle"
	wsAttrs.RaceGoTime = clock.now + 1
	BattleCore.start(forest)
	eq(#BattleBots.bots, 2, "a second client takes a bot's seat")
	parkBots()
	heartbeat(1.2)
	local last = arena.center + V3.new(-60, 40, 30)
	FakeFlightServer.records[b].hull.Position = last
	heartbeat(1 / 30)
	S().rules.entries["player:505"].carried = 5
	S().rules.entries["player:505"].deposited = 12
	unseat(b)
	heartbeat(1 / 30)
	eq(S().rules.entries["player:505"].out, true, "out")
	local dropped = 0
	for _, acorn in S().rules.acorns do
		if acorn.anchor == nil then
			dropped += 1
			check(BattleRules.horizontal(acorn.pos, last) <= 14 + 1e-6, "dropped where it was last seen")
		end
	end
	eq(dropped, 5, "the whole sack")
	heartbeat(0.3)
	check(string.find(wsAttrs.BattleBoard, '"s":"LEFT"', 1, true) ~= nil, "board shows the leaver")
	eq(BattleCore.phase(), "running", "the battle goes on for the stayer")
	wsAttrs.TriggerBattleEnd = true
	heartbeat(0.1)
	local res = lastFired("BattleResults", a)
	eq(res.rows[#res.rows].name, "Leaver", "the leaver ranks last despite 12 banked")
	BattleCore.stop()
end)

test("bot goals: home with a full sack (aimed on the ring axis), raid a rich carrier with a missile, acorn otherwise", function()
	local p = newPlayer(606, "Target")
	startWith(p, 2, 1)
	heartbeat(1.2)
	local l = live :: any
	local bot = l.ctx.byId["bot:101"]
	local entry = S().rules.entries["bot:101"]
	local goal = Hoard.botGoal(l.ctx, S(), bot)
	eq(goal.reason == "acorn" or goal.reason == "wide turn" or goal.reason == "pod", true, "empty sack: acorn or pod (" .. goal.reason .. ")")
	entry.carried = 10
	local home = Hoard.botGoal(l.ctx, S(), bot)
	check(home.reason == "home full" or home.reason == "wide turn", "full sack flies home (" .. home.reason .. ")")
	local ring = S().rules.rings[entry.ring]
	if home.reason == "home full" then
		local off = home.pos - ring.pos
		check((off - ring.axis * off:Dot(ring.axis)).Magnitude < 1e-3, "aim point on the ring axis")
	end
	entry.carried = 2
	-- The player carries 6 near the bot, and the bot holds a missile.
	S().rules.entries["player:606"].carried = 6
	FakeFlightServer.records[p].hull.Position = bot.bot.pos + V3.new(0, 0, -150)
	local ItemService = load("src/server/ItemService.luau")
	local realState = ItemService.getState
	ItemService.getState = function(id: string): any
		if id == "bot:101" then
			return { color = "red", level = 1 }
		end
		return realState(id)
	end
	local raid = Hoard.botGoal(l.ctx, S(), bot)
	ItemService.getState = realState
	eq(raid.attack, "player:606", "the missile aims at the rich carrier")
	check(raid.reason == "raid" or raid.reason == "wide turn", "raid (" .. raid.reason .. ")")
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
print(string.format("hoard_flow_spec: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
