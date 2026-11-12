-- Wood-and-Stone UI sound kit rules (REMARKABLE item 4, shared/UiSoundRules): the selection marimba scale, the step
-- maths, sibling ranking, and the gates that keep the curtain quiet and rapid taps from stacking.
return function(h)
	local R = h.require("src/shared/UiSoundRules.luau")

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end

	h.test("pitch: steps 1..6 climb the major pentatonic C5 D5 E5 G5 A5 C6", function()
		local want = { 1, 9 / 8, 5 / 4, 3 / 2, 5 / 3, 2 }
		for i, r in want do
			h.ok(near(R.pitch(i), r), string.format("step %d: want %.4f got %.4f", i, r, R.pitch(i)))
		end
	end)

	h.test("pitch: tops out at E6 (2.5) then walks back down, never above 2.5", function()
		h.ok(near(R.pitch(7), 9 / 4), "D6")
		h.ok(near(R.pitch(8), 5 / 2), "E6 is the top")
		h.ok(near(R.pitch(9), 9 / 4), "back down to D6")
		h.ok(near(R.pitch(10), 2), "C6")
		h.ok(near(R.pitch(15), 1), "home at C5 after a full wave")
		h.ok(near(R.pitch(16), 9 / 8), "and up again")
		for s = 1, 60 do
			local p = R.pitch(s)
			h.ok(p >= 1 and p <= 2.5, "step " .. s .. " in range")
		end
	end)

	h.test("pitch: a missing or zero step is the root", function()
		h.eq(R.pitch(nil), 1)
		h.eq(R.pitch(0), 1)
	end)

	h.test("pitch: every note sits on the pentatonic (any two neighbours sound good together)", function()
		local allowed = {}
		for oct = 0, 1 do
			for _, r in R.PENTATONIC do
				table.insert(allowed, r * 2 ^ oct)
			end
		end
		for s = 1, 30 do
			local ok = false
			for _, a in allowed do
				if near(R.pitch(s), a) then
					ok = true
				end
			end
			h.ok(ok, "step " .. s .. " off-scale")
		end
	end)

	h.test("step: rank lifted by the row (moving right or down both climb)", function()
		h.eq(R.step(1, nil), 1)
		h.eq(R.step(3, nil), 3)
		h.eq(R.step(1, 1), 1)
		h.eq(R.step(2, 4), 5)
		h.eq(R.step(0, nil), 1)
	end)

	h.test("rank: by LayoutOrder when siblings set one (Garage tabs 1..7)", function()
		local slots = {}
		for i = 1, 7 do
			-- positions deliberately scrambled: the order wins
			table.insert(slots, { order = i, x = (8 - i) * 50, y = 0 })
		end
		for i = 1, 7 do
			h.eq(R.rank(slots, slots[i]), i, "tab " .. i)
		end
	end)

	h.test("rank: reading order when no sibling has a LayoutOrder (right-aligned row buttons)", function()
		local a = { order = 0, x = 300, y = 4 }
		local b = { order = 0, x = 200, y = 6 } -- same row (within 4 px), further left
		local c = { order = 0, x = 10, y = 60 } -- next row
		local slots = { a, b, c }
		h.eq(R.rank(slots, b), 1)
		h.eq(R.rank(slots, a), 2)
		h.eq(R.rank(slots, c), 3)
	end)

	h.test("gate: nothing under the TrackSwitching curtain, unless the curtain game asks", function()
		h.eq(R.gate("tap", { now = 10, switching = true }), false)
		h.eq(R.gate("select", { now = 10, switching = true }), false)
		h.eq(R.gate("tap", { now = 10, switching = true, allowCurtain = true }), true)
		h.eq(R.gate("tap", { now = 10, switching = false }), true)
	end)

	h.test("gate: fifty rapid taps 10 ms apart play at most one in every MIN_GAP", function()
		local last: number? = nil
		local played = 0
		for i = 0, 49 do
			local now = 100 + i * 0.01
			if R.gate("tap", { now = now, switching = false, lastAt = last }) then
				played += 1
				last = now
			end
		end
		h.ok(played <= math.ceil(0.5 / R.MIN_GAP.tap) + 1, "played " .. played)
		h.ok(played >= 5, "still answers a fast hand: " .. played)
	end)

	h.test("gate: a selection note right after a press stays quiet; a later one plays", function()
		h.eq(R.gate("select", { now = 5.1, switching = false, lastPressAt = 5.0 }), false)
		h.eq(R.gate("hover", { now = 5.1, switching = false, lastPressAt = 5.0 }), false)
		h.eq(R.gate("select", { now = 5.0 + R.SELECT_HUSH_AFTER_PRESS + 0.01, switching = false, lastPressAt = 5.0 }), true)
		-- presses are never hushed by presses
		h.eq(R.gate("confirm", { now = 5.1, switching = false, lastPressAt = 5.0 }), true)
	end)

	h.test("gate: unknown kinds never play", function()
		h.eq(R.gate("explosion", { now = 1, switching = false }), false)
	end)

	h.test("kinds: every kind has a cue, a volume and a gap; presses vs notes", function()
		for _, k in R.KINDS do
			-- The two sfx_v2 kinds (unlock, vote) play SfxV2Audio roles, the UI-overhaul motion/event kinds play Roblox
			-- free-library cues (shared/ToolboxAudio); every other cue is a ui_* from synth_ui.py.
			h.ok(type(R.CUE[k]) == "string" and (R.SFX_V2_KINDS[k] or R.TOOLBOX_KINDS[k] or string.sub(R.CUE[k], 1, 3) == "ui_"), k .. " cue")
			h.ok(type(R.VOLUME[k]) == "number" and R.VOLUME[k] > 0 and R.VOLUME[k] <= 1, k .. " volume")
			h.ok(type(R.MIN_GAP[k]) == "number", k .. " gap")
		end
		h.eq(R.isPress("tap"), true)
		h.eq(R.isPress("deny"), true)
		h.eq(R.isPress("select"), false)
		h.eq(R.isPress("hover"), false)
		h.ok(R.VOLUME.hover < R.VOLUME.select, "hover is quieter than gamepad selection")
		h.eq(R.isPress("hover_tick"), false)
		h.eq(R.gate("hover_tick", { now = 5.1, switching = false, lastPressAt = 5.0 }), false, "hover tick hushed after a press too")
		for k in R.TOOLBOX_KINDS do
			h.ok(R.VOLUME[k] <= 0.5, k .. " motion cue sits under the press kit")
			h.ok(R.poolSize(k) >= 1 and R.poolSize(k) <= R.POOL_SIZE, k .. " pool")
		end
	end)

	h.test("cues: every cue the kit names is one synth_ui.py writes", function()
		local src = h.readFile("tools/audio/synth_ui.py")
		local sfx = h.readFile("src/shared/SfxV2Audio.luau")
		local toolbox = h.readFile("src/shared/ToolboxAudio.luau")
		for _, k in R.KINDS do
			if R.SFX_V2_KINDS[k] then
				h.contains(sfx, R.CUE[k] .. " =", k .. " is an uploaded sfx_v2 role")
			elseif R.TOOLBOX_KINDS[k] then
				h.contains(toolbox, "\t" .. R.CUE[k] .. " = ", k .. " is a Roblox library cue in ToolboxAudio")
			else
				h.contains(src, '"' .. R.CUE[k] .. '"', k)
			end
		end
	end)

	h.test("vote: the pip climbs a little with each vote and stops climbing at a full room", function()
		h.ok(near(R.votePitch(nil), 1))
		h.ok(near(R.votePitch(1), 1.06))
		h.ok(R.votePitch(3) > R.votePitch(2))
		h.ok(near(R.votePitch(20), R.votePitch(8)))
	end)

	h.test("sfx_v2 kinds: unlock and vote are quiet-gated like the rest and sit in the kind list", function()
		h.eq(R.CUE.unlock, "unlock_fanfare")
		h.eq(R.CUE.vote, "vote_pip")
		h.eq(R.gate("unlock", { now = 10, switching = true }), false)
		h.eq(R.isPress("unlock"), true)
		h.eq(R.isPress("vote"), false, "another racer's vote is not a press")
	end)

	h.test("groupVolume: UiVolume attribute clamps, default 0.6", function()
		h.eq(R.groupVolume(nil), 0.6)
		h.eq(R.groupVolume("loud"), 0.6)
		h.eq(R.groupVolume(0.3), 0.3)
		h.eq(R.groupVolume(4), 1)
		h.eq(R.groupVolume(-1), 0)
		h.eq(R.groupVolume(0 / 0), 0.6)
	end)

	h.test("feel: wobble is 0 -> -3 -> 2 -> 0 over 0.18 s, every step under 150 ms; shake ends at rest", function()
		local total = 0
		for _, f in R.WOBBLE do
			total += f[2]
			h.ok(f[2] < 0.15, "step under 150 ms")
		end
		h.ok(near(total, 0.18), "0.18 s total")
		h.eq(R.WOBBLE[1][1], -3)
		h.eq(R.WOBBLE[2][1], 2)
		h.eq(R.WOBBLE[#R.WOBBLE][1], 0)
		h.eq(R.SHAKE[#R.SHAKE], 0)
		h.eq(R.SHAKE[1], 4)
	end)
end
