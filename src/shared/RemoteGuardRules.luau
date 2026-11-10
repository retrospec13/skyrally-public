--!strict
-- Remote hardening (systems audit v32 T1-9, MP-4/MP-8). Pure: no Instances, no clock of its own; specced in
-- tools/tests/remote_guard_spec.luau. What every client->server remote handler uses to treat its arguments as claims:
--   * type/range checks: finite numbers (NaN and inf never reach an attribute), short control-free names, enum strings
--     (BoostState is one of BOOST_STATES, nothing else);
--   * per-player token buckets (LIMITS, one row per remote) so a client firing in a loop costs the server nothing;
--   * the ring / boost-pad check: the claimed trigger exists, the server's own position history of the racer's hull
--     came within reach of it, and the same trigger was not already paid inside its cooldown.
--
-- The trigger check is only about the server's own bookkeeping (ring count, replicated BoostState, the server speed
-- floor). The client boosts locally either way, so a refused claim never stalls a vehicle. It reads 3D distance only:
-- no ground, orientation or height assumption, so wall driving, climbing and alternate lines pass exactly like the road.
-- Reach is generous on purpose: trigger radius + SLACK + MAX_SPEED x (LEAD_S + ping), because the replicated hull can
-- trail the event by a frame or two, and the history is tested as segments (a 210 studs/s pass between two samples
-- still counts). A respawn or teleport jump splits the history so a segment never sweeps across the map.

local RemoteGuardRules = {}

RemoteGuardRules.LOG = "[SkyRally][ANTICHEAT] "

------------------------------------------------------------------------------------------------ value checks

RemoteGuardRules.BOOST_STATES = { None = true, Standard = true, Overcharge = true } :: { [string]: boolean }

-- The BoostState a client may report, or nil (any other string, any other type).
function RemoteGuardRules.boostState(v: any): string?
	if type(v) == "string" and RemoteGuardRules.BOOST_STATES[v] then
		return v
	end
	return nil
end

function RemoteGuardRules.finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- A finite number clamped to [lo, hi], or nil (not a number, NaN, +-inf).
function RemoteGuardRules.num(v: any, lo: number, hi: number): number?
	if not RemoteGuardRules.finite(v) then
		return nil
	end
	return math.clamp(v :: number, lo, hi)
end

RemoteGuardRules.NAME_MAX = 64

-- A non-empty, control-free name of at most maxLen (default NAME_MAX) characters, or nil.
function RemoteGuardRules.name(v: any, maxLen: number?): string?
	if type(v) ~= "string" or #v == 0 or #v > (maxLen or RemoteGuardRules.NAME_MAX) or string.find(v, "%c") then
		return nil
	end
	return v
end

-- A value safe to print in a log line (24 chars, control characters replaced).
function RemoteGuardRules.shown(v: any): string
	return (string.gsub(string.sub(tostring(v), 1, 24), "%c", "?"))
end

------------------------------------------------------------------------------------------------ rate limits

export type Limit = { burst: number, perSec: number }
export type Bucket = { tokens: number, at: number }

-- Per player, per remote. Each row is at least twice the honest peak:
--   flightState: SyncTransform at 12.5 Hz (FlightController 0.08 s, CarConfig.SYNC_INTERVAL 0.08) plus the odd request;
--   raceEvent: rings and pads (1.2 s per trigger on the client), pods and geysers; a dense pod row is a short burst;
--   item: Use / Roll / Drag from the item button and barrel rolls;
--   battleIntro: TrackFlowRemote "BattleIntroSeen" (once per unlock; it writes the save).
RemoteGuardRules.LIMITS = {
	flightState = { burst = 40, perSec = 30 },
	raceEvent = { burst = 24, perSec = 12 },
	item = { burst = 12, perSec = 6 },
	battleIntro = { burst = 2, perSec = 0.2 },
} :: { [string]: Limit }

function RemoteGuardRules.newBucket(limit: Limit, now: number): Bucket
	return { tokens = limit.burst, at = now }
end

-- Takes one token; false = over the limit (the caller drops the message).
function RemoteGuardRules.take(bucket: Bucket, limit: Limit, now: number): boolean
	local dt = math.max(0, now - bucket.at)
	bucket.at = now
	bucket.tokens = math.min(limit.burst, bucket.tokens + dt * limit.perSec)
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

export type Limiter = {
	allow: (key: any, now: number) -> boolean,
	forget: (key: any) -> (),
	size: () -> number,
}

-- One bucket per key (a Player); forget(key) on PlayerRemoving.
function RemoteGuardRules.newLimiter(limit: Limit): Limiter
	local buckets: { [any]: Bucket } = {}
	local self = {} :: Limiter
	function self.allow(key: any, now: number): boolean
		local b = buckets[key]
		if not b then
			b = RemoteGuardRules.newBucket(limit, now)
			buckets[key] = b
		end
		return RemoteGuardRules.take(b :: Bucket, limit, now)
	end
	function self.forget(key: any)
		buckets[key] = nil
	end
	function self.size(): number
		local n = 0
		for _ in buckets do
			n += 1
		end
		return n
	end
	return self
end

------------------------------------------------------------------------------------------------ position history

