--!strict
-- How this client draws the OTHER racers (owner 2026-10-19: "all of the opponents were like jittering on the screen as
-- if they were in the wrong frame ... constantly bumping"; "have the player name be above but ... only when the player
-- gets close and semi-transparent ... make sure it doesn't constantly jitter"). Pure and allocation-light, so
-- client/RacerView and tools/tests/racer_view_spec share it.
--
-- Why bots jittered: every bot (AIRacers, BattleBots, the zone boss) is an ANCHORED server part that the server
-- re-CFrames each Heartbeat. An anchored part's CFrame replicates as a plain property change: no physics interpolation
-- on the client, each update shows on whatever frame it happens to arrive, and arrivals bunch and gap with the network
-- (two in one frame, none for the next two). At 130-250 studs/s a one-frame gap is a 2-4 stud stall followed by a jump,
-- while this player's own vehicle and the chase camera move smoothly every render frame, so every bot shudders against
-- the camera. Remote PLAYERS' vehicles are unanchored and owned by their own clients; the engine already buffers and
-- interpolates those, so they are left alone.
--
-- Fix (snapshot interpolation): the client keeps the last replicated CFrames of each bot hull on a server sim-time
-- timeline and, every render frame, writes the hull's LOCAL CFrame to the pose interpolated at now - lag (the clock
-- offset plus a 50-250 ms render delay sized from the measured lateness). The welded body, pilot, flames and every
-- BillboardGui adorned to the hull ride the smoothed frame. Nothing is written back to the server: hits, pods,
-- standings and the server's own hull stay authoritative; the drawn bot is typically 50-120 ms behind it.
--
-- Timeline (2026-10-20 rework, docs/audits/opponent_jitter.md): snapshots are stamped in SERVER sim time, not arrival
-- time. Bots step in whole SERVER_STEP steps (serverSteps below), so a snapshot is the previous one plus k steps, k being
-- how many steps the hull moved (distance over the step length, stepLength; arrival gap over SERVER_STEP while the
-- racer is near standstill), the whole count next to it that also fits the clock winning a near tie. Arrivals never
-- move a stamp; they only feed the clock that maps sim time onto this client's clock:
--   offset  arrival minus stamp near its EARLIEST (a running 10 % quantile), so a late packet is lateness, not a moved
--           pose. The old timeline pulled each stamp 5 % toward its own arrival, so one-sided network lateness (a spike
--           holds back every packet behind it) bent the drawn path by 10-20 ms, 2-4 studs at racing speed.
--   late    mean lateness above that floor; the render delay is 1.5 packet intervals plus 4x it (50-250 ms).
--   lag     the playback lag actually drawn (offset + delay), eased toward its target (LAG_TAU, at most LAG_SLEW), so a
--           clock change speeds or slows the view by a few percent instead of jumping it.
-- A stamp more than RELOCK from its arrival-equivalent (a stall, lost steps) re-locks to it. A jump further than
-- SNAP_DISTANCE (grid reset, track switch) restarts the track at the new pose instead of sliding across the map.
local Rules = {}

