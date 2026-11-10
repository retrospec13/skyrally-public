--!strict
-- DINO-4 launch upgrade (docs/design/TRACK_VARIETY.md 5a), client half. Two things, both driven by shared/VolcanoRules:
-- * GEYSER UPDRAFTS. The Alt1 vents server/VolcanoVents built (workspace map root / VolcanoVents) get their effects here:
--   a crater glow that rises through the 1.6 s build-up (the telegraph), a steam trickle that thickens, then a 1.2 s
--   column of steam and sparks. The cycle is a pure function of server time, so every client and the server agree with
--   no traffic. Flying a plane through an ACTIVE column gives the ordinary ring boost: this client applies it at once
--   (FlightController.triggerBoost) and reports "GeyserTriggered" so the server re-checks the stage and position and
--   applies the same boost to its copy of the plane. Never a hazard: nothing here collides, damages or stuns.
-- * LAP-3 ERUPTION. While the local racer is on the eruption lap (the folder's EruptionLap attribute, 3) the volcano
--   wakes: a pulsing lava glow under the plane, a drift of ash, a rumble on a fixed beat with a small camera shake, and
--   one banner. The rumble is a stand-in (the sneeze inhale sample pitched down) until a real asset replaces it.
-- * Camera and phone safety: every particle is small and translucent, the ash rate follows Settings.particleScale (0.6 on
--   a phone, 0.4 under LOW GRAPHICS), the column is translucent and 1.2 s long, the lava light is one PointLight
--   (brightness <= 1.1) and nothing is ever placed on the route ahead of the plane. Vents beyond 900 studs are idle,
--   beyond 450 they update at a fraction of the frame rate.
-- QA (Studio): workspace.VolcanoTest = true prints each vent's stage; "eruption" starts the eruption now and keeps it until the attribute is cleared.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("VolcanoRules"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local VolcanoMoments = {}

local FOLDER_NAME = "VolcanoVents"
local RACE_MODES = { race = true, quickrace = true, timetrial = true, coin = true, stormcup = true }
local SCAN_SEC = 1.5
local FAR, MID = 900, 450

type VentFx = {
	vent: Rules.Vent,
	model: Model,
	glow: BasePart,
	steam: ParticleEmitter,
	sparks: ParticleEmitter,
	light: PointLight,
	crossedAt: number,
	stage: string,
}

local fx: { VentFx } = {}
local fxFolder: Instance? = nil
local conn: RBXScriptConnection? = nil
local lastScan = -math.huge
local frameNo = 0
local flight: any = nil
local raceUI: any = nil
local eventRemote: RemoteEvent? = nil

local eruptStart: number? = nil
local prevT = -1
local ashPart: Part? = nil
local ashEmitter: ParticleEmitter? = nil
local lavaPart: Part? = nil
local lavaLight: PointLight? = nil

local ORANGE = Color3.fromRGB(255, 120, 40)
local HOT = Color3.fromRGB(255, 226, 150)

---------------------------------------------------------------------------------------------------- vents

local function newEmitter(att: Attachment, name: string, tex: string): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = name
	FlipFx.apply(pe, tex)
	pe.Enabled = false
	pe.Rate = 0
	pe.LockedToPart = false
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Parent = att
	return pe
end

local function buildFx(model: Model): VentFx?
	local glow = model:FindFirstChild("Glow")
	local base = model:GetAttribute("BasePos")
	if not (glow and glow:IsA("BasePart") and typeof(base) == "Vector3") then
		return nil
	end
	local vent = Rules.parseVent({
		id = model.Name,
		pos = base,
		phase = model:GetAttribute("Phase"),
		radius = model:GetAttribute("Radius"),
		height = model:GetAttribute("Height"),
	})
	if not vent then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "VentTop"
	-- The glow cylinder is stood on end (its axis, local X, is world up), so the attachment is turned back to world-up:
	-- its local +Y (EmissionDirection Top) then points up the column, and it sits on the glow's top face (X half 0.15).
	att.CFrame = CFrame.new(0.15, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2)
	att.Parent = glow

	local steam = newEmitter(att, "Steam", "smoke_puff_8x8")
	steam.Lifetime = NumberRange.new(0.6, 0.9)
	steam.SpreadAngle = Vector2.new(9, 9)
	steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 10) })
	steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	steam.Color = ColorSequence.new(Color3.fromRGB(255, 232, 214), Color3.fromRGB(190, 176, 170))
	steam.LightEmission = 0.25
	steam.Rotation = NumberRange.new(0, 360)
	steam.Enabled = true

	local sparks = newEmitter(att, "Sparks", "ember")
	sparks.Lifetime = NumberRange.new(0.5, 0.9)
	sparks.SpreadAngle = Vector2.new(14, 14)
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0.2) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	sparks.Color = ColorSequence.new(HOT, ORANGE)
	sparks.LightEmission = 1
	sparks.Acceleration = Vector3.new(0, -20, 0)
	sparks.Enabled = true

	local light = Instance.new("PointLight")
	light.Name = "VentLight"
	light.Color = ORANGE
	light.Range = 34
	light.Brightness = 0
	light.Shadows = false
	light:SetAttribute("MapLight", true) -- LightLod keeps only the nearest decor lights on
	light.Parent = glow

	return { vent = vent, model = model, glow = glow, steam = steam, sparks = sparks, light = light, crossedAt = -math.huge, stage = "" }
