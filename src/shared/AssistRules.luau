--!strict
-- ASSIST rules, pure (no Roblox globals; tools/tests/assist_spec.luau runs it under Lune). ASSIST = auto throttle plus the
-- plane's steering assist. The player owns the switch (the HUD chip, the T key, the gear panel's ASSIST row; saved in the
-- profile settings as "assist", default on); this file only says WHEN the auto throttle may act:
--   * only in a running race phase (after GO, before the finish; boss race and time trial are the "race" phase too), never
--     in the hub, on the grid, in a battle, at the finish or in the results;
--   * outside that (ASSIST off, or no race running) a touch car drives only while a finger is on the steer pad: lift it and the
--     car coasts to a stop. There is no gas button on a phone, so this hold-to-drive is the manual mode;
--   * never as a creep: a car that stands still with no steering, drift or gas input for IDLE_STOP_S stops being pushed
--     until the player touches the pad again (holding the brake while stopped counts as standing still, not as an input).
-- Throttle and the assist flag only: nothing here reads or changes adhesion, walls, barriers, kill volumes or rescue.
local AssistRules = {}

AssistRules.KEY = "assist" -- SettingsRules key (attribute AutoThrottle)
AssistRules.IDLE_STOP_S = 2 -- stopped and hands-off this long: the auto throttle lets go
AssistRules.STOP_SPEED = 3 -- studs/s: below this the car counts as stopped
AssistRules.MAX_DT = 0.25 -- a long frame (alt-tab, a stall) never fills the idle clock by itself

export type State = { idle: number, held: boolean, at: number }

function AssistRules.newState(): State
	return { idle = 0, held = false, at = 0 }
end

-- HudPhase names in which the auto throttle may act.
function AssistRules.racingPhase(phase: string): boolean
	return phase == "race"
end

-- The one-tap switch's state readout (the lane B banner, <= 1.2 s) and the chip's label.
AssistRules.BANNER_S = 1.2
function AssistRules.bannerText(on: boolean): string
	return if on then "ASSIST ON" else "ASSIST OFF"
end

-- One driving frame. `enabled` = the player's ASSIST switch, `racing` = racingPhase(HudPhase.phase()) and the local racer has
-- not finished, `steering` = any steer / drift / gas input this frame, `braking` = the brake is held, `speed` = |speed| in
-- studs/s, `now` = a monotonic clock. Returns whether a touch car should get its drive throttle this frame (ASSIST's auto
-- throttle in a race, else the hold-to-drive on the pad).
function AssistRules.step(s: State, now: number, enabled: boolean, racing: boolean, steering: boolean, braking: boolean, speed: number): boolean
	local dt = math.clamp(now - s.at, 0, AssistRules.MAX_DT)
	s.at = now
	if not enabled or not racing then
		s.idle = 0
		s.held = false
		return steering and not braking
	end
	if steering then
		s.idle = 0
		s.held = false
	elseif speed < AssistRules.STOP_SPEED then
		s.idle += dt -- brake held or no input at all: the same standing-still clock
		if s.idle >= AssistRules.IDLE_STOP_S then
			s.held = true
		end
	else
		s.idle = 0
	end
	return not s.held and not braking
end

return AssistRules
