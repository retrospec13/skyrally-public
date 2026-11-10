--!strict
-- DINO-BATTLE egg battle (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L71) on the DINO-4 overlay: the lower-basin cavern
-- floor of the great hall round the altar deck (plane vs three bots). Scoring is EggRules (carry, drop, 10 s hatch,
-- steal, knock-loose, first to 3, cap and tie rules, all specced under Lune in tools/tests/egg_spec.luau); this module
-- wires it to the battle framework and builds what the players see:
-- * The centre nest on the altar top (TrackData modes.battle.centerNest): a gold ring over a twig bowl on a stone
--   plinth, with the egg hanging in the ring under a gold beacon while it waits. Flying through the egg takes it.
-- * Four nest rings standing on stone pillars at the sides of the altar (modes.battle.nests), one per seat (the plan
--   lays spawn pad i beside nest i), tinted with the seat colour (BLUE, RED, GREEN, PURPLE, as the hoard rings), a
--   light beacon and the owner's name over each; eggs sit in the twig bowl in the bottom of the ring.
-- * Eggs: speckled cream ovoids with a glow. A carried egg rides under the carrier's plane (welded to its hull, so it
--   moves with the client-simulated plane at no lag); an egg in a nest glows warmer as it nears hatching and rocks in
--   its last seconds, then cracks into a baby dinosaur in an open shell; a knocked-loose egg hangs where it fell (no
--   lower than the nest rings).
-- * The board shows "N HATCHED + n NEST + EGG"; the objective line says what to do next and names the nest colour.
-- * A crash respawn (FlightServer stamps the player's LastRespawnClock) drops a carried egg where the plane was
--   (EggRules.respawned). A boundary return is not a crash (trap audit D4-01): BattleCore copies its stamp to
--   BoundaryReturnClock, and the carrier keeps the egg through the put-back (its teleport jump is not a drop either).
-- Bots (botGoal): EggRules.botTarget picks the cheapest objective (their nest when carrying; else the centre egg, a
-- dropped egg or the rival egg nearest to hatching, yielding a target another bot is clearly closer to; else chase
-- the carrier), aiming their items at the nearest carrier; EggRules.approach swings them wide of a point inside their
-- turning circle so they fly through it instead of orbiting it, and turns them round level for a point behind; they
-- fly no lower than just over the nests (AIM_OVER_NEST).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EggRules = require(Shared:WaitForChild("battle"):WaitForChild("EggRules"))
local BattleCore = require(script.Parent.Parent.BattleCore)
local BattleRules = require(Shared:WaitForChild("battle"):WaitForChild("BattleRules"))

local server = ((script.Parent :: Instance).Parent :: Instance).Parent :: Instance

type Ctx = BattleCore.Ctx
type Entrant = BattleCore.Entrant
type Result = BattleCore.Result

local okVfx, VfxAssets = pcall(require, Shared:WaitForChild("VfxAssets"))
local okFlip, FlipFx = pcall(require, Shared:WaitForChild("FlipFx"))

local Egg = {}

Egg.kind = "egg"
Egg.title = "EGG BATTLE"

-- Bots: BattleBots flies planes at about 102 studs/s turning at most 80 degrees/s (its TUNE.plane).
local BOT_TURN_DEG = 80
local TURN_MARGIN = 1.1
-- Bot heights: they aim no lower than this far over the lowest nest ring's centre and no steeper than AIM_SLOPE (rise
-- per stud). Every objective is a fly-through at that height or above (loose eggs hang no lower than the nests), and
-- a bot that dives at its 32-degree pitch limit loses ~35 studs in the turn after it (BattleRules.turnToward slerps
-- yaw and pitch together): on DINO-4 it then skimmed the lava and flew into the altar's tiers side-on.
local AIM_OVER_NEST = 6
local AIM_SLOPE = 0.45

-- Looks (OURS).
local SEAT_TINT: { Color3 } = {
	Color3.fromRGB(70, 150, 255),
	Color3.fromRGB(240, 84, 70),
	Color3.fromRGB(96, 208, 92),
	Color3.fromRGB(176, 108, 240),
}
local SEAT_NAME: { string } = { "BLUE", "RED", "GREEN", "PURPLE" }
local UNOWNED = Color3.fromRGB(150, 146, 138)
local GOLD = Color3.fromRGB(255, 204, 84)
local SHELL = Color3.fromRGB(246, 236, 212)
local SPECKLE: { Color3 } = { Color3.fromRGB(126, 90, 60), Color3.fromRGB(172, 124, 80), Color3.fromRGB(96, 70, 52) }
local TWIG: { Color3 } = { Color3.fromRGB(116, 80, 48), Color3.fromRGB(148, 106, 64) }
local STONE = Color3.fromRGB(70, 54, 50)
local BABY = Color3.fromRGB(112, 200, 92)
local RING_SEGMENTS = 20
local BEACON_HEIGHT = 70
local EGG_SIZE = Vector3.new(3, 3.9, 3) -- in a nest
local CENTRE_EGG_SIZE = Vector3.new(4.4, 5.7, 4.4)
local CARRY_EGG_SIZE = Vector3.new(2.6, 3.4, 2.6)
local LOOSE_EGG_SIZE = Vector3.new(3.6, 4.6, 3.6)
local CARRY_OFFSET = CFrame.new(0, -3.3, 0.8) -- under the hull (4.2 x 3 x 12), a little aft of the middle
local LOOSE_MIN_LIFT = 24 -- a knocked-loose egg hangs at least this far over the arena floor and no lower than the
-- lowest nest ring's centre (where every plane, bots included, can fly through it)
local REFRESH_EVERY = 0.25 -- board, objective line, egg views
local PULSE_EVERY = 0.1 -- nest egg glow and rocking (replicated property changes: not every Heartbeat)
local ROCK_FROM = 0.7 -- hatch progress after which an egg rocks in its nest

