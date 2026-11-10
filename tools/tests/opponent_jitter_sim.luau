--!strict
-- Offline replay of how this client draws an opponent bot (docs/audits/opponent_jitter.md). Not a spec: loaded by
-- tools/tests/opponent_jitter_spec.luau, which asserts on the numbers, and printable with
--   SKYRALLY_JITTER_REPORT=1 tools/tests/run_lune_tests.sh tools/tests/opponent_jitter_spec.luau
--
-- Server: one bot on a 400-stud circle, its speed eased toward a rubber-band wobble with a boost every 5 s, a 3-stud
-- weave, stepped every Heartbeat exactly as AIRacers does (station += speed * dt; a plane's hull lerps toward its goal
-- with dt * 12, a car's sits on its goal with only the rotation eased). The Heartbeat dt is steady, or jittered the way a
-- loaded Studio local server runs (+-30 %, 4 % hitches of 2-3 frames), optionally with rare 0.1-0.3 s stalls. `fixedStep` replays the fix: the bot simulation
-- runs whole RacerViewRules.serverSteps steps, so every replicated pose sits on a uniform sim-time grid.
-- Network: each Heartbeat that moved the hull sends its pose (`sendEvery` 2 = the latest pose every other Heartbeat),
-- landing latency + jitter later, in order (property replication is ordered); the client sees only the newest pose that
-- landed before its frame. Client: frames at `fps` with +-8 % frame-time jitter, each running RacerView.stepSmooth.
--
-- Metric: every drawn pose is mapped back to the sim time at which a fine reference run (1/1200 s steps) stood at the
-- same angle on the circle. drawn lag = frame time - that sim time. A smooth view has a smooth lag; its frame-to-frame
-- second difference times the speed is the along-track jerk in studs (what reads as jitter against a chase camera that
-- moves smoothly), and its deviation from a +-0.25 s moving average times the speed is the position wobble in studs.
local Sim = {}

export type Options = {
	seconds: number?,
	seed: number?,
	mode: string?, -- "plane" | "car"
	server: string?, -- "steady" | "studio" | "hitchy" (studio plus 0.5 % stalls of 0.1-0.3 s)
	fixedStep: boolean?,
	net: string?, -- "local" | "live"
	sendEvery: number?,
	fps: number?,
}

export type Stats = {
	jerkP50: number,
	jerkP95: number,
	jerkMax: number,
	wobbleP95: number,
	yawP95: number, -- degrees: second difference of the drawn heading (the circle's own turn is constant)
	extrapolated: number, -- frames drawn past the newest snapshot
	frames: number,
}

local R = 400
local HEIGHT = 60

local function rng(seed: number): () -> number
	local s = seed
	return function(): number
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

type Bot = { station: number, speed: number, simT: number, hull: CFrame }

local function targetSpeed(t: number): number
	local base = 190 + 20 * math.sin(0.8 * t)
	if t % 5 >= 2 and t % 5 < 3 then
		return 270
	end
	return base
end

local function goal(bot: Bot): CFrame
	local theta = bot.station / R
	local lateral = 3 * math.sin(1.6 * bot.simT)
	local h = HEIGHT + 1.2 * math.cos(1.3 * bot.simT)
	local pos = Vector3.new((R + lateral) * math.cos(theta), h, (R + lateral) * math.sin(theta))
	local tan = Vector3.new(-math.sin(theta), 0, math.cos(theta))
	return CFrame.lookAt(pos, pos + tan)
end

-- One AIRacers-style step (stepMotion's speed ease and advance, then renderPlane / renderCar).
local function stepBot(bot: Bot, dt: number, mode: string)
	local target = targetSpeed(bot.simT)
	local rate = if target > bot.speed then 9 else 4.5
	bot.speed += (target - bot.speed) * math.clamp(dt * rate, 0, 1)
	bot.station += bot.speed * dt
	bot.simT += dt
	local g = goal(bot)
	if mode == "plane" then
		bot.hull = bot.hull:Lerp(g, math.clamp(dt * 12, 0, 1))
	else
		bot.hull = CFrame.new(g.Position) * bot.hull.Rotation:Lerp(g.Rotation, math.clamp(dt * 14, 0, 1))
	end
end

local function newBot(): Bot
	local b: Bot = { station = 0, speed = 190, simT = 0, hull = CFrame.identity }
	b.hull = goal(b)
	return b
end

local function angleOf(p: Vector3): number
	return math.atan2(p.Z, p.X)
end

-- Unwraps successive angles into a continuous one.
local function unwrap(prev: number?, a: number): number
	if prev == nil then
		return a
	end
	local d = a - prev
	d = (d + math.pi) % (2 * math.pi) - math.pi
	return prev + d
end

local function percentile(xs: { number }, p: number): number
	local s = table.clone(xs)
	table.sort(s)
	if #s == 0 then
		return 0
	end
	return s[math.clamp(math.floor(p * (#s - 1) + 0.5) + 1, 1, #s)]
end

function Sim.run(Rules: any, opts: Options, client: any?): Stats
	local View = client or Rules -- the client rules under test (the server always steps with Rules.serverSteps)
	local seconds = opts.seconds or 30
	local mode = opts.mode or "plane"
	local server = opts.server or "studio"
	local net = opts.net or "local"
	local sendEvery = opts.sendEvery or 1
	local fps = opts.fps or 60
	local rand = rng(opts.seed or 7)

	-- Reference: the same bot stepped finely; angle (continuous) -> sim time table.
	local ref = newBot()
	local refT: { number } = { 0 }
	local refA: { number } = { angleOf(ref.hull.Position) }
	local refV: { number } = { ref.speed }
	local fine = 1 / 1200
	while ref.simT < seconds + 1 do
		stepBot(ref, fine, mode)
		table.insert(refT, ref.simT)
		table.insert(refA, unwrap(refA[#refA], angleOf(ref.hull.Position)))
		table.insert(refV, ref.speed)
	end
	local function simTimeAt(a: number): (number, number)
		local lo, hi = 1, #refA
		if a <= refA[1] then
			return refT[1], refV[1]
		end
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if refA[mid] <= a then
				lo = mid
			else
				hi = mid
			end
		end
		local f = (a - refA[lo]) / math.max(refA[hi] - refA[lo], 1e-12)
		return refT[lo] + (refT[hi] - refT[lo]) * f, refV[lo]
	end

	-- Server Heartbeats and the packets they send.
	local bot = newBot()
	local clock = Rules.newServerClock()
	local packets: { { arrive: number, cf: CFrame } } = {}
	local wall, beat, lastArrive, lastSent = 0, 0, 0, bot.hull
	while wall < seconds + 1 do
		local dt = 1 / 60
		if server == "studio" or server == "hitchy" then
			dt = (1 / 60) * (0.7 + 0.6 * rand())
			if rand() < 0.04 then
				dt = (1 / 60) * (2 + rand())
			end
			if server == "hitchy" and rand() < 0.005 then
				dt = 0.1 + 0.2 * rand() -- a GC or map-load stall
			end
		end
		wall += dt
		beat += 1
		if opts.fixedStep then
			local n, sdt = Rules.serverSteps(clock, dt)
			for _ = 1, n do
				stepBot(bot, sdt, mode)
			end
		else
			stepBot(bot, dt, mode)
		end
		if beat % sendEvery == 0 and bot.hull ~= lastSent then
			lastSent = bot.hull
			local latency = if net == "live" then 0.06 + 0.04 * rand() else 0.004 + 0.012 * rand()
			if rand() < (if net == "live" then 0.03 else 0.02) then
				latency += if net == "live" then 0.08 else 0.04
			end
			local arrive = math.max(lastArrive, wall + latency)
			lastArrive = arrive
			table.insert(packets, { arrive = arrive, cf = bot.hull })
		end
	end

	-- Client frames.
	local track = View.newTrack()
	local written: CFrame? = nil
	local hullCF: CFrame? = nil
	local nextPacket = 1
	local now = 0
	local lags: { number } = {}
	local speeds: { number } = {}
	local yaws: { number } = {}
	local extrapolated, frames = 0, 0
	local prevAngle: number? = nil
	while now < seconds do
		now += (1 / fps) * (0.92 + 0.16 * rand())
		while nextPacket <= #packets and packets[nextPacket].arrive <= now do
			hullCF = packets[nextPacket].cf
			nextPacket += 1
		end
		local current = hullCF
		if current then
			-- RacerView.stepSmooth
			if View.changed(current, written) then
				View.push(track, current, now)
			end
			local cf = View.sample(track, now, mode == "car")
			if cf then
				hullCF = cf
				written = cf
				if now > 2 then
					frames += 1
					local snaps = track.snaps
					local at = if track.at ~= nil then track.at else now - View.delay(track)
					if at > snaps[#snaps].t then
						extrapolated += 1
					end
					local a = unwrap(prevAngle, angleOf(cf.Position))
					prevAngle = a
					local t, v = simTimeAt(a)
					table.insert(lags, now - t)
					table.insert(speeds, v)
					local look = cf.LookVector
					table.insert(yaws, math.deg(math.atan2(look.X, look.Z)))
				end
			end
		end
	end

	local jerks: { number } = {}
	for i = 2, #lags - 1 do
		table.insert(jerks, math.abs(lags[i + 1] - 2 * lags[i] + lags[i - 1]) * speeds[i])
	end
	local wobble: { number } = {}
	local W = math.floor(fps * 0.25)
	for i = W + 1, #lags - W do
		local sum = 0
		for j = i - W, i + W do
			sum += lags[j]
		end
		table.insert(wobble, math.abs(lags[i] - sum / (2 * W + 1)) * speeds[i])
	end
	local yawJerk: { number } = {}
	for i = 2, #yaws - 1 do
		local d1 = (yaws[i + 1] - yaws[i] + 180) % 360 - 180
		local d0 = (yaws[i] - yaws[i - 1] + 180) % 360 - 180
		table.insert(yawJerk, math.abs(d1 - d0))
	end
	local maxJerk = 0
	for _, j in jerks do
		maxJerk = math.max(maxJerk, j)
	end
	return {
		jerkP50 = percentile(jerks, 0.5),
		jerkP95 = percentile(jerks, 0.95),
		jerkMax = maxJerk,
		wobbleP95 = percentile(wobble, 0.95),
		yawP95 = percentile(yawJerk, 0.95),
		extrapolated = extrapolated,
		frames = frames,
	}
end

function Sim.format(name: string, s: Stats): string
	return string.format(
		"%-44s jerk p50 %.3f p95 %.3f max %.2f studs | wobble p95 %.3f studs | yaw p95 %.3f deg | extrapolated %d/%d",
		name,
		s.jerkP50,
		s.jerkP95,
		s.jerkMax,
		s.wobbleP95,
		s.yawP95,
		s.extrapolated,
		s.frames
	)
end

return Sim
