--!strict
-- Boost-pad anticipation (client only). The pads are server-built (Gameplay.buildGroundBoostPad, TriggerType
-- "GroundBoostPad", tagged TriggerRules.TAG), so this module decorates them from the client: only pads within
-- BoostRules.PAD_RADIUS (150 studs) of the camera, at most BoostRules.PAD_POOL (6) at a time, from a FIXED pool of
-- invisible anchored parts built once (no per-frame Instance.new, no per-pad instances for the far pads). Each decorated
-- pad gets a slow pulsing PointLight and a thin stream of upward chevron arrows (BoostTexAssets.pad_chevron; until it is
-- uploaded the stream falls back to sparkle stars). Vfx.onPad flares the pad it was touched on (Vfx calls
-- BoostPadFx.flare). Phone cost: 6 lights + 6 emitters at 1.6 particles/s x particleScale, nothing for far pads, the
-- emitters are off under LOW GRAPHICS (the light pulse stays).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoostRules = require(Shared:WaitForChild("BoostRules"))
local BoostTexAssets = require(Shared:WaitForChild("BoostTexAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local TriggerRules = require(Shared:WaitForChild("TriggerRules"))
local FidelityRules = require(Shared:WaitForChild("FidelityRules")) -- a timed hub-boss pad that is off shows no glow (M-2)
local Settings = require(script.Parent:WaitForChild("Settings"))

local BoostPadFx = {}

local WARM = Color3.fromRGB(255, 214, 80)
local CREAM = Color3.fromRGB(255, 244, 214)
local BASE_RATE = 1.6 -- chevrons per second per pad, before particleScale

type Slot = {
	part: Part,
	light: PointLight,
	emitter: ParticleEmitter,
	pad: BasePart?,
	phase: number,
	flare: number, -- 1 -> 0 over FLARE_TIME after a touch
	rate: number, -- last Rate written
}

local slots: { Slot } = {}
local pads: { [BasePart]: boolean } = {}
local padList: { BasePart } = {}
local listDirty = true
local scanT = 0
local built = false

local function chevronTexture(): string
	local id = (BoostTexAssets :: any).pad_chevron
	if type(id) == "number" and id > 0 then
		return "rbxassetid://" .. tostring(id)
	end
	return ""
end

local function buildSlot(i: number, parent: Instance): Slot
	local part = Instance.new("Part")
	part.Name = "VfxPadDecor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(7, 0.2, 13)
	part.CFrame = CFrame.new(0, -500, 0) -- parked far below the world until assigned
	local light = Instance.new("PointLight")
	light.Range = 16
	light.Brightness = 0
	light.Color = WARM
	light.Shadows = false
	light.Parent = part
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "VfxPadChevron"
	local own = chevronTexture()
	if own ~= "" then
		pe.Texture = own
	else
		FlipFx.apply(pe, "sparkle_star_4x4") -- not uploaded yet: sparkle stars rise instead
	end
	pe.Enabled = false
	pe.Rate = 0
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Lifetime = NumberRange.new(1.0, 1.4)
	pe.Speed = NumberRange.new(5, 7)
	pe.SpreadAngle = Vector2.new(4, 4)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(0.3, 1.9), NumberSequenceKeypoint.new(1, 1.6) }) -- v29 D7: was 2.2/3.6/3, a blown-out burst over the hull
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.5), NumberSequenceKeypoint.new(0.7, 0.65), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(CREAM, WARM)
	pe.LightEmission = 0.5 -- v29 D7: was 1
	pe.LightInfluence = 0
	pe.Orientation = Enum.ParticleOrientation.FacingCamera
	pe.Parent = part
	part.Parent = parent
	return { part = part, light = light, emitter = pe, pad = nil, phase = i * 1.7, flare = 0, rate = 0 }
end

local function isPad(inst: Instance): boolean
	return inst:IsA("BasePart") and inst:GetAttribute("TriggerType") == "GroundBoostPad"
end

local function addPad(inst: Instance)
	if isPad(inst) and not pads[inst :: BasePart] then
		pads[inst :: BasePart] = true
		listDirty = true
	end
end

local function freeSlot(s: Slot)
	s.pad = nil
	s.light.Brightness = 0
	s.emitter.Enabled = false
	s.emitter.Rate = 0
	s.rate = 0
	s.flare = 0
	s.part.CFrame = CFrame.new(0, -500, 0)
end

function BoostPadFx.init(parent: Instance)
	if built then
		return
	end
	built = true
	for i = 1, BoostRules.PAD_POOL do
		table.insert(slots, buildSlot(i, parent))
	end
	for _, inst in CollectionService:GetTagged(TriggerRules.TAG) do
		addPad(inst)
	end
	CollectionService:GetInstanceAddedSignal(TriggerRules.TAG):Connect(addPad)
	CollectionService:GetInstanceRemovedSignal(TriggerRules.TAG):Connect(function(inst)
		if pads[inst :: BasePart] then
			pads[inst :: BasePart] = nil
			listDirty = true
		end
	end)
end

-- A pad was touched: flare its light and throw a couple of extra chevrons (Vfx.onPad).
function BoostPadFx.flare(pos: Vector3)
	for _, s in slots do
		local pad = s.pad
		if pad and (pad.Position - pos).Magnitude < 14 then
			s.flare = 1
			if Settings.particleScale() > 0 then
				s.emitter:Emit(math.max(1, math.floor(1 * Settings.particleScale() + 0.5)))
			end
			return
		end
	end
end

local function rescan(camPos: Vector3)
	if listDirty then
		listDirty = false
		padList = {}
		for p in pads do
			if p.Parent then
				table.insert(padList, p)
			end
		end
	end
	local dists: { number } = {}
	for i, p in padList do
		dists[i] = (p.Position - camPos).Magnitude
	end
	local picks = BoostRules.pickPads(dists, #slots)
	local want: { [BasePart]: boolean } = {}
	for _, i in picks do
		want[padList[i]] = true
	end
	for _, s in slots do
		local pad = s.pad
		if pad and not (want[pad] and pad.Parent) then
			freeSlot(s)
		elseif pad then
			want[pad] = nil -- keeps its slot
		end
	end
	for pad in want do
		for _, s in slots do
			if not s.pad then
				s.pad = pad
				s.part.Size = Vector3.new(7, 0.2, 13)
				s.part.CFrame = pad.CFrame * CFrame.new(0, 1.2, 0)
				break
			end
		end
	end
	local scale = Settings.particleScale()
	local on = not Settings.lowGraphics() and scale > 0
	for _, s in slots do
		local padOn = s.pad ~= nil and FidelityRules.padIsLive(if s.pad.Parent then s.pad.Parent:GetAttribute("PadLive") else nil)
		local r = if padOn and on then BASE_RATE * scale else 0
		if r ~= s.rate then
			s.rate = r
			s.emitter.Rate = r
			s.emitter.Enabled = r > 0
		end
	end
end

function BoostPadFx.step(dt: number)
	if not built then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	scanT -= dt
	if scanT <= 0 then
		scanT = BoostRules.PAD_SCAN
		rescan(cam.CFrame.Position)
	end
	local now = os.clock()
	for _, s in slots do
		if s.pad then
			s.flare = math.max(0, s.flare - dt / BoostRules.FLARE_TIME)
			local live = FidelityRules.padIsLive(if s.pad.Parent then s.pad.Parent:GetAttribute("PadLive") else nil)
			s.light.Brightness = if live then BoostRules.padLight(BoostRules.padPulse(now, s.phase), s.flare) else 0
		end
	end
end

return BoostPadFx
