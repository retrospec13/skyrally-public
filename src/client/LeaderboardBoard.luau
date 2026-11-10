--!strict
-- The viewer's own line on the hub leaderboard (social lane). server/HubBoard draws the sign and the top 10; each row
-- carries a UserId attribute and the sign a Page attribute (the board on show). This module reads them with the player's own
-- numbers (attributes LbBest_<track> / LbStars, set by server/Leaderboards) and writes "YOU  #3  1:02.345" into the sign's
-- OwnLine label on this client only. No remote: everything is replicated state.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LeaderboardRules"))

local LeaderboardBoard = {}

local LocalPlayer = Players.LocalPlayer
local POLL_SECONDS = 0.5
local started = false

local function update(model: Model)
	local line = model:FindFirstChild("OwnLine", true)
	if not (line and line:IsA("TextLabel")) then
		return
	end
	local page = model:GetAttribute("Page")
	if type(page) ~= "string" or page == "" then
		return
	end
	local kind = if page == "stars" then "stars" else "time"
	local rows: { LeaderboardRules.Row } = {}
	for i = 1, LeaderboardRules.ROWS do
		local row = model:FindFirstChild("Row" .. i, true)
		if row then
			local uid = row:GetAttribute("UserId")
			local value = row:GetAttribute("Value")
			if type(uid) == "number" and uid > 0 and type(value) == "number" then
				table.insert(rows, { userId = uid, value = value })
			end
		end
	end
	local mine = LocalPlayer:GetAttribute(LeaderboardRules.ownAttribute(page))
	local text = LeaderboardRules.ownLine(kind, rows, LocalPlayer.UserId, if type(mine) == "number" then mine else nil)
	if line.Text ~= text then
		line.Text = text
	end
end

function LeaderboardBoard.init()
	if started then
		return
	end
	started = true
	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			local model = workspace:FindFirstChild("HubLeaderboard")
			if model and model:IsA("Model") then
				pcall(update, model)
			end
		end
	end)
end

return LeaderboardBoard
