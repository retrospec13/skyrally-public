--!strict
-- Reverse v2 (owner 2026-10-21: "going in reverse is an awful experience"; docs/research/MOBILE_CONTROLS_AND_REVERSE.md on
-- research-controls). Pure (no Roblox globals; tools/tests/reverse_spec.luau runs it under Lune). CarController reads it for
-- the brake/reverse state machine, the reverse speed curve, the reverse turn rate, the camera's reverse framing and the car
-- WRONG WAY sign.
--
-- Mario Kart / DKR rule: the brake slows the kart; once it has STOPPED, keep holding the brake for REVERSE_DELAY and it backs
-- up. Let go and it drives forward again. v27 reversed the instant speed fell to 1 stud/s, so every hard brake became an
-- accidental roll-back (CarController's old `speed > 1` branch).
--
-- OWNER RULE (wall and mountain driving untouched): input, the along-track speed TARGET, the yaw rate while reversing, the camera
-- and the HUD only. Nothing here reads or changes adhesion, the up vector, walls, barriers, kill volumes or the rescue timings;
-- slope gravity still applies to the speed CarController integrates, exactly as before.
local CarConfig = require(script.Parent.CarConfig)

local ReverseRules = {}

-- ---------------------------------------------------------------- state machine
ReverseRules.STOP_SPEED = 2 -- studs/s: at or under this (forward) the car counts as stopped
ReverseRules.REVERSE_DELAY = 0.28 -- s of brake held while stopped before the car backs up (MK feel, kills accidental roll-back)
ReverseRules.MAX_DT = 0.1 -- a long frame never fills the delay by itself
ReverseRules.BRAKE_DEADBAND = 0.05 -- |throttle| under this is no input

-- Reverse speed curve: exponential approach to -REVERSE_DRIVE_SPEED * magnitude with an acceleration floor, like the forward
-- ACCEL_RESPONSE / ACCEL_MIN pair: 0 -> 30 studs/s in about 0.4 s, 45 in about 1 s (v27: 0.67 s and never 45).
ReverseRules.REVERSE_RESPONSE = 2.4 -- 1/s
ReverseRules.REVERSE_ACCEL_MIN = 30 -- studs/s^2
ReverseRules.MIN_REVERSE_MAG = 0.6 -- once reversing, a part-pulled pad or a diagonal thumb still backs up at 60 percent or more

-- Reverse steering: a turn rate floor once rolling (v27 ramped from 0 so the car went straight first and swung late) and a
-- 0.9 factor (was 0.7). The sign stays as v27 and a real car: steering right while reversing swings the tail right.
ReverseRules.TURN_FACTOR = 0.9
ReverseRules.TURN_FLOOR = 0.55 -- of TURN_RATE_MAX once rolling at FLOOR_SPEED or faster
ReverseRules.FLOOR_SPEED = 8 -- studs/s: the floor ramps in from 0 here, so there is still no turning on the spot

-- Camera while reversing: a calmer heading follow (no whip as the tail swings) and a small pull-back so the car never backs
-- into the lens. Ramps with the reverse speed fraction.
ReverseRules.CAM_YAW_RESPONSE = 2.6 -- 1/s at full reverse speed (forward driving keeps CarConfig.CAM_YAW_RESPONSE)
ReverseRules.CAM_PULLBACK = 3 -- studs at full reverse speed

-- WRONG WAY for cars (the plane already has one): the travel direction more than AWAY_DEG off the course for WRONG_WAY_S
-- while moving. Standing still or a slow three-point turn holds the clock (never fills it, never clears it); facing the right
-- way clears it at once. A sign only: it never steers, slows or rescues the car.
ReverseRules.AWAY_DEG = 110
ReverseRules.WRONG_WAY_S = 3.0
ReverseRules.WRONG_WAY_MOVING = 10 -- studs/s: below this the clock holds

export type Mode = "drive" | "brake" | "hold" | "reverse"
export type State = { mode: Mode, holdT: number, awayT: number }

function ReverseRules.newState(): State
	return { mode = "drive", holdT = 0, awayT = 0 }
end

-- One frame of intent. throttle: the summed input (-1..1; negative = brake / reverse), speed: signed along-track speed.
-- Returns the mode the speed integration uses this frame:
--   "drive"   no brake input (forward gas or coast; a reversing car with gas brakes to 0 then drives, as before)
--   "brake"   brake held while rolling forward: decelerate toward 0, never past it
--   "hold"    brake held at a stop, the reverse delay still running: stay stopped
--   "reverse" brake held after the delay (or already rolling backwards): back up
function ReverseRules.step(s: State, throttle: number, speed: number, dt: number): Mode
	local d = math.clamp(dt, 0, ReverseRules.MAX_DT)
	if throttle >= -ReverseRules.BRAKE_DEADBAND then
		s.mode = "drive"
		s.holdT = 0
		return s.mode
	end
	if speed > ReverseRules.STOP_SPEED then
		s.mode = "brake"
		s.holdT = 0
		return s.mode
	end
	if s.mode == "reverse" or speed < -ReverseRules.STOP_SPEED then
		s.mode = "reverse"
		return s.mode
	end
	s.holdT += d
	if s.holdT >= ReverseRules.REVERSE_DELAY - 1e-9 then
		s.mode = "reverse"
	else
		s.mode = "hold"
	end
	return s.mode
end

-- The new along-track speed for a braking / holding / reversing frame (mode from step). brakeMag = -throttle (0..1).
-- Slope gravity, items and the magnet stay CarController's job after this, as before.
function ReverseRules.stepSpeed(mode: string, speed: number, brakeMag: number, dt: number): number
	local mag = math.clamp(brakeMag, 0, 1)
	if mode == "brake" then
		return math.max(0, speed - CarConfig.BRAKE_DECEL * mag * dt)
	elseif mode == "hold" then
		-- Stopped (or creeping either way under STOP_SPEED): settle to 0 at brake strength.
		if speed > 0 then
			return math.max(0, speed - CarConfig.BRAKE_DECEL * dt)
		end
		return math.min(0, speed + CarConfig.BRAKE_DECEL * dt)
	elseif mode == "reverse" then
		local target = -CarConfig.REVERSE_DRIVE_SPEED * math.max(ReverseRules.MIN_REVERSE_MAG, mag)
		if speed > target then
			local accel = math.max(ReverseRules.REVERSE_ACCEL_MIN, (speed - target) * ReverseRules.REVERSE_RESPONSE)
			return math.max(target, speed - accel * dt)
		end
		-- Faster backwards than the target (a part-released pad, a downhill): ease back up to it at brake strength.
		return math.min(target, speed + CarConfig.BRAKE_DECEL * 0.5 * dt)
	end
	return speed
end

-- Yaw rate (deg/s, before the steer input) while rolling backwards: the forward curve, floored at TURN_FLOOR of the peak once
-- the car moves at FLOOR_SPEED, times TURN_FACTOR. 0 at a standstill.
function ReverseRules.turnRate(speed: number): number
	local v = math.abs(speed)
	local floorRate = CarConfig.TURN_RATE_MAX * ReverseRules.TURN_FLOOR * math.clamp(v / ReverseRules.FLOOR_SPEED, 0, 1)
	return math.max(CarConfig.turnRate(v), floorRate) * ReverseRules.TURN_FACTOR
end

-- Signed yaw (deg/s) for a grip turn: steer * rate going forward; reversing turns the nose the other way (tail follows the
-- wheel, like a real car and Mario Kart). Drift arcs are CarController's (a drift cancels under DRIFT_CANCEL_SPEED anyway).
function ReverseRules.gripYaw(steer: number, speed: number): number
	if speed < 0 then
		return -steer * ReverseRules.turnRate(speed)
	end
	return steer * CarConfig.turnRate(speed)
end

-- Camera framing: (heading response 1/s, extra distance studs) for a signed speed. Forward driving returns the v27 values.
function ReverseRules.camera(speed: number): (number, number)
	if speed >= 0 then
		return CarConfig.CAM_YAW_RESPONSE, 0
	end
	local f = math.clamp(-speed / CarConfig.REVERSE_DRIVE_SPEED, 0, 1)
	local resp = CarConfig.CAM_YAW_RESPONSE + (ReverseRules.CAM_YAW_RESPONSE - CarConfig.CAM_YAW_RESPONSE) * f
	return resp, ReverseRules.CAM_PULLBACK * f
end

-- Signed heading error (deg, -180..180) from a flat direction (fx, fz) to the course tangent (tx, tz): + = the course is to the
-- left (FlightController's convention, so CourseArrow gets -yawErr).
function ReverseRules.yawErrDeg(fx: number, fz: number, tx: number, tz: number): number
	return math.deg(math.atan2(fz * tx - fx * tz, fx * tx + fz * tz))
end

-- One WRONG WAY tick. travelYawErr: yawErrDeg of the TRAVEL direction (the nose when going forward, the tail when reversing).
-- Returns whether the sign shows.
function ReverseRules.stepWrongWay(s: State, travelYawErr: number, speed: number, dt: number): boolean
	if math.abs(travelYawErr) <= ReverseRules.AWAY_DEG then
		s.awayT = 0
	elseif math.abs(speed) >= ReverseRules.WRONG_WAY_MOVING then
		s.awayT += math.clamp(dt, 0, 0.5)
	end
	return s.awayT >= ReverseRules.WRONG_WAY_S - 1e-9
end

-- HUD: the touch brake button's caption ("BRAKE", or "REV" while backing up).
function ReverseRules.brakeCaption(mode: string): string
	return if mode == "reverse" then "REV" else "BRAKE"
end

return ReverseRules
