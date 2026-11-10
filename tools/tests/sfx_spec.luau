-- sfx_v2 rules (shared/SfxRules): the per-cue table matches the uploaded set, cooldowns, the 3D audibility cut, the
-- coin ladder and the voice limiter that keeps simultaneous SFX bounded.
return function(h)
	local R = h.require("src/shared/SfxRules.luau")
	local Ids = h.require("src/shared/SfxV2Audio.luau")

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end

	local function voice(priority: number, startedAt: number, endsAt: number)
		return { priority = priority, startedAt = startedAt, endsAt = endsAt }
	end

	h.test("table: every uploaded cue has a rules entry and every entry an uploaded id", function()
		for role in Ids do
			h.ok(R.ROLES[role] ~= nil, role .. " has no SfxRules entry")
		end
		for role in R.ROLES do
			h.ok(Ids[role] ~= nil, role .. " has no id in SfxV2Audio")
		end
	end)

	h.test("table: volume follows upload_list.json", function()
		local list = h.readFile("assets/audio/sfx_v2/upload_list.json")
		local n = 0
		for role, volume in string.gmatch(list, '"role": "([%w_]+)".-"volume": ([%d%.]+)') do
			local def = R.ROLES[role]
			h.ok(def ~= nil, role)
			h.ok(near(def.volume, tonumber(volume) :: number), role .. " volume")
			n += 1
		end
		h.eq(n, 38)
	end)

	h.test("table: length and loop flag follow upload_list.json", function()
		local list = h.readFile("assets/audio/sfx_v2/upload_list.json")
		local n = 0
		for role, loop, duration in string.gmatch(list, '"role": "([%w_]+)".-"loop": (%a+).-"duration_s": ([%d%.]+)') do
			local def = R.ROLES[role]
			h.ok(near(def.length, tonumber(duration) :: number), role .. " length")
			h.eq(def.loop == true, loop == "true", role .. " loop")
			n += 1
		end
		h.eq(n, 38)
	end)

	h.test("table: sane ranges (volume, priority, cooldown, jitter, roll-off)", function()
		for role, def in R.ROLES do
			h.ok(def.volume > 0 and def.volume <= 1, role .. " volume")
			h.ok(def.priority >= 1 and def.priority <= 10, role .. " priority")
			h.ok(def.cooldown >= 0 and def.cooldown <= 1, role .. " cooldown")
			h.ok(def.jitter >= 0 and def.jitter <= 0.06, role .. " jitter")
			local minD, maxD = R.rollOff(role)
			h.ok(minD > 0 and maxD > minD, role .. " roll-off")
		end
	end)

	h.test("priority: the moments the player must hear outrank the rattle", function()
		h.ok(R.ROLES.countdown_v2.priority > R.ROLES.crash_hit.priority)
		h.ok(R.ROLES.finish_tada.priority > R.ROLES.lap_ding.priority)
		h.ok(R.ROLES.crash_hit.priority > R.ROLES.wall_scrape.priority)
		h.ok(R.ROLES.missile_explode.priority > R.ROLES.trap_arm.priority)
		h.ok(R.ROLES.shield_block.priority > R.ROLES.vote_pip.priority)
	end)

	h.test("pitch: base times a spread inside +-jitter; zero-jitter cues keep the pitch asked for", function()
		h.ok(near(R.pitch("wall_scrape", 1.1, 0.0), 1.1))
		h.ok(near(R.pitch("wall_scrape", 1.1, 1.0), 1.1))
		local j = R.ROLES.boost_kick.jitter
		h.ok(near(R.pitch("boost_kick", 1, 0), 1 - j))
		h.ok(near(R.pitch("boost_kick", 1, 1), 1 + j))
		h.ok(near(R.pitch("boost_kick", 1, 0.5), 1))
		h.ok(near(R.pitch("boost_kick", nil, 0.5), 1))
	end)

	h.test("cooldown: first play always, then only after the gap; unknown cues never", function()
		h.eq(R.cooldownOk("place_up", 10, nil), true)
		h.eq(R.cooldownOk("place_up", 10.2, 10), false)
		h.eq(R.cooldownOk("place_up", 10.4, 10), true)
		h.eq(R.cooldownOk("no_such_cue", 10, nil), false)
	end)

	h.test("audible: 3D cues past their roll-off max are skipped; explosions carry farther than a trap tick", function()
		h.eq(R.audible("missile_explode", 250), true)
		h.eq(R.audible("missile_explode", 270), false)
		h.eq(R.audible("trap_arm", 39), true)
		h.eq(R.audible("trap_arm", 41), false)
		h.eq(R.audible("shield_block", 171), false)
		local minD, maxD = R.rollOff("missile_explode")
		h.eq(minD, 24)
		h.eq(maxD, 260)
	end)

	h.test("others: another racer's cue plays quieter than your own", function()
		h.ok(R.otherVolume(0.8) < 0.8)
		h.ok(near(R.otherVolume(1), R.OTHER_SCALE))
	end)

	h.test("coins: the ladder climbs the pentatonic and holds at the top", function()
		for i = 2, #R.COIN_LADDER do
			h.ok(R.coinPitch(i) > R.coinPitch(i - 1), "step " .. i)
		end
		h.eq(R.coinPitch(0), 1)
		h.eq(R.coinPitch(1), 1)
		h.eq(R.coinPitch(8), 2.5)
		h.eq(R.coinPitch(40), 2.5)
	end)

	h.test("coins: a rising count rings its step, the last coin also the finale, a reset or first look is silent", function()
		h.eq({ R.coinStep(nil, 3, 8) }, { nil, false })
		h.eq({ R.coinStep(2, 3, 8) }, { 3, false })
		h.eq({ R.coinStep(7, 8, 8) }, { 8, true })
		h.eq({ R.coinStep(8, 0, 8) }, { nil, false })
		h.eq({ R.coinStep(3, 3, 8) }, { nil, false })
		h.eq({ R.coinStep(0, 1, nil) }, { 1, false })
	end)

	h.test("duration: clip length divided by playback speed", function()
		h.ok(near(R.duration("lap_ding", 1), 1.1))
		h.ok(near(R.duration("lap_ding", 2), 0.55))
		h.ok(R.duration("lap_ding", 0) > 0)
	end)

	h.test("voices: below the cap everything is admitted; finished voices are pruned first", function()
		local v = { voice(2, 0, 0.5), voice(2, 0, 5) }
		local ok, steal = R.admit(v, 1, 1, 2)
		h.eq(ok, true)
		h.eq(steal, nil)
		h.eq(#v, 1, "the finished voice left")
	end)

	h.test("voices: at the cap a louder-priority cue steals the lowest, oldest voice", function()
		local v = { voice(5, 0, 9), voice(2, 1, 9), voice(2, 0.5, 9), voice(7, 0, 9) }
		local ok, steal = R.admit(v, 2, 6, 4)
		h.eq(ok, true)
		h.eq(steal, 3, "priority 2 started at 0.5 is the oldest of the lowest")
	end)

	h.test("voices: a cue that does not outrank anything playing is dropped; an equal one steals the oldest", function()
		local v = { voice(5, 0, 9), voice(6, 1, 9) }
		local ok, steal = R.admit(v, 2, 4, 2)
		h.eq(ok, false)
		h.eq(steal, nil)
		local ok2, steal2 = R.admit(v, 2, 5, 2)
		h.eq(ok2, true)
		h.eq(steal2, 1)
	end)

	h.test("voices: a flood of 100 cues never holds more than MAX_VOICES at once", function()
		local v = {}
		local peak = 0
		for i = 1, 100 do
			local now = i * 0.01
			local pri = (i * 7) % 9 + 1
			local ok, steal = R.admit(v, now, pri)
			if ok then
				if steal then
					table.remove(v, steal)
				end
				table.insert(v, voice(pri, now, now + 0.8))
			end
			peak = math.max(peak, #v)
		end
		h.eq(peak, R.MAX_VOICES)
	end)

	h.test("voices: the top-priority cue always gets in, even into a full mix of lesser cues", function()
		local v = {}
		for i = 1, R.MAX_VOICES do
			table.insert(v, voice(9, 0, 99))
		end
		local ok, steal = R.admit(v, 1, R.ROLES.countdown_v2.priority)
		h.eq(ok, true)
		h.ok(steal ~= nil)
	end)

	h.test("wall: a pinned wall plays wall_bump once, then hands off to wall_scrape while contact lasts", function()
		local c = R.newWallContact()
		h.eq(R.wallCue(c, 0, 40, 0.8), "wall_bump")
		for i = 1, 10 do
			h.eq(R.wallCue(c, i * 0.3, 40, 0.8), "wall_scrape")
		end
	end)

	h.test("wall: a new wall_bump only after 0.6 s without contact, or on a clearly harder hit", function()
		local c = R.newWallContact()
		h.eq(R.wallCue(c, 0, 40, 0.8), "wall_bump")
		h.eq(R.wallCue(c, 0.5, 40, 0.8), "wall_scrape")
		h.eq(R.wallCue(c, 1.2, 40, 0.8), "wall_bump", "0.7 s since last contact is a fresh contact")
		h.eq(R.wallCue(c, 1.3, 40, 0.8), "wall_scrape")
		h.eq(R.wallCue(c, 1.4, 90, 0.9), "wall_bump", "a clearly harder hit still bumps")
		h.eq(R.wallCue(c, 1.5, 90, 0.9), "wall_scrape")
	end)

	h.test("wall: a light grind does not re-bump, and the reset gap is measured from the last contact frame", function()
		local c = R.newWallContact()
		h.eq(R.wallCue(c, 0, 40, 0.8), "wall_bump")
		h.eq(R.wallCue(c, 0.5, 40, 0.8), "wall_scrape")
		h.eq(R.wallCue(c, 1.0, 40, 0.8), "wall_scrape", "contact frames keep refreshing the gap")
		h.eq(R.wallCue(c, 1.5, 42, 0.8), "wall_scrape", "a barely harder grind is not a new bump")
	end)

	h.test("wiring: every client call names a cue that exists in the rules", function()
		local names = { "Sfx", "SoundJuice", "ItemClient", "CarController", "FlightController", "RaceUI", "CourseArrow", "TrackFlow" }
		local seen = 0
		for _, name in names do
			local src = h.readFile("src/client/" .. name .. ".luau")
			for role in string.gmatch(src, 'Sfx%.%w+%(%s*"([%w_]+)"') do
				h.ok(R.ROLES[role] ~= nil, name .. " plays unknown cue " .. role)
				seen += 1
			end
		end
		h.ok(seen >= 20, "found " .. seen .. " Sfx call sites")
	end)
end
