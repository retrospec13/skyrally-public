--!strict
-- The hub portals' fill (a deep swirling vortex in the arch opening, not a tinted glass box). Client only, display
-- only. Over each arch's PortalShimmer_<ZONE> part, on both faces, stacked layers (SurfaceGui ImageLabels):
--   core    a dark, zone-tinted soft disc: the depth at the middle
--   streaks faint radial speed lines pulling inward (PortalTexAssets only; absent on the fallback)
--   vortexA a log-spiral turning one way, and vortexB a smaller, fainter, opposite-handed one turning the other way
--   rim     a crisp glowing ring in the zone's accent, pulsing and breathing
--   label   the zone's name in front of all of it (ZIndex), or LOCKED
-- Textures: shared/PortalTexAssets (tools/gen_portal_tex.py) when uploaded (id non-zero), else the older VfxAssets
-- art (magic_swirl_8x8 frames, shockwave_ring, glow_soft), so nothing changes until the ids are filled in.
-- plus a ring of MOTE_COUNT emitters on the rim whose motes drift inward and fade at the core. Cheap on purpose: nothing
-- animates beyond RANGE studs (half on a phone), motes stop at the far tier, one 30 Hz update for every portal, a fixed
-- number of Instances per portal. The maths is shared/PortalFillRules (specced).
-- Called from TrackFlow's labelPortals (apply, idempotent: a re-call only recolours). The glass veil is faded and the
-- hung banners hidden server side (kit/ArtSwap, hub_portal rule), so this disc is the portal.
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PortalFillRules = require(Shared:WaitForChild("PortalFillRules"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets")) :: any
local PortalTexAssets = require(Shared:WaitForChild("PortalTexAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))

local PortalFill = {}

local MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Studio verifier tuning.
local DISC_DIAMETER = 22 -- studs; the arch opening is 24 wide
local DISC_Y_OFFSET = 0 -- studs up from the shimmer part's centre
local CANVAS = 256 -- SurfaceGui pixels per side
local RANGE = 170 -- studs: full detail (half on a phone); 2 x this is the far tier; beyond, everything is off
local UPDATE_HZ = 30
local SWIRL_A_SPEED = 38 -- deg/s, clockwise
local SWIRL_B_SPEED = -64 -- deg/s, counter-clockwise (the inner copy)
local SWIRL_B_SCALE = 0.7
local SWIRL_A_FRAME = 0 -- which magic_swirl_8x8 frame to hold (0..63)
local SWIRL_B_FRAME = 24
local SWIRL_WHITE_MIX = 0.55 -- fallback sheet only: 0 = swirl fully tinted, 1 = the sheet's own violet/white (tint multiplies)
local VORTEX_WHITE_MIX = 0.12 -- new white vortex textures: nearly the pure zone colour (Sunshine-bright, not washed out)
local VORTEX_A_TRANSPARENCY = 0.12
local VORTEX_B_TRANSPARENCY = 0.38
local STREAK_TRANSPARENCY = 0.55
local RIM_BREATHE = 0.025 -- rim scale swells by +-this
local CORE_DARKEN = 0.4 -- the core's colour = accent x this
local CORE_TRANSPARENCY = 0.1
local RIM_PULSE_HZ = 0.8
local MOTE_COUNT = if MOBILE then 5 else 8 -- emitters round the rim
local MOTE_RATE_OPEN = 3 -- per emitter per second
local MOTE_RATE_LOCKED = 0.8
local MOTE_LIFETIME = 1.7
local MOTE_SIZE = 0.9
local LOCKED_SPEED_SCALE = 0.35
local LOCKED_FADE = 0.45 -- extra transparency on a locked portal's layers
local LABEL_TEXT_SIZE = 30 -- px on the CANVAS

type Face = {
	gui: SurfaceGui,
	core: ImageLabel,
	streaks: ImageLabel,
	swirlA: ImageLabel,
	swirlB: ImageLabel,
	rim: ImageLabel,
	label: TextLabel,
}
type Fill = {
	disc: Part,
	faces: { Face },
	motes: { ParticleEmitter },
	accent: Color3,
	open: boolean,
	tier: string,
	phase: number,
}
local fills: { [BasePart]: Fill } = {}
local conn: RBXScriptConnection? = nil
local acc = 0

local function glow(): string
	local a = VfxAssets.glow_soft
	return if a then a.id else ""
end

local function ringTex(): string
	return PortalFillRules.texOrFallback(PortalTexAssets.rim, (function()
		local a = VfxAssets.shockwave_ring
		return if a then a.id else ""
	end)())
end

local function coreTex(): string
	return PortalFillRules.texOrFallback(PortalTexAssets.core, glow())
end

-- True when the new vortex textures are uploaded (both spirals), else the swirl sheet frames stand in.
local function newVortex(): boolean
	return (PortalTexAssets.vortex_a or 0) > 0 and (PortalTexAssets.vortex_b or 0) > 0
end

local function image(parent: Instance, name: string, z: number, size: number): ImageLabel
	local l = Instance.new("ImageLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromScale(size, size)
	l.ZIndex = z
	l.Parent = parent
	return l
end

local function buildFace(disc: Part, face: Enum.NormalId, zoneName: string): Face
	local g = Instance.new("SurfaceGui")
	g.Name = "Fill_" .. face.Name
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	g.CanvasSize = Vector2.new(CANVAS, CANVAS)
	g.LightInfluence = 0
	g.Brightness = 1.6
	g.ClipsDescendants = false
	g.Parent = disc
	local core = image(g, "Core", 1, if (PortalTexAssets.core or 0) > 0 then 1 else 0.96)
	core.Image = coreTex()
	local streaks = image(g, "Streaks", 2, 1)
	streaks.Image = PortalFillRules.texOrFallback(PortalTexAssets.streaks, "")
	streaks.Visible = (PortalTexAssets.streaks or 0) > 0
	local swirlA = image(g, "SwirlA", 3, 1)
	local swirlB = image(g, "SwirlB", 4, SWIRL_B_SCALE)
	if newVortex() then
		swirlA.Image = PortalFillRules.texOrFallback(PortalTexAssets.vortex_a, "")
		swirlB.Image = PortalFillRules.texOrFallback(PortalTexAssets.vortex_b, "")
	else
		local sheet = FlipFx.resolve("magic_swirl_8x8")
		for i, l in { swirlA, swirlB } do
			l.Image = sheet.texture
			if sheet.flip then -- the real sheet: hold one frame; a fallback texture is already a single image
				local x, y, w, h = PortalFillRules.frameRect(if i == 1 then SWIRL_A_FRAME else SWIRL_B_FRAME)
				l.ImageRectOffset = Vector2.new(x, y)
				l.ImageRectSize = Vector2.new(w, h)
			end
		end
	end
	local rim = image(g, "Rim", 5, 1.02)
	rim.Image = ringTex()
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.82, 0.2)
	label.ZIndex = 8
	label.Font = Enum.Font.GothamBlack
	label.TextSize = LABEL_TEXT_SIZE
	label.TextWrapped = false
	label.TextScaled = true
	label.RichText = false
	label.Text = zoneName
	label.TextColor3 = Color3.new(1, 1, 1)
	local lim = Instance.new("UITextSizeConstraint")
	lim.MaxTextSize = LABEL_TEXT_SIZE
	lim.MinTextSize = 10
	lim.Parent = label
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(28, 18, 36)
	st.Thickness = 3
	st.Parent = label
	label.Parent = g
	return { gui = g, core = core, streaks = streaks, swirlA = swirlA, swirlB = swirlB, rim = rim, label = label }
end

-- Motes round the rim, each pointing at the centre and living exactly long enough to reach it.
local function buildMotes(disc: Part): { ParticleEmitter }
	local out: { ParticleEmitter } = {}
	local radius = DISC_DIAMETER * 0.5
	local speed = PortalFillRules.inwardSpeed(radius, MOTE_LIFETIME)
	for i, pt in PortalFillRules.ringPoints(MOTE_COUNT, radius) do
		local at = Instance.new("Attachment")
		at.Name = "Mote" .. i
		at.CFrame = CFrame.lookAt(Vector3.new(pt.x, pt.y, 0), Vector3.zero)
		at.Parent = disc
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "Mote"
		pe.Texture = glow()
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.EmissionDirection = Enum.NormalId.Front
		pe.SpreadAngle = Vector2.new(7, 7)
		pe.Speed = NumberRange.new(speed * 0.9, speed * 1.05)
		pe.Lifetime = NumberRange.new(MOTE_LIFETIME * 0.95, MOTE_LIFETIME)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, MOTE_SIZE), NumberSequenceKeypoint.new(1, 0) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.1), NumberSequenceKeypoint.new(1, 1) })
		pe.RotSpeed = NumberRange.new(-120, 120)
		pe.Rate = MOTE_RATE_OPEN
		pe.Enabled = false
		pe.Parent = at
		table.insert(out, pe)
	end
	return out
