--!strict
-- Storm Cup and Festival schedule (MONETIZATION_PROPOSAL "Storm Cup every 30 minutes" and "Festival window";
-- TEST_LIST_LAUNCH L54). Both run off EconomyRules on the UTC wall clock, so every server (and every client countdown)
-- agrees to the second without MessagingService.
-- * Storm Cup: at :00 and :30 UTC the cup's launch map (rotation in MonetizationConfig.STORM_CUP) loads for the whole
--   server as RaceMode "stormcup" with that cup's modifier and the full bot field. It starts from the hub, or from a
--   finished race once its results have shown for RESULTS_HOLD; it never interrupts a race: a cup that comes due
--   mid-race waits for that race to end, for up to LATE_START, then is skipped. During the lobby minute the hub refuses
--   new races (TrackDirector.holdRequests) so nobody starts a 3-lap race into the cup.
--   Rewards: Economy.raceFinished pays GEARS.stormCup by placement to finishers only and counts first place as a Win Pass
--   win. No Sky Token, no best time (the modifiers change the course, so a cup time is not a track record; RaceManager
--   TIMED_MODES) and no hidden key (KeyPickup.MODES). FLY AGAIN is refused in a cup (it would pay the cup table again).
-- * Modifiers: "night" (a lighting overlay on the map's own profile) and "doubleItemBoxes" (a twin of every item pod a
--   little further down the route; a pod with no safe twin spot respawns twice as fast instead). "mirrored" is NOT
--   built: the track pipeline has no reverse-direction support (checkpoint order, grid, finish arch, one-way ramps and
--   jumps, boost pad facing and the bots' spline all assume one direction), so it is left out of the rotation until
--   it does (MonetizationConfig.STORM_CUP comment).
-- * Festival: the multiplier itself is Economy's (rules.festivalAt at payout time); this module publishes the window
--   for the HUD banner. The golden coin pickup is not built yet (FestivalGoldenCoin is published for it).
-- Workspace attributes (UTC seconds; clients compare with workspace:GetServerTimeNow(), which is epoch time):
--   StormCupEnabled, StormCupState ("idle" | "lobby" | "due" | "running" | "off"), StormCupAt, StormCupIndex,
--   StormCupTrack, StormCupModifier, RaceModifier (the running cup's modifier, nil otherwise; the curtain names it),
--   FestivalActive, FestivalName, FestivalEndsAt, FestivalMultiplier, FestivalGoldenCoin, FestivalNextAt,
--   FestivalNextName.
-- Studio: the cup only fires with workspace.StormCupQA = true (a SelfTest playtest is never hijacked at :00/:30);
-- workspace.StormCupNow = true runs the next cup at once (QA). Live servers always run it.
-- The scheduler is pure over Options so tools/tests/stormcup_spec.luau drives it with fake clocks and fake servers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EconomyRules = require(Shared:WaitForChild("EconomyRules"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local AdminRules = require(Shared:WaitForChild("AdminRules"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))

local StormCup = {}

StormCup.MODE = "stormcup"
StormCup.TICK = 0.25 -- seconds between schedule checks: two servers launch well inside L54's 2 s
StormCup.LATE_START = 600 -- OURS: a cup still starts up to 10 min late (race running, server just booted), then skips
StormCup.RESULTS_HOLD = 8 -- OURS: seconds the results screen shows before a due cup replaces the finished race
StormCup.TWIN_AHEAD = 45 -- OURS: double item boxes put the twin row this far down the route (back if blocked)
StormCup.TWIN_CLEAR = 10 -- a twin keeps this far from every other pod (car pickup radius is 10, plane 14 centre-to-centre)
StormCup.FALLBACK_RESPAWN_SCALE = 0.5 -- a pod with no safe twin spot respawns this much faster instead

-- Night overlay (OURS tuning, unverified on device): moonlit, cool, still readable on a phone. Applied over the map's own
-- profile and only to the keys that profile sets, so the next map's LightingProfiles.apply resets every one of them.
StormCup.NIGHT = {
	ClockTime = 0.5,
	Brightness = 1.1,
	Ambient = Color3.fromRGB(70, 78, 112),
	OutdoorAmbient = Color3.fromRGB(86, 98, 140),
	ColorShift_Top = Color3.fromRGB(150, 170, 230),
	ExposureCompensation = 0.25,
	EnvironmentDiffuseScale = 0.35,
} :: { [string]: any }
StormCup.NIGHT_ATMOSPHERE = { Color = Color3.fromRGB(44, 52, 84), Decay = Color3.fromRGB(22, 26, 52) } :: { [string]: any }

local MODIFIER_LABEL: { [string]: string } = { night = "Night", doubleItemBoxes = "Double items", mirrored = "Mirrored" }
StormCup.MODIFIER_LABEL = MODIFIER_LABEL

export type Cup = {
	index: number,
	startsAt: number,
	trackId: string,
	modifier: string,
	forced: boolean?, -- Studio StormCupNow, or the owner admin's force
	admin: boolean?, -- D22: the owner admin forced this cup with his own map and modifier (never the rotation's slot)
}

-- What the scheduler reads from the server each tick.
export type World = {
	mode: string, -- workspace RaceMode
	switching: boolean, -- TrackDirector is tearing down / building a map
	finishedFor: number?, -- seconds since every player finished the current race; nil while anyone is racing
	players: number,
}

export type Options = {
	rules: EconomyRules.Rules?,
	now: () -> number, -- UTC seconds (fractional is fine)
	enabled: () -> boolean,
	world: () -> World,
	hasTrack: (trackId: string) -> boolean, -- a mounted map exists for this id
	launch: (cup: Cup) -> boolean, -- switch the server to cup.trackId as RaceMode "stormcup"
	setAttr: (name: string, value: any) -> (),
	log: ((string) -> ())?,
	forceNext: (() -> boolean)?, -- Studio QA: true once to run the next cup now
	-- Storm race v2 (StormConfig.RACE_V2 with PER_GROUP; server/StormRace runs the storm race): the schedule and the
	-- Festival are still published (StormCupAt / StormCupTrack for the hub countdown, Festival* for the HUD), but no cup
	-- ever launches, nothing is held and the state never reads "lobby" / "due" / "running".
	publishOnly: boolean?,
	-- RaceFlowRules.PER_GROUP without storm race v2: TrackDirector refuses a whole-server (player-less) launch, so the admin
	-- force is refused up front instead of failing at launch.
	perGroup: boolean?,
}

export type Service = {
	rules: EconomyRules.Rules,
	lastRun: number, -- index of the last cup this server started (or skipped)
	running: Cup?,
	due: (t: number) -> Cup?,
	trackFor: (cup: Cup) -> string?,
	holdReason: (t: number) -> string?,
	step: () -> string?,
	publish: (t: number, w: World, due: Cup?) -> (),
	-- D22 owner admin (server/AdminService calls it after its UserId check): the next cup runs now on this server with this
	-- map and modifier ("none" = no modifier) instead of the rotation's next entry. Returns ok and a short reply.
	forceAdmin: (trackId: string, modifier: string) -> (boolean, string),
}

local function clockText(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end
StormCup.clockText = clockText

function StormCup.new(o: Options): Service
	local rules: EconomyRules.Rules = o.rules or EconomyRules.default
	local sc = rules.cfg.STORM_CUP
	local log = o.log or function(line: string)
		print(line)
	end
	local svc = {} :: Service
	svc.rules = rules
	svc.lastRun = -math.huge
	svc.running = nil
	local forcePending = false
	-- D22: the admin's pick for the forced cup (nil = the Studio StormCupNow path, the rotation's next entry).
	local adminPick: any = nil -- { trackId: string, modifier: string }
	local published: { [string]: any } = {}

	local function set(name: string, value: any)
		if published[name] ~= value then
			published[name] = value
			o.setAttr(name, value)
		end
	end

	-- The cup whose slot has passed and has not run here yet, while it may still start.
	function svc.due(t: number): Cup?
		if not o.enabled() then
			return nil
		end
		local cur = rules.stormCupCurrent(t)
		if cur.index > svc.lastRun and t - cur.startsAt < StormCup.LATE_START then
			return { index = cur.index, startsAt = cur.startsAt, trackId = cur.trackId, modifier = cur.modifier }
		end
		return nil
	end

	-- The cup's map, or the next mounted one in rotation order (same answer on every server with the same build).
	function svc.trackFor(cup: Cup): string?
		local n = #sc.tracks
		for i = 0, n - 1 do
			local id = sc.tracks[((cup.index + i) % n) + 1]
			if o.hasTrack(id) then
				return id
			end
		end
		return nil
	end

	-- Why the hub refuses a new race right now: the lobby minute before a cup, or a cup that is due.
	function svc.holdReason(t: number): string?
		if not o.enabled() or o.publishOnly then
			return nil
		end
		if svc.due(t) then
			return "Storm Cup is starting"
		end
		local nextCup = rules.stormCupNext(t)
		if t >= nextCup.lobbyOpensAt then
			return "Storm Cup starts in " .. clockText(nextCup.startsAt - t)
		end
		return nil
	end

	function svc.publish(t: number, w: World, due: Cup?)
		local enabled = o.enabled()
		set("StormCupEnabled", enabled)
		local shown: Cup
		local state: string
		if due then
			shown = due
			state = "due"
		else
			local n = rules.stormCupNext(t)
			shown = { index = n.index, startsAt = n.startsAt, trackId = n.trackId, modifier = n.modifier }
			state = if not enabled then "off"
				elseif o.publishOnly then "idle"
				elseif w.mode == StormCup.MODE then "running"
				elseif t >= n.lobbyOpensAt then "lobby"
				else "idle"
		end
		set("StormCupState", state)
		set("StormCupAt", shown.startsAt)
		set("StormCupIndex", shown.index)
		set("StormCupTrack", svc.trackFor(shown) or shown.trackId)
		set("StormCupModifier", shown.modifier)

		local fest = rules.festivalAt(t)
		set("FestivalActive", fest ~= nil)
		set("FestivalName", if fest then fest.name else nil)
		set("FestivalEndsAt", if fest then fest.endsAt else nil)
		set("FestivalMultiplier", if fest then fest.multiplier else nil)
		set("FestivalGoldenCoin", if fest then fest.goldenCoin else nil)
		local nextFest = rules.festivalNext(t)
		set("FestivalNextAt", if nextFest then nextFest.startsAt else nil)
		set("FestivalNextName", if nextFest then nextFest.name else nil)
	end

	local function adminLog(result: string, detail: string)
		log(string.format("%s action=storm result=%s %s", AdminRules.LOG, result, detail))
	end

	function svc.forceAdmin(trackId: string, modifier: string): (boolean, string)
		if o.publishOnly then
			return false, "storm race v2 runs the storm on this server"
		end
		if o.perGroup then
			return false, "per-group races: no whole-server cup on this server"
		end
		if not o.enabled() then
			return false, "Storm Cup is off on this server"
		end
		if type(trackId) ~= "string" or not table.find(sc.tracks, trackId) then
			return false, "not a cup map"
		end
		if modifier ~= "none" and not table.find(sc.modifiers, modifier) then
			return false, "not a cup modifier"
		end
		if not o.hasTrack(trackId) then
			return false, trackId .. " is not on this server"
		end
		adminPick = { trackId = trackId, modifier = modifier }
		forcePending = true
		log(string.format("[SkyRally][STORM] admin force queued track=%s modifier=%s", trackId, modifier))
		return true, "queued"
	end

	-- One schedule check. Returns what happened ("launched", "waiting", "skipped", "failed") or nil when no cup is due.
	function svc.step(): string?
		local t = o.now()
		local w = o.world()
		if o.forceNext and o.forceNext() then
			forcePending = true
		end
		if o.publishOnly then
			svc.publish(t, w, nil)
			return nil
		end
		local cup = svc.due(t)
		if not cup and forcePending then
			local n = rules.stormCupNext(t)
			cup = { index = n.index, startsAt = n.startsAt, trackId = n.trackId, modifier = n.modifier, forced = true }
			local pick = adminPick
			if pick and not o.enabled() then
				-- D22: the cup was switched off after the force; the admin's cup is dropped, never run while it is off.
				adminPick = nil
				forcePending = false
				adminLog("dropped", string.format("track=%s modifier=%s (Storm Cup off)", pick.trackId, pick.modifier))
				svc.publish(t, w, nil)
				return "skipped"
			end
			if pick then
				-- D22: the admin's map and modifier; the slot's own cup still runs at :00/:30 (lastRun is not moved).
				cup = { index = n.index, startsAt = n.startsAt, trackId = pick.trackId, modifier = pick.modifier, forced = true, admin = true }
			end
		end
		svc.publish(t, w, if cup and not cup.forced then cup else nil)
		if not cup then
			return nil
		end
		-- Never interrupt a race: start from the hub, or once everyone has finished and seen the results.
		local ready = w.mode == "hub" or (w.finishedFor ~= nil and w.finishedFor >= StormCup.RESULTS_HOLD)
		if w.switching or w.players < 1 or not ready then
			return "waiting"
		end
		forcePending = false
		if cup.admin then
			adminPick = nil
		else
			svc.lastRun = math.max(svc.lastRun, cup.index)
			local pending = adminPick
			if pending then
				-- D22: a scheduled cup came due first; the admin's queued cup stays pending and runs after it.
				forcePending = true
				adminLog("deferred", string.format("track=%s modifier=%s (scheduled cup=%d runs first)", pending.trackId, pending.modifier, cup.index))
			end
		end
		local trackId = if cup.admin then (if o.hasTrack(cup.trackId) then cup.trackId else nil) else svc.trackFor(cup)
		if not trackId then
			log(string.format("[SkyRally][STORM] skip cup=%d: no mounted map in the rotation", cup.index))
			if cup.admin then
				adminLog("failed", string.format("track=%s modifier=%s (map not mounted)", cup.trackId, cup.modifier))
			end
			return "skipped"
		end
		local run: Cup = { index = cup.index, startsAt = cup.startsAt, trackId = trackId, modifier = cup.modifier, forced = cup.forced, admin = cup.admin }
		if not o.launch(run) then
			log(string.format("[SkyRally][STORM] launch failed cup=%d track=%s", cup.index, trackId))
			if run.admin then
				adminLog("failed", string.format("track=%s modifier=%s (launch refused)", trackId, run.modifier))
			end
			return "failed"
		end
		svc.running = run
		log(string.format(
			"[SkyRally][STORM] launch cup=%d track=%s modifier=%s slot=%d late=%.2fs from=%s players=%d%s",
			run.index,
			trackId,
			run.modifier,
			run.startsAt,
			t - run.startsAt,
			w.mode,
			w.players,
			if run.admin then " (admin force)" elseif run.forced then " (QA StormCupNow)" else ""
		))
		return "launched"
	end

	return svc
end

------------------------------------------------------------------------------------------------ double item boxes

export type PodIn = { name: string, pos: Vector3, item: boolean }
export type Spline = {
	project: (pos: Vector3) -> number, -- station
	sample: (station: number) -> (Vector3, Vector3), -- position, tangent
}
export type TwinPlan = { name: string, offset: Vector3? } -- offset nil: no safe twin spot, respawn faster instead

local UP = Vector3.new(0, 1, 0)
local function rightOf(tan: Vector3): Vector3
	local r = tan:Cross(UP)
	return if r.Magnitude > 0.01 then r.Unit else Vector3.new(1, 0, 0)
end

-- Where each item pod's twin goes: the same lateral offset and height over the route TWIN_AHEAD further on (or back),
-- clear of every pod and twin. A pod beyond `halfWidth` of the main line (an alternate route) gets no twin.
function StormCup.planTwins(pods: { PodIn }, spline: Spline, halfWidth: number): { TwinPlan }
	local taken: { Vector3 } = {}
	for _, p in pods do
		table.insert(taken, p.pos)
	end
	local function clear(pos: Vector3): boolean
		for _, q in taken do
			if (q - pos).Magnitude < StormCup.TWIN_CLEAR then
				return false
			end
		end
		return true
	end
	local out: { TwinPlan } = {}
	for _, p in pods do
		if p.item then
			local st = spline.project(p.pos)
			local p0, tan0 = spline.sample(st)
			local rel = p.pos - p0
			local lateral = rel:Dot(rightOf(tan0))
			local offset: Vector3? = nil
			if math.abs(lateral) <= halfWidth then
				for _, d in { StormCup.TWIN_AHEAD, -StormCup.TWIN_AHEAD } do
					local p1, tan1 = spline.sample(st + d)
					local cand = p1 + rightOf(tan1) * lateral + Vector3.new(0, rel.Y, 0)
					-- A sample that did not move (the spline is missing or ends here) is no place for a twin.
					if (cand - p.pos).Magnitude >= StormCup.TWIN_AHEAD * 0.5 and clear(cand) then
						offset = cand - p.pos
						table.insert(taken, cand)
						break
					end
				end
			end
			table.insert(out, { name = p.name, offset = offset })
		end
	end
	return out
end

-- Route half-width a twin may sit in: the car deck, or the plane's flight corridor (TrackData, MAP_PLAN_SCHEMA).
function StormCup.halfWidthOf(td: any): number
	if type(td) ~= "table" then
		return 0
	end
	if td.vehicle == "car" and type(td.deck) == "table" and type(td.deck.width) == "number" then
		return td.deck.width * 0.5 - 3
	end
	local corridor = type(td.flight) == "table" and td.flight.corridor
	local hw = if type(corridor) == "table" and type(corridor.halfWidth) == "number" then corridor.halfWidth else 34
	return hw - 4
end

------------------------------------------------------------------------------------------------ live wiring

local defaultService: Service? = nil
local liveNow = function(): number
	-- TG-6: the real UTC in a live server; Studio's workspace.QAUtcAt moves it (server/QAClock).
	return (require(script.Parent.QAClock) :: any).now()
end

-- Night: the overlay over the keys the map's own profile set (MapAdapter applied it in this load).
local function applyNight(td: any)
	local Lighting = game:GetService("Lighting")
	local LightingProfiles = require(Shared:WaitForChild("LightingProfiles")) :: any
	local profile = LightingProfiles.get(td.lighting or td.id)
	if not profile then
		print(string.format("[SkyRally][STORM] night skipped: no lighting profile for %s", tostring(td.id)))
		return
	end
	local n = 0
	for _, pair in profile.lighting do
		local value = StormCup.NIGHT[pair[1]]
		if value ~= nil then
			local ok = pcall(function()
				(Lighting :: any)[pair[1]] = value
			end)
			n += if ok then 1 else 0
		end
	end
	local atmosphere = Lighting:FindFirstChild("SkyRally_Atmosphere")
	if atmosphere then
		for k, v in StormCup.NIGHT_ATMOSPHERE do
			pcall(function()
				(atmosphere :: any)[k] = v
			end)
		end
	end
	print(string.format("[SkyRally][STORM] night on %s (%d lighting keys)", tostring(td.id), n))
end

-- Double item boxes: a twin of every item pod (same RaceManager/ItemService contract: a direct child of Boosts with its
-- own name, ItemPodSpawn and the <name>_CoreVisual child), placed before RaceManager and the bots scan the folder.
local function doubleItemBoxes(td: any)
	local TrackRegistry = require(Shared:WaitForChild("TrackRegistry")) :: any
	local SplineUtils = require(Shared:WaitForChild("SplineUtils")) :: any
	local boosts = TrackRegistry.getBoostsFolder()
	if not boosts then
		print("[SkyRally][STORM] double item boxes skipped: no Boosts folder")
		return
	end
	SplineUtils.loadWaypoints(true) -- this map's spline (RaceManager.onTrackChanged reloads it again right after)
	local pods: { PodIn } = {}
	local parts: { [string]: BasePart } = {}
	for _, c in boosts:GetChildren() do
		if c:IsA("BasePart") and c:GetAttribute("ItemPodSpawn") == true then
			table.insert(pods, { name = c.Name, pos = c.Position, item = ItemRules.classifyPod(c:GetAttribute("PodType")) == "item" })
			parts[c.Name] = c
		end
	end
	local plan = StormCup.planTwins(pods, {
		project = function(pos: Vector3): number
			return (SplineUtils.projectPosition(pos))
		end,
		sample = function(station: number): (Vector3, Vector3)
			local pos, tan = SplineUtils.sampleAtStation(station)
			return pos, tan
		end,
	}, StormCup.halfWidthOf(td))
	local twins, faster = 0, 0
	for _, entry in plan do
		local pod = parts[entry.name]
		local offset = entry.offset
		if pod and offset then
			local twinName = entry.name .. "_StormTwin"
			local twin = pod:Clone() :: BasePart
			twin.Name = twinName
			for _, d in twin:GetDescendants() do
				if string.sub(d.Name, 1, #entry.name) == entry.name then
					d.Name = twinName .. string.sub(d.Name, #entry.name + 1)
				end
			end
			twin.CFrame = twin.CFrame + offset
			for _, d in twin:GetDescendants() do
				if d:IsA("BasePart") then
					d.CFrame = d.CFrame + offset
				end
			end
			twin:SetAttribute("OnCooldown", false)
			twin:SetAttribute("StormCupTwin", true)
			twin.Parent = boosts
			twins += 1
		elseif pod then
			local respawn = pod:GetAttribute("RespawnSeconds")
			pod:SetAttribute("RespawnSeconds", (if type(respawn) == "number" then respawn else 4) * StormCup.FALLBACK_RESPAWN_SCALE)
			faster += 1
		end
	end
	print(string.format("[SkyRally][STORM] double item boxes on %s: %d twins, %d faster respawns", tostring(td.id), twins, faster))
end

-- TrackDirector hook (Hooks.prepareMode): after the map is built, before RaceManager and the bots read it.
function StormCup.prepareMode(mode: string, td: any)
	if mode ~= StormCup.MODE then
		workspace:SetAttribute("RaceModifier", nil)
		return
	end
	local svc = defaultService
	local modifier = (if svc and svc.running then svc.running.modifier else nil) or workspace:GetAttribute("RaceModifier")
	if modifier == "none" then
		modifier = nil -- D22: an admin cup with no modifier (the curtain then reads STORM)
	end
	workspace:SetAttribute("RaceModifier", modifier)
	if modifier == "night" then
		applyNight(td)
	elseif modifier == "doubleItemBoxes" then
		doubleItemBoxes(td)
	end
end

-- Why a new race (board, portal, FLY AGAIN) must wait right now, or nil.
function StormCup.holdReason(): string?
	local svc = defaultService
	return if svc then svc.holdReason(liveNow()) else nil
end

-- Wires the scheduler to TrackDirector and starts the tick. Call once from the server entry script after
-- TrackDirector.init. opts.publishOnly: storm race v2 is live (see Options.publishOnly): publish, never launch or hold.
function StormCup.init(opts: { publishOnly: boolean? }?): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local TrackDirector = require(script.Parent.TrackDirector) :: any
	local svc = StormCup.new({
		now = liveNow,
		-- The cup pays Gears and Win Pass progress, both hidden while the economy is off (MonetizationConfig.Enabled):
		-- it runs only with the Garage on, or in Studio with StormCupQA.
		enabled = function(): boolean
			-- T1-5: the "stormcup" kill switch and a closing server stop new cups (server/LiveOps; fail open).
			local LiveOps = require(script.Parent.LiveOps) :: any
			if not LiveOps.isOn("stormcup") or LiveOps.closing() then
				return false
			end
			if RunService:IsStudio() then
				return workspace:GetAttribute("StormCupQA") == true
			end
			return workspace:GetAttribute("GarageEnabled") == true
		end,
		world = function(): World
			local mode = workspace:GetAttribute("RaceMode")
			local doneAt = TrackDirector.allFinishedAt
			return {
				mode = if type(mode) == "string" and mode ~= "" then mode else "race",
				switching = TrackDirector.switching == true,
				finishedFor = if type(doneAt) == "number" then os.clock() - doneAt else nil,
				players = #Players:GetPlayers(),
			}
		end,
		hasTrack = function(trackId: string): boolean
			return TrackDirector.keyForId(trackId) ~= nil
		end,
		launch = function(cup: Cup): boolean
			local key = TrackDirector.keyForId(cup.trackId)
			if not key then
				return false
			end
			-- Set before the switch so the curtain names the modifier; prepareMode keeps or clears it.
			workspace:SetAttribute("RaceModifier", if cup.modifier == "none" then nil else cup.modifier)
			return TrackDirector.requestRace(nil, key, "storm cup " .. cup.index, StormCup.MODE)
		end,
		setAttr = function(name: string, value: any)
			workspace:SetAttribute(name, value)
		end,
		publishOnly = opts ~= nil and opts.publishOnly == true,
		perGroup = RaceFlowRules.PER_GROUP == true,
		forceNext = function(): boolean
			if RunService:IsStudio() and workspace:GetAttribute("StormCupNow") == true then
				workspace:SetAttribute("StormCupNow", nil)
				return true
			end
			return false
		end,
	})
	defaultService = svc
	if not (opts and opts.publishOnly) then
		TrackDirector.holdRequests = StormCup.holdReason
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < StormCup.TICK then
			return
		end
		acc = 0
		local ok, err = pcall(svc.step)
		if not ok then
			warn("[SkyRally][STORM] step error: " .. tostring(err))
		end
	end)
	print(string.format("[SkyRally][STORM] init enabled=%s next=%d", tostring(if RunService:IsStudio() then workspace:GetAttribute("StormCupQA") == true else workspace:GetAttribute("GarageEnabled") == true), svc.rules.stormCupNext(liveNow()).startsAt))
	return svc
end

-- D22 owner admin: force the next cup on this live server (server/AdminService, after its UserId check).
function StormCup.adminForce(trackId: string, modifier: string): (boolean, string)
	local svc = defaultService
	if not svc then
		return false, "Storm Cup is not running on this server"
	end
	return svc.forceAdmin(trackId, modifier)
end

function StormCup.service(): Service?
	return defaultService
end

return StormCup
