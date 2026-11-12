--!strict
-- Missile v3 rules (owner 2026-10-20: "too many times I feel like the missles dont ever reach an enemy or go off shooting
-- nothing", plus a beep warning, a barrel-roll dodge for planes and an item block for the other vehicles). Pure: the
-- server (kit/ItemEffects, ItemService) decides with these, the client (ItemJuice, FlightController) only displays and
-- reports input. No Roblox API; runs under Lune (tools/tests/missile_v3_spec.luau).
--
-- Root causes of the misses (v2, measured against the spec fixtures):
--   1. Levels one and three were UNGUIDED: they flew the course line in the shooter's lane, so a racer one lane over (the
--      corridor is 68 studs wide, the hit radius 9) was simply never reached. Most fired shots were these.
--   2. The level-two lock took the next racer in race ORDER with no reach check: a leader 900 studs up the track was
--      locked, the shot lived 4 s at 240 studs/s against a 165-210 studs/s plane and expired short of it ("shooting
--      nothing"). A racer who crashed or finished turned it unguided mid-flight.
--   3. A shot chasing the hull flew straight at it through the world, so a car up a wall or behind a ridge took the
--      shot into the rock (wall blast) although a course path existed.
-- v3 is the Mario Kart red shell: every shot locks the nearest racer AHEAD within LOCK_RANGE at fire time (players and
-- bots alike), flies the course path (gaining on the target: chaseSpeed) until close, then homes directly while the line
-- to the target is open, and falls back to the course path when it is not. With nobody ahead in reach it flies forward
-- along the course in the shooter's lane and expires. A shot that loses its target (dodged, blocked, the target crashed
-- or was already spinning) overshoots: straight on for OVERSHOOT_SECONDS, then it fizzles.
-- Counterplay (server decides; MissileRules.evasion): a plane's barrel roll inside DODGE_WINDOW before contact makes the
-- shot miss; any racer dragging a trap behind them (hold the item button with a trap) or under a shield blocks it; bots
-- evade with BOT_EVADE_CHANCE so the field plays fair.

local MissileRules = {}

