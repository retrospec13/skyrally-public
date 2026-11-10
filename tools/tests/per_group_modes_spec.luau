-- Per-group mode systems (systems audit v32 T0-2, code part; docs/design/PER_GROUP_RACES.md "Per-group readiness").
-- Every mode a group can pick runs with its systems in its own RaceScope scope, so RaceFlowRules.PER_GROUP can turn on
-- without one group's coins, boss hazards, key, battle arena or countdown reaching another. Pinned here with two groups
-- on one server at once (fake scopes 1 and 2, the hub scope 0):
--   - shared/ModeScopeRules: a Slot is one box on the single path and one per scope per group; each() steps every
--     holder inside its own scope and one group's error never stops another's; bind() keeps a scope across a new
--     thread; audience() is "every client" on the single path and the scope's players per group;
--   - the REAL CoinChallenge: two challenges at once, each player collects only his own race's coins, CoinsTotal lands
--     on each race's root, one group's stop leaves the other's coins;
--   - the REAL BossRace and KeyPickup: a start / stop in one scope never touches the other's, each steps in its scope;
--   - the REAL ItemService: a battle arena per scope;
--   - server/RaceGroups: a group's load starts its mode in its scope, its close stops it there first, a battle never
--     joins a race on the same map, a battle restart replays only its own group, Storm Cup v1 stays refused;
--   - the readiness checklist (ModeScopeRules.GROUP_MODES / SYSTEMS) matches RaceInstanceRules.groupModeOk, the
--     source tree and the design doc;
--   - the single path stays a pass-through (PER_GROUP stays false in source).
return function(h)
	local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")
	local RaceScope = h.require("src/shared/RaceScope.luau")
	local RaceAttr = h.require("src/shared/RaceAttr.luau")
	local R = h.require("src/shared/RaceInstanceRules.luau")
	local M = h.require("src/shared/ModeScopeRules.luau")
	local Progression = h.require("src/shared/Progression.luau")
	local ws = h.stubs.workspace
	local Players = h.stubs.Players
	local HttpService = h.stubs.game:GetService("HttpService")
	HttpService.JSONEncode = function(_s: any, v: any): string
		return "#" .. tostring(#v)
	end

	------------------------------------------------------------------------------------------------------------------
	-- Minimal instances (attributes, children, Destroy) and a workspace with RaceInstances roots.
	local function newInst(className: string, name: string): any
		local raw: any = { ClassName = className, Name = name, attrs = {}, children = {}, destroyed = false }
		local inst: any
		local methods: any = {}
		function methods.IsA(_s: any, c: string): boolean
			return c == className or c == "Instance"
		end
		function methods.GetAttribute(_s: any, k: string): any
			return raw.attrs[k]
		end
		function methods.SetAttribute(_s: any, k: string, v: any)
			raw.attrs[k] = v
		end
		function methods.GetAttributeChangedSignal(): any
			return { Connect = function()
				return { Disconnect = function() end }
			end }
		end
		function methods.FindFirstChild(_s: any, n: string): any
			for _, c in raw.children do
				if c.Name == n then
					return c
				end
			end
			return nil
		end
		function methods.GetChildren(): { any }
			return table.clone(raw.children)
		end
		function methods.Destroy(self: any)
			self.Parent = nil
			raw.destroyed = true
		end
		inst = setmetatable({}, {
			__index = function(_t: any, k: string): any
				return methods[k] or raw[k]
			end,
			__newindex = function(_t: any, k: string, v: any)
				if k == "Parent" then
					local old = raw.Parent
					if old then
						local i = table.find(old.children, inst)
						if i then
							table.remove(old.children, i)
						end
					end
					raw.Parent = v
					if v then
						table.insert(v.children, inst)
					end
				else
					raw[k] = v
				end
			end,
		})
		return inst
	end

	local wsKids: { [string]: any } = {}
	ws.FindFirstChild = function(_s: any, n: string): any
		return wsKids[n]
	end
	local serverNow = 5000
	ws.GetServerTimeNow = function(): number
		return serverNow
	end
	local function resetWorld()
		table.clear(wsKids)
		wsKids.RaceInstances = newInst("Folder", "RaceInstances")
		wsKids.Maps = newInst("Folder", "Maps")
		wsKids.Planes = newInst("Folder", "Planes")
		table.clear(ws.attrs)
		table.clear(Players.list)
	end
	resetWorld()

	local function perGroup(fn: () -> ())
		RaceFlowRules.PER_GROUP = true
		local ok, err = pcall(fn)
		RaceFlowRules.PER_GROUP = false
		RaceScope.resetForSpec()
		resetWorld()
		if not ok then
			error(err, 0)
		end
	end

	local function rootFor(id: number, trackId: string): any
		local root = newInst("Folder", tostring(id))
		root.Parent = wsKids.RaceInstances
		RaceScope.open(id, trackId)
		return root
	end

	local function seat(p: any, id: number?)
		p:SetAttribute("RaceInstanceId", id)
	end

	------------------------------------------------------------------------------------------------------------------
	h.test("source: PER_GROUP stays false; ModeScopeRules single path is a pass-through", function()
		h.contains(h.readFile("src/shared/RaceFlowRules.luau"), "RaceFlowRules.PER_GROUP = false\n")
		h.eq(RaceFlowRules.PER_GROUP, false)
		local slot = M.slot("SpecSingle")
		h.eq(slot:get(), nil)
		slot:set("A")
		h.eq(slot:get(), "A")
		local seen = {}
		slot:each(function(v: any, id: number)
			table.insert(seen, tostring(v) .. "@" .. id)
		end)
		h.eq(seen, { "A@0" }, "one value, the hub scope, called once")
		-- No pcall on the single path: a step error surfaces exactly as the old Heartbeat step's did.
		local ok = pcall(function()
			slot:each(function()
				error("boom")
			end)
		end)
		h.eq(ok, false, "the error is not swallowed on the single path")
		local fn = function() end
		h.eq(M.bind(fn), fn, "bind returns fn itself")
		h.eq(M.audience({ 1, 2 }), nil, "every client (FireAllClients)")
		h.eq(M.perGroup(), false)
		h.eq(M.inGroup(), false)
		h.eq(M.runFor(h.fakePlayer(1), function(): number
			return RaceScope.current()
		end), 0)
		slot:set(nil)
		h.eq(slot:any(), false)
		RaceScope.resetForSpec()
	end)

	h.test("two groups: one slot value per scope, each steps in its own scope, errors stay in their group", function()
		perGroup(function()
			rootFor(1, "SNOW-1")
			rootFor(2, "DINO-4")
			local slot = M.slot("SpecTwo")
			RaceScope.run(1, function()
				slot:set("coins@SNOW")
				h.eq(M.inGroup(), true)
			end)
			RaceScope.run(2, function()
				slot:set("battle@DINO")
			end)
			h.eq(slot:get(), nil, "the hub scope holds nothing")
			h.eq(slot:holders(), { 1, 2 })
			local seen = {}
			slot:each(function(v: any, id: number)
				table.insert(seen, string.format("%s in %d (current %d)", tostring(v), id, RaceScope.current()))
				if id == 1 then
					error("group 1 step broke")
				end
			end)
			h.eq(seen, { "coins@SNOW in 1 (current 1)", "battle@DINO in 2 (current 2)" }, "group 2 still stepped")
			h.contains(h.logs, "SpecTwo step error in scope 1")
			-- One group's stop is its own.
			RaceScope.run(1, function()
				slot:set(nil)
			end)
			h.eq(slot:holders(), { 2 })
			-- bind keeps the scope on a new thread (task.delay / task.spawn callbacks).
			local bound = RaceScope.run(2, function()
				return M.bind(function(): number
					return RaceScope.current()
				end)
			end)
			local got = nil
			local co = coroutine.create(function()
				got = bound()
			end)
			coroutine.resume(co)
			h.eq(got, 2, "a delayed callback runs in the scope it was made in")
			-- runFor: the player's own race; audience: the scope's players.
			local a, b, c = h.fakePlayer(11), h.fakePlayer(12), h.fakePlayer(13)
			table.insert(Players.list, a)
			table.insert(Players.list, b)
			table.insert(Players.list, c)
			seat(a, 1)
			seat(b, 2)
			h.eq(M.runFor(b, function(): number
				return RaceScope.current()
			end), 2)
			local function idsOf(list: { any }): { number }
				local out = {}
				for i, p in list do
					out[i] = p.UserId
				end
				return out
			end
			RaceScope.run(1, function()
				h.eq(idsOf(M.audience(Players:GetPlayers()) :: any), { 11 }, "group 1's toast reaches group 1 only")
			end)
			h.eq(idsOf(M.audience(Players:GetPlayers()) :: any), { 13 }, "the hub scope: the plaza only")
			-- A closed instance forgets its box (its owner stopped it first: RaceGroups' stopMode).
			RaceScope.close(2)
			h.eq(slot:holders(), {})
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	-- The REAL CoinChallenge with two challenges at once.
	local CoinChallenge = h.require("src/server/CoinChallenge.luau")

	h.test("CoinChallenge: two groups at once, own coins, own CoinsTotal, one stop leaves the other", function()
		perGroup(function()
			local root1 = rootFor(1, "SNOW-1")
			local root2 = rootFor(2, "DINO-4")
			local p1, p2 = h.fakePlayer(21), h.fakePlayer(22)
			table.insert(Players.list, p1)
			table.insert(Players.list, p2)
			seat(p1, 1)
			seat(p2, 2)
			-- Both hulls sit on coin A1's spot; only group 1 has a coin there.
			local spot = Vector3.new(100, 50, 100)
			local hull1 = { Parent = true, Position = spot }
			local hull2 = { Parent = true, Position = spot }
			local records = { [p1] = { hull = hull1 }, [p2] = { hull = hull2 } }
			local function scoped(): any
				return RaceScope.filter(records)
			end
			local f1, f2 = newInst("Folder", "ChallengeCoins"), newInst("Folder", "ChallengeCoins")
			RaceScope.run(1, function()
				CoinChallenge.arm(f1, { { id = "A1", pos = spot }, { id = "A2", pos = Vector3.new(900, 50, 900) } }, "plane", scoped)
			end)
			RaceScope.run(2, function()
				CoinChallenge.arm(f2, { { id = "B1", pos = Vector3.new(-900, 50, -900) } }, "plane", scoped)
			end)
			h.eq(root1:GetAttribute("CoinsTotal"), 2, "group 1's coin count on its own root")
			h.eq(root2:GetAttribute("CoinsTotal"), 1, "group 2's coin count on its own root")
			h.eq(ws:GetAttribute("CoinsTotal"), nil, "never on workspace per group")
			CoinChallenge.stepAll()
			h.eq(p1:GetAttribute("Coins"), 1, "p1 took A1 in his race")
			h.eq(p2:GetAttribute("Coins"), 0, "p2 at the same spot takes nothing: group 2 has no coin there")
			hull1.Position = Vector3.new(900, 50, 900)
			CoinChallenge.stepAll()
			h.eq(RaceScope.run(1, CoinChallenge.allCollected, p1), true, "group 1 complete for p1")
			h.eq(RaceScope.run(2, CoinChallenge.allCollected, p2), false)
			h.eq(CoinChallenge.isActive(), false, "the hub runs no challenge")
			-- Group 2 stops (its load, replay or close): group 1's coins stay.
			RaceScope.run(2, CoinChallenge.stop)
			h.ok(f2.destroyed, "group 2's coins gone")
			h.ok(not f1.destroyed, "group 1's coins stay")
			h.eq(root1:GetAttribute("CoinsTotal"), 2)
			h.eq(root2:GetAttribute("CoinsTotal"), nil)
			h.eq(RaceScope.run(1, CoinChallenge.isActive), true)
			RaceScope.run(1, CoinChallenge.stop)
		end)
	end)

	h.test("CoinChallenge single path: one challenge, CoinsTotal on workspace, as before", function()
		local p = h.fakePlayer(31)
		local spot = Vector3.new(1, 2, 3)
		local records = { [p] = { hull = { Parent = true, Position = spot } } }
		CoinChallenge.arm(newInst("Folder", "ChallengeCoins"), { { id = "C1", pos = spot } }, "car", function(): any
			return records
		end)
		h.eq(ws:GetAttribute("CoinsTotal"), 1)
		CoinChallenge.stepAll()
		h.eq(CoinChallenge.allCollected(p), true)
		CoinChallenge.stop()
		h.eq(ws:GetAttribute("CoinsTotal"), nil)
		RaceScope.resetForSpec()
	end)

	------------------------------------------------------------------------------------------------------------------
	-- The REAL BossRace and KeyPickup: starts and stops per scope.
	local BossRace = h.require("src/server/BossRace.luau")
	local KeyPickup = h.require("src/server/KeyPickup.luau")

	h.test("BossRace: two boss races at once share the BossHazards folder, each stops only its own", function()
		perGroup(function()
			rootFor(1, "SNOW-1")
			rootFor(2, "DINO-4")
			local shared = newInst("Folder", "BossHazards")
			wsKids.BossHazards = shared
			local stepped: { string } = {}
			local function hooksFor(tag: string): any
				return {
					hit = function() end,
					records = function(): any
						table.insert(stepped, tag .. "@" .. RaceScope.current())
						return {}
					end,
					bossHull = function(): any
						return nil
					end,
					bossStation = function(): any
						return nil
					end,
				}
			end
			RaceScope.run(1, BossRace.start, "SNOW", false, hooksFor("snow"))
			RaceScope.run(2, BossRace.start, "DINO", true, hooksFor("dino"))
			h.eq(RaceScope.run(1, BossRace.isActive), true)
			h.eq(RaceScope.run(2, BossRace.isActive), true)
			h.eq(BossRace.isActive(), false, "the hub runs no boss race")
			BossRace.stepAll(1 / 60)
			h.eq(stepped, { "snow@1", "dino@2" }, "each boss race steps in its own scope")
			RaceScope.run(1, BossRace.stop)
			h.ok(not shared.destroyed, "a group's stop never destroys the shared hazard folder")
			h.eq(RaceScope.run(1, BossRace.isActive), false)
			h.eq(RaceScope.run(2, BossRace.isActive), true, "group 2's hazards keep coming")
			table.clear(stepped)
			BossRace.stepAll(1 / 60)
			h.eq(stepped, { "dino@2" })
			RaceScope.run(2, BossRace.stop)
		end)
	end)

	h.test("KeyPickup: a key check per scope; a group's stop leaves the other group's key", function()
		perGroup(function()
			rootFor(1, "SNOW-1")
			rootFor(2, "DINO-4")
			local function td(id: string): any
				return { id = id, zone = Progression.TRACKS[id].zone, hiddenKey = { pos = Vector3.new(0, 10, 0) } }
			end
			local hooks = {
				records = function(): any
					return {}
				end,
				log = function() end,
			}
			h.ok(RaceScope.run(1, KeyPickup.start, nil, td("SNOW-1"), "race", "plane", hooks) ~= nil, "SNOW key placed in group 1")
			h.ok(RaceScope.run(2, KeyPickup.start, nil, td("DINO-4"), "timetrial", "plane", hooks) ~= nil, "DINO key placed in group 2")
			-- Group 2 replays as a boss race (no key mode): its start stops only its own check.
			h.eq(RaceScope.run(2, KeyPickup.start, nil, td("DINO-4"), "boss", "plane", hooks), nil)
			h.eq(RaceScope.run(1, KeyPickup.isActive), true, "group 1's key is still live")
			h.eq(RaceScope.run(2, KeyPickup.isActive), false)
			RaceScope.run(1, KeyPickup.stop)
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	-- The REAL ItemService: battle arena hooks per scope.
	h.test("ItemService: a battle arena per scope (hits never route to another group's arena bots)", function()
		local ItemService = h.require("src/server/ItemService.luau")
		h.eq(ItemService.arena(), nil)
		local hub = { tag = "hub" }
		ItemService.setArena(hub :: any)
		h.eq(ItemService.arena(), hub, "single path: the one slot")
		perGroup(function()
			ItemService.enableScopes({
				current = RaceScope.current,
				instanceOf = RaceScope.instanceOf,
				run = RaceScope.run,
				state = RaceScope.state,
				filter = RaceScope.filter,
			} :: any, function(): any
				return {}
			end)
			rootFor(1, "SNOW-1")
			rootFor(2, "DINO-4")
			local a1, a2 = { tag = "arena1" }, { tag = "arena2" }
			RaceScope.run(1, ItemService.setArena, a1 :: any)
			RaceScope.run(2, ItemService.setArena, a2 :: any)
			h.eq(RaceScope.run(1, ItemService.arena), a1)
			h.eq(RaceScope.run(2, ItemService.arena), a2)
			h.eq(ItemService.arena(), hub, "the hub scope keeps its own slot")
			RaceScope.run(2, ItemService.setArena, nil)
			h.eq(RaceScope.run(1, ItemService.arena), a1, "group 2's battle end never clears group 1's arena")
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	-- server/RaceGroups: the mode hooks run in the group's scope.
	h.test("RaceGroups: start / stop a group's mode in its scope; one mode per track; battle replays its own group", function()
		local RaceGroups = h.require("src/server/RaceGroups.luau")
		perGroup(function()
			RaceGroups.resetForSpec()
			local calls: { string } = {}
			local sent: { string } = {}
			local delayed: { () -> () } = {}
			local nextId = 0
			local function td(key: string): any
				local map = { snow1 = "SNOW-1", dino4 = "DINO-4", island2 = "ISLAND-2" }
				local id = map[key]
				return if id then { id = id, zone = Progression.TRACKS[id].zone, vehicle = "plane" } else nil
			end
			local function newInstance(key: string, t: any, mode: string, field: number): any
				nextId += 1
				local id = nextId
				local root = newInst("Folder", tostring(id))
				root.Parent = wsKids.RaceInstances
				local inst: any = { rules = R.new(id, key, t.id, t.zone, mode, field), root = root, players = {} }
				function inst.setAttr(_s: any, k: string, v: any)
					root:SetAttribute(k, v)
				end
				function inst.getAttr(_s: any, k: string): any
					return root:GetAttribute(k)
				end
				function inst.transition(_s: any, to: any): boolean
					return R.transition(inst.rules, to)
				end
				function inst.join(_s: any, p: any): boolean
					if not R.join(inst.rules, p.UserId) then
						return false
					end
					inst.players[p] = true
					p:SetAttribute("RaceInstanceId", id)
					return true
				end
				function inst.leave(_s: any, p: any): boolean
					inst.players[p] = nil
					p:SetAttribute("RaceInstanceId", nil)
					return R.leave(inst.rules, p.UserId)
				end
				function inst.close(_s: any)
					root:Destroy()
				end
				return inst
			end
			RaceGroups.init({
				hooks = {
					suspendRace = function() end,
					onTrackChanged = function() end,
					spawnBots = function() end,
					despawnBots = function()
						table.insert(calls, "despawn@" .. RaceScope.current())
					end,
					clearItems = function() end,
					resetRace = function() end,
					allPlayersFinished = function(): boolean
						return false
					end,
					startMode = function(mode: string, _t: any)
						table.insert(calls, "start " .. mode .. "@" .. RaceScope.current())
					end,
					stopMode = function()
						table.insert(calls, "stop@" .. RaceScope.current())
					end,
				},
				loadTrackData = td,
				buildMap = function(): boolean
					return true
				end,
				destroyMap = function() end,
				publishZone = function() end,
				newInstance = newInstance,
				spawn = function() end,
				hubReturn = function() end,
				records = function(): any
					return {}
				end,
				serverNow = function(): number
					return serverNow
				end,
				clock = function(): number
					return serverNow
				end,
				send = function(p: any, event: string)
					table.insert(sent, "U" .. p.UserId .. ":" .. event)
				end,
				delay = function(_s: number, fn: () -> ())
					table.insert(delayed, fn)
				end,
				spawnTask = function(fn: () -> ())
					fn()
				end,
				log = function() end,
				hubTrackId = "HUB-0",
			} :: any)
			local p = {}
			for i = 1, 5 do
				p[i] = h.fakePlayer(40 + i)
				table.insert(Players.list, p[i])
			end
			h.eq(RaceGroups.request({ p[1] }, "snow1", "coin", "portal"), "open")
			h.eq(RaceGroups.request({ p[2] }, "island2", "battle", "board"), "open")
			h.eq(calls, { "start coin@1", "start battle@2" }, "each group's mode starts in its own scope")
			-- One mode per track: a battle never joins the coin grid on SNOW-1; the same mode joins.
			h.eq(RaceGroups.request({ p[3] }, "snow1", "battle", "board"), "busy")
			h.contains(sent, "U43:RaceBusy")
			h.eq(RaceGroups.request({ p[3] }, "snow1", "coin", "board"), "join")
			-- Storm Cup v1 is a whole-server cup: refused per group.
			h.eq(RaceGroups.request({ p[4] }, "dino4", "stormcup", "board"), "refused")
			h.contains(sent, "U44:PortalLocked")
			-- BattleCore's "a player is back" restart (after GO) replays only the battle's own group.
			serverNow += 30
			RaceGroups.step()
			h.eq(RaceGroups.group(2).inst.rules.state, "racing")
			table.clear(calls)
			h.eq(RaceScope.run(2, RaceGroups.replayScope), true)
			h.eq(calls, { "start battle@2" })
			h.eq(RaceGroups.replayScope(), false, "nothing to replay from the hub scope")
			-- The battle's last player leaves: its mode stops in its scope before the scope closes; the coins race on.
			table.clear(calls)
			p[2].Parent = nil
			RaceGroups.onLeave(p[2])
			h.eq(calls, { "stop@2", "despawn@2" }, "the group's systems stop first, in its own scope")
			h.eq(RaceScope.liveIds(), { 1 })
			h.eq(RaceGroups.group(1).inst.rules.mode, "coin", "group 1 untouched")
			RaceGroups.resetForSpec()
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	h.test("readiness checklist: modes, systems, source and the design doc agree", function()
		local modes: { [string]: boolean } = { stormrace = true, stormcup = true, hub = true }
		for _, m in Progression.MODES do
			modes[m] = true
		end
		for m in modes do
			h.eq(M.groupMode(m), R.groupModeOk(m) and m ~= "hub", "GROUP_MODES and groupModeOk agree on " .. m)
			h.ok(M.groupMode(m) or M.GROUP_REFUSED[m] ~= nil, m .. " is a group mode or refused with a reason")
		end
		for _, m in Progression.MODES do
			h.ok(M.groupMode(m), "every board mode runs per group: " .. m)
		end
		h.eq(M.groupMode("stormcup"), false)
		local doc = h.readFile("docs/design/PER_GROUP_RACES.md")
		h.contains(doc, "## Per-group readiness")
		local statuses = { scoped = true, routed = true, hub = true, server = true }
		for _, s in M.SYSTEMS do
			h.ok(statuses[s.status], s.id .. " has a known status")
			h.ok(#h.readFile(s.file) > 0, s.file .. " exists")
			h.contains(doc, "| `" .. s.id .. "` |", "the doc lists " .. s.id)
		end
		-- Every mode system keeps its state in a Slot (no one-per-server `active` left).
		for _, f in { "src/server/CoinChallenge.luau", "src/server/BossRace.luau", "src/server/KeyPickup.luau", "src/server/DuckHunt.luau", "src/server/WorldSetPieces.luau", "src/server/battle/BattleCore.luau" } do
			local src = h.readFile(f)
			h.contains(src, "ModeScopeRules.slot(", f)
			h.ok(not string.find(src, "\nlocal active: ", 1, true), f .. " has no module-level active state")
			h.ok(not string.find(src, "\nlocal armed: ", 1, true), f .. " has no module-level armed state")
		end
		h.contains(h.readFile("src/server/VolcanoVents.luau"), 'RaceScope.state("VolcanoVents"')
		h.contains(h.readFile("src/server/PhotoFinish.luau"), "for _, id in RaceScope.liveIds() do")
		h.contains(h.readFile("src/server/battle/BattleBots.luau"), 'RaceScope.state("BattleBots"')
		local core = h.readFile("src/server/battle/BattleCore.luau")
		h.contains(core, "FlightServer.respawnGuard = scopedRespawnGuard")
		h.contains(core, 'RaceAttr.set("BattleState", "over")')
		h.contains(core, "local to = ModeScopeRules.audience(Players:GetPlayers())")
		h.ok(not string.find(core, 'workspace:SetAttribute("Battle', 1, true), "Battle* attributes go through RaceAttr.set")
		-- Review fix: a player who left a group's battle (or whose group closed after he left its scope) loses BattleOut,
		-- BattleHud and BoundaryReturnClock, or a stale BattleOut keeps his rescue / RESPAWN off on the plaza.
		h.contains(core, "local function releaseLeaver(player: Player?)")
		h.contains(core, 'log("left %s phase=%s", e.name, a.phase)\n\t\t\treleaseLeaver(player)')
		h.contains(core, "for _, e in a.entrants do\n\t\t\treleaseLeaver(e.player)")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "records = scopedRecords,")
		h.contains(init, "trackData = TrackDirector.scopeTrackData,")
		h.contains(init, "RaceGroups.replayScope()")
		local funnels = h.readFile("src/server/Funnels.luau")
		h.contains(funnels, "local present = RaceScope.players(Players:GetPlayers())")
		-- The attributes the mode systems publish are shimmed (the client reads them through RaceAttr).
		for _, n in { "CoinsTotal", "BattleState", "BattleKind", "BattleBoard", "BattleEndsAt", "BattleCenter" } do
			h.ok(R.shimmed(n), n .. " is shimmed")
		end
		h.eq(RaceAttr.get("CoinsTotal", nil), nil)
	end)
end
