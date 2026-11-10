--!strict
-- AFK detection, server side (social lane). The rules (45 s idle, rate limits, states) are shared/AfkRules, specced in
-- tools/tests/afk_spec.luau. The client (client/AfkBeat) only reports "my player used an input" on AfkRemote, at most
-- every 5 s; this module keeps its own clock and decides.
--   * Player attribute Afk = true while AFK (nil otherwise) and AfkLong = true after three more idle minutes. Nobody is
--     kicked: Roblox's own idle timeout handles the hub, and a racer who stops is finished as DNF at the DNF deadline.
--   * A small "AFK" tag floats over the vehicle of an AFK player (a BillboardGui parented to the current hull; a respawn or a
--     vehicle swap builds a new hull, and the next tick puts the tag on it).
--   * TrackDirector asks Afk.isAfk to leave AFK players out of FLY AGAIN / HUB votes and the lobby's group rule, and
--     onChange to recount when somebody comes back or drifts off.
-- A map switch (the curtain) holds every idle clock: loading is not idleness. Time before the first heartbeat counts from
-- the join. A forged heartbeat can only make its own sender look active.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AfkRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AfkRules"))

local AfkService = {}

local LOG = "[SkyRally][AFK] "
local TICK = 1 -- seconds between evaluations

local tracker = AfkRules.newTracker()
local started = false
local tags: { [Player]: BillboardGui } = {}

-- Set by the boot script: the player's current vehicle hull (FlightServer.records[player].hull), nil when none.
AfkService.hullOf = nil :: ((Player) -> BasePart?)?
-- Called (pcall'ed) after any AFK state change, with the player and whether he is AFK now.
AfkService.onChange = nil :: ((Player, boolean) -> ())?
-- Injectable clock for the Lune specs.
AfkService.clock = os.clock :: () -> number

function AfkService.isAfk(player: Player): boolean
	return tracker.isAfk(player)
end

function AfkService.state(player: Player): AfkRules.State
	return tracker.state(player)
end

-- Any validated request from the player (a vote, a race pick) is activity too.
function AfkService.touch(player: Player)
	tracker.touch(player, AfkService.clock())
	AfkService.evaluate()
end

local function makeTag(): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "AfkTag"
	gui.Size = UDim2.fromOffset(64, 26)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(62, 40, 24)
	label.BackgroundTransparency = 0.15
	label.Text = AfkRules.TAG_TEXT
	label.TextColor3 = Color3.fromRGB(255, 214, 90)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	return gui
end

-- Keeps the tag on exactly the AFK players, adorned to whatever hull they have now.
local function syncTags()
	for player, tag in tags do
		if not player.Parent or not tracker.isAfk(player) then
			tag:Destroy()
			tags[player] = nil
		end
	end
	local hullOf = AfkService.hullOf
	for _, player in Players:GetPlayers() do
		if tracker.isAfk(player) then
			local hull = if hullOf then hullOf(player) else nil
			local tag: BillboardGui? = tags[player]
			if hull and hull.Parent then
				-- The tag lives on the hull itself, so a respawn or a vehicle swap (a new hull) replaces it.
				if tag and tag.Parent ~= hull then
					tag:Destroy()
					tag = nil
					tags[player] = nil
				end
				if not tag then
					local fresh = makeTag()
					fresh.Adornee = hull
					fresh.Parent = hull
					tags[player] = fresh
				end
			elseif tag then
				tag:Destroy()
				tags[player] = nil
			end
		end
	end
end

-- One evaluation: applies state changes to the attributes and tells TrackDirector. Cheap; safe to call often.
function AfkService.evaluate()
	local now = AfkService.clock()
	if workspace:GetAttribute("TrackSwitching") == true then
		tracker.hold(now)
	end
	for _, change in tracker.update(now) do
		local player = change.key :: Player
		local afk = change.to ~= "active"
		player:SetAttribute("Afk", if afk then true else nil)
		player:SetAttribute("AfkLong", if change.to == "long" then true else nil)
		if change.from == "active" or change.to == "active" then
			print(string.format("%suser=%d player=%s %s (idle %.0f s)", LOG, player.UserId, player.Name, if afk then "AFK" else "back", tracker.idle(player, now)))
			local cb = AfkService.onChange
			if cb then
				local okCb, errCb = pcall(function(): any
					cb(player, afk)
					return nil
				end)
				if not okCb then
					warn(LOG .. "onChange failed: " .. tostring(errCb))
				end
			end
		end
	end
	syncTags()
end

function AfkService.track(player: Player)
	tracker.join(player, AfkService.clock())
end

function AfkService.untrack(player: Player)
	tracker.leave(player)
	local tag = tags[player]
	if tag then
		tag:Destroy()
		tags[player] = nil
	end
end

-- A heartbeat from a client. Returns whether it was accepted (the rate limit is the only refusal).
function AfkService.onBeat(player: Player): boolean
	local ok = tracker.beat(player, AfkService.clock())
	if ok and tracker.isAfk(player) then
		AfkService.evaluate()
	end
	return ok
end

function AfkService.init()
	if started then
		return
	end
	started = true
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		remotes = f
	end
	local r = (remotes :: Instance):FindFirstChild("AfkRemote") :: RemoteEvent?
	if not r then
		local nr = Instance.new("RemoteEvent")
		nr.Name = "AfkRemote"
		nr.Parent = remotes
		r = nr
	end
	(r :: RemoteEvent).OnServerEvent:Connect(function(player: Player)
		AfkService.onBeat(player)
	end)
	for _, p in Players:GetPlayers() do
		AfkService.track(p)
	end
	Players.PlayerAdded:Connect(AfkService.track)
	Players.PlayerRemoving:Connect(function(p: Player)
		AfkService.untrack(p)
	end)
	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(function(): any
				AfkService.evaluate()
				return nil
			end)
			if not ok then
				warn(LOG .. "evaluate failed: " .. tostring(err))
			end
		end
	end)
end

return AfkService
