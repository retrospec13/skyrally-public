--!strict
-- Human-like bot pace (economy v3 phase 4): a per-race skill multiplier so a slot is not the same speed every race, a
-- small start delay, short slips (a clipped corner, a late boost) and a short recovery after a hit. Pure: every draw
-- comes from the generator passed in (math.random live, a seeded one in tools/tests/bot_looks_spec.luau). AIRacers owns
-- WHEN these apply; the roster's base pace, the track's BotPace and the rubber band stay exactly as they were.
local BotPaceRules = {}

BotPaceRules.SKILL_MIN = 0.96 -- per-race multiplier on the roster base pace
BotPaceRules.SKILL_MAX = 1.03
BotPaceRules.DELAY_MIN = 0.1 -- s after GO before the bot leaves the grid
BotPaceRules.DELAY_MAX = 0.4
BotPaceRules.SLIP_FACTOR_MIN = 0.90 -- speed multiplier during a slip
BotPaceRules.SLIP_FACTOR_MAX = 0.95
BotPaceRules.SLIP_SECONDS_MIN = 0.6
BotPaceRules.SLIP_SECONDS_MAX = 1.4
BotPaceRules.SLIP_GAP_MIN = 20 -- s between two slips of one bot
BotPaceRules.SLIP_GAP_MAX = 55
BotPaceRules.FIRST_SLIP_MIN = 8 -- the first slip never comes in the opening seconds
BotPaceRules.HIT_RECOVER_SECONDS = 1.2 -- extra easing after a stun ends
BotPaceRules.HIT_RECOVER_FACTOR = 0.94

local function between(rng: () -> number, a: number, b: number): number
	return a + (b - a) * rng()
end

-- The sum of two draws, so most races land near the middle and the extremes are rare (a bell, not a flat spread).
function BotPaceRules.skill(rng: () -> number): number
	local mid = (BotPaceRules.SKILL_MIN + BotPaceRules.SKILL_MAX) * 0.5
	local half = (BotPaceRules.SKILL_MAX - BotPaceRules.SKILL_MIN) * 0.5
	return math.clamp(mid + half * (rng() + rng() - 1), BotPaceRules.SKILL_MIN, BotPaceRules.SKILL_MAX)
end

function BotPaceRules.startDelay(rng: () -> number): number
	return between(rng, BotPaceRules.DELAY_MIN, BotPaceRules.DELAY_MAX)
end

-- raceElapsed of this bot's next slip, drawn after `from` (the race clock now).
function BotPaceRules.nextSlipAt(rng: () -> number, from: number): number
	local gap = between(rng, BotPaceRules.SLIP_GAP_MIN, BotPaceRules.SLIP_GAP_MAX)
	return math.max(from, BotPaceRules.FIRST_SLIP_MIN) + gap
end

-- A slip's { seconds, factor }.
function BotPaceRules.slip(rng: () -> number): (number, number)
	return between(rng, BotPaceRules.SLIP_SECONDS_MIN, BotPaceRules.SLIP_SECONDS_MAX),
		between(rng, BotPaceRules.SLIP_FACTOR_MIN, BotPaceRules.SLIP_FACTOR_MAX)
end

-- The speed multiplier now, from the slip and recovery timers still running (the lower one wins, they never stack).
function BotPaceRules.factor(slipLeft: number, slipFactor: number, recoverLeft: number): number
	local f = 1
	if slipLeft > 0 then
		f = math.min(f, slipFactor)
	end
	if recoverLeft > 0 then
		f = math.min(f, BotPaceRules.HIT_RECOVER_FACTOR)
	end
	return f
end

return BotPaceRules
