--!strict
-- v37 item spectacle (owner 2026-11-10: "the special power ups are boring as all get out"; the bar is Mario Kart 8 /
-- Diddy Kong Racing: every use is an event you see, hear and feel, as the user and as the victim). ItemClient forwards
-- every ItemFx (everyone) and ItemEffect (this player) here after its own handling; HudExtras calls landSting when the
-- roulette lands. The server decides every hit, speed and reward; this module only draws and plays sound.
--
-- What it adds on top of ItemClient / ItemsV4Fx (which keep the classic bubbles, beams, bursts and auras):
--   * world: a lightning bolt that really strikes from the sky (jagged Beams, a light spike, thunder), a big bomb
--     blast with a flash and shock rings, a rocket's comet trail of fire, golden wingtip ribbons and a gold outline,
--     frost that ices the victim over (outline, snowflakes, shards), a coin fountain, a boost's tail flare, a shield's
--     raise ring, and missile copies that wear their item (snow for frost, gold glints for coins).
--   * this player's screen: brief edge pulses and a short flash (edges only, never the road), the hit payoff (flash,
--     shake, hurt sound) and a recover chime when the spin-out ends.
--   * sounds: each item's own cue at use, hit and roulette land (existing project audio and Roblox library audio
--     already in the ledger; docs/ASSETS_TOOLBOX_TEMP.md).
-- Performance: every emitter rate goes through Settings.particleScale() (FrameGovernor caps it), world effects farther
-- than SHOW_RANGE from the camera are skipped, and everything timed is cleaned in step().
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local UiV2Icons = require(Shared:WaitForChild("UiV2Icons")) :: { [string]: string }

