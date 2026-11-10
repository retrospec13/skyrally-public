--!strict
-- Lune spec for src/shared/SoundscapeRules.luau (REMARKABLE Batch 2 items 12, 26 and 29): the zone ambience beds and
-- the lava-rumble stopgap, the Storm Cup and battle theme choice, the last-10-seconds clock and its air horn, the
-- local engine's two-band crossfade, rival engine voices, Doppler, fly-bys, nearest-voice picking, the lift-off
-- backfire and the speed wind. client/Soundscape, client/SoundJuice and client/Music use exactly these functions; every
-- cue they name must have a prepared file in assets/audio/soundscape_v1/upload or an exact EXCLUDED_FILES.json
-- source-release entry. Unknown missing cues still fail; omission does not certify recording distribution rights.
-- Run: tools/tests/run_lune_tests.sh tools/tests/soundscape_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/SoundscapeRules.luau")
	local MusicRules = h.require("src/shared/MusicRules.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	local function prepared(cue: string): boolean
		local path = "assets/audio/soundscape_v1/upload/" .. cue .. ".ogg"
		local ok = pcall(h.readFile, path)
		if ok then return true end
		-- Public source packages deliberately omit separately ungranted recordings.
		-- Require the exact named exclusion, never silently skip a missing cue.
		local hasManifest, manifest = pcall(h.readFile, "EXCLUDED_FILES.json")
		return hasManifest and string.find(manifest, '"path": "' .. path .. '"', 1, true) ~= nil
	end

	---------------------------------------------------------------------------------------------------- 12. ambience

	h.test("ambience: one amb_<zone> bed for each launch zone, nothing for an unknown zone", function()
		for zone in R.AMB_ZONES do
			local cue = R.ambienceCue(zone)
			h.eq(cue, "amb_" .. string.lower(zone))
			h.ok(R.ambienceVolume(zone) > 0 and R.ambienceVolume(zone) <= 0.6, zone .. " bed sits under the music")
		end
		h.eq(R.ambienceCue("MOON"), nil)
		h.eq(R.ambienceCue(nil), nil)
	end)

	h.test("lava stopgap: the old engine-sample rumble is silent on SNOW, SPACE and every non-DINO map", function()
		for _, zone in { "SNOW", "SPACE", "ISLAND", "FOREST", "HUB", nil } do
			h.eq(R.legacyLavaVolume(zone, false, 0.28), 0, tostring(zone))
		end
		h.eq(R.legacyLavaVolume("DINO", false, 0.2), 0.2, "DINO keeps it until its real bed exists")
		h.eq(R.legacyLavaVolume("DINO", true, 0.2), 0, "the real DINO bed replaces it")
	end)

	h.test("DINO bed swells toward the lava: 0.7 high up, 1.3 at the lava floor", function()
		h.ok(near(R.dinoBedGain(R.lavaProximity(500)), 0.7))
		h.ok(near(R.dinoBedGain(R.lavaProximity(R.LAVA_FLOOR_Y)), 1.3))
		h.ok(R.lavaProximity(60) > R.lavaProximity(100), "closer is louder")
	end)

	h.test("Storm Cup rain layer only while a cup runs", function()
		h.eq(R.stormLayer("stormcup"), true)
		h.eq(R.stormLayer("race"), false)
		h.eq(R.stormLayer("hub"), false)
	end)

	------------------------------------------------------------------------------------------- 26. themes and clock

	h.test("themes: Storm Cup theme in a cup, the battle kind's theme in a running battle, zone theme otherwise", function()
		h.eq(R.themeCandidates("music_dino", "stormcup", nil, nil), { "music_stormcup", "music_dino" })
		h.eq(R.themeCandidates("music_snow", "battle", "survival", "running"), { "music_battle_survival", "music_snow" })
		h.eq(R.themeCandidates("music_island", "battle", "water", "countdown"), { "music_battle_water", "music_island" })
		h.eq(R.themeCandidates("music_island", "battle", "water", "over"), { "music_island" }, "results: the map's own theme")
		h.eq(R.themeCandidates("music_forest", "battle", "joust", "running"), { "music_forest" }, "unknown kind falls back")
		h.eq(R.themeCandidates("music_hub", "hub", nil, nil), { "music_hub" })
		h.eq(R.themeCandidates(nil, "race", nil, nil), {})
	end)

	h.test("themes: MusicRules.pick falls back to the zone theme while the new themes have no ids", function()
		local none = function(cue: string): boolean
			return cue == "music_dino"
		end
		h.eq(MusicRules.pick(R.themeCandidates("music_dino", "battle", "egg", "running"), none), "music_dino")
		local all = function(_cue: string): boolean
			return true
		end
		h.eq(MusicRules.pick(R.themeCandidates("music_dino", "battle", "egg", "running"), all), "music_battle_egg")
	end)

	h.test("clock cues: tick and tock alternate from 10, the last three are the hard tick", function()
		h.eq(R.clockCue(11), nil)
		h.eq(R.clockCue(10), "clock_tick")
		h.eq(R.clockCue(9), "clock_tock")
		h.eq(R.clockCue(4), "clock_tick")
		h.eq(R.clockCue(3), "clock_last")
		h.eq(R.clockCue(1), "clock_last")
		h.eq(R.clockCue(0), nil)
	end)

	h.test("clock events: one tick per shown second from 10 down to 1, then exactly one horn", function()
		local events: { string } = {}
		local prev: number? = nil
		local left = 12.5
		while left > -1 do
			local ev, s = R.clockEvent(prev, left)
			if ev == "tick" then
				table.insert(events, tostring(s))
			elseif ev == "horn" then
				table.insert(events, "horn")
			end
			prev = left
			left -= 1 / 60
		end
		h.eq(events, { "10", "9", "8", "7", "6", "5", "4", "3", "2", "1", "horn" })
	end)

	h.test("clock events: first look never fires; a frame hitch that skips seconds ticks once, not a burst", function()
		h.eq((R.clockEvent(nil, 4.5)), nil, "joining at 4.5 s left is silent until the next second")
		local ev, s = R.clockEvent(7.9, 4.2)
		h.eq(ev, "tick")
		h.eq(s, 5)
		h.eq((R.clockEvent(0.4, -3)), "horn")
		h.eq((R.clockEvent(-0.2, -0.3)), nil, "after the horn nothing more")
		h.eq((R.clockEvent(30.2, 29.9)), nil, "no tick above ten")
	end)

	h.test("clock active window: (0, 10]", function()
		h.eq(R.clockActive(nil), false)
		h.eq(R.clockActive(10.5), false)
		h.eq(R.clockActive(10), true)
		h.eq(R.clockActive(0.01), true)
		h.eq(R.clockActive(0), false)
		h.ok(R.CLOCK_TEMPO <= MusicRules.SPEED_CAP, "the clock push stays musical")
	end)

	------------------------------------------------------------------------------------------ 29. engines and fly-bys

	h.test("engine bands: low band alone at idle, high band alone at full revs, equal power across", function()
		for _, vehicle in { "car", "plane" } do
			local lo, hi, ls, hs = R.engineBands(0.75, vehicle, 0)
			h.ok(near(lo, 1) and near(hi, 0), vehicle .. " idle is the low band")
			h.ok(near(ls, 0.75 / R.LOW_REF), "low band speed")
			h.ok(hs < ls, "the high band was rendered at higher revs, so it plays slower")
			lo, hi = R.engineBands(1.65, vehicle, 0)
			h.ok(near(lo, 0, 1e-9) and near(hi, 1), vehicle .. " full revs is the high band")
			for p = 0.75, 1.65, 0.05 do
				local a, b = R.engineBands(p, vehicle, 0)
				h.ok(near(a * a + b * b, 1, 1e-6), "equal power at " .. p)
			end
		end
	end)

	h.test("engine bands: both bands land on the same revs at the crossover; load brings the snarl in early", function()
		local _, _, ls, hs = R.engineBands(1.15, "car", 0)
		-- low band rendered at 2400 rpm, high at 4200: the revs each band plays must agree.
		h.ok(near(ls * 2400, hs * 4200, 1), "car bands agree on revs")
		local _, hiIdle = R.engineBands(1.0, "car", 0)
		local _, hiLoad = R.engineBands(1.0, "car", 1)
		h.ok(hiLoad > hiIdle, "a boost brings the high band in")
	end)

	h.test("voices: stable per id, cars get the three car voices, planes the prop, pitches spread", function()
		local seen: { [string]: boolean } = {}
		for id = 1, 9 do
			local v = R.voiceFor(id, "car")
			seen[v.cue] = true
			h.eq(R.voiceFor(id, "car").pitch, v.pitch, "same id, same voice")
			h.ok(v.pitch > 0.4 and v.pitch < 1.4, "sane pitch")
		end
		h.eq(seen, { eng_voice_putt = true, eng_voice_twin = true, eng_voice_turbo = true })
		h.eq(R.voiceFor(3, "plane").cue, "eng_voice_prop")
		h.ok(R.voiceFor(1, "plane").pitch ~= R.voiceFor(2, "plane").pitch, "two planes do not phase into one")
		h.eq(R.voiceFor(-5, "car").cue, R.voiceFor(5, "car").cue, "negative ids are fine")
	end)

	h.test("doppler: higher while it comes at you, lower as it goes, 1 when nothing moves, clamped", function()
		-- Source 50 studs down the x axis coming at the listener at 150 studs/s.
		local up = R.doppler(-50, 0, 0, 150, 0, 0, 0, 0, 0, 0, 0, 0)
		local down = R.doppler(50, 0, 0, 150, 0, 0, 0, 0, 0, 0, 0, 0)
		h.ok(up > 1.2 and up < 1.35, "approach ~+30 %: " .. up)
		h.ok(down < 0.85 and down > 0.75, "recede ~-19 %: " .. down)
		h.ok(near(R.doppler(10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), 1), "still")
		h.ok(near(R.doppler(0, 50, 0, 150, 0, 0, 0, 0, 0, 0, 0, 0), 1, 1e-9), "crossing at right angles: no shift")
		h.eq(R.doppler(-50, 0, 0, 5000, 0, 0, 0, 0, 0, 0, 0, 0), R.DOPPLER_MAX, "a teleport is clamped")
		h.ok(R.doppler(-50, 0, 0, 0, 0, 0, 0, 0, 0, -150, 0, 0) > 1, "driving toward a parked rival also rises")
	end)

	h.test("fly-by: closing then opening, close and fast; not far, not slow, not while still closing", function()
		h.eq(R.isFlyby(40, -40, 12, 120), true)
		h.eq(R.isFlyby(40, -40, 80, 120), false, "too far")
		h.eq(R.isFlyby(10, -10, 12, 20), false, "too slow")
		h.eq(R.isFlyby(40, 30, 12, 120), false, "still closing")
		h.eq(R.isFlyby(-5, -40, 12, 120), false, "was already opening")
	end)

	h.test("voice picking: the three nearest inside range; a held voice is sticky; far racers get none", function()
		local d = { a = 50, b = 20, c = 100, d = 400, e = 30 }
		local pick = R.pickVoices(d, {})
		h.eq(pick, { "b", "e", "a" })
		-- c holds a voice; a newcomer at 90 (only 10 % closer) does not steal it ...
		local held = R.pickVoices({ a = 20, b = 30, c = 100, x = 90 }, { "a", "b", "c" })
		table.sort(held)
		h.eq(held, { "a", "b", "c" })
		-- ... but one at 40 (much closer) does.
		local stolen = R.pickVoices({ a = 20, b = 30, c = 100, x = 40 }, { "a", "b", "c" })
		table.sort(stolen)
		h.eq(stolen, { "a", "b", "x" })
		h.eq(R.pickVoices({ far = R.MAX_DIST + 1 }, { "far" }), {}, "out of range loses its voice")
		h.eq(#R.pickVoices({}, {}), 0)
		h.ok(R.MAX_VOICES <= 3, "at most three extra 3D loops (REMARKABLE item 29)")
	end)

	h.test("backfire: a lift, a brake or a boost running out pops (sometimes); a wall, a boost, low revs or a recent pop never do", function()
		h.eq(R.backfire(150, 26, "None", 5, 0.1), true, "coasting lift from speed")
		h.eq(R.backfire(150, 150, "None", 5, 0.1), true, "full brake")
		h.eq(R.backfire(150, 42, "None", 5, 0.1), true, "a boost running out")
		h.eq(R.backfire(150, 100, "None", 5, 0.9), false, "the dice said no")
		h.eq(R.backfire(150, 9000, "None", 5, 0.1), false, "a crash is not a backfire")
		h.eq(R.backfire(150, 10, "None", 5, 0.1), false, "a gentle slope")
		h.eq(R.backfire(150, 100, "Standard", 5, 0.1), false, "boosting")
		h.eq(R.backfire(90, 100, "None", 5, 0.1), false, "low revs")
		h.eq(R.backfire(150, 100, "None", 1, 0.1), false, "cooldown")
	end)

	h.test("speed wind: silent at cruise, a rush at full tilt, planes hear more", function()
		h.eq(R.windGain(80, "car"), 0)
		h.ok(R.windGain(210, "plane") > R.windGain(210, "car"))
		h.ok(R.windGain(210, "plane") <= 0.6)
	end)

	----------------------------------------------------------------------------------------------------- the files

	h.test("every named cue has a prepared recording or an explicit source-release exclusion", function()
		h.ok(not prepared("unknown_unlisted_release_cue"), "unlisted missing cues still fail")
		local cues = { "music_stormcup", "sfx_airhorn", "clock_tick", "clock_tock", "clock_last", "eng_car_low", "eng_car_high",
			"eng_plane_low", "eng_plane_high", "wind_rush", "flyby_whoosh", "eng_backfire", "amb_storm" }
		for zone in R.AMB_ZONES do
			table.insert(cues, R.ambienceCue(zone) :: string)
		end
		for kind in R.BATTLE_KINDS do
			table.insert(cues, "music_battle_" .. kind)
		end
		for _, list in { R.CAR_VOICES, R.PLANE_VOICES } do
			for _, cue in list do
				table.insert(cues, cue)
				h.ok(R.VOICE_BASE[cue] ~= nil, cue .. " has a base pitch")
			end
		end
		for _, cue in cues do
			h.ok(prepared(cue), cue .. ".ogg is prepared (tools/audio/prep_soundscape.sh)")
		end
	end)
end
