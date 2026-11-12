--!strict
-- Studio-only QA helpers, pure rules (no Roblox globals; tools/tests/qa_tools_spec.luau runs it under Lune). QA V5A could
-- not test missiles, traps or shields because nothing could hand the local player an item, and could not put a bot in
-- front of a plane on demand. server/QATools wires these to a RemoteFunction and workspace attributes that exist ONLY when
-- RunService:IsStudio(); this file says what the commands mean and refuses everything else. Nothing here touches the
-- race, adhesion, walls, barriers, kill volumes or rescue.
--   give    "<color>[:<level>]"  e.g. "red:3", "green", "blue:2"  -> the item the local player holds (level 1..MAX, default 1)
--           items v4: any special id too, e.g. "storm_bolt:3", "orbit_missiles:2" (QAToolRules.SPECIALS)
--   ahead   "<studs>[:<lateral>]" e.g. "60", "120:-8"             -> a bot placed that far ahead of the local player on the line
local QAToolRules = {}

QAToolRules.REMOTE_NAME = "QAToolsRemote" -- RemoteFunction in SkyRallyRemotes (Studio only)
QAToolRules.GIVE_ATTR = "QAGiveItem" -- workspace attribute: set from a Server-context command, applies to the first player
QAToolRules.AHEAD_ATTR = "QABotAhead" -- same, for the bot placement
QAToolRules.COLORS = table.freeze({ "red", "blue", "yellow", "green", "rainbow" })
-- Items v4 ids (the same list as ItemRules.SPECIALS; kept here so this file stays free of requires).
QAToolRules.SPECIALS = table.freeze({
	"rocket_rush",
	"golden_wings",
	"orbit_missiles",
	"storm_bolt",
	"boom_bomb",
	"gift_box",
	"frost_shot",
	"coin_burst",
	"bubble_guard",
	"ink_splat",
	"item_steal",
	"coin_pouch",
})
QAToolRules.MAX_LEVEL = 3
QAToolRules.AHEAD_MIN = 15 -- studs: closer than this overlaps the plane
QAToolRules.AHEAD_MAX = 2000
QAToolRules.LATERAL_MAX = 60

-- Only a Studio session may use any of it.
function QAToolRules.allowed(isStudio: boolean): boolean
	return isStudio == true
end

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- "red:3" -> ("red", 3); "green" -> ("green", 1); junk -> nil, reason. The level is clamped into 1..MAX_LEVEL.
function QAToolRules.parseGive(text: any): (string?, number, string)
	if type(text) ~= "string" then
		return nil, 0, "not_text"
	end
	local color, lv = string.match(string.lower(trim(text)), "^([%a_]+):?(%d*)$")
	if not color or not (table.find(QAToolRules.COLORS, color) or table.find(QAToolRules.SPECIALS, color)) then
		return nil, 0, "unknown_color"
	end
	local level = tonumber(lv) or 1
	return color, math.clamp(math.floor(level), 1, QAToolRules.MAX_LEVEL), "ok"
end

-- "60" -> (60, 0); "120:-8" -> (120, -8); a bare number works too. Clamped into the allowed range.
function QAToolRules.parseAhead(text: any): (number?, number, string)
	local s: string
	if type(text) == "number" then
		s = tostring(text)
	elseif type(text) == "string" then
		s = trim(text)
	else
		return nil, 0, "not_text"
	end
	local a, b = string.match(s, "^(%-?[%d%.]+):?(%-?[%d%.]*)$")
	local studs = tonumber(a)
	if not studs or studs ~= studs then
		return nil, 0, "bad_number"
	end
	local lateral = tonumber(b) or 0
	return math.clamp(studs, QAToolRules.AHEAD_MIN, QAToolRules.AHEAD_MAX),
		math.clamp(lateral, -QAToolRules.LATERAL_MAX, QAToolRules.LATERAL_MAX),
		"ok"
end

-- The course station `studs` ahead of `station`, wrapped into [0, totalLen); lapsAhead = how many start lines it crosses.
function QAToolRules.stationAhead(station: number, studs: number, totalLen: number): (number, number)
	if totalLen <= 0 then
		return station, 0
	end
	local raw = station + studs
	return raw % totalLen, math.floor(raw / totalLen)
end

return QAToolRules