local Sfx = require(script.Parent:WaitForChild("Sfx"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local ToolboxCues = require(script.Parent:WaitForChild("ToolboxCues"))
local Sfx37 = require(script.Parent:WaitForChild("Sfx37"))

local LocalPlayer = Players.LocalPlayer

local ItemShow = {}

type Burst = (name: string, pos: Vector3, tint: Color3?, scale: number?) -> ()
local burst: Burst = function() end
local kick: (amount: number) -> () = function() end

local SHOW_RANGE = 900 -- studs from the camera: farther world effects are skipped
local CREAM = Color3.fromRGB(255, 244, 214)

local rng = Random.new()

local function rgb(id: string): Color3
	local t = ItemRules.COLOR_RGB[id] or { 255, 255, 255 }
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function rate(base: number): number
	return base * math.clamp(Settings.particleScale(), 0.2, 1)
end

local function hullOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local p = model.PrimaryPart
	return if p and p:IsA("BasePart") then p else nil
end

local function isOwn(model: any): boolean
	return typeof(model) == "Instance"
		and (model.Name == "Car_" .. LocalPlayer.Name or model.Name == "Plane_" .. LocalPlayer.Name)
end

local function camPos(): Vector3?
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

local function inRange(pos: Vector3): boolean
	local c = camPos()
	return c == nil or (c - pos).Magnitude <= SHOW_RANGE
end

local function ownHull(): BasePart?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	local m = planes:FindFirstChild("Car_" .. LocalPlayer.Name) or planes:FindFirstChild("Plane_" .. LocalPlayer.Name)
	return hullOf(m)
end

local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

------------------------------------------------------------------------------------------------------------------------
-- Timed instances (destroyed in step) and emitters switched off before they go
------------------------------------------------------------------------------------------------------------------------

type Timed = { inst: Instance, stopAt: number, dieAt: number, emitters: { ParticleEmitter }, trails: { Trail } }
local timed: { Timed } = {}

local function keep(inst: Instance, seconds: number, tail: number?)
	local now = os.clock()
	local emitters: { ParticleEmitter } = {}
	local trails: { Trail } = {}
	for _, d in inst:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(emitters, d)
		elseif d:IsA("Trail") then
			table.insert(trails, d)
		end
	end
	if inst:IsA("ParticleEmitter") then
		table.insert(emitters, inst)
	end
	table.insert(timed, { inst = inst, stopAt = now + seconds, dieAt = now + seconds + (tail or 1.2), emitters = emitters, trails = trails })
end

local function emitter(props: { [string]: any }): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.LightInfluence = 0
	for k, v in props do
		(pe :: any)[k] = v
	end
	return pe
end

local function attach(parent: Instance, pos: Vector3, name: string?): Attachment
	local a = Instance.new("Attachment")
	a.Name = name or "ItemShow"
	a.Position = pos
	a.Parent = parent
	return a
end

local function worldAttach(pos: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Name = "ItemShow"
	a.WorldPosition = pos
	a.Parent = workspace.Terrain
	return a
end

-- A ribbon between two attachments on the hull, fading over `life` seconds.
local function ribbon(hull: BasePart, a: Vector3, b: Vector3, color: ColorSequence, life: number, light: number?): Attachment
	local a0 = attach(hull, a, "ItemShowRibbon")
	local a1 = attach(hull, b, "ItemShowRibbonB")
	a0.Destroying:Once(function()
		a1:Destroy()
	end)
	local tr = Instance.new("Trail")
	tr.Attachment0 = a0
	tr.Attachment1 = a1
	tr.Texture = tex("trail_soft")
	tr.Lifetime = life
	tr.MinLength = 0.2
	tr.FaceCamera = true
	tr.LightEmission = light or 1
	tr.LightInfluence = 0
	tr.Color = color
	tr.Transparency = ns({ { 0, 0.05 }, { 0.7, 0.45 }, { 1, 1 } })
	tr.WidthScale = ns({ { 0, 1 }, { 1, 0.3 } })
	tr.Parent = a0
	return a0
end

-- An outline on a whole vehicle model for `seconds` (Highlight; at most HIGHLIGHT_MAX of ours at once).
local HIGHLIGHT_MAX = 6
local highlights: { [Model]: Highlight } = {}
local function outline(model: Model, fill: Color3, fillT: number, line: Color3, seconds: number)
	local old = highlights[model]
	if old and old.Parent then
		old:Destroy()
	end
	local n = 0
	for _ in highlights do
		n += 1
	end
	if n >= HIGHLIGHT_MAX then
		return
	end
	local h = Instance.new("Highlight")
	h.Name = "ItemShowOutline"
	h.FillColor = fill
	h.FillTransparency = fillT
	h.OutlineColor = line
	h.OutlineTransparency = 0.05
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	highlights[model] = h
	keep(h, seconds, 0)
end

------------------------------------------------------------------------------------------------------------------------
-- This player's screen: edge pulses and a short flash (edges only: the road in the middle always stays clear)
------------------------------------------------------------------------------------------------------------------------

type Pulse = { color: Color3, peak: number, t0: number, dur: number, hold: number }
local screen: ScreenGui? = nil
local edges: { Frame } = {}
local flashFrame: Frame? = nil
local pulse: Pulse? = nil
local flashState = { peak = 0, t0 = 0, dur = 0.1 }

local function buildScreen()
	if screen and screen.Parent then
		return
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyItemShow"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 6 -- over the speed lines (5), under the incoming badge (7)
	edges = {}
	-- Four edge bands, each fading to clear toward the middle.
	local specs = {
		{ anchor = Vector2.new(0.5, 0), pos = UDim2.fromScale(0.5, 0), size = UDim2.fromScale(1, 0.22), rot = 90, flip = false },
		{ anchor = Vector2.new(0.5, 1), pos = UDim2.fromScale(0.5, 1), size = UDim2.fromScale(1, 0.22), rot = 90, flip = true },
		{ anchor = Vector2.new(0, 0.5), pos = UDim2.fromScale(0, 0.5), size = UDim2.fromScale(0.16, 1), rot = 0, flip = false },
		{ anchor = Vector2.new(1, 0.5), pos = UDim2.fromScale(1, 0.5), size = UDim2.fromScale(0.16, 1), rot = 0, flip = true },
	}
	for i, s in specs do
		local f = Instance.new("Frame")
		f.Name = "Edge" .. i
		f.AnchorPoint = s.anchor
		f.Position = s.pos
		f.Size = s.size
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BackgroundTransparency = 1
		f.Active = false
		local g = Instance.new("UIGradient")
		g.Rotation = s.rot
		g.Transparency = if s.flip
			then NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
			else NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		f.Parent = sg
		table.insert(edges, f)
	end
	local fl = Instance.new("Frame")
	fl.Name = "Flash"
	fl.Size = UDim2.fromScale(1, 1)
	fl.BorderSizePixel = 0
	fl.BackgroundColor3 = Color3.new(1, 1, 1)
	fl.BackgroundTransparency = 1
	fl.Active = false
	fl.Parent = sg
	flashFrame = fl
	sg.Parent = pg
	screen = sg
end

-- Coloured edges rising to `peak` opacity, held `hold` s, then fading over the rest of `dur`.
function ItemShow.edgePulse(color: Color3, peak: number, dur: number, hold: number?)
	buildScreen()
	pulse = { color = color, peak = math.clamp(peak, 0, 0.35), t0 = os.clock(), dur = math.max(dur, 0.05), hold = hold or 0 }
	for _, f in edges do
		f.BackgroundColor3 = color
	end
end

-- A whole-screen flash: short (<= 0.15 s at full) and never fully opaque.
function ItemShow.flash(color: Color3, peak: number, dur: number?)
	buildScreen()
	local fl = flashFrame
	if fl then
		fl.BackgroundColor3 = color
	end
	flashState.peak = math.clamp(peak, 0, 0.3)
	flashState.t0 = os.clock()
	flashState.dur = math.clamp(dur or 0.12, 0.04, 0.3)
end

local function stepScreen(now: number)
	local p = pulse
	if p then
		local t = now - p.t0
		local a: number
		if t < 0.06 then
			a = p.peak * (t / 0.06)
		elseif t < 0.06 + p.hold then
			a = p.peak
		else
			a = p.peak * math.max(0, 1 - (t - 0.06 - p.hold) / math.max(0.05, p.dur - 0.06 - p.hold))
		end
		for _, f in edges do
			f.BackgroundTransparency = 1 - a
		end
		if t > p.dur + p.hold then
			pulse = nil
			for _, f in edges do
				f.BackgroundTransparency = 1
			end
		end
	end
	local fl = flashFrame
	if fl and flashState.peak > 0 then
		local t = (now - flashState.t0) / flashState.dur
		if t >= 1 then
			flashState.peak = 0
			fl.BackgroundTransparency = 1
		else
			fl.BackgroundTransparency = 1 - flashState.peak * (1 - t) * (1 - t)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Lightning that strikes from the sky
------------------------------------------------------------------------------------------------------------------------

local STORM_VIOLET = Color3.fromRGB(196, 170, 255)

local function boltPoints(top: Vector3, bottom: Vector3, n: number, jag: number): { Vector3 }
	local pts = {}
	for i = 0, n do
		local t = i / n
		local p = top:Lerp(bottom, t)
		if i > 0 and i < n then
			local k = jag * (1 - t * 0.6)
			p += Vector3.new(rng:NextNumber(-1, 1) * k, rng:NextNumber(-0.3, 0.3) * k, rng:NextNumber(-1, 1) * k)
		end
		table.insert(pts, p)
	end
	return pts
end

local function drawBolt(pts: { Vector3 }, core: number, glow: number, color: Color3): Instance
	local holder = Instance.new("Folder")
	holder.Name = "ItemShowBolt"
	local atts: { Attachment } = {}
	for _, p in pts do
		local a = Instance.new("Attachment")
		a.WorldPosition = p
		a.Parent = workspace.Terrain
		table.insert(atts, a)
		local tag = Instance.new("ObjectValue")
		tag.Value = a
		tag.Parent = holder
	end
	for i = 1, #atts - 1 do
		for layer = 1, 2 do
			local b = Instance.new("Beam")
			b.Attachment0 = atts[i]
			b.Attachment1 = atts[i + 1]
			b.FaceCamera = true
			b.LightEmission = 1
			b.LightInfluence = 0
			b.Segments = 1
			if layer == 1 then
				b.Width0, b.Width1 = core, core * 0.85
				b.Color = ColorSequence.new(Color3.new(1, 1, 1))
				b.Transparency = NumberSequence.new(0)
			else
				b.Width0, b.Width1 = glow, glow * 0.8
				b.Texture = tex("glow_soft")
				b.Color = ColorSequence.new(color)
				b.Transparency = NumberSequence.new(0.35)
			end
			b.Parent = atts[i]
		end
	end
	holder.Parent = workspace.Terrain
	holder.Destroying:Once(function()
		for _, a in atts do
			a:Destroy()
		end
	end)
	return holder
end

-- A bolt from high above down to pos: two quick flickers, a light spike, the blast at the ground, the thunder clap.
function ItemShow.lightning(pos: Vector3, onMe: boolean)
	if not inRange(pos) then
		return
	end
	local top = pos + Vector3.new(rng:NextNumber(-35, 35), 300, rng:NextNumber(-35, 35))
	-- Under a roof (a cave, a tunnel) the bolt comes out of the ceiling instead of through it.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = {}
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		table.insert(skip, planes)
	end
	params.FilterDescendantsInstances = skip
	local roof = workspace:Raycast(pos + Vector3.new(0, 4, 0), top - pos, params)
	if roof then
		top = roof.Position - (top - pos).Unit * 2
	end
	local first = drawBolt(boltPoints(top, pos, 9, 26), 2.6, 14, STORM_VIOLET)
	local light = worldAttach(pos + Vector3.new(0, 6, 0))
	local pl = Instance.new("PointLight")
	pl.Color = STORM_VIOLET
	pl.Range = 60
	pl.Brightness = 12
	pl.Shadows = false
	pl.Parent = light
	keep(light, 0.35, 0)
	task.delay(0.07, function()
		first:Destroy()
	end)
	task.delay(0.12, function()
		local second = drawBolt(boltPoints(top, pos, 9, 30), 3.2, 18, STORM_VIOLET)
		-- a forked branch off the upper third
		local pts = boltPoints(top, pos, 9, 30)
		local fork = drawBolt(boltPoints(pts[4], pts[4] + Vector3.new(rng:NextNumber(-60, 60), -90, rng:NextNumber(-60, 60)), 4, 14), 1.4, 7, STORM_VIOLET)
		task.delay(0.22, function()
			second:Destroy()
			fork:Destroy()
		end)
	end)
	burst("missileBlast", pos, STORM_VIOLET, 1.8)
	burst("hitRing", pos + Vector3.new(0, 1, 0), STORM_VIOLET, 2.2)
	burst("stormSparks", pos, nil, 1)
	-- Thunder: the crack at once, the roll a beat later. Heard from far away.
	ToolboxCues.playAt("storm_thunder_2", pos, 1.15, if onMe then 1.8 else 1.4)
	task.delay(0.25, function()
		ToolboxCues.playAt("storm_thunder_1", pos, 0.85, if onMe then 1.6 else 1.2)
	end)
	Sfx.at("crash_hit", pos, if onMe then 0.85 else 0.6, 0.7)
	local c = camPos()
	local d = if c then (c - pos).Magnitude else 0
	if onMe or d < 180 then
		ItemShow.flash(Color3.fromRGB(235, 228, 255), if onMe then 0.5 else 0.42 * (1 - d / 180) + 0.1, 0.14)
		kick(if onMe then 0.7 else 0.35 * (1 - d / 180))
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Per-item world moments
------------------------------------------------------------------------------------------------------------------------

local function seconds(payload: { [string]: any }, fallback: number): number
	local s = tonumber(payload.seconds)
	return math.clamp(s or fallback, 0.2, 10)
end

local function tailOf(hull: BasePart): Vector3
	return Vector3.new(0, 0, hull.Size.Z * 0.5 + 0.5)
end

-- Rocket Rush: a comet. A wide fire ribbon and a roaring jet out of the tail, a smoke wake, a shock ring at the start.
local function rocket(model: Model, hull: BasePart, secs: number)
	local tail = tailOf(hull)
	-- The chase camera sits right behind its own vehicle: there the jet is shorter and slimmer so the road stays clear
	-- (Studio ob1: the full jet filled the bottom of the screen).
	local mine = isOwn(model)
	local k = if mine then 0.55 else 1
	local half = math.max(1.2, hull.Size.Y * 0.45)
	local fire = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 210)), ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 170, 40)), ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 60, 20)) })
	-- Ribbons only on other racers: on your own vehicle a world-space trail streams back through the chase camera.
	if not mine then
		keep(ribbon(hull, tail + Vector3.new(0, half, 0), tail + Vector3.new(0, -half, 0), fire, 0.7), secs, 0.8)
	end
	local jet = attach(hull, tail + Vector3.new(0, 0, 0.5), "ItemShowJet")
	jet.Orientation = Vector3.new(0, 180, 0)
	local flame = emitter({
		Rate = rate(110),
		Lifetime = NumberRange.new(0.25 * k, 0.4 * k),
		Speed = NumberRange.new(30, 46),
		SpreadAngle = Vector2.new(9, 9),
		Size = ns({ { 0, 4.2 * k }, { 0.5, 3 * k }, { 1, 0.8 * k } }),
		Transparency = ns({ { 0, 0 }, { 0.75, 0.2 }, { 1, 1 } }),
		Color = fire,
		LightEmission = 0.9,
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		EmissionDirection = Enum.NormalId.Front,
	})
	FlipFx.apply(flame, "fire_loop_8x8")
	flame.Parent = jet
	local smoke = emitter({
		Rate = rate(if Settings.heavySmoke() then 26 else 10),
		Lifetime = NumberRange.new(0.8, 1.2),
		Speed = NumberRange.new(4, 8),
		SpreadAngle = Vector2.new(14, 14),
		Size = ns({ { 0, 2.5 }, { 1, 6 } }),
		Transparency = ns({ { 0, 0.4 }, { 1, 1 } }),
		Color = ColorSequence.new(Color3.fromRGB(120, 110, 104), Color3.fromRGB(190, 182, 176)),
		LightInfluence = 1,
		ZOffset = -1,
		EmissionDirection = Enum.NormalId.Front,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
	})
	FlipFx.apply(smoke, "smoke_puff_8x8")
	smoke.Parent = jet
	-- v37 fix (coordinator: SPACE-4 washed orange): a small glow on other racers only; on your own vehicle a light pool
	-- tints the whole road the chase camera looks at.
	if not mine then
		local pl = Instance.new("PointLight")
		pl.Color = Color3.fromRGB(255, 160, 60)
		pl.Range = 12
		pl.Brightness = 1.5
		pl.Shadows = false
		pl.Parent = jet
	end
	keep(jet, secs, 1.2)
	-- The roar rides the jet for the length of the rush only (own: close behind the camera, so quieter), then fades.
	Sfx37.loopOn("rocket_loop", jet, if mine then 0.32 else 0.8, secs, 140)
	burst("hitRing", hull.Position, Color3.fromRGB(255, 170, 60), if mine then 1.3 else 2.0)
	burst("missileLaunch", hull.Position + hull.CFrame:VectorToWorldSpace(tail), Color3.fromRGB(255, 170, 60), if mine then 1.0 else 2.2)
	ToolboxCues.playAt("geyser_whoosh", hull.Position, 1.05, if isOwn(model) then 2 else 1.4)
