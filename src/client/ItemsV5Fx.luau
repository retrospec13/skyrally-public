--!strict
-- v38 items (design lane; owner 2026-11-10: "not every item boost needs to be some missile thing"): the client look of
-- the new verbs. The server decides everything (server/kit/ItemEffects hooks.special: "horn", "ink_splat",
-- "item_steal", "coin_pouch"); ItemClient forwards the events here.
-- * ItemFx "horn" {plane, pos, radius, clear}: a gold shockwave ring the size of the horn's reach plus a blast cue.
-- * ItemEffect "ink" {seconds}: ink blots over THIS player's screen, dripping, for `seconds`; any boost (BoostState not
--   "None") wipes them at once (the counter). Kept off the lower centre third so the kart itself stays visible.
-- * ItemFx "ink" {plane}: a dark puff over every inked vehicle (so the user sees whom it reached).
-- * ItemFx "steal" {plane, from, item}: a spark burst on the robbed vehicle and on the thief.
-- * ItemFx "coinPouch" {plane, count}: a gold sparkle burst on the vehicle.
-- Particles and 2D frames only: no mesh, nothing over the road except the ink, which is the item's whole point.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlipFx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FlipFx"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))

local LocalPlayer = Players.LocalPlayer

local ItemsV5Fx = {}

type Burst = (name: string, pos: Vector3, tint: Color3?, scale: number?) -> ()
local burst: Burst = function() end

local GOLD = Color3.fromRGB(255, 214, 70)
local INK = Color3.fromRGB(28, 16, 46)
local INK_TINT = Color3.fromRGB(70, 46, 110) -- multiplies the slick's sheen down to a dark violet ink
local INK_ALPHA = 0.05

local function hullOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local p = model.PrimaryPart
	return if p and p:IsA("BasePart") then p else nil
end

local function own(model: any): boolean
	return typeof(model) == "Instance"
		and (model.Name == "Car_" .. LocalPlayer.Name or model.Name == "Plane_" .. LocalPlayer.Name)
end

------------------------------------------------------------------------------------------------ ink over the screen

-- Blot layout in screen scale: centre x, centre y, size (of the screen height), kept off the lower middle (the kart).
local BLOTS = {
	{ 0.30, 0.30, 0.62 },
	{ 0.64, 0.24, 0.55 },
	{ 0.84, 0.58, 0.46 },
	{ 0.13, 0.66, 0.42 },
	{ 0.50, 0.40, 0.40 },
}

local inkGui: ScreenGui? = nil
local inkUntil = 0
local inkFading = false
local inkAt = 0
local boostSeen = false -- a boost already running when the ink landed never wipes it; only a fresh one does

local function boosting(): boolean
	local b = LocalPlayer:GetAttribute("BoostState")
	return type(b) == "string" and b ~= "None" and b ~= ""
end

-- One splat: the owned oil_slick texture (a blob with droplets) tinted ink, turned so no two read the same.
local INK_TEX = "rbxassetid://129814809454701" -- shared/ItemTexAssets.oil_slick
local function blot(parent: Instance, x: number, y: number, size: number, seed: number): ImageLabel
	local f = Instance.new("ImageLabel")
	f.Name = "Blot"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(size, size)
	f.BackgroundTransparency = 1
	f.Image = INK_TEX
	f.ImageColor3 = INK_TINT
	f.ImageTransparency = INK_ALPHA
	f.Rotation = (seed * 97) % 360
	f.ScaleType = Enum.ScaleType.Fit
	f.Parent = parent
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = f
	return f
end

local function setInkAlpha(gui: ScreenGui, t: number)
	for _, d in gui:GetDescendants() do
		if d:IsA("ImageLabel") then
			d.ImageTransparency = t
		end
	end
end

local function clearInk(wiped: boolean)
	local gui = inkGui
	if not gui or inkFading then
		return
	end
	inkFading = true
	if wiped then
		TrickJuice.callout("INK WIPED", Color3.fromRGB(140, 255, 170), 0.8)
	end
	local start = os.clock()
	local dur = if wiped then 0.25 else 0.6
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local k = math.clamp((os.clock() - start) / dur, 0, 1)
		if gui.Parent then
			setInkAlpha(gui, INK_ALPHA + (1 - INK_ALPHA) * k)
		end
		if k >= 1 then
			if conn then
				conn:Disconnect()
			end
			gui:Destroy()
			if inkGui == gui then
				inkGui = nil
			end
			inkFading = false
		end
	end)
