--!strict
-- Lune spec for the first-session guide, the analytics funnels and the HUD safe area (TEST_LIST_LAUNCH L27, L28, L82;
-- audit B5, M3, H15): src/shared/OnboardingRules.luau, src/shared/SafeAreaRules.luau, the saved "onboarded" flag in
-- src/server/SaveService.luau, and static checks that the client and server wire them without a way around the rules.
-- Run: tools/tests/run_lune_tests.sh tools/tests/onboarding_spec.luau
return function(h)
	local R = h.require("src/shared/OnboardingRules.luau")
	local S = h.require("src/shared/SafeAreaRules.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local function near(a: number, b: number)
		h.ok(math.abs(a - b) < 1e-6, string.format("%s is not near %s", tostring(a), tostring(b)))
	end

	------------------------------------------------------------------------------------------------ guide words

	h.test("words: the goal card says the goal and the input family's controls", function()
		for _, family in { "Touch", "Gamepad", "KeyboardMouse" } do
			local lines = R.goalLines(family)
			h.eq(lines[1], "Win races, earn Sky Tokens, open new worlds!")
			h.eq(#lines, 3)
		end
		h.contains(R.controlsLine("Touch"), "stone pad")
		h.contains(R.controlsLine("Gamepad"), "stick")
		h.contains(R.controlsLine("KeyboardMouse"), "A and D")
	end)

	h.test("words: the item tip names the right button for touch, gamepad and keyboard", function()
		h.eq((R.tip("item", "Touch", "plane") :: any).body, "Tap ITEM to fire it.")
		h.eq((R.tip("item", "Gamepad", "plane") :: any).body, "Press X to fire it.")
		h.eq((R.tip("item", "KeyboardMouse", "plane") :: any).body, "Press F to fire it.")
	end)

	h.test("words: the drift tip is for cars; planes get the sharp-bank words", function()
		h.contains((R.tip("drift", "Touch", "car") :: any).body, "TURN")
		h.contains((R.tip("drift", "Gamepad", "car") :: any).body, "R1")
		h.contains((R.tip("drift", "KeyboardMouse", "car") :: any).body, "SHIFT")
		h.eq((R.tip("drift", "Touch", "plane") :: any).title, "SHARP BANK!")
	end)

	h.test("words: the lap tip counts the laps left and is silent when none are", function()
		h.eq((R.tip("lap", "Touch", "car", 2) :: any).body, "2 more to win. Stay ahead!")
		h.eq((R.tip("lap", "Touch", "car", 1) :: any).body, "Last lap! Give it everything!")
		h.eq(R.tip("lap", "Touch", "car", 0), nil)
		h.eq(R.tip("nonsense", "Touch", "car"), nil)
	end)

	h.test("words: every line is short enough for a 740x360 card (title 16, body 44, goal 46 characters)", function()
		for _, family in { "Touch", "Gamepad", "KeyboardMouse" } do
			for _, vehicle in { "car", "plane" } do
				for _, id in R.TIP_IDS do
					local t = R.tip(id, family, vehicle, 2)
					h.ok(t ~= nil, id)
					h.ok(#(t :: any).title <= 16, (t :: any).title)
					h.ok(#(t :: any).body <= 44, (t :: any).body)
				end
			end
			for _, line in R.goalLines(family) do
				h.ok(#line <= 46, line)
			end
		end
	end)

	h.test("words: the help card gives the controls for each family and vehicle in three short lines", function()
		local touch = R.helpLines("Touch", "car")
		h.eq(touch[2], "Tap ITEM to fire items.")
		h.eq(touch[3], "Hold TURN in corners to drift.")
		h.eq(R.helpLines("Gamepad", "plane")[3], "Hold R1 for tight turns.")
		h.eq(R.helpLines("KeyboardMouse", "car")[2], "Press F to fire items.")
		for _, family in { "Touch", "Gamepad", "KeyboardMouse" } do
			for _, vehicle in { "car", "plane" } do
				local lines = R.helpLines(family, vehicle)
				h.eq(#lines, 3)
				for _, line in lines do
					h.ok(#line <= 40, line)
				end
			end
		end
	end)

	h.test("family: unknown input falls back to keyboard", function()
		h.eq(R.family("Touch"), "Touch")
		h.eq(R.family("Gamepad"), "Gamepad")
		h.eq(R.family("KeyboardMouse"), "KeyboardMouse")
		h.eq(R.family(nil), "KeyboardMouse")
		h.eq(R.family(7), "KeyboardMouse")
	end)

	------------------------------------------------------------------------------------------------ guide timing

	h.test("goal: shown once, in the hub, after the first spawn, and not after a portal", function()
		local st = R.newState(true)
		h.eq(R.goalDue(st, "hub", false), false, "not before the first spawn")
		h.eq(R.goalDue(st, "race", true), false, "not in a race")
		h.eq(R.goalDue(st, "hub", true), true)
		st.goalShown = true
		h.eq(R.goalDue(st, "hub", true), false, "once")
		local st2 = R.newState(true)
		st2.portalDone = true
		h.eq(R.goalDue(st2, "hub", true), false, "after the portal the goal is old news")
		h.eq(R.goalDue(R.newState(false), "hub", true), false, "an onboarded player sees no guide")
	end)

	h.test("arrow: hub only, only until a portal is driven through, only with a target", function()
		local st = R.newState(true)
		h.eq(R.arrowOn(st, "hub", true), true)
		h.eq(R.arrowOn(st, "hub", false), false)
		h.eq(R.arrowOn(st, "race", true), false)
		st.portalDone = true
		h.eq(R.arrowOn(st, "hub", true), false)
		h.eq(R.arrowOn(R.newState(false), "hub", true), false)
	end)

	h.test("hold: nil in the plain hub, a reason for every race flow state, race > lobby > switching > storm > loading", function()
		local base = { raceMode = "hub", lobbyGoAt = nil, now = 100, switching = false, stormHold = false, loadingOver = true }
		local function with(over: any): any
			local c = table.clone(base)
			for k, v in over do
				c[k] = v
			end
			return c
		end
		h.eq(R.holdReason(base), nil)
		h.eq(R.holdReason(with({ lobbyGoAt = 105 })), "lobby")
		h.eq(R.holdReason(with({ lobbyGoAt = 99.8 })), "lobby", "0.5 s grace after the go time")
		h.eq(R.holdReason(with({ lobbyGoAt = 99 })), nil, "an expired lobby holds nothing")
		for _, m in { "race", "battle", "timetrial", "countdown" } do
			h.eq(R.holdReason(with({ raceMode = m })), "race", m)
		end
		h.eq(R.holdReason(with({ raceMode = "" })), nil, "empty mode is not a race")
		h.eq(R.holdReason(with({ switching = true })), "switching")
		h.eq(R.holdReason(with({ stormHold = true })), "storm")
		h.eq(R.holdReason(with({ loadingOver = false })), "loading")
		h.eq(R.holdReason(with({ resumeAt = 101 })), "resume")
		h.eq(R.holdReason(with({ resumeAt = 99 })), nil)
		h.eq(R.holdReason(with({ raceMode = "race", lobbyGoAt = 105, switching = true, loadingOver = false })), "race")
		h.eq(R.holdReason(with({ lobbyGoAt = 105, switching = true, stormHold = true, loadingOver = false })), "lobby")
		h.eq(R.holdReason(with({ switching = true, stormHold = true, loadingOver = false })), "switching")
		h.eq(R.holdReason(with({ stormHold = true, loadingOver = false })), "storm")
	end)

	h.test("hold: arrowOn is false under any hold; the 3-argument call is unchanged", function()
		local st = R.newState(true)
		h.eq(R.arrowOn(st, "hub", true, "lobby"), false)
		h.eq(R.arrowOn(st, "hub", true, nil), true)
		h.eq(R.arrowOn(st, "hub", true), true)
	end)

	h.test("retire: a race seen with a vehicle ends the guide for good; replay brings it back", function()
		local st = R.newState(true)
		h.eq(R.shouldRetireForRace(st, "hub", true), false)
		h.eq(R.shouldRetireForRace(st, "", true), false)
		h.eq(R.shouldRetireForRace(st, "race", false), false, "no vehicle yet")
		h.eq(R.shouldRetireForRace(st, "race", true), true)
		R.retire(st, "race")
		h.eq(st.portalDone, true)
		h.eq(st.retiredWhy, "race")
		h.eq(R.arrowOn(st, "hub", true), false, "back in the hub after the race: still gone")
		st.arrived, st.arrowSeconds, st.ringSeconds = true, 50, 9
		R.replay(st)
		h.eq(st.portalDone, false)
		h.eq(st.arrived, false)
		h.eq(st.arrowSeconds, 0)
		h.eq(st.ringSeconds, 0)
		h.eq(st.retiredWhy, nil)
		h.eq(R.shouldRetireForRace(R.newState(false), "race", true), false, "an onboarded player has no guide to retire")
	end)

	h.test("phase: arrow far away, ring near or after arrival, off at the caps", function()
		local st = R.newState(true)
		h.eq(R.phase(st, 100), "arrow")
		h.eq(R.phase(st, 30), "ring")
		h.eq(R.phase(st, 10), "ring")
		st.arrowSeconds = 119.9
		h.eq(R.phase(st, 100), "arrow")
		st.arrowSeconds = 120
		h.eq(R.phase(st, 100), "off")
		st = R.newState(true)
		st.arrived = true
		st.ringSeconds = 44
		h.eq(R.phase(st, 100), "ring", "after arrival the ring holds wherever the car goes")
		st.ringSeconds = 45
		h.eq(R.phase(st, 100), "off")
	end)

	h.test("step: the arrival beat fires once; a hold stops every clock", function()
		local st = R.newState(true)
		h.eq(R.step(st, 0.1, false, nil), false)
		h.eq(R.step(st, 0.1, true, nil), true, "first frame in the ring")
		h.eq(R.step(st, 0.1, true, nil), false)
		h.eq(R.step(st, 0.1, false, nil), false)
		h.eq(R.step(st, 0.1, true, nil), false, "leaving and re-entering is silent")
		near(st.ringSeconds, 0.3)
		local held = R.newState(true)
		h.eq(R.step(held, 5, true, "lobby"), false, "no beat while held")
		h.eq(held.arrived, false)
		h.eq(held.arrowSeconds, 0)
		R.step(held, 2, false, nil)
		h.eq(held.arrowSeconds, 2)
	end)

	h.test("ring and gem: alphas and centres", function()
		near(R.ringAlpha(45), 0.5)
		near(R.ringAlpha(45), 1 - R.arrowAlpha(45))
		local x, z = R.ringCentre(0, 0, 0, 1)
		h.eq(x, 0)
		h.eq(z, -14)
		x, z = R.ringCentre(100, 50, 3, 0)
		near(x, 86)
		h.eq(z, 50)
		x, z = R.diamondCentre(0, 0, 0, 1)
		h.eq(x, 0)
		h.eq(z, -R.DIAMOND_BACK)
		h.ok(R.DIAMOND_BACK < R.RING_BACK + R.RING_RADIUS, "the gem floats inside the landing ring")
		h.eq(R.diamondAlpha(5), 0, "gone when the car is on it")
		h.eq(R.diamondAlpha(R.DIAMOND_FADE_NEAR), 0)
		near(R.diamondAlpha((R.DIAMOND_FADE_NEAR + R.DIAMOND_FADE_FAR) / 2), 0.5)
		h.eq(R.diamondAlpha(R.DIAMOND_FADE_FAR), 1)
		h.eq(R.diamondAlpha(200), 1)
		h.eq(R.ARRIVE_RADIUS, 12)
		h.ok(R.DIAMOND_HEIGHT >= 4 and R.DIAMOND_HEIGHT <= 6, "about vehicle height (hull 2.4, cab and driver ~5)")
	end)

	h.test("plaza: hysteresis keeps the rim from flickering, the arches stand inside", function()
		local cx, cz = R.PLAZA_X, R.PLAZA_Z
		h.eq(R.plazaStep(false, cx, cz), true, "the fountain")
		h.eq(R.plazaStep(false, cx + 138, cz), true, "in at PLAZA_IN")
		h.eq(R.plazaStep(false, cx + 139, cz), false, "outside stays outside between the radii")
		h.eq(R.plazaStep(true, cx + 139, cz), true, "inside stays inside between the radii")
		h.eq(R.plazaStep(true, cx, cz - 154), true)
		h.eq(R.plazaStep(true, cx, cz - 155), false, "out past PLAZA_OUT")
		h.eq(R.plazaStep(false, cx, cz - 155), false)
		-- the ISLAND portal (hub0 plan: shimmer -8150, 7882) and the spawn side are on the plaza
		h.eq(R.plazaStep(false, -8150, 7882), true)
		h.eq(R.plazaStep(false, -8266.2, 7979.5), true, "DINO arch")
		h.ok(R.PLAZA_IN < R.PLAZA_OUT, "a real dead band")
		h.eq(R.plazaStep(false, -8540, 7945), false, "the route start by the harbour is off the plaza")
	end)

	h.test("plaza: the constants follow the hub0 author script", function()
		local py = h.readFile("tools/map/author_hub0.py")
		h.contains(py, "ORIGIN = (-8000.0, 0.0, 8000.0)")
		h.contains(py, "PLAZA_C = (-150.0, 0.0)")
		h.contains(py, "PLAZA_R = 150.0")
		h.eq(R.PLAZA_X, -8000 - 150)
		h.eq(R.PLAZA_Z, 8000)
		h.ok(R.PLAZA_OUT <= 150 + 4, "never past the paved edge by much")
		for zone, hex in R.PORTAL_COLORS do
			h.contains(py, string.format('"%s": ("%s"', zone, hex))
		end
	end)

	h.test("surface: arrow on the plaza only, the chip off it, nothing under a hold", function()
		local st = R.newState(true)
		h.eq(R.surface(st, "hub", true, nil, 10), "chip", "not on the plaza yet")
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
		h.eq(st.onPlaza, true)
		h.eq(R.surface(st, "hub", true, nil, 10), "world")
		h.eq(R.surface(st, "hub", false, nil, 10), "none", "no portal to point at")
		R.watchPlaza(st, R.PLAZA_X + 200, R.PLAZA_Z)
		h.eq(st.onPlaza, false)
		h.eq(R.surface(st, "hub", true, nil, 10), "chip", "off the plaza: the chip, not the arrow")
		h.eq(R.surface(R.newState(false), "hub", true, nil, 10), "none", "an onboarded player has no guide")
		for _, hold in { "race", "lobby", "storm", "switching", "loading", "resume" } do
			h.eq(R.surface(st, "hub", true, hold, 10), "none", hold)
			R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
			h.eq(R.surface(st, "hub", true, hold, 10), "none", hold .. " on the plaza")
			R.watchPlaza(st, R.PLAZA_X + 200, R.PLAZA_Z)
		end
		h.eq(R.surface(st, "race", true, nil, 10), "none")
		st.portalDone = true
		h.eq(R.surface(st, "hub", true, nil, 10), "none", "a portal driven through ends it for good")
	end)

	h.test("chip: tap peeks for a few seconds, tap again dismisses, the plaza resets it", function()
		local st = R.newState(true)
		st.onPlaza = false
		h.eq(R.chipTap(st, 100), "peek")
		h.eq(st.peekUntil, 100 + R.PEEK_SECONDS)
		h.eq(R.surface(st, "hub", true, nil, 103), "world", "the way is shown off the plaza")
		h.eq(R.surface(st, "hub", true, nil, 100 + R.PEEK_SECONDS), "chip", "the peek ran out by itself")
		h.eq(R.chipTap(st, 101), "dismiss", "while the way is shown a tap hides the chip")
		h.eq(st.peekUntil, 0)
		h.eq(R.surface(st, "hub", true, nil, 102), "none", "dismissed: nothing off the plaza")
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z + 20)
		h.eq(R.surface(st, "hub", true, nil, 103), "world", "back on the plaza the arrow is on again")
		R.watchPlaza(st, R.PLAZA_X + 300, R.PLAZA_Z)
		h.eq(R.surface(st, "hub", true, nil, 104), "chip", "and the chip is back after leaving once more")
		R.chipTap(st, 105)
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
		h.eq(st.peekUntil, 0, "a peek ends on reaching the plaza")
		st.chipDismissed = true
		R.replay(st)
		h.eq(st.chipDismissed, false, "? runs the guide again")
		h.eq(R.surface(st, "hub", true, "lobby", 0), "none")
		R.chipTap(st, 5)
		h.eq(R.surface(st, "hub", true, "lobby", 6), "none", "a hold hides even a peek")
	end)

	h.test("chip: the plaza arrow hands over to the chip when its time runs out; a peek ignores the caps", function()
		local st = R.newState(true)
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
		st.arrowSeconds = R.ARROW_MAX_SECONDS
		h.eq(R.spent(st), true)
		h.eq(R.surface(st, "hub", true, nil, 1), "chip")
		h.eq(R.phase(st, 100, true), "arrow", "a peek shows the arrow past the cap")
		h.eq(R.phase(st, 10, true), "ring")
		R.chipTap(st, 1)
		h.eq(R.surface(st, "hub", true, nil, 2), "world")
		st = R.newState(true)
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
		st.arrived, st.ringSeconds = true, R.RING_LINGER
		h.eq(R.spent(st), true)
		h.eq(R.phase(st, 100, true), "arrow", "after arrival a peek still points at the arch")
		h.eq(R.spent(R.newState(true)), false)
	end)

	h.test("chip: a plaza guide that never started counts no time while off the plaza or held", function()
		local st = R.newState(true)
		R.step(st, 3, false, "chip")
		h.eq(st.arrowSeconds, 0)
		R.step(st, 3, false, nil)
		h.eq(st.arrowSeconds, 3)
	end)

	h.test("storm: the Storm match holds the guide and does not retire it; every other race does", function()
		local st = R.newState(true)
		h.eq(R.shouldRetireForRace(st, "stormcup", true), false)
		h.eq(R.shouldRetireForRace(st, R.STORM_MODE, true), false)
		h.eq(R.shouldRetireForRace(st, "race", true), true)
		h.eq(R.shouldRetireForRace(st, "battle", true), true)
		local ctx = { raceMode = "stormcup", lobbyGoAt = nil, now = 100, switching = false, stormHold = false, loadingOver = true }
		h.eq(R.holdReason(ctx), "race", "hidden for the whole match")
		R.watchPlaza(st, R.PLAZA_X, R.PLAZA_Z)
		h.eq(R.surface(st, "stormcup", true, "race", 5), "none")
		h.eq(st.portalDone, false, "nothing retired it")
		-- left the match: the hub is back, the resume delay passes, the world is on again
		ctx.raceMode, ctx.resumeAt = "hub", 101.5
		h.eq(R.holdReason(ctx), "resume")
		ctx.now = 101.6
		h.eq(R.holdReason(ctx), nil)
		h.eq(R.surface(st, "hub", true, R.holdReason(ctx), 101.6), "world")
		-- off the plaza on return: the chip
		R.watchPlaza(st, R.PLAZA_X + 300, R.PLAZA_Z)
		h.eq(R.surface(st, "hub", true, R.holdReason(ctx), 101.6), "chip")
		-- the clocks stood still through the match
		local held = R.newState(true)
		R.step(held, 60, false, "race")
		h.eq(held.arrowSeconds, 0)
		-- the Storm lobby minute and the cup start hold hide it too
		ctx.raceMode, ctx.resumeAt, ctx.stormHold = "hub", nil, true
		h.eq(R.holdReason(ctx), "storm")
	end)

	h.test("chip: the rect is right of the ? button, or under the token chip when lane A is in the way", function()
		local H = h.require("src/shared/HudLayoutRules.luau")
		local ins: any = { top = 0, bottom = 0, left = 0, right = 0 }
		for _, c in { { 844, 390, "touch" }, { 740, 360, "touch" }, { 1280, 720, "desktop" }, { 1920, 1080, "desktop" } } do
			local r = H.compute(c[1], c[2], ins, { x = 0, y = 0, w = 170, h = 58 }, c[3] :: any)
			local chip = R.chipRect(r.help, r.token, r.laneA)
			h.ok(chip.w >= 44 and chip.h >= 44, "a thumb-sized chip at " .. c[1])
			h.ok(not H.overlap(chip, r.laneA), "clear of lane A at " .. c[1])
			h.ok(not H.overlap(chip, r.nav), "clear of the Roblox nav at " .. c[1])
			h.ok(not H.overlap(chip, r.item), "clear of the item frame at " .. c[1])
			h.ok(not H.overlap(chip, r.help) and not H.overlap(chip, r.gear), "clear of the system buttons at " .. c[1])
			h.ok(not H.overlap(chip, r.token), "clear of the token chip at " .. c[1])
			h.ok(not H.overlap(chip, H.roadBand(c[1], c[2])), "clear of the road band (the kart) at " .. c[1])
			if r.steerPad then
				h.ok(not H.overlap(chip, r.steerPad), "clear of the steer pad at " .. c[1])
				h.ok(not H.overlap(chip, r.autoPill), "clear of the AUTO pill at " .. c[1])
			end
			h.ok(chip.x + chip.w <= c[1] * 0.5, "left half only at " .. c[1])
		end
		local roomy = R.chipRect({ x = 10, y = 10, w = 44, h = 44 }, { x = 10, y = 60, w = 100, h = 30 }, { x = 300, y = 10, w = 200, h = 80 })
		h.eq(roomy.x, 60)
		h.eq(roomy.y, 10)
		local tight = R.chipRect({ x = 10, y = 10, w = 44, h = 44 }, { x = 10, y = 60, w = 100, h = 30 }, { x = 60, y = 10, w = 200, h = 80 })
		h.eq(tight.x, 10)
		h.eq(tight.y, 96)
	end)

	h.test("tips: each appears once, only in a race, only while the guide runs", function()
		local st = R.newState(true)
		h.eq(R.onEvent(st, "item", "hub"), nil, "no items in the hub")
		h.eq(R.onEvent(st, "item", "race"), "item")
		h.eq(R.onEvent(st, "item", "race"), nil, "second pickup is silent")
		h.eq(R.onEvent(st, "pad", "race"), "boost")
		h.eq(R.onEvent(st, "drift", "race"), "drift")
		h.eq(R.onEvent(st, "pad", "race"), nil)
		h.eq(R.onEvent(st, "unknown", "race"), nil)
		h.eq(R.onEvent(R.newState(false), "item", "race"), nil, "onboarded players get no tips")
	end)

	h.test("tips: the lap tip needs a finished lap with laps still to fly", function()
		local st = R.newState(true)
		h.eq(R.onEvent(st, "lap", "race", 1, 3), nil, "lap 1 is the start, not a lap done")
		h.eq(R.onEvent(st, "lap", "race", 2, 3), "lap")
		local st2 = R.newState(true)
		h.eq(R.onEvent(st2, "lap", "race", 4, 3), nil, "nothing left after the last lap")
		h.eq(R.lapsLeft(2, 3), 2)
		h.eq(R.lapsLeft(3, 3), 1)
		h.eq(R.lapsLeft(nil, 3), 0)
	end)

	h.test("replay: the ? button runs the whole guide again, even for an onboarded player", function()
		local st = R.newState(false)
		R.replay(st)
		h.eq(st.guideOn, true)
		h.eq(R.onEvent(st, "item", "race"), "item")
		st.goalShown = true
		st.portalDone = true
		R.replay(st)
		h.eq(R.onEvent(st, "item", "race"), "item", "shown tips are forgotten")
		h.eq(R.goalDue(st, "hub", true), true)
		h.eq(R.arrowOn(st, "hub", true), true)
	end)

	h.test("portal: the arrow points at the first open race portal (DINO first), never the hub", function()
		local rows = {
			{ id = "DINO-4", zone = "DINO", open = true },
			{ id = "SNOW-1", zone = "SNOW", open = false },
			{ id = "HUB-0", zone = "HUB", open = true },
		}
		h.eq((R.firstOpenPortal(rows) :: any).zone, "DINO")
		rows[1].open = false
		h.eq(R.firstOpenPortal(rows), nil, "the hub's final boss is not a portal to point at")
		rows[2].open = true
		h.eq((R.firstOpenPortal(rows) :: any).zone, "SNOW")
		h.eq(R.firstOpenPortal({}), nil)
		h.eq(R.firstOpenPortal({ "junk", 5 }), nil)
	end)

	h.test("arrow maths: unit direction on the ground, floats ahead 9 to 15 studs, fades inside 30 studs", function()
		local dx, dz, d = R.groundDir(0, 0, 30, 40)
		h.eq(d, 50)
		h.ok(math.abs(dx - 0.6) < 1e-9 and math.abs(dz - 0.8) < 1e-9)
		local zx, zz, zd = R.groundDir(5, 5, 5, 5)
		h.eq({ zx, zz, zd }, { 0, 0, 0 })
		h.eq(R.arrowAhead(10), 9)
		h.eq(R.arrowAhead(30), 12)
		h.eq(R.arrowAhead(500), 15)
		h.eq(R.arrowAlpha(10), 0)
		h.eq(R.arrowAlpha(30), 0)
		h.eq(R.arrowAlpha(45), 0.5)
		h.eq(R.arrowAlpha(90), 1)
	end)

	------------------------------------------------------------------------------------------------ funnels

	local function newRecorder(): any
		local rec: any = { onboarding = {}, funnel = {}, custom = {}, ids = 0 }
		local sink = {
			onboarding = function(player: any, step: number, name: string, fields: any)
				table.insert(rec.onboarding, { player = player, step = step, name = name, fields = fields })
			end,
			funnel = function(player: any, funnel: string, session: string, step: number, name: string, fields: any)
				table.insert(rec.funnel, { player = player, funnel = funnel, session = session, step = step, name = name, fields = fields })
			end,
			custom = function(player: any, name: string, value: number, fields: any)
				table.insert(rec.custom, { player = player, name = name, value = value })
			end,
		}
		rec.tracker = R.newTracker(sink, function(): string
			rec.ids += 1
			return "sess" .. tostring(rec.ids)
		end)
		return rec
	end

	local function steps(list: { any }): { number }
		local out = {}
		for _, e in list do
			table.insert(out, e.step)
		end
		return out
	end

	local DINO = R.fields("DINO-4", "race", "portal")

	h.test("funnel: a first session logs steps 1 to 7 in order, each once", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, true)
		rec.tracker.moved(p)
		rec.tracker.moved(p)
		rec.tracker.pick(p, DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.go(p, DINO)
		rec.tracker.finish(p, DINO, true)
		rec.tracker.next(p, "hub", DINO)
		rec.tracker.pick(p, DINO) -- second race
		rec.tracker.countdown(p, DINO)
		rec.tracker.go(p, DINO)
		rec.tracker.go(p, DINO) -- a third race must not log step 7 again
		h.eq(steps(rec.onboarding), { 1, 2, 3, 4, 5, 6, 7 })
		local names = {}
		for _, e in rec.onboarding do
			table.insert(names, e.name)
		end
		h.eq(names, { "joined", "first_move", "reached_portal", "race_started", "first_finish", "first_token", "second_race" })
	end)

	h.test("funnel: a returning player (not the first session) logs no onboarding steps but the race funnel runs", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, false)
		rec.tracker.moved(p)
		rec.tracker.pick(p, DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.go(p, DINO)
		rec.tracker.finish(p, DINO, true)
		h.eq(#rec.onboarding, 0)
		h.eq(steps(rec.funnel), { 1, 2, 3 })
	end)

	h.test("funnel: no token, no step 6; a finish without a pick is still step 5", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, true)
		rec.tracker.countdown(p, DINO)
		rec.tracker.go(p, DINO)
		rec.tracker.finish(p, DINO, false)
		h.eq(steps(rec.onboarding), { 1, 4, 5 })
	end)

	h.test("funnel: the race funnel is pick, countdown, finish, next with one session id per race", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, false)
		rec.tracker.pick(p, DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.finish(p, DINO, false)
		rec.tracker.next(p, "again", DINO)
		rec.tracker.next(p, "hub", DINO) -- dedupe
		h.eq(steps(rec.funnel), { 1, 2, 3, 4 })
		h.eq(rec.funnel[1].funnel, "race")
		h.eq(rec.funnel[4].fields.detail, "again")
		for _, e in rec.funnel do
			h.eq(e.session, "sess1")
		end
	end)

	h.test("funnel: FLY AGAIN starts a new race session with no pick", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, false)
		rec.tracker.pick(p, DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.finish(p, DINO, false)
		rec.tracker.next(p, "again", DINO)
		rec.tracker.countdown(p, DINO) -- the replay
		rec.tracker.finish(p, DINO, false)
		h.eq(steps(rec.funnel), { 1, 2, 3, 4, 2, 3 })
		h.eq(rec.funnel[5].session, "sess2")
	end)

	h.test("funnel: a finished race that ends on the automatic return logs next=auto; a quit mid-race logs nothing more", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, false)
		rec.tracker.pick(p, DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.finish(p, DINO, false)
		rec.tracker.pick(p, DINO) -- the next race, no vote between
		h.eq(steps(rec.funnel), { 1, 2, 3, 4, 1 })
		h.eq(rec.funnel[4].fields.detail, "auto")
		rec.tracker.countdown(p, DINO)
		rec.tracker.pick(p, DINO) -- abandoned before the finish: no step 4
		h.eq(steps(rec.funnel), { 1, 2, 3, 4, 1, 2, 1 })
	end)

	h.test("funnel: a next without a finish is not part of the funnel", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, false)
		rec.tracker.pick(p, DINO)
		rec.tracker.next(p, "hub", DINO)
		rec.tracker.countdown(p, DINO)
		rec.tracker.next(p, "hub", DINO)
		h.eq(steps(rec.funnel), { 1, 2 })
	end)

	h.test("funnel: players are tracked apart, and an unknown player logs nothing", function()
		local rec = newRecorder()
		local a, b, c = {}, {}, {}
		rec.tracker.begin(a, true)
		rec.tracker.begin(b, true)
		rec.tracker.moved(a)
		rec.tracker.moved(c)
		rec.tracker.pick(c, DINO)
		h.eq(#rec.onboarding, 3)
		h.eq(rec.onboarding[3].player, a)
		rec.tracker.forget(a)
		rec.tracker.moved(a)
		h.eq(#rec.onboarding, 3, "a player who left logs nothing")
		h.eq(rec.tracker.known(b), true)
		h.eq(rec.tracker.known(a), false)
	end)

	h.test("funnel: custom events pass sane numbers only", function()
		local rec = newRecorder()
		local p = {}
		rec.tracker.begin(p, true)
		rec.tracker.custom(p, R.EVENT_PROFILE_LOAD, 1.25)
		rec.tracker.custom(p, R.EVENT_READY, 0 / 0)
		rec.tracker.custom(p, R.EVENT_READY, -3)
		rec.tracker.custom(p, R.EVENT_READY, 2e9)
		rec.tracker.custom(p, R.EVENT_READY, "5" :: any)
		h.eq(#rec.custom, 1)
		h.eq(rec.custom[1].name, "profile_load_seconds")
	end)

	h.test("fields: only ids and words get through; no names, no free text, at most three fields", function()
		local f = R.fields("DINO-4", "race", "portal")
		h.eq(f, { track = "DINO-4", mode = "race", detail = "portal" })
		local dirty = R.fields("Retro 123 <script>", string.rep("x", 90), 42)
		h.eq(dirty.track, "Retro_123__script_")
		h.eq(#(dirty.mode :: string), 40)
		h.eq(dirty.detail, nil)
		h.eq(R.fields("", nil, nil), {})
	end)

	------------------------------------------------------------------------------------------------ saved flag

	local function newService(): any
		local sched = h.newScheduler()
		local svc = SaveService.new({
			store = SaveService.newMemoryStore({}),
			sessionId = "server-A",
			newToken = function(): string
				return "tok"
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function() end,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0 },
		})
		return { sched = sched, svc = svc }
	end

	h.test("flag: a new account is not onboarded; the flag lives in settings and the Onboarded attribute follows it", function()
		local env = newService()
		local p = h.fakePlayer(4242)
		env.sched.run(function()
			return env.svc.load(p)
		end)
		h.eq(p:GetAttribute("Onboarded"), false)
		h.eq(SaveService.isOnboarded(env.svc.get(p)), false)
		h.ok(env.svc.edit(p, "onboarded", function(profile: any)
			profile.settings[R.FLAG] = true
		end))
		h.eq(p:GetAttribute("Onboarded"), true)
		h.eq(SaveService.isOnboarded(env.svc.get(p)), true)
		h.eq(SaveService.isOnboarded(nil), false)
	end)

	h.test("flag: it survives a rejoin and never touches progression", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local function service(session: string): any
			return SaveService.new({
				store = SaveService.newMemoryStore(backing),
				sessionId = session,
				newToken = function(): string
					return session .. "-tok"
				end,
				now = sched.clock,
				clock = sched.clock,
				sleep = sched.sleep,
				spawn = sched.spawn,
				log = function() end,
				random = function(): number
					return 0.5
				end,
				config = { writeCooldown = 0 },
			})
		end
		local a = service("server-A")
		local p = h.fakePlayer(4343)
		sched.run(function()
			return a.load(p)
		end)
		h.ok(a.edit(p, "onboarded", function(profile: any)
			profile.settings[R.FLAG] = true
		end))
		p:leave()
		sched.run(function()
			return a.release(p)
		end)
		local b = service("server-B")
		local p2 = h.fakePlayer(4343)
		local profile = sched.run(function()
			return b.load(p2)
		end)
		h.eq(profile.settings[R.FLAG], true)
		h.eq(p2:GetAttribute("Onboarded"), true)
		h.eq(profile.tokens, {})
	end)

	------------------------------------------------------------------------------------------------ safe area

	h.test("safe area: a notch phone gives its device insets, rounded and clamped", function()
		-- 844x390 landscape: notch left 47, home bar bottom 21.
		local i = S.fromRect(844, 390, 47, 0, 844 - 47, 390 - 21)
		h.eq(i, { left = 47, top = 0, right = 47, bottom = 21 })
		h.eq(S.compute(844, 390, i, false), { left = 47, top = 0, right = 47, bottom = 21 })
	end)

	h.test("safe area: nonsense readings (NaN, negative, absurdly large) never eat the screen", function()
		local i = S.fromOffsets(740, 360, 0 / 0, -5, "x", 9999)
		h.eq(i.left, 0)
		h.eq(i.top, 0)
		h.eq(i.right, 0)
		h.eq(i.bottom, 72, "capped at 20 percent of the short side")
		h.eq(S.fromRect(740, 360, 0, 0, 740, 360), { left = 0, top = 0, right = 0, bottom = 0 })
	end)

	h.test("safe area: a ten-foot interface keeps 5 percent on every edge at 1920x1080 (L82)", function()
		h.eq(S.compute(1920, 1080, nil, true), { left = 96, top = 54, right = 96, bottom = 54 })
		h.eq(S.compute(1920, 1080, nil, false), { left = 0, top = 0, right = 0, bottom = 0 })
	end)

	h.test("safe area: the bigger of the device inset and the TV inset wins", function()
		local device = { left = 120, top = 10, right = 0, bottom = 80 }
		h.eq(S.compute(1920, 1080, device, true), { left = 120, top = 54, right = 96, bottom = 80 })
	end)

	h.test("safe area: equal compares all four edges", function()
		h.ok(S.equal({ left = 1, top = 2, right = 3, bottom = 4 }, { left = 1, top = 2, right = 3, bottom = 4 }))
		h.ok(not S.equal({ left = 1, top = 2, right = 3, bottom = 4 }, { left = 1, top = 2, right = 3, bottom = 5 }))
	end)

	------------------------------------------------------------------------------------------------ wiring (static)

	h.test("wiring: Funnels is server-side only, pcall-wrapped, and keeps names and ids out of its events", function()
		local src = h.readFile("src/server/Funnels.luau")
		h.contains(src, "LogOnboardingFunnelStepEvent")
		h.contains(src, "LogFunnelStepEvent")
		h.contains(src, "LogCustomEvent")
		h.contains(src, "pcall")
		h.ok(not string.find(src, "DisplayName", 1, true), "no display names in events")
		for _, f in { "src/client/Onboarding.luau", "src/client/SafeArea.luau" } do
			local client = h.readFile(f)
			h.ok(not string.find(client, "AnalyticsService", 1, true), f .. " never logs analytics")
		end
	end)

	h.test("wiring: the client asks the server nothing it could use to award; the flag is set server-side", function()
		local client = h.readFile("src/client/Onboarding.luau")
		h.ok(not string.find(client, "markOnboarded", 1, true))
		h.ok(not string.find(client, "SaveService", 1, true))
		local server = h.readFile("src/server/Funnels.luau")
		h.contains(server, "markOnboarded")
	end)

	h.test("wiring: the HUD ScreenGui stays full-bleed and the layout takes the safe-area insets", function()
		local race = h.readFile("src/client/RaceUI.luau")
		-- HUD layout v2: client/HudMetrics folds SafeArea (and the Roblox nav reserve) into one rect table the HUD consumes.
		h.contains(race, "HudMetrics")
		h.contains(race, "ScreenInsets.None")
		h.contains(race, "snap.insets")
		h.contains(h.readFile("src/client/HudMetrics.luau"), "SafeArea.get()")
		local extras = h.readFile("src/client/HudExtras.luau")
		h.contains(extras, "l.rects")
		local flow = h.readFile("src/client/TrackFlow.luau")
		h.contains(flow, "SafeArea")
		h.contains(flow, "Onboarding")
	end)

	h.test("wiring: the guide holds, retires, lands in a ring, glows the arch and floats a gem, with no tall beam", function()
		local client = h.readFile("src/client/Onboarding.luau")
		h.contains(client, "holdReason")
		h.contains(client, "LobbyGoAt")
		h.contains(client, "shouldRetireForRace")
		h.contains(client, "watchPlaza")
		h.contains(client, "OnboardingRules.surface")
		h.contains(client, "chipTap")
		h.contains(client, "GuideDiamond")
		h.contains(client, "RimPost")
		h.contains(client, "PORTAL_COLORS")
		h.contains(client, "\"confirm\"")
		h.contains(client, "\"confetti\"")
		h.ok(not string.find(client, "Instance.new(\"Beam\")", 1, true), "no beam")
		h.ok(not string.find(client, "BEACON", 1, true), "the beacon is gone")
		h.ok(not string.find(client, "PartType.Cylinder", 1, true), "no cylinder beacon")
		-- nothing the guide draws may collide, be touched, be hit by a ray or cast a shadow (the camera and the car ignore it)
		local wp = string.match(client, "local function worldPart.-\nend\n")
		h.ok(wp ~= nil, "worldPart found")
		for _, needle in { "CanCollide = false", "CanQuery = false", "CanTouch = false", "CastShadow = false" } do
			h.contains(wp :: string, needle)
		end
		-- the Storm match is the one race that must not retire the guide in the RaceMode signal either
		h.contains(client, "OnboardingRules.STORM_MODE")
		h.contains(h.readFile("src/client/TrackFlow.luau"), "Onboarding.event(\"portal\")")
		h.contains(h.readFile("src/server/StormCup.luau"), 'StormCup.MODE = "stormcup"')
		h.eq(R.STORM_MODE, "stormcup")
	end)

	h.test("Storm match does not mark players onboarded", function()
		h.eq(R.marksOnboarded("stormcup"), false)
		h.eq(R.marksOnboarded("race"), true)
		h.eq(R.marksOnboarded("battle"), true)
		local f = h.readFile("src/server/Funnels.luau")
		h.contains(f, "OnboardingRules.marksOnboarded(mode)")
	end)

	h.test("wiring: the boot scripts start the guide and the funnels", function()
		local client = h.readFile("src/shared/BootRules.luau") -- the client boot's order (audit T1-1)
		h.contains(client, '{ name = "Onboarding" }')
		local server = h.readFile("src/server/init.server.luau")
		h.contains(server, "Funnels")
		h.contains(h.readFile("src/server/TrackDirector.luau"), "funnelHook")
		h.contains(h.readFile("src/server/RaceManager.luau"), "funnelHook")
	end)

	h.test("hub declutter: no opaque ground arrow is ever built", function()
		local c = h.readFile("src/client/Onboarding.luau")
		h.ok(not string.find(c, 'worldPart("Arrow', 1, true), "no ArrowWing / ArrowOutline / ArrowShadow part is created")
		h.ok(not string.find(c, "ARROW_GOLD", 1, true), "no amber arrow colour")
	end)
end
