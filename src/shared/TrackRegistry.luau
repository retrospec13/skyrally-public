--!strict
-- Active-track lookup for server and client (docs/MAP_PLAN_SCHEMA.md section 4).
-- The server registers a def per map; register() mirrors what clients need onto root attributes because clients
-- cannot see _G or server module tables. Until a map is built under Workspace.Maps.<id>, every lookup falls back
-- to the legacy DINO-4 build (builder_dino4.luau), and accessors return nil so callers keep their legacy constants.
local RunService = game:GetService("RunService")
-- Economy v3 phase 2b (docs/design/PER_GROUP_RACES.md): per group the server asks for the active track inside a
-- RaceScope (one instance's track), and a client seated in an instance reads its instance root. Both inert while
-- RaceFlowRules.PER_GROUP is false: the workspace ActiveTrackId, as before.
local RaceFlowRules = require(script.Parent:WaitForChild("RaceFlowRules"))
local RaceScope = require(script.Parent:WaitForChild("RaceScope"))

local TrackRegistry = {}

export type FinishDef = {
	pos: Vector3,
	radius: number,
	station: number,
}

export type TrackDef = {
	id: string,
	root: Instance,
	length: number,
	startCFrames: { CFrame },
	finish: FinishDef,
	laps: number,
	lavaFloorY: number?,
	key: string?,
	zone: string?,
	vehicle: string?,
}

TrackRegistry.LEGACY_ID = "DINO-4"
local LEGACY_MODEL_NAME = "DINO-4_TrackModel"
local MAPS_FOLDER_NAME = "Maps"

-- Server-side only; the client's copy of this module stays empty and reads root attributes instead.
local defs: { [string]: TrackDef } = {}

-- Per group only: the instance's track (server: the running RaceScope; client: the local player's instance root).
local function scopedId(): string?
	if RunService:IsServer() then
		return RaceScope.track()
	end
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	local seat = if player then player:GetAttribute(RaceScope.PLAYER_ATTRIBUTE) else nil
	if seat == nil then
		return nil
	end
	local folder = workspace:FindFirstChild("RaceInstances")
	local root = if folder then folder:FindFirstChild(tostring(seat)) else nil
	local id = if root then root:GetAttribute("ActiveTrackId") else nil
	return if type(id) == "string" and id ~= "" then id else nil
end

function TrackRegistry.getActiveId(): string
	if RaceFlowRules.PER_GROUP then
		local scoped = scopedId()
		if scoped then
			return scoped
		end
	end
	local id = workspace:GetAttribute("ActiveTrackId")
	if type(id) == "string" and id ~= "" then
		return id
	end
	return TrackRegistry.LEGACY_ID
end

-- Returns the root and a short label of where it came from (logged by SelfTest).
local function resolveRoot(): (Instance?, string)
	local id = TrackRegistry.getActiveId()
	local maps = workspace:FindFirstChild(MAPS_FOLDER_NAME)
	local mapRoot = if maps then maps:FindFirstChild(id) else nil
	if mapRoot then
		return mapRoot, "Maps." .. id
	end
	local def = defs[id]
	if def and def.root.Parent then
		return def.root, "registered:" .. def.root:GetFullName()
	end
	-- Legacy fallback ignores the active id: the pre-pipeline build only ever holds DINO-4.
	local model = workspace:FindFirstChild(LEGACY_MODEL_NAME)
	local inner = if model then model:FindFirstChild(TrackRegistry.LEGACY_ID) else nil
	if inner then
		return inner, "legacy:" .. LEGACY_MODEL_NAME .. "/" .. TrackRegistry.LEGACY_ID
	end
	local bare = workspace:FindFirstChild(TrackRegistry.LEGACY_ID)
	if bare then
		return bare, "legacy:" .. TrackRegistry.LEGACY_ID
	end
	return nil, "none"
end

function TrackRegistry.getRoot(): Instance?
	local root = resolveRoot()
	return root
end

function TrackRegistry.describeRoot(): string
	local _, source = resolveRoot()
	return source
end

local function rootChild(name: string): Instance?
	local root = TrackRegistry.getRoot()
	return if root then root:FindFirstChild(name) else nil
end

function TrackRegistry.getWaypointsFolder(): Instance?
	return rootChild("WaypointsData")
end

function TrackRegistry.getCheckpointsFolder(): Instance?
	return rootChild("Checkpoints")
end

function TrackRegistry.getBoostsFolder(): Instance?
	return rootChild("BoostsAndPods")
end

function TrackRegistry.getLandmarks(): Instance?
	return rootChild("Landmarks")
end

function TrackRegistry.getDef(id: string?): TrackDef?
	return defs[id or TrackRegistry.getActiveId()]
end

