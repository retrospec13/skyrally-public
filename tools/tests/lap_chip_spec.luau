-- HUD lap chip (shared/LapChipRules, client/RaceUI). V9 Studio: in one session every race after the first read
-- "FINAL LAP!" from 0:05 with TotalLaps = 3 (island2 seq B, dino4 A/B). The chip's text must follow the lap in every race.
-- Run: tools/tests/run_lune_tests.sh tools/tests/lap_chip_spec.luau
return function(h)
	local R = h.require("src/shared/LapChipRules.luau")
	local FINAL = R.FINAL_TEXT

	-- The label as RaceUI writes it: only when step() says the text changed.
	local function hud()
		local s = R.new()
		local label = "LAP 1/3" -- RaceUI's build-time placeholder
		local events: { string } = {}
		local function frame(lap: number, now: number, mode: string?, finished: boolean?): string
			local text, changed, ev = R.step(s, lap, 3, now, mode or "race", finished)
			if changed then
				label = text
			end
			if ev then
				table.insert(events, ev)
			end
			return label
		end
		return frame, events, s
	end

	h.test("race 1: LAP 1/3, LAP 2/3, FINAL LAP! for 2.5 s, then LAP 3/3", function()
		local frame, events = hud()
		h.eq(frame(1, 0), R.lapText(1, 3))
		h.eq(frame(2, 40), R.lapText(2, 3), "lap 2 is written (the old cache compared the text with itself)")
		h.eq(frame(3, 80), FINAL)
		h.eq(frame(3, 82), FINAL)
		h.eq(frame(3, 82.6), R.lapText(3, 3), "the flash ends")
		h.eq(events, { "final" })
	end)

	h.test("race 2 in the same session starts at lap 1 (not FINAL LAP!)", function()
		local frame, events = hud()
		frame(1, 0)
		frame(2, 40)
		frame(3, 80)
		frame(3, 120, "race", true) -- finished, results card
		frame(1, 130, "hub") -- back in the hub
		h.eq(frame(1, 160), R.lapText(1, 3), "race 2 at 0:05")
		h.eq(frame(1, 165), R.lapText(1, 3))
		h.eq(frame(2, 200), R.lapText(2, 3))
		h.eq(frame(3, 240), FINAL, "race 2's own final lap still flashes")
		h.eq(events, { "final", "reset", "final" })
	end)

	h.test("FLY AGAIN straight from the card (lap 3 -> 1, no hub frame) resets too", function()
		local frame, events = hud()
		frame(1, 0)
		frame(2, 40)
		frame(3, 80)
		h.eq(frame(1, 125), R.lapText(1, 3))
		h.eq(events, { "final", "reset" })
	end)

	h.test("a race that ends inside the 2.5 s flash never carries FINAL LAP! into the next race", function()
		local frame = hud()
		frame(2, 0)
		h.eq(frame(3, 10), FINAL)
		h.eq(frame(1, 11), R.lapText(1, 3), "new race 1 s after the final-lap entry")
	end)

	h.test("no surge on a finished spectator, in the hub, or for a one-lap race", function()
		local frame, events = hud()
		frame(2, 0, "race", true)
		h.eq(frame(3, 1, "race", true), R.lapText(3, 3))
		frame(1, 2, "hub")
		h.eq(frame(3, 3, "hub"), R.lapText(3, 3))
		local s = R.new()
		local text = R.step(s, 1, 1, 0, "race", false)
		h.eq(text, R.lapText(1, 1))
		h.eq(#events, 0)
	end)

	h.test("text changes are reported once (the label is written only then)", function()
		local s = R.new()
		local _, c1 = R.step(s, 1, 3, 0, "race", false)
		local _, c2 = R.step(s, 1, 3, 0.1, "race", false)
		local _, c3 = R.step(s, 2, 3, 30, "race", false)
		h.eq({ c1, c2, c3 }, { true, false, true })
	end)
	h.test("v38 splits: green when faster, red when slower, nothing without a reference", function()
		h.eq({ R.split(61.2, 62.04) }, { "-0.84", true })
		h.eq({ R.split(63.2, 62.0) }, { "+1.20", false })
		h.eq({ R.split(60, nil) }, { nil, false })
		h.eq(R.splitRich(60, nil), "")
		h.ok(string.find(R.splitRich(61, 62), R.SPLIT_FASTER, 1, true) ~= nil, "faster is green")
		h.ok(string.find(R.splitRich(63, 62), R.SPLIT_SLOWER, 1, true) ~= nil, "slower is red")
	end)
end
