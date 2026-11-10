-- Finish payoffs (REMARKABLE Batch 2 items 23, 24, 27, 30; shared/FinaleRules): who gets a photo-finish polaroid and
-- what it says, when the local photo cam may take over, the podium pick and the Participation Crate (never a new
-- reward: only the server's Gears or a cardboard medal), the skip rule, the token's arc, the portal-wake diff and the
-- turntable's spin. Plus a static check that the server half only reads the finish order and sends a notice.
return function(h)
	local R = h.require("src/shared/FinaleRules.luau")

	local function entry(name: string, isPlayer: boolean, time: number, rank: number)
		return { name = name, isPlayer = isPlayer, time = time, rank = rank }
	end

	h.test("photoNotices: a player edging a bot by 0.12 s gets one notice, won = true", function()
		local order = { entry("Ana", true, 101.30, 1), entry("Pip", false, 101.42, 2) }
		local n = R.photoNotices(order, 2)
		h.eq(#n, 1)
		h.eq(n[1].name, "Ana")
		h.eq(n[1].rival, "Pip")
		h.eq(n[1].won, true)
		h.ok(math.abs(n[1].gap - 0.12) < 1e-9)
		h.eq(n[1].rivalIsPlayer, false)
	end)

	h.test("photoNotices: two players in a dead heat both get one (one won, one did not)", function()
		local order = { entry("Bot", false, 90, 1), entry("Ana", true, 95.00, 2), entry("Ben", true, 95.00, 3) }
		local n = R.photoNotices(order, 3)
		h.eq(#n, 2)
		h.eq(n[1].name, "Ana")
		h.eq(n[1].won, true)
		h.eq(n[2].name, "Ben")
		h.eq(n[2].won, false)
		h.eq(n[2].rivalRank, 2)
	end)

	h.test("photoNotices: nothing for bot pairs, wide gaps, the first finisher or a bad order", function()
		h.eq(#R.photoNotices({ entry("A", false, 1, 1), entry("B", false, 1.1, 2) }, 2), 0, "bots only")
		h.eq(#R.photoNotices({ entry("A", true, 1, 1), entry("B", false, 1.6, 2) }, 2), 0, "0.6 s is not close")
		h.eq(#R.photoNotices({ entry("A", true, 1, 1) }, 1), 0, "nobody before the winner")
		h.eq(#R.photoNotices({ entry("A", true, 2, 1), entry("B", true, 1, 2) }, 2), 0, "negative gap")
		h.eq(#R.photoNotices({ entry("A", true, 1, 1), entry("B", false, 1.5, 2) }, 2), 1, "exactly the window counts")
	end)

	h.test("photoVerdict and caption: the closer, the bigger the word; kind either way", function()
		h.eq(R.photoVerdict(0), "DEAD HEAT!")
		h.eq(R.photoVerdict(0.03), "BY A WHISKER!")
		h.eq(R.photoVerdict(0.1), "BY A NOSE!")
		h.eq(R.photoVerdict(0.2), "BY A BUMPER!")
		h.eq(R.photoVerdict(0.45), "PHOTO FINISH!")
		h.eq(R.photoCaption(true, 0.08, "Pip"), "You pipped Pip by 0.08 s")
		h.eq(R.photoCaption(false, 0.004, "Pip"), "You and Pip - a hair's breadth!")
		h.eq(R.photoCaption(false, 0.001 + 0.2, "Pip"), "Pip got there by 0.20 s - so close!")
		for _, won in { true, false } do
			local c = string.lower(R.photoCaption(won, 0.3, "Pip"))
			h.ok(not string.find(c, "%f[%a]lose") and not string.find(c, "loser", 1, true), "no loser wording")
		end
	end)

	h.test("photoStage: the server gap at the finisher's speed, kept inside the frame", function()
		h.ok(math.abs(R.photoStage(0.05, 100) - 5) < 1e-9)
		h.eq(R.photoStage(0.001, 100), 0.6)
		h.eq(R.photoStage(0.4, 128), 12)
	end)

	h.test("shouldTakeover: the racer ahead within 0.6 s, or a car behind within 0.6 s at my speed", function()
		h.eq(R.shouldTakeover(0.3, nil, 100), true)
		h.eq(R.shouldTakeover(0.9, nil, 100), false)
		h.eq(R.shouldTakeover(nil, 40, 100), true, "40 studs at 100/s is 0.4 s")
		h.eq(R.shouldTakeover(nil, 90, 100), false)
		h.eq(R.shouldTakeover(nil, 5, 0), false, "standing still: no estimate")
	end)

	h.test("aheadGap: read from the RaceFinished standings (server finish times)", function()
		local st = {
			{ rank = 1, name = "Pip", finished = true, finishTime = 100.0, isPlayer = false },
			{ rank = 2, name = "Ana", finished = true, finishTime = 100.25, isPlayer = true },
			{ rank = 3, name = "Bo", finished = false, finishTime = 0, isPlayer = false },
		}
		h.ok(math.abs((R.aheadGap(st, 2) :: number) - 0.25) < 1e-9)
		h.eq(R.aheadGap(st, 1), nil, "the winner has nobody ahead")
		h.eq(R.aheadGap(st, 4), nil)
	end)

	h.test("ceremony: race-like modes with three racers; the first one always plays, later ones skip", function()
		h.eq(R.ceremonyEligible("race", 8), true)
		h.eq(R.ceremonyEligible("boss", 8), true)
		h.eq(R.ceremonyEligible("stormcup", 8), true)
		h.eq(R.ceremonyEligible("battle", 4), false)
		h.eq(R.ceremonyEligible("timetrial", 1), false)
		h.eq(R.ceremonyEligible("hub", 8), false)
		h.eq(R.ceremonyEligible("race", 2), false)
		h.eq(R.canSkip(0), false)
		h.eq(R.canSkip(1), true)
		h.eq(R.CEREMONY_SECONDS, 4)
	end)

	h.test("podium: top three and me, on or off the podium", function()
		local st = {
			{ rank = 2, name = "Pip", isPlayer = false },
			{ rank = 1, name = "Ana", isPlayer = true },
			{ rank = 3, name = "Bo", isPlayer = false },
			{ rank = 6, name = "Me", isPlayer = true },
		}
		local p = R.podium(st, "Me")
		h.eq(p.first.name, "Ana")
		h.eq(p.second.name, "Pip")
		h.eq(p.third.name, "Bo")
		h.eq(p.me.rank, 6)
		h.eq(p.meOnPodium, false)
		h.eq(R.podium(st, "Ana").meOnPodium, true)
		h.eq(R.podium(st, "Pip").me, nil, "a bot with my name is not me")
	end)

	h.test("crateContents: the server's Gears when the Garage shows them, else a kind cardboard medal", function()
		h.eq(R.crateContents({ gears = 12 }, true, 6), { kind = "gears", text = "+12 CASH" })
		h.eq(R.crateContents({ gears = 12 }, false, 6).kind, "medal", "Garage hidden: no Gears talk")
		h.eq(R.crateContents(nil, true, 6).kind, "medal")
		h.eq(R.crateContents({ gears = 0 }, true, 6).kind, "medal")
		h.eq(R.crateContents(nil, false, 4).text, R.crateContents(nil, false, 4).text, "stable per rank")
		for rank = 1, 12 do
			local t = string.lower(R.crateContents(nil, false, rank).text)
			h.ok(not string.find(t, "%f[%a]lose"), "kind line at rank " .. rank)
		end
	end)

	h.test("tokenArc: starts and ends on the points and bows upward in between", function()
		local x0, y0 = R.tokenArc(100, 300, 400, 20, 0, 120)
		h.eq(x0, 100)
		h.eq(y0, 300)
		local x1, y1 = R.tokenArc(100, 300, 400, 20, 1, 120)
		h.ok(math.abs(x1 - 400) < 1e-9 and math.abs(y1 - 20) < 1e-9)
		local _, ym = R.tokenArc(100, 300, 400, 300, 0.5, 120)
		h.ok(ym < 300, "a level flight still arcs up")
	end)

	h.test("newlyOpened: open zones not yet seen open, in board order", function()
		local states = {
			{ zone = "DINO", open = true },
			{ zone = "SNOW", open = true },
			{ zone = "ISLAND", open = false },
			{ zone = "FOREST", open = true },
		}
		h.eq(R.newlyOpened({ DINO = true }, states), { "SNOW", "FOREST" })
		h.eq(R.newlyOpened({ DINO = true, SNOW = true, FOREST = true }, states), {})
	end)

	h.test("turnStep: a flick coasts back to the idle spin; dragging keeps the finger's speed", function()
		local a, v = 0, 600
		for _ = 1, 600 do
			a, v = R.turnStep(a, v, 1 / 60, false)
		end
		h.ok(math.abs(v - R.TURN_AUTO) < 1, "settles at the idle spin")
		h.ok(a >= 0 and a < 360)
		local _, v2 = R.turnStep(0, -300, 1 / 60, true)
		h.eq(v2, -300)
		local _, v3 = R.turnStep(0, 5000, 1 / 60, true)
		h.eq(v3, R.TURN_MAX, "capped")
		local _, v4 = R.turnStep(0, -400, 10, false)
		h.ok(math.abs(v4 + R.TURN_AUTO) < 1e-6, "a backwards flick idles backwards")
	end)

	h.test("revLevel: quick REVs climb to the limiter, a slow one starts over", function()
		h.eq(R.revLevel(nil, 10, 0), 1)
		h.eq(R.revLevel(9.7, 10, 1), 2)
		h.eq(R.revLevel(9.8, 10, 2), 3)
		h.eq(R.revLevel(9.9, 10, 3), 3)
		h.eq(R.revLevel(8, 10, 3), 1)
	end)

	h.test("static: the server photo finish only reads the finish order and sends a notice", function()
		local src = h.readFile("src/server/PhotoFinish.luau")
		h.contains(src, "RaceManager.finishOrder")
		h.contains(src, "\"PhotoFinish\"")
		for _, banned in { "award(", "SetAttribute(\"Gears", "SetAttribute(\"SkyTokens", "finishTime =", "table.insert(RaceManager" } do
			h.ok(not string.find(src, banned, 1, true), "server photo finish must not touch " .. banned)
		end
	end)

	h.test("livery palette moved to shared (the turntable paints its copy); the server kit re-exports it", function()
		local LiveryPaint = h.require("src/shared/LiveryPaint.luau")
		h.eq(type(LiveryPaint.apply), "function")
		h.eq(type(LiveryPaint.applyFor), "function")
		h.eq(type(LiveryPaint.slotFor), "function")
		local kit = h.readFile("src/server/kit/LiveryPaint.luau")
		h.contains(kit, 'WaitForChild("LiveryPaint")')
		h.ok(not string.find(kit, "function LiveryPaint", 1, true), "no second copy of the painter on the server")
		local turn = h.readFile("src/client/GarageTurntable.luau")
		h.contains(turn, 'Shared:WaitForChild("LiveryPaint")')
		h.ok(not string.find(turn, "FireServer", 1, true) and not string.find(turn, "InvokeServer", 1, true), "the toy never asks the server")
	end)
end
