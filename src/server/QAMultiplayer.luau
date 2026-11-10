--!strict
-- Studio-only multiplayer QA (TEST_LIST L30-L32): runs only inside StudioTestService:ExecuteMultiplayerTestAsync with
-- args { qa = "mp", scenario = ..., key = ... } (tools/mp_check.py starts it from the edit window). Real client
-- DataModels join one local server; the existing workspace.AutoPilot drives every client's vehicle, so the race,
-- the countdown, finishing order, awards and the trip back to the hub run through the shipping code paths.
-- Scenarios:
--   race      every client races `key`; all must finish, places unique, each gets its own RaceFinished, then hub.
--   join_mid  one client races; a second joins 20 s after GO (AddPlayers) and must get a vehicle and not break the race.
--   leave_mid two clients race; the second leaves 20 s after GO (LeaveTest); the race must still end and return to hub.
--   hub       two clients in the hub: one is set on a vehicle exchange pad; the other's vehicle must not change.
--   pergroup  (needs PER_GROUP: Studio QAPerGroup) player A alone asks for `key`; every client reports its own loading
--             curtain (client/QAMultiplayerClient); A's must come up while his group loads, lift once his grid is
--             formed and stay lifted through the race and back on the plaza; B (in the hub, joined nothing) must never
--             see it. res.curtain[name] is each client's curtain timeline.
--   jitter    every client races `key`; 20 s after GO each client records Shared.JitterProbe for args.jitterSecs
--             (default 10) and sends the summary back; res.jitter[name] holds it (tools/jitter_probe.py mp). Ends there.
--   join_countdown (TG-3, L31) one client opens the server-wide lobby (TrackDirector.openLobby; the lobby is stretched to
--             args.lobbySecs, default 45, for this run only, so a slow client start still lands inside it); 3 s in, a second
--             client joins (AddPlayers). It must get a vehicle in the hub while the lobby is still open, then both race
--             the same race to the end with unique places. res.lobby has the numbers.
--   leave_lobby (TG-3, L31) players=2: the non-opener leaves 3 s into the lobby; the lobby must stay open and the opener's
--             race must start and finish.
--   leave_countdown (TG-3, L31) players=2: the second client leaves as soon as the race map is loaded, i.e. during the
--             3-2-1; the first client's race must still start and finish. res.countdown.leftBeforeGo says whether the
--             leave really landed before GO (if not the verdict is INCONCLUSIVE: the countdown was shorter than the leave).
--   solo_start (TG-3, L31) players=1: the lone client picks args.trackId (default derived from key) through the REAL board
--             request (client fires TrackFlowRemote RequestRace). Per group (QAPerGroup on) that is the arch lobby: res.solo
--             records the lobby seconds (about LOBBY_SECONDS) and the GridField (8 = 1 human + 7 bots); with per group off a
--             lone human warps (about 1.5 s), recorded the same way. The race must finish and return to the hub.
-- Every server error and warning, and client errors forwarded over QAMPLog, are in the result. EndTest returns JSON.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local QAMultiplayer = {}

type Deps = { TrackDirector: any, FlightServer: any, RaceManager: any, CarServer: any }

local function now(): number
	return os.clock()
end