end

local function showInk(seconds: number)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	inkUntil = os.clock() + seconds
	inkAt = os.clock()
	boostSeen = boosting()
	if inkGui and not inkFading then
		return -- already inked: the timer is extended
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallyInk"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1 -- under every HUD gui (the item slot, callouts and the warning stay readable)
	gui.Parent = pg
	inkGui = gui
	inkFading = false
	for i, b in BLOTS do
		local f = blot(gui, b[1], b[2], b[3], i * 1.7)
		-- splat in: from small with an overshoot, then a slow drip downward
		f.Size = UDim2.fromScale(b[3] * 0.2, b[3] * 0.2)
		TweenService:Create(f, TweenInfo.new(0.18 + i * 0.03, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(b[3], b[3]) }):Play()
		TweenService:Create(f, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Position = UDim2.fromScale(b[1], b[2] + 0.05) }):Play()
	end
	Sfx.play("oil_splat", 0.8, 0.7)
	TrickJuice.callout("BOOST TO CLEAR", Color3.fromRGB(205, 170, 255), 1.4)
end

local function stepInk()
	if not inkGui or inkFading then
		return
	end
	-- The counter: a boost STARTED after the ink landed (a pad, a ring, an item) wipes it. One already running does not.
	local b = boosting()
	if not b then
		boostSeen = false
	elseif not boostSeen and os.clock() - inkAt > 0.4 then
		clearInk(true)
		return
	end
	if os.clock() >= inkUntil then
		clearInk(false)
	end
end

------------------------------------------------------------------------------------------------ the horn's shockwave

-- A flat ring that grows from the hull out to the horn's reach (`clear` studs) and fades, a second thinner one just
-- behind it, and a gold flash at the hull: you see exactly how far the horn reached. Particles only, laid on the ground.
local function hornWave(pos: Vector3, clear: number, mine: boolean)
	local att = Instance.new("Attachment")
	att.Name = "HornWave"
	att.WorldCFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0))
	att.Parent = workspace.Terrain
	local function wave(life: number, startSize: number, endSize: number, alpha: number, tex: string?, count: number?)
		local pe = Instance.new("ParticleEmitter")
		if tex then
			FlipFx.apply(pe, tex)
		else
			FlipFx.apply(pe, "shockwave_8x8", 64 / life)
		end
		pe.Enabled = false
		pe.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
		pe.EmissionDirection = Enum.NormalId.Top
		pe.Speed = NumberRange.new(0.01)
		pe.Lifetime = NumberRange.new(life)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, startSize), NumberSequenceKeypoint.new(1, endSize) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, alpha), NumberSequenceKeypoint.new(0.6, alpha + 0.15), NumberSequenceKeypoint.new(1, 1) })
		pe.Color = ColorSequence.new(GOLD)
		pe.LightEmission = 1
		pe.ZOffset = 0.5
		pe.Parent = att
		pe:Emit(count or 1)
	end
	-- the rim (two stacked emits read twice as bright), a second rim behind it, and a gold wash over the whole reach
	wave(0.7, 4, clear * 2, 0, nil, 2)
	wave(0.9, 2, clear * 1.6, 0.2)
	wave(0.6, 6, clear * 2, 0.55, "glow_soft")
	if not mine and not Settings.lowGraphics() then -- the holder's own flash sat on the lens: everyone else's only
		local flash = Instance.new("ParticleEmitter")
		FlipFx.apply(flash, "glow_soft")
		flash.Enabled = false
		flash.Speed = NumberRange.new(0)
		flash.Lifetime = NumberRange.new(0.25)
		flash.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 14) })
		flash.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		flash.Color = ColorSequence.new(GOLD)
		flash.LightEmission = 1
		flash.Parent = att
		flash:Emit(1)
	end
	task.delay(1.5, function()
		att:Destroy()
	end)
