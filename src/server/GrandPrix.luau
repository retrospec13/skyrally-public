--!strict
-- Grand Prix (v37): a cup of the player's unlocked race tracks raced back to back (shared/GrandPrixRules has every
-- number). Solo with a full bot field on the single-race path (RaceFlowRules.PER_GROUP false): a cup starts only when
-- its player is the one human on the server; someone joining mid-cup races along but scores nothing and cannot end it.
--
-- Flow: START (GrandPrixRemote) -> race 1 loads through TrackDirector.requestRace (the normal admit: Storm Cup hold,
-- unlock check). Every race is a standard 3-lap "race" (tokens, best times and the race's own Cash as usual). At the
-- race end TrackDirector hands over (TrackDirector.grandPrix): the race is scored from RaceManager.standings(), the
-- standings go to the client ("Standings"), and after HOLD (or CONTINUE) the next track loads with the same bot roster
-- (AIRacers.namePins) and class tuning (AIRacers.classTune). After the last race the trophy and the cup bonus are saved
-- at once (SaveService.edit grandPrix, Economy.earn "grandprix", not multiplied), the final standings and trophy go to
-- the client, and after FINAL_HOLD (or CONTINUE) the server returns to the hub.
-- QUIT (GrandPrixRemote, or HUB on the results card) ends the cup and goes to the hub; leaving the server ends it. Neither
-- pays the cup bonus. A load that lands anywhere but the cup's next track (a load failure's hub fallback) ends the cup.
-- Workspace attributes (clients): GPActive, GPClass, GPRace, GPRaces, GPTracks ("DINO-4,SNOW-1,..."), GPNextAt (server
-- time of the next step while a race end holds), GPFinal (the hold before the hub).
-- Studio QA: workspace QAGPDnf = true marks the cup's player DNF at once (the DNF path without waiting for the field).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GrandPrixRules = require(Shared:WaitForChild("GrandPrixRules"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr")) -- single-race path: the workspace values

local GrandPrix = {}

local LOG = "[SkyRally][GP] "

type Cup = {
	player: Player,
	class: string,
	tracks: { string }, -- track ids in race order
	index: number, -- the race now (1-based)
	rows: { [string]: GrandPrixRules.Row },
	ended: boolean, -- this race has been scored
	final: boolean, -- the last race has been scored (trophy saved)
	quitting: boolean,
	finishes: number, -- races the player crossed the line in
}

local cup: Cup? = nil
local remote: RemoteEvent? = nil
local deps: any = nil

local function log(fmt: string, ...: any)
	print(LOG .. string.format(fmt, ...))
end

local function send(player: Player, kind: string, data: any)
	local r = remote
	if r and player.Parent then
		r:FireClient(player, kind, data)
	end
end