function QAMultiplayer.start(deps: Deps)
	if not RunService:IsStudio() then
		return
	end
	local ok, sts = pcall(function()
		return game:GetService("StudioTestService")
	end)
	if not ok or not sts then
		return
	end
	local okArgs, args = pcall(function()
		return (sts :: any):GetTestArgs()
	end)
	if not okArgs or type(args) ~= "table" or args.qa ~= "mp" then
		return
	end
	local TD, FS = deps.TrackDirector, deps.FlightServer
	local scenario = tostring(args.scenario or "race")
	local key = tostring(args.key or "dino4")
	local want = tonumber(args.players) or 2
	local t0 = now()
	local res: any = { token = args.token, scenario = scenario, key = key, errors = {}, warnings = {}, clientErrors = {}, events = {}, samples = {} }
	local okB, build = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BuildInfo") :: ModuleScript) :: any
	end)
	res.build = if okB then { commit = build.Commit, tree = build.Tree, utc = build.BuiltUtc } else nil
	local function event(fmt: string, ...: any)
		local line = string.format("%6.1f ", now() - t0) .. string.format(fmt, ...)
		table.insert(res.events, line)
		print("[SkyRally][QAMP] " .. line)
	end
	-- An error whose stack starts in a Studio plugin (the MCP plugin loads into the test server too) is not the game's.
	local lastErrorAt: number? = nil
	LogService.MessageOut:Connect(function(msg: string, kind: Enum.MessageType)
		if string.find(msg, "[QAMP]", 1, true) then
			return
		end
		if lastErrorAt and string.find(msg, "Stack Begin", 1, true) then
			return
		end
		if lastErrorAt then
			local at = lastErrorAt
			lastErrorAt = nil
			local name = string.match(msg, "Script '([^']+)'")
			if name and (string.find(name, "^user_") or string.find(name, "^s?a?builtin_")) and res.errors[at] then
				table.remove(res.errors, at)
				return
			end
		end
		if kind == Enum.MessageType.MessageError and #res.errors < 60 then
			lastErrorAt = #res.errors + 1
			table.insert(res.errors, string.sub(msg, 1, 400))
		elseif kind == Enum.MessageType.MessageWarning and #res.warnings < 60 then
			table.insert(res.warnings, string.sub(msg, 1, 300))
		end
	end)
	local logRemote = Instance.new("RemoteEvent")
	logRemote.Name = "QAMPLog"
	logRemote.Parent = ReplicatedStorage
	local ready: { [Player]: boolean } = {}
	res.jitter = {}
	res.curtain = {}
	local curtainNow: { [Player]: { up: boolean, seat: number? } } = {}
	local curtainEverUp: { [Player]: boolean } = {}
	logRemote.OnServerEvent:Connect(function(player: Player, msg: any)
		if msg == "__QAMP_READY" then
			ready[player] = true
			return
		end
		if type(msg) == "string" and string.sub(msg, 1, 15) == "__QAMP_CURTAIN " then
			local okD, data = pcall(HttpService.JSONDecode, HttpService, string.sub(msg, 16))
			if okD and type(data) == "table" then
				local prev = curtainNow[player]
				local cur = { up = data.up == true, seat = if type(data.seat) == "number" then data.seat else nil }
				curtainNow[player] = cur
				if cur.up then
					curtainEverUp[player] = true
				end
				if not prev or prev.up ~= cur.up or prev.seat ~= cur.seat then
					local line = res.curtain[player.Name] or {}
					res.curtain[player.Name] = line
					if #line < 80 then
						table.insert(line, string.format("%.1f up=%s seat=%s", now() - t0, tostring(cur.up), tostring(cur.seat)))
					end
				end
			end
			return
		end
		if type(msg) == "string" and string.sub(msg, 1, 14) == "__QAMP_JITTER " then
			local okD, data = pcall(HttpService.JSONDecode, HttpService, string.sub(msg, 15))
			res.jitter[player.Name] = if okD then data else { error = "json" }
			return
		end
		if #res.clientErrors < 60 then
			table.insert(res.clientErrors, player.Name .. ": " .. string.sub(tostring(msg), 1, 400))
		end
	end)
	workspace:SetAttribute("QAMP", true)
	workspace:SetAttribute("UnlockAll", true)
	workspace:SetAttribute("AutoPilot", true)

	local function finish(verdict: string, why: string)
		res.verdict = verdict
		res.why = why
		res.seconds = math.floor(now() - t0)
		event("END %s: %s", verdict, why)
		local okJ, json = pcall(HttpService.JSONEncode, HttpService, res)
		task.wait(1)
		;(sts :: any):EndTest(if okJ then json else ('{"verdict":"ERROR","why":"json"}'))
	end

	local function waitFor(cond: () -> boolean, timeout: number): boolean
		local deadline = now() + timeout
		while now() < deadline do
			if cond() then
				return true
			end
			task.wait(0.5)
		end
		return false
	end

	local function vehicleName(p: Player): string
		local rec = FS.records and FS.records[p]
		local v = rec and rec.plane
		return if v and v.Parent then v.Name else "none"
	end

	local function sample(tag: string)
		local rows = {}
		for _, p in Players:GetPlayers() do
			local rec = FS.records and FS.records[p]
			local v = rec and rec.plane
			local pos = if v and v.Parent and v:IsA("Model") then v:GetPivot().Position else nil
			table.insert(rows, string.format("%s veh=%s pos=%s lap=%s fin=%s rank=%s",
				p.Name, vehicleName(p), if pos then string.format("(%.0f,%.0f,%.0f)", pos.X, pos.Y, pos.Z) else "-",
				tostring(p:GetAttribute("Lap")), tostring(p:GetAttribute("RaceFinished")), tostring(p:GetAttribute("FinishRank"))))
		end
		table.insert(res.samples, string.format("%6.1f %s %s | %s", now() - t0, tag, tostring(TD.currentKey), table.concat(rows, " ; ")))
	end

	task.spawn(function()
		xpcall(function()
			event("waiting for %d players", want)
			if not waitFor(function()
				if #Players:GetPlayers() < want then
					return false
				end
				for _, p in Players:GetPlayers() do
					if vehicleName(p) == "none" or not ready[p] then
						return false
					end
				end
				return not TD.switching
			end, 150) then
				finish("FAIL", "players, vehicles or client control not ready in 150 s")
				return
			end
			event("ready: %d players in %s", #Players:GetPlayers(), tostring(TD.currentKey))
			sample("ready")

			if scenario == "soak" then
				-- Soak (audit T1-12): the loop in server/QASoak runs with the real clients connected; args.soak is its config.
				local SoakRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoakRules")) :: any
				local cfg, why = SoakRules.parseConfig(args.soak)
				if not cfg then
					finish("FAIL", "bad soak config: " .. tostring(why))
					return
				end
				local QASoak = require(script.Parent:WaitForChild("QASoak")) :: any
				QASoak.ensureRemote()
				local soakSamples = {}
				res.soak = soakSamples
				local okRun, whyRun = QASoak.run({ TrackDirector = TD }, cfg, function(s: any)
					table.insert(soakSamples, s)
				end)
				event("soak finished: %s %s (%d samples)", tostring(okRun), tostring(whyRun), #soakSamples)
				finish(if okRun then "PASS" else "FAIL", if okRun then "soak ran; leak verdict is tools/soak.py" else tostring(whyRun))
				return
			end
			if scenario == "hub" then
				-- Parked cars: the pad and the arch decide, not the pilot (AutoPilot would drive A off the pad and B back
				-- out of the arch).
				workspace:SetAttribute("AutoPilot", false)
				local a, b = Players:GetPlayers()[1], Players:GetPlayers()[2]
				local function veh(p: Player): Instance?
					local rec = FS.records[p]
					local v = rec and rec.plane
					return if v and v.Parent then v else nil
				end
				local va, vb = veh(a), veh(b)
				local td = TD.currentTrackData and TD.currentTrackData()
				local kindA = if deps.CarServer.isCar(va) then "car" else "plane"
				local pad = nil
				for _, pd in (td and td.hub and td.hub.exchange) or {} do
					if pd.vehicle ~= kindA and typeof(pd.cf) == "CFrame" then
						pad = pd
						break
					end
				end
				if not pad then
					finish("FAIL", "no exchange pad for " .. kindA .. " in hub data")
					return
				end
				-- A respawn rolls on at CarConfig.RESPAWN_SPEED (~30 studs before it stops): set A down 15 studs short of the
				-- pad, facing it, so it rolls across the pad's middle the way a driver pulls in, not off its far edge.
				local padLook = Vector3.new(pad.cf.LookVector.X, 0, pad.cf.LookVector.Z).Unit
				local padAt = pad.cf.Position + Vector3.new(0, 3, 0)
				a:SetAttribute("QARespawnAt", CFrame.lookAt(padAt - padLook * 15, padAt))
				event("player A %s (%s) set down rolling onto the %s pad", a.Name, kindA, pad.vehicle)
				-- A swap destroys the old vehicle before the new one spawns: only a NEW vehicle of the pad's kind counts.
				-- The trace (A's offset from the pad every half second) says why a swap did not come.
				res.padTrace = {}
				local tStart = now()
				local swapped = waitFor(function()
					local v = veh(a)
					if v and v:IsA("Model") and #res.padTrace < 40 then
						local d = v:GetPivot().Position - pad.cf.Position
						table.insert(res.padTrace, string.format("%.1f %s (%.0f,%.0f,%.0f)", now() - tStart, v.Name, d.X, d.Y, d.Z))
					end
					return v ~= nil and v ~= va and (if deps.CarServer.isCar(v) then "car" else "plane") == pad.vehicle
				end, 20)
				local vaNew = veh(a)
				task.wait(5) -- the new vehicle must stay (no revert, no second swap) and B's must not be touched
				sample("after-pad")
				res.hubA = { before = if va then va.Name else "none", after = vehicleName(a), swapped = swapped, kept = vaNew ~= nil and veh(a) == vaNew }
				res.hubB = { before = if vb then vb.Name else "none", after = vehicleName(b), same = veh(b) == vb }
				if not swapped then
					finish("FAIL", "exchange pad did not give A a " .. pad.vehicle)
					return
				elseif not res.hubA.kept then
					finish("FAIL", "A's new vehicle did not stay")
					return
				elseif not res.hubB.same then
					finish("FAIL", "B's vehicle changed when A used the pad")
					return
				end
				event("A swapped to %s; B unchanged", vehicleName(a))
				-- Portal (L32): B drives through an arch; with two humans that opens the server-wide lobby, A is untouched,
				-- and when the countdown ends both are in that race with vehicles.
				local portal, pkey = nil, nil
				for _, pt in (td.hub.portals or {}) do
					local k = TD.keyForId(pt.track)
					if typeof(pt.cf) == "CFrame" and k then
						portal, pkey = pt, k
						break
					end
				end
				if not portal or not pkey then
					finish("FAIL", "no portal with a track in hub data")
					return
				end
				local pcf: CFrame = portal.cf
				local ground = pcf.Position - pcf.UpVector * 8 -- the cf is 11 above the plaza; a car hull rides ~3 above it
				local look = pcf.LookVector
				-- Two respawns, each waited for (a respawn lands after its delay; a second one sent before the first lands is
				-- lost, and a jump from far away is longer than PortalRules.MAX_STEP, never a crossing).
				local function setDown(cf: CFrame): boolean
					b:SetAttribute("QARespawnAt", cf)
					return waitFor(function()
						local rec = FS.records[b]
						return rec ~= nil and rec.hull ~= nil and rec.hull.Parent ~= nil and (rec.hull.Position - cf.Position).Magnitude < 8
					end, 6)
				end
				local before = setDown(CFrame.lookAt(ground - look * 10, ground))
				task.wait(0.6) -- a few hub steps on the plaza side
				local after = setDown(CFrame.lookAt(ground + look * 4, ground + look * 20))
				event("player B %s driven through the %s arch (landed before=%s after=%s)", b.Name, tostring(portal.track), tostring(before), tostring(after))
				local lobbyOpen = waitFor(function()
					return workspace:GetAttribute("LobbyTrack") ~= nil
				end, 6)
				sample("lobby")
				res.hubPortal = {
					track = portal.track,
					lobby = lobbyOpen,
					lobbyTrack = workspace:GetAttribute("LobbyTrack"),
					opener = workspace:GetAttribute("LobbyOpener"),
					aDuringLobby = vehicleName(a),
				}
				if not lobbyOpen then
					finish("FAIL", "B's portal crossing opened no lobby")
					return
				end
				local aKept = veh(a) == vaNew
				local switched = waitFor(function()
					return TD.currentKey == pkey and not TD.switching
				end, 60)
				task.wait(5)
				sample("portal-race")
				res.hubPortal.aKeptDuringLobby = aKept
				res.hubPortal.switched = switched
				res.hubPortal.vehicles = { a = vehicleName(a), b = vehicleName(b) }
				if not aKept then
					finish("FAIL", "A's vehicle changed while B's lobby ran")
				elseif not switched then
					finish("FAIL", "the lobby did not take the server to " .. tostring(portal.track))
				elseif vehicleName(a) == "none" or vehicleName(b) == "none" then
					finish("FAIL", "a player has no vehicle in the portal race")
				elseif #res.errors > 0 or #res.clientErrors > 0 then
					finish("FAIL", string.format("%d server and %d client errors", #res.errors, #res.clientErrors))
				else
					finish("PASS", "A swapped and kept it, B unchanged; B's arch opened the lobby and both raced " .. tostring(portal.track))
				end
				return
			end

			if scenario == "pergroup" then
				local Flow = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceFlowRules") :: ModuleScript) :: any
				if not Flow.PER_GROUP then
					finish("FAIL", "PER_GROUP is off: set workspace QAPerGroup = true in Edit, then start the test again")
					return
				end
				-- Parked: AutoPilot would drive B through an arch in the hub (then B would be seated too). A's race ends
				-- without him (the field finishes, RaceGroups abandons it, the return timer takes him home).
				workspace:SetAttribute("AutoPilot", false)
				local a, b = Players:GetPlayers()[1], Players:GetPlayers()[2]
				workspace:SetAttribute("QAMPCurtain", true)
				waitFor(function()
					return curtainNow[a] ~= nil and (b == nil or curtainNow[b] ~= nil)
				end, 10)
				local pc: any = { aStartUp = curtainNow[a] and curtainNow[a].up, bStartUp = b and curtainNow[b] and curtainNow[b].up }
				res.pergroup = pc
				local okReq = TD.requestRace(a, key, "qa-mp", "race")
				event("pergroup: %s asks for %s -> %s", a.Name, key, tostring(okReq))
				pc.seated = waitFor(function()
					return a:GetAttribute("RaceInstanceId") ~= nil
				end, 10)
				local seat = a:GetAttribute("RaceInstanceId")
				pc.aCurtainUp = waitFor(function()
					return curtainEverUp[a] == true
				end, 15)
				local function root(): Instance?
					local f = workspace:FindFirstChild("RaceInstances")
					return f and f:FindFirstChild(tostring(seat))
				end
				pc.loaded = waitFor(function()
					local r = root()
					return r ~= nil and r:GetAttribute("Loading") == false
				end, 70)
				event("pergroup: seated=%s curtainUp=%s loaded=%s", tostring(pc.seated), tostring(pc.aCurtainUp), tostring(pc.loaded))
				pc.aLiftedInRace = waitFor(function()
					local c = curtainNow[a]
					return c ~= nil and c.up == false and c.seat ~= nil
				end, 12)
				sample("pergroup-grid")
				task.wait(15)
				pc.aStillLifted = curtainNow[a] ~= nil and curtainNow[a].up == false
				sample("pergroup-race")
				pc.returned = waitFor(function()
					return a:GetAttribute("RaceInstanceId") == nil
				end, tonumber(args.raceTimeout) or 300)
				task.wait(6)
				sample("pergroup-hub")
				pc.aLiftedInHub = curtainNow[a] ~= nil and curtainNow[a].up == false
				pc.bEverUp = b ~= nil and curtainEverUp[b] == true
				workspace:SetAttribute("QAMPCurtain", nil)
				if not pc.seated then
					finish("FAIL", "A was not seated in a group")
				elseif not pc.loaded then
					finish("FAIL", "A's group did not load (root Loading never false)")
				elseif not pc.aLiftedInRace then
					finish("FAIL", "A's curtain did not lift after his grid formed")
				elseif not pc.aStillLifted then
					finish("FAIL", "A's curtain came back during his race")
				elseif not pc.returned then
					finish("FAIL", "A's group never returned him to the hub")
				elseif not pc.aLiftedInHub then
					finish("FAIL", "A's curtain is up back in the hub")
				elseif pc.bEverUp then
					finish("FAIL", "B (hub, joined nothing) saw the curtain")
				elseif #res.errors > 0 or #res.clientErrors > 0 then
					finish("FAIL", string.format("%d server and %d client errors", #res.errors, #res.clientErrors))
				else
					finish("PASS", string.format("A's curtain %s while loading, lifted on his grid and in the hub; B never saw it",
						if pc.aCurtainUp then "came up" else "was too quick to sample"))
				end
				return
			end

			local started = false
			if scenario == "join_countdown" or scenario == "leave_lobby" then
				local Flow = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceFlowRules") :: ModuleScript) :: any
				if Flow.PER_GROUP then
					finish("FAIL", scenario .. " drives the single server-wide lobby (TrackDirector.openLobby); PER_GROUP is on (QAPerGroup): switch it off")
					return
				end
				local a = Players:GetPlayers()[1]
				local lobbySecs = tonumber(args.lobbySecs) or 45
				local keep = Flow.LOBBY_SECONDS
				Flow.LOBBY_SECONDS = lobbySecs -- read when the lobby opens; restored at once
				workspace:SetAttribute("AutoPilot", false) -- parked: AutoPilot would drive the opener out of the hub
				local opened = TD.openLobby(a, key, "race", nil)
				Flow.LOBBY_SECONDS = keep
				event("%s: %s opens the %s lobby (%d s) -> %s", scenario, a.Name, key, lobbySecs, tostring(opened))
				if not opened then
					finish("FAIL", "openLobby refused (hub not idle, or the track is not open to the player)")
					return
				end
				local goAt0 = workspace:GetAttribute("LobbyGoAt")
				local lobby: any = { seconds = lobbySecs, humansAtOpen = #Players:GetPlayers() }
				res.lobby = lobby
				task.wait(3)
				if scenario == "join_countdown" then
					(sts :: any):AddPlayers(1)
					event("AddPlayers(1) during the lobby")
					lobby.joined = waitFor(function()
						return #Players:GetPlayers() >= want + 1
					end, 90)
					local late = Players:GetPlayers()[#Players:GetPlayers()]
					lobby.lateVehicle = lobby.joined and waitFor(function()
						return vehicleName(late) ~= "none"
					end, 30)
					lobby.stillOpen = workspace:GetAttribute("LobbyTrack") ~= nil
					lobby.humansAtJoin = #Players:GetPlayers()
					lobby.secondsLeft = if type(goAt0) == "number" then goAt0 - workspace:GetServerTimeNow() else nil
					sample("lobby-joined")
					if not lobby.joined or not lobby.lateVehicle then
						finish("FAIL", "the second client did not join with a vehicle during the lobby")
						return
					elseif not lobby.stillOpen then
						finish("INCONCLUSIVE", "the lobby ended before the joiner arrived (slow client start): raise args.lobbySecs")
						return
					end
				else
					local leaver = Players:GetPlayers()[2]
					if not leaver then
						finish("FAIL", "leave_lobby needs players=2")
						return
					end
					leaver:SetAttribute("QALeave", true)
					event("asked %s to leave during the lobby", leaver.Name)
					lobby.left = waitFor(function()
						return leaver.Parent == nil
					end, 30)
					lobby.stillOpen = workspace:GetAttribute("LobbyTrack") ~= nil
					sample("lobby-left")
					if not lobby.left then
						finish("FAIL", "the second client did not leave")
						return
					elseif not lobby.stillOpen then
						finish("INCONCLUSIVE", "the lobby had already ended when the leave landed: raise args.lobbySecs")
						return
					end
				end
				if not waitFor(function()
					return TD.currentKey == key and not TD.switching
				end, lobbySecs + 120) then
					finish("FAIL", "the lobby never started the race")
					return
				end
				workspace:SetAttribute("AutoPilot", true)
				started = true
			elseif scenario == "solo_start" then
				local Flow = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceFlowRules") :: ModuleScript) :: any
				local a = Players:GetPlayers()[1]
				local trackId = tostring(args.trackId or string.gsub(string.upper(key), "^(%a+)(%d+)$", "%1-%2"))
				if TD.keyForId(trackId) ~= key then
					finish("FAIL", "no track id " .. trackId .. " for key " .. key .. ": pass args.trackId")
					return
				end
				workspace:SetAttribute("AutoPilot", false)
				local solo: any = { perGroup = Flow.PER_GROUP == true, trackId = trackId }
				res.solo = solo
				local tPick = now()
				a:SetAttribute("QAPick", trackId) -- the client fires the real RequestRace over TrackFlowRemote
				task.delay(1.5, function()
					a:SetAttribute("QAPick", nil)
				end)
				event("solo_start: %s picks %s through the board request (perGroup=%s)", a.Name, trackId, tostring(solo.perGroup))
				local function raceReady(): boolean
					if solo.perGroup then
						return a:GetAttribute("RaceInstanceId") ~= nil
					end
					return TD.currentKey == key and not TD.switching
				end
				if solo.perGroup then
					solo.queued = waitFor(function()
						return a:GetAttribute("LobbyArch") ~= nil
					end, 10)
				end
				if not waitFor(raceReady, 120) then
					finish("FAIL", "the pick did not start a race in 120 s")
					return
				end
				solo.startSecs = math.floor((now() - tPick) * 10) / 10
				solo.gridField = a:GetAttribute("GridField")
				workspace:SetAttribute("AutoPilot", true)
				event("solo_start: race started %.1f s after the pick (queued=%s field=%s)", solo.startSecs, tostring(solo.queued), tostring(solo.gridField))
				solo.finished = waitFor(function()
					return a:GetAttribute("FinishRank") ~= nil
				end, tonumber(args.raceTimeout) or 420)
				solo.backInHub = waitFor(function()
					if solo.perGroup then
						return a:GetAttribute("RaceInstanceId") == nil
					end
					return TD.currentKey == TD.HUB_KEY and not TD.switching
				end, 120)
				task.wait(3)
				sample("solo-end")
				local lobbyOk = not solo.perGroup or (solo.queued == true and solo.startSecs >= Flow.LOBBY_SECONDS - 4 and solo.startSecs <= Flow.LOBBY_SECONDS + 25)
				if not solo.finished then
					finish("FAIL", "the lone player did not finish")
				elseif not solo.backInHub then
					finish("FAIL", "the lone player was not returned to the hub")
				elseif not lobbyOk then
					finish("FAIL", string.format("per-group solo lobby ran %.1f s (queued=%s), expected about %d", solo.startSecs, tostring(solo.queued), Flow.LOBBY_SECONDS))
				elseif solo.gridField ~= nil and solo.gridField ~= 8 then
					finish("FAIL", "grid field is " .. tostring(solo.gridField) .. ", expected 8 (1 human + 7 bots)")
				elseif #res.errors > 0 or #res.clientErrors > 0 then
					finish("FAIL", string.format("%d server and %d client errors", #res.errors, #res.clientErrors))
				else
					finish("PASS", string.format("solo start %.1f s after the pick, field %s, finished, back in the hub", solo.startSecs, tostring(solo.gridField)))
				end
				return
			end
			if not started then
				local okReq = TD.requestRace(nil, key, "qa-mp", "race")
				event("requestRace %s -> %s", key, tostring(okReq))
				if not waitFor(function()
					return TD.currentKey == key and not TD.switching
				end, 120) then
					finish("FAIL", "race map did not load in 120 s")
					return
				end
			end
			local goAt = workspace:GetAttribute("RaceGoTime")
			event("race loaded; GO in %s s", if type(goAt) == "number" then string.format("%.1f", goAt - workspace:GetServerTimeNow()) else "?")
			if scenario == "leave_countdown" then
				-- The second client leaves while the 3-2-1 is still to come; the first client's race must still start.
				local leaver = Players:GetPlayers()[2]
				local cd: any = { goInAtAsk = if type(goAt) == "number" then goAt - workspace:GetServerTimeNow() else nil }
				res.countdown = cd
				if leaver then
					leaver:SetAttribute("QALeave", true)
					event("asked %s to leave during the countdown (GO in %s s)", leaver.Name, tostring(cd.goInAtAsk))
					waitFor(function()
						return leaver.Parent == nil
					end, 30)
					local nowT = workspace:GetServerTimeNow()
					cd.left = leaver.Parent == nil
					cd.leftBeforeGo = cd.left and type(goAt) == "number" and nowT < goAt
					cd.leftAfterGoSecs = if type(goAt) == "number" then math.floor((nowT - goAt) * 10) / 10 else nil
				end
			end
			sample("grid") -- each human on his own grid slot (L30: planes used to stack on pole)
			task.wait(4)
			sample("grid+4s")
			task.wait(20)
			sample("go+20s")
			if scenario == "jitter" then
				local secs = tonumber(args.jitterSecs) or 10
				workspace:SetAttribute("QAJitterSecs", secs)
				event("jitter probe: %d s on every client", secs)
				local got = waitFor(function()
					for _, p in Players:GetPlayers() do
						if res.jitter[p.Name] == nil then
							return false
						end
					end
					return true
				end, secs + 30)
				workspace:SetAttribute("QAJitterSecs", nil)
				-- the server's remote-player relay counters since boot (Shared.PlayerStreamRules.serverStats, remote-smooth)
				local okR, PRules = pcall(function()
					return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerStreamRules") :: ModuleScript) :: any
				end)
				res.relay = if okR and PRules then table.clone(PRules.serverStats) else nil
				sample("after-jitter")
				if not got then
					finish("FAIL", "not every client sent its jitter summary")
				elseif #res.errors > 0 or #res.clientErrors > 0 then
					finish("FAIL", string.format("%d server and %d client errors", #res.errors, #res.clientErrors))
				else
					finish("PASS", "jitter summaries from every client")
				end
				return
			elseif scenario == "join_mid" then
				(sts :: any):AddPlayers(1)
				event("AddPlayers(1) mid-race")
				local joined = waitFor(function()
					return #Players:GetPlayers() >= want + 1
				end, 60)
				task.wait(10)
				sample("after-join")
				local late = Players:GetPlayers()[#Players:GetPlayers()]
				res.lateJoiner = { joined = joined, vehicle = if late then vehicleName(late) else "none" }
			elseif scenario == "leave_mid" then
				local leaver = Players:GetPlayers()[2]
				if leaver then
					leaver:SetAttribute("QALeave", true)
					event("asked %s to leave mid-race", leaver.Name)
					waitFor(function()
						return leaver.Parent == nil
					end, 30)
					sample("after-leave")
				end
			end
			local deadline = now() + (tonumber(args.raceTimeout) or 420)
			while now() < deadline do
				if TD.currentKey ~= key then
					break
				end
				task.wait(10)
				sample("race")
			end
			-- Finishing order as each client saw it.
			local ranks, seen, dup = {}, {}, false
			for _, p in Players:GetPlayers() do
				local r = p:GetAttribute("FinishRank")
				ranks[p.Name] = r
				if r ~= nil then
					if seen[r] then
						dup = true
					end
					seen[r] = true
				end
			end
			res.ranks = ranks
			local backInHub = waitFor(function()
				return TD.currentKey == TD.HUB_KEY and not TD.switching
			end, 90)
			task.wait(5)
			sample("end")
			local allVehicles = true
			for _, p in Players:GetPlayers() do
				if vehicleName(p) == "none" then
					allVehicles = false
				end
			end
			local unfinished = {}
			for name, r in ranks do
				if r == nil then
					table.insert(unfinished, name)
				end
			end
			for _, p in Players:GetPlayers() do
				if ranks[p.Name] == nil then
					table.insert(unfinished, p.Name)
				end
			end
			local isLeaveCountdown = scenario == "leave_countdown"
			if not backInHub then
				finish("FAIL", "server did not return to the hub after the race")
			elseif dup then
				finish("FAIL", "two players share a finishing place")
			elseif #unfinished > 0 and scenario ~= "join_mid" then
				finish("FAIL", "players without a finish: " .. table.concat(unfinished, ","))
			elseif not allVehicles then
				finish("FAIL", "a player has no vehicle back in the hub")
			elseif #res.errors > 0 or #res.clientErrors > 0 then
				finish("FAIL", string.format("%d server and %d client errors", #res.errors, #res.clientErrors))
			elseif isLeaveCountdown and not (res.countdown and res.countdown.leftBeforeGo == true) then
				finish("INCONCLUSIVE", "the race ran fine but the leave landed after GO (countdown shorter than the leave): see res.countdown")
			else
				finish("PASS", "race ran, unique places, back in hub with vehicles")
			end
		end, function(e: any)
			-- The handler may not yield; finish waits a second before EndTest.
			task.spawn(finish, "ERROR", tostring(e))
		end)
	end)
end

return QAMultiplayer
