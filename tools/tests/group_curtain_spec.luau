-- Per-group loading curtain (economy v3 phase 2b; docs/design/PER_GROUP_RACES.md "Loading curtain"; V5B on aa6f798:
-- with PER_GROUP on the curtain never lifted after a group's race loaded and stayed up back in the hub).
-- Pinned here:
--   - shared/GroupCurtainRules: join -> loading -> lifted (map built and grid formed); return -> lifted; a hub bystander
--     never sees it; the client timeout lifts it and it stays lifted until the seat changes; PER_GROUP off never acts;
--   - server/RaceGroups: a load that fails or never finishes sends "GroupLoadFailed" and returns the group to the hub
--     (the seat goes, so the curtain lifts);
--   - shared/RaceFlowRules QA switch (Studio-only QAPerGroup) and the client wiring (TrackFlow level-driven curtain,
--     PortalPlunge's per-group switch) by source.
return function(h)
	local C = h.require("src/shared/GroupCurtainRules.luau")
	local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")

	local function input(over: { [string]: any }): any
		local i: any = { perGroup = true, seat = nil, rootPresent = false, rootLoading = false, mapReady = false, now = 0 }
		for k, v in over do
			i[k] = v
		end
		return i
	end

	h.test("join -> loading -> lifted: up from the seat until his map is in and his grid formed", function()
		local s = C.new()
		h.eq(s.phase, "lifted")
		h.eq(C.step(s, input({ now = 0 })), nil, "in the hub: nothing")
		-- Seated at GO; the instance root has not replicated yet.
		h.eq(C.step(s, input({ seat = 1, now = 1 })), "show")
		h.ok(C.up(s))
		h.eq(C.step(s, input({ seat = 1, rootPresent = true, rootLoading = true, now = 2 })), nil, "still loading: no second show")
		-- Loading off but his map has not replicated (or ZoneVisibility has not un-parked it): still up.
		h.eq(C.step(s, input({ seat = 1, rootPresent = true, rootLoading = false, mapReady = false, now = 3 })), nil)
		h.ok(C.up(s))
		-- Map in and grid formed: lift, exactly once.
		h.eq(C.step(s, input({ seat = 1, rootPresent = true, rootLoading = false, mapReady = true, now = 4 })), "lift")
		h.ok(not C.up(s))
		h.eq(C.step(s, input({ seat = 1, rootPresent = true, mapReady = true, now = 5 })), nil, "racing: stays lifted")
		h.eq(C.step(s, input({ seat = 1, rootPresent = true, mapReady = true, now = 200 })), nil)
	end)

	h.test("return -> lifted: the seat going lifts it at once, mid-load or after the race", function()
		local s = C.new()
		h.eq(C.step(s, input({ seat = 3, rootPresent = true, rootLoading = true, now = 0 })), "show")
		-- A failed load (or a leave) clears the seat while loading: the curtain lifts.
		h.eq(C.step(s, input({ seat = nil, now = 2 })), "lift")
		h.ok(not C.up(s))
		h.eq(C.step(s, input({ seat = nil, now = 3 })), nil, "in the hub: stays lifted")
		-- A full race then the return: nothing to do, nothing re-shown on the plaza.
		local r = C.new()
		C.step(r, input({ seat = 4, rootPresent = true, rootLoading = true, now = 0 }))
		h.eq(C.step(r, input({ seat = 4, rootPresent = true, mapReady = true, now = 6 })), "lift")
		h.eq(C.step(r, input({ seat = nil, now = 180 })), nil, "back on the plaza: no curtain")
		h.ok(not C.up(r))
		-- Root destroyed before the seat attribute cleared on this client (replication order): seat still set, no
		-- root. That is "joining" again only if the curtain was down; after the race it would show for a frame, so the
		-- return order matters: RaceGroups clears the seat (inst:leave) before closing the instance.
		h.contains(h.readFile("src/server/RaceGroups.luau"), "\tfor _, p in list do\n\t\tg.inst:leave(p)\n\tend")
	end)

	h.test("hub bystander: another group's load never shows his curtain", function()
		local s = C.new()
		for t = 0, 120, 5 do
			-- He sits in no instance; other groups' roots and maps come and go around him.
			h.eq(C.step(s, input({ seat = nil, rootPresent = false, rootLoading = false, mapReady = t % 10 == 0, now = t })), nil)
		end
		h.ok(not C.up(s))
		h.ok(not C.wants(input({ seat = nil, rootLoading = true })), "a Loading flag without his seat is not his")
	end)

	h.test("timeout fallback: lifts after CLIENT_TIMEOUT, stays lifted until the seat changes", function()
		h.ok(C.CLIENT_TIMEOUT > C.SERVER_LOAD_TIMEOUT, "the server's return lands before the client gives up")
		h.ok(C.SERVER_LOAD_TIMEOUT >= 30, "a cold map build (~18 s in Studio) is never cut short")
		local s = C.new()
		h.eq(C.step(s, input({ seat = 2, rootPresent = true, rootLoading = true, now = 10 })), "show")
		h.eq(C.step(s, input({ seat = 2, rootPresent = true, rootLoading = true, now = 10 + C.CLIENT_TIMEOUT - 1 })), nil)
		h.eq(C.step(s, input({ seat = 2, rootPresent = true, rootLoading = true, now = 10 + C.CLIENT_TIMEOUT })), "timeout")
		h.ok(not C.up(s))
		h.eq(s.phase, "timedout")
		h.eq(C.step(s, input({ seat = 2, rootPresent = true, rootLoading = true, now = 200 })), nil, "no flicker back up")
		-- The server returns him (seat clears): back to lifted, and a later seat shows it again.
		h.eq(C.step(s, input({ seat = nil, now = 210 })), nil)
		h.eq(s.phase, "lifted")
		h.eq(C.step(s, input({ seat = 5, now = 220 })), "show", "the next race gets its curtain")
		-- A timed-out load that finishes late: still lifted, nothing to do.
		local late = C.new()
		C.step(late, input({ seat = 6, rootPresent = true, rootLoading = true, now = 0 }))
		h.eq(C.step(late, input({ seat = 6, rootPresent = true, rootLoading = true, now = C.CLIENT_TIMEOUT })), "timeout")
		h.eq(C.step(late, input({ seat = 6, rootPresent = true, mapReady = true, now = C.CLIENT_TIMEOUT + 5 })), nil)
	end)

	h.test("PER_GROUP off: the rules never act (the single race keeps workspace.TrackSwitching)", function()
		local s = C.new()
		for _, i in { input({ perGroup = false, seat = 1, rootLoading = true }), input({ perGroup = false, now = 999 }) } do
			h.eq(C.step(s, i), nil)
		end
		h.eq(s.phase, "lifted")
		h.eq(RaceFlowRules.PER_GROUP, false, "per-group races stay off in source")
	end)

	h.test("QA switch: Studio-only QAPerGroup, read once at require; never outside Studio", function()
		h.eq(RaceFlowRules.qaPerGroup(true, true), true)
		h.eq(RaceFlowRules.qaPerGroup(false, true), false, "a live server ignores it")
		h.eq(RaceFlowRules.qaPerGroup(true, nil), false)
		h.eq(RaceFlowRules.qaPerGroup(true, "true"), false, "only a real boolean true")
		h.eq(RaceFlowRules.QA_ATTRIBUTE, "QAPerGroup")
		h.eq(RaceFlowRules.QA_PER_GROUP, false, "no attribute in this run: untouched")
		local src = h.readFile("src/shared/RaceFlowRules.luau")
		h.contains(src, "RaceFlowRules.PER_GROUP = false\n")
		h.contains(src, "return RaceFlowRules.qaPerGroup(RunService:IsStudio(), (workspace :: any):GetAttribute(RaceFlowRules.QA_ATTRIBUTE))")
		h.contains(src, "if ok and on == true and not RaceFlowRules.PER_GROUP then")
		h.contains(h.readFile("src/server/init.server.luau"), 'workspace:SetAttribute("PerGroupLive", true)')
		h.contains(h.readFile("tools/qa_pergroup.py"), "workspace:SetAttribute('QAPerGroup', true)")
	end)

	h.test("client wiring: TrackFlow's curtain is level-driven per group; PortalPlunge hands over on the seat", function()
		local tf = h.readFile("src/client/TrackFlow.luau")
		-- The old edge-only handler (showCurtain on a Loading edge, nothing on the return) is gone.
		h.ok(not string.find(tf, "myLoadRoot", 1, true), "no edge-only Loading handler")
		h.contains(tf, "local action = GroupCurtainRules.step(groupCurtain, groupCurtainInput())")
		h.contains(tf, "task.delay(GroupCurtainRules.LIFT_GUARD, forceCurtainOff)")
		h.contains(tf, 'RaceAttr.changed("Loading", safeStep)')
		h.contains(tf, "task.wait(GroupCurtainRules.PERIOD)")
		h.contains(tf, 'event == "GroupLoadFailed"')
		-- Single path untouched: the workspace switch still drives the curtain.
		h.contains(tf, 'workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()\n\t\tshowCurtain(workspace:GetAttribute("TrackSwitching") == true)')
		h.contains(tf, "return workspace:GetAttribute(\"TrackSwitching\") == true or groupCurtainUp()")
		h.contains(tf, "return RaceFlowRules.PER_GROUP and GroupCurtainRules.up(groupCurtain)")
		local pp = h.readFile("src/client/PortalPlunge.luau")
		h.contains(pp, "or (RaceFlowRules.PER_GROUP and LocalPlayer:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE) ~= nil)")
		h.contains(pp, "if RaceFlowRules.PER_GROUP and pl and pl.closingAt then")
	end)

	h.test("RaceGroups: a failed or stuck load sends GroupLoadFailed and returns the group (seat cleared)", function()
		local RaceScope = h.require("src/shared/RaceScope.luau")
		local R = h.require("src/shared/RaceInstanceRules.luau")
		local RaceGroups = h.require("src/server/RaceGroups.luau")
		RaceFlowRules.PER_GROUP = true
		local ok, err = pcall(function()
			RaceGroups.resetForSpec()
			local sent: { string } = {}
			local delayed: { { s: number, fn: () -> () } } = {}
			local tasks: { () -> () } = {}
			local returned: { string } = {}
			local buildOk = true
			local nextId = 0
			local function newInstance(key: string, td: any, mode: string, field: number): any
				nextId += 1
				local rules = R.new(nextId, key, td.id, td.zone, mode, field)
				local root: any = { attrs = {} }
				function root.SetAttribute(self: any, k: string, v: any)
					self.attrs[k] = v
				end
				function root.GetAttribute(self: any, k: string): any
					return self.attrs[k]
				end
				local inst: any = { rules = rules, root = root, players = {} }
				function inst.setAttr(self: any, k: string, v: any)
					self.root:SetAttribute(k, v)
				end
				function inst.getAttr(self: any, k: string): any
					return self.root:GetAttribute(k)
				end
				function inst.transition(self: any, to: any): boolean
					return R.transition(self.rules, to)
				end
				function inst.join(self: any, p: any): boolean
					if not R.join(self.rules, p.UserId) then
						return false
					end
					self.players[p] = true
					p:SetAttribute("RaceInstanceId", self.rules.id)
					return true
				end
				function inst.leave(self: any, p: any): boolean
					if not R.leave(self.rules, p.UserId) then
						return false
					end
					self.players[p] = nil
					p:SetAttribute("RaceInstanceId", nil)
					return true
				end
				function inst.close(self: any)
					for p in self.players do
						self:leave(p)
					end
					R.transition(self.rules, "closed")
				end
				return inst
			end
			local noop = function() end
			RaceGroups.init({
				hooks = {
					suspendRace = noop,
					onTrackChanged = noop,
					spawnBots = noop,
					despawnBots = noop,
					clearItems = noop,
					resetRace = noop,
					allPlayersFinished = function(): boolean
						return false
					end,
					startMode = noop,
				},
				loadTrackData = function(key: string): any
					return ({ dino4 = { id = "DINO-4", zone = "DINO" }, snow1 = { id = "SNOW-1", zone = "SNOW" } })[key]
				end,
				buildMap = function(): boolean
					return buildOk
				end,
				destroyMap = noop,
				publishZone = noop,
				newInstance = newInstance,
				spawn = noop,
				hubReturn = function(list: { any }, zone: string?)
					for _, p in list do
						table.insert(returned, p.Name .. "@" .. tostring(zone))
					end
				end,
				records = function(): any
					return {}
				end,
				serverNow = function(): number
					return 1000
				end,
				clock = function(): number
					return 0
				end,
				send = function(p: any, event: string, data: any)
					table.insert(sent, p.Name .. ":" .. event .. ":" .. tostring(data and data.why))
				end,
				delay = function(s: number, fn: () -> ())
					table.insert(delayed, { s = s, fn = fn })
				end,
				spawnTask = function(fn: () -> ())
					table.insert(tasks, fn) -- the load runs when the spec says (or never: a build that hangs)
				end,
				log = noop,
				hubTrackId = "HUB-0",
			})
			local a = h.fakePlayer(301, "A")
			local b = h.fakePlayer(302, "B")
			-- A stuck build: the load task never runs; the watchdog fires after LOAD_TIMEOUT.
			h.eq(RaceGroups.request({ a }, "dino4", "race", "portal"), "open")
			h.eq(a:GetAttribute("RaceInstanceId"), 1)
			h.eq(b:GetAttribute("RaceInstanceId"), nil, "B stays in the hub")
			local watchdog = nil
			for _, d in delayed do
				if d.s == RaceGroups.LOAD_TIMEOUT then
					watchdog = d.fn
				end
			end
			h.ok(watchdog ~= nil, "a watchdog is armed at LOAD_TIMEOUT")
			h.eq(RaceGroups.LOAD_TIMEOUT, C.SERVER_LOAD_TIMEOUT)
			table.clear(delayed);
			(watchdog :: any)()
			h.eq(sent, { "A:GroupLoadFailed:timeout" })
			h.eq(a:GetAttribute("RaceInstanceId"), nil, "seat cleared: his curtain lifts")
			h.eq(RaceGroups.group(1), nil, "the group is closed")
			for _, d in delayed do
				d.fn()
			end
			h.eq(returned, { "A@DINO" }, "set down on the plaza at the DINO arch")
			-- The hung build returns later: its clean-up path runs, nothing is re-seated.
			tasks[1]()
			h.eq(a:GetAttribute("RaceInstanceId"), nil)
			-- A build that fails: the same message ("failed") and the same return.
			table.clear(sent)
			table.clear(delayed)
			table.clear(returned)
			buildOk = false
			h.eq(RaceGroups.request({ a }, "snow1", "race", "board"), "open")
			h.eq(a:GetAttribute("RaceInstanceId"), 2)
			tasks[2]()
			h.eq(sent, { "A:GroupLoadFailed:failed" })
			h.eq(a:GetAttribute("RaceInstanceId"), nil)
			-- A good load: Loading goes true then false, the watchdog finds it loaded and does nothing.
			table.clear(sent)
			buildOk = true
			h.eq(RaceGroups.request({ a }, "snow1", "race", "board"), "open")
			tasks[3]()
			h.eq(RaceGroups.group(3).inst.root:GetAttribute("Loading"), false)
			for _, d in delayed do
				if d.s == RaceGroups.LOAD_TIMEOUT then
					d.fn()
				end
			end
			h.eq(sent, {}, "a loaded group is left alone")
			h.eq(a:GetAttribute("RaceInstanceId"), 3)
		end)
		RaceFlowRules.PER_GROUP = false
		RaceGroups.resetForSpec()
		RaceScope.resetForSpec()
		if not ok then
			error(err, 0)
		end
	end)
end
