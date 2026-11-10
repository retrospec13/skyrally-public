--!strict
-- Trick and start rules (REMARKABLE Batch 1 items 5, 6 and 7): car Hop and Spin with Grid Bounce, the rev-match
-- start, and the plane barrel roll. Pure constants and helpers only, shared by CarController, FlightController and
-- tools/tests/tricks_spec.luau. (The spec put these in CarConfig/PlaneConfig; they live here so the trick lane does
-- not edit the shared config files other lanes touch.)
--
-- Fairness (REMARKABLE ground rules): every reward reuses a boost tier the game already has. A stuck ramp trick and a
-- perfect car start use CarConfig.DRIFT_LEVELS[1] (150 for 0.6 / 0.8 s), a perfect plane start is the normal ring
-- boost cut to 0.8 s, and THREADED! only lengthens a ring boost by ROLL_RING_BONUS at the same BOOST_SPEED. Nothing
-- raises CarConfig.maxHorizontalSpeed() or the FlightServer 0..260 clamp, and bots never get any of it.
local TrickRules = {}

-- ---------------------------------------------------------------- car hop and spin (item 5)
TrickRules.HOP_VY = 26 -- apex ~2.4 studs, ~0.37 s of air on flat road with CarConfig.GRAVITY 140
TrickRules.HOP_COOLDOWN = 0.6
TrickRules.HOP_MIN_SPEED = 22.5 -- CarConfig.DRIFT_MIN_SPEED * 0.5
TrickRules.HOP_STEER_MAX = 0.3 -- CarConfig.DRIFT_STEER_START: steering at the press starts a drift, not a hop
TrickRules.SPIN_STEER_MIN = 0.5 -- airborne press with at least this much steer spins the body
TrickRules.SPIN_DEG_PER_S = 1440 -- 0.25 s a turn: a hop's ~0.37 s of air fits one spin from a quick double tap
TrickRules.SPIN_MAX_DEG = 720 -- at most two queued turns per airtime
TrickRules.LAND_TOLERANCE_DEG = 35 -- overshoot past upright still counts as stuck
-- A spin still this far from finishing when the wheels touch is whipped round on landing and counts: a hop's air is
-- short and a double tap is never instant. A greedy double spin on a small hop still flubs.
TrickRules.LAND_GRACE_DEG = 100
TrickRules.MIN_AIR = 0.55 -- a stuck landing earns the boost only after this much air (ramps and lips, never a hop)
TrickRules.BOOST_TIME = 0.6
TrickRules.FLUB_SPEED_KEEP = 0.85
TrickRules.FLUB_UNWIND_TIME = 0.25 -- a flubbed spin unwinds to upright over this long
TrickRules.FLUB_WOBBLE_TIME = 0.55
-- Grid Bounce: body-only bounce on the start line (hull, simPos and velocity stay frozen).
TrickRules.GRID_HOP_TIME = 0.34
TrickRules.GRID_HOP_HEIGHT = 1.6
TrickRules.GRID_HOP_COOLDOWN = 0.12

-- ---------------------------------------------------------------- rev-match start (item 6)
TrickRules.START_WINDOW_LO = 0.85 -- seconds before GO: the "1" numeral appears at 1.0
TrickRules.START_WINDOW_HI = 1.15
TrickRules.START_FLOOD_LEFT = 2.0 -- gas held since before this many seconds to GO floods the engine
TrickRules.START_BOOST_TIME = 0.8
TrickRules.FLOOD_TIME = 0.5
TrickRules.FLOOD_THROTTLE_CAP = 0.6
TrickRules.TOUCH_TAP_SHOW_LEFT = 1.4 -- the touch START ring appears this long before GO
TrickRules.REV_PITCH_BASE = 0.75 -- grid engine pitch = BASE + SPAN * throttle (SoundJuice range 0.75..1.65)
TrickRules.REV_PITCH_SPAN = 0.6

-- ---------------------------------------------------------------- plane barrel roll (item 7)
TrickRules.ROLL_TIME = 0.45
TrickRules.ROLL_COOLDOWN = 1.2
TrickRules.ROLL_RING_BONUS = 0.4
-- The roll is triggered by a double tap left or right: shared/DodgeRules (window, tap length, thresholds).
TrickRules.GRID_WOBBLE_TIME = 0.5
TrickRules.GRID_WOBBLE_DEG = 25

-- ================================================================ helpers
-- Signed angle in [-180, 180).
function TrickRules.wrap180(deg: number): number
	return ((deg + 180) % 360) - 180
end

-- Moves cur toward target by at most maxStep.
function TrickRules.approach(cur: number, target: number, maxStep: number): number
	local d = target - cur
	if math.abs(d) <= maxStep then
		return target
	end
	return cur + math.sign(d) * maxStep
end

