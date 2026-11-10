--!strict
-- Opponent pose stream, server side (Shared.RacerStreamRules has the why, the wire format and the client half).
-- AIRacers, BattleCore and BossRace call RacerViewRules.publish(source, clock, collect) after each Heartbeat that ran
-- whole fixed steps; this module is that hook's sink. Every RacerStreamRules.SEND_STEPS steps per mover (60 Hz) it
-- sends the mover's parts' CFrames, stamped with the mover's exact sim time, to every client on the
-- SkyRallyRemotes.RacerStream UnreliableRemoteEvent (a lost packet is just a gap the client's curve spans). Nothing
-- here moves a part: the hulls stay where the movers put them and replicate as before, so hits, items, pods and every
-- server check are unchanged. Parts are named on the wire by a StreamId attribute set here on first send.
-- Cost: per send one table walk and one buffer per 36 parts; 7 race bots are 164 bytes, about 9 KB/s per client.
-- Remote players (2026-10-20 remote-smooth, Shared.PlayerStreamRules): each client fires its own vehicle's pose on the
-- same remote (32 bytes, up to 60 Hz, stamped with that client's sim time). The server gates it (size, source, rate,
-- within PLAUSIBLE studs of the server's copy of the hull, no server hold: anchored or ownership taken; stamp
-- newer and within a band of the server clock) and relays it, id set to the hull's
-- StreamId, to every other player of the same race instance within RELAY_RANGE. Visual only: nothing on the server
-- reads the pose; hits, items, standings, validation and respawn keep the replicated physics hull. 8 players at 60 Hz:
-- 1.9 KB/s up per client, 13.4 KB/s down per client, 108 KB/s out of the server (payload).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RacerViewRules = require(Shared:WaitForChild("RacerViewRules"))
local S = require(Shared:WaitForChild("RacerStreamRules"))
local P = require(Shared:WaitForChild("PlayerStreamRules"))

local RacerStream = {}

local remote: UnreliableRemoteEvent? = nil
local nextId = 0
local ids: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local holders: { [number]: BasePart? } = setmetatable({}, { __mode = "v" }) :: any -- id -> the part that holds it

-- A part's StreamId. After the u16 counter wraps (a long-lived server: every boss hazard takes a fresh id) an id still
-- held by a part in the world is skipped, so two live parts never share one client track.
local function idOf(part: BasePart): number
	local id = ids[part]
	if id then
		return id
	end
	for _ = 1, 65535 do
		nextId = (nextId % 65535) + 1
		local holder: BasePart? = holders[nextId]
		if not holder or holder.Parent == nil then
			if holder then
				ids[holder] = nil -- a part that comes back later takes a fresh id
			end
			break
		end
	end
	ids[part] = nextId
	holders[nextId] = part
	part:SetAttribute("StreamId", nextId)
	return nextId
end

function RacerStream.send(source: number, clock: RacerViewRules.ServerClock, parts: { BasePart })
	local r = remote
	if not r or #parts == 0 or #Players:GetPlayers() == 0 then
		return
	end
	if not S.shouldSend(clock :: any) then
		return
	end
	local stamp = S.stamp(clock :: any, os.clock())
	local i = 1
	while i <= #parts do
		local batchIds: { number } = {}
		local batchCfs: { CFrame } = {}
		for j = i, math.min(i + S.MAX_ENTRIES - 1, #parts) do
			local p = parts[j]
			table.insert(batchIds, idOf(p))
			table.insert(batchCfs, p.CFrame)
		end
		r:FireAllClients(S.encode(source, stamp, batchIds, batchCfs))
		i += S.MAX_ENTRIES
	end
end

-- Remote players' relay ------------------------------------------------------------------------------------------------
-- hull nil: a spectator (gets his instance's players). owned: the hull is network-owned by its player (a car hold takes
-- the ownership without anchoring, CarServer escalate: poses are refused for it like an anchored hold).
type Seat = { hull: BasePart?, pos: Vector3?, group: any, owned: boolean }
local gates: { [Player]: P.Gate } = setmetatable({}, { __mode = "k" }) :: any
local roster: { [Player]: Seat } = {}
local rosterAt = -math.huge

-- The player's own vehicle (workspace.Planes.<PlaneName>, owned by him), as the clients find it.
local function hullOf(player: Player): BasePart?
	local planes = workspace:FindFirstChild("Planes")
	local name = player:GetAttribute("PlaneName")
	local m = if planes and type(name) == "string" then planes:FindFirstChild(name) else nil
	if m and m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId then
		local hull = m.PrimaryPart
		return if hull and hull.Parent then hull else nil
	end
	return nil
end

-- Who is where (server copies), refreshed every ROSTER_INTERVAL: the per-packet work is a table read.
local function refreshRoster(now: number)
	if now - rosterAt < P.ROSTER_INTERVAL then
		return
	end
	rosterAt = now
	table.clear(roster)
	for _, p in Players:GetPlayers() do
		local hull = hullOf(p)
		local owned = false
		if hull and not hull.Anchored then
			local ok, owner = pcall(function()
				return (hull :: BasePart):GetNetworkOwner()
			end)
			owned = ok and owner == p
		end
		roster[p] = { hull = hull, pos = if hull then hull.Position else nil, group = p:GetAttribute("RaceInstanceId"), owned = owned }
	end
end

local function onPlayerPose(player: Player, b: any)
	local r = remote
	if not r then
		return
	end
	local now = os.clock()
	refreshRoster(now)
	local g = gates[player]
	if not g then
		local fresh = P.newGate()
		gates[player] = fresh
		g = fresh
	end
	local seat = roster[player]
	local hull = if seat then seat.hull else nil
	if hull and not hull.Parent then
		hull = nil
	end
	-- the live hull position, not the roster's (up to 0.1 s old: 26 studs at full boost)
	local stamp = P.admit(g :: P.Gate, b, now, if hull then hull.Position else nil, hull ~= nil and (hull.Anchored or not (seat :: Seat).owned))
	if stamp == nil or not seat or not hull then
		return
	end
	local out = P.relayBuffer(b :: buffer, idOf(hull))
	local from = hull.Position
	for other, o in roster do
		if other ~= player and other.Parent then
			if P.relayable(from, seat.group, o.pos, o.group) then
				r:FireClient(other, out)
				P.serverStats.relayed += 1
			else
				P.serverStats.culled += 1
			end
		end
	end
end

function RacerStream.init()
	if remote then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local existing = (folder :: Instance):FindFirstChild(S.REMOTE)
	if existing and not existing:IsA("UnreliableRemoteEvent") then
		existing:Destroy()
		existing = nil
	end
	if not existing then
		local u = Instance.new("UnreliableRemoteEvent")
		u.Name = S.REMOTE
		u.Parent = folder
		existing = u
	end
	local r = existing :: UnreliableRemoteEvent
	remote = r
	-- Client -> server: each player's own vehicle pose (remote-smooth), gated and relayed above; anything else a client
	-- fires is dropped by the gate.
	r.OnServerEvent:Connect(onPlayerPose)
	Players.PlayerRemoving:Connect(function(p: Player)
		gates[p] = nil
		roster[p] = nil
	end)
	RacerViewRules.streamSink = RacerStream.send
end

return RacerStream
