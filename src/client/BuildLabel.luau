--!strict
-- Small always-on build label (D19 joined-client verification): bottom-left, readable at 740x360,
-- out of the way of the D-pad and HUD plaques. Also exposed as a player attribute and a log line.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildInfo = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BuildInfo"))

local BuildLabel = {}

function BuildLabel.text(): string
	local c = tostring(BuildInfo.Commit)
	return string.format("SkyRally %s %s", BuildInfo.Channel, string.sub(c, 1, 7))
end

function BuildLabel.init()
	local lp = Players.LocalPlayer
	lp:SetAttribute("BuildCommit", BuildInfo.Commit)
	print(string.format("[SkyRally][BUILD] commit=%s tree=%s built=%s channel=%s place=%d version=%d",
		tostring(BuildInfo.Commit), tostring(BuildInfo.Tree), tostring(BuildInfo.BuiltUtc), tostring(BuildInfo.Channel),
		game.PlaceId, game.PlaceVersion))
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyBuild"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	sg.IgnoreGuiInset = false
	local t = Instance.new("TextLabel")
	t.Name = "BuildLabel"
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0, 1)
	t.Position = UDim2.new(0, 6, 1, -2)
	t.Size = UDim2.new(0, 220, 0, 14)
	t.Font = Enum.Font.Code
	t.TextSize = 11
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextColor3 = Color3.fromRGB(255, 244, 220)
	t.TextStrokeTransparency = 0.4
	t.TextTransparency = 0.25
	t.Text = BuildLabel.text() .. string.format(" v%d", game.PlaceVersion)
	t.Parent = sg
	sg.Parent = lp:WaitForChild("PlayerGui")
end

return BuildLabel
