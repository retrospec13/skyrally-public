--!strict
-- Lune spec for the live kill switches and soft shutdown (systems audit v32 T1-5): shared/LiveOpsRules (flag document
-- parsing, fail-open defaults, admin command grammar, shutdown timing), server/LiveOps over fakes (store reads and writes,
-- nudges, the shutdown sequence on fake time), the "/admin live" path in server/AdminService, and source guards on the
-- hooks (Economy, TrackDirector, StormCup, StormRace, AvatarSelect, telemetry sinks, the server entry script).
-- Run: tools/tests/run_lune_tests.sh tools/tests/live_ops_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	readFile: (string) -> string,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
}

local ADMIN = 90000001
local OTHER = 5550001

return function(h: Harness)
	-- Synthetic server policy for authorized-admin behavior; public defaults tested separately.
	h.fake("src/server/AdminConfig.luau", h.require("src/server/AdminConfig.luau").forUserId(90000001))
	local R = h.require("src/shared/LiveOpsRules.luau")
	local LiveOps = h.require("src/server/LiveOps.luau")
	local AdminService = h.require("src/server/AdminService.luau")

	------------------------------------------------------------------------------------------------ parsing

	h.test("parse: no row, a non-table, another schema or a damaged off table all mean every flag ON", function()
		for _, doc in { nil, "store", 42, { v = 2, off = { store = true } }, { off = { store = true } }, { v = 1, off = "store" } } do
			local st = R.parse(doc)
			h.eq(#R.offList(st), 0, "doc " .. tostring(doc))
			h.ok(R.isOn(st, "store"))
		end
		local _, w = R.parse({ v = 2, off = { store = true } })
		h.contains(w, "schema 2 unknown, ignored")
	end)

	h.test("parse: only off[flag] == true switches a flag off; names are canonical; unknown flags warn", function()
		local st, w = R.parse({
			v = 1,
			rev = 7,
			off = { STORE = true, battles = false, avatars = "yes", ["map:dino"] = true, ["map:HUB-0"] = true, bogus = true },
		})
		h.eq(R.offList(st), { "map:DINO-4", "store" })
		h.eq(st.rev, 7)
		h.ok(R.isOn(st, "battles"), "false stays on")
		h.ok(R.isOn(st, "avatars"), "a string stays on")
		h.contains(w, "unknown flag bogus")
		h.contains(w, "unknown flag map:HUB-0", "the hub can never be switched off")
		h.eq(R.isOn(nil, "store"), true, "no state = ON")
	end)

	h.test("parse: a flooded document reads at most MAX_FLAGS entries", function()
		local off = {}
		for i = 1, 200 do
			off["x" .. i] = true
		end
		off.store = true
		local st, w = R.parse({ v = 1, off = off })
		h.contains(w, "more than 64 flags, rest ignored")
		h.ok(#R.offList(st) <= 1)
	end)

	h.test("resolve: fail OPEN at boot; a read failure keeps the last good flags for STALE_SECONDS, then all ON", function()
		local good = R.parse({ v = 1, rev = 3, off = { stormcup = true } })
		local st, src = R.resolve(false, nil, nil, nil, 1000)
		h.eq(src, "default")
		h.eq(#R.offList(st), 0)
		st, src = R.resolve(false, nil, good, 1000, 1000 + R.STALE_SECONDS)
		h.eq(src, "stale")
		h.eq(R.offList(st), { "stormcup" })
		st, src = R.resolve(false, nil, good, 1000, 1000 + R.STALE_SECONDS + 1)
		h.eq(src, "default")
		h.eq(#R.offList(st), 0)
		st, src = R.resolve(true, nil, good, 1000, 1001)
		h.eq(src, "store", "a successful read of no row is all ON, not stale")
		h.eq(#R.offList(st), 0)
	end)

	h.test("modeBlock: battles, single maps and closing; the hub never", function()
		local st = R.parse({ v = 1, off = { battles = true, ["map:SNOW-1"] = true } })
		h.eq(R.modeBlock(st, "DINO-4", "battle"), "battles paused for maintenance")
		h.eq(R.modeBlock(st, "DINO-4", "race"), nil)
		h.eq(R.modeBlock(st, "SNOW-1", "race"), "map paused for maintenance")
		h.eq(R.modeBlock(st, "HUB-0", "hub"), nil)
		h.eq(R.modeBlock(st, "HUB-0", "hub", true), nil, "closing never blocks the hub")
		h.eq(R.modeBlock(nil, "DINO-4", "race", true), "server restarting")
		h.eq(R.modeBlock(nil, "DINO-4", "battle"), nil)
	end)

	h.test("apply: set, clear and reset bump rev and stamp the actor; damaged old content is dropped", function()
		local d1 = R.apply(nil, "store", false, ADMIN, 5000.7)
		h.eq(d1, { v = 1, rev = 1, off = { store = true }, by = ADMIN, at = 5000 })
		local d2 = R.apply(d1, "map:DINO-4", false, ADMIN, 5001)
		h.eq(d2.off, { store = true, ["map:DINO-4"] = true })
		h.eq(d2.rev, 2)
		local d3 = R.apply(d2, "store", true, ADMIN, 5002)
		h.eq(d3.off, { ["map:DINO-4"] = true })
		local d4 = R.apply(d3, nil, true, ADMIN, 5003)
		h.eq(d4.off, {})
		h.eq(d4.rev, 4)
		local d5 = R.apply({ v = 1, rev = 9, off = { junk = true, battles = true } }, "avatars", false, ADMIN, 1)
		h.eq(d5.off, { battles = true, avatars = true })
	end)

	h.test("commands: /admin live grammar", function()
		h.ok(R.isLiveCommand("/admin live"))
		h.ok(R.isLiveCommand("  /ADMIN Live store off"))
		h.eq(R.isLiveCommand("/admin cash 10"), false)
		h.eq(R.isLiveCommand("/admin"), false)
		h.eq(R.isLiveCommand("live store off"), false)
		h.eq(R.parseCommand("/admin live"), { action = "status" })
		h.eq(R.parseCommand("/admin live reset"), { action = "reset" })
		h.eq(R.parseCommand("/admin live store off"), { action = "set", flag = "store", on = false })
		h.eq(R.parseCommand("/admin live StormCup on"), { action = "set", flag = "stormcup", on = true })
		h.eq(R.parseCommand("/admin live map island off"), { action = "set", flag = "map:ISLAND-2", on = false })
		local c, why = R.parseCommand("/admin live map hub off")
		h.eq(c, nil)
		h.contains(why, "hub cannot be switched off")
		c, why = R.parseCommand("/admin live nitro off")
		h.eq(c, nil)
		h.contains(why, "flag must be one of store, stormcup, battles, avatars, telemetry")
		c, why = R.parseCommand("/admin live store maybe")
		h.contains(why, "store takes on or off")
	end)

	------------------------------------------------------------------------------------------------ service

	local function newLive(opts: any?)
		local o = opts or {}
		local w: any = { doc = o.doc, attrs = {}, logs = {}, published = {}, changes = 0, t = 1000, readFails = false, writeFails = false }
		w.svc = LiveOps.new({
			read = function()
				if w.readFails then
					error("DataStore 502")
				end
				return true, w.doc
			end,
			update = function(transform)
				if w.writeFails then
					return false, "DataStore 503"
				end
				w.doc = transform(w.doc)
				return true, w.doc
			end,
			publish = function(rev)
				table.insert(w.published, rev)
			end,
			now = function()
				return w.t
			end,
			setAttr = function(k, v)
				w.attrs[k] = v
			end,
			log = function(line)
				table.insert(w.logs, line)
			end,
			onChange = function()
				w.changes += 1
			end,
		})
		return w
	end

	h.test("service: boot read, fail-open on an unreadable store, LiveOff attribute", function()
		local w = newLive({ doc = { v = 1, rev = 2, off = { battles = true } } })
		h.eq(w.attrs.LiveOff, "", "all ON before the first read")
		w.svc.refresh("boot")
		h.eq(w.attrs.LiveOff, "battles")
		h.eq(w.svc.source(), "store")
		h.eq(w.svc.modeBlock("DINO-4", "battle"), "battles paused for maintenance")
		h.eq(w.changes, 1)
		-- A blip keeps the flag; a long outage fails open.
		w.readFails = true
		w.t += 60
		w.svc.refresh("poll")
		h.eq(w.svc.source(), "stale")
		h.eq(w.svc.isOn("battles"), false)
		w.t += R.STALE_SECONDS + 1
		w.svc.refresh("poll")
		h.eq(w.svc.source(), "default")
		h.eq(w.svc.isOn("battles"), true)
		h.eq(w.attrs.LiveOff, "")
		h.contains(w.logs, "read failed why=poll")

		local cold = newLive()
		cold.readFails = true
		cold.svc.refresh("boot")
		h.eq(cold.svc.source(), "default")
		h.eq(cold.svc.isOn("store"), true, "a server that never read the store runs normal play")
	end)

	h.test("service: admin set writes the row, adopts it at once and nudges the others; a failed write changes nothing", function()
		local w = newLive()
		w.svc.refresh("boot")
		local ok, text = w.svc.command(ADMIN, { action = "set", flag = "store", on = false })
		h.ok(ok)
		h.contains(text, "store OFF")
		h.eq(w.doc.off, { store = true })
		h.eq(w.doc.by, ADMIN)
		h.eq(w.published, { 1 })
		h.eq(w.svc.storeBlock(), "paused for maintenance")
		w.writeFails = true
		ok, text = w.svc.command(ADMIN, { action = "reset" })
		h.eq(ok, false)
		h.contains(text, "nothing changed")
		h.eq(w.svc.storeBlock(), "paused for maintenance")
		w.writeFails = false
		ok = w.svc.command(ADMIN, { action = "reset" })
		h.ok(ok)
		h.eq(w.svc.storeBlock(), nil)
		local okS, status = w.svc.command(ADMIN, { action = "status" })
		h.ok(okS)
		h.contains(status, "Live flags all on (rev 2, store).")
	end)

	h.test("service: nudges re-read the row, skip stale revisions and collapse bursts", function()
		local w = newLive({ doc = { v = 1, rev = 1, off = {} } })
		w.svc.refresh("boot")
		w.doc = { v = 1, rev = 2, off = { telemetry = true } }
		h.eq(w.svc.nudge(1), false, "an older revision is ignored")
		w.t += 10
		h.eq(w.svc.nudge(2), true)
		h.eq(w.svc.isOn("telemetry"), false)
		w.doc = { v = 1, rev = 3, off = {} }
		h.eq(w.svc.nudge(3), false, "inside NUDGE_GAP: collapsed (the poll catches it)")
		w.t += R.NUDGE_GAP
		h.eq(w.svc.nudge(3), true)
		h.eq(w.svc.isOn("telemetry"), true)
	end)

	h.test("service: closing refuses store prompts and every non-hub mode", function()
		local w = newLive()
		w.svc.refresh("boot")
		w.svc.setClosing(true)
		h.eq(w.svc.storeBlock(), "server restarting")
		h.eq(w.svc.modeBlock("DINO-4", "race"), "server restarting")
		h.eq(w.svc.modeBlock("HUB-0", "hub"), nil)
		h.contains(w.logs, "closing=true")
	end)

	h.test("module reads fail OPEN before init", function()
		h.eq(LiveOps.isOn("store"), true)
		h.eq(LiveOps.closing(), false)
		h.eq(LiveOps.service(), nil)
	end)

	------------------------------------------------------------------------------------------------ shutdown

	local function newShutdown(opts: any?)
		local o = opts or {}
		local sched = h.newScheduler()
		local w: any = { sched = sched, events = {}, players = {}, racing = o.racing == true, kicks = {}, teleports = 0, closing = false }
		for i = 1, (o.players or 2) do
			table.insert(w.players, h.fakePlayer(9000 + i))
		end
		local function ev(s: string)
			table.insert(w.events, s)
		end
		w.sd = LiveOps.newShutdown({
			players = function()
				return table.clone(w.players)
			end,
			racing = function()
				return w.racing
			end,
			release = function(p, deadline)
				ev("save " .. p.UserId)
				sched.sleep(1)
				if o.saveFails and o.saveFails[p.UserId] then
					return false
				end
				return sched.clock() <= deadline
			end,
			teleport = function(list)
				w.teleports += 1
				ev("teleport " .. #list)
				if o.teleportFails then
					return false, "TeleportService 773"
				end
				-- Everyone arrives elsewhere a few seconds later, except listed stragglers.
				sched.spawn(function()
					sched.sleep(3)
					local keep = {}
					for _, p in w.players do
						if o.stuck and o.stuck[p.UserId] then
							table.insert(keep, p)
						end
					end
					w.players = keep
				end)
				return true
			end,
			kick = function(p, msg)
				table.insert(w.kicks, { user = p.UserId, msg = msg })
				ev("kick " .. p.UserId)
			end,
			notify = function(kind, text)
				ev(kind .. ": " .. tostring(text))
			end,
			setClosing = function(on)
				w.closing = on
				ev("closing " .. tostring(on))
			end,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function(line)
				ev(line)
			end,
			dryRun = o.dryRun,
		})
		return w
	end

	local function indexOf(list: { string }, needle: string): number
		for i, s in list do
			if string.find(s, needle, 1, true) then
				return i
			end
		end
		return -1
	end

	h.test("moveBy / readyToMove: race grace capped by the restart time, never before the notice", function()
		h.eq(R.moveBy(100, nil), 100 + R.SHUTDOWN.RACE_GRACE)
		h.eq(R.moveBy(100, 200), 200 - R.SHUTDOWN.MOVE_MARGIN)
		h.eq(R.moveBy(100, 110), 100 + R.SHUTDOWN.NOTICE_SECONDS, "a restart already near still shows the notice")
		h.eq(R.readyToMove(102, 100, 250, false), false, "notice first")
		h.eq(R.readyToMove(105, 100, 250, false), true)
		h.eq(R.readyToMove(200, 100, 250, true), false, "a race is still running")
		h.eq(R.readyToMove(250, 100, 250, true), true, "grace over")
	end)

	h.test("soft shutdown: notice and hold, wait for the race, save every player, teleport, nobody kicked", function()
		local w = newShutdown({ racing = true })
		local t0 = w.sched.clock()
		local done = false
		w.sched.spawn(function()
			w.sd.soft(600)
			done = true
		end)
		h.eq(w.closing, true, "new races held at once")
		h.ok(indexOf(w.events, "banner: " .. R.TEXT.softBanner) > 0)
		h.ok(indexOf(w.events, "toast: " .. R.TEXT.softToast) > 0)
		w.sched.advance(60)
		h.eq(indexOf(w.events, "save "), -1, "nothing saved or moved while the race runs")
		w.racing = false
		w.sched.advance(2)
		h.ok(indexOf(w.events, "save 9001") > 0 and indexOf(w.events, "save 9002") > 0)
		w.sched.advance(30)
		h.ok(done)
		h.eq(w.teleports, 1)
		h.ok(indexOf(w.events, "save 9002") < indexOf(w.events, "teleport 2"), "saves land before the teleport")
		h.eq(#w.kicks, 0)
		h.eq(w.sd.phase(), "done")
		h.ok(w.sched.clock() - t0 < 120)
	end)

	h.test("soft shutdown: a race still running at the grace limit is cut (logged), restart time respected", function()
		local w = newShutdown({ racing = true })
		local t0 = w.sched.clock()
		w.sched.spawn(function()
			w.sd.soft(100)
		end)
		w.sched.advance(100 - R.SHUTDOWN.MOVE_MARGIN - 1)
		h.eq(indexOf(w.events, "save "), -1)
		w.sched.advance(2)
		h.ok(indexOf(w.events, "phase=save raceCut=1") > 0)
		h.ok(w.sched.clock() - t0 <= 100)
	end)

	h.test("soft shutdown: teleport fails twice -> friendly kick that says whether the save landed", function()
		local w = newShutdown({ teleportFails = true, saveFails = { [9002] = true } })
		w.sched.spawn(function()
			w.sd.soft(nil)
		end)
		w.sched.advance(60)
		h.eq(w.teleports, 2, "one retry")
		h.eq(#w.kicks, 2)
		h.eq(w.kicks[1].msg, R.TEXT.kickSaved)
		h.eq(w.kicks[2].msg, R.TEXT.kickUnsaved)
		h.ok(indexOf(w.events, "teleport failed again") > 0)
	end)

	h.test("soft shutdown: a straggler the teleport did not take is kicked after KICK_AFTER", function()
		local w = newShutdown({ stuck = { [9001] = true } })
		w.sched.spawn(function()
			w.sd.soft(nil)
		end)
		w.sched.advance(60)
		h.eq(#w.kicks, 1)
		h.eq(w.kicks[1].user, 9001)
		h.eq(w.kicks[1].msg, R.TEXT.kickSaved)
	end)

	h.test("soft shutdown dry run (Studio QA): logs the teleport and the kick, does neither", function()
		local w = newShutdown({ dryRun = true })
		w.sched.spawn(function()
			w.sd.soft(nil)
		end)
		w.sched.advance(60)
		h.eq(w.teleports, 0)
		h.eq(#w.kicks, 0)
		h.ok(indexOf(w.events, "dryRun teleport players=2") > 0)
		h.ok(indexOf(w.events, "dryRun kick user=9001 saved=true") > 0)
	end)

	h.test("hard close (BindToClose): toast, saves within the budget, friendly kick; a soft run in progress yields", function()
		local w = newShutdown({ racing = true })
		w.sched.spawn(function()
			w.sd.soft(600)
		end)
		w.sched.advance(10)
		local result
		w.sched.spawn(function()
			result = w.sd.close()
		end)
		w.sched.advance(R.SHUTDOWN.CLOSE_SAVE_SECONDS + 2)
		h.eq(result, "done")
		h.ok(indexOf(w.events, "toast: " .. R.TEXT.closeToast) > 0)
		h.eq(#w.kicks, 2)
		h.eq(w.kicks[1].msg, R.TEXT.kickSaved)
		h.ok(indexOf(w.events, "save 9001") < indexOf(w.events, "kick 9001"), "save before kick")
		w.sched.advance(600)
		h.eq(w.teleports, 0, "the soft run stopped once the close took over")
	end)

	------------------------------------------------------------------------------------------------ admin path

	local function adminSvc(studio: boolean, live: any)
		local logs = {}
		local tick = 1000
		local svc = AdminService.new({
			isStudio = function()
				return studio
			end,
			attr = function(name)
				return if name == "QAAdminStudio" then studio else nil
			end,
			playerByUserId = function()
				return nil
			end,
			award = function()
				return "noop"
			end,
			economy = function()
				return nil
			end,
			keyForId = function()
				return nil
			end,
			adminStart = function()
				return false, "no"
			end,
			republish = function() end,
			stormForce = function()
				return false, "no"
			end,
			clock = function()
				tick += 1 -- each request a second apart (past REQUEST_GAP)
				return tick
			end,
			log = function(line)
				table.insert(logs, line)
			end,
			liveOps = function()
				return live
			end,
		})
		return svc, logs
	end

	h.test("admin: /admin live flips flags for the admin account with a kind=admin line; others get nothing", function()
		local w = newLive()
		w.svc.refresh("boot")
		local svc, logs = adminSvc(false, w.svc)
		local other = h.fakePlayer(OTHER)
		h.eq(svc.handle(other, "/admin live store off"), nil)
		h.eq(w.svc.isOn("store"), true, "a normal player changes nothing")
		local admin = h.fakePlayer(ADMIN)
		local r = svc.handle(admin, "/admin live store off")
		h.ok(r and r.ok)
		h.eq(w.svc.isOn("store"), false)
		h.contains(logs, "[SkyRally][ADMIN] kind=admin action=live user=" .. ADMIN .. " result=set flag=store on=false")
	end)

	h.test("admin: the Studio override may read the flags but never write them", function()
		local w = newLive()
		w.svc.refresh("boot")
		local svc, logs = adminSvc(true, w.svc)
		local tester = h.fakePlayer(OTHER)
		svc.noteJoin(tester)
		local r = svc.handle(tester, "/admin live")
		h.ok(r and r.ok)
		h.contains(r.text, "Live flags all on")
		local r2 = svc.handle(tester, "/admin live battles off")
		h.ok(r2 ~= nil and r2.ok == false)
		h.eq(r2.text, "Live flags need the admin account itself.")
		h.eq(w.svc.isOn("battles"), true)
		h.contains(logs, "action=live user=" .. OTHER .. " result=denied studioOverride")
	end)

	------------------------------------------------------------------------------------------------ source guards

	h.test("hooks: every switch is wired where it acts, and each fails open", function()
		local econ = h.readFile("src/server/Economy.luau")
		h.contains(econ, "Economy.liveCheck = nil :: (() -> string?)?")
		h.contains(econ, "local paused = if live then live() else nil")
		h.contains(econ, "if not telemetryOn() then")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "TrackDirector.liveBlock = nil")
		h.contains(td, "local paused = if live then live(td.id, m) else nil")
		for _, f in { "src/server/StormCup.luau", "src/server/StormRace.luau" } do
			h.contains(h.readFile(f), 'if not LiveOps.isOn("stormcup") or LiveOps.closing() then')
		end
		h.contains(h.readFile("src/server/AvatarSelect.luau"), 'isOn("avatars")')
		h.contains(h.readFile("src/server/ErrorReporter.luau"), 'isOn("telemetry")')
		local funnels = h.readFile("src/server/Funnels.luau")
		local n = 0
		for _ in string.gmatch(funnels, "if not telemetryOn%(%) then") do
			n += 1
		end
		h.eq(n, 6, "three funnel sinks and three progression sinks")
		local boot = h.readFile("src/server/init.server.luau")
		local a = string.find(boot, "require(script.StormRace).boot(StormCup)", 1, true)
		local b = string.find(boot, "require(script.LiveOps).init()", 1, true)
		local c = string.find(boot, "require(script.AdminService).init()", 1, true)
		h.ok(a and b and c and a < b and b < c, "LiveOps starts after StormRace (hold chain) and before AdminService")
		h.contains(boot, "init failed (all features ON)")
		-- FLY AGAIN (solo, vote, BattleCore) goes through replayCurrent: a paused mode or a closing server sends the
		-- players to the hub instead of restarting the battle or race; no hook / nothing paused = the old replay.
		local rc = string.find(boot, "local function replayCurrent(): boolean", 1, true)
		local lb = string.find(boot, "local paused = liveReplayBlock()", rc or 1, true)
		local st = string.find(boot, "TrackDirector.onReplay()", rc or 1, true)
		h.ok(rc and lb and st and rc < lb and lb < st, "replayCurrent checks the live block before restarting the mode")
		h.contains(boot, "local live = TrackDirector.liveBlock\n\tif not live then\n\t\treturn nil")
	end)

	h.test("live ops never touch driving, adhesion, barriers, kill volumes or rescue", function()
		for _, f in { "src/shared/LiveOpsRules.luau", "src/server/LiveOps.luau" } do
			local src = string.lower(h.readFile(f))
			for _, word in { "adhesion", "killvolume", "barrier", "rescue", "carcontroller", "flightcontroller" } do
				h.eq(string.find(src, word, 1, true), nil, f .. " mentions " .. word)
			end
		end
	end)
end
