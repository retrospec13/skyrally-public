--!strict
-- Lune spec for the 2026-10-20 residual opponent jitter fix (docs/audits/opponent_jitter.md): bots stepped in whole
-- RacerViewRules.SERVER_STEP steps on the server, and the client's snapshot track timed in server sim time with a
-- lateness-floor clock. tools/tests/opponent_jitter_sim.luau replays a bot through server Heartbeats, replication and
-- client frames; the numbers below are the drawn bot's along-track jerk against a smooth chase camera.
-- Usage: SKYRALLY_TEST_VERBOSE=1 tools/tests/run_lune_tests.sh tools/tests/opponent_jitter_spec.luau (prints the table)

return function(h)
	local Rules = h.require("src/shared/RacerViewRules.luau")
	local Sim = h.require("tools/tests/opponent_jitter_sim.luau")

	h.test("serverSteps: whole steps, no sim time lost, a hitch spread over MAX_SERVER_STEPS", function()
		local clock = Rules.newServerClock()
		local n, dt = Rules.serverSteps(clock, 1 / 60)
		h.eq(n, 1, "one Heartbeat at 60 Hz is one step")
		h.ok(math.abs(dt - Rules.SERVER_STEP) < 1e-12, "of SERVER_STEP")
		h.eq((Rules.serverSteps(clock, 0)), 0, "a zero dt runs nothing")
		-- Jittered Heartbeats: the sim clock keeps up with the wall clock to within one step.
		local seed, wall, sim = 99, 1 / 60, 1 / 60
		for _ = 1, 3000 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local beat = (1 / 60) * (0.6 + 0.8 * seed / 2147483648)
			wall += beat
			local k, sdt = Rules.serverSteps(clock, beat)
			h.ok(k <= 2, "a jittered 60 Hz Heartbeat runs at most two steps")
			sim += k * sdt
		end
		h.ok(wall - sim >= -1e-6 and wall - sim < Rules.SERVER_STEP + 1e-6, "sim time trails wall time by under a step")
		local fresh = Rules.newServerClock()
		local k, sdt = Rules.serverSteps(fresh, 0.3)
		h.eq(k, Rules.MAX_SERVER_STEPS, "a 0.3 s hitch runs MAX_SERVER_STEPS steps")
		h.ok(math.abs(k * sdt - 0.3) < 1e-9, "covering all of it")
	end)

	-- Every network and server case, planes and cars, 60 and 144 fps: the drawn bot moves smoothly.
	h.test("fixed step + sim-time track: smooth in every replayed case", function()
		for _, fps in { 60, 144 } do
			for _, mode in { "plane", "car" } do
				for _, net in { "local", "live" } do
					for _, sendEvery in { 1, 2 } do
						for _, server in { "steady", "studio" } do
							local name = string.format("%s %s send/%d %s %d fps", mode, net, sendEvery, server, fps)
							local s = Sim.run(Rules, { mode = mode, net = net, server = server, fixedStep = true, sendEvery = sendEvery, fps = fps })
							print(Sim.format(name, s))
							h.ok(s.jerkP95 < 0.1, string.format("%s: jerk p95 %.3f < 0.1 stud", name, s.jerkP95))
							h.ok(s.jerkMax < 4, string.format("%s: worst frame %.2f < 4 studs", name, s.jerkMax))
							h.ok(s.wobbleP95 < 2, string.format("%s: wobble p95 %.2f < 2 studs", name, s.wobbleP95))
							h.ok(s.extrapolated < s.frames * 0.05, string.format("%s: %d extrapolated frames", name, s.extrapolated))
						end
					end
				end
			end
		end
	end)

	-- Root cause 1: a server stepped with the raw Heartbeat dt moves the bot unevenly per replicated pose, and no client
	-- timeline can tell a long step from a fast bot. The same client draws it many times rougher.
	h.test("a raw-dt server is what the fixed step removes", function()
		for _, mode in { "plane", "car" } do
			local o = { mode = mode, net = "local", server = "studio", fixedStep = false }
			local raw = Sim.run(Rules, o)
			o.fixedStep = true
			local fixed = Sim.run(Rules, o)
			print(Sim.format(mode .. " studio raw dt", raw))
			print(Sim.format(mode .. " studio fixed step", fixed))
			h.ok(raw.jerkP95 > 10 * fixed.jerkP95, string.format("%s: raw dt %.3f vs fixed %.3f", mode, raw.jerkP95, fixed.jerkP95))
			h.ok(raw.jerkP95 > 0.5, "the raw-dt surge is the visible kind (over half a stud a frame)")
		end
	end)

	h.test("a bot that stops and starts again resumes without a slide or a lurch", function()
		local track = Rules.newTrack()
		local written: CFrame? = nil
		local hull = CFrame.new(0, 0, 0)
		local zs: { number } = {}
		local z, speed = 0, 0
		for frame = 1, 60 * 6 do
			local now = frame / 60
			-- Parked 2 s, then a launch at 120 studs/s^2 to 150 studs/s (one server step per frame, 10 ms late).
			if now > 2 then
				speed = math.min(speed + 120 / 60, 150)
				z += speed / 60
				hull = CFrame.new(0, 0, z) -- the server's new pose replaces this client's own write
			end
			if Rules.changed(hull, written) then
				Rules.push(track, hull, now + 0.01)
			end
			local cf = Rules.sample(track, now + 0.01) :: CFrame
			hull = cf
			written = cf
			table.insert(zs, cf.Position.Z)
		end
		local worst, backwards = 0, false
		for i = 3, #zs do
			worst = math.max(worst, math.abs(zs[i] - 2 * zs[i - 1] + zs[i - 2]))
			backwards = backwards or zs[i] < zs[i - 1] - 1e-6
		end
		print(string.format("stop-and-go worst step change %.3f studs", worst))
		h.ok(not backwards, "never drawn moving backwards")
		h.ok(worst < 0.5, string.format("launch drawn without a lurch (%.3f studs)", worst))
	end)

	h.test("a spin-out in place (rotation only) is drawn, and stamps always increase", function()
		local track = Rules.newTrack()
		local t = 0
		for i = 0, 90 do
			t = i / 60
			Rules.push(track, CFrame.new(5, 0, 5) * CFrame.Angles(0, i * 0.1, 0), t + 0.02)
		end
		for i = 2, #track.snaps do
			h.ok(track.snaps[i].t > track.snaps[i - 1].t, "stamps increase")
		end
		local cf = Rules.sample(track, t + 0.02) :: CFrame
		h.ok((cf.Position - Vector3.new(5, 0, 5)).Magnitude < 1e-6, "stays on its spot")
		h.ok(math.abs(cf.LookVector:Dot(Vector3.new(0, 0, -1))) < 0.999, "turned")
	end)

	-- tools/jitter_probe.py's Studio sampler: its pure parts.
	h.test("JitterProbe: second differences and the summary rows", function()
		local Probe = h.require("src/shared/JitterProbe.luau")
		local a, b = Vector3.new(0, 0, 10), Vector3.new(0, 0, 10)
		h.eq(Probe.secondDiff(a, b, Vector3.new(0, 0, 10)), 0, "a racer holding station on the camera scores 0")
		h.ok(math.abs(Probe.secondDiff(Vector3.new(0, 0, 10), Vector3.new(0, 0, 12), Vector3.new(0, 0, 14))) < 1e-9, "a steady drift scores 0")
		h.ok(math.abs(Probe.secondDiff(Vector3.new(0, 0, 10), Vector3.new(0, 0, 10), Vector3.new(0, 0, 13)) - 3) < 1e-9, "a stall then a leap scores the leap")
		local xs: { number } = {}
		for i = 1, 100 do
			xs[i] = 101 - i
		end
		local s = Probe.summarise(xs)
		h.eq(s.n, 100, "count")
		h.eq(s.max, 100, "max")
		h.ok(s.p50 >= 50 and s.p50 <= 51, "median")
		h.ok(s.p95 >= 95 and s.p95 <= 96, "p95")
		h.eq(Probe.summarise({}).n, 0, "an empty row")
	end)
end