end

-- Golden Wings: gold wingtip ribbons, a gold outline and glow, a shower of sparkles, a ring at the start.
local function golden(model: Model, hull: BasePart, secs: number)
	local gold = rgb("golden_wings")
	local span = math.max(hull.Size.X * 0.5, 3)
	local sides: { number } = if isOwn(model) then {} else { -1, 1 }
	for _, side in sides do
		keep(ribbon(hull, Vector3.new(side * span, 0.4, 0), Vector3.new(side * span, -0.4, 0), ColorSequence.new(Color3.fromRGB(255, 250, 200), gold), 0.9), secs, 1)
	end
	outline(model, gold, 0.8, Color3.fromRGB(255, 236, 150), secs)
	local core = attach(hull, Vector3.new(0, 1, 0), "ItemShowGold")
	local sparkle = emitter({
		Rate = rate(40),
		Lifetime = NumberRange.new(0.6, 1.0),
		Speed = NumberRange.new(4, 10),
		SpreadAngle = Vector2.new(180, 180),
		Size = ns({ { 0, 1.8 }, { 0.5, 1.4 }, { 1, 0 } }),
		Transparency = ns({ { 0, 0 }, { 1, 0.3 } }),
		Color = ColorSequence.new(CREAM, gold),
		LightEmission = 1,
		Acceleration = Vector3.new(0, -8, 0),
		Rotation = NumberRange.new(-20, 20),
	})
	FlipFx.apply(sparkle, "sparkle_star_4x4")
	sparkle.Parent = core
	if not isOwn(model) then
		local pl = Instance.new("PointLight")
		pl.Color = gold
		pl.Range = 12
		pl.Brightness = 1.2
		pl.Shadows = false
		pl.Parent = core
	else
		sparkle.Rate = rate(14)
	end
	keep(core, secs, 1)
	Sfx37.loopOn("golden_loop", core, if isOwn(model) then 0.3 else 0.6, secs, 110)
	burst("shieldPop", hull.Position, gold, if isOwn(model) then 0.9 else 1.8)
	if isOwn(model) then
		ToolboxCues.play("tier_up_sting", 1.05, 1.4)
	else
		ToolboxCues.playAt("tier_up_sting", hull.Position, 1.05, 1.2)
	end
