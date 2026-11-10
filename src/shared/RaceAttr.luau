--!strict
-- Race attribute shim (economy v3 phase 2, plan sub-step a; rules in shared/RaceInstanceRules). One call for "this
-- race's RaceMode / RaceGoTime / ..." that works on both paths:
-- - RaceFlowRules.PER_GROUP false (today): workspace attributes, exactly as every reader did before.
-- - PER_GROUP true: the player's RaceInstance root (workspace.RaceInstances.<id>, found by the player's RaceInstanceId
--   attribute) for the shimmed names; workspace for everything else and for a player in no instance (the hub).
-- Phase 2b: the server reads and writes through here() / set() for the instance whose RaceScope it runs in, the client
-- reads its own race through mine() / changed() (RaceUI, FinishShow, Minimap, TrackFlow, Onboarding, the map
-- scanners), and myMapRoot() is the map the local player races on (workspace.Maps.<ActiveTrackId>).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local RaceScope = require(Shared:WaitForChild("RaceScope"))

local RaceAttr = {}

RaceAttr.FOLDER = "RaceInstances" -- workspace child holding one Folder per live instance, named by its id
RaceAttr.PLAYER_ATTRIBUTE = "RaceInstanceId" -- set on a Player while he is seated in an instance

function RaceAttr.rootById(id: number?): Instance?
	if id == nil or id == RaceScope.DEFAULT then
		return nil
	end
	local folder = workspace:FindFirstChild(RaceAttr.FOLDER)
	return if folder then folder:FindFirstChild(tostring(id)) else nil
end

-- The instance root a player is seated in, or nil (hub, between races, single-race path).
function RaceAttr.rootOf(player: Player?): Instance?
	if not player then
		return nil
	end
	local id = player:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE)
	if id == nil then
		return nil
	end
	local folder = workspace:FindFirstChild(RaceAttr.FOLDER)
	return if folder then folder:FindFirstChild(tostring(id)) else nil
end

local function worldGet(name: string): any
	return workspace:GetAttribute(name)
end

