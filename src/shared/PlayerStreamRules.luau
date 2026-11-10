--!strict
-- Remote players' pose stream (2026-10-20, branch remote-smooth; owner: "the planes still stutter"). Pure parts, used
-- by client/RacerView (send and draw), server/RacerStream (gate and relay) and tools/tests/remote_stream_spec.luau.
-- Why and the numbers: docs/audits/opponent_stream.md, "Remote players".
--
-- The problem. A human's vehicle is an unanchored assembly network-owned by that human's client. Its controller
-- (FlightController stepFlight / CarController writeHull) teleports the hull to the frame's simulated pose once per
-- RENDER frame and lets a LinearVelocity carry it in between. Every other client draws it from the engine's physics
-- replication: owner -> server -> receiver, sampled at the owner's frame and network cadence, timed by the engine and
-- interpolated by the engine (piecewise linear: a velocity kink at every sample). Nothing in the game smooths it
-- (RacerView smoothed bots only). Bots got a stamped 60 Hz stream; players did not.
--
-- The fix, the same idea as the bot stream:
--   sender   (the owning client, after its controller stepped) every frame at least SEND_GAP since the last send, the
--            hull's CFrame in the RacerStream wire format (RacerStreamRules.encode: one entry, 32 bytes), stamped with
--            the client's own sim time (the sum of the render dt its controller integrated: the exact time of that
--            pose; re-anchored to os.clock() only after a 0.25 s drift, RacerStreamRules.stamp), on the existing
--            SkyRallyRemotes.RacerStream UnreliableRemoteEvent (FireServer).
--   server   gates each packet (a buffer of exactly one entry, source SOURCE_PLAYER, a token bucket of RATE per s, the
--            pose within PLAUSIBLE studs of the server's own copy of that hull, no server hold, a fresh in-band stamp)
--            and relays it unchanged except the id, which the server sets to the hull's StreamId, to every other
--            player in the same race instance whose vehicle is within RELAY_RANGE. The pose is never used for any
--            gameplay: hits, items, standings, validation and respawn keep reading the replicated physics hull.
--   receiver one clock per remote player (clockKey: the sender's own timeline), the same pose buffer, Hermite curve,
--            lateness-sized playhead and render clock as the bots. RacerView writes the hull's LOCAL CFrame first in
--            the frame (render only: the engine puts its replicated pose back in its next simulation step, and nothing
--            this client writes to another player's assembly replicates). It blends from the engine's pose over
--            BLEND_TIME when a stream starts and back when it stops (no pop where the two delays differ).
local S = require(script.Parent:WaitForChild("RacerStreamRules"))

local P = {}

P.SOURCE = S.SOURCE_PLAYER -- 4 (1 race bots, 2 battle bots, 3 hazards)
P.SIZE = S.HEADER + S.ENTRY -- 32 bytes, the only accepted size client -> server
P.SEND_GAP = 1 / 60 - 0.002 -- s of sender sim time between sends: every frame up to 60 fps (one at 144 fps is 48 Hz)
P.RATE = 75 -- packets per s the server accepts per player (a 60 fps sender sends at most ~68)
P.BURST = 20 -- the token bucket's depth (a sender's hitch flushes a few at once)
P.PLAUSIBLE = 100 -- studs: a pose this far from the server's copy of the hull is dropped (a respawn shows ~0.1 s late)
P.RELAY_RANGE = 1200 -- studs between the two players' vehicles (server copies): no relay past it
P.ROSTER_INTERVAL = 0.1 -- s: the server refreshes who is where this often
P.BLEND_TIME = 0.35 -- s: the drawn pose eases between the engine's and the stream's
P.CLOCK_BASE = 65536 -- a player's clock key = CLOCK_BASE + StreamId (bots key by source)
-- Review fixes (2026-10-20, security / engine / client lenses):
P.MIN_STAMP_GAP = 0.008 -- s: the server drops a pose whose stamp is this close to one of the last RECENT it accepted
-- (honest poses are SEND_GAP apart; an unreliable packet that arrives out of order is still relayed)
P.RECENT = 8
P.STAMP_BAND = 1.0 -- s: an honest stamp tracks the sender's wall clock within its 0.25 s re-anchor slack (plus network
-- jitter), so (stamp - server time) stays within this of where it locked; a stamp outside is dropped
P.STAMP_RELOCK = 1.0 -- s without an accepted pose: the next one re-locks the band (a paused or backgrounded sender)
P.MAX_OFFSET = 40 -- studs: the drawn pose is never further than this from the engine's pose of the hull (honest gaps
-- between the two delays are a few studs; ~0.13 s at a 300 studs/s boost)
P.SNAP_SPEED = 400 -- studs/s: a player's pose jump faster than this is a cut (respawn), not a curve (boost is ~300)
P.RESTART_GAP = 0.25 -- s without a player pose: the next one starts a fresh buffer (a refused respawn, a hold)
P.ENGINE_FRESH = 0.1 -- s: an engine pose recorded by RacerView counts for enginePosition this long
-- The in-place draw (RacerView stepRemote writes the remote hull's local CFrame) is OFF unless the workspace attribute
-- DRAW_ATTR is exactly true. Studio V5A (aa6f798): the engine did not re-apply its replicated pose over our write on
-- ~30 % of drawn frames (noRestore), so a non-owned hull must not be written by default (2026-10-20 remote-clone).
P.DRAW_ATTR = "SkyRallyRemoteDraw"
P.DRAW_DEFAULT = false

-- Whether the in-place draw runs, from the workspace attribute's value (nil or not a boolean: DRAW_DEFAULT).
function P.drawOn(attr: any): boolean
	if type(attr) == "boolean" then
		return attr
	end
	return P.DRAW_DEFAULT
end

-- Counters (client: RacerView adds; server: RacerStream adds). The jitter probe and QAMultiplayer read them.
P.stats = {
	sent = 0, -- this client's own poses sent
	packets = 0, -- remote player poses received
	drawn = 0, -- frames a remote player was drawn from the stream (fully)
	blend = 0, -- frames in a blend between engine and stream
	engine = 0, -- frames a remote player was left to the engine (no fresh stream)
	cuts = 0, -- remote player poses that started a cut (respawn, teleport)
	noRestore = 0, -- frames the engine had not put its pose back over this client's last write (Studio step 8: ~0)
	clamped = 0, -- frames the stream pose was clamped to MAX_OFFSET from the engine's pose
	-- the visual clone (Shared.RemoteCloneRules, workspace.SkyRallyRemoteClone; 2026-10-20 remote-clone)
	cloneDrawn = 0, -- frames a remote player's clone was drawn fully from the stream
	cloneBlend = 0, -- frames a clone blended between the engine's pose and the stream's
	cloneEngine = 0, -- frames a remote player showed his real hull (no clone)
	cloneMade = 0, -- clones built (a stream started)
	cloneGone = 0, -- clones handed back to the real hull
	cloneCuts = 0, -- instant hand-backs: stream and engine more than RemoteCloneRules.CUT apart (respawn, teleport)
}
P.serverStats = {
	accepted = 0,
	relayed = 0,
	culled = 0,
	badSize = 0,
	badPacket = 0,
	rate = 0,
	implausible = 0,
	held = 0,
	noHull = 0,
	stamp = 0,
}

-- The clock a decoded track belongs to: bots share their mover's clock, each player has his own timeline.
function P.clockKey(source: number, id: number): number
	return if source == P.SOURCE then P.CLOCK_BASE + id else source
end

------------------------------------------------------------------------------------------------------------------------
-- Sender (the owning client)

export type Sender = { acc: number, sim: number, epoch: number?, lastSent: number }

function P.newSender(): Sender
	return { acc = 0, sim = 0, epoch = nil, lastSent = -math.huge }
end

-- One render frame of the owning client after its controller wrote the hull at `cf`: `dt` the render step (the dt the
-- controller integrated), `wall` os.clock(). Returns the packet to FireServer, or nil (not due yet).
function P.senderStep(s: Sender, dt: number, wall: number, cf: CFrame): buffer?
	s.sim += math.max(dt, 0)
	if s.sim - s.lastSent < P.SEND_GAP then
		return nil
	end
	s.lastSent = s.sim
	local stamp = S.stamp(s :: any, wall)
	return S.encode(P.SOURCE, stamp, { 0 }, { cf })
end

------------------------------------------------------------------------------------------------------------------------
-- Server gate and relay

export type Gate = { tokens: number, at: number, recent: { number }, band: number, okAt: number }

function P.newGate(): Gate
	return { tokens = P.BURST, at = -math.huge, recent = {}, band = 0, okAt = -math.huge }
end

-- Checks one client packet at server time `now` against the server's copy of the sender's hull (`hullPos`, nil: no
-- vehicle; `held`: a server hold, anchored or network ownership taken back). Returns (stamp, cf) or (nil, reason). Rate first, so a flood costs one
-- compare per packet.
function P.admit(g: Gate, b: any, now: number, hullPos: Vector3?, held: boolean?): (number?, any)
	if g.at > -math.huge then
		g.tokens = math.min(P.BURST, g.tokens + (now - g.at) * P.RATE)
	end
	g.at = now
	if g.tokens < 1 then
		P.serverStats.rate += 1
		return nil, "rate"
	end
	g.tokens -= 1
	if typeof(b) ~= "buffer" or buffer.len(b) ~= P.SIZE then
		P.serverStats.badSize += 1
		return nil, "size"
	end
	local source, stamp, _, cfs = S.decode(b)
	if source ~= P.SOURCE or #cfs ~= 1 then
		P.serverStats.badPacket += 1
		return nil, "packet"
	end
	if hullPos == nil then
		P.serverStats.noHull += 1
		return nil, "nohull"
	end
	if held then
		P.serverStats.held += 1
		return nil, "held"
	end
	if (cfs[1].Position - hullPos).Magnitude > P.PLAUSIBLE then
		P.serverStats.implausible += 1
		return nil, "implausible"
	end
	-- The stamp: at least MIN_STAMP_GAP from each of the last RECENT accepted and within STAMP_BAND of the server clock
	-- where it locked (no forged pair microseconds apart, no timeline running ahead or behind). Locked on the first pose
	-- and after STAMP_RELOCK of silence.
	local recent = g.recent
	if #recent == 0 or now - g.okAt > P.STAMP_RELOCK then
		table.clear(recent)
		g.band = stamp - now
	else
		local bad = math.abs(stamp - now - g.band) > P.STAMP_BAND
		for _, r in recent do
			if math.abs(stamp - r) < P.MIN_STAMP_GAP then
				bad = true
				break
			end
		end
		if bad then
			P.serverStats.stamp += 1
			return nil, "stamp"
		end
	end
	table.insert(recent, stamp)
	if #recent > P.RECENT then
		table.remove(recent, 1)
	end
	g.okAt = now
	P.serverStats.accepted += 1
	return stamp, cfs[1]
end

-- The packet other clients get: the sender's bytes with the id set to the hull's StreamId (never the client's).
function P.relayBuffer(b: buffer, id: number): buffer
	local out = buffer.create(buffer.len(b))
	buffer.copy(out, 0, b)
	buffer.writeu16(out, S.HEADER, id % 65536)
	return out
end

-- Whether a receiver gets a sender's poses: same race instance (nil = the shared race) and within RELAY_RANGE of the
-- sender's vehicle (a receiver with no vehicle, a spectator, gets every sender of his instance).
function P.relayable(senderPos: Vector3, senderGroup: any, recvPos: Vector3?, recvGroup: any): boolean
	if senderGroup ~= recvGroup then
		return false
	end
	return recvPos == nil or (recvPos - senderPos).Magnitude <= P.RELAY_RANGE
end

------------------------------------------------------------------------------------------------------------------------
-- Receiver

-- Eases the engine -> stream weight `w` (0 engine, 1 stream) by `dt` toward 1 when `has` a stream pose, else 0.
function P.stepBlend(w: number, has: boolean, dt: number): number
	local step = math.max(dt, 0) / P.BLEND_TIME
	return if has then math.min(1, w + step) else math.max(0, w - step)
end

-- The smoothstep of the blend weight (no speed step where the blend starts or ends).
function P.ease(w: number): number
	return w * w * (3 - 2 * w)
end

-- The pose to draw this frame. With a fresh stream pose `streamCF`: the engine's pose `engineCF` eased toward it by the
-- weight. Without one (the stream stopped): the last stream pose's offset from the engine (`offset`, in the engine
-- pose's space, offsetOf) rides along with the engine's pose and fades out, so the hand-back never freezes or slides
-- against the motion. Nil: leave the engine's pose.
function P.mix(engineCF: CFrame, streamCF: CFrame?, offset: CFrame?, w: number): CFrame?
	if w <= 0 then
		return nil
	end
	local e = P.ease(w)
	if streamCF then
		return if e >= 1 then streamCF else engineCF:Lerp(streamCF, e)
	end
	if offset == nil then
		return nil
	end
	return engineCF * CFrame.identity:Lerp(offset, e)
end

-- The stream pose in the engine pose's space (kept each frame while the stream draws, for the hand-back).
function P.offsetOf(engineCF: CFrame, streamCF: CFrame): CFrame
	return engineCF:ToObjectSpace(streamCF)
end

-- The stream pose kept within MAX_OFFSET studs of the engine's pose (rotation kept). Returns (pose, clamped).
function P.clampTo(engineCF: CFrame, streamCF: CFrame): (CFrame, boolean)
	local d = streamCF.Position - engineCF.Position
	local m = d.Magnitude
	if m <= P.MAX_OFFSET then
		return streamCF, false
	end
	return streamCF.Rotation + (engineCF.Position + d * (P.MAX_OFFSET / m)), true
end

-- The engine's pose of the hull this frame. `cur` the hull's CFrame as read now, `lastDrawn` / `lastEngine` what this
-- client wrote last frame and the engine pose it read then. When the hull still holds exactly the last write, the
-- engine did not put its replicated pose back (an anchored hull, a frame with no physics step, a sleeping assembly):
-- the last engine pose stands in. Returns (engine pose, restored).
function P.engineOf(cur: CFrame, lastDrawn: CFrame?, lastEngine: CFrame?): (CFrame, boolean)
	if lastDrawn ~= nil and lastEngine ~= nil and cur == lastDrawn then
		return lastEngine, false
	end
	return cur, true
end

-- Gameplay reads of another player's hull (the magnet pull and its arrival, in CarController and FlightController)
-- must see the engine's replicated pose, never this client's stream draw, which RacerView writes first in the frame.
-- RacerView records the engine pose here each frame it draws a hull; enginePosition falls back to the part's own
-- position (nothing drawn: they are the same).
P.enginePoses = (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: { cf: CFrame, at: number } }

-- What shows a remote player's vehicle on this client: RacerView registers the visual clone's root part (Shared.
-- RemoteCloneRules) under the real hull while one is drawn. Visual reads (minimap dot, bubbles, the jitter probe) use
-- visualOf; gameplay reads keep the real hull (enginePosition).
P.visuals = (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: any }

function P.visualOf(part: BasePart): BasePart
	local v = P.visuals[part]
	if v and v.Parent then
		return v
	end
	return part
end

function P.enginePosition(part: BasePart): Vector3
	local e = P.enginePoses[part]
	if e and os.clock() - e.at <= P.ENGINE_FRESH then
		return e.cf.Position
	end
	return part.Position
end

return P
