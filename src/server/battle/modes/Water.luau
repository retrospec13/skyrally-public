--!strict
-- ISLAND-BATTLE water battle (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L73) on the ISLAND-2 cove overlay: the beach
-- shallows, the sandbars and the galleon decks and gangways (car vs seven bots: a field of eight, BattleRules.FIELD).
-- Shallow water is drivable (the car's own WATER_SINK_DEPTH rule); the tide rises in the plan's three timed steps and
-- closes the low sand, so the dry area shrinks toward the beach crest and the decks.
--
-- Lives and items are SNOW survival composed, not copied: the Survival mode seats the field and runs every landed item
-- hit (lives, toasts, out, last standing), its resolve() builds every result, and SurvivalRules counts the lives. On
-- top of it this mode owns the tide (rules in shared/battle/WaterRules, specced under Lune):
-- * Water: a translucent water plane over the arena (ctx.folder, CanQuery off so no car, bot or item ray ever lands on
--   it) follows WaterRules.levelAt; hidden at the base level (the terrain sea is there), it fades in with the first
--   step. Warn / rise / settled toasts per step; the settled one gives the dry share left (the log line too).
-- * Drowning: every Heartbeat each car still in play is checked against the tide: car bottom (hull minus ride height)
--   deeper than drownDepth = a life lost to the tide (WaterRules.drown, credits nobody, a shield does not help), then a
--   respawn on a safe pad with a short immunity (trap audit G1, WaterRules.pickSafeSpawn): dry through the coming step,
--   never the deck pad (a player put back on the galleon was the owner's "teleported back onto the ship"), at least
--   SAFE_CLEAR from where it went under and away from live rivals, so bots no longer stack on one pad. It faces the
--   pad's authored heading (spawnLooks) or the longest dry run, whichever a car-sized Blockcast finds clear of masts and
--   rails. The last life lost is out (the car stays where it sank). The client still drowns a car
--   in the deep terrain sea on its own (fade, RequestRespawn); the server sees the same car sink and counts that life
--   once, and both answers name the same dry pad, since ctx.respawn sets the record's checkpoint the client's own
--   request is answered with.
-- * Wedged bots: BattleBots holds a car bot still at a wall (water deeper than maxWaterDepth under the tide this mode
--   reports through waterLevel, a climb, a solid face) and swings it toward open ground, but a bot boxed in by the
--   flood can still freeze. An arena bot that stays put for WaterRules.STUCK_SECONDS (not stunned) is set down on a
--   dry beach pad away from where it froze, no life lost, with the tide immunity.
-- * Ground: at the start the arena out to its boundary band (where bots still roam before the edge pull turns them)
--   is raycast once on a 6-stud grid (about 2700 rays on ISLAND-2) plus the spawn pads and pods, for the dry share,
--   the bots' dry-path checks and the respawn heading (a tide respawn faces the longest dry run from its pad, not the
--   arena centre across the flood).
-- * Boundary return (BattleCore returnFrame hook, trap audit I2-05): a car past the boundary band comes back on the
--   safe pad nearest where it left (never the decks, never ground the coming step floods), with the tide immunity.
-- * Doomed pods (I2-06): at each step's warning, every pod on ground that step will flood sinks into the sand and is
--   gone, so no glowing pod lures a kid onto ground that drowns him.
-- * HUD: "LIVES n  -  TIDE k/3 IN m:ss" with a HIGH GROUND! nudge when the ground under the player goes under at the
--   coming step; the board shows lives (as SNOW).
-- * Bots: WaterRules.botGoal (flee the tide, pods on dry ground, hunt on dry ground, patrol dry ground; beach ground
--   only at launch, the decks are the players' high ground; a human rival weighed closer), a decision kept THINK
--   seconds; a hunt follows its rival and a gangway trip (a bot already high on a ramp) refreshes its waypoint every
--   frame. Bots hold a missile or trap botItemDelay seconds before using it, and an item hit inside LIFE_GRACE of a
--   life lost costs nothing, so the tide, not the bots' crossfire, decides most battles. A beach bot never locks a
--   human on the decks, and a bot locks a given human at most once per WaterRules.HUMAN_SHOT_GAP (I2-07: the deck was
--   a shooting gallery), through botGoal's attack and BattleCore's targetable / locked hooks.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local battleShared = Shared:WaitForChild("battle")
local BattleRules = require(battleShared:WaitForChild("BattleRules"))
local SurvivalRules = require(battleShared:WaitForChild("SurvivalRules"))
local WaterRules = require(battleShared:WaitForChild("WaterRules"))
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local BattleCore = require(script.Parent.Parent.BattleCore)
local Survival = require(script.Parent.Survival)

type Ctx = BattleCore.Ctx
type Entrant = BattleCore.Entrant
type Result = BattleCore.Result

type SurvivalState = { rules: SurvivalRules.State }

type Plan = {
	goal: WaterRules.Goal,
	untilT: number, -- os.clock when the bot decides again
}

type State = {
	survival: SurvivalState,
	tide: WaterRules.Tide,
	course: WaterRules.Course,
	watch: WaterRules.Watch,
	motion: WaterRules.Motion,
	spawnGround: { number },
	deckPads: { [number]: boolean }, -- pads on the galleon decks (arena bots respawn elsewhere)
	podGround: { [string]: number },
	water: BasePart,
	level: number,
	lastT: number,
	hudTimer: number,
	plans: { [string]: Plan },
	ride: number,
	over: boolean,
	frames: { [string]: CFrame }, -- respawn frame per "pad|level|bot" (headings are checked with a Blockcast once)
	sinking: { Sink }, -- doomed pods going under
	sunk: { [string]: boolean }, -- pod names the tide has taken
	locks: { [string]: number }, -- "bot id|human id" -> elapsed time the bot last locked that human
}

type Sink = {
	name: string,
	part: BasePart,
	t0: number, -- os clock when it started to go under
	parts: { { part: BasePart, cf: CFrame } },
}

local Water = {}

Water.kind = "water"
Water.title = "WATER BATTLE"
Water.podTypes = Survival.podTypes -- item combat as SNOW: red, green, yellow at level one
-- Car bots treat water deeper than this as a wall (2.0, under the 2.2 drown depth), the tide included (waterLevel).
Water.maxWaterDepth = WaterRules.WALL_DEPTH
-- OURS: a bot holds a missile or trap this long before it uses it (BattleBots world.itemDelay). Firing the moment it
-- picked one up, three bots that chase pods and each other emptied each other's 3 lives in 20-60 s (Studio: one was
-- out at 17.5 s), so the battle was over long before the tide mattered; a human fires when he likes. 6 s still let
-- two bots go out by ~98 s in one Studio run.
Water.botItemDelay = 9
-- OURS: an item hit inside this many seconds after the victim lost a life (to an item or the tide) costs nothing: the
-- ItemEffects immunity is only stun + 0.4 s, and a bot stunned in a convoy took a second trap or missile while still
-- spinning (two lives in ~3 s, Studio); 4 s still let a convoy take a bot's three lives inside ~20 s.
local LIFE_GRACE = 6

local GRID_CELL = 6 -- studs between ground samples
local GRID_PAD = 12 -- sample past the play radius (bots skirt it before the edge pull turns them) ...
-- ... and at least out to the boundary band: past the grid every bot path check fails (unknown ground).
local THINK = 0.3 -- seconds a bot keeps a decision
local HUD_EVERY = 0.25
local RUNWAY = 60 -- studs of dry run a respawned car is pointed along
local PAD_MATCH = 6 -- a respawn frame within this many studs (flat) of a pad is that pad's (Water.frameSafe)
local LAND_ABOVE = 24 -- the dry share counts land up to this far over the base level (decks yes; cliff tops, masts no)
local WATER_THICK = 0.4
local WATER_ALPHA = 0.45 -- transparency of the risen water
local WATER_COLOR = Color3.fromRGB(47, 182, 196) -- a shade deeper than the plan's sea (#36c9d3)
local SINK_SECONDS = 1.6 -- a doomed pod slides into the sand over this long at its step's warning ...
local SINK_DEPTH = 7 -- ... this far, then it is gone
-- A respawn heading must leave this run clear of collidable parts in front of the car (trap audit I2-04: the deck
-- respawn faced the main mast 5.8 studs ahead): a Blockcast of the car's box, lifted off the ground, terrain excluded
-- (dryHeading already keeps to ground a car can climb).
local CLEAR_AHEAD = 12
local CAR_BOX = Vector3.new(6.3, 2, 10.5)
local BOX_LIFT = 2.6 -- box centre over the pad's ground: from 1.6 to 3.6, over a kerb, under the deck rails' tops

------------------------------------------------------------------------------------------------------------------------
-- Ground and water
------------------------------------------------------------------------------------------------------------------------

-- Solid ground only: vehicles, characters, item fx and this battle's own visuals are skipped; non-colliding decor
-- (sails, ropes, pods) too. The sea is ignored (the bed is the ground).
local function groundParams(ctx: Ctx): RaycastParams
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.RespectCanCollide = true
	rp.IgnoreWater = true
	local list: { Instance } = { ctx.folder }
	for _, name in { "Planes", "SkyRallyItemFX", "SkyRallyVfx" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	rp.FilterDescendantsInstances = list
	return rp
end

local function groundAt(rp: RaycastParams, x: number, z: number, top: number, depth: number): number?
	local hit = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -depth, 0), rp)
	return if hit then hit.Position.Y else nil
