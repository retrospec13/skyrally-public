--!strict
-- Lune spec for Curtain Kart (docs/REMARKABLE.md item 8): the baked outlines in src/shared/CurtainTracks.luau
-- (tools/bake_curtain_tracks.py) and the 2D arcade rules in src/shared/CurtainKartSim.luau that client/CurtainKart
-- runs every frame under the map-load curtain.
-- Run: tools/tests/run_lune_tests.sh tools/tests/curtain_kart_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

local DT = 1 / 60

return function(h: Harness)
	local Sim = h.require("src/shared/CurtainKartSim.luau")
	local Tracks = h.require("src/shared/CurtainTracks.luau")
	local TrackInfo = h.require("src/shared/TrackInfo.luau")

	local function ids(): { string }
		local out = {}
		for id in Tracks do
			table.insert(out, id)
		end
		table.sort(out)
		return out
	end

	-- Drives with the attract-mode autopilot until `laps` laps or `limit` seconds; returns the lap times.
	local function autoLaps(tr: any, laps: number, limit: number): { number }
		local k = Sim.newKart(tr, 1)
		local times = {}
		local t = 0
		while t < limit and #times < laps do
			local lap = Sim.step(tr, k, DT, Sim.autoSteer(tr, k))
			if lap then
				table.insert(times, lap)
			end
			t += DT
		end
		return times
	end

	h.test("every launch track with a route has a baked outline (battle-only ids are skipped by the client)", function()
		for id in TrackInfo.BY_ID do
			h.ok(Tracks[id] ~= nil, "no curtain track for " .. id)
		end
	end)

	h.test("outlines: 12..48 points inside the unit box, long side 1, start index 1, perimeter cached", function()
		for _, id in ids() do
			local t = Tracks[id]
			h.ok(#t.points >= 12 and #t.points <= 48, id .. " point count " .. #t.points)
			h.eq(t.startIndex, 1, id)
			h.ok(math.abs(math.max(t.w, t.h) - 1) < 1e-3, id .. " long side")
			local per = 0
			for i, p in t.points do
				h.ok(p[1] >= -1e-4 and p[1] <= t.w + 1e-4 and p[2] >= -1e-4 and p[2] <= t.h + 1e-4, id .. " point " .. i .. " outside the box")
				local q = t.points[i % #t.points + 1]
				per += math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2)
			end
			h.ok(math.abs(per - t.length) < 0.01, id .. " cached length")
		end
	end)

	h.test("the autopilot laps every track, the first lap inside about 6 s (0.5 s fade + at most 5.7 s)", function()
		for _, id in ids() do
			local t = Tracks[id]
			local tr = Sim.prepare(t.points, t.w, t.h)
			h.ok(tr.top >= Sim.BASE_SPEED and tr.top <= Sim.MAX_SPEED, id .. " top speed")
			local times = autoLaps(tr, 3, 30)
			h.eq(#times, 3, id .. " laps in 30 s")
			h.ok(times[1] < 5.7, string.format("%s first lap %.2f s", id, times[1]))
			h.ok(times[2] > 2.5, string.format("%s flying lap %.2f s is suspiciously short", id, times[2]))
		end
	end)

	h.test("no steering: the kart leaves the road, drops to 40 percent and never laps", function()
		local t = Tracks["HUB-0"]
		local tr = Sim.prepare(t.points, t.w, t.h)
		local k = Sim.newKart(tr, 1)
		local laps = 0
		for _ = 1, 60 * 20 do
			if Sim.step(tr, k, DT, 0) then
				laps += 1
			end
		end
		h.eq(laps, 0)
		h.ok(k.offTrack, "ends off the road")
		h.ok(math.abs(k.speed - tr.top * Sim.OFF_FACTOR) < 1e-6, "off-road speed")
		h.ok(k.x >= -Sim.BOX_MARGIN and k.x <= tr.w + Sim.BOX_MARGIN and k.y >= -Sim.BOX_MARGIN and k.y <= tr.h + Sim.BOX_MARGIN, "held in the box")
	end)

	h.test("a lap needs more than 80 percent of the loop: rocking back and forth over the line never counts", function()
		local t = Tracks["ISLAND-2"]
		local tr = Sim.prepare(t.points, t.w, t.h)
		local k = Sim.newKart(tr, 1)
		local laps = 0
		-- Reverse over the line, then drive forward over it again, many times (teleport-free: real steps).
		for _ = 1, 6 do
			k.heading = Sim.segHeading(tr, tr.n) + math.pi
			for _ = 1, 30 do
				if Sim.step(tr, k, DT, 0) then
					laps += 1
				end
			end
			k.heading = Sim.segHeading(tr, 1)
			for _ = 1, 30 do
				if Sim.step(tr, k, DT, 0) then
					laps += 1
				end
			end
		end
		h.eq(laps, 0)
	end)

	h.test("a shortcut across the infield skips too many segments to count", function()
		local t = Tracks["HUB-0"]
		local tr = Sim.prepare(t.points, t.w, t.h)
		local k = Sim.newKart(tr, 1)
		-- Drive half the loop with the autopilot, then jump straight to just before the line (a cut).
		while k.station < tr.total * 0.45 do
			Sim.step(tr, k, DT, Sim.autoSteer(tr, k))
		end
		local n = tr.n
		k.x, k.y = tr.xs[n], tr.ys[n]
		k.segIndex = n
		k.heading = Sim.segHeading(tr, n)
		local lap = nil
		for _ = 1, 120 do
			lap = lap or Sim.step(tr, k, DT, Sim.autoSteer(tr, k))
		end
		h.eq(lap, nil)
		h.ok(k.lapStart > 0, "the line still restarts the lap clock")
	end)

	h.test("SNOW-1's figure eight: the local search keeps the kart on its own branch through the crossover", function()
		local t = Tracks["SNOW-1"]
		local tr = Sim.prepare(t.points, t.w, t.h)
		local k = Sim.newKart(tr, 1)
		local lastStation = 0
		local jumps = 0
		for _ = 1, 60 * 6 do
			Sim.step(tr, k, DT, Sim.autoSteer(tr, k))
			local ds = (k.station - lastStation) % tr.total
			if ds > 0.2 then
				jumps += 1
			end
			lastStation = k.station
		end
		h.eq(jumps, 0, "progress jumped to the other branch")
	end)

	h.test("best lap and lap text", function()
		local t = Tracks["SPACE-4"]
		local tr = Sim.prepare(t.points, t.w, t.h)
		local k = Sim.newKart(tr, 1)
		local times = {}
		while #times < 2 do
			local lap = Sim.step(tr, k, DT, Sim.autoSteer(tr, k))
			if lap then
				table.insert(times, lap)
			end
		end
		h.eq(k.laps, 2)
		h.eq(k.best, math.min(times[1], times[2]))
		h.eq(Sim.formatLap(7.24), "7.2")
		h.eq(Sim.formatLap(65.3), "1:05.3")
	end)
end
