--!strict
-- Player-facing names and colours for zones and tracks (original names; the N64 catalogue in CONTENT.md is a design
-- reference, never shipped text). Used by the curtain, the Adventure board and the hub portal labels.
export type Info = { zone: string, zoneName: string, trackName: string, circuit: string?, color: Color3, accent: Color3, vehicle: string }

local TrackInfo = {}

TrackInfo.BY_ID = {
	["HUB-0"] = { zone = "HUB", zoneName = "Central Island", trackName = "Harbour Loop", color = Color3.fromRGB(64, 156, 214), accent = Color3.fromRGB(255, 214, 120), vehicle = "car" },
	["DINO-4"] = { zone = "DINO", zoneName = "Dino Ridge", trackName = "Molten Cavern", circuit = "VOLCANIC CIRCUIT", color = Color3.fromRGB(196, 72, 34), accent = Color3.fromRGB(255, 186, 80), vehicle = "plane" },
	["SNOW-1"] = { zone = "SNOW", zoneName = "Frostpeak", trackName = "Frozen River Peak", color = Color3.fromRGB(86, 150, 222), accent = Color3.fromRGB(226, 246, 255), vehicle = "plane" },
	["ISLAND-2"] = { zone = "ISLAND", zoneName = "Sunreef Isles", trackName = "Galleon Cove", color = Color3.fromRGB(28, 176, 182), accent = Color3.fromRGB(255, 232, 160), vehicle = "car" },
	["FOREST-1"] = { zone = "FOREST", zoneName = "Windmill Vale", trackName = "Windmill Countryside", color = Color3.fromRGB(84, 168, 64), accent = Color3.fromRGB(250, 236, 176), vehicle = "plane" },
	["SPACE-4"] = { zone = "SPACE", zoneName = "Neon Moon", trackName = "Monorail Neon Grid", color = Color3.fromRGB(70, 60, 160), accent = Color3.fromRGB(110, 236, 255), vehicle = "car" },
	["TEST-STRIP"] = { zone = "DINO", zoneName = "Test Strip", trackName = "Test Strip", color = Color3.fromRGB(120, 120, 120), accent = Color3.fromRGB(240, 240, 240), vehicle = "car" },
} :: { [string]: Info }

TrackInfo.ZONE_TO_ID = {
	DINO = "DINO-4",
	SNOW = "SNOW-1",
	ISLAND = "ISLAND-2",
	FOREST = "FOREST-1",
	SPACE = "SPACE-4",
	HUB = "HUB-0",
} :: { [string]: string }

function TrackInfo.get(id: string?): Info?
	return if id then TrackInfo.BY_ID[id] else nil
end

-- Upper-case circuit name for the finish banner (circuit when set, else the track name); nil for an unknown id.
function TrackInfo.circuitName(id: string?): string?
	local info = TrackInfo.get(id)
	if not info then
		return nil
	end
	return string.upper(info.circuit or info.trackName)
end

function TrackInfo.forZone(zone: string?): Info?
	local id = if zone then TrackInfo.ZONE_TO_ID[zone] else nil
	return TrackInfo.get(id)
end

return TrackInfo
