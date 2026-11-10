--!strict
-- Lune spec for remote players' pose stream (2026-10-20 remote-smooth; Shared.PlayerStreamRules + RacerStreamRules,
-- client/RacerView, server/RacerStream; docs/audits/opponent_stream.md "Remote players"). Pure math, no Studio.
--
-- The replay, two clients and a server:
--   sender    a human flies (or drives) a known smooth path on its own client: render frames at 15/30/60 fps with
--             jittered frame times, the controller's pose at the sum of its dt, sent through the real
--             PlayerStreamRules.senderStep (stamp + encoder); client send jitter +-30 ms around 40 ms, 1 % loss
--   server    the real gate (size, source, rate, plausibility against the server's copy of the hull, which trails
--             the client by 60 ms) and relay (id rewritten to the hull's StreamId), handled on the next jittered
--             server Heartbeat (relay delay), then 50 +- 30 ms and 1 % loss to the receiver
--   receiver  the real decoder, per-player clock (clockKey), playhead, Hermite buffer and render clock at
--             30/60/144 Hz with jittered frame times
-- Metrics as racer_stream_spec (dev, jit = client-added studsT, fit = the probe's own-path fit, jitT = the probe's
-- studsT against a trailing chase camera, raw = the probe's old studs). The Studio baseline these replace
-- (evidence/jitter/jitter_mp_dino4_a3b89bc.json, Player2 row player_plane_physics): fit p95 0.281 / p99 0.389,
-- studsT p95 0.93 / p99 2.00, raw p95 0.94 / p99 1.99. Marks: fit p95 < 0.05, jit p95 < 0.05, studsT well below raw.
-- Print the table: SKYRALLY_TEST_VERBOSE=1 tools/tests/run_lune_tests.sh tools/tests/remote_stream_spec.luau

return function(h)
	local S = h.require("src/shared/RacerStreamRules.luau")
	local P = h.require("src/shared/PlayerStreamRules.luau")
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

	-- A human's path: 190 +- 20 studs/s, a boost to 270 every 5 s, a weave; a plane bobs and banks, a car rides
	-- 0.6-stud bumps. `jumpAt`: respawned 200 studs back at that sim time.
	local function makePath(mode: string, R: number, seconds: number, jumpAt: number?): (number) -> CFrame
		local fine = 1 / 1200
		local stations: { number } = { 0 }
		local v, st, t = 190, 0, 0
		while t < seconds + 3 do
			local target = 190 + 20 * math.sin(0.8 * t)
			if t % 5 >= 2 and t % 5 < 3 then
				target = 270
			end
			v += (target - v) * math.clamp(fine * (if target > v then 9 else 4.5), 0, 1)
			st += v * fine
			t += fine
			table.insert(stations, st)
		end
		return function(tau: number): CFrame
			local x = math.clamp(tau / fine, 0, #stations - 2)
			local i = math.floor(x)
			local s = stations[i + 1] + (stations[i + 2] - stations[i + 1]) * (x - i)
			if jumpAt and tau >= jumpAt then
				s -= 200
			end
			local theta = s / R
			local lateral = 3 * math.sin(1.6 * tau)
			local y = if mode == "car" then 0.6 * math.sin(s / 7) else 60 + 1.2 * math.cos(1.3 * tau)
			local pos = Vector3.new((R + lateral) * math.cos(theta), y, (R + lateral) * math.sin(theta))
			local tan = Vector3.new(-math.sin(theta), 0, math.cos(theta))
			return CFrame.lookAt(pos, pos + tan) * CFrame.Angles(0, 0, if mode == "car" then 0 else math.rad(25))
		end
	end

	type Opts = {
		mode: string?,
		senderFps: number?,
		fps: number?,
		seconds: number?,
		seed: number?,
		jumpAt: number?,
		loss: number?,
		lateJoin: number?, -- the receiver starts this many s in
	}
	type Result = {
		dev: { number },
		jit: { number },
		fit: { number },
		fitTruth: { number },
		jitT: { number },
		raw: { number },
		drawn: { Vector3 },
		frames: number,
		firstDraw: number?,
		extrap: number,
		sent: number,
		relayed: number,
		rejected: number,
		seconds: number,
		truthT: { number }, -- studsT of the TRUE path against the same camera (real motion: boosts, turns)
	}

	local function run(o: Opts): Result
		local mode = o.mode or "plane"
		local seconds = o.seconds or 20
		local rand = rng(o.seed or 17)
		local path = makePath(mode, 300, seconds, o.jumpAt)
		local path0 = makePath(mode, 300, seconds, nil)
		local loss = o.loss or 0.01
		P.serverStats.relayed = 0

		-- Sender client: its own os.clock() epoch (300 s).
		local SENDER = 300
		local sender = P.newSender()
		local sim, wallS = 0, SENDER
		local sfps = o.senderFps or 60
		type Pkt = { at: number, buf: buffer, pos: number }
		local toServer: { Pkt } = {}
		local frames: { { t: number, cf: CFrame } } = {} -- the sender's own hull per frame (the engine baseline)
		local sent = 0
		while sim < seconds + 1 do
			local dt = (1 / sfps) * (1 + 0.08 * (2 * rand() - 1))
			sim += dt
			wallS += dt
			local cf = path(sim)
			table.insert(frames, { t = wallS - SENDER, cf = cf })
			local b = P.senderStep(sender, dt, wallS + 0.0005 * rand(), cf)
			if b then
				sent += 1
				if rand() >= loss then
					-- client send jitter: 40 ms +- 30 ms to the server (unreliable: may reorder)
					table.insert(toServer, { at = wallS - SENDER + 0.04 + 0.03 * (2 * rand() - 1), buf = b, pos = sim })
				end
			end
		end
		table.sort(toServer, function(a, b)
			return a.at < b.at
		end)

		-- Server: Heartbeats at 60 Hz +-30 %; each packet is handled on the first Heartbeat after it lands (relay delay),
		-- gated against the server's copy of the hull (the physics replica, 60 ms behind the sender's sim).
		local gate = P.newGate()
		type Out = { at: number, buf: buffer }
		local toClient: { Out } = {}
		local hb, k = 0, 1
		local rejected = 0
		while k <= #toServer do
			hb += (1 / 60) * (0.7 + 0.6 * rand())
			while k <= #toServer and toServer[k].at <= hb do
				local pk = toServer[k]
				local hullPos = path(math.max(pk.pos - 0.06, 0)).Position
				local stamp = P.admit(gate, pk.buf, hb, hullPos, false)
				if stamp then
					P.serverStats.relayed += 1
					if rand() >= loss then
						table.insert(toClient, { at = hb + 0.05 + 0.03 * (2 * rand() - 1), buf = P.relayBuffer(pk.buf, 4242) })
					end
				else
					rejected += 1
				end
				k += 1
			end
		end
		table.sort(toClient, function(a, b)
			return a.at < b.at
		end)

		-- Receiver: os.clock() epoch 9000 s; render clock; per-player clock.
		local RECV = 9000
		local fps = o.fps or 60
		local clocks: { [number]: any } = {}
		local tracks: { [number]: any } = {}
		local rc = S.newRenderClock()
		local frameT = (o.lateJoin or 0)
		local idx = 1
		while idx <= #toClient and toClient[idx].at < frameT do
			idx += 1 -- a late joiner never saw the earlier packets
		end
		local res: Result = {
			dev = {},
			jit = {},
			fit = {},
			fitTruth = {},
			jitT = {},
			raw = {},
			drawn = {},
			frames = 0,
			firstDraw = nil,
			extrap = 0,
			sent = sent,
			relayed = P.serverStats.relayed,
			rejected = rejected,
			seconds = sim,
			truthT = {},
		}
		local rel, ts, errs, truths, lagv, trel = {}, {}, {}, {}, {}, {}
		local senderEpoch: number? = nil
		local camLag: number? = nil -- the chase camera: the own plane on the same line, a fixed time behind (frame clock)
		while frameT < seconds do
			local dt = (1 / fps) * (1 + 0.08 * (2 * rand() - 1))
			frameT += dt
			local osclock = frameT + RECV + 0.0005 * rand()
			while idx <= #toClient and toClient[idx].at <= frameT do
				local source, stamp, ids, cfs = S.decode(toClient[idx].buf)
				assert(source == P.SOURCE and ids[1] == 4242, "relayed packet decodes with the server's id")
				local key = P.clockKey(source :: number, ids[1])
				local c = clocks[key]
				if not c then
					c = S.newClock()
					clocks[key] = c
				end
				S.observe(c, stamp, osclock)
				local tr = tracks[ids[1]]
				if not tr then
					tr = S.newTrack(source :: number, key, P.SNAP_SPEED)
					tracks[ids[1]] = tr
				end
				S.push(tr, stamp, cfs[1], osclock)
				idx += 1
			end
			senderEpoch = sender.epoch
			local now = S.advanceRender(rc, dt, osclock)
			local tr = tracks[4242]
			local cf: CFrame? = nil
			local at = 0
			if tr then
				at = S.playhead(clocks[tr.clock], now)
				if #tr.snaps > 0 and at >= tr.snaps[1].t then
					cf = S.sample(tr, at, false)
				end
			end
			if cf then
				if res.firstDraw == nil then
					res.firstDraw = frameT
				end
				if frameT > 3 + (o.lateJoin or 0) then
					res.frames += 1
					if tr.mode == "extrap" or tr.mode == "hold" then
						res.extrap += 1
					end
					local simAt = at - (senderEpoch :: number)
					local truth = path(simAt)
					if o.jumpAt then
						local alt = path0(simAt)
						if (cf.Position - alt.Position).Magnitude < (cf.Position - truth.Position).Magnitude then
							truth = alt
						end
					end
					table.insert(res.dev, (cf.Position - truth.Position).Magnitude)
					table.insert(res.drawn, cf.Position)
					if camLag == nil then
						camLag = frameT - simAt + 0.1
					end
					local cam = path0(frameT - (camLag :: number)).Position + Vector3.new(0, 5, 0)
					table.insert(rel, cf.Position - cam)
					table.insert(trel, truth.Position - cam)
					table.insert(ts, frameT)
					table.insert(errs, cf.Position - truth.Position)
					table.insert(truths, truth.Position)
					table.insert(lagv, Vector3.new(frameT - simAt, 0, 0))
					local n = #rel
					local W = Probe.FIT_WINDOW
					if n >= W then
						local ws, wt, wtr = {}, {}, {}
						local jumped = false
						for j = n - W + 1, n do
							table.insert(ws, res.drawn[j])
							table.insert(wtr, truths[j])
							table.insert(wt, ts[j])
							if j > n - W + 1 and (res.drawn[j] - res.drawn[j - 1]).Magnitude > 60 then
								jumped = true
							end
						end
						if not jumped then
							table.insert(res.fit, Probe.fitResidual(ws, wt))
							table.insert(res.fitTruth, Probe.fitResidual(wtr, wt))
						end
					end
					if n >= 3 then
						local big = (rel[n] - rel[n - 1]).Magnitude > 60 or (rel[n - 1] - rel[n - 2]).Magnitude > 60
						if not big then
							local e = Probe.secondDiffT(errs[n - 2], errs[n - 1], errs[n], ts[n - 2], ts[n - 1], ts[n])
							local l = Probe.secondDiffT(lagv[n - 2], lagv[n - 1], lagv[n], ts[n - 2], ts[n - 1], ts[n])
							table.insert(res.jit, e + l * 220)
							table.insert(res.jitT, Probe.secondDiffT(rel[n - 2], rel[n - 1], rel[n], ts[n - 2], ts[n - 1], ts[n]))
							table.insert(res.raw, Probe.secondDiff(rel[n - 2], rel[n - 1], rel[n]))
							table.insert(res.truthT, Probe.secondDiffT(trel[n - 2], trel[n - 1], trel[n], ts[n - 2], ts[n - 1], ts[n]))
						end
					end
				end
			end
		end
		return res
	end

	local function line(name: string, r: Result): string
		return string.format(
			"%-40s dev p95 %.3f p99 %.3f | fit p95 %.4f p99 %.4f (truth %.4f) | jit p95 %.4f p99 %.4f | studsT p95 %.3f p99 %.3f (true motion %.3f) | raw p95 %.3f p99 %.3f | extrap %d / %d | sent %.1f/s",
			name,
			pct(r.dev, 0.95),
			pct(r.dev, 0.99),
			pct(r.fit, 0.95),
			pct(r.fit, 0.99),
			pct(r.fitTruth, 0.95),
			pct(r.jit, 0.95),
			pct(r.jit, 0.99),
			pct(r.jitT, 0.95),
			pct(r.jitT, 0.99),
			pct(r.truthT, 0.95),
			pct(r.raw, 0.95),
			pct(r.raw, 0.99),
			r.extrap,
			r.frames,
			r.sent / r.seconds
		)
	end

	h.test("remote player: 60 fps sender, +-30 ms send jitter, 1 % loss, server relay, 30/60/144 Hz receivers", function()
		for _, mode in { "plane", "car" } do
			for _, fps in { 30, 60, 144 } do
				local name = string.format("%s sender 60 -> recv %d Hz", mode, fps)
				local r = run({ mode = mode, fps = fps, senderFps = 60 })
				print(line(name, r))
				h.ok(r.frames > fps * 15, name .. ": drawn from the stream every frame")
				local f95 = pct(r.fit, 0.95)
				h.ok(f95 < math.max(0.05, pct(r.fitTruth, 0.95) + 0.02), string.format("%s: own-path fit p95 %.4f < 0.05 (true path %.4f)", name, f95, pct(r.fitTruth, 0.95)))
				h.ok(pct(r.jit, 0.95) < 0.05, string.format("%s: client-added studsT p95 %.4f < 0.05", name, pct(r.jit, 0.95)))
				h.ok(pct(r.jit, 0.99) < 0.3, string.format("%s: client-added studsT p99 %.4f < 0.3", name, pct(r.jit, 0.99)))
				h.ok(pct(r.dev, 0.99) < 0.3, string.format("%s: path deviation p99 %.3f", name, pct(r.dev, 0.99)))
				-- studsT against a chase camera on the same line 0.1 s behind (the probe's number): within 0.05 of the
				-- TRUE path's studsT against that camera (a boost onset is real relative acceleration, 4x larger per frame
				-- at 30 Hz), and at 60 Hz and up far below the Studio baseline (raw p95 0.94, studsT 0.93, p99 2.0)
				h.ok(pct(r.jitT, 0.95) < pct(r.truthT, 0.95) + 0.05, string.format("%s: studsT p95 %.3f = true motion %.3f + under 0.05", name, pct(r.jitT, 0.95), pct(r.truthT, 0.95)))
				if fps >= 60 and mode == "plane" then
					h.ok(pct(r.jitT, 0.95) < 0.94 / 5 and pct(r.jitT, 0.99) < 1.99 / 5, string.format("%s: studsT p95 %.3f p99 %.3f under a fifth of the Studio raw 0.94 / 1.99", name, pct(r.jitT, 0.95), pct(r.jitT, 0.99)))
				end
				h.ok(r.extrap < r.frames * 0.03, string.format("%s: %d extrapolated frames", name, r.extrap))
				-- planes against the Studio remote plane (fit p95 0.281); a car's 4 Hz road bumps are real motion (its fit is
				-- held to the true path's above)
				if mode == "plane" then
					h.ok(f95 * 5 < 0.281, string.format("%s: fit p95 %.4f is under a fifth of the Studio remote plane's 0.281", name, f95))
				end
				h.eq(r.rejected, 0, name .. ": the gate passes an honest sender")
			end
		end
	end)

	h.test("remote player: slow senders (30 fps phone, 15 fps throttled Studio window)", function()
		for _, sfps in { 30, 15 } do
			for _, fps in { 30, 60, 144 } do
				local name = string.format("plane sender %d -> recv %d Hz", sfps, fps)
				local r = run({ fps = fps, senderFps = sfps, seed = 23 })
				print(line(name, r))
				local mark = if sfps >= 30 then 0.05 else 0.12
				h.ok(pct(r.fit, 0.95) < mark, string.format("%s: own-path fit p95 %.4f < %.2f", name, pct(r.fit, 0.95), mark))
				h.ok(pct(r.dev, 0.99) < (if sfps >= 30 then 0.5 else 2.0), string.format("%s: deviation p99 %.3f", name, pct(r.dev, 0.99)))
				h.ok(pct(r.fit, 0.95) * 2 < 0.281, string.format("%s: fit p95 %.4f under half the Studio remote player's 0.281", name, pct(r.fit, 0.95)))
			end
		end
	end)

	h.test("remote player: respawn is one cut, late joiner draws within half a second", function()
		for _, fps in { 30, 60, 144 } do
			local r = run({ fps = fps, jumpAt = 8, seed = 5 })
			local jumps = 0
			for i, p in r.drawn do
				if i > 1 and (p - r.drawn[i - 1]).Magnitude > 60 then
					jumps += 1
				end
			end
			h.eq(jumps, 1, fps .. " Hz: the respawn shows as one jump")
			h.ok(maxOf(r.dev) < 1.5, string.format("%d Hz: every frame on one branch of the true path (worst %.3f)", fps, maxOf(r.dev)))
		end
		local late = run({ fps = 60, lateJoin = 7, seed = 8 })
		print(string.format("late joiner: first stream frame %.3f s after joining", (late.firstDraw or 99) - 7))
		h.ok(late.firstDraw ~= nil and (late.firstDraw :: number) - 7 < 0.5, string.format("late joiner: first stream frame %.3f s after joining", (late.firstDraw or 99) - 7))
		h.ok(pct(late.fit, 0.95) < 0.05, string.format("late joiner: fit p95 %.4f", pct(late.fit, 0.95)))
	end)

	h.test("sender cadence and bandwidth with 8 players", function()
		local rates = {}
		for _, sfps in { 30, 60, 144 } do
			local s = P.newSender()
			local n, t = 0, 0
			local rand = rng(sfps)
			while t < 10 do
				local dt = (1 / sfps) * (1 + 0.08 * (2 * rand() - 1))
				t += dt
				if P.senderStep(s, dt, 50 + t, CFrame.new(t, 0, 0)) then
					n += 1
				end
			end
			rates[sfps] = n / t
		end
		print(string.format("sends per second at 30/60/144 fps: %.1f %.1f %.1f", rates[30], rates[60], rates[144]))
		h.ok(rates[30] > 29 and rates[30] < 31, "30 fps: every frame")
		h.ok(rates[60] > 58 and rates[60] <= P.RATE, "60 fps: every frame, under the server's rate")
		h.ok(rates[144] > 40 and rates[144] < 70, "144 fps: capped near 60 Hz")
		local peak = math.max(rates[60], rates[144])
		local players = 8
		local perRecv = (players - 1) * peak * P.SIZE
		local serverOut = players * perRecv
		local up = peak * P.SIZE
		print(string.format("8 players at %.0f Hz, %d-byte payload: upload %.2f KB/s per client, download %.1f KB/s per client, server out %.1f KB/s (payload, before Roblox's per-event overhead)", peak, P.SIZE, up / 1000, perRecv / 1000, serverOut / 1000))
		h.eq(P.SIZE, 32, "one pose is 32 bytes")
		h.ok(perRecv < 16000, "under 16 KB/s per receiver for 7 remote players")
	end)

	h.test("server gate: size, source, rate, plausibility, holds; relay rewrites the id only", function()
		local cf = CFrame.new(100, 50, -20) * CFrame.Angles(0.3, 1.1, -0.2)
		local good = S.encode(P.SOURCE, 1234.5, { 999 }, { cf })
		local g = P.newGate()
		local stamp, got = P.admit(g, good, 0, cf.Position + Vector3.new(30, 0, 0), false)
		h.ok(stamp == 1234.5, "an honest pose is admitted")
		h.ok((got.Position - cf.Position).Magnitude < 0.01, "with its pose")
		h.eq((P.admit(g, "x", 0.1, cf.Position, false)), nil, "a string is refused")
		h.eq((P.admit(g, S.encode(P.SOURCE, 1, { 1, 2 }, { cf, cf }), 0.2, cf.Position, false)), nil, "two entries are refused (size)")
		h.eq((P.admit(g, S.encode(1, 1, { 1 }, { cf }), 0.3, cf.Position, false)), nil, "a bot source is refused")
		local _, why = P.admit(g, good, 0.4, cf.Position + Vector3.new(0, 0, 500), false)
		h.eq(why, "implausible", "a pose 500 studs off the server's hull is refused")
		_, why = P.admit(g, good, 0.5, cf.Position, true)
		h.eq(why, "held", "a hull in a server hold is not relayed")
		_, why = P.admit(g, good, 0.6, nil, false)
		h.eq(why, "nohull", "a player without a vehicle is not relayed")
		-- a flood: 400 packets in one second
		local flood = P.newGate()
		local ok = 0
		for i = 1, 400 do
			if P.admit(flood, good, 10 + i / 400, cf.Position, false) then
				ok += 1
			end
		end
		h.ok(ok <= P.RATE + P.BURST + 1, string.format("a flood of 400/s is cut to %d", ok))
		local nan = buffer.create(P.SIZE)
		buffer.copy(nan, 0, good)
		buffer.writef32(nan, S.HEADER + 2, 0 / 0)
		h.eq((P.admit(P.newGate(), nan, 0, cf.Position, false)), nil, "a NaN position is refused")
		local relayed = P.relayBuffer(good, 4242)
		local src, st, ids, cfs = S.decode(relayed)
		h.eq(src, P.SOURCE, "source kept")
		h.ok(st == 1234.5, "the sender's own stamp kept")
		h.eq(ids[1], 4242, "the id is the server's StreamId, not the client's 999")
		h.ok((cfs[1].Position - cf.Position).Magnitude < 0.01, "pose kept")
		local _, _, oids = S.decode(good)
		h.eq(oids[1], 999, "the sender's buffer is untouched")
		h.ok(P.relayable(Vector3.zero, nil, Vector3.new(500, 0, 0), nil), "same race, near: relayed")
		h.ok(not P.relayable(Vector3.zero, nil, Vector3.new(5000, 0, 0), nil), "far: culled")
		h.ok(not P.relayable(Vector3.zero, 1, Vector3.new(5, 0, 0), 2), "another race instance: culled")
		h.ok(P.relayable(Vector3.zero, 3, nil, 3), "a spectator of the same instance: relayed")
		h.eq(P.clockKey(1, 7), 1, "bots key their clock by source")
		h.eq(P.clockKey(P.SOURCE, 7), P.CLOCK_BASE + 7, "each player has his own clock")
	end)

	h.test("blend: engine -> stream and back without a pop", function()
		local engineAt = function(t: number): CFrame
			return CFrame.new(200 * t, 50, 0)
		end
		local streamAt = function(t: number): CFrame
			return CFrame.new(200 * t - 12, 50, 0) -- the stream trails the engine by 60 ms here
		end
		local w = 0
		local last: CFrame? = nil
		local worst = 0
		local offset: CFrame? = nil
		local t = 0
		for i = 1, 150 do
			t += 1 / 60
			local has = i > 20 and i < 90
			local s = if has then streamAt(t) else nil
			w = P.stepBlend(w, has, 1 / 60)
			if s then
				offset = P.offsetOf(engineAt(t), s)
			end
			local cf = P.mix(engineAt(t), s, offset, w) or engineAt(t)
			if last then
				-- per-frame step minus the 3.33 studs of true motion
				worst = math.max(worst, math.abs((cf.Position - (last :: CFrame).Position).Magnitude - 200 / 60))
			end
			last = cf
		end
		h.ok(worst < 1.0, string.format("a 12-stud offset blends in and out with at most %.2f studs of extra step per frame", worst))
		h.eq(P.mix(CFrame.new(), nil, nil, 0.5), nil, "no stream, no override")
		h.ok(P.ease(0) == 0 and P.ease(1) == 1 and math.abs(P.ease(0.5) - 0.5) < 1e-9, "smoothstep ends")
	end)

	h.test("abuse: forged stamps microseconds apart are refused; the curve and the draw stay bounded", function()
		local hull = Vector3.new(0, 50, 0)
		local function pkt(stamp: number, x: number): buffer
			return S.encode(P.SOURCE, stamp, { 1 }, { CFrame.new(hull + Vector3.new(x, 0, 0)) })
		end
		-- the reviewer's attack: two poses 2 us apart, -11 and +12 studs, every 1/60 s
		local g = P.newGate()
		local passed = 0
		local tr = S.newTrack(P.SOURCE, P.clockKey(P.SOURCE, 1), P.SNAP_SPEED)
		for i = 0, 120 do
			local t = 100 + i / 60
			for j, b in { pkt(t, -11), pkt(t + 2e-6, 12) } do
				local stamp, cf = P.admit(g, b, 5 + i / 60 + j * 1e-4, hull, false)
				if stamp then
					passed += 1
					S.push(tr, stamp, cf, 0)
				end
			end
		end
		h.ok(passed <= 121, string.format("the gate drops the twin of each pair (%d of 242 passed)", passed))
		h.ok(P.serverStats.stamp >= 120, "counted as stamp refusals")
		-- even poses that reach a receiver directly (no server gate) cannot fling the curve
		local raw = S.newTrack(P.SOURCE, 99, P.SNAP_SPEED)
		for i = 0, 60 do
			local t = 200 + i / 60
			S.push(raw, t, CFrame.new(hull + Vector3.new(-11, 0, 0)), 0)
			S.push(raw, t + 2e-6, CFrame.new(hull + Vector3.new(12, 0, 0)), 0) -- under MIN_GAP: dropped
			S.push(raw, t + 0.005, CFrame.new(hull + Vector3.new(12, 0, 0)), 0)
		end
		local worst = 0
		for i = 0, 600 do
			local at = 200 + i / 600 + 0.12 -- through the buffer and past its end (extrapolation)
			local cf = S.sample(raw, at, false)
			if cf then
				worst = math.max(worst, (cf.Position - hull).Magnitude)
			end
		end
		h.ok(worst < 12 + S.MAX_TANGENT * S.MAX_EXTRAPOLATE + 1, string.format("worst drawn %.1f studs from the hull (was 28,182 / 574,989)", worst))
		-- and the receiver's last line: the draw is clamped to MAX_OFFSET from the engine's pose
		local far, clamped = P.clampTo(CFrame.new(hull), CFrame.new(hull + Vector3.new(500, 0, 0)) * CFrame.Angles(0, 1, 0))
		h.ok(clamped and math.abs((far.Position - hull).Magnitude - P.MAX_OFFSET) < 1e-6, "clamped to MAX_OFFSET")
		h.ok(far.Rotation:FuzzyEq(CFrame.Angles(0, 1, 0), 1e-6), "rotation kept")
		local near, c2 = P.clampTo(CFrame.new(hull), CFrame.new(hull + Vector3.new(10, 0, 0)))
		h.ok(not c2 and near.Position == hull + Vector3.new(10, 0, 0), "an honest offset is untouched")
	end)

	h.test("stamp band: honest reorder relayed, a timeline run ahead refused, relock after silence", function()
		local cf = CFrame.new(0, 50, 0)
		local g = P.newGate()
		local function adm(stamp: number, now: number)
			return P.admit(g, S.encode(P.SOURCE, stamp, { 1 }, { cf }), now, cf.Position, false)
		end
		h.ok(adm(1000, 10) ~= nil, "first pose locks the band")
		h.ok(adm(1000 + 2 / 60, 10.04) ~= nil, "next")
		h.ok(adm(1000 + 1 / 60, 10.05) ~= nil, "an out-of-order pose (unreliable reorder) is still relayed")
		h.eq((adm(1000 + 1 / 60, 10.06)), nil, "a duplicate is refused")
		h.eq((adm(1003, 10.07)), nil, "a stamp 3 s ahead of the server clock is refused")
		h.eq((adm(990, 10.08)), nil, "a stamp 10 s behind is refused")
		h.ok(adm(1000 + 3 / 60, 10.1) ~= nil, "the honest timeline goes on")
		h.ok(adm(1000 + 0.3 + 4 / 60, 10.12) ~= nil, "a sender re-anchor (0.25 s slack) stays in the band")
		h.ok(adm(5000, 12) ~= nil, "after STAMP_RELOCK of silence (a paused phone) the band relocks")
		h.ok(adm(5000 + 1 / 60, 12.02) ~= nil, "and the new timeline flows")
	end)

	h.test("hand-back: an engine that does not put its pose back (anchored hold) never compounds the offset", function()
		-- the hull as this client sees it: the engine restores it each frame until `freeze`, then never again (the
		-- server anchored it); RacerView's loop: engineOf, mix, write
		local hullCF = CFrame.new(0, 50, 0)
		local drawn: CFrame?, engine: CFrame? = nil, nil
		local w, offset = 0, nil :: CFrame?
		local worst, restores = 0, 0
		local t = 0
		for i = 1, 120 do
			t += 1 / 60
			if i < 60 then
				hullCF = CFrame.new(200 * t, 50, 0) -- the engine's replicated pose
			end
			local eng, restored = P.engineOf(hullCF, drawn, engine)
			if not restored then
				restores += 1
			end
			local s = if i < 50 then CFrame.new(200 * t - 12, 50, 0) else nil -- the stream stops (the server refuses)
			w = P.stepBlend(w, s ~= nil, 1 / 60)
			if s and (restored or offset == nil) then
				offset = P.offsetOf(eng, s)
			end
			local d = P.mix(eng, s, offset, w)
			if d then
				hullCF = d -- the local write
				drawn, engine = d, eng
				if i >= 60 then
					worst = math.max(worst, (d.Position - eng.Position).Magnitude)
				end
			else
				if not restored then
					hullCF = eng -- RacerView: the hand-back ends on the engine's pose
				end
				drawn, engine = nil, nil
			end
		end
		h.ok(restores > 0, "the frozen engine is detected")
		h.ok(worst <= 12.001, string.format("the frozen hull's draw stays within the 12-stud offset (%.2f; compounding gave ~10x)", worst))
		h.ok((hullCF.Position - CFrame.new(200 * 59 / 60, 50, 0).Position).Magnitude < 0.01, "once handed back the hull rests at the engine's last pose")
	end)

	h.test("enginePosition: the recorded engine pose while fresh, else the part's own", function()
		local part = { Position = Vector3.new(1, 2, 3) }
		h.ok(P.enginePosition(part :: any) == Vector3.new(1, 2, 3), "nothing recorded: the part")
		P.enginePoses[part] = { cf = CFrame.new(9, 9, 9), at = os.clock() }
		h.ok(P.enginePosition(part :: any) == Vector3.new(9, 9, 9), "recorded this frame: the engine pose")
		P.enginePoses[part] = { cf = CFrame.new(9, 9, 9), at = os.clock() - 1 }
		h.ok(P.enginePosition(part :: any) == Vector3.new(1, 2, 3), "stale: the part")
		P.enginePoses[part] = nil
	end)

	h.test("in-place draw is OFF by default (Studio V5A noRestore ~30 %): only an explicit true turns it on", function()
		h.eq(P.DRAW_DEFAULT, false, "config default off")
		h.eq(P.DRAW_ATTR, "SkyRallyRemoteDraw", "the workspace attribute")
		h.eq(P.drawOn(nil), false, "attribute unset: off")
		h.eq(P.drawOn(false), false, "false: off")
		h.eq(P.drawOn("true"), false, "a non-boolean: off")
		h.eq(P.drawOn(1), false, "a number: off")
		h.eq(P.drawOn(true), true, "only an explicit true: on")
	end)

	h.test("source guards: render only, own vehicle never written, controllers and gameplay untouched", function()
		local rv = h.readFile("src/client/RacerView.luau")
		local rs = h.readFile("src/server/RacerStream.luau")
		h.ok(string.find(rv, "elseif r.remote and not r.own then", 1, true) ~= nil, "RacerView draws remote players only, never this player's own vehicle")
		h.ok(string.find(rv, "local remote = not isBot and not own and not r.hull.Anchored", 1, true) ~= nil, "a held (anchored) hull is left to the engine")
		h.ok(string.find(rv, "if hull.Anchored or not PStream.drawOn(workspace:GetAttribute(PStream.DRAW_ATTR)) then", 1, true) ~= nil, "every frame: an anchored hull (or drawing switched off) is handed back, never written")
		h.ok(string.find(rv, "SkyRallyRemoteDraw\") == false", 1, true) == nil, "no opt-out read left: the in-place draw is opt-in")
		h.ok(string.find(rv, "PStream.engineOf(hull.CFrame, r.drawn, r.engine)", 1, true) ~= nil, "the engine pose is checked for this client's own last write")
		h.ok(string.find(rv, "PStream.clampTo(engineCF, cf)", 1, true) ~= nil, "the stream pose is clamped to the engine's")
		h.ok(string.find(rv, "PStream.enginePoses[hull] = { cf = engineCF", 1, true) ~= nil, "the engine pose is recorded for gameplay reads")
		h.ok(string.find(rv, "Enum.RenderPriority.Camera.Value + 5", 1, true) ~= nil, "the own pose is sent after both controllers stepped")
		h.ok(string.find(rv, "PStream.senderStep(sender, dt, os.clock(), hull.CFrame)", 1, true) ~= nil, "the sender reads the hull, never writes it")
		h.ok(string.find(rs, "P.admit(", 1, true) ~= nil and string.find(rs, "P.relayBuffer(", 1, true) ~= nil, "the server gates and relays")
		-- the relay never moves anything: no CFrame, velocity or anchoring writes in the server stream module
		h.ok(string.find(rs, "%.CFrame%s*=") == nil and string.find(rs, "Anchored%s*=") == nil and string.find(rs, "Velocity%s*=") == nil, "the server stream writes no hull state")
		h.ok(string.find(rs, "hull.Anchored or not (seat :: Seat).owned", 1, true) ~= nil, "a car hold (ownership taken, not anchored) refuses poses too")
		for _, path in { "src/server/FlightServer.luau", "src/server/CarServer.luau", "src/server/RaceManager.luau", "src/server/ItemService.luau" } do
			h.ok(string.find(h.readFile(path), "PlayerStreamRules", 1, true) == nil, path .. " does not read the visual stream")
		end
		-- The controllers use PlayerStreamRules for one thing: the magnet reads the target at the ENGINE pose (never the
		-- stream draw RacerView wrote first in the frame). No other use, and no raw target position read left.
		for _, path in { "src/client/FlightController.luau", "src/client/CarController.luau" } do
			local src = h.readFile(path)
			local uses = 0
			for use in string.gmatch(src, "PlayerStreamRules%.([%w_]+)") do
				h.eq(use, "enginePosition", path .. " uses PlayerStreamRules only for enginePosition")
				uses += 1
			end
			h.eq(uses, 2, path .. ": both magnet reads go through enginePosition")
			h.ok(string.find(src, "tHull.Position", 1, true) == nil, path .. ": no magnet read of the drawn hull")
		end
	end)
end
