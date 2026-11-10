--!strict
-- Lune spec for storm race v2 (economy v3 phase 5 flow; docs/design/STORM_RACE_V2.md): shared/StormFlowRules (schedule
-- math, field filling, late join, dragon rule, flag fallbacks) and server/StormRace driven with a fake clock, fake groups
-- and fake players (no Roblox services).
-- Run: tools/tests/run_lune_tests.sh tools/tests/storm_flow_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	fakePlayer: (number, string?) -> any,
	readFile: (string) -> string,
}

local P = 1800
local A = 60
local L = 20
local T0 = 1794009600 -- 2026-11-07 00:00 UTC, a :00 slot

return function(h: Harness)
	local R = h.require("src/shared/StormFlowRules.luau")
	local StormConfig = h.require("src/shared/StormConfig.luau")
	local BossConfig = h.require("src/shared/BossConfig.luau")
	local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")
	local StormRace = h.require("src/server/StormRace.luau")

	------------------------------------------------------------------------------------------------ flags

	h.test("flags: RACE_V2 defaults off; v2 only with PER_GROUP; RACE_V2 without PER_GROUP falls back with a warning", function()
		h.eq(StormConfig.RACE_V2, false, "RACE_V2 default false (the Storm Cup is unchanged)")
		h.eq(R.flow(false, false), "legacy")
		h.eq(R.flow(false, true), "legacy", "PER_GROUP alone keeps the Storm Cup path")
		h.eq(R.flow(true, true), "v2")
		h.eq(R.flow(true, false), "fallback")
		h.contains(R.FALLBACK_WARNING, "PER_GROUP")
		h.contains(R.FALLBACK_WARNING, "old Storm Cup")
		h.eq(StormConfig.MODES[StormConfig.FLOW.mode], true, "the v2 mode pays Shards")
		h.eq(StormConfig.FLOW.fieldSize, 8)
		h.eq(StormConfig.FLOW.announceSeconds, 60)
	end)

	h.test("flags: a storm race never replays (FLY AGAIN would pay the storm tables again)", function()
		h.eq(RaceFlowRules.canReplay("stormrace"), false)
		h.eq(RaceFlowRules.canReplay("stormcup"), false)
		h.eq(RaceFlowRules.canReplay("race"), true)
		h.eq(RaceFlowRules.canVote("again", true, "stormrace"), false)
		h.eq(RaceFlowRules.canVote("hub", true, "stormrace"), true)
	end)

	h.test("static: boot picks the flow, v2 runs the Storm Cup publish-only, the old launch stays on the legacy path", function()
		local sr = h.readFile("src/server/StormRace.luau")
		h.contains(sr, "StormCup.init({ publishOnly = true })")
		h.contains(sr, "warn(StormFlowRules.FALLBACK_WARNING)")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "require(script.StormRace).boot(StormCup)")
		local cup = h.readFile("src/server/StormCup.luau")
		h.contains(cup, "if o.publishOnly then\n\t\t\tsvc.publish(t, w, nil)\n\t\t\treturn nil")
	end)

	------------------------------------------------------------------------------------------------ schedule

	h.test("schedule: :00 / :30 UTC, the window opens 60 s before and closes 20 s after", function()
		local ph, s = R.phaseAt(T0 + 10 * 60, P, A, L)
		h.eq(ph, "idle")
		h.eq(s.startsAt, T0 + P, "next slot is :30")
		h.eq(s.startsAt % 1800, 0, "on the UTC half hour")
		ph, s = R.phaseAt(T0 + P - 61, P, A, L)
		h.eq(ph, "idle", "61 s before: not yet")
		ph, s = R.phaseAt(T0 + P - 60, P, A, L)
		h.eq(ph, "announce", "60 s before: window open")
		h.eq(s.index, (T0 + P) // P)
		h.eq(s.announceAt, T0 + P - 60)
		ph, s = R.phaseAt(T0 + P - 1, P, A, L)
		h.eq(ph, "announce")
		ph, s = R.phaseAt(T0 + P, P, A, L)
		h.eq(ph, "late", "at the start: late seats")
		h.eq(s.startsAt, T0 + P)
		ph, s = R.phaseAt(T0 + P + 19.9, P, A, L)
		h.eq(ph, "late")
		ph, s = R.phaseAt(T0 + P + 20, P, A, L)
		h.eq(ph, "idle", "window closed 20 s after the start")
		h.eq(s.startsAt, T0 + 2 * P)
	end)

	h.test("schedule: the Studio QA slot announces now; its window is clamped", function()
		local s = R.qaSlot(1000, 30, L, 2)
		h.eq(s.announceAt, 1000)
		h.eq(s.startsAt, 1030)
		h.eq(s.lateUntil, 1050)
		h.eq(s.forced, true)
		h.ok(s.index < 0, "a QA slot never collides with a UTC slot")
		h.eq(R.qaWindow(nil, 60, 10, 300), 60)
		h.eq(R.qaWindow(2, 60, 10, 300), 10)
		h.eq(R.qaWindow(5000, 60, 10, 300), 300)
		h.eq(R.qaWindow(25.7, 60, 10, 300), 25)
		h.eq(R.qaWindow(0 / 0, 60, 10, 300), 60)
		h.eq(R.clock(62.2), "1:03")
		h.eq(R.clock(-4), "0:00")
	end)

	------------------------------------------------------------------------------------------------ fields

	h.test("fields: fill in join order, 8 per field; overflow opens a new field; joining twice is a no-op", function()
		local f = {}
		for id = 1, 8 do
			local n, new = R.join(f, id, 8)
			h.eq(n, 1)
			h.eq(new, true)
		end
		local n, new = R.join(f, 9, 8)
		h.eq(n, 2, "the 9th joiner opens field 2")
		h.eq(new, true)
		n, new = R.join(f, 3, 8)
		h.eq(n, 1, "already in field 1")
		h.eq(new, false)
		h.eq(R.total(f), 9)
		h.eq(f[1], { 1, 2, 3, 4, 5, 6, 7, 8 })
		h.eq(f[2], { 9 })
		h.eq(R.botsFor(f, 8), { 0, 7 }, "bots fill the remainder of the last field")
		for id = 10, 17 do
			R.join(f, id, 8)
		end
		h.eq(#f, 3)
		h.eq(R.botsFor(f, 8), { 0, 0, 7 })
	end)

	h.test("fields: the storm dragon keeps a seat in every field (7 humans + dragon = 8)", function()
		h.eq(R.seats(8), 7)
		h.eq(R.seats(1), 1, "never below one human seat")
		local f: any = {}
		for id = 1, 8 do
			R.join(f, id, R.seats(8))
		end
		h.eq(#f, 2)
		h.eq(#f[1], 7)
		h.eq(R.botsFor(f, 8)[1], 1, "a full field still has the dragon's seat")
		h.eq(R.lateJoin({ count = 7, open = true }, R.seats(8)), "new", "7 humans: the field is full")
	end)

	h.test("static: a field trim never takes the boss while another bot can go", function()
		local ai = h.readFile("src/server/AIRacers.luau")
		h.contains(ai, "function AIRacers.trimCandidates(")
		h.contains(ai, "local candidates = AIRacers.trimCandidates(AIRacers.bots)")
		h.contains(ai, "victim = AIRacers.pickTrimVictim(candidates, totalLen)")
	end)

	h.test("static: the hub storm layer and thunder follow the local player's race mode", function()
		local ss = h.readFile("src/client/Soundscape.luau")
		h.contains(ss, 'stormOn = Rules.stormLayer(RaceAttr.mine("RaceMode")')
		h.contains(ss, 'RaceAttr.changed("RaceMode", refreshBeds)')
		h.ok(not string.find(ss, 'workspace:GetAttribute("RaceMode")', 1, true), "no workspace RaceMode read left")
	end)

	h.test("fields: a LEAVE keeps the order; compact refills so only the last field has bots", function()
		local f = {}
		for id = 1, 10 do
			R.join(f, id, 8)
		end
		h.eq(R.leave(f, 4), 1)
		h.eq(R.leave(f, 4), nil, "leaving twice")
		h.eq(R.fieldOf(f, 9), 2)
		local c = R.compact(f, 8)
		h.eq(c[1], { 1, 2, 3, 5, 6, 7, 8, 9 })
		h.eq(c[2], { 10 })
		h.eq(R.botsFor(c, 8), { 0, 7 })
		local e = { {}, { 5 } }
		h.eq(R.compact(e, 8), { { 5 } }, "an emptied field is dropped")
		h.eq(R.compact({}, 8), {})
	end)

	h.test("late join: the last field while its grid forms and has room, else a new field", function()
		h.eq(R.lateJoin(nil, 8), "new", "nothing launched yet")
		h.eq(R.lateJoin({ count = 3, open = true }, 8), "last")
		h.eq(R.lateJoin({ count = 8, open = true }, 8), "new", "full")
		h.eq(R.lateJoin({ count = 3, open = false }, 8), "new", "already racing: no mid-race seat")
	end)

	h.test("tracks: field 1 takes the slot's rotation track, later fields the next free mounted one", function()
		local tracks = { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" }
		local all = function(_: string): boolean
			return true
		end
		h.eq(R.trackFor(0, tracks, all, {}), "DINO-4")
		h.eq(R.trackFor(7, tracks, all, {}), "ISLAND-2", "index 7 -> 7 % 5 = 2 -> third")
		h.eq(R.trackFor(7, tracks, all, { ["ISLAND-2"] = true }), "FOREST-1")
		local busy = function(id: string): boolean
			return id ~= "ISLAND-2" and id ~= "FOREST-1"
		end
		h.eq(R.trackFor(7, tracks, busy, {}), "SPACE-4", "a track a group races is skipped")
		h.eq(R.trackFor(7, tracks, function(_: string): boolean
			return false
		end, {}), nil)
		h.eq(R.trackFor(-3, tracks, all, {}), "ISLAND-2", "a negative QA index still maps into the rotation (-3 % 5 = 2)")
	end)

	------------------------------------------------------------------------------------------------ dragon

	h.test("dragon: beaten when the dragon was in the field and had not crossed first; other bots do not matter", function()
		h.eq(R.beatDragon({}, true), true, "first across")
		h.eq(R.beatDragon({ { isPlayer = false, isBoss = false }, { isPlayer = true } }, true), true, "a normal bot ahead")
		h.eq(R.beatDragon({ { isPlayer = false, isBoss = true } }, true), false, "the dragon ahead")
		h.eq(R.beatDragon({ { isPlayer = true }, { isPlayer = false, isBoss = true } }, true), false)
		h.eq(R.beatDragon({}, false), false, "no dragon in the field: nobody beats it")
	end)

	h.test("dragon: a tracked stand-in outside the zone bosses, tuned beatable", function()
		local plane = BossConfig.stormDragon("plane")
		local car = BossConfig.stormDragon("car")
		h.eq(BossConfig.forZone("STORM"), plane)
		h.eq(BossConfig.forZone("STORM_CAR"), car)
		h.eq(BossConfig.BY_ZONE.STORM, nil, "not a zone boss (retirements, pads and clip specs never see it)")
		h.eq(BossConfig.forTrack(""), nil)
		h.eq(plane.model, BossConfig.BY_ZONE.DINO.model, "stand-in: Cinderwing's uploaded rig")
		h.eq(car.model, BossConfig.BY_ZONE.HUB.model, "stand-in: Thunderwright's uploaded rig")
		-- Beatable: no faster than the slowest plane zone boss, faster than the field's top bot (139).
		local slowestPlaneBoss = math.huge
		for _, b in BossConfig.BY_ZONE do
			if b.vehicle == "plane" then
				slowestPlaneBoss = math.min(slowestPlaneBoss, b.pace)
			end
		end
		h.ok(plane.pace <= slowestPlaneBoss, "plane dragon <= the slowest plane zone boss")
		h.ok(plane.pace > 139, "plane dragon > the fastest field bot")
		h.ok(car.pace >= BossConfig.BY_ZONE.ISLAND.pace and car.pace <= BossConfig.BY_ZONE.HUB.pace, "car dragon between the car bosses")
		h.contains(h.readFile("docs/ASSETS_TOOLBOX_TEMP.md"), "Storm dragon stand-in")
	end)

	h.test("static: RaceManager tags the dragon's crossing and judges beatDragon only in a storm race", function()
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "isBoss = bot.isBoss == true")
		h.contains(rm, 'if RaceManager.getMode() == "stormrace" then')
		h.contains(rm, "beatDragon = StormFlowRules.beatDragon(RaceManager.finishOrder, dragon)")
		local ai = h.readFile("src/server/AIRacers.luau")
		h.contains(ai, 'if mode == "stormrace" then\n\t\treturn BossConfig.stormDragon(activeVehicle()), false')
	end)

	------------------------------------------------------------------------------------------------ service

	-- A fake world: groups by track, players in the hub or not, sent events, attributes.
	local function world(t: number): any
		local w: any = { t = t, on = true, groups = {}, sent = {}, attrs = {}, players = {}, racing = {}, logs = {}, force = false, qa = 30 }
		w.svc = StormRace.new({
			now = function(): number
				return w.t
			end,
			enabled = function(): boolean
				return w.on
			end,
			period = P,
			announce = A,
			late = L,
			size = 8,
			tracks = { "DINO-4", "SNOW-1", "ISLAND-2" },
			usable = function(id: string): boolean
				return w.groups[id] == nil and w.blocked ~= id
			end,
			inHub = function(p: any): boolean
				return p.Parent ~= nil and not w.racing[p.UserId]
			end,
			launch = function(list: { any }, id: string): string
				local g = w.groups[id]
				if g then
					if g.mode ~= "stormrace" then
						return "busy"
					end
					if (g.state == "loading" or g.state == "grid") and g.count + #list <= 8 then
						g.count += #list
					else
						return "busy"
					end
					for _, p in list do
						w.racing[p.UserId] = id
					end
					return "join"
				end
				w.groups[id] = { mode = "stormrace", state = "loading", count = #list, order = (w.order or 0) + 1 }
				w.order = (w.order or 0) + 1
				for _, p in list do
					w.racing[p.UserId] = id
				end
				return "open"
			end,
			liveFields = function(): { any }
				local out = {}
				for id, g in w.groups do
					if g.mode == "stormrace" then
						table.insert(out, { trackId = id, state = g.state, count = g.count, field = 8, order = g.order })
					end
				end
				table.sort(out, function(a, b)
					return a.order < b.order
				end)
				return out
			end,
			send = function(p: any, kind: string, data: any)
				table.insert(w.sent, { who = p.UserId, kind = kind, data = data })
			end,
			setAttr = function(name: string, v: any)
				w.attrs[name] = v
			end,
			playerById = function(id: number): any
				return w.players[id]
			end,
			leaveQueue = function(p: any)
				w.leftQueue = (w.leftQueue or 0) + 1
			end,
			forceAnnounce = function(): boolean
				local f = w.force
				w.force = false
				return f
			end,
			qaWindow = function(): number
				return w.qa
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
		})
		function w.player(id: number): any
			local p = h.fakePlayer(id)
			w.players[id] = p
			return p
		end
		function w.events(id: number, kind: string): { any }
			local out = {}
			for _, e in w.sent do
				if e.who == id and e.kind == kind then
					table.insert(out, e.data)
				end
			end
			return out
		end
		return w
	end

	h.test("service: idle publishes the next :00/:30; the window opens 60 s before; JOIN outside it is refused", function()
		local w = world(T0 + 100)
		local p = w.player(1)
		w.svc.step()
		h.eq(w.attrs.StormRaceV2, true)
		h.eq(w.attrs.StormRaceState, "idle")
		h.eq(w.attrs.StormRaceAt, T0 + P)
		h.eq(w.attrs.StormRaceLive, false)
		h.eq(w.svc.join(p), "closed")
		h.eq(w.events(1, "Refused")[1].why, "closed")
		w.t = T0 + P - 60
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "open")
		h.eq(w.attrs.StormRaceSeq, (T0 + P) // P)
		h.eq(w.attrs.StormRaceAt, T0 + P)
		h.eq(w.attrs.StormRaceCloseAt, T0 + P + L)
	end)

	h.test("service: nobody is pulled; only joiners launch, in fields of 8 by join order, at the start", function()
		local w = world(T0 + P - 50)
		w.svc.step()
		for id = 1, 11 do
			w.player(id)
		end
		for id = 1, 9 do
			h.eq(w.svc.join(w.players[id]), "joined")
		end
		h.eq(w.svc.join(w.players[2]), "already")
		h.eq(w.attrs.StormRaceJoined, 9)
		h.eq(w.events(9, "Joined")[1].field, 2, "9th joiner in field 2")
		h.eq(w.events(8, "Joined")[1].field, 2, "8th joiner in field 2: 7 humans + the storm dragon make a field of 8")
		h.eq(w.events(7, "Joined")[1].field, 1)
		h.eq(w.events(1, "Joined")[1].field, 1)
		w.t = T0 + P - 1
		w.svc.step()
		h.eq(next(w.groups), nil, "nothing launches before the start")
		w.t = T0 + P
		w.svc.step()
		local live = 0
		for _ in w.groups do
			live += 1
		end
		h.eq(live, 2, "two fields")
		local slotIndex = (T0 + P) // P
		local first = ({ "DINO-4", "SNOW-1", "ISLAND-2" })[(slotIndex % 3) + 1]
		h.eq(w.groups[first].count, 7, "field 1 = the first 7 joiners on the slot's track (the dragon takes the 8th seat)")
		h.eq(w.racing[7], first)
		h.ok(w.racing[8] ~= nil and w.racing[8] ~= first, "field 2 on another track")
		h.eq(w.racing[9], w.racing[8])
		h.eq(w.groups[w.racing[8]].count, 2)
		h.eq(w.racing[10], nil, "players who never pressed JOIN stay in the hub")
		h.eq(w.racing[11], nil)
		h.eq(#w.events(10, "Launched"), 0)
		h.eq(w.events(9, "Launched")[1].field, 2)
		h.eq(w.attrs.StormRaceLive, true, "the hub storm runs while a field races")
		h.eq(w.attrs.StormRaceState, "late")
	end)

	h.test("service: a late JOIN takes the last field while its grid forms, else a new field; the window then closes", function()
		local w = world(T0 + P - 30)
		w.svc.step()
		for id = 1, 12 do
			w.player(id)
		end
		for id = 1, 6 do
			w.svc.join(w.players[id])
		end
		w.t = T0 + P
		w.svc.step()
		local track = w.racing[1]
		h.eq(w.groups[track].count, 6)
		w.t = T0 + P + 3
		h.eq(w.svc.join(w.players[7]), "late", "room in the last field")
		h.eq(w.groups[track].count, 7)
		h.eq(w.racing[7], track)
		h.eq(w.svc.join(w.players[8]), "lateNew", "7 humans fill a field (the dragon's seat stays): a new field")
		h.ok(w.racing[8] ~= nil and w.racing[8] ~= track)
		h.eq(w.svc.join(w.players[9]), "late", "the new field forms: a seat there")
		local second = w.racing[8]
		h.eq(w.racing[9], second)
		w.groups[second].state = "racing"
		h.eq(w.svc.join(w.players[10]), "lateNew", "the last field already races: another new field")
		local third = w.racing[10]
		h.ok(third ~= nil and third ~= track and third ~= second)
		h.eq(w.svc.join(w.players[11]), "late", "joins the newest field")
		h.eq(w.racing[11], third)
		w.blocked = nil
		h.eq(w.svc.join(w.players[8]), "racing", "already racing: refused")
		w.t = T0 + P + L
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "idle")
		h.eq(w.svc.join(w.players[12]), "closed")
		h.eq(w.racing[12], nil)
		-- The slot never reopens.
		w.t = T0 + P + L + 1
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "idle")
	end)

	h.test("service: LEAVE before the start frees the seat; a racer elsewhere cannot join; leaving the server leaves", function()
		local w = world(T0 + P - 40)
		w.svc.step()
		local a, b, c = w.player(1), w.player(2), w.player(3)
		w.racing[3] = "FOREST-1" -- racing a normal group
		h.eq(w.svc.join(c), "racing")
		h.eq(w.events(3, "Refused")[1].why, "racing")
		w.svc.join(a)
		w.svc.join(b)
		h.eq(w.svc.leave(a, "leave"), true)
		h.eq(#w.events(1, "Left"), 1)
		h.eq(w.attrs.StormRaceJoined, 1)
		b:leave()
		w.svc.leave(b, "left the server")
		w.t = T0 + P
		w.svc.step()
		h.eq(next(w.groups), nil, "nobody left: no field launches")
		h.eq(w.racing[1], nil, "the leaver stays in the hub")
	end)

	h.test("service: a joiner who went racing elsewhere before the start is skipped with a message", function()
		local w = world(T0 + P - 40)
		w.svc.step()
		local a, b = w.player(1), w.player(2)
		w.svc.join(a)
		w.svc.join(b)
		w.racing[2] = "FOREST-1"
		w.t = T0 + P
		w.svc.step()
		h.ok(w.racing[1] ~= nil and w.racing[1] ~= "FOREST-1")
		h.eq(w.racing[2], "FOREST-1")
		h.eq(w.events(2, "Refused")[1].why, "racing")
	end)

	h.test("service: no free track: the field hears it and stays in the hub", function()
		local w = world(T0 + P - 40)
		w.svc.step()
		local a = w.player(1)
		w.svc.join(a)
		for _, id in { "DINO-4", "SNOW-1", "ISLAND-2" } do
			w.groups[id] = { mode = "race", state = "racing", count = 1, order = 0 }
		end
		w.t = T0 + P
		w.svc.step()
		h.eq(w.racing[1], nil)
		h.eq(w.events(1, "Refused")[1].why, "full")
		h.eq(w.attrs.StormRaceLive, false, "normal groups do not turn the hub stormy")
	end)

	h.test("service: switched off before the start cancels the joiners; off means no window", function()
		local w = world(T0 + P - 40)
		w.svc.step()
		local a = w.player(1)
		w.svc.join(a)
		w.on = false
		w.svc.step()
		h.eq(w.events(1, "Refused")[1].why, "cancelled")
		h.eq(w.attrs.StormRaceState, "idle")
		h.eq(w.attrs.StormRaceEnabled, false)
		w.t = T0 + P
		w.svc.step()
		h.eq(next(w.groups), nil)
	end)

	h.test("service: Studio QA (StormQA) opens a window now with the short QA length", function()
		local w = world(T0 + 300)
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "idle")
		w.force = true
		w.qa = 15
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "open")
		h.eq(w.attrs.StormRaceAt, T0 + 315)
		h.ok(w.attrs.StormRaceSeq < 0, "QA seq")
		local a = w.player(1)
		w.svc.join(a)
		w.t = T0 + 315
		w.svc.step()
		h.ok(w.racing[1] ~= nil, "QA field launched")
		w.t = T0 + 315 + L
		w.svc.step()
		h.eq(w.attrs.StormRaceState, "idle")
		-- A second press opens a new QA window with a new seq.
		local seq1 = -1
		w.force = true
		w.svc.step()
		h.ok(w.attrs.StormRaceSeq ~= nil and w.attrs.StormRaceSeq < seq1, "a fresh seq")
	end)
end
