--!strict
-- Slipstream for the local car or plane (v37, shared/SlipstreamRules): sit in a rival's wake and it charges; at full
-- charge you slingshot (the controller fires its boost with the speed SlipstreamRules gives). While it charges, wind
-- lines stream past both sides of the vehicle (denser as it builds, never across the road ahead of the chase camera)
-- and a soft rush rises; the slingshot itself rides the controller's boost (FOV punch, boost hit, flames).
-- step() is called by CarController / FlightController once per driving frame; nothing runs on the grid or in the hub.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SlipstreamRules = require(Shared:WaitForChild("SlipstreamRules"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local SfxV2Audio = require(Shared:WaitForChild("SfxV2Audio"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))

local Slipstream = {}

Slipstream.charge = 0 -- 0..1, read by QA
Slipstream.count = 0 -- slingshots this session (QA)

local state = SlipstreamRules.new()
type Track = { pos: Vector3, at: number, speed: number }
local tracks: { [Model]: Track } = setmetatable({}, { __mode = "k" }) :: any
type Kit = { hull: BasePart, atts: { Attachment }, lines: { ParticleEmitter }, rush: Sound }
local kit: Kit? = nil
local wasIn = false
local lastShown = -1

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function build(hull: BasePart, halfWidth: number): Kit
	local atts, lines = {}, {}
	for _, side in { -1, 1 } do
		local a = Instance.new("Attachment")
		a.Name = "SlipstreamAtt"
		-- ahead of the nose and out past the flank: the lines run back along the side, beside the vehicle, never over it
		a.CFrame = CFrame.new(side * (halfWidth + 2.2), 1.6, -9) * CFrame.Angles(0, math.pi, 0)
		a.Parent = hull
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "SlipstreamLines"
		pe.Texture = tex("speed_line")
		pe.Shape = Enum.ParticleEmitterShape.Box
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		pe.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		pe.EmissionDirection = Enum.NormalId.Front
		pe.SpreadAngle = Vector2.new(2, 2)
		pe.Orientation = Enum.ParticleOrientation.VelocityParallel
		pe.Lifetime = NumberRange.new(0.22, 0.32)
		pe.Speed = NumberRange.new(70, 95)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 0.1) })
		pe.Squash = NumberSequence.new(4)
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.35), NumberSequenceKeypoint.new(0.8, 0.5), NumberSequenceKeypoint.new(1, 1) })
		pe.Color = ColorSequence.new(Color3.fromRGB(235, 246, 255))
		pe.LightEmission = 0.6
		pe.LightInfluence = 0
		pe.Rate = 0
		pe.Enabled = false
		pe.Parent = a
		table.insert(atts, a)
		table.insert(lines, pe)
	end
	local rush = Instance.new("Sound")
	rush.Name = "SlipstreamRush"
	rush.SoundId = SfxV2Audio.boost_loop
	rush.Looped = true
	rush.Volume = 0
	Settings.sfx(rush)
	rush.Parent = hull
	return { hull = hull, atts = atts, lines = lines, rush = rush }
end

local function kitFor(hull: BasePart, halfWidth: number): Kit
	local k = kit
	if k and k.hull == hull and k.rush.Parent == hull then
		return k
	end
	if k then
		for _, a in k.atts do
			a:Destroy()
		end
		k.rush:Destroy()
	end
	local nk = build(hull, halfWidth)
	kit = nk
	return nk
end

local function setLook(k: Kit, charge: number, fired: boolean)
	local scale = Settings.particleScale()
	for _, pe in k.lines do
		local rate = if charge > 0.05 then (8 + 34 * charge) * scale else 0
		pe.Rate = rate
		pe.Enabled = rate > 0
		if fired and scale > 0 then
			pe:Emit(math.max(1, math.floor(10 * scale + 0.5)))
		end
	end
	if charge > 0.05 then
		k.rush.Volume = 0.05 + 0.2 * charge
		k.rush.PlaybackSpeed = 0.8 + 0.5 * charge
		if not k.rush.IsPlaying then
			k.rush:Play()
		end
	elseif k.rush.IsPlaying then
		k.rush:Stop()
	end
end

-- Speed of a rival from its replicated position (studs/s, smoothed over >= 0.1 s windows).
local function rivalSpeed(model: Model, pos: Vector3, now: number): number
	local t = tracks[model]
	if not t then
		tracks[model] = { pos = pos, at = now, speed = 0 }
		return 0
	end
	local dt = now - t.at
	if dt >= 0.1 then
		local v = (pos - t.pos).Magnitude / dt
		t.speed = if dt > 1 then v else t.speed + (v - t.speed) * 0.6
		t.pos, t.at = pos, now
	end
	return t.speed
end

-- One driving frame. hull: the local vehicle's hull; speed: its forward speed (studs/s); halfWidth: half its width.
-- Returns true on the frame the slingshot fires.
function Slipstream.step(dt: number, hull: BasePart?, speed: number, halfWidth: number): boolean
	if not hull or not hull.Parent then
		Slipstream.stop()
		return false
	end
	local planes = workspace:FindFirstChild("Planes")
	local now = os.clock()
	local inWake = false
	if planes then
		local cf = hull.CFrame
		for _, m in planes:GetChildren() do
			if m ~= hull.Parent and m:IsA("Model") and m:GetAttribute("IsBoss") ~= true then
				local h = m:FindFirstChild("Hull")
				if h and h:IsA("BasePart") then
					local p = h.Position
					local rs = rivalSpeed(m, p, now)
					if not inWake then
						local rel = cf:PointToObjectSpace(p)
						inWake = SlipstreamRules.inWake(rel.X, rel.Y, rel.Z, speed, rs)
					end
				end
			end
		end
	end
	if inWake and not wasIn and state.cooldown <= 0 and state.charge < 0.05 then
		TrickJuice.play("trick_whoosh", 0.75, 0.25) -- tucked in: a soft whoosh as the wake catches
	end
	wasIn = inWake
	local fired = SlipstreamRules.step(state, inWake, dt)
	Slipstream.charge = state.charge
	local shown = math.floor(state.charge * 10) / 10
	if shown ~= lastShown then
		lastShown = shown
		Players.LocalPlayer:SetAttribute("DraftCharge", shown) -- QA / captures: the charge in 0.1 steps
	end
	local k = kitFor(hull, halfWidth)
	setLook(k, if state.cooldown > 0 then 0 else state.charge, fired)
	if fired then
		Slipstream.count += 1
		TrickJuice.play("roll_whoosh_r", 0.9, 0.5)
		print(string.format("[SkyRally][DRAFT] slingshot speed=%d", math.floor(speed)))
	end
	return fired
end

function Slipstream.stop()
	if state.charge > 0 then
		Players.LocalPlayer:SetAttribute("DraftCharge", 0)
		lastShown = 0
	end
	state.charge = 0
	Slipstream.charge = 0
	wasIn = false
	local k = kit
	if k then
		setLook(k, 0, false)
	end
end

return Slipstream