end

-- v19: cream FOREST / grey SNOW discs read as dirty glass; push the accent toward a saturated, bright version of its hue.
local function vivid(c: Color3): Color3
	local h, sat, v = c:ToHSV()
	return Color3.fromHSV(h, math.max(sat, 0.7), math.max(v, 0.95))
end

local function tint(f: Fill)
	local accent = vivid(f.accent)
	local white = Color3.new(1, 1, 1)
	local fade = if f.open then 0 else LOCKED_FADE
	for _, fc in f.faces do
		fc.core.ImageColor3 = Color3.new(accent.R * CORE_DARKEN, accent.G * CORE_DARKEN, accent.B * CORE_DARKEN)
		fc.core.ImageTransparency = math.min(1, CORE_TRANSPARENCY + fade)
		local nv = newVortex()
		local mix = if nv then VORTEX_WHITE_MIX else SWIRL_WHITE_MIX
		fc.swirlA.ImageColor3 = accent:Lerp(white, mix)
		fc.swirlA.ImageTransparency = math.min(1, (if nv then VORTEX_A_TRANSPARENCY else 0.2) + fade)
		fc.swirlB.ImageColor3 = accent:Lerp(white, mix + 0.15)
		fc.swirlB.ImageTransparency = math.min(1, (if nv then VORTEX_B_TRANSPARENCY else 0.35) + fade)
		fc.streaks.ImageColor3 = accent:Lerp(white, 0.5)
		fc.streaks.ImageTransparency = math.min(1, STREAK_TRANSPARENCY + fade)
		fc.rim.ImageColor3 = accent:Lerp(white, 0.25)
		fc.label.TextColor3 = if f.open then white:Lerp(accent, 0.25) else Color3.fromRGB(200, 196, 190)
	end
	for _, pe in f.motes do
		pe.Color = ColorSequence.new(accent:Lerp(white, 0.35))
		pe.Rate = if f.open then MOTE_RATE_OPEN else MOTE_RATE_LOCKED
	end
