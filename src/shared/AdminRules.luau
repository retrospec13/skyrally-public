--!strict
-- Owner admin rules (DECISIONS D22; TEST_LIST_LAUNCH L90-L91). Pure: no services, no Instances, no yields, so the server
-- (server/AdminService and the gates it branches), the client page (client/AdminPanel, an ADMIN tab in Settings) and the Lune spec
-- (tools/tests/admin_spec.luau) share one reading of what a command means and how far it may go.
--  * Who: NOT here. This module replicates to every client, so the admin's UserId, the Studio test path and the award
--    source that opens SaveService's gates live in server/AdminConfig (ServerScriptService) only.
--  * Flags (runtime only, never saved): portals (map access bypass, default ON), lobby ("normal" | "short" | "skip"), holdOff
--    (the Storm Cup lobby minute does not refuse his race), vehicles (D22a: every vehicle avatar counts as owned and
--    selectable, default ON; AvatarRules.owns branches on it first). Bypass is not a grant: no token or avatar is ever
--    written by a flag.
--  * Commands: one grammar for the chat ("/admin cash 10000") and the panel (its buttons send the same text).
--  * Clamps: Cash per call and the wallet total; Win Pass counters.
local Progression = require(script.Parent:WaitForChild("Progression"))
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))

local AdminRules = {}

AdminRules.PREFIX = "/admin"
AdminRules.LOG = "[SkyRally][ADMIN] kind=admin"
AdminRules.REMOTE = "AdminRequest" -- RemoteFunction in ReplicatedStorage.SkyRallyRemotes; text in, reply out (nil for others)
AdminRules.PROBE = "/admin status" -- every client's one start-up ask; a refused probe is not logged (it is every join)
AdminRules.REQUEST_GAP = 0.25 -- seconds between two admin requests the server answers

AdminRules.CASH_MIN = 1
AdminRules.CASH_MAX_PER_CALL = 1000000
AdminRules.CASH_TOTAL_MAX = 100000000 -- the wallet never goes past this through an admin grant
AdminRules.WINPASS_MAX = 1000
AdminRules.SHORT_LOBBY_SECONDS = 5
AdminRules.LOBBY_MODES = { "normal", "short", "skip" }

-- The real SaveService AwardKind values the admin may grant (bestTime and duck are not progression grants).
AdminRules.AWARD_KINDS = { "token", "hubFind", "key", "bossFirst", "bossRematch", "battle", "finalBoss" }
-- The only pass the admin may flip at runtime (MonetizationConfig pass key).
AdminRules.PASS_KEYS = { x2 = "x2Gears", x2gears = "x2Gears", x2cash = "x2Gears" } :: { [string]: string }
-- The distinct pass keys in scope ({ "x2Gears" }).
function AdminRules.passKeys(): { string }
	local out: { string } = {}
	for _, key in AdminRules.PASS_KEYS do
		if not table.find(out, key) then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end
AdminRules.WINPASS_FIELDS = { wins = true, races = true, premium = true }

export type Flags = {
	portals: boolean,
	lobby: string,
	holdOff: boolean,
	vehicles: boolean,
}

export type Command = {
	action: string,
	on: boolean?,
	amount: number?,
	kind: string?,
	id: string?,
	pass: string?,
	field: string?,
	value: any,
	track: string?,
	modifier: string?,
	mode: string?,
}

------------------------------------------------------------------------------------------------ flags

function AdminRules.defaultFlags(): Flags
	return { portals = true, lobby = "normal", holdOff = false, vehicles = true }
end

------------------------------------------------------------------------------------------------ gates

-- Map access bypass for this admin's flags (nil flags = not admin = false).
function AdminRules.portalsOpen(flags: Flags?): boolean
	return flags ~= nil and flags.portals == true
end

-- D22a: every vehicle avatar unlocked for this admin (nil flags = not admin = false). Runtime only, never saved.
function AdminRules.vehiclesOpen(flags: Flags?): boolean
	return flags ~= nil and flags.vehicles == true
end

function AdminRules.skipsHold(flags: Flags?): boolean
	return flags ~= nil and flags.holdOff == true
end