end

local function scan()
	local root = TrackRegistry.getRoot()
	local folder = if root then root:FindFirstChild(FOLDER_NAME) else nil
	if folder == fxFolder then
		return
	end
	table.clear(fx)
	fxFolder = folder
	if not folder then
		return
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("GeyserVent") == true then
			local e = buildFx(m)
			if e then
				table.insert(fx, e)
			end
		end
	end
end

-- Effects of one vent for server time `now` (glow, light, steam and sparks follow the stage).
local function paint(e: VentFx, now: number)
	local v = e.vent
	local g = Rules.glow(now, v.phase)
	local stage = Rules.stage(now, v.phase)
	e.glow.Transparency = 1 - (0.3 + 0.7 * g) * 0.9
	e.glow.Color = ORANGE:Lerp(HOT, if stage == "active" then 1 else math.max(0, g - 0.4))
	e.light.Brightness = g * 1.4
	local scale = Settings.particleScale()
	e.steam.Rate = Rules.steamRate(now, v.phase, scale)
	if stage ~= e.stage then -- speeds change only when the stage does (no per-frame allocation)
		e.stage = stage
		if stage == "active" then
			e.steam.Speed = NumberRange.new(v.height * 1.2, v.height * 1.5)
			e.sparks.Speed = NumberRange.new(v.height * 1.3, v.height * 1.7)
		else
			e.steam.Speed = NumberRange.new(5, 9)
		end
	end
	e.sparks.Rate = if stage == "active" then 26 * scale else 0
end

local function idle(e: VentFx)
	e.steam.Rate = 0
	e.sparks.Rate = 0
	e.light.Brightness = 0
end

---------------------------------------------------------------------------------------------------- crossing

local function localHull(): BasePart?
	local model = Kit.vehicleOf(LocalPlayer.UserId)
	if not model or model:GetAttribute("IsCar") == true then
		return nil
	end
	return Kit.hullOf(model)
end

local function racing(): boolean
	return RACE_MODES[RaceAttr.mine("RaceMode")] == true and LocalPlayer:GetAttribute("RaceFinished") ~= true
end

local function cross(e: VentFx, hull: BasePart)
	e.crossedAt = os.clock()
	local pos = hull.Position
	if flight and type(flight.triggerBoost) == "function" then
		flight.triggerBoost(false)
	end
	Kit.burst("sparks", CFrame.lookAt(pos, pos + Vector3.yAxis), 1)
	local ok, Sfx = pcall(require, script.Parent:WaitForChild("Sfx"))
	if ok and type(Sfx) == "table" and type(Sfx.play) == "function" then
		Sfx.play("pad_zip", 1.1, 0.4)
	end
	if eventRemote then
		eventRemote:FireServer("GeyserTriggered", { id = e.vent.id, pos = pos })
	end
end

---------------------------------------------------------------------------------------------------- eruption

local function ensureEruptionFx()
	if ashPart and ashPart.Parent then
		return
	end
	local ash = Instance.new("Part")
	ash.Name = "VolcanoAsh"
	ash.Anchored = true
	ash.CanCollide = false
	ash.CanQuery = false
	ash.CanTouch = false
	ash.CastShadow = false
	ash.Transparency = 1
	ash.Size = Vector3.new(150, 1, 150)
	ash.Parent = workspace.Terrain
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Ash"
	FlipFx.apply(pe, "ember")
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.EmissionDirection = Enum.NormalId.Bottom
	pe.Lifetime = NumberRange.new(4, 6)
	pe.Speed = NumberRange.new(1, 3)
	pe.SpreadAngle = Vector2.new(25, 25)
	pe.Acceleration = Vector3.new(2, -4, 1) -- a slow drift down and across
	pe.Size = NumberSequence.new(Rules.ASH_SIZE_MAX)
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, Rules.ASH_TRANSPARENCY_MIN),
		NumberSequenceKeypoint.new(0.85, Rules.ASH_TRANSPARENCY_MIN),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Color = ColorSequence.new(Color3.fromRGB(96, 84, 80), Color3.fromRGB(168, 120, 90))
	pe.LightEmission = 0.1
	pe.LightInfluence = 0.5
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-60, 60)
	pe.LockedToPart = false
	pe.Rate = 0
	pe.Parent = ash
	ashPart, ashEmitter = ash, pe

	local lava = Instance.new("Part")
	lava.Name = "VolcanoLavaGlow"
	lava.Anchored = true
	lava.CanCollide = false
	lava.CanQuery = false
	lava.CanTouch = false
	lava.CastShadow = false
	lava.Transparency = 1
	lava.Size = Vector3.one
	lava.Parent = workspace.Terrain
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 104, 34)
	light.Range = Rules.LIGHT_RANGE
	light.Brightness = 0
	light.Shadows = false
	light.Parent = lava
	lavaPart, lavaLight = lava, light
