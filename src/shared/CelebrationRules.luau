--!strict
-- Celebration FX maths (client/CelebrationFx; specced in tools/tests/celebration_spec.luau). Pure: no Instances, no clock.
-- Everything here keeps the owner's rules in numbers: small and short near the chase camera, counts scaled by the phone
-- particle scale, nothing past a cull distance, fixed shell/chain counts.
local CelebrationRules = {}

-- Palette (r, g, b 0..255), Sunshine-bright: shell tints cycle through these.
CelebrationRules.SHELL_COLORS = {
	{ 255, 96, 96 }, { 255, 200, 70 }, { 90, 220, 255 }, { 150, 255, 120 }, { 255, 130, 230 }, { 255, 255, 255 },
} :: { { number } }

-- Countdown pulse colour per label: 3 red, 2 amber, 1 yellow-green, GO green.
function CelebrationRules.countdownColor(label: string): { number }
	if label == "3" then
		return { 255, 30, 70 }
	elseif label == "2" then
		return { 255, 140, 0 }
	elseif label == "1" then
		return { 190, 255, 40 }
	end
	return { 110, 255, 130 } -- GO!
end

-- Ring size (studs) grows a little with each tick and is biggest on GO.
function CelebrationRules.countdownRingSize(label: string): number
	-- v19: 14/17/20/34 -> 20/24/28/44 (the thin red/amber ring on sunlit sand read as a faint line at chase distance)
	if label == "3" then
		return 20
	elseif label == "2" then
		return 24
	elseif label == "1" then
		return 28
	end
	return 44
end

-- Phone budget: a burst count scaled by Settings.particleScale(), at least 1 while the scale is above 0.
function CelebrationRules.count(n: number, scale: number): number
	if scale <= 0 then
		return 0
	end
	return math.max(1, math.floor(n * scale + 0.5))
end

CelebrationRules.CULL_NEAR = 140 -- full effect inside this distance from the camera
CelebrationRules.CULL_FAR = 420 -- nothing at or beyond it

-- 1 near the camera, 0 past CULL_FAR, linear between.
function CelebrationRules.cullScale(dist: number): number
	if dist <= CelebrationRules.CULL_NEAR then
		return 1
	elseif dist >= CelebrationRules.CULL_FAR then
		return 0
	end
	return 1 - (dist - CelebrationRules.CULL_NEAR) / (CelebrationRules.CULL_FAR - CelebrationRules.CULL_NEAR)
end

-- Small camera FOV pop: degrees added on GO (one write; the controller's own FOV response eases it back).
CelebrationRules.GO_FOV_POP = 4
function CelebrationRules.fovPop(low: boolean): number
	return if low then CelebrationRules.GO_FOV_POP * 0.5 else CelebrationRules.GO_FOV_POP
end

export type Shell = { delay: number, side: number, ahead: number, height: number, color: number }

-- The finish show: `n` shells (clamped 4..6) launched 0.22-0.3 s apart, alternating sides, rising heights, colours cycling.
-- Deterministic (no random) so it is testable and never different between two clients. `side` is -1..1 across the road,
-- `ahead` studs further away from the camera, `height` studs above the anchor where the shell opens.
function CelebrationRules.shellPlan(n: number): { Shell }
	local count = math.clamp(math.floor(n), 4, 6)
	local out: { Shell } = {}
	for i = 1, count do
		local sideSign = if i % 2 == 1 then -1 else 1
		local spread = 0.45 + 0.12 * ((i * 3) % 4) -- 0.45..0.81 of the half width
		table.insert(out, {
			delay = (i - 1) * 0.26 + (if i % 2 == 0 then 0.04 else 0),
			side = sideSign * spread,
			ahead = 12 + (i % 3) * 8,
			height = 30 + ((i * 5) % 4) * 5,
			color = (i - 1) % #CelebrationRules.SHELL_COLORS + 1,
		})
	end
	return out
end

CelebrationRules.SHELL_RISE = 0.55 -- seconds from launch trail to the explosion

export type Chain = { delay: number, along: number, size: number }

-- Boss finale: `n` chained explosions (clamped 3..6) down the body, from the tail to the head. `along` is -0.5..0.5 of the
-- body length; sizes swell then shrink; the last one is the biggest (the pop).
function CelebrationRules.bossChain(n: number): { Chain }
	local count = math.clamp(math.floor(n), 3, 6)
	local out: { Chain } = {}
	for i = 1, count do
		local k = (i - 1) / (count - 1)
		table.insert(out, {
			delay = (i - 1) * 0.13,
			along = -0.4 + 0.8 * k,
			size = if i == count then 1.4 else 0.8 + 0.3 * math.sin(math.pi * k),
		})
	end
	return out
end

-- Explosion flipbook size (studs) for a boss of the given bounding size: modest so it never fills the view.
function CelebrationRules.bossBurstSize(bodyLength: number): number
	return math.clamp(bodyLength * 0.16, 7, 15)
end

-- Final-lap vehicle aura: a low-key red-gold ember stream off the tail for the whole last lap, plus a thin trail ribbon
-- that only shows above AURA_TRAIL_FRAC of the reference top speed (hysteresis so it never flickers). Phone (scale
-- under AURA_TRAIL_MIN_SCALE): embers only, thinned, no ribbon.
CelebrationRules.AURA_EMBER_RATE = 10
CelebrationRules.AURA_TRAIL_FRAC = 0.6
CelebrationRules.AURA_TRAIL_HYST = 0.08
CelebrationRules.AURA_TRAIL_MIN_SCALE = 0.6
CelebrationRules.AURA_COLORS = { { 255, 120, 90 }, { 255, 200, 80 } } :: { { number } }

export type Aura = { emberRate: number, trail: boolean }

function CelebrationRules.auraPlan(scale: number): Aura
	local s = math.clamp(scale, 0, 1)
	return { emberRate = CelebrationRules.AURA_EMBER_RATE * s, trail = s >= CelebrationRules.AURA_TRAIL_MIN_SCALE }
end

-- Is the ribbon on at this speed? `wasOn` is the previous answer (a Schmitt trigger around AURA_TRAIL_FRAC * top).
function CelebrationRules.auraTrailOn(speed: number, top: number, wasOn: boolean): boolean
	local edge = top * CelebrationRules.AURA_TRAIL_FRAC
	local band = top * CelebrationRules.AURA_TRAIL_HYST
	return speed > (if wasOn then edge - band else edge + band)
end

-- The aura runs from the final-lap call until the local racer finishes (or has no vehicle any more).
function CelebrationRules.auraActive(finalLap: boolean, raceFinished: boolean, hasHull: boolean): boolean
	return finalLap and not raceFinished and hasHull
end

return CelebrationRules
