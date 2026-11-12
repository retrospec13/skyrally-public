--!strict
-- First-session guide and analytics funnels (TEST_LIST_LAUNCH L27; audit B5 and M3). Pure: no Instances, no clock, specced
-- in tools/tests/onboarding_spec.luau. Shared by client/Onboarding (what to say, when, where the arrow points) and
-- server/Funnels (which funnel step an event is, deduped per player). The words are short and kid-friendly and are
-- written for 740x360; the control words follow the active input family (client/InputMode: Touch, Gamepad, KeyboardMouse).
local OnboardingRules = {}

export type Family = "Touch" | "Gamepad" | "KeyboardMouse"
export type Vehicle = "car" | "plane"
export type Tip = { title: string, body: string }

------------------------------------------------------------------------------------------------------------------------
-- Guide: words
------------------------------------------------------------------------------------------------------------------------

OnboardingRules.FLAG = "onboarded" -- profile.settings key (SaveService.markOnboarded); replicated as player attribute Onboarded
OnboardingRules.GOAL_TITLE = "WELCOME, RACER!"
OnboardingRules.GOAL_TEXT = "Win races, earn Sky Tokens, open new worlds!"
OnboardingRules.PORTAL_TEXT = "Press RACE or drive into a portal."
OnboardingRules.TIP_IDS = { "item", "boost", "drift", "lap" } :: { string }
OnboardingRules.TIP_SECONDS = 6 -- a tip leaves by itself after this long
OnboardingRules.TIP_MIN_SECONDS = 1.2 -- ... and input dismisses it, but never before this (a held button must not eat it)
OnboardingRules.GOAL_SECONDS = 25
OnboardingRules.READY_WAIT = 25 -- seconds the client waits for the saved flag before it gives up on a guide
OnboardingRules.ARROW_HIDE_DIST = 30 -- studs from the portal: the ground arrow has done its job
OnboardingRules.MOVE_DIST = 10 -- studs from the first spawn point that count as "first move"
OnboardingRules.ARRIVE_TEXT = "Drive in!" -- the goal card's last line once the car is in the landing ring
-- The definitive end (docs/design/GUIDE_ARROW.md 4.2): the arrow lands in a ground ring in front of the portal veil.
OnboardingRules.RING_BACK = 14 -- studs on the plaza side of the veil that the ring is centred
OnboardingRules.RING_RADIUS = 12 -- the ring is 24 wide, like the veil (PortalRules.HALF_WIDTH)
OnboardingRules.ARRIVE_RADIUS = 12 -- hull inside this (flat) distance from the ring centre = arrived
OnboardingRules.RING_LINGER = 45 -- seconds the ring stays after arrival
OnboardingRules.ARROW_MAX_SECONDS = 120 -- plaza time with the world showing before the "!" chip takes over (a peek or "?" shows it again)
OnboardingRules.HOLD_RESUME_SECONDS = 1.5 -- the guide waits this long after a hold ends (a cancelled lobby)
OnboardingRules.LOBBY_GRACE = 0.5
OnboardingRules.LOADING_MAX = 40 -- same cap the goal card uses for the loading screen
-- The target arch's "arch glow" (owner pick, docs/design/GUIDE_ARROW.md): an emissive rim along the opening in the portal's own
-- colour plus a slowly spinning gem floating in front of the arch at vehicle height. No tall beam: the name sign stays readable.
OnboardingRules.DIAMOND_BACK = 7 -- studs on the plaza side of the veil (inside the landing ring)
OnboardingRules.DIAMOND_HEIGHT = 4.5 -- studs over the ground: a car's cab and driver top out around 5 (hull 2.4 high)
OnboardingRules.DIAMOND_SIZE = 3 -- edge of the cube stood on its corner
OnboardingRules.DIAMOND_FADE_NEAR = 7 -- the gem is gone this close (flat studs): driving through it never fills the camera
OnboardingRules.DIAMOND_FADE_FAR = 18 -- ... and fully there from this far
-- Where the arrow lives (the hub0 plaza). Centre = tools/map/author_hub0.py ORIGIN + PLAZA_C, paved out to PLAZA_R - 4 = 146
-- (the portal arches stand 118 out). The two radii are the hysteresis: in at PLAZA_IN, out only past PLAZA_OUT, so a car
-- driving along the rim does not flicker the arrow and the chip.
OnboardingRules.PLAZA_X = -8150
OnboardingRules.PLAZA_Z = 8000
OnboardingRules.PLAZA_IN = 138
OnboardingRules.PLAZA_OUT = 154
-- Off the plaza a small "!" chip stands in for the arrow; tapping it shows the way for this long.
OnboardingRules.PEEK_SECONDS = 6
-- The portal veil colours (tools/map/author_hub0.py ZONE_COLOURS, first entry; a spec keeps them in step).
OnboardingRules.PORTAL_COLORS = { DINO = "#f07a2a", SNOW = "#8fd8ff", ISLAND = "#2fd0c8", FOREST = "#6cc84a", SPACE = "#9a6cff" } :: { [string]: string }
-- The one race mode the guide survives: leaving the Storm match brings the arrow back (every other race retires it).
OnboardingRules.STORM_MODE = "stormcup"