end

local function waterFrame(center: Vector3, level: number): CFrame
	-- A cylinder's axis is its X: lay it flat, top face at the water level.
	return CFrame.new(center.X, level - WATER_THICK / 2, center.Z) * CFrame.Angles(0, 0, math.pi / 2)
end

-- Hidden at the base level (the terrain sea is the water there), fading in over the first step's climb.
local function waterTransparency(tide: WaterRules.Tide, level: number): number
	local first = tide.steps[1]
	if not first or level <= tide.base + 0.01 then
		return 1
	end
	local k = math.clamp((level - tide.base) / math.max(first.level - tide.base, 0.01), 0, 1)
	return 1 - (1 - WATER_ALPHA) * k
end

local function buildWater(ctx: Ctx, tide: WaterRules.Tide): BasePart
	local p = Instance.new("Part")
	p.Name = "TideWater"
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Glass
	p.Color = WATER_COLOR
	p.Transparency = 1
	local d = ctx.arena.returnRadius * 2
	p.Size = Vector3.new(WATER_THICK, d, d)
	p.CFrame = waterFrame(ctx.arena.center, tide.base)
	p:SetAttribute("TideLevel", tide.base)
	p.Parent = ctx.folder
	return p
end

local function placeWater(ctx: Ctx, st: State)
	st.water.CFrame = waterFrame(ctx.arena.center, st.level)
	st.water.Transparency = waterTransparency(st.tide, st.level)
	st.water:SetAttribute("TideLevel", math.floor(st.level * 100 + 0.5) / 100)