end

local function stopEruption()
	eruptStart = nil
	prevT = -1
	if ashEmitter then
		ashEmitter.Rate = 0
	end
	if lavaLight then
		lavaLight.Brightness = 0
	end
end

local function startEruption(banner: boolean)
	eruptStart = os.clock()
	prevT = -1
	ensureEruptionFx()
	if banner and raceUI and type(raceUI.stamp) == "function" then
		pcall(raceUI.stamp, "THE VOLCANO WAKES", Color3.fromRGB(255, 150, 70), 1.8)
	end
end

local function stepEruption(focus: Vector3)
	local t0 = eruptStart
	if not t0 then
		return
	end
	local t = os.clock() - t0
	if ashPart and ashEmitter then
		ashPart.CFrame = CFrame.new(focus + Vector3.new(0, 26, 0))
		ashEmitter.Rate = Rules.ashRate(t, Settings.particleScale())
	end
	if lavaPart and lavaLight then
		lavaPart.CFrame = CFrame.new(focus + Vector3.new(0, -26, 0))
		lavaLight.Brightness = Rules.lavaLight(t)
	end
	if Rules.rumbleStarts(prevT, t) then
		-- Stand-in rumble: the sneeze inhale sample, pitched far down. A real asset replaces the cue later.
		Kit.ui("dino_rumble", "sneeze_inhale", Rules.RUMBLE_VOLUME, Rules.RUMBLE_SPEED)
		Kit.trauma(Rules.shake())
	end
	prevT = t
end

---------------------------------------------------------------------------------------------------- frame

local function step()
	frameNo += 1
	local nowClock = os.clock()
	if nowClock - lastScan >= SCAN_SEC then
		lastScan = nowClock
		scan()
	end
	if #fx == 0 and not eruptStart and not fxFolder then
		return
	end
	local focus = Kit.focus()
	local now = workspace:GetServerTimeNow()
	local hull = localHull()
	local isRacing = racing()
	for _, e in fx do
		local d = (focus - e.vent.pos).Magnitude
		if d > FAR then
			idle(e)
		elseif d <= MID or frameNo % 6 == 0 then
			paint(e, now)
		end
		if hull and isRacing and Rules.inColumn(e.vent, hull.Position) and Rules.isActive(now, e.vent.phase)
			and nowClock - e.crossedAt >= Rules.COOLDOWN then
			cross(e, hull)
		end
	end

	-- the eruption lap
	local folder = fxFolder
	local lap = LocalPlayer:GetAttribute("Lap")
	local lapWanted = if folder then folder:GetAttribute("EruptionLap") else nil
	local want = isRacing and type(lap) == "number" and type(lapWanted) == "number" and Rules.erupting(lap, lapWanted :: number)
	if want and not eruptStart then
		startEruption(true)
	elseif not want and eruptStart and workspace:GetAttribute("VolcanoTest") ~= "eruption" then
		stopEruption()
	end
	stepEruption(focus)
end

function VolcanoMoments.init(flightController: any, raceUi: any)
	flight = flightController
	raceUI = raceUi
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
		local ev = remotes and remotes:WaitForChild("RaceEventRemote", 15)
		if ev and ev:IsA("RemoteEvent") then
			eventRemote = ev
		end
	end)
	workspace:GetAttributeChangedSignal("VolcanoTest"):Connect(function()
		local v = workspace:GetAttribute("VolcanoTest")
		if v == "eruption" then
			ensureEruptionFx()
			startEruption(false)
		elseif v == true then
			local now = workspace:GetServerTimeNow()
			for _, e in fx do
				print(string.format("[SkyRally][GEYSER] %s stage=%s glow=%.2f untilActive=%.2f", e.vent.id,
					(Rules.stage(now, e.vent.phase)), Rules.glow(now, e.vent.phase), Rules.untilActive(now, e.vent.phase)))
			end
		end
	end)
	if conn then
		conn:Disconnect()
	end
	conn = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(function()
			step()
		end)
		if not ok then
			warn("[SkyRally][GEYSER] step failed: " .. tostring(err))
		end
	end)
end

return VolcanoMoments
