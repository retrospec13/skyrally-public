--!strict
-- The hub during a storm race (economy v3 phase 5, venue B: racers go to their own race area, only the hub changes).
-- Client-side visuals, hub only (shared/StormRules.hubState decides, 2 Hz):
--   * storm sky: the HUB-0-STORM lighting values (shared/lighting/hub0.luau) written over the hub's own, each property
--     saved first and restored when the storm ends (only if nothing else changed it meanwhile, FinishLighting's rule);
--   * lightning: every 6-14 s a short Lighting flash and a ParticleEmitter bolt (VfxAssets lightning_beam) emitted far
--     out ahead of the camera and high in the sky, never between the camera and the vehicle; no meshes;
--   * thunder: the Soundscape's storm bed (SoundscapeRules.stormLayer, amb_storm) plays in the hub while the storm is on, and each
--     bolt is followed a beat later by a far clap (Creator Store thunder, shared/ToolboxAudio; three variants);
--   * the marker over the Storm vendor stand (workspace.StormVendorStand.MarkerAnchor): STORM RACE IN PROGRESS while a
--     storm race runs, otherwise NEXT STORM RACE m:ss (NotifySpec storm_hub_live / storm_hub_next, NotifyKit arch label).
-- On: workspace.StormRaceLive (server: a storm race is running on this server; set by the per-group storm flow, a later
-- phase) or workspace.HubStormQA (Studio capture switch). Next: workspace.StormCupAt, else the next :00/:30 UTC.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StormRules = require(Shared:WaitForChild("StormRules"))
local StormConfig = require(Shared:WaitForChild("StormConfig"))
local ToolboxAudioRules = require(Shared:WaitForChild("ToolboxAudioRules"))
local ToolboxCues = require(script.Parent:WaitForChild("ToolboxCues"))
local LightingProfiles = require(Shared:WaitForChild("LightingProfiles"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets")) :: any
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
-- Storm race v2 (per group): the local player's own race mode; workspace while PER_GROUP is off. A racer in a storm field
-- (or any group race) is not in the hub, so his race map never gets the hub's storm sky.
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local HubStorm = {}

HubStorm.PERIOD = 0.5
HubStorm.PROFILE = "HUB-0-STORM"

local saved: { { inst: Instance, prop: string, old: any, new: any } } = {}
local stormOn = false
local marker: any = nil
local markerAnchor: BasePart? = nil
local boltPart: Part? = nil
local boltEmitter: ParticleEmitter? = nil
local nextFlash = 0
local flashBefore: number? = nil -- Lighting.Brightness before the flash that is lit now
local rng = Random.new()

local function set(inst: Instance, prop: string, value: any)
	local ok, old = pcall(function()
		return (inst :: any)[prop]
	end)
	if not ok or old == value then
		return
	end
	local okSet = pcall(function()
		(inst :: any)[prop] = value
	end)
	if okSet then
		table.insert(saved, { inst = inst, prop = prop, old = old, new = (inst :: any)[prop] })
	end
end

local function restore()
	for i = #saved, 1, -1 do
		local s = saved[i]
		if s.inst.Parent and (s.inst :: any)[s.prop] == s.new then
			(s.inst :: any)[s.prop] = s.old
		end
	end
	table.clear(saved)
end

-- Storm sky: the profile's Lighting values and its Atmosphere / ColorCorrection values on the hub's own effects.
local function applySky()
	local profile = LightingProfiles.get(HubStorm.PROFILE) :: any
	if not profile then
		return
	end
	for _, pair in profile.lighting do
		set(Lighting, pair[1], pair[2])
	end
	for _, effect in profile.effects do
		local inst = Lighting:FindFirstChildWhichIsA(effect.className)
		if inst then
			for _, pair in effect.props do
				set(inst, pair[1], pair[2])
			end
		end
	end
end

local function ensureBolt(): (Part?, ParticleEmitter?)
	if boltPart and boltPart.Parent and boltEmitter then
		return boltPart, boltEmitter
	end
	local tex = if VfxAssets.lightning_beam then VfxAssets.lightning_beam.id else ""
	local p = Instance.new("Part")
	p.Name = "SkyRally_HubStormBolt"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	local e = Instance.new("ParticleEmitter")
	e.Texture = tex
	e.Enabled = false
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.18, 0.28)
	e.Speed = NumberRange.new(0)
	e.Size = NumberSequence.new(160)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Color = ColorSequence.new(Color3.fromRGB(235, 230, 255))
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.6, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	e.Rotation = NumberRange.new(-12, 12)
	e.Parent = p
	p.Parent = workspace
	boltPart, boltEmitter = p, e
	return p, e
end

-- A far clap after the bolt (Creator Store thunder, three variants; ToolboxAudioRules.thunder): the flash comes first, the sound
-- follows a beat later. Silent when the cue has no id.
local function thunderClap()
	local cue, pitch = ToolboxAudioRules.thunder(rng:NextNumber(), rng:NextNumber())
	task.delay(ToolboxAudioRules.thunderDelay(rng:NextNumber()), function()
		if stormOn then
			ToolboxCues.play(cue, pitch)
		end
	end)
end

local function flash()
	thunderClap()
	local cam = workspace.CurrentCamera
	local p, e = ensureBolt()
	if cam and p and e then
		local look = cam.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
		local side = Vector3.new(-flat.Z, 0, flat.X) * rng:NextNumber(-0.5, 0.5) * StormConfig.HUB.boltDistance
		p.Position = cam.CFrame.Position + flat * StormConfig.HUB.boltDistance + side + Vector3.new(0, StormConfig.HUB.boltHeight, 0)
		e:Emit(1)
	end
	if flashBefore then
		return -- a flash is still lit; never stack one on top (the brightness would ratchet up)
	end
	local before = Lighting.Brightness
	Lighting.Brightness = before + StormConfig.HUB.flashBrightness
	-- Read back: Brightness is stored as a float, so comparing with the double we wrote never matches and the flash
	-- would stay lit (then the next flash would add to it).
	local lit = Lighting.Brightness
	flashBefore = before
	task.delay(StormConfig.HUB.flashSeconds, function()
		if flashBefore == before then
			flashBefore = nil
			if Lighting.Brightness == lit then
				Lighting.Brightness = before
			end
		end
	end)
end

-- Ends a lit flash now (the storm turning off mid-flash), so restore() sees the storm value it set.
local function endFlash()
	local b = flashBefore
	if b then
		flashBefore = nil
		Lighting.Brightness = b
	end
end

local function setStorm(on: boolean)
	if on == stormOn then
		return
	end
	stormOn = on
	if on then
		applySky()
		nextFlash = os.clock() + StormRules.lightningGap(rng:NextNumber())
		print("[SkyRally][HUB_STORM] storm on")
	else
		endFlash()
		restore()
		if boltPart then
			boltPart:Destroy()
			boltPart, boltEmitter = nil, nil
		end
		print("[SkyRally][HUB_STORM] storm off")
	end
end

local function findAnchor(): BasePart?
	local stand = workspace:FindFirstChild("StormVendorStand")
	local a = if stand then stand:FindFirstChild("MarkerAnchor") else nil
	return if a and a:IsA("BasePart") then a else nil
end

local function updateMarker(state: StormRules.HubState)
	local anchor = if state.show and state.marked then findAnchor() else nil
	if anchor ~= markerAnchor then
		if marker then
			marker.destroy()
			marker = nil
		end
		markerAnchor = anchor
		if anchor then
			marker = NotifyKit.archLabel(anchor, state.text, "storm")
		end
	end
	if marker then
		marker.setText(state.text)
	end
end

local function tick()
	local state = StormRules.hubState({
		mode = RaceAttr.mine("RaceMode"),
		live = workspace:GetAttribute("StormRaceLive"),
		qa = workspace:GetAttribute("HubStormQA"),
		nextAt = workspace:GetAttribute("StormCupAt"),
		cupEnabled = workspace:GetAttribute("StormCupEnabled"),
	}, workspace:GetServerTimeNow())
	setStorm(state.active and workspace:GetAttribute("TrackSwitching") ~= true)
	updateMarker(state)
end

function HubStorm.isOn(): boolean
	return stormOn
end

function HubStorm.init()
	local acc = HubStorm.PERIOD
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if stormOn and os.clock() >= nextFlash then
			nextFlash = os.clock() + StormRules.lightningGap(rng:NextNumber())
			local ok, err = pcall(function(): any
				flash()
				return nil
			end)
			if not ok then
				warn("[SkyRally][HUB_STORM] flash failed: " .. tostring(err))
			end
		end
		if acc < HubStorm.PERIOD then
			return
		end
		acc = 0
		local ok, err = pcall(function(): any
			tick()
			return nil
		end)
		if not ok then
			warn("[SkyRally][HUB_STORM] tick failed: " .. tostring(err))
		end
	end)
end

return HubStorm