-- One getter per instance root, made on its first read and reused (weak keys: a closed instance's root goes with it),
-- so a per-group read (RaceUI and the map scanners read every frame) allocates no closure. The getter holds its root
-- only through a weak-valued box: Luau has no ephemerons, so a value that captured its own key would pin every root.
local rootGetters: { [Instance]: (string) -> any } = setmetatable({}, { __mode = "k" }) :: any

local function rootGetter(root: Instance): (string) -> any
	local g = rootGetters[root]
	if not g then
		local ref: { r: Instance? } = setmetatable({ r = root }, { __mode = "v" }) :: any
		g = function(n: string): any
			local r = ref.r
			return if r then r:GetAttribute(n) else nil
		end
		rootGetters[root] = g
	end
	return g :: (string) -> any
end

local function readFrom(root: Instance?, name: string): any
	return RaceInstanceRules.read(name, RaceFlowRules.PER_GROUP, if root then rootGetter(root) else nil, worldGet)
end

-- QA/spec: how many roots hold a cached getter (weak; collected roots drop out).
function RaceAttr.cachedGetters(): number
	local n = 0
	for _ in rootGetters do
		n += 1
	end
	return n
end

function RaceAttr.get(name: string, player: Player?): any
	if not RaceFlowRules.PER_GROUP then
		return workspace:GetAttribute(name)
	end
	return readFrom(RaceAttr.rootOf(player), name)
end

------------------------------------------------------------------------------------------------------------------
-- Server: the instance of the running RaceScope.

-- The race attribute for the scope this thread runs in (RaceScope.run): the instance root per group, workspace for
-- the hub scope and on the single-race path (workspace:GetAttribute, unchanged).
function RaceAttr.here(name: string): any
	if not RaceFlowRules.PER_GROUP then
		return workspace:GetAttribute(name)
	end
	local id = RaceScope.current()
	if id == RaceScope.DEFAULT then
		return workspace:GetAttribute(name)
	end
	return readFrom(RaceAttr.rootById(id), name)
end

-- Writes a race attribute for the running scope: a shimmed name on the instance root per group, workspace otherwise
-- (workspace:SetAttribute, unchanged, on the single-race path and in the hub scope).
function RaceAttr.set(name: string, value: any)
	if not RaceFlowRules.PER_GROUP then
		workspace:SetAttribute(name, value)
		return
	end
	local id = RaceScope.current()
	if id ~= RaceScope.DEFAULT and RaceInstanceRules.writeTarget(name, true) == "root" then
		local root = RaceAttr.rootById(id)
		if root then
			root:SetAttribute(name, value)
		end
		return
	end
	workspace:SetAttribute(name, value)
end

------------------------------------------------------------------------------------------------------------------
-- Client: the local player's race.

local function localPlayer(): Player?
	local ok, p = pcall(function(): any
		return Players.LocalPlayer
	end)
	return if ok then p else nil
end

-- This client's race attribute (RaceAttr.get for Players.LocalPlayer); workspace:GetAttribute on the single path.
function RaceAttr.mine(name: string): any
	if not RaceFlowRules.PER_GROUP then
		return workspace:GetAttribute(name)
	end
	return readFrom(RaceAttr.rootOf(localPlayer()), name)
end

-- The map root this client races on (workspace.Maps.<ActiveTrackId>), or nil.
function RaceAttr.myMapRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

-- What RaceAttr.changed returns: the RBXScriptConnection surface callers may use, Connected and :Disconnect()
-- (idempotent; after it fn never runs again). It is a connection, not a signal: there is no :Once / :Wait on it (nor
-- on what Signal:Connect returns); a one-shot caller disconnects inside fn, a waiter uses RaceAttr.wait.
export type Conn = { Connected: boolean, Disconnect: (Conn) -> () }

-- Calls fn whenever this client's value of `name` may have changed. Single path: exactly
-- workspace:GetAttributeChangedSignal(name):Connect(fn) (a real RBXScriptConnection). Per group also when the local
-- player enters or leaves an instance and when that instance's root changes it (the root may replicate after the
-- player's attribute); the returned Conn has the same Connected / :Disconnect() contract.
function RaceAttr.changed(name: string, fn: () -> ()): any
	if not RaceFlowRules.PER_GROUP then
		return workspace:GetAttributeChangedSignal(name):Connect(fn)
	end
	local conns: { any } = {}
	local rootConn: any = nil
	local folderConn: any = nil
	local handle: any = { Connected = true }
	local function rewire()
		if not handle.Connected then
			return -- disconnected before a deferred rewire ran (task.spawn, a late ChildAdded)
		end
		if rootConn then
			rootConn:Disconnect()
			rootConn = nil
		end
		if folderConn then
			folderConn:Disconnect()
			folderConn = nil
		end
		local player = localPlayer()
		local root = RaceAttr.rootOf(player)
		if root then
			rootConn = root:GetAttributeChangedSignal(name):Connect(fn)
		elseif player and player:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE) ~= nil then
			-- Seated, root not replicated yet: wait for it under workspace.RaceInstances.
			local folder = workspace:FindFirstChild(RaceAttr.FOLDER) or workspace:WaitForChild(RaceAttr.FOLDER, 10)
			if not handle.Connected or folderConn or rootConn then
				return -- disconnected, or another rewire wired up, while WaitForChild yielded
			end
			if folder then
				folderConn = folder.ChildAdded:Connect(function()
					if RaceAttr.rootOf(localPlayer()) then
						rewire()
						fn()
					end
				end)
			end
		end
	end
	table.insert(conns, workspace:GetAttributeChangedSignal(name):Connect(fn))
	local player = localPlayer()
	if player then
		table.insert(conns, player:GetAttributeChangedSignal(RaceAttr.PLAYER_ATTRIBUTE):Connect(function()
			rewire()
			fn()
		end))
	end
	task.spawn(rewire)
	function handle.Disconnect(self: any)
		if not handle.Connected then
			return
		end
		handle.Connected = false
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		if rootConn then
			rootConn:Disconnect()
			rootConn = nil
		end
		if folderConn then
			folderConn:Disconnect()
			folderConn = nil
		end
	end
	return handle
end

-- Yields until this client's value of `name` may have changed (RaceAttr.changed fired once), then returns the new
-- value. The per-group stand-in for workspace:GetAttributeChangedSignal(name):Wait().
function RaceAttr.wait(name: string): any
	if not RaceFlowRules.PER_GROUP then
		workspace:GetAttributeChangedSignal(name):Wait()
		return workspace:GetAttribute(name)
	end
	local thread = coroutine.running()
	local fired, waiting = false, false
	local conn: any = nil
	conn = RaceAttr.changed(name, function()
		if fired then
			return
		end
		fired = true
		if conn then
			conn:Disconnect()
		end
		if waiting then
			task.spawn(thread)
		end
	end)
	if fired then
		conn:Disconnect()
	else
		waiting = true
		coroutine.yield()
	end
	return RaceAttr.mine(name)
end

return RaceAttr
