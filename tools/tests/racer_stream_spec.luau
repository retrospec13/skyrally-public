--!strict
-- Lune spec for the opponent pose stream (2026-10-20 opp-smooth; Shared.RacerStreamRules, server/RacerStream,
-- client/RacerView; docs/audits/opponent_stream.md). Pure math, no Studio.
--
-- The replay: a bot flies (or drives) a known smooth path. The server steps it in whole RacerViewRules fixed steps
-- under Studio-like Heartbeat jitter, sends after every Heartbeat that stepped (RacerStreamRules.SEND_STEPS, 60 Hz) through the real encoder, the packets cross
-- an unreliable network (latency +-30 ms jitter, so they also reorder, and 1 % loss), and the client draws it with the
-- real decoder, clock, playhead and Catmull-Rom buffer on its render clock at 30 / 60 / 144 Hz with jittered frame
-- times. Metrics, per frame:
--   dev     |drawn - truth at the playhead|: how far the drawn racer is off the true path (studs)
--   jit     what the client adds frame to frame, in the jitter probe's studsT form: the time-normalised second
--           difference of (drawn - truth at the playhead), plus the playhead's own surge (second difference of the
--           playback lag times the speed). The true path's own acceleration is not in it: a real boost is motion.
--   jitT    for reference, the probe's studsT on (drawn - chase camera), the camera trailing on the same path (it
--           includes the true relative acceleration: the boosts), and raw, the probe's old metric (frame pacing too)
-- J1 marks (docs/STUDIO_ROUND_V22.md section 4) on jit: p95 < 0.05 studs, p99 < 0.3 studs; dev p99 < 0.3 studs.
-- Print the table: SKYRALLY_TEST_VERBOSE=1 tools/tests/run_lune_tests.sh tools/tests/racer_stream_spec.luau

