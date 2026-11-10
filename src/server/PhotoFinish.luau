--!strict
-- Photo finish, server half (REMARKABLE Batch 2 item 23). The polaroid on the results card shows a gap the SERVER
-- measured: this module watches RaceManager.finishOrder (read only) and, whenever a racer lands within
-- FinaleRules.PHOTO_GAP of the one before, tells each player of that pair ("PhotoFinish" on RaceEventRemote) who the
-- rival was, the gap and who got there first. The racer behind may finish after the local results card is up, so the
-- notice can arrive late; client/Polaroid pins it onto the card whenever it comes. Nothing here awards, ranks or times
-- anything: RaceManager owns the order and the times, this only reads them at 20 Hz.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FinaleRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FinaleRules"))
local RaceScope = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceScope"))
local RaceAttr = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceAttr"))

local PhotoFinish = {}

local started = false

local function displayOf(name: string, isPlayer: boolean): string
	if isPlayer then
		local p = Players:FindFirstChild(name)
		if p and p:IsA("Player") then
			return p.DisplayName
		end
	end
	return name
end

-- Per group (systems audit v32 T0-2): every race's finish order is its RaceScope's (RaceManager.finishOrder reads the
-- running scope's copy), so the scan runs once per scope (the hub scope, then every live instance in its own), with
-- its own "seen" mark and that race's mode. The single path: one scope, the same steps as before.
local function scan(st: { seen: number }, RaceManager: any, getRemote: () -> RemoteEvent?)
	local order = RaceManager.finishOrder
	if type(order) ~= "table" then
		return
	end
	local n = #order
	if n < st.seen then
		st.seen = 0 -- a reset cleared the order (table.clear)
	end
	if n == st.seen then
		return
	end
	local mode = tostring(RaceAttr.here("RaceMode"))
	if not FinaleRules.PHOTO_MODES[mode] then
		st.seen = n
		return
	end
	local remote = getRemote()
	for i = st.seen + 1, n do
		for _, note in FinaleRules.photoNotices(order, i, FinaleRules.PHOTO_GAP) do
			local p = Players:FindFirstChild(note.name)
			if p and p:IsA("Player") and remote then
				remote:FireClient(p, "PhotoFinish", {
					gap = note.gap,
					won = note.won,
					rank = note.rank,
					rival = displayOf(note.rival, note.rivalIsPlayer),
					rivalName = note.rival, -- the standings name (finds the rival's car for the photo)
					rivalIsPlayer = note.rivalIsPlayer,
					rivalRank = note.rivalRank,
				})
				print(string.format("[SkyRally][PHOTO] %s vs %s gap=%.3f won=%s", note.name, note.rival, note.gap, tostring(note.won)))
			end
		end
	end
	st.seen = n
end

local function seenState(): { seen: number }
	return RaceScope.state("PhotoFinish", function(): { seen: number }
		return { seen = 0 }
	end)
end

function PhotoFinish.init()
	if started then
		return
	end
	started = true
	local RaceManager = require(script.Parent.RaceManager) :: any
	local remote: RemoteEvent? = nil
	local function getRemote(): RemoteEvent?
		if not remote then
			local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
			local r = remotes and remotes:FindFirstChild("RaceEventRemote")
			remote = if r and r:IsA("RemoteEvent") then r else nil
		end
		return remote
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.05 then
			return
		end
		acc = 0
		scan(seenState(), RaceManager, getRemote)
		if RaceScope.enabled() then
			for _, id in RaceScope.liveIds() do
				local ok, err = pcall(RaceScope.run, id, function()
					scan(seenState(), RaceManager, getRemote)
				end)
				if not ok then
					warn(string.format("[SkyRally][PHOTO] instance %d scan error %s", id, tostring(err)))
				end
			end
		end
	end)
end

return PhotoFinish
