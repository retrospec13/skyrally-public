--!strict
-- Pure rules for the World Moments set pieces (docs/REMARKABLE.md items 10 and 11), shared by the server pose
-- (server/SauropodSneeze) and the client effects (client/WorldMoments) and tested in tools/tests/worldmoments_spec.luau.
-- Nothing here touches the DataModel: callers pass positions, clocks and a random function in.
--
-- * Sauropod Sneeze (DINO-4): once per race, when the race leader first passes the sneeze station on lap 2 or 3, the
--   sauropod rears back (inhale), snaps forward (sneeze) and wobbles back to rest (recover). The pose is a whole-body
--   pitch about the model pivot (its feet) plus a short lunge along the head's horizontal direction. Visual only:
--   the statue never collides, and racers are never touched.
-- * Horn answers: honk within reach of a landmark and, 0.45 s later, it answers. Each landmark has its own cooldown;
--   hearing all six answer kinds in one session earns a toast.
local WorldMomentsRules = {}

---------------------------------------------------------------------------------------------------- sneeze

WorldMomentsRules.INHALE_SEC = 1.2
WorldMomentsRules.SNEEZE_SEC = 0.25
WorldMomentsRules.RECOVER_SEC = 1.5
WorldMomentsRules.INHALE_PITCH_DEG = 8 -- head back
WorldMomentsRules.SNEEZE_PITCH_DEG = -14 -- head snaps forward
WorldMomentsRules.LUNGE_STUDS = 3
WorldMomentsRules.SHAKE_RADIUS = 150
WorldMomentsRules.SHAKE_MAX = 0.4
WorldMomentsRules.HATCHLING_ODDS = 20 -- one race in 20
WorldMomentsRules.HATCHLING_SEC = 4
-- How far along the route before the statue's own station the leader starts the inhale, so the snap lands as the
-- leader comes abeam (about 1.2 s of travel at race pace) and the pack behind sees the whole thing.
WorldMomentsRules.SNEEZE_LEAD_STUDS = 220
WorldMomentsRules.SNEEZE_MIN_STATION = 20
-- Where the nostrils sit in the StoneSauropodV2 mesh's own box (win/blender_sauropod_v2.py keeps the build axes:
-- head at -X, base at the bottom): fractions of MeshPart.Size from the box centre.
WorldMomentsRules.NOSE_FRACTION = Vector3.new(-0.47, 0.4, 0)

function WorldMomentsRules.sequenceSec(): number
	return WorldMomentsRules.INHALE_SEC + WorldMomentsRules.SNEEZE_SEC + WorldMomentsRules.RECOVER_SEC
end