-- The server saves the onboarded flag at GO only for modes that count as a first race; the Storm match holds the guide
-- and must not retire it (a new player who joins one still gets the portal guide after leaving).
function OnboardingRules.marksOnboarded(mode: any): boolean
	return mode ~= OnboardingRules.STORM_MODE
end

function OnboardingRules.family(mode: any): Family
	if mode == "Touch" or mode == "Gamepad" then
		return mode :: Family
	end
	return "KeyboardMouse"
end

function OnboardingRules.fireWord(family: Family): string
	return if family == "Touch" then "ITEM" elseif family == "Gamepad" then "X" else "F"
end

function OnboardingRules.turnWord(family: Family): string
	return if family == "Touch" then "TURN" elseif family == "Gamepad" then "R1" else "SHIFT"
end

-- How to steer, in the family's words (the goal card's second line and the replay card).
function OnboardingRules.controlsLine(family: Family): string
	if family == "Touch" then
		return "Drag the left pad to steer."
	elseif family == "Gamepad" then
		return "Left stick steers. A is go."
	end
	return "A and D steer. W is go."
end

local function press(family: Family): string
	return if family == "Touch" then "Tap" else "Press"
end

-- One tip's words. lapsLeft only matters for "lap"; vehicle only for "drift".
function OnboardingRules.tip(id: string, family: Family, vehicle: Vehicle, lapsLeft: number?): Tip?
	if id == "item" then
		return { title = "ITEM READY!", body = string.format("%s %s to fire it.", press(family), OnboardingRules.fireWord(family)) }
	elseif id == "boost" then
		return { title = "BOOST!", body = "Pads and rings give a burst of speed." }
	elseif id == "drift" then
		if vehicle == "car" then
			return { title = "NICE DRIFT!", body = string.format("Hold %s in a corner, release to boost.", OnboardingRules.turnWord(family)) }
		end
		return { title = "SHARP BANK!", body = string.format("Hold %s any time for tighter turns.", OnboardingRules.turnWord(family)) }
	elseif id == "lap" then
		local left = math.max(0, math.floor(lapsLeft or 0))
		if left <= 0 then
			return nil
		elseif left == 1 then
			return { title = "LAP DONE!", body = "Last lap! Give it everything!" }
		end
		return { title = "LAP DONE!", body = string.format("%d more to win. Stay ahead!", left) }
	end
	return nil
end

-- The "?" help card when the player is already racing: the controls in the family's words, three short lines.
function OnboardingRules.helpLines(family: Family, vehicle: Vehicle): { string }
	return {
		OnboardingRules.controlsLine(family),
		string.format("%s %s to fire items.", press(family), OnboardingRules.fireWord(family)),
		if vehicle == "car"
			then string.format("Hold %s in corners to drift.", OnboardingRules.turnWord(family))
			else string.format("Hold %s for tight turns.", OnboardingRules.turnWord(family)),
	}
