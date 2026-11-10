--!strict
-- Garage cosmetics that play on the client (MONETIZATION_PROPOSAL 2a). Liveries are painted by the server
-- (server/kit/LiveryPaint) and trails live in Vfx's per-plane rig; this module owns the two moments:
-- * HORN: H on the keyboard, R3 (right stick click) on a gamepad, free in both FlightController and CarController.
--   The client asks the server (SkyRallyRemotes.CosmeticEvent "Horn"); the server checks the equipped horn and the
--   cooldown and tells every client, which plays the beeps as a 3D sound at that racer's vehicle. GarageModel.HORN_COOLDOWN
--   applies on both sides; the beeps are SoundJuice's loaded samples (SoundService.SkyRallySounds), re-pitched
--   (GarageModel.hornBeeps).
-- * FINISH EMOTE: when any racer's RaceFinished flips true in a race mode and they have an emote equipped, every
--   client plays the flourish on that racer's vehicle: a stand-in of the hero mesh rolls / loops / spins over the real
--   hull (which keeps its line, so physics and ownership never change) with Vfx bursts (GarageModel.emotePose).
-- Garage previews call previewHorn / previewEmote (local only).
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local Prof = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local GarageModel = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GarageModel"))
local Vfx = require(script.Parent:WaitForChild("Vfx"))

local LocalPlayer = Players.LocalPlayer

local Cosmetics = {}

local event: RemoteEvent? = nil
local lastHornAt = -math.huge
local playing: { [Model]: boolean } = {}

local function vehicleOf(userId: number): Model?
	local folder = workspace:FindFirstChild("Planes")
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == userId then
			return m
		end
	end
	return nil
end

local function hullOf(model: Model): BasePart?
	local h = model.PrimaryPart or model:FindFirstChild("Hull")
	return if h and h:IsA("BasePart") then h else nil
end

---------------------------------------------------------------------------------------------------- horn

-- One beep: a clone of SoundJuice's loaded sample as a 3D Sound on the hull (others hear it from where the racer is),
-- cut after `length` when set.
local function beep(parent: Instance, cue: { sound: string, speed: number }, b: GarageModel.Beep)
	local folder = SoundService:FindFirstChild("SkyRallySounds")
	local src = folder and folder:FindFirstChild(cue.sound)
	if not src or not src:IsA("Sound") then
		return
	end
	local s = src:Clone()
	s.Name = "GarageHorn"
	s.Looped = false
	s.Volume = 0.7
	s.PlaybackSpeed = cue.speed * b.speed
	s.RollOffMaxDistance = 320
	s.RollOffMinDistance = 12
	s.Parent = parent
	s:Play()
	local life = b.length or 3
	task.delay(life, function()
		if s.Parent then
			s:Stop()
			s:Destroy()
		end
	end)
end

local function playHorn(key: string, at: Instance?)
	local item = GarageModel.cosmetic(key)
	local style = item and item.horn
	if not style then
		return
	end
	local cue = GarageModel.HORN_CUES[style.cue]
	if not cue then
		return
	end
	local parent: Instance = at or (workspace.CurrentCamera :: Instance)
	for _, b in GarageModel.hornBeeps(style) do
		task.delay(b.at, beep, parent, cue, b)
	end
end

function Cosmetics.previewHorn(key: string)
	playHorn(key, workspace.CurrentCamera)
end

