--!strict
-- Lune spec for shared/SailGateRules (FOREST-1 sail-gap timing ring) and the wiring of the controllers, bots and sails.
-- Run: tools/tests/run_lune_tests.sh tools/tests/sail_gate_spec.luau
return function(h)
	local R = h.require("src/shared/SailGateRules.luau")
	local cfg = { rpm = 4, phaseDeg = 0, ringDeg = 220.4 }

	local function near(a: number, b: number, tol: number)
		h.ok(math.abs(a - b) <= tol, string.format("%f vs %f", a, b))
	end

	local function fakeInst(attrs: { [string]: any })
		return {
			GetAttribute = function(_self: any, k: string): any
				return attrs[k]
			end,
		}
	end

	h.test("spin angle: rpm * 6 degrees a second on the shared clock, wrapped, phase added", function()
		h.eq(R.spinDeg(0, 4, 0), 0)
		near(R.spinDeg(1, 4, 0), 24, 1e-9)
		near(R.spinDeg(15, 4, 0), 0, 1e-9) -- one full turn
		near(R.spinDeg(1, 4, 10), 34, 1e-9)
		near(R.spinDeg(3.75 * 1000, 4, 0), 0, 1e-6)
		h.ok(R.spinDeg(123456.789, 4.6, 33) >= 0 and R.spinDeg(123456.789, 4.6, 33) < 360)
	end)

	h.test("the lit window is the quarter-turn gap: 35 to 63 degrees past an arm, once every 3.75 s, lit 1.17 s", function()
		near(R.cycleSeconds(4), 3.75, 1e-9)
		near(R.openSeconds(4), 28 / 24, 1e-9)
		local lit = 0
		local steps = 3750
		for i = 0, steps - 1 do
			if R.isOpen(i / 1000, cfg) then
				lit += 1
			end
		end
		near(lit / 1000, R.openSeconds(4), 0.01)
		-- periodic in one quarter turn
		for _, t in { 0.2, 1.1, 2.9 } do
			h.eq(R.isOpen(t, cfg), R.isOpen(t + R.cycleSeconds(4), cfg))
			h.eq(R.isOpen(t, cfg), R.isOpen(t + 10 * R.cycleSeconds(4), cfg))
		end
	end)

	h.test("a sail edge is never across a lit ring: the window keeps the arm and the ring opening apart", function()
		for i = 0, 3749 do
			local t = i / 1000
			if R.isOpen(t, cfg) then
				local rel = R.relativeDeg(t, cfg)
				h.ok(rel - R.RING_HALF_DEG > R.ARM_SPAN_DEG, "ring clear of the arm behind it")
				h.ok(rel + R.RING_HALF_DEG < 90, "ring clear of the next arm")
				-- the in-game sails are the v3 mesh (ArtSwap), its blades centred on the stock: clear of both edges too
				h.ok(rel - R.RING_HALF_DEG > R.MESH_ARM_HALF_DEG, "ring clear of the mesh blade behind it")
				h.ok(rel + R.RING_HALF_DEG + R.MESH_ARM_HALF_DEG < 90, "ring clear of the mesh blade ahead")
			end
		end
	end)

	h.test("glow: 0 under a sail, ramps over the warning arc before the window, 1 inside it, never negative", function()
		local sawZero, sawRamp, sawFull = false, false, false
		local prevOpen = false
		for i = 0, 3749 do
			local t = i / 1000
			local g = R.glow(t, cfg)
			h.ok(g >= 0 and g <= 1)
			if g == 0 then
				sawZero = true
			elseif g < 1 then
				sawRamp = true
			else
				sawFull = true
			end
			h.eq(R.isOpen(t, cfg), g == 1)
			-- the ramp only ever precedes an opening: once the window has shut the glow is 0 again, not a fade-out
			if prevOpen and not R.isOpen(t, cfg) then
				h.eq(g, 0)
			end
			prevOpen = R.isOpen(t, cfg)
		end
		h.ok(sawZero and sawRamp and sawFull)
	end)

	h.test("secondsToOpen: 0 while lit, otherwise the exact wait for the next window", function()
		for i = 0, 3749, 7 do
			local t = i / 1000
			local w = R.secondsToOpen(t, cfg)
			if R.isOpen(t, cfg) then
				h.eq(w, 0)
			else
				h.ok(w > 0 and w < R.cycleSeconds(4))
				h.ok(R.isOpen(t + w + 1e-6, cfg), "open when the wait is over")
				h.ok(not R.isOpen(t + w * 0.99 - 1e-6, cfg), "still dark just before")
			end
		end
	end)

	h.test("liveWithin: the server accepts a crossing lit at any instant of the network grace, never one dark throughout", function()
		h.ok(R.SERVER_GRACE_S < R.openSeconds(4), "grace shorter than the lit window (the two-ends check is exact)")
		h.ok(R.liveWithin(5, nil, R.SERVER_GRACE_S), "ordinary ring")
		for i = 0, 3749, 3 do
			local t = i / 1000
			local brute = false
			for k = 0, 50 do
				if R.isOpen(t - R.SERVER_GRACE_S * k / 50, cfg) then
					brute = true
					break
				end
			end
			h.eq(R.liveWithin(t, cfg, R.SERVER_GRACE_S), brute)
		end
	end)

	h.test("two clients and the server agree: the state is a function of the clock only", function()
		for _, t in { 1000.25, 98765.4321, 5e6 + 0.5 } do
			h.eq(R.isOpen(t, cfg), R.isOpen(t, { rpm = 4, phaseDeg = 0, ringDeg = 220.4 }))
			h.eq(R.glow(t, cfg), R.glow(t, { rpm = 4, phaseDeg = 0, ringDeg = 220.4 }))
		end
	end)

	h.test("configOf: reads the ring's attributes; anything unusable is an ordinary always-live ring", function()
		local ok = R.configOf(fakeInst({ SailGateRpm = 4, SailGatePhase = 7, SailGateRingDeg = 220.4 }))
		h.ok(ok ~= nil)
		h.eq((ok :: any).rpm, 4)
		h.eq((ok :: any).phaseDeg, 7)
		h.eq((ok :: any).ringDeg, 220.4)
		h.eq((R.configOf(fakeInst({ SailGateRpm = 4, SailGateRingDeg = 1 })) :: any).phaseDeg, 0)
		h.eq(R.configOf(fakeInst({})), nil)
		h.eq(R.configOf(fakeInst({ SailGateRpm = 0, SailGateRingDeg = 1 })), nil)
		h.eq(R.configOf(fakeInst({ SailGateRpm = "4", SailGateRingDeg = 1 })), nil)
		h.eq(R.configOf(fakeInst({ SailGateRpm = 4 })), nil)
		h.eq(R.configOf(fakeInst({ SailGateRpm = 0 / 0, SailGateRingDeg = 1 })), nil)
		h.ok(R.live(123, nil), "no config: live")
	end)

	h.test("the flag: with ENABLED false a gate ring is always live and fully lit", function()
		R.ENABLED = false
		h.ok(R.isOpen(0.3, cfg) and R.isOpen(1.9, cfg))
		h.eq(R.glow(0.3, cfg), 1)
		R.ENABLED = true
		h.ok(R.ENABLED)
	end)

	h.test("static wiring: players, bots and the sails read the same rules; closed rings are inert", function()
		local fc = h.readFile("src/client/FlightController.luau")
		h.contains(fc, "SailGateRules.configOf(trig)")
		h.contains(fc, "gateCfg ~= nil and not SailGateRules.live(workspace:GetServerTimeNow(), gateCfg)")
		local ai = h.readFile("src/server/AIRacers.luau")
		h.contains(ai, "SailGateRules.live(workspace:GetServerTimeNow(), F().boostGateAt[bs])")
		h.contains(ai, "F().boostGateAt[bs] == nil or", "the clock is read only for a gated ring")
		local anim = h.readFile("src/client/WorldAnim.luau")
		h.contains(anim, "SailGateRules.spinDeg(serverNow, s.rpm, s.phase)")
		h.contains(anim, "restPivot[d] or d:GetPivot()")
		local gp = h.readFile("src/server/kit/Gameplay.luau")
		h.contains(gp, "ring.sailGate)")
		h.contains(gp, "SailGateRules.ATTR_RING_DEG")
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "SailGateRules.liveWithin(workspace:GetServerTimeNow(), cfg, SailGateRules.SERVER_GRACE_S)")
		h.contains(rm, 'eventType == "RingTriggered" and sailGateRefuses(payload)', "the server re-checks a gate ring crossing")
		local fx = h.readFile("src/client/SailGateFx.luau")
		h.ok(not string.find(fx, "Instance.new(\"Part\"", 1, true) and not string.find(fx, "MeshPart", 1, true), "lights and particles only")
		h.ok(string.find(h.readFile("src/shared/BootRules.luau"), '{ name = "SailGateFx" }', 1, true) ~= nil)
	end)
end
