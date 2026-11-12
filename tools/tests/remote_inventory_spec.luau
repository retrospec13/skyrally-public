--!strict
-- Remote inventory (systems audit v32 T1-9): every client->server handler under src/server (OnServerEvent /
-- OnServerInvoke) is on AUDITED with how it checks types and ranges and how it limits rate, and the guard each row
-- names is still in that file. A new remote fails this spec until it is audited and listed here.
-- Plain lune script: run via tools/tests/run_lune_tests.sh (exit 1 on any failure).
local fs = require("@lune/fs")
local process = require("@lune/process")

type Row = { handlers: number, remote: string, types: string, rate: string, guards: { string } }

local AUDITED: { [string]: Row } = {
	["src/server/RaceManager.luau"] = {
		handlers = 1,
		remote = "RaceEventRemote (Ring/Pad/Geyser/PickupCollected)",
		types = "eventType string; ring/pad name + trigger exists + position history + cooldown (RemoteGuardRules); "
			.. "geyser: VolcanoVents.onTriggered position/stage; pickup: name + pod + distance",
		rate = "RemoteGuardRules.LIMITS.raceEvent",
		guards = { "raceEventLimiter.allow(player, os.clock())", "triggerClaimOk(player, rec, eventType, payload)", "RaceManager.handlePickup(player, rec, payload.podName)" },
	},
	["src/server/FlightServer.luau"] = {
		handlers = 1,
		remote = "FlightStateRemote (SyncTransform, RequestRespawn, RequestCourseReturn, RequestPlayAgain)",
		types = "speed finite + clamped, BoostState enum; course-return reason checked by FlightGuideRules.canReturn; "
			.. "play-again goes through TrackDirector.requestExit (VOTE_COOLDOWN)",
		rate = "RemoteGuardRules.LIMITS.flightState",
		guards = { "flightLimiter.allow(player, os.clock())", "RemoteGuardRules.boostState(payload.boostState)" },
	},
	["src/server/CarServer.luau"] = {
		handlers = 1,
		remote = "FlightStateRemote (car half: SyncTransform visuals, RequestRespawn)",
		types = "every number finite + clamped; respawn reason string capped at 24 chars",
		rate = "RemoteGuardRules.LIMITS.flightState; respawn RESPAWN_MIN_INTERVAL + RespawnRules.SERVER_MANUAL_FLOOR",
		guards = { "carLimiter.allow(player, os.clock())", "RemoteGuardRules.num(payload.steer, -1, 1)" },
	},
	["src/server/ItemService.luau"] = {
		handlers = 1,
		remote = "ItemRemote (Use, Roll, Drag)",
		types = "action compared to three constants; payload ignored (the server knows what the racer holds)",
		rate = "RemoteGuardRules.LIMITS.item; Roll at most once per MissileRules rollMinInterval",
		guards = { "itemLimiter.allow(player, os.clock())" },
	},
	["src/server/TrackDirector.luau"] = {
		handlers = 1,
		remote = "TrackFlowRemote (LeaveLobby, BattleIntroSeen, RequestRace, RequestHub, RequestBattle)",
		types = "track keys looked up in keyById, modes in BOARD_MODES",
		rate = "1.5 s per request; LEAVE_THROTTLE; BattleIntroSeen RemoteGuardRules.LIMITS.battleIntro",
		guards = { "introLimiter.allow(player, now)", "now - (lastRequest[player] or 0) < 1.5", "keyById[arg]" },
	},
	["src/server/ErrorReporter.luau"] = {
		handlers = 1,
		remote = "ErrorRemote (RemoteEvent: kind, source, fingerprint, count, message)",
		types = "Rules.cleanClient checks every field (kind enum, source/fingerprint/count/message shape and caps, player names scrubbed)",
		rate = "per-player ErrorReporterRules budget (window budget plus a session cap)",
		guards = { "Rules.cleanClient(kind, source, fp, count, msg, playerNames())", "(b :: Rules.Budget).take()" },
	},
	["src/server/Economy.luau"] = {
		handlers = 1,
		remote = "EconomyRequest (RemoteFunction)",
		types = "ACTIONS table lookup; each handler validates its own arguments",
		rate = "per-player token bucket (st.bucket)",
		guards = { "st.bucket -= 1", "ACTIONS[action]" },
	},
	["src/server/StormShards.luau"] = {
		handlers = 1,
		remote = "StormRequest (RemoteFunction: GetState, Buy, Equip)",
		types = "key string length-checked (MAX_KEY_LEN); slot checked by StormRules.canEquip",
		rate = "StormShards.REQUEST_GAP (reads and writes spaced separately)",
		guards = { "StormShards.REQUEST_GAP", "#key > MAX_KEY_LEN" },
	},
	["src/server/GrandPrix.luau"] = {
		handlers = 1,
		remote = "GrandPrixRemote (Start, Continue, Quit)",
		types = "action compared to three constants; class checked by GrandPrixRules.isClass + classOpen on the saved record; "
			.. "length only selects short/full; Continue/Quit act only for the cup's own player",
		rate = "0.75 s per player",
		guards = { "now - (last[player] or 0) < 0.75", "GrandPrixRules.isClass(class)", "c.player ~= player" },
	},
	["src/server/StormRace.luau"] = {
		handlers = 1,
		remote = "StormRace event (Join, Leave)",
		types = "action compared to two constants",
		rate = "StormRace.REQUEST_GAP",
		guards = { "StormRace.REQUEST_GAP" },
	},
	["src/server/SettingsService.luau"] = {
		handlers = 1,
		remote = "SettingsEvent",
		types = "SettingsRules.cleanUpdate (known keys, clamped values)",
		rate = "SettingsRules token bucket",
		guards = { "service.handle(player, payload)" },
	},
	["src/server/Funnels.luau"] = {
		handlers = 1,
		remote = "OnboardingRemote (moved, ready)",
		types = "action compared to constants; ready logged once",
		rate = "CLIENT_GAP",
		guards = { "CLIENT_GAP" },
	},
	["src/server/CosmeticService.luau"] = {
		handlers = 1,
		remote = "CosmeticEvent (Horn)",
		types = "action compared to one constant; the horn comes from the saved loadout, not the client",
		rate = "GarageModel.HORN_COOLDOWN",
		guards = { "GarageModel.HORN_COOLDOWN" },
	},
	["src/server/AfkService.luau"] = {
		handlers = 1,
		remote = "AfkRemote (beat)",
		types = "no arguments read",
		rate = "AfkRules.MIN_BEAT_GAP (tracker.beat)",
		guards = { "AfkService.onBeat(player)" },
	},
	["src/server/CurtainKartRelay.luau"] = {
		handlers = 1,
		remote = "CurtainKartPos (UnreliableRemoteEvent)",
		types = "CurtainKartNet.sanitize; only while TrackSwitching",
		rate = "CurtainKartNet.accept (MIN_GAP)",
		guards = { "Net.accept(lastAt[player], now)", "Net.sanitize(pos, state, best)" },
	},
	["src/server/RacerStream.luau"] = {
		handlers = 1,
		remote = "RacerStream pose (UnreliableRemoteEvent)",
		types = "PlayerStreamRules gate: buffer size and contents",
		rate = "PlayerStreamRules gate (P.admit)",
		guards = { "P.admit(" },
	},
	["src/server/AdminService.luau"] = {
		handlers = 1,
		remote = "Admin RemoteFunction",
		types = "isAdmin first (nil for everyone else); AdminRules.parse",
		rate = "AdminRules.REQUEST_GAP; denied log once per DENIED_LOG_GAP",
		guards = { "svc.handle, player, text" },
	},
	["src/server/QATools.luau"] = {
		handlers = 1,
		remote = "QA RemoteFunction (Studio only)",
		types = "created only when QAToolRules.allowed(IsStudio)",
		rate = "Studio only",
		guards = { "Rules.allowed(RunService:IsStudio())" },
	},
	["src/server/QASoak.luau"] = {
		handlers = 1,
		remote = "QASoakLog (Studio only; soak sample replies)",
		types = "string <= 4000 chars, JSON-decoded under pcall, seq must be a pending sample; shaped by SoakRules.shape",
		rate = "one reply per client per sample point (replies for a closed seq are dropped)",
		guards = { "SoakRules.allowed(RunService:IsStudio())" },
	},
	["src/server/QAMultiplayer.luau"] = {
		handlers = 1,
		remote = "QAMPLog (Studio only)",
		types = "string prefixes; created only in Studio",
		rate = "Studio only; result lists capped",
		guards = { "if not RunService:IsStudio() then" },
	},
}