-- Seconds of a portal lobby the admin opens (skip = 0: the server switches at once).
function AdminRules.lobbySeconds(mode: any, base: number): number
	if mode == "skip" then
		return 0
	elseif mode == "short" then
		return math.min(base, AdminRules.SHORT_LOBBY_SECONDS)
	end
	return base
end

-- The kind=admin line for a race start the admin's flags let through (TrackDirector.admit and the lobby): holdActive = the
-- Storm Cup lobby minute would have refused anyone else, why = canOpen's reason ("admin" = the map-access bypass opened it).
-- nil when no admin flag changed the outcome (nothing to log). The caller adds the user and the track.
function AdminRules.admitBypass(flags: Flags?, holdActive: boolean, why: any): string?
	if flags == nil then
		return nil
	end
	local parts: { string } = {}
	if holdActive and flags.holdOff == true then
		table.insert(parts, "holdBypass")
	end
	if why == "admin" then
		table.insert(parts, "portalBypass")
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "+")
end

------------------------------------------------------------------------------------------------ clamps

-- Cash per call: a whole number 1..CASH_MAX_PER_CALL (larger asks are clamped down, not refused). nil + why when unusable.
function AdminRules.clampCash(raw: any): (number?, string?)
	local n = if type(raw) == "string" then tonumber((string.gsub(raw, ",", ""))) else raw
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return nil, "amount must be a number"
	end
	n = math.floor(n)
	if n < AdminRules.CASH_MIN then
		return nil, "amount must be at least " .. AdminRules.CASH_MIN
	end
	return math.min(n, AdminRules.CASH_MAX_PER_CALL), nil
end

-- What a grant adds to a wallet holding `balance`: the wallet stops at CASH_TOTAL_MAX.
function AdminRules.cashGrant(balance: any, amount: number): number
	local b = if type(balance) == "number" and balance == balance then math.max(0, balance) else 0
	return math.max(0, math.min(amount, AdminRules.CASH_TOTAL_MAX - b))
end

-- Win Pass edits: wins / races a whole number 0..WINPASS_MAX; premium a boolean.
function AdminRules.clampWinPass(field: any, raw: any): (any, string?)
	if field == "premium" then
		if raw == true or raw == "on" or raw == "true" then
			return true, nil
		elseif raw == false or raw == "off" or raw == "false" then
			return false, nil
		end
		return nil, "premium takes on or off"
	end
	if field ~= "wins" and field ~= "races" then
		return nil, "field must be wins, races or premium"
	end
	local n = if type(raw) == "string" then tonumber(raw) else raw
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return nil, field .. " must be a number"
	end
	return math.clamp(math.floor(n), 0, AdminRules.WINPASS_MAX), nil
end

------------------------------------------------------------------------------------------------ ids

local function upper(s: string): string
	return string.upper(s)
end

-- "dino-4", "DINO", "dino" -> "DINO-4"; "hub-0" -> "HUB-0". nil when no launch map matches.
function AdminRules.trackOf(raw: any): string?
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local u = upper(raw)
	if Progression.TRACKS[u] then
		return u
	end
	return Progression.ZONE_TRACK[u]
end

local function zoneOf(raw: any): string?
	if type(raw) ~= "string" then
		return nil
	end
	local u = upper(raw)
	local zone = Progression.zoneOf(u)
	if zone and Progression.isChainZone(zone) then
		return zone
	end
	return nil
end

local KIND_ALIAS: { [string]: string } = {}
for _, k in AdminRules.AWARD_KINDS do
	KIND_ALIAS[string.lower(k)] = k
end

local FIND_ALIAS: { [string]: string } = {}
for _, id in Progression.HUB_FINDS do
	FIND_ALIAS[string.lower(id)] = id
	FIND_ALIAS[string.lower((string.gsub(id, "^HubFind_", "")))] = id
end