end

-- Frost: the victim ices over (outline, a ring of snow, shards) for the slow.
local FROST = Color3.fromRGB(170, 232, 255)
local function frost(model: Model, hull: BasePart, secs: number)
	outline(model, FROST, 0.7, Color3.new(1, 1, 1), secs)
	local a = attach(hull, Vector3.new(0, 1, 0), "ItemShowFrost")
	local snow = emitter({
		Texture = tex("snowflake"),
		Rate = rate(30),
		Lifetime = NumberRange.new(0.6, 1.0),
		Speed = NumberRange.new(2, 6),
		SpreadAngle = Vector2.new(180, 180),
		Size = ns({ { 0, 1.2 }, { 1, 0.4 } }),
		Transparency = ns({ { 0, 0 }, { 1, 0.6 } }),
		Color = ColorSequence.new(Color3.new(1, 1, 1), FROST),
		LightEmission = 0.6,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-90, 90),
	})
	snow.Parent = a
	keep(a, secs, 1)
	burst("frostShards", hull.Position, nil, 1)
end

-- A coin fountain from where a Coin Burst hit: spinning coins thrown up and falling back (one pooled emitter).
local fountain: ParticleEmitter? = nil
local fountainAtt: Attachment? = nil
local function coinFountain(pos: Vector3)
	local pe = fountain
	if not pe or not pe.Parent then
		local a = worldAttach(pos)
		a.Name = "ItemShowCoinFountain"
		pe = emitter({
			Texture = UiV2Icons.icon_coin or tex("pickup_glint"),
			Enabled = false,
			Rate = 0,
			Lifetime = NumberRange.new(1.0, 1.4),
			Speed = NumberRange.new(38, 62),
			SpreadAngle = Vector2.new(28, 28),
			Size = NumberSequence.new(2.2),
			Transparency = ns({ { 0, 0 }, { 0.85, 0 }, { 1, 1 } }),
			Acceleration = Vector3.new(0, -120, 0),
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-360, 360),
			LightInfluence = 0.3,
			EmissionDirection = Enum.NormalId.Top,
		})
		;(pe :: ParticleEmitter).Parent = a
		fountain, fountainAtt = pe, a
	end
	local a = fountainAtt
	if a then
		a.WorldPosition = pos + Vector3.new(0, 2, 0)
	end
	;(pe :: ParticleEmitter):Emit(math.max(6, math.floor(18 * math.clamp(Settings.particleScale(), 0.3, 1))))
	burst("pickupGlint", pos, rgb("coin_burst"), 1.6)
	Sfx.at("coin_all", pos, 0.7, 1.05)