Rules.CAPACITY = 32 -- snapshots kept per racer (~0.5 s at 60 Hz: the step-length check spans 0.4 s)
Rules.SERVER_STEP = 1 / 60 -- server sim time per bot step (AIRacers / BattleBots via serverSteps)
Rules.MAX_STEPS = 12 -- server steps one snapshot may stand for (merged or coalesced updates, a 0.2 s gap)
Rules.TIMING_WEIGHT = 0.35 -- step-count cost per server step a count misses the clock by
Rules.MOVING_STEP = 0.25 -- studs per step: below this the racer is near standstill and k comes from arrival gaps
Rules.INTERVAL_GAIN = 0.05 -- packet interval (sim time per snapshot) mean
Rules.FLOOR_QUANTILE = 0.1 -- the clock floor sits at this quantile of (arrival - stamp)
Rules.FLOOR_RATE = 0.002 -- s per packet the floor steps (down 90 % of it for an earlier packet, up 10 % otherwise)
Rules.LATE_GAIN = 0.05
Rules.STEP_WINDOW = 0.4 -- s of arrivals the step-length check is measured over (arrival jitter averages out)
Rules.STEP_TOLERANCE = 0.3 -- the exact step length stands while the stamps cover the arrival span within 30 %
Rules.RELOCK = 0.25 -- s a stamp may sit from its arrival-equivalent before the timeline re-locks
Rules.DELAY_INTERVALS = 1.5
Rules.LATE_MULT = 4
Rules.MIN_DELAY = 0.05
Rules.MAX_DELAY = 0.25
Rules.LAG_SLEW = 0.05 -- s of playback lag per s (the view runs at most 5 % fast or slow while the clock settles)
Rules.LAG_TAU = 1 -- s: the drawn lag eases toward its target with this time constant (inside the slew limit)
Rules.LAG_RESET = 0.5 -- s without a sample: the next one takes the target lag at once
Rules.LAG_SNAP = 0.15 -- s between the drawn and the target lag past which the view jumps (a re-lock) instead of slewing
Rules.MAX_EXTRAPOLATE = 0.1 -- s past the newest snapshot (late packet); then the bot holds
Rules.SNAP_DISTANCE = 120 -- studs between consecutive snapshots: a teleport, not flight (250 studs/s * 0.25 s = 62)

export type Snapshot = { t: number, cf: CFrame, arrival: number }
export type Track = {
	snaps: { Snapshot },
	interval: number,
	lastArrival: number,
	lastStamp: number,
	offset: number,
	late: number,
	lag: number?,
	lagAt: number,
	at: number?, -- the playhead of the last sample (diagnostics, specs)
}

function Rules.newTrack(): Track
	return {
		snaps = {},
		interval = Rules.SERVER_STEP,
		lastArrival = -math.huge,
		lastStamp = -math.huge,
		offset = 0,
		late = 0,
		lag = nil,
		lagAt = -math.huge,
		at = nil,
	}
end

local function restart(track: Track, cf: CFrame, arrival: number)
	table.clear(track.snaps)
	table.insert(track.snaps, { t = arrival, cf = cf, arrival = arrival })
	track.lastArrival = arrival
	track.lastStamp = arrival
	track.offset = 0
	track.late = 0
	track.lag = nil
end