end

local function share(st: State, ctx: Ctx, level: number): (number, number, number)
	local grid = st.course.grid
	if not grid then
		return 0, 0, 0
	end
	local dry, total = WaterRules.dryShare(grid, level, st.tide.drownDepth, ctx.arena.radius, st.tide.base + LAND_ABOVE)
	return math.floor(100 * dry / math.max(total, 1) + 0.5), dry, total
end

------------------------------------------------------------------------------------------------------------------------
-- HUD, board, end
------------------------------------------------------------------------------------------------------------------------

local function refreshBoard(ctx: Ctx, st: State)
	local rules = st.survival.rules
	for _, e in ctx.entrants do
		if not e.spectator then
			ctx.setScore(e.id, SurvivalRules.livesOf(rules, e.id), SurvivalRules.scoreText(rules, e.id))
		end
	end
end

local function refreshHud(ctx: Ctx, st: State, t: number)
	local rules = st.survival.rules
	local tideText = WaterRules.tideText(st.tide, math.max(t, 0))
	for _, e in ctx.entrants do
		if not e.spectator then
			local lives = SurvivalRules.livesOf(rules, e.id)
			if lives > 0 and not e.out then
				local pos = ctx.position(e.id)
				local danger = pos ~= nil and t >= 0 and WaterRules.inDanger(st.tide, t, pos.Y - st.ride)
				ctx.setHud(e.id, WaterRules.hudText(lives, tideText, danger))
			else
				ctx.setHud(e.id, "OUT - spectating")
			end
		end
	end
end

-- Ends the battle once SurvivalRules says so (last car with lives, or every player out); the result is Survival's.
local function checkEnd(ctx: Ctx, st: State)
	if st.over then
		return
	end
	local outcome = SurvivalRules.checkEnd(st.survival.rules, true)
	if outcome.over then
		st.over = true
		ctx.log("water over reason=%s winner=%s", outcome.reason, tostring(outcome.winner))
		ctx.finish(Survival.resolve(ctx, st.survival, outcome.reason))
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Tide
------------------------------------------------------------------------------------------------------------------------