-- OURS numbers, tuned for "it reaches what it locks, and a good player can still beat it".
MissileRules.TUNING = table.freeze({
	lockRange = 600, -- studs of course progress: the furthest racer ahead a shot locks (about 3 s of closing)
	terminalRange = 80, -- straight-line studs: from here the shot homes on the hull directly
	terminalGap = 30, -- or when the course progress gap is this small (racer alongside the shot)
	-- v37: the terminal phase needs the target in front of the shot (cos of the cone half-angle) and turns at most
	-- terminalTurnDeg toward it; a racer under minLockAhead studs of progress ahead of the shooter is not locked (it is
	-- beside the nose, and the server's sample of a player's hull trails the client's by 10-25 studs).
	terminalCone = 0.17,
	terminalTurnDeg = 420,
	minLockAhead = 25,
	catchUp = 70, -- studs/s a locked shot flies faster than its target while on the course path
	maxSpeed = 420, -- studs/s cap (overcharge plane 210 + catchUp stays under it; v37: base shots fly 320)
	lockedLifetime = 7.0, -- s a locked shot may live (lockRange / catchUp is about 8.5 s at the worst case; most land < 3 s)
	overshootSeconds = 0.5, -- a shot that lost its target flies on this long, then fizzles
	-- Barrel roll dodge: the roll lasts TrickRules.ROLL_TIME (0.45 s); the extra 0.35 s covers the client -> server trip,
	-- so a roll the player started as the beeps turned to a trill counts.
	dodgeWindow = 0.8,
	rollMinInterval = 1.1, -- s between rolls the server accepts (client cooldown 1.2 s; a faster client gets nothing)
	-- A roll only counts when it began after the shot was fired (EvadeInput.since): no standing roll before a warning.
	botEvadeChance = 0.15, -- per shot that reaches a bot: a plane bot rolls it off, a car bot blocks it
	dragHoldSeconds = 0.22, -- client: holding the item button this long with a trap drags it behind instead of dropping
})

export type Candidate = { id: string, progress: number, active: boolean, targetable: boolean? }

-- Whom a shot fired at shooterProgress locks: the nearest racer AHEAD (smallest positive progress gap) within range,
-- preferring one that can be hit now (targetable ~= false: not already spinning, not in a respawn bubble) over a nearer
-- one that cannot, so the next shots of a volley go on to the next racer. nil: nobody ahead in reach.
--
-- strict (v6 minor D3): only a racer that can be hit now counts. A salvo shot whose target was hit or is spinning retargets
-- with strict = true: a spinning racer is never "the next target", so with nobody else the shot fizzles instead of
-- overshooting into a wall. The range test is inclusive (a racer exactly `range` ahead is in reach) and uses course
-- progress only: the shooter and the candidates must carry the same unwrapped progress (D4).
--
-- taken (MK-style fairness, a bot's volley): shots this volley already sent at each racer. Among the racers that can be
-- hit, the one with the fewest shots wins, then the nearest, so a level-3 salvo fans out over the racers ahead instead of
-- all locking the same one (with one racer ahead they all still go there). nil: the plain nearest pick.
function MissileRules.pickTarget(self: string, shooterProgress: number, candidates: { Candidate }, range: number?, strict: boolean?, taken: { [string]: number }?): string?
	local reach = range or MissileRules.TUNING.lockRange
	local best: string?, bestGap, bestOk, bestTaken = nil, math.huge, false, math.huge
	for _, c in candidates do
		if c.id ~= self and c.active then
			local gap = c.progress - shooterProgress
			if gap > 0 and gap <= reach then
				local ok = c.targetable ~= false
				if strict == true and not ok then
					continue
				end
				local used = if taken then (taken[c.id] or 0) else 0
				if (ok and not bestOk) or (ok == bestOk and (used < bestTaken or (used == bestTaken and gap < bestGap))) then
					best, bestGap, bestOk, bestTaken = c.id, gap, ok, used
				end
			end
		end
	end
	return best
end

-- Whom a free shot (shooter off the course line) locks: the nearest racer in the cone ahead of the nose, else the progress
-- lock taken at fire time (v6 minor D4: a QA bot 350-420 studs ahead was inside lockRange 600 by progress but outside the
-- 320-stud cone, so a free shot got target=none). nil: nobody. roam (the hub's free roam): the hub loop is a road, not a
-- race line, so its progress order means nothing there and only the cone counts (a hub shot never turns around onto a
-- player behind the nose).
function MissileRules.freeLock(coneTarget: string?, progressTarget: string?, roam: boolean?): string?
	if coneTarget ~= nil or roam == true then
		return coneTarget
	end
	return progressTarget
end

-- What a race shot does when its target is hit, spinning or gone: "retarget" to the next racer ahead in reach, or
-- "fizzle" in the air when there is none (it never flies on into a wall). v6 minor D3.
function MissileRules.lostTargetFate(nextTarget: string?): "retarget" | "fizzle"
	return if nextTarget ~= nil then "retarget" else "fizzle"
end

-- "course" (follow the track path) or "terminal" (home on the hull). gap: target progress minus shot progress; dist:
-- straight-line studs; lineClear: nothing solid between the shot and the hull. Never terminal through a wall.
function MissileRules.phase(gap: number, dist: number, lineClear: boolean): "course" | "terminal"
	local T = MissileRules.TUNING
	if lineClear and (dist <= T.terminalRange or gap <= T.terminalGap) then
		return "terminal"
	end
	return "course"
end

-- Course-path speed of a locked shot: its own speed, or the target's plus catchUp when that is faster, capped.
function MissileRules.chaseSpeed(base: number, targetSpeed: number?): number
	local T = MissileRules.TUNING
	local want = if targetSpeed then targetSpeed + T.catchUp else base
	return math.clamp(math.max(base, want), base, math.max(base, T.maxSpeed))
end

export type EvadeInput = {
	vehicle: string?, -- "plane" | "car" | nil (unknown: treated as a plane for the roll, which a car client never sends)
	isBot: boolean,
	now: number,
	rolledAt: number?, -- server time of the racer's last accepted roll
	since: number?, -- the shot's launch time: an earlier roll does not count
	dragging: boolean?, -- holding a trap behind them
	random: number?, -- [0, 1): the bot's dice for this shot
}

-- What saves a racer from a shot reaching them: "roll" (a plane rolled inside dodgeWindow: the shot misses), "block"
-- (a dragged trap eats it; a bot car's block), or nil (it hits; a shield or a respawn bubble is ItemEffects' own check).
function MissileRules.evasion(e: EvadeInput): ("roll" | "block")?
	local T = MissileRules.TUNING
	if e.isBot then
		if (e.random or 1) < T.botEvadeChance then
			return if e.vehicle == "car" then "block" else "roll"
		end
		return nil
	end
	local at = e.rolledAt
	if e.vehicle ~= "car" and at ~= nil and at >= (e.since or -math.huge) and e.now - at >= 0 and e.now - at <= T.dodgeWindow then
		return "roll"
	end
	if e.dragging == true then
		return "block"
	end
	return nil
end

-- Whether the server accepts a roll report: the last accepted one is old enough (a forged roll loop gets nothing more).
function MissileRules.acceptRoll(now: number, lastRoll: number?): boolean
	return lastRoll == nil or now - lastRoll >= MissileRules.TUNING.rollMinInterval
end

-- The counterplay hint under the incoming badge (brief, MK style). vehicle "plane" | "car"; held: the held item colour.
function MissileRules.counterHint(vehicle: string?, held: string?, dragging: boolean?): string?
	if dragging then
		return "TRAP BEHIND"
	elseif vehicle == "plane" then
		return "DOUBLE-TAP TO DODGE"
	elseif held == "green" then
		return "HOLD ITEM: TRAP BEHIND"
	elseif held == "yellow" then
		return "HORN IT AWAY!" -- v38: the horn destroys a shot inside its ring (timed on the beeps)
	elseif held == "orbit_missiles" then
		return "ORBITERS BLOCK IT"
	end
	return nil
end

-- Screen angle (degrees, 0 = up/ahead, 90 = right, 180 = behind) of a threat at (dx, dz) from the racer, for a camera
-- looking along (lookX, lookZ). Flat; pure.
function MissileRules.arrowAngle(dx: number, dz: number, lookX: number, lookZ: number): number
	local lm = math.sqrt(lookX * lookX + lookZ * lookZ)
	local dm = math.sqrt(dx * dx + dz * dz)
	if lm < 1e-4 or dm < 1e-4 then
		return 180
	end
	local fx, fz = lookX / lm, lookZ / lm
	local tx, tz = dx / dm, dz / dm
	-- right of the look direction (Roblox: Y up, so right = look x up = (-fz, fx))
	local rx, rz = -fz, fx
	local ahead = tx * fx + tz * fz
	local right = tx * rx + tz * rz
	local deg = math.deg(math.atan2(right, ahead))
	return (deg + 360) % 360
end

-- Client press semantics for the item button. With a trap held, nothing fires on the press: a release before
-- dragHoldSeconds drops it ("use"); a hold past that drags it ("drag") and the release drops it ("use"). Any other
-- item fires on the press. Returns the action for this moment, or nil for "wait".
function MissileRules.pressAction(heldColor: string?, heldFor: number, released: boolean, dragging: boolean): ("use" | "drag")?
	if heldColor ~= "green" then
		return if heldFor == 0 and not released then "use" else nil
	end
	if released then
		return "use"
	end
	if not dragging and heldFor >= MissileRules.TUNING.dragHoldSeconds then
		return "drag"
	end
	return nil
end

return MissileRules