local REASON_TEXT: { [string]: string } = {
	time = "time up - most eggs hatched wins",
	qa = "ended early (QA) - ranked by eggs hatched",
}

type NestView = {
	model: Model,
	pos: Vector3,
	frame: CFrame, -- ring centre, LookVector along the fly-through axis (toward the arena centre)
	bowl: CFrame, -- top of the twig bowl, same facing
	glow: { BasePart },
	glowColour: Color3,
	light: PointLight,
	emitter: ParticleEmitter,
	confetti: ParticleEmitter, -- confetti_burst_4x4 on a hatch
	beacon: BasePart?,
	label: TextLabel?,
	caption: string,
	token: number,
}

type EggView = {
	key: string,
	model: Model,
	shell: BasePart,
	light: PointLight?,
	tint: Color3,
	base: CFrame,
	hull: BasePart?, -- carried: the hull it is welded to
}

type State = {
	rules: EggRules.State,
	nests: { NestView },
	centre: NestView,
	eggFolder: Folder,
	views: { [number]: EggView }, -- egg id -> view
	refreshTimer: number,
	pulseTimer: number,
	stopped: boolean,
	respawnSeen: { [string]: any }, -- player id -> the LastRespawnClock stamp already handled
	lowY: number, -- the lowest nest ring's centre height
	keepUntil: { [string]: number }, -- player id -> elapsed time until which a teleport jump is a boundary put-back
}

------------------------------------------------------------------------------------------------------------------------
-- Visuals
------------------------------------------------------------------------------------------------------------------------

local function part(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function texture(name: string): string
	local entry = if okVfx and type(VfxAssets) == "table" then (VfxAssets :: any)[name] else nil
	return if type(entry) == "table" and type(entry.id) == "string" then entry.id else ""
end

-- Twinkling sparkle_star_4x4 glints (flip_v2 loop through Shared.FlipFx; the old star_twinkle when it is missing).
local function glints(name: string, colour: Color3, rate: number, parent: Instance): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	if okFlip and type(FlipFx) == "table" then
		FlipFx.apply(e, "sparkle_star_4x4")
	else
		e.Texture = texture("star_twinkle")
	end
	e.Color = ColorSequence.new(colour)
	e.LightEmission = 0.8
	e.LightInfluence = 0
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.5, 1.4), NumberSequenceKeypoint.new(1, 0) })
	e.Lifetime = NumberRange.new(0.6, 1.1)
	e.Rate = rate
	e.Speed = NumberRange.new(1, 3)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Parent = parent
	return e
end

