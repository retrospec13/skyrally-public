--!strict
-- Dressing LOD (owner, SNOW-1 play-test 2026-10-20: "whats up with all the floating assets in this test?"). Pure rules
-- for client/DressingLod; design and Studio recipe in docs/design/DRESSING_LOD.md.
--
-- Roblox stops drawing terrain past a render distance that shrinks with the graphics level (measured on DINO-4, D7
-- probe: about 500 studs at Level01, 600-800 at Level05), on phones and under Automatic whenever the frame-rate manager
-- lowers detail. Parts and meshes stay drawn much further, so set dressing (MapAdapter's SetDressing props: pine
-- clusters with their snow mounds, rocks, lantern posts, fences) that stands on far terrain floats in the sky. The
-- client hides each terrain-grounded prop past a radius tied to that terrain draw distance, so the prop and its ground
-- vanish together; past the cut the Backdrop shells (kit/Backdrop) stand in for the ground.
--
-- * Radius: a manual graphics level (UserGameSettings.SavedQualityLevel 1-10, or the Studio
--   settings().Rendering.QualityLevel 1-21) maps to a conservative radius just inside the measured cut. Automatic
--   (level 0) adapts from the smoothed frame time, the frame-rate manager's own input: fast frames keep a wide radius,
--   slow ones pull it to the Level01 cut. Phone tier under Automatic uses the Level01 cut. The applied radius drops at
--   once (floating is the bug) and grows back slowly.
-- * Per prop: hidden past the radius, shown again only inside radius - HYST (no flicker at the edge).
-- * Grouping by ground: a prop on terrain (or on nothing) is LOD'd on its own base point; a prop standing on another
--   managed prop follows that prop (same group, they vanish together); a prop standing on any other part (bridge, lodge,
--   wall, a part-built mountain) stays drawn, because its ground is a part that stays drawn.
-- * Budget: at most MAX_PARTS_PER_STEP part writes per step; hides first, the rest waits for the next step.
-- * Fade (adaptive haze, docs/design/ADAPTIVE_HAZE.md): over the last FADE studs inside the radius a prop steps
--   through FADE_STEPS transparency levels instead of popping, so it thins into the haze that client/AdaptiveHaze
--   thickens at the same radius. A hidden prop still shows again only inside radius - HYST.
-- * Per-map scenery (MAP_SCENERY): compiled scenery folders (FOREST-1 groves, hedgerows, far windmills...) whose models
--   join the LOD like SetDressing, with the map's own size cap.
-- Hiding is LocalTransparencyModifier on the client only: collision, queries and the server are untouched. Never a
-- terrain voxel, barrier, kill volume, course part, trigger, pod, hazard or anything bigger than MAX_EXTENT.
local DressingLodRules = {}

DressingLodRules.TICK = 0.2 -- seconds between passes (5 Hz)
DressingLodRules.MAX_PARTS_PER_STEP = 300
DressingLodRules.HYST = 40 -- a hidden prop shows again only inside radius - HYST
DressingLodRules.MAX_EXTENT = 80 -- a "prop" bigger than this on any axis may be something you drive on: never managed
DressingLodRules.FOLDER = "SetDressing" -- MapAdapter step 7b
DressingLodRules.OPT_IN_ATTR = "DressingLod" -- any other decorative Model can opt in with this attribute = true
DressingLodRules.GROUND_ATTR = "DressGround" -- optional override: "terrain" | "part" | "none"
DressingLodRules.GAMEPLAY_ATTRS = table.freeze({ "TriggerType", "ItemPodSpawn", "HazardType", "Checkpoint", "KillVolume" }) :: { string }
DressingLodRules.OFF_ATTR = "DressingLodOff" -- workspace attribute (Studio A/B): true shows everything, LOD stops
DressingLodRules.RADIUS_ATTR = "DressingLodRadius" -- workspace attribute (Studio QA): a number forces the radius
DressingLodRules.FADE = 60 -- studs inside the radius over which a prop fades out
DressingLodRules.FADE_STEPS = 4 -- transparency levels 0 (drawn) .. FADE_STEPS (hidden); 0.25 per step

