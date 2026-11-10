--!strict
-- Client map visibility (economy v3 phase 2b, docs/design/PER_GROUP_RACES.md). Per group several zone maps live on the
-- server at once (the hub and every group's race map). A phone should render one: this module parents every map root
-- the local player is not in out of Workspace on THIS client only (a client-side Parent swap into a folder outside
-- the world; the server's copy, its physics and every other client are untouched), and puts it back the moment the
-- player's race needs it. Which maps show is shared/RaceInstanceRules.visibleMaps: his instance's map, or the hub
-- while he is in none, and the hub also while his race map is missing or still loading (he is on the plaza until the
-- grid seats him).
--
-- Inert unless RaceFlowRules.PER_GROUP is true (StreamingEnabled stays off; the streaming trial is in the design doc).
-- Checked at 4 Hz and at once when the player's seat or his instance's Loading flag changes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local ZoneVisibility = {}

ZoneVisibility.PERIOD = 0.25
ZoneVisibility.HUB_TRACK = "HUB-0"
ZoneVisibility.HOLDER = "SkyRallyHiddenMaps"

local holder: Folder? = nil
-- Map roots this client has parked, by name (their real parent is workspace.Maps).
local parked: { [string]: Instance } = {}

local function holderFolder(): Folder
	local h = holder
	if h and h.Parent then
		return h
	end
	local f = Instance.new("Folder")
	f.Name = ZoneVisibility.HOLDER
	f.Parent = ReplicatedStorage -- outside Workspace: nothing under it renders or simulates on this client
	holder = f
	return f
end

function ZoneVisibility.step()
	local maps = workspace:FindFirstChild("Maps")
	if not maps then
		return
	end
	-- Forget parked roots the server destroyed meanwhile.
	for name, root in parked do
		if root.Parent == nil then
			parked[name] = nil
		end
	end
	local ids: { string } = {}
	for _, root in maps:GetChildren() do
		table.insert(ids, root.Name)
	end
	for name in parked do
		table.insert(ids, name)
	end
	local player = Players.LocalPlayer
	local seat = RaceAttr.rootOf(player)
	local myTrack = RaceAttr.mine("ActiveTrackId")
	local loading = seat ~= nil and seat:GetAttribute("Loading") == true
	local show = RaceInstanceRules.visibleMaps(
		RaceFlowRules.PER_GROUP,
		if type(myTrack) == "string" then myTrack else nil,
		ZoneVisibility.HUB_TRACK,
		ids,
		loading
	)
	for _, root in maps:GetChildren() do
		if not show[root.Name] then
			parked[root.Name] = root
			root.Parent = holderFolder()
		end
	end
	for name, root in parked do
		if show[name] then
			parked[name] = nil
			root.Parent = maps
		end
	end
end

function ZoneVisibility.init()
	if not RaceFlowRules.PER_GROUP then
		return
	end
	local function safeStep()
		local ok, err = pcall(function()
			ZoneVisibility.step()
		end)
		if not ok then
			warn("[SkyRally][ZONEVIS] " .. tostring(err))
		end
	end
	RaceAttr.changed("Loading", safeStep) -- also fires when the player's seat (RaceInstanceId) changes
	task.spawn(function()
		while true do
			safeStep()
			task.wait(ZoneVisibility.PERIOD)
		end
	end)
end

return ZoneVisibility