-- A speckled ovoid: a block shell drawn as an ellipsoid (SpecialMesh Sphere) with dark speckles on its surface and a
-- PointLight glow. The model pivot is the egg's centre at `cf` (PivotTo moves it as a unit).
local function buildEgg(name: string, size: Vector3, cf: CFrame, glow: Color3, parent: Instance): (Model, BasePart, PointLight)
	local m = Instance.new("Model")
	m.Name = name
	local shell = part("Shell", Enum.PartType.Block, size, cf, SHELL, Enum.Material.SmoothPlastic, m)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = shell
	local a, b = size.X * 0.5, size.Y * 0.5
	for i = 1, 9 do
		-- Golden-angle spread over the shell, kept off the very top and bottom.
		local phi = math.acos(0.82 - (i - 1) * 0.2)
		local theta = i * 2.39996
		local d = 0.16 + (i % 3) * 0.06
		local local_ = Vector3.new(a * math.sin(phi) * math.cos(theta), b * math.cos(phi), a * math.sin(phi) * math.sin(theta)) * 0.97
		local dot = part("Speckle" .. i, Enum.PartType.Ball, Vector3.new(d, d, d) * size.X, cf * CFrame.new(local_), SPECKLE[(i % #SPECKLE) + 1], Enum.Material.SmoothPlastic, m)
		dot.CastShadow = false
	end
	local light = Instance.new("PointLight")
	light.Color = glow
	light.Range = 12 + size.Y * 1.5
	light.Brightness = 1.4
	light.Shadows = false
	light.Parent = shell
	m.PrimaryPart = shell
	m.Parent = parent
	return m, shell, light
end

-- A hatched egg: the lower half of the shell with a jagged rim and a baby dinosaur's head peeking out, facing along
-- cf's LookVector (the arena centre).
local function buildHatchling(name: string, cf: CFrame, glow: Color3, parent: Instance): (Model, BasePart, PointLight)
	local m = Instance.new("Model")
	m.Name = name
	local cup = part("Shell", Enum.PartType.Block, Vector3.new(3.2, 2.4, 3.2), cf * CFrame.new(0, -0.6, 0), SHELL, Enum.Material.SmoothPlastic, m)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = cup
	for i = 1, 6 do
		local a = (i - 1) * math.pi / 3
		part("Shard" .. i, Enum.PartType.Wedge, Vector3.new(0.3, 0.9, 0.8), cf * CFrame.Angles(0, a, 0) * CFrame.new(0, 0.75, -1.35) * CFrame.Angles(0, 0, if i % 2 == 0 then 0.25 else -0.2), SHELL, Enum.Material.SmoothPlastic, m)
	end
	local head = part("Head", Enum.PartType.Ball, Vector3.new(2.3, 2.3, 2.3), cf * CFrame.new(0, 1.35, 0), BABY, Enum.Material.SmoothPlastic, m)
	part("Snout", Enum.PartType.Ball, Vector3.new(1.4, 1.4, 1.4), cf * CFrame.new(0, 1.15, -1.05), BABY, Enum.Material.SmoothPlastic, m)
	for _, side in { -1, 1 } do
		part("Eye", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7), cf * CFrame.new(side * 0.55, 1.85, -0.8), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, m)
		part("Pupil", Enum.PartType.Ball, Vector3.new(0.36, 0.36, 0.36), cf * CFrame.new(side * 0.57, 1.88, -1.1), Color3.fromRGB(24, 20, 18), Enum.Material.SmoothPlastic, m)
	end
	local light = Instance.new("PointLight")
	light.Color = glow
	light.Range = 10
	light.Brightness = 0.9
	light.Shadows = false
	light.Parent = head
	m.PrimaryPart = cup
	cup.PivotOffset = cup.CFrame:ToObjectSpace(cf)
	m.Parent = parent
	return m, cup, light
end

-- A nest ring: a rim of RING_SEGMENTS blocks in the tint with a neon inner band, square to its fly-through axis, a twig
-- bowl cradled in its bottom, a stone pillar down to `ground` (when known), and for an owned nest (or the centre) a
-- light beacon and a caption over it.
local function buildNest(
	name: string,
	pos: Vector3,
	yawDeg: number,
	radius: number,
	ground: number?,
	tint: Color3,
	caption: string?,
	parent: Instance
): NestView
	local m = Instance.new("Model")
	m.Name = name
	local frame = CFrame.new(pos) * CFrame.Angles(0, math.rad(yawDeg), 0)
	local glowColour = tint:Lerp(Color3.new(1, 1, 1), 0.45)
	local glow: { BasePart } = {}
	local inner = radius - 1.6
	for i = 1, RING_SEGMENTS do
		local a = (i - 1) * (2 * math.pi / RING_SEGMENTS)
		local spin = frame * CFrame.Angles(0, 0, a)
		part("Rim_" .. i, Enum.PartType.Block, Vector3.new(2 * math.pi * radius / RING_SEGMENTS * 1.12, 2.4, 3.2), spin * CFrame.new(0, radius, 0), tint, Enum.Material.SmoothPlastic, m)
		local g = part("Glow_" .. i, Enum.PartType.Block, Vector3.new(2 * math.pi * inner / RING_SEGMENTS * 1.12, 0.8, 1.6), spin * CFrame.new(0, inner, 0), glowColour, Enum.Material.Neon, m)
		g.CastShadow = false
		table.insert(glow, g)
	end
	-- Twig bowl in the bottom of the ring: a flat woven base and two rings of tilted sticks.
	local bowlCentre = frame * CFrame.new(0, -radius + 3.4, 0)
	part("BowlBase", Enum.PartType.Cylinder, Vector3.new(1.6, 9.5, 9.5), bowlCentre * CFrame.new(0, -0.8, 0) * CFrame.Angles(0, 0, math.pi / 2), TWIG[1], Enum.Material.Wood, m)
	for i = 1, 14 do
		-- Tangent sticks round the rim, alternate ends raised so they read as woven.
		local a = (i - 1) * (2 * math.pi / 14)
		local tilt = if i % 2 == 0 then 0.35 else -0.35
		part("Twig_" .. i, Enum.PartType.Block, Vector3.new(0.6, 0.6, 4.8), bowlCentre * CFrame.Angles(0, a, 0) * CFrame.new(4.4, 0.5, 0) * CFrame.Angles(tilt, 0, 0), TWIG[(i % 2) + 1], Enum.Material.Wood, m)
	end
	if type(ground) == "number" and ground < pos.Y - radius then
		local top = pos.Y - radius - 0.8
		local h = top - ground
		part("Pillar", Enum.PartType.Cylinder, Vector3.new(h, 5.5, 5.5), CFrame.new(pos.X, ground + h * 0.5, pos.Z) * CFrame.Angles(0, 0, math.pi / 2), STONE, Enum.Material.Basalt, m)
		part("Footing", Enum.PartType.Cylinder, Vector3.new(3, 10, 10), CFrame.new(pos.X, ground + 1, pos.Z) * CFrame.Angles(0, 0, math.pi / 2), STONE, Enum.Material.Basalt, m)
	end
	local core = part("Core", Enum.PartType.Block, Vector3.new(1, 1, 1), frame, tint, Enum.Material.SmoothPlastic, m)
	core.Transparency = 1
	core.CastShadow = false
	local light = Instance.new("PointLight")
	light.Color = glowColour
	light.Range = 30
	light.Brightness = 1.1
	light.Shadows = false
	light.Parent = core
	local emitter = glints("NestBurst", glowColour, 120, core)
	emitter.Speed = NumberRange.new(20, 38)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.6), NumberSequenceKeypoint.new(0.6, 2.2), NumberSequenceKeypoint.new(1, 0) })
	emitter.Enabled = false
	-- Hatch party: the rendered confetti_burst_4x4 (already coloured; OneShot over each particle's life), ~3 sheets.
	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "NestConfetti"
	if okFlip and type(FlipFx) == "table" then
		FlipFx.apply(confetti, "confetti_burst_4x4")
	else
		confetti.Texture = texture("confetti")
	end
	confetti.LightEmission = 0.1
	confetti.Size = NumberSequence.new(9)
	confetti.Lifetime = NumberRange.new(1.3, 1.6)
	confetti.Rate = 9
	confetti.Speed = NumberRange.new(4, 10)
	confetti.SpreadAngle = Vector2.new(180, 180)
	confetti.Acceleration = Vector3.new(0, -6, 0)
	-- Gravity is baked into the sheet: keep it upright (a random Rotation made confetti fall sideways or up).
	confetti.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	confetti.Enabled = false
	confetti.Parent = core
	local beacon: BasePart? = nil
	local label: TextLabel? = nil
	if caption then
		local b = part(
			"Beacon",
			Enum.PartType.Cylinder,
			Vector3.new(BEACON_HEIGHT, 1.6, 1.6),
			CFrame.new(pos + Vector3.new(0, radius + 2 + BEACON_HEIGHT / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			glowColour,
			Enum.Material.Neon,
			m
		)
		b.Transparency = 0.45
		b.CastShadow = false
		beacon = b
		local gui = Instance.new("BillboardGui")
		gui.Name = "Owner"
		gui.Size = UDim2.new(0, 170, 0, 28) -- v21: was 220x40 and read giant on a phone; the client also hides it behind the HUD (BattleWorldLabel)
		gui.StudsOffset = Vector3.new(0, radius + 6, 0)
		gui.LightInfluence = 0
		gui.MaxDistance = 320
		pcall(function()
			game:GetService("CollectionService"):AddTag(gui, "BattleWorldLabel")
		end)
		gui.Parent = core
		local text = Instance.new("TextLabel")
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 1, 0)
		text.Font = Enum.Font.GothamBlack
		text.TextScaled = true
		text.TextColor3 = glowColour
		text.TextStrokeColor3 = Color3.fromRGB(40, 28, 18)
		text.TextStrokeTransparency = 0.15
		text.Text = caption
		text.Parent = gui
		label = text
	end
	m.Parent = parent
	return {
		model = m,
		pos = pos,
		frame = frame,
		bowl = bowlCentre,
		glow = glow,
		glowColour = glowColour,
		light = light,
		emitter = emitter,
		confetti = confetti,
		beacon = beacon,
		label = label,
		caption = caption or "",
		token = 0,
	}
end

-- The nest moment (drop, hatch, steal): glints burst, the inner band flashes white and `flash` shows over it; a hatch
-- (`party`) also pops confetti.
local function burst(view: NestView, flash: string?, party: boolean?)
	view.token += 1
	local token = view.token
	view.emitter.Enabled = true
	view.confetti.Enabled = party == true
	view.light.Brightness = 6
	for _, g in view.glow do
		g.Color = Color3.new(1, 1, 1)
	end
	local label = view.label
	if label and flash then
		label.Text = flash
	end
	task.delay(0.35, function()
		if view.token ~= token or not view.model.Parent then
			return
		end
		view.emitter.Enabled = false
		view.confetti.Enabled = false
		view.light.Brightness = 1.1
		for _, g in view.glow do
			g.Color = view.glowColour
		end
	end)
	task.delay(1.8, function()
		local l = view.label
		if view.token == token and l and l.Parent then
			l.Text = view.caption
		end
	end)
end

-- Bowl spot k (1-based) of a nest: five round the bowl, then a second layer; faces the nest's LookVector.
local function bowlSpot(view: NestView, k: number): CFrame
	local layer = (k - 1) // 5
	local i = (k - 1) % 5
	local a = i * (2 * math.pi / 5) + 0.3
	local r = if layer == 0 then 2.4 else 1.3
	return view.bowl * CFrame.new(math.cos(a) * r, 1.9 + layer * 3.2, math.sin(a) * r)
end

------------------------------------------------------------------------------------------------------------------------
-- Rules plumbing
------------------------------------------------------------------------------------------------------------------------

local function seatName(index: number?): string
	return if index and SEAT_NAME[index] then SEAT_NAME[index] else "OPEN"
end

local function seatTint(index: number?): Color3
	return if index and SEAT_TINT[index] then SEAT_TINT[index] else UNOWNED
end

local function nestNameOf(st: State, id: string): string
	local e = st.rules.entries[id]
	return seatName(if e then e.nest else nil)
end

local function nameOf(ctx: Ctx, id: string?): string
	local e = if id then ctx.byId[id] else nil
	return if e then e.name else "Someone"
end

-- The plan's nests (pos, yaw, radius, ground); an arena without them gets one at each spawn pad, facing the centre.
type NestSpec = { name: string, pos: Vector3, yaw: number, radius: number, ground: number? }

local function nestList(ctx: Ctx): { NestSpec }
	local out: { NestSpec } = {}
	if type(ctx.battle.nests) == "table" then
		for i, n in ctx.battle.nests do
			if type(n) == "table" and typeof(n.pos) == "Vector3" then
				table.insert(out, {
					name = if type(n.name) == "string" then n.name else "Nest_" .. tostring(i),
					pos = n.pos,
					yaw = tonumber(n.yaw) or 0,
					radius = tonumber(n.radius) or 16,
					ground = tonumber(n.ground),
				})
			end
		end
	end
	if #out == 0 then
		for i, p in ctx.arena.spawns do
			local c = ctx.arena.center
			table.insert(out, { name = "Nest_" .. tostring(i), pos = p, yaw = math.deg(math.atan2(p.X - c.X, p.Z - c.Z)), radius = 16, ground = nil })
		end
		ctx.log("egg: no nests in the plan, %d nests at the spawn pads", #out)
	end
	return out
end

local function centreSpec(ctx: Ctx): NestSpec
	local c = ctx.battle.centerNest
	if type(c) == "table" and typeof(c.pos) == "Vector3" then
		return { name = "CentreNest", pos = c.pos, yaw = tonumber(c.yaw) or 0, radius = tonumber(c.radius) or 14, ground = tonumber(c.ground) }
	end
	return { name = "CentreNest", pos = ctx.arena.center, yaw = 0, radius = 14, ground = nil }
end

-- Board and objective line. The board scores are places in the cap ranking (EggRules.boardScore), so the order it
-- shows is the order the results will give.
local function refresh(ctx: Ctx, st: State)
	local t = math.max(ctx.elapsed(), 0)
	local ranking = EggRules.ranking(st.rules, t)
	for _, e in ctx.entrants do
		if not e.spectator and st.rules.entries[e.id] then
			ctx.setScore(e.id, EggRules.boardScore(st.rules, e.id, t, ranking), EggRules.scoreText(st.rules, e.id))
			ctx.setHud(e.id, EggRules.hudText(st.rules, e.id, t, nestNameOf(st, e.id)))
		end
	end
end

local function toResult(st: State, outcome: EggRules.Outcome, reason: string, t: number): Result
	local ranking = EggRules.ranking(st.rules, t)
	local texts: { [string]: string } = {}
	for _, id in ranking do
		texts[id] = EggRules.scoreText(st.rules, id)
	end
	local text = REASON_TEXT[reason] or (if string.sub(reason, 1, 9) == "first to " then string.format("first to hatch %d eggs", st.rules.toWin) else reason)
	if reason == "time" and not outcome.winner then
		text = "time up - no egg hatched"
	end
	return { winner = outcome.winner, ranking = ranking, reason = text, texts = texts }
end

-- A knocked-loose egg hangs inside the play radius, no lower than the nests (clear of the floor) and under the ceiling.
local function looseSpot(ctx: Ctx, st: State, p: Vector3): Vector3
	local a = ctx.arena
	local dx, dz = p.X - a.center.X, p.Z - a.center.Z
	local d = math.sqrt(dx * dx + dz * dz)
	local limit = a.radius * 0.9
	local k = if d > limit then limit / d else 1
	local low = math.max(st.lowY, if a.floor > -math.huge then a.floor + LOOSE_MIN_LIFT else -math.huge)
	local high = if a.ceiling < math.huge then a.ceiling - 20 else p.Y
	return Vector3.new(a.center.X + dx * k, math.clamp(p.Y, low, math.max(low, high)), a.center.Z + dz * k)
end

-- The hull an entrant flies (bots: their anchored hull; players: FlightServer's record).
local flightServer: any = nil
local function hullOf(e: Entrant?): BasePart?
	if not e then
		return nil
	end
	local bot = e.bot
	if bot then
		return if bot.hull.Parent then bot.hull else nil
	end
	local player = e.player
	if not player then
		return nil
	end
	if flightServer == nil then
		local ok, mod = pcall(require, server:WaitForChild("FlightServer") :: any)
		flightServer = if ok then mod else false
	end
	local records = if flightServer then flightServer.records else nil
	local rec = if records then records[player] else nil
	local hull = if rec then rec.hull else nil
	return if hull and hull.Parent then hull else nil
end

------------------------------------------------------------------------------------------------------------------------
-- Egg views (rebuilt whenever an egg changes place)
------------------------------------------------------------------------------------------------------------------------

local function dropView(st: State, eggId: number)
	local v = st.views[eggId]
	if v then
		v.model:Destroy()
		st.views[eggId] = nil
	end
end

-- Welds a built egg under the carrier's hull: unanchored and massless, so it rides the (client-owned) plane assembly.
local function weldUnder(model: Model, shell: BasePart, hull: BasePart)
	model:PivotTo(hull.CFrame * CARRY_OFFSET)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= shell then
			local w = Instance.new("WeldConstraint")
			w.Part0 = shell
			w.Part1 = d
			w.Parent = shell
		end
	end
	local carry = Instance.new("WeldConstraint")
	carry.Name = "CarryWeld"
	carry.Part0 = hull
	carry.Part1 = shell
	carry.Parent = shell
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Massless = true
			d.Anchored = false
		end
	end
	-- Joining parts to the assembly resets its network owner to automatic (the server took it, and the server's hull then
	-- drifted away from the plane the player flies): hand the plane straight back to its pilot.
	pcall(function()
		local owner = Players:GetPlayerByUserId((hull.Parent :: Instance):GetAttribute("OwnerUserId") :: number)
		if owner then
			hull:SetNetworkOwner(owner)
		end
	end)
end

local function syncEggs(ctx: Ctx, st: State)
	local rules = st.rules
	-- Bowl spots: every egg in a nest, oldest first.
	local spot: { [number]: number } = {}
	local ownerNest: { [number]: number } = {}
	for _, id in rules.ids do
		local e = rules.entries[id]
		for k, egg in EggRules.nestEggs(rules, id) do
			spot[egg.id] = k
			ownerNest[egg.id] = e.nest or 0
		end
	end
	for eggId, egg in rules.eggs do
		local key: string
		local cf: CFrame? = nil
		local hull: BasePart? = nil
		local tint = GOLD
		if egg.at == "centre" then
			key = "centre"
			cf = CFrame.new(rules.geometry.centre)
		elseif egg.at == "carried" then
			local holder = egg.holder :: string
			local entry = rules.entries[holder]
			tint = seatTint(if entry then entry.nest else nil)
			hull = hullOf(ctx.byId[holder])
			key = "carried:" .. holder
			if not hull then
				local p = ctx.position(holder)
				cf = if p then CFrame.new(p) * CARRY_OFFSET else nil
			end
		elseif egg.at == "nest" then
			local view = st.nests[ownerNest[eggId] or 0]
			tint = seatTint(ownerNest[eggId])
			key = string.format("%s:%s:%d", if egg.hatched then "hatched" else "nest", tostring(egg.owner), spot[eggId] or 1)
			cf = if view then bowlSpot(view, spot[eggId] or 1) else nil
		else
			local p = egg.pos or rules.geometry.centre
			key = string.format("loose:%.1f:%.1f:%.1f", p.X, p.Y, p.Z)
			cf = CFrame.new(p)
			tint = Color3.fromRGB(255, 240, 200)
		end
		local v: EggView? = st.views[eggId]
		if v and (v.key ~= key or (v.hull ~= nil and (v.hull ~= hull or not v.hull.Parent))) then
			dropView(st, eggId)
			v = nil
		end
		if not v and (cf or hull) then
			local name = string.format("Egg_%02d", eggId)
			local model: Model, shell: BasePart, light: PointLight
			if egg.at == "nest" and egg.hatched then
				model, shell, light = buildHatchling(name, cf :: CFrame, tint, st.eggFolder)
			else
				local size = if egg.at == "centre"
					then CENTRE_EGG_SIZE
					elseif egg.at == "carried" then CARRY_EGG_SIZE
					elseif egg.at == "loose" then LOOSE_EGG_SIZE
					else EGG_SIZE
				local base = cf or (hull :: BasePart).CFrame * CARRY_OFFSET
				model, shell, light = buildEgg(name, size, base, tint, st.eggFolder)
				if egg.at == "centre" then
					light.Range = 26
					light.Brightness = 2.4
					glints("EggGlint", GOLD, 6, shell)
				elseif egg.at == "loose" then
					light.Brightness = 2.2
					glints("EggGlint", tint, 4, shell)
				end
			end
			if hull then
				weldUnder(model, shell, hull)
			end
			st.views[eggId] = { key = key, model = model, shell = shell, light = light, tint = tint, base = cf or CFrame.new(), hull = hull }
		elseif v and not hull and egg.at == "carried" and cf then
			-- No hull to weld to (a player whose record is gone): follow its position.
			v.model:PivotTo(cf)
		end
	end
	for eggId in st.views do
		if not rules.eggs[eggId] then
			dropView(st, eggId)
		end
	end
	-- The centre beacon shows while an egg waits.
	local beacon = st.centre.beacon
	if beacon then
		beacon.Transparency = if rules.centreEgg then 0.45 else 0.92
	end
end

-- Nest eggs glow warmer and brighter as they near hatching, and rock in their last seconds.
local function pulse(st: State, t: number)
	for eggId, v in st.views do
		local egg = st.rules.eggs[eggId]
		if egg and egg.at == "nest" and not egg.hatched then
			local p = EggRules.progress(st.rules, egg, t)
			local light = v.light
			if light then
				light.Brightness = 0.8 + 2.6 * p
				light.Range = 10 + 10 * p
				light.Color = v.tint:Lerp(GOLD, p)
			end
			if p >= ROCK_FROM then
				local k = (p - ROCK_FROM) / (1 - ROCK_FROM)
				v.model:PivotTo(v.base * CFrame.Angles(0, 0, math.sin(t * 17 + eggId) * 0.22 * k))
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------------------------------------

local function nestView(st: State, id: string?): NestView?
	local e = if id then st.rules.entries[id] else nil
	return if e and e.nest then st.nests[e.nest] else nil
end

local function handle(ctx: Ctx, st: State, events: { EggRules.Event }, attacker: Entrant?)
	local rules = st.rules
	for _, ev in events do
		local id = ev.id
		if ev.kind == "pickup" and id then
			ctx.log("egg pickup egg=%d by=%s from=%s t=%.1f", ev.egg or 0, nameOf(ctx, id), tostring(ev.from), ev.t)
			ctx.toast(id, string.format("YOU HAVE THE EGG - fly through your %s nest!", nestNameOf(st, id)), "good")
		elseif ev.kind == "deposit" and id then
			ctx.log("egg deposit egg=%d by=%s nest=%s t=%.1f", ev.egg or 0, nameOf(ctx, id), nestNameOf(st, id), ev.t)
			ctx.toast(id, string.format("EGG IN YOUR NEST - hatches in %d s", math.ceil(rules.hatchSeconds)), "good")
			local view = nestView(st, id)
			if view then
				burst(view, nil)
			end
		elseif ev.kind == "steal" and id then
			ctx.log("egg steal egg=%d by=%s from=%s t=%.1f", ev.egg or 0, nameOf(ctx, id), nameOf(ctx, ev.victim), ev.t)
			ctx.toast(id, string.format("STOLEN FROM %s! Fly it home", string.upper(nameOf(ctx, ev.victim))), "good")
			if ev.victim then
				ctx.toast(ev.victim, string.format("%s STOLE YOUR EGG!", string.upper(nameOf(ctx, id))), "bad")
			end
			local view = nestView(st, ev.victim)
			if view then
				burst(view, "STOLEN!")
			end
		elseif ev.kind == "hatch" and id then
			local count = ev.count or 0
			ctx.log("egg hatch egg=%d owner=%s count=%d t=%.1f", ev.egg or 0, nameOf(ctx, id), count, ev.t)
			ctx.toast(id, string.format("HATCHED! %d/%d", count, rules.toWin), "good")
			for _, other in ctx.entrants do
				if other.isPlayer and other.id ~= id and not other.spectator then
					ctx.toast(other.id, string.format("%s hatched an egg (%d/%d)", nameOf(ctx, id), count, rules.toWin), "info")
				end
			end
			local view = nestView(st, id)
			if view then
				burst(view, string.format("HATCHED %d/%d", count, rules.toWin), true)
			end
		elseif ev.kind == "drop" and id then
			ctx.log("egg drop egg=%d by=%s why=%s attacker=%s t=%.1f", ev.egg or 0, nameOf(ctx, id), tostring(ev.from), if attacker then attacker.name else "-", ev.t)
			local lost = ev.from == "jump" or ev.from == "respawn"
			ctx.toast(id, if lost then "EGG LOST - it hangs where you were" else "EGG KNOCKED LOOSE!", "bad")
			if attacker and attacker.id ~= id then
				ctx.toast(attacker.id, string.format("KNOCKED %s'S EGG LOOSE - grab it!", string.upper(nameOf(ctx, id))), "good")
			end
		elseif ev.kind == "lay" then
			ctx.log("egg lay egg=%d t=%.1f", ev.egg or 0, ev.t)
		elseif ev.kind == "crumble" then
			ctx.log("egg crumble egg=%d t=%.1f", ev.egg or 0, ev.t)
		elseif ev.kind == "win" and id then
			ctx.log("egg win %s hatched=%d t=%.1f", nameOf(ctx, id), ev.count or 0, ev.t)
		end
	end
	-- A loose egg hangs where the mode can reach it (the rules keep the raw spot of a crash).
	for _, ev in events do
		local egg = if ev.kind == "drop" and ev.egg then rules.eggs[ev.egg] else nil
		if egg and egg.at == "loose" and egg.pos then
			egg.pos = looseSpot(ctx, st, egg.pos)
		end
	end
	syncEggs(ctx, st)
end

------------------------------------------------------------------------------------------------------------------------
-- Mode
------------------------------------------------------------------------------------------------------------------------

-- One nest per seat: humans past the last nest would carry eggs they can never bank, so the core makes them spectate (L71).
function Egg.capacity(battle: any, arena: BattleRules.Arena): number
	local n = 0
	if type(battle.nests) == "table" then
		for _, nest in battle.nests do
			if type(nest) == "table" and typeof(nest.pos) == "Vector3" then
				n += 1
			end
		end
	end
	if n == 0 then
		n = #arena.spawns -- nestList's fallback: a nest at each spawn pad
	end
	return math.max(n, 1) -- never zero seats: one human must still play
end

function Egg.start(ctx: Ctx): State
	local seats: { EggRules.Seat } = {}
	for _, e in ctx.entrants do
		if not e.spectator then
			table.insert(seats, { id = e.id, isPlayer = e.isPlayer, slot = e.slot })
		end
	end
	local specs = nestList(ctx)
	local centre = centreSpec(ctx)
	local nestPositions: { Vector3 } = {}
	for _, n in specs do
		table.insert(nestPositions, n.pos)
	end
	local rules = EggRules.new(seats, { centre = centre.pos, nests = nestPositions }, {
		hatchSeconds = tonumber(ctx.rules.hatchSeconds),
		toWin = tonumber(ctx.rules.eggsToWin),
		respawnSeconds = tonumber(ctx.rules.eggRespawnSeconds),
	})

	local nestFolder = Instance.new("Folder")
	nestFolder.Name = "EggNests"
	nestFolder.Parent = ctx.folder
	local eggFolder = Instance.new("Folder")
	eggFolder.Name = "Eggs"
	eggFolder.Parent = ctx.folder

	local nests: { NestView } = {}
	for i, n in specs do
		local owner = EggRules.nestOwner(rules, i)
		local caption = if owner then string.upper(nameOf(ctx, owner)) .. "'S NEST" else nil
		local view = buildNest(n.name, n.pos, n.yaw, n.radius, n.ground, seatTint(if owner then i else nil), caption, nestFolder)
		view.model:SetAttribute("EggNest", i)
		view.model:SetAttribute("NestColour", seatName(i))
		view.model:SetAttribute("NestOwner", owner or "")
		table.insert(nests, view)
	end
	local centreView = buildNest(centre.name, centre.pos, centre.yaw, centre.radius, centre.ground, GOLD, "EGG", nestFolder)
	centreView.model:SetAttribute("EggNest", 0)

	local st: State = {
		rules = rules,
		nests = nests,
		centre = centreView,
		eggFolder = eggFolder,
		views = {},
		refreshTimer = 0,
		pulseTimer = 0,
		stopped = false,
		respawnSeen = {},
		lowY = math.huge,
		keepUntil = {},
	}
	for _, n in specs do
		st.lowY = math.min(st.lowY, n.pos.Y)
	end
	if st.lowY == math.huge then
		st.lowY = ctx.arena.center.Y -- no nests at all (no plan nests, no pads): nothing to deposit in anyway
	end
	-- A respawn stamped before this battle (the race reset, an earlier battle) is not a respawn in it.
	for _, e in ctx.entrants do
		local player = e.player
		if player then
			st.respawnSeen[e.id] = player:GetAttribute("LastRespawnClock")
		end
	end
	syncEggs(ctx, st)
	refresh(ctx, st)
	ctx.log(
		"egg start entrants=%d nests=%d hatch=%.0f win=%d respawn=%.0f centre=(%.0f,%.0f,%.0f)",
		#seats,
		#specs,
		rules.hatchSeconds,
		rules.toWin,
		rules.respawnSeconds,
		centre.pos.X,
		centre.pos.Y,
		centre.pos.Z
	)
	return st
end

function Egg.step(ctx: Ctx, st: State, dt: number)
	if st.stopped then
		return
	end
	local t = ctx.elapsed()
	local positions: { [string]: Vector3 } = {}
	local events: { EggRules.Event } = {}
	for _, e in ctx.alive() do
		local p = ctx.position(e.id)
		if p then
			positions[e.id] = p
		end
		-- Crash respawns, before the step sees the jump: the egg falls where the plane was. A boundary return keeps it.
		local player = e.player
		if player then
			local stamp = player:GetAttribute("LastRespawnClock")
			if stamp ~= st.respawnSeen[e.id] then
				st.respawnSeen[e.id] = stamp
				if stamp ~= nil and stamp == player:GetAttribute("BoundaryReturnClock") then
					st.keepUntil[e.id] = t + EggRules.RESPAWN_WINDOW
				else
					local ev = EggRules.respawned(st.rules, e.id, t)
					if ev then
						table.insert(events, ev)
					end
				end
			end
		end
		-- The put-back's jump reaches the server a replication or two after the stamp: the rules see the carrier
		-- arrive (no previous position), not a teleport jump that drops the egg.
		local keep = st.keepUntil[e.id]
		if keep then
			local prev = st.rules.prev[e.id]
			if t > keep then
				st.keepUntil[e.id] = nil
			elseif p and prev and (p - prev).Magnitude > EggRules.SEGMENT_MAX then
				st.rules.prev[e.id] = nil
				st.keepUntil[e.id] = nil
			end
		end
	end
	for _, ev in EggRules.step(st.rules, t, positions) do
		table.insert(events, ev)
	end
	if #events > 0 then
		handle(ctx, st, events, nil) -- syncs the egg views
	end
	st.refreshTimer -= dt
	if st.refreshTimer <= 0 or #events > 0 then
		st.refreshTimer = REFRESH_EVERY
		if #events == 0 then
			syncEggs(ctx, st)
		end
		refresh(ctx, st)
	end
	st.pulseTimer -= dt
	if st.pulseTimer <= 0 then
		st.pulseTimer = PULSE_EVERY
		pulse(st, t)
	end
	local outcome = EggRules.checkEnd(st.rules)
	if outcome.over then
		ctx.finish(toResult(st, outcome, outcome.reason, t))
	end
end

function Egg.onHit(ctx: Ctx, st: State, victim: Entrant, attacker: Entrant?, source: string, pos: Vector3)
	local t = ctx.elapsed()
	local where = looseSpot(ctx, st, ctx.position(victim.id) or pos)
	local ev = EggRules.hit(st.rules, victim.id, t, where)
	if not ev then
		return
	end
	ctx.log("egg hit victim=%s by=%s source=%s", victim.name, if attacker then attacker.name else "self", source)
	handle(ctx, st, { ev }, attacker)
	refresh(ctx, st)
end

function Egg.onLeave(ctx: Ctx, st: State, entrant: Entrant)
	-- The record is usually gone by now: the egg drops where the rules last saw the plane.
	local p = ctx.position(entrant.id) or st.rules.prev[entrant.id]
	local events = EggRules.leave(st.rules, entrant.id, ctx.elapsed(), if p then looseSpot(ctx, st, p) else nil)
	handle(ctx, st, events, nil)
	refresh(ctx, st)
end

function Egg.botGoal(ctx: Ctx, st: State, bot: Entrant): any
	local pos = ctx.position(bot.id)
	if not pos then
		return nil
	end
	local others: { [string]: Vector3 } = {}
	local bots: { [string]: boolean } = {}
	for _, e in ctx.alive() do
		local p = ctx.position(e.id)
		if p then
			others[e.id] = p
		end
		if not e.isPlayer then
			bots[e.id] = true
		end
	end
	local target = EggRules.botTarget(st.rules, bot.id, pos, ctx.elapsed(), others, bots)
	local b = bot.bot
	local speed = if b then math.max(b.speed, b.baseSpeed) else 102
	local radius = speed / math.rad(BOT_TURN_DEG) * TURN_MARGIN
	local aim, swung, why = EggRules.approach(pos, ctx.forward(bot.id) or Vector3.new(0, 0, -1), target.pos, radius)
	local floorY = st.lowY + AIM_OVER_NEST
	local ceilY = if ctx.arena.ceiling < math.huge then ctx.arena.ceiling - 20 else math.huge
	local dx, dz = aim.X - pos.X, aim.Z - pos.Z
	local rise = math.sqrt(dx * dx + dz * dz) * AIM_SLOPE
	local y = math.clamp(math.clamp(aim.Y, floorY, math.max(floorY, ceilY)), pos.Y - rise, pos.Y + rise)
	return {
		pos = Vector3.new(aim.X, y, aim.Z),
		attack = target.attack,
		reason = if swung then string.format("%s (%s)", target.reason, why or "line up") else target.reason,
	}
end

function Egg.resolve(ctx: Ctx, st: State, reason: string): Result
	local t = ctx.elapsed()
	return toResult(st, EggRules.resolveCap(st.rules, t), reason, t)
end

function Egg.stop(_ctx: Ctx, st: State)
	-- Everything the mode built lives under ctx.folder (the core destroys it); carried eggs go with their welds.
	st.stopped = true
end

return Egg
