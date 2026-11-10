--!strict
-- Lune spec for the Storm Cup and Festival schedule: src/server/StormCup.luau over EconomyRules (TEST_LIST_LAUNCH L54;
-- MONETIZATION_PROPOSAL "Storm Cup every 30 minutes", "Festival window"), and the cup's payouts through the REAL
-- Economy over a REAL SaveService (memory store).
-- Run: tools/tests/run_lune_tests.sh tools/tests/stormcup_spec.luau
-- Servers here are fakes of what StormCup reads (RaceMode, TrackDirector.switching, all-finished time, player count)
-- with their own UTC clocks, so two "servers" can be stepped side by side with different tick phases and clock skew.

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
}

local DAY = 86400
local S1_START = 1794009600 -- Saturday 2026-11-07 00:00 UTC (season 1 start, MonetizationConfig.WIN_PASS)
local NEW_YEAR = 1798761600 -- Friday 2027-01-01 00:00 UTC
local SUNDAY_10 = S1_START + DAY + 10 * 3600 -- inside season 1, no Festival window

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local StormCup = h.require("src/server/StormCup.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local Economy = h.require("src/server/Economy.luau")
	local V3 = Vector3.new
	local rules = EconomyRules.default
	local SC = MonetizationConfig.STORM_CUP

	-- A fake server: what StormCup reads each tick, and what it launched.
	local function newServer(t: number, opts: { [string]: any }?): any
		local o: any = opts or {}
		local w: any = {
			t = t, -- the server's own UTC clock (skew is added by the caller)
			mode = "hub",
			switching = false,
			finishedFor = nil,
			players = 1,
			enabled = true,
			mounted = {} :: { [string]: boolean },
			attrs = {} :: { [string]: any },
			launches = {} :: { any },
			logs = {} :: { string },
			force = false,
		}
		w.svc = StormCup.new({
			rules = o.rules,
			now = function(): number
				return w.t
			end,
			enabled = function(): boolean
				return w.enabled
			end,
			world = function(): any
				return { mode = w.mode, switching = w.switching, finishedFor = w.finishedFor, players = w.players }
			end,
			hasTrack = function(id: string): boolean
				return w.mounted[id] ~= false
			end,
			launch = function(cup: any): boolean
				table.insert(w.launches, { cup = cup, at = w.t })
				w.mode = StormCup.MODE
				return true
			end,
			setAttr = function(name: string, value: any)
				w.attrs[name] = value
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			forceNext = function(): boolean
				local f = w.force
				w.force = false
				return f
			end,
		})
		-- Steps every TICK of this server's clock for `seconds`.
		function w.run(seconds: number)
			local stop = w.t + seconds
			while w.t < stop do
				w.svc.step()
				w.t += StormCup.TICK
			end
		end
		return w
	end

	---------------------------------------------------------------------------------------------- slot math

	h.test("slot math: cups at :00/:30 UTC across hour, day, month and year boundaries; lobby a minute before", function()
		for _, t in { NEW_YEAR - 1, NEW_YEAR, NEW_YEAR + 1, S1_START - 0.5, S1_START + 1799.9, 1792366199, 1792366200 } do
			local cur = rules.stormCupCurrent(t)
			local nxt = rules.stormCupNext(t)
			h.ok(cur.startsAt <= t and t < cur.startsAt + 1800, "current cup contains t=" .. tostring(t))
			h.eq(cur.startsAt % 1800, 0, "starts on a :00/:30 boundary")
			h.ok(cur.startsAt % 3600 == 0 or cur.startsAt % 3600 == 1800, "minute 00 or 30")
			h.eq(nxt.startsAt, cur.startsAt + 1800, "next is exactly one period later")
			h.eq(nxt.lobbyOpensAt, nxt.startsAt - SC.lobbySeconds)
		end
		-- New Year: 23:59:59 still belongs to the 23:30 cup; midnight opens a new cup with the next map and modifier.
		local before = rules.stormCupCurrent(NEW_YEAR - 1)
		local at = rules.stormCupCurrent(NEW_YEAR)
		h.eq(before.startsAt, NEW_YEAR - 1800)
		h.eq(at.startsAt, NEW_YEAR)
		h.eq(at.index, before.index + 1)
		h.eq(at.index, NEW_YEAR // 1800)
		h.eq(rules.stormCupNext(NEW_YEAR - 1).startsAt, NEW_YEAR, "the cup after 23:59:59 is midnight")
		-- 2026-10-18 23:29:59 -> 23:30:00 (a day's last :30).
		h.eq(rules.stormCupNext(1792366199).startsAt, 1792366200)
		h.eq(rules.stormCupCurrent(1792366200).startsAt, 1792366200)
		h.eq(StormCup.clockText(61.2), "1:02")
		h.eq(StormCup.clockText(-3), "0:00")
	end)

	h.test("slot math: a server fires the cup on the slot tick, never before, and only once", function()
		local slot = NEW_YEAR
		local w = newServer(slot - 90)
		w.run(89)
		h.eq(#w.launches, 0, "nothing before the slot")
		h.eq(w.attrs.StormCupState, "lobby", "the lobby minute is announced")
		h.eq(w.attrs.StormCupAt, slot)
		h.ok(w.svc.holdReason(w.t) ~= nil, "the hub holds new races in the lobby minute")
		w.run(2)
		h.eq(#w.launches, 1, "fires at the slot")
		h.ok(w.launches[1].at >= slot and w.launches[1].at < slot + StormCup.TICK + 1e-6, "on the first tick at or after the slot")
		h.eq(w.launches[1].cup.index, slot // 1800)
		w.mode = "hub" -- the cup race ended and the server is back in the hub before the half hour is up
		w.run(1500)
		h.eq(#w.launches, 1, "the same cup never runs twice on one server")
		h.eq(w.attrs.StormCupAt, slot + 1800, "the HUD now counts to the next cup")
		h.contains(w.logs, "[SkyRally][STORM] launch cup=" .. tostring(slot // 1800))
	end)

	---------------------------------------------------------------------------------------------- two servers (L54)

	h.test("two independent servers start the same cup within 2 s (different tick phase and clock skew)", function()
		local slot = S1_START + 1800 * 7
		local skews = { 0, 0.45, -0.3 } -- each server's UTC clock against true time
		local phases = { 0, 0.13, 0.21 } -- where in its 0.25 s tick each server happens to be
		local servers = {}
		for i = 1, #skews do
			servers[i] = newServer(slot - 5 + skews[i])
			servers[i].nextTick = slot - 5 + phases[i]
		end
		local real = slot - 5
		local launchedAt: { number } = {}
		while real < slot + 5 do
			for i, w in servers do
				if real >= w.nextTick then
					w.t = real + skews[i]
					w.svc.step()
					w.nextTick += StormCup.TICK
					if #w.launches == 1 and launchedAt[i] == nil then
						launchedAt[i] = real
					end
				end
			end
			real += 0.01
		end
		for i, w in servers do
			h.eq(#w.launches, 1, "server " .. i .. " launched once")
			h.ok(w.launches[1].at >= slot, "never before its own clock reaches the slot")
			h.eq(w.launches[1].cup, servers[1].launches[1].cup, "same cup, map and modifier on every server")
		end
		local lo, hi = math.huge, -math.huge
		for _, at in launchedAt do
			lo = math.min(lo, at)
			hi = math.max(hi, at)
		end
		h.ok(hi - lo <= 2, string.format("spread %.2f s within 2 s", hi - lo))
		h.ok(hi - lo <= 1, "and in practice within the clock skew plus one tick")
	end)

	---------------------------------------------------------------------------------------------- rotation

	h.test("rotation: maps and modifiers step with the cup index; every combination per cycle; missing map falls forward", function()
		h.eq(SC.modifiers, { "night", "doubleItemBoxes" }, "mirrored stays out until the pipeline can reverse a route")
		local first = rules.stormCupNext(SUNDAY_10)
		local w = newServer(first.startsAt - 1)
		local seen: { [string]: boolean } = {}
		local cycle = #SC.tracks * #SC.modifiers
		for i = 0, cycle - 1 do
			w.run(2)
			local launch = w.launches[i + 1]
			h.ok(launch ~= nil, "cup " .. i .. " launched")
			h.eq(launch.cup.trackId, SC.tracks[((first.index + i) % #SC.tracks) + 1])
			h.eq(launch.cup.modifier, SC.modifiers[((first.index + i) % #SC.modifiers) + 1])
			seen[launch.cup.trackId .. "/" .. launch.cup.modifier] = true
			w.mode = "hub"
			w.t = first.startsAt + 1800 * (i + 1) - 1
		end
		local n = 0
		for _ in seen do
			n += 1
		end
		h.eq(n, cycle, "all map x modifier combinations in one cycle")
		-- A map this build does not mount: the next mounted map in rotation order, the same on every server.
		local a = newServer(0)
		local b = newServer(0)
		local cup = nil
		for idx = first.index, first.index + 10 do
			local c = rules.stormCup(idx)
			if c.trackId == "SNOW-1" then
				cup = { index = c.index, startsAt = c.startsAt, trackId = c.trackId, modifier = c.modifier }
				break
			end
		end
		h.ok(cup ~= nil)
		a.mounted["SNOW-1"] = false
		b.mounted["SNOW-1"] = false
		h.eq(a.svc.trackFor(cup), "ISLAND-2")
		h.eq(b.svc.trackFor(cup), "ISLAND-2")
		for _, id in SC.tracks do
			a.mounted[id] = false
		end
		h.eq(a.svc.trackFor(cup), nil, "no mounted map at all")
		a.t = cup.startsAt
		h.eq(a.svc.step(), "skipped")
		h.contains(a.logs, "skip cup=" .. tostring(cup.index))
	end)

	---------------------------------------------------------------------------------------------- never interrupts

	h.test("never interrupts a running race: waits for every finish plus the results hold, then starts", function()
		local slot = S1_START + 1800 * 40
		local w = newServer(slot - 10)
		w.mode = "quickrace"
		w.run(120)
		h.eq(#w.launches, 0, "mid-race: no launch")
		h.eq(w.attrs.StormCupState, "due", "the HUD knows a cup is waiting")
		h.ok(w.svc.holdReason(w.t) ~= nil, "FLY AGAIN and the board are held while the cup waits")
		w.finishedFor = 3
		w.run(1)
		h.eq(#w.launches, 0, "results still showing")
		w.finishedFor = StormCup.RESULTS_HOLD
		w.switching = true
		w.run(1)
		h.eq(#w.launches, 0, "never during a map switch")
		w.switching = false
		w.run(1)
		h.eq(#w.launches, 1, "starts once everyone finished and the results showed")
		h.contains(w.logs, "from=quickrace")
	end)

	h.test("a cup that cannot start within LATE_START is skipped; empty servers wait; late boots still join", function()
		local slot = S1_START + 1800 * 41
		local w = newServer(slot - 1)
		w.mode = "race" -- someone races (or idles unfinished) through the whole window
		w.run(StormCup.LATE_START + 5)
		h.eq(#w.launches, 0)
		w.mode = "hub"
		w.run(30)
		h.eq(#w.launches, 0, "too late: the missed cup does not start mid-half-hour")
		h.eq(w.svc.holdReason(w.t), nil, "and holds nothing")
		-- An empty server waits; the first joiner inside the window gets the cup.
		local e = newServer(slot)
		e.players = 0
		e.run(60)
		h.eq(#e.launches, 0, "nobody to race")
		e.players = 1
		e.run(1)
		h.eq(#e.launches, 1, "first joiner inside the window")
		-- A server booted five minutes after the slot still runs it; one booted after LATE_START waits for the next.
		local late = newServer(slot + 300)
		late.run(1)
		h.eq(#late.launches, 1)
		local tooLate = newServer(slot + StormCup.LATE_START + 1)
		tooLate.run(1)
		h.eq(#tooLate.launches, 0)
	end)

	h.test("Studio switches: disabled schedule never fires; StormCupNow runs the next cup once", function()
		local slot = S1_START + 1800 * 42
		local off = newServer(slot - 2)
		off.enabled = false
		off.run(10)
		h.eq(#off.launches, 0)
		h.eq(off.attrs.StormCupEnabled, false)
		h.eq(off.attrs.StormCupState, "off")
		h.eq(off.svc.holdReason(off.t), nil, "a disabled cup holds nothing")
		local qa = newServer(slot - 900)
		qa.force = true
		qa.mode = "race"
		qa.run(1)
		h.eq(#qa.launches, 0, "even a forced cup waits for the race")
		qa.mode = "hub"
		qa.run(1)
		h.eq(#qa.launches, 1, "forced cup starts from the hub")
		h.eq(qa.launches[1].cup.index, slot // 1800, "it is the next scheduled cup")
		h.eq(qa.launches[1].cup.forced, true)
		qa.mode = "hub"
		qa.t = slot - 1
		qa.run(5)
		h.eq(#qa.launches, 1, "that slot does not run a second time")
	end)

	---------------------------------------------------------------------------------------------- Festival

	h.test("Festival: window attributes for the HUD banner; multiplier read at payout time", function()
		local w = newServer(S1_START + 15 * 3600 + 600) -- Saturday 15:10 UTC
		w.run(1)
		h.eq(w.attrs.FestivalActive, true)
		h.eq(w.attrs.FestivalName, "Saturday Festival")
		h.eq(w.attrs.FestivalEndsAt, S1_START + 16 * 3600)
		h.eq(w.attrs.FestivalMultiplier, 2)
		h.eq(w.attrs.FestivalGoldenCoin, true)
		local quiet = newServer(SUNDAY_10)
		quiet.run(1)
		h.eq(quiet.attrs.FestivalActive, false)
		h.eq(quiet.attrs.FestivalName, nil)
		h.eq(quiet.attrs.FestivalNextAt, S1_START + 4 * DAY + 22 * 3600, "next: Wednesday 22:00 UTC")
		h.eq(quiet.attrs.FestivalNextName, "Midweek Festival")
		-- The window closes on time.
		w.t = S1_START + 16 * 3600
		w.run(1)
		h.eq(w.attrs.FestivalActive, false)
	end)

	---------------------------------------------------------------------------------------------- payouts

	local function econServer(utc: { t: number }): any
		local sched = h.newScheduler()
		local w: any = { sched = sched, logs = {} }
		local function log(line: string)
			table.insert(w.logs, line)
		end
		w.save = SaveService.new({
			store = SaveService.newMemoryStore({}),
			sessionId = "server-storm",
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = log,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0, saveAttempts = 2, loadAttempts = 2 },
		})
		w.econ = Economy.new({
			save = w.save,
			purchaseStore = SaveService.newMemoryStore({}),
			giftStore = SaveService.newMemoryStore({}),
			now = function(): number
				return utc.t
			end,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = log,
			isStudio = function(): boolean
				return false
			end,
		})
		w.save.onLoaded(w.econ.playerLoaded)
		function w.join(userId: number): any
			local p = h.fakePlayer(userId)
			w.econ.playerAdded(p)
			sched.run(function()
				w.save.load(p)
			end)
			sched.advance(0)
			return p
		end
		return w
	end

	h.test("payouts: every Storm Cup finisher gets Gears by placement, first place a Win Pass win, no tokens", function()
		local utc = { t = SUNDAY_10 }
		local s = econServer(utc)
		local g = MonetizationConfig.GEARS
		local function cup(userId: number, rank: number, rings: number?): (any, any)
			local p = s.join(userId)
			local r = s.econ.raceFinished(p, { trackId = "SNOW-1", mode = "stormcup", rank = rank, laps = 3, rings = rings or 0 })
			return p, r
		end
		local p1, r1 = cup(2001, 1, 8)
		h.eq(r1.base, g.stormCup[1] + 3 * g.perLap + 8 * g.perRing, "winner: placement + laps + rings")
		h.eq(r1.gears, r1.base, "no multiplier outside a Festival")
		h.eq(r1.winPassWin, true)
		h.eq(r1.winPassWins, 1)
		h.eq(s.save.get(p1).gears, r1.gears)
		h.eq(p1:GetAttribute("WinPassWins"), 1)
		local _, r3 = cup(2003, 3)
		h.eq(r3.base, g.stormCup[3] + 15)
		h.eq(r3.winPassWin, false, "only first place advances the Win Pass")
		local p8, r8 = cup(2008, 8)
		h.eq(r8.base, g.stormCup[8] + 15)
		h.eq(s.save.get(p8).winPass.wins, 0)
		local _, r12 = cup(2012, 12)
		h.eq(r12.base, g.stormCup[#g.stormCup] + 15, "every finisher is paid, past the table too")
		-- The cup pays more than a quick race at the same placement.
		local q = s.join(2100)
		local rq = s.econ.raceFinished(q, { trackId = "SNOW-1", mode = "quickrace", rank = 1, laps = 3, rings = 8 })
		h.ok(r1.base > rq.base, "Storm Cup placement table beats the regular one")
		-- Economy never touches progression: no tokens, fragments or best times from a cup.
		local prof = s.save.get(p1)
		h.eq(next(prof.tokens), nil, "no Sky Token")
		h.eq(next(prof.bestTimes), nil, "no best time")
		h.eq(prof.fragments or 0, 0)
	end)

	h.test("payouts: only finishers; Festival doubles the cup payout", function()
		local utc = { t = SUNDAY_10 }
		local s = econServer(utc)
		local quitter = s.join(2201)
		s.econ.raceAbandoned(quitter) -- left or never finished: RaceManager calls only this
		h.eq(s.save.get(quitter).gears, 0, "a racer who does not finish gets nothing")
		utc.t = S1_START + 15 * 3600 + 600 -- Saturday Festival
		local p = s.join(2202)
		local r = s.econ.raceFinished(p, { trackId = "DINO-4", mode = "stormcup", rank = 2, laps = 3, rings = 0 })
		h.eq(r.festival, true)
		h.eq(r.multiplier, 2)
		h.eq(r.gears, r.base * 2)
		h.eq(r.winPassWin, false)
		h.contains(s.logs, "source=stormcup rank=2")
	end)

	---------------------------------------------------------------------------------------------- double item boxes

	h.test("double item boxes: twins down the route, clear of other pods; alternate-route pods respawn faster instead", function()
		-- Straight route along +X: station = x, right = +Z.
		local spline = {
			project = function(pos: Vector3): number
				return pos.X
			end,
			sample = function(station: number): (Vector3, Vector3)
				return V3(station, 0, 0), V3(1, 0, 0)
			end,
		}
		local pods = {
			{ name = "A", pos = V3(100, 3, 0), item = true },
			{ name = "B", pos = V3(100, 3, 10), item = true },
			{ name = "Speed", pos = V3(145, 3, 2), item = false }, -- blocks the ahead spots; never twinned itself
			{ name = "Alt", pos = V3(300, 3, 80), item = true }, -- 80 off the main line (an alternate route)
		}
		local plan = StormCup.planTwins(pods, spline, 30)
		h.eq(#plan, 3, "item pods only")
		local byName: { [string]: any } = {}
		for _, e in plan do
			byName[e.name] = e.offset
		end
		h.eq(byName.A, V3(-StormCup.TWIN_AHEAD, 0, 0), "ahead is blocked by the speed pod: twin goes back")
		h.eq(byName.B, V3(-StormCup.TWIN_AHEAD, 0, 0), "same lateral offset and height as the original")
		h.eq(byName.Alt, nil, "off the main line: no twin (faster respawn instead)")
		local clearPlan = StormCup.planTwins({ { name = "C", pos = V3(500, 3, -6), item = true } }, spline, 30)
		h.eq(clearPlan[1].offset, V3(StormCup.TWIN_AHEAD, 0, 0), "an open route takes the twin ahead")
		-- Route half-widths from TrackData.
		h.eq(StormCup.halfWidthOf({ vehicle = "car", deck = { width = 44 } }), 19)
		h.eq(StormCup.halfWidthOf({ vehicle = "plane", deck = { width = 32 }, flight = { corridor = { halfWidth = 34 } } }), 30)
		h.eq(StormCup.halfWidthOf(nil), 0)
	end)
end