end

-- A boost's tail flare (seen by everyone), a shield's raise ring.
local function boostFlare(hull: BasePart, level: number, mine: boolean)
	local tailW = hull.Position + hull.CFrame:VectorToWorldSpace(tailOf(hull))
	burst("missileLaunch", tailW, rgb("blue"), 1.2 + 0.3 * level)
	burst("hitRing", tailW, rgb("blue"), 1.1 + 0.2 * level)
	local eff = ItemRules.effectFor("blue", math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL))
	local secs = if eff.boost then eff.boost.seconds else 1.8
	local tail = tailOf(hull)
	local half = math.max(0.8, hull.Size.Y * 0.32)
	if not mine then
		keep(ribbon(hull, tail + Vector3.new(0, half, 0), tail + Vector3.new(0, -half, 0), ColorSequence.new(Color3.fromRGB(230, 250, 255), rgb("blue")), 0.45), secs, 0.6)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Entry points
------------------------------------------------------------------------------------------------------------------------

-- Every ItemFx (ItemClient calls this after its own drawing).
function ItemShow.onFx(fx: string, payload: { [string]: any })
	local model = payload.plane
	local hull = hullOf(model)
	local pos = payload.pos
	local mdl = if typeof(model) == "Instance" and model:IsA("Model") then model else nil
	local strike = fx == "stormStrike" -- heard and seen by the whole field, wherever the target is
	if hull and not strike and not inRange(hull.Position) then
		return
	end
	if fx == "rocket" and hull and mdl then
		rocket(mdl, hull, seconds(payload, 3))
		if isOwn(mdl) then
			ItemShow.edgePulse(Color3.fromRGB(255, 150, 40), 0.3, 0.7, 0.1)
			ItemShow.flash(Color3.fromRGB(255, 220, 160), 0.12, 0.08)
		end
	elseif fx == "golden" and hull and mdl then
		golden(mdl, hull, seconds(payload, 4))
		if isOwn(mdl) then
			ItemShow.edgePulse(rgb("golden_wings"), 0.28, 0.7, 0.1)
			ItemShow.flash(Color3.fromRGB(255, 240, 180), 0.12, 0.08)
		end
	elseif fx == "stormStrike" and typeof(pos) == "Vector3" then
		ItemShow.lightning(pos, isOwn(mdl))
		-- The whole field hears it and sees the sky flash, wherever they are (a race's big moment, MK lightning style).
		local c = camPos()
		if c and (c - pos).Magnitude > 180 and not isOwn(mdl) then
			ToolboxCues.play("storm_thunder_1", 0.9, 0.9)
			ItemShow.flash(Color3.fromRGB(235, 228, 255), 0.18, 0.12)
		end
	elseif fx == "stormCloud" and hull then
		-- The cloud ItemsV4Fx draws gets a crackle of arcs inside it, so it reads as a thunderhead from far away.
		local a = attach(hull, Vector3.new(0, 17, 0), "ItemShowCloud")
		local arcs = emitter({
			Rate = rate(9),
			Lifetime = NumberRange.new(0.08, 0.16),
			Speed = NumberRange.new(0),
			SpreadAngle = Vector2.new(0, 0),
			Size = NumberSequence.new(7),
			Color = ColorSequence.new(STORM_VIOLET),
			LightEmission = 1,
			Rotation = NumberRange.new(0, 360),
		})
		FlipFx.apply(arcs, "electric_arc_4x4")
		arcs.Parent = a
		-- A real thunderhead: big slow dark puffs, readable from far down the track.
		local cloud = emitter({
			Rate = rate(14),
			Lifetime = NumberRange.new(1.0, 1.4),
			Speed = NumberRange.new(1, 3),
			SpreadAngle = Vector2.new(180, 25),
			Size = ns({ { 0, 10 }, { 0.5, 16 }, { 1, 18 } }),
			Transparency = ns({ { 0, 1 }, { 0.2, 0.15 }, { 0.8, 0.25 }, { 1, 1 } }),
			Color = ColorSequence.new(Color3.fromRGB(52, 48, 72), Color3.fromRGB(86, 80, 110)),
			LightInfluence = 0.4,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-15, 15),
			ZOffset = -2,
		})
		FlipFx.apply(cloud, "smoke_puff_8x8")
		cloud.Parent = a
		local pl = Instance.new("PointLight")
		pl.Color = STORM_VIOLET
		pl.Range = 30
		pl.Brightness = 1.5
		pl.Shadows = false
		pl.Parent = a
		keep(a, seconds(payload, 4), 0.5)
	elseif fx == "bombBlast" and typeof(pos) == "Vector3" then
		local r = tonumber(payload.radius) or 18
		burst("missileBlast", pos, Color3.fromRGB(255, 150, 60), math.clamp(r / 9, 1.6, 3.2))
		burst("hitRing", pos, nil, math.clamp(r / 7, 2, 4.4))
		burst("bigRing", pos, nil, math.clamp(r / 12, 1.2, 2.6))
		ToolboxCues.playAt("storm_thunder_3", pos, 0.6, 1.6)
		local c = camPos()
		local d = if c then (c - pos).Magnitude else 0
		if d < r * 4 then
			kick(0.5 * (1 - d / (r * 4)) + 0.1)
			ItemShow.flash(Color3.fromRGB(255, 230, 190), 0.35 * (1 - d / (r * 4)) + 0.05, 0.12)
		end
	elseif fx == "slow" and hull and mdl and payload.source == "frost_shot" then
		frost(mdl, hull, seconds(payload, 2))
	elseif fx == "explode" and typeof(pos) == "Vector3" then
		local source = payload.source
		if source == "coin_burst" and mdl then
			coinFountain(pos)
		elseif source == "frost_shot" and mdl then
			if not Sfx37.at("ice_crack", pos, if isOwn(mdl) then 0.8 else 0.55) then
				Sfx.at("shield_break", pos, if isOwn(mdl) then 0.8 else 0.55, 1.5)
			end
		elseif source == "missile" and mdl and not isOwn(mdl) then
			-- Far away the blast must still read: the bigger ring is cheap (one particle).
			local c = camPos()
			if c and (c - pos).Magnitude > 70 then
				burst("bigRing", pos, nil, 1.2)
			end
		end
	elseif fx == "boost" and hull and mdl then
		boostFlare(hull, tonumber(payload.level) or 1, isOwn(mdl))
	elseif fx == "shield" and hull and mdl and payload.bubble ~= true then
		burst("shieldPop", hull.Position, rgb("yellow"), 1.4)
	elseif fx == "reflect" and typeof(pos) == "Vector3" then
		burst("bigRing", pos, rgb("bubble_guard"), 0.9)
		if isOwn(mdl) then
			ItemShow.flash(rgb("bubble_guard"), 0.25, 0.1)
		end
	end