local function hornAction(_name: string, state: Enum.UserInputState, _obj: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if UserInputService:GetFocusedTextBox() ~= nil or workspace:GetAttribute("GarageEnabled") ~= true then
		return Enum.ContextActionResult.Pass
	end
	local item = GarageModel.equipped(GarageModel.decodeLoadout(LocalPlayer:GetAttribute("Equipped")), "horn")
	local t = os.clock()
	if not item or t - lastHornAt < GarageModel.HORN_COOLDOWN or not event then
		return Enum.ContextActionResult.Pass
	end
	lastHornAt = t
	-- The server answers every client ("Horn", userId, key), this one included, so the owner hears what others hear.
	local remote = event :: RemoteEvent
	remote:FireServer("Horn")
	return Enum.ContextActionResult.Sink
end

---------------------------------------------------------------------------------------------------- finish emote

local function stripJoints(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") or d:IsA("Attachment") then
			d:Destroy()
		end
	end
end

-- Plays an emote on a vehicle model. The mesh stand-in is local to this client; the real mesh is hidden for the
-- flourish with LocalTransparencyModifier and comes back at the end (or if the vehicle goes away).
local function playEmote(model: Model, key: string)
	local item = GarageModel.cosmetic(key)
	local style = item and item.emote
	local hull = hullOf(model)
	if not style or not hull or playing[model] then
		return
	end
	playing[model] = true
	local isCar = model:GetAttribute("IsCar") == true
	local seconds = math.max(0.5, style.seconds)
	for _, b in GarageModel.emoteBursts(style.flourish) do
		task.delay(b.at * seconds, function()
			if hull.Parent then
				local pos = hull.Position + Vector3.new(0, 3, 0)
				Vfx.burst(b.preset, CFrame.lookAt(pos, pos + Vector3.yAxis), 0.7)
			end
		end)
	end
	local mesh = model:FindFirstChild("TripoHeroPlaneMesh") or model:FindFirstChild("TripoHeroCarMesh")
	if not mesh or not mesh:IsA("BasePart") then
		task.delay(seconds, function()
			playing[model] = nil
		end)
		return
	end
	local real = mesh :: BasePart
	local offset = hull.CFrame:ToObjectSpace(real.CFrame)
	local proxy = real:Clone()
	stripJoints(proxy)
	proxy.Name = "EmoteStandIn"
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanQuery = false
	proxy.CanTouch = false
	proxy.CFrame = real.CFrame
	proxy.Parent = workspace.CurrentCamera
	real.LocalTransparencyModifier = 1
	local start = os.clock()
	local conn: RBXScriptConnection? = nil
	local function finish()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		proxy:Destroy()
		real.LocalTransparencyModifier = 0
		playing[model] = nil
	end
	conn = RunService.RenderStepped:Connect(Prof.wrap("SR_Cosmetics", function()
		local t = (os.clock() - start) / seconds
		if t >= 1 or not hull.Parent or not real.Parent then
			finish()
			return
		end
		local p = GarageModel.emotePose(style.flourish, isCar, t)
		proxy.CFrame = hull.CFrame * CFrame.new(0, p.lift, 0) * CFrame.Angles(p.pitch, p.yaw, p.roll) * offset
	end))
end

function Cosmetics.previewEmote(key: string)
	local model = vehicleOf(LocalPlayer.UserId)
	if model then
		playEmote(model, key)
	end
end

local function onFinished(player: Player)
	if player:GetAttribute("RaceFinished") ~= true then
		return
	end
	local mode = RaceAttr.mine("RaceMode")
	if mode == nil or mode == "hub" or mode == "battle" then
		return
	end
	local item = GarageModel.equipped(GarageModel.decodeLoadout(player:GetAttribute("Equipped")), "emote")
	if not item then
		return
	end
	-- After the finish burst (Vfx.onFinish) has popped.
	task.delay(0.6, function()
		local model = vehicleOf(player.UserId)
		if model then
			playEmote(model, item.key)
		end
	end)
end

local function watch(player: Player)
	player:GetAttributeChangedSignal("RaceFinished"):Connect(function()
		onFinished(player)
	end)
end

function Cosmetics.init()
	local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
	local ev = remotes and remotes:WaitForChild("CosmeticEvent", 15)
	if ev and ev:IsA("RemoteEvent") then
		event = ev
		ev.OnClientEvent:Connect(function(kind: any, userId: any, key: any)
			if kind == "Horn" and type(userId) == "number" and type(key) == "string" then
				local model = vehicleOf(userId)
				local hull = model and hullOf(model)
				if hull then
					playHorn(key, hull)
				end
			end
		end)
	end
	ContextActionService:BindAction("SkyRallyHorn", hornAction, false, Enum.KeyCode.H, Enum.KeyCode.ButtonR3)
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return Cosmetics
