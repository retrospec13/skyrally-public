--!strict
-- Lune spec for Shared.RacerViewRules (client/RacerView): snapshot interpolation of the anchored bot hulls the server
-- re-CFrames every Heartbeat, and the proximity name labels over other racers. The jitter test replays the failure the
-- owner saw: 60 Hz server poses replicated in ~30 Hz bunches with network jitter, drawn at 60 fps. Showing each pose
-- as it arrives (the old behaviour) stalls and leaps; the interpolated track moves the same distance every frame.
-- Usage: tools/tests/run_lune_tests.sh tools/tests/racer_view_spec.luau

return function(h)
	local Rules = h.require("src/shared/RacerViewRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")

	-- Deterministic LCG so the jitter is the same every run.
	local function rng(seed: number): () -> number
		local s = seed
		return function(): number
			s = (s * 1103515245 + 12345) % 2147483648
			return s / 2147483648
		end
	end

	-- Per-frame on-screen step statistics (mean, coefficient of variation, stalled frames) along a straight run.
	local function stepStats(positions: { number }): (number, number, number)
		local steps = {}
		for i = 2, #positions do
			table.insert(steps, positions[i] - positions[i - 1])
		end
		local sum = 0
		for _, s in steps do
			sum += s
		end
		local mean = sum / #steps
		local var, stalls = 0, 0
		for _, s in steps do
			var += (s - mean) ^ 2
			if s < mean * 0.25 then
				stalls += 1
			end
		end
		return mean, math.sqrt(var / #steps) / mean, stalls
	end

	-- A bot flying +Z along zAt(t); the server writes every 1/60 s, packets leave every 1/30 s carrying the latest pose
	-- and land 50-90 ms later, in order (property replication is ordered). The client draws at 60 fps.
	local function replay(zAt: (number) -> number, seconds: number)
		local rand = rng(4242)
		local packets: { { arrive: number, z: number } } = {}
		local lastArrive = 0
		for k = 0, math.floor(seconds * 30) do
			local send = k / 30
			local z = zAt(send) -- the server's pose at its Heartbeat 2k
			local arrive = math.max(lastArrive, send + 0.05 + rand() * 0.04)
			lastArrive = arrive
			table.insert(packets, { arrive = arrive, z = z })
		end
		local track = Rules.newTrack()
		local raw, smooth = {}, {}
		local nextPacket = 1
		local shownRaw = 0
		local frame = 0
		local written: CFrame? = nil
		while true do
			frame += 1
			local now = frame / 60
			if now > seconds then
				break
			end
			-- Replication applies between frames: the hull holds the newest packet that has landed.
			local hull: CFrame? = nil
			while nextPacket <= #packets and packets[nextPacket].arrive <= now do
				hull = CFrame.new(0, 0, packets[nextPacket].z)
				shownRaw = packets[nextPacket].z
				nextPacket += 1
			end
			if hull and Rules.changed(hull, written) then
				Rules.push(track, hull, now)
			end
			local cf = Rules.sample(track, now)
			if cf then
				written = cf
				if now > 1 then -- past the warm-up
					table.insert(smooth, cf.Position.Z)
					table.insert(raw, shownRaw)
				end
			end
		end
		return raw, smooth
	end

	h.test("raw replicated poses stall and leap; interpolated poses step evenly", function()
		local speed = 200
		local raw, smooth = replay(function(t: number): number
			return speed * t
		end, 6)
		local rawMean, rawCv, rawStalls = stepStats(raw)
		local mean, cv, stalls = stepStats(smooth)
		print(string.format("raw mean %.2f cv %.2f stalls %d | smooth mean %.2f cv %.3f stalls %d", rawMean, rawCv, rawStalls, mean, cv, stalls))
		h.ok(rawCv > 0.5 and rawStalls > 50, "the old path (pose as it lands) visibly stutters at 200 studs/s")
		h.ok(math.abs(mean - speed / 60) < 0.05 * speed / 60, "smoothed bot keeps its true speed on screen")
		h.ok(cv < 0.06, string.format("smoothed per-frame step varies < 6%% (cv %.3f)", cv))
		h.eq(stalls, 0, "no stalled frames once smoothed")
	end)

	h.test("speeding up and braking hard stays smooth (no frame-to-frame lurch)", function()
		-- Boost from 130 to 250 studs/s, then a spin-out brake to 52 (AI_HIT.speedFactor 0.4), each over ~0.5 s.
		local function speedAt(t: number): number
			if t < 2 then
				return 130
			elseif t < 2.5 then
				return 130 + 240 * (t - 2)
			elseif t < 4 then
				return 250
			elseif t < 4.5 then
				return 250 - 396 * (t - 4)
			end
			return 52
		end
		local function zAt(t: number): number
			local z, dt = 0, 1 / 240
			local x = 0
			while x < t do
				z += speedAt(x) * dt
				x += dt
			end
			return z
		end
		local raw, smooth = replay(zAt, 6)
		local function worstLurch(zs: { number }): number
			local worst = 0
			for i = 2, #zs - 1 do
				worst = math.max(worst, math.abs(zs[i + 1] - 2 * zs[i] + zs[i - 1]))
			end
			return worst
		end
		local rawLurch, lurch = worstLurch(raw), worstLurch(smooth)
		print(string.format("worst frame-to-frame step change: raw %.2f studs, smoothed %.2f studs", rawLurch, lurch))
		-- The path itself changes its per-frame step by at most 396/3600 = 0.11 studs.
		h.ok(rawLurch > 4, "the old path lurches")
		h.ok(lurch < 0.8, string.format("smoothed step changes < 0.8 stud per frame (%.2f)", lurch))
	end)

	h.test("delay stays inside its band and lags the server by about one and a half intervals", function()
		local track = Rules.newTrack()
		for i = 0, 60 do
			Rules.push(track, CFrame.new(0, 0, i), i / 30)
		end
		local d = Rules.delay(track)
		h.ok(d >= Rules.MIN_DELAY and d <= Rules.MAX_DELAY, "delay in band")
		h.ok(math.abs(d - Rules.DELAY_INTERVALS / 30) < 0.01, string.format("delay ~ DELAY_INTERVALS packet intervals at 30 Hz with no lateness (%.3f)", d))
		local cf = Rules.sample(track, 2) :: CFrame
		-- At t = 2 the newest pose is z = 60; drawn ~d seconds behind at 30 studs/s.
		h.ok(math.abs(cf.Position.Z - (60 - d * 30)) < 0.6, "drawn pose is the server's pose ~delay ago")
	end)

	h.test("a teleport restarts the track instead of sliding across the map", function()
		local track = Rules.newTrack()
		h.eq(Rules.push(track, CFrame.new(0, 0, 0), 0), true, "first pose restarts")
		h.eq(Rules.push(track, CFrame.new(0, 0, 5), 1 / 30), false, "flight is not a teleport")
		h.eq(Rules.push(track, CFrame.new(0, 0, 900), 2 / 30), true, "a grid reset is")
		h.eq(#track.snaps, 1, "only the new pose is kept")
		local cf = Rules.sample(track, 3 / 30) :: CFrame
		h.eq(cf.Position.Z, 900, "drawn at the new pose at once")
	end)

	h.test("a late packet extrapolates briefly, then holds", function()
		local track = Rules.newTrack()
		for i = 0, 10 do
			Rules.push(track, CFrame.new(0, 0, i * 4), i / 30)
		end
		local newest = track.snaps[#track.snaps]
		local far = Rules.sample(track, newest.t + 5) :: CFrame
		local cap = 4 * 30 * Rules.MAX_EXTRAPOLATE
		h.ok(far.Position.Z <= 40 + cap + 0.5, "never more than MAX_EXTRAPOLATE ahead of the newest pose")
		h.ok(far.Position.Z >= 40, "keeps moving forward while waiting")
	end)

	h.test("a ground racer's late packet never extrapolates its height (no car in the air over a crest)", function()
		-- A car climbing a ramp lip at 130 studs/s and 45 degrees: 30 Hz poses rise 3 studs each.
		local air, road = Rules.newTrack(), Rules.newTrack()
		for i = 0, 10 do
			local cf = CFrame.new(0, i * 3, i * 3)
			Rules.push(air, cf, i / 30)
			Rules.push(road, cf, i / 30)
		end
		local newest = road.snaps[#road.snaps]
		local late = newest.t + Rules.delay(road) + Rules.MAX_EXTRAPOLATE
		local plane = Rules.sample(air, late) :: CFrame
		local car = Rules.sample(road, late, true) :: CFrame
		h.ok(plane.Position.Y > 30 + 1, "a plane carries on climbing past its newest pose")
		h.eq(car.Position.Y, 30, "a car holds the server's last ride height")
		h.ok(car.Position.Z > 30 + 1, "a car still carries on along the road")
		-- Between snapshots a car is interpolated as before (the server's own road-snapped poses).
		local mid = Rules.sample(road, newest.t - 0.5 / 30 + Rules.delay(road), true) :: CFrame
		h.ok(math.abs(mid.Position.Y - mid.Position.Z) < 1e-6, "between snapshots the car stays on the ramp line")
	end)

	h.test("snapshots are capped and stamps strictly increase even for bunched arrivals", function()
		local track = Rules.newTrack()
		for i = 0, 40 do
			-- Two packets in the same frame every other step.
			local arrival = math.floor(i / 2) / 30
			Rules.push(track, CFrame.new(0, 0, i), arrival)
		end
		h.ok(#track.snaps <= Rules.CAPACITY, "buffer capped")
		for i = 2, #track.snaps do
			h.ok(track.snaps[i].t > track.snaps[i - 1].t, "stamps increase")
		end
	end)

	h.test("changed() sees only a new server pose, not this client's own write", function()
		local a = CFrame.new(1, 2, 3) * CFrame.Angles(0, 0.3, 0)
		h.eq(Rules.changed(a, a), false, "own write")
		h.eq(Rules.changed(a, nil), true, "nothing written yet")
		h.eq(Rules.changed(a + Vector3.new(0, 0, 0.01), a), true, "moved")
		h.eq(Rules.changed(a * CFrame.Angles(0, 0, 0.05), a), true, "rolled in place (spin-out)")
	end)

	h.test("labels: full near, gone past 70 studs, smooth in between, semi-transparent", function()
		h.eq(Rules.labelAlpha(0), 1)
		h.eq(Rules.labelAlpha(Rules.LABEL_FULL), 1)
		h.eq(Rules.labelAlpha(Rules.LABEL_HIDE), 0)
		h.eq(Rules.labelAlpha(500), 0)
		h.ok(Rules.LABEL_HIDE == 70, "owner: about 70 studs")
		local prev = 1
		for d = Rules.LABEL_FULL, Rules.LABEL_HIDE, 1 do
			local a = Rules.labelAlpha(d)
			h.ok(a <= prev + 1e-9, "fades monotonically with distance")
			prev = a
		end
		local textT, backT = Rules.labelTransparency(1)
		h.ok(textT > 0.05 and textT < 0.5, "text semi-transparent at full")
		h.ok(backT > textT and backT < 1, "backing lighter than the text")
		local t0, b0 = Rules.labelTransparency(0)
		h.eq(t0, 1)
		h.eq(b0, 1)
		-- Fading takes a few frames, never a pop.
		local shown = 0
		shown = Rules.approachAlpha(shown, 1, 1 / 60)
		h.ok(shown > 0 and shown < 0.25, "one frame is a small step")
		for _ = 1, 60 do
			shown = Rules.approachAlpha(shown, 1, 1 / 60)
		end
		h.ok(shown > 0.99, "fully in within a second")
	end)

	h.test("label text: bots by roster name, players by display name, never self or a boss", function()
		local names = { [42] = "SkyPilot", [7] = "Friend" }
		local function nameOf(id: number): string?
			return names[id]
		end
		h.eq(Rules.labelText({ BotName = "Ace Aero", BotId = 1 }, 42, nameOf), "Ace Aero")
		h.eq(Rules.labelText({ OwnerUserId = 7, OwnerName = "friend_user" }, 42, nameOf), "Friend")
		h.eq(Rules.labelText({ OwnerUserId = 9, OwnerName = "left_user" }, 42, nameOf), "left_user", "falls back to OwnerName")
		h.eq(Rules.labelText({ OwnerUserId = 42, OwnerName = "me" }, 42, nameOf), nil, "never over this player's own vehicle")
		h.eq(Rules.labelText({ BotName = "Rex", IsBoss = true }, 42, nameOf), nil, "boss has its own card")
		h.eq(Rules.labelText({}, 42, nameOf), nil)
		local long = Rules.labelText({ BotName = string.rep("é", 30) }, 42, nil) :: string
		h.eq(utf8.len(long), Rules.LABEL_MAX_CHARS, "cut to the cap on a character boundary")
	end)

	h.test("one field size: grid slots and the bot roster follow AI_FIELD_SIZE; the server size is its own", function()
		h.eq(PlaneConfig.MAX_PLAYERS, PlaneConfig.SERVER_SIZE, "player cap = server size")
		h.eq(PlaneConfig.AI_COUNT, PlaneConfig.AI_FIELD_SIZE - 1, "roster fills every seat but one player's")
		h.ok(#PlaneConfig.AI_BOTS >= PlaneConfig.AI_FIELD_SIZE - 1, "enough roster bots for a solo race")
		h.ok(PlaneConfig.HUB_SEATS >= 1 and PlaneConfig.HUB_SEATS % 4 == 0, "hub seats fill whole rows of four")
		local project = h.readFile("default.project.json")
		local maxPlayers = tonumber(string.match(project, '"MaxPlayers"%s*:%s*(%d+)'))
		h.eq(maxPlayers, PlaneConfig.SERVER_SIZE, "default.project.json MaxPlayers = server size")
		-- Single-race path (RaceFlowRules.PER_GROUP false) seats every player in one field: the server cannot outgrow it.
		local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")
		h.ok(RaceFlowRules.PER_GROUP or PlaneConfig.SERVER_SIZE <= PlaneConfig.AI_FIELD_SIZE, "server <= field while one race")
		local adapt = h.readFile("tools/map/adapt.py")
		local gridSlots = tonumber(string.match(adapt, "\nGRID_SLOTS = (%d+)"))
		h.eq(gridSlots, PlaneConfig.AI_FIELD_SIZE, "tools/map/adapt.py bakes one start slot per entrant")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- Camera-near fade (grid-order regression: the chase camera sat inside the racer one row behind on the grid).

	h.test("near fade: box distance and sightline maths", function()
		local half = Vector3.new(8, 2.5, 7)
		h.eq(Rules.boxDistance(Vector3.new(0, 0, 0), half), 0, "inside")
		h.eq(Rules.boxDistance(Vector3.new(11, 0, 0), half), 3, "beside a wingtip")
		h.ok(math.abs(Rules.boxDistance(Vector3.new(11, 6.5, -7), half) - 5) < 1e-9, "off a corner")
		local q = Rules.segmentPoint(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10), Vector3.new(3, 0, -4))
		h.ok((q - Vector3.new(0, 0, -4)).Magnitude < 1e-9, "closest point inside the segment")
		q = Rules.segmentPoint(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10), Vector3.new(0, 0, 5))
		h.ok(q.Magnitude < 1e-9, "clamped to the start")
		h.eq(Rules.nearFade(0), Rules.NEAR_MAX)
		h.eq(Rules.nearFade(Rules.NEAR_HIDE), Rules.NEAR_MAX)
		h.eq(Rules.nearFade(Rules.NEAR_CLEAR), 0)
		local prev = Rules.NEAR_MAX
		for d = Rules.NEAR_HIDE, Rules.NEAR_CLEAR, 0.25 do
			local f = Rules.nearFade(d)
			h.ok(f <= prev + 1e-9, "near fade falls with distance")
			prev = f
		end
		h.ok(Rules.SIGHT_MAX < 1 and Rules.SIGHT_MAX > 0.3, "a racer in the sightline stays a readable ghost")
	end)

	h.test("near fade: targets for a racer at the lens, in the sightline, alongside, far and behind", function()
		local half = Vector3.new(8, 2.5, 7)
		local cam = Vector3.new(0, 15.5, 15.2) -- 15.2 behind and 4.5 above a vehicle at (0, 11, 0) flying -Z
		local own = Vector3.new(0, 11, 0)
		local look = (Vector3.new(0, 12.2, -32) - cam).Unit
		local function target(at: Vector3): number
			return Rules.fadeTarget(CFrame.new(at), half, cam, look, own)
		end
		h.eq(target(cam + Vector3.new(0, -3, 0)), Rules.NEAR_MAX, "a racer under the lens is gone")
		h.eq(target(Vector3.new(14, 15.5, 15.2)), 0, "a wingtip 6 studs beside the lens is left alone")
		local wing = target(Vector3.new(10.5, 15.5, 15.2))
		h.ok(wing > 0 and wing < Rules.NEAR_MAX, "a wingtip 2.5 studs beside the lens fades part-way")
		-- A small racer (a fallen kart, a walker's leg) between the camera and the vehicle, clear of the lens itself.
		local small = Vector3.new(2, 1, 2)
		h.eq(Rules.fadeTarget(CFrame.new(0, 13, 7), small, cam, look, own), Rules.SIGHT_MAX, "in the sightline: ghosted")
		h.eq(Rules.fadeTarget(CFrame.new(6, 13, 7), small, cam, look, own), 0, "4 studs off the sightline: left alone")
		h.eq(target(Vector3.new(17, 11, 0)), 0, "a racer alongside the vehicle (one span out) is left alone")
		h.eq(target(Vector3.new(0, 11, -60)), 0, "a racer ahead is left alone")
		h.eq(target(Vector3.new(0, 11, 15.2 + 13)), 0, "a racer wholly behind the camera is not faded (it cannot be seen)")
		-- Without a vehicle (spectating) only the near fade applies.
		h.eq(Rules.fadeTarget(CFrame.new(0, 13, 7), small, cam, look, nil), 0)
	end)

	h.test("near fade eases in and out without a pop and writes parts only when it moved", function()
		local shown = Rules.approachFade(0, 1, 1 / 60)
		h.ok(shown > 0 and shown < 0.25, "one frame is a small step")
		for _ = 1, 40 do
			shown = Rules.approachFade(shown, 1, 1 / 60)
		end
		h.eq(shown, 1, "settles exactly on the target")
		for _ = 1, 40 do
			shown = Rules.approachFade(shown, 0, 1 / 60)
		end
		h.eq(shown, 0, "settles back to exactly 0 (parts restored)")
		h.eq(Rules.shouldWrite(0.5, 0.5), false)
		h.eq(Rules.shouldWrite(0.505, 0.5), false, "tiny moves are not rewritten")
		h.eq(Rules.shouldWrite(0.53, 0.5), true)
		h.eq(Rules.shouldWrite(0, 0.01), true, "the final 0 is always written")
		h.eq(Rules.shouldWrite(Rules.NEAR_MAX, Rules.NEAR_MAX - 0.01), true, "the full fade is always written")
	end)

	-- adapt.py grid_slot: slot 1 on the centre line at the grid station, then pairs (+lane, -lane) one row further on.
	local function gridSlot(k: number, station: number, rowSpacing: number, laneOffset: number): (number, number)
		if k == 1 then
			return station, 0
		end
		return station + ((k - 1) // 2) * rowSpacing, if k % 2 == 0 then laneOffset else -laneOffset
	end

	-- Worst fade any neighbour gets on the screen of a player in any slot (straight start along -Z, slots at one height).
	local function worstGridFade(grid: { station: number, rowSpacing: number, laneOffset: number }, camBack: number,
		camUp: number, lookAhead: number, lookUp: number, half: Vector3): (number, string)
		local worst, at = 0, "none"
		for k = 1, PlaneConfig.AI_FIELD_SIZE do
			local st, lat = gridSlot(k, grid.station, grid.rowSpacing, grid.laneOffset)
			local pos = Vector3.new(lat, 0, -st)
			local forward = Vector3.new(0, 0, -1)
			local cam = Rules.chaseCameraPos(pos, forward, camBack, camUp)
			local look = (pos + forward * lookAhead + Vector3.new(0, lookUp, 0) - cam).Unit
			for j = 1, PlaneConfig.AI_FIELD_SIZE do
				if j ~= k then
					local sj, lj = gridSlot(j, grid.station, grid.rowSpacing, grid.laneOffset)
					local f = Rules.fadeTarget(CFrame.new(lj, 0, -sj), half, cam, look, pos)
					if f > worst then
						worst, at = f, string.format("slot %d on the screen of slot %d", j, k)
					end
				end
			end
		end
		return worst, at
	end

	local AVOID = PlaneConfig.AI_AVOID
	local PLANE_HALF = Vector3.new(AVOID.span / 2, AVOID.clearHeight / 2, AVOID.length / 2)

	h.test("start grid: no neighbour fades on a plane player's screen from any slot (legacy grid = DINO-4 plan)", function()
		local worst, at = worstGridFade(PlaneConfig.AI_GRID, PlaneConfig.CAM_DISTANCE, PlaneConfig.CAM_HEIGHT, 32, 1.2, PLANE_HALF)
		h.eq(worst, 0, "worst fade on the plane grid: " .. at)
		-- The pre-fix grid (rows 14, lanes 8) put the row behind inside the camera: the regression this guards.
		local old, oldAt = worstGridFade({ station = 18, rowSpacing = 14, laneOffset = 8 }, PlaneConfig.CAM_DISTANCE,
			PlaneConfig.CAM_HEIGHT, 32, 1.2, PLANE_HALF)
		h.ok(old > 0.5, "the old grid faded a neighbour (" .. oldAt .. ")")
	end)

	h.test("start grid: every map plan's startGrid clears its vehicle's chase camera", function()
		local CarConfig = h.require("src/shared/CarConfig.luau")
		local carHalf = Vector3.new(CarConfig.HALF_WIDTH, 2.5, CarConfig.HALF_LENGTH)
		for _, key in { "dino4", "forest1", "snow1", "island2", "space4", "hub0", "teststrip" } do
			local plan = h.readFile("map/" .. key .. "/plan.json")
			local vehicle = string.match(plan, '"vehicle":%s*"(%a+)"')
			local body = string.match(plan, '"startGrid":%s*(%b{})') :: string
			local grid = {
				station = tonumber(string.match(body, '"station":%s*([%d%.]+)')) :: number,
				rowSpacing = tonumber(string.match(body, '"rowSpacing":%s*([%d%.]+)')) :: number,
				laneOffset = tonumber(string.match(body, '"laneOffset":%s*([%d%.]+)')) :: number,
			}
			local worst, at
			if vehicle == "car" then
				worst, at = worstGridFade(grid, CarConfig.CAM_DISTANCE, CarConfig.CAM_HEIGHT, CarConfig.CAM_LOOK_AHEAD,
					CarConfig.CAM_LOOK_HEIGHT, carHalf)
			else
				worst, at = worstGridFade(grid, PlaneConfig.CAM_DISTANCE, PlaneConfig.CAM_HEIGHT, 32, 1.2, PLANE_HALF)
			end
			h.eq(worst, 0, key .. " (" .. tostring(vehicle) .. ") worst fade: " .. at)
		end
	end)

	h.test("tools/map/adapt.py grid_camera_gate uses the live camera, vehicle and fade numbers", function()
		local CarConfig = h.require("src/shared/CarConfig.luau")
		local adapt = h.readFile("tools/map/adapt.py")
		local function pyNum(pattern: string): number?
			return tonumber(string.match(adapt, pattern))
		end
		local plane = string.match(adapt, '"plane": (%b{})') :: string
		local car = string.match(adapt, '"car": (%b{})') :: string
		h.eq(tonumber(string.match(plane, '"camBack": ([%d%.]+)')), PlaneConfig.CAM_DISTANCE, "plane camera distance")
		h.eq(tonumber(string.match(plane, '"camUp": ([%d%.]+)')), PlaneConfig.CAM_HEIGHT, "plane camera height")
		local px, py, pz = string.match(plane, '"half": %(([%d%.]+), ([%d%.]+), ([%d%.]+)%)')
		h.eq(tonumber(px), AVOID.span / 2, "plane half span")
		h.eq(tonumber(py), AVOID.clearHeight / 2, "plane half height")
		h.eq(tonumber(pz), AVOID.length / 2, "plane half length")
		h.eq(tonumber(string.match(car, '"camBack": ([%d%.]+)')), CarConfig.CAM_DISTANCE, "car camera distance")
		h.eq(tonumber(string.match(car, '"camUp": ([%d%.]+)')), CarConfig.CAM_HEIGHT, "car camera height")
		local cx, _, cz = string.match(car, '"half": %(([%d%.]+), ([%d%.]+), ([%d%.]+)%)')
		h.eq(tonumber(cx), CarConfig.HALF_WIDTH, "car half width")
		h.eq(tonumber(cz), CarConfig.HALF_LENGTH, "car half length")
		h.eq(pyNum("\nGRID_NEAR_CLEAR = ([%d%.]+)"), Rules.NEAR_CLEAR, "near clearance")
		h.eq(pyNum("\nGRID_SIGHT_CLEAR = ([%d%.]+)"), Rules.SIGHT_CLEAR, "sightline clearance")
		h.eq(pyNum("\nGRID_SIGHT_OWN_MARGIN = ([%d%.]+)"), Rules.SIGHT_OWN_MARGIN, "sightline stop short of the vehicle")
	end)
end