end

function OnboardingRules.goalLines(family: Family): { string }
	return { OnboardingRules.GOAL_TEXT, OnboardingRules.controlsLine(family), OnboardingRules.PORTAL_TEXT }
end

------------------------------------------------------------------------------------------------------------------------
-- Guide: when
------------------------------------------------------------------------------------------------------------------------

export type State = {
	guideOn: boolean, -- this session runs the guide (not onboarded yet, or the player pressed ?)
	shown: { [string]: boolean }, -- tips already shown this session
	goalShown: boolean,
	portalDone: boolean, -- the guide's world is done for good (portal entered, or a race seen with a vehicle)
	arrived: boolean, -- the car has been in the landing ring (the arrival beat has fired)
	arrowSeconds: number, -- visible, un-held guide time so far
	ringSeconds: number, -- time since arrival
	retiredWhy: string?,
	onPlaza: boolean, -- the car is on the hub plaza (hysteresis, watchPlaza)
	peekUntil: number, -- clock time the chip's "show me" ends (0 = not peeking)
	chipDismissed: boolean, -- the chip was waved away; it stays down until the car is back on the plaza
}

function OnboardingRules.newState(guideOn: boolean): State
	return { guideOn = guideOn, shown = {}, goalShown = false, portalDone = false, arrived = false, arrowSeconds = 0, ringSeconds = 0, onPlaza = false, peekUntil = 0, chipDismissed = false }
end

-- The "?" button: the whole guide runs again.
function OnboardingRules.replay(state: State)
	state.guideOn = true
	table.clear(state.shown)
	state.goalShown = false
	state.portalDone = false
	state.arrived = false
	state.arrowSeconds = 0
	state.ringSeconds = 0
	state.retiredWhy = nil
	state.peekUntil = 0
	state.chipDismissed = false
end

-- Should the goal card show now? Once, in the hub, after the first spawn.
function OnboardingRules.goalDue(state: State, raceMode: any, ready: boolean): boolean
	return state.guideOn and ready and raceMode == "hub" and not state.goalShown and not state.portalDone
end

-- The guide world (arrow, ring, arch glow, gem): the hub, until the player has driven through a portal. hold (OnboardingRules.holdReason)
-- hides the whole world while a lobby, map switch, loading screen or race is under way.
function OnboardingRules.arrowOn(state: State, raceMode: any, haveTarget: boolean, hold: string?): boolean
	return state.guideOn and haveTarget and raceMode == "hub" and not state.portalDone and hold == nil
end

-- Why the guide world is hidden right now, or nil. ctx: raceMode, lobbyGoAt (server time or nil), now (server time),
-- switching, stormHold, loadingOver, resumeAt (server time a finished hold lets the guide back, or nil).
-- Priority: race > lobby > switching > storm > loading > resume.
export type HoldCtx = {
	raceMode: any,
	lobbyGoAt: any,
	now: number,
	switching: boolean?,
	stormHold: boolean?,
	loadingOver: boolean?,
	resumeAt: number?,
}
function OnboardingRules.holdReason(ctx: HoldCtx): string?
	local m = ctx.raceMode
	if type(m) == "string" and m ~= "hub" and m ~= "" then
		return "race"
	end
	if type(ctx.lobbyGoAt) == "number" and ctx.lobbyGoAt > ctx.now - OnboardingRules.LOBBY_GRACE then
		return "lobby"
	end
	if ctx.switching == true then
		return "switching"
	end
	if ctx.stormHold == true then
		return "storm"
	end
	if ctx.loadingOver ~= true then
		return "loading"
	end
	if ctx.resumeAt and ctx.now < ctx.resumeAt then
		return "resume"
	end
	return nil
end

-- Retire the guide world for good (portal entered, a race seen with a vehicle). The "?" button (replay) brings it back.
function OnboardingRules.retire(state: State, why: string)
	state.portalDone = true
	state.retiredWhy = why
end

