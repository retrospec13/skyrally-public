--!strict
-- Dodge (plane barrel roll) input: DOUBLE-TAP left or right (owner 2026-10-21: "make it the dodge is double tap left or
-- right"). Pure (no Roblox globals; tools/tests/dodge_spec.luau). FlightController feeds step() one signed RAW direction per
-- frame: keyboard A/D and arrows and the D-pad as -1/0/1 BEFORE the key ramp, the gamepad stick's raw X, the touch steer
-- pad's raw X (or the side of the pad a finger lands on, so a plain tap counts). Never the shaped steer (the key ramp of
-- the 2026-10-20 flight feel pass kept a quick A/D tap under the old 0.85 threshold) and never the course assist.
--
-- A tap = the direction passes PRESS then falls under RELEASE within MAX_TAP. A second press on the SAME side within WINDOW
-- of the first press fires the dodge for that side. A single tap, a held steer, a slow second tap, or alternating sides
-- (slalom) never fires; a push the other way restarts the pattern on that side. The fire is consumed: holding the second press
-- or a third quick tap does not fire again (FlightController's cooldown, ROLL_COOLDOWN, also gates the roll itself).
local DodgeRules = {}

DodgeRules.PRESS = 0.5 -- |raw| at or above this is a press
DodgeRules.RELEASE = 0.25 -- |raw| under this is a release (the gap between the two is hysteresis)
DodgeRules.WINDOW = 0.3 -- s, first press -> second press
DodgeRules.MAX_TAP = 0.22 -- s, the first press must be released this fast: a hold through a turn never arms a dodge

export type State = {
	down: boolean, -- a press is currently held
	side: number, -- side of the press being held / armed (+1 right, -1 left)
	firstT: number, -- clock of the first press of the pattern
	armed: boolean, -- a short tap was released and its side is waiting for the second press
	spent: boolean, -- the press that fired is still held: nothing more until it is released
}

function DodgeRules.new(): State
	return { down = false, side = 0, firstT = -math.huge, armed = false, spent = false }
end

-- raw: signed direction, +1 right. Returns +1 / -1 on the frame a double tap completes, else 0.
function DodgeRules.step(f: State, raw: number, now: number): number
	local a = math.abs(raw)
	local s = if raw > 0 then 1 else -1
	if f.armed and now - f.firstT > DodgeRules.WINDOW then
		f.armed = false
	end
	if f.down then
		if a >= DodgeRules.PRESS and s ~= f.side then
			-- pushed straight through to the other side: a new first press there
			f.side, f.firstT, f.armed, f.spent = s, now, false, false
		elseif a < DodgeRules.RELEASE then
			f.down = false
			if f.spent then
				f.spent = false
			elseif now - f.firstT <= DodgeRules.MAX_TAP then
				f.armed = true
			else
				f.armed = false
			end
		end
		return 0
	end
	if a >= DodgeRules.PRESS then
		f.down = true
		if f.armed and s == f.side and now - f.firstT <= DodgeRules.WINDOW then
			f.armed, f.spent = false, true
			return s
		end
		f.side, f.firstT, f.armed, f.spent = s, now, false, false
	end
	return 0
end

-- The strongest of the raw sources (keys, stick, touch), sign kept.
function DodgeRules.pick(...: number): number
	local best = 0
	for _, v in { ... } do
		if math.abs(v) > math.abs(best) then
			best = v
		end
	end
	return math.clamp(best, -1, 1)
end

-- Touch: the side of the steer pad a finger lands on, -1..1 (pos and centre in px, half the pad side), so a tap on the left or
-- right half of the pad is a direction press even though the floating stick origin sits under the finger.
function DodgeRules.padSide(posX: number, centerX: number, side: number): number
	return math.clamp((posX - centerX) / math.max(1, side * 0.3), -1, 1)
end

return DodgeRules
