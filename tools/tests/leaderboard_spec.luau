-- Hub leaderboards (shared/LeaderboardRules, server/Leaderboards; social lane): which finishes may post a time (server race
-- clock only; AutoPilot, QA, simulated, untimed modes and impossible times refused), the stars definition, keep-best writes
-- through a throttled retrying queue, the cached top 10 with backoff and budget checks, the viewer's own line, and the
-- board's single placement constant.
return function(h)
	local R = h.require("src/shared/LeaderboardRules.luau")
	local L = h.require("src/server/Leaderboards.luau")

	local function race(over)
		local info = { trackId = "DINO-4", mode = "race", finished = true, time = 95.25, simulated = false }
		for k, v in over or {} do
			info[k] = v
		end
		return info
	end

	h.test("timeEntry: a real finish becomes integer milliseconds from the race clock", function()
		h.eq({ R.timeEntry(race(), { totalLen = 3600, laps = 3 }) }, { 95250, "ok" })
		h.eq((R.timeEntry(race({ time = 95.2506 }))), 95251, "rounded to the nearest ms")
		for _, mode in { "race", "timetrial", "quickrace" } do
			h.ok(R.timeEntry(race({ mode = mode })) ~= nil, mode)
		end
	end)

	h.test("timeEntry: AutoPilot, QA, simulated and unfinished runs never post", function()
		h.eq({ R.timeEntry(race(), { autopilot = true }) }, { nil, "autopilot run" })
		h.eq({ R.timeEntry(race(), { qa = true }) }, { nil, "qa run" })
		h.eq({ R.timeEntry(race({ simulated = true })) }, { nil, "simulated finish" })
		h.eq({ R.timeEntry(race({ finished = false })) }, { nil, "not finished" })
	end)

	h.test("timeEntry: only the five race tracks and only timed modes", function()
		for _, mode in { "coin", "boss", "rematch", "battle", "stormcup" } do
			h.eq({ R.timeEntry(race({ mode = mode })) }, { nil, "untimed mode" }, mode)
		end
		h.eq({ R.timeEntry(race({ trackId = "HUB-0" })) }, { nil, "not a race track" })
		h.eq({ R.timeEntry(race({ trackId = "TEST-STRIP" })) }, { nil, "not a race track" })
		for _, id in R.RACE_TRACKS do
			h.ok(R.timeEntry(race({ trackId = id })) ~= nil, id)
		end
	end)

	h.test("timeEntry: times no legal flight can reach, NaN, infinity and endless runs are refused", function()
		-- 3 laps of a 4000-stud spline at the speed ceiling with the 0.65 shortcut allowance: about 30 s
		local floor = R.minSeconds(4000, 3)
		h.ok(floor > 29 and floor < 31, "minimum for DINO-sized track " .. tostring(floor))
		h.eq({ R.timeEntry(race({ time = 12 }), { totalLen = 4000, laps = 3 }) }, { nil, "faster than any legal flight" })
		h.ok(R.timeEntry(race({ time = 31 }), { totalLen = 4000, laps = 3 }) ~= nil)
		h.eq({ R.timeEntry(race({ time = 5 })) }, { nil, "faster than any legal flight" }, "no spline: the absolute floor")
		h.eq(R.minSeconds(nil, nil), 20)
		h.eq(R.minSeconds(0 / 0, 3), 20)
		h.eq({ R.timeEntry(race({ time = 0 / 0 })) }, { nil, "bad time" })
		h.eq({ R.timeEntry(race({ time = math.huge })) }, { nil, "bad time" })
		h.eq({ R.timeEntry(race({ time = 5000 })) }, { nil, "too slow for a board" })
	end)

	h.test("stars: race token, coin token and the zone's boss are one star each; SPACE uses the final boss", function()
		local p = { tokens = {}, boss = {}, finalBoss = false }
		h.eq(R.trackStars(p, "DINO-4"), 0)
		p.tokens["race:DINO-4"] = true
		h.eq(R.trackStars(p, "DINO-4"), 1)
		p.tokens["coin:DINO-4"] = true
		h.eq(R.trackStars(p, "DINO-4"), 2)
		p.boss["DINO-4"] = { first = true, rematch = false }
		h.eq(R.trackStars(p, "DINO-4"), 3)
		h.eq(R.trackStars(p, "SNOW-1"), 0, "other tracks unaffected")
		p.tokens["race:SPACE-4"] = true
		h.eq(R.trackStars(p, "SPACE-4"), 1, "SPACE has no boss yet")
		p.finalBoss = true
		h.eq(R.trackStars(p, "SPACE-4"), 2, "the final boss is SPACE's third star slot")
		h.eq(R.trackStars(p, "HUB-0"), 0, "the hub loop has no stars")
		h.eq(R.totalStars(p), 5)
		h.eq(R.totalStars(nil), 0)
		h.eq(R.trackStars({ tokens = { ["race:DINO-4"] = false } }, "DINO-4"), 0, "a false flag is not a star")
	end)

	h.test("totalStars tops out at MAX_STARS", function()
		local p = { tokens = {}, boss = {}, finalBoss = true }
		for _, id in R.RACE_TRACKS do
			p.tokens["race:" .. id] = true
			p.tokens["coin:" .. id] = true
			p.boss[id] = { first = true }
		end
		h.eq(R.totalStars(p), R.MAX_STARS)
	end)

	h.test("text: times, values, names and the viewer's own line", function()
		h.eq(R.formatTime(83456), "1:23.456")
		h.eq(R.formatTime(59250), "59.250")
		h.eq(R.formatTime(600000), "10:00.000")
		h.eq(R.formatTime(nil), "--")
		h.eq(R.formatTime(0 / 0), "--")
		h.eq(R.formatValue("stars", 12), "12")
		h.eq(R.shortName("AVeryLongPlayerNameIndeed", 16), "AVeryLongPlayer.")
		h.eq(R.shortName("", 16), "Player")
		local rows = { { userId = 5, value = 90000 }, { userId = 7, value = 91000 } }
		h.eq(R.ownLine("time", rows, 7, 91000), "YOU  #2  1:31.000")
		h.eq(R.ownLine("time", rows, 9, nil), "Finish this race to get on the board")
		h.eq(R.ownLine("stars", {}, 9, nil), "Earn stars to get on the board")
		h.eq(R.ownLine("time", rows, 9, 99000), "YOU  1:39.000  (posting...)", "board has room: not written yet")
		local full = {}
		for i = 1, 10 do
			table.insert(full, { userId = 100 + i, value = 80000 + i })
		end
		h.eq(R.ownLine("time", full, 9, 99000), "YOU  1:39.000  (outside the top 10)")
		h.eq(R.ownAttribute("best:DINO-4"), "LbBest_DINO_4")
		h.eq(R.ownAttribute("stars"), "LbStars")
	end)

	h.test("cleanRows: bad keys and values are dropped, at most ten rows", function()
		local raw = { { key = "123", value = 5 }, { key = "abc", value = 6 }, { key = "9", value = 0 / 0 }, { key = "-4", value = 3 }, { key = "77", value = 8 } }
		h.eq(R.cleanRows(raw), { { userId = 123, value = 5 }, { userId = 77, value = 8 } })
		local many = {}
		for i = 1, 25 do
			table.insert(many, { key = tostring(i), value = i })
		end
		h.eq(#R.cleanRows(many), 10)
		h.eq(R.cleanRows(nil), {})
	end)

	h.test("boards: five best-time boards (ascending) then stars (descending), each with its own store", function()
		local b = R.boards({ ["DINO-4"] = "Molten Cavern" })
		h.eq(#b, 6)
		h.eq(b[1].id, "best:DINO-4")
		h.ok(b[1].ascending and b[1].kind == "time")
		h.eq(b[1].title, "BEST TIMES - MOLTEN CAVERN")
		h.eq(b[6].id, "stars")
		h.ok(not b[6].ascending)
		local seen = {}
		for _, x in b do
			h.ok(not seen[x.store], "unique store " .. x.store)
			seen[x.store] = true
		end
	end)

	h.test("timing: refresh every 120 s, doubling backoff after failures up to 10 minutes, budget gate", function()
		h.eq(R.REFRESH_SECONDS, 120)
		h.eq(R.nextRefreshDelay(0), 120)
		h.eq(R.nextRefreshDelay(1), 30)
		h.eq(R.nextRefreshDelay(2), 60)
		h.eq(R.nextRefreshDelay(3), 120)
		h.eq(R.nextRefreshDelay(9), 600)
		h.ok(R.canRead(8, 6) and not R.canRead(7, 6))
		h.eq(R.ROWS, 10)
	end)

	h.test("queue: merges the better value per key, honours retry times, drops after the attempt limit", function()
		local q = R.newQueue()
		q.push("s", "1", 90000, true)
		q.push("s", "1", 88000, true)
		q.push("s", "1", 99000, true)
		q.push("s", "2", 5, false)
		q.push("s", "2", 9, false)
		h.eq(q.size(), 2)
		local j1 = q.pop(0)
		h.eq(j1.value, 88000, "best (lowest) time kept")
		local j2 = q.pop(0)
		h.eq(j2.value, 9, "most stars kept")
		h.eq(q.pop(0), nil)
		h.ok(q.retry(j1, 10))
		h.eq(q.pop(10), nil, "waiting out its retry delay")
		h.ok(q.pop(10 + R.WRITE_RETRY_BASE) ~= nil)
		local job = { store = "s", key = "k", value = 1, ascending = true, attempts = R.WRITE_ATTEMPTS - 1, notBefore = 0 }
		h.ok(not q.retry(job, 0), "the last attempt fails: dropped")
		h.eq(R.merge(nil, 5, true), 5)
		h.eq(R.merge(4, 5, true), 4)
		h.eq(R.merge(4, 5, false), 5)
	end)

	h.test("board placement: one constant, on the plaza, facing the spawn, off the spawn grid", function()
		local B = R.BOARD
		h.eq(B.pos.Y, 26, "plaza paving")
		local spawn = h.require("build/hub0/TrackData.luau")
		local sp = spawn.hub.spawn.cf.Position
		h.ok((B.pos - sp).Magnitude > 40 and (B.pos - sp).Magnitude < 120, "near the spawn, not on it")
		-- the spawn grid sits behind the spawn: rows at +16 studs along the frame's back vector, columns +-18 along its right
		for row = 0, 1 do
			for col = 0, 3 do
				local slot = spawn.hub.spawn.cf * CFrame.new((col - 1.5) * 12, 3, row * 16)
				h.ok((Vector3.new(slot.X, 0, slot.Z) - Vector3.new(B.pos.X, 0, B.pos.Z)).Magnitude > 30, "clear of grid slot")
			end
		end
		local portalMin = math.huge
		for _, portal in spawn.hub.portals do
			portalMin = math.min(portalMin, (Vector3.new(portal.cf.X, 0, portal.cf.Z) - Vector3.new(B.pos.X, 0, B.pos.Z)).Magnitude)
		end
		h.ok(portalMin > 60, "clear of the portal arcs")
	end)

	-- -------------------------------------------------------------------------------------------------- service

	local function newService(over)
		local backend = L.memoryBackend()
		local sched = h.newScheduler(100)
		local profiles = {}
		local opts = {
			backend = backend,
			clock = sched.clock,
			profileOf = function(p)
				return profiles[p]
			end,
			nameOf = function(id)
				return "User" .. id
			end,
			log = function() end,
		}
		for k, v in over or {} do
			opts[k] = v
		end
		return L.new(opts), backend, sched, profiles
	end

	local function drain(svc, sched, limit)
		for _ = 1, limit or 40 do
			svc.step()
			sched.advance(1.1)
			if svc.queueSize() == 0 then
				break
			end
		end
	end

	local function topOf(backend, svc, id)
		for _, b in svc.boards do
			if b.id == id then
				local _, rows = backend.top(b.store, b.ascending, 10)
				return rows
			end
		end
	end

	h.test("service: a personal best posts once; a slower repeat never worsens the record", function()
		local svc, backend, sched, profiles = newService()
		local p = h.fakePlayer(1001, "Ada")
		profiles[p] = { bestTimes = { ["DINO-4"] = 95250 }, tokens = { ["race:DINO-4"] = true } }
		h.eq(svc.onFinish(p, race(), { bestTimeResult = "awarded", bestTimeMs = 95250 }, { totalLen = 4000, laps = 3 }), "queued")
		drain(svc, sched)
		local rows = topOf(backend, svc, "best:DINO-4")
		h.eq(rows, { { key = "1001", value = 95250 } })
		h.eq(p:GetAttribute("LbBest_DINO_4"), 95250, "the player's own value rides on an attribute")
		h.eq(p:GetAttribute("LbStars"), 1)
		-- a slower finish: SaveService says noop, so nothing is queued
		h.eq(svc.onFinish(p, race({ time = 99 }), { bestTimeResult = "noop" }, nil), "no personal best")
		-- even a forced slower write cannot overwrite the record (UpdateAsync keeps the better)
		local slow = L.memoryBackend()
		slow.update("x", "1", function(old)
			return R.merge(old, 90000, true)
		end)
		slow.update("x", "1", function(old)
			return R.merge(old, 99000, true)
		end)
		local _, got = slow.top("x", true, 1)
		h.eq(got[1].value, 90000)
	end)

	h.test("service: AutoPilot, QA, simulated, boss and Storm Cup finishes post nothing", function()
		local svc, backend, sched, profiles = newService()
		local p = h.fakePlayer(1002, "Bot")
		profiles[p] = { bestTimes = {}, tokens = {} }
		local award = { bestTimeResult = "awarded" }
		h.eq(svc.onFinish(p, race(), award, { autopilot = true }), "autopilot run")
		h.eq(svc.onFinish(p, race(), award, { qa = true }), "qa run")
		h.eq(svc.onFinish(p, race({ simulated = true }), award, nil), "simulated finish")
		h.eq(svc.onFinish(p, race({ mode = "boss" }), award, nil), "untimed mode")
		h.eq(svc.onFinish(p, race({ mode = "stormcup" }), award, nil), "untimed mode")
		h.eq(svc.queueSize(), 0)
		drain(svc, sched)
		h.eq(#topOf(backend, svc, "best:DINO-4"), 0)
	end)

	h.test("service: profile load backfills saved best times and stars once per join", function()
		local svc, backend, sched, profiles = newService()
		local p = h.fakePlayer(1003, "Veteran")
		profiles[p] = {
			bestTimes = { ["DINO-4"] = 100000, ["SNOW-1"] = 5, ["SPACE-4"] = 130500 }, -- SNOW-1's 5 ms is junk
			tokens = { ["race:DINO-4"] = true, ["coin:DINO-4"] = true },
			boss = { ["DINO-4"] = { first = true } },
		}
		svc.onLoaded(p)
		svc.onLoaded(p) -- a second call changes nothing
		h.eq(svc.queueSize(), 3, "two sane times + the star total")
		drain(svc, sched)
		h.eq(topOf(backend, svc, "best:DINO-4")[1].value, 100000)
		h.eq(#topOf(backend, svc, "best:SNOW-1"), 0, "an impossible saved time is not posted")
		h.eq(topOf(backend, svc, "best:SPACE-4")[1].value, 130500)
		h.eq(topOf(backend, svc, "stars")[1].value, 3)
		h.eq(p:GetAttribute("LbStars"), 3)
	end)

	h.test("service: refresh caches a sorted top 10 with names; boards order correctly", function()
		local svc, backend, sched = newService()
		for i = 1, 12 do
			backend.update(svc.boards[1].store, tostring(2000 + i), function()
				return 90000 + (13 - i) * 100
			end)
		end
		backend.update(svc.boards[6].store, "2001", function()
			return 7
		end)
		backend.update(svc.boards[6].store, "2002", function()
			return 11
		end)
		h.ok(svc.refresh())
		local pages = svc.pages()
		h.eq(#pages, 6)
		h.eq(#pages[1].rows, 10, "top 10 only")
		h.eq(pages[1].rows[1].userId, 2012, "fastest first")
		h.eq(pages[1].rows[1].name, "User2012")
		h.eq(pages[1].rows[1].value, 90100)
		h.eq(pages[6].rows[1].userId, 2002, "stars: most first")
		h.eq(svc.version(), 1)
		sched.advance(0)
	end)

	h.test("service: the step reads again only after 120 s; a failing read backs off and keeps the old rows", function()
		local reads = 0
		local failing = false
		local svc, backend, sched = newService()
		local realTop = backend.top
		backend.top = function(...)
			reads += 1
			if failing then
				return false, "503"
			end
			return realTop(...)
		end
		backend.update(svc.boards[1].store, "3001", function()
			return 91000
		end)
		svc.step()
		h.eq(reads, 6, "one page per board")
		sched.advance(119)
		svc.step()
		h.eq(reads, 6, "still cached at 119 s")
		sched.advance(2)
		failing = true
		svc.step()
		h.eq(reads, 12, "refresh at 121 s")
		h.eq(svc.pages()[1].rows[1].userId, 3001, "a failed read keeps the cached rows")
		sched.advance(29)
		svc.step()
		h.eq(reads, 12, "backoff: 30 s after the first failure")
		sched.advance(2)
		failing = false
		svc.step()
		h.eq(reads, 18, "retried after the backoff and recovered")
		sched.advance(121)
		svc.step()
		h.eq(reads, 24, "back on the 120 s period")
	end)

	h.test("service: a low read budget postpones the refresh instead of spending it", function()
		local svc, backend, sched = newService()
		local budget = 3
		backend.readBudget = function()
			return budget
		end
		local reads = 0
		local realTop = backend.top
		backend.top = function(...)
			reads += 1
			return realTop(...)
		end
		svc.step()
		h.eq(reads, 0, "budget 3 < 6 boards + reserve")
		sched.advance(31)
		budget = 50
		svc.step()
		h.eq(reads, 6)
	end)

	h.test("service: a failing write retries with a delay and gives up after five tries; a low write budget waits", function()
		local svc, backend, sched, profiles = newService()
		local p = h.fakePlayer(4001, "Flaky")
		profiles[p] = { bestTimes = { ["DINO-4"] = 95250 }, tokens = {} }
		local attempts = 0
		backend.update = function()
			attempts += 1
			return false, "datastore down"
		end
		svc.onFinish(p, race(), { bestTimeResult = "awarded" }, nil)
		svc.step()
		h.eq(attempts, 1)
		svc.step()
		h.eq(attempts, 1, "inside the write gap and the retry delay")
		for _ = 1, 80 do
			sched.advance(5)
			svc.step()
		end
		h.eq(attempts, 5, "five attempts, then dropped")
		h.eq(svc.queueSize(), 0)
		-- budget
		local svc2, backend2, sched2, profiles2 = newService()
		local q = h.fakePlayer(4002, "Budget")
		profiles2[q] = { bestTimes = { ["DINO-4"] = 95250 }, tokens = {} }
		local budget = 2
		backend2.writeBudget = function()
			return budget
		end
		svc2.onFinish(q, race(), { bestTimeResult = "awarded" }, nil)
		svc2.step()
		h.eq(svc2.queueSize(), 1, "write budget at the reserve: not spent")
		budget = 60
		sched2.advance(10)
		svc2.step()
		h.eq(svc2.queueSize(), 0)
	end)

	h.test("service: names come from the player in the server first, then the lookup (capped), then 'Player'", function()
		local lookups = 0
		local svc, backend = newService({
			nameOf = function(id)
				lookups += 1
				if id == 6003 then
					error("no such user")
				end
				return "Remote" .. id
			end,
		})
		local here = h.fakePlayer(6001, "InServer")
		table.insert(h.stubs.Players.list, here)
		for _, id in { 6001, 6002, 6003 } do
			backend.update(svc.boards[1].store, tostring(id), function()
				return 90000 + id
			end)
		end
		svc.refresh()
		local rows = svc.pages()[1].rows
		h.eq(rows[1].name, "InServer")
		h.eq(rows[2].name, "Remote6002")
		h.eq(rows[3].name, "Player", "a failed lookup falls back")
		local before = lookups
		svc.pages()
		h.eq(lookups, before, "neither cached names nor a just-failed one are looked up again")
		h.stubs.Players.list = {}
	end)

	h.test("static: the board is built by the server, the own line by the client; RaceManager hands finishes over after the award", function()
		local board = h.readFile("src/server/HubBoard.luau")
		h.contains(board, "SurfaceGui")
		h.contains(board, "LeaderboardRules.BOARD")
		h.contains(board, "OwnLine")
		local client = h.readFile("src/client/LeaderboardBoard.luau")
		h.contains(client, "OwnLine")
		h.ok(not string.find(client, "FireServer", 1, true), "no remote")
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "RaceManager.finishHook")
		local awardAt = string.find(rm, "pcall(RaceManager.awardFinish", 1, true)
		local hookAt = string.find(rm, "local finishHook = RaceManager.finishHook", 1, true)
		h.ok(awardAt ~= nil and hookAt ~= nil and hookAt > awardAt, "the hook runs after the saved award")
	end)
end
