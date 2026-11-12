--!strict
-- Slipstream payoff (v37, client/Slipstream): tuck in behind a rival for CHARGE_TIME and the wake slingshots you past
-- (Mario Kart rule). Before this the wake was a cosmetic trail only (client/Vfx stepDraft). Pure numbers and the charge
-- step, pinned by tools/tests/slipstream_spec.luau.
--
-- Anti-cheat: the slingshot speeds are speeds the server's validators already allow (a car's is the blue mini-turbo
-- speed, under CarConfig.maxHorizontalSpeed; a plane's is PlaneConfig.BOOST_SPEED inside FlightServer's clamp), so no
-- validator bound moves. Bots get no slingshot (their pace is the roster + rubber band, unchanged).
local SlipstreamRules = {}

SlipstreamRules.MIN_AHEAD = 8 -- studs: nearer is bumping, not drafting
SlipstreamRules.MAX_AHEAD = 60
SlipstreamRules.CONE_DEG = 14 -- half-angle of the wake behind the rival
SlipstreamRules.MAX_UP = 10 -- studs above / below the local vehicle's plane (a car on a bridge above is no wake)
SlipstreamRules.MIN_RIVAL_SPEED = 85 -- the rival must be moving to leave a wake
SlipstreamRules.SPEED_RATIO = 0.85 -- and the local vehicle no slower than this fraction of it

SlipstreamRules.CHARGE_TIME = 1.3 -- seconds in the wake for a full charge
SlipstreamRules.DRAIN_RATE = 1.2 -- charge lost per second out of the wake (a short wobble out keeps most of it)
SlipstreamRules.COOLDOWN = 3.0 -- seconds after a slingshot before the next can charge

SlipstreamRules.CAR_SPEED = 150 -- CarConfig.DRIFT_LEVELS[1].boostSpeed
SlipstreamRules.CAR_SECONDS = 1.0
SlipstreamRules.PLANE_SECONDS = 0.9 -- at PlaneConfig.BOOST_SPEED

-- rel = rival position in the local hull's object space (-Z forward).
function SlipstreamRules.inWake(relX: number, relY: number, relZ: number, localSpeed: number, rivalSpeed: number): boolean
	local ahead = -relZ
	if ahead < SlipstreamRules.MIN_AHEAD or ahead > SlipstreamRules.MAX_AHEAD or math.abs(relY) > SlipstreamRules.MAX_UP then
		return false
	end
	if math.abs(relX) > ahead * math.tan(math.rad(SlipstreamRules.CONE_DEG)) + 2 then
		return false
	end
	return rivalSpeed >= SlipstreamRules.MIN_RIVAL_SPEED and localSpeed >= rivalSpeed * SlipstreamRules.SPEED_RATIO
end

export type State = { charge: number, cooldown: number }

function SlipstreamRules.new(): State
	return { charge = 0, cooldown = 0 }
end

-- One step. Returns true on the frame the charge completes (the slingshot fires; the charge resets and cools down).
function SlipstreamRules.step(st: State, inWake: boolean, dt: number): boolean
	if st.cooldown > 0 then
		st.cooldown = math.max(0, st.cooldown - dt)
		st.charge = math.max(0, st.charge - SlipstreamRules.DRAIN_RATE * dt)
		return false
	end
	if inWake then
		st.charge = math.min(1, st.charge + dt / SlipstreamRules.CHARGE_TIME)
		if st.charge >= 1 then
			st.charge = 0
			st.cooldown = SlipstreamRules.COOLDOWN
			return true
		end
	else
		st.charge = math.max(0, st.charge - SlipstreamRules.DRAIN_RATE * dt)
	end
	return false
end

return SlipstreamRules