-- Records a replicated pose seen at `arrival` (client clock). Returns true when the track restarted (first pose or a
-- teleport): the caller shows that pose as is.
function Rules.push(track: Track, cf: CFrame, arrival: number): boolean
	local snaps = track.snaps
	local n = #snaps
	if n == 0 or (cf.Position - snaps[n].cf.Position).Magnitude > Rules.SNAP_DISTANCE then
		restart(track, cf, arrival)
		return true
	end
	local last = snaps[n]
	local gap = math.max(arrival - track.lastArrival, 0)
	local k = math.clamp(math.floor(gap / Rules.SERVER_STEP + 0.5), 1, Rules.MAX_STEPS)
	local moved = (cf.Position - last.cf.Position).Magnitude
	local step = Rules.stepLength(track)
	if step and step >= Rules.MOVING_STEP then
		-- Distance says r steps; of the whole counts next to it, take the one that also fits the clock best (a count
		-- that makes this packet earlier than the floor, or later than the usual lateness, pays per step it misses by).
		-- Distance alone can settle on a self-consistent miscount (see stepLength); the clock pulls it back.
		local r = moved / step
		local near = math.floor(r + 0.5)
		local band = math.max(track.late * Rules.LATE_MULT, Rules.SERVER_STEP)
		local bestCost = math.huge
		for c = math.max(near - 1, 1), math.min(near + 1, Rules.MAX_STEPS) do
			local e = arrival - (track.lastStamp + c * Rules.SERVER_STEP) - track.offset
			local miss = if e < -Rules.SERVER_STEP * 0.5
				then -Rules.SERVER_STEP * 0.5 - e
				elseif e > band then e - band
				else 0
			local cost = math.abs(r - c) + Rules.TIMING_WEIGHT * miss / Rules.SERVER_STEP
			if cost < bestCost then
				bestCost = cost
				k = c
			end
		end
	end
	local stamp = track.lastStamp + k * Rules.SERVER_STEP
	local d = arrival - stamp
	if math.abs(d - track.offset) > Rules.RELOCK then
		stamp = arrival - track.offset -- a stall, lost steps or a miscount: re-lock to the arrival (the floor stays)
		d = track.offset
	elseif d < track.offset then
		track.offset -= Rules.FLOOR_RATE * (1 - Rules.FLOOR_QUANTILE)
	else
		track.offset += Rules.FLOOR_RATE * Rules.FLOOR_QUANTILE
	end
	stamp = math.max(stamp, track.lastStamp + Rules.SERVER_STEP * 0.5) -- strictly increasing (interpolation divides)
	track.late += (math.max(d - track.offset, 0) - track.late) * Rules.LATE_GAIN
	track.interval += (math.min(stamp - track.lastStamp, Rules.MAX_STEPS * Rules.SERVER_STEP) - track.interval)
		* Rules.INTERVAL_GAIN
	track.lastArrival = arrival
	track.lastStamp = stamp
	if n >= Rules.CAPACITY then
		table.remove(snaps, 1)
	end
	table.insert(snaps, { t = stamp, cf = cf, arrival = arrival })
	return false
end

-- Studs per server step. The newest pair of snapshots gives it exactly (its stamps are whole steps apart) unless a
-- miscount put them a wrong number of steps apart, which would feed back: one stamp too far apart reads as a slower bot,
-- which counts the next pose as more steps, and so on, a self-consistent drift. That drift shows on the clock: over the
-- last STEP_WINDOW s of ARRIVALS (where arrival jitter averages out) the stamps then cover more or less time than the
-- arrivals did. Past STEP_TOLERANCE the path length over that arrival span is used instead. Speed itself is not compared:
-- a hard brake or a boost legitimately changes it within the window. nil: under STEP_WINDOW of history yet (a start-up
-- count from arrival gaps may still be off; the caller counts from the arrival gap meanwhile).
function Rules.stepLength(track: Track): number?
	local snaps = track.snaps
	local n = #snaps
	if n < 2 then
		return nil
	end
	local newest, prev = snaps[n], snaps[n - 1]
	local exact = (newest.cf.Position - prev.cf.Position).Magnitude / (newest.t - prev.t) * Rules.SERVER_STEP
	local path = 0
	for i = n, 2, -1 do
		path += (snaps[i].cf.Position - snaps[i - 1].cf.Position).Magnitude
		local span = newest.arrival - snaps[i - 1].arrival
		if span >= Rules.STEP_WINDOW then
			if math.abs((newest.t - snaps[i - 1].t) / span - 1) > Rules.STEP_TOLERANCE then
				return path / span * Rules.SERVER_STEP
			end
			return exact
		end
	end
	return nil
end

-- Render delay behind the clock floor: a packet interval and a half plus three mean latenesses, so a late packet
-- still has a pose to blend to.
function Rules.delay(track: Track): number
	return math.clamp(
		track.interval * Rules.DELAY_INTERVALS + track.late * Rules.LATE_MULT,
		Rules.MIN_DELAY,
		Rules.MAX_DELAY
	)
end