end

-- This player's ItemEffect (after ItemClient's and ItemsV4Fx's own handling).
local stunned = false
local stunnedAt = 0
function ItemShow.onEffect(kind: string, data: { [string]: any })
	if kind == "hit" then
		-- The payoff: a hot flash at the edges, a short white pop, a hard shake. The controllers already spin the
		-- vehicle and hold a hit-stop; ItemClient plays the knock.
		ItemShow.edgePulse(Color3.fromRGB(255, 70, 40), 0.35, 0.6, 0.08)
		ItemShow.flash(Color3.fromRGB(255, 245, 230), 0.16, 0.08)
		kick(0.35)
		Sfx.play("crash_hit", 0.85, 0.55)
		stunned = true
		stunnedAt = os.clock()
	elseif kind == "slow" and data.source == "frost_shot" then
		ItemShow.edgePulse(FROST, 0.3, 1.2, 0.4)
		if not Sfx37.play("ice_crack", 0.7) then
			Sfx.play("shield_break", 1.6, 0.6)
		end
	elseif kind == "boost" then
		local item = data.item
		if item == nil then
			-- A plain boost (blue): the whoosh and a cool rush at the edges.
			ItemShow.edgePulse(Color3.fromRGB(140, 220, 255), 0.3, 0.6, 0.1)
			ToolboxCues.play("geyser_whoosh", 1.25, 1.2)
		end
	elseif kind == "stormWarn" then
		ItemShow.edgePulse(STORM_VIOLET, 0.3, 1.4, 0.6)
	end