end

-- v39: the horn item's own voice. No horn sample is uploaded; the owned foghorn (WorldMomentsAudio ans_foghorn, the
-- SNOW crossing's air-horn stand-in) pitched up to an air-horn blast, through the EFFECTS slider. Own horn: a 2D blast;
-- anyone else's: 3D on their hull, quieter. One Sound per hull (reused), so a horn spam cannot pile voices up.
local HORN_ID = (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorldMomentsAudio")) :: any).ans_foghorn
local HORN_PITCH = 1.45
local hornOwn: Sound? = nil
local hornOn: { [BasePart]: Sound } = {}
local function hornSound(hull: BasePart?, mine: boolean)
	if type(HORN_ID) ~= "string" then
		return
	end
	local s: Sound
	if mine then
		local o = hornOwn
		if not o or not o.Parent then
			local n = Instance.new("Sound")
			n.Name = "ItemHorn"
			n.SoundId = HORN_ID
			Settings.sfx(n)
			n.Parent = game:GetService("SoundService")
			hornOwn = n
			o = n
		end
		s = o :: Sound
		s.Volume = 0.75
	else
		if not hull then
			return
		end
		local o = hornOn[hull]
		if not o or not o.Parent then
			local n = Instance.new("Sound")
			n.Name = "ItemHorn"
			n.SoundId = HORN_ID
			n.RollOffMode = Enum.RollOffMode.InverseTapered
			n.RollOffMinDistance = 20
			n.RollOffMaxDistance = 400
			Settings.sfx(n)
			n.Parent = hull
			hornOn[hull] = n
			hull.Destroying:Connect(function()
				hornOn[hull] = nil
			end)
			o = n
		end
		s = o :: Sound
		s.Volume = Sfx.quiet(0.75)
	end
	s.PlaybackSpeed = HORN_PITCH + (math.random() - 0.5) * 0.06
	s.TimePosition = 0
	s:Play()
end

------------------------------------------------------------------------------------------------ events

function ItemsV5Fx.onEffect(kind: string, data: { [string]: any })
	if kind == "ink" then
		showInk(math.clamp(tonumber(data.seconds) or 3.5, 0.5, 8))
	elseif kind == "coins" then
		local n = math.floor(tonumber(data.count) or 0)
		if n > 0 then
			TrickJuice.callout(string.format("+%d COINS", n), GOLD, 1.0)
			Sfx.play("coin_all", 1.15, 0.5)
		end
	end
end

function ItemsV5Fx.onFx(fx: string, payload: { [string]: any })
	local hull = hullOf(payload.plane)
	if fx == "horn" then
		local pos = if typeof(payload.pos) == "Vector3" then payload.pos elseif hull then hull.Position else nil
		if pos then
			local clear = math.clamp(tonumber(payload.clear) or 30, 10, 60)
			hornWave(pos, clear, own(payload.plane))
			local mine = own(payload.plane)
			-- the air-horn blast is the item's voice; a low, softer thump under it is the shockwave
			hornSound(hull, mine)
			if mine then
				Sfx.play("missile_explode", 0.55, 0.38)
			elseif hull then
				Sfx.play3D("missile_explode", hull, Sfx.quiet(0.38))
			end
		end
	elseif fx == "ink" and hull then
		burst("spinSmoke", hull.Position + Vector3.new(0, 2, 0), INK, 1.2)
	elseif fx == "steal" then
		local from = hullOf(payload.from)
		if from then
			burst("magnetZap", from.Position, Color3.fromRGB(190, 200, 255), 0.8)
		end
		if hull then
			burst("pickupGlint", hull.Position + Vector3.new(0, 2, 0), nil, 1.2)
		end
		if own(payload.plane) and hull then
			Sfx.play("magnet_lock", 1.3, 0.55)
		end
	elseif fx == "coinPouch" and hull then
		burst("pickupGlint", hull.Position + Vector3.new(0, 2, 0), GOLD, 1.4)
	end
end

function ItemsV5Fx.init(burstFn: Burst)
	burst = burstFn
	RunService.RenderStepped:Connect(stepInk)
end

return ItemsV5Fx
