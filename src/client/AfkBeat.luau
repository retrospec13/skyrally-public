--!strict
-- Input heartbeat for the AFK check (social lane). Tells the server, at most every AfkRules.BEAT_SECONDS, that this player
-- used an input; the server (server/AfkService) keeps its own clock and decides who is AFK (45 s without a heartbeat). The
-- client never says "I am AFK" and nothing here changes how the game plays.
-- What counts as input: a key, mouse button, wheel, touch or gamepad button press; a touch drag; a gamepad stick or trigger
-- pushed off centre; and a key held down right now (a racer holding the throttle presses nothing new for a whole lap). Mouse
-- movement alone does not count. workspace.AutoPilot (QA) counts as input, so a QA run never looks AFK.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AfkRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AfkRules"))

local AfkBeat = {}

local POLL_SECONDS = 1
local STICK_DEADZONE = 0.3

local remote: RemoteEvent? = nil
local sawInput = false
local lastSent = -math.huge
local started = false

local function isInputType(t: Enum.UserInputType): boolean
	return t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseButton2
		or t == Enum.UserInputType.MouseButton3
		or t == Enum.UserInputType.MouseWheel
		or t == Enum.UserInputType.Touch
		or string.sub(t.Name, 1, 7) == "Gamepad"
end

local function onInput(input: InputObject, _processed: boolean)
	if isInputType(input.UserInputType) then
		sawInput = true
	end
end

local function onChanged(input: InputObject, _processed: boolean)
	local t = input.UserInputType
	if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseWheel then
		sawInput = true
	elseif string.sub(t.Name, 1, 7) == "Gamepad" then
		local k = input.KeyCode
		if k == Enum.KeyCode.Thumbstick1 or k == Enum.KeyCode.Thumbstick2 then
			if input.Position.Magnitude > STICK_DEADZONE then
				sawInput = true
			end
		elseif k == Enum.KeyCode.ButtonL2 or k == Enum.KeyCode.ButtonR2 then
			if input.Position.Z > 0.1 then
				sawInput = true
			end
		end
	end
end

-- Held right now: a key (the throttle), a stick or trigger off centre on the first gamepad.
local function heldNow(): boolean
	local ok, keys = pcall(function()
		return UserInputService:GetKeysPressed()
	end)
	if ok and #keys > 0 then
		return true
	end
	local okPad, state = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if okPad then
		for _, obj in state do
			local k = obj.KeyCode
			if k == Enum.KeyCode.Thumbstick1 or k == Enum.KeyCode.Thumbstick2 then
				if obj.Position.Magnitude > STICK_DEADZONE then
					return true
				end
			elseif k == Enum.KeyCode.ButtonL2 or k == Enum.KeyCode.ButtonR2 then
				if obj.Position.Z > 0.1 then
					return true
				end
			end
		end
	end
	return false
end

function AfkBeat.init()
	if started then
		return
	end
	started = true
	UserInputService.InputBegan:Connect(onInput)
	UserInputService.InputChanged:Connect(onChanged)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		remote = if remotes then remotes:WaitForChild("AfkRemote", 30) :: RemoteEvent? else nil
	end)
	-- The server floats an "AFK" tag over an idle player's vehicle (server/AfkService). Other players see it; its owner has
	-- no use for it and it sits in the middle of his own chase-camera view (a big pill over the route), so his own copy is
	-- switched off. His vehicle is the model named by his PlaneName attribute.
	local Players = game:GetService("Players")
	local me = Players.LocalPlayer
	local function ownTag(tag: Instance)
		if tag:IsA("BillboardGui") and tag.Name == "AfkTag" then
			local model = tag:FindFirstAncestorOfClass("Model")
			tag.Enabled = not (model ~= nil and model.Name == me:GetAttribute("PlaneName"))
		end
	end
	local function sweep()
		for _, d in workspace:GetDescendants() do
			if d.Name == "AfkTag" then
				ownTag(d)
			end
		end
	end
	workspace.DescendantAdded:Connect(ownTag)
	me:GetAttributeChangedSignal("PlaneName"):Connect(sweep)
	sweep()
	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			local active = sawInput or workspace:GetAttribute("AutoPilot") == true or heldNow()
			local now = os.clock()
			local r = remote
			if active and r and now - lastSent >= AfkRules.BEAT_SECONDS then
				sawInput = false
				lastSent = now
				r:FireServer()
			elseif not active then
				sawInput = false
			end
		end
	end)
end

return AfkBeat
