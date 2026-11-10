--!strict
-- BootLog ring buffer: what is kept, dedupe, bounds, and the attribute tail.
return function(h)
	local BootLog = h.require("src/server/BootLog.luau")

	h.test("bootlog: keeps game lines, drops Store chatter and untagged noise, keeps problems", function()
		local r = BootLog.new()
		h.eq(r:push("[SkyRally][BOOT] phase=start t=0.00"), true)
		h.eq(r:push("[SkyRally][Store] round 2/10: 1 bound"), false)
		h.eq(r:push("some engine noise"), false)
		h.eq(r:push("Script error at line 3", true), true)
		h.eq(r:push("[30MAPS] DONE in 3s"), true)
		h.eq(#r.lines, 3)
	end)

	h.test("bootlog: consecutive duplicates collapse; ring is bounded", function()
		local r = BootLog.new()
		r:push("[SkyRally][AI] x")
		h.eq(r:push("[SkyRally][AI] x"), false)
		for i = 1, BootLog.MAX_LINES + 50 do
			r:push("[SkyRally][AI] line " .. i)
		end
		h.eq(#r.lines, BootLog.MAX_LINES)
		h.eq(r.lines[#r.lines], "[SkyRally][AI] line " .. (BootLog.MAX_LINES + 50))
	end)

	h.test("bootlog: attribute text is the newest lines within the cap", function()
		local r = BootLog.new()
		for i = 1, 290 do
			r:push("[SkyRally][MAP] " .. string.rep("x", 100) .. " " .. i)
		end
		local t = r:text()
		h.ok(#t <= BootLog.MAX_ATTR, "within cap")
		h.contains(t, " 290")
		h.ok(not string.find(t, " 1\n", 1, true), "oldest dropped")
	end)

	h.test("bootlog (V1 D2): boot evidence survives chatter in the key list, long timing lines kept whole", function()
		local r = BootLog.new()
		r:push("[SkyRally][BOOT] phase=start t=0.00")
		r:push("[SkyRally][DIRECTOR] load space4 (SPACE-4) mode=race ok=true errors=0 built in 4.2s")
		local steps = "[SkyRally][MAP] SPACE-4 steps build " .. string.rep("step=0.01 ", 40) .. "total=4.0"
		r:push(steps)
		r:push("[SkyRally][SELFTEST] PASS: TrackRegistry_Root")
		for i = 1, BootLog.MAX_LINES * 3 do
			r:push("[SkyRally][NAMES] pool dry " .. i)
			r:push("[SkyRally][ITEM] hit racer=" .. i)
		end
		h.ok(not string.find(r:text(), "[SkyRally][DIRECTOR]", 1, true), "the main ring did roll over")
		local key = r:keyText()
		h.contains(key, "[SkyRally][DIRECTOR] load space4 (SPACE-4) mode=race ok=true errors=0")
		h.contains(key, "[SkyRally][BOOT] phase=start")
		h.contains(key, "[SkyRally][SELFTEST] PASS")
		h.contains(key, "total=4.0", "the steps line is not cut at MAX_LINE")
		h.ok(not string.find(key, "[SkyRally][NAMES]", 1, true) and not string.find(key, "[SkyRally][ITEM]", 1, true), "no chatter")
		h.eq(#r.keyLines, 4)
	end)

	h.test("bootlog: a long key line that repeats only in its first MAX_LINE characters still reports a change", function()
		local r = BootLog.new()
		local head = "[SkyRally][MAP] SPACE-4 steps build " .. string.rep("w", BootLog.MAX_LINE)
		h.eq(r:push(head .. " total=4.0"), true)
		h.eq(r:push(head .. " total=5.0"), true, "key list grew, so BootLogKey must be republished")
		h.eq(#r.lines, 1)
		h.eq(#r.keyLines, 2)
		h.eq(r:push(head .. " total=5.0"), false, "a true duplicate is still dropped")
	end)
end