return function(h)
	local S = h.require("src/shared/RacerStreamRules.luau")
	local Rules = h.require("src/shared/RacerViewRules.luau")
	local Probe = h.require("src/shared/JitterProbe.luau")

	local function rng(seed: number): () -> number
		local s = seed
		return function(): number
			s = (s * 1103515245 + 12345) % 2147483648
			return s / 2147483648
		end
	end

	local function pct(xs: { number }, p: number): number
		local s = table.clone(xs)
		table.sort(s)
		if #s == 0 then
			return 0
		end
		return s[math.clamp(math.floor(p * (#s - 1) + 0.5) + 1, 1, #s)]
	end

	local function maxOf(xs: { number }): number
		local m = 0
		for _, x in xs do
			m = math.max(m, x)
		end
		return m
	end

	-- The true path: speed integrated finely (rubber band 190 +- 20, a boost to 270 for 1 s every 5 s, eased like
	-- AIRacers), on a circle of radius R with a 3-stud weave; a car rides 0.6-stud road bumps, a plane bobs and banks.
	-- `jumpAt`: at that sim time the racer is respawned 200 studs back along the path (a cut).
	type Path = { pose: (number) -> CFrame, speedAt: (number) -> number }
	local function makePath(mode: string, R: number, seconds: number, jumpAt: number?): Path
		local fine = 1 / 1200
		local stations: { number } = { 0 }
		local speeds: { number } = { 190 }
		local v, st, t = 190, 0, 0
		while t < seconds + 2 do
			local target = 190 + 20 * math.sin(0.8 * t)
			if t % 5 >= 2 and t % 5 < 3 then
				target = 270
			end
			v += (target - v) * math.clamp(fine * (if target > v then 9 else 4.5), 0, 1)
			st += v * fine
			t += fine
			table.insert(stations, st)
			table.insert(speeds, v)
		end
		local function stationAt(tau: number): (number, number)
			local x = math.clamp(tau / fine, 0, #stations - 2)
			local i = math.floor(x)
			local f = x - i
			return stations[i + 1] + (stations[i + 2] - stations[i + 1]) * f, speeds[i + 1]
		end
		local function pose(tau: number): CFrame
			local s = stationAt(tau)
			if jumpAt and tau >= jumpAt then
				s -= 200
			end
			local theta = s / R
			local lateral = 3 * math.sin(1.6 * tau)
			local y = if mode == "car" then 0.6 * math.sin(s / 7) else 60 + 1.2 * math.cos(1.3 * tau)
			local pos = Vector3.new((R + lateral) * math.cos(theta), y, (R + lateral) * math.sin(theta))
			local tan = Vector3.new(-math.sin(theta), 0, math.cos(theta))
			local bank = if mode == "car" then 0 else math.rad(25)
			return CFrame.lookAt(pos, pos + tan) * CFrame.Angles(0, 0, bank)
		end
		return {
			pose = pose,
			speedAt = function(tau: number): number
				local _, sp = stationAt(tau)
				return sp
			end,
		}
	end

	export type Opts = {
		mode: string?,
		fps: number?,
		frameJitter: number?, -- +- fraction of the frame time
		latency: number?, -- s, mean one-way
		jitter: number?, -- s, +- uniform per packet (unreliable: packets may reorder)
		loss: number?,
		server: string?, -- "steady" | "studio"
		seconds: number?,
		seed: number?,
		R: number?,
		jumpAt: number?,
		stopAt: number?, -- the server stops sending at this sim time
		wallNoise: number?, -- s: os.clock() at the bind vs the summed dt (scheduling noise)
	}

	type Result = {
		dev: { number },
		jit: { number },
		jitE: { number },
		jitL: { number },
		fit: { number },
		fitTruth: { number }, -- the same fit on the true path at the same playheads (a bumpy road is real motion)
		jitT: { number },
		raw: { number },
		frames: number,
		extrap: number,
		held: number,
		drawn: { Vector3 },
		ats: { number },
		truthAt: (number) -> CFrame,
		bytes: number,
		packets: number,
	}

	local function run(o: Opts): Result
		local mode = o.mode or "plane"
		local fps = o.fps or 60
		local seconds = o.seconds or 20
		local rand = rng(o.seed or 11)
		local path = makePath(mode, o.R or 300, seconds, o.jumpAt)
		local path0 = makePath(mode, o.R or 300, seconds, nil)
		local ground = mode == "car"

		-- Server: Heartbeats, fixed steps, sends through the real encoder.
		type Pkt = { arrive: number, buf: buffer }
		local pkts: { Pkt } = {}
		local clock = Rules.newServerClock()
		local wall = 1000 -- the server's os.clock() at sim 0 (any epoch)
		local serverStart = wall
		local maxBytes = 0
		while wall - serverStart < seconds + 1 do
			local dt = 1 / 60
			if (o.server or "studio") == "studio" then
				dt = (1 / 60) * (0.7 + 0.6 * rand())
				if rand() < 0.04 then
					dt = (1 / 60) * (2 + rand())
				end
			end
			wall += dt
			local n = Rules.serverSteps(clock, dt)
			if n > 0 and (o.stopAt == nil or clock.sim < (o.stopAt :: number)) and S.shouldSend(clock) then
				local stamp = S.stamp(clock, wall)
				local buf = S.encode(1, stamp, { 7 }, { path.pose(clock.sim) })
				maxBytes = math.max(maxBytes, buffer.len(buf))
				if rand() >= (o.loss or 0.01) then
					local lat = (o.latency or 0.08) + (o.jitter or 0.03) * (2 * rand() - 1)
					table.insert(pkts, { arrive = wall + math.max(lat, 0.002), buf = buf })
				end
			end
		end
		table.sort(pkts, function(a, b)
			return a.arrive < b.arrive
		end)

		-- Client: the client's os.clock() runs on its own epoch (offset 5000 s from the server's).
		local CLIENT = 5000
		local sc = S.newClock()
		local track = S.newTrack(1)
		local rc = S.newRenderClock()
		local frameT = serverStart + CLIENT -- the summed dt (the chase camera's clock)
		local nextPkt = 1
		local res: Result = {
			dev = {},
			jit = {},
			jitE = {},
			jitL = {},
			fit = {},
			fitTruth = {},
			jitT = {},
			raw = {},
			frames = 0,
			extrap = 0,
			held = 0,
			drawn = {},
			ats = {},
			truthAt = function(at: number): CFrame
				return path.pose(at - (clock.epoch :: number))
			end,
			bytes = maxBytes,
			packets = #pkts,
		}
		local rel: { Vector3 } = {}
		local ts: { number } = {}
		local errs: { Vector3 } = {}
		local truths: { Vector3 } = {}
		local lagv: { Vector3 } = {}
		while frameT - CLIENT - serverStart < seconds do
			local dt = (1 / fps) * (1 + (o.frameJitter or 0.08) * (2 * rand() - 1))
			frameT += dt
			local osclock = frameT + (o.wallNoise or 0) * rand()
			-- packets that landed before this frame are handled at its start (OnClientEvent), stamped os.clock() then
			while nextPkt <= #pkts and pkts[nextPkt].arrive + CLIENT <= frameT do
				local source, stamp, ids, cfs = S.decode(pkts[nextPkt].buf)
				assert(source == 1 and ids[1] == 7, "decoded")
				S.observe(sc, stamp, osclock)
				S.push(track, stamp, cfs[1], osclock)
				nextPkt += 1
			end
			local now = S.advanceRender(rc, dt, osclock)
			local at = S.playhead(sc, now)
			local cf = if #track.snaps > 0 and at >= track.snaps[1].t then S.sample(track, at, ground) else nil
			if cf and frameT - CLIENT - serverStart > 3 then
				res.frames += 1
				if track.mode == "extrap" then
					res.extrap += 1
				elseif track.mode == "hold" then
					res.held += 1
				end
				local truth = res.truthAt(at)
				if o.jumpAt then
					-- around a respawn either branch is the truth (the old pose runs on until the cut's stamp)
					local alt = path0.pose(at - (clock.epoch :: number))
					if (cf.Position - alt.Position).Magnitude < (cf.Position - truth.Position).Magnitude then
						truth = alt
					end
				end
				table.insert(res.dev, (cf.Position - truth.Position).Magnitude)
				table.insert(res.drawn, cf.Position)
				table.insert(res.ats, at)
				-- The chase camera: trailing 0.3 s behind on the same path, 14 studs back and 5 up, on the frame clock.
				local camTau = (frameT - CLIENT - serverStart) - 0.42
				local cam = path.pose(camTau).Position + Vector3.new(0, 5, 0)
				table.insert(rel, cf.Position - cam)
				table.insert(ts, frameT)
				table.insert(errs, cf.Position - truth.Position)
				table.insert(truths, truth.Position)
				local W = Probe.FIT_WINDOW
				if #ts >= W then
					local ws, wt, wtr = table.create(W), table.create(W), table.create(W)
					local jumped = false
					for j = #ts - W + 1, #ts do
						table.insert(ws, res.drawn[#res.drawn - (#ts - j)])
						table.insert(wtr, truths[j])
						table.insert(wt, ts[j])
						if j > #ts - W + 1 and (ws[#ws] - ws[#ws - 1]).Magnitude > 60 then
							jumped = true
						end
					end
					if not jumped then
						table.insert(res.fit, Probe.fitResidual(ws, wt))
						table.insert(res.fitTruth, Probe.fitResidual(wtr, wt))
					end
				end
				table.insert(lagv, Vector3.new(frameT - CLIENT - at, 0, 0))
				local n = #rel
				if n >= 3 then
					local e = Probe.secondDiffT(errs[n - 2], errs[n - 1], errs[n], ts[n - 2], ts[n - 1], ts[n])
					local l = Probe.secondDiffT(lagv[n - 2], lagv[n - 1], lagv[n], ts[n - 2], ts[n - 1], ts[n])
					local lj = l * path.speedAt(at - (clock.epoch :: number))
					table.insert(res.jit, e + lj)
					table.insert(res.jitE, e)
					table.insert(res.jitL, lj)
					local big = (rel[n] - rel[n - 1]).Magnitude > 60 or (rel[n - 1] - rel[n - 2]).Magnitude > 60
					if not big then -- the probe skips a teleport the same way
						table.insert(res.jitT, Probe.secondDiffT(rel[n - 2], rel[n - 1], rel[n], ts[n - 2], ts[n - 1], ts[n]))
						table.insert(res.raw, Probe.secondDiff(rel[n - 2], rel[n - 1], rel[n]))
					end
				end
			end
		end
		return res
	end

	local function line(name: string, r: Result): string
		return string.format(
			"%-34s dev p95 %.3f p99 %.3f max %.2f | fit p95 %.4f p99 %.4f (truth %.4f) | jit p95 %.4f p99 %.4f max %.3f (curve p95 %.4f, playhead p95 %.4f) | cam jitT p95 %.3f p99 %.3f max %.2f | raw p95 %.3f p99 %.3f | extrap %d hold %d / %d",
			name,
			pct(r.dev, 0.95),
			pct(r.dev, 0.99),
			maxOf(r.dev),
			pct(r.fit, 0.95),
			pct(r.fit, 0.99),
			pct(r.fitTruth, 0.95),
			pct(r.jit, 0.95),
			pct(r.jit, 0.99),
			maxOf(r.jit),
			pct(r.jitE, 0.95),
			pct(r.jitL, 0.95),
			pct(r.jitT, 0.95),
			pct(r.jitT, 0.99),
			maxOf(r.jitT),
			pct(r.raw, 0.95),
			pct(r.raw, 0.99),
			r.extrap,
			r.held,
			r.frames
		)
	end

	h.test("wire: round trip, size cap, malformed packets rejected", function()
		local ids, cfs = {}, {}
		local rand = rng(3)
		for i = 1, S.MAX_ENTRIES do
			ids[i] = i * 1000 + 7
			cfs[i] = CFrame.new(rand() * 8000 - 4000, rand() * 500, rand() * 8000 - 4000)
				* CFrame.Angles(rand() * 6.28, rand() * 6.28, rand() * 6.28)
		end
		local b = S.encode(2, 123456.789, ids, cfs)
		h.ok(buffer.len(b) <= 900, "a full packet fits the 900-byte unreliable cap: " .. buffer.len(b))
		local source, stamp, gotIds, gotCfs = S.decode(b)
		h.eq(source, 2, "source")
		h.ok(stamp == 123456.789, "stamp is exact (f64)")
		h.eq(#gotIds, S.MAX_ENTRIES, "every entry")
		local worstPos, worstRot = 0, 0
		for i = 1, S.MAX_ENTRIES do
			h.eq(gotIds[i], ids[i], "id")
			worstPos = math.max(worstPos, (gotCfs[i].Position - cfs[i].Position).Magnitude)
			local _, ang = (cfs[i].Rotation:Inverse() * gotCfs[i].Rotation):ToAxisAngle()
			worstRot = math.max(worstRot, math.abs(ang))
		end
		h.ok(worstPos < 0.002, string.format("position within f32 precision: %.5f", worstPos))
		h.ok(worstRot < 2e-4, string.format("rotation within 2e-4 rad (0.002 studs at 10 studs): %.6f", worstRot))
		h.eq((S.decode("nope")), nil, "a string is not a packet")
		h.eq((S.decode(buffer.create(3))), nil, "a short buffer is not a packet")
		local bad = buffer.create(buffer.len(b) - 1)
		buffer.copy(bad, 0, b, 0, buffer.len(b) - 1)
		h.eq((S.decode(bad)), nil, "a truncated packet is rejected")
		local v2 = buffer.create(buffer.len(b))
		buffer.copy(v2, 0, b)
		buffer.writeu8(v2, 0, 2 * 16 + 1)
		h.eq((S.decode(v2)), nil, "another version is rejected")
		-- quaternion sign: w >= 0 always, rotation 180 degrees round each axis survives
		for _, r in { CFrame.Angles(math.pi, 0, 0), CFrame.Angles(0, math.pi, 0), CFrame.Angles(0, 0, math.pi) } do
			local _, _, _, c = S.decode(S.encode(1, 0, { 1 }, { r }))
			h.ok((c[1].LookVector - r.LookVector).Magnitude < 1e-3 and (c[1].UpVector - r.UpVector).Magnitude < 1e-3, "180 degree turn")
		end
	end)

	h.test("server: stamps sit on the exact step grid under Heartbeat jitter; one send per stepped Heartbeat", function()
		h.ok(S.STEP == Rules.SERVER_STEP, "the stream's step is the movers' fixed step")
		local clock = Rules.newServerClock()
		local rand = rng(5)
		local wall = 77.7
		local stamps: { number } = {}
		for _ = 1, 3000 do
			local dt = (1 / 60) * (0.7 + 0.6 * rand())
			if rand() < 0.04 then
				dt = (1 / 60) * (2 + rand())
			end
			wall += dt
			local n = Rules.serverSteps(clock, dt)
			if n > 0 and S.shouldSend(clock) then
				table.insert(stamps, S.stamp(clock, wall))
			end
		end
		local epoch = clock.epoch :: number
		local worstGrid, minGap, maxGap = 0, math.huge, 0
		for i, s in stamps do
			local k = (s - epoch) / S.STEP
			worstGrid = math.max(worstGrid, math.abs(k - math.floor(k + 0.5)))
			if i > 1 then
				minGap = math.min(minGap, s - stamps[i - 1])
				maxGap = math.max(maxGap, s - stamps[i - 1])
			end
		end
		h.ok(worstGrid < 1e-6, "every stamp is a whole number of steps from the epoch")
		h.ok(minGap >= S.SEND_STEPS * S.STEP - 1e-9, string.format("sends at least SEND_STEPS apart: %.4f", minGap))
		h.ok(maxGap <= (S.SEND_STEPS + 3) * S.STEP + 1e-9, string.format("and never a long gap: %.4f", maxGap))
		local secs = wall - 77.7
		-- one per Heartbeat that ran a step (a jittered 55 Hz Heartbeat runs no step now and then): 45-60 per second
		h.ok(#stamps / secs > 45 and #stamps / secs <= 60.5, string.format("%.1f sends per second", #stamps / secs))
		h.ok(math.abs(wall - (epoch + clock.sim + clock.acc)) < 1e-6, "epoch + sim + acc is the wall clock")
	end)

	h.test("client: the drawn path stays on the true path and passes J1 at 30/60/144 Hz with +-30 ms network jitter", function()
		for _, mode in { "plane", "car" } do
			for _, fps in { 30, 60, 144 } do
				for _, net in { { "live 80+-30ms", 0.08 }, { "local 35+-30ms", 0.035 } } do
					for _, pacing in { 0.08, 0.2 } do
						local name = string.format("%s %d Hz pace+-%d%% %s", mode, fps, math.floor(pacing * 100 + 0.5), net[1])
						local r = run({ mode = mode, fps = fps, latency = net[2], jitter = 0.03, frameJitter = pacing, wallNoise = 0.0005 })
						print(line(name, r))
						h.ok(r.frames > fps * 15, name .. ": drew every frame")
						-- the probe's studsT as this frame rate would print it (J1 is set at 60 fps; at 30 fps the same
						-- motion error reads up to 4x larger per frame, at 144 fps smaller, and both pass natively)
						h.ok(pct(r.jit, 0.95) < 0.05, string.format("%s: jitter p95 %.4f < 0.05 stud", name, pct(r.jit, 0.95)))
						h.ok(pct(r.jit, 0.99) < 0.3, string.format("%s: jitter p99 %.4f < 0.3 stud", name, pct(r.jit, 0.99)))
						-- the probe's own-path fit: under J1, or (a car on 4 Hz road bumps at 30 fps, real motion) within
						-- 0.02 / 0.1 stud of the same fit on the true path
						local f95, f99 = pct(r.fit, 0.95), pct(r.fit, 0.99)
						h.ok(f95 < math.max(0.05, pct(r.fitTruth, 0.95) + 0.02) and f99 < math.max(0.3, pct(r.fitTruth, 0.99) + 0.1),
							string.format("%s: own-path fit p95 %.4f p99 %.4f (true path %.4f / %.4f)", name, f95, f99, pct(r.fitTruth, 0.95), pct(r.fitTruth, 0.99)))
						h.ok(pct(r.dev, 0.99) < 0.3, string.format("%s: path deviation p99 %.3f < 0.3 stud", name, pct(r.dev, 0.99)))
						h.ok(r.extrap + r.held < r.frames * 0.03, string.format("%s: %d extrapolated frames", name, r.extrap + r.held))
					end
				end
			end
		end
	end)

	h.test("frame-rate independence: the same path and jitter at 30, 60 and 144 Hz", function()
		local devs: { number } = {}
		local jits: { number } = {}
		for _, fps in { 30, 60, 144 } do
			local r = run({ fps = fps, seed = 21 })
			table.insert(devs, pct(r.dev, 0.95))
			table.insert(jits, pct(r.jit, 0.95))
		end
		h.ok(math.max(devs[1], devs[2], devs[3]) < 0.1, string.format("deviation p95 30/60/144: %.3f %.3f %.3f", devs[1], devs[2], devs[3]))
		h.ok(math.max(devs[1], devs[2], devs[3]) - math.min(devs[1], devs[2], devs[3]) < 0.05, "deviation does not depend on the frame rate")
		h.ok(jits[1] >= jits[2] * 0.8 and jits[2] >= jits[3] * 0.8, string.format("per-frame jitter falls as the frame rate rises: %.4f %.4f %.4f", jits[1], jits[2], jits[3]))
		h.ok(math.max(jits[1], jits[2], jits[3]) < 0.05, "and passes J1 at every rate")
	end)

	h.test("pacing: the raw probe metric counts frame pacing, studsT does not", function()
		-- A perfect opponent: the true pose at each frame's own time, against a camera 40 studs/s slower.
		local rand = rng(9)
		local v, t = 190, 0
		local relList: { Vector3 } = {}
		local ts: { number } = {}
		local raw, tn = {}, {}
		for _ = 1, 3000 do
			t += (1 / 60) * (1 + 0.15 * (2 * rand() - 1)) -- a Studio window's frame times (16.6 p50, 19 p95)
			table.insert(relList, Vector3.new(0, -5, (v - (v - 40)) * t)) -- bot at v, camera at v - 40 (f32: keep it small)
			table.insert(ts, t)
			local n = #relList
			if n >= 3 then
				table.insert(raw, Probe.secondDiff(relList[n - 2], relList[n - 1], relList[n]))
				table.insert(tn, Probe.secondDiffT(relList[n - 2], relList[n - 1], relList[n], ts[n - 2], ts[n - 1], ts[n]))
			end
		end
		print(string.format("perfect opponent, 40 studs/s relative, +-15%% frame times: raw p50 %.3f p95 %.3f p99 %.3f | studsT p95 %.6f", pct(raw, 0.5), pct(raw, 0.95), pct(raw, 0.99), pct(tn, 0.95)))
		h.ok(pct(raw, 0.95) > 0.1, "raw second difference reads > 0.1 stud for a perfect opponent")
		h.ok(pct(tn, 0.95) < 0.002, "studsT reads 0 (f32 rounding)")
		h.ok(math.abs(Probe.secondDiffT(Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(2, 0, 0), 0, 1, 2)) < 1e-9, "even times: as secondDiff")
		-- the own-path fit: 0 on any parabola in time (a boost, a turn over 0.1 s) at uneven frame times; e for a pose e off
		local ps, tt = {}, {}
		local tm = 0
		for i = 1, 7 do
			tm += (1 / 60) * (1 + 0.2 * (2 * rand() - 1))
			tt[i] = tm
			ps[i] = Vector3.new(190 * tm + 0.5 * 720 * tm * tm, 3 * tm, -40 * tm * tm)
		end
		h.ok(Probe.fitResidual(ps, tt) < 1e-3, string.format("parabola fit %.6f", Probe.fitResidual(ps, tt)))
		ps[4] += Vector3.new(0, 0.2, 0)
		local r = Probe.fitResidual(ps, tt)
		h.ok(r > 0.1 and r < 0.2, string.format("a pose 0.2 off reads %.3f", r))
		h.ok(math.abs(Probe.secondDiffT(Vector3.new(0, 0, 0), Vector3.new(1, 2, 0), Vector3.new(2, 0, 0), 0, 1, 2) - Probe.secondDiff(Vector3.new(0, 0, 0), Vector3.new(1, 2, 0), Vector3.new(2, 0, 0))) < 1e-9, "even times: equal to secondDiff")
	end)

	h.test("the old inferred-time property track on the same stream (reference) is rougher", function()
		-- RacerViewRules' property path on the same server and network (ordered, newest per frame, 60 Hz), drawn on
		-- os.clock(): the comparison the audit table quotes.
		for _, mode in { "plane", "car" } do
			local rand = rng(13)
			local path = makePath(mode, 300, 20, nil)
			local clock = Rules.newServerClock()
			local wall = 0
			local sends: { { arrive: number, cf: CFrame } } = {}
			local lastArrive = 0
			while wall < 21 do
				local dt = (1 / 60) * (0.7 + 0.6 * rand())
				if rand() < 0.04 then
					dt = (1 / 60) * (2 + rand())
				end
				wall += dt
				local n = Rules.serverSteps(clock, dt)
				if n > 0 then
					local arrive = math.max(lastArrive, wall + 0.08 + 0.03 * (2 * rand() - 1))
					lastArrive = arrive
					table.insert(sends, { arrive = arrive, cf = path.pose(clock.sim) })
				end
			end
			local track = Rules.newTrack()
			local written: CFrame? = nil
			local hullCF: CFrame? = nil
			local k, now = 1, 0
			local rel, ts, jit, world, fit = {}, {}, {}, {}, {}
			while now < 20 do
				now += (1 / 60) * (1 + 0.08 * (2 * rand() - 1))
				while k <= #sends and sends[k].arrive <= now do
					hullCF = sends[k].cf
					k += 1
				end
				local cur = hullCF
				if cur then
					if Rules.changed(cur, written) then
						Rules.push(track, cur, now)
					end
					local cf = Rules.sample(track, now, mode == "car")
					if cf then
						hullCF, written = cf, cf
						if now > 3 then
							table.insert(rel, cf.Position - (path.pose(now - 0.42).Position + Vector3.new(0, 5, 0)))
							table.insert(ts, now)
							table.insert(world, cf.Position)
							local n = #rel
							if n >= Probe.FIT_WINDOW then
								table.insert(fit, Probe.fitResidual(table.move(world, n - Probe.FIT_WINDOW + 1, n, 1, {}), table.move(ts, n - Probe.FIT_WINDOW + 1, n, 1, {})))
							end
							if n >= 3 then
								table.insert(jit, Probe.secondDiffT(rel[n - 2], rel[n - 1], rel[n], ts[n - 2], ts[n - 1], ts[n]))
							end
						end
					end
				end
			end
			local new = run({ mode = mode, fps = 60, latency = 0.08, jitter = 0.03, frameJitter = 0.08, seed = 13 })
			print(string.format("%s live 80+-30ms 60 Hz, camera-relative studsT: property track p95 %.4f p99 %.4f max %.3f -> stream p95 %.4f p99 %.4f max %.3f", mode, pct(jit, 0.95), pct(jit, 0.99), maxOf(jit), pct(new.jitT, 0.95), pct(new.jitT, 0.99), maxOf(new.jitT)))
			print(string.format("%s live 80+-30ms 60 Hz, own-path fit: property track p95 %.4f p99 %.4f max %.3f -> stream p95 %.4f p99 %.4f max %.3f", mode, pct(fit, 0.95), pct(fit, 0.99), maxOf(fit), pct(new.fit, 0.95), pct(new.fit, 0.99), maxOf(new.fit)))
			h.ok(pct(new.fit, 0.99) < pct(fit, 0.99), mode .. ": the stream's own path is smoother at p99 than the property track's")
			h.ok(pct(new.jitT, 0.99) <= pct(jit, 0.99) * 1.05, mode .. ": the stream is no rougher at p99 than the property track")
		end
	end)

	h.test("teleport / respawn: a cut, never a slide across the map", function()
		for _, fps in { 30, 60, 144 } do
			local r = run({ fps = fps, jumpAt = 8, seed = 4 })
			local worst = maxOf(r.dev) -- the nearer of the pre-jump and the post-jump branch at each playhead
			local jumps = 0
			for i, p in r.drawn do
				if i > 1 and (p - r.drawn[i - 1]).Magnitude > 60 then
					jumps += 1
				end
			end
			h.eq(jumps, 1, fps .. " Hz: the respawn shows as one jump")
			h.ok(worst < 1, string.format("%d Hz: every frame on the true path (worst %.3f studs)", fps, worst))
		end
		-- push-level: the cut flag
		local tr = S.newTrack(1)
		S.push(tr, 0, CFrame.new(0, 0, 0), 0)
		S.push(tr, 1 / 30, CFrame.new(0, 0, 9), 0)
		h.ok(not tr.snaps[2].cut, "9 studs in 1/30 s (270 studs/s) is flight")
		S.push(tr, 2 / 30, CFrame.new(0, 0, 209), 0)
		h.ok(tr.snaps[3].cut, "200 studs in 1/30 s is a cut")
		local held = S.sample(tr, 1.5 / 30)
		h.ok(held ~= nil and ((held :: CFrame).Position - Vector3.new(0, 0, 13.5)).Magnitude < 1e-4, "before the cut the old pose runs on at its speed")
		local after = S.sample(tr, 2 / 30 + 0.001)
		h.ok(after ~= nil and ((after :: CFrame).Position - Vector3.new(0, 0, 209)).Magnitude < 1e-3, "at the cut the new pose shows")
	end)

	h.test("extrapolation is clamped: a stream that stops carries on MAX_EXTRAPOLATE, then holds", function()
		local r = run({ fps = 60, stopAt = 10, seconds = 14, seed = 8 })
		local last = r.drawn[#r.drawn]
		local prev = r.drawn[#r.drawn - 1]
		h.ok((last - prev).Magnitude < 1e-6, "the bot holds at the end")
		h.ok(r.held > 60, "held frames after the stream stopped: " .. r.held)
		local tr = S.newTrack(1)
		S.push(tr, 0, CFrame.new(0, 0, 0), 0)
		S.push(tr, 0.1, CFrame.new(0, 0, 20), 0) -- 200 studs/s
		local e1 = S.sample(tr, 0.15) :: CFrame
		h.ok(math.abs(e1.Position.Z - 30) < 1e-4 and tr.mode == "extrap", "50 ms past: carried on at the last velocity")
		local e2 = S.sample(tr, 1.0) :: CFrame
		h.ok(math.abs(e2.Position.Z - (20 + 200 * S.MAX_EXTRAPOLATE)) < 1e-4 and tr.mode == "hold", "then held at MAX_EXTRAPOLATE")
		local trG = S.newTrack(1)
		S.push(trG, 0, CFrame.new(0, 0, 0), 0)
		S.push(trG, 0.1, CFrame.new(0, 5, 20), 0)
		local g = S.sample(trG, 0.2, true) :: CFrame
		h.ok(math.abs(g.Position.Y - 5) < 1e-6, "a ground racer never extrapolates its height")
	end)

	h.test("buffer: out-of-order poses slotted in, duplicates dropped, capacity kept, crests not overshot", function()
		local tr = S.newTrack(1)
		h.ok(S.push(tr, 1, CFrame.new(0, 0, 0), 0), "first")
		h.ok(S.push(tr, 2, CFrame.new(1, 0, 0), 0), "second")
		h.ok(S.push(tr, 1.5, CFrame.new(0.5, 0, 0), 0), "out of order: slotted in")
		h.ok(tr.snaps[2].t == 1.5 and tr.snaps[3].t == 2, "in stamp order")
		h.ok(not S.push(tr, 2, CFrame.new(1, 0, 0), 0), "duplicate: dropped")
		h.ok(not S.push(tr, 0.5, CFrame.new(1, 0, 0), 0), "older than the whole buffer: dropped")
		for i = 3, 60 do
			S.push(tr, i, CFrame.new(i, 0, 0), 0)
		end
		h.eq(#tr.snaps, S.CAPACITY, "capacity")
		-- a symmetric crest: a ground racer between road-snapped poses never rises above it (an asymmetric one may, slightly:
		-- RacerStreamRules.tangent says why that is accepted)
		local c = S.newTrack(1)
		S.push(c, 0, CFrame.new(0, 0, 0), 0)
		S.push(c, 1, CFrame.new(10, 1, 0), 0)
		S.push(c, 2, CFrame.new(20, 0, 0), 0)
		S.push(c, 3, CFrame.new(30, -1, 0), 0)
		local top = -math.huge
		for k = 0, 100 do
			local cf = S.sample(c, 0.5 + k * 0.02, true) :: CFrame
			top = math.max(top, cf.Position.Y)
		end
		h.ok(top <= 1 + 1e-6, string.format("crest held at the road (%.4f)", top))
		-- interpolation hits the poses exactly
		local at1 = S.sample(c, 1, false) :: CFrame
		h.ok((at1.Position - Vector3.new(10, 1, 0)).Magnitude < 1e-6, "passes through the pose at its stamp")
	end)

	h.test("clocks: render clock follows dt, slews onto os.clock, relocks; playhead relocks on a new server clock", function()
		local rc = S.newRenderClock()
		h.eq(S.advanceRender(rc, 1 / 60, 10), 10, "starts on os.clock")
		local t = S.advanceRender(rc, 1 / 60, 10 + 1 / 60)
		h.ok(math.abs(t - (10 + 1 / 60)) < 1e-9, "advances by dt")
		-- os.clock 10 ms ahead: pulled in at most 2 % per frame
		local before = rc.t :: number
		local t2 = S.advanceRender(rc, 1 / 60, before + 1 / 60 + 0.01)
		h.ok(t2 - before <= (1 / 60) * 1.02 + 1e-9 and t2 - before > 1 / 60, "slewed, not jumped")
		local t3 = S.advanceRender(rc, 1 / 60, 50)
		h.eq(t3, 50, "a big gap relocks")
		local c = S.newClock()
		S.observe(c, 100, 5100.08)
		for i = 1, 60 do
			S.observe(c, 100 + i / 30, 5100.08 + i / 30)
		end
		local p1 = S.playhead(c, 5103)
		h.ok(math.abs((5103 - p1) - (5000.08 + S.delay(c))) < 0.01, "playhead = now - (offset + delay)")
		h.ok(S.delay(c) >= S.MIN_DELAY and S.delay(c) <= S.MAX_DELAY, "delay clamped")
		S.observe(c, 900, 5103.1) -- a new server clock (restart): relock
		h.ok(math.abs(c.offset - (5103.1 - 900)) < 1e-9, "relocked")
	end)

	-- A client frame stall: every packet queued during it is handled in one frame and looks late by up to the stall.
	-- The playhead must step by the frame's dt on every ordinary frame afterwards (no forward pop of every racer of the
	-- source when the lateness decays), whether the stall is flagged (RacerView) or not (a network burst looks the same).
	local function hitchRun(H: number, flagged: boolean): (number, number)
		local c = S.newClock()
		local rc = S.newRenderClock()
		local t, nextPkt, lastFrame, frameDt = 0, 0, -math.huge, 1 / 60
		local hitchAt, hitched = 5, false
		local prevHead: number? = nil
		local worstAfter, worstForward = 0, 0
		while t < 15 do
			local dt = 1 / 60
			if not hitched and t >= hitchAt then
				dt = H
				hitched = true
			end
			t += dt
			while nextPkt <= t - 0.08 do
				local stalled = flagged and lastFrame > -math.huge and S.isStall(t - lastFrame, frameDt)
				S.observe(c, nextPkt, t, stalled)
				nextPkt += 1 / 60
			end
			lastFrame = t
			frameDt += (math.clamp(dt, 0, 0.5) - frameDt) * 0.05
			local head = S.playhead(c, S.advanceRender(rc, dt, t))
			if prevHead and t > hitchAt + 0.05 then
				local adv = head - (prevHead :: number)
				worstAfter = math.max(worstAfter, math.abs(adv - dt))
				worstForward = math.max(worstForward, adv - dt)
			end
			prevHead = head
		end
		return worstAfter, worstForward
	end

	h.test("client stall: no playhead pop after a 0.3 / 0.45 s frame hitch; a burst never jumps racers forward", function()
		for _, H in { 0.3, 0.45 } do
			local after, fwd = hitchRun(H, true)
			h.ok(after < 0.01, string.format("stall %.2f s flagged: playhead step within 0.01 s of dt on later frames (%.4f)", H, after))
			local _, fwdU = hitchRun(H, false)
			h.ok(fwd < 0.01 and fwdU < 0.01, string.format("stall %.2f s: never a forward jump (flagged %.4f, unflagged %.4f)", H, fwd, fwdU))
		end
		h.ok(S.isStall(0.3, 1 / 60) and not S.isStall(0.05, 1 / 60), "a 300 ms gap is a stall, a frame is not")
		h.ok(not S.isStall(0.2, 0.125), "a steady 8 fps phone is not stalling")
		-- a stalled packet never relocks the clock or feeds the lateness
		local c = S.newClock()
		for i = 0, 60 do
			S.observe(c, i / 60, 100 + i / 60 + 0.08)
		end
		local off, late = c.offset, c.late
		S.observe(c, 61 / 60, 100 + 61 / 60 + 0.08 + 0.7, true)
		h.ok(math.abs(c.offset - off) < 0.01 and c.late == late, "stalled: no relock, no lateness")
	end)

	h.test("source guards: movers publish, RacerView draws the stream on the render clock, the probe has studsT", function()
		local ai = h.readFile("src/server/AIRacers.luau")
		h.ok(string.find(ai, "RacerViewRules.publish(1, stepClock, collectHulls)", 1, true) ~= nil, "AIRacers publishes race bots as source 1")
		local bc = h.readFile("src/server/battle/BattleCore.luau")
		h.ok(string.find(bc, "RacerViewRules.publish(2, botClock, botHulls)", 1, true) ~= nil, "BattleCore publishes battle bots as source 2")
		local br = h.readFile("src/server/BossRace.luau")
		h.ok(string.find(br, "RacerViewRules.publish(3, a.clock", 1, true) ~= nil, "BossRace publishes hazards as source 3")
		h.eq(S.SOURCE_RACE, 1, "source ids match the movers")
		h.eq(S.SOURCE_BATTLE, 2, "")
		h.eq(S.SOURCE_HAZARD, 3, "")
		local boot = h.readFile("src/server/init.server.luau")
		h.ok(string.find(boot, "require(script.RacerStream).init()", 1, true) ~= nil, "the server boots the stream")
		local rv = h.readFile("src/client/RacerView.luau")
		h.ok(string.find(rv, "Stream.advanceRender(renderClock, dt, wallNow)", 1, true) ~= nil, "RacerView draws on the render clock")
		h.ok(string.find(rv, "Stream.observe(c :: Stream.Clock, stamp, arrival, stalled)", 1, true) ~= nil, "RacerView flags packets a client stall queued")
		local rs = h.readFile("src/server/RacerStream.luau")
		h.ok(string.find(rs, "r.OnServerEvent:Connect(onPlayerPose)", 1, true) ~= nil, "client sends go through the remote-player gate (remote_stream_spec)")
		h.ok(string.find(rs, "not holder or holder.Parent == nil", 1, true) ~= nil, "a wrapped StreamId skips ids live parts hold")
		h.ok(string.find(rv, "local now = os.clock()", 1, true) == nil, "not on os.clock()")
		h.ok(string.find(rv, "remote.OnClientEvent:Connect(onStreamPacket)", 1, true) ~= nil, "RacerView listens to the stream")
		local jp = h.readFile("src/shared/JitterProbe.luau")
		h.ok(string.find(jp, "studsT = if sT", 1, true) ~= nil, "the probe reports studsT")
		h.ok(string.find(jp, "local hull = m.PrimaryPart", 1, true) ~= nil, "the probe still measures the drawn hull")
		local py = h.readFile("tools/jitter_probe.py")
		h.ok(string.find(py, "studsT", 1, true) ~= nil, "jitter_probe.py prints studsT")
		-- the hard rule: the player's own vehicle code is untouched by this change (no stream use there)
		local cc = h.readFile("src/client/CarController.luau")
		local fc = h.readFile("src/client/FlightController.luau")
		h.ok(string.find(cc, "RacerStream", 1, true) == nil and string.find(fc, "RacerStream", 1, true) == nil, "own-vehicle controllers untouched")
	end)
end