-- Compiled scenery that joins the LOD per map (adaptive haze review, owner FOREST-1 report 2026-10-20). Each path is a
-- folder under the map root; every Model inside it (through sub-folders, not into models) is managed like a SetDressing
-- prop, with maxExtent in place of MAX_EXTENT. Ground, gameplay and Backdrop checks still apply: a prop on a part
-- stays drawn, collision never changes. FOREST-1 (plan groups, map/forest1/plan.json; route distance median / max):
-- groves 221/640, rim groves 446/760, trees 192/648, poplars 116/350, river bank 362/519, hedgerows 174/423, rocks
-- 207/456, bushes 234/633, far ridge windmills (Windmill#far 74-87 studs, 250-565 off the line; the start and tunnel
-- mills are over 100 and stay). Not the aqueduct (159, spans the course), FarHills (backdrop-sized) or the tunnel.
export type Scenery = { folders: { string }, maxExtent: number }
DressingLodRules.MAP_SCENERY = table.freeze({
	["FOREST-1"] = {
		folders = {
			"Scenery/Groves", "Scenery/RimGroves", "Scenery/Trees", "Scenery/Poplars", "Scenery/RiverBank",
			"Scenery/Hedgerows", "Scenery/Rocks", "Scenery/Bushes", "MillYard", "Windmills",
		},
		maxExtent = 100,
	},
	-- Palms on the far headlands (median 147, max 493 off the line).
	["ISLAND-2"] = { folders = { "Palms" }, maxExtent = 60 },
	-- Ruins, totems and bones on the far cave floor (no lavafalls: their emitters would stay drawn).
	["DINO-4"] = { folders = { "Dressing/Ruins", "Dressing/Totems", "Dressing/Bones" }, maxExtent = 80 },
}) :: { [string]: Scenery }

-- Radius by Studio rendering level (Enum.QualityLevel Level01..Level21). Measured: terrain cut ~500 at Level01 and
-- 600-800 at Level05 (DINO-4 D7). Each value sits inside the measured cut so a prop vanishes before its ground. Levels
-- above 5 are not measured yet: they rise slowly and the LOD stops at OFF_LEVEL (terrain is drawn to the horizon haze).
DressingLodRules.LEVEL_RADIUS = table.freeze({
	[1] = 450, [2] = 470, [3] = 500, [4] = 530, [5] = 560,
	[6] = 620, [7] = 690, [8] = 760, [9] = 830, [10] = 900,
	[11] = 1000, [12] = 1120, [13] = 1260, [14] = 1420,
}) :: { [number]: number }
DressingLodRules.OFF_LEVEL = 15 -- rendering level 15+: no LOD (radius math.huge)

-- Automatic: radius from the smoothed frame time (ms). <= FAST_MS keeps AUTO_MAX (the Level05 cut), >= SLOW_MS is the
-- Level01 cut, linear between, quantised to QUANT studs so a jittery frame time never moves it.
DressingLodRules.AUTO_MIN = 450
DressingLodRules.AUTO_MAX = 550
DressingLodRules.FAST_MS = 17
DressingLodRules.SLOW_MS = 33
DressingLodRules.QUANT = 25
DressingLodRules.FRAME_TAU = 2 -- seconds, frame-time smoothing
DressingLodRules.RISE = 30 -- studs per second the applied radius may grow

-- Pump guard (QA V5A, 2026-10-20: DressingLod radius and the adaptive haze swung 450 -> 525 -> 450 -> 525 within 3 s at race
-- start). The map load and the countdown spike the frame time for a moment, and Automatic reads that as "slow, then fast,
-- then slow". Three layers, all pure and all inside the Automatic estimate only (a manual level, the slider and the forced
-- radius never go through them, and nothing here touches terrain, collision, walls or rescue):
--   1. Settle: frame samples are ignored for SETTLE_S after a map switch or race start (and until SETTLE_S after GO), so the
--      load and the countdown never enter the smoothed frame time.
--   2. Sample cap: one frame counts at most SAMPLE_CAP_MS and weighs at most SAMPLE_DT_CAP seconds, so a single hitch (or a
--      stall) cannot drag the average across the whole FAST..SLOW range by itself.
--   3. Governor: the Automatic radius narrows at most one QUANT step per STEP_DOWN_HOLD s (the safe side), and widens one step
--      only after the raw estimate has stayed wider than the applied radius for a whole STEP_UP_HOLD s without a break (a wide
--      radius must be earned by a calm stretch; any dip back resets the clock). While settling it holds.
-- Together: no change faster than one step per STEP_DOWN_HOLD, and a spiky series ratchets down and stays there instead of
-- flipping: reversals need an unbroken calm stretch of STEP_UP_HOLD.
DressingLodRules.SETTLE_S = 6
DressingLodRules.SAMPLE_CAP_MS = 50
DressingLodRules.SAMPLE_DT_CAP = 0.05
DressingLodRules.STEP_DOWN_HOLD = 1.5
DressingLodRules.STEP_UP_HOLD = 6