local failures: { string } = {}
local function fail(msg: string)
	table.insert(failures, msg)
end

local found: { [string]: number } = {}
local function scan(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			scan(path)
		elseif string.match(name, "%.luau$") then
			local text = fs.readFile(path)
			local n = 0
			for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
				local code = string.gsub(line, "%-%-.*$", "")
				if string.find(code, "OnServerEvent", 1, true) or string.find(code, "OnServerInvoke", 1, true) then
					if string.find(code, ":Connect(", 1, true) or string.find(code, "OnServerInvoke%s*=") then
						n += 1
					end
				end
			end
			if n > 0 then
				found[path] = n
			end
		end
	end
end
scan("src/server")

for path, n in found do
	local row = AUDITED[path]
	if not row then
		fail(path .. ": " .. n .. " server remote handler(s) not on the AUDITED list (add a row: types, rate, guards)")
	elseif row.handlers ~= n then
		fail(string.format("%s: %d handler(s) found, AUDITED says %d (re-audit)", path, n, row.handlers))
	end
end
for path, row in AUDITED do
	if not found[path] then
		fail(path .. ": listed but no handler found (remove or fix the row)")
	else
		local text = fs.readFile(path)
		for _, g in row.guards do
			if not string.find(text, g, 1, true) then
				fail(path .. ": guard missing: " .. g)
			end
		end
	end
end

local total = 0
for _ in found do
	total += 1
end
if #failures > 0 then
	for _, f in failures do
		print("  FAIL " .. f)
	end
	process.exit(1)
end
print(string.format("  PASS remote inventory: %d server files with client->server handlers, all audited", total))