-- The pose to draw at client time `now`, or nil before the first snapshot. Call once per frame per track (it advances
-- the slewed playback lag). `ground` (a car or walker on the road): past the newest snapshot only the horizontal motion
-- carries on and the height holds the server's last ride height, so a late packet over a crest or a ramp lip never
-- lifts the car off the road (and never sinks it through a landing). Between snapshots the poses are the server's own
-- road-snapped ones, 1/60 s apart: their chord over a crest sits well under 0.05 studs from the road.
function Rules.sample(track: Track, now: number, ground: boolean?): CFrame?
	local snaps = track.snaps
	local n = #snaps
	if n == 0 then
		return nil
	elseif n == 1 then
		track.at = nil
		return snaps[1].cf
	end
	local target = track.offset + Rules.delay(track)
	local lag = track.lag
	local since = now - track.lagAt
	if lag == nil or since > Rules.LAG_RESET or since < 0 or math.abs(target - lag) > Rules.LAG_SNAP then
		lag = target
	else
		-- Eased, not bang-bang: a rate that flips between +-LAG_SLEW reads as a surge at speed.
		local rate = math.clamp((target - (lag :: number)) / Rules.LAG_TAU, -Rules.LAG_SLEW, Rules.LAG_SLEW)
		lag = (lag :: number) + rate * since
	end
	track.lag = lag
	track.lagAt = now
	local at = now - (lag :: number)
	track.at = at
	if at <= snaps[1].t then
		return snaps[1].cf
	end
	local newest = snaps[n]
	if at < newest.t then
		for i = n, 2, -1 do
			local a = snaps[i - 1]
			if a.t <= at then
				local b = snaps[i]
				return a.cf:Lerp(b.cf, (at - a.t) / (b.t - a.t))
			end
		end
		return snaps[1].cf
	end
	-- Past the newest stamp (a late packet, or the bot stopped): carry on at the last velocity for a moment, then hold.
	local prev = snaps[n - 1]
	local over = math.min(at - newest.t, Rules.MAX_EXTRAPOLATE)
	local vel = (newest.cf.Position - prev.cf.Position) / (newest.t - prev.t)
	if ground then
		vel = Vector3.new(vel.X, 0, vel.Z)
	end
	return newest.cf + vel * over
end

