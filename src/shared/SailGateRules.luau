--!strict
-- FOREST-1 sail-gap timing ring (docs/design/TRACK_VARIETY.md 5a, "FOREST-1 launch upgrade"). Pure maths, no Instances.
--
-- The gate mill's sails turn on the shared server clock (workspace:GetServerTimeNow(), the same value on every client and
-- on the server), so the sail angle is a function of time alone: nothing is stepped per client and nothing drifts. A
-- booster ring stands inside the sail disc at a fixed angle. The ring is lit while it sits in the gap between two sails
-- and dark while a sail passes it. A lit ring gives the normal ring boost; a dark ring does nothing at all (no pull, no
-- boost, no penalty), so a miss costs only the boost.
--
-- Geometry: four arms at 45 + 90k degrees in the pivot's XY plane. The block prefab (tools/map/author_forest1.py pf_sails)
-- fills the ARM_SPAN degrees counter-clockwise of each stock at the ring radius; the v3 sails mesh that ArtSwap puts in its
-- place in game (assets/models/props_v3/windmill_sails) is centred on the stock, MESH_ARM_HALF degrees either side. The
-- lit window keeps the ring opening clear of both, so the ring is never lit with a sail across it. The model turns about its
-- pivot's +Z by (phase + rpm * 6 * t) degrees (client/WorldAnim, rate = rpm * pi / 30 rad/s), so every arm's angle only
-- grows with time.
local SailGateRules = {}

-- Feature flag: false makes the ring an ordinary, always live booster ring (the sails still turn on the shared clock).
SailGateRules.ENABLED = true

-- Attribute names set by the map builder (kit/Gameplay) on the ring's trigger disc and read by the controllers.
SailGateRules.ATTR_RPM = "SailGateRpm"
SailGateRules.ATTR_PHASE = "SailGatePhase"
SailGateRules.ATTR_RING_DEG = "SailGateRingDeg"
-- Set on the gate mill's sails model so client/WorldAnim turns it on the shared clock instead of a local timer.
SailGateRules.ATTR_CLOCK = "SailClock"
SailGateRules.ATTR_SAIL_PHASE = "SailPhase"

SailGateRules.ARMS = 4
SailGateRules.ARM_OFFSET_DEG = 45 -- angle of arm 0 when the model is at rest
SailGateRules.ARM_SPAN_DEG = 16 -- lattice width seen from the hub at the ring radius (about 10 wide at 35.5 studs)
SailGateRules.MESH_ARM_HALF_DEG = 10 -- v3 mesh blade half width about its stock at the ring radius (measured: 9.5)
SailGateRules.RING_HALF_DEG = 16 -- ring opening seen from the hub (radius ~10 at ~36 studs)
-- The ring counts as lit while its angle is LIT_FROM..LIT_TO degrees counter-clockwise of the nearest arm's stock. The
-- bare geometric gap is ARM_SPAN + RING_HALF = 32 (prefab) to 90 - MESH_ARM_HALF - RING_HALF = 64 (mesh); measured
-- against the real geometry it is 34.3..64.1 (tools/map/tests/test_forest1.py), so a lit ring never has a sail edge
-- across its opening.
SailGateRules.LIT_FROM_DEG = 35
SailGateRules.LIT_TO_DEG = 63
-- The server re-checks a reported crossing on the same clock; this covers the report's trip over the network. It must stay
-- shorter than the lit window (openSeconds) so checking both ends of the span is exact (liveWithin).
SailGateRules.SERVER_GRACE_S = 0.5
-- The glow starts rising this many degrees before the window opens, so a player reads that the gap is coming.
SailGateRules.WARN_DEG = 14

export type Config = { rpm: number, phaseDeg: number, ringDeg: number }

local STEP = 360 / SailGateRules.ARMS

local function wrap(x: number, m: number): number
	return x - m * math.floor(x / m)
end

-- Degrees the model has turned about its pivot at server time `t`.
function SailGateRules.spinDeg(t: number, rpm: number, phaseDeg: number?): number
	return wrap((phaseDeg or 0) + rpm * 6 * t, 360)
