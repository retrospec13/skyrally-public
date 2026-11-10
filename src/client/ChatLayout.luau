--!strict
-- Applies shared/ChatLayoutRules: a small, semi-transparent chat window bottom-left (centre-left on touch, above the steer pad)
-- and the Roblox PlayerList hidden while racing. TextChatService is never disabled. The loading screen re-enables ALL CoreGui
-- when it finishes, so nothing is applied before the LoadingDone attribute, and the state is re-asserted on every HudPhase
-- change and a slow heartbeat (cheap, idempotent) so a late CoreGui re-enable cannot leave the PlayerList up during a race.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChatLayoutRules = require(Shared:WaitForChild("ChatLayoutRules"))
local ChatCompatClient = require(script.Parent:WaitForChild("ChatCompatClient"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))

local LocalPlayer = Players.LocalPlayer
local ChatLayout = {}

local started = false
local lastKey = ""
local listShown: boolean? = nil

local function viewport(): (number, number)
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return v.X, v.Y
end

local function isTouch(): boolean
	local mode = LocalPlayer:GetAttribute("InputMode")
	if mode == "Touch" then
		return true
	elseif mode ~= nil then
		return false
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function applyChat(vpX: number, vpY: number, touch: boolean, phase: string): boolean
	local cfg = ChatLayoutRules.compute(vpX, vpY, touch, phase)
	return ChatCompatClient.applyLayout(cfg)
end

local function apply(force: boolean)
	if LocalPlayer:GetAttribute("LoadingDone") ~= true then
		return
	end
	local vpX, vpY = viewport()
	local touch = isTouch()
	local phase = HudPhase.phase()
	local key = string.format("%d|%d|%s|%s", math.floor(vpX), math.floor(vpY), tostring(touch), phase)
	-- Remember the key only once the layout landed, so a not-yet-ready chat (legacy SetCore callbacks) retries next tick.
	if key ~= lastKey and applyChat(vpX, vpY, touch, phase) then
		lastKey = key
	end
	local want = ChatLayoutRules.playerListVisible(vpX, touch, phase)
	-- Re-assert on a cadence (force) in case something re-enabled CoreGui; otherwise only on change.
	if force or listShown ~= want then
		listShown = want
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, want)
		end)
	end
end

function ChatLayout.init()
	if started then
		return
	end
	started = true
	task.spawn(function()
		local elapsed = 0
		while true do
			apply(elapsed >= 2)
			if elapsed >= 2 then
				elapsed = 0
			end
			elapsed += 0.25
			task.wait(0.25)
		end
	end)
end

return ChatLayout
