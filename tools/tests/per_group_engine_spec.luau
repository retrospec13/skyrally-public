-- Per-group engine (economy v3 phase 2b; docs/design/PER_GROUP_RACES.md "Per-instance engine"): with
-- RaceFlowRules.PER_GROUP true two RaceInstances race on one server at once, each in its own shared/RaceScope.
-- Pinned here, with the real modules wherever Lune can load them:
--   - the single-race path is a pass-through (same tables, workspace attributes, plain calls);
--   - scope state is per instance and follows its thread across a yield;
--   - records, players and race attributes are read per instance (server here/set, client mine/get);
--   - the REAL RaceManager and AIRacers run two fields: finish order, grid reset, RaceResetSeq and bots (field minus that
--     field's humans) never cross;
--   - the REAL ItemService keeps one ledger per instance: the same racer id in two fields holds two different items;
--   - server/RaceGroups: two groups open and race at once, a pick joins a forming grid, a racing track is busy, a leaver
--     frees his seat mid-race, one group returns to the hub while the other keeps racing, the last one out closes it.
return function(h)
	local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")
	local RaceScope = h.require("src/shared/RaceScope.luau")
	local RaceAttr = h.require("src/shared/RaceAttr.luau")
	local R = h.require("src/shared/RaceInstanceRules.luau")
	local ws = h.stubs.workspace
	local Players = h.stubs.Players

	------------------------------------------------------------------------------------------------------------------
	-- Minimal instances: attributes, children, re-parenting, IsA, Destroy.
	local function signal()
		return { Connect = function()
			return { Disconnect = function() end }
		end }
	end
	local function newInst(className: string, name: string, isA: { string }?): any
		local raw: any = { ClassName = className, Name = name, attrs = {}, children = {}, __isInstance = true }
		local classes: { [string]: boolean } = { [className] = true, Instance = true }
		for _, c in isA or {} do
			classes[c] = true
		end
		local inst: any
		local methods: any = {}
		function methods.IsA(_s: any, c: string): boolean
			return classes[c] == true
		end
		function methods.GetAttribute(_s: any, k: string): any
			return raw.attrs[k]
		end
		function methods.SetAttribute(_s: any, k: string, v: any)
			raw.attrs[k] = v
		end
		function methods.GetAttributeChangedSignal(): any
			return signal()
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
				if k == "Position" and raw.CFrame then
					return raw.CFrame.Position
				end
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

	-- workspace.RaceInstances / Maps / Planes on the shared harness workspace.
	local wsKids: { [string]: any } = {}
	ws.FindFirstChild = function(_s: any, n: string): any
		return wsKids[n]
	end
	local serverNow = 1000
	ws.GetServerTimeNow = function(): number
		return serverNow
	end
	local function resetWorld()
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

	local function rootFor(id: number, attrs: { [string]: any }): any
		local root = newInst("Folder", tostring(id))
		for k, v in attrs do
			root:SetAttribute(k, v)
		end
		root.Parent = wsKids.RaceInstances
		return root
	end

	-- Players as UserIds (the harness's deep compare would walk a player's Parent forever).
	local function ids(list: { any }): { number }
		local out = {}
		for i, p in list do
			out[i] = p.UserId
		end
		return out
	end

	local function seat(p: any, id: number?)
		p:SetAttribute("RaceInstanceId", id)
	end

	------------------------------------------------------------------------------------------------------------------
	h.test("single-race path: RaceScope and RaceAttr are pass-throughs (same tables, workspace, plain calls)", function()
		h.eq(RaceFlowRules.PER_GROUP, false)
		local records = { a = 1 }
		h.ok(rawequal(RaceScope.filter(records), records), "filter hands back the same record map")
		local list = { "p" }
		h.ok(rawequal(RaceScope.players(list), list), "players hands back the same list")
		h.eq(RaceScope.current(), 0)
		local s0 = RaceScope.state("Spec", function()
			return {}
		end)
		local inRun = RaceScope.run(7, function()
			return RaceScope.state("Spec", function()
				return {}
			end), RaceScope.current()
		end)
		h.ok(rawequal(s0, inRun), "one state table for the whole server")
		h.eq(select(2, RaceScope.run(7, function()
			return 1, RaceScope.current()
		end)), 0, "run is a plain call")
		ws:SetAttribute("RaceMode", "race")
		ws:SetAttribute("RaceGoTime", 42)
		local p = h.fakePlayer(1)
		seat(p, 3)
		rootFor(3, { RaceMode = "boss" })
		h.eq(RaceAttr.here("RaceMode"), "race")
		h.eq(RaceAttr.get("RaceMode", p), "race", "a seat attribute changes nothing while PER_GROUP is false")
		h.eq(RaceAttr.mine("RaceGoTime"), 42)
		RaceAttr.set("RaceResetSeq", 5)
		h.eq(ws:GetAttribute("RaceResetSeq"), 5, "set writes workspace")
		h.eq(RaceScope.instanceOf(p), 0)
		RaceScope.resetForSpec()
		resetWorld()
	end)

	h.test("two instances: per-instance state, track and close; the scope follows its thread across a yield", function()
		perGroup(function()
			RaceScope.open(1, "SNOW-1")
			RaceScope.open(2, "DINO-4")
			local function fresh()
				return { n = 0 }
			end
			RaceScope.run(1, function()
				RaceScope.state("Spec", fresh).n = 11
				h.eq(RaceScope.track(), "SNOW-1")
			end)
			RaceScope.run(2, function()
				RaceScope.state("Spec", fresh).n = 22
				h.eq(RaceScope.track(), "DINO-4")
				-- nested run, then back
				RaceScope.run(1, function()
					h.eq(RaceScope.state("Spec", fresh).n, 11)
				end)
				h.eq(RaceScope.current(), 2, "the outer scope comes back after a nested run")
			end)
			h.eq(RaceScope.state("Spec", fresh).n, 0, "the hub has its own")
			h.eq(RaceScope.track(), nil, "the hub scope has no instance track")
			-- A load that yields keeps its instance; a run elsewhere meanwhile does not disturb it.
			local seen: { number } = {}
			local co = coroutine.create(function()
				RaceScope.run(1, function()
					table.insert(seen, RaceScope.current())
					coroutine.yield()
					table.insert(seen, RaceScope.current())
					table.insert(seen, RaceScope.state("Spec", fresh).n)
				end)
			end)
			coroutine.resume(co)
			RaceScope.run(2, function()
				h.eq(RaceScope.current(), 2)
			end)
			h.eq(RaceScope.current(), 0, "the main thread never entered instance 1")
			coroutine.resume(co)
			h.eq(seen, { 1, 1, 11 })
			-- An error inside a run restores the scope and rethrows.
			local ok = pcall(RaceScope.run, 2, function()
				error("boom")
			end)
			h.ok(not ok)
			h.eq(RaceScope.current(), 0)
			h.eq(RaceScope.liveIds(), { 1, 2 })
			RaceScope.close(1)
			h.eq(RaceScope.liveIds(), { 2 })
			RaceScope.run(1, function()
				h.eq(RaceScope.state("Spec", fresh).n, 0, "a closed instance's state is gone")
			end)
		end)
	end)

	h.test("records, players and race attributes per instance (server here/set; client get/mine)", function()
		perGroup(function()
			RaceScope.open(1, "SNOW-1")
			RaceScope.open(2, "DINO-4")
			local a, b, c = h.fakePlayer(11), h.fakePlayer(12), h.fakePlayer(13)
			seat(a, 1)
			seat(b, 2)
			Players.list = { a, b, c }
			local records = { [a] = "ra", [b] = "rb", [c] = "rc" }
			local r1 = RaceScope.run(1, RaceScope.filter, records)
			local function only(map: { [any]: string }): string
				local out = {}
				for _, v in map do
					table.insert(out, v)
				end
				table.sort(out)
				return table.concat(out, ",")
			end
			h.eq(only(r1), "ra")
			h.eq(only(RaceScope.run(2, RaceScope.filter, records)), "rb")
			h.eq(only(RaceScope.filter(records)), "rc", "the hub scope: players in no race")
			h.eq(ids(RaceScope.run(1, RaceScope.players, Players:GetPlayers())), { 11 })
			ws:SetAttribute("RaceMode", "hub")
			ws:SetAttribute("TrackSwitching", false)
			local root1 = rootFor(1, { RaceMode = "race", RaceGoTime = 1010, ActiveTrackId = "SNOW-1" })
			local root2 = rootFor(2, { RaceMode = "boss", ActiveTrackId = "DINO-4" })
			h.eq(RaceAttr.get("RaceMode", a), "race")
			h.eq(RaceAttr.get("RaceMode", b), "boss")
			h.eq(RaceAttr.get("RaceMode", c), "hub", "no seat: the hub's workspace value")
			h.eq(RaceAttr.get("RaceGoTime", b), nil, "never another race's value through workspace")
			h.eq(RaceAttr.get("TrackSwitching", a), false, "server-wide flags stay on workspace")
			h.eq(RaceScope.run(1, RaceAttr.here, "RaceGoTime"), 1010)
			h.eq(RaceScope.run(2, RaceAttr.here, "RaceMode"), "boss")
			h.eq(RaceAttr.here("RaceMode"), "hub")
			RaceScope.run(1, RaceAttr.set, "RaceResetSeq", 3)
			RaceScope.run(2, RaceAttr.set, "TotalRacers", 8)
			RaceScope.run(2, RaceAttr.set, "TriggerRaceReset", true)
			h.eq(root1:GetAttribute("RaceResetSeq"), 3)
			h.eq(root2:GetAttribute("TotalRacers"), 8)
			h.eq(ws:GetAttribute("RaceResetSeq"), nil, "an instance never writes the hub's workspace race attributes")
			h.eq(ws:GetAttribute("TriggerRaceReset"), true, "unshimmed names still go to workspace")
			-- Client: the local player's race; the map he races on.
			Players.LocalPlayer = b
			local map = newInst("Model", "DINO-4")
			map.Parent = wsKids.Maps
			h.eq(RaceAttr.mine("RaceMode"), "boss")
			h.ok(RaceAttr.myMapRoot() == map)
			Players.LocalPlayer = c
			h.eq(RaceAttr.mine("RaceMode"), "hub")
			Players.LocalPlayer = nil
		end)
	end)

	h.test("RaceAttr pre-enable: one cached getter per root; changed() keeps the Connected / :Disconnect() contract", function()
		perGroup(function()
			local a = h.fakePlayer(21)
			seat(a, 1)
			local root = rootFor(1, { RaceMode = "race" })
			local before = RaceAttr.cachedGetters()
			for _ = 1, 50 do
				h.eq(RaceAttr.get("RaceMode", a), "race")
			end
			h.eq(RaceAttr.cachedGetters(), before + 1, "50 reads of one root: one getter, made once")
			h.eq(RaceScope.run(1, RaceAttr.here, "RaceMode"), "race", "here() reuses it")
			h.eq(RaceAttr.cachedGetters(), before + 1)
			root:SetAttribute("RaceMode", "boss")
			h.eq(RaceAttr.get("RaceMode", a), "boss", "the cached getter reads the live value")
			-- changed(): the RBXScriptConnection surface (Connected, :Disconnect()), idempotent.
			Players.LocalPlayer = a
			local conn = RaceAttr.changed("RaceMode", function() end)
			h.eq(conn.Connected, true)
			conn:Disconnect()
			h.eq(conn.Connected, false)
			conn:Disconnect() -- a second Disconnect is a no-op, as on a real connection
			h.eq(conn.Connected, false)
			Players.LocalPlayer = nil
		end)
		local conn = RaceAttr.changed("RaceMode", function() end)
		h.ok(type(conn.Disconnect) == "function", "single path: the signal's own connection")
		local src = h.readFile("src/shared/RaceAttr.luau")
		h.contains(src, "if root then rootGetter(root) else nil", "readFrom allocates no closure per call")
		h.contains(src, 'setmetatable({ r = root }, { __mode = "v" })', "a cached getter never pins its own (weak) key")
		h.ok(not string.find(src, "\t\t\treturn root:GetAttribute(n)", 1, true), "no getter captures its root strongly")
		h.contains(src, "if not handle.Connected or folderConn or rootConn then", "no wiring after a Disconnect during WaitForChild")
		h.contains(src, "export type Conn = { Connected: boolean, Disconnect: (Conn) -> () }")
		h.contains(src, "function RaceAttr.wait(name: string): any")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- The REAL RaceManager and AIRacers over fake vehicles.
	local spawned: { [any]: number } = {}
	local FakeFlightServer: any = { records = {} }
	function FakeFlightServer.getStartCFrame(slot: number): any
		return CFrame.new(slot * 10, 100, 0)
	end
	function FakeFlightServer.spawnOrResetPlane(player: any, slot: number): any
		spawned[player] = (spawned[player] or 0) + 1
		local hull = newInst("Part", "Hull", { "BasePart" })
		hull.CFrame = CFrame.new(slot * 10, 100, 0)
		local plane = newInst("Model", "Plane_" .. player.Name)
		hull.Parent = plane
		local rec = {
			player = player,
			plane = plane,
			hull = hull,
			lap = 1,
			station = 0,
			finished = false,
			finishTime = 0,
			finishRank = 0,
			orbs = 0,
			passedCheckpoints = {},
			lastCheckpointIdx = 1,
			lastCheckpointCF = CFrame.new(),
			speed = 110,
		}
		FakeFlightServer.records[player] = rec
		return rec
	end
	function FakeFlightServer.stepGuide() end
	function FakeFlightServer.guideNewLap() end
	function FakeFlightServer.courseFix(): (number, boolean)
		return 0, false
	end
	h.fake("src/server/FlightServer.luau", FakeFlightServer)
	h.fake("src/server/CarServer.luau", { activeVehicle = function(): string
		return "plane"
	end })
	h.fake("src/server/PlaneBuilder.luau", {
		createPlane = function(name: string, _c: any, _a: any, cf: any, _ai: boolean): any
			local model = newInst("Model", name)
			local hull = newInst("Part", "Hull", { "BasePart" })
			hull.CFrame = cf
			hull.Parent = model
			model.PrimaryPart = hull
			return model
		end,
	})
	h.fake("src/server/kit/CarBuilder.luau", {})
	h.fake("src/server/kit/RacerPaint.luau", { paintBot = function() end })
	local dealt = 0
	h.fake("src/server/kit/BotDisguise.luau", {
		deal = function(): (string, any, boolean)
			dealt += 1
			return "Racer" .. dealt, nil, true
		end,
		setNames = function() end,
		setLook = function() end,
		recheck = function() end,
	})

	h.test("RaceManager + AIRacers: two fields keep their own grid, bots, finish order and RaceResetSeq", function()
		perGroup(function()
			local AIRacers = h.require("src/server/AIRacers.luau")
			local RaceManager = h.require("src/server/RaceManager.luau")
			RaceScope.open(1, "SNOW-1")
			RaceScope.open(2, "DINO-4")
			local root1 = rootFor(1, { RaceMode = "race", ActiveTrackId = "SNOW-1" })
			local root2 = rootFor(2, { RaceMode = "race", ActiveTrackId = "DINO-4" })
			ws:SetAttribute("RaceMode", "hub")
			local p: { any } = {}
			for i = 1, 5 do
				p[i] = h.fakePlayer(100 + i, "P" .. i)
			end
			seat(p[1], 1)
			seat(p[2], 1)
			seat(p[3], 1)
			seat(p[4], 2)
			Players.list = table.clone(p) -- p[5] drives the hub
			for _, pl in p do
				FakeFlightServer.spawnOrResetPlane(pl, 1)
			end
			table.clear(spawned)
			RaceScope.run(1, RaceManager.resetRaceForAll, serverNow + 5)
			RaceScope.run(2, RaceManager.resetRaceForAll, serverNow + 5)
			h.eq(spawned[p[1]], 1)
			h.eq(spawned[p[4]], 1)
			h.eq(spawned[p[5]], nil, "the hub player is never seated on a grid")
			h.eq(RaceScope.run(1, function()
				return #AIRacers.bots
			end), 5, "3 humans in field 1: 5 bots")
			h.eq(RaceScope.run(2, function()
				return #AIRacers.bots
			end), 7, "1 human in field 2: 7 bots (the server's 5 players never count)")
			h.eq(#AIRacers.bots, 0, "the hub scope has no field")
			h.eq(root1:GetAttribute("RaceResetSeq"), 1)
			h.eq(root2:GetAttribute("RaceResetSeq"), 1)
			h.eq(ws:GetAttribute("RaceResetSeq"), nil)
			h.eq(root1:GetAttribute("RaceGoTime"), serverNow + 5)
			h.eq(p[1]:GetAttribute("GridField"), 8)
			-- The standings each field sees: its humans and its bots, 8 each.
			h.eq(#RaceScope.run(1, RaceManager.racerOrder), 8)
			h.eq(#RaceScope.run(2, RaceManager.racerOrder), 8)
			-- A finish in field 1 is rank 1 there and nowhere else.
			RaceScope.run(1, function()
				local rec = FakeFlightServer.records[p[2]]
				rec.lap = 3
				RaceManager.raceStartClock = os.clock() - 95
				RaceManager.completePlayerLap(rec, os.clock(), 1000)
			end)
			h.eq(FakeFlightServer.records[p[2]].finishRank, 1)
			h.eq(RaceScope.run(1, function()
				return #RaceManager.finishOrder
			end), 1)
			h.eq(RaceScope.run(2, function()
				return #RaceManager.finishOrder
			end), 0, "field 2's finish order is untouched")
			h.ok(RaceScope.run(2, function()
				return not RaceManager.allPlayersFinished()
			end), "field 2 is still racing")
			-- A second reset of field 2 (FLY AGAIN there) leaves field 1's race alone.
			RaceScope.run(2, RaceManager.resetRaceForAll, serverNow + 5)
			h.eq(root2:GetAttribute("RaceResetSeq"), 2)
			h.eq(root1:GetAttribute("RaceResetSeq"), 1)
			h.eq(FakeFlightServer.records[p[2]].finished, true, "field 1's finisher keeps his finish")
			-- Leave and join while field 1's grid is open: the leaver's seat gets a bot, a joiner's seat costs one; field
			-- 2 never moves.
			Players.list = { p[1], p[2], p[4], p[5] } -- p[3] left the server
			RaceScope.run(1, AIRacers.refreshField, "leave", p[3])
			h.eq(RaceScope.run(1, function()
				return #AIRacers.bots
			end), 6, "2 humans left in field 1: 6 bots")
			seat(p[5], 1)
			RaceScope.run(1, AIRacers.refreshField, "join", nil)
			h.eq(RaceScope.run(1, function()
				return #AIRacers.bots
			end), 5, "the joiner takes a bot's seat")
			h.eq(RaceScope.run(2, function()
				return #AIRacers.bots
			end), 7)
			-- Bots of one field go without touching the other.
			RaceScope.run(1, AIRacers.despawnAll)
			h.eq(RaceScope.run(1, function()
				return #AIRacers.bots
			end), 0)
			h.eq(RaceScope.run(2, function()
				return #AIRacers.bots
			end), 7)
			table.clear(FakeFlightServer.records)
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	h.test("ItemService: one ledger per instance; the same racer ids in two fields never share an item", function()
		perGroup(function()
			local ItemService = h.require("src/server/ItemService.luau")
			RaceScope.open(1, "SNOW-1")
			RaceScope.open(2, "DINO-4")
			local t = 100
			local published: { string } = {}
			local world = {
				now = function(): number
					return t
				end,
				racerPosition = function(_id: string): any
					return Vector3.new(0, 0, 0)
				end,
				findPod = function(name: string): any
					return { position = Vector3.new(0, 0, 0), podType = if name == "RedPod" then "Red" else "Blue", respawnSeconds = 4 }
				end,
				publish = function(id: string, state: any)
					table.insert(published, string.format("%d:%s=%s", RaceScope.current(), id, tostring(state.color)))
				end,
				log = function() end,
			}
			local hooks = ItemService.loggingHooks(function() end)
			local base = ItemService.new(world, hooks)
			rawset(ItemService, "active", base)
			ItemService.world = world
			local api = {
				current = RaceScope.current,
				instanceOf = RaceScope.instanceOf,
				run = RaceScope.run,
				state = RaceScope.state,
				filter = RaceScope.filter,
			}
			ItemService.enableScopes(api, function(): any
				return hooks
			end)
			h.ok(ItemService.active == base, "the hub scope keeps the started service")
			local s1 = RaceScope.run(1, function()
				return ItemService.active
			end)
			local s2 = RaceScope.run(2, function()
				return ItemService.active
			end)
			h.ok(s1 ~= nil and s2 ~= nil and s1 ~= s2 and s1 ~= base, "one service per instance")
			h.ok(RaceScope.run(1, function()
				return ItemService.active
			end) == s1, "made once, then kept")
			h.ok(RaceScope.run(1, ItemService.pickup, "bot:1", "RedPod"))
			h.ok(RaceScope.run(2, ItemService.pickup, "bot:1", "BluePod"))
			h.eq(RaceScope.run(1, ItemService.getState, "bot:1").color, "red")
			h.eq(RaceScope.run(2, ItemService.getState, "bot:1").color, "blue", "bot 1 of field 2 is another racer")
			h.eq(ItemService.getState("bot:1").color, nil, "the hub holds nothing")
			-- A reset of one field (its grid) clears only its ledger.
			RaceScope.run(1, ItemService.reset)
			h.eq(RaceScope.run(1, ItemService.getState, "bot:1").color, nil)
			h.eq(RaceScope.run(2, ItemService.getState, "bot:1").color, "blue")
			-- A player's "Use" goes to the service of the instance he is seated in.
			local p = h.fakePlayer(77)
			seat(p, 2)
			RaceScope.run(2, ItemService.pickup, "player:77", "RedPod")
			t += 5
			local route = ItemService.routeRemote
			h.ok(route ~= nil)
			if route then
				route(p, "Use")
			end
			h.eq(RaceScope.run(2, ItemService.getState, "player:77").color, nil, "used in field 2")
			h.contains(published, "2:player:77=red")
			setmetatable(ItemService, nil)
			rawset(ItemService, "active", nil)
			ItemService.routeRemote = nil
			ItemService.routeRemoving = nil
			ItemService.recordFilter = nil
			ItemService.world = nil
		end)
	end)

	------------------------------------------------------------------------------------------------------------------
	-- server/RaceGroups over fake deps: the per-group director end to end.
	h.test("RaceGroups: two groups at once; join a forming grid; busy while racing; leave mid-race; one returns", function()
		perGroup(function()
			local RaceGroups = h.require("src/server/RaceGroups.luau")
			RaceGroups.resetForSpec()
			local clock = 0
			local nextId = 0
			local records: { [any]: any } = {}
			local sent: { string } = {}
			local delayed: { () -> () } = {}
			local returned: { { players: { any }, zone: string? } } = {}
			local destroyed: { string } = {}
			local resets: { string } = {}
			local seated: { [any]: number } = {}
			local refreshed: { string } = {}
			local dropped: { string } = {}
			local despawned: { string } = {}
			local duringBuild: (() -> ())? = nil
			local function newInstance(key: string, td: any, mode: string, field: number): any
				nextId += 1
				local rules = R.new(nextId, key, td.id, td.zone, mode, field)
				local root = rootFor(nextId, {})
				local inst: any = { rules = rules, root = root, players = {} }
				function inst.setAttr(self: any, name: string, value: any)
					self.rules.attrs[name] = value
					self.root:SetAttribute(name, value)
				end
				function inst.getAttr(self: any, name: string): any
					return self.root:GetAttribute(name)
				end
				function inst.transition(self: any, to: any): boolean
					local ok = R.transition(self.rules, to)
					if ok then
						self.root:SetAttribute("State", to)
						if to == "grid" then
							self:setAttr("RaceResetSeq", self.rules.seq)
						end
					end
					return ok
				end
				function inst.join(self: any, player: any): boolean
					if not R.join(self.rules, player.UserId) then
						return false
					end
					self.players[player] = true
					player:SetAttribute("RaceInstanceId", self.rules.id)
					return true
				end
				function inst.leave(self: any, player: any): boolean
					if not R.leave(self.rules, player.UserId) then
						return false
					end
					self.players[player] = nil
					player:SetAttribute("RaceInstanceId", nil)
					return true
				end
				function inst.close(self: any)
					for pl in self.players do
						self:leave(pl)
					end
					R.transition(self.rules, "closed")
					self.root:Destroy()
				end
				inst:setAttr("RaceMode", mode)
				inst:setAttr("ActiveTrackId", td.id)
				return inst
			end
			local TD = {
				snow1 = { id = "SNOW-1", zone = "SNOW" },
				dino4 = { id = "DINO-4", zone = "DINO" },
				hub0 = { id = "HUB-0", zone = "HUB" },
			}
			RaceGroups.init({
				hooks = {
					suspendRace = function() end,
					onTrackChanged = function() end,
					spawnBots = function() end,
					despawnBots = function()
						table.insert(despawned, tostring(RaceScope.current()))
					end,
					clearItems = function() end,
					resetRace = function(_goTime: number?)
						-- Like RaceManager.resetRaceForAll: only this scope's players are seated.
						for pl in RaceScope.filter(records) do
							seated[pl] = RaceScope.current()
						end
						table.insert(resets, tostring(RaceScope.current()))
					end,
					allPlayersFinished = function(): boolean
						local any = false
						for pl, rec in RaceScope.filter(records) do
							if pl.Parent then
								any = true
								if not rec.finished then
									return false
								end
							end
						end
						return any
					end,
					startMode = function() end,
					fieldDone = function(): boolean
						return false
					end,
					refreshField = function(reason: string, _leaving: any)
						table.insert(refreshed, reason .. "@" .. RaceScope.current())
					end,
					dropRacer = function(pl: any)
						table.insert(dropped, pl.Name .. "@" .. RaceScope.current())
					end,
				},
				loadTrackData = function(key: string): any
					return TD[key]
				end,
				buildMap = function(_key: string, td: any): boolean
					h.eq(RaceScope.track(), td.id, "a group's map builds inside its own scope")
					local during = duringBuild
					if during then
						duringBuild = nil
						during() -- what happens on the server while the build yields
					end
					return true
				end,
				destroyMap = function(trackId: string)
					table.insert(destroyed, trackId)
				end,
				publishZone = function() end,
				newInstance = newInstance,
				spawn = function(pl: any, _slot: number)
					seated[pl] = RaceScope.current()
				end,
				hubReturn = function(list: { any }, zone: string?)
					table.insert(returned, { players = list, zone = zone })
				end,
				records = function(): any
					return records
				end,
				serverNow = function(): number
					return serverNow
				end,
				clock = function(): number
					return clock
				end,
				send = function(pl: any, event: string, _data: any)
					table.insert(sent, pl.Name .. ":" .. event)
				end,
				delay = function(_s: number, fn: () -> ())
					table.insert(delayed, fn)
				end,
				spawnTask = function(fn: () -> ())
					fn()
				end,
				log = function() end,
				hubTrackId = "HUB-0",
			})
			local p: { any } = {}
			for i = 1, 5 do
				p[i] = h.fakePlayer(200 + i, "G" .. i)
				records[p[i]] = { finished = false }
			end
			Players.list = table.clone(p)
			ws:SetAttribute("RaceMode", "hub")

			-- Two groups open at once.
			h.eq(RaceGroups.request({ p[1] }, "snow1", "race", "portal"), "open")
			h.eq(RaceGroups.request({ p[3] }, "dino4", "race", "board"), "open")
			h.eq(RaceScope.liveIds(), { 1, 2 })
			h.eq(seated[p[1]], 1)
			h.eq(seated[p[3]], 2)
			h.eq(seated[p[5]], nil, "the hub player stays on the plaza")
			h.eq(RaceAttr.get("RaceMode", p[1]), "race")
			h.eq(RaceAttr.get("ActiveTrackId", p[3]), "DINO-4")
			h.eq(RaceAttr.get("RaceMode", p[5]), "hub")
			h.eq(RaceGroups.group(1).inst.rules.state, "grid")
			-- A pick of a track whose grid is still forming joins it (his own choice); seated at once.
			h.eq(RaceGroups.request({ p[2] }, "snow1", "race", "portal"), "join")
			h.eq(seated[p[2]], 1)
			h.eq(RaceGroups.group(1).inst.rules.count, 2)
			-- GO for both; a pick of a racing track is busy and moves nobody.
			serverNow += 20
			RaceGroups.step()
			h.eq(RaceGroups.group(1).inst.rules.state, "racing")
			h.eq(RaceGroups.group(2).inst.rules.state, "racing")
			-- Phase 3: each track's race as the portal queue reads it (arch label, start rule).
			local tr = RaceGroups.trackRaces()
			h.eq(tr["SNOW-1"].state, "racing")
			h.eq(tr["SNOW-1"].goAt, RaceGroups.group(1).goTime)
			h.eq(tr["SNOW-1"].endAt, nil, "no results yet")
			h.eq(tr["DINO-4"].state, "racing")
			h.eq(tr["FOREST-1"], nil, "no race on that track")
			h.eq(RaceGroups.request({ p[4] }, "snow1", "race", "portal"), "busy")
			h.contains(sent, "G4:RaceBusy")
			h.eq(RaceScope.instanceOf(p[4]), 0)
			-- Battles run per group now (systems audit v32 T0-2), but never on a map another mode races on (one mode per track).
			h.eq(RaceGroups.request({ p[4] }, "snow1", "battle", "board"), "busy", "a battle never joins a race on the same map")
			-- A leaver mid-race frees his seat; the race goes on.
			p[2].Parent = nil
			RaceGroups.onLeave(p[2])
			h.eq(RaceGroups.group(1).inst.rules.count, 1)
			h.eq(RaceScope.liveIds(), { 1, 2 })
			h.eq(dropped, { "G2@1" }, "his item ledger entry goes in his own instance")
			for _, fn in delayed do
				fn()
			end
			table.clear(delayed)
			h.contains(refreshed, "leave@1", "his field refreshes in his own instance, after he is gone")
			-- Group 1 finishes: its return timer and DNF line are its own; group 2 sees none of it.
			records[p[1]].finished = true
			clock += 1
			RaceGroups.step()
			local root1 = wsKids.RaceInstances:FindFirstChild("1")
			local root2 = wsKids.RaceInstances:FindFirstChild("2")
			h.ok(type(root1:GetAttribute("ReturnToHubAt")) == "number", "group 1 return timer")
			h.eq(root2:GetAttribute("ReturnToHubAt"), nil, "group 2 keeps racing")
			h.eq(ws:GetAttribute("ReturnToHubAt"), nil, "nothing server-wide")
			h.eq(RaceGroups.group(1).inst.rules.state, "results")
			h.eq(RaceGroups.trackRaces()["SNOW-1"].endAt, root1:GetAttribute("ReturnToHubAt"), "results: the real return time")
			-- FLY AGAIN (solo): a fresh grid in group 1 only.
			h.eq(RaceGroups.requestExit(p[1], "again"), "done")
			h.eq(RaceGroups.group(1).inst.rules.state, "grid")
			h.eq(root1:GetAttribute("RaceResetSeq"), 2)
			h.eq(root2:GetAttribute("RaceResetSeq"), 1)
			-- HUB (solo): group 1 returns; group 2 races on.
			clock += 2
			h.eq(RaceGroups.requestExit(p[1], "hub"), "done")
			h.eq(RaceScope.instanceOf(p[1]), 0, "seat given up first: his client shows the hub again")
			h.eq(RaceScope.liveIds(), { 2 })
			h.eq(destroyed, { "SNOW-1" })
			h.eq(#returned, 0, "the plaza respawn waits RETURN_UNHIDE")
			for _, fn in delayed do
				fn()
			end
			table.clear(delayed)
			h.eq(#returned, 1)
			h.eq(ids(returned[1].players), { p[1].UserId })
			h.eq(returned[1].zone, "SNOW", "back at the arch of the zone he left")
			h.eq(RaceAttr.get("RaceMode", p[1]), "hub")
			h.eq(RaceAttr.get("RaceMode", p[3]), "race")
			h.eq(RaceGroups.group(2).inst.rules.state, "racing")
			-- SNOW-1 is free again: a new group opens there while DINO-4 still races.
			h.eq(RaceGroups.request({ p[4] }, "snow1", "race", "portal"), "open")
			h.eq(RaceScope.liveIds(), { 2, 3 })
			-- The last one out of group 2 closes it (bots, items, map).
			p[3].Parent = nil
			RaceGroups.onLeave(p[3])
			h.eq(RaceScope.liveIds(), { 3 })
			h.eq(destroyed, { "SNOW-1", "DINO-4" })
			h.eq(wsKids.RaceInstances:FindFirstChild("2"), nil)
			-- Review fixes: a seated player's request moves nobody; a Storm Cup v1 pick is refused per group (the cup takes the
			-- whole server; coin challenges and battles run per group since systems audit v32 T0-2).
			table.clear(sent)
			h.eq(RaceGroups.request({ p[4] }, "dino4", "race", "board"), "refused", "p4 already races SNOW-1")
			h.eq(RaceScope.instanceOf(p[4]), 3)
			h.eq(RaceGroups.request({ p[5] }, "dino4", "stormcup", "board"), "refused", "Storm Cup v1 is never per group")
			h.contains(sent, "G5:PortalLocked")
			h.eq(RaceScope.liveIds(), { 3 })
			-- The last player leaves while his map builds: what the load made after closeGroup is taken back too.
			table.clear(despawned)
			duringBuild = function()
				p[5].Parent = nil
				RaceGroups.onLeave(p[5])
			end
			h.eq(RaceGroups.request({ p[5] }, "dino4", "race", "board"), "open")
			h.eq(RaceScope.liveIds(), { 3 }, "the abandoned instance is not stepped")
			h.eq(RaceGroups.group(4), nil)
			h.eq(destroyed, { "SNOW-1", "DINO-4", "DINO-4", "DINO-4" }, "its map goes (closeGroup, then the load's clean-up)")
			h.contains(despawned, "4", "its bots go, in its own scope")
			h.eq(resets, { "1", "2", "1", "3" }, "no grid is formed for it")
			RaceGroups.resetForSpec()
		end)
	end)

	h.test("client map visibility: own race map, else the hub; the hub stays while his map loads", function()
		local ids = { "HUB-0", "SNOW-1", "DINO-4" }
		h.eq(R.visibleMaps(false, "SNOW-1", "HUB-0", ids), { ["HUB-0"] = true, ["SNOW-1"] = true, ["DINO-4"] = true }, "single race: nothing hidden")
		h.eq(R.visibleMaps(true, "HUB-0", "HUB-0", ids), { ["HUB-0"] = true }, "in the hub: other groups' maps hidden")
		h.eq(R.visibleMaps(true, "SNOW-1", "HUB-0", ids), { ["SNOW-1"] = true }, "racing: only his map")
		h.eq(R.visibleMaps(true, "SNOW-1", "HUB-0", ids, true), { ["HUB-0"] = true, ["SNOW-1"] = true }, "loading: the hub stays")
		h.eq(R.visibleMaps(true, "SPACE-4", "HUB-0", ids), { ["HUB-0"] = true }, "his map not replicated yet: the hub stays")
		h.ok(R.RETURN_UNHIDE > 0)
	end)

	h.test("admit: open a free track, join a forming grid with a seat, busy while racing or full", function()
		local live = {
			{ trackId = "SNOW-1", state = "grid", count = 3, field = 8 },
			{ trackId = "DINO-4", state = "racing", count = 1, field = 8 },
			{ trackId = "SPACE-4", state = "loading", count = 8, field = 8 },
		}
		h.eq(R.admit(live, "FOREST-1"), "open")
		h.eq(R.admit(live, "SNOW-1"), "join")
		h.eq(R.admit(live, "DINO-4"), "busy")
		h.eq(R.admit(live, "SPACE-4"), "busy", "a full field")
		h.eq(R.admit({ { trackId = "SNOW-1", state = "closed", count = 0, field = 8 } }, "SNOW-1"), "open")
		-- Modes a group may race alone (review fix): the one-per-server mode systems refuse battle, Storm Cup and coins.
		h.eq(R.groupModeOk("race"), true)
		h.eq(R.groupModeOk("quickrace"), true)
		h.eq(R.groupModeOk("boss"), true)
		-- Systems audit v32 T0-2: the mode systems are per scope, so coin challenges and battles run per group too.
		h.eq(R.groupModeOk("coin"), true)
		h.eq(R.groupModeOk("battle"), true)
		h.eq(R.groupModeOk("stormcup"), false)
	end)

	h.test("source guards: the single-race path is gated, the client reads its own race, scanners scope to its map", function()
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "if not RaceFlowRules.PER_GROUP then\n\t\t\tstepRace(dt)\n\t\t\treturn")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "if RaceFlowRules.PER_GROUP then\n\t\tinitGroups(h)")
		h.contains(td, "return RaceGroups.request({ player }, key, m, reason)")
		h.contains(td, "remote:FireClient(player, \"PortalWarp\", warpData)")
		h.contains(td, "elseif ok and group and not RaceFlowRules.PER_GROUP then")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "if PerGroupFlow.PER_GROUP then\n\tlocal RaceGroups = require(script.RaceGroups)")
		for _, f in { "RaceUI", "TrackFlow", "Minimap", "Onboarding", "FinishShow", "WorldAnim", "LightLod", "MapFxLod", "PortalPlunge" } do
			local src = h.readFile("src/client/" .. f .. ".luau")
			h.contains(src, "RaceAttr", f .. " reads its race through RaceAttr")
			for _, name in { "RaceMode", "ActiveTrackId", "RaceGoTime", "RaceResetSeq", "TotalLaps", "ReturnToHubAt", "TotalRacers", "VoteHumans" } do
				h.ok(not string.find(src, 'workspace:GetAttribute("' .. name .. '")', 1, true), f .. " no workspace " .. name)
				h.ok(not string.find(src, 'workspace:GetAttributeChangedSignal("' .. name .. '")', 1, true), f .. " no workspace signal " .. name)
			end
		end
		h.contains(h.readFile("src/client/Onboarding.luau"), 'maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))')
		local zv = h.readFile("src/client/ZoneVisibility.luau")
		h.contains(zv, "if not RaceFlowRules.PER_GROUP then\n\t\treturn")
		h.ok(not string.find(zv, "Transparency", 1, true) and not string.find(zv, "CanCollide", 1, true), "hides by parent only")
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "ZoneVisibility" }')
		-- Review fixes: a group's load never touches the one-per-server mode systems; the busy answer reaches the asker;
		-- the grid hold and the HUD phase read the player's own race (pass-through to workspace when PER_GROUP is off).
		-- Systems audit v32 T0-2: a group's load starts its own scope's mode systems; its close stops them first.
		h.contains(td, "startMode = h.startMode,")
		h.contains(td, 'h.startMode("hub", nil) -- every system\'s stop, in this scope')
		local tf = h.readFile("src/client/TrackFlow.luau")
		h.contains(tf, 'event == "RaceBusy"')
		h.contains(tf, 'NotifyKit.fromSpec("portal_busy"')
		local hp = h.readFile("src/client/HudPhase.luau")
		h.contains(hp, 'local goAt = RaceAttr.mine("RaceGoTime")')
		h.ok(not string.find(hp, 'workspace:GetAttribute("RaceMode")', 1, true), "HudPhase no workspace RaceMode")
		h.contains(h.readFile("src/client/FlightController.luau"), 'local goTime = RaceAttr.mine("RaceGoTime")\n\tif battleOutHoldCF or switchHoldCF')
		h.contains(h.readFile("src/client/CarController.luau"), 'local goTime = RaceAttr.mine("RaceGoTime")\n\tlocal switching = workspace:GetAttribute("TrackSwitching") == true')
		-- The streaming trial is written down, StreamingEnabled is not turned on.
		h.contains(h.readFile("docs/design/PER_GROUP_RACES.md"), "## Streaming trial (steps)")
		h.ok(not string.find(h.readFile("default.project.json"), '"StreamingEnabled": true', 1, true), "StreamingEnabled stays off")
	end)
end
