--!strict
-- SNOW-1 over/under crossing cue, client only (TRACK_VARIETY 5a). When two racers cross at the arch bridge within one
-- second of each other, one under and one over (shared/SnowCrossingRules; replicated hull positions from workspace.Planes, so players and bots
-- count alike), the bridge answers with a horn and a spotlight sweep: two lamps on the deck edges swing their beams over
-- the gorge for a few seconds.
-- * VISUAL AND AUDIO ONLY: two anchored, non-colliding, non-queryable lamp parts (a SpotLight and a thin translucent
--   Beam each) plus one pooled Sound; no map Instance, vehicle or race state is touched, so wall driving, the corridor,
--   kill volumes and rescue are unchanged. The beams swing away from the route (SnowCrossingRules.lamp), stay thin and
--   mostly transparent, and are skipped under LOW GRAPHICS (the lights stay).
-- * Phone budget: one 10 Hz poll that only runs on SNOW-1 and only looks at cars while this client is within
--   POLL_RANGE of the bridge; the show runs on MomentKit.animate.
-- The horn is a stand-in (the foghorn cue from WorldMomentsAudio, pitched up) until a real air horn is uploaded.
-- QA (Studio): workspace.SnowCrossingTest = true plays the show once.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SnowCrossingRules"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local SnowCrossing = {}

local POLL_INTERVAL = 0.1
local POLL_RANGE = 1400 -- studs from the bridge centre: farther than this nothing is polled (the horn reaches 900)
local FOLDER_NAME = "SnowCrossingFx"
local LAMP_COLOR = Color3.fromRGB(205, 232, 255)

type Lamp = { part: Part, target: Part, light: SpotLight, beam: Beam, side: number }

local folder: Folder? = nil
local lamps: { Lamp }? = nil
local state = Rules.new()
local conn: RBXScriptConnection? = nil
local acc = 0
local playing = false

local function visualOnly(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
end

local function buildLamps(): { Lamp }
	local root = Instance.new("Folder")
	root.Name = FOLDER_NAME
	local out = {}
	for _, side in { 1, -1 } do
		local part = Instance.new("Part")
		part.Name = "Lamp" .. (if side > 0 then "South" else "North")
		visualOnly(part)
		local target = Instance.new("Part")
		target.Name = part.Name .. "Target"
		visualOnly(target)
		local a0 = Instance.new("Attachment")
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Parent = target
		local light = Instance.new("SpotLight")
		light.Color = LAMP_COLOR
		light.Range = 150
		light.Angle = 38
		light.Shadows = false
		light.Face = Enum.NormalId.Front
		light.Brightness = 0
		light.Enabled = false
		light.Parent = part
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Color = ColorSequence.new(LAMP_COLOR)
		beam.LightEmission = 1
		beam.Width0 = 1.2
		beam.Width1 = 7
		beam.FaceCamera = true
		beam.Transparency = NumberSequence.new(1)
		beam.Enabled = false
		beam.Parent = part
		part.Parent = root
		target.Parent = root
		table.insert(out, { part = part, target = target, light = light, beam = beam, side = side })
	end
	root.Parent = workspace
	folder = root
	return out
end

local function setLamp(l: Lamp, k: number)
	local pos, look = Rules.lamp(l.side, k)
	l.part.CFrame = CFrame.lookAt(pos, pos + look)
	l.target.CFrame = CFrame.new(pos + look * Rules.BEAM_LENGTH)
	local e = Rules.envelope(k)
	l.light.Brightness = 5 * e
	local t = 0.84 - 0.1 * e
	l.beam.Transparency = NumberSequence.new(t, math.min(1, t + 0.14))
end

local function show()
	if playing then
		return
	end
	playing = true
	local list = lamps
	if not list or not (folder and folder.Parent) then
		list = buildLamps()
		lamps = list
	end
	local ls = list :: { Lamp }
	local beams = not Settings.lowGraphics()
	for _, l in ls do
		setLamp(l, 0)
		l.light.Enabled = true
		l.beam.Enabled = beams
	end
	Kit.sfx("snow_cross_horn", "ans_foghorn", Rules.CENTRE + Vector3.new(0, Rules.LAMP_Y, 0), 0.9, 1.35, 900)
	Kit.animate(Rules.SHOW_TIME, function(k: number)
		for _, l in ls do
			setLamp(l, k)
		end
	end, function()
		for _, l in ls do
			l.light.Enabled = false
			l.light.Brightness = 0
			l.beam.Enabled = false
		end
		playing = false
	end)
end

local function samples(): { Rules.Sample }
	local out = {}
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") then
				local hull = Kit.hullOf(m)
				if hull then
					table.insert(out, { id = m, pos = hull.Position })
				end
			end
		end
	end
	return out
end

local function poll()
	local now = workspace:GetServerTimeNow()
	if (Kit.focus() - Rules.CENTRE).Magnitude > POLL_RANGE then
		state = Rules.new()
		return
	end
	local ev = Rules.step(state, samples(), now)
	if ev then
		show()
	end
end

local function active(): boolean
	return RaceAttr.mine("ActiveTrackId") == Rules.TRACK_ID and workspace:GetAttribute("TrackSwitching") ~= true
end

local function stop()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	state = Rules.new()
end

local function refresh()
	stop()
	if not active() then
		return
	end
	acc = 0
	conn = RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < POLL_INTERVAL then
			return
		end
		acc = 0
		local ok, err = pcall(function()
			poll()
		end)
		if not ok then
			warn("[SkyRally][SNOW-CROSSING] " .. tostring(err))
		end
	end)
end

function SnowCrossing.init()
	RaceAttr.changed("ActiveTrackId", refresh)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(refresh)
	workspace:GetAttributeChangedSignal("SnowCrossingTest"):Connect(function()
		if workspace:GetAttribute("SnowCrossingTest") == true then
			workspace:SetAttribute("SnowCrossingTest", nil)
			print("[SkyRally][SNOW-CROSSING] test show")
			show()
		end
	end)
	refresh()
end

return SnowCrossing