-- Frame-time smoothing with the settle window and the sample cap. `now`/`mutedUntil` share one clock; while now <
-- mutedUntil the sample is ignored.
function DressingLodRules.sampleFrame(prevMs: number, dtSec: number, now: number, mutedUntil: number): number
	if now < mutedUntil then
		return prevMs
	end
	local dt = math.max(0, dtSec)
	local ms = math.clamp(dt * 1000, 0, DressingLodRules.SAMPLE_CAP_MS)
	local a = 1 - math.exp(-math.min(dt, DressingLodRules.SAMPLE_DT_CAP) / DressingLodRules.FRAME_TAU)
	return prevMs + (ms - prevMs) * a
end

-- When samples may count again after a map switch or a race start. goIn: seconds until GO when it is known and ahead
-- (the countdown), else nil/0. The later of the two wins, and an earlier window is never shortened.
function DressingLodRules.settleUntil(now: number, goIn: number?, current: number?): number
	local untilT = now + DressingLodRules.SETTLE_S + math.max(0, goIn or 0)
	return math.max(untilT, current or 0)
end

export type Governor = { value: number?, changedAt: number, wideSince: number? }

function DressingLodRules.newGovernor(): Governor
	return { value = nil, changedAt = -math.huge, wideSince = nil }
end

-- The governed Automatic radius: raw is autoRadius(...) for the current smoothed frame time. The first call takes raw as is;
-- later calls hold while settling, move one QUANT step toward raw once the hold since the last change has passed, else hold.
function DressingLodRules.govern(g: Governor, raw: number, now: number, mutedUntil: number): number
	local cur = g.value
	if cur == nil then
		g.value = raw
		g.changedAt = now
		return raw
	end
	if now < mutedUntil then
		g.wideSince = nil
		return cur
	end
	if raw == cur then
		g.wideSince = nil
		return cur
	end
	local step = math.min(DressingLodRules.QUANT, math.abs(raw - cur))
	if raw > cur then
		local since = g.wideSince
		if since == nil then
			g.wideSince = now
			return cur
		end
		if now - since < DressingLodRules.STEP_UP_HOLD then
			return cur
		end
		g.value = cur + step
		g.changedAt = now
		g.wideSince = now -- the next step needs another unbroken calm stretch
		return cur + step
	end
	g.wideSince = nil
	if now - g.changedAt < DressingLodRules.STEP_DOWN_HOLD then
		return cur
	end
	g.value = cur - step
	g.changedAt = now
	return cur - step
end

-- User slider level (SavedQualityLevel 1..10) -> rendering level (1..21): 1 -> 1, 5 -> 10, 10 -> 21.
function DressingLodRules.renderLevel(saved: number): number
	local s = math.clamp(math.floor(saved + 0.5), 1, 10)
	return math.floor(1 + (s - 1) * 20 / 9 + 0.5)
end

function DressingLodRules.levelRadius(level: number): number
	local l = math.max(1, math.floor(level + 0.5))
	if l >= DressingLodRules.OFF_LEVEL then
		return math.huge
	end
	return DressingLodRules.LEVEL_RADIUS[l] :: number
end

-- Automatic: smoothed frame time (ms) -> radius. Phone tier always gets the Level01 cut.
function DressingLodRules.autoRadius(frameMs: number, phone: boolean): number
	if phone then
		return DressingLodRules.AUTO_MIN
	end
	local lo, hi = DressingLodRules.AUTO_MIN, DressingLodRules.AUTO_MAX
	local t = math.clamp((frameMs - DressingLodRules.FAST_MS) / (DressingLodRules.SLOW_MS - DressingLodRules.FAST_MS), 0, 1)
	local r = hi - (hi - lo) * t
	local q = DressingLodRules.QUANT
	return math.clamp(math.floor(r / q + 0.5) * q, lo, hi)
end

-- The target radius. studioLevel: settings().Rendering.QualityLevel as 0 (Automatic) or 1..21; savedLevel: the user
-- slider 0 (Automatic) or 1..10. A Studio override wins (it is what the Studio recipe sets), then the slider, then the
-- frame-time estimate. forced: the RADIUS_ATTR number, if any.
function DressingLodRules.targetRadius(studioLevel: number?, savedLevel: number?, frameMs: number, phone: boolean, forced: number?): number
	if type(forced) == "number" and forced > 0 then
		return forced
	end
	if type(studioLevel) == "number" and studioLevel >= 1 then
		return DressingLodRules.levelRadius(studioLevel)
	end
	if type(savedLevel) == "number" and savedLevel >= 1 then
		local r = DressingLodRules.levelRadius(DressingLodRules.renderLevel(savedLevel))
		-- A phone draws terrain short whatever the slider says: never past the Level05 cut there.
		return if phone then math.min(r, DressingLodRules.AUTO_MAX) else r
	end
	return DressingLodRules.autoRadius(frameMs, phone)
end