-- Hop on a drift press: grounded, not already drifting or spinning out, stick near centre, rolling, off cooldown.
function TrickRules.canHop(grounded: boolean, drifting: boolean, spinningOut: boolean, steer: number, speed: number, cooldown: number): boolean
	return grounded
		and not drifting
		and not spinningOut
		and math.abs(steer) < TrickRules.HOP_STEER_MAX
		and speed >= TrickRules.HOP_MIN_SPEED
		and cooldown <= 0
end

-- Adds one queued turn in the steer direction, capped at SPIN_MAX_DEG either way from where the airtime started.
function TrickRules.queueSpin(target: number, steer: number): number
	if math.abs(steer) < TrickRules.SPIN_STEER_MIN then
		return target
	end
	return math.clamp(target + 360 * math.sign(steer), -TrickRules.SPIN_MAX_DEG, TrickRules.SPIN_MAX_DEG)
end

-- Landing verdict for a spin that was started this airtime: "stuck" when the body is upright (target reached, or
-- overshoot within LAND_TOLERANCE_DEG, or still short by no more than LAND_GRACE_DEG), else "flub".
function TrickRules.trickLanded(target: number, spin: number): boolean
	local remaining = (target - spin) * (if target >= 0 then 1 else -1) -- > 0: not finished yet
	if remaining >= 0 then
		return remaining <= TrickRules.LAND_GRACE_DEG
	end
	return -remaining <= TrickRules.LAND_TOLERANCE_DEG
end

-- Hop airtime is not a way across grass or shallow water (review fix): the slow surface the hop left keeps braking the
-- car in the air exactly as it would on the ground (speed above that surface's top eases down at
-- max(coastDecel, excess * overspeedDecay)), so hop spam across a shortcut is never faster than driving through it.
function TrickRules.hopAirSpeed(speed: number, surfaceTop: number, dt: number, coastDecel: number, overspeedDecay: number): number
	if speed <= surfaceTop then
		return speed
	end
	return math.max(surfaceTop, speed - math.max(coastDecel, (speed - surfaceTop) * overspeedDecay) * dt)
end

function TrickRules.trickBoostEligible(air: number): boolean
	return air >= TrickRules.MIN_AIR
end

-- ---------------------------------------------------------------- rev-match start state machine
export type StartState = {
	state: string, -- "none" | "perfect" | "flooded"
	held: boolean,
	heldSinceLeft: number, -- seconds-to-GO when the current hold began
}

function TrickRules.newStart(): StartState
	return { state = "none", held = false, heldSinceLeft = 0 }
end

-- One grid frame. pressed = gas held (keyboard W, gamepad A/R2); left = seconds to GO; canFlood is false on touch
-- (auto-gas: touch players start through the tap ring and cannot flood). A press inside the window is perfect; gas
-- held since before START_FLOOD_LEFT floods; releasing clears a flood so the player can still recover.
function TrickRules.stepStart(st: StartState, pressed: boolean, left: number, canFlood: boolean): string
	if pressed and not st.held then
		st.heldSinceLeft = left
		if left >= TrickRules.START_WINDOW_LO and left <= TrickRules.START_WINDOW_HI then
			st.state = "perfect"
		end
	elseif not pressed and st.held and st.state == "flooded" then
		st.state = "none"
	end
	st.held = pressed
	if pressed and canFlood and st.heldSinceLeft > TrickRules.START_FLOOD_LEFT and st.state ~= "perfect" then
		st.state = "flooded"
	end
	return st.state
end

-- Touch START ring tapped: perfect inside the window, otherwise nothing (no flood on touch).
function TrickRules.tapStart(st: StartState, left: number): string
	if left >= TrickRules.START_WINDOW_LO and left <= TrickRules.START_WINDOW_HI and st.state ~= "flooded" then
		st.state = "perfect"
	end
	return st.state
end

-- Engine pitch on the grid for a throttle 0..1.
function TrickRules.revPitch(throttle: number): number
	return TrickRules.REV_PITCH_BASE + TrickRules.REV_PITCH_SPAN * math.clamp(throttle, 0, 1)
end

-- Roll angle (degrees) for the time left on a roll: eased in and out so it snaps through the middle.
function TrickRules.rollDeg(timer: number, dir: number): number
	local t = math.clamp(1 - timer / TrickRules.ROLL_TIME, 0, 1)
	local e = t * t * (3 - 2 * t)
	return 360 * e * dir
end

-- Grid wing wobble (plane on the start line): damped sine, bank degrees for the time since the press.
function TrickRules.gridWobbleDeg(elapsed: number, dir: number): number
	if elapsed < 0 or elapsed >= TrickRules.GRID_WOBBLE_TIME then
		return 0
	end
	local t = elapsed / TrickRules.GRID_WOBBLE_TIME
	return TrickRules.GRID_WOBBLE_DEG * dir * math.sin(t * math.pi * 3) * (1 - t)
end

return TrickRules
