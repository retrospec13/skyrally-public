--!strict
-- Arena bots for battle overlays (LAUNCH_PROGRESSION 2b: "player plus three bots"; since owner 2026-10-21 the field
-- is eight, BattleRules.FIELD; TEST_LIST_LAUNCH L71-L74).
-- Built like AIRacers bots (PlaneBuilder / CarBuilder models in workspace.Planes, anchored hull, CFrame-driven every
-- Heartbeat, server-authoritative), but free-roaming instead of route-following:
-- * Each step a bot asks the mode for a Goal (world.goal: a position, optionally an opponent to hunt) and steers
--   toward it with BattleRules.steerDirection (stay inside the play radius, keep apart from every other entrant).
-- * Planes keep `clearance` studs over the ground under them (down ray) and below the arena ceiling, and dodge walls
--   with a forward ray (climb and turn away). Cars sit on the ground under them (down ray) and treat water deeper
--   than world.maxWaterDepth as a wall: the terrain sea, and the mode's own water surface (world.waterLevel, the
--   water battle's tide) where it stands higher. Ground that rises steeper than CAR_CLIMB (a rock face, a hull side)
--   is a wall too. At a wall a car holds still and swings toward the open direction nearest its goal (escape probes),
--   and a car slows into tight turns so it does not swing a 43-stud arc off a sandbar.
-- * Items: a bot takes any ready battle pod it passes (ItemService.pickup, same ledger and cooldown as players) and
--   decides 4 times a second whether to fire what it holds (BattleRules.decideItem), aiming at its hunted opponent.
-- * Hits and item effects reach a bot through ItemService.setArena (BattleCore routes applyToBot here): a hit spins it
--   out (speed cut, barrel roll) for the stun; boost and magnet raise its speed.
-- Bot ids start at ID_BASE + 1 ("bot:101"), so they never collide with race roster ids even if a race bot lingered.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local BattleRules = require(Shared:WaitForChild("battle"):WaitForChild("BattleRules"))
local RaceScope = require(Shared:WaitForChild("RaceScope"))

local server = (script.Parent :: Instance).Parent :: Instance
local PlaneBuilder = require(server:WaitForChild("PlaneBuilder")) :: any
local CarBuilder = require(server:WaitForChild("kit"):WaitForChild("CarBuilder")) :: any
local RacerPaint = require(server:WaitForChild("kit"):WaitForChild("RacerPaint")) :: any
local BotDisguise = require(server:WaitForChild("kit"):WaitForChild("BotDisguise")) :: any

local BattleBots = {}

BattleBots.ID_BASE = 100