-- Applied radius: falls to the target at once, rises by at most RISE studs per second.
function DressingLodRules.stepRadius(current: number, target: number, dt: number): number
	if target <= current or current == math.huge then
		return target
	end
	if target == math.huge then
		-- the LOD switching off (a high manual level) shows everything at once
		return target
	end
	return math.min(target, current + DressingLodRules.RISE * math.max(0, dt))
end

-- Exponential smoothing of the frame time (ms) over FRAME_TAU seconds.
function DressingLodRules.smoothFrame(prevMs: number, dtSec: number): number
	local ms = math.clamp(dtSec * 1000, 0, 250)
	local a = 1 - math.exp(-math.max(0, dtSec) / DressingLodRules.FRAME_TAU)
	return prevMs + (ms - prevMs) * a
end

-- Visible next pass? Hidden past the radius; a hidden prop shows again only inside radius - HYST.
function DressingLodRules.wantVisible(dist: number, radius: number, visible: boolean): boolean
	if radius == math.huge then
		return true
	end
	if visible then
		return dist <= radius
	end
	return dist <= radius - DressingLodRules.HYST
end

-- Fade level next pass (0 drawn .. FADE_STEPS hidden). Past the radius: hidden. Inside it: the last FADE studs step
-- through the levels, changing only once the distance is most of a step past the current level (no shimmer at a step
-- edge). A hidden prop shows again only inside radius - HYST, as wantVisible. Coming back (level falling) moves at
-- most one level per pass, so a prop re-entering inside the HYST band fades in over a few passes instead of popping
-- straight to nearly opaque.
function DressingLodRules.fadeLevel(dist: number, radius: number, cur: number): number
	local steps = DressingLodRules.FADE_STEPS
	if radius == math.huge then
		return 0
	end
	if dist > radius or (cur >= steps and dist > radius - DressingLodRules.HYST) then
		return steps
	end
	local raw = math.clamp((dist - (radius - DressingLodRules.FADE)) / DressingLodRules.FADE, 0, 1) * steps
	if cur < steps and math.abs(raw - cur) < 0.75 then
		return cur
	end
	local l = math.clamp(math.floor(raw + 0.5), 0, steps - 1)
	return if l < cur - 1 then cur - 1 else l
end

-- LocalTransparencyModifier for a fade level.
function DressingLodRules.levelAlpha(level: number): number
	return math.clamp(level / DressingLodRules.FADE_STEPS, 0, 1)
end

-- batch for fade levels: groups whose level must rise (fading out) first, then those that fall, within `budget` parts.
function DressingLodRules.batchLevels(want: { number }, cur: { number }, cost: { number }, n: number, budget: number): { number }
	local out: { number } = {}
	local used = 0
	for pass = 1, 2 do
		local rising = pass == 1
		for i = 1, n do
			local w, c0 = want[i], cur[i]
			if w ~= c0 and (w > c0) == rising then
				local c = cost[i] or 0
				if used > 0 and used + c > budget then
					return out
				end
				used += c
				table.insert(out, i)
			end
		end
	end
	return out
end

-- Ground kind -> LOD group kind. "terrain" (stands on terrain) and "none" (nothing under it) are managed on their own
-- base point; "dressing" (stands on another managed prop) follows that prop; "part" (stands on any other part, which
-- stays drawn) is never hidden.
export type GroupKind = "own" | "follow" | "fixed"
function DressingLodRules.groupKind(ground: string): GroupKind
	if ground == "terrain" or ground == "none" then
		return "own"
	elseif ground == "dressing" then
		return "follow"
	end
	return "fixed"
end

-- Is a model eligible at all: inside SetDressing or opted in, no gameplay attribute or trigger, small enough.
-- maxExtent: a map's MAP_SCENERY cap for its scenery folders (default MAX_EXTENT).
function DressingLodRules.eligible(inDressing: boolean, optIn: boolean, gameplay: boolean, maxAxis: number, maxExtent: number?): boolean
	return (inDressing or optIn) and not gameplay and maxAxis <= (maxExtent or DressingLodRules.MAX_EXTENT)
end

-- Plans one step's writes. want/visible/cost are per group (1..n); returns the indices to flip this step, hides first
-- then shows, within `budget` parts (a single group bigger than the budget still goes when it is the first one).
function DressingLodRules.batch(want: { boolean }, visible: { boolean }, cost: { number }, n: number, budget: number): { number }
	local out: { number } = {}
	local used = 0
	for pass = 1, 2 do
		local hiding = pass == 1
		for i = 1, n do
			if want[i] ~= visible[i] and (not want[i]) == hiding then
				local c = cost[i] or 0
				if used > 0 and used + c > budget then
					return out
				end
				used += c
				table.insert(out, i)
			end
		end
	end
	return out
end

return DressingLodRules
