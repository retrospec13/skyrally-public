--!strict
-- Style chain, near-miss and lava-skim rules (REMARKABLE Batch 2 items 16 and 17). Pure numbers, strings and plain
-- tables only (no Roblox types), so tools/tests/style_spec.luau loads it under Lune. The client StyleChain (chain
-- state, HUD meter, sounds), StyleSense (the side and down rays) and the two controllers use exactly these helpers.
--
-- Fairness (REMARKABLE ground rules): nothing here grants speed, items or tokens. A chain is a score on the HUD and
-- the results card, near misses and lava skims are sparks, embers and a sound. Bots never feed a chain, and the chain
-- is off in battles.
local StyleRules = {}

-- ---------------------------------------------------------------- chain (item 17)
StyleRules.WINDOW = 3.2 -- seconds a chain stays alive after its last counted move
StyleRules.WINDOW_MIN = 2.2 -- the fuse shortens a little as the chain grows (0.05 s per point)
StyleRules.MAX_REPEAT = 3 -- the same move more than this many times running stops counting until a different one
StyleRules.MIN_SHOW = 2 -- the HUD meter appears from this chain length

-- Points per move. A move missing here never counts (hops, rings and pads are racing, not style).
StyleRules.POINTS = {
	Stuck = 1, -- car trick landed (STUCK IT!)
	StuckDouble = 2, -- a double spin landed
	Drift1 = 1, -- mini-turbo released at each tier
	Drift2 = 1,
	Drift3 = 2, -- the zone turbo (third tier)
	PerfectStart = 1,
	Roll = 1, -- plane barrel roll
	Threaded = 2, -- a roll through a boost ring
	NearMiss = 1,
	Squeeze = 2, -- both sides close at once (a tunnel mouth, a gap)
	LavaSkim = 1,
} :: { [string]: number }

-- The meter's small "last move" line.
StyleRules.LABELS = {
	Stuck = "STUCK IT",
	StuckDouble = "DOUBLE SPIN",
	Drift1 = "MINI TURBO",
	Drift2 = "SUPER TURBO",
	Drift3 = "ZONE TURBO",
	PerfectStart = "PERFECT START",
	Roll = "BARREL ROLL",
	Threaded = "THREADED",
	NearMiss = "NEAR MISS",
	Squeeze = "SQUEEZE",
	LavaSkim = "LAVA SKIM",
} :: { [string]: string }

-- Zone callouts: our own words, one per zone, shown in the chain meter at the zone milestone.
StyleRules.ZONE_CALLOUT = {
	DINO = "ERUPTION!",
	SNOW = "ICE COLD!",
	ISLAND = "AHOY!",
	FOREST = "GUST!",
	SPACE = "ORBITAL!",
	HUB = "SHOWBOAT!",
} :: { [string]: string }
StyleRules.DEFAULT_CALLOUT = "SKY HIGH!"

-- Zone colours {r, g, b} 0-255: the chain meter's milestone flash, the third drift tier's sparks (CarConfig reads
-- these through driftColor) and the zone-turbo burst. Our own palette: magma gold, ice white, seafoam, meadow lime,
-- neon violet, coral pink.
StyleRules.ZONE_COLOR = {
	DINO = { 255, 184, 40 },
	SNOW = { 222, 244, 255 },
	ISLAND = { 80, 238, 196 },
	FOREST = { 166, 240, 84 },
	SPACE = { 186, 92, 255 },
	HUB = { 255, 128, 186 },
} :: { [string]: { number } }
StyleRules.DEFAULT_COLOR = { 186, 92, 255 } :: { number }

-- Milestones: crossing `at` shows the text in the meter (and plays the zone sting from `sting`).
StyleRules.MILESTONES = {
	{ at = 3, tier = 1 }, -- NICE!
	{ at = 5, tier = 2 }, -- the zone callout
	{ at = 8, tier = 3 }, -- SUPER <zone>
	{ at = 12, tier = 4 }, -- MEGA <zone>
	{ at = 16, tier = 5 }, -- <zone> LEGEND (and every LEGEND_STEP after)
} :: { { at: number, tier: number } }
StyleRules.LEGEND_STEP = 4

