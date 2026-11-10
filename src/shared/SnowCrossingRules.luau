--!strict
-- SNOW-1 over/under crossing cue (TRACK_VARIETY 5a, "the crossing becomes the identity"). Pure rules for
-- client/SnowCrossing: when two racers cross at the arch bridge within WINDOW seconds of each other (one on the under-pass,
-- one on the over-pass: the figure-8 crossing itself), the bridge fires a spotlight sweep and a horn. Two racers on the
-- same level do not count: the pack passes under together right after the start, so a same-level trigger would sound
-- the horn at the start of every race and on every pack pass instead of at real crossings. The check runs on replicated hull
-- positions only; it has no gameplay effect and nothing here is a map Instance. No services, no Instances; Vector3
-- values only.
local Rules = {}

Rules.TRACK_ID = "SNOW-1"

-- The StoneArchBridge instance sits at the map origin (-8000, 0, 0) (tools/map/author_snow1.py ORIGIN). The under-pass
-- runs north-south on the river (waypoint y ~42), the over-pass east-west on the deck (y 140).
Rules.CENTRE = Vector3.new(-8000, 0, 0)
Rules.RADIUS = 45 -- plan-view distance that counts as "at the crossing" (plane speeds make that about 0.7 s)
Rules.SPLIT_Y = 100 -- below: the under-pass, at or above: the over-pass
Rules.CEILING_Y = 260 -- a racer higher than this is not on either line
Rules.WINDOW = 1.0 -- seconds between the two passes
Rules.COOLDOWN = 5 -- seconds before the bridge cues again
Rules.SHOW_TIME = 2.4 -- spotlight sweep length

-- Spotlight lamps: one on each deck edge (the deck is 104 studs wide, the over-pass corridor is 68, so they sit outside
-- it). Each lamp sweeps away from the route, over its own side of the gorge, and never toward the other lamp's side.
Rules.LAMP_Y = 168.5
Rules.LAMP_Z = 50
Rules.SWEEP_HALF = math.rad(60) -- yaw swing either side of straight out
Rules.LAMP_PITCH = math.rad(-24) -- aimed down at the valley floor
Rules.BEAM_LENGTH = 170

export type Sample = { id: any, pos: Vector3 }
export type State = {
	inside: { [any]: boolean },
	lastPass: { [any]: { t: number, level: string } },
	nextAt: number,
}
export type Event = { a: any, b: any, dt: number } -- a: the earlier pass, b: the pass on the other level that completed the pair

function Rules.new(): State
	return { inside = {}, lastPass = {}, nextAt = 0 }
end

-- "under", "over" or nil when the position is not on a crossing line. Plan view distance only plus the two height bands.
function Rules.level(pos: Vector3): string?
	local dx = pos.X - Rules.CENTRE.X
	local dz = pos.Z - Rules.CENTRE.Z
	if dx * dx + dz * dz > Rules.RADIUS * Rules.RADIUS then
		return nil
	end
	if pos.Y < 0 or pos.Y > Rules.CEILING_Y then
		return nil
	end
	return if pos.Y < Rules.SPLIT_Y then "under" else "over"
end

-- Feed one tick of racer positions (any order, `now` in seconds). Returns the event when this tick completes a pair of
-- passes on different levels (one under, one over) inside WINDOW and the cooldown is over. A pass is the moment a racer comes inside RADIUS on a level; racers
-- missing from `samples` (left the race) are forgotten.
function Rules.step(state: State, samples: { Sample }, now: number): Event?
	local event: Event? = nil
	local seen: { [any]: boolean } = {}
	for _, s in samples do
		seen[s.id] = true
	end
	for id in state.inside do
		if not seen[id] then
			state.inside[id] = nil
			state.lastPass[id] = nil
		end
	end
	for _, s in samples do
		local level = Rules.level(s.pos)
		local was = state.inside[s.id] == true
		state.inside[s.id] = level ~= nil
		if level and not was then
			state.lastPass[s.id] = { t = now, level = level }
			if event == nil and now >= state.nextAt then
				local bestId: any = nil
				local bestDt = Rules.WINDOW + 1
				for id, p in state.lastPass do
					if id ~= s.id and p.level ~= level then
						local dt = now - p.t
						if dt >= 0 and dt <= Rules.WINDOW and dt < bestDt then
							bestId, bestDt = id, dt
						end
					end
				end
				if bestId ~= nil then
					event = { a = bestId, b = s.id, dt = bestDt }
					state.nextAt = now + Rules.COOLDOWN
				end
			end
		end
	end
	return event
end

-- Lamp pose for `side` (+1: the +z deck edge, -1: the -z edge) at progress k (0..1): its position and unit look. The two
-- lamps swing in opposite senses, so the beams fan apart.
function Rules.lamp(side: number, k: number): (Vector3, Vector3)
	k = math.clamp(k, 0, 1)
	local yaw = (k * 2 - 1) * Rules.SWEEP_HALF * side
	local pitch = Rules.LAMP_PITCH
	local look = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), side * math.cos(yaw) * math.cos(pitch))
	local pos = Vector3.new(Rules.CENTRE.X, Rules.LAMP_Y, Rules.CENTRE.Z + side * Rules.LAMP_Z)
	return pos, look.Unit
end

-- Light and beam strength through the show: ramps up fast, holds, then fades (0..1).
function Rules.envelope(k: number): number
	if k <= 0 or k >= 1 then
		return 0
	end
	if k < 0.15 then
		return k / 0.15
	end
	if k > 0.7 then
		return (1 - k) / 0.3
	end
	return 1
end

return Rules