-- OURS tuning. Planes cruise a little under the player's base speed (110) so a player can run one down; cars under
-- the car's top speed (128) for the same reason.
local TUNE = {
	plane = { speed = 102, turnDeg = 80, pitchMaxDeg = 32, clearance = 9, separation = 28, pickup = 14, probe = 46 },
	car = { speed = 72, turnDeg = 95, pitchMaxDeg = 0, clearance = 0, separation = 16, pickup = 10, probe = 20 },
}
local HIT = PlaneConfig.AI_HIT
local UP = Vector3.new(0, 1, 0)
-- OURS (car bots). The down ray used to start 12 studs over the car and nothing else stopped it, so a car bot drove
-- up any rock face or the galleon's hull side in a few frames (ISLAND-2 Studio trace: 26.6 -> 42.9 in one 0.25 s
-- sample, then off the far side into the deep) and, parked under a gangway, saw the ramp 8 studs overhead as its
-- ground. Now the ray starts CAR_REACH_UP over the car; a solid face across the step (WALL_NORMAL_Y) stops it; one step
-- may rise at most CAR_KERB (the track curbs and the beached rowboat stand 0.8-1.0 proud of the sand and the grid
-- plans over them); and over the step plus CAR_LOOK studs beyond, ground may rise at most CAR_CLIMB per stud plus
-- CAR_STEP (the gangways climb 0.24; a rock face or hull side climbs far more), so it cannot creep up a slope a few
-- hundredths of a stud per frame either.
local CAR_REACH_UP = 4
local CAR_KERB = 1.3
local CAR_LOOK = 3
local CAR_CLIMB = 0.5
local CAR_STEP = 0.1
local WALL_NORMAL_Y = 0.6
-- OURS: a car already in water deeper than maxWaterDepth may always drive on to ground no lower than its own, and
-- through water up to DEPTH_SLACK deeper than where it is (flat sand varies by a few hundredths) while that stays under
-- CarConfig.WATER_SINK_DEPTH less SINK_KEEP. Without it a bot on a flat sandbar the step had made exactly 2.0 deep froze
-- (every neighbour 2.02) until the watchdog moved it.
local DEPTH_SLACK = 0.1
local SINK_KEEP = 0.08
-- OURS: a car bot's cruise is cut to CAR_TURN_SLOW when its goal lies behind it (full speed from dead ahead), braking
-- at CAR_TURN_BRAKE, which shrinks the ~43-stud cruise turn to ~13: chasing a pod or rival behind it at full speed
-- swung bots off the sandbars into the deep (Studio: a 35-stud swing onto 19.6 sand a second before a tide step).
-- Held at a wall (nearly stopped) it swings round CAR_PIVOT times faster toward the open side.
local CAR_TURN_SLOW = 0.3
local CAR_TURN_BRAKE = 6
local CAR_PIVOT = 1.8
local CAR_PIVOT_SPEED = 10
local ESCAPE_PROBE = 12 -- studs out the escape directions are probed
local ESCAPE_DIRS = 8
-- OURS: car bots steer round a dropped trap (theirs too) on their line: within TRAP_LOOK studs ahead and TRAP_LANE to
-- the side (a car turning at 95 deg/s needs ~0.6 s of warning to clear the 11-stud hit radius). They drove blind over
-- traps on the pod and patrol lines, and traps were most of the lives lost in the ISLAND-2 water battle (Studio: 6 of
-- 8 hits, 3 of them a bot's own trap seconds later).
local TRAP_LOOK = 60
local TRAP_LANE = 18 -- the trap's hit radius (11) plus a car's half width and some
local TRAP_PUSH = 2.5
-- OURS: its own traps (it knows where it dropped them) a car bot treats as a wall within TRAP_STOP studs: bots
-- chasing each other round a tight loop drove over the trap they had dropped one lap before (Studio: 2 of 9 hits).
local TRAP_STOP = 14

export type Bot = {
	id: number,
	racerId: string,
	name: string,
	slot: number,
	plane: Model,
	hull: BasePart,
	isCar: boolean,
	pos: Vector3,
	forward: Vector3,
	speed: number,
	baseSpeed: number,
	bank: number,
	-- Read by ItemService / ItemEffects exactly like an AIRacers bot.
	station: number,
	lap: number,
	finished: boolean,
	-- Battle state.
	out: boolean,
	stunTimer: number,
	stunTotal: number,
	boostTimer: number,
	boostSpeed: number,
	magnetTimer: number,
	magnetPull: number,
	heldColor: string?,
	heldSince: number,
	thinkTimer: number,
	avoidTimer: number,
	avoidDir: Vector3,
	probeTimer: number,
	groundY: number?,
	propAngle: number,
	spinner: BasePart?,
	blade1: BasePart?,
	blade2: BasePart?,
	attrTimer: number,
	boostState: string,
	spawnCF: CFrame,
	lastGoal: string,
	attack: string?, -- the racer id the mode's last Goal hunts (BattleCore's arena target aims this bot's shots at it)
}

export type Goal = {
	pos: Vector3,
	attack: string?, -- racer id it hunts: missiles and magnets aim at it
	reason: string?,
}

export type Pod = {
	name: string,
	part: BasePart,
	pos: Vector3,
	podType: string,
}

export type World = {
	arena: BattleRules.Arena,
	goal: (bot: Bot) -> Goal?,
	pods: () -> { Pod },
	-- Every entrant still in the battle (players and bots) with its live position.
	entrants: () -> { BattleRules.Candidate },
	-- Racer ids currently holding a red item (threat for the shield decision).
	missileHolders: () -> { [string]: boolean },
	-- Instances the bots' rays ignore besides vehicles and item fx (the mode's own visuals).
	ignore: { Instance },
	maxWaterDepth: number?,
	-- The mode's water surface height (the water battle's tide) when it has one; cars treat it like the terrain sea.
	waterLevel: (() -> number?)?,
	-- Seconds a bot holds a missile or trap before it may use it (the mode's botItemDelay; default 0).
	itemDelay: number?,
}

BattleBots.bots = {} :: { Bot }

-- The arena bots of the running scope (systems audit v32 T0-2): BattleBots.bots itself in the hub scope and on the
-- single-race path (unchanged); per group each RaceInstance's battle has its own list.
local function bots(): { Bot }
	if RaceScope.current() == RaceScope.DEFAULT then
		return BattleBots.bots
	end
	return RaceScope.state("BattleBots", function(): { Bot }
		return {}
	end)
end
BattleBots.list = bots

local rayFilterAt = -math.huge -- when the bots' ray exclude list was last rebuilt (params below)

------------------------------------------------------------------------------------------------------------------------
-- ItemService (lazy: it requires race modules inside its functions)
------------------------------------------------------------------------------------------------------------------------

local itemServiceModule: any = nil
local function itemService(): any
	if itemServiceModule == nil then
		local ok, mod = pcall(require, server:WaitForChild("ItemService") :: any)
		itemServiceModule = if ok then mod else false
	end
	return if itemServiceModule then itemServiceModule else nil
end

local function held(racerId: string): (string?, number)
	local IS = itemService()
	if not IS then
		return nil, 0
	end
	local ok, st = pcall(IS.getState, racerId)
	if ok and type(st) == "table" then
		return st.color, st.level or 0
	end
	return nil, 0
end

------------------------------------------------------------------------------------------------------------------------
-- Spawn / despawn
------------------------------------------------------------------------------------------------------------------------

local function planesFolder(): Folder
	local f = workspace:FindFirstChild("Planes")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Planes"
	nf.Parent = workspace
	return nf
end

function BattleBots.find(botId: number): Bot?
	for _, b in bots() do
		if b.id == botId then
			return b
		end
	end
	return nil
end

