-- Starting grid order (shared/GridOrder, docs/design/GRID_ORDER.md): the weighted random first race, the solo
-- catch-up, the humans' reverse with its MAX_MOVE cap, bots filling the rest, late joiners in the rear half, exempt
-- modes on the fixed grid, the result harvest (DNF = last, leavers excluded) and the HUD line.
return function(h)
	local G = h.require("src/shared/GridOrder.luau")
	local FIELD = 8

	local function entrants(plan): { [number]: string }
		local bySlot: { [number]: string } = {}
		for uid, s in plan.humanSlots do
			h.ok(bySlot[s] == nil, "slot " .. s .. " held twice")
			bySlot[s] = "human" .. uid
		end
		for i, s in plan.botSlots do
			h.ok(bySlot[s] == nil, "slot " .. s .. " held twice (bot " .. i .. ")")
			bySlot[s] = "bot" .. i
		end
		return bySlot
	end

	h.test("slot 1 is the back of the grid: position 1 (pole) is the highest slot", function()
		h.eq(G.slotOf(1, 8), 8)
		h.eq(G.slotOf(8, 8), 1)
		h.eq(G.positionOf(G.slotOf(3, 8), 8), 3)
		-- adapt.py grid_slot: slot k sits at startGrid.station + ((k - 1) // 2) * rowSpacing, so stations rise with k.
		local function station(k: number): number
			return 18 + ((k - 1) // 2) * 14
		end
		for k = 2, 8 do
			h.ok(station(k) >= station(k - 1), "slot " .. k .. " not behind slot " .. (k - 1))
		end
		h.ok(station(G.slotOf(1, 8)) > station(G.slotOf(8, 8)), "pole further down the route than the back")
	end)

	h.test("every plan is a bijection onto the field, for 0..8 humans and any history", function()
		for humansN = 0, 8 do
			for seed = 1, 60 do
				local humans = {}
				for i = 1, humansN do
					humans[i] = { userId = 100 + i, lastPlace = if seed % 3 == 0 then nil else ((i + seed) % 8) + 1, lastGrid = ((i * 3 + seed) % 8) + 1 }
				end
				local bots = math.clamp(FIELD - math.max(humansN, 1), 0, 7)
				local plan = G.assign(humans, bots, FIELD, seed, "race", 0)
				local bySlot = entrants(plan)
				local n = 0
				for s in bySlot do
					h.ok(s >= 1 and s <= FIELD, "slot on the grid")
					n += 1
				end
				h.eq(n, humansN + bots, humansN .. " humans: every entrant seated")
				h.eq(plan.field, FIELD)
				for _, hm in humans do
					h.eq(plan.humanSlots[hm.userId], G.slotOf(plan.humanPositions[hm.userId], FIELD), "slot = field + 1 - position")
				end
			end
		end
	end)

	h.test("no human: the one open seat is the rearmost (slot 1), where the first joiner lands", function()
		for seed = 1, 20 do
			local plan = G.assign({}, 7, FIELD, seed, "race")
			local bySlot = entrants(plan)
			h.eq(bySlot[1], nil, "slot 1 open")
		end
	end)

	h.test("deterministic per seed, different across seeds", function()
		local humans = { { userId = 7 }, { userId = 3 }, { userId = 11 } }
		local a = G.assign(humans, 5, FIELD, 42, "race")
		local b = G.assign({ humans[3], humans[1], humans[2] }, 5, FIELD, 42, "race")
		h.eq(a, b, "same seed, any input order")
		local differs = false
		for seed = 43, 60 do
			if not differs and G.assign(humans, 5, FIELD, seed, "race").humanSlots[7] ~= a.humanSlots[7] then
				differs = true
			end
		end
		h.ok(differs, "seeds change the grid")
	end)

	h.test("solo first race: middle-weighted 5/10/15/20/20/15/10/5 over 10k seeds", function()
		local total = 0
		for p = 1, 8 do
			total += G.SOLO_WEIGHTS[p]
			h.eq(G.soloWeight(p, 8), G.SOLO_WEIGHTS[p])
		end
		h.eq(total, 100)
		local counts = { 0, 0, 0, 0, 0, 0, 0, 0 }
		local N = 10000
		for seed = 1, N do
			local plan = G.assign({ { userId = 1 } }, 7, FIELD, seed, "race")
			h.eq(plan.reasons[1], "random")
			local p = plan.humanPositions[1]
			counts[p] += 1
		end
		for p = 1, 8 do
			local share = counts[p] / N * 100
			h.ok(math.abs(share - G.SOLO_WEIGHTS[p]) < 1.5, string.format("position %d: %.1f%% vs %d%%", p, share, G.SOLO_WEIGHTS[p]))
		end
	end)

	h.test("solo race 2+: last place mirrored +-1, always in 2..7, never pole after a loss nor last after a win", function()
		for last = 1, 8 do
			local seen: { [number]: boolean } = {}
			for seed = 1, 2000 do
				local plan = G.assign({ { userId = 1, lastPlace = last } }, 7, FIELD, seed, "race")
				local p = plan.humanPositions[1]
				h.eq(plan.reasons[1], "catchup")
				h.eq(plan.lastPlaces[1], last)
				h.ok(p >= 2 and p <= 7, "clamped to 2..7, got " .. p)
				h.ok(math.abs(p - (9 - last)) <= 1 or p == 2 or p == 7, "mirror +-1")
				seen[p] = true
			end
			if last == 1 then
				h.eq(seen, { [7] = true }, "a win starts 7th (never last)")
			elseif last == 8 then
				h.eq(seen, { [2] = true }, "last place starts 2nd (never pole)")
			elseif last == 3 then
				h.eq(seen, { [5] = true, [6] = true, [7] = true }, "3rd -> 6th +-1")
			end
		end
	end)

	h.test("2+ humans race 1: a fair shuffle of all 8 positions", function()
		local counts = { 0, 0, 0, 0, 0, 0, 0, 0 }
		local N = 8000
		for seed = 1, N do
			local plan = G.assign({ { userId = 1 }, { userId = 2 } }, 6, FIELD, seed, "race")
			h.eq(plan.reasons[1], "random")
			counts[plan.humanPositions[1]] += 1
		end
		for p = 1, 8 do
			h.ok(math.abs(counts[p] / N - 1 / 8) < 0.02, "position " .. p .. " near 1/8")
		end
	end)

	h.test("2+ humans race 2+: winner furthest back among the humans, bots interleave", function()
		local humans = {
			{ userId = 1, lastPlace = 1 },
			{ userId = 2, lastPlace = 5 },
			{ userId = 3, lastPlace = 8 },
		}
		local interleaved = false
		for seed = 1, 500 do
			local plan = G.assign(humans, 5, FIELD, seed, "race", 0)
			local p = plan.humanPositions
			h.ok(p[3] < p[2] and p[2] < p[1], "reverse of the last finish (8th front, winner back)")
			for _, hm in humans do
				h.eq(plan.reasons[hm.userId], "reverse")
			end
			if p[1] - p[3] > 2 then
				interleaved = true
			end
		end
		h.ok(interleaved, "bots between the humans on some grids")
		h.eq(G.hudLine("reverse", 7, 1, 8), "WINNER STARTS LAST  -  YOU START 7TH")
	end)

	h.test("MAX_MOVE: nobody moves more than 4 positions from last race's grid", function()
		for seed = 1, 3000 do
			local humans = {
				{ userId = 1, lastPlace = 1, lastGrid = 1 }, -- won from pole: the reverse wants the back
				{ userId = 2, lastPlace = 2, lastGrid = 2 },
				{ userId = 3, lastPlace = 8, lastGrid = 8 }, -- last from the back: the reverse wants the front
				{ userId = 4, lastPlace = 7, lastGrid = 7 },
			}
			local plan = G.assign(humans, 4, FIELD, seed, "race", 0)
			entrants(plan)
			for _, hm in humans do
				local moved = math.abs(plan.humanPositions[hm.userId] - hm.lastGrid)
				h.ok(moved <= G.MAX_MOVE, string.format("seed %d user %d moved %d", seed, hm.userId, moved))
			end
		end
	end)

	h.test("more than 2 DNFs last race: the reverse is skipped (fresh shuffle)", function()
		local humans = { { userId = 1, lastPlace = 8 }, { userId = 2, lastPlace = 8 }, { userId = 3, lastPlace = 8 }, { userId = 4, lastPlace = 1 } }
		local plan = G.assign(humans, 4, FIELD, 9, "race", 3)
		for _, hm in humans do
			h.eq(plan.reasons[hm.userId], "random")
		end
		local kept = G.assign(humans, 4, FIELD, 9, "race", 2)
		h.eq(kept.reasons[4], "reverse")
	end)

	h.test("tie in last place (two DNFs): broken by a userId hash, stable within a race", function()
		local humans = { { userId = 10, lastPlace = 8 }, { userId = 20, lastPlace = 8 }, { userId = 30, lastPlace = 1 } }
		local frontCount = 0
		for seed = 1, 400 do
			local a = G.assign(humans, 5, FIELD, seed, "race", 2)
			local b = G.assign(humans, 5, FIELD, seed, "race", 2)
			h.eq(a.humanPositions, b.humanPositions, "stable per seed")
			local p = a.humanPositions
			h.ok(p[30] > p[10] and p[30] > p[20], "the winner behind both DNFs")
			h.eq(p[10] < p[20], G.tieKey(10, seed) < G.tieKey(20, seed), "tie order follows the hash")
			if p[10] < p[20] then
				frontCount += 1
			end
		end
		h.ok(frontCount > 100 and frontCount < 300, "neither DNF is always in front: " .. frontCount)
	end)

	h.test("a human with no result on this server mixes into the reverse order at random", function()
		local humans = { { userId = 1, lastPlace = 1 }, { userId = 2, lastPlace = 6 }, { userId = 3 } }
		for seed = 1, 100 do
			local plan = G.assign(humans, 5, FIELD, seed, "race", 0)
			h.eq(plan.reasons[3], "random")
			h.ok(plan.humanPositions[2] < plan.humanPositions[1], "the two with results still reversed")
		end
	end)

	h.test("bots: fastest at the front of what is left, a speed neighbour swap at most one place", function()
		local swapped = false
		for seed = 1, 400 do
			local plan = G.assign({ { userId = 1 } }, 7, FIELD, seed, "race")
			local hp = plan.humanPositions[1]
			local free = {}
			for p = 1, FIELD do
				if p ~= hp then
					table.insert(free, p)
				end
			end
			for i, s in plan.botSlots do
				local p = G.positionOf(s, FIELD)
				local idx = table.find(free, p) :: number
				h.ok(math.abs(idx - i) <= 1, "bot " .. i .. " within one place of its speed rank")
				if idx ~= i then
					swapped = true
				end
			end
		end
		h.ok(swapped, "the 3rd-fastest sometimes starts ahead of the 2nd")
	end)

	h.test("row-mates fan outward: the larger lane offset takes the right (even) seat", function()
		local lanes = { 6, -6, 0, -12, 9, -9, 12 }
		h.eq(G.fanRowMates({ 7, 8 }, { 6, -6 }), { 8, 7 }, "swap when the left seat has the right-hand lane")
		h.eq(G.fanRowMates({ 8, 7 }, { 6, -6 }), { 8, 7 }, "already fanned")
		h.eq(G.fanRowMates({ 8, 7, 6, 5, 4, 3, 2 }, lanes), { 8, 7, 6, 5, 4, 3, 2 }, "the old fixed grid is already fanned")
		for seed = 1, 200 do
			local plan = G.assign({ { userId = 1 } }, 7, FIELD, seed, "race")
			local fanned = G.fanRowMates(plan.botSlots, lanes)
			local bySlot = {}
			for i, s in fanned do
				bySlot[s] = i
			end
			for row = 0, 3 do
				local l, r = bySlot[2 * row + 1], bySlot[2 * row + 2]
				if l and r then
					h.ok(lanes[r] >= lanes[l], "row " .. row .. " fanned")
				end
			end
			local sorted, orig = table.clone(fanned), table.clone(plan.botSlots)
			table.sort(sorted)
			table.sort(orig)
			h.eq(sorted, orig, "same seats")
		end
	end)

	h.test("late joiner: a random rear-half seat, empty before a bot's, never a human's", function()
		local seen: { [number]: boolean } = {}
		for seed = 1, 300 do
			-- Solo race grid: the human at slot 6, bots everywhere else.
			local humanHeld = { [6] = true }
			local botHeld = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [7] = true, [8] = true }
			local s, p = G.lateJoinSlot(humanHeld, botHeld, FIELD, seed)
			h.ok(s >= 1 and s <= 4, "rear half (slots 1..4)")
			h.eq(p, 9 - s)
			seen[s] = true
		end
		h.eq(seen, { [1] = true, [2] = true, [3] = true, [4] = true }, "any rear seat")
		h.eq(G.lateJoinSlot({ [2] = true }, { [1] = true, [4] = true }, FIELD, 5) == 3, true, "the empty rear seat first")
		local s = G.lateJoinSlot({ [1] = true, [2] = true, [3] = true, [4] = true }, {}, FIELD, 1)
		h.ok(s >= 5 and s <= 8, "rear half full of humans: a front seat")
		local all = {}
		for i = 1, 8 do
			all[i] = true
		end
		h.eq(G.lateJoinSlot(all, {}, FIELD, 1), 9, "a full grid wraps past the field")
		h.eq(G.hudLine("late", 6, nil, 8), "LATE START  -  6TH OF 8")
	end)

	h.test("boss / rematch / time trial / battle / hub: the fixed grid, humans from slot 1", function()
		for _, mode in { "boss", "rematch", "timetrial", "battle", "hub" } do
			h.ok(not G.isGridded(mode), mode .. " exempt")
			local plan = G.assign({ { userId = 5, lastPlace = 1 } }, if mode == "boss" or mode == "rematch" then 1 else 0, FIELD, 3, mode)
			h.ok(plan.exempt)
			h.eq(plan.humanSlots[5], 1, mode .. ": slot 1")
			h.eq(plan.reasons[5], "fixed")
			h.eq(G.hudLine(plan.reasons[5], plan.humanPositions[5], nil, plan.field), "", "no HUD line")
		end
		local two = G.assign({ { userId = 9 }, { userId = 4 } }, 0, FIELD, 3, "hub")
		h.eq(two.humanSlots, { [4] = 1, [9] = 2 }, "hub: by userId, not pairs() order")
		h.eq(G.assign({ { userId = 1 } }, 1, FIELD, 3, "boss").botSlots, { 2 }, "the boss bot after the player")
		for _, mode in { "race", "quickrace", "stormcup", "coin" } do
			h.ok(G.isGridded(mode), mode .. " gridded")
		end
		h.ok(G.isGridded(nil), "no RaceMode = standard race")
	end)

	h.test("harvest: finishers keep their place, a DNF is last, leavers and unfinished are excluded", function()
		local hist, dnf = G.harvest({
			{ userId = 1, finished = true, rank = 3, grid = 5 },
			{ userId = 2, finished = false, dnf = true, grid = 2 },
			{ userId = 3, finished = false }, -- quit to the hub before the finish: no entry, no front seat
		}, FIELD)
		h.eq(hist, { [1] = { place = 3, grid = 5 }, [2] = { place = 8, grid = 2 } })
		h.eq(dnf, 1)
	end)

	h.test("HUD lines: the doc's three examples and ordinals", function()
		h.eq(G.hudLine("random", 4, nil, 8), "START 4TH OF 8")
		h.eq(G.hudLine("catchup", 3, 6, 8), "START 3RD  -  LAST RACE 6TH")
		h.eq(G.hudLine("reverse", 7, nil, 8), "WINNER STARTS LAST  -  YOU START 7TH")
		h.eq(G.hudLine("catchup", 2, nil, 8), "", "catch-up needs the last place")
		h.eq(G.hudLine(nil, 2, nil, 8), "")
		h.eq({ G.ordinal(1), G.ordinal(2), G.ordinal(3), G.ordinal(4), G.ordinal(11), G.ordinal(12), G.ordinal(13), G.ordinal(21), G.ordinal(22) },
			{ "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd" })
		h.ok(not G.hudVisible(3.2) and G.hudVisible(3.0) and G.hudVisible(0.6) and not G.hudVisible(0.5), "2.5 s, ending before GO")
	end)

	h.test("plankText: grid seat before GO, never 1/1; live rank/total from GO", function()
		h.eq(G.plankText(false, 1, 1, 6, 8, 8), "6/8", "seat of the field")
		h.eq(G.plankText(false, 1, 1, nil, nil, 8), "\u{2013}/8", "unknown seat: neutral dash over the fallback field")
		h.eq(G.plankText(false, 1, 5, nil, nil, 8), "\u{2013}/5", "no GridField: the standings count when it is a field")
		h.eq(G.plankText(false, 1, 1, 3, 4, 8), "3/4")
		h.eq(G.plankText(false, 1, 1, 9, 8, 8), "\u{2013}/8", "a seat outside the field is not shown")
		h.eq(G.plankText(true, 3, 8, 6, 8, 8), "3/8", "from GO the live rank")
	end)
end
