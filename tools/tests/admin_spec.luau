--!strict
-- Lune spec for the owner admin account (DECISIONS D22; TEST_LIST_LAUNCH L90): server/AdminConfig + shared/AdminRules,
-- server/AdminService over fakes, the REAL SaveService (memory store) and Economy for the grants, the StormCup force path,
-- the Progression bypass arguments and source guards on the gates (TrackDirector, SaveService, the client's Settings ADMIN page).
-- The law: the wrong user gets nothing (nil reply, no write, no hook opens), the admin gets every action, the map-access
-- bypass is runtime only (no token is ever written by it) and live servers ignore the Studio test path.
-- Run: tools/tests/run_lune_tests.sh tools/tests/admin_spec.luau

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
local SUNDAY_10 = 1794009600 + 86400 + 10 * 3600

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	-- Synthetic server policy for authorized-admin behavior; public defaults tested separately.
	h.fake("src/server/AdminConfig.luau", h.require("src/server/AdminConfig.luau").forUserId(90000001))
	local AdminConfig = h.require("src/server/AdminConfig.luau")
	local HudLayoutRules = h.require("src/shared/HudLayoutRules.luau")
	local AdminRules = h.require("src/shared/AdminRules.luau")
	local Progression = h.require("src/shared/Progression.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local AdminService = h.require("src/server/AdminService.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local Economy = h.require("src/server/Economy.luau")
	local StormCup = h.require("src/server/StormCup.luau")

	-- A server: real SaveService + Economy, AdminService over them, fakes for TrackDirector and StormCup.
	local function server(opts: { studio: boolean?, attrs: { [string]: any }? }?): any
		local o: any = opts or {}
		local sched = h.newScheduler()
		local w: any = { sched = sched, logs = {}, calls = {}, attrs = o.attrs or {}, players = {}, t = 0 }
		local function log(line: string)
			table.insert(w.logs, line)
		end
		local svcRef: any = nil
		w.save = SaveService.new({
			store = SaveService.newMemoryStore({}),
			sessionId = "server-admin",
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = log,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0, saveAttempts = 2, loadAttempts = 2 },
			adminBypass = function(userId: number, source: string): boolean
				return svcRef ~= nil and svcRef.bypass(userId, source)
			end,
		})
		w.econ = Economy.new({
			save = w.save,
			purchaseStore = SaveService.newMemoryStore({}),
			giftStore = SaveService.newMemoryStore({}),
			now = function(): number
				return SUNDAY_10
			end,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = log,
			isStudio = function(): boolean
				return false
			end,
			isAdmin = function(p: any): boolean
				return svcRef ~= nil and svcRef.isAdmin(p)
			end,
		})
		w.save.onLoaded(w.econ.playerLoaded)
		local function call(name: string, ...: any)
			table.insert(w.calls, { name = name, args = { ... } })
		end
		w.svc = AdminService.new({
			isStudio = function(): boolean
				return o.studio == true
			end,
			attr = function(name: string): any
				return w.attrs[name]
			end,
			playerByUserId = function(userId: number): any
				return w.players[userId]
			end,
			award = function(p: any, kind: string, id: string, source: string): string
				call("award", kind, id, source)
				return (w.save.award(p, kind, id, source))
			end,
			economy = function(): any
				return w.econ
			end,
			keyForId = function(trackId: string): string?
				return "key_" .. trackId
			end,
			adminStart = function(p: any, key: string, mode: string): (boolean, string)
				call("adminStart", key, mode)
				return true, "starting"
			end,
			republish = function(p: any)
				call("republish")
			end,
			stormForce = function(trackId: string, modifier: string): (boolean, string)
				call("stormForce", trackId, modifier)
				return true, "queued"
			end,
			clock = function(): number
				w.t += 1 -- every request is one second after the last (past the request gap)
				return w.t
			end,
			log = log,
		})
		svcRef = w.svc
		function w.join(userId: number): any
			local p = h.fakePlayer(userId)
			w.players[userId] = p
			w.svc.noteJoin(p)
			w.econ.playerAdded(p)
			sched.run(function()
				w.save.load(p)
			end)
			sched.advance(0)
			return p
		end
		return w
	end

	---------------------------------------------------------------------------------------------- who

	h.test("who: one hard-coded UserId; usernames, strings and other ids are not admin", function()
		h.eq(AdminConfig.ADMIN_USER_ID, ADMIN)
		h.eq(AdminConfig.isAdmin(ADMIN), true)
		h.eq(AdminConfig.isAdmin(tostring(ADMIN)), false, "a string id is not the UserId")
		h.eq(AdminConfig.isAdmin("SomeUsername"), false, "never by username")
		h.eq(AdminConfig.isAdmin(OTHER), false)
		h.eq(AdminConfig.isAdmin(nil), false)
		h.ok(table.isfrozen(AdminConfig), "no runtime grant path: the config is frozen")
		local src = h.readFile("src/server/AdminService.luau")
		h.ok(not string.find(src, "GetRankInGroup", 1, true) and not string.find(src, "GetRoleInGroup", 1, true), "no group-rank check")
	end)

	h.test("who: the Studio test path is scoped to one player and ignored on a live server", function()
		local A = AdminConfig
		h.eq(A.isAdminPlayer(OTHER, false, true, OTHER), false, "live server (isStudio false) + attribute true = not admin")
		h.eq(A.isAdminPlayer(OTHER, true, false, OTHER), false, "Studio without the attribute")
		h.eq(A.isAdminPlayer(OTHER, true, "true", OTHER), false, "attribute must be exactly true")
		h.eq(A.isAdminPlayer(OTHER, true, true, OTHER), true, "Studio + attribute: the chosen test player")
		h.eq(A.isAdminPlayer(OTHER + 1, true, true, OTHER), false, "a second Studio client stays a normal player")
		h.eq(A.isAdminPlayer(ADMIN, false, nil, nil), true, "the real admin anywhere")
		-- Service level: a live server never reads the Studio attributes.
		local live = server({ studio = false, attrs = { QAAdminStudio = true, QAAdminStudioUserId = OTHER } })
		local p = live.join(OTHER)
		h.eq(live.svc.isAdmin(p), false)
		h.eq(live.svc.handle(p, "/admin cash 10000"), nil)
		-- Studio: the first joiner only (no QAAdminStudioUserId).
		local studio = server({ studio = true, attrs = { QAAdminStudio = true } })
		local first = studio.join(OTHER)
		local second = studio.join(OTHER + 1)
		h.eq(studio.svc.isAdmin(first), true)
		h.eq(studio.svc.isAdmin(second), false, "Player2 of a Local Server keeps the normal gates")
		studio.attrs.QAAdminStudio = false
		h.eq(studio.svc.isAdmin(first), false, "attribute off: nobody")
		-- AdminService reads RunService:IsStudio() itself; the remote takes only (player, text).
		local src = h.readFile("src/server/AdminService.luau")
		h.contains(src, "return RunService:IsStudio()")
		h.contains(src, "rf.OnServerInvoke = function(player: Player, text: any): any")
	end)

	---------------------------------------------------------------------------------------------- the wrong user

	h.test("wrong user gets nothing: nil reply, no hook opens, no write, no Cash, no award", function()
		local w = server()
		local p = w.join(OTHER)
		for _, text in { "/admin status", "/admin portals on", "/admin cash 10000", "/admin award token DINO-4", "/admin pass x2 on", "/admin winpass races 20", "/admin storm DINO-4 night", "/admin lobby skip", "/admin solo", "/admin hold off", "garbage", 42 } do
			h.eq(w.svc.handle(p, text), nil, "nil for " .. tostring(text))
		end
		h.eq(#w.calls, 0, "no award, start, force or republish ran")
		h.eq(w.svc.flagsOf(p), nil, "no flags: every TrackDirector gate takes the normal path")
		h.eq(w.svc.bypass(OTHER, "admin:grant"), false, "an admin: source does not open another player's gates")
		h.eq(w.save.get(p).gears, 0)
		h.eq(next(w.save.get(p).tokens), nil)
		-- Economy's own entry points refuse him too, on the kind=admin log stream, with no Garage copy needed.
		local r = w.econ.adminGrantCash(p, 10000)
		h.eq(r.ok, false)
		h.eq(r.reason, "notAdmin")
		h.eq(w.econ.adminSetPass(p, "x2Gears", true).ok, false)
		h.eq(w.econ.adminSetWinPass(p, "races", 20).ok, false)
		h.eq(w.econ.isPassActive(p, "x2Gears"), false)
		h.eq(w.save.get(p).gears, 0)
		h.ok(h.count(w.logs, "[SkyRally][ADMIN] kind=admin action=cash user=" .. OTHER .. " result=denied") == 1, "denied cash on the admin stream")
		h.ok(h.count(w.logs, "kind=admin action=request user=" .. OTHER .. " result=denied") >= 1, "denied remote request logged")
		h.eq(h.count(w.logs, "[SkyRally][ECON] reject"), 0, "no Garage reject line (no reasonText copy needed)")
		-- The client's start-up probe is not logged (it is every join).
		local before = #w.logs
		local w2 = server()
		local q = w2.join(OTHER)
		w2.svc.handle(q, AdminRules.PROBE)
		h.eq(h.count(w2.logs, "result=denied"), 0)
		h.ok(before > 0)
	end)

	---------------------------------------------------------------------------------------------- the admin

	h.test("admin: map access bypass is runtime only; grants go through award with admin:grant and repeat as noop", function()
		local w = server()
		local p = w.join(ADMIN)
		local f = w.svc.flagsOf(p)
		h.eq(f.portals, true, "bypass on by default")
		-- Progression with the bypass argument: every portal and every mode the map has; nothing read from the profile.
		local empty = Progression.newProfile and Progression.newProfile() or w.save.get(p)
		for _, zone in { "DINO", "SNOW", "ISLAND", "FOREST", "SPACE" } do
			h.eq(Progression.isPortalOpen(empty, zone, true), true, zone .. " open for the admin")
		end
		h.eq(Progression.isPortalOpen(w.save.get(p), "SNOW"), false, "without the argument the gate is unchanged")
		h.eq(Progression.isModeUnlocked(empty, "SNOW-1", "boss", true), true)
		h.eq(Progression.isModeUnlocked(empty, "SNOW-1", "battle", true), true)
		h.eq(Progression.isModeUnlocked(empty, "SPACE-4", "boss", true), false, "a mode the map does not have stays closed")
		h.eq(Progression.isModeUnlocked(empty, "HUB-0", "boss", true), true, "final boss open")
		-- A gameplay award on a bypassed map is refused by the normal gate: the bypass writes nothing.
		h.eq((w.save.award(p, "token", "race:SNOW-1", "race:SNOW-1:finish")), "rejected")
		h.eq(w.svc.bypass(ADMIN, "race:SNOW-1:finish"), false)
		h.eq(w.save.get(p).tokens["race:SNOW-1"], nil, "no token from the bypass")
		-- Explicit grants: the real AwardKind values through SaveService.award.
		local r = w.svc.handle(p, "/admin award token SNOW-1")
		h.eq(r.ok, true)
		h.contains(r.text, "granted")
		h.eq(w.calls[1].name, "award")
		h.eq(w.calls[1].args, { "token", "race:SNOW-1", "admin:grant" })
		h.eq(w.save.get(p).tokens["race:SNOW-1"], true)
		r = w.svc.handle(p, "/admin award token SNOW-1")
		h.contains(r.text, "already held", "a repeat is a noop")
		h.ok(h.count(w.logs, "noop user=" .. ADMIN .. " kind=token id=race:SNOW-1") >= 1 or h.count(w.logs, "noop") >= 1, "SaveService logs noop")
		for _, line in { "/admin award key SNOW", "/admin award bossFirst SNOW", "/admin award bossRematch SNOW", "/admin award battle ISLAND", "/admin award hubFind cove", "/admin award finalBoss" } do
			r = w.svc.handle(p, line)
			h.eq(r.ok, true, line .. ": " .. tostring(r.text))
		end
		local prof = w.save.get(p)
		h.eq(prof.keys.SNOW, true)
		h.eq(prof.battles.ISLAND, true)
		h.eq(prof.finalBoss, true)
		h.eq(prof.tokens.HubFind_Cove, true)
		-- Toggling the bypass is a flag + a board republish; it never writes the save.
		local gearsBefore = prof.gears
		r = w.svc.handle(p, "/admin portals off")
		h.eq(r.state.portals, false)
		h.eq(w.svc.flagsOf(p).portals, false)
		h.eq(w.calls[#w.calls].name, "republish")
		h.eq(w.save.get(p).gears, gearsBefore)
		h.contains(w.logs, "[SkyRally][ADMIN] kind=admin action=portals user=" .. ADMIN .. " result=set on=false")
		h.contains(w.logs, "kind=admin action=award user=" .. ADMIN)
	end)

	h.test("admin: Cash grant through the earn pattern (multiplier 1, analytics admin, clamped); 2x pass and Win Pass", function()
		local w = server()
		local p = w.join(ADMIN)
		local r = w.svc.handle(p, "/admin cash 10000")
		h.eq(r.ok, true, tostring(r.text))
		h.eq(w.save.get(p).gears, 10000)
		h.contains(r.text, "+10000 Cash")
		-- The 2x pass does not multiply an admin grant.
		h.eq(w.svc.handle(p, "/admin pass x2 on").ok, true)
		h.eq(w.econ.isPassActive(p, "x2Gears"), true)
		h.contains(tostring(p:GetAttribute("Passes")), "x2Gears", "the HUD shows the override")
		local garage = w.econ.getState(p)
		h.eq(garage.ok, true)
		h.contains(garage.data.passes, "x2Gears", "the Garage shows 2x CASH ACTIVE from the same list")
		w.svc.handle(p, "/admin cash 500")
		h.eq(w.save.get(p).gears, 10500, "admin:grant is not a multiplied source")
		-- Per-call clamp and the wallet cap.
		h.eq(AdminRules.clampCash(5000000), AdminRules.CASH_MAX_PER_CALL)
		h.eq(AdminRules.clampCash(0), nil)
		h.eq(AdminRules.clampCash("abc"), nil)
		h.eq(AdminRules.cashGrant(AdminRules.CASH_TOTAL_MAX - 10, 1000), 10)
		h.eq(w.svc.handle(p, "/admin cash -5").ok, false)
		-- Only the 2x Cash pass is in scope.
		h.eq(w.econ.adminSetPass(p, "garagePlus", true).ok, false)
		h.eq(w.svc.handle(p, "/admin pass garageplus on").ok, false)
		h.eq(AdminRules.passKeys(), { "x2Gears" })
		h.eq(w.svc.handle(p, "/admin pass x2 off").ok, true)
		h.eq(w.econ.isPassActive(p, "x2Gears"), false)
		-- Win Pass counters in his own profile.
		h.eq(w.svc.handle(p, "/admin winpass races 20").ok, true)
		h.eq(w.svc.handle(p, "/admin winpass wins 10").ok, true)
		h.eq(w.svc.handle(p, "/admin winpass premium on").ok, true)
		local wp = w.save.get(p).winPass
		h.eq(wp.races, 20)
		h.eq(wp.wins, 10)
		h.eq(wp.premium, true)
		h.eq(w.svc.handle(p, "/admin winpass races 99999").ok, true)
		h.eq(w.save.get(p).winPass.races, AdminRules.WINPASS_MAX)
		h.contains(w.logs, "[SkyRally][ADMIN] kind=admin action=cash user=" .. ADMIN .. " result=granted")
		h.contains(w.logs, "kind=admin action=winpass user=" .. ADMIN .. " result=set")
		-- Single-target: another player's save is untouched.
		local q = w.join(OTHER)
		h.eq(w.save.get(q).gears, 0)
		h.eq(w.econ.isPassActive(q, "x2Gears"), false)
		h.eq(w.econ.getState(q).data.passes, {}, "another player's Garage pass list is untouched")
		h.eq(w.econ.getState(p).data.passes, {}, "his Garage list follows the override off again")
	end)

	h.test("admin: storm, lobby, solo and hold reach their hooks with validated arguments", function()
		local w = server()
		local p = w.join(ADMIN)
		local r = w.svc.handle(p, "/admin storm snow-1 night")
		h.eq(r.ok, true)
		h.eq(w.calls[#w.calls].args, { "SNOW-1", "night" })
		w.svc.handle(p, "/admin storm DINO-4 doubleitemboxes")
		h.eq(w.calls[#w.calls].args, { "DINO-4", "doubleItemBoxes" })
		w.svc.handle(p, "/admin storm FOREST-1 none")
		h.eq(w.calls[#w.calls].args, { "FOREST-1", "none" })
		h.eq(w.svc.handle(p, "/admin storm HUB-0 night").ok, false, "not a cup map")
		h.eq(w.svc.handle(p, "/admin storm DINO-4 mirrored").ok, false, "not a built modifier")
		h.eq(w.svc.handle(p, "/admin lobby skip").state.lobby, "skip")
		h.eq(AdminRules.lobbySeconds("skip", 20), 0)
		h.eq(AdminRules.lobbySeconds("short", 20), AdminRules.SHORT_LOBBY_SECONDS)
		h.eq(AdminRules.lobbySeconds("normal", 20), 20)
		h.eq(w.svc.handle(p, "/admin hold off").state.holdOff, true)
		h.eq(AdminRules.skipsHold(w.svc.flagsOf(p)), true)
		h.eq(AdminRules.skipsHold(nil), false, "nobody else skips the cup hold")
		r = w.svc.handle(p, "/admin solo")
		h.eq(r.ok, true)
		h.eq(w.calls[#w.calls].args, { "key_DINO-4", "race" })
		w.svc.handle(p, "/admin solo hub-0")
		h.eq(w.calls[#w.calls].args, { "key_HUB-0", "boss" })
		h.eq(w.svc.handle(p, "/admin solo SPACE-4 boss").ok, false, "SPACE-4 has no boss")
		h.eq(w.svc.handle(p, "/admin help").ok, true)
		h.eq(w.svc.handle(p, "/admin nonsense").ok, false)
	end)

	---------------------------------------------------------------------------------------------- Storm Cup force

	h.test("StormCup.forceAdmin: his map and modifier, the slot's own cup still runs, refused under storm race v2", function()
		local function cup(publishOnly: boolean?): any
			local w: any = { t = SUNDAY_10 + 700, mode = "hub", launches = {}, logs = {} }
			w.svc = StormCup.new({
				now = function(): number
					return w.t
				end,
				enabled = function(): boolean
					return true
				end,
				world = function(): any
					return { mode = w.mode, switching = false, finishedFor = nil, players = 1 }
				end,
				hasTrack = function(id: string): boolean
					return id ~= "SPACE-4"
				end,
				launch = function(c: any): boolean
					table.insert(w.launches, c)
					w.mode = StormCup.MODE
					return true
				end,
				setAttr = function() end,
				log = function(line: string)
					table.insert(w.logs, line)
				end,
				publishOnly = publishOnly,
			})
			return w
		end
		local w = cup()
		local ok = w.svc.forceAdmin("ISLAND-2", "night")
		h.eq(ok, true)
		w.svc.step()
		h.eq(#w.launches, 1)
		h.eq(w.launches[1].trackId, "ISLAND-2")
		h.eq(w.launches[1].modifier, "night")
		h.eq(w.launches[1].admin, true)
		h.eq(w.svc.lastRun, -math.huge, "the scheduled cup at the next slot still runs")
		h.contains(w.logs, "(admin force)")
		w.mode = "hub"
		w.svc.step()
		h.eq(#w.launches, 1, "one force = one cup")
		h.eq((w.svc.forceAdmin("SPACE-4", "night")), false, "a map not mounted here")
		h.eq((w.svc.forceAdmin("HUB-0", "night")), false, "not a cup map")
		h.eq((w.svc.forceAdmin("DINO-4", "mirrored")), false, "not a built modifier")
		h.eq((w.svc.forceAdmin("DINO-4", "none")), true)
		local v2 = cup(true)
		h.eq((v2.svc.forceAdmin("DINO-4", "night")), false, "storm race v2: no whole-server cup")
		v2.svc.step()
		h.eq(#v2.launches, 0)
		h.ok(table.find(MonetizationConfig.STORM_CUP.tracks, "ISLAND-2") ~= nil)
		-- Live wiring: only through AdminService (after its UserId check); the Studio StormCupNow path is unchanged.
		local src = h.readFile("src/server/StormCup.luau")
		h.contains(src, 'if RunService:IsStudio() and workspace:GetAttribute("StormCupNow") == true then')
		h.contains(src, "function StormCup.adminForce(trackId: string, modifier: string)")
	end)

	---------------------------------------------------------------------------------------------- gates (source guards)

	h.test("gates: the admin branch sits at the top of each check and is nil for everyone else", function()
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "if AdminRules.portalsOpen(adminOf(player)) and Progression.isModeUnlocked({} :: any, td.id, m, true) then")
		h.contains(td, "local hold = if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) then TrackDirector.holdRequests() else nil")
		h.contains(td, "if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(l.opener)) and TrackDirector.holdRequests() then")
		-- Arch crossings (stepPortals since portal-load): every cup-hold read there honours the admin's CUP HOLD off.
		for line in string.gmatch(td, "[^\n]*local hold = if ok and TrackDirector%.holdRequests[^\n]*") do
			h.ok(string.find(line, "AdminRules.skipsHold(adminOf(player))", 1, true) ~= nil, "arch hold check skips for the admin: " .. line)
		end
		h.contains(td, "local hold = if ok and TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) then TrackDirector.holdRequests() else nil")
		h.contains(td, "lobbySeconds = AdminRules.lobbySeconds(af.lobby, lobbySeconds)")
		h.contains(td, "function TrackDirector.adminStart(player: Player, key: string, mode: string): (boolean, string)")
		h.contains(td, 'if not adminOf(player) then\n\t\treturn false, "not available"')
		-- The non-admin paths keep their words.
		h.contains(td, "local ok, why = TrackDirector.canOpen(player, key, m)")
		h.contains(td, 'return false, if need then string.format("needs %d Sky Token%s"')
		h.eq(AdminRules.portalsOpen(nil), false)
		-- SaveService: adminOpen only from the hook, only for admin: sources.
		local sv = h.readFile("src/server/SaveService.luau")
		h.contains(sv, "local adminOpen = adminBypass(st.userId, source)")
		h.eq(AdminConfig.awardBypass(AdminRules.defaultFlags(), "race:DINO-4:finish"), false)
		h.eq(AdminConfig.awardBypass(AdminRules.defaultFlags(), "admin:grant"), true)
		h.eq(AdminConfig.awardBypass(nil, "admin:grant"), false)
		-- Wiring: the boot script starts AdminService; the hooks are set there only.
		local boot = h.readFile("src/server/init.server.luau")
		h.contains(boot, "require(script.AdminService).init()")
		local svc = h.readFile("src/server/AdminService.luau")
		h.contains(svc, "SaveService.adminBypass = svc.bypass")
		h.contains(svc, "Economy.adminCheck = svc.isAdmin")
		h.contains(svc, "TrackDirector.adminFlags = svc.flagsOf")
		h.ok(not string.find(svc, ":SetAttribute(", 1, true), "no replicated attribute marks the admin")
	end)

	h.test("client: nothing exists (Settings tab, page, /admin command) until the server answers the status ask", function()
		-- The gate: only a reply table from the server's status ask counts; nil (every other player) or an error is nothing.
		h.eq(AdminRules.probeSaysAdmin(true, { ok = true, text = "x" }), true)
		h.eq(AdminRules.probeSaysAdmin(true, nil), false, "the server answers nil to everyone else")
		h.eq(AdminRules.probeSaysAdmin(false, "error"), false)
		h.eq(AdminRules.probeSaysAdmin(true, "text"), false)
		local src = h.readFile("src/client/AdminPanel.luau")
		h.contains(src, "if AdminRules.probeSaysAdmin(ok, r) then\n\t\t\t\tregister()")
		local _, n = string.gsub(src, 'Instance.new%("TextChatCommand"%)', "")
		h.eq(n, 1)
		local _, m = string.gsub(src, "Settings.setExtraPage%(", "")
		h.eq(m, 1, "one registration")
		local reg = string.find(src, "local function register()", 1, true) :: number
		h.ok(reg < string.find(src, 'Instance.new("TextChatCommand")', 1, true), "the command is created inside register()")
		h.ok(reg < string.find(src, "Settings.setExtraPage(", 1, true), "the tab is registered inside register()")
		-- Owner 2026-10-21: the admin settings live in the Settings tab. No button, hotkey or screen of their own.
		h.ok(not string.find(src, 'Instance.new("ScreenGui")', 1, true), "no ScreenGui of its own")
		h.ok(not string.find(src, "KeyCode", 1, true) and not string.find(src, "InputBegan", 1, true), "no hotkey")
		h.ok(not string.find(src, "HudMetrics", 1, true), "no HUD slot")
		h.eq(AdminRules.HOTKEY, nil)
		h.eq(AdminRules.buttonRect, nil)
		h.eq(AdminRules.panelRect, nil)
		h.eq(AdminRules.PAGE_TITLE, "ADMIN")
		h.ok(not string.find(src, "livery", 1, true) and not string.find(string.lower(src), "bonk", 1, true), "copy rules")
		-- Settings builds the tab pair and the page only for a registered page; nobody but AdminPanel registers one.
		local st = h.readFile("src/client/Settings.luau")
		h.contains(st, "local function addExtra()\n\tlocal e = extra\n\tif not built or not e or extraTab then\n\t\treturn\n\tend")
		local _, tabs = string.gsub(st, 'tab%("PageTab"', "")
		h.eq(tabs, 1, "the page tab is made in addExtra only")
		h.contains(st, "\tpaintAll()\n\taddExtra()\nend")
		h.contains(st, "\tshowPage(false) -- every open starts on the settings rows")
		h.ok(not string.find(st, "AdminRules", 1, true), "Settings knows no admin rules")
		h.ok(not string.find(st, tostring(ADMIN), 1, true))
	end)

	---------------------------------------------------------------------------------------------- review fixes (v28 review)

	h.test("replication: the admin's UserId, the Studio path and the gate source are server-only", function()
		h.ok(not pcall(h.readFile, "src/shared/AdminConfig.luau") or h.readFile("src/shared/AdminConfig.luau") == "", "no shared AdminConfig")
		for _, path in { "src/shared/AdminRules.luau", "src/client/AdminPanel.luau", "src/client/Settings.luau", "src/shared/SettingsRules.luau", "src/client/HudMetrics.luau", "src/shared/HudLayoutRules.luau" } do
			local src = h.readFile(path)
			h.ok(not string.find(src, tostring(ADMIN), 1, true), path .. " carries no admin UserId")
			h.ok(not string.find(src, "AdminConfig", 1, true) or path == "src/shared/AdminRules.luau", path .. " requires no AdminConfig")
			h.ok(not string.find(src, "admin:grant", 1, true), path .. " carries no gate-opening award source")
			h.ok(not string.find(src, "QAAdminStudio", 1, true), path .. " carries no Studio admin attribute")
		end
		h.ok(not string.find(h.readFile("src/shared/AdminRules.luau"), "require(script.Parent:WaitForChild(\"AdminConfig\"))", 1, true))
		h.eq(AdminRules.isAdmin, nil)
		h.eq(AdminRules.isAdminPlayer, nil)
		h.eq(AdminRules.awardBypass, nil)
		h.eq(AdminRules.AWARD_SOURCE, nil)
		h.eq(AdminConfig.AWARD_SOURCE, "admin:grant")
		h.contains(h.readFile("src/server/AdminService.luau"), "local AdminConfig = require(script.Parent.AdminConfig)")
	end)

	h.test("logs: race starts the admin's flags let through log kind=admin (hold, portals, lobby skip / short)", function()
		local f = AdminRules.defaultFlags()
		h.eq(AdminRules.admitBypass(nil, true, "admin"), nil, "nobody else")
		h.eq(AdminRules.admitBypass(f, false, "open"), nil, "no flag changed the outcome")
		h.eq(AdminRules.admitBypass(f, false, "admin"), "portalBypass")
		h.eq(AdminRules.admitBypass(f, true, "open"), nil, "hold on: his race was held like anyone's")
		f.holdOff = true
		h.eq(AdminRules.admitBypass(f, true, "open"), "holdBypass")
		h.eq(AdminRules.admitBypass(f, true, "admin"), "holdBypass+portalBypass")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, 'print(string.format("%s action=%s user=%d result=applied %s", AdminRules.LOG, action, player.UserId, detail))')
		h.contains(td, "local what = AdminRules.admitBypass(af, holdActive, why)")
		h.contains(td, 'adminLog(player, "lobbySkip", ')
		h.contains(td, 'adminLog(player, "lobbyShort", ')
		h.contains(td, 'adminLog(l.opener, "holdBypass", ')
		h.contains(td, "l.adminHoldLogged = true")
		-- The non-admin gate lines are unchanged.
		h.contains(td, "local hold = if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) then TrackDirector.holdRequests() else nil")
		h.contains(td, "local ok, why = TrackDirector.canOpen(player, key, m)")
	end)

	local function cupWorld(opts: { enabled: boolean?, perGroup: boolean?, launchOk: boolean?, t: number? }): any
		local w: any = { t = opts.t or (SUNDAY_10 + 700), mode = "hub", launches = {}, logs = {}, enabled = opts.enabled ~= false }
		w.svc = StormCup.new({
			now = function(): number
				return w.t
			end,
			enabled = function(): boolean
				return w.enabled
			end,
			world = function(): any
				return { mode = w.mode, switching = false, finishedFor = nil, players = 1 }
			end,
			hasTrack = function(id: string): boolean
				return id ~= "SPACE-4"
			end,
			launch = function(c: any): boolean
				if opts.launchOk == false then
					return false
				end
				table.insert(w.launches, c)
				w.mode = StormCup.MODE
				return true
			end,
			setAttr = function() end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			perGroup = opts.perGroup,
		})
		return w
	end

	h.test("storm force: a scheduled cup due first runs, then the admin's cup (never silently dropped, never stale)", function()
		local w = cupWorld({ t = SUNDAY_10 + 1790 })
		w.mode = "race" -- a race is running: the forced cup waits
		h.eq((w.svc.forceAdmin("ISLAND-2", "night")), true)
		h.eq(w.svc.step(), "waiting")
		w.t = SUNDAY_10 + 1801 -- the :30 slot comes due before the world is ready
		w.mode = "hub"
		h.eq(w.svc.step(), "launched")
		h.eq(#w.launches, 1)
		h.eq(w.launches[1].admin, nil, "the scheduled cup ran first")
		h.contains(w.logs, "[SkyRally][ADMIN] kind=admin action=storm result=deferred track=ISLAND-2 modifier=night")
		w.mode = "hub" -- after that cup
		h.eq(w.svc.step(), "launched")
		h.eq(#w.launches, 2)
		h.eq(w.launches[2].admin, true, "then the admin's cup")
		h.eq(w.launches[2].trackId, "ISLAND-2")
		h.eq(w.launches[2].modifier, "night")
		w.mode = "hub"
		h.eq(w.svc.step(), nil, "nothing stale left: no third cup")
		h.eq(#w.launches, 2)
	end)

	h.test("storm force: refused while the cup is off or per-group; a failed admin launch logs kind=admin", function()
		local off = cupWorld({ enabled = false })
		local ok, why = off.svc.forceAdmin("DINO-4", "night")
		h.eq(ok, false)
		h.contains(why, "off")
		off.svc.step()
		h.eq(#off.launches, 0, "no whole-server cup while the Garage is off")
		-- Switched off after the force: dropped and logged, never launched.
		local late = cupWorld({})
		late.mode = "race"
		h.eq((late.svc.forceAdmin("DINO-4", "night")), true)
		late.enabled = false
		late.mode = "hub"
		late.svc.step()
		h.eq(#late.launches, 0)
		h.contains(late.logs, "kind=admin action=storm result=dropped track=DINO-4")
		late.enabled = true
		late.svc.step()
		h.eq(#late.launches, 0, "the dropped pick does not come back")
		-- Per group without storm race v2: no whole-server launch path.
		local pg = cupWorld({ perGroup = true })
		local pok, pwhy = pg.svc.forceAdmin("DINO-4", "night")
		h.eq(pok, false)
		h.contains(pwhy, "per-group")
		h.contains(h.readFile("src/server/StormCup.luau"), "perGroup = RaceFlowRules.PER_GROUP == true,")
		-- A launch the server refuses is reported on the admin stream.
		local bad = cupWorld({ launchOk = false })
		h.eq((bad.svc.forceAdmin("DINO-4", "none")), true)
		h.eq(bad.svc.step(), "failed")
		h.contains(bad.logs, "[SkyRally][ADMIN] kind=admin action=storm result=failed track=DINO-4 modifier=none")
	end)

	h.test("HUD: the layout is the stage-v28 layout for everyone (no admin slot, no admin option)", function()
		for _, path in { "src/shared/HudLayoutRules.luau", "src/client/HudMetrics.luau" } do
			h.ok(not string.find(string.lower(h.readFile(path)), "admin", 1, true), path .. " has no admin branch")
		end
		local R = HudLayoutRules
		for _, c in {
			{ 844, 390, { left = 47, top = 0, right = 47, bottom = 21 }, "touch" },
			{ 740, 360, { left = 44, top = 0, right = 44, bottom = 20 }, "touch" },
			{ 1920, 1080, { left = 0, top = 0, right = 0, bottom = 0 }, "desktop" },
		} do
			local plain = R.compute(c[1], c[2], c[3], R.fallbackNav(c[1], c[2]), c[4])
			local withOld = R.compute(c[1], c[2], c[3], R.fallbackNav(c[1], c[2]), c[4], { adminSlot = true } :: any)
			h.eq(plain.admin, nil)
			h.eq(withOld.admin, nil, "the old adminSlot option is gone")
			for k, rect in plain do
				h.eq(withOld[k], rect, string.format("%dx%d %s unchanged", c[1], c[2], k))
			end
		end
	end)

	h.test("Settings ADMIN page: under the header, clear of the Roblox nav on phones, room for the rows", function()
		local R = HudLayoutRules
		local SettingsRules = h.require("src/shared/SettingsRules.luau")
		local W, H = SettingsRules.PANEL_W, SettingsRules.PANEL_H
		for _, c in { { 740, 360 }, { 844, 390 }, { 667, 375 }, { 1366, 768 }, { 1920, 1080 }, { 1920, 857 } } do
			local vx, vy = c[1], c[2]
			local label = string.format("%dx%d", vx, vy)
			local s = SettingsRules.panelScale(vx, vy)
			local nav = R.fallbackNav(vx, vy)
			local top = SettingsRules.pageTop(vx, vy, s, nav)
			h.ok(top >= SettingsRules.PAGE_TOP, label .. ": under the header")
			local page = { x = (vx - W * s) / 2 + 14 * s, y = (vy - H * s) / 2 + top * s, w = (W - 28) * s, h = (H - top - 12) * s }
			-- Three 44 px tap rows must show at once on screen; the rest scroll.
			h.ok(page.h >= 3 * 44, string.format("%s: room for three rows (%d px)", label, math.floor(page.h)))
			h.ok(not R.overlap(page, nav), label .. ": page clear of the nav (top " .. top .. ")")
			h.ok(page.y + page.h <= vy and page.x >= 0 and page.x + page.w <= vx, label .. ": on screen")
		end
		-- Desktop: the panel sits far from the nav, the page starts right under the header.
		h.eq(SettingsRules.pageTop(1920, 1080, SettingsRules.panelScale(1920, 1080), R.fallbackNav(1920, 1080)), SettingsRules.PAGE_TOP)
		h.eq(SettingsRules.pageTop(740, 360, 1, { x = 0, y = 0, w = 0, h = 0 }), SettingsRules.PAGE_TOP, "no nav reserve")
		h.contains(h.readFile("src/client/Settings.luau"), "local top = Rules.pageTop(vp.X, vp.Y, fit.Scale, HudMetrics.get().nav)")
	end)

	h.test("BattlesOpen: the admin's bypass lists every battle (results card BATTLE); everyone else keeps the profile's", function()
		local BattleAccessRules = h.require("src/shared/BattleAccessRules.luau")
		local w = server()
		SaveService.adminPortals = w.svc.portalsOpen
		local ok, err = pcall(function()
			local p = w.join(ADMIN)
			local q = w.join(OTHER)
			local all = BattleAccessRules.encode(Progression.battleZones(w.save.get(p), true))
			h.ok(all ~= BattleAccessRules.encode({}), "the bypass opens battles")
			h.eq(p:GetAttribute("BattlesOpen"), all, "admin: every battle the map has")
			h.eq(q:GetAttribute("BattlesOpen"), BattleAccessRules.encode(Progression.battleZones(w.save.get(q))), "other: the profile's")
			h.eq(w.svc.portalsOpen(OTHER), false)
			w.svc.handle(p, "/admin portals off")
			h.eq(w.svc.portalsOpen(ADMIN), false)
		end)
		SaveService.adminPortals = nil
		h.ok(ok, tostring(err))
		h.contains(h.readFile("src/server/AdminService.luau"), "SaveService.adminPortals = svc.portalsOpen")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "player:SetAttribute(BattleAccessRules.ATTR, BattleAccessRules.encode(Progression.battleZones(profile, open)))")
		h.contains(h.readFile("src/server/SaveService.luau"), "st.player:SetAttribute(BattleAccessRules.ATTR, BattleAccessRules.encode(Progression.battleZones(profile)))")
	end)

	---------------------------------------------------------------------------------------------- Studio proof fixes (2026-10-21)

	h.test("chat: legacy chat lines; everyone else returns at once with nothing parsed or logged, his /admin lines run", function()
		h.eq(AdminRules.isChatCommand("/admin"), true)
		h.eq(AdminRules.isChatCommand("  /ADMIN cash 1000"), true)
		h.eq(AdminRules.isChatCommand("/administrator"), false)
		h.eq(AdminRules.isChatCommand("/adminx cash 5"), false)
		h.eq(AdminRules.isChatCommand("hello /admin cash 5"), false)
		h.eq(AdminRules.isChatCommand(string.rep("a", 201)), false)
		h.eq(AdminRules.isChatCommand(42), false)
		local w = server()
		local q = w.join(OTHER)
		local logsBefore = #w.logs
		for _, line in { "/admin cash 1000", "/admin status", "/admin storm DINO-4 night", "hello" } do
			h.eq(w.svc.chat(q, line), nil, "nil for " .. line)
		end
		h.eq(#w.logs, logsBefore, "no line logged for another player's chat")
		h.eq(#w.calls, 0)
		h.eq(w.save.get(q).gears, 0)
		local p = w.join(ADMIN)
		h.eq(w.svc.chat(p, "good race"), nil, "his ordinary chat stays chat")
		local r = w.svc.chat(p, "/admin cash 1000")
		h.ok(r ~= nil and r.ok, "his /admin line runs")
		h.eq(w.save.get(p).gears, 1000)
		h.contains(w.logs, "kind=admin action=cash user=" .. ADMIN .. " result=granted")
		-- The legacy hook swallows only lines svc.chat answered; every other message goes to chat unchanged.
		local src = h.readFile("src/server/AdminService.luau")
		h.contains(src, "local legacy = ChatCompat.detect(TextChatService.ChatVersion.Name) == \"legacy\"")
		h.contains(src, 'cs:RegisterProcessCommandsFunction("SkyRallyAdmin"')
		h.contains(src, "local okChat, reply = pcall(svc.chat, player, message)\n\t\t\t\tif not okChat or reply == nil then\n\t\t\t\t\treturn false")
		h.contains(src, "speaker:SendSystemMessage(reply.text, channelName)")
	end)

	h.test("Garage, solo copy and the status line: the 2x override shows, the cup hold names its fix, status shows once", function()
		-- D2 is covered in the Cash/pass case (getState passes); here the shared list is the only source.
		local econ = h.readFile("src/server/Economy.luau")
		local _, n = string.gsub(econ, "activePassList%(st%)", "")
		h.eq(n, 2, "the HUD attribute and the Garage both read activePassList")
		-- D4: the cup lobby refusal tells him what to flip.
		local td = h.readFile("src/server/TrackDirector.luau")
		local holdAt = string.find(td, 'return false, "the cup lobby holds races, set CUP HOLD off"', 1, true)
		local reqAt = string.find(td, 'TrackDirector.requestRace(player, key, "admin solo", mode)', 1, true)
		h.ok(holdAt ~= nil and reqAt ~= nil and holdAt < reqAt, "the hold check comes before the request")
		h.ok(not string.find(td, 'else "refused"', 1, true), "no bare refused")
		-- D5: the status ask on open updates only the state line.
		local panel = h.readFile("src/client/AdminPanel.luau")
		h.contains(panel, "send(AdminRules.PROBE, true)")
		h.contains(panel, "showReply(r, true)")
		h.contains(panel, "if quiet or (stateText ~= nil and tostring(r.text) == stateText) then")
	end)

	h.test("D22a vehicles switch: default ON for the admin, runtime only, parsed for chat and panel, wired at the ownership check", function()
		h.eq(AdminRules.defaultFlags().vehicles, true, "ON by default (like the portals bypass)")
		h.eq(AdminRules.vehiclesOpen(nil), false, "not admin: off")
		h.eq(AdminRules.vehiclesOpen(AdminRules.defaultFlags()), true)
		h.eq(AdminRules.parse("/admin vehicles off"), { action = "vehicles", on = false })
		h.eq(AdminRules.parse("vehicles on"), { action = "vehicles", on = true })
		h.eq(select(2, AdminRules.parse("/admin vehicles maybe")), "vehicles takes on or off")
		h.contains(AdminRules.HELP, "/admin vehicles on|off")
		h.contains(AdminRules.describe(AdminRules.defaultFlags()), "Vehicles all.")
		local svcSrc = h.readFile("src/server/AdminService.luau")
		h.contains(svcSrc, "AvatarSelect.adminVehicles = svc.vehiclesOpen")
		h.contains(svcSrc, "adminLog(player, \"vehicles\", \"set\", \"on=\" .. tostring(f.vehicles))")
		h.contains(h.readFile("src/client/AdminPanel.luau"), "send(\"/admin vehicles on\")")
		-- The branch sits at the top of the ownership check and never reaches the save.
		local rules = h.readFile("src/shared/AvatarRules.luau")
		local ownsAt = string.find(rules, "function AvatarRules.owns(", 1, true)
		local branchAt = string.find(rules, "if allUnlocked == true then", ownsAt or 1, true)
		local savedAt = string.find(rules, "state.owned[key] == true", ownsAt or 1, true)
		h.ok(ownsAt and branchAt and savedAt and branchAt < savedAt, "allUnlocked first, then the saved set")
		local sel = h.readFile("src/server/AvatarSelect.luau")
		h.ok(not string.find(sel, "save.edit", 1, true) and not string.find(sel, "SaveService.edit", 1, true), "AvatarSelect never writes a profile")
		h.contains(h.readFile("src/server/SaveService.luau"), "storm = false,", "derive still grants no storm row")
	end)
end