local function announce(ctx: Ctx, st: State, ev: WaterRules.TideEvent)
	local s = ev.step
	local total = #st.tide.steps
	if ev.kind == "warn" then
		ctx.log("water tide warn step=%d/%d in=%.0f level=%.1f", s.step, total, s.at - ev.at, s.level)
		ctx.toast(nil, string.format("TIDE %d/%d IN %d - HEAD FOR HIGH GROUND", s.step, total, math.floor(s.at - ev.at + 0.5)), "bad")
	elseif ev.kind == "rise" then
		ctx.log("water tide step=%d/%d rising %.1f -> %.1f over %.0fs", s.step, total, st.level, s.level, st.tide.rise)
		ctx.toast(nil, string.format("TIDE %d/%d RISING - THE LOW SAND IS GOING UNDER", s.step, total), "info")
	elseif ev.kind == "settled" then
		local pct, dry, cells = share(st, ctx, s.level)
		ctx.log("water tide step=%d/%d level=%.1f dry=%d%% (%d/%d cells)", s.step, total, s.level, pct, dry, cells)
		ctx.toast(nil, string.format("TIDE %d/%d IS UP - DRY LAND LEFT %d%%", s.step, total, pct), "info")
	end
end

-- Whether a car set down at `p` (ground `ground`) facing `dir` has CLEAR_AHEAD studs free of collidable parts. A
-- Blockcast that cannot run (no physics world, as under the Lune spec) counts as clear.
local function headingClear(ctx: Ctx, p: Vector3, ground: number, dir: Vector3): boolean
	local origin = Vector3.new(p.X, ground + BOX_LIFT, p.Z)
	local rp = groundParams(ctx)
	local ok, hit = pcall(function(): any
		local list = rp.FilterDescendantsInstances
		table.insert(list, workspace.Terrain)
		rp.FilterDescendantsInstances = list
		return workspace:Blockcast(CFrame.lookAt(origin, origin + dir), CAR_BOX, dir * CLEAR_AHEAD, rp)
	end)
	return not ok or hit == nil
end

