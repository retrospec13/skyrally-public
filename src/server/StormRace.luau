--!strict
-- Storm race v2 (economy v3 phase 5 flow; SKYRALLY_ECONOMY_V3 section 3, owner ruling venue B; docs/design/STORM_RACE_V2.md).
-- Behind StormConfig.RACE_V2 and RaceFlowRules.PER_GROUP (StormRace.boot decides; StormFlowRules.flow):
--   * every 30 min on the UTC clock (:00 / :30) a JOIN window opens StormConfig.FLOW.announceSeconds before the start
--     (client/StormRaceClient shows the popup and the Adventure board row from the attributes below; nobody is pulled,
--     closing or ignoring the popup changes nothing);
--   * JOIN slots the player into a field of 8 in join order (StormFlowRules.join); at the start each field becomes its own
--     RaceInstance (RaceGroups.request, mode "stormrace") on a free track of the cup rotation, bots fill the rest of the
--     field and the storm dragon (BossConfig.STORM, AIRacers roster slot 1) races in every field; only joiners leave the hub;
--   * a JOIN after the start, inside the window, takes a seat in the last field while its grid forms and has room, else a
--     new field opens;
--   * on finish the existing paths pay: Cash (EconomyRules "stormrace"), Storm Shards and the badges (server/StormShards,
--     BadgeAwards; RaceManager sets FinishInfo.beatDragon), the results card, then the group's return to the hub;
--   * the hub: workspace.StormRaceLive while any storm field races (client/HubStorm: storm sky, lightning, thunder, the
--     STORM RACE IN PROGRESS marker with the countdown to the next one).
-- Workspace attributes: StormRaceV2 (this server runs v2), StormRaceEnabled, StormRaceState ("idle" | "open" | "late"),
-- StormRaceSeq (one value per window: the popup shows once per value), StormRaceAt (start, UTC = server time),
-- StormRaceCloseAt, StormRaceTrack (field 1's track), StormRaceJoined (players slotted before the start), StormRaceLive.
-- Remote: SkyRallyRemotes.StormRaceRemote. Client -> server "Join" / "Leave"; server -> client "Joined" {field, n, at,
-- track}, "Left", "Launched" {field, track}, "Refused" {why}.
-- Studio: only with workspace.StormQA = true (a SelfTest playtest is never hijacked at :00 / :30); setting it true also
-- opens a window NOW (a QA slot starting StormQAWindow seconds later, default the announce length, clamped 10-300).
-- The service is pure over Options so tools/tests/storm_flow_spec.luau drives it with a fake clock and fake groups.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StormConfig = require(Shared:WaitForChild("StormConfig"))
local StormFlowRules = require(Shared:WaitForChild("StormFlowRules"))

local StormRace = {}

StormRace.TICK = 0.25
StormRace.REQUEST_GAP = 0.5 -- seconds between one player's Join / Leave requests
local LOG = "[SkyRally][STORM_RACE] "

export type FieldInfo = { trackId: string, state: string, count: number, field: number }

export type Options = {
	now: () -> number, -- UTC seconds (workspace:GetServerTimeNow())
	enabled: () -> boolean,
	period: number?,
	announce: number?,
	late: number?,
	size: number?,
	tracks: { string },
	usable: (trackId: string) -> boolean, -- mounted, and no group races on it
	inHub: (player: Player) -> boolean,
	launch: (players: { Player }, trackId: string) -> string, -- RaceGroups.request: "open" | "join" | "busy" | "refused"
	liveFields: () -> { FieldInfo }, -- live storm groups, oldest first
	send: (player: Player, kind: string, data: any) -> (),
	setAttr: (name: string, value: any) -> (),
	playerById: (userId: number) -> Player?,
	leaveQueue: ((player: Player) -> ())?,
	forceAnnounce: (() -> boolean)?, -- Studio QA: true once = open a window now
	qaWindow: (() -> number)?,
	log: ((string) -> ())?,
}

type Run = {
	slot: StormFlowRules.Slot,
	fields: StormFlowRules.Fields,
	started: boolean,
	launched: { string }, -- track per launched field, in field order
}

export type Service = {
	step: () -> (),
	join: (player: Player) -> string,
	leave: (player: Player, why: string?) -> boolean,
	current: () -> Run?,
}

function StormRace.new(o: Options): Service
	local period = o.period or 1800
	local announce = o.announce or StormConfig.FLOW.announceSeconds
	local late = o.late or StormConfig.FLOW.lateJoinSeconds
	local size = o.size or StormConfig.FLOW.fieldSize
	-- Humans per field: the dragon keeps one seat of every field (StormFlowRules.seats).
	local seats = StormFlowRules.seats(size)
	local log = o.log or function(line: string)
		print(line)
	end
	local cur: Run? = nil
	local lastIndex = -math.huge
	local qaSeq = 0
	local published: { [string]: any } = {}
	local svc = {} :: Service

	local function set(name: string, value: any)
		if published[name] ~= value then
			published[name] = value
			o.setAttr(name, value)
		end
	end

	local function open(slot: StormFlowRules.Slot, t: number)
		cur = { slot = slot, fields = {}, started = t >= slot.startsAt, launched = {} }
		if not slot.forced then
			lastIndex = math.max(lastIndex, slot.index)
		end
		log(string.format("%sopen slot=%d start=%d close=%d%s", LOG, slot.index, slot.startsAt, slot.lateUntil, if slot.forced then " (QA StormQA)" else ""))
	end

	local function takenTracks(run: Run): { [string]: boolean }
		local taken: { [string]: boolean } = {}
		for _, id in run.launched do
			taken[id] = true
		end
		return taken
	end

	-- Launches one field on the next free track; returns the track or nil (players told why).
	local function launchField(run: Run, players: { Player }, fieldNo: number): string?
		local trackId = StormFlowRules.trackFor(run.slot.index, o.tracks, o.usable, takenTracks(run))
		if not trackId then
			for _, p in players do
				o.send(p, "Refused", { why = "full" })
			end
			log(string.format("%sfield %d: no free track for %d player(s)", LOG, fieldNo, #players))
			return nil
		end
		if o.leaveQueue then
			for _, p in players do
				o.leaveQueue(p)
			end
		end
		local res = o.launch(players, trackId)
		if res ~= "open" and res ~= "join" then
			for _, p in players do
				o.send(p, "Refused", { why = res })
			end
			log(string.format("%sfield %d on %s: %s", LOG, fieldNo, trackId, res))
			return nil
		end
		table.insert(run.launched, trackId)
		for _, p in players do
			o.send(p, "Launched", { field = #run.launched, track = trackId })
		end
		log(string.format("%sfield %d on %s: %d player(s), %d bot(s) incl. the storm dragon", LOG, #run.launched, trackId, #players, math.max(0, size - #players)))
		return trackId
	end

	local function start(run: Run)
		run.started = true
		local fields = StormFlowRules.compact(run.fields, seats)
		run.fields = fields
		local humans = 0
		for i, f in fields do
			local players: { Player } = {}
			for _, id in f do
				local p = o.playerById(id)
				if p and o.inHub(p) then
					table.insert(players, p)
				elseif p then
					o.send(p, "Refused", { why = "racing" })
				end
			end
			humans += #players
			if #players > 0 then
				launchField(run, players, i)
			end
		end
		log(string.format("%sstart slot=%d fields=%d players=%d", LOG, run.slot.index, #run.launched, humans))
	end

	function svc.current(): Run?
		return cur
	end

	function svc.step()
		local t = o.now()
		local on = o.enabled()
		if on and o.forceAnnounce and o.forceAnnounce() then
			local run = cur
			if run == nil or run.started then
				qaSeq += 1
				local window = if o.qaWindow then o.qaWindow() else announce
				open(StormFlowRules.qaSlot(t, window, late, qaSeq), t)
			end
		end
		local run = cur
		if run == nil and on then
			local phase, slot = StormFlowRules.phaseAt(t, period, announce, late)
			if phase ~= "idle" and slot.index > lastIndex then
				open(slot, t)
			end
		elseif run and not on and not run.started then
			-- Switched off before the start (live: the Garage hid; Studio: StormQA cleared): the joiners hear it.
			for _, f in run.fields do
				for _, id in f do
					local p = o.playerById(id)
					if p then
						o.send(p, "Refused", { why = "cancelled" })
					end
				end
			end
			log(string.format("%scancel slot=%d (switched off)", LOG, run.slot.index))
			cur = nil
		end
		run = cur
		if run then
			if not run.started and t >= run.slot.startsAt then
				start(run)
			end
			if t >= run.slot.lateUntil then
				log(string.format("%sclose slot=%d fields=%d", LOG, run.slot.index, #run.launched))
				cur = nil
			end
		end
		-- Publish.
		run = cur
		local live = o.liveFields()
		set("StormRaceV2", true)
		set("StormRaceEnabled", on)
		set("StormRaceLive", #live > 0)
		if run then
			set("StormRaceState", if run.started then "late" else "open")
			set("StormRaceSeq", run.slot.index)
			set("StormRaceAt", run.slot.startsAt)
			set("StormRaceCloseAt", run.slot.lateUntil)
			set("StormRaceJoined", if run.started then nil else StormFlowRules.total(run.fields))
			set("StormRaceTrack", run.launched[1] or StormFlowRules.trackFor(run.slot.index, o.tracks, o.usable, {}))
		else
			local _, nxt = StormFlowRules.phaseAt(t, period, announce, late)
			set("StormRaceState", "idle")
			set("StormRaceSeq", nil)
			set("StormRaceAt", nxt.startsAt)
			set("StormRaceCloseAt", nil)
			set("StormRaceJoined", nil)
			set("StormRaceTrack", o.tracks[(nxt.index % math.max(1, #o.tracks)) + 1])
		end
	end

	function svc.join(player: Player): string
		local run = cur
		if run == nil or not o.enabled() then
			o.send(player, "Refused", { why = "closed" })
			return "closed"
		end
		if not o.inHub(player) then
			o.send(player, "Refused", { why = "racing" })
			return "racing"
		end
		if not run.started then
			local field, new = StormFlowRules.join(run.fields, player.UserId, seats)
			if new then
				if o.leaveQueue then
					o.leaveQueue(player)
				end
				log(string.format("%sjoin %s field %d (%d slotted)", LOG, player.Name, field, StormFlowRules.total(run.fields)))
			end
			o.send(player, "Joined", { field = field, n = StormFlowRules.total(run.fields), at = run.slot.startsAt })
			set("StormRaceJoined", StormFlowRules.total(run.fields))
			return if new then "joined" else "already"
		end
		-- Late: the last field while its grid forms and has room, else a new field.
		local lastTrack = run.launched[#run.launched]
		local last: { count: number, open: boolean }? = nil
		if lastTrack then
			for _, f in o.liveFields() do
				if f.trackId == lastTrack then
					last = { count = f.count, open = f.state == "loading" or f.state == "grid" }
				end
			end
		end
		if StormFlowRules.lateJoin(last, seats) == "last" and lastTrack then
			if o.leaveQueue then
				o.leaveQueue(player)
			end
			local res = o.launch({ player }, lastTrack)
			if res == "open" or res == "join" then
				o.send(player, "Launched", { field = #run.launched, track = lastTrack })
				log(string.format("%slate join %s field %d on %s", LOG, player.Name, #run.launched, lastTrack))
				return "late"
			end
		end
		local trackId = launchField(run, { player }, #run.launched + 1)
		return if trackId then "lateNew" else "full"
	end

	function svc.leave(player: Player, why: string?): boolean
		local run = cur
		if run == nil or run.started then
			return false
		end
		local was = StormFlowRules.leave(run.fields, player.UserId)
		if was then
			if player.Parent then
				o.send(player, "Left", { why = why or "leave" })
			end
			set("StormRaceJoined", StormFlowRules.total(run.fields))
			log(string.format("%sleave %s field %d (%s)", LOG, player.Name, was, why or "leave"))
		end
		return was ~= nil
	end

	return svc
end

------------------------------------------------------------------------------------------------------------ live wiring

local defaultService: Service? = nil

-- Decides the storm flow at boot (StormFlowRules.flow) and starts it: "legacy" / "fallback" run the old Storm Cup
-- (fallback warns), "v2" runs the Storm Cup publish-only (schedule + Festival attributes) and this flow. Call once from
-- the server entry script after TrackDirector.init, in place of StormCup.init().
function StormRace.boot(StormCup: any): string
	local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules")) :: any
	local flow = StormFlowRules.flow(StormConfig.RACE_V2 == true, RaceFlowRules.PER_GROUP == true)
	workspace:SetAttribute("StormRaceV2", flow == "v2")
	if flow == "fallback" then
		warn(StormFlowRules.FALLBACK_WARNING)
	end
	if flow ~= "v2" then
		StormCup.init()
		return flow
	end
	StormCup.init({ publishOnly = true })
	StormRace.init()
	return flow
end

function StormRace.init(): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig")) :: any
	local TrackDirector = require(script.Parent.TrackDirector) :: any
	local RaceGroups = require(script.Parent.RaceGroups) :: any
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "SkyRallyRemotes"
		folder.Parent = ReplicatedStorage
	end
	local remote = folder:FindFirstChild("StormRaceRemote") :: RemoteEvent?
	if not remote then
		local r = Instance.new("RemoteEvent")
		r.Name = "StormRaceRemote"
		r.Parent = folder
		remote = r
	end
	local ev = remote :: RemoteEvent
	local studio = RunService:IsStudio()
	local qaPending = studio and workspace:GetAttribute("StormQA") == true
	if studio then
		workspace:GetAttributeChangedSignal("StormQA"):Connect(function()
			if workspace:GetAttribute("StormQA") == true then
				qaPending = true
			end
		end)
	end
	local mode = StormConfig.FLOW.mode
	local svc = StormRace.new({
		now = function(): number
			return workspace:GetServerTimeNow()
		end,
		-- Like the Storm Cup: live with the Garage on (it pays Cash), in Studio only with StormQA.
		enabled = function(): boolean
			if StormConfig.Enabled ~= true then
				return false
			end
			-- T1-5: the "stormcup" kill switch and a closing server stop new storm races (server/LiveOps; fail open).
			local LiveOps = require(script.Parent.LiveOps) :: any
			if not LiveOps.isOn("stormcup") or LiveOps.closing() then
				return false
			end
			if studio then
				return workspace:GetAttribute("StormQA") == true
			end
			return workspace:GetAttribute("GarageEnabled") == true
		end,
		period = MonetizationConfig.STORM_CUP.periodSeconds,
		tracks = MonetizationConfig.STORM_CUP.tracks,
		usable = function(trackId: string): boolean
			return TrackDirector.keyForId(trackId) ~= nil and RaceGroups.trackRaces()[trackId] == nil
		end,
		inHub = function(player: Player): boolean
			return player.Parent ~= nil and RaceGroups.inHub(player)
		end,
		launch = function(players: { Player }, trackId: string): string
			local key = TrackDirector.keyForId(trackId)
			if not key then
				return "refused"
			end
			return RaceGroups.request(players, key, mode, "storm")
		end,
		liveFields = function(): { FieldInfo }
			local out: { FieldInfo } = {}
			for _, g in RaceGroups.liveOf(mode) do
				table.insert(out, { trackId = g.trackId, state = g.state, count = g.count, field = g.field })
			end
			return out
		end,
		send = function(player: Player, kind: string, data: any)
			if player.Parent then
				ev:FireClient(player, kind, data)
			end
		end,
		setAttr = function(name: string, value: any)
			workspace:SetAttribute(name, value)
		end,
		playerById = function(userId: number): Player?
			return Players:GetPlayerByUserId(userId)
		end,
		leaveQueue = function(player: Player)
			if TrackDirector.leaveQueue then
				TrackDirector.leaveQueue(player, "storm race")
			end
		end,
		forceAnnounce = function(): boolean
			if qaPending then
				qaPending = false
				return true
			end
			return false
		end,
		qaWindow = function(): number
			local f = StormConfig.FLOW
			return StormFlowRules.qaWindow(workspace:GetAttribute("StormQAWindow"), f.announceSeconds, f.qaWindowMin, f.qaWindowMax)
		end,
	})
	defaultService = svc
	local last: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	ev.OnServerEvent:Connect(function(player: Player, action: any)
		local now = os.clock()
		if now - (last[player] or -math.huge) < StormRace.REQUEST_GAP then
			return
		end
		last[player] = now
		local ok, err = pcall(function()
			if action == "Join" then
				svc.join(player)
			elseif action == "Leave" then
				svc.leave(player, "leave")
			end
		end)
		if not ok then
			warn(LOG .. "request failed: " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		pcall(svc.leave, p, "left the server")
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < StormRace.TICK then
			return
		end
		acc = 0
		local ok, err = pcall(function(): any
			svc.step()
			return nil
		end)
		if not ok then
			warn(LOG .. "step error: " .. tostring(err))
		end
	end)
	print(string.format("%sinit v2 (per-group storm race, fields of %d, window %d s + %d s late)", LOG, StormConfig.FLOW.fieldSize, StormConfig.FLOW.announceSeconds, StormConfig.FLOW.lateJoinSeconds))
	return svc
end

function StormRace.service(): Service?
	return defaultService
end

return StormRace
