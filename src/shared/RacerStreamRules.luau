--!strict
-- Opponent pose stream (2026-10-20, opp-smooth; owner: "the planes still stutter a little bit, double check this
-- again"). Pure and allocation-light: server/RacerStream encodes, client/RacerView decodes and draws, and
-- tools/tests/racer_stream_spec.luau replays both. Background and the earlier fixes: docs/audits/opponent_jitter.md
-- and docs/audits/plane_stutter.md; this pass: docs/audits/opponent_stream.md.
--
-- Why a stream. Bots (AIRacers, BattleBots, the boss) and boss hazards are anchored server parts. Their CFrame reaches
-- the client as a plain property change with no time on it, so RacerViewRules had to INFER each pose's server time
-- from arrival gaps and from distance over the last step. That inference is exact only when every packet is one
-- step, the bot's speed is steady and the network is quiet; a coalesced pair, a boost, a brake or a lateness spike
-- puts a stamp a step off (8 studs per step at 250 studs/s is the extreme, a fraction of a stud typically), and every
-- miscount shows as a small surge against the chase camera. The client also drew bots on os.clock() while the chase
-- camera and the own vehicle advance by the render step's dt: two clocks for two things the eye compares.
--
-- What the stream does instead:
--   server  after every Heartbeat that ran a fixed step (SEND_STEPS, 60 Hz) each mover sends its parts' CFrames on one
--           UnreliableRemoteEvent (SkyRallyRemotes.RacerStream) with the EXACT server sim time of those poses
--           (stamp = epoch + whole steps, RacerViewRules.serverSteps). One packet per mover per send, 10 + 22 bytes per
--           part (7 bots: 164 B, about 9 KB/s per client). The authoritative hulls still move and replicate as
--           before: hits, items, pods, standings and the server's own checks are untouched.
--   client  per source a clock maps sim time onto this client's clock (a running 10 % floor of arrival - stamp, so
--           lateness never moves a pose), a render delay sized from the measured lateness (50-250 ms), and a playhead
--           eased toward it (at most 5 % rate change, the rate itself eased: no kink in the playback speed). Each part
--           keeps a buffer of stamped poses in stamp order (an unreliable packet that overtook another is slotted in,
--           not dropped) and is drawn at the playhead with a cubic Hermite position curve whose tangents are the
--           three-point derivative (exact for uneven spacing, where a plain central difference is off by
--           accel * gap / 2) and a slerped rotation: C1 in position, no per-sample velocity kink. Past the newest pose
--           it carries on at the last velocity for MAX_EXTRAPOLATE, then holds; a ground racer never extrapolates its
--           height. A jump faster than SNAP_SPEED (respawn, grid reset, track switch) is a CUT: the old pose carries on
--           at its own velocity until the playhead reaches the jump and the new one shows at once, never a slide
--           across the map.
--           The playhead runs on the RENDER clock (sum of the render step's dt, slewed onto os.clock()), the same clock
--           the chase camera and the own vehicle integrate on, so bot and camera advance by the same time every frame.
-- The visual IS the hull (RacerView writes the hull's local CFrame each frame, before the camera): labels, bubbles,
-- flames, the seated pilot, the minimap and the jitter probe all follow what the player sees. The drawn hull trails the
-- server's by the render delay (as before the stream: 50-120 ms typical).
local S = {}

S.REMOTE = "RacerStream" -- SkyRallyRemotes.<REMOTE>, an UnreliableRemoteEvent
S.VERSION = 1
S.SOURCE_RACE = 1 -- AIRacers (race bots, the zone boss)
S.SOURCE_BATTLE = 2 -- BattleBots
S.SOURCE_HAZARD = 3 -- BossRace hazards
S.SOURCE_PLAYER = 4 -- remote players' own poses, relayed by the server (Shared.PlayerStreamRules, 2026-10-20 remote-smooth)
S.STEP = 1 / 60 -- = RacerViewRules.SERVER_STEP (asserted by the spec)
S.SEND_STEPS = 1 -- a pose every Heartbeat that ran a fixed step: 60 Hz (30 Hz doubled the curve error on bumpy roads)
S.HEADER = 10 -- u8 version*16 + source, f64 stamp, u8 count
S.ENTRY = 22 -- u16 id, f32 x y z, i16 qx qy qz qw
S.MAX_ENTRIES = 36 -- 10 + 36 * 22 = 802 bytes: under the 900-byte unreliable payload cap
S.Q = 32767
S.EPOCH_SLACK = 0.25 -- s: a mover's sim clock this far off the server clock re-anchors its epoch

-- client
S.CAPACITY = 40 -- poses kept per part (0.67 s at 60 Hz: the playhead sits at most MAX_DELAY behind the newest)
S.FLOOR_QUANTILE = 0.1
S.FLOOR_RATE = 0.002 -- s per packet the clock floor steps (down 90 % of it for an earlier packet, up 10 % otherwise)
S.LATE_GAIN = 0.05
S.INTERVAL_GAIN = 0.1
S.RELOCK = 0.5 -- s off the floor: a new clock (server restart, epoch re-anchor)
S.DELAY_INTERVALS = 1.5
S.LATE_MULT = 3
S.MIN_DELAY = 0.05
S.MAX_DELAY = 0.25
S.LAG_SLEW = 0.05 -- s of playback lag per s
S.LAG_TAU = 1
S.RATE_TAU = 0.5 -- s: the playback rate itself eases (a second-order follow), so the playhead never changes speed in a step
S.LAG_RESET = 0.5
S.LAG_SNAP = 0.15 -- s: a target this much MORE delay than the lag snaps up (never down: see playhead)
S.LAG_CATCHUP = 0.2 -- s of lag per s: the slew while the target is LAG_SNAP or more below the lag (the playhead runs
-- up to 20 % fast for a moment instead of jumping every racer of the source forward at once)
S.STALL_FRAME = 0.1 -- s since the last render frame (and STALL_FRAMES typical frames): packets handled then were
S.STALL_FRAMES = 2.5 -- queued by a client stall, not late (a steady low frame rate is not a stall: S.isStall)
S.MAX_EXTRAPOLATE = 0.1
S.SNAP_SPEED = 600 -- studs/s between two poses: a teleport (the fastest boost is ~300)
S.SNAP_MIN = 24 -- studs: a smaller jump is never a cut
S.MIN_GAP = 0.004 -- s: a pose this close in time to a buffered one is a duplicate (dropped). Server poses are 1/60 s apart
-- and a player's at least PlayerStreamRules.SEND_GAP; two forged poses microseconds apart would otherwise give a tangent of
-- millions of studs/s (security review of remote-smooth, 2026-10-20).
S.MAX_TANGENT = 600 -- studs/s: the curve's velocity is never faster than this (= SNAP_SPEED; the fastest boost is ~300)
S.STALE = 0.5 -- s without a pose for a part: RacerView falls back to the replicated-property track
S.RENDER_GAIN = 2 -- 1/s: the render clock's pull onto os.clock()
S.RENDER_SLEW = 0.02 -- the render clock runs at most 2 % fast or slow while it settles
S.RENDER_RELOCK = 0.25 -- s apart: the render clock jumps to os.clock()

-- Counters the jitter probe reads (client: shared module table; RacerView adds to them).
S.stats = { stream = 0, fallback = 0, extrapolated = 0, held = 0, cuts = 0, packets = 0, dropped = 0 }

------------------------------------------------------------------------------------------------------------------------
-- Wire format

local function quatOf(cf: CFrame): (number, number, number, number)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local tr = r00 + r11 + r22
	local qx, qy, qz, qw
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		qw = 0.25 * s
		qx = (r21 - r12) / s
		qy = (r02 - r20) / s
		qz = (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		qw = (r21 - r12) / s
		qx = 0.25 * s
		qy = (r01 + r10) / s
		qz = (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		qw = (r02 - r20) / s
		qx = (r01 + r10) / s
		qy = 0.25 * s
		qz = (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		qw = (r10 - r01) / s
		qx = (r02 + r20) / s
		qy = (r12 + r21) / s
		qz = 0.25 * s
	end
	if qw < 0 then
		qx, qy, qz, qw = -qx, -qy, -qz, -qw
	end
	return qx, qy, qz, qw
end
S.quatOf = quatOf

local function q16(v: number): number
	return math.clamp(math.floor(v * S.Q + 0.5), -S.Q, S.Q)
end

-- One packet: `ids[i]` (0..65535) at `cfs[i]`, all at sim time `stamp`, from `source`. #ids <= MAX_ENTRIES.
function S.encode(source: number, stamp: number, ids: { number }, cfs: { CFrame }): buffer
	local n = math.min(#ids, S.MAX_ENTRIES)
	local b = buffer.create(S.HEADER + n * S.ENTRY)
	buffer.writeu8(b, 0, S.VERSION * 16 + source)
	buffer.writef64(b, 1, stamp)
	buffer.writeu8(b, 9, n)
	local o = S.HEADER
	for i = 1, n do
		local cf = cfs[i]
		local p = cf.Position
		local qx, qy, qz, qw = quatOf(cf)
		buffer.writeu16(b, o, ids[i] % 65536)
		buffer.writef32(b, o + 2, p.X)
		buffer.writef32(b, o + 6, p.Y)
		buffer.writef32(b, o + 10, p.Z)
		buffer.writei16(b, o + 14, q16(qx))
		buffer.writei16(b, o + 16, q16(qy))
		buffer.writei16(b, o + 18, q16(qz))
		buffer.writei16(b, o + 20, q16(qw))
		o += S.ENTRY
	end
	return b
end

-- (source, stamp, ids, cfs) or nil for anything that is not a well-formed packet of this version.
function S.decode(b: any): (number?, number, { number }, { CFrame })
	if typeof(b) ~= "buffer" then
		return nil, 0, {}, {}
	end
	local len = buffer.len(b)
	if len < S.HEADER then
		return nil, 0, {}, {}
	end
	local head = buffer.readu8(b, 0)
	if head // 16 ~= S.VERSION then
		return nil, 0, {}, {}
	end
	local n = buffer.readu8(b, 9)
	if len ~= S.HEADER + n * S.ENTRY then
		return nil, 0, {}, {}
	end
	local stamp = buffer.readf64(b, 1)
	if stamp ~= stamp or math.abs(stamp) == math.huge then
		return nil, 0, {}, {}
	end
	local ids: { number } = table.create(n)
	local cfs: { CFrame } = table.create(n)
	local o = S.HEADER
	for i = 1, n do
		local x, y, z = buffer.readf32(b, o + 2), buffer.readf32(b, o + 6), buffer.readf32(b, o + 10)
		local qx, qy, qz, qw =
			buffer.readi16(b, o + 14) / S.Q, buffer.readi16(b, o + 16) / S.Q, buffer.readi16(b, o + 18) / S.Q, buffer.readi16(b, o + 20) / S.Q
		local m = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if m < 0.5 or x ~= x or y ~= y or z ~= z then
			return nil, 0, {}, {}
		end
		ids[i] = buffer.readu16(b, o)
		cfs[i] = CFrame.new(x, y, z, qx / m, qy / m, qz / m, qw / m)
		o += S.ENTRY
	end
	return head % 16, stamp, ids, cfs
end

------------------------------------------------------------------------------------------------------------------------
-- Server side (pure parts): when to send, and the stamp of a mover's current poses.

export type ServerClock = { acc: number, sim: number, epoch: number?, sentStep: number? }

-- True when a mover whose clock just stepped should send now (every SEND_STEPS whole steps).
function S.shouldSend(clock: ServerClock): boolean
	local step = math.floor(clock.sim / S.STEP + 0.5)
	local last = clock.sentStep
	if last ~= nil and step - last < S.SEND_STEPS and step >= last then
		return false
	end
	clock.sentStep = step
	return true
end

-- The sim time of the mover's poses on the server clock `wall` (os.clock()): its epoch plus its whole steps. The
-- epoch is set once (wall - acc - sim) and kept, so stamps sit on the exact step grid whatever the Heartbeat jitter;
-- it re-anchors only if the sim clock drifts EPOCH_SLACK off the wall (never in normal running).
function S.stamp(clock: ServerClock, wall: number): number
	local want = wall - clock.acc - clock.sim
	local e = clock.epoch
	if e == nil or math.abs(e - want) > S.EPOCH_SLACK then
		e = want
		clock.epoch = want
	end
	return (e :: number) + clock.sim
end

------------------------------------------------------------------------------------------------------------------------
-- Client: per-source clock and playhead

export type Clock = {
	offset: number,
	late: number,
	interval: number,
	lastStamp: number,
	count: number,
	lag: number?,
	lagAt: number,
	rate: number, -- s of lag per s the playhead is currently slewing at
}

function S.newClock(): Clock
	return { offset = 0, late = 0, interval = S.STEP * S.SEND_STEPS, lastStamp = -math.huge, count = 0, lag = nil, lagAt = -math.huge, rate = 0 }
end

-- A packet stamped `stamp` (server sim time) arrived at client time `arrival`. `stalled`: the client's frame stalled
-- (RacerView: more than STALL_FRAME since the last render frame), so this packet sat in the client's own queue and its
-- arrival time says nothing about the network: it feeds neither the lateness nor a relock (a phone's 300 ms GC pause
-- must not grow the render delay, whose later decay would then pull the playhead forward). The floor still steps (an
-- inflated arrival only nudges it up by FLOOR_RATE * FLOOR_QUANTILE).
function S.observe(c: Clock, stamp: number, arrival: number, stalled: boolean?)
	local d = arrival - stamp
	if c.count == 0 or (not stalled and math.abs(d - c.offset) > S.RELOCK) then
		c.offset = d
		c.late = 0
		c.lag = nil
		c.lastStamp = stamp
		c.count = 1
		return
	end
	c.count += 1
	if d < c.offset then
		c.offset -= S.FLOOR_RATE * (1 - S.FLOOR_QUANTILE)
	else
		c.offset += S.FLOOR_RATE * S.FLOOR_QUANTILE
	end
	if not stalled then
		c.late += (math.max(d - c.offset, 0) - c.late) * S.LATE_GAIN
	end
	if stamp > c.lastStamp then
		c.interval += (math.min(stamp - c.lastStamp, 0.25) - c.interval) * S.INTERVAL_GAIN
		c.lastStamp = stamp
	end
end

-- True when a packet handled `gap` s after the last render frame sat out a client stall: over STALL_FRAME and over
-- STALL_FRAMES times the smoothed frame time `frameDt` (so a steady 8 fps phone still measures its real lateness).
function S.isStall(gap: number, frameDt: number): boolean
	return gap > math.max(S.STALL_FRAME, S.STALL_FRAMES * frameDt)
end

function S.delay(c: Clock): number
	return math.clamp(c.interval * S.DELAY_INTERVALS + c.late * S.LATE_MULT, S.MIN_DELAY, S.MAX_DELAY)
end

-- The sim time to draw at render time `now` (call once per frame per source; it advances the eased lag).
function S.playhead(c: Clock, now: number): number
	local target = c.offset + S.delay(c)
	local lag = c.lag
	local since = now - c.lagAt
	if lag == nil or since > S.LAG_RESET or since < 0 or target - lag > S.LAG_SNAP then
		-- One-directional: only MORE delay snaps (the buffer ran dry; the playhead steps back once). Less delay is
		-- always slewed below, faster while far off, so a decaying lateness never pops every racer forward at once.
		lag = target
		c.rate = 0
	else
		-- Second order: the wanted slew (toward the target over LAG_TAU, at most LAG_SLEW, LAG_CATCHUP while the
		-- target is LAG_SNAP or more below) is itself eased over RATE_TAU, so a target that steps (each packet nudges
		-- the floor and the lateness) bends the playhead's speed smoothly instead of kinking it; frame-rate independent
		-- (exponential ease by elapsed time).
		local gap = target - (lag :: number)
		local maxDown = if gap < -S.LAG_SNAP then S.LAG_CATCHUP else S.LAG_SLEW
		local want = math.clamp(gap / S.LAG_TAU, -maxDown, S.LAG_SLEW)
		c.rate += (want - c.rate) * (1 - math.exp(-since / S.RATE_TAU))
		lag = (lag :: number) + c.rate * since
	end
	c.lag = lag
	c.lagAt = now
	return now - (lag :: number)
end

-- The render clock: advanced by the render step's dt (the clock the chase camera integrates on), pulled gently onto
-- `wall` (os.clock()) so it never drifts from the arrival clock. Returns the new time.
export type RenderClock = { t: number? }
function S.newRenderClock(): RenderClock
	return { t = nil }
end
function S.advanceRender(rc: RenderClock, dt: number, wall: number): number
	local t = rc.t
	if t == nil or math.abs(wall - ((t :: number) + dt)) > S.RENDER_RELOCK then
		rc.t = wall
		return wall
	end
	local nt = (t :: number) + math.max(dt, 0)
	local err = wall - nt
	nt += math.clamp(err * math.min(dt * S.RENDER_GAIN, 1), -S.RENDER_SLEW * dt, S.RENDER_SLEW * dt)
	rc.t = nt
	return nt
end

------------------------------------------------------------------------------------------------------------------------
-- Client: per-part pose buffer

export type Snap = { t: number, cf: CFrame, cut: boolean }
-- clock: the key of the Clock this track's stamps are on (a bot mover's source; a remote player's own timeline,
-- PlayerStreamRules.clockKey). Defaults to the source.
-- snapSpeed: the cut speed for this track (default SNAP_SPEED; remote players use a lower one, PlayerStreamRules).
export type Track = { snaps: { Snap }, source: number, clock: number, lastArrival: number, mode: string?, snapSpeed: number? }

function S.newTrack(source: number, clock: number?, snapSpeed: number?): Track
	return { snaps = {}, source = source, clock = clock or source, lastArrival = -math.huge, mode = nil, snapSpeed = snapSpeed }
end

local function isCut(a: Snap, t: number, cf: CFrame, snapSpeed: number?): boolean
	local dist = (cf.Position - a.cf.Position).Magnitude
	return dist > S.SNAP_MIN and dist > (snapSpeed or S.SNAP_SPEED) * (t - a.t)
end

-- Adds a pose at sim time `t`, in stamp order: an unreliable packet that arrives after a newer one is slotted in
-- where it belongs (a gap filled is a better curve). A duplicate, or a pose older than the whole buffer, is dropped
-- (returns false). A jump faster than SNAP_SPEED from the pose before marks a cut.
function S.push(track: Track, t: number, cf: CFrame, arrival: number): boolean
	local snaps = track.snaps
	local n = #snaps
	local at = n + 1 -- insert position
	while at > 1 and snaps[at - 1].t > t do
		at -= 1
	end
	if (at > 1 and t - snaps[at - 1].t < S.MIN_GAP) or (at <= n and snaps[at].t - t < S.MIN_GAP) or (at == 1 and n > 0) then
		S.stats.dropped += 1
		return false
	end
	local cut = at > 1 and isCut(snaps[at - 1], t, cf, track.snapSpeed)
	if cut then
		S.stats.cuts += 1
	end
	local new: Snap = { t = t, cf = cf, cut = cut }
	table.insert(snaps, at, new)
	if at < #snaps then
		local nxt = snaps[at + 1]
		nxt.cut = isCut(new, nxt.t, nxt.cf, track.snapSpeed)
	end
	if #snaps > S.CAPACITY then
		table.remove(snaps, 1)
	end
	track.lastArrival = math.max(track.lastArrival, arrival)
	return true
end

-- Velocity at pose j (Catmull-Rom style: the three-point derivative; one-sided at an end or a cut). The same for ground
-- racers: levelling the tangent at a road crest or dip (tried 2026-10-20) kinks the vertical speed at every 60 Hz bump
-- and raised the car jitter p95 from under 0.05 to 0.068 studs at 30 fps in racer_stream_spec, against a small overshoot
-- on an asymmetric crest between 60 Hz poses. Ground racers are only kept from extrapolating their height
-- (sample: past the newest pose and before a cut).
local function tangent(snaps: { Snap }, j: number): Vector3
	local n = #snaps
	local s = snaps[j]
	local hasPrev = j > 1 and not s.cut
	local hasNext = j < n and not snaps[j + 1].cut
	local v: Vector3
	if hasPrev and hasNext then
		-- the three-point derivative for uneven spacing (a lost or merged pose): exact for a parabola, where the plain
		-- central difference is off by accel * (h2 - h1) / 2
		local a, b = snaps[j - 1], snaps[j + 1]
		local h1, h2 = s.t - a.t, b.t - s.t
		local d1 = (s.cf.Position - a.cf.Position) / h1
		local d2 = (b.cf.Position - s.cf.Position) / h2
		v = (d1 * h2 + d2 * h1) / (h1 + h2)
	elseif hasNext then
		local b = snaps[j + 1]
		v = (b.cf.Position - s.cf.Position) / (b.t - s.t)
	elseif hasPrev then
		local a = snaps[j - 1]
		v = (s.cf.Position - a.cf.Position) / (s.t - a.t)
	else
		return Vector3.zero
	end
	-- never faster than MAX_TANGENT: a forged or glitched pair of poses cannot fling the curve or the extrapolation
	local m = v.Magnitude
	return if m > S.MAX_TANGENT then v * (S.MAX_TANGENT / m) else v
end

-- The pose at sim time `at` (nil before the first pose). Sets track.mode: "interp" | "extrap" | "hold" | "first".
function S.sample(track: Track, at: number, ground: boolean?): CFrame?
	local snaps = track.snaps
	local n = #snaps
	if n == 0 then
		return nil
	end
	local first = snaps[1]
	if n == 1 or at <= first.t then
		track.mode = "first"
		return if at <= first.t then first.cf else snaps[n].cf
	end
	local newest = snaps[n]
	if at >= newest.t then
		local over = at - newest.t
		if over > S.MAX_EXTRAPOLATE then
			track.mode = "hold"
			over = S.MAX_EXTRAPOLATE
		else
			track.mode = "extrap"
		end
		if newest.cut then
			return newest.cf
		end
		local v = tangent(snaps, n)
		if ground then
			v = Vector3.new(v.X, 0, v.Z)
		end
		return newest.cf + v * over
	end
	local i = n - 1
	while i > 1 and snaps[i].t > at do
		i -= 1
	end
	local a, b = snaps[i], snaps[i + 1]
	track.mode = "interp"
	if b.cut then
		-- The old pose carries on at its own velocity until the playhead reaches the jump, then the new one shows.
		local v = tangent(snaps, i)
		if ground then
			v = Vector3.new(v.X, 0, v.Z)
		end
		return a.cf + v * math.min(at - a.t, S.MAX_EXTRAPOLATE)
	end
	local h = b.t - a.t
	local s = math.clamp((at - a.t) / h, 0, 1)
	local p0, p1 = a.cf.Position, b.cf.Position
	local m0, m1 = tangent(snaps, i) * h, tangent(snaps, i + 1) * h
	local s2, s3 = s * s, s * s * s
	local pos = p0 * (2 * s3 - 3 * s2 + 1) + m0 * (s3 - 2 * s2 + s) + p1 * (-2 * s3 + 3 * s2) + m1 * (s3 - s2)
	return CFrame.new(pos) * a.cf.Rotation:Lerp(b.cf.Rotation, s)
end

return S