-- Seen in a race with a vehicle (also a mid-race join, polled each frame): the guide has done what it can. The Storm match is
-- the exception: the guide is only held there and comes back when the player leaves it (owner 2026-10-20).
function OnboardingRules.shouldRetireForRace(state: State, raceMode: any, hasVehicle: boolean): boolean
	return state.guideOn
		and not state.portalDone
		and hasVehicle
		and type(raceMode) == "string"
		and raceMode ~= "hub"
		and raceMode ~= ""
		and raceMode ~= OnboardingRules.STORM_MODE
end

-- The plaza guide has run its course: the arrow's time cap, or the ring has lingered after arrival. The chip takes over.
function OnboardingRules.spent(state: State): boolean
	return state.arrowSeconds >= OnboardingRules.ARROW_MAX_SECONDS
		or (state.arrived and state.ringSeconds >= OnboardingRules.RING_LINGER)
end

-- What the world shows: the floating "arrow", the landing "ring" (near, or after arrival) or "off" (a cap was reached).
-- A chip peek (peeking) ignores the caps and the arrival: it just points the way, by distance.
function OnboardingRules.phase(state: State, dist: number, peeking: boolean?): string
	if peeking == true then
		return if dist <= OnboardingRules.ARROW_HIDE_DIST then "ring" else "arrow"
	end
	if state.arrowSeconds >= OnboardingRules.ARROW_MAX_SECONDS then
		return "off"
	end
	if state.arrived then
		return if state.ringSeconds >= OnboardingRules.RING_LINGER then "off" else "ring"
	end
	return if dist <= OnboardingRules.ARROW_HIDE_DIST then "ring" else "arrow"
end

-- Advance the clocks by dt. Nothing advances while held. Returns true on the single call where the car first enters the
-- ring (the arrival beat: confetti and the chime).
function OnboardingRules.step(state: State, dt: number, inRing: boolean, hold: string?): boolean
	if hold ~= nil then
		return false
	end
	state.arrowSeconds += dt
	if state.arrived then
		state.ringSeconds += dt
		return false
	end
	if inRing then
		state.arrived = true
		return true
	end
	return false
end

-- The ring takes over from the arrow over the same distance the arrow fades out in.
function OnboardingRules.ringAlpha(dist: number): number
	return 1 - OnboardingRules.arrowAlpha(dist)
end

-- Flat centre of the landing ring: the portal minus its look (the plaza side), RING_BACK studs out.
function OnboardingRules.ringCentre(px: number, pz: number, lookX: number, lookZ: number): (number, number)
	local d = math.sqrt(lookX * lookX + lookZ * lookZ)
	if d < 0.001 then
		return px, pz
	end
	return px - lookX / d * OnboardingRules.RING_BACK, pz - lookZ / d * OnboardingRules.RING_BACK
end

-- Flat centre of the diamond: DIAMOND_BACK studs on the plaza side of the veil.
function OnboardingRules.diamondCentre(px: number, pz: number, lookX: number, lookZ: number): (number, number)
	local d = math.sqrt(lookX * lookX + lookZ * lookZ)
	if d < 0.001 then
		return px, pz
	end
	return px - lookX / d * OnboardingRules.DIAMOND_BACK, pz - lookZ / d * OnboardingRules.DIAMOND_BACK
end

-- 0 inside DIAMOND_FADE_NEAR, 1 beyond DIAMOND_FADE_FAR (flat studs from the gem to the car).
function OnboardingRules.diamondAlpha(dist: number): number
	local n, f = OnboardingRules.DIAMOND_FADE_NEAR, OnboardingRules.DIAMOND_FADE_FAR
	return math.clamp((dist - n) / (f - n), 0, 1)
end

------------------------------------------------------------------------------------------------------------------------
-- Guide: plaza-only arrow and the "!" chip
------------------------------------------------------------------------------------------------------------------------