local function smooth(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Phase at `elapsed` seconds since the inhale began: "idle" | "inhale" | "sneeze" | "recover", and progress 0..1.
function WorldMomentsRules.phase(elapsed: number?): (string, number)
	if elapsed == nil or elapsed < 0 then
		return "idle", 0
	end
	local R = WorldMomentsRules
	if elapsed < R.INHALE_SEC then
		return "inhale", elapsed / R.INHALE_SEC
	end
	local e = elapsed - R.INHALE_SEC
	if e < R.SNEEZE_SEC then
		return "sneeze", e / R.SNEEZE_SEC
	end
	e -= R.SNEEZE_SEC
	if e < R.RECOVER_SEC then
		return "recover", e / R.RECOVER_SEC
	end
	return "idle", 0
end

-- Pose at `elapsed`: pitch in degrees (positive = head back) and lunge in studs along the head direction.
-- inhale: eases back to +8 with a shiver as it fills its lungs; sneeze: snaps to -14 and lunges 3 studs;
-- recover: a damped wobble that lands exactly on 0, 0.
function WorldMomentsRules.pose(elapsed: number?): (number, number)
	local R = WorldMomentsRules
	local ph, k = R.phase(elapsed)
	if ph == "inhale" then
		-- peaks at 0.45 degrees two thirds in and is gone again at the snap, so the pose stays continuous
		local shiver = 0.45 * 6.75 * k * k * (1 - k) * math.sin((elapsed :: number) * 2 * math.pi * 9)
		return R.INHALE_PITCH_DEG * smooth(k) + shiver, -0.6 * smooth(k)
	elseif ph == "sneeze" then
		local s = 1 - (1 - k) * (1 - k) -- ease-out: the snap is fastest at the start
		return R.INHALE_PITCH_DEG + (R.SNEEZE_PITCH_DEG - R.INHALE_PITCH_DEG) * s, -0.6 + (R.LUNGE_STUDS + 0.6) * s
	elseif ph == "recover" then
		local decay = (1 - k) * (1 - k)
		return R.SNEEZE_PITCH_DEG * decay * math.cos(k * math.pi * 2.5), R.LUNGE_STUDS * decay
	end
	return 0, 0
end

-- Camera trauma for a viewer `dist` studs from the nose: 0.4 at the nose, 0 at 150 and beyond.
function WorldMomentsRules.trauma(dist: number): number
	local R = WorldMomentsRules
	if dist >= R.SHAKE_RADIUS then
		return 0
	end
	return R.SHAKE_MAX * (1 - math.max(0, dist) / R.SHAKE_RADIUS)
end

-- Nose point in the mesh's own space for a MeshPart of `size`.
function WorldMomentsRules.noseLocal(size: Vector3): Vector3
	local f = WorldMomentsRules.NOSE_FRACTION
	return Vector3.new(size.X * f.X, size.Y * f.Y, size.Z * f.Z)
end

-- Horizontal unit direction of the head from the pivot, and the axis a positive (head-back) pitch turns about.
-- A head straight above the pivot falls back to -X (the build's head side).
function WorldMomentsRules.headFrame(headOffset: Vector3): (Vector3, Vector3)
	local flat = Vector3.new(headOffset.X, 0, headOffset.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(-1, 0, 0)
	-- Turning about dir x Y by a positive angle rotates dir towards +Y: a raised head moves back over the body.
	return dir, dir:Cross(Vector3.yAxis).Unit
end

-- Station along the route where the leader starts the sneeze: the statue's nearest station minus the lead, kept
-- inside the lap. An explicit plan value (model attribute SneezeStation) wins.
function WorldMomentsRules.sneezeStation(statueStation: number, override: number?): number
	if override then
		return override
	end
	local R = WorldMomentsRules
	return math.max(R.SNEEZE_MIN_STATION, statueStation - R.SNEEZE_LEAD_STUDS)
end

export type SneezePlan = {
	lap: number, -- lap the sneeze is due on
	station: number,
	laps: number,
	done: boolean,
}

-- One plan per race: the lap is random(2, 3), clamped to the race's lap count.
function WorldMomentsRules.newPlan(laps: number, station: number, rand: (number, number) -> number): SneezePlan
	local hi = math.max(1, math.min(3, laps))
	local lo = math.min(2, hi)
	return { lap = rand(lo, hi), station = station, laps = laps, done = false }
end

-- True on the first step the leader (on `lap`, at `station`) is inside the sneeze window. A leader who jumped past
-- the window (respawn ahead, a lap-counter wrap) moves the plan to the lap they are on, so a race still gets its one
-- sneeze while a lap is left. The caller marks plan.done when it starts the sneeze.
function WorldMomentsRules.planDue(plan: SneezePlan, lap: number, station: number, totalLen: number): boolean
	if plan.done then
		return false
	end
	if lap > plan.lap then
		if lap > plan.laps then
			plan.done = true
			return false
		end
		plan.lap = lap
	end
	if lap ~= plan.lap then
		return false
	end
	local d = station - plan.station
	return d >= 0 and d < math.min(400, totalLen * 0.5)
end

-- Hatchling flight at progress k (0..1): a cubic Bezier out of the nose, tumbling forward, then climbing away to one
-- side towards the roof. `fwd` is the sneeze direction (horizontal unit), `side` its right-hand horizontal.
function WorldMomentsRules.hatchlingPoint(k: number, nose: Vector3, fwd: Vector3, side: Vector3): Vector3
	local up = Vector3.yAxis
	local p0 = nose
	local p1 = nose + fwd * 28 + up * 4
	local p2 = nose + fwd * 46 + side * 14 + up * 42
	local p3 = nose + fwd * 34 + side * 46 + up * 120
	local t = math.clamp(k, 0, 1)
	local u = 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
end

---------------------------------------------------------------------------------------------------- horn answers

WorldMomentsRules.HORN_REACH = 70
WorldMomentsRules.HORN_DELAY = 0.45
WorldMomentsRules.HORN_COOLDOWN = 4
WorldMomentsRules.SESSION_TOAST = "The world talks back (6/6)"

export type LandmarkDef = {
	answer: string, -- "foghorn" | "fountain" | "cuckoo" | "puff" | "chime" | "honk"
	name: string, -- instance name the client finds under the active map root (every same-named sibling counts)
	map: string, -- for the check list and logs
	anchor: string, -- "top": top of the highest part; "boxTop": top centre of the bounds; "nose": the sauropod's nose
}

-- A model can also carry HornAnswer / HornAnswerReach attributes (plan modelAttributes) to override these.
WorldMomentsRules.LANDMARKS = {
	{ answer = "foghorn", name = "GalleonHull", map = "ISLAND-2", anchor = "boxTop" },
	{ answer = "fountain", name = "PlazaFountain", map = "HUB-0", anchor = "top" },
	{ answer = "cuckoo", name = "GapMill", map = "FOREST-1", anchor = "top" },
	{ answer = "puff", name = "MountainLodge", map = "SNOW-1", anchor = "top" },
	{ answer = "chime", name = "MonorailStation", map = "SPACE-4", anchor = "top" },
	{ answer = "honk", name = "RoamingGreenSauropod", map = "DINO-4", anchor = "nose" },
} :: { LandmarkDef }

WorldMomentsRules.ANSWER_KINDS = #WorldMomentsRules.LANDMARKS

-- Distance from `point` to an oriented box (0 inside it).
function WorldMomentsRules.distToBox(cf: CFrame, size: Vector3, point: Vector3): number
	local p = cf:PointToObjectSpace(point)
	local h = size * 0.5
	local dx = math.max(math.abs(p.X) - h.X, 0)
	local dy = math.max(math.abs(p.Y) - h.Y, 0)
	local dz = math.max(math.abs(p.Z) - h.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

export type Candidate = {
	cf: CFrame,
	size: Vector3,
	reach: number,
	readyAt: number,
}

-- Index of the nearest candidate whose box is within its reach of `point` and off cooldown at `now`, or nil.
function WorldMomentsRules.pickLandmark(cands: { Candidate }, point: Vector3, now: number): number?
	local best, bestD = nil, math.huge
	for i, c in cands do
		if now >= c.readyAt then
			local d = WorldMomentsRules.distToBox(c.cf, c.size, point)
			if d <= c.reach and d < bestD then
				best, bestD = i, d
			end
		end
	end
	return best
end

-- Records one heard answer kind in the session set. Returns the count and true exactly once, when the set first
-- holds every kind.
function WorldMomentsRules.markHeard(heard: { [string]: boolean }, answer: string): (number, boolean)
	local before = 0
	for _ in heard do
		before += 1
	end
	if heard[answer] then
		return before, false
	end
	local known = false
	for _, def in WorldMomentsRules.LANDMARKS do
		if def.answer == answer then
			known = true
			break
		end
	end
	if not known then
		return before, false
	end
	heard[answer] = true
	local n = before + 1
	return n, n == WorldMomentsRules.ANSWER_KINDS
end

-- Points on a smoke ring: `n` unit directions around +Y, tilted `tilt` (0..1) upward, for the chimney puff.
function WorldMomentsRules.ringDirections(n: number, tilt: number): { Vector3 }
	local out = table.create(n)
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2
		out[i] = Vector3.new(math.cos(a), tilt, math.sin(a)).Unit
	end
	return out
end

return WorldMomentsRules