end

-- The roulette landed on `color`: the item's own sting under the land punch.
local STINGS: { [string]: { cue: string, pitch: number, vol: number, toolbox: boolean? } } = {
	red = { cue = "missile_launch", pitch = 1.35, vol = 0.55 },
	blue = { cue = "boost_kick", pitch = 1.2, vol = 0.55 },
	yellow = { cue = "shield_up", pitch = 1.2, vol = 0.55 },
	green = { cue = "trap_arm", pitch = 1.1, vol = 0.6 },
	rainbow = { cue = "magnet_lock", pitch = 1.1, vol = 0.55 },
	rocket_rush = { cue = "geyser_whoosh", pitch = 1.3, vol = 1.4, toolbox = true },
	golden_wings = { cue = "tier_up_sting", pitch = 1.1, vol = 1.0, toolbox = true },
	orbit_missiles = { cue = "magnet_lock", pitch = 1.35, vol = 0.55 },
	storm_bolt = { cue = "storm_thunder_2", pitch = 1.5, vol = 1.1, toolbox = true },
	boom_bomb = { cue = "mine_blast", pitch = 1.5, vol = 0.45 },
	gift_box = { cue = "unlock_fanfare", pitch = 1.4, vol = 0.4 },
	frost_shot = { cue = "shield_break", pitch = 1.7, vol = 0.5 },
	coin_burst = { cue = "coin_all", pitch = 1.1, vol = 0.5 },
	bubble_guard = { cue = "shield_block", pitch = 1.35, vol = 0.55 },
}
function ItemShow.landSting(color: string)
	local s = STINGS[color]
	if not s then
		return
	end
	if color == "gift_box" then
		Sfx37.play("gift_pop", 0.5)
	end
	if s.toolbox then
		ToolboxCues.play(s.cue, s.pitch, s.vol)
	else
		Sfx.play(s.cue, s.pitch, s.vol)
	end
