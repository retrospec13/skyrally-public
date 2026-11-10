--!strict
-- Touch steering v2 for ground vehicles (owner 2026-10-21: "look online/git/etc for how to create excellent mobile vehicle
-- controls"; docs/research/MOBILE_CONTROLS_AND_REVERSE.md). Pure (no Roblox globals; tools/tests/touch_steer_spec.luau).
-- RaceUI feeds the raw pad vector through padVector (floating origin), CarController shapes it with steer / padBrake.
--
--   * Floating origin: the stick centres where the thumb lands (within ORIGIN_SLACK of the pad centre), so a thumb that lands
--     off centre is not an instant hard turn. Dragging past the radius clamps.
--   * Steer: a small dead zone (a resting thumb never drifts the car) and a mild expo (fine corrections near the centre, full
--     lock at the edge). v27 passed pad X straight through.
--   * Brake from the pad (fallback for the BRAKE button): a mostly-downward pull past PAD_BRAKE_Y, so a diagonal steer that
--     dips low no longer brakes or reverses by accident.
-- Input shaping only: nothing here touches adhesion, walls, barriers, kill volumes or rescue.
local TouchSteerRules = {}

TouchSteerRules.DEADZONE = 0.12
TouchSteerRules.EXPO = 0.35 -- (1 - e) x + e x^3 on the rescaled magnitude
TouchSteerRules.PAD_BRAKE_Y = 0.55 -- pad pulled down this far starts to brake
TouchSteerRules.PAD_BRAKE_FULL = 0.9 -- ... and brakes fully here
TouchSteerRules.PAD_BRAKE_SLOPE = 0.8 -- the pull must be at least this steep: -y >= SLOPE * |x|
TouchSteerRules.RADIUS_FRAC = 0.42 -- stick travel as a fraction of the pad side (v27 value)
TouchSteerRules.MIN_RADIUS = 48 -- px: never a twitchy stick on a small phone pad
TouchSteerRules.ORIGIN_SLACK = 0.22 -- the floating origin stays within this fraction of the pad side from its centre

-- Steer: dead zone + expo on pad X, sign kept, |out| <= 1.
function TouchSteerRules.steer(x: number): number
	local a = math.abs(x)
	if a <= TouchSteerRules.DEADZONE then
		return 0
	end
	local t = math.min(1, (a - TouchSteerRules.DEADZONE) / (1 - TouchSteerRules.DEADZONE))
	local e = TouchSteerRules.EXPO
	return math.sign(x) * ((1 - e) * t + e * t * t * t)
end

-- Brake magnitude 0..1 from the pad (y up = +1): only a mostly-downward pull past PAD_BRAKE_Y.
function TouchSteerRules.padBrake(x: number, y: number): number
	if y >= -TouchSteerRules.PAD_BRAKE_Y then
		return 0
	end
	if -y < TouchSteerRules.PAD_BRAKE_SLOPE * math.abs(x) then
		return 0
	end
	return math.clamp((-y - TouchSteerRules.PAD_BRAKE_Y) / (TouchSteerRules.PAD_BRAKE_FULL - TouchSteerRules.PAD_BRAKE_Y), 0, 1)
end

-- Stick radius (px) for a pad side (px).
function TouchSteerRules.radius(side: number): number
	return math.max(TouchSteerRules.MIN_RADIUS, side * TouchSteerRules.RADIUS_FRAC)
end

-- The floating origin for a touch that lands at (tx, ty) on a pad centred at (cx, cy) with side `side`: the landing point,
-- pulled back to within ORIGIN_SLACK * side of the centre.
function TouchSteerRules.origin(cx: number, cy: number, side: number, tx: number, ty: number): (number, number)
	local dx, dy = tx - cx, ty - cy
	local lim = side * TouchSteerRules.ORIGIN_SLACK
	local m = math.sqrt(dx * dx + dy * dy)
	if m > lim and m > 0 then
		dx, dy = dx / m * lim, dy / m * lim
	end
	return cx + dx, cy + dy
end

-- The pad vector for a thumb at (tx, ty) dragged from origin (ox, oy) with stick radius r: (puck dx, puck dy) in px (screen
-- axes, clamped to r) and the normalised (nx, ny) with y up, each -1..1.
function TouchSteerRules.padVector(ox: number, oy: number, r: number, tx: number, ty: number): (number, number, number, number)
	local dx, dy = tx - ox, ty - oy
	local m = math.sqrt(dx * dx + dy * dy)
	if m > r and m > 0 then
		dx, dy = dx / m * r, dy / m * r
	end
	return dx, dy, math.clamp(dx / r, -1, 1), math.clamp(-dy / r, -1, 1)
end

return TouchSteerRules
