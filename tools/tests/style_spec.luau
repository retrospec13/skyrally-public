--!strict
-- Lune spec for the style lane (REMARKABLE Batch 2 items 15, 16, 17) and the plane's course leash and alternate lines
-- (trap audit G5.4, G8):
--   CarConfig   the third drift tier (zone turbo): fair (pad boost speed and length, inside the bots' ring boost in
--               the field simulation, maxHorizontalSpeed unchanged), reached late, zone colours
--   StyleRules  the chain (points, variety rule, fuse, milestones and zone callouts, best, break), near-miss and
--               lava-skim classification
--   PlaneConfig leash weight, warn hysteresis and the 1.5 s auto-respawn past 380
--   RouteBranch nearest / pointAt / target, the enter-stay-leave rule, station stretches, and on the six launch maps'
--               real TrackData: every alternate point away from the main line picks its own line, no main-line point
--               picks one
-- Run: tools/tests/run_lune_tests.sh tools/tests/style_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local C = h.require("src/shared/CarConfig.luau")
	local P = h.require("src/shared/PlaneConfig.luau")
	local S = h.require("src/shared/StyleRules.luau")
	local R = h.require("src/shared/RouteBranch.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	-- ------------------------------------------------------------ item 15: the zone turbo
	h.test("zone turbo: third tier is the pad boost exactly, inside the bots' ring boost; top speed bound unchanged", function()
		local lv = C.DRIFT_LEVELS
		h.eq(#lv, 3, "three drift tiers")
		local z = lv[3]
		h.eq(z.boostSpeed, C.PAD_BOOST_SPEED, "tier 3 speed = pad boost (no new speed source)")
		h.eq(z.boostDuration, C.PAD_BOOST_DURATION, "tier 3 length = pad boost length (1.6 s)")
		h.ok(z.boostDuration <= P.BOOST_DURATION, "tier 3 <= the ring boost each bot takes in field_spec (1.8 s)")
		h.ok(z.boostDuration > lv[2].boostDuration and z.threshold > lv[2].threshold, "longer charge, longer boost than orange")
		h.eq(z.boostState, "Overcharge", "a Vfx/SoundJuice boost family")
		local expected = math.max(C.TOP_SPEED + C.SPEED_PICKUP_BONUS * C.MAX_SPEED_PICKUPS, C.PAD_BOOST_SPEED, C.ITEM_BOOST_MAX_SPEED) + C.MAGNET_MAX_BONUS
		h.eq(C.maxHorizontalSpeed(), expected, "validator bound is what it was without tier 3")
	end)

	h.test("zone turbo takes a long committed drift: ~1.8 s tight, ~3.1 s neutral (orange ~1.1 s tight)", function()
		local dt = 1 / 60
		local function timeTo(steer: number, level: number): number
			local charge, t = 0, 0
			while C.driftLevel(charge) < level and t < 10 do
				charge += C.driftChargeRate(steer, 1) * dt
				t += dt
			end
			return t
		end
		local tight3, neutral3, tight2 = timeTo(1, 3), timeTo(0, 3), timeTo(1, 2)
		h.ok(tight3 > 1.7 and tight3 < 1.95, string.format("tight %.2f s", tight3))
		h.ok(neutral3 > 3.0 and neutral3 < 3.2, string.format("neutral %.2f s", neutral3))
		h.ok(tight3 > tight2 + 0.6, "well after orange")
	end)

	h.test("zone turbo sparks take the zone colour; tiers 1-2 keep blue and orange; palettes agree", function()
		for zone, c in C.DRIFT_ZONE_COLORS do
			h.eq(C.driftColor(3, zone), c, "tier 3 in " .. zone)
			h.eq(S.ZONE_COLOR[zone], c, "chain meter palette matches the spark palette in " .. zone)
			h.eq(C.driftColor(1, zone), C.DRIFT_LEVELS[1].color, "tier 1 stays blue in " .. zone)
			h.eq(C.driftColor(2, zone), C.DRIFT_LEVELS[2].color, "tier 2 stays orange in " .. zone)
		end
		for _, zone in { "DINO", "SNOW", "ISLAND", "FOREST", "SPACE", "HUB" } do
			h.ok(C.DRIFT_ZONE_COLORS[zone] ~= nil, "a colour for " .. zone)
			h.ok(S.ZONE_CALLOUT[zone] ~= nil, "a callout for " .. zone)
		end
		h.eq(C.driftColor(3, nil), C.DRIFT_LEVELS[3].color, "no zone: the fallback violet")
		h.eq(C.driftColor(3, "MOON"), C.DRIFT_LEVELS[3].color, "unknown zone: the fallback")
		h.eq(C.driftColor(0, "DINO"), C.DRIFT_SMOKE_COLOR, "no level: smoke")
	end)

	-- ------------------------------------------------------------ item 17: the chain
	h.test("chain: points add, unknown moves are ignored, the fuse restarts on each move", function()
		local c = S.newChain()
		h.eq({ S.add(c, "Hop", "DINO") }, { 0, 0 }, "a hop alone is racing, not style")
		h.eq(c.count, 0)
		h.eq({ S.add(c, "NearMiss", "DINO") }, { 1, 0 })
		h.ok(near(c.timer, S.window(1)), "fuse set")
		S.tick(c, 1.0, false)
		h.eq({ S.add(c, "Drift3", "DINO") }, { 2, 1 }, "zone turbo is worth 2 and crosses NICE (3)")
		h.eq(c.count, 3)
		h.ok(near(c.timer, S.window(3)), "fuse restarted")
		h.ok(S.window(40) == S.WINDOW_MIN and S.window(0) == S.WINDOW, "fuse shortens with length, never below the minimum")
	end)

	h.test("chain milestones: NICE, the zone callout at 5, SUPER, MEGA, LEGEND and every 4 after", function()
		local c = S.newChain()
		local tiers = {}
		for _ = 1, 24 do
			-- Alternate two one-point moves so the variety rule never stalls the chain.
			local _, tier = S.add(c, if c.count % 2 == 0 then "Roll" else "NearMiss", "SNOW")
			if tier > 0 then
				table.insert(tiers, c.count .. ":" .. S.milestoneText(tier, "SNOW"))
			end
		end
		h.eq(tiers, { "3:NICE!", "5:ICE COLD!", "8:SUPER ICE COLD!", "12:MEGA ICE COLD!", "16:ICE COLD LEGEND!", "20:ICE COLD LEGEND!", "24:ICE COLD LEGEND!" })
		h.eq(S.milestoneText(2, "DINO"), "ERUPTION!")
		h.eq(S.milestoneText(2, "ISLAND"), "AHOY!")
		h.eq(S.milestoneText(2, "FOREST"), "GUST!")
		h.eq(S.milestoneText(2, "SPACE"), "ORBITAL!")
		h.eq(S.milestoneText(2, nil), S.DEFAULT_CALLOUT)
		h.eq(c.best, 24)
		h.eq(c.bestText, "ICE COLD LEGEND!")
	end)

	h.test("chain variety: the same move more than three times running stops counting until another move", function()
		local c = S.newChain()
		for i = 1, 3 do
			h.eq((S.add(c, "NearMiss", "HUB")), 1, "near miss " .. i)
		end
		h.eq((S.add(c, "NearMiss", "HUB")), 0, "fourth in a row is stale")
		h.eq((S.add(c, "Stuck", "HUB")), 1, "a different move counts")
		h.eq((S.add(c, "NearMiss", "HUB")), 1, "and freshens near misses again")
		h.eq(c.count, 5)
	end)

	h.test("chain fuse: banks when it runs out, a held move (drift, skim) stops the burn; a break drops it but keeps the best", function()
		local c = S.newChain()
		S.add(c, "Roll", "DINO")
		S.add(c, "Threaded", "DINO")
		h.eq(S.tick(c, 10, true), 0, "held: no burn")
		h.eq(c.count, 3)
		h.eq(S.tick(c, S.window(3) - 0.01, false), 0, "not yet")
		h.eq(S.tick(c, 0.02, false), 3, "banked at the end of the fuse")
		h.eq(c.count, 0)
		h.eq(c.best, 3)
		S.add(c, "Stuck", "DINO")
		S.add(c, "Drift2", "DINO")
		h.eq(S.breakChain(c), 2, "a crash loses the running chain")
		h.eq({ c.count, c.best, c.bestText }, { 0, 3, "NICE!" }, "the race best stays")
		h.eq(S.tick(c, 1, false), 0, "an empty chain never banks")
		S.resetRace(c)
		h.eq({ c.best, c.bestText }, { 0, "" }, "a new race starts clean")
	end)

	h.test("chain notes climb a pentatonic scale over two octaves, then hold the top", function()
		local prev = 0
		for m = 1, 10 do
			local p = S.tickPitch(m)
			h.ok(p > prev, "rises at move " .. m)
			prev = p
		end
		h.eq(S.tickPitch(1), 1)
		h.ok(near(S.tickPitch(6), 2), "octave at the sixth move")
		h.eq(S.tickPitch(30), S.tickPitch(10), "holds the top note")
	end)

	-- ------------------------------------------------------------ item 16: near miss and lava skim
	h.test("near miss: rising edge into the band at speed, per-side cooldown; a touch or a slow pass never counts", function()
		local car = S.NEAR.car
		local s = S.newNear()
		local inBand = car.halfWidth + 1.5
		h.eq({ S.nearStep(s, nil, nil, car, 10, true, -100) }, { nil, 0 }, "clear")
		h.eq({ S.nearStep(s, inBand, nil, car, 10.05, true, -100) }, { "NearMiss", -1 }, "left wall swings into the band")
		h.eq({ S.nearStep(s, inBand, nil, car, 10.1, true, -100) }, { nil, 0 }, "staying in the band is one event")
		S.nearStep(s, nil, nil, car, 10.2, true, -100)
		h.eq({ S.nearStep(s, inBand, nil, car, 10.3, true, -100) }, { nil, 0 }, "inside the cooldown")
		S.nearStep(s, nil, nil, car, 11.0, true, -100)
		h.eq({ S.nearStep(s, nil, inBand, car, 11.05, true, -100) }, { "NearMiss", 1 }, "right side has its own cooldown")
		-- Touching, then easing into the band: a scrape, not a near miss.
		local t = S.newNear()
		S.nearStep(t, car.halfWidth + 0.1, nil, car, 20, true, -100)
		h.eq({ S.nearStep(t, inBand, nil, car, 20.05, true, -100) }, { nil, 0 }, "touch sticks")
		-- A wall contact in the grace window voids it; slow passes never count.
		local u = S.newNear()
		h.eq({ S.nearStep(u, inBand, nil, car, 30, true, 29.8) }, { nil, 0 }, "recent scrape")
		local v = S.newNear()
		h.eq({ S.nearStep(v, inBand, nil, car, 30, false, -100) }, { nil, 0 }, "too slow")
		h.eq(S.gapClass(car.halfWidth + car.band + 0.1, car), "clear", "past the band is clear")
		h.ok(S.nearReach(car) > car.halfWidth + car.band, "the ray covers the band")
	end)

	h.test("near miss: both sides at once is a SQUEEZE (a tunnel mouth, a gap between rocks)", function()
		local plane = S.NEAR.plane
		local s = S.newNear()
		local d = plane.halfWidth + 4
		h.eq({ S.nearStep(s, d, d, plane, 5, true, -100) }, { "Squeeze", 0 })
		h.eq({ S.nearStep(s, d, d, plane, 5.05, true, -100) }, { nil, 0 }, "once")
	end)

	h.test("lava skim: enters in the band, counts again every second, rides through a short gap, ends after the grace", function()
		local s = S.newSkim()
		local dt = 1 / S.SKIM_HZ
		h.eq({ S.skimStep(s, nil, dt) }, { nil, false })
		h.eq({ S.skimStep(s, S.SKIM_MAX + 1, dt) }, { nil, false }, "too high")
		h.eq({ S.skimStep(s, S.SKIM_MIN - 0.5, dt) }, { nil, false }, "touching lava is a crash, not a skim")
		h.eq({ S.skimStep(s, 6, dt) }, { "LavaSkim", true }, "enter")
		local counted = 0
		for _ = 1, 25 do
			local kind = S.skimStep(s, 6, dt)
			if kind then
				counted += 1
			end
		end
		h.eq(counted, 2, "2.5 s more skimming counts twice more")
		h.eq({ S.skimStep(s, nil, dt) }, { nil, true }, "a rock island inside the grace keeps the wake")
		h.eq({ S.skimStep(s, 6, dt) }, { nil, true }, "back over lava: same skim")
		for _ = 1, 3 do
			S.skimStep(s, nil, dt)
		end
		h.eq({ S.skimStep(s, nil, dt) }, { nil, false }, "ends after the grace")
		h.eq(s.active, false)
	end)

	-- ------------------------------------------------------------ G5.4: the leash
	h.test("leash: weight from LEASH_MIN_PULL at 200 to 1 at 300; warn hysteresis; auto-respawn after 1.5 s past 380", function()
		h.eq(P.leashWeight(150), 0)
		h.eq(P.leashWeight(P.LEASH_WARN), 0)
		h.ok(near(P.leashWeight(P.LEASH_WARN + 0.001), P.LEASH_MIN_PULL, 1e-3), "starts at the minimum pull")
		h.ok(near(P.leashWeight(250), P.LEASH_MIN_PULL + (1 - P.LEASH_MIN_PULL) * 0.5), "halfway")
		h.eq(P.leashWeight(P.LEASH_FULL), 1)
		h.eq(P.leashWeight(1000), 1)
		h.eq({ P.LEASH_WARN, P.LEASH_RESPAWN, P.LEASH_RESPAWN_TIME }, { 200, 380, 1.5 }, "the audit's numbers")
		local s = P.newLeash()
		h.eq(P.leashStep(s, 190, 0.1), "ok")
		h.eq(P.leashStep(s, 210, 0.1), "warn")
		h.eq(P.leashStep(s, 190, 0.1), "warn", "hysteresis: still warning just inside")
		h.eq(P.leashStep(s, 170, 0.1), "ok", "clears 20 inside")
		local dt = 1 / 60
		local verdict, t = "", 0
		repeat
			verdict = P.leashStep(s, 400, dt)
			t += dt
		until verdict == "respawn" or t > 5
		h.ok(verdict == "respawn" and near(t, P.LEASH_RESPAWN_TIME, dt * 1.5), string.format("respawn after %.2f s", t))
		h.eq(s.outTimer, 0, "fires once, then starts over")
		local s2 = P.newLeash()
		for _ = 1, 80 do
			P.leashStep(s2, 400, dt)
		end
		P.leashStep(s2, 300, dt)
		h.eq(s2.outTimer, 0, "coming back inside 380 resets the clock")
	end)

	-- ------------------------------------------------------------ G8: alternate lines
	local V = Vector3.new
	h.test("RouteBranch geometry: nearest, pointAt and the pursuit target past the end", function()
		local line = R.makeLine("A", "ledge", { V(0, 0, 0), V(100, 0, 0), V(100, 0, 100) }, 500, 700)
		h.eq(line.length, 200)
		local d, along, p = R.nearest(line, V(50, 10, 0))
		h.ok(near(d, 10) and near(along, 50) and (p - V(50, 0, 0)).Magnitude < 1e-6, "nearest on segment 1")
		local q, over = R.pointAt(line, 150)
		h.ok((q - V(100, 0, 50)).Magnitude < 1e-6 and over == 0, "pointAt inside")
		local e, over2 = R.pointAt(line, 230)
		h.ok((e - V(100, 0, 100)).Magnitude < 1e-6 and near(over2, 30), "past the end: the end point and the overflow")
		local tunnel = R.makeLine("T", "tunnel", line.points, nil, nil)
		local _, o1 = R.target(line, 150, 100)
		local _, o2 = R.target(tunnel, 150, 100)
		h.ok(o1 > o2, "a tunnel pursues nearer than a ledge")
		h.eq(R.RADIUS.hidden, 14)
		-- A span (SPACE-4's rooftop line, plan-owned geometry) is a ledge-width course line that pursues like a ledge.
		h.eq(R.RADIUS.span, 26)
		local span = R.makeLine("Alt2", "span", line.points, nil, nil)
		local _, o3 = R.target(span, 150, 100)
		h.eq(o3, o1, "a span pursues like a ledge")
	end)

	h.test("RouteBranch pick: enter close and closer than main, stay with hysteresis, leave past the end or the stretch", function()
		local line = R.makeLine("Alt1", "tunnel", { V(0, 0, 0), V(0, 0, -400) }, 100, 500)
		local lines = { line }
		local picked = R.pick(lines, V(10, 0, -100), 120, nil, 200, 5000)
		h.eq(picked and picked.id, "Alt1", "inside the tube, main 120 away")
		h.eq((R.pick(lines, V(10, 0, -100), 12, nil, 200, 5000)), nil, "main is closer: stay on main")
		h.eq((R.pick(lines, V(25, 0, -100), 120, nil, 200, 5000)), nil, "outside the radius: not entered")
		local held = R.pick(lines, V(25, 0, -100), 120, "Alt1", 200, 5000)
		h.eq(held and held.id, "Alt1", "but held once on it")
		h.eq((R.pick(lines, V(0, 0, -399), 120, "Alt1", 480, 5000)), nil, "past the end: back on main")
		h.eq((R.pick(lines, V(5, 0, -100), 120, nil, 2000, 5000)), nil, "outside its join..rejoin stretch")
		local _, _, _, course = R.pick(lines, V(5, 0, -100), 120, nil, 2000, 5000)
		h.ok(near(course, 5), "the leash still measures the alternate as course")
		-- A stretch that wraps past the finish line.
		local wrap = R.makeLine("W", "ledge", line.points, 4900, 200)
		h.ok(R.inStretch(wrap, 4950, 5000) and R.inStretch(wrap, 100, 5000), "wrapped stretch")
		h.ok(not R.inStretch(wrap, 2500, 5000), "far from it")
		h.ok(R.inStretch(R.makeLine("G", "hidden", line.points, nil, nil), 2500, 5000), "no stations: always in stretch")
	end)

	-- Real data: the launch maps' TrackData (the same numbers MapAdapter publishes).
	local function projectMain(wps: { any }, pos: Vector3, lift: number): (number, number)
		local best, station = math.huge, 0
		for i = 1, #wps - 1 do
			local a, b = wps[i].pos + V(0, lift, 0), wps[i + 1].pos + V(0, lift, 0)
			local seg = b - a
			local len2 = seg:Dot(seg)
			local t = if len2 > 1e-6 then math.clamp((pos - a):Dot(seg) / len2, 0, 1) else 0
			local d = (pos - (a + seg * t)).Magnitude
			if d < best then
				best = d
				station = wps[i].station + (wps[i + 1].station - wps[i].station) * t
			end
		end
		return best, station
	end

	-- ------------------------------------------------------------ ISLAND-2 Alt2: the cliff line's progress
	h.test("cliff line: never picked on the client (rescue guard), maps the distance along it to a main-route station, hands back past the end", function()
		local cliff = R.makeLine("Alt2", "cliff", { V(0, 100, 0), V(0, 100, -400) }, 100, 500)
		h.eq(cliff.radius, R.RADIUS.cliff, "its own radius")
		local ledge = R.makeLine("L", "ledge", cliff.points, 100, 500)
		local lines = R.cliffOnly({ ledge, cliff })
		h.eq(#lines, 1, "cliffOnly keeps only the cliff lines")
		local rest = R.withoutCliff({ ledge, cliff })
		h.ok(#rest == 1 and rest[1] == ledge, "withoutCliff drops only the cliff lines")
		-- Rescue guard (owner rule): the client pick never returns a cliff line, so CarController's stranded test keeps
		-- measuring from the main route on the rock, exactly as before Alt2; nor does it count for the plane leash.
		local cliffAlone = R.makeLine("Alt2", "cliff", { V(0, 100, 0), V(0, 100, -400) }, 100, 500)
		local picked, _, _, course = R.pick({ cliffAlone }, V(5, 100, -200), 120, nil, 300, 5000)
		h.eq(picked, nil, "pick never returns a cliff line")
		h.eq(course, 120, "a cliff line is not course for the leash")
		h.eq((R.pick({ cliffAlone }, V(5, 100, -200), 120, "Alt2", 300, 5000)), nil, "not even when held")
		local line, st = R.cliffProgress(lines, V(5, 100, -200), 120, nil)
		h.ok(line ~= nil and near(st, 300, 1e-6), "half way along: station join + (rejoin - join) / 2")
		h.eq((R.cliffProgress(lines, V(5, 100, -200), 8, nil)), nil, "main line about as close: not entered")
		h.eq((R.cliffProgress(lines, V(60, 100, -200), 120, nil)), nil, "outside the radius: not entered")
		h.ok(R.cliffProgress(lines, V(60, 100, -200), 120, "Alt2") ~= nil, "but held once on it (stay factor)")
		h.eq((R.cliffProgress(lines, V(0, 100, -399), 120, "Alt2")), nil, "past the end: back on the main spline")
		local _, st0 = R.cliffProgress(lines, V(0, 100, -1), 120, nil)
		h.ok(st0 >= 100 and st0 < 105, "the start maps to the join station")
	end)

	h.test("cliff line on ISLAND-2: every point away from the road is on course, stations run join to rejoin and cover the checkpoints", function()
		local td = h.require("build/island2/TrackData.luau")
		local alt2
		local lines = {}
		for i, alt in td.alternates do
			table.insert(lines, R.makeLine(alt.id or ("Alt" .. i), alt.style or "ledge", alt.points, alt.joinStation, alt.rejoinStation))
			if alt.id == "Alt2" then
				alt2 = alt
			end
		end
		h.ok(alt2 ~= nil and alt2.style == "cliff", "Alt2 is a cliff line in TrackData")
		local cliffLines = R.cliffOnly(lines)
		h.eq(#cliffLines, 1)
		local join, rejoin = alt2.joinStation, alt2.rejoinStation
		h.ok(join < rejoin and join > 30 and rejoin < td.length - 500, "stretch inside the lap, after the start line")
		local last, held, onCount, firstOn = join - 1, nil, 0, nil
		local stations = {}
		for i, p in alt2.points do
			local mainDist = projectMain(td.waypoints, p, 0)
			local line, st = R.cliffProgress(cliffLines, p, mainDist, held)
			if line then
				held = line.id
				onCount += 1
				firstOn = firstOn or i
				table.insert(stations, st)
				h.ok(st >= join - 1e-6 and st <= rejoin + 1e-6, "station inside join..rejoin")
				h.ok(st >= last - 1e-6, string.format("stations never run backwards (point %d: %.1f after %.1f)", i, st, last))
				h.ok(st - last <= 60, string.format("no jump: %.1f studs of station in one 16-stud step (point %d)", st - last, i))
				last = st
			elseif mainDist > R.RADIUS.cliff + R.MAIN_MARGIN_ENTER + 2 then
				h.ok(false, string.format("point %d is %.0f from the road but not on course", i, mainDist))
			end
		end
		h.ok(onCount >= #alt2.points - 12, string.format("on course for %d of %d points (the ends are on the road)", onCount, #alt2.points))
		-- Every checkpoint inside the stretch is within the server's 110-stud station window of some point on the line.
		for _, cp in td.checkpoints do
			if cp.station > join + 60 and cp.station < rejoin - 60 then
				local hit = false
				for _, st in stations do
					if math.abs(st - cp.station) <= 110 then
						hit = true
					end
				end
				h.ok(hit, "checkpoint " .. cp.index .. " is counted on the line")
			end
		end
		-- The main spline never reads as the cliff line.
		local bad = 0
		for _, w in td.waypoints do
			if R.cliffProgress(cliffLines, w.pos, 0, nil) then
				bad += 1
			end
		end
		h.eq(bad, 0, "no main-spline point is picked as cliff")
	end)

	h.test("cliff line: rides the existing rock (no carve, no deck) and leaves wall driving untouched (owner rule guard)", function()
		local deck = h.readFile("src/server/kit/Deck.luau")
		h.ok(string.find(deck, 'alt.style == "cliff"', 1, true) ~= nil, "Deck builds nothing for a cliff line")
		local adapter = h.readFile("src/server/MapAdapter.luau")
		h.ok(string.find(adapter, 'if alt.style == "cliff" then', 1, true) ~= nil, "MapAdapter carves nothing for a cliff line")
		local rm = h.readFile("src/server/RaceManager.luau")
		h.ok(string.find(rm, "RouteBranch.cliffProgress", 1, true) ~= nil, "RaceManager counts the cliff line as on course")
		for _, path in { "src/client/CarController.luau", "src/shared/CarConfig.luau", "src/shared/RespawnRules.luau", "src/server/CarServer.luau" } do
			local src = h.readFile(path)
			h.ok(string.find(src, 'RouteBranch.CLIFF', 1, true) == nil and string.find(src, '"cliff"', 1, true) == nil and string.find(src, "cliffProgress", 1, true) == nil, path .. " does not know cliff lines (no car, adhesion or rescue change)")
		end
	end)

	h.test("G8 on the launch maps: alternate points away from the main line pick their line; main-line points never do", function()
		local report = {}
		for _, key in { "dino4", "forest1", "snow1", "space4", "island2", "hub0" } do
			local td = h.require("build/" .. key .. "/TrackData.luau")
			local lift = if td.vehicle == "plane" then R.PLANE_LIFT else 0
			local lines = {}
			for i, alt in td.alternates or {} do
				local pts = {}
				for _, p in alt.points do
					table.insert(pts, p + V(0, lift, 0))
				end
				table.insert(lines, R.makeLine(alt.id or ("Alt" .. i), alt.style or "ledge", pts, alt.joinStation, alt.rejoinStation))
			end
			if td.hiddenKey and td.hiddenKey.gallery then
				table.insert(lines, R.makeLine("KeyGallery", "hidden", td.hiddenKey.gallery, nil, nil))
			end
			local checked, mainChecked = 0, 0
			for _, line in lines do
				for i = 2, #line.points - 1 do
					local pos = line.points[i]
					local mainDist, station = projectMain(td.waypoints, pos, lift)
					-- Cliff lines are server progress only (pick skips them; see the cliff line tests).
					if line.style ~= "cliff" and mainDist > line.radius + R.MAIN_MARGIN_ENTER + 2 then
						local picked = R.pick(lines, pos, mainDist, nil, station, td.length)
						h.eq(picked and picked.id, line.id, string.format("%s %s point %d (main %.0f away)", key, line.id, i, mainDist))
						-- The pursuit point ahead stays on the line (or runs on to the main spline past its end).
						if picked then
							local _, along = R.nearest(picked, pos)
							local tgt, over = R.target(picked, along, 115)
							if over == 0 then
								h.ok(R.nearest(picked, tgt) < 0.05, "target on the line (float32 at map scale)")
							end
						end
						checked += 1
					end
				end
			end
			for i = 1, #td.waypoints, 7 do
				local pos = td.waypoints[i].pos + V(0, lift, 0)
				local clear = true
				for _, line in lines do
					if (R.nearest(line, pos)) < line.radius * R.STAY_FACTOR + 10 then
						clear = false
					end
				end
				if clear then
					h.eq((R.pick(lines, pos, 0, nil, td.waypoints[i].station, td.length)), nil, key .. " main point " .. i)
					mainChecked += 1
				end
			end
			table.insert(report, string.format("%s %d/%d", key, checked, mainChecked))
			h.ok(#lines == 0 or checked > 0, key .. ": some alternate points were checked")
		end
		print("G8 checked " .. table.concat(report, ", "))
	end)

	h.test("the dead DINO-4 RouteBranch block is gone from the plane assist (SN-11)", function()
		local src = h.readFile("src/client/FlightController.luau")
		h.ok(string.find(src, "Vector3.new(58, 134, -142)", 1, true) == nil, "legacy Alt1 target removed")
		h.ok(string.find(src, 'workspace:GetAttribute("RouteBranch")', 1, true) == nil, "no workspace-wide RouteBranch read")
		h.ok(string.find(src, "RouteBranch.pick", 1, true) ~= nil or string.find(src, "sampleCourse", 1, true) ~= nil, "the assist picks lines")
	end)
end