export type Chain = {
	count: number, -- current chain (sum of points)
	timer: number, -- seconds left before it banks
	best: number, -- best chain this race
	bestText: string, -- the highest milestone text the best chain reached ("" below the first)
	lastKind: string,
	repeatN: number,
	moves: number, -- counted moves in the current chain
	tier: number, -- highest milestone tier reached in the current chain
}

function StyleRules.newChain(): Chain
	return { count = 0, timer = 0, best = 0, bestText = "", lastKind = "", repeatN = 0, moves = 0, tier = 0 }
end

-- Resets the chain and the race best (a new race).
function StyleRules.resetRace(c: Chain)
	c.count, c.timer, c.best, c.bestText, c.lastKind, c.repeatN, c.moves, c.tier = 0, 0, 0, "", "", 0, 0, 0
end

function StyleRules.callout(zone: string?): string
	return (if zone then StyleRules.ZONE_CALLOUT[zone] else nil) or StyleRules.DEFAULT_CALLOUT
end

function StyleRules.color(zone: string?): { number }
	return (if zone then StyleRules.ZONE_COLOR[zone] else nil) or StyleRules.DEFAULT_COLOR
end

-- The text a milestone tier shows in a zone ("ERUPTION!" -> "SUPER ERUPTION!").
function StyleRules.milestoneText(tier: number, zone: string?): string
	local call = StyleRules.callout(zone)
	local bare = string.gsub(call, "!$", "")
	if tier <= 0 then
		return ""
	elseif tier == 1 then
		return "NICE!"
	elseif tier == 2 then
		return call
	elseif tier == 3 then
		return "SUPER " .. call
	elseif tier == 4 then
		return "MEGA " .. call
	end
	return bare .. " LEGEND!"
end

-- Highest milestone tier at or below a chain length (the LEGEND tier repeats every LEGEND_STEP past the last one).
function StyleRules.tierAt(count: number): number
	local tier = 0
	for _, m in StyleRules.MILESTONES do
		if count >= m.at then
			tier = m.tier
		end
	end
	return tier
end

