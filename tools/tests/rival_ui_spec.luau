-- Rival marker and sting rules (shared/RivalRules): the glyph marker text, when a sting plays (only on a real flip,
-- never for a missing side, rate limited), and which results row is the rival's. Plus a static check that nothing
-- draws the old red RIVAL pill any more.
return function(h)
	local R = h.require("src/shared/RivalRules.luau")

	h.test("marked: glyph, space, name", function()
		h.eq(R.marked("PIP"), R.GLYPH .. " PIP")
	end)

	h.test("sting: you overtake the rival -> passed; the rival overtakes you -> passedBy", function()
		h.eq(R.sting(true, false, 100, 0), "passed")
		h.eq(R.sting(false, true, 100, 0), "passedBy")
	end)

	h.test("sting: no flip, or an unknown side on either end, stays silent", function()
		h.eq(R.sting(true, true, 100, 0), nil)
		h.eq(R.sting(false, false, 100, 0), nil)
		h.eq(R.sting(nil, true, 100, 0), nil)
		h.eq(R.sting(true, nil, 100, 0), nil)
	end)

	h.test("sting: rate limited by STING_GAP", function()
		h.eq(R.sting(true, false, 100, 100 - R.STING_GAP + 0.1), nil)
		h.eq(R.sting(true, false, 100, 100 - R.STING_GAP - 0.1), "passed")
	end)

	local rows = {
		{ rank = 1, name = "Ana", isPlayer = true },
		{ rank = 2, name = "Pip", isPlayer = false },
		{ rank = 3, name = "Blaze", isPlayer = false },
	}

	h.test("rivalRow: finds the rival bot by name", function()
		h.eq(R.rivalRow(rows, "Blaze"), 3)
		h.eq(R.rivalRow(rows, "Pip"), 2)
	end)

	h.test("rivalRow: a missing rival, a card with no player row, or junk gives nil", function()
		h.eq(R.rivalRow(rows, "Nobody"), nil)
		h.eq(R.rivalRow({ { rank = 1, name = "Pip", isPlayer = false } }, "Pip"), nil)
		h.eq(R.rivalRow(nil, "Pip"), nil)
		h.eq(R.rivalRow({ "x" }, "Pip"), nil)
	end)

	h.test("rivalRow: a player who shares the rival's name is never the rival", function()
		h.eq(R.rivalRow({ { rank = 1, name = "Pip", isPlayer = true } }, "Pip"), nil)
	end)

	h.test("static: no red RIVAL pill or 'RIVAL - ' tab text left in the client", function()
		local src = h.readFile("src/client/RivalBubbles.luau")
		h.ok(not string.find(src, "RivalPill", 1, true))
		h.ok(not string.find(src, '"RIVAL - "', 1, true))
		h.ok(string.find(src, "RivalRules.marked", 1, true) ~= nil)
	end)
end
