--!strict
-- Race flow rules with more than one human on a server (TEST_LIST L16, L19, L28, L30, L31, L32; LAUNCH_PROGRESSION
-- section 6). Pure: no Instances, no clock, specced in tools/tests/raceflow_spec.luau. Shared by the server
-- (TrackDirector: the DNF deadline, FLY AGAIN / HUB votes, the portal lobby, the return frame at the zone's arch;
-- RaceManager: who beat the boss) and the client (TrackFlow, RaceUI, HudExtras: the banner, vote and countdown lines).
--
-- A solo server (one human) keeps the old flow: FLY AGAIN and HUB act at once, a portal warps in 1.5 s. With 2+ humans
-- one player's tap must never end a race the others are still flying (L30), so the exits become votes and a portal
-- opens a short server-wide lobby instead of pulling everyone in after 1.5 s (L31, L32).
local RaceFlowRules = {}

-- Economy v3 phase 2 (docs/design/PER_GROUP_RACES.md): each group races in its own RaceInstance on its zone map while
-- the hub stays live for everyone else. false keeps today's single race (one map, the whole server switches) byte for
-- byte; it turns on only after the Studio pass of the per-instance engine (phase 2b: RaceScope, RaceGroups), the
-- streaming trial and the 16-player phone measurement.
RaceFlowRules.PER_GROUP = false

