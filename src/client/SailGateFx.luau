--!strict
-- FOREST-1 sail-gap ring presentation (rules: shared/SailGateRules). The gate ring stays faintly visible while a sail
-- covers it, brightens as the gap comes round and burns warm gold with a soft light and a sparkle trickle while it is
-- lit. One ring per map, so the whole module is a handful of property writes at 20 Hz: no meshes, nothing near the
-- chase camera, and the ring is the same size lit or dark, so it never hides the route or the next gate.
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SailGateRules = require(Shared:WaitForChild("SailGateRules"))
local TriggerIndex = require(script.Parent:WaitForChild("TriggerIndex"))

local SailGateFx = {}

local TICK = 0.05
local RESCAN = 1.0
local DARK_FADE = 0.6 -- how much of the ring's opacity a sail across it takes away
local LIGHT_RANGE = 38
local LIGHT_BRIGHTNESS = 1.2 -- v29 W1b A4: was 2.4 (the lit gate bloomed the whole opening)
local GOLD = Color3.fromRGB(255, 214, 120)

type Ring = {
	trigger: BasePart,
	cfg: SailGateRules.Config,
	parts: { BasePart },
	base: { number },
	light: PointLight,
	sparkle: ParticleEmitter,
	level: number,
}

local rings: { [BasePart]: Ring } = {}
local sinceTick = 0
local sinceScan = 0

local function build(trigger: BasePart, cfg: SailGateRules.Config): Ring?
	local model = trigger.Parent
	if not model then
		return nil
	end
	local parts, base = {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= trigger and d.Transparency < 1 then
			table.insert(parts, d)
			table.insert(base, d.Transparency)
		end
	end
	local light = Instance.new("PointLight")
	light.Name = "SailGateGlow"
	light.Color = GOLD
	light.Range = LIGHT_RANGE
	light.Brightness = 0
	light.Shadows = false
	light.Parent = trigger
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "SailGateSparkle"
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(GOLD)
	sparkle.LightEmission = 1
	sparkle.Lifetime = NumberRange.new(0.2, 0.3) -- v28 W1.2: short glints, under 0.3 s
	sparkle.Speed = NumberRange.new(2, 5)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) }) -- v29 A4: was 1.0
	sparkle.Rate = 0
	sparkle.Parent = trigger
	return { trigger = trigger, cfg = cfg, parts = parts, base = base, light = light, sparkle = sparkle, level = -1 }
end

local function rescan()
	for _, trig in TriggerIndex.get() do
		if not rings[trig] and trig:GetAttribute("TriggerType") == "BoosterRing" then
			local cfg = SailGateRules.configOf(trig)
			if cfg then
				local ring = build(trig, cfg)
				if ring then
					rings[trig] = ring
				end
			end
		end
	end
	for trig in rings do
		if not trig.Parent or not trig:IsDescendantOf(workspace) then
			rings[trig] = nil
		end
	end
end

local function apply(ring: Ring, glow: number)
	-- Quantised so an idle (dark or lit) ring costs no writes.
	local level = math.floor(glow * 12 + 0.5)
	if level == ring.level then
		return
	end
	ring.level = level
	local g = level / 12
	for i, p in ring.parts do
		if p.Parent then
			local b = ring.base[i]
			p.Transparency = b + (1 - b) * DARK_FADE * (1 - g)
		end
	end
	ring.light.Brightness = LIGHT_BRIGHTNESS * g
	ring.sparkle.Rate = if g >= 1 then 6 else 0 -- v29 A4: a sparse trickle (was 22 a second filling the opening)
end

function SailGateFx.init()
	RunService.Heartbeat:Connect(function(dt: number)
		sinceTick += dt
		sinceScan += dt
		if sinceScan >= RESCAN then
			sinceScan = 0
			rescan()
		end
		if sinceTick < TICK then
			return
		end
		sinceTick = 0
		if next(rings) == nil then
			return
		end
		local now = workspace:GetServerTimeNow()
		for _, ring in rings do
			apply(ring, SailGateRules.glow(now, ring.cfg))
		end
	end)
end

return SailGateFx