function BattleBots.findByRacerId(racerId: string): Bot?
	for _, b in bots() do
		if b.racerId == racerId then
			return b
		end
	end
	return nil
end

function BattleBots.despawn()
	rayFilterAt = -math.huge -- the next battle has its own visuals folder to exclude
	local IS = itemService()
	local svc = if IS then IS.active else nil
	for _, b in bots() do
		if svc and type(svc.removeRacer) == "function" then
			svc.removeRacer(b.racerId)
		end
		if b.plane.Parent then
			b.plane:Destroy()
		end
	end
	table.clear(bots())
end

-- count bots on seats `slots` (BattleRules.assignSlots), vehicle "plane" | "car". Roster names and colours are the
-- race roster's first entries, so a battle meets familiar rivals.
function BattleBots.spawn(count: number, slots: { number }, arena: BattleRules.Arena, vehicle: string): { Bot }
	BattleBots.despawn()
	local isCar = vehicle == "car"
	local tune = if isCar then TUNE.car else TUNE.plane
	for i = 1, count do
		local cfg: any = PlaneConfig.AI_BOTS[((i - 1) % #PlaneConfig.AI_BOTS) + 1]
		local id = BattleBots.ID_BASE + i
		local cf = BattleRules.spawnCFrame(arena, slots[i] or (#arena.spawns + i))
		-- Economy v3 phase 4: PlaneConfig.BOT_DISGUISE dresses the battle bots as players (username, outfit, livery, trail)
		local disguise = PlaneConfig.BOT_DISGUISE
		local shownName: string = cfg.name
		local look: any = nil
		local nameChecked = true
		if disguise then
			shownName, look, nameChecked = BotDisguise.deal(bots())
		end
		local name = if disguise then (if isCar then "Car_-" else "Plane_-") .. tostring(BattleBots.ID_BASE + i) else "AI_" .. (string.gsub(cfg.name, " ", "_"))
		local model: Model = if isCar
			then CarBuilder.createCar(name, cfg.color, cfg.accent, cf, true)
			else PlaneBuilder.createPlane(name, cfg.color, cfg.accent, cf, true)
		BotDisguise.setNames(model, shownName, cfg.name)
		RacerPaint.paintBot(model, cfg.name, if look then look.livery else nil)
		if look then
			BotDisguise.setLook(model, look)
		end
		model:SetAttribute("BotId", id)
		model:SetAttribute("BattleBot", true)
		model.Parent = planesFolder()
		local function part(n: string): BasePart?
			local p = model:FindFirstChild(n)
			return if p and p:IsA("BasePart") then p else nil
		end
		-- Roster pace spread (139..) scaled onto the arena cruise so the three bots are not identical.
		local paceScale = math.clamp((cfg.baseSpeed or 130) / 135, 0.9, 1.06)
		local bot: Bot = {
			id = id,
			racerId = "bot:" .. tostring(id),
			name = shownName,
			slot = slots[i] or (#arena.spawns + i),
			plane = model,
			hull = model.PrimaryPart :: BasePart,
			isCar = isCar,
			pos = cf.Position,
			forward = cf.LookVector,
			speed = 0,
			baseSpeed = tune.speed * paceScale,
			bank = 0,
			station = 0,
			lap = 1,
			finished = false,
			out = false,
			stunTimer = 0,
			stunTotal = 0,
			boostTimer = 0,
			boostSpeed = 0,
			magnetTimer = 0,
			magnetPull = 0,
			heldColor = nil,
			heldSince = 0,
			thinkTimer = 0.25 * i,
			avoidTimer = 0,
			avoidDir = Vector3.zero,
			probeTimer = 0,
			groundY = nil,
			propAngle = i * 1.1,
			spinner = part("PropSpinner"),
			blade1 = part("PropBlade1"),
			blade2 = part("PropBlade2"),
			attrTimer = 0,
			boostState = "None",
			spawnCF = cf,
			lastGoal = "",
			attack = nil,
		}
		table.insert(bots(), bot)
		if disguise and not nameChecked then
			BotDisguise.recheck(shownName, function(fresh: string)
				bot.name = fresh
				model:SetAttribute("BotName", fresh)
			end)
		end
	end
	print(string.format("[SkyRally][BATTLE] bots spawned count=%d vehicle=%s", count, vehicle))
	return bots()
end

-- Back to its seat, all timers cleared (battle restart without a respawn of the models).
function BattleBots.reset(bot: Bot)
	bot.pos = bot.spawnCF.Position
	bot.forward = bot.spawnCF.LookVector
	bot.speed = 0
	bot.out = false
	bot.finished = false
	bot.stunTimer, bot.stunTotal = 0, 0
	bot.boostTimer, bot.magnetTimer = 0, 0
	bot.heldColor = nil
	bot.attack = nil
	bot.hull.CFrame = bot.spawnCF
	bot.plane:SetAttribute("Stunned", false)
	bot.plane:SetAttribute("BattleOut", false)
end

------------------------------------------------------------------------------------------------------------------------
-- Effects (ItemService.setArena -> BattleCore -> here)
------------------------------------------------------------------------------------------------------------------------

-- Returns true when botId is an arena bot (the effect is then consumed here, applied or not).
function BattleBots.applyEffect(botId: number, effect: any): boolean
	local bot = BattleBots.find(botId)
	if not bot then
		return false
	end
	if bot.out or bot.finished or type(effect) ~= "table" then
		return true
	end
	local seconds = if type(effect.seconds) == "number" then effect.seconds else 0
	if effect.kind == "hit" then
		local s = math.clamp(if seconds > 0 then seconds else HIT.defaultStun, HIT.minStun, HIT.maxStun)
		bot.stunTimer = math.max(bot.stunTimer, s)
		bot.stunTotal = bot.stunTimer
		bot.boostTimer, bot.magnetTimer = 0, 0
		bot.plane:SetAttribute("Stunned", true)
		print(string.format("[SkyRally][BATTLE] hit bot=%s source=%s stun=%.2f", bot.name, tostring(effect.source), bot.stunTimer))
	elseif effect.kind == "boost" then
		bot.boostTimer = math.max(bot.boostTimer, seconds)
		bot.boostSpeed = math.max(if type(effect.speed) == "number" then effect.speed else PlaneConfig.BOOST_SPEED, bot.boostSpeed)
	elseif effect.kind == "magnet" then
		bot.magnetTimer = math.max(bot.magnetTimer, seconds)
		bot.magnetPull = if type(effect.pull) == "number" then math.max(0, effect.pull) else 30
	elseif effect.kind == "magnetEnd" then
		bot.magnetTimer = 0 -- magnet v2: contact with the target ends the pull
	end
	return true
end

-- Out of the battle (survival lives gone, or the battle is over): hovers / parks where it is, takes nothing.
function BattleBots.setOut(bot: Bot, out: boolean)
	bot.out = out
	bot.finished = out
	bot.plane:SetAttribute("BattleOut", out)
end

------------------------------------------------------------------------------------------------------------------------
-- Motion
------------------------------------------------------------------------------------------------------------------------

local rayParams: RaycastParams? = nil

-- One RaycastParams for every bot ray; its exclude list (vehicles, item fx, the mode's visuals, characters) is rebuilt
-- once a second, not per ray.
local function params(world: World): RaycastParams
	local rp = rayParams or RaycastParams.new()
	rayParams = rp
	local now = os.clock()
	if now - rayFilterAt < 1 then
		return rp
	end
	rayFilterAt = now
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.RespectCanCollide = false
	local list: { Instance } = { planesFolder() }
	local fx = workspace:FindFirstChild("SkyRallyItemFX")
	if fx then
		table.insert(list, fx)
	end
	for _, inst in world.ignore do
		table.insert(list, inst)
	end
	for _, p in game:GetService("Players"):GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	rp.FilterDescendantsInstances = list
	return rp
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Dropped traps (ItemEffects' visuals in the item fx folder, Kind "trap", Owner = racer id), rescanned at most every
-- 0.2 s.
type TrapSeen = { pos: Vector3, owner: string }
local trapCache: { TrapSeen } = {}
local trapCacheAt = -math.huge
local function trapPositions(now: number): { TrapSeen }
	if now - trapCacheAt < 0.2 then
		return trapCache
	end
	trapCacheAt = now
	table.clear(trapCache)
	local fx = workspace:FindFirstChild("SkyRallyItemFX")
	if fx then
		for _, m in fx:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Kind") == "trap" then
				table.insert(trapCache, { pos = m:GetPivot().Position, owner = tostring(m:GetAttribute("Owner")) })
			end
		end
	end
	return trapCache
end

-- The bot's own trap that `to` closes in on within TRAP_STOP (see there), or nil.
local function ownTrapAhead(bot: Bot, to: Vector3, now: number): Vector3?
	for _, tr in trapPositions(now) do
		if tr.owner == bot.racerId then
			local dTo = flat(tr.pos - to).Magnitude
			if dTo < TRAP_STOP and dTo < flat(tr.pos - bot.pos).Magnitude then
				return tr.pos
			end
		end
	end
	return nil
end

-- A sideways push off the traps on a car bot's line (see TRAP_LOOK), zero when its line is clear.
local function trapAvoid(pos: Vector3, forward: Vector3, now: number): Vector3
	local fwd = flat(forward)
	if fwd.Magnitude < 0.01 then
		return Vector3.zero
	end
	fwd = fwd.Unit
	local push = Vector3.zero
	for _, tr in trapPositions(now) do
		local rel = flat(tr.pos - pos)
		local ahead = rel:Dot(fwd)
		if ahead > 0 and ahead < TRAP_LOOK then
			local lateral = rel - fwd * ahead
			local side = lateral.Magnitude
			if side < TRAP_LANE then
				-- Away from the trap's side (a trap dead ahead: to the right).
				local away = if side > 0.5 then -lateral.Unit else fwd:Cross(UP).Unit
				push += away * (1 - side / TRAP_LANE) * TRAP_PUSH
			end
		end
	end
	return push
end

-- Ground under a point (nil past the reach) and the water surface above it (nil when dry). `solid` (car bots) counts
-- only colliding parts as ground, like the water battle's ground grid (Water groundParams): with every part counted, a
-- car bot rode up onto non-colliding pods, trigger volumes and foliage, so its ground disagreed with the grid it plans
-- on, and with the climb limit such a part became a wall it sat wedged at (ISLAND-2 Studio trace, arena centre).
local function probeGround(pos: Vector3, rp: RaycastParams, reachUp: number, reachDown: number, solid: boolean?): (number?, number?)
	rp.RespectCanCollide = solid == true
	rp.IgnoreWater = true
	local hit = workspace:Raycast(pos + UP * reachUp, -UP * (reachUp + reachDown), rp)
	rp.IgnoreWater = false
	local wet = workspace:Raycast(pos + UP * reachUp, -UP * (reachUp + reachDown), rp)
	rp.IgnoreWater = true
	rp.RespectCanCollide = false
	local waterY = if wet and wet.Material == Enum.Material.Water then wet.Position.Y else nil
	return if hit then hit.Position.Y else nil, waterY
end

local function stepTimers(bot: Bot, dt: number)
	bot.boostTimer = math.max(0, bot.boostTimer - dt)
	bot.magnetTimer = math.max(0, bot.magnetTimer - dt)
	if bot.stunTimer > 0 then
		bot.stunTimer = math.max(0, bot.stunTimer - dt)
		if bot.stunTimer == 0 then
			bot.plane:SetAttribute("Stunned", false)
		end
	end
end

local function neighbours(bot: Bot, list: { BattleRules.Candidate }): { Vector3 }
	local out: { Vector3 } = {}
	for _, c in list do
		if c.id ~= bot.racerId then
			table.insert(out, c.pos)
		end
	end
	return out
end

-- Where a car bot would stand at `to` (ground height), and whether `to` is a wall for it: a solid face across the
-- step, no ground, water over the ground deeper than maxWaterDepth (the terrain sea, or the mode's water level where
-- higher) unless the car is already that deep and it is not much deeper there (DEPTH_SLACK: a car caught by a rising
-- tide may still drive out), or ground rising steeper than CAR_CLIMB from hereGround.
local function carStep(from: Vector3, to: Vector3, hereGround: number, tide: number?, world: World, rp: RaycastParams): (number?, boolean)
	local step = flat(to - from)
	local dist = step.Magnitude
	if dist > 0.01 then
		rp.RespectCanCollide = true
		local face = workspace:Raycast(from, step.Unit * (dist + 2), rp)
		rp.RespectCanCollide = false
		if face and face.Normal.Y < WALL_NORMAL_Y then
			return nil, true
		end
	end
	local groundY, waterY = probeGround(to, rp, CAR_REACH_UP, 40, true)
	if not groundY then
		return nil, true
	end
	local surface = waterY
	if tide and (surface == nil or tide > surface) then
		surface = tide
	end
	local maxDepth = world.maxWaterDepth or CarConfig.WATER_SINK_DEPTH
	if surface then
		local depth, hereDepth = surface - groundY, surface - hereGround
		local deeper = depth > hereDepth
			and (depth > hereDepth + DEPTH_SLACK or depth > CarConfig.WATER_SINK_DEPTH - SINK_KEEP)
		if depth > maxDepth and deeper then
			return groundY, true
		end
	end
	if groundY - hereGround > CAR_KERB + CAR_CLIMB * dist then
		return groundY, true
	end
	if dist > 0.01 then
		rp.RespectCanCollide = true
		local beyond = to + step.Unit * CAR_LOOK
		local ahead = workspace:Raycast(beyond + UP * CAR_REACH_UP, -UP * (CAR_REACH_UP + 40), rp)
		rp.RespectCanCollide = false
		if ahead and ahead.Position.Y - hereGround > CAR_CLIMB * (dist + CAR_LOOK) + CAR_STEP then
			return groundY, true
		end
	end
	return groundY, false
end

-- Escape heading for a car bot held at a wall: of ESCAPE_DIRS directions, the open one (carStep from here) nearest
-- the direction of its goal; straight back when every probe is a wall.
local function escapeDir(bot: Bot, goalPos: Vector3, hereGround: number, tide: number?, world: World, rp: RaycastParams): Vector3
	local want = flat(goalPos - bot.pos)
	want = if want.Magnitude > 0.01 then want.Unit else flat(bot.forward).Unit
	local best: Vector3? = nil
	local bestDot = -math.huge
	for k = 0, ESCAPE_DIRS - 1 do
		local a = k / ESCAPE_DIRS * 2 * math.pi
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local _, blocked = carStep(bot.pos, bot.pos + dir * ESCAPE_PROBE, hereGround, tide, world, rp)
		if not blocked then
			local d = dir:Dot(want)
			if d > bestDot then
				best, bestDot = dir, d
			end
		end
	end
	return best or -flat(bot.forward).Unit
end

local function moveBot(bot: Bot, dt: number, world: World, goal: Goal, others: { Vector3 }, rp: RaycastParams)
	local tune = if bot.isCar then TUNE.car else TUNE.plane
	local arena = world.arena
	local desired = BattleRules.steerDirection(bot.pos, goal.pos, arena, others, tune.separation, bot.isCar)
	if bot.isCar then
		local push = trapAvoid(bot.pos, bot.forward, os.clock())
		if push.Magnitude > 0.01 and (desired + push).Magnitude > 0.01 then
			desired = (desired + push).Unit
		end
	end

	-- Walls: a forward probe a few times a second; on a hit, climb (planes) and turn away for a moment. A surface that
	-- faces down (a cavern roof, a rock lip) is passed under instead: climbing there would drive the plane into it.
	bot.probeTimer -= dt
	if bot.probeTimer <= 0 then
		bot.probeTimer = 0.15
		local look = if bot.isCar then flat(bot.forward) else bot.forward
		if look.Magnitude > 0.01 then
			rp.RespectCanCollide = bot.isCar -- a car meets solid walls only (see probeGround)
			local hit = workspace:Raycast(bot.pos, look.Unit * tune.probe, rp)
			rp.RespectCanCollide = false
			if hit and hit.Normal.Y < 0.7 then
				local away = flat(hit.Normal)
				if not bot.isCar and hit.Normal.Y < -0.3 then
					bot.avoidDir = (if away.Magnitude > 0.01 then away.Unit * 0.5 else Vector3.zero) - UP
				else
					bot.avoidDir = (if away.Magnitude > 0.01 then away.Unit else -look.Unit) + (if bot.isCar then Vector3.zero else UP * 0.8)
				end
				bot.avoidTimer = 0.7
			end
		end
	end
	if bot.avoidTimer > 0 then
		bot.avoidTimer -= dt
		local blended = desired + bot.avoidDir * 1.6
		if blended.Magnitude > 0.01 then
			desired = blended.Unit
		end
	end

	local turn = math.rad(tune.turnDeg) * dt * (if bot.stunTimer > 0 then 0.3 else 1)
	if bot.isCar and bot.stunTimer <= 0 and bot.speed < CAR_PIVOT_SPEED then
		turn *= CAR_PIVOT
	end
	local newForward = BattleRules.turnToward(bot.forward, desired, turn)
	if not bot.isCar then
		-- Limit the climb/dive angle so a plane never stands on its tail.
		local h = flat(newForward)
		local maxPitch = math.rad(tune.pitchMaxDeg)
		if h.Magnitude > 0.01 then
			local pitch = math.atan2(newForward.Y, h.Magnitude)
			pitch = math.clamp(pitch, -maxPitch, maxPitch)
			newForward = (h.Unit * math.cos(pitch) + UP * math.sin(pitch)).Unit
		end
	else
		newForward = if flat(newForward).Magnitude > 0.01 then flat(newForward).Unit else flat(bot.forward).Unit
	end
	-- Bank into the turn (planes), from the signed yaw change this step: a left turn (positive cross Y) rolls the left
	-- wing down, a positive roll about the nose axis, the same sign as the player's plane (FlightController).
	local yawRate = flat(bot.forward):Cross(flat(newForward)).Y / math.max(dt, 1e-3)
	bot.bank += (math.clamp(yawRate * 0.9, -0.9, 0.9) - bot.bank) * math.clamp(dt * 5, 0, 1)
	bot.forward = newForward

	local target = bot.baseSpeed
	local turning = false
	if bot.stunTimer > 0 then
		target = bot.baseSpeed * HIT.speedFactor
	else
		if bot.boostTimer > 0 then
			target = math.max(target, bot.boostSpeed * (if bot.isCar then 0.75 else 1))
		end
		if bot.magnetTimer > 0 then
			target += bot.magnetPull
		end
	end
	if bot.isCar then
		-- Slow into tight turns (see CAR_TURN_SLOW).
		local toGoal = flat(goal.pos - bot.pos)
		if toGoal.Magnitude > 1 then
			local dot = flat(bot.forward):Dot(toGoal.Unit)
			target *= CAR_TURN_SLOW + (1 - CAR_TURN_SLOW) * math.clamp((dot + 0.2) / 1.2, 0, 1)
			turning = dot < 0.7
		end
	end
	local rate = if target > bot.speed then 4 elseif bot.stunTimer > 0 then HIT.brakeRate elseif turning then CAR_TURN_BRAKE else 3
	bot.speed += (target - bot.speed) * math.clamp(dt * rate, 0, 1)

	local nextPos = bot.pos + bot.forward * (bot.speed * dt)
	if bot.isCar then
		local hereGround = bot.pos.Y - CarConfig.RIDE_HEIGHT
		local tide = if world.waterLevel then world.waterLevel() else nil
		local groundY, blocked = carStep(bot.pos, nextPos, hereGround, tide, world, rp)
		local trap = if blocked then nil else ownTrapAhead(bot, nextPos, os.clock())
		if trap then
			-- Its own trap ahead: hold and swing away from it.
			nextPos = bot.pos
			local away = flat(bot.pos - trap)
			bot.avoidDir = if away.Magnitude > 0.01 then away.Unit else -flat(bot.forward).Unit
			bot.avoidTimer = 0.8
			bot.speed *= 0.5
		elseif blocked then
			-- A wall (deep water or a climb) ahead: hold position and swing toward the open direction nearest the goal.
			nextPos = bot.pos
			if bot.avoidTimer <= 0.4 then
				bot.avoidDir = escapeDir(bot, goal.pos, hereGround, tide, world, rp)
			end
			bot.avoidTimer = 0.8
			bot.speed *= 0.5
		elseif groundY then
			nextPos = Vector3.new(nextPos.X, groundY + CarConfig.RIDE_HEIGHT, nextPos.Z)
		end
	else
		-- A plane treats a water surface as the floor too.
		local groundY, waterY = probeGround(nextPos, rp, 4, 160)
		local floorY = if groundY and waterY then math.max(groundY, waterY) else (groundY or waterY)
		if floorY then
			bot.groundY = floorY
			nextPos = Vector3.new(nextPos.X, math.max(nextPos.Y, floorY + tune.clearance), nextPos.Z)
		end
		if arena.ceiling < math.huge then
			nextPos = Vector3.new(nextPos.X, math.min(nextPos.Y, arena.ceiling - 6), nextPos.Z)
		end
	end
	-- Hard rim: never past the soft band (the steering pull normally turns them long before this).
	local d = BattleRules.horizontal(nextPos, arena.center)
	local rim = arena.returnRadius - 4
	if d > rim then
		local inward = flat(nextPos - arena.center).Unit * rim
		nextPos = Vector3.new(arena.center.X + inward.X, nextPos.Y, arena.center.Z + inward.Z)
	end
	bot.pos = nextPos
end

local function render(bot: Bot, dt: number)
	local spin = 0
	if bot.stunTimer > 0 and bot.stunTotal > 0 then
		local k = 1 - bot.stunTimer / bot.stunTotal
		spin = HIT.spinTurns * 2 * math.pi * (1 - (1 - k) * (1 - k))
	end
	local fwd = if bot.forward.Magnitude > 0.01 then bot.forward.Unit else Vector3.new(0, 0, -1)
	local goal: CFrame
	if bot.isCar then
		goal = CFrame.lookAt(bot.pos, bot.pos + fwd) * CFrame.Angles(0, spin, 0)
	else
		goal = CFrame.lookAt(bot.pos, bot.pos + fwd) * CFrame.Angles(0, 0, bot.bank + spin)
	end
	bot.hull.CFrame = bot.hull.CFrame:Lerp(goal, math.clamp(dt * 14, 0, 1))
	if not bot.isCar then
		bot.propAngle = (bot.propAngle + dt * 28) % (math.pi * 2)
		local hullCF = bot.hull.CFrame
		local spinner, b1, b2 = bot.spinner, bot.blade1, bot.blade2
		if spinner then
			spinner.CFrame = hullCF * CFrame.new(0, 0, -7.2) * CFrame.Angles(0, math.pi / 2, 0)
		end
		if b1 then
			b1.CFrame = hullCF * CFrame.new(0, 0, -7.25) * CFrame.Angles(0, 0, bot.propAngle)
		end
		if b2 then
			b2.CFrame = hullCF * CFrame.new(0, 0, -7.25) * CFrame.Angles(0, 0, bot.propAngle + math.pi * 0.5)
		end
	end
	local boosting = bot.stunTimer <= 0 and bot.boostTimer > 0
	local state = if boosting then "Standard" else "None"
	if state ~= bot.boostState then
		bot.boostState = state
		bot.plane:SetAttribute("BoostState", state)
	end
	bot.attrTimer -= dt
	if bot.attrTimer <= 0 then
		bot.attrTimer = 0.1
		bot.plane:SetAttribute("Speed", math.floor(bot.speed))
		if bot.isCar then
			bot.plane:SetAttribute("Steer", math.clamp(math.floor(-bot.bank * 20 + 0.5) / 20, -1, 1))
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------------------------------------------------------

local function tryPods(bot: Bot, world: World, now: number)
	local IS = itemService()
	if not IS or IS.active == nil then
		return
	end
	local reach = if bot.isCar then TUNE.car.pickup else TUNE.plane.pickup
	for _, pod in world.pods() do
		if pod.part.Parent and pod.part:GetAttribute("OnCooldown") ~= true and (pod.pos - bot.pos).Magnitude <= reach then
			local before = bot.heldColor
			local ok = IS.pickup(bot.racerId, pod.name)
			if ok then
				local color = held(bot.racerId)
				if color ~= before then
					bot.heldSince = now
				end
				bot.heldColor = color
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Line of sight (trap audit X-01): missiles stop at walls and pop on respawn bubbles, so a bot only fires one it can land
------------------------------------------------------------------------------------------------------------------------

local itemEffectsModule: any = nil
local function itemEffects(): any
	if itemEffectsModule == nil then
		local ok, mod = pcall(function(): any
			return (require :: any)(server:WaitForChild("kit"):WaitForChild("ItemEffects"))
		end)
		itemEffectsModule = if ok and type(mod) == "table" then mod else false
	end
	return if itemEffectsModule then itemEffectsModule else nil
end

local losParams: RaycastParams? = nil

-- One ray from the bot to its target through what a missile meets (ItemEffects' world sweep: solid parts and terrain;
-- never water, vehicles, item fx or characters). Ground the shot would skim (normal Y at or over SKIM_NORMAL_Y) does
-- not block; a rock face, a wall or the galleon's hull does.
local function clearShot(from: Vector3, to: Vector3, rp: RaycastParams): boolean
	local d = to - from
	local dist = d.Magnitude
	if dist < 1 then
		return true
	end
	local lp = losParams or RaycastParams.new()
	losParams = lp
	lp.FilterType = Enum.RaycastFilterType.Exclude
	lp.RespectCanCollide = true
	lp.IgnoreWater = true
	lp.FilterDescendantsInstances = rp.FilterDescendantsInstances
	local hit = workspace:Raycast(from, d, lp)
	if not hit then
		return true
	end
	local mod = itemEffects()
	local skim = if mod and type(mod.SKIM_NORMAL_Y) == "number" then mod.SKIM_NORMAL_Y else 0.7
	-- Only a surface on the line between the two counts (a ray reports nothing past its end).
	return hit.Normal.Y >= skim or (hit.Position - from).Magnitude >= dist - 1
end

-- True while the target's respawn protection runs on the live item engine (nil engine: unknown, so false).
local function protected(racerId: string): boolean
	local mod = itemEffects()
	local engine = if mod then mod.active else nil
	if not engine or type(engine.isImmune) ~= "function" then
		return false
	end
	local ok, immune = pcall(engine.isImmune, racerId)
	return ok and immune == true
end

local function think(bot: Bot, world: World, goal: Goal, now: number)
	local IS = itemService()
	if not IS or IS.active == nil then
		return
	end
	local color, level = held(bot.racerId)
	if color ~= bot.heldColor then
		bot.heldSince = now
	end
	bot.heldColor = color
	if not color or level <= 0 then
		return
	end
	local kind = ItemRules.KIND_OF[color :: ItemRules.Color]
	if not kind then
		return
	end
	if (kind == "missile" or kind == "trap") and now - bot.heldSince < (world.itemDelay or 0) then
		return
	end
	local entrants = world.entrants()
	local sense: BattleRules.ItemSense = { heldFor = now - bot.heldSince, magnetRange = ItemRules.PARAMS.magnet[1].range }
	local targetId = goal.attack
	if not targetId then
		targetId = BattleRules.nearestOpponent(bot.racerId, bot.pos, entrants)
	end
	local holders = world.missileHolders()
	for _, c in entrants do
		if c.id ~= bot.racerId then
			local to = c.pos - bot.pos
			local d = to.Magnitude
			if c.id == targetId then
				sense.targetDist = d
				sense.targetDot = if d > 0.01 then bot.forward:Dot(to / d) else 1
				if kind == "missile" then
					sense.clearShot = clearShot(bot.pos, c.pos, params(world))
					sense.targetProtected = protected(c.id)
				end
			end
			if d > 0.01 and bot.forward:Dot(to / d) < -0.3 and d < (sense.behindDist or math.huge) then
				sense.behindDist = d
			end
			if holders[c.id] and d < (sense.threatDist or math.huge) then
				sense.threatDist = d
			end
		end
	end
	local use, why = BattleRules.decideItem(kind, sense)
	if use then
		local ok, reason = IS.use(bot.racerId)
		print(string.format(
			"[SkyRally][BATTLE] item bot=%s use=%s why=%s target=%s dist=%s ok=%s%s",
			bot.name,
			kind,
			why,
			tostring(targetId),
			if sense.targetDist then string.format("%.0f", sense.targetDist) else "-",
			tostring(ok),
			if ok then "" else " reason=" .. tostring(reason)
		))
		bot.heldColor = held(bot.racerId)
	end
end

export type Phase = "countdown" | "running" | "over"

-- One Heartbeat for every arena bot. "countdown": sit on the seat; "over": hover / park where it is; "running": play.
function BattleBots.step(dt: number, world: World, phase: Phase)
	if #bots() == 0 then
		return
	end
	local now = os.clock()
	local rp = params(world)
	local entrants = world.entrants()
	for _, bot in bots() do
		if not bot.hull.Parent then
			continue
		end
		stepTimers(bot, dt)
		if phase ~= "running" or bot.out then
			-- Hover / park: stop where it is (on the seat during the countdown), a slow bob for planes.
			bot.speed = 0
			bot.attack = nil
			if phase == "countdown" and not bot.out then
				bot.pos = bot.spawnCF.Position
				bot.forward = bot.spawnCF.LookVector
			end
			local bob = if bot.isCar then Vector3.zero else UP * math.sin(now * 2 + bot.id) * 0.4
			local cf = CFrame.lookAt(bot.pos + bob, bot.pos + bob + bot.forward)
			bot.hull.CFrame = bot.hull.CFrame:Lerp(cf, math.clamp(dt * 6, 0, 1))
			continue
		end
		local goal: Goal = world.goal(bot) or { pos = world.arena.center, attack = nil, reason = "centre" }
		bot.attack = goal.attack
		local reason = goal.reason or "goal"
		if reason ~= bot.lastGoal then
			bot.lastGoal = reason
			bot.plane:SetAttribute("BattleGoal", reason)
		end
		moveBot(bot, dt, world, goal, neighbours(bot, entrants), rp)
		render(bot, dt)
		tryPods(bot, world, now)
		bot.thinkTimer -= dt
		if bot.thinkTimer <= 0 and bot.stunTimer <= 0 then
			bot.thinkTimer = 0.25
			think(bot, world, goal, now)
		end
	end
end

return BattleBots