function TrackRegistry.register(def: TrackDef)
	if not RunService:IsServer() then
		warn("[SkyRally][TrackRegistry] register is server-only; ignored on client for " .. def.id)
		return
	end
	defs[def.id] = def
	if #def.startCFrames == 0 then
		-- startCFrame() then returns nil and FlightServer spawns on the legacy DINO-4 grid, wherever this map is.
		warn("[SkyRally][TrackRegistry] " .. def.id .. " registered with no start grid; spawns use the DINO-4 grid")
	end

	local root = def.root
	root:SetAttribute("TrackId", def.id)
	root:SetAttribute("TrackLength", def.length)
	root:SetAttribute("TrackLaps", def.laps)
	-- Drop slots left by an earlier, longer registration of the same root so clients never read a stale grid.
	local oldCount = root:GetAttribute("StartCFCount")
	if type(oldCount) == "number" then
		for i = #def.startCFrames + 1, oldCount do
			root:SetAttribute("StartCF_" .. tostring(i), nil)
		end
	end
	for i, cf in ipairs(def.startCFrames) do
		root:SetAttribute("StartCF_" .. tostring(i), cf)
	end
	root:SetAttribute("StartCFCount", #def.startCFrames)
	root:SetAttribute("FinishPos", def.finish.pos)
	root:SetAttribute("FinishRadius", def.finish.radius)
	root:SetAttribute("FinishStation", def.finish.station)
	root:SetAttribute("LavaFloorY", def.lavaFloorY)
end

function TrackRegistry.setActive(id: string)
	if not RunService:IsServer() then
		warn("[SkyRally][TrackRegistry] setActive is server-only; ignored on client for " .. id)
		return
	end
	if RaceFlowRules.PER_GROUP and RaceScope.current() ~= RaceScope.DEFAULT then
		-- A group's load: its instance races on this track; the hub's workspace ActiveTrackId stays the hub's.
		RaceScope.setTrack(RaceScope.current(), id)
	else
		workspace:SetAttribute("ActiveTrackId", id)
	end
	local root, source = resolveRoot()
	-- Never stamp another id onto the legacy DINO-4 folder when the requested map is missing.
	if root and (string.sub(source, 1, 7) ~= "legacy:" or id == TrackRegistry.LEGACY_ID) then
		root:SetAttribute("TrackId", id)
	end
end

-- Slots past the registered grid wrap, so a late joiner never lands on legacy DINO-4 coordinates on another map.
function TrackRegistry.startCFrame(slot: number): CFrame?
	local def = defs[TrackRegistry.getActiveId()]
	if def and #def.startCFrames > 0 then
		return def.startCFrames[((slot - 1) % #def.startCFrames) + 1]
	end
	local root = TrackRegistry.getRoot()
	if not root then
		return nil
	end
	local direct = root:GetAttribute("StartCF_" .. tostring(slot))
	if typeof(direct) == "CFrame" then
		return direct
	end
	local count = root:GetAttribute("StartCFCount")
	if type(count) == "number" and count >= 1 then
		local wrapped = root:GetAttribute("StartCF_" .. tostring(((slot - 1) % count) + 1))
		if typeof(wrapped) == "CFrame" then
			return wrapped
		end
	end
	return nil
end

function TrackRegistry.finish(): FinishDef?
	local def = defs[TrackRegistry.getActiveId()]
	if def then
		return def.finish
	end
	local root = TrackRegistry.getRoot()
	if not root then
		return nil
	end
	local pos = root:GetAttribute("FinishPos")
	local radius = root:GetAttribute("FinishRadius")
	if typeof(pos) == "Vector3" and type(radius) == "number" then
		local station = root:GetAttribute("FinishStation")
		return {
			pos = pos,
			radius = radius,
			station = if type(station) == "number" then station else 0,
		}
	end
	return nil
end

local function numberFromDefOrRoot(defValue: number?, attrName: string): number?
	if defValue ~= nil then
		return defValue
	end
	local root = TrackRegistry.getRoot()
	local v = if root then root:GetAttribute(attrName) else nil
	return if type(v) == "number" then v else nil
end

function TrackRegistry.length(): number?
	local def = defs[TrackRegistry.getActiveId()]
	local len = numberFromDefOrRoot(if def then def.length else nil, "TrackLength")
	return if len and len > 0 then len else nil
end

function TrackRegistry.laps(): number?
	local def = defs[TrackRegistry.getActiveId()]
	return numberFromDefOrRoot(if def then def.laps else nil, "TrackLaps")
end

function TrackRegistry.lavaFloorY(): number?
	local def = defs[TrackRegistry.getActiveId()]
	if def then
		return def.lavaFloorY
	end
	return numberFromDefOrRoot(nil, "LavaFloorY")
end

return TrackRegistry