-- Pad `slot` facing its authored heading (the plan's spawnLooks) while dry ground runs along it, else the longest dry
-- run from it at `level` (WaterRules.respawnHeadings); the first heading with CLEAR_AHEAD free of walls wins (the
-- best by run when none is). An arena bot plans over beach only. Cached per pad, level and kind.
local function respawnFrame(ctx: Ctx, st: State, slot: number, level: number, bot: boolean): CFrame
	local grid = st.course.grid
	if not grid then
		return BattleRules.spawnCFrame(ctx.arena, slot)
	end
	local key = string.format("%d|%.2f|%s", slot, level, if bot then "bot" else "car")
	local cached = st.frames[key]
	if cached then
		return cached
	end
	local p = BattleRules.spawnPosition(ctx.arena, slot)
	local course = st.course
	local skip = if bot and not course.board
		then function(x: number, z: number, h: number): boolean
			return WaterRules.offBeach(course, x, z, h)
		end
		else nil
	local look = ctx.arena.looks and ctx.arena.looks[slot]
	local dirs = WaterRules.respawnHeadings(grid, p, level, st.tide.drownDepth, RUNWAY, ctx.arena.center, skip, look)
	local ground = st.spawnGround[slot] or (p.Y - 4)
	local dir = dirs[1]
	for _, d in dirs do
		if headingClear(ctx, p, ground, d) then
			dir = d
			break
		end
	end
	local frame = CFrame.lookAt(p, p + dir)
	st.frames[key] = frame
	return frame
end

-- Live rivals' positions for the safe-spawn choice (everyone in play but `id`).
local function rivalsOf(ctx: Ctx, id: string): { Vector3 }
	local out: { Vector3 } = {}
	for _, e in ctx.alive() do
		if e.id ~= id then
			local p = ctx.position(e.id)
			if p then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- The tide level a respawn is judged at: the coming step settled (rise plus its warning), so a car is never set down
-- on ground the step that is about to be announced floods.
local function respawnLevel(st: State, t: number): number
	return WaterRules.levelAhead(st.tide, t, st.tide.rise + WaterRules.WARN_SECONDS)
end

local function drown(ctx: Ctx, st: State, e: Entrant, pos: Vector3, depth: number, t: number)
	local rules = st.survival.rules
	local lost, out = WaterRules.drown(rules, e.id, t)
	if not lost then
		return
	end
	local lives = SurvivalRules.livesOf(rules, e.id)
	-- Players and bots alike: never the decks (G1), never back where it sank, away from the rivals.
	local ahead = respawnLevel(st, t)
	local slot = WaterRules.pickSafeSpawn(ctx.arena.spawns, st.spawnGround, ahead, st.tide.drownDepth, {
		avoid = st.deckPads,
		from = pos,
		rivals = rivalsOf(ctx, e.id),
	})
	ctx.log(
		"water drown %s (%s) at=(%.0f,%.1f,%.0f) level=%.2f depth=%.2f lives=%d%s",
		e.name,
		e.id,
		pos.X,
		pos.Y,
		pos.Z,
		st.level,
		depth,
		lives,
		if out then " OUT" else string.format(" respawn=pad%d", slot or e.slot)
	)
	st.plans[e.id] = nil
	WaterRules.resetMotion(st.motion, e.id)
	if out then
		-- A player's car is set down on a dry pad before going out: nothing respawns a spectator's car, and one left in
		-- the tide sank through the sea bed (Studio probe: y -494).
		if e.isPlayer and slot then
			ctx.respawn(e.id, respawnFrame(ctx, st, slot, ahead, false))
		end
		ctx.eliminate(e.id, "drowned")
		ctx.toast(nil, string.format("%s is OUT", e.name), "info")
		ctx.toast(e.id, "THE TIDE TOOK YOUR LAST LIFE - spectating", "bad")
	else
		ctx.toast(e.id, string.format("SWAMPED! %d %s left", lives, if lives == 1 then "life" else "lives"), "bad")
		ctx.respawn(e.id, if slot then respawnFrame(ctx, st, slot, ahead, not e.isPlayer) else nil)
	end
	refreshBoard(ctx, st)
	refreshHud(ctx, st, t)
	checkEnd(ctx, st)
end

-- A wedged arena bot (see the header): onto a safe beach pad that stays dry through the look-ahead, at least
-- UNSTICK_CLEAR from where it froze and away from the rivals (pickSafeSpawn); no life lost, immune to the tide while
-- the move settles, a fresh decision.
local function unstick(ctx: Ctx, st: State, e: Entrant, pos: Vector3, t: number)
	local avoid: { [number]: boolean } = table.clone(st.deckPads)
	for i, s in ctx.arena.spawns do
		if BattleRules.horizontal(s, pos) < WaterRules.UNSTICK_CLEAR then
			avoid[i] = true
		end
	end
	local ahead = WaterRules.levelAhead(st.tide, t, WaterRules.LOOKAHEAD)
	local slot = WaterRules.pickSafeSpawn(ctx.arena.spawns, st.spawnGround, ahead, st.tide.drownDepth, {
		avoid = avoid,
		from = pos,
		rivals = rivalsOf(ctx, e.id),
	})
	local plan = st.plans[e.id]
	ctx.log(
		"water unstick %s (%s) at=(%.0f,%.1f,%.0f) goal=%s after=%.0fs -> pad%d",
		e.name,
		e.id,
		pos.X,
		pos.Y,
		pos.Z,
		if plan then plan.goal.reason else "none",
		WaterRules.STUCK_SECONDS,
		slot or e.slot
	)
	st.plans[e.id] = nil
	WaterRules.shield(st.watch, e.id, t + WaterRules.IMMUNE)
	WaterRules.resetMotion(st.motion, e.id)
	ctx.respawn(e.id, if slot then respawnFrame(ctx, st, slot, ahead, true) else nil)
end

------------------------------------------------------------------------------------------------------------------------
-- Doomed pods (trap audit I2-06)
------------------------------------------------------------------------------------------------------------------------

-- At a step's warning: every pod whose ground that step floods starts to sink (marked Sinking at once, so bots and the
-- pod-taken path drop it), slides SINK_DEPTH into the sand over SINK_SECONDS and is destroyed.
local function sinkDoomed(ctx: Ctx, st: State, level: number)
	local dd = st.tide.drownDepth
	for _, pod in ctx.pods() do
		local ground = st.podGround[pod.name]
		local part = pod.part
		if ground and not st.sunk[pod.name] and part.Parent and not WaterRules.isDry(ground, level, dd) then
			st.sunk[pod.name] = true
			part:SetAttribute("Sinking", true)
			local parts: { { part: BasePart, cf: CFrame } } = {}
			if typeof(part) == "Instance" then
				local list: { Instance } = part:GetDescendants()
				table.insert(list, part)
				for _, d in list do
					if d:IsA("BasePart") then
						table.insert(parts, { part = d, cf = d.CFrame })
					end
				end
			end
			table.insert(st.sinking, { name = pod.name, part = part, t0 = ctx.now(), parts = parts })
			ctx.log("water pod sinks %s ground=%.1f level=%.1f", pod.name, ground, level)
		end
	end
end

