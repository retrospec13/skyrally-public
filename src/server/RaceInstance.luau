--!strict
-- One group's race on a shared server (economy v3 phase 2, Option A; docs/design/PER_GROUP_RACES.md). The lifecycle,
-- seat and bot arithmetic are shared/RaceInstanceRules (Lune spec tools/tests/race_instance_spec.luau); this file only
-- holds the Instances: a Folder per instance under workspace.RaceInstances carrying the shimmed race attributes
-- (RaceMode, RaceGoTime, RaceResetSeq, ...) that today live on workspace, plus each seated player's RaceInstanceId.
--
-- Used only when RaceFlowRules.PER_GROUP is true; nothing on the single-race path creates an instance. Phase 2b:
-- server/RaceGroups opens, joins, steps and closes instances; their bots, items and race state live in each one's
-- shared/RaceScope (see the design doc).
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local RaceInstance = {}
RaceInstance.__index = RaceInstance

export type RaceInstance = typeof(setmetatable(
	{} :: { rules: RaceInstanceRules.RaceInst, root: Folder, players: { [Player]: boolean } },
	RaceInstance
))

-- Live instances by id.
RaceInstance.live = {} :: { [number]: RaceInstance }
local nextId = 0

local function folder(): Folder
	local f = workspace:FindFirstChild(RaceAttr.FOLDER)
	if f and f:IsA("Folder") then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = RaceAttr.FOLDER
	made.Parent = workspace
	return made
end

function RaceInstance.new(key: string, td: any, mode: string, field: number?): RaceInstance
	nextId += 1
	local rules = RaceInstanceRules.new(nextId, key, td.id, td.zone, mode, field or PlaneConfig.AI_FIELD_SIZE)
	local root = Instance.new("Folder")
	root.Name = tostring(nextId)
	root:SetAttribute("State", rules.state)
	root:SetAttribute("Field", rules.field)
	root.Parent = folder()
	local self = setmetatable({ rules = rules, root = root, players = {} }, RaceInstance)
	self:setAttr("RaceMode", mode)
	self:setAttr("ActiveTrackId", td.id)
	self:setAttr("ActiveZone", td.zone)
	self:setAttr("CurrentTrackKey", key)
	RaceInstance.live[nextId] = self
	return self
end

-- Writes a race attribute through the shim: the instance root per group, workspace on the single-race path.
function RaceInstance.setAttr(self: RaceInstance, name: string, value: any)
	self.rules.attrs[name] = value
	if RaceInstanceRules.writeTarget(name, RaceFlowRules.PER_GROUP) == "root" then
		self.root:SetAttribute(name, value)
	else
		workspace:SetAttribute(name, value)
	end
end

function RaceInstance.getAttr(self: RaceInstance, name: string): any
	local root = self.root
	return RaceInstanceRules.read(name, RaceFlowRules.PER_GROUP, function(n: string): any
		return root:GetAttribute(n)
	end, function(n: string): any
		return workspace:GetAttribute(n)
	end)
end

function RaceInstance.transition(self: RaceInstance, to: RaceInstanceRules.State): boolean
	if not RaceInstanceRules.transition(self.rules, to) then
		return false
	end
	self.root:SetAttribute("State", to)
	if to == "grid" then
		self:setAttr("RaceResetSeq", self.rules.seq)
	end
	return true
end

function RaceInstance.join(self: RaceInstance, player: Player): boolean
	if not RaceInstanceRules.join(self.rules, player.UserId) then
		return false
	end
	self.players[player] = true
	player:SetAttribute(RaceAttr.PLAYER_ATTRIBUTE, self.rules.id)
	self.root:SetAttribute("Humans", self.rules.count)
	return true
end

function RaceInstance.leave(self: RaceInstance, player: Player): boolean
	if not RaceInstanceRules.leave(self.rules, player.UserId) then
		return false
	end
	self.players[player] = nil
	if player:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE) == self.rules.id then
		player:SetAttribute(RaceAttr.PLAYER_ATTRIBUTE, nil)
	end
	self.root:SetAttribute("Humans", self.rules.count)
	return true
end

-- Bots this field needs: its own humans, not the server's players.
function RaceInstance.botsNeeded(self: RaceInstance): number
	return RaceInstanceRules.botsNeeded(self.rules.count, self.rules.field, #PlaneConfig.AI_BOTS)
end

function RaceInstance.close(self: RaceInstance)
	for player in self.players do
		self:leave(player)
	end
	RaceInstanceRules.transition(self.rules, "closed")
	RaceInstance.live[self.rules.id] = nil
	self.root:Destroy()
end

function RaceInstance.of(player: Player): RaceInstance?
	local id = player:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE)
	return if type(id) == "number" then RaceInstance.live[id] else nil
end

-- What client/ZoneLighting needs to light a map it cannot read the TrackData of (TrackData lives in ServerStorage):
-- the zone, its XZ box, the lighting profile id and the plan's terrain material and water look as JSON. Written on the
-- map root (workspace.Maps.<id>) after a per-group load.
function RaceInstance.publishZone(mapRoot: Instance, td: any)
	local box = RaceInstanceRules.zoneBox(td)
	if not box then
		return
	end
	mapRoot:SetAttribute("ZoneId", box.zone)
	mapRoot:SetAttribute("ZoneProfile", box.profile)
	mapRoot:SetAttribute("ZoneMin", Vector3.new(box.minX, 0, box.minZ))
	mapRoot:SetAttribute("ZoneMax", Vector3.new(box.maxX, 0, box.maxZ))
	local m = td.materials
	if type(m) == "table" then
		local ok, json = pcall(function(): string
			return HttpService:JSONEncode({
				terrainOverrides = m.terrainOverrides,
				terrainColors = m.terrainColors,
				terrainColor = m.terrainColor,
				waterReflectance = m.waterReflectance,
				waterTransparency = m.waterTransparency,
				waterColor = m.waterColor,
			})
		end)
		mapRoot:SetAttribute("ZoneMaterials", if ok then json else nil)
	end
end

return RaceInstance
