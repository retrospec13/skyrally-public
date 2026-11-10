--!strict
-- Lune spec for the finish-banner circuit name (shared/TrackInfo.circuitName), which replaced the DINO-4 literal in
-- client/RaceUI. DINO-4 keeps its original text; other maps read their own track name.
-- Run: tools/tests/run_lune_tests.sh tools/tests/track_circuit_spec.luau
return function(h)
	local T = h.require("src/shared/TrackInfo.luau")

	h.test("circuitName: DINO-4 keeps VOLCANIC CIRCUIT", function()
		h.eq(T.circuitName("DINO-4"), "VOLCANIC CIRCUIT")
	end)

	h.test("circuitName: other maps use their upper-case track name", function()
		h.eq(T.circuitName("SNOW-1"), "FROZEN RIVER PEAK")
		h.eq(T.circuitName("SPACE-4"), "MONORAIL NEON GRID")
	end)

	h.test("circuitName: unknown or missing id is nil", function()
		h.eq(T.circuitName("NOPE-9"), nil)
		h.eq(T.circuitName(nil), nil)
	end)
end