local function stepSinking(ctx: Ctx, st: State)
	local now = ctx.now()
	for i = #st.sinking, 1, -1 do
		local s = st.sinking[i]
		local k = math.clamp((now - s.t0) / SINK_SECONDS, 0, 1)
		local drop = Vector3.new(0, -SINK_DEPTH * k * k, 0) -- eases in: a wobble, then the sand swallows it
		for _, p in s.parts do
			if p.part.Parent then
				p.part.CFrame = p.cf + drop
			end
		end
		if k >= 1 then
			table.remove(st.sinking, i)
			if typeof(s.part) == "Instance" and s.part.Parent then
				s.part:Destroy()
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Mode
------------------------------------------------------------------------------------------------------------------------

function Water.start(ctx: Ctx): State
	local survival = Survival.start(ctx) :: SurvivalState
	local tide = WaterRules.tide(ctx.battle)
	local arena = ctx.arena
	local rp = groundParams(ctx)

	local grid = WaterRules.newGrid(arena.center, math.max(arena.radius + GRID_PAD, arena.returnRadius), GRID_CELL)
	local top = math.min(arena.ceiling, arena.center.Y + 200)
	local reach = top - arena.center.Y + 120
	local hits = 0
	for _, c in WaterRules.cells(grid) do
		local h = groundAt(rp, c.x, c.z, top, reach)
		WaterRules.setHeight(grid, c.index, h)
		if h then
			hits += 1
		end
	end
	local spawnGround: { number } = {}
	for i, s in arena.spawns do
		spawnGround[i] = groundAt(rp, s.X, s.Z, s.Y + 2, 40) or (s.Y - 4)
	end
	local podGround: { [string]: number } = {}
	for _, pod in ctx.pods() do
		podGround[pod.name] = groundAt(rp, pod.pos.X, pod.pos.Z, pod.pos.Y + 1, 30) or (pod.pos.Y - 3)
	end

	local course = WaterRules.course(ctx.battle, arena.center, arena.radius * 0.85, grid)
	local deckPads: { [number]: boolean } = {}
	for i, s in arena.spawns do
		if WaterRules.onDeck(course, s, spawnGround[i]) then
			deckPads[i] = true
		end
	end

	local st: State = {
		survival = survival,
		tide = tide,
		course = course,
		watch = WaterRules.newWatch(),
		motion = WaterRules.newMotion(),
		spawnGround = spawnGround,
		deckPads = deckPads,
		podGround = podGround,
		water = buildWater(ctx, tide),
		level = tide.base,
		lastT = 0,
		hudTimer = 0,
		plans = {},
		ride = if ctx.vehicle == "car" then CarConfig.RIDE_HEIGHT else 0,
		over = false,
		frames = {},
		sinking = {},
		sunk = {},
		locks = {},
	}

	local steps: { string } = {}
	local shares: { string } = { string.format("%d%%", (share(st, ctx, tide.base))) }
	for _, s in tide.steps do
		table.insert(steps, string.format("%.0fs:%.1f", s.at, s.level))
		table.insert(shares, string.format("%d%%", (share(st, ctx, s.level))))
	end
	local grounds: { string } = {}
	for _, g in spawnGround do
		table.insert(grounds, string.format("%.1f", g))
	end
	ctx.log(
		"water start entrants=%d lives=%d base=%.1f steps=%s drown=%.1f rise=%.0fs grid=%d/%d dry=%s spawnGround=%s gangways=%d",
		#survival.rules.ids,
		survival.rules.lives,
		tide.base,
		table.concat(steps, ","),
		tide.drownDepth,
		tide.rise,
		hits,
		#WaterRules.cells(grid),
		table.concat(shares, "/"),
		table.concat(grounds, ","),
		#st.course.gangways
	)
	refreshHud(ctx, st, 0)
	return st
end

