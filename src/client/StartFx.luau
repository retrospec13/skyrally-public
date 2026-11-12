--!strict
-- Rocket start feedback (v37, shared/TrickRules start grades), for the local car and plane alike:
-- * step(): every grid frame. While the gas is held on the beat (grade good / perfect) the exhaust glows and throws a
--   few sparks, brighter and denser toward GO (blue-white for good, hot orange for perfect), and a short rising whine
--   plays under the revs. A burnt (flooded) hold shows nothing here (the controllers puff soot and stutter the revs).
-- * release(): on GO for a good / perfect start: one spark + flame burst at the exhaust (the controllers' triggerBoost
--   adds the FOV punch, the boost hit and the flames).
-- * stop(): off (GO without a grade, a reset, the vehicle going away).
-- Pre-built emitters on one Attachment per hull; nothing runs while idle. Rates scale with Settings.particleScale().
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local SfxV2Audio = require(Shared:WaitForChild("SfxV2Audio"))
local SfxV37Assets = require(Shared:WaitForChild("SfxV37Assets")) :: { [string]: string } -- rs_charge / rs_burst (v37)
local Sfx37 = require(script.Parent:WaitForChild("Sfx37"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local StartFx = {}

local GOOD = Color3.fromRGB(90, 190, 255)
local PERFECT = Color3.fromRGB(255, 150, 40)

type Kit = { hull: BasePart, att: Attachment, sparks: ParticleEmitter, glow: ParticleEmitter, light: PointLight, whine: Sound }
local kit: Kit? = nil

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function seq(...: number): NumberSequence
	local a = { ... }
	local kps = {}
	for i = 1, #a, 2 do
		table.insert(kps, NumberSequenceKeypoint.new(a[i], a[i + 1]))
	end
	return NumberSequence.new(kps)
end

local function build(hull: BasePart): Kit
	local att = Instance.new("Attachment")
	att.Name = "StartFxAtt"
	att.Parent = hull
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "StartFxSparks"
	sparks.Texture = tex("spark_streak")
	sparks.Lifetime = NumberRange.new(0.18, 0.36)
	sparks.Speed = NumberRange.new(14, 30)
	sparks.SpreadAngle = Vector2.new(28, 28)
	sparks.Size = seq(0, 1.3, 1, 0)
	sparks.Transparency = seq(0, 0, 1, 1)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Orientation = Enum.ParticleOrientation.VelocityParallel
	sparks.Acceleration = Vector3.new(0, -30, 0)
	sparks.EmissionDirection = Enum.NormalId.Front
	sparks.Rate = 0
	sparks.Enabled = false
	sparks.Parent = att
	local glow = Instance.new("ParticleEmitter")
	glow.Name = "StartFxGlow"
	glow.Texture = tex("glow_soft")
	glow.Lifetime = NumberRange.new(0.12, 0.2)
	glow.Speed = NumberRange.new(0, 1)
	glow.Size = seq(0, 1.6, 1, 0.4)
	glow.Transparency = seq(0, 0.2, 1, 1)
	glow.LightEmission = 0.8
	glow.LightInfluence = 0
	glow.Rate = 0
	glow.Enabled = false
	glow.Parent = att
	local light = Instance.new("PointLight")
	light.Name = "StartFxLight"
	light.Range = 9
	light.Brightness = 0
	light.Shadows = false
	light.Enabled = false
	light.Parent = att
	local whine = Instance.new("Sound")
	whine.Name = "StartFxWhine"
	-- v37: the generated rocket-start charge (one rising shot per charge), the old boost loop as the fallback
	whine.SoundId = SfxV37Assets.rs_charge or SfxV2Audio.boost_loop
	whine.Looped = SfxV37Assets.rs_charge == nil
	whine.Volume = 0
	Settings.sfx(whine)
	whine.Parent = hull
	return { hull = hull, att = att, sparks = sparks, glow = glow, light = light, whine = whine }
end

local function kitFor(hull: BasePart): Kit
	local k = kit
	if k and k.hull == hull and k.att.Parent == hull then
		return k
	end
	if k and k.att.Parent then
		k.att:Destroy()
		k.whine:Destroy()
	end
	local nk = build(hull)
	kit = nk
	return nk
end

-- exhaust: world CFrame whose LookVector points out of the exhaust (backwards); state: TrickRules start state;
-- charge: TrickRules.startCharge (0 = off).
function StartFx.step(hull: BasePart?, exhaust: CFrame, state: string, charge: number)
	if not hull or charge <= 0 or not (state == "good" or state == "perfect") then
		StartFx.stop()
		return
	end
	local k = kitFor(hull)
	k.att.WorldCFrame = exhaust
	local perfect = state == "perfect"
	local c = if perfect then PERFECT else GOOD
	local scale = Settings.particleScale()
	k.sparks.Color = ColorSequence.new(Color3.new(1, 1, 1), c)
	k.sparks.Rate = (if perfect then 80 else 36) * charge * scale
	k.sparks.Enabled = k.sparks.Rate > 0
	k.glow.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(c, 0.6), c)
	k.glow.Size = seq(0, (if perfect then 1.8 else 1.3) + 1.8 * charge, 1, 0.5)
	k.glow.Rate = 24 * scale
	k.glow.Enabled = scale > 0
	k.light.Color = c
	k.light.Brightness = (if perfect then 3 else 1.8) * charge
	k.light.Enabled = true
	-- The whine rises with the charge (0.7 -> 1.5) and only while it builds: short, never a drone.
	if k.whine.Looped then
		k.whine.PlaybackSpeed = 0.7 + 0.8 * charge
		k.whine.Volume = (if perfect then 0.42 else 0.3) * charge
		if not k.whine.IsPlaying then
			k.whine:Play()
		end
	else
		-- the one-shot charge: starts once per hold, its volume follows the charge
		k.whine.Volume = (if perfect then 0.45 else 0.32) * math.max(0.4, charge)
		if not k.whine.IsPlaying and not k.att:GetAttribute("ChargePlayed") then
			k.att:SetAttribute("ChargePlayed", true)
			k.whine.PlaybackSpeed = if perfect then 1.06 else 1
			k.whine:Play()
		end
	end
end

-- GO burst at the exhaust for a good / perfect start (count scales with the grade).
function StartFx.release(hull: BasePart?, exhaust: CFrame, state: string)
	if not hull or not (state == "good" or state == "perfect") then
		StartFx.stop()
		return
	end
	local k = kitFor(hull)
	k.att.WorldCFrame = exhaust
	local perfect = state == "perfect"
	local c = if perfect then PERFECT else GOOD
	local scale = Settings.particleScale()
	k.sparks.Color = ColorSequence.new(Color3.new(1, 1, 1), c)
	k.glow.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(c, 0.5), c)
	k.glow.Size = seq(0, if perfect then 4.2 else 3, 1, 0.5)
	if scale > 0 then
		k.sparks:Emit(math.max(1, math.floor((if perfect then 34 else 16) * scale + 0.5)))
		k.glow:Emit(if perfect then 4 else 2)
	end
	k.sparks.Enabled, k.glow.Enabled = false, false
	k.whine:Stop()
	Sfx37.play("rs_burst", if perfect then 0.55 else 0.42, if perfect then 1.08 else 1)
	k.light.Brightness = if perfect then 5 else 3
	k.light.Enabled = true
	task.delay(0.25, function()
		local cur = kit
		if cur == k then
			k.light.Enabled = false
		end
	end)
end

function StartFx.stop()
	local k = kit
	if not k then
		return
	end
	k.att:SetAttribute("ChargePlayed", nil)
	if k.sparks.Enabled or k.glow.Enabled or k.light.Enabled or k.whine.IsPlaying then
		k.sparks.Enabled, k.glow.Enabled, k.light.Enabled = false, false, false
		k.sparks.Rate, k.glow.Rate = 0, 0
		k.whine:Stop()
	end
end

return StartFx
