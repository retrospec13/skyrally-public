--!strict
-- Client zone lighting (economy v3 phase 2, plan sub-step c; docs/design/PER_GROUP_RACES.md). Per group, several zone
-- maps are live on one server at once and the server stops writing Lighting, Sky, Atmosphere, MaterialService
-- overrides and water (MapAdapter, RaceInstanceRules.serverWritesLighting). This module applies them on this client
-- for the zone the local player is in: Lighting, its SkyRally_ effects (Atmosphere, post) and Sky through
-- shared/LightingProfiles, then the zone's terrain material overrides, tints and water look.
--
-- Zones come from the live map roots (workspace.Maps.<id>: ZoneId, ZoneProfile, ZoneMin/ZoneMax, ZoneMaterials, set by
-- server/RaceInstance.publishZone). Lookup is shared/RaceInstanceRules.zoneAt on the camera focus (XZ only; outside
-- every box the current zone holds). 2 Hz; writes only when the zone changes.
--
-- Inert unless RaceFlowRules.PER_GROUP is true: on the single-race path the server lights the one map, as before.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))

local ZoneLighting = {}

ZoneLighting.PERIOD = 0.5
ZoneLighting.current = nil :: RaceInstanceRules.Box?

local function toColor3(v: any): Color3?
	if type(v) == "string" then
		local hex = string.match(v, "^#?(%x%x%x%x%x%x)$")
		if hex then
			return Color3.fromRGB(tonumber(string.sub(hex, 1, 2), 16) :: number, tonumber(string.sub(hex, 3, 4), 16) :: number, tonumber(string.sub(hex, 5, 6), 16) :: number)
		end
	elseif type(v) == "table" and #v >= 3 then
		if v[1] > 1 or v[2] > 1 or v[3] > 1 then
			return Color3.fromRGB(v[1], v[2], v[3])
		end
		return Color3.new(v[1], v[2], v[3])
	end
	return nil
end

local function toMaterial(v: any): Enum.Material?
	local ok, m = pcall(function()
		return (Enum.Material :: any)[v]
	end)
	return if ok and typeof(m) == "EnumItem" then m :: any else nil
end

-- The zone boxes of every live map that published one.
local function boxes(): ({ RaceInstanceRules.Box }, { [string]: Instance })
	local list: { RaceInstanceRules.Box } = {}
	local roots: { [string]: Instance } = {}
	local maps = workspace:FindFirstChild("Maps")
	if not maps then
		return list, roots
	end
	for _, root in maps:GetChildren() do
		local zone, profile = root:GetAttribute("ZoneId"), root:GetAttribute("ZoneProfile")
		local lo, hi = root:GetAttribute("ZoneMin"), root:GetAttribute("ZoneMax")
		if type(zone) == "string" and type(profile) == "string" and typeof(lo) == "Vector3" and typeof(hi) == "Vector3" then
			table.insert(list, { zone = zone, profile = profile, minX = lo.X, minZ = lo.Z, maxX = hi.X, maxZ = hi.Z })
			roots[zone] = root
		end
	end
	return list, roots
end

local function applyMaterials(root: Instance)
	local json = root:GetAttribute("ZoneMaterials")
	if type(json) ~= "string" then
		return
	end
	local ok, m = pcall(function(): any
		return HttpService:JSONDecode(json)
	end)
	if not ok or type(m) ~= "table" then
		return
	end
	local terrain = workspace.Terrain
	if type(m.waterReflectance) == "number" then
		terrain.WaterReflectance = m.waterReflectance
	end
	if type(m.waterTransparency) == "number" then
		terrain.WaterTransparency = m.waterTransparency
	end
	local water = toColor3(m.waterColor)
	if water then
		terrain.WaterColor = water
	end
	local MaterialService = game:GetService("MaterialService")
	for base, variant in (if type(m.terrainOverrides) == "table" then m.terrainOverrides else {}) :: { [string]: string } do
		local mat = toMaterial(base)
		if mat then
			pcall(function()
				MaterialService:SetBaseMaterialOverride(mat, variant)
			end)
			local tint = toColor3((type(m.terrainColors) == "table" and m.terrainColors[base]) or m.terrainColor)
			if tint then
				terrain:SetMaterialColor(mat, tint)
			end
		end
	end
end

local function apply(box: RaceInstanceRules.Box, root: Instance?)
	local LightingProfiles = require(Shared:WaitForChild("LightingProfiles")) :: any
	LightingProfiles.apply(box.profile)
	if root then
		applyMaterials(root)
	end
end

function ZoneLighting.step()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local list, roots = boxes()
	local zone = RaceInstanceRules.zoneAt(camera.Focus.Position, list, ZoneLighting.current)
	local cur = ZoneLighting.current
	if zone and (cur == nil or cur.zone ~= zone.zone or cur.profile ~= zone.profile) then
		ZoneLighting.current = zone
		apply(zone, roots[zone.zone])
	end
end

function ZoneLighting.init()
	if not RaceFlowRules.PER_GROUP then
		return
	end
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				ZoneLighting.step()
			end)
			if not ok then
				warn("[SkyRally][ZONELIGHT] " .. tostring(err))
			end
			task.wait(ZoneLighting.PERIOD)
		end
	end)
end

return ZoneLighting