-- Plaza test with hysteresis: was inside -> stays inside until past PLAZA_OUT; was outside -> comes in at PLAZA_IN.
function OnboardingRules.plazaStep(inside: boolean, x: number, z: number): boolean
	local d = math.sqrt((x - OnboardingRules.PLAZA_X) ^ 2 + (z - OnboardingRules.PLAZA_Z) ^ 2)
	if inside then
		return d <= OnboardingRules.PLAZA_OUT
	end
	return d <= OnboardingRules.PLAZA_IN
end

-- Feed the car's position each frame. Coming (back) onto the plaza ends any dismissal and any peek: the arrow is on by itself.
function OnboardingRules.watchPlaza(state: State, x: number, z: number)
	local now = OnboardingRules.plazaStep(state.onPlaza, x, z)
	if now and not state.onPlaza then
		state.chipDismissed = false
		state.peekUntil = 0
	end
	state.onPlaza = now
end

-- What the guide puts on screen: "world" (arrow, ring, arch glow and gem), "chip" (the small "!") or "none".
-- Hidden outright under any hold (lobby, Storm match, race, map switch, loading), after the portal, or off the hub.
-- On the plaza the world shows until it has run its course (spent); off the plaza only a chip peek shows it.
function OnboardingRules.surface(state: State, raceMode: any, haveTarget: boolean, hold: string?, now: number): string
	if not OnboardingRules.arrowOn(state, raceMode, haveTarget, hold) then
		return "none"
	end
	if now < state.peekUntil then
		return "world"
	end
	if state.onPlaza and not OnboardingRules.spent(state) then
		return "world"
	end
	return if state.chipDismissed then "none" else "chip"
end

-- The chip was tapped: when idle it peeks (the way shown for PEEK_SECONDS); while peeking it dismisses. Returns which.
function OnboardingRules.chipTap(state: State, now: number): string
	if now < state.peekUntil then
		state.peekUntil = 0
		state.chipDismissed = true
		return "dismiss"
	end
	state.peekUntil = now + OnboardingRules.PEEK_SECONDS
	return "peek"
end

-- Where the chip sits, px: right of the "?" button in the left system cluster (phone-safe, never over the kart). When that
-- would touch lane A (a narrow 740 px phone) it drops under the token chip instead. Rects are {x, y, w, h}.
function OnboardingRules.chipRect(help: any, token: any, laneA: any): { x: number, y: number, w: number, h: number }
	local w, gap = help.w, 6
	local right = { x = help.x + help.w + gap, y = help.y, w = w, h = help.h }
	local clearX = right.x + w <= laneA.x - 4 or right.x >= laneA.x + laneA.w or right.y + right.h <= laneA.y or right.y >= laneA.y + laneA.h
	if clearX then
		return right
	end
	return { x = token.x, y = token.y + token.h + gap, w = w, h = help.h }
end

local EVENT_TIP: { [string]: string } = { item = "item", pad = "boost", drift = "drift", lap = "lap" }

-- A just-in-time tip for an event, or nil. Marks it shown, so each appears once per session. Races only: the hub has no
-- items, pads or laps. ctx.lap is the lap the player just entered (Lap attribute), ctx.totalLaps the race's lap count.
function OnboardingRules.onEvent(state: State, event: string, raceMode: any, lap: number?, totalLaps: number?): string?
	local id = EVENT_TIP[event]
	if not id or not state.guideOn or state.shown[id] then
		return nil
	end
	if type(raceMode) ~= "string" or raceMode == "hub" then
		return nil
	end
	if id == "lap" then
		if OnboardingRules.lapsLeft(lap, totalLaps) < 1 then
			return nil
		end
	end
	state.shown[id] = true
	return id
end

-- Entering lap N means N - 1 laps are done; the laps still to fly (the tip is for the first lap done).
function OnboardingRules.lapsLeft(lap: number?, totalLaps: number?): number
	if type(lap) ~= "number" or type(totalLaps) ~= "number" or lap < 2 then
		return 0
	end
	return math.max(0, totalLaps - (lap - 1))
end

