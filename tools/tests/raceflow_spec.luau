-- Race flow with 2+ humans (shared/RaceFlowRules; TEST_LIST L16, L19, L20/L21, L28, L30-L32, LAUNCH_PROGRESSION 6):
-- FLY AGAIN / HUB votes (unanimous acts at once, the timer's majority otherwise), the DNF deadline's state machine,
-- who beat the boss, the lobby texts and back-out rule, the return grid in front of each real hub arch, join slots
-- that never grow past the player count, and SaveService's pending queue merging a repeated award.
return function(h)
	local R = h.require("src/shared/RaceFlowRules.luau")
	local PortalRules = h.require("src/shared/PortalRules.luau")

	h.test("isGroup / canVote: only done humans vote; never in the hub; no AGAIN in a Storm Cup", function()
		h.ok(not R.isGroup(1) and R.isGroup(2) and R.isGroup(8))
		h.ok(R.canVote("again", true, "race") and R.canVote("hub", true, "boss"))
		h.ok(not R.canVote("again", false, "race"), "still racing")
		h.ok(not R.canVote("hub", true, "hub"), "nothing to vote on in the hub")
		h.ok(not R.canVote("again", true, "stormcup") and R.canVote("hub", true, "stormcup"), "cup: HUB only")
		h.ok(not R.canVote("quit", true, "race"), "unknown choice")
	end)

	h.test("tally: only the humans present count (a leaver's vote leaves with him)", function()
		local a, b, c = {}, {}, {}
		local votes = { [a] = "again", [b] = "hub", [c] = "again" }
		h.eq({ R.tally(votes, { a, b, c }) }, { 2, 1 })
		h.eq({ R.tally(votes, { a, b }) }, { 1, 1 }, "c left")
		h.eq({ R.tally({}, { a }) }, { 0, 0 })
	end)

	h.test("decide: every human the same way acts at once; split votes wait for the timer", function()
		h.eq(R.decide(3, 0, 3, false), "again")
		h.eq(R.decide(0, 2, 2, false), "hub")
		h.eq(R.decide(2, 0, 3, false), nil, "one human has not voted yet")
		h.eq(R.decide(2, 1, 3, false), nil, "split: the timer decides")
		h.eq(R.decide(1, 0, 1, false), "again", "solo vote acts at once")
	end)

	h.test("decide at the timer: AGAIN needs more than half of the humans present, otherwise HUB", function()
		h.eq(R.decide(2, 1, 3, true), "again", "2 of 3")
		h.eq(R.decide(1, 0, 2, true), "hub", "1 of 2 is not more than half")
		h.eq(R.decide(2, 0, 4, true), "hub", "2 of 4 is not more than half")
		h.eq(R.decide(3, 0, 5, true), "again")
		h.eq(R.decide(0, 0, 1, true), "hub", "solo with no vote: back to the hub as before")
		h.eq(R.decide(0, 0, 0, true), "hub", "everyone left")
	end)

	h.test("voteLabel: AGAIN 1/3 on the card with votes; the plain label solo or before any vote", function()
		h.eq(R.voteLabel("FLY AGAIN", "AGAIN", 1, 3), "AGAIN 1/3")
		h.eq(R.voteLabel("HUB", "HUB", 2, 3), "HUB 2/3")
		h.eq(R.voteLabel("FLY AGAIN", "AGAIN", 0, 3), "FLY AGAIN")
		h.eq(R.voteLabel("FLY AGAIN", "AGAIN", nil, nil), "FLY AGAIN", "solo: the server publishes nothing")
		h.eq(R.voteLabel("HUB", "HUB", 1, 1), "HUB")
	end)

	h.test("raceEndStep: solo returns at the finish; a group starts the DNF deadline, then times out", function()
		h.eq(R.raceEndStep(true, true, 100, nil, false), "return", "solo finish (all done)")
		h.eq(R.raceEndStep(false, false, 100, nil, false), "wait", "nobody home yet")
		h.eq(R.raceEndStep(false, true, 100, nil, false), "dnf", "first human home: the deadline starts")
		h.eq(R.raceEndStep(false, true, 120, 145, false), "wait", "inside the deadline")
		h.eq(R.raceEndStep(false, true, 145, 145, false), "timeout", "deadline passed")
		h.eq(R.raceEndStep(true, true, 130, 145, false), "return", "everyone finished before it")
		h.eq(R.raceEndStep(false, true, 200, nil, true), "wait", "a battle ends itself")
		h.eq(R.DNF_SECONDS, 45)
	end)

	h.test("dnfText: whole seconds, gone at zero", function()
		h.eq(R.dnfText(31.2), "Finish in 32 s or DNF")
		h.eq(R.dnfText(0.1), "Finish in 1 s or DNF")
		h.eq(R.dnfText(0), "")
		h.eq(R.dnfText(-3), "")
	end)

	h.test("botsAhead: a human behind another human but ahead of the boss beat it (L13, L16)", function()
		local order = { { isPlayer = true }, { isPlayer = true } }
		h.eq(R.botsAhead(order), 0, "third human, boss not home yet: beaten")
		table.insert(order, { isPlayer = false })
		h.eq(R.botsAhead(order), 1, "the boss crossed first")
		h.eq(R.botsAhead({}), 0, "first home")
	end)

	h.test("lobby texts: banner, busy toast, guest line fit a phone", function()
		h.eq(R.lobbyText("Rex", "SNOW", 11.3), "Rex opened SNOW - race starts in 12")
		h.eq(R.lobbyText("Rex", "SNOW", -1), "Rex opened SNOW - race starts in 0")
		h.ok(#R.lobbyText(string.rep("W", 40), "FOREST TIME TRIAL", 12) <= 70, "long names are cut")
		h.eq(R.lobbyBusyText(true, "Rex", "SNOW", 7.5), "You're in! SNOW starts in 8")
		h.eq(R.lobbyBusyText(false, "Rex", "SNOW", 7.5), "Rex opened SNOW - starts in 8")
		h.eq(R.GUEST_TEXT, "Guest race: results won't count")
		h.eq(R.LOBBY_SECONDS, 20, "economy v3 section 2")
		h.eq(R.SOLO_QUICK_WARP, false, "solo uses the lobby per group; the 1.5 s warp is a config fallback")
	end)

	-- PortalArch_SNOW as authored (LookVector out of the plaza).
	local SNOW = CFrame.new(-8225.8489, 37.0, 7909.6068, 0.7660, 0.0, 0.6428, 0.0, 1.0, 0.0, -0.6428, 0.0, 0.7660)

	h.test("lobbyHolds: driving on beyond the arch or turning away holds; backing out onto the plaza cancels", function()
		local function side(d: number, lateral: number): number
			return PortalRules.side(SNOW.Position + SNOW.LookVector * d + SNOW.RightVector * lateral, SNOW)
		end
		h.ok(R.lobbyHolds(side(2, 0), PortalRules.CANCEL_BACK))
		h.ok(R.lobbyHolds(side(300, 200), PortalRules.CANCEL_BACK), "12 s of driving, far off the axis")
		h.ok(R.lobbyHolds(side(-2, 0), PortalRules.CANCEL_BACK), "a nose bump back")
		h.ok(not R.lobbyHolds(side(-6, 0), PortalRules.CANCEL_BACK), "back on the plaza")
	end)

	h.test("returnFrame (L19): every real hub arch lands the grid on the plaza side, clear of the veil, facing out", function()
		local td = h.require("build/hub0/TrackData.luau")
		local hub = td.hub
		local groundY = hub.spawn.cf.Y - R.RETURN_GROUND_LIFT
		local plaza = Vector3.new(-8150, groundY, 8000)
		h.eq(#hub.portals, 5)
		for _, portal in hub.portals do
			local f = R.returnFrame(portal.cf, groundY)
			h.ok(math.abs(f.Y - hub.spawn.cf.Y) < 0.01, portal.zone .. ": the hub spawn's height above the paving")
			-- H0-08: out of the arch, turned RETURN_TURN off the fountain (straight out, the grid faced the basin).
			local outDot = f.LookVector:Dot(portal.cf.LookVector)
			h.ok(math.abs(outDot + math.cos(math.rad(R.RETURN_TURN))) < 1e-3, portal.zone .. ": out of the arch, turned RETURN_TURN")
			h.ok(math.abs(f.LookVector.Y) < 1e-6 and math.abs(f.UpVector.Y - 1) < 1e-6, portal.zone .. ": level, upright")
			-- FlightServer.getStartCFrame's grid: two rows of four, rows stepping back (+Z) toward the arch.
			for slot = 1, 8 do
				local s = slot - 1
				local cf = f * CFrame.new((s % 4 - 1.5) * 12, 3, (s // 4) * 16)
				local sd = PortalRules.side(cf.Position, portal.cf)
				h.ok(sd < -PortalRules.CANCEL_BACK, portal.zone .. " slot " .. slot .. ": on the plaza side, clear of the veil")
				-- Driving straight ahead from the grid never crosses the arch.
				h.ok(not PortalRules.crossed(cf.Position, cf.Position + cf.LookVector * 40, portal.cf), portal.zone .. " slot " .. slot)
			end
			local toPlaza = Vector3.new(plaza.X - f.X, 0, plaza.Z - f.Z).Unit
			h.ok(f.LookVector:Dot(toPlaza) > 0.6, portal.zone .. ": looking into the plaza")
			-- H0-08: the line ahead passes the fountain (upper basin radius 17) with a car's width and more to spare.
			local rel = Vector3.new(plaza.X - f.X, 0, plaza.Z - f.Z)
			local along = rel:Dot(f.LookVector)
			local miss = (rel - f.LookVector * along).Magnitude
			h.ok(miss > 17 + 12 * 1.5 + 4, portal.zone .. ": every slot's line misses the fountain basin (" .. string.format("%.1f", miss) .. ")")
		end
	end)

	h.test("freeSlot: joiners take the lowest free slot, so churn never grows the hub grid (L31)", function()
		h.eq(R.freeSlot({}), 1)
		h.eq(R.freeSlot({ [1] = true, [2] = true, [4] = true }), 3, "a leaver's slot is reused")
		local used: { [number]: boolean } = {}
		for _ = 1, 8 do
			used[R.freeSlot(used)] = true
		end
		for _ = 1, 100 do -- a public server: someone leaves, someone joins, a hundred times
			used[5] = nil
			local s = R.freeSlot(used)
			h.ok(s <= 8, "slot stays within the player count")
			used[s] = true
		end
	end)

	h.test("SaveService (L20/L21): an award repeated while the profile loads is queued once; later awards still fit", function()
		local SaveService = h.require("src/server/SaveService.luau")
		local sched = h.newScheduler()
		local inner = SaveService.newMemoryStore({})
		local down = true
		local store: any = { kind = "flaky", data = inner.data }
		function store.update(key: string, transform: (any) -> any, ids: { number }?): (boolean, string?)
			if down then
				return false, "502: simulated outage"
			end
			return inner.update(key, transform, ids)
		end
		local logs: { string } = {}
		local issued = 0
		local svc = SaveService.new({
			store = store,
			sessionId = "server-A",
			newToken = function(): string
				issued += 1
				return "server-A-load" .. tostring(issued)
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function(line: string)
				table.insert(logs, line)
			end,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0 },
		})
		local p = h.fakePlayer(701)
		sched.spawn(function()
			svc.load(p)
		end)
		-- A player parked on a hub find for 10 s while the DataStore is down: 50 polls at 5 Hz.
		for _ = 1, 50 do
			h.eq(svc.award(p, "hubFind", "HubFind_Ground", "hub:HubFind_Ground"), "queued")
		end
		h.eq(h.count(logs, "queued user=701 kind=hubFind"), 1, "one queued copy, no log flood")
		h.eq(svc.award(p, "bestTime", "DINO-4", "race_finish", 99000), "queued")
		h.eq(svc.award(p, "bestTime", "DINO-4", "race_finish", 95000), "queued", "a faster time while queued")
		h.eq(svc.award(p, "bestTime", "DINO-4", "race_finish", 97000), "queued", "a slower one")
		h.eq(svc.award(p, "key", "DINO", "keyPickup"), "queued", "a later real award is not rejected")
		h.eq(h.count(logs, "pending queue full"), 0)
		down = false
		sched.advance(120)
		local snap = svc.get(p)
		h.ok(snap and snap.tokens.HubFind_Ground == true, "the find landed")
		h.eq(snap.bestTimes["DINO-4"], 95000, "the fastest queued time kept")
		h.ok(snap.keys.DINO == true, "the key landed")
	end)
end
