--!strict
-- Live kill switches and soft shutdown (systems audit v32 T1-5; docs/RUNBOOK.md section 4). Pure: no services, no
-- Instances, no clock of its own, so server/LiveOps, server/AdminService and tools/tests/live_ops_spec.luau share one
-- reading of the flag document, the fail-open rule and the shutdown sequence.
--
-- Flag source: one DataStore row (STORE_NAME / KEY), read by every server at boot and every POLL_SECONDS, and re-read at
-- once when a MessagingService nudge on TOPIC arrives (the nudge carries only a revision number; its content is never
-- trusted as flags). Only server code reads the row; only the D22 admin account writes it (/admin live ...).
-- Document: { v = 1, rev = <n>, off = { [flag] = true }, by = <userId>, at = <epoch> }. A flag is OFF only when the
-- document says `off[flag] = true`; anything else (missing, false, a string, an unknown flag) leaves it ON.
-- Fail OPEN: no row, a row that does not parse, or a store that cannot be read means normal play (every flag ON). A read
-- failure after a good read keeps the last good flags for STALE_SECONDS (a DataStore blip must not re-open a feature the
-- owner just switched off), then falls back to all ON.
-- Private builds keep everything ON: the default is all ON, nothing here reads LAUNCH_HIDE, and an empty or missing row
-- changes nothing.
local Progression = require(script.Parent:WaitForChild("Progression"))

local LiveOpsRules = {}

LiveOpsRules.LOG = "[SkyRally][LIVEOPS] "
LiveOpsRules.SCHEMA = 1
LiveOpsRules.STORE_NAME = "SkyRallyLiveOps"
LiveOpsRules.KEY = "flags_v1"
LiveOpsRules.TOPIC = "SkyRallyLiveOps"
LiveOpsRules.POLL_SECONDS = 60
LiveOpsRules.STALE_SECONDS = 900
LiveOpsRules.NUDGE_GAP = 2 -- seconds: MessagingService nudges closer than this collapse into one read
LiveOpsRules.MAX_FLAGS = 64 -- entries read from one document; the rest are ignored (a damaged row cannot flood the server)
LiveOpsRules.MAP_PREFIX = "map:"
LiveOpsRules.ATTR_OFF = "LiveOff" -- workspace attribute: sorted, comma-separated OFF flags ("" when all ON)
LiveOpsRules.ATTR_NOTICE = "ServerNotice" -- workspace attribute: the closing text the client banner shows (nil = none)

-- Feature flags, in the order the status line lists them.
LiveOpsRules.FEATURES = { "store", "stormcup", "battles", "avatars", "telemetry" } :: { string }
LiveOpsRules.FEATURE_INFO = {
	store = "every Robux prompt refused (receipts for purchases already made are still granted)",
	stormcup = "no Storm Cup or storm race launches (the schedule still shows)",
	battles = "battle mode refused on every map",
	avatars = "every vehicle spawns with its class starter avatar (saved picks untouched)",
	telemetry = "no AnalyticsService events (server log lines still print)",
} :: { [string]: string }

-- Player-facing reasons (portal toast, board lock line, Garage refusal).
LiveOpsRules.REASON_PAUSED = "paused for maintenance"
LiveOpsRules.REASON_CLOSING = "server restarting"

export type State = {
	off: { [string]: boolean },
	rev: number,
	by: number?,
	at: number?,
}

export type Doc = { v: number, rev: number, off: { [string]: boolean }, by: number?, at: number? }

function LiveOpsRules.defaultState(): State
	return { off = {}, rev = 0 }
end

------------------------------------------------------------------------------------------------ flag names

