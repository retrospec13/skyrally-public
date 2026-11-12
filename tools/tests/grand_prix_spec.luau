-- Grand Prix rules (shared/GrandPrixRules, v37): points, standings across races, class unlocks, track picks, payout,
-- the saved record (never lowered) and its replicated encoding.
return function(h)
	local R = h.require("src/shared/GrandPrixRules.luau")

	h.test("points: 15 12 10 8 6 4 2 1; DNF and 9th+ score 0", function()
		h.eq(R.pointsFor(1), 15)
		h.eq(R.pointsFor(3), 10)
		h.eq(R.pointsFor(8), 1)
		h.eq(R.pointsFor(9), 0)
		h.eq(R.pointsFor(1, true), 0)
	end)

	h.test("apply: totals accumulate, ranks re-sort, prevRank and gained are per race", function()
		local r1 = R.apply(nil, {
			{ key = "u1", name = "me", human = true, place = 2, dnf = false },
			{ key = "b1", name = "a", human = false, place = 1, dnf = false },
			{ key = "b2", name = "b", human = false, place = 3, dnf = false },
		})
		h.eq(r1[1].key, "b1")
		h.eq(r1[2].key, "u1")
		h.eq(r1[2].total, 12)
		h.eq(r1[2].prevRank, 0)
		local byKey = {}
		for _, r in r1 do
			byKey[r.key] = r
		end
		local r2 = R.apply(byKey, {
			{ key = "u1", name = "me", human = true, place = 1, dnf = false },
			{ key = "b2", name = "b", human = false, place = 2, dnf = false },
			{ key = "b1", name = "a", human = false, place = 3, dnf = true },
		})
		h.eq(r2[1].key, "u1", "12+15 = 27 leads")
		h.eq(r2[1].total, 27)
		h.eq(r2[1].prevRank, 2)
		h.eq(r2[1].gained, 15)
		local a = r2[3]
		h.eq(a.key, "b1")
		h.eq(a.gained, 0)
		h.ok(a.dnf)
		h.eq(r2[2].total, 22, "b: 10+12")
	end)

	h.test("apply: a tie goes to the better place in the latest race", function()
		local prev = {
			x = { key = "x", name = "x", human = false, total = 15, gained = 0, place = 0, rank = 1, prevRank = 0, dnf = false },
			y = { key = "y", name = "y", human = false, total = 18, gained = 0, place = 0, rank = 2, prevRank = 0, dnf = false },
		}
		local out = R.apply(prev, {
			{ key = "x", name = "x", human = false, place = 2, dnf = false }, -- 15 + 12 = 27
			{ key = "y", name = "y", human = false, place = 3, dnf = false }, -- 18 + 10 = 28
		})
		h.eq(out[1].key, "y")
		local tie = R.apply({
			x = { key = "x", name = "x", human = false, total = 10, gained = 0, place = 0, rank = 1, prevRank = 0, dnf = false },
			y = { key = "y", name = "y", human = false, total = 13, gained = 0, place = 0, rank = 2, prevRank = 0, dnf = false },
		}, {
			{ key = "x", name = "x", human = false, place = 2, dnf = false }, -- 22
			{ key = "y", name = "y", human = false, place = 3, dnf = false }, -- 23
		})
		h.eq(tie[1].key, "y")
	end)

	h.test("classes: ROOKIE open; PRO after any ROOKIE trophy; MASTER after a PRO gold", function()
		local rec = R.defaults()
		h.ok(R.classOpen(rec, "rookie"))
		h.ok(not R.classOpen(rec, "pro"))
		rec.best.rookie = 1
		h.ok(R.classOpen(rec, "pro"))
		rec.best.pro = 2
		h.ok(not R.classOpen(rec, "master"))
		rec.best.pro = 3
		h.ok(R.classOpen(rec, "master"))
		h.ok(not R.classOpen(rec, "nope"))
	end)

	h.test("tracks: at least 3 open; full = every open one in zone order; short = 3 of them in zone order", function()
		h.eq(#R.lengths(2), 0)
		h.eq(R.lengths(3), { "full" })
		h.eq(R.lengths(5), { "short", "full" })
		h.eq(R.pickTracks({ "DINO-4", "SNOW-1" }, "full", math.random), nil)
		local all = R.openTracks({ ["SPACE-4"] = true, ["DINO-4"] = true, ["SNOW-1"] = true, ["ISLAND-2"] = true, ["FOREST-1"] = true })
		h.eq(all, { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" })
		h.eq(R.pickTracks(all, "full", math.random), all)
		local seq = { 0.9, 0.1, 0.5 }
		local i = 0
		local short = R.pickTracks(all, "short", function()
			i += 1
			return seq[i]
		end) :: { string }
		h.eq(#short, 3)
		local last = 0
		for _, id in short do
			local at = table.find(all, id) :: number
			h.ok(at > last, "zone order")
			last = at
		end
	end)

	h.test("payout: class bonus x place share x races / 5; nothing under 3 races", function()
		h.eq(R.payout("rookie", 1, 5), 150)
		h.eq(R.payout("master", 1, 5), 400)
		h.eq(R.payout("pro", 2, 5), 163)
		h.eq(R.payout("rookie", 1, 3), 90)
		h.eq(R.payout("rookie", 6, 5), 30)
		h.eq(R.payout("rookie", 1, 2), 0)
		h.eq(R.payout("nope", 1, 5), 0)
		h.eq(R.payout("rookie", 1, 5, 3), 150, "3 of 5 finished")
		h.eq(R.payout("rookie", 6, 5, 2), 0, "an idle cup pays nothing")
		h.eq(R.payout("rookie", 1, 3, 2), 90)
	end)

	h.test("record: best trophy and points only rise; opened classes reported once", function()
		local rec, opened = R.record(nil, "rookie", 1, 40)
		h.eq(rec.best.rookie, 1)
		h.eq(opened, { "pro" })
		local rec2, opened2 = R.record(rec, "rookie", 0, 20)
		h.eq(rec2.best.rookie, 1, "a worse cup keeps the bronze")
		h.eq(rec2.points.rookie, 40)
		h.eq(#opened2, 0)
		h.eq(rec2.cups, 2)
		local rec3, opened3 = R.record(rec2, "pro", 3, 60)
		h.eq(opened3, { "master" })
		h.eq(R.read({ best = { rookie = 9, pro = "x" } }).best.rookie, 3, "clamped")
		h.eq(R.read("junk").cups, 0)
		h.eq(R.decode(R.encode(rec3)).best.pro, 3)
		h.eq(R.decode(R.encode(rec3)).points.rookie, 40)
		h.eq(R.encode(R.defaults()), "0,0,0;0,0,0")
		h.eq(R.decode(nil).best.master, 0)
	end)
end
