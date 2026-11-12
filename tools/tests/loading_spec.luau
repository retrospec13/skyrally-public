--!strict
-- Lune spec for the loading screen rules (src/loading/LoadingRules.luau): TEST_LIST_LAUNCH L27 (the screen never sticks)
-- and L42 (the join-to-control line). The drawing script (src/loading/init.client.luau) is checked for its wiring.
-- Run: tools/tests/run_lune_tests.sh tools/tests/loading_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/loading/LoadingRules.luau")

	local function allDone(): any
		local d: any = {}
		for _, m in R.MILESTONES do
			d[m.id] = true
		end
		return d
	end

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end

	h.test("loading: the title is one constant and the milestones add up to 1", function()
		h.eq(R.TITLE, "SkyRally")
		local sum = 0
		local ids: any = {}
		for _, m in R.MILESTONES do
			sum += m.weight
			h.ok(not ids[m.id], "unique " .. m.id)
			ids[m.id] = true
			h.ok(#m.text <= 24, m.text .. " is short")
		end
		h.ok(near(sum, 1), "weights sum to " .. tostring(sum))
		for _, id in { "game", "assets", "character", "vehicle", "track" } do
			h.ok(ids[id], id)
		end
		-- The title is not typed anywhere else in the loading script.
		local script = h.readFile("src/loading/init.client.luau")
		h.ok(string.find(script, "Rules.TITLE", 1, true) ~= nil)
		h.ok(string.find(script, '"SkyRally"', 1, true) == nil, "no second copy of the title")
	end)

	h.test("loading: progress follows real milestones only", function()
		h.eq(R.progress({}, nil), 0)
		h.ok(near(R.progress({ game = true }, nil), 0.1))
		h.ok(near(R.progress({ game = true }, 0.5), 0.1 + 0.35 * 0.5), "asset fraction counts while under way")
		h.ok(near(R.progress({ game = true, assets = true }, 0.2), 0.45), "a finished milestone ignores the fraction")
		h.ok(near(R.progress({ character = true }, 0.9), 0.15 + 0.35 * 0.9), "fraction only feeds the assets milestone")
		h.ok(near(R.progress(allDone(), 0), 1))
		h.ok(R.progress({ game = true }, 7) <= 1 and R.progress({}, -3) >= 0, "clamped")
	end)

	h.test("loading: status text names the first open milestone", function()
		h.eq(R.statusText({}), "Opening the hangar...")
		h.eq(R.statusText({ game = true }), "Painting the signs...")
		h.eq(R.statusText({ game = true, assets = true, character = true }), "Fueling up...")
		h.eq(R.statusText(allDone()), "Ready for takeoff!")
		h.eq(R.missing({ game = true, assets = true }), { "character", "vehicle", "track" })
		h.eq(#R.missing(allDone()), 0)
	end)

	h.test("loading: the bar never goes backward, never overshoots, always creeps", function()
		local shown = 0
		local last = 0
		for _ = 1, 600 do
			shown = R.smooth(shown, 0.5, 1 / 60)
			h.ok(shown >= last, "monotonic")
			h.ok(shown <= 0.5, "never past the target")
			last = shown
		end
		h.ok(shown > 0.49, "arrives")
		h.eq(R.smooth(0.8, 0.5, 0.1), 0.8, "a lower target never pulls it back")
		-- A long stall still moves a little each frame until the target.
		h.ok(R.smooth(0.2, 0.9, 1 / 60) > 0.2)
	end)

	h.test("loading: leaves when everything is done after the minimum, or at the hard timeout", function()
		h.eq(R.status({}, 0), "wait")
		h.eq(R.status(allDone(), 0.5), "wait", "a fast join still shows the logo for MIN_SHOW")
		h.eq(R.status(allDone(), R.MIN_SHOW), "ready")
		h.eq(R.status({ game = true }, R.TIMEOUT - 0.1), "wait")
		h.eq(R.status({ game = true }, R.TIMEOUT), "timeout", "never sticks")
		h.eq(R.status({}, 3600), "timeout")
		h.eq(R.status(allDone(), R.TIMEOUT + 5), "ready")
		h.ok(R.TIMEOUT >= R.BUDGET_HUB and R.TIMEOUT >= R.BUDGET_TRACK, "the timeout is beyond the L42 budgets")
		h.ok(R.ASSET_BUDGET < R.TIMEOUT)
	end)

	h.test("loading: tips are short, start with the portal, and match the device", function()
		for _, mode in { "Touch", "Gamepad", "KeyboardMouse" } do
			local tips = R.tipsFor(mode)
			h.eq(tips[1], "Drive through a portal to start a race!")
			h.ok(#tips >= 8, mode .. " has a rotation")
			local seen: any = {}
			for _, t in tips do
				h.ok(#t <= 40, mode .. ": '" .. t .. "' fits a 740 px line")
				h.ok(not seen[t], "no repeats: " .. t)
				seen[t] = true
			end
		end
		local function joined(mode: string): string
			return table.concat(R.tipsFor(mode), "|")
		end
		h.contains(joined("Touch"), "left pad")
		h.contains(joined("Gamepad"), "Left stick")
		h.contains(joined("KeyboardMouse"), "A and D")
		h.ok(string.find(joined("Touch"), "Left stick", 1, true) == nil, "no gamepad words on a phone")
		h.contains(joined("Touch"), "item balloons")
		h.contains(R.tipsFor("nonsense")[2], "A and D", "unknown device falls back to keyboard")
		h.eq(R.modeFor(true, false, false), "Touch")
		h.eq(R.modeFor(false, false, true), "Gamepad")
		h.eq(R.modeFor(true, true, false), "KeyboardMouse")
		h.eq(R.modeFor(false, true, true), "KeyboardMouse")
	end)

	h.test("loading: tips rotate on a timer with a fade in and out", function()
		h.eq(R.tipIndex(8, 0), 1)
		h.eq(R.tipIndex(8, R.TIP_SECONDS), 2)
		h.eq(R.tipIndex(8, R.TIP_SECONDS * 8), 1, "wraps")
		h.eq(R.tipIndex(0, 5), 1)
		h.eq(R.tipAlpha(0), 0)
		h.eq(R.tipAlpha(0.5), 1)
		h.ok(R.tipAlpha(0.06) > 0 and R.tipAlpha(0.06) < 1)
		h.eq(R.tipAlpha(1), 0)
		h.ok(near(R.tipPhase(R.TIP_SECONDS * 3.25), 0.25))
	end)

	h.test("loading: the plane crosses the whole sky and loops", function()
		h.ok(R.planeX(0) < 0, "starts off the left edge")
		local maxX = -1
		for i = 0, 100 do
			local x = R.planeX(R.PLANE_PERIOD * i / 100 * 0.999)
			maxX = math.max(maxX, x)
		end
		h.ok(maxX > 1, "ends off the right edge")
		h.ok(near(R.planeX(R.PLANE_PERIOD), R.planeX(0)), "loops")
		for t = 0, 30 do
			h.ok(math.abs(R.planeBob(t)) <= 0.02 and math.abs(R.planeTilt(t)) <= 4.0001)
		end
	end)

	h.test("loading: the L42 log line carries the seconds, the verdict and every milestone", function()
		local stamps = { game = 0.4, assets = 2.9, character = 1.2, vehicle = 3.8, track = 4.8 }
		local line = R.formatLog(stamps, {}, 4.8, "hub", "HUB-0")
		h.eq(line, "[SkyRally][LOAD] join_to_control=4.80s PASS(<=10s) game=0.40 assets=2.90 character=1.20 vehicle=3.80 track=4.80 mode=hub map=HUB-0")
		h.contains(R.formatLog(stamps, {}, 11.2, "hub", "HUB-0"), "SLOW(>10s)")
		h.contains(R.formatLog(stamps, {}, 11.2, "race", "DINO-4"), "PASS(<=12s)", "a track gets 12 s")
		h.contains(R.formatLog(stamps, {}, 13, "race", "DINO-4"), "SLOW(>12s)")
		local timeout = R.formatLog({ game = 0.4 }, { "assets", "vehicle" }, 20, "hub", nil)
		h.contains(timeout, "TIMEOUT(missing=assets,vehicle)")
		h.contains(timeout, "assets=-")
		h.contains(timeout, "map=?")
		h.eq(R.budgetFor("hub"), 10)
		h.eq(R.budgetFor(nil), 10)
		h.eq(R.budgetFor("race"), 12)
	end)

	h.test("loading: preloaded sprites and sounds are the ones the game really uses", function()
		local raceUi = h.readFile("src/client/RaceUI.luau")
		for _, id in R.HUD_SPRITES do
			h.contains(raceUi, tostring(id), "RaceUI.ASSET_IDS has " .. tostring(id))
		end
		h.eq(R.thumbUrl(96696699374497, 420, 420), "rbxthumb://type=Asset&id=96696699374497&w=420&h=420")
		local juice = h.readFile("src/client/SoundJuice.luau")
		for _, sid in R.KEY_SOUNDS do
			h.contains(juice, sid, "SoundJuice.SOUND_IDS has " .. sid)
		end
		-- The cue names exist in the shared audio tables (a typo would silently preload nothing).
		local ui = h.readFile("src/shared/UiAudioAssets.luau")
		for _, cue in R.KEY_SOUND_CUES do
			h.contains(ui .. h.readFile("src/shared/AudioAssets.luau") .. h.readFile("src/shared/SfxV2Audio.luau"), cue .. " =", cue)
		end
	end)

	h.test("loading: the screen is wired to remove the default, wait on real signals and never stick", function()
		local s = h.readFile("src/loading/init.client.luau")
		h.contains(s, "RemoveDefaultLoadingScreen")
		h.contains(s, "PreloadAsync")
		h.contains(s, "TrackReady")
		h.contains(s, "MountedInPlane")
		h.contains(s, "HumanoidRootPart")
		h.contains(s, "Rules.formatLog")
		h.contains(s, "Rules.status")
		h.contains(s, "LoadingDone")
		local project = h.readFile("default.project.json")
		h.contains(project, '"ReplicatedFirst"')
		h.contains(project, '"src/loading"')
	end)
end
