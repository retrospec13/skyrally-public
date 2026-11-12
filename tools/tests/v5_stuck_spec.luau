--!strict
-- Lune spec for V5-1 (VERIFY_RESULTS_V33.md): FOREST-1 coin run 2, a plane that RETURNed to the course was corrected
-- back to its last checkpoint and then corrected back to the same frame every ~1.3 s for ~1000 s (114+
-- "[PLANE] correction ... to=(-352.8,77.8,-5540.6)", Station stuck at 3999-4190). Two validator steps, both pure:
--   trigger: on arrival at a server teleport the budget restarted at VALIDATION_TOLERANCE only, so the replication
--            burst right after a RETURN landing (22.9 studs in 0.022 s) was a violation;
--   loop:    CarServer.correctPlane holds the hull on the checkpoint for ESCALATE_HOLD while the client (already sent
--            CheckpointRespawn) flies on from it; the hold's end re-armed expectTeleport(cf), the server's held copy
--            passed as "arrived" (budget = tolerance) and the client's first packet ~speed * 1.3 s ahead failed it.
-- R-1/R-3 (review of eafcfec): the hold-end re-arm is shared by cars and planes and skips when a newer server
-- teleport replaced the correction during the hold.
-- Run: tools/tests/run_lune_tests.sh tools/tests/v5_stuck_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local C = h.require("src/shared/CarConfig.luau")
	local G = h.require("src/shared/PlaneGuardRules.luau")

	local CP = { x = -352.8, y = 77.8, z = -5540.6 } -- the stuck run's checkpoint frame
	local SPEED = 166 -- FOREST-1 cruise with the throttle held (pilot jsonl spd)
	local HOLD = C.ESCALATE_HOLD

	-- One correction hold as the server runs it, with an honest client: it applies CheckpointRespawn at `t0` and flies
	-- on along +X at SPEED. The server's copy stays on the checkpoint through the hold, is sampled once at the hold's
	-- end (the held copy, before any client packet), then the client's packets arrive from `lag` s later every 1/20 s.
	-- rearm(v, t0, tEnd) is what the hold's end does. Returns the first non-ok verdict (or "ok") and its numbers.
	local function holdCycle(rearm: (any, number, number) -> (), lag: number, limits: any?): (string, number, number)
		local v = C.newValidator(limits or G.limits())
		local t0 = 100
		C.expectTeleport(v, CP.x, CP.y, CP.z, t0) -- correctPlane's own expectTeleport before the hold
		local tEnd = t0 + HOLD
		rearm(v, t0, tEnd)
		local verdict, dist, allowed = C.observe(v, CP.x, CP.y, CP.z, tEnd + 1 / 60) -- server's held copy
		if verdict ~= "ok" and verdict ~= "idle" then
			return verdict, dist, allowed
		end
		local t = tEnd + lag
		while t < tEnd + 4 do
			local x = CP.x + SPEED * (t - t0)
			verdict, dist, allowed = C.observe(v, x, CP.y, CP.z, t)
			if verdict ~= "ok" and verdict ~= "idle" then
				return verdict, dist, allowed
			end
			t += 1 / 20
		end
		return "ok", 0, 0
	end

	-- The plane limits as they were before V5-1 (no arrival credit): the old build's validator.
	local function oldLimits(): any
		local lim = G.limits()
		lim.arrivalSeconds = nil
		return lim
	end

	local function oldRearm(v: any, _t0: number, tEnd: number)
		C.expectTeleport(v, CP.x, CP.y, CP.z, tEnd)
	end
	local function newRearm(v: any, t0: number, _tEnd: number)
		C.expectFlightFrom(v, CP.x, CP.y, CP.z, t0)
	end

	h.test("repro: the old hold-end re-arm corrects an honest 166 studs/s plane again (the V5-1 loop)", function()
		local verdict, dist, allowed = holdCycle(oldRearm, 0.27, oldLimits())
		h.eq(verdict, "violation", "old path")
		-- The log's numbers: dist 165-182 against allowed 111-150.
		h.ok(dist > 160 and dist < 230, string.format("dist %.1f", dist))
		h.ok(allowed > 100 and allowed < 160, string.format("allowed %.1f", allowed))
	end)

	h.test("fix: after the hold an honest plane flying on from the checkpoint is accepted", function()
		for _, lag in { 0.05, 0.15, 0.27, 0.32, 0.6 } do
			local verdict, dist, allowed = holdCycle(newRearm, lag)
			h.eq(verdict, "ok", string.format("lag %.2f: dist %.1f allowed %.1f", lag, dist, allowed))
		end
	end)

	h.test("fix: ten correction cycles in a row no longer feed each other (progress resumes after one)", function()
		-- Old path: every cycle ends in another violation, so the plane never leaves the checkpoint's stretch.
		local oldViolations, newViolations = 0, 0
		for _ = 1, 10 do
			if (holdCycle(oldRearm, 0.27, oldLimits())) == "violation" then
				oldViolations += 1
			end
			if (holdCycle(newRearm, 0.27)) == "violation" then
				newViolations += 1
			end
		end
		h.eq(oldViolations, 10, "old: stuck")
		h.eq(newViolations, 0, "new: free after the hold")
	end)

	h.test("the arrival credit alone would not end the loop at overcharge speed: the hold-end re-arm is the fix", function()
		local saved = SPEED
		SPEED = 224
		local oldVerdict = holdCycle(oldRearm, 0.27)
		local newVerdict = holdCycle(newRearm, 0.27)
		SPEED = saved
		h.eq(oldVerdict, "violation", "old re-arm with the arrival credit, 224 studs/s")
		h.eq(newVerdict, "ok", "new re-arm, 224 studs/s")
	end)

	h.test("fix keeps the guard: a client that ignored the respawn is still corrected at the hold's end", function()
		local v = C.newValidator(G.limits())
		local t0 = 100
		C.expectFlightFrom(v, CP.x, CP.y, CP.z, t0)
		-- Still at the far spot it teleported to (2000 studs on), 1.3 s later.
		local verdict = C.observe(v, CP.x + 2000, CP.y, CP.z, t0 + HOLD + 0.3)
		h.eq(verdict, "violation")
		h.ok(math.abs(v.x - CP.x) < 1e-6, "correction target stays the checkpoint")
	end)

	h.test("fix keeps the guard: travel from the held frame is capped at one second of slacked flight", function()
		local v = C.newValidator(G.limits())
		C.expectFlightFrom(v, 0, 100, 0, 0)
		local capH = C.budgetCaps(G.limits())
		h.eq((C.observe(v, capH + 5, 100, 0, 30)), "violation", "a long hold earns no more than the cap")
	end)

	h.test("trigger: the burst right after a RETURN landing is accepted for a plane", function()
		local v = C.newValidator(G.limits())
		C.observe(v, 0, 76, 0, 0)
		C.expectTeleport(v, 500, 76, 0, 1)
		h.eq((C.observe(v, 500, 76, 0, 1.2)), "ok", "arrived")
		-- The log: dist=22.9 allowed=17.8 dt=0.022 straight after "[GUIDE] return ... to=4215".
		h.eq((C.observe(v, 522.9, 76, 0, 1.222)), "ok", "22.9 studs in 0.022 s")
	end)

	h.test("trigger fix stays bounded: a big jump right after arrival is still a violation", function()
		local v = C.newValidator(G.limits())
		C.observe(v, 0, 76, 0, 0)
		C.expectTeleport(v, 500, 76, 0, 1)
		C.observe(v, 500, 76, 0, 1.2)
		local lim = G.limits()
		local arrival = C.VALIDATION_TOLERANCE + lim.maxH * lim.slack * G.ARRIVAL_SECONDS
		h.ok(arrival < 120, "arrival credit " .. arrival)
		h.eq((C.observe(v, 500 + 300, 76, 0, 1.21)), "violation", "300 studs in 10 ms")
	end)

	h.test("cars are unchanged: no arrival credit without plane limits", function()
		local v = C.newValidator()
		C.observe(v, 0, 20, 0, 0)
		C.expectTeleport(v, 500, 20, 0, 1)
		h.eq((C.observe(v, 500, 20, 0, 1.2)), "ok")
		h.eq((C.observe(v, 522.9, 20, 0, 1.222)), "violation", "car arrival budget is the tolerance, as before")
	end)
	-- R-1: a newer server teleport during the hold (spawnOrResetPlane reusing the hull -> expectTeleport(startCF))
	-- must win over the stale correction frame. Re-arming on cf anyway judges the honest plane at startCF (far from
	-- cf) against one capped budget from cf and corrects it at race start; keeping the newer expectation accepts it.
	h.test("R-1: a stale hold-end re-arm overriding a newer teleport corrects an honest plane; the guarded path does not", function()
		local START = { x = CP.x + 900, y = CP.y, z = CP.z } -- the race start grid, hundreds of studs from cf
		local function run(staleRearm: boolean): string
			local v = C.newValidator(G.limits())
			local t0 = 100
			C.expectTeleport(v, CP.x, CP.y, CP.z, t0) -- the correction
			C.expectTeleport(v, START.x, START.y, START.z, t0 + 0.4) -- reset to the grid during the hold
			if staleRearm then
				C.expectFlightFrom(v, CP.x, CP.y, CP.z, t0)
			end
			return (C.observe(v, START.x, START.y, START.z, t0 + HOLD + 0.1))
		end
		h.eq(run(true), "violation", "unguarded: corrected at the grid")
		h.eq(run(false), "ok", "guarded: arrives at the grid")
	end)

	h.test("R-1: CarServer bumps a teleport generation and the shared hold end skips a superseded re-arm", function()
		local src = h.readFile("src/server/CarServer.luau")
		local exp = string.match(src, "function CarServer%.expectTeleport%(.-\nend")
		h.ok(exp ~= nil and string.find(exp, "st.teleportGen += 1", 1, true) ~= nil, "expectTeleport bumps the generation")
		local helper = string.match(src, "local function rearmAfterHold%(.-\nend")
		h.ok(helper ~= nil, "shared hold-end helper exists")
		h.ok(string.find(helper :: string, "CarServer.states[player] ~= st or st.teleportGen ~= gen", 1, true) ~= nil, "guard")
		h.ok(string.find(helper :: string, "CarConfig.expectFlightFrom", 1, true) ~= nil, "flight-from re-arm")
		local _, uses = string.gsub(src, "rearmAfterHold%(player, st, gen,", "")
		h.eq(uses, 2, "used by correct() and correctPlane()")
	end)

	-- R-3: the car's escalate hold now ends the same way. The server holds the (unanchored) car on the valid frame;
	-- the client drives off from wherever it gets the hull back. Honest driving at top speed is accepted.
	h.test("R-3: after a car hold an honest car driving off the held frame at full boost is accepted", function()
		local v = C.newValidator()
		local t0 = 100
		C.expectTeleport(v, CP.x, 20, CP.z, t0)
		C.expectFlightFrom(v, CP.x, 20, CP.z, t0)
		local speed = C.maxHorizontalSpeed()
		local tEnd = t0 + HOLD
		h.eq((C.observe(v, CP.x + 12, 20, CP.z, tEnd + 1 / 60)), "ok", "server copy drifted 12 studs during the hold")
		local t = tEnd + 0.1
		while t < tEnd + 3 do
			local verdict = C.observe(v, CP.x + 12 + speed * (t - tEnd - 0.05), 20, CP.z, t)
			h.ok(verdict == "ok" or verdict == "idle", string.format("t+%.2f %s", t - tEnd, verdict))
			t += 1 / 20
		end
	end)

	h.test("R-3: a car that ignored the corrections is still corrected after the hold", function()
		local v = C.newValidator()
		C.expectFlightFrom(v, CP.x, 20, CP.z, 100)
		h.eq((C.observe(v, CP.x + 1500, 20, CP.z, 100 + HOLD + 0.2)), "violation")
	end)
end