-- A flag's canonical name, or nil when it is not a known flag. Features are any case; maps are "map:<launch track id>"
-- (also "map:dino" for the zone's map). The hub can never be switched off: it is where everyone waits.
function LiveOpsRules.canonical(raw: any): string?
	if type(raw) ~= "string" or #raw > 40 then
		return nil
	end
	local lower = string.lower(raw)
	if table.find(LiveOpsRules.FEATURES, lower) then
		return lower
	end
	local rest = string.match(lower, "^map:(.+)$")
	if rest then
		local track = LiveOpsRules.trackOf(rest)
		if track then
			return LiveOpsRules.MAP_PREFIX .. track
		end
	end
	return nil
end

-- A launch map id other than the hub ("dino-4", "DINO" -> "DINO-4"), or nil.
function LiveOpsRules.trackOf(raw: any): string?
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local u = string.upper(raw)
	local id = if Progression.TRACKS[u] then u else Progression.ZONE_TRACK[u]
	if id == nil or id == Progression.HUB_TRACK then
		return nil
	end
	return id
end

function LiveOpsRules.mapFlag(trackId: string): string
	return LiveOpsRules.MAP_PREFIX .. trackId
end

------------------------------------------------------------------------------------------------ parsing

-- The flags in a stored document. Never errors; returns the state and a list of warnings (logged by the server).
-- A document that is not a table, or has another schema, is ignored as a whole (all ON).
function LiveOpsRules.parse(doc: any): (State, { string })
	local warnings: { string } = {}
	local state = LiveOpsRules.defaultState()
	if doc == nil then
		return state, warnings
	end
	if type(doc) ~= "table" then
		table.insert(warnings, "doc is " .. type(doc) .. ", ignored")
		return state, warnings
	end
	if doc.v ~= LiveOpsRules.SCHEMA then
		table.insert(warnings, "schema " .. tostring(doc.v) .. " unknown, ignored")
		return state, warnings
	end
	if type(doc.rev) == "number" and doc.rev == doc.rev and doc.rev >= 0 then
		state.rev = math.floor(doc.rev)
	end
	if type(doc.by) == "number" then
		state.by = doc.by
	end
	if type(doc.at) == "number" then
		state.at = doc.at
	end
	local off = doc.off
	if off == nil then
		return state, warnings
	end
	if type(off) ~= "table" then
		table.insert(warnings, "off is " .. type(off) .. ", ignored")
		return state, warnings
	end
	local seen = 0
	local keys: { string } = {}
	for k in pairs(off) do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	for _, k in keys do
		seen += 1
		if seen > LiveOpsRules.MAX_FLAGS then
			table.insert(warnings, "more than " .. LiveOpsRules.MAX_FLAGS .. " flags, rest ignored")
			break
		end
		local name = LiveOpsRules.canonical(k)
		if not name then
			table.insert(warnings, "unknown flag " .. string.sub(k, 1, 40))
		elseif off[k] == true then
			state.off[name] = true
		end
	end
	return state, warnings
end

-- What the server runs on after a read. readOk false = the store call failed. lastGood/lastGoodAt = the last state
-- that came from a successful read (nil at boot). Returns the state and its source: "store" | "stale" | "default".
function LiveOpsRules.resolve(readOk: boolean, doc: any, lastGood: State?, lastGoodAt: number?, now: number): (State, string, { string })
	if readOk then
		local state, warnings = LiveOpsRules.parse(doc)
		return state, "store", warnings
	end
	if lastGood and lastGoodAt and now - lastGoodAt <= LiveOpsRules.STALE_SECONDS then
		return lastGood, "stale", {}
	end
	return LiveOpsRules.defaultState(), "default", {}
end

------------------------------------------------------------------------------------------------ reading a state

function LiveOpsRules.isOn(state: State?, flag: string): boolean
	return state == nil or state.off[flag] ~= true
end

-- Why `mode` on `trackId` may not start now, or nil. The hub (and its hub mode) is never blocked: it is where players wait.
function LiveOpsRules.modeBlock(state: State?, trackId: any, mode: any, closing: boolean?): string?
	if trackId == Progression.HUB_TRACK and (mode == "hub" or mode == nil) then
		return nil
	end
	if closing then
		return LiveOpsRules.REASON_CLOSING
	end
	if state == nil then
		return nil
	end
	if mode == "battle" and state.off.battles == true then
		return "battles " .. LiveOpsRules.REASON_PAUSED
	end
	if type(trackId) == "string" and state.off[LiveOpsRules.mapFlag(trackId)] == true then
		return "map " .. LiveOpsRules.REASON_PAUSED
	end
	return nil
end

-- Sorted OFF flags (the LiveOff attribute and the status line).
function LiveOpsRules.offList(state: State?): { string }
	local out: { string } = {}
	if state then
		for k, v in pairs(state.off) do
			if v == true then
				table.insert(out, k)
			end
		end
	end
	table.sort(out)
	return out
end

function LiveOpsRules.describe(state: State?, source: string?): string
	local off = LiveOpsRules.offList(state)
	local list = if #off == 0 then "all on" else "off: " .. table.concat(off, ", ")
	return string.format("Live flags %s (rev %d, %s).", list, if state then state.rev else 0, source or "default")
end

------------------------------------------------------------------------------------------------ writing (admin)

-- The document after one change (the UpdateAsync transform body). on = true removes the flag; flag = nil with on = true
-- is "reset" (every flag ON). Unknown or damaged old content is dropped, never carried forward.
function LiveOpsRules.apply(old: any, flag: string?, on: boolean, actorId: number, now: number): Doc
	local state = LiveOpsRules.parse(old)
	local off: { [string]: boolean } = {}
	if flag ~= nil then
		for k, v in pairs(state.off) do
			off[k] = v
		end
		if on then
			off[flag] = nil
		else
			off[flag] = true
		end
	end
	return { v = LiveOpsRules.SCHEMA, rev = state.rev + 1, off = off, by = actorId, at = math.floor(now) }
end

export type Command = { action: string, flag: string?, on: boolean? }

LiveOpsRules.HELP = table.concat({
	"/admin live",
	"/admin live <store|stormcup|battles|avatars|telemetry> on|off",
	"/admin live map <map> on|off",
	"/admin live reset",
}, "\n")

-- "/admin live ..." (any case). Everything else goes to AdminRules.parse.
function LiveOpsRules.isLiveCommand(text: any): boolean
	if type(text) ~= "string" or #text > 200 then
		return false
	end
	local a, b = string.match(text, "^%s*(%S+)%s+(%S+)")
	if a == nil then
		a = string.match(text, "^%s*(%S+)")
	end
	return a ~= nil and string.lower(a) == "/admin" and b ~= nil and string.lower(b) == "live"
end

local function onOff(word: string?): boolean?
	if word == "on" or word == "true" then
		return true
	elseif word == "off" or word == "false" then
		return false
	end
	return nil
end

function LiveOpsRules.parseCommand(text: any): (Command?, string?)
	if not LiveOpsRules.isLiveCommand(text) then
		return nil, "not a live command"
	end
	local words: { string } = {}
	for w in string.gmatch(text :: string, "%S+") do
		table.insert(words, string.lower(w))
	end
	-- words[1] = "/admin", words[2] = "live"
	local w3, w4, w5 = words[3], words[4], words[5]
	if w3 == nil or w3 == "status" then
		return { action = "status" }, nil
	end
	if w3 == "help" then
		return { action = "help" }, nil
	end
	if w3 == "reset" then
		return { action = "reset" }, nil
	end
	if w3 == "map" then
		local track = LiveOpsRules.trackOf(w4)
		if not track then
			return nil, "map takes a launch map (the hub cannot be switched off)"
		end
		local on = onOff(w5)
		if on == nil then
			return nil, "map " .. track .. " takes on or off"
		end
		return { action = "set", flag = LiveOpsRules.mapFlag(track), on = on }, nil
	end
	local flag = LiveOpsRules.canonical(w3)
	if not flag then
		return nil, "flag must be one of " .. table.concat(LiveOpsRules.FEATURES, ", ") .. " or map <map>"
	end
	local on = onOff(w4)
	if on == nil then
		return nil, flag .. " takes on or off"
	end
	return { action = "set", flag = flag, on = on }, nil
end

------------------------------------------------------------------------------------------------ shutdown

-- Soft shutdown (DataModel.ServerRestartScheduled: an update was published and Roblox scheduled this server's restart;
-- the Roblox sample teleports players with TeleportAsync(game.PlaceId, ...) "to a server on the latest place version"):
--   1 notice   banner + toast for everyone, new races and Storm Cups held, store prompts refused;
--   2 races    wait for running races to finish (results shown) up to RACE_GRACE seconds, never past the restart
--              time minus MOVE_MARGIN;
--   3 save     the final save of every player (SaveService.release: write + unlock, so the new server loads at once);
--   4 move     TeleportAsync to the same place in one call (8 players max); one retry after RETRY_GAP;
--   5 kick     anyone still here after the teleport: a friendly kick that says whether the save landed.
-- Hard close (BindToClose, about 30 s and no way to teleport reliably): toast, final saves within CLOSE_SAVE_SECONDS,
-- then the friendly kick; a running race ends without a payout (the same as leaving mid-race).
LiveOpsRules.SHUTDOWN = {
	RACE_GRACE = 150, -- seconds a running race may still finish after the notice
	MOVE_MARGIN = 30, -- the move starts at least this long before Roblox's restart time
	NOTICE_SECONDS = 5, -- the banner shows at least this long before anyone moves
	SAVE_SECONDS = 12, -- deadline for the final saves before the move
	RETRY_GAP = 5, -- seconds before the one teleport retry
	KICK_AFTER = 15, -- seconds after the last teleport call before stragglers are kicked
	CLOSE_SAVE_SECONDS = 20, -- BindToClose: final-save budget (Roblox allows 30 s in all)
	POLL = 1,
}

LiveOpsRules.TEXT = {
	softBanner = "Update ready: finish your race, then you move to a new server.",
	softToast = "SkyRally has an update. Your progress is saved first.",
	moving = "Moving you to the updated server...",
	closeToast = "This server is closing. Saving your progress...",
	kickSaved = "SkyRally restarted for an update. Your progress is saved. Rejoin to keep racing!",
	kickUnsaved = "SkyRally restarted for an update. Your last few seconds may not have saved. Rejoin in a minute.",
}

-- When the soft sequence stops waiting for races: now + RACE_GRACE, but never later than restartAt - MOVE_MARGIN, and
-- never sooner than now + NOTICE_SECONDS. restartAt nil = no known restart time.
function LiveOpsRules.moveBy(now: number, restartAt: number?): number
	local s = LiveOpsRules.SHUTDOWN
	local by = now + s.RACE_GRACE
	if restartAt then
		by = math.min(by, restartAt - s.MOVE_MARGIN)
	end
	return math.max(by, now + s.NOTICE_SECONDS)
end

-- Whether the soft sequence moves now: after the notice time, once no race is running, or at moveBy regardless.
function LiveOpsRules.readyToMove(now: number, noticeAt: number, moveByAt: number, racing: boolean): boolean
	if now < noticeAt + LiveOpsRules.SHUTDOWN.NOTICE_SECONDS then
		return false
	end
	return (not racing) or now >= moveByAt
end

function LiveOpsRules.kickMessage(saved: boolean): string
	return if saved then LiveOpsRules.TEXT.kickSaved else LiveOpsRules.TEXT.kickUnsaved
end

return LiveOpsRules
