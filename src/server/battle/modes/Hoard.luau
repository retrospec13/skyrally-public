--!strict
-- FOREST-BATTLE hoard (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L74) on the FOREST-1 windmill field and mill yard (plane
-- vs three bots). Scoring is HoardRules (carry cap, banking, hit drops, first to 20, cap and tie rules, all specced under
-- Lune); this module wires it to the battle framework and builds what the players see:
-- * Acorns (cap, nut, gold glint) hang at the plan's 18 pickup anchors and regrow on a timer after they are taken. A
--   vehicle that passes through one takes it (server proximity on the hull path, 10 at most in the sack).
-- * Four home rings at the field windmills (TrackData modes.battle.homeRings), one per seat (the plan lays spawn pad i
--   beside ring i), tinted with the seat colour, a light beacon and the owner's name over each. Flying through your
--   own ring banks the sack: a burst of glints, a flash and "+N" over the ring. A respawn jump is not flight
--   (HoardRules.advance): a crash at the own windmill puts the plane back on its pad across the ring, banking nothing.
-- * A landed item hit drops half the victim's sack: the acorns scatter, fall to the ground (down ray) and anyone can
--   take them once landed. A player who leaves drops its sack where it was last seen.
-- * Item pods: the anchors belong to the acorns, so every third anchor carries a level-one weapon pod 22 studs above
--   its acorn (Mode.itemPods replaces the core's default anchor pods).
-- * The board shows "banked +carried" in ranking order (the cap's tie rule, so the results never contradict it); the
--   objective line says what to do next and names the home ring's colour.
-- Bots (botGoal): chase the cheapest acorn (near, ahead, outside their turning circle, not contested by a closer bot;
-- they give up on one they keep missing), fly home when the sack is full, the win is in it, the clock runs out or the
-- acorns are far, raid a rich carrier when they hold a missile, and aim their items at the richest carrier near them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local battleShared = Shared:WaitForChild("battle")
local BattleRules = require(battleShared:WaitForChild("BattleRules"))
local HoardRules = require(battleShared:WaitForChild("HoardRules"))
local BattleCore = require(script.Parent.Parent.BattleCore)

type Ctx = BattleCore.Ctx
type Entrant = BattleCore.Entrant
type Result = BattleCore.Result

local okVfx, VfxAssets = pcall(require, Shared:WaitForChild("VfxAssets"))
local okFlip, FlipFx = pcall(require, Shared:WaitForChild("FlipFx"))

local Hoard = {}

Hoard.kind = "hoard"
Hoard.title = "HOARD"

-- OURS tuning.
local POD_EVERY = 3 -- every third anchor carries a weapon pod (six on FOREST-1)
local POD_LIFT = 22 -- studs above that anchor's acorn
local DROP_SPREAD = 14 -- dropped acorns scatter this far round the victim
local DROP_PROBE = 240 -- down ray reach for where a dropped acorn lands
local ACORN_REST = 2.2 -- a landed acorn's centre above the ground
local ACORN_GRAVITY = 120 -- fall animation (studs/s^2): readable, not Roblox's 196
local NEAR_WIN = 5 -- broadcast once when someone is this close to the win
local NAG_EVERY = 4 -- seconds between "not your ring" toasts per player
-- Bots. BattleBots flies planes at about 102 studs/s turning at most 80 degrees/s (its TUNE.plane): ~75 studs radius.
local BOT_TURN_DEG = 80
local CHASE_GIVE_UP = 7 -- seconds on one acorn (orbiting a missed one) before trying another
local SKIP_FOR = 6
local RAID_MIN = 4 -- a missile holder chases a rival carrying at least this many
local RAID_RANGE = 260
local ATTACK_RANGE = 320
local POD_DETOUR = 60

local ACORN_SCALE = 1.35
local NUT = Color3.fromRGB(184, 118, 52)
local CAP = Color3.fromRGB(106, 68, 36)
local CAP_RIM = Color3.fromRGB(84, 54, 30)
local GOLD = Color3.fromRGB(255, 214, 96)
local UNOWNED = Color3.fromRGB(150, 146, 138)
-- Seat tints, in HoardRules.RING_COLOURS order (BLUE, RED, GREEN, PURPLE).
local RING_TINT: { Color3 } = {
	Color3.fromRGB(70, 150, 255),
	Color3.fromRGB(240, 84, 70),
	Color3.fromRGB(96, 208, 92),
	Color3.fromRGB(176, 108, 240),
}
local RING_SEGMENTS = 20
local BEACON_HEIGHT = 70

local REASON_TEXT: { [string]: string } = {
	time = "time up - most acorns banked wins",
	qa = "ended early (QA) - ranked by acorns banked",
}

type RingView = {
	model: Model,
	glow: { BasePart },
	glowColour: Color3,
	emitter: ParticleEmitter,
	confetti: ParticleEmitter, -- confetti_burst_4x4 on a bank
	light: PointLight,
	label: TextLabel?,
	caption: string,
	token: number,
}

type Fall = {
	model: Model,
	from: Vector3,
	to: Vector3,
	start: number,
	dur: number,
}

type BotPlan = {
	target: number?,
	since: number,
	skip: { [number]: number }, -- acorn id -> battle time until which it is skipped
}

type State = {
	rules: HoardRules.State,
	cfg: HoardRules.Config,
	acornFolder: Folder,
	models: { [number]: Model }, -- acorn id -> model
	falls: { [number]: Fall },
	rings: { RingView },
	motion: { [string]: HoardRules.Motion }, -- where each entrant was at the last check (path sweeps, a leaver's drop)
	plans: { [string]: BotPlan },
	nagAt: { [string]: number },
	warned: { [string]: boolean },
	fullSaid: { [string]: boolean },
	rayParams: RaycastParams,
	stopped: boolean,
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

-- An acorn about 8 studs tall that reads at flying speed: round nut with a pointed tip, a wooden cap with a darker rim
-- and a stem, a neon glint on the nut and a slow gold sparkle. The model pivot is `pos` (PivotTo moves it as a unit).
local function buildAcorn(name: string, pos: Vector3, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = name
	local s = ACORN_SCALE
	local base = CFrame.new(pos)
	local nut = part("Nut", Enum.PartType.Ball, Vector3.new(3.6, 3.6, 3.6) * s, base * CFrame.new(0, -0.3 * s, 0), NUT, Enum.Material.SmoothPlastic, m)
	nut.Reflectance = 0.12
	part("Tip", Enum.PartType.Ball, Vector3.new(2, 2, 2) * s, base * CFrame.new(0, -1.9 * s, 0), NUT, Enum.Material.SmoothPlastic, m)
	-- Cylinders run along X: rolled a quarter turn they stand upright.
	part("Cap", Enum.PartType.Cylinder, Vector3.new(1.5, 4.1, 4.1) * s, base * CFrame.new(0, 1.25 * s, 0) * CFrame.Angles(0, 0, math.pi / 2), CAP, Enum.Material.Wood, m)
	part("CapRim", Enum.PartType.Cylinder, Vector3.new(0.5, 4.4, 4.4) * s, base * CFrame.new(0, 0.6 * s, 0) * CFrame.Angles(0, 0, math.pi / 2), CAP_RIM, Enum.Material.Wood, m)
	part("Stem", Enum.PartType.Block, Vector3.new(0.5, 1.3, 0.5) * s, base * CFrame.new(0.15 * s, 2.45 * s, 0) * CFrame.Angles(0, 0, -0.25), CAP, Enum.Material.Wood, m)
	local glint = part("Glint", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7) * s, base * CFrame.new(-0.95 * s, 0.1 * s, -1.25 * s), GOLD, Enum.Material.Neon, m)
	glint.CastShadow = false
	local light = Instance.new("PointLight")
	light.Color = GOLD
	light.Range = 10
	light.Brightness = 1.3
	light.Parent = nut
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "AcornGlint"
	-- A slow sparkle_star_4x4 twinkle (flip_v2 loop through Shared.FlipFx; old pickup_glint when it is missing).
	if okFlip and type(FlipFx) == "table" then
		FlipFx.apply(sparkle, "sparkle_star_4x4")
	else
		sparkle.Texture = texture("pickup_glint")
	end
	sparkle.Color = ColorSequence.new(GOLD)
	sparkle.LightEmission = 0.8
	sparkle.LightInfluence = 0
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.4, 1.5), NumberSequenceKeypoint.new(1, 0) })
	sparkle.Lifetime = NumberRange.new(0.5, 0.9)
	sparkle.Rate = 2.5
	sparkle.Speed = NumberRange.new(0.5, 1.5)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = nut
	m.PrimaryPart = nut
	nut.PivotOffset = nut.CFrame:ToObjectSpace(base)
	m.Parent = parent
	return m
end

-- A home ring: a rim of RING_SEGMENTS blocks in the seat tint with a neon inner band, standing square to its
-- fly-through axis. Owned rings get a light beacon and a name label; the invisible core holds the deposit burst.
local function buildRing(ring: HoardRules.Ring, colour: Color3, caption: string?, parent: Instance): RingView
	local m = Instance.new("Model")
	m.Name = ring.name
	local cf = CFrame.lookAt(ring.pos, ring.pos + ring.axis)
	local glowColour = colour:Lerp(Color3.new(1, 1, 1), 0.45)
	local glow: { BasePart } = {}
	local r = ring.radius
	local inner = r - 1.6
	for i = 1, RING_SEGMENTS do
		local a = (i - 1) * (2 * math.pi / RING_SEGMENTS)
		local spin = cf * CFrame.Angles(0, 0, a)
		part("Rim_" .. i, Enum.PartType.Block, Vector3.new(2 * math.pi * r / RING_SEGMENTS * 1.12, 2.4, 3.2), spin * CFrame.new(0, r, 0), colour, Enum.Material.SmoothPlastic, m)
		local g = part("Glow_" .. i, Enum.PartType.Block, Vector3.new(2 * math.pi * inner / RING_SEGMENTS * 1.12, 0.8, 1.6), spin * CFrame.new(0, inner, 0), glowColour, Enum.Material.Neon, m)
		g.CastShadow = false
		table.insert(glow, g)
	end
	local core = part("Core", Enum.PartType.Block, Vector3.new(1, 1, 1), cf, colour, Enum.Material.SmoothPlastic, m)
	core.Transparency = 1
	core.CastShadow = false
	local light = Instance.new("PointLight")
	light.Color = glowColour
	light.Range = 22
	light.Brightness = 0.9
	light.Parent = core
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DepositBurst"
	if okFlip and type(FlipFx) == "table" then
		FlipFx.apply(emitter, "sparkle_star_4x4")
	else
		emitter.Texture = texture("pickup_glint")
	end
	emitter.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, GOLD), ColorSequenceKeypoint.new(1, glowColour) })
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.6), NumberSequenceKeypoint.new(0.6, 2.2), NumberSequenceKeypoint.new(1, 0) })
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Rate = 120
	emitter.Speed = NumberRange.new(22, 40)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Enabled = false
	emitter.Parent = core
	-- Bank party: the rendered confetti_burst_4x4 (already coloured; OneShot over each particle's life), ~3 sheets.
	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "DepositConfetti"
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
	local label: TextLabel? = nil
	if caption then
		local beacon = part(
			"Beacon",
			Enum.PartType.Cylinder,
			Vector3.new(BEACON_HEIGHT, 1.6, 1.6),
			CFrame.new(ring.pos + Vector3.new(0, r + 2 + BEACON_HEIGHT / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			glowColour,
			Enum.Material.Neon,
			m
		)
		beacon.Transparency = 0.45
		beacon.CastShadow = false
		local gui = Instance.new("BillboardGui")
		gui.Name = "Owner"
		gui.Size = UDim2.new(0, 170, 0, 28) -- v21: smaller; the client hides it behind the HUD (BattleWorldLabel)
		gui.StudsOffset = Vector3.new(0, r + 6, 0)
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
		glow = glow,
		glowColour = glowColour,
		emitter = emitter,
		confetti = confetti,
		light = light,
		label = label,
		caption = caption or "",
		token = 0,
	}
end

-- The bank moment: glints and confetti burst from the ring, the inner band flashes white and "+N" shows over it.
local function burst(view: RingView, n: number)
	view.token += 1
	local token = view.token
	view.emitter.Enabled = true
	view.confetti.Enabled = true
	view.light.Brightness = 6
	for _, g in view.glow do
		g.Color = Color3.new(1, 1, 1)
	end
	local label = view.label
	if label then
		label.Text = string.format("+%d", n)
	end
	task.delay(0.35, function()
		if view.token ~= token or not view.model.Parent then
			return
		end
		view.emitter.Enabled = false
		view.confetti.Enabled = false
		view.light.Brightness = 0.9
		for _, g in view.glow do
			g.Color = view.glowColour
		end
	end)
	task.delay(1.6, function()
		local l = view.label
		if view.token == token and l and l.Parent then
			l.Text = view.caption
		end
	end)
end

local function removeModel(st: State, acornId: number)
	local m = st.models[acornId]
	if m then
		m:Destroy()
		st.models[acornId] = nil
	end
	st.falls[acornId] = nil
end

-- Dropped acorns tumble from where they were knocked loose to their landing spot (level path, falling height).
local function animateFalls(st: State, t: number)
	for id, f in st.falls do
		local k = math.clamp((t - f.start) / math.max(f.dur, 1e-3), 0, 1)
		local p = Vector3.new(f.from.X + (f.to.X - f.from.X) * k, f.from.Y + (f.to.Y - f.from.Y) * k * k, f.from.Z + (f.to.Z - f.from.Z) * k)
		if f.model.Parent then
			f.model:PivotTo(CFrame.new(p) * CFrame.Angles((1 - k) * 4, 0, (1 - k) * 2.5))
		end
		if k >= 1 then
			st.falls[id] = nil
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Rules plumbing
------------------------------------------------------------------------------------------------------------------------

local function anchorList(battle: any): { Vector3 }
	local out: { Vector3 } = {}
	if type(battle) == "table" and type(battle.pickupAnchors) == "table" then
		for _, a in battle.pickupAnchors do
			local v = if typeof(a) == "Vector3" then a elseif type(a) == "table" and typeof(a.pos) == "Vector3" then a.pos else nil
			if v then
				table.insert(out, v)
			end
		end
	end
	return out
end

-- The plan's home rings; an arena without them gets one at each spawn pad, facing the centre.
local function ringList(ctx: Ctx): { HoardRules.Ring }
	local out: { HoardRules.Ring } = {}
	if type(ctx.battle.homeRings) == "table" then
		for i, r in ctx.battle.homeRings do
			local ring = HoardRules.ringFromPlan(r, i)
			if ring then
				table.insert(out, ring)
			end
		end
	end
	if #out == 0 then
		for i, p in ctx.arena.spawns do
			local inward = Vector3.new(ctx.arena.center.X - p.X, 0, ctx.arena.center.Z - p.Z)
			table.insert(out, {
				name = "HomeRing_" .. tostring(i),
				pos = p,
				axis = if inward.Magnitude > 1e-3 then inward.Unit else Vector3.new(0, 0, -1),
				radius = 14,
			})
		end
		ctx.log("hoard: no homeRings in the plan, %d rings at the spawn pads", #out)
	end
	return out
end

local function colourName(index: number): string
	local names = HoardRules.RING_COLOURS
	return if index >= 1 then names[((index - 1) % #names) + 1] else "HOME"
end

local function ringNameOf(st: State, id: string): string
	local e = st.rules.entries[id]
	return colourName(if e then e.ring else 0)
end

local function refresh(ctx: Ctx, st: State)
	local ranking = HoardRules.ranking(st.rules)
	for _, e in ctx.entrants do
		if not e.spectator then
			ctx.setScore(e.id, HoardRules.boardScore(st.rules, e.id, ranking), HoardRules.scoreText(st.rules, e.id))
			ctx.setHud(e.id, HoardRules.hudText(st.rules, e.id, ringNameOf(st, e.id)))
		end
	end
end

local function toResult(st: State, winner: string?, ranking: { string }, reason: string): Result
	local texts: { [string]: string } = {}
	for _, id in ranking do
		texts[id] = HoardRules.resultText(st.rules, id)
	end
	return { winner = winner, ranking = ranking, reason = reason, texts = texts }
end

-- Clamped inside the play radius (a hit at the edge still drops reachable acorns).
local function insideArena(ctx: Ctx, p: Vector3): Vector3
	local a = ctx.arena
	local d = BattleRules.horizontal(p, a.center)
	local limit = a.radius * 0.92
	if d <= limit then
		return p
	end
	local k = limit / d
	return Vector3.new(a.center.X + (p.X - a.center.X) * k, p.Y, a.center.Z + (p.Z - a.center.Z) * k)
end

local function groundUnder(st: State, p: Vector3): Vector3
	local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -DROP_PROBE, 0), st.rayParams)
	if hit then
		return Vector3.new(p.X, hit.Position.Y + ACORN_REST, p.Z)
	end
	return p
end

-- n acorns knocked loose at `at`: they scatter, fall to the ground and become takeable once all have landed.
local function dropAcorns(ctx: Ctx, st: State, at: Vector3, n: number, t: number)
	if n <= 0 then
		return
	end
	local from = insideArena(ctx, at)
	local spots: { Vector3 } = {}
	local durs: { number } = {}
	local longest = 0
	for _, p in HoardRules.scatter(from, n, DROP_SPREAD) do
		local land = groundUnder(st, insideArena(ctx, p))
		local h = math.max(from.Y - land.Y, 0)
		local dur = math.clamp(math.sqrt(2 * h / ACORN_GRAVITY), 0.35, 1.4)
		table.insert(spots, land)
		table.insert(durs, dur)
		longest = math.max(longest, dur)
	end
	for i, a in HoardRules.addLoose(st.rules, spots, t, longest) do
		local m = buildAcorn("Dropped_" .. tostring(a.id), from, st.acornFolder)
		st.models[a.id] = m
		st.falls[a.id] = { model = m, from = from, to = a.pos, start = t, dur = durs[i] }
	end
end

local function onTaken(ctx: Ctx, st: State, e: Entrant, taken: { HoardRules.Acorn })
	for _, a in taken do
		if a.anchor then
			local m = st.models[a.id]
			if m then
				m.Parent = nil -- regrows in place (tick -> "ready")
			end
		else
			removeModel(st, a.id)
		end
	end
	local entry = st.rules.entries[e.id]
	local carried = if entry then entry.carried else 0
	ctx.log("hoard pickup %s n=%d carry=%d/%d", e.name, #taken, carried, st.cfg.carryMax)
	if carried >= st.cfg.carryMax then
		if not st.fullSaid[e.id] then
			st.fullSaid[e.id] = true
			ctx.toast(e.id, string.format("SACK FULL - fly through your %s ring!", ringNameOf(st, e.id)), "info")
		end
	end
end

local function onBanked(ctx: Ctx, st: State, e: Entrant, n: number)
	local entry = st.rules.entries[e.id]
	if not entry then
		return
	end
	st.fullSaid[e.id] = nil
	local view = st.rings[entry.ring]
	if view then
		burst(view, n)
	end
	ctx.log("hoard bank %s +%d total=%d/%d ring=%d", e.name, n, entry.deposited, st.cfg.depositToWin, entry.ring)
	ctx.toast(e.id, string.format("+%d BANKED  -  %d/%d", n, entry.deposited, st.cfg.depositToWin), "good")
	local need = st.cfg.depositToWin - entry.deposited
	if need > 0 and need <= NEAR_WIN and not st.warned[e.id] then
		st.warned[e.id] = true
		ctx.toast(nil, string.format("%s has %d banked - %d to win!", string.upper(e.name), entry.deposited, need), "info")
	end
end

-- A player flying a full or part sack through someone else's ring: a reminder which ring is theirs.
local function nagForeign(ctx: Ctx, st: State, e: Entrant, from: Vector3?, to: Vector3, t: number)
	local entry = st.rules.entries[e.id]
	if not entry or entry.carried <= 0 then
		return
	end
	local other = HoardRules.foreignRing(st.rules, e.id, from, to)
	if other and t - (st.nagAt[e.id] or -math.huge) >= NAG_EVERY then
		st.nagAt[e.id] = t
		ctx.toast(e.id, string.format("Not yours - your home is the %s ring", ringNameOf(st, e.id)), "bad")
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Mode
------------------------------------------------------------------------------------------------------------------------

-- Bots fill the field up to one entrant per home ring (BattleCore fieldSize): FOREST-1 has four rings, so its field
-- stays four until the arena gets a ring per seat (docs/design/BATTLE_MAPS_V2.md).
function Hoard.fieldSize(battle: any, arena: BattleRules.Arena): number
	local n = 0
	if type(battle) == "table" and type(battle.homeRings) == "table" then
		for i, r in battle.homeRings do
			if HoardRules.ringFromPlan(r, i) then
				n += 1
			end
		end
	end
	return if n > 0 then n else #arena.spawns
end

function Hoard.itemPods(ctx: Ctx): { BattleRules.PodSpec }
	local out: { BattleRules.PodSpec } = {}
	local types = BattleRules.LEVEL_ONE_SET
	for i, p in HoardRules.podSpots(anchorList(ctx.battle), POD_EVERY, POD_LIFT, ctx.arena.ceiling) do
		table.insert(out, { pos = p, podType = types[((i - 1) % #types) + 1], respawn = BattleRules.POD_RESPAWN })
	end
	return out
end

function Hoard.start(ctx: Ctx): State
	local seats: { HoardRules.Seat } = {}
	for _, e in ctx.entrants do
		if not e.spectator then
			table.insert(seats, { id = e.id, isPlayer = e.isPlayer, slot = e.slot })
		end
	end
	local cfg = HoardRules.config(ctx.rules)
	local anchors = anchorList(ctx.battle)
	local rings = ringList(ctx)
	local rules = HoardRules.new(seats, anchors, rings, cfg)

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.RespectCanCollide = true
	rp.IgnoreWater = false -- a dropped acorn floats on a pond
	local exclude: { Instance } = { ctx.folder }
	for _, name in { "Planes", "SkyRallyItemFX" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	rp.FilterDescendantsInstances = exclude

	local acornFolder = Instance.new("Folder")
	acornFolder.Name = "HoardAcorns"
	acornFolder.Parent = ctx.folder
	local ringFolder = Instance.new("Folder")
	ringFolder.Name = "HoardRings"
	ringFolder.Parent = ctx.folder

	local st: State = {
		rules = rules,
		cfg = cfg,
		acornFolder = acornFolder,
		models = {},
		falls = {},
		rings = {},
		motion = {},
		plans = {},
		nagAt = {},
		warned = {},
		fullSaid = {},
		rayParams = rp,
		stopped = false,
	}
	for _, a in rules.acorns do
		st.models[a.id] = buildAcorn(string.format("Acorn_%02d", a.id), a.pos, acornFolder)
	end
	for i, ring in rings do
		local owners: { string } = {}
		for _, e in ctx.entrants do
			local entry = rules.entries[e.id]
			if entry and entry.ring == i then
				table.insert(owners, string.upper(e.name))
			end
		end
		local owned = #owners > 0
		local tint = if owned then RING_TINT[((i - 1) % #RING_TINT) + 1] else UNOWNED
		local view = buildRing(ring, tint, if owned then "HOME  " .. table.concat(owners, " / ") else nil, ringFolder)
		view.model:SetAttribute("HomeRing", i)
		view.model:SetAttribute("RingColour", colourName(i))
		table.insert(st.rings, view)
	end
	refresh(ctx, st)
	ctx.log(
		"hoard start entrants=%d anchors=%d rings=%d carry=%d win=%d respawn=%.0f drop=%.2f",
		#seats,
		#anchors,
		#rings,
		cfg.carryMax,
		cfg.depositToWin,
		cfg.respawn,
		cfg.hitDropFraction
	)
	return st
end

function Hoard.step(ctx: Ctx, st: State, _dt: number)
	if st.stopped then
		return
	end
	local t = ctx.elapsed()
	for _, ev in HoardRules.tick(st.rules, t) do
		local a = ev.acorn
		if ev.kind == "ready" and a.anchor then
			local m = st.models[a.id]
			if m then
				m.Parent = st.acornFolder
			end
		elseif ev.kind == "expired" then
			removeModel(st, a.id)
		end
	end
	animateFalls(st, t)
	local dirty = false
	for _, e in ctx.entrants do
		if not e.out and not e.spectator then
			local pos = ctx.position(e.id)
			if pos then
				local motion = st.motion[e.id]
				if not motion then
					motion = HoardRules.newMotion()
					st.motion[e.id] = motion
				end
				-- nil after a teleport (crash respawn, boundary put-back): only where it is now counts.
				local prev = HoardRules.advance(st.cfg, motion, pos, t)
				local taken = HoardRules.collect(st.rules, e.id, prev, pos, t)
				if #taken > 0 then
					onTaken(ctx, st, e, taken)
					dirty = true
				end
				local banked = HoardRules.deposit(st.rules, e.id, prev, pos, t)
				if banked > 0 then
					onBanked(ctx, st, e, banked)
					dirty = true
					local winner = HoardRules.winner(st.rules)
					if winner then
						refresh(ctx, st)
						local w = ctx.byId[winner]
						ctx.log("hoard win %s banked=%d at=%.1f", if w then w.name else winner, st.rules.entries[winner].deposited, t)
						ctx.finish(toResult(st, winner, HoardRules.ranking(st.rules), string.format("first to %d acorns banked", st.cfg.depositToWin)))
						return
					end
				elseif e.isPlayer then
					nagForeign(ctx, st, e, prev, pos, t)
				end
			end
		end
	end
	if dirty then
		refresh(ctx, st)
	end
end

function Hoard.onHit(ctx: Ctx, st: State, victim: Entrant, attacker: Entrant?, source: string, pos: Vector3)
	local t = ctx.elapsed()
	local n = HoardRules.hit(st.rules, victim.id, if attacker then attacker.id else nil, t)
	local entry = st.rules.entries[victim.id]
	ctx.log(
		"hoard hit victim=%s by=%s source=%s dropped=%d carry=%d",
		victim.name,
		if attacker then attacker.name else "self",
		source,
		n,
		if entry then entry.carried else 0
	)
	if n > 0 then
		st.fullSaid[victim.id] = nil
		dropAcorns(ctx, st, ctx.position(victim.id) or pos, n, t)
		ctx.toast(victim.id, string.format("HIT! You dropped %d acorn%s", n, if n == 1 then "" else "s"), "bad")
		if attacker then
			ctx.toast(attacker.id, string.format("HIT %s - %d acorn%s loose!", string.upper(victim.name), n, if n == 1 then "" else "s"), "good")
		end
		refresh(ctx, st)
	elseif attacker then
		ctx.toast(attacker.id, string.format("HIT %s!", string.upper(victim.name)), "good")
	end
end

function Hoard.onLeave(ctx: Ctx, st: State, entrant: Entrant)
	local t = ctx.elapsed()
	local n = HoardRules.leave(st.rules, entrant.id, t)
	local motion = st.motion[entrant.id]
	local last = if motion then motion.last else nil
	ctx.log("hoard left %s dropped=%d", entrant.name, n)
	if n > 0 and last then
		dropAcorns(ctx, st, last, n, t)
	end
	refresh(ctx, st)
end

------------------------------------------------------------------------------------------------------------------------
-- Bots
------------------------------------------------------------------------------------------------------------------------

local function turnRadius(e: Entrant): number
	local bot = e.bot
	local speed = if bot then math.max(bot.speed, bot.baseSpeed) else 102
	return math.max(speed, 40) / math.rad(BOT_TURN_DEG)
end

-- The richest rival in range carrying at least minCarry (or any rival whose sack would win it the battle).
local function richestRival(ctx: Ctx, st: State, selfId: string, pos: Vector3, range: number, minCarry: number): Entrant?
	local best: Entrant? = nil
	local bestValue = 0
	for _, o in ctx.alive() do
		local entry = st.rules.entries[o.id]
		local opos = if o.id ~= selfId then ctx.position(o.id) else nil
		if entry and opos and (opos - pos).Magnitude <= range and entry.carried > 0 then
			local threat = entry.deposited + entry.carried >= st.cfg.depositToWin
			local value = entry.carried + (if threat then 100 else 0)
			if (entry.carried >= minCarry or threat) and value > bestValue then
				best, bestValue = o, value
			end
		end
	end
	return best
end

-- Acorns other bots are heading for, with their distance to them (a closer claimant makes an acorn expensive).
local function claimsAgainst(ctx: Ctx, st: State, selfId: string): { [number]: number }
	local out: { [number]: number } = {}
	for id, plan in st.plans do
		local target = plan.target
		local other = ctx.byId[id]
		if id ~= selfId and target and other and not other.out then
			local a = HoardRules.find(st.rules, target)
			local p = ctx.position(id)
			if a and p then
				local d = (a.pos - p).Magnitude
				out[target] = math.min(out[target] or math.huge, d)
			end
		end
	end
	return out
end

local function planOf(st: State, id: string): BotPlan
	local plan = st.plans[id]
	if not plan then
		plan = { target = nil, since = 0, skip = {} }
		st.plans[id] = plan
	end
	return plan
end

function Hoard.botGoal(ctx: Ctx, st: State, bot: Entrant): any
	local entry = st.rules.entries[bot.id]
	local pos = ctx.position(bot.id)
	if not entry or not pos or st.stopped then
		return nil
	end
	local fwd = ctx.forward(bot.id) or Vector3.new(0, 0, -1)
	local t = ctx.elapsed()
	local plan = planOf(st, bot.id)
	local radius = turnRadius(bot)
	local skip: { [number]: boolean } = {}
	for id, untilT in plan.skip do
		if untilT > t then
			skip[id] = true
		else
			plan.skip[id] = nil
		end
	end
	local acorn = HoardRules.pickAcorn(st.rules, pos, fwd, t, {
		skip = skip,
		claims = claimsAgainst(ctx, st, bot.id),
		current = plan.target,
		turnRadius = radius,
	})
	local rich = richestRival(ctx, st, bot.id, pos, ATTACK_RANGE, 2)
	local attack = if rich then rich.id else nil
	local ring = st.rules.rings[entry.ring]
	local speed = if bot.bot then bot.bot.baseSpeed else 102
	local home, why = HoardRules.botWantsHome(entry, st.cfg, {
		nearestAcorn = if acorn then (acorn.pos - pos).Magnitude else nil,
		homeDist = if ring then (ring.pos - pos).Magnitude else math.huge,
		timeLeft = ctx.timeLeft(),
		speed = speed,
	})

	local goal: Vector3
	local reason: string
	if home and ring then
		plan.target = nil
		goal, reason = HoardRules.ringAim(ring, pos), "home " .. why
	else
		local color = ctx.holding(bot.id)
		local raid = if color == "red" and entry.carried < st.cfg.carryMax then richestRival(ctx, st, bot.id, pos, RAID_RANGE, RAID_MIN) else nil
		local raidPos = if raid then ctx.position(raid.id) else nil
		local pod = if not color and entry.carried < st.cfg.carryMax then ctx.nearestPod(bot.id) else nil
		if raid and raidPos then
			plan.target = nil
			goal, reason, attack = raidPos, "raid", raid.id
		elseif pod and (pod.pos - pos).Magnitude <= POD_DETOUR then
			goal, reason = pod.pos, "pod"
		elseif acorn then
			if plan.target ~= acorn.id then
				plan.target = acorn.id
				plan.since = t
			elseif t - plan.since > CHASE_GIVE_UP then
				-- Kept missing it (orbiting, or someone keeps beating it there): try another for a while.
				plan.skip[acorn.id] = t + SKIP_FOR
				plan.target = nil
			end
			goal, reason = acorn.pos, "acorn"
		elseif pod then
			goal, reason = pod.pos, "pod"
		else
			local target = rich or ctx.nearestOpponent(bot.id)
			local tpos = if target then ctx.position(target.id) else nil
			if target and tpos then
				goal, reason, attack = tpos, "hunt", target.id
			else
				goal, reason = ctx.arena.center, "centre"
			end
		end
	end
	if HoardRules.turnBlocked(pos, fwd, goal, radius) then
		goal, reason = HoardRules.openTurn(pos, fwd, goal), "wide turn"
	end
	return { pos = goal, attack = attack, reason = reason }
end

function Hoard.resolve(_ctx: Ctx, st: State, reason: string): Result
	local winner, ranking = HoardRules.resolveCap(st.rules)
	local text = REASON_TEXT[reason] or reason
	if reason == "time" and not winner then
		text = "time up - nobody banked an acorn"
	end
	return toResult(st, winner, ranking, text)
end

function Hoard.stop(_ctx: Ctx, st: State)
	-- Everything visual is under ctx.folder (destroyed by the core), except the taken anchor acorns waiting to regrow:
	-- they sit unparented, so they are destroyed here. Stray burst timers check the ring model's parent.
	st.stopped = true
	for _, m in st.models do
		m:Destroy()
	end
	table.clear(st.falls)
	table.clear(st.models)
end

return Hoard
