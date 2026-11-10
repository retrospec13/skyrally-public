--!strict
-- Lune spec for src/shared/MusicRules.luau (REMARKABLE Batch 1 items 1, 2, 3 and 9): the boss chase theme and roar
-- with their fallbacks, the finish jingle per place (including the comic last place), the final-lap surge gate (lap
-- race modes only, never for a finished spectator, once on the step into the last lap), tempo rules, stacked ducks,
-- and the secret cue per find kind. client/Music uses exactly these functions; the cue names must exist in
-- shared/AudioAssets (checked here too, so a renamed upload cannot silently mute a moment).
-- Run: tools/tests/run_lune_tests.sh tools/tests/music_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local R = h.require("src/shared/MusicRules.luau")
	local Assets = h.require("src/shared/AudioAssets.luau")
	local Boss = h.require("src/shared/BossConfig.luau")

	local function hasAll(cue: string): boolean
		return Assets[cue] ~= nil
	end

	h.test("boss theme candidates: own zone, shared fallback, first boss theme, then the zone theme", function()
		local c = R.bossThemeCandidates("SNOW")
		h.eq(c[1], "music_boss_snow")
		h.eq(c[2], "music_boss")
		h.eq(c[3], "music_boss_dino")
		h.eq(c[4], "music_snow")
		h.eq(#R.bossThemeCandidates(nil), 2, "no zone: only the shared fallbacks")
	end)

	h.test("pick: first cue with an id; zone theme when no boss theme exists; nil when nothing can play", function()
		h.eq(R.pick(R.bossThemeCandidates("ISLAND"), hasAll), "music_boss_island")
		local onlyZone = function(cue: string): boolean
			return cue == "music_forest"
		end
		h.eq(R.pick(R.bossThemeCandidates("FOREST"), onlyZone), "music_forest")
		local onlyDino = function(cue: string): boolean
			return cue == "music_boss_dino"
		end
		h.eq(R.pick(R.bossThemeCandidates("SPACE"), onlyDino), "music_boss_dino", "a zone with no chase theme borrows DINO's")
		h.eq(R.pick(R.bossThemeCandidates("HUB"), function()
			return false
		end), nil)
	end)

	h.test("every launch boss has an uploaded chase theme and roar keyed off its clips name", function()
		for zone, b in Boss.BY_ZONE do
			local theme = R.pick(R.bossThemeCandidates(zone), hasAll)
			h.eq(theme, "music_boss_" .. string.lower(zone), zone .. " chase theme")
			local roar = R.roarCue(b.clips)
			h.ok(roar ~= nil and Assets[roar] ~= nil, zone .. " roar " .. tostring(roar))
		end
		h.eq(R.roarCue("Cinderwing"), "roar_cinderwing")
		h.eq(R.roarCue(nil), nil)
		h.eq(R.roarCue(""), nil)
	end)

	h.test("finish jingle per place: 1, 2, 5 and 8 of 8", function()
		h.eq(R.finishCue(1, 8, "race"), "jingle_victory")
		h.eq(R.finishCue(2, 8, "race"), "jingle_place2")
		h.eq(R.finishCue(3, 8, "race"), "jingle_place3")
		h.eq(R.finishCue(5, 8, "race"), "jingle_midpack")
		h.eq(R.finishCue(8, 8, "race"), "jingle_last")
	end)

	h.test("last place needs a field of four: a 1v1 boss loss is a runner-up, 3 of 3 is bronze", function()
		h.eq(R.finishCue(2, 2, "boss"), "jingle_place2")
		h.eq(R.finishCue(3, 3, "race"), "jingle_place3")
		h.eq(R.finishCue(4, 4, "quickrace"), "jingle_last")
		h.eq(R.finishCue(4, 5, "race"), "jingle_midpack")
		h.ok(R.isLastPlace(8, 8))
		h.ok(R.isLastPlace(4, 4))
		h.ok(not R.isLastPlace(3, 3))
		h.ok(not R.isLastPlace(2, 2))
		h.ok(not R.isLastPlace(5, 8))
		h.ok(not R.isLastPlace(nil, 8))
	end)

	h.test("no finish jingle in battle or the hub, or for a nonsense rank", function()
		h.eq(R.finishCue(1, 6, "battle"), nil)
		h.eq(R.finishCue(1, 6, "hub"), nil)
		h.eq(R.finishCue(0, 6, "race"), nil)
		h.eq(R.finishCue(nil, 6, "race"), nil)
		h.eq(R.finishCue(1, 1, "timetrial"), "jingle_victory")
		h.eq(R.finishCue(2, nil, "stormcup"), "jingle_place2")
	end)

	h.test("every finish, sting and secret cue is uploaded", function()
		for _, cue in { "jingle_victory", "jingle_place2", "jingle_place3", "jingle_midpack", "jingle_last", "jingle_finallap",
			"chip_secret", "chip_find", "jingle_countdown" } do
			h.ok(Assets[cue] ~= nil, cue)
		end
	end)

	h.test("final lap: fires on the step into the last lap of a lap race", function()
		h.ok(R.isFinalLapEntry(2, 3, 3, "race", false))
		h.ok(R.isFinalLapEntry(2, 3, 3, "boss", nil))
		h.ok(R.isFinalLapEntry(2, 3, 3, "rematch", false))
		h.ok(R.isFinalLapEntry(nil, 3, 3, "coin", false), "first Lap value seen is the last lap")
		h.ok(R.isFinalLapEntry(4, 5, 5, "race", false), "per-track TotalLaps")
		h.ok(not R.isFinalLapEntry(1, 2, 3, "race", false), "lap 2 of 3")
		h.ok(not R.isFinalLapEntry(3, 1, 3, "race", false), "race reset")
		h.ok(not R.isFinalLapEntry(3, 3, 3, "race", false), "no step")
	end)

	h.test("final lap: never in battle or the hub, a one-lap race, or for a finished spectator", function()
		h.ok(not R.isFinalLapEntry(2, 3, 3, "battle", false))
		h.ok(not R.isFinalLapEntry(2, 3, 3, "hub", false))
		h.ok(not R.isFinalLapEntry(0, 1, 1, "race", false))
		h.ok(not R.isFinalLapEntry(2, 3, 3, "race", true))
		h.ok(not R.isFinalLapEntry(2, nil, 3, "race", false))
	end)

	h.test("total laps: the TotalLaps attribute when sane, else the default", function()
		h.eq(R.totalLaps(5, 3), 5)
		h.eq(R.totalLaps(nil, 3), 3)
		h.eq(R.totalLaps(0, 3), 3)
		h.eq(R.totalLaps("3", 3), 3)
	end)

	h.test("tempo: rematch 4 % up, final lap 6 % (8 % for bosses), capped", function()
		h.eq(R.themeSpeed("race"), 1)
		h.eq(R.themeSpeed("boss"), 1)
		h.eq(R.themeSpeed("rematch"), 1.04)
		h.ok(math.abs(R.finalLapSpeed(1, "race") - 1.06) < 1e-9)
		h.ok(math.abs(R.finalLapSpeed(1, "boss") - 1.08) < 1e-9)
		local rematch = R.finalLapSpeed(R.themeSpeed("rematch"), "rematch")
		h.ok(rematch > 1.08 and rematch <= R.SPEED_CAP, "rematch surge stays under the cap: " .. tostring(rematch))
	end)

	h.test("ducks stack: the quietest reason wins, none is full volume", function()
		h.eq(R.duckFactor({}), 1)
		h.eq(R.duckFactor({ curtain = 0.12 }), 0.12)
		h.eq(R.duckFactor({ curtain = 0.12, roar = 0 }), 0)
		h.eq(R.duckFactor({ finish = 0.12, sting = 0.5 }), 0.12)
	end)

	h.test("secret cue: the key gets the full fanfare, a hub find the short one", function()
		h.eq(R.secretCue("key"), "chip_secret")
		h.eq(R.secretCue("find"), "chip_find")
		h.eq(R.secretCue(nil), "chip_find")
	end)

	h.test("zone themes: one per zone, nil for an unknown zone", function()
		for zone, cue in R.THEME_BY_ZONE do
			h.eq(R.zoneTheme(zone), cue)
			h.ok(Assets[cue] ~= nil, cue)
		end
		h.eq(R.zoneTheme("MOON"), nil)
		h.eq(R.zoneTheme(nil), nil)
		h.ok(R.isBossMode("boss") and R.isBossMode("rematch") and not R.isBossMode("race"))
	end)
end
