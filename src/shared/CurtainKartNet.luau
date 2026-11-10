--!strict
-- Shared Curtain Kart wire rules (docs/REMARKABLE.md item 28): everyone in the server races the same curtain mini
-- track. Pure and allocation-free, so client/CurtainKart, server/CurtainKartRelay and tools/tests/curtain_kart_net_spec
-- all use the same packing, validation and overtake rules.
--
-- Wire: the client fires SkyRallyRemotes.CurtainKartPos (an UnreliableRemoteEvent: a lost 5 Hz sample is replaced by
-- the next one) with (Vector3(x, y, heading), state, best?):
--   * x, y      the kart in the baked unit box of shared/CurtainTracks (long side = 1), heading in radians;
--   * state     laps * 2048 + floor(lap fraction * 1023) * 2 + (1 when the player has the wheel, 0 in attract mode),
--               so every client ranks karts from the sender's own progress (no re-projection, no disagreement);
--   * best      the sender's best counted lap on this curtain (seconds) or nil.
-- The server keeps only sane values (Net.sanitize), at most one sample per MIN_GAP per player, and only while
-- workspace.TrackSwitching is on, and republishes them as player attributes CKPos / CKState / CKBest, which every
-- client reads. Nothing here is a reward or a race result: it is a loading-screen toy.
local Net = {}

Net.SEND_HZ = 5
Net.MIN_GAP = 0.12 -- server: one accepted sample per player per 0.12 s (5 Hz plus jitter headroom)
Net.STALE = 1.2 -- client: a rival kart with no new sample for this long is hidden
Net.MAX_LAPS = 99
Net.FRAC_STEPS = 1023
Net.STATE_MAX = (Net.MAX_LAPS + 1) * 2048 - 1
Net.BOX_MIN = -0.25 -- the unit box plus the Sim's margin and slack
Net.BOX_MAX = 1.25
Net.BEST_MIN = 1.0 -- a curtain lap faster than this is not physical (top speed 0.85 units/s on a loop of >= 2 units)
Net.BEST_MAX = 600
Net.PASS_GAP = 0.015 -- laps: a lead must open this far before it counts (no flicker at a tie)

Net.REMOTE = "CurtainKartPos"
Net.ATTR_POS = "CKPos"
Net.ATTR_STATE = "CKState"
Net.ATTR_BEST = "CKBest"

local TAU = 2 * math.pi

local function finite(n: number): boolean
	return n == n and n > -math.huge and n < math.huge
end

-- Packs a kart into the wire state number.
function Net.packState(laps: number, frac: number, manual: boolean): number
	local l = math.clamp(math.floor(laps), 0, Net.MAX_LAPS)
	local f = math.clamp(math.floor(frac * Net.FRAC_STEPS), 0, Net.FRAC_STEPS)
	return l * 2048 + f * 2 + (if manual then 1 else 0)
end

-- (laps, lap fraction 0..1, has the wheel)
function Net.unpackState(state: number): (number, number, boolean)
	local s = math.floor(state)
	local laps = s // 2048
	local rest = s % 2048
	return laps, (rest // 2) / Net.FRAC_STEPS, rest % 2 == 1
end

-- Race progress in laps (laps done + fraction of the current one).
function Net.progress(state: number): number
	local laps, frac = Net.unpackState(state)
	return laps + frac
end

-- Server-side check of a client sample. Returns the values to publish, or nil for anything malformed (wrong types,
-- NaN/inf, off the box, an impossible lap). The heading is wrapped to -pi..pi; a bad `best` is dropped on its own.
function Net.sanitize(pos: any, state: any, best: any): (Vector3?, number?, number?)
	if typeof(pos) ~= "Vector3" or type(state) ~= "number" then
		return nil, nil, nil
	end
	local x, y, h = pos.X, pos.Y, pos.Z
	if not (finite(x) and finite(y) and finite(h) and finite(state)) then
		return nil, nil, nil
	end
	if x < Net.BOX_MIN or x > Net.BOX_MAX or y < Net.BOX_MIN or y > Net.BOX_MAX then
		return nil, nil, nil
	end
	if state < 0 or state > Net.STATE_MAX or state ~= math.floor(state) then
		return nil, nil, nil
	end
	h = (h + math.pi) % TAU - math.pi
	local b: number? = nil
	if type(best) == "number" and finite(best) and best >= Net.BEST_MIN and best <= Net.BEST_MAX then
		b = math.floor(best * 10 + 0.5) / 10
	end
	return Vector3.new(x, y, h), state, b
end

-- Server rate gate: accept when the previous accepted sample is at least MIN_GAP old.
function Net.accept(lastAt: number?, now: number): boolean
	return lastAt == nil or now - lastAt >= Net.MIN_GAP
end

-- Shortest-way angle lerp (radians).
function Net.lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % TAU - math.pi
	return a + d * t
end

-- Overtake tracking against one rival. side: 1 = I am ahead, -1 = behind, 0 = not known yet. Returns the new side
-- and the event: 1 = I just passed them, -1 = they just passed me, 0 = nothing. A lead has to open past PASS_GAP
-- before it flips, so two karts side by side never spam the pop.
function Net.overtake(side: number, mine: number, theirs: number): (number, number)
	local diff = mine - theirs
	if diff > Net.PASS_GAP and side ~= 1 then
		return 1, if side == -1 then 1 else 0
	elseif diff < -Net.PASS_GAP and side ~= -1 then
		return -1, if side == 1 then -1 else 0
	end
	return side, 0
end

-- 1-based position of `mine` among `n` rival progresses (ties go to me).
function Net.position(mine: number, rivals: { number }, n: number): number
	local p = 1
	for i = 1, n do
		if rivals[i] > mine then
			p += 1
		end
	end
	return p
end

return Net
