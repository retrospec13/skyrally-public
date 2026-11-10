--!strict
-- Shared Curtain Kart relay (docs/REMARKABLE.md item 28). While workspace.TrackSwitching is on, each client fires its
-- curtain kart at 5 Hz on SkyRallyRemotes.CurtainKartPos (UnreliableRemoteEvent); this module keeps the sane samples
-- (shared/CurtainKartNet.sanitize, one per MIN_GAP per player) and republishes them as the player attributes CKPos,
-- CKState and CKBest, which every client reads to draw everyone's kart with their name on the same curtain track.
-- All three are cleared whenever the curtain opens or closes, so a new curtain never shows last load's karts.
--
-- Cost: a handful of attribute writes per player per second; the handler does no yielding and no allocation beyond
-- the Vector3 it publishes, so the map build the curtain is covering never waits on it. Nothing here is a reward, a
-- race result or a save: the curtain kart is a loading-screen toy, so the relay only guards against garbage.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CurtainKartNet"))

local Relay = {}

local lastAt: { [Player]: number } = {}
local started = false

local function clearPlayer(p: Player)
	p:SetAttribute(Net.ATTR_POS, nil)
	p:SetAttribute(Net.ATTR_STATE, nil)
	p:SetAttribute(Net.ATTR_BEST, nil)
end

function Relay.clearAll()
	for _, p in Players:GetPlayers() do
		clearPlayer(p)
	end
	table.clear(lastAt)
end

-- One client sample; `switching` and `now` are passed in so the Lune spec can drive it. Returns true when published.
function Relay.receive(player: Player, pos: any, state: any, best: any, switching: boolean, now: number): boolean
	if not switching then
		return false
	end
	if not Net.accept(lastAt[player], now) then
		return false
	end
	local v, s, b = Net.sanitize(pos, state, best)
	if not (v and s) then
		return false
	end
	lastAt[player] = now
	player:SetAttribute(Net.ATTR_POS, v)
	player:SetAttribute(Net.ATTR_STATE, s)
	if b ~= nil then
		local prev = player:GetAttribute(Net.ATTR_BEST)
		if type(prev) ~= "number" or b < prev then
			player:SetAttribute(Net.ATTR_BEST, b)
		end
	end
	return true
end

function Relay.forget(player: Player)
	lastAt[player] = nil
end

function Relay.init()
	if started then
		return
	end
	started = true
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local remote = (folder :: Instance):FindFirstChild(Net.REMOTE)
	if not (remote and remote:IsA("UnreliableRemoteEvent")) then
		if remote then
			remote:Destroy()
		end
		local r = Instance.new("UnreliableRemoteEvent")
		r.Name = Net.REMOTE
		r.Parent = folder
		remote = r
	end
	(remote :: UnreliableRemoteEvent).OnServerEvent:Connect(function(player: Player, pos: any, state: any, best: any)
		Relay.receive(player, pos, state, best, workspace:GetAttribute("TrackSwitching") == true, os.clock())
	end)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(Relay.clearAll)
	Players.PlayerRemoving:Connect(Relay.forget)
	Relay.clearAll()
end

return Relay