-- Whether going from `before` to `after` crosses a milestone (including each LEGEND step). Returns its tier or 0.
function StyleRules.crossed(before: number, after: number): number
	local hit = 0
	for _, m in StyleRules.MILESTONES do
		if before < m.at and after >= m.at then
			hit = m.tier
		end
	end
	local last = StyleRules.MILESTONES[#StyleRules.MILESTONES]
	if hit == 0 and after > last.at then
		local stepB = math.floor((before - last.at) / StyleRules.LEGEND_STEP)
		local stepA = math.floor((after - last.at) / StyleRules.LEGEND_STEP)
		if before >= last.at and stepA > stepB then
			hit = last.tier
		end
	end
	return hit
end

function StyleRules.window(count: number): number
	return math.max(StyleRules.WINDOW_MIN, StyleRules.WINDOW - 0.05 * count)
end

-- Adds a move. Returns the points it added (0 = not a style move, or stale from repeating) and the milestone tier
-- it crossed (0 = none). The fuse restarts on every counted move.
function StyleRules.add(c: Chain, kind: string, zone: string?): (number, number)
	local pts = StyleRules.POINTS[kind]
	if not pts then
		return 0, 0
	end
	if kind == c.lastKind then
		c.repeatN += 1
	else
		c.lastKind = kind
		c.repeatN = 1
	end
	if c.repeatN > StyleRules.MAX_REPEAT then
		return 0, 0
	end
	local before = c.count
	c.count += pts
	c.moves += 1
	c.timer = StyleRules.window(c.count)
	local tier = StyleRules.crossed(before, c.count)
	if tier > c.tier then
		c.tier = tier
	end
	if c.count > c.best then
		c.best = c.count
		c.bestText = StyleRules.milestoneText(StyleRules.tierAt(c.count), zone)
	end
	return pts, tier
end

-- Advances the fuse. held = a sustained move is running (a drift charging, a lava skim): the fuse does not burn.
-- Returns the chain length when it banks (ran out), else 0.
function StyleRules.tick(c: Chain, dt: number, held: boolean): number
	if c.count <= 0 then
		return 0
	end
	if not held then
		c.timer -= dt
	end
	if c.timer <= 0 then
		local banked = c.count
		c.count, c.timer, c.lastKind, c.repeatN, c.moves, c.tier = 0, 0, "", 0, 0, 0
		return banked
	end
	return 0
end

-- A crash, spin-out, flubbed trick or respawn drops the current chain (the race best stays). Returns what was lost.
function StyleRules.breakChain(c: Chain): number
	local lost = c.count
	c.count, c.timer, c.lastKind, c.repeatN, c.moves, c.tier = 0, 0, "", 0, 0, 0
	return lost
end

-- The tick note for each counted move climbs a major pentatonic over two octaves (ratios of the base sample), so a
-- chain plays a rising scale; past the top it stays on the top note.
StyleRules.PENTATONIC = { 1, 9 / 8, 5 / 4, 3 / 2, 5 / 3 } :: { number }
function StyleRules.tickPitch(moves: number): number
	local i = math.clamp(math.floor(moves) - 1, 0, 9)
	local octave = i // 5
	return StyleRules.PENTATONIC[i % 5 + 1] * (2 ^ octave)
end

-- ---------------------------------------------------------------- near miss (item 16)
-- Two side rays (left and right of the vehicle) at NEAR_HZ while the speed is at least NEAR_SPEED_FRAC of the
-- vehicle's top speed. dist = distance from the vehicle's centre to the hit along the side ray (nil = clear).
StyleRules.NEAR_HZ = 20
StyleRules.NEAR_SPEED_FRAC = 0.8
StyleRules.NEAR_COOLDOWN = 0.9 -- per side
StyleRules.NEAR_CONTACT_GRACE = 0.5 -- a wall touched this recently voids the near miss (that was a scrape)
export type NearProfile = { halfWidth: number, band: number, minGap: number }
StyleRules.NEAR = {
	car = { halfWidth = 3.2, band = 3.6, minGap = 0.35 }, -- body half width 3.15; near = 0.35..3.6 studs of air
	plane = { halfWidth = 7.8, band = 8, minGap = 1.0 }, -- wingtips at 7.6
} :: { [string]: NearProfile }

-- "clear" | "near" | "touch" for one side.
function StyleRules.gapClass(dist: number?, p: NearProfile): string
	if dist == nil then
		return "clear"
	end
	local gap = dist - p.halfWidth
	if gap < p.minGap then
		return "touch"
	elseif gap <= p.band then
		return "near"
	end
	return "clear"
end

-- The ray length that covers the band.
function StyleRules.nearReach(p: NearProfile): number
	return p.halfWidth + p.band + 0.5
end

export type NearState = { left: string, right: string, coolL: number, coolR: number }
function StyleRules.newNear(): NearState
	return { left = "clear", right = "clear", coolL = -math.huge, coolR = -math.huge }
end

-- One sample. Returns the move ("NearMiss" | "Squeeze" | nil) and the side it happened on (-1 left, 1 right, 0 both).
-- A side counts on its rising edge from clear into near (a touch never counts, and a side must clear again before it
-- can count again), only at speed, outside its cooldown and with no wall contact in the last NEAR_CONTACT_GRACE.
function StyleRules.nearStep(s: NearState, leftDist: number?, rightDist: number?, p: NearProfile, now: number, fast: boolean, lastContact: number): (string?, number)
	local l = StyleRules.gapClass(leftDist, p)
	local r = StyleRules.gapClass(rightDist, p)
	local okContact = now - lastContact >= StyleRules.NEAR_CONTACT_GRACE
	local hitL = fast and okContact and l == "near" and s.left == "clear" and now - s.coolL >= StyleRules.NEAR_COOLDOWN
	local hitR = fast and okContact and r == "near" and s.right == "clear" and now - s.coolR >= StyleRules.NEAR_COOLDOWN
	-- "touch" sticks until the side clears: a scrape that eases off into the band is not a near miss.
	s.left = if l == "near" and s.left == "touch" then "touch" else l
	s.right = if r == "near" and s.right == "touch" then "touch" else r
	if hitL then
		s.coolL = now
	end
	if hitR then
		s.coolR = now
	end
	if hitL and (hitR or r == "near") or hitR and l == "near" then
		s.coolL, s.coolR = now, now
		return "Squeeze", 0
	elseif hitL then
		return "NearMiss", -1
	elseif hitR then
		return "NearMiss", 1
	end
	return nil, 0
end

-- ---------------------------------------------------------------- lava skim (item 16)
-- A down ray (and the side rays) finding lava: a lethal hazard part or lava terrain. gap = height of the vehicle's
-- underside above it. Skimming = gap within SKIM_MIN..SKIM_MAX; GRACE bridges a sample or two of no lava (a rock
-- island in the lake) so the wake does not flicker.
StyleRules.SKIM_MIN = 1.5
StyleRules.SKIM_MAX = 16
StyleRules.SKIM_TICK = 1.0 -- a long skim counts again every this many seconds (still subject to MAX_REPEAT)
StyleRules.SKIM_GRACE = 0.35
StyleRules.SKIM_HZ = 10

export type SkimState = { active: boolean, held: number, since: number, lost: number }
function StyleRules.newSkim(): SkimState
	return { active = false, held = 0, since = 0, lost = 0 }
end

-- One sample (dt = time since the last sample). Returns the move to add ("LavaSkim" on entering and every SKIM_TICK
-- while it lasts) and whether the skim is active (the ember wake).
function StyleRules.skimStep(s: SkimState, gap: number?, dt: number): (string?, boolean)
	local inBand = gap ~= nil and gap >= StyleRules.SKIM_MIN and gap <= StyleRules.SKIM_MAX
	if inBand then
		s.lost = 0
		if not s.active then
			s.active = true
			s.held = 0
			s.since = 0
			return "LavaSkim", true
		end
		s.held += dt
		s.since += dt
		if s.since >= StyleRules.SKIM_TICK then
			s.since -= StyleRules.SKIM_TICK
			return "LavaSkim", true
		end
		return nil, true
	end
	if s.active then
		s.lost += dt
		if s.lost > StyleRules.SKIM_GRACE then
			s.active = false
			s.held, s.since, s.lost = 0, 0, 0
			return nil, false
		end
		return nil, true
	end
	return nil, false
end

-- ---------------------------------------------------------------- lava heat (DINO ember spray + haze)
-- Beyond the skim band the same down ray still feels lava up to HEAT_MAX below: a thin ember spray that fades with
-- height (full inside the skim band) and, on a thick particle budget only, a faint charcoal heat haze.
StyleRules.HEAT_MAX = 40
StyleRules.HEAT_EMBER_RATE = 26 -- v21: was 18
StyleRules.HEAT_HAZE_RATE = 6
StyleRules.HEAT_HAZE_MIN_SCALE = 0.6

-- 0..1 heat from the gap above lava (nil = no lava below): 1 within the skim band, linear to 0 at HEAT_MAX.
function StyleRules.lavaHeat(gap: number?): number
	if gap == nil or gap > StyleRules.HEAT_MAX then
		return 0
	elseif gap <= StyleRules.SKIM_MAX then
		return 1
	end
	return 1 - (gap - StyleRules.SKIM_MAX) / (StyleRules.HEAT_MAX - StyleRules.SKIM_MAX)
end

-- Emitter rates (ember, haze) for a heat value under the particle scale; the haze is dropped on phone.
function StyleRules.heatRates(heat: number, scale: number): (number, number)
	local h = math.clamp(heat, 0, 1)
	local s = math.clamp(scale, 0, 1)
	local haze = if s >= StyleRules.HEAT_HAZE_MIN_SCALE then StyleRules.HEAT_HAZE_RATE * h * s else 0
	return StyleRules.HEAT_EMBER_RATE * h * s, haze
end

return StyleRules