end

-- The icon for an item in the v2 icon set (roulette faces, warning chips), or nil.
function ItemShow.icon(color: string?): string?
	if type(color) ~= "string" then
		return nil
	end
	return UiV2Icons[ItemRules.iconKey(color)] -- v38: placeholder keys for the new items (ItemRules.ICON_KEY)
end

-- A missile copy wears its item: snow off a Frost Shot, gold glints off a Coin Burst.
function ItemShow.dressShot(copy: BasePart, status: string?)
	if status ~= "frost_shot" and status ~= "coin_burst" then
		return
	end
	local a = attach(copy, Vector3.new(0, 0, 1.4), "ItemShowShot")
	local frosty = status == "frost_shot"
	local pe = emitter({
		Texture = if frosty then tex("snowflake") else tex("pickup_glint"),
		Rate = rate(frosty and 40 or 30),
		Lifetime = NumberRange.new(0.35, 0.6),
		Speed = NumberRange.new(2, 6),
		SpreadAngle = Vector2.new(40, 40),
		Size = ns({ { 0, if frosty then 1.4 else 1.6 }, { 1, 0.2 } }),
		Transparency = ns({ { 0, 0 }, { 1, 0.7 } }),
		Color = ColorSequence.new(Color3.new(1, 1, 1), rgb(status)),
		LightEmission = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-120, 120),
	})
	pe.Parent = a
	local pl = Instance.new("PointLight")
	pl.Color = rgb(status)
	pl.Range = 14
	pl.Brightness = 2.5
	pl.Shadows = false
	pl.Parent = a
end

function ItemShow.step(_dt: number)
	local now = os.clock()
	stepScreen(now)
	for i = #timed, 1, -1 do
		local t = timed[i]
		if now >= t.dieAt or not t.inst.Parent then
			if t.inst.Parent then
				t.inst:Destroy()
			end
			table.remove(timed, i)
		elseif now >= t.stopAt then
			for _, pe in t.emitters do
				pe.Enabled = false
			end
			for _, tr in t.trails do
				tr.Enabled = false
			end
		end
	end
	for m, h in highlights do
		if not h.Parent then
			highlights[m] = nil
		end
	end
	-- The recover: the spin-out is over, the vehicle is yours again.
	if stunned and now - stunnedAt > 0.5 and (LocalPlayer:GetAttribute("ItemStunned") ~= true or now - stunnedAt > 4.5) then
		stunned = false
		Sfx.play("respawn_pop", 1.25, 0.4)
		local hull = ownHull()
		if hull then
			burst("pickupGlint", hull.Position + Vector3.new(0, 2, 0), Color3.fromRGB(190, 255, 200), 1)
		end
	end
end

-- Ends every running effect at once (screen edges and flash, outlines, attached emitters, lights, ribbons): a respawn, a
-- track switch, the race ending or the mode changing must never leave a tint or a glaze behind.
function ItemShow.clearAll()
	for _, t in timed do
		if t.inst.Parent then
			t.inst:Destroy()
		end
	end
	table.clear(timed)
	for m, h in highlights do
		if h.Parent then
			h:Destroy()
		end
		highlights[m] = nil
	end
	pulse = nil
	flashState.peak = 0
	for _, f in edges do
		f.BackgroundTransparency = 1
	end
	local fl = flashFrame
	if fl then
		fl.BackgroundTransparency = 1
	end
	stunned = false
end

function ItemShow.init(burstFn: Burst, kickFn: (amount: number) -> ())
	burst = burstFn
	kick = kickFn
	Sfx37.preload()
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(ItemShow.clearAll)
	RaceAttr.changed("RaceMode", ItemShow.clearAll)
	LocalPlayer:GetAttributeChangedSignal("LastRespawnClock"):Connect(ItemShow.clearAll)
end

return ItemShow
