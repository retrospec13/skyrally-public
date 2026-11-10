--!strict
-- Finish stage lighting, client only (shared/FinishLightingRules has the numbers). From the podium until the results card
-- is dismissed the map's Lighting / Atmosphere / ColorCorrection are lifted to a readable level (MK8D / Mario Kart World
-- stage the ceremony in their own bright set whatever the track's time of day), then restored exactly. A property that
-- something else changed meanwhile (the next map's LightingProfiles.apply) is not written back. Race lighting itself
-- is never touched: nothing runs between a race's start and its finish.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FinishLightingRules"))

local FinishLighting = {}

local PROPS = { "Brightness", "ClockTime", "ExposureCompensation", "Ambient", "OutdoorAmbient" }

-- { instance, property, original, applied } for everything changed, so release() restores only what is still ours.
local saved: { { inst: Instance, prop: string, old: any, new: any } } = {}
local active = false

local function set(inst: Instance, prop: string, value: any)
	local old = (inst :: any)[prop]
	if old == value then
		return
	end
	;(inst :: any)[prop] = value
	-- Keep the value as read back: float properties store 32 bits (0.2 reads 0.2000000029...), and release() compares.
	table.insert(saved, { inst = inst, prop = prop, old = old, new = (inst :: any)[prop] })
end

function FinishLighting.isActive(): boolean
	return active
end

function FinishLighting.apply()
	if active then
		return
	end
	active = true
	local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
	local cc = Lighting:FindFirstChildWhichIsA("ColorCorrectionEffect")
	local snap: any = {
		atmosphereDensity = if atmo then atmo.Density else nil,
		atmosphereHaze = if atmo then atmo.Haze else nil,
		ccBrightness = if cc then cc.Brightness else nil,
	}
	for _, p in PROPS do
		snap[p] = (Lighting :: any)[p]
	end
	local t = Rules.target(snap)
	for _, p in PROPS do
		set(Lighting, p, (t :: any)[p])
	end
	if atmo and t.atmosphereDensity and t.atmosphereHaze then
		set(atmo, "Density", t.atmosphereDensity)
		set(atmo, "Haze", t.atmosphereHaze)
	end
	if cc and t.ccBrightness then
		set(cc, "Brightness", t.ccBrightness)
	end
	print(string.format("[SkyRally][FINISH_LIGHT] stage lighting on (Brightness %.1f, Clock %.1f, Exposure %.2f)", t.Brightness, t.ClockTime, t.ExposureCompensation))
end

function FinishLighting.release()
	if not active then
		return
	end
	active = false
	for i = #saved, 1, -1 do
		local s = saved[i]
		if s.inst.Parent and (s.inst :: any)[s.prop] == s.new then
			(s.inst :: any)[s.prop] = s.old
		end
	end
	table.clear(saved)
end

-- The podium stage's own key / fill / rim lights (Rules.STAGE_LIGHTS), created once inside the stage model.
function FinishLighting.buildStageLights(stage: Model)
	for _, d in Rules.STAGE_LIGHTS do
		local anchor = Instance.new("Part")
		anchor.Name = d.name
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Size = Vector3.one
		anchor.CFrame = if d.aim then CFrame.lookAt(d.pos, d.aim) else CFrame.new(d.pos)
		local l = Instance.new(d.kind :: any) :: any
		l.Brightness = d.brightness
		l.Range = d.range
		l.Color = d.color
		l.Shadows = false
		if d.kind == "SpotLight" then
			l.Angle = d.angle or 70
			l.Face = Enum.NormalId.Front
		end
		l.Parent = anchor
		anchor.Parent = stage -- stage space: the stage is pivoted as one, so the lights ride with it
	end
end

return FinishLighting