-- QA switch (Studio only; the one exception to "no Instances" in this module): the workspace attribute QAPerGroup =
-- true, set on the place in Edit before Play (command bar: workspace:SetAttribute("QAPerGroup", true)), turns
-- PER_GROUP on for that session without editing source. Read ONCE, when this module is first required (server boot,
-- each client's first require); ignored outside Studio, so a live server can never flip it. qaPerGroup is the pure rule.
RaceFlowRules.QA_ATTRIBUTE = "QAPerGroup"
RaceFlowRules.QA_PER_GROUP = false -- true when the QA switch (not the source constant) turned PER_GROUP on

function RaceFlowRules.qaPerGroup(isStudio: boolean, value: any): boolean
	return isStudio == true and value == true
end

do
	local ok, on = pcall(function(): boolean
		local RunService = (game :: any):GetService("RunService")
		return RaceFlowRules.qaPerGroup(RunService:IsStudio(), (workspace :: any):GetAttribute(RaceFlowRules.QA_ATTRIBUTE))
	end)
	if ok and on == true and not RaceFlowRules.PER_GROUP then
		RaceFlowRules.PER_GROUP = true
		RaceFlowRules.QA_PER_GROUP = true
	end
end

RaceFlowRules.DNF_SECONDS = 45 -- after the first human finishes, the others have this long (L30)
-- A portal or board pick gathers racers this long (LAUNCH_PROGRESSION 6; economy v3 section 2: 20 s, was 12). Per group
-- (shared/PortalQueueRules) every arch's lobby lasts this long, solo included; on the single path the server-wide one.
RaceFlowRules.LOBBY_SECONDS = 20
-- Fallback (config): with PER_GROUP true a lone human on the server warps in PortalRules.WARP_SECONDS as before instead
-- of the LOBBY_SECONDS lobby with bots. Off: solo uses the same lobby. With PER_GROUP false solo always warps.
RaceFlowRules.SOLO_QUICK_WARP = false
-- Phase 3: LEAVE (portal lobby) per player, seconds; its own bucket, apart from the 1.5 s race-request throttle.
RaceFlowRules.LEAVE_THROTTLE = 0.3
RaceFlowRules.VOTE_COOLDOWN = 1 -- RequestPlayAgain / RequestHub per player, seconds
RaceFlowRules.RETURN_BACK = 30 -- studs onto the plaza side of the arch the return grid's front row sits (L19)
RaceFlowRules.RETURN_GROUND_LIFT = 3 -- the hub spawn frame rides this far above the paving (hub.spawn.cf convention)
-- OURS (trap audit H0-08, the return half): facing straight out of an arch puts the whole return grid nose-on to the
-- fountain basin 55-65 studs ahead (the boot spawn's wall bump, after every race). The grid turns this many degrees
-- (about +Y) off that line instead: every slot of every arch then has 120 studs of open paving ahead (2 s of touch
-- auto-throttle), clear of the fountain, lamps, planters, stalls and the other arches' triggers, with 2 degrees to
-- spare either way (tools/map/tests/test_hub0.py test_h0_08_return_grid_lanes_clear).
RaceFlowRules.RETURN_TURN = 41

export type Choice = "again" | "hub"

-- Votes and the lobby only exist with two or more humans.
function RaceFlowRules.isGroup(humans: number): boolean
	return humans >= 2
end

-- Only a racer who is done (crossed the line, or timed out as DNF) may vote; a Storm Cup never replays (it would pay
-- the cup's placement table again), so AGAIN is refused there.
function RaceFlowRules.canVote(choice: string, done: boolean, mode: string?): boolean
	if choice ~= "again" and choice ~= "hub" then
		return false
	end
	if mode == "hub" or not done then
		return false
	end
	return not (choice == "again" and not RaceFlowRules.canReplay(mode))
end

-- FLY AGAIN on the same map: never in a storm race (the Storm Cup, or a storm race v2 field), it would pay the storm
-- tables (Cash placement, Storm Shards) again.
function RaceFlowRules.canReplay(mode: string?): boolean
	return mode ~= "stormcup" and mode ~= "stormrace"
end

-- Counts the votes of the humans present (a leaver's vote is gone with him).
function RaceFlowRules.tally(votes: { [any]: any }, present: { any }): (number, number)
	local again, hub = 0, 0
	for _, p in present do
		local v = votes[p]
		if v == "again" then
			again += 1
		elseif v == "hub" then
			hub += 1
		end
	end
	return again, hub
end

-- What the votes decide now. Every human present voting the same way acts at once; when the return timer runs out,
-- AGAIN wins only with more than half of the humans present, otherwise the server goes back to the hub.
function RaceFlowRules.decide(again: number, hub: number, humans: number, expired: boolean): Choice?
	if humans > 0 and again >= humans then
		return "again"
	end
	if humans > 0 and hub >= humans then
		return "hub"
	end
	if expired then
		return if again > humans / 2 then "again" else "hub"
	end
	return nil
end

-- "AGAIN 1/3" on the finish card's buttons (short label plus the count); the idle label ("FLY AGAIN") when there is
-- nothing to count (solo, or no votes yet).
function RaceFlowRules.voteLabel(idle: string, short: string, count: any, humans: any): string
	if type(humans) ~= "number" or humans < 2 or type(count) ~= "number" or count <= 0 then
		return idle
	end
	return string.format("%s %d/%d", short, count, humans)
end

-- The race-end state machine's next step (L30). allDone: every human finished or timed out. anyDone: at least one
-- human finished. dnfAt: the running deadline, or nil. Returns "return" (start the return timer), "dnf" (start the
-- DNF deadline now), "timeout" (the deadline passed: the unfinished are DNF, then the return timer) or "wait".
function RaceFlowRules.raceEndStep(allDone: boolean, anyDone: boolean, now: number, dnfAt: number?, battle: boolean): string
	if allDone then
		return "return"
	end
	-- A battle scores its own end (BattleCore finishes every record at once, with its own time cap).
	if battle or not anyDone then
		return "wait"
	end
	if dnfAt == nil then
		return "dnf"
	end
	return if now >= dnfAt then "timeout" else "wait"
end

-- Abandoned race (owner, 2026-10-20): every bot has crossed the line (fieldDone: a field exists and all of it finished)
-- and no human present is still racing (activeRacing: present, not finished, not DNF, not AFK). The race is over: the
-- unfinished AFK racers are DNF and the return timer starts, so an idle racer or an empty server never keeps a finished
-- race's map running for the next joiner. A battle scores its own end.
function RaceFlowRules.abandoned(fieldDone: boolean, activeRacing: number, battle: boolean): boolean
	return not battle and fieldDone and activeRacing <= 0
end

RaceFlowRules.REJOIN_GRACE = 60 -- seconds a racer who dropped out of a running race may come back into it

-- Whether a joiner's leave record (TrackDirector, kept in server memory, never saved) lets him back into the race
-- running now: the same server (jobId), the same race (raceId, workspace.RaceResetSeq) and at most REJOIN_GRACE seconds
-- ago (os.time). Anything else (nil, another server, a later race, a stale or future time, wrong types, an old shape
-- without these fields) is no resume.
function RaceFlowRules.canResume(left: any, jobId: string, raceId: number?, now: number): boolean
	if type(left) ~= "table" or type(left.jobId) ~= "string" or left.jobId == "" or left.jobId ~= jobId then
		return false
	end
	if type(left.raceId) ~= "number" or type(raceId) ~= "number" or left.raceId ~= raceId then
		return false
	end
	if type(left.at) ~= "number" or type(now) ~= "number" then
		return false
	end
	local age = now - left.at
	return age >= 0 and age <= RaceFlowRules.REJOIN_GRACE
end

export type JoinContext = {
	mode: string?, -- workspace.RaceMode
	switching: boolean?, -- a map load is running (it seats the joiner itself)
	ended: boolean?, -- the race is over: the return timer runs (results shown)
	othersActive: number?, -- other humans present who are not AFK
	left: any, -- the joiner's leave record on this server, or nil
	jobId: string,
	raceId: number?,
	now: number,
}

-- Where a joiner goes (owner, 2026-10-20: never thrown into an old race). "stay": the server keeps its map (the hub, a
-- load in progress, a race other humans are flying or watching the results of, or his own race within REJOIN_GRACE);
-- "hub": nobody else is playing it, so the server ends the race and returns to the hub.
function RaceFlowRules.joinStep(ctx: JoinContext): string
	local mode = ctx.mode
	if mode == nil or mode == "hub" or ctx.switching == true then
		return "stay"
	end
	local others = if type(ctx.othersActive) == "number" then ctx.othersActive else 0
	if others > 0 then
		return "stay"
	end
	if ctx.ended ~= true and RaceFlowRules.canResume(ctx.left, ctx.jobId, ctx.raceId, ctx.now) then
		return "stay"
	end
	return "hub"
end

-- "Finish in 32 s or DNF" on an unfinished racer's HUD; "" when the deadline is gone.
function RaceFlowRules.dnfText(secondsLeft: number): string
	if secondsLeft <= 0 then
		return ""
	end
	return string.format("Finish in %d s or DNF", math.ceil(secondsLeft))
end

-- Boss, rematch and final boss (L13, L16): a human who crosses the line before the boss bot beats it, whatever other
-- humans did. finishOrder rows are { isPlayer = bool }; the caller counts them before inserting this finisher.
function RaceFlowRules.botsAhead(finishOrder: { any }): number
	local n = 0
	for _, e in finishOrder do
		if not e.isPlayer then
			n += 1
		end
	end
	return n
end

-- The lobby banner every hub client shows: "<name> opened <track> - race starts in 12".
function RaceFlowRules.lobbyText(name: string, trackLabel: string, secondsLeft: number): string
	return string.format("%s opened %s - race starts in %d", string.sub(name, 1, 20), trackLabel, math.max(0, math.ceil(secondsLeft)))
end

RaceFlowRules.GUEST_TEXT = "Guest race: results won't count"

-- The toast for a portal or board pick refused while someone else's lobby runs.
function RaceFlowRules.lobbyBusyText(sameTrack: boolean, name: string, trackLabel: string, secondsLeft: number): string
	local n = math.max(0, math.ceil(secondsLeft))
	if sameTrack then
		return string.format("You're in! %s starts in %d", trackLabel, n)
	end
	return string.format("%s opened %s - starts in %d", string.sub(name, 1, 20), trackLabel, n)
end

-- A portal lobby holds while the opener stays on the far side of the arch; backing out onto the plaza (more than
-- cancelBack studs back through the veil) cancels it. side is PortalRules.side of the opener's hull.
function RaceFlowRules.lobbyHolds(side: number, cancelBack: number): boolean
	return side >= -cancelBack
end

-- Where the server lands after a race (L19): in front of the arch of the zone it came from, on the plaza side, facing
-- out of the arch onto the plaza, turned RETURN_TURN off the fountain. archCf is the hub plan's portal cf (LookVector out of the plaza); groundY the paving
-- height under that point. The grid's rows step backward (+Z), toward the arch: the front row sits RETURN_BACK studs
-- out, the second 16 closer, both clear of the veil, so nobody warps again by just sitting there.
function RaceFlowRules.returnFrame(archCf: CFrame, groundY: number): CFrame
	local look = archCf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local base = archCf.Position - dir * RaceFlowRules.RETURN_BACK
	local pos = Vector3.new(base.X, groundY + RaceFlowRules.RETURN_GROUND_LIFT, base.Z)
	-- fromMatrix, not CFrame.lookAt: same frame in Roblox, and Lune's lookAt mirrors Z (the spec runs this under Lune).
	-- Out of the arch, turned RETURN_TURN about +Y (as CFrame.Angles(0, t, 0) turns a vector) so it misses the fountain.
	local t = math.rad(RaceFlowRules.RETURN_TURN)
	local c, sn = math.cos(t), math.sin(t)
	local look = Vector3.new(-dir.X * c - dir.Z * sn, 0, dir.X * sn - dir.Z * c)
	local up = Vector3.new(0, 1, 0)
	return CFrame.fromMatrix(pos, look:Cross(up), up)
end

-- The lowest join slot nobody holds (FlightServer): slots stay within the player count, so the hub grid never grows
-- past two rows however many players came and went (L31, L32).
function RaceFlowRules.freeSlot(used: { [number]: boolean }): number
	local s = 1
	while used[s] do
		s += 1
	end
	return s
end

return RaceFlowRules