-- The first open race portal in the order the server lists them (DINO first), from the PortalStates attribute rows
-- { id, zone, open }. The hub itself (final boss) is not a portal to point at.
function OnboardingRules.firstOpenPortal(states: { any }): any?
	for _, st in ipairs(states) do
		if type(st) == "table" and st.open == true and st.id ~= "HUB-0" and type(st.zone) == "string" then
			return st
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- Guide: the ground arrow (flat x/z maths so it needs no vectors)
------------------------------------------------------------------------------------------------------------------------

-- Unit direction on the ground from the vehicle to the portal, and the distance. (0, 0, d) when on top of it.
function OnboardingRules.groundDir(px: number, pz: number, tx: number, tz: number): (number, number, number)
	local dx, dz = tx - px, tz - pz
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.001 then
		return 0, 0, d
	end
	return dx / d, dz / d, d
end

-- How far ahead of the vehicle the arrow floats: close enough to read, never past the portal.
function OnboardingRules.arrowAhead(dist: number): number
	return math.clamp(dist * 0.4, 9, 15)
end

-- The arrow fades out as the portal gets near and is gone inside ARROW_HIDE_DIST.
function OnboardingRules.arrowAlpha(dist: number): number
	local hide = OnboardingRules.ARROW_HIDE_DIST
	return math.clamp((dist - hide) / hide, 0, 1)
end

------------------------------------------------------------------------------------------------------------------------
-- Funnels (audit M3)
------------------------------------------------------------------------------------------------------------------------

-- Onboarding funnel, first session only. Step names are the dashboard's labels. Step 3 is a portal crossing or a pick on
-- the Adventure board (the two ways into a race); step 4 is the countdown reaching GO.
OnboardingRules.ONBOARDING = {
	joined = 1,
	first_move = 2,
	reached_portal = 3,
	race_started = 4,
	first_finish = 5,
	first_token = 6,
	second_race = 7,
} :: { [string]: number }

-- The repeating race funnel: pick -> countdown -> finish -> next action.
OnboardingRules.RACE_FUNNEL = "race"
OnboardingRules.RACE = { pick = 1, countdown = 2, finish = 3, next = 4 } :: { [string]: number }

-- Custom event names (LogCustomEvent).
OnboardingRules.EVENT_PROFILE_LOAD = "profile_load_seconds"
OnboardingRules.EVENT_READY = "ready_seconds"
-- Per-race frame time from client/FrameGovernor (perf review v21 PF-22), in ms; fields: track, mode, device tier word.
OnboardingRules.EVENT_FRAME_P50 = "frame_p50_ms"
OnboardingRules.EVENT_FRAME_P95 = "frame_p95_ms"

local FIELD_MAX = 40

local function cleanText(v: any): string?
	if type(v) ~= "string" or v == "" then
		return nil
	end
	-- Ids, modes and choices only: letters, digits and a few separators. A name or a free-text string never gets through.
	local safe = string.gsub(v, "[^%w_%-%.:]", "_") -- gsub also returns a count: keep the string only
	return string.sub(safe, 1, FIELD_MAX)
end

export type Fields = { track: string?, mode: string?, detail: string? }

-- The three custom fields every funnel event may carry (Roblox allows three): track id, race mode, one detail word.
function OnboardingRules.fields(track: any, mode: any, detail: any): Fields
	return { track = cleanText(track), mode = cleanText(mode), detail = cleanText(detail) }
end

export type Sink = {
	onboarding: (player: any, step: number, name: string, fields: Fields) -> (),
	funnel: (player: any, funnel: string, session: string, step: number, name: string, fields: Fields) -> (),
	custom: (player: any, name: string, value: number, fields: Fields) -> (),
}

export type Tracker = {
	begin: (player: any, firstSession: boolean) -> (),
	forget: (player: any) -> (),
	known: (player: any) -> boolean,
	moved: (player: any) -> (),
	pick: (player: any, fields: Fields) -> (),
	countdown: (player: any, fields: Fields) -> (),
	go: (player: any, fields: Fields) -> (),
	finish: (player: any, fields: Fields, gotToken: boolean) -> (),
	next: (player: any, choice: string, fields: Fields) -> (),
	custom: (player: any, name: string, value: number, fields: Fields?) -> (),
}

