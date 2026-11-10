--!strict
-- Error and memory telemetry rules (audit T1-4): scrub, fingerprint, de-dupe, budget, client cleaning, memory summary.
return function(h)
	local R = h.require("src/shared/ErrorReporterRules.luau")

	h.test("errors: scrub keeps one line, drops player names and long ids, caps length", function()
		local s = R.scrub("Players.Bobby.PlayerGui.X:12: attempt to index nil (user 123456789)\nstack", { "Bob", "Bobby" })
		h.eq(s, "Players.<player>.PlayerGui.X:12: attempt to index nil (user #)")
		h.eq(#R.scrub(string.rep("a", 900)), R.MAX_MSG)
		h.eq(R.scrub("a\tb\0c"), "a b c")
		-- Two-letter names are not scrubbed (they would eat ordinary words).
		h.eq(R.scrub("ok go", { "ok" }), "ok go")
	end)

	h.test("errors: source name and fingerprint fold digits", function()
		h.eq(R.sourceName("Players.x.PlayerScripts.Client.CarController"), "CarController")
		h.eq(R.sourceName(nil), "unknown")
		h.eq(R.sourceName("A.b-c d"), "bcd")
		local a = R.fingerprint("CarController", "index 3 nil")
		h.eq(a, R.fingerprint("CarController", "index 47 nil"))
		h.ok(a ~= R.fingerprint("RaceUI", "index 3 nil"))
		h.ok(string.match(a, "^%x%x%x%x%x%x%x%x$") ~= nil)
	end)

	h.test("errors: build label", function()
		h.eq(R.buildLabel("abc1234def", 29), "v29-abc1234")
		h.eq(R.buildLabel("dev", 0), "v0-dev")
		h.eq(R.buildLabel(nil, nil), "v0-dev")
	end)

	h.test("errors: first sighting reports, repeats count and flush as one report", function()
		local t = 0
		local tr = R.newTracker({ now = function()
			return t
		end })
		local r = tr.note("error", "CarController", "index 1 nil")
		h.eq(r and r.count, 1)
		h.eq(tr.note("error", "CarController", "index 2 nil"), nil)
		h.eq(tr.note("error", "CarController", "index 3 nil"), nil)
		local f = tr.flush()
		h.eq(#f, 1)
		h.eq(f[1].count, 2)
		h.eq(#tr.flush(), 0, "nothing pending after a flush")
		h.eq(tr.stats().seen, 3)
	end)

	h.test("errors: budget per window and a session cap bound the reports", function()
		local t = 0
		local tr = R.newTracker({ now = function()
			return t
		end, budget = 3, window = 60, sessionCap = 5 })
		local sent = 0
		for i = 1, 6 do
			if tr.note("error", "S" .. i, "distinct " .. i) then
				sent += 1
			end
		end
		h.eq(sent, 3)
		h.eq(tr.stats().dropped, 3)
		t = 61
		local f = tr.flush()
		h.eq(#f, 2, "next window: the session cap leaves two")
		h.eq(tr.stats().sent, 5)
		t = 200
		h.eq(#tr.flush(), 0, "session cap holds")
		h.eq(tr.note("error", "New", "new one"), nil)
	end)

	h.test("errors: unknown kinds become error", function()
		local tr = R.newTracker({ now = function()
			return 0
		end })
		local r = tr.note("weird", "X", "m")
		h.eq(r and r.kind, "error")
		h.eq((tr.note("boot_core", "CarController", "m") :: any).kind, "boot_core")
	end)

	h.test("errors: cleanClient accepts a good report and rejects bad fields", function()
		local good = R.cleanClient("boot", "AdminPanel", "0a1b2c3d", 2, "Players.Alice.x failed", { "Alice" })
		h.eq(good and good.msg, "Players.<player>.x failed")
		h.eq(R.cleanClient("hack", "AdminPanel", "0a1b2c3d", 1, "m"), nil)
		h.eq(R.cleanClient("error", "Admin Panel", "0a1b2c3d", 1, "m"), nil)
		h.eq(R.cleanClient("error", string.rep("a", 41), "0a1b2c3d", 1, "m"), nil)
		h.eq(R.cleanClient("error", "A", "zz", 1, "m"), nil)
		h.eq(R.cleanClient("error", "A", "0a1b2c3d", 0, "m"), nil)
		h.eq(R.cleanClient("error", "A", "0a1b2c3d", 1.5, "m"), nil)
		h.eq(R.cleanClient("error", "A", "0a1b2c3d", 0 / 0, "m"), nil)
		h.eq(R.cleanClient("error", "A", "0a1b2c3d", 1, string.rep("m", 1000)), nil)
		h.eq(R.cleanClient("error", "A", "0a1b2c3d", 1, {}), nil)
	end)

	h.test("errors: the log line carries origin, build, kind, source, fingerprint and count", function()
		local line = R.line("client", "v29-abc1234", { kind = "boot", source = "AdminPanel", fp = "0a1b2c3d", count = 3, msg = "x" })
		h.eq(line, "[SkyRally][ERR] client v29-abc1234 boot AdminPanel 0a1b2c3d x3: x")
	end)

	h.test("memory: peak and p95 in whole MB; bad samples ignored; ring bounded", function()
		local m = R.newMem()
		h.eq(R.memSummary(m), nil)
		for i = 1, 100 do
			R.addMem(m, 1000 + i)
		end
		R.addMem(m, 0 / 0)
		R.addMem(m, -5)
		R.addMem(m, "x")
		local peak, p95 = R.memSummary(m)
		h.eq(peak, 1100)
		h.eq(p95, 1095)
		for _ = 1, R.MEM_MAX_SAMPLES + 10 do
			R.addMem(m, 500)
		end
		h.eq(#m.samples, R.MEM_MAX_SAMPLES)
		R.clearMem(m)
		h.eq(#m.samples, 0)
	end)

	h.test("memory: cleanMem", function()
		local a, b = R.cleanMem(1500.4, 1400.6)
		h.eq(a, 1500)
		h.eq(b, 1401)
		h.eq(R.cleanMem(100, 200), nil, "p95 above peak")
		h.eq(R.cleanMem(0, 0), nil)
		h.eq(R.cleanMem(99999, 1), nil)
		h.eq(R.cleanMem("1", 1), nil)
	end)
	h.test("errors: relay budget passes a first sighting and its repeat flush (no fingerprint folding)", function()
		local t = 0
		local b = R.newBudget({ now = function()
			return t
		end, budget = 3, sessionCap = 4 })
		local first = R.cleanClient("error", "CarController", "1a2b3c4d", 1, "index nil")
		local flush = R.cleanClient("error", "CarController", "1a2b3c4d", 7, "index nil")
		h.ok(first ~= nil and flush ~= nil)
		h.ok(b.take(), "first sighting")
		h.ok(b.take(), "repeat flush of the same fingerprint")
		h.ok(b.take())
		h.ok(not b.take(), "window budget")
		t += R.WINDOW
		h.ok(b.take())
		h.ok(not b.take(), "session cap")
		h.eq(b.sent(), 4)
	end)
end