-- The SaveService award id for an admin grant: kind (any case), target (track, zone or full id), optional "race"/"coin" for
-- tokens. Returns kind, id or nil, why.
function AdminRules.awardId(rawKind: any, target: any, extra: any): (string?, string?)
	local kind = if type(rawKind) == "string" then KIND_ALIAS[string.lower(rawKind)] else nil
	if not kind then
		return nil, "kind must be one of " .. table.concat(AdminRules.AWARD_KINDS, ", ")
	end
	if kind == "finalBoss" then
		return kind, Progression.FINAL_BOSS_ID
	end
	if kind == "hubFind" then
		local id = if type(target) == "string" then FIND_ALIAS[string.lower(target)] else nil
		if not id then
			return nil, "hub find must be one of ground, wateredge, ledge, cove"
		end
		return kind, id
	end
	if kind == "token" then
		if type(target) == "string" then
			local prefix, rest = string.match(target, "^(%a+):(.+)$")
			if prefix and rest then
				local track = AdminRules.trackOf(rest)
				local p = string.lower(prefix)
				if track and (p == "race" or p == "coin") then
					local id = p .. ":" .. track
					if Progression.TOKEN_INFO[id] then
						return kind, id
					end
				end
				return nil, "no token " .. target
			end
		end
		local track = AdminRules.trackOf(target)
		local which = if type(extra) == "string" then string.lower(extra) else "race"
		if not track or track == Progression.HUB_TRACK or (which ~= "race" and which ~= "coin") then
			return nil, "token takes a launch map and race or coin"
		end
		local id = if which == "coin" then Progression.coinTokenId(track) else Progression.raceTokenId(track)
		return kind, id
	end
	-- key, bossFirst, bossRematch, battle: a chain zone (or its map)
	local zone = zoneOf(target)
	if not zone then
		return nil, kind .. " takes DINO, SNOW, ISLAND or FOREST"
	end
	return kind, zone
end

local MODIFIER_ALIAS: { [string]: string } = { none = "none" }
for _, m in MonetizationConfig.STORM_CUP.modifiers do
	MODIFIER_ALIAS[string.lower(m)] = m
end

-- A forced Storm Cup: the track must be in the cup rotation, the modifier one the cup builds (or none).
function AdminRules.validateStorm(rawTrack: any, rawModifier: any): (string?, string?)
	local track = AdminRules.trackOf(rawTrack)
	if not track or not table.find(MonetizationConfig.STORM_CUP.tracks, track) then
		return nil, "cup track must be one of " .. table.concat(MonetizationConfig.STORM_CUP.tracks, ", ")
	end
	local modifier = if type(rawModifier) == "string" then MODIFIER_ALIAS[string.lower(rawModifier)] else "none"
	if rawModifier == nil then
		modifier = "none"
	end
	if not modifier then
		return nil, "modifier must be night, doubleItemBoxes or none"
	end
	return track, modifier
end

function AdminRules.stormModifiers(): { string }
	local out = table.clone(MonetizationConfig.STORM_CUP.modifiers)
	table.insert(out, "none")
	return out
end

-- Solo start: map (default DINO-4) and mode (default race; the hub map runs its boss).
function AdminRules.soloTarget(rawTrack: any, rawMode: any): (string?, string?)
	local track = if rawTrack == nil then "DINO-4" else AdminRules.trackOf(rawTrack)
	if not track then
		return nil, "no launch map " .. tostring(rawTrack)
	end
	local mode = if type(rawMode) == "string" then string.lower(rawMode) else (if track == Progression.HUB_TRACK then "boss" else "race")
	if not table.find(Progression.MODES, mode) then
		return nil, "mode must be one of " .. table.concat(Progression.MODES, ", ")
	end
	if not Progression.modeExists(track, mode) then
		return nil, track .. " has no " .. mode
	end
	return track, mode
end

------------------------------------------------------------------------------------------------ commands

local function onOff(word: any): boolean?
	if word == "on" or word == "true" then
		return true
	elseif word == "off" or word == "false" then
		return false
	end
	return nil
end

AdminRules.HELP = table.concat({
	"/admin portals on|off",
	"/admin award <kind> <map|zone|find> [race|coin]",
	"/admin cash <amount>",
	"/admin pass x2 on|off",
	"/admin winpass wins|races <n> | premium on|off",
	"/admin storm <map> <night|doubleItemBoxes|none>",
	"/admin lobby skip|short|normal",
	"/admin solo [map] [mode]",
	"/admin hold on|off",
	"/admin vehicles on|off",
	"/admin status",
}, "\n")