end

-- The ring's angle measured counter-clockwise from the nearest arm's stock behind it, 0..90.
function SailGateRules.relativeDeg(t: number, cfg: Config): number
	local arm0 = SailGateRules.ARM_OFFSET_DEG + SailGateRules.spinDeg(t, cfg.rpm, cfg.phaseDeg)
	return wrap(cfg.ringDeg - arm0, STEP)
end

function SailGateRules.isOpen(t: number, cfg: Config): boolean
	if not SailGateRules.ENABLED then
		return true
	end
	local rel = SailGateRules.relativeDeg(t, cfg)
	return rel >= SailGateRules.LIT_FROM_DEG and rel <= SailGateRules.LIT_TO_DEG
end

-- 0 while a sail covers the ring, rising to 1 over WARN_DEG before the window opens, 1 while it is open. The arms move
-- counter-clockwise, so the relative angle falls with time: the window opens at LIT_TO and shuts at LIT_FROM.
function SailGateRules.glow(t: number, cfg: Config): number
	if not SailGateRules.ENABLED then
		return 1
	end
	local rel = SailGateRules.relativeDeg(t, cfg)
	if rel >= SailGateRules.LIT_FROM_DEG and rel <= SailGateRules.LIT_TO_DEG then
		return 1
	end
	local ahead = rel - SailGateRules.LIT_TO_DEG
	if ahead > 0 and ahead < SailGateRules.WARN_DEG then
		return 1 - ahead / SailGateRules.WARN_DEG
	end
	return 0
end

-- Seconds until the window next opens (0 while it is open). Used by tests and by the bots' arrival check.
function SailGateRules.secondsToOpen(t: number, cfg: Config): number
	if SailGateRules.isOpen(t, cfg) then
		return 0
	end
	local rel = SailGateRules.relativeDeg(t, cfg)
	local degPerSec = cfg.rpm * 6
	local toGo = if rel > SailGateRules.LIT_TO_DEG then rel - SailGateRules.LIT_TO_DEG else rel + STEP - SailGateRules.LIT_TO_DEG
	return toGo / degPerSec
end

-- Seconds of one full cycle (one quarter turn) and how long the ring stays lit in it.
function SailGateRules.cycleSeconds(rpm: number): number
	return STEP / (rpm * 6)
end

function SailGateRules.openSeconds(rpm: number): number
	return (SailGateRules.LIT_TO_DEG - SailGateRules.LIT_FROM_DEG) / (rpm * 6)
end

-- Config from a ring trigger's attributes; nil when it is not a gate ring or the values are unusable, in which case
-- callers treat the ring as an ordinary one. Allocation free (called per ring per frame).
function SailGateRules.configOf(inst: Instance): Config?
	local rpm = inst:GetAttribute(SailGateRules.ATTR_RPM)
	if rpm == nil then
		return nil
	end
	local phase, ringDeg = inst:GetAttribute(SailGateRules.ATTR_PHASE), inst:GetAttribute(SailGateRules.ATTR_RING_DEG)
	if type(rpm) ~= "number" or rpm ~= rpm or rpm <= 0 or type(ringDeg) ~= "number" or ringDeg ~= ringDeg then
		return nil
	end
	return { rpm = rpm, phaseDeg = if type(phase) == "number" and phase == phase then phase else 0, ringDeg = ringDeg }
end

-- Whether a crossing reported at server time `t` happened while the ring was lit at some point in [t - grace, t]. With
-- grace shorter than the lit window a window cannot fall strictly inside the span, so its two ends decide.
function SailGateRules.liveWithin(t: number, cfg: Config?, grace: number): boolean
	if cfg == nil then
		return true
	end
	return SailGateRules.isOpen(t, cfg) or SailGateRules.isOpen(t - grace, cfg)
end

-- Whether a gated ring should act now: true for an ordinary ring (cfg nil).
function SailGateRules.live(t: number, cfg: Config?): boolean
	if cfg == nil then
		return true
	end
	return SailGateRules.isOpen(t, cfg)
end

return SailGateRules