local function publish()
	local c = cup
	workspace:SetAttribute("GPActive", if c then true else nil)
	workspace:SetAttribute("GPClass", if c then c.class else nil)
	workspace:SetAttribute("GPRace", if c then c.index else nil)
	workspace:SetAttribute("GPRaces", if c then #c.tracks else nil)
	workspace:SetAttribute("GPTracks", if c then table.concat(c.tracks, ",") else nil)
	workspace:SetAttribute("GPOwner", if c then c.player.UserId else nil)
	if not c then
		workspace:SetAttribute("GPNextAt", nil)
		workspace:SetAttribute("GPFinal", nil)
	end
end

local function finish(why: string)
	local c = cup
	if not c then
		return
	end
	cup = nil
	deps.AIRacers.classTune = nil
	deps.AIRacers.namePins = nil
	publish()
	log("end user=%d class=%s race=%d/%d why=%s", c.player.UserId, c.class, c.index, #c.tracks, why)
end

function GrandPrix.active(): boolean
	return cup ~= nil
end

-- The race tracks this player may race now, in zone order (the server's own unlock check).
local function openTracks(player: Player): { string }
	local TD = deps.TrackDirector
	local open: { [string]: boolean } = {}
	for _, id in GrandPrixRules.TRACKS do
		local key = TD.keyForId(id)
		if key and (TD.canOpen(player, key, "race")) then
			open[id] = true
		end
	end
	return GrandPrixRules.openTracks(open)
end

local function recordOf(player: Player): GrandPrixRules.Record
	local profile = deps.SaveService.get(player)
	return GrandPrixRules.read(if profile then profile.grandPrix else nil)
end

local function refuse(player: Player, why: string)
	send(player, "Refused", { why = why })
	log("start refused user=%d: %s", player.UserId, why)
end

function GrandPrix.start(player: Player, class: any, length: any): boolean
	local TD = deps.TrackDirector
	if cup then
		refuse(player, "A Grand Prix is already running")
		return false
	end
	if RaceFlowRules.PER_GROUP then
		refuse(player, "Grand Prix is not available on this server yet")
		return false
	end
	if TD.switching or RaceAttr.here("RaceMode") ~= "hub" then
		refuse(player, "Start a Grand Prix from Central Island")
		return false
	end
	if #Players:GetPlayers() > 1 then
		refuse(player, "Grand Prix is solo for now: other racers are on this server")
		return false
	end
	if not GrandPrixRules.isClass(class) then
		return false
	end
	if not deps.SaveService.get(player) then
		refuse(player, "Your progress is still loading")
		return false
	end
	if not GrandPrixRules.classOpen(recordOf(player), class) then
		refuse(player, GrandPrixRules.LABEL[class] .. " is locked: " .. GrandPrixRules.lockLine(class))
		return false
	end
	local open = openTracks(player)
	local tracks = GrandPrixRules.pickTracks(open, if length == "short" then "short" else "full", math.random)
	if not tracks then
		refuse(player, string.format("Open %d race tracks first (%d open)", GrandPrixRules.MIN_TRACKS, #open))
		return false
	end
	local key = TD.keyForId(tracks[1])
	if not key then
		return false
	end
	cup = {
		player = player,
		class = class,
		tracks = tracks,
		index = 1,
		rows = {},
		ended = false,
		final = false,
		quitting = false,
		finishes = 0,
	}
	deps.AIRacers.classTune = GrandPrixRules.TUNE[class]
	deps.AIRacers.namePins = {}
	publish()
	if not TD.requestRace(player, key, "grand prix", "race") then
		finish("start refused by the director")
		return false
	end
	log("start user=%d class=%s tracks=%s", player.UserId, class, table.concat(tracks, ","))
	return true
end

-- This race's entries for the cup: the cup's player and the bots, in race order (other humans left out, places closed up).
local function raceEntries(c: Cup): { GrandPrixRules.Entry }
	local out: { GrandPrixRules.Entry } = {}
	local dnfRow: GrandPrixRules.Entry? = nil
	local rec = deps.FlightServer.records[c.player]
	for _, e in deps.RaceManager.standings() do
		local botId = string.match(tostring(e.racerId), "^bot:(%d+)$")
		if botId then
			table.insert(out, { key = "b" .. botId, name = e.name, human = false, place = 0, dnf = false })
		elseif e.racerId == "player:" .. tostring(c.player.UserId) then
			local dnf = rec == nil or rec.dnf == true or not e.finished
			local row = { key = "u" .. tostring(c.player.UserId), name = c.player.DisplayName, human = true, place = 0, dnf = dnf }
			if dnf then
				dnfRow = row
			else
				table.insert(out, row)
			end
		end
	end
	if dnfRow then
		table.insert(out, dnfRow)
	end
	for i, e in out do
		e.place = i
	end
	return out
end

local function rowsPayload(c: Cup, list: { GrandPrixRules.Row }): { any }
	local out = {}
	local me = "u" .. tostring(c.player.UserId)
	for _, r in list do
		table.insert(out, {
			name = r.name,
			me = r.key == me,
			total = r.total,
			gained = r.gained,
			place = r.place,
			rank = r.rank,
			prevRank = r.prevRank,
			dnf = r.dnf,
		})
	end
	return out
end

-- The cup's end: trophy and points saved, the bonus paid. Never yields (edit and earn queue their writes).
local function award(c: Cup, myRank: number, myPoints: number): any
	local trophy = GrandPrixRules.trophyFor(myRank)
	local races = #c.tracks
	local opened: { string } = {}
	local before = recordOf(c.player)
	local ok = deps.SaveService.edit(c.player, "grandprix:" .. c.class, function(draft: any)
		local rec, newly = GrandPrixRules.record(draft.grandPrix, c.class, trophy, myPoints)
		draft.grandPrix = rec
		opened = newly
	end)
	local amount = GrandPrixRules.payout(c.class, myRank, races, c.finishes)
	local paid = 0
	local svc = deps.Economy.service()
	if ok and svc and amount > 0 then
		paid = svc.earn(c.player, "grandprix", amount, { txType = "Gameplay", sku = "grandprix_" .. c.class })
	end
	log(
		"award user=%d class=%s rank=%d points=%d finishes=%d trophy=%s best=%s saved=%s cash=%d/%d opened=%s",
		c.player.UserId,
		c.class,
		myRank,
		myPoints,
		c.finishes,
		GrandPrixRules.TROPHY[trophy],
		GrandPrixRules.TROPHY[before.best[c.class] or 0],
		tostring(ok),
		paid,
		amount,
		table.concat(opened, ",")
	)
	return {
		trophy = trophy,
		newBest = trophy > (before.best[c.class] or 0),
		bestPoints = math.max(myPoints, before.points[c.class] or 0),
		cash = paid,
		opened = opened,
		saved = ok,
	}
end

-- TrackDirector: every human is done (or the field finished with the cup's player idle): score the race.
function GrandPrix.raceEnded(): number
	local c = cup
	if not c then
		return 22
	end
	if c.ended then
		return GrandPrixRules.HOLD
	end
	c.ended = true
	local entries = raceEntries(c)
	for _, e in entries do
		if e.human and not e.dnf then
			c.finishes += 1
		end
	end
	local list = GrandPrixRules.apply(c.rows, entries)
	table.clear(c.rows)
	local myRank, myPoints = 0, 0
	for _, r in list do
		c.rows[r.key] = r
		if r.key == "u" .. tostring(c.player.UserId) then
			myRank, myPoints = r.rank, r.total
		end
	end
	local last = c.index >= #c.tracks
	local hold = if last then GrandPrixRules.FINAL_HOLD else GrandPrixRules.HOLD
	local payload: any = {
		race = c.index,
		races = #c.tracks,
		class = c.class,
		trackId = c.tracks[c.index],
		nextId = if last then nil else c.tracks[c.index + 1],
		rows = rowsPayload(c, list),
		final = last,
	}
	if last then
		c.final = true
		payload.result = award(c, myRank, myPoints)
		payload.result.rank = myRank
		payload.result.points = myPoints
		workspace:SetAttribute("GPFinal", true)
	end
	workspace:SetAttribute("GPNextAt", workspace:GetServerTimeNow() + hold)
	send(c.player, "Standings", payload)
	local parts = {}
	for _, e in entries do
		table.insert(parts, string.format("%d:%s%s", e.place, e.name, if e.dnf then "(DNF)" else ""))
	end
	log("race %d/%d %s scored: %s | you rank=%d total=%d", c.index, #c.tracks, tostring(c.tracks[c.index]), table.concat(parts, " "), myRank, myPoints)
	return hold
end

-- TrackDirector: the race end's hold ran out: the next track, or the hub after the last.
function GrandPrix.due()
	local c = cup
	if not c then
		return
	end
	local TD = deps.TrackDirector
	if c.final or c.quitting then
		finish(if c.final then "complete" else "quit")
		TD.returnToHub("grand prix over")
		return
	end
	c.index += 1
	c.ended = false
	local key = TD.keyForId(c.tracks[c.index])
	workspace:SetAttribute("GPNextAt", nil)
	publish()
	if not key or not TD.requestRace(nil, key, "grand prix race " .. c.index, "race") then
		finish("next track refused")
		TD.returnToHub("grand prix: next track refused")
	end
end

local function quit(player: Player): string
	local c = cup
	if not c or c.player ~= player then
		return "refused"
	end
	if c.final then
		-- The cup is complete and paid: QUIT / HUB now is just the trip home.
		deps.TrackDirector.raceEndIn(0.5)
		return "done"
	end
	finish("quit")
	deps.TrackDirector.returnToHub("grand prix quit")
	return "done"
end

-- TrackDirector.requestExit while a cup runs: no FLY AGAIN; HUB from the cup's player quits the cup.
function GrandPrix.exit(player: Player, choice: string): string
	if choice == "hub" then
		return quit(player)
	end
	send(player, "Refused", { why = "No replays in a Grand Prix" })
	return "refused"
end

local function continue(player: Player)
	local c = cup
	if not c or c.player ~= player or not c.ended then
		return
	end
	local secs = if c.final then 0.5 else GrandPrixRules.NEXT_CARD
	if deps.TrackDirector.raceEndIn(secs) then
		local at = workspace:GetServerTimeNow() + secs
		local cur = workspace:GetAttribute("GPNextAt")
		if type(cur) ~= "number" or at < cur then
			workspace:SetAttribute("GPNextAt", at)
		end
	end
end

-- A load that is not the cup's current track (the hub fallback after a failed build, an admin command) ends the cup.
local function checkTrack()
	local c = cup
	if not c or deps.TrackDirector.switching then
		return
	end
	local mode = RaceAttr.here("RaceMode")
	local id = RaceAttr.here("ActiveTrackId")
	if mode ~= "race" or id ~= c.tracks[c.index] then
		finish(string.format("left the cup's track (mode=%s track=%s)", tostring(mode), tostring(id)))
	end
end

function GrandPrix.init(d: any)
	deps = d
	local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes")
	local r = remotes:FindFirstChild("GrandPrixRemote") :: RemoteEvent?
	if not r then
		local nr = Instance.new("RemoteEvent")
		nr.Name = "GrandPrixRemote"
		nr.Parent = remotes
		r = nr
	end
	remote = r
	local last: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	(r :: RemoteEvent).OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any)
		local now = os.clock()
		if now - (last[player] or 0) < 0.75 then
			return
		end
		last[player] = now
		if action == "Start" then
			GrandPrix.start(player, a, b)
		elseif action == "Continue" then
			continue(player)
		elseif action == "Quit" then
			quit(player)
		end
	end)
	d.TrackDirector.grandPrix = {
		active = GrandPrix.active,
		raceEnded = GrandPrix.raceEnded,
		due = GrandPrix.due,
		exit = GrandPrix.exit,
	}
	Players.PlayerRemoving:Connect(function(p: Player)
		local c = cup
		if c and c.player == p then
			finish("player left")
		end
	end)
	-- The director's switching flag drops after every load: check the cup is where it should be (0.5 s; cheap).
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		checkTrack()
		local c = cup
		if c and RunService:IsStudio() and workspace:GetAttribute("QAGPDnf") == true then
			workspace:SetAttribute("QAGPDnf", nil)
			log("QA: %s marked DNF", c.player.Name)
			deps.RaceManager.markDnf(c.player)
		end
	end)
	log("init")
end

return GrandPrix