RemoteGuardRules.TRAIL = {
	sampleGap = 0.05, -- seconds between kept samples (20 Hz)
	keep = 1.6, -- seconds of history
	maxSpeed = 260, -- studs/s: FlightServer's speed clamp, above every boost (OVERCHARGE 210, item boost 210)
	jumpSlack = 40, -- studs beyond maxSpeed x dt that mark a teleport (respawn, seat, course return)
}

export type Sample = { t: number, p: Vector3, cut: boolean? } -- cut: no segment joins this sample to the one before
export type Trail = { samples: { Sample } }

function RemoteGuardRules.newTrail(): Trail
	return { samples = {} }
end

-- Adds one server-side hull position. Samples closer than sampleGap to the last are skipped; old ones drop.
function RemoteGuardRules.record(trail: Trail, t: number, p: Vector3)
	local cfg = RemoteGuardRules.TRAIL
	local s = trail.samples
	local last = s[#s]
	if last and t - last.t < cfg.sampleGap then
		return
	end
	local cut = false
	if last then
		local dt = math.max(t - last.t, 0)
		cut = (p - last.p).Magnitude > cfg.maxSpeed * dt + cfg.jumpSlack
	end
	table.insert(s, { t = t, p = p, cut = cut })
	local drop = 0
	for i = 1, #s do
		if t - s[i].t > cfg.keep then
			drop = i
		else
			break
		end
	end
	if drop > 0 then
		local n = #s
		table.move(s, drop + 1, n, 1)
		for i = n - drop + 1, n do
			s[i] = nil
		end
		s[1].cut = true
	end
end

function RemoteGuardRules.clear(trail: Trail)
	table.clear(trail.samples)
end

-- Distance from point q to the segment a-b.
function RemoteGuardRules.segmentDistance(a: Vector3, b: Vector3, q: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return (q - a).Magnitude
	end
	local u = math.clamp((q - a):Dot(ab) / len2, 0, 1)
	return (q - (a + ab * u)).Magnitude
end

-- Closest approach of the racer to q: every kept sample and every segment between two joined samples, plus the live
-- position (joined to the last sample unless the step from it is a teleport). math.huge with no data at all.
function RemoteGuardRules.nearest(trail: Trail, q: Vector3, live: Vector3?, now: number?): number
	local cfg = RemoteGuardRules.TRAIL
	local best = math.huge
	local s = trail.samples
	for i, smp in s do
		local d: number
		if i > 1 and not smp.cut then
			d = RemoteGuardRules.segmentDistance(s[i - 1].p, smp.p, q)
		else
			d = (smp.p - q).Magnitude
		end
		if d < best then
			best = d
		end
	end
	if live then
		local last = s[#s]
		local d: number
		local dt = if last and now then math.max(now - last.t, 0) else 0
		if last and (live - last.p).Magnitude <= cfg.maxSpeed * dt + cfg.jumpSlack then
			d = RemoteGuardRules.segmentDistance(last.p, live, q)
		else
			d = (live - q).Magnitude
		end
		if d < best then
			best = d
		end
	end
	return best
end

------------------------------------------------------------------------------------------------ ring / pad claims

RemoteGuardRules.TRIGGER = {
	slack = 8, -- studs on top of the trigger radius (the disc / plate size, float error)
	leadS = 0.25, -- seconds the replicated hull may trail the event, before ping
	pingMax = 0.5, -- seconds of ping counted at most (a worse connection gets no more reach)
	cooldown = 0.9, -- seconds per trigger per player (the clients use 1.2; 0.3 s of network bunching)
	-- Trigger radii: the larger of the plane's and the car's (PlaneConfig 19/18, CarConfig 16/14).
	ringRadius = 19,
	padRadius = 18,
}

RemoteGuardRules.KINDS = { RingTriggered = "BoosterRing", PadTriggered = "GroundBoostPad" } :: { [string]: string }

-- How far from the trigger the history may be and still count (studs).
function RemoteGuardRules.reach(radius: number, ping: number?): number
	local cfg = RemoteGuardRules.TRIGGER
	local p = if RemoteGuardRules.finite(ping) then math.clamp(ping :: number, 0, cfg.pingMax) else cfg.pingMax
	return radius + cfg.slack + RemoteGuardRules.TRAIL.maxSpeed * (cfg.leadS + p)
end

export type Claim = {
	found: boolean, -- the named trigger of this kind exists on the racer's map
	distance: number?, -- RemoteGuardRules.nearest to it (the closest candidate when several share the name)
	radius: number, -- trigger radius (+ PickupLift for a lifted pad)
	ping: number?, -- seconds (player:GetNetworkPing())
	lastAt: number?, -- when this player's claim on this trigger was last accepted
	now: number,
}

-- (true, "ok") or (false, reason): "unknown_trigger", "no_history", "too_far", "cooldown".
function RemoteGuardRules.triggerVerdict(c: Claim): (boolean, string)
	if not c.found then
		return false, "unknown_trigger"
	end
	if c.lastAt ~= nil and c.now - c.lastAt < RemoteGuardRules.TRIGGER.cooldown then
		return false, "cooldown"
	end
	local d = c.distance
	if d == nil or d == math.huge or not RemoteGuardRules.finite(d) then
		return false, "no_history"
	end
	if d > RemoteGuardRules.reach(c.radius, c.ping) then
		return false, "too_far"
	end
	return true, "ok"
end

return RemoteGuardRules