end

local function step(now: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	for part, f in fills do
		if not part.Parent or not f.disc.Parent then
			f.disc:Destroy()
			fills[part] = nil
		else
			local tier = PortalFillRules.tier((f.disc.Position - camPos).Magnitude, RANGE, MOBILE)
			if tier ~= f.tier then
				f.tier = tier
				for _, fc in f.faces do
					fc.gui.Enabled = tier ~= "off"
				end
				for _, pe in f.motes do
					pe.Enabled = tier == "full"
				end
			end
			if tier == "full" then
				local k = if f.open then 1 else LOCKED_SPEED_SCALE
				local t = now + f.phase
				for _, fc in f.faces do
					fc.swirlA.Rotation = PortalFillRules.angle(t, SWIRL_A_SPEED * k)
					if not MOBILE then
						fc.swirlB.Rotation = PortalFillRules.angle(t, SWIRL_B_SPEED * k, 40)
					end
					local pulse = PortalFillRules.pulse(t, RIM_PULSE_HZ)
					fc.rim.ImageTransparency = (if f.open then 0.08 else 0.5) + 0.18 * (1 - pulse)
					local bs = 1.02 * PortalFillRules.breathe(t, RIM_PULSE_HZ, RIM_BREATHE)
					fc.rim.Size = UDim2.fromScale(bs, bs)
					-- streaks counter-turn very slowly so the pull-in reads as motion, not a static starburst
					fc.streaks.Rotation = PortalFillRules.angle(t, -9 * k, 80)
				end
			end
		end
	end
end

local function ensureLoop()
	if conn then
		return
	end
	conn = RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 1 / UPDATE_HZ then
			return
		end
		acc = 0
		step(os.clock())
	end)
end

-- Builds (once) or recolours the swirl fill on a PortalShimmer_<ZONE> part. accent: the zone's colour; open: gate state.
function PortalFill.apply(part: BasePart, accent: Color3, open: boolean, zoneName: string)
	local fill = fills[part]
	if not fill then
		local disc = Instance.new("Part")
		disc.Name = "PortalFillDisc"
		disc.Anchored = true
		disc.CanCollide = false
		disc.CanQuery = false
		disc.CanTouch = false
		disc.CastShadow = false
		disc.Transparency = 1
		-- The disc is a touch thicker than the shimmer part it sits in: a SurfaceGui face that lies inside a (transparent) part's volume is
		-- hidden by it in the renderer (Studio 2026-10-19: the fill was invisible), so both faces must lie just outside it.
		disc.Size = Vector3.new(DISC_DIAMETER, DISC_DIAMETER, part.Size.Z + 0.2)
		disc.CFrame = part.CFrame * CFrame.new(0, DISC_Y_OFFSET, 0)
		disc.Parent = part
		local nf: Fill = {
			disc = disc,
			faces = {
				buildFace(disc, Enum.NormalId.Front, zoneName),
				buildFace(disc, Enum.NormalId.Back, zoneName),
			},
			motes = buildMotes(disc),
			accent = accent,
			open = open,
			tier = "off",
			phase = math.random() * 20,
		}
		for _, fc in nf.faces do
			fc.gui.Enabled = false
		end
		fills[part] = nf
		fill = nf
	end
	local f: Fill = fill :: Fill
	f.accent = accent
	f.open = open
	for _, fc in f.faces do
		fc.label.Text = if open then zoneName else "LOCKED"
		fc.label.Visible = not open -- the arch's signboard already names the zone; the disc only says LOCKED
	end
	tint(f)
	ensureLoop()
end

return PortalFill