type Session = { id: string, steps: { [number]: boolean } }
type Log = { first: boolean, onboard: { [number]: boolean }, races: number, session: Session? }

local NO_FIELDS: Fields = { track = nil, mode = nil, detail = nil }

-- Dedupes per player and keeps the order honest; the sink does the Roblox call (server/Funnels, pcall-wrapped there).
function OnboardingRules.newTracker(sink: Sink, newId: () -> string): Tracker
	local logs: { [any]: Log } = {}
	local tracker = {} :: Tracker

	local function onboard(player: any, name: string, fields: Fields?)
		local l = logs[player]
		local step = OnboardingRules.ONBOARDING[name]
		if not l or not l.first or l.onboard[step] then
			return
		end
		l.onboard[step] = true
		sink.onboarding(player, step, name, fields or NO_FIELDS)
	end

	local function raceStep(player: any, l: Log, name: string, fields: Fields)
		local s = l.session
		local step = OnboardingRules.RACE[name]
		if not s or s.steps[step] then
			return
		end
		s.steps[step] = true
		sink.funnel(player, OnboardingRules.RACE_FUNNEL, s.id, step, name, fields)
	end

	-- A session that reached the finish but never got its "next" ended on the automatic return.
	local function closeSession(player: any, l: Log)
		local s = l.session
		if s and s.steps[OnboardingRules.RACE.finish] and not s.steps[OnboardingRules.RACE.next] then
			raceStep(player, l, "next", OnboardingRules.fields(nil, nil, "auto"))
		end
		l.session = nil
	end

	local function open(player: any, l: Log)
		closeSession(player, l)
		l.session = { id = newId(), steps = {} }
	end

	function tracker.begin(player, firstSession)
		if logs[player] then
			return
		end
		logs[player] = { first = firstSession, onboard = {}, races = 0, session = nil }
		onboard(player, "joined")
	end

	function tracker.forget(player)
		logs[player] = nil
	end

	function tracker.known(player)
		return logs[player] ~= nil
	end

	function tracker.moved(player)
		onboard(player, "first_move")
	end

	function tracker.pick(player, fields)
		local l = logs[player]
		if not l then
			return
		end
		onboard(player, "reached_portal", fields)
		open(player, l)
		raceStep(player, l, "pick", fields)
	end

	function tracker.countdown(player, fields)
		local l = logs[player]
		if not l then
			return
		end
		local s = l.session
		-- A pick that is still waiting for its countdown continues; a replay, a lobby or a Storm Cup start has none.
		if not s or s.steps[OnboardingRules.RACE.countdown] then
			open(player, l)
		end
		raceStep(player, l, "countdown", fields)
	end

	-- The countdown ended and the race is on.
	function tracker.go(player, fields)
		local l = logs[player]
		if not l then
			return
		end
		l.races += 1
		onboard(player, "race_started", fields)
		if l.races == 2 then
			onboard(player, "second_race", fields)
		end
	end

	function tracker.finish(player, fields, gotToken)
		local l = logs[player]
		if not l then
			return
		end
		raceStep(player, l, "finish", fields)
		onboard(player, "first_finish", fields)
		if gotToken then
			onboard(player, "first_token", fields)
		end
	end

	function tracker.next(player, choice, fields)
		local l = logs[player]
		local s = if l then l.session else nil
		-- A "next" only follows a finish; a vote cast while still racing (or a stray call) is not part of the funnel.
		if not l or not s or not s.steps[OnboardingRules.RACE.finish] then
			return
		end
		raceStep(player, l, "next", OnboardingRules.fields(fields.track, fields.mode, choice))
	end

	function tracker.custom(player, name, value, fields)
		if logs[player] and type(value) == "number" and value == value and value >= 0 and value < 1e6 then
			sink.custom(player, name, value, fields or NO_FIELDS)
		end
	end

	return tracker
end

return OnboardingRules