------------------------------------------------------------------------------------------------------------------------
-- Server fixed step (owner 2026-10-20, after the snapshot fix: "the opponents in flying and car racing still jitter just
-- a little bit"; docs/audits/opponent_jitter.md). The client has no clock for a replicated pose: it rebuilds each
-- pose's time from arrivals and from distance (`push` counts server steps as distance over the last step), which is
-- exact only when every server step covers the same sim time. Bots were stepped with the raw Heartbeat dt, which a
-- loaded server (a Studio local server with two clients above all) varies by +-30 % with 2-3 frame hitches: a step
-- 30 % long moved the bot 30 % further but was drawn in one mean interval, so the bot surged and sagged against the
-- smooth chase camera (and a plane's lerp toward its goal, alpha dt * 12, added its own dt-dependent surge on top).
-- AIRacers and BattleBots now step bots in whole SERVER_STEP steps from an accumulator: every replicated pose sits on a
-- uniform sim-time grid, a Heartbeat with no whole step sends nothing, and one with two sends a pose two steps on that
-- `push` counts as k = 2. No bandwidth is added and the step count per second is unchanged on average.

Rules.MAX_SERVER_STEPS = 6 -- a longer server stall (over 0.1 s) is spread over 6 equal, longer steps (sim time is kept)

-- acc: wall time not yet stepped; sim: sim time stepped so far (whole steps); epoch / sentStep: the pose stream's
-- (Shared.RacerStreamRules.stamp / shouldSend).
export type ServerClock = { acc: number, sim: number, epoch: number?, sentStep: number? }

function Rules.newServerClock(): ServerClock
	return { acc = 0, sim = 0, epoch = nil, sentStep = nil }
end

-- The whole steps to run for a Heartbeat of `dt`: (count, step dt). Normally (0..2, SERVER_STEP); past
-- MAX_SERVER_STEPS the backlog runs as MAX_SERVER_STEPS equal longer steps (sim time is never dropped).
function Rules.serverSteps(clock: ServerClock, dt: number): (number, number)
	clock.acc += math.max(dt, 0)
	local n = math.floor(clock.acc / Rules.SERVER_STEP + 1e-6)
	if n <= 0 then
		return 0, Rules.SERVER_STEP
	end
	local span = n * Rules.SERVER_STEP
	clock.acc = math.max(clock.acc - span, 0)
	clock.sim += span
	if n > Rules.MAX_SERVER_STEPS then
		return Rules.MAX_SERVER_STEPS, span / Rules.MAX_SERVER_STEPS
	end
	return n, Rules.SERVER_STEP
end

-- Pose stream hook (Shared.RacerStreamRules, server/RacerStream). A mover that just ran whole steps calls
-- publish(source, clock, collect); on the server RacerStream sets streamSink and sends the parts `collect` returns,
-- stamped with the clock's exact sim time. Nil sink (the client, the Lune specs): nothing happens, nothing is built.
Rules.streamSink = nil :: ((source: number, clock: ServerClock, parts: { BasePart }) -> ())?
function Rules.publish(source: number, clock: ServerClock, collect: () -> { BasePart })
	local sink = Rules.streamSink
	if sink then
		sink(source, clock, collect())
	end
end

-- True when the hull's CFrame is no longer the one this client wrote last frame: the server sent a new pose.
function Rules.changed(current: CFrame, written: CFrame?): boolean
	if written == nil then
		return true
	end
	return (current.Position - written.Position).Magnitude > 1e-3
		or (current.LookVector - written.LookVector).Magnitude > 1e-4
		or (current.UpVector - written.UpVector).Magnitude > 1e-4
end

------------------------------------------------------------------------------------------------------------------------
-- Name labels over the other racers: shown only near this player's vehicle, faded in and out, semi-transparent.

Rules.LABEL_FULL = 55 -- studs between vehicles: full label at or inside this
Rules.LABEL_HIDE = 70 -- studs: gone at or beyond this
Rules.LABEL_FADE_RATE = 8 -- 1/s: shown alpha eases toward the distance alpha (no pop at the edge)
Rules.LABEL_TEXT_OPACITY = 0.8 -- text at full label (TextTransparency 0.2)
Rules.LABEL_BACK_OPACITY = 0.4 -- backing pill at full label (BackgroundTransparency 0.6)
Rules.LABEL_MAX_CHARS = 20

-- 0..1 label strength for a racer `distance` studs from this player's vehicle (smoothstep between FULL and HIDE).
function Rules.labelAlpha(distance: number): number
	if distance <= Rules.LABEL_FULL then
		return 1
	elseif distance >= Rules.LABEL_HIDE then
		return 0
	end
	local x = 1 - (distance - Rules.LABEL_FULL) / (Rules.LABEL_HIDE - Rules.LABEL_FULL)
	return x * x * (3 - 2 * x)
end

-- One frame of the eased label alpha.
function Rules.approachAlpha(shown: number, target: number, dt: number): number
	return shown + (target - shown) * math.clamp(dt * Rules.LABEL_FADE_RATE, 0, 1)
end

-- (TextTransparency, BackgroundTransparency) for a shown alpha.
function Rules.labelTransparency(alpha: number): (number, number)
	local a = math.clamp(alpha, 0, 1)
	return 1 - a * Rules.LABEL_TEXT_OPACITY, 1 - a * Rules.LABEL_BACK_OPACITY
end

-- The text over a vehicle model's attributes: a bot's roster name, a player's display name (nameOf resolves
-- OwnerUserId), else OwnerName. nil: no label (this player's own vehicle, a boss, or nothing to call it).
function Rules.labelText(attrs: { [string]: any }, localUserId: number, nameOf: ((userId: number) -> string?)?): string?
	if attrs.IsBoss == true then
		return nil -- the boss has its own title card and model
	end
	local owner = attrs.OwnerUserId
	if type(owner) == "number" and owner == localUserId then
		return nil
	end
	local name: string? = nil
	if type(attrs.BotName) == "string" and attrs.BotName ~= "" then
		name = attrs.BotName
	elseif type(owner) == "number" and nameOf then
		name = nameOf(owner)
	end
	if (name == nil or name == "") and type(attrs.OwnerName) == "string" and attrs.OwnerName ~= "" then
		name = attrs.OwnerName
	end
	if name == nil or name == "" then
		return nil
	end
	local s = name :: string
	local chars = utf8.len(s)
	if chars and chars > Rules.LABEL_MAX_CHARS then
		-- Cut on a character boundary (display names are UTF-8).
		local cut = utf8.offset(s, Rules.LABEL_MAX_CHARS)
		if cut then
			s = string.sub(s, 1, cut - 1) .. "."
		end
	end
	return s
end

------------------------------------------------------------------------------------------------------------------------
-- Camera-near fade (owner 2026-10-19, grid-order regression: since the player can start mid-pack, the chase camera
-- sat inside the racer one row behind; a bot wing crossed the whole screen in the countdown, a dark hull filled the
-- bottom of a phone screen). Every other racer's visible parts (BaseParts, decals, the seated avatar) fade with
-- LocalTransparencyModifier when the racer's box comes within NEAR_CLEAR of the camera, and part-way when it stands in
-- the sightline from the camera to this player's vehicle. Client-only, never on this player's own vehicle, eased so it
-- never pops. The start grid is spaced so that nothing on it fades at all (tools/map/adapt.py grid_camera_gate checks
-- every map's startGrid against these same numbers).

Rules.NEAR_CLEAR = 6 -- studs from the camera to a racer's box: no fade at or beyond
Rules.NEAR_HIDE = 2 -- studs: fully faded at or inside
Rules.NEAR_MAX = 1 -- LocalTransparencyModifier at full near fade (a wing through the lens is just gone)
Rules.SIGHT_CLEAR = 3 -- studs from the camera -> vehicle sightline to a racer's box: no fade at or beyond
Rules.SIGHT_MAX = 0.7 -- a racer squarely in the sightline stays readable as a ghost
Rules.SIGHT_OWN_MARGIN = 6 -- the sightline stops this far short of this player's hull centre (a racer alongside is not "between")
Rules.FADE_RATE = 10 -- 1/s: shown fade eases toward its target (~0.3 s to settle, no pop)
Rules.FADE_WRITE_STEP = 0.02 -- parts are rewritten only when the shown fade moved this much (or reached 0 / its max)

-- Distance from point `p` (in the box's own space, origin at its centre) to an axis-aligned box of half extents `half`;
-- 0 inside.
function Rules.boxDistance(p: Vector3, half: Vector3): number
	local dx = math.max(math.abs(p.X) - half.X, 0)
	local dy = math.max(math.abs(p.Y) - half.Y, 0)
	local dz = math.max(math.abs(p.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The point of segment a..b closest to p.
function Rules.segmentPoint(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return a
	end
	return a + ab * math.clamp((p - a):Dot(ab) / len2, 0, 1)
end

-- 0..1 smoothstep: 1 at or inside `full`, 0 at or beyond `clear`.
local function ramp(d: number, full: number, clear: number): number
	if d <= full then
		return 1
	elseif d >= clear then
		return 0
	end
	local x = 1 - (d - full) / (clear - full)
	return x * x * (3 - 2 * x)
end

-- Near fade for a racer whose box is `d` studs from the camera.
function Rules.nearFade(d: number): number
	return ramp(d, Rules.NEAR_HIDE, Rules.NEAR_CLEAR) * Rules.NEAR_MAX
end

-- Sightline fade for a racer whose box is `d` studs from the camera -> vehicle sightline.
function Rules.sightFade(d: number): number
	return ramp(d, 0, Rules.SIGHT_CLEAR) * Rules.SIGHT_MAX
end

-- Target fade (LocalTransparencyModifier) of a racer whose visible box is `box` (centre and orientation) with half
-- extents `half`, seen from a camera at camPos looking along camLook, while this player's vehicle is at ownPos (nil:
-- no vehicle, near fade only). A box wholly behind the camera is never faded (it cannot be seen).
function Rules.fadeTarget(box: CFrame, half: Vector3, camPos: Vector3, camLook: Vector3, ownPos: Vector3?): number
	if (box.Position - camPos):Dot(camLook) < -half.Magnitude then
		return 0
	end
	local fade = Rules.nearFade(Rules.boxDistance(box:PointToObjectSpace(camPos), half))
	if ownPos then
		local toOwn = ownPos - camPos
		local len = toOwn.Magnitude
		if len > Rules.SIGHT_OWN_MARGIN + 1e-3 then
			local stop = camPos + toOwn * ((len - Rules.SIGHT_OWN_MARGIN) / len)
			local q = Rules.segmentPoint(camPos, stop, box.Position)
			fade = math.max(fade, Rules.sightFade(Rules.boxDistance(box:PointToObjectSpace(q), half)))
		end
	end
	return fade
end

-- One frame of the eased fade; settles exactly on the target once within half a write step.
function Rules.approachFade(shown: number, target: number, dt: number): number
	local nextFade = shown + (target - shown) * math.clamp(dt * Rules.FADE_RATE, 0, 1)
	if math.abs(nextFade - target) < Rules.FADE_WRITE_STEP * 0.5 then
		return target
	end
	return nextFade
end

-- True when the parts should be rewritten for `shown` (last written: `applied`).
function Rules.shouldWrite(shown: number, applied: number): boolean
	if shown == applied then
		return false
	end
	return math.abs(shown - applied) >= Rules.FADE_WRITE_STEP or shown == 0 or shown >= Rules.NEAR_MAX
end

-- Chase-camera position over a vehicle at `pos` heading `forward` (flat unit vector): `back` studs behind, `up` above.
-- The grid spec places the camera with it; FlightController / CarController own the live camera.
function Rules.chaseCameraPos(pos: Vector3, forward: Vector3, back: number, up: number): Vector3
	return pos - forward * back + Vector3.new(0, up, 0)
end

-- Bot plane path frame (docs/audits/plane_stutter.md C5), used by server AIRacers.renderPlane. Bot planes fly the
-- waypoint polyline (11-27 studs apart, up to 19 deg between chords on DINO-4), and the chord tangent
-- SplineUtils.sampleAtStation returns turns in one step at every waypoint. Taken raw, that step moved the lane offset
-- sideways (12 studs x 10 deg = 2 studs) and switched the curvature bank between per-chord values (12-31 deg on DINO-4)
-- about five times a second: wing wobble and side hops that the hull lerp only softened, on top of anything a client's
-- timeline can smooth. This is the polyline box-filtered over +-PATH_HALF studs (four taps): position, tangent and bank
-- are continuous in station and each corner's kink is split in four. On a bend of radius R the point sits about
-- PATH_HALF^2 / (6 R) inside the line (0.4 studs at R 100). `sample` is SplineUtils.sampleAtStation.
Rules.PATH_HALF = 16
function Rules.pathFrame(sample: (number) -> (Vector3, Vector3, number), station: number): (Vector3, Vector3, number)
	local q = Rules.PATH_HALF * 0.25
	local a, _, ba = sample(station - 3 * q)
	local b, fallback, bb = sample(station - q)
	local c, _, bc = sample(station + q)
	local d, _, bd = sample(station + 3 * q)
	local dir = (c + d) - (a + b)
	return (a + b + c + d) * 0.25, if dir.Magnitude > 0.05 then dir.Unit else fallback, (ba + bb + bc + bd) * 0.25
end

return Rules