-- Parses one command line ("/admin cash 10000", or the same without the prefix). Returns the command or nil, why.
-- A chat line meant for the admin handler: "/admin" alone or "/admin <words>" (any case). Anything else is normal chat.
function AdminRules.isChatCommand(text: any): boolean
	if type(text) ~= "string" or #text > 200 then
		return false
	end
	local first = string.match(text, "^%s*(%S+)")
	return first ~= nil and string.lower(first) == AdminRules.PREFIX
end

function AdminRules.parse(text: any): (Command?, string?)
	if type(text) ~= "string" or #text > 200 then
		return nil, "bad command"
	end
	local words: { string } = {}
	for w in string.gmatch(text, "%S+") do
		table.insert(words, w)
	end
	if words[1] and string.lower(words[1]) == AdminRules.PREFIX then
		table.remove(words, 1)
	end
	local verb = if words[1] then string.lower(words[1]) else "open"
	local a1, a2, a3 = words[2], words[3], words[4]
	local l1 = if a1 then string.lower(a1) else nil
	local l2 = if a2 then string.lower(a2) else nil
	if verb == "open" or verb == "panel" then
		return { action = "open" }, nil
	elseif verb == "help" then
		return { action = "help" }, nil
	elseif verb == "status" or verb == "state" then
		return { action = "status" }, nil
	elseif verb == "portals" then
		local on = onOff(l1)
		if on == nil then
			return nil, "portals takes on or off"
		end
		return { action = "portals", on = on }, nil
	elseif verb == "cash" then
		local amount, why = AdminRules.clampCash(a1)
		if not amount then
			return nil, why
		end
		return { action = "cash", amount = amount }, nil
	elseif verb == "award" then
		local kind, id = AdminRules.awardId(a1, a2, a3)
		if not kind then
			return nil, id
		end
		return { action = "award", kind = kind, id = id }, nil
	elseif verb == "pass" then
		local key = if l1 then AdminRules.PASS_KEYS[l1] else nil
		local on = onOff(l2)
		if not key or on == nil then
			return nil, "pass takes x2 on or off"
		end
		return { action = "pass", pass = key, on = on }, nil
	elseif verb == "winpass" then
		local value, why = AdminRules.clampWinPass(l1, if l1 == "premium" then l2 else a2)
		if value == nil then
			return nil, why
		end
		return { action = "winpass", field = l1, value = value }, nil
	elseif verb == "storm" then
		local track, modifier = AdminRules.validateStorm(a1, a2)
		if not track then
			return nil, modifier
		end
		return { action = "storm", track = track, modifier = modifier }, nil
	elseif verb == "lobby" then
		if not l1 or not table.find(AdminRules.LOBBY_MODES, l1) then
			return nil, "lobby takes skip, short or normal"
		end
		return { action = "lobby", mode = l1 }, nil
	elseif verb == "solo" then
		local track, mode = AdminRules.soloTarget(a1, a2)
		if not track then
			return nil, mode
		end
		return { action = "solo", track = track, mode = mode }, nil
	elseif verb == "hold" then
		local on = onOff(l1)
		if on == nil then
			return nil, "hold takes on or off"
		end
		return { action = "hold", on = on }, nil
	elseif verb == "vehicles" or verb == "vehicle" then
		local on = onOff(l1)
		if on == nil then
			return nil, "vehicles takes on or off"
		end
		return { action = "vehicles", on = on }, nil
	end
	return nil, "unknown command (try /admin help)"
end

-- One line for the status reply and the panel header.
function AdminRules.describe(flags: Flags): string
	return string.format(
		"Portals %s. Lobby %s. Cup hold %s. Vehicles %s.",
		if flags.portals then "open" else "normal",
		flags.lobby,
		if flags.holdOff then "off" else "on",
		if flags.vehicles then "all" else "owned"
	)
end

------------------------------------------------------------------------------------------------ client

-- The ADMIN page lives in the Settings panel (client/Settings.setExtraPage; owner 2026-10-21: "my account should just have
-- the admin settings via the settings tab"): no button of its own, no hotkey. The client registers it only when its
-- start-up status ask came back as a reply table; the server answers nil to every other player, so they get nothing.
AdminRules.PAGE_TITLE = "ADMIN"

function AdminRules.probeSaysAdmin(ok: boolean, reply: any): boolean
	return ok == true and type(reply) == "table"
end

return AdminRules