function Water.step(ctx: Ctx, st: State, dt: number)
	if st.over then
		return
	end
	local t = ctx.elapsed()
	for _, ev in WaterRules.events(st.tide, st.lastT, t) do
		announce(ctx, st, ev)
		if ev.kind == "warn" then
			sinkDoomed(ctx, st, ev.step.level)
		end
	end
	st.lastT = math.max(st.lastT, t)
	if #st.sinking > 0 then
		stepSinking(ctx, st)
	end
	local level = WaterRules.levelAt(st.tide, t)
	if level ~= st.level then
		-- Only while a step climbs (the level is constant between steps), so the plane ends exactly on the step.
		st.level = level
		placeWater(ctx, st)
	end
	for _, e in ctx.alive() do
		local pos = ctx.position(e.id)
		if pos then
			local depth = level - (pos.Y - st.ride)
			local bot = e.bot
			if WaterRules.sample(st.watch, e.id, depth, st.tide.drownDepth, t) then
				drown(ctx, st, e, pos, depth, t)
				if st.over then
					return
				end
			elseif bot then
				-- The watchdog: arena bots only (a player may park); a stunned bot is allowed to crawl.
				if bot.stunTimer > 0 then
					WaterRules.resetMotion(st.motion, e.id)
				elseif WaterRules.stuck(st.motion, e.id, pos, t) then
					unstick(ctx, st, e, pos, t)
				end
			end
		end
	end
	st.hudTimer -= dt
	if st.hudTimer <= 0 then
		st.hudTimer = HUD_EVERY
		refreshHud(ctx, st, t)
	end
end

-- Item hits are survival's (life, toasts, out, end); the HUD line is put back to the tide one after.
function Water.onHit(ctx: Ctx, st: State, victim: Entrant, attacker: Entrant?, source: string, pos: Vector3)
	if st.over then
		return
	end
	local entry = st.survival.rules.entries[victim.id]
	local lastLoss = if entry then entry.lastLossAt else nil
	if lastLoss and ctx.elapsed() - lastLoss < LIFE_GRACE then
		ctx.log("water hit ignored victim=%s source=%s (%.1fs after a life lost)", victim.name, source, ctx.elapsed() - lastLoss)
		return
	end
	Survival.onHit(ctx, st.survival, victim, attacker, source, pos)
	st.plans[victim.id] = nil
	if SurvivalRules.checkEnd(st.survival.rules, true).over then
		st.over = true -- Survival.onHit finished the battle
		return
	end
	refreshHud(ctx, st, ctx.elapsed())
end

function Water.onLeave(ctx: Ctx, st: State, entrant: Entrant)
	if st.over then
		return
	end
	Survival.onLeave(ctx, st.survival, entrant)
	if SurvivalRules.checkEnd(st.survival.rules, true).over then
		st.over = true
		return
	end
	refreshHud(ctx, st, ctx.elapsed())
end

-- Whether `shooter` (a bot) may lock human `victim` now (I2-07): not while the human is on the decks and the bot is
-- not, and not again inside HUMAN_SHOT_GAP of its last lock on him. Anyone else is always fair game.
local function mayLock(ctx: Ctx, st: State, shooter: Entrant, victim: Entrant): boolean
	if shooter.isPlayer or not victim.isPlayer then
		return true
	end
	local last = st.locks[shooter.id .. "|" .. victim.id]
	if last and ctx.elapsed() - last < WaterRules.HUMAN_SHOT_GAP then
		return false
	end
	local vp, sp = ctx.position(victim.id), ctx.position(shooter.id)
	if vp and sp then
		local victimDeck = WaterRules.onDeck(st.course, vp, vp.Y - st.ride)
		if victimDeck and not WaterRules.onDeck(st.course, sp, sp.Y - st.ride) then
			return false
		end
	end
	return true
end

local function botView(ctx: Ctx, st: State, bot: Entrant, pos: Vector3, fwd: Vector3): WaterRules.BotView
	local pods: { WaterRules.PodView } = {}
	for _, pod in ctx.pods() do
		if pod.part.Parent and pod.part:GetAttribute("OnCooldown") ~= true and not st.sunk[pod.name] then
			table.insert(pods, { pos = pod.pos, ground = st.podGround[pod.name] or (pod.pos.Y - 3) })
		end
	end
	local rivals: { WaterRules.RivalView } = {}
	for _, e in ctx.alive() do
		if e.id ~= bot.id then
			local p = ctx.position(e.id)
			if p then
				table.insert(rivals, {
					id = e.id,
					pos = p,
					ground = p.Y - st.ride,
					isPlayer = e.isPlayer,
					noAttack = not mayLock(ctx, st, bot, e),
				})
			end
		end
	end
	local color = ctx.holding(bot.id)
	return {
		pos = pos,
		forward = fwd,
		ground = pos.Y - st.ride,
		holding = color ~= nil,
		t = ctx.elapsed(),
		pods = pods,
		rivals = rivals,
	}
end

