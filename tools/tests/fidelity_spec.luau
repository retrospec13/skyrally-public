--!strict
-- Lune spec for shared/FidelityRules (M-1 completion line, M-2 timed pads, M-5 bot pace) and the wiring of each.
-- Run: tools/tests/run_lune_tests.sh tools/tests/fidelity_spec.luau
return function(h)
	local R = h.require("src/shared/FidelityRules.luau")
	local P = h.require("src/shared/Progression.luau")

	local function summary(t: number, k: number, b: number, bt: number, fin: boolean)
		local tokens = {}
		for i, id in ipairs(P.TOKENS) do
			if i <= t then
				tokens[id] = true
			end
		end
		local zones = { "DINO", "SNOW", "ISLAND", "FOREST" }
		local keys, boss, battles = {}, {}, {}
		for i = 1, k do
			keys[zones[i]] = true
		end
		for i = 1, b do
			boss[zones[i]] = { first = true, rematch = true }
		end
		for i = 1, bt do
			battles[zones[i]] = true
		end
		return P.completion({ tokens = tokens, boss = boss, keys = keys, battles = battles, finalBoss = fin })
	end

	h.test("completion line: short progress line under the board title", function()
		local c = summary(3, 1, 0, 0, false)
		h.eq(R.progressLine(c), "3/14 tokens | 1/4 keys | 0/4 boss | 0/4 battle | final boss: not yet")
		h.eq(R.encode(c), R.progressLine(c), "partial save carries one line only")
		local d = R.decode(R.encode(c))
		h.ok(d ~= nil and not d.complete and d.text == "")
	end)

	h.test("completion: full text and roadmap once complete, never game complete", function()
		local c = summary(14, 4, 4, 4, true)
		h.ok(c.complete)
		local d = R.decode(R.encode(c))
		h.ok(d ~= nil and d.complete)
		h.eq(d.text, c.text)
		h.eq(d.roadmap, c.roadmap)
		h.contains(d.text, "more worlds coming")
		h.ok(not string.find(string.lower(R.encode(c)), "game complete", 1, true))
		h.eq(d.line, "14/14 tokens | 4/4 keys | 4/4 boss | 4/4 battle | final boss: beaten")
	end)

	h.test("completion decode: missing or empty attribute draws nothing", function()
		h.eq(R.decode(nil), nil)
		h.eq(R.decode(""), nil)
	end)

	h.test("timed pads: on 1.6 s of every 4 s, phase shifts the window", function()
		local a = { name = "A", period = 4, onFor = 1.6, phase = 0 }
		local b = { name = "B", period = 4, onFor = 1.6, phase = 2 }
		h.ok(R.padLive(0, a))
		h.ok(R.padLive(1.59, a))
		h.ok(not R.padLive(1.6, a))
		h.ok(not R.padLive(3.99, a))
		h.ok(R.padLive(4.0, a))
		h.ok(R.padLive(1003.2, a) == R.padLive(3.2, a), "periodic")
		h.ok(not R.padLive(0, b) and not R.padLive(1.9, b))
		h.ok(R.padLive(2, b) and R.padLive(3.59, b) and not R.padLive(3.6, b))
		h.ok(R.padLive(1, b) == false and R.padLive(6.0, b) == true, "wraps before phase")
	end)

	h.test("timed pads: no period means always live; nil attribute means live", function()
		h.ok(R.padLive(123.4, { name = "X" }))
		h.ok(R.padIsLive(nil))
		h.ok(R.padIsLive(true))
		h.ok(not R.padIsLive(false))
	end)

	h.test("bot pace: default 1.0, valid multipliers pass, junk falls back", function()
		h.eq(R.botPace(nil), 1.0)
		h.eq(R.botPace(0.9), 0.9)
		h.eq(R.botPace(1.1), 1.1)
		h.eq(R.botPace(0), 1.0)
		h.eq(R.botPace(-2), 1.0)
		h.eq(R.botPace("fast"), 1.0)
		h.eq(R.botPace(0 / 0), 1.0)
		h.eq(R.botPace(math.huge), 1.0)
	end)

	h.test("static: pad trigger and bot pad use skip an off pad; only the boost grant is gated", function()
		local car = h.readFile("src/client/CarController.luau")
		h.contains(car, 'FidelityRules.padIsLive(if trig.Parent then trig.Parent:GetAttribute("PadLive")')
		local ai = h.readFile("src/server/AIRacers.luau")
		h.contains(ai, 'padModel:GetAttribute("PadLive")')
		h.contains(ai, "FidelityRules.botPace(workspace:GetAttribute(FidelityRules.BOT_PACE_ATTRIBUTE))")
		h.contains(ai, ") * trackPace")
		local pads = h.readFile("src/server/HubBossPads.luau")
		h.contains(pads, "GetServerTimeNow")
		h.contains(pads, "FidelityRules.padLive")
		h.ok(not string.find(pads, "Mesh", 1, true), "dimming never swaps a mesh")
		h.ok(not string.find(pads, "CanCollide", 1, true), "no collision changes")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "HubBossPads.start(td)")
		h.contains(td, "HubBossPads.stop()")
	end)

	h.test("static: the board draws the completion line and the save replicates it", function()
		local tf = h.readFile("src/client/TrackFlow.luau")
		h.contains(tf, "FidelityRules.decode(LocalPlayer:GetAttribute(FidelityRules.COMPLETION_ATTRIBUTE))")
		local save = h.readFile("src/server/SaveService.luau")
		h.contains(save, "FidelityRules.encode(Progression.completion(profile))")
	end)

	h.test("static: no shipped plan or TrackData sets botPace", function()
		local td = h.readFile("build/hub0/TrackData.luau")
		h.ok(not string.find(td, "botPace", 1, true), "hub0 TrackData has no botPace")
	end)
end