function Water.botGoal(ctx: Ctx, st: State, bot: Entrant): any
	local pos = ctx.position(bot.id)
	if not pos then
		return nil
	end
	local fwd = ctx.forward(bot.id) or Vector3.new(0, 0, -1)
	local now = ctx.now()
	local plan = st.plans[bot.id]
	if plan == nil or now >= plan.untilT then
		local fresh: Plan = { goal = WaterRules.botGoal(st.course, botView(ctx, st, bot, pos, fwd)), untilT = now + THINK }
		st.plans[bot.id] = fresh
		plan = fresh
	end
	local goal = plan.goal
	local g = goal.gangway
	if g then
		-- A gangway trip: the line-up waypoint moves with the bot.
		goal.pos = WaterRules.routeStep(g, pos, fwd, goal.up == true)
	elseif goal.reason == "hunt" and goal.attack and goal.attack ~= WaterRules.HOLD_FIRE then
		local rival = ctx.byId[goal.attack]
		local rp = ctx.position(goal.attack)
		if rival and not rival.out and rp then
			goal.pos = rp
		end
	end
	return goal
end

-- The tide for the car bots' water wall (BattleBots world.waterLevel): the level WaterRules.WALL_AHEAD seconds on, so
-- a bot stops at the edge of ground a rising or imminent step is about to take. Before, a bot only saw the terrain sea
-- (20.0, the base level) and drove onto 18.8 ground at the 21.5 step (the drown at (-5266, 4151), depth 2.68); with the
-- level as it stood, bots still swung onto low sand in the second before a step and drowned in its rise. The planner
-- (WaterRules.botGoal) plans its ways out at this same level.
function Water.waterLevel(ctx: Ctx, st: State): number
	local t = ctx.elapsed()
	return if t > 0 then WaterRules.levelAhead(st.tide, t, WaterRules.WALL_AHEAD) else st.tide.base
end

-- BattleCore's boundary return (trap audit I2-05 / G3): the safe pad nearest where the car left the arena, dry through
-- the coming step, never the decks, with the tide immunity so the put-back can never drown it.
function Water.returnFrame(ctx: Ctx, st: State, e: Entrant, pos: Vector3): CFrame?
	local t = math.max(ctx.elapsed(), 0)
	local ahead = respawnLevel(st, t)
	local slot = WaterRules.pickSafeSpawn(ctx.arena.spawns, st.spawnGround, ahead, st.tide.drownDepth, {
		avoid = st.deckPads,
		rivals = rivalsOf(ctx, e.id),
		near = pos,
	})
	if not slot then
		return nil
	end
	WaterRules.shield(st.watch, e.id, t + WaterRules.IMMUNE)
	WaterRules.resetMotion(st.motion, e.id)
	st.plans[e.id] = nil
	ctx.log("water return %s from=(%.0f,%.1f,%.0f) level=%.2f -> pad%d", e.name, pos.X, pos.Y, pos.Z, ahead, slot)
	return respawnFrame(ctx, st, slot, ahead, not e.isPlayer)
end

-- BattleCore's respawn guard: whether a respawn frame at `pos` is still a safe place to set a car down. A pad is safe
-- while it is not on the decks (G1) and stays dry through the coming step (the drown rule's look-ahead). A frame that
-- is no pad is left alone. A respawn the player asks for onto an unsafe frame goes through returnFrame instead: the
-- pad a drown chose was only promised dry through the next step, and a later RESPAWN press must not drown the car.
function Water.frameSafe(ctx: Ctx, st: State, pos: Vector3): boolean
	local i = BattleRules.nearestIndex(ctx.arena.spawns, pos)
	if not i or BattleRules.horizontal(ctx.arena.spawns[i], pos) > PAD_MATCH then
		return true
	end
	if st.deckPads[i] then
		return false
	end
	local ground = st.spawnGround[i]
	if not ground then
		return true
	end
	return WaterRules.isDry(ground, respawnLevel(st, math.max(ctx.elapsed(), 0)), st.tide.drownDepth)
end

-- BattleCore's item targeting: whether `shooter`'s missile or magnet may lock `victim` (see mayLock), and the lock it
-- took (the HUMAN_SHOT_GAP clock).
function Water.targetable(ctx: Ctx, st: State, shooter: Entrant, victim: Entrant): boolean
	return mayLock(ctx, st, shooter, victim)
end

function Water.locked(ctx: Ctx, st: State, shooter: Entrant, victim: Entrant)
	if not shooter.isPlayer and victim.isPlayer then
		st.locks[shooter.id .. "|" .. victim.id] = ctx.elapsed()
	end
end

function Water.resolve(ctx: Ctx, st: State, reason: string): Result
	st.over = true
	return Survival.resolve(ctx, st.survival, reason)
end

return Water
