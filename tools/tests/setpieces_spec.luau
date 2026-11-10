--!strict
-- Lune spec for the Batch 2 set pieces (docs/REMARKABLE.md items 13, 21, 22, 25): shared/SetPieceRules (cannon rides,
-- the gull, ducks, the Moon Monorail, boss gags and retirement), server/DuckHunt's pickup check, and the v2 save
-- schema (ducks, the Golden Quack horn) with the A14 idempotency rules: a held duck is a no-op on a double pickup, a
-- retry, a rejoin and a queued pickup before the profile loads, and the horn can neither be sold nor removed.
-- Run: tools/tests/run_lune_tests.sh tools/tests/setpieces_spec.luau

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
	stubs: any,
}

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local Rules = h.require("src/shared/SetPieceRules.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local Progression = h.require("src/shared/Progression.luau")

	local function near(a: number, b: number, eps: number, msg: string?)
		h.ok(math.abs(a - b) <= eps, string.format("%s: %.4f vs %.4f (eps %.4f)", msg or "near", a, b, eps))
	end

	-- A launcher shaped like the plan's CrestCannon (beach crest -> main deck).
	local function crest(): any
		local axis = Vector3.new(-0.59, 0.5, -0.634).Unit
		return Rules.parseLauncher({
			name = "CrestCannon",
			cradle = Vector3.new(-5222, 25.869, 4250),
			breech = Vector3.new(-5225.407, 27.969, 4246.34),
			axis = axis,
			length = 15,
			land = Vector3.new(-5348.4, 33.9, 4114.2),
			landLook = Vector3.new(-0.6, 0, 0.8),
			ground = 32,
			surface = "deck",
		})
	end

	---------------------------------------------------------------------------------------------------- launchers

	h.test("launchers: only the allow-listed names parse; malformed rows are refused", function()
		h.ok(crest() ~= nil)
		h.eq(Rules.parseLauncher({ name = "Trebuchet", cradle = Vector3.zero }), nil)
		h.eq(Rules.parseLauncher({ name = "DeckCannon" }), nil, "missing fields")
		h.eq(Rules.parseLauncher("CrestCannon"), nil)
		local keys = {}
		for k in Rules.LAUNCHER_NAMES do
			table.insert(keys, k)
		end
		table.sort(keys)
		h.eq(keys, { "CrestCannon", "DeckCannon" })
	end)

	h.test("launchers: the ride starts on the car, leaves the muzzle along the barrel and ends on the landing", function()
		local l = crest()
		local start = CFrame.lookAt(l.cradle, l.cradle + Vector3.new(-1, 0, 0))
		local cf0, ph0 = Rules.rideFrame(l, start, 0)
		h.eq(ph0, "load")
		near((cf0.Position - start.Position).Magnitude, 0, 1e-4, "t=0 is the start frame")
		local tFlight = Rules.LOAD_TIME + Rules.FUSE_TIME
		local cf1, ph1 = Rules.rideFrame(l, start, tFlight + 1e-6)
		h.eq(ph1, "flight")
		near((cf1.Position - Rules.muzzle(l)).Magnitude, 0, 0.05, "the flight starts at the muzzle")
		local a, _ = Rules.rideFrame(l, start, tFlight + 0.01)
		local dir = (a.Position - cf1.Position).Unit
		h.ok(dir:Dot(l.axis) > 0.995, "the car leaves along the barrel axis")
		local cfEnd, phEnd = Rules.rideFrame(l, start, Rules.rideTime() - 1e-6)
		h.eq(phEnd, "flight")
		near((cfEnd.Position - l.land).Magnitude, 0, 0.05, "the arc ends on the landing")
		local done, phase = Rules.rideFrame(l, start, Rules.rideTime() + 0.01)
		h.eq(phase, "done")
		near((done.Position - l.land).Magnitude, 0, 1e-4)
		h.ok(done.LookVector:Dot(l.landLook) > 0.999, "set down facing landLook")
	end)

	h.test("launchers: the ride is continuous and fits inside the validator's grace window", function()
		local l = crest()
		local start = CFrame.lookAt(l.cradle, l.cradle + Vector3.new(-1, 0, 0))
		local prev = Rules.rideFrame(l, start, 0).Position
		local worst = 0
		local t = 1 / 60
		while t < Rules.rideTime() do
			local p = Rules.rideFrame(l, start, t).Position
			local jump = (p - prev).Magnitude
			-- the only intended jump: the car is inside the bore at fuse end and appears at the muzzle (hidden by
			-- the barrel and the blast)
			if not (t >= Rules.LOAD_TIME + Rules.FUSE_TIME and t - 1 / 60 < Rules.LOAD_TIME + Rules.FUSE_TIME) then
				worst = math.max(worst, jump)
			end
			prev = p
			t += 1 / 60
		end
		h.ok(worst < 4.5, string.format("frame-to-frame move %.2f studs (60 fps)", worst))
		h.ok(Rules.graceSeconds() >= Rules.rideTime() + 0.5, "grace covers the ride with network slack")
		h.ok(Rules.graceSeconds() <= Rules.GRACE_MAX, "never more than GRACE_MAX")
		h.ok(Rules.arcHeight(l) > 5 and Rules.arcHeight(l) < 60, "a sensible arc")
	end)

	h.test("launchers: a car must drive into the cradle; cooldown per player", function()
		local l = crest()
		local way = Vector3.new(l.axis.X, 0, l.axis.Z).Unit
		h.ok(Rules.inCradle(l, l.cradle - way * 2, way * 20), "driving in")
		h.ok(not Rules.inCradle(l, l.cradle - way * 2, -way * 20), "driving away from it")
		h.ok(not Rules.inCradle(l, l.cradle, Vector3.zero), "parked: not fired")
		h.ok(not Rules.inCradle(l, l.cradle + Vector3.new(20, 0, 0), way * 20), "outside the radius")
		h.ok(not Rules.inCradle(l, l.cradle + Vector3.new(0, 9, 0), way * 20), "above it (in the air)")
		local book = {}
		h.ok(Rules.canFire(book, "p1", 100))
		Rules.noteFire(book, "p1", 100)
		h.ok(not Rules.canFire(book, "p1", 100 + Rules.rideTime()), "still riding or cooling down")
		h.ok(Rules.canFire(book, "p2", 100.1), "per player")
		h.ok(Rules.canFire(book, "p1", 100 + Rules.rideTime() + Rules.COOLDOWN + 0.01))
	end)

	h.test("launchers: data checks (sand above the last tide, aim, own cradle)", function()
		local l = crest()
		h.eq(select(1, Rules.validateLauncher(l, 24.5)), true)
		local sand = table.clone(l)
		sand.surface = "sand"
		sand.ground = 24.3
		local ok, why = Rules.validateLauncher(sand, 24.5)
		h.eq(ok, false)
		h.contains(why, "under the last tide")
		sand.ground = 24.6
		h.eq(select(1, Rules.validateLauncher(sand, 24.5)), true)
		local skew = table.clone(l)
		skew.axis = Vector3.new(0.6, 0.5, -0.6).Unit
		h.eq(select(2, Rules.validateLauncher(skew, 24.5)), "barrel not aimed at the landing")
		local close = table.clone(l)
		close.land = l.cradle + Vector3.new(-3, 0, -3)
		close.axis = (Vector3.new(-3, 0, -3).Unit + Vector3.new(0, 0.9, 0)).Unit
		h.eq(select(1, Rules.validateLauncher(close, 24.5)), false)
	end)

	---------------------------------------------------------------------------------------------------- gull

	h.test("gull: a long jump out of the tide is a rescue; driving and dry respawns are not", function()
		local tide = 23
		h.ok(Rules.isWaterRescue(Vector3.new(0, 22.5, 0), Vector3.new(60, 27, 10), tide, 1.9), "sank in the tide, set down on sand")
		h.ok(not Rules.isWaterRescue(Vector3.new(0, 22.5, 0), Vector3.new(10, 27, 0), tide, 1.9), "a short move")
		h.ok(not Rules.isWaterRescue(Vector3.new(0, 30, 0), Vector3.new(80, 30, 0), tide, 1.9), "a dry respawn")
		h.ok(not Rules.isWaterRescue(Vector3.new(0, 22, 0), Vector3.new(80, 22, 0), nil, 1.9), "no tide (not a water battle)")
		local a, b = Vector3.new(0, 20, 0), Vector3.new(100, 26, 0)
		near((Rules.gullCarry(a, b, 0) - a).Magnitude, 0, 1e-6)
		near((Rules.gullCarry(a, b, 1) - b).Magnitude, 0, 1e-6)
		local mid = Rules.gullCarry(a, b, 0.5)
		h.ok(mid.Y > 23 + 14, "carried well over the water")
		h.ok(math.abs(Rules.gullFlap(0.1, true)) <= 0.75 and math.abs(Rules.gullFlap(0.3, false)) <= 0.5)
	end)

	---------------------------------------------------------------------------------------------------- ducks

	h.test("ducks: one per launch map, on the named alternate, eligible modes only", function()
		h.eq(#Rules.DUCK_TRACKS, 6)
		for _, id in Rules.DUCK_TRACKS do
			h.ok(Rules.DUCK_SPOTS[id] ~= nil, id)
			h.ok(Progression.TRACKS[id] ~= nil, id .. " is a launch track")
		end
		local pts = { Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(10, 0, 10) }
		near((Rules.alongPolyline(pts, 0) - pts[1]).Magnitude, 0, 1e-6)
		near((Rules.alongPolyline(pts, 1) - pts[3]).Magnitude, 0, 1e-6)
		near((Rules.alongPolyline(pts, 0.25) - Vector3.new(5, 0, 0)).Magnitude, 0, 1e-6)
		local alts = { { id = "Alt1", points = pts }, { id = "Alt2", points = { Vector3.new(100, 0, 0), Vector3.new(200, 0, 0) } } }
		local p = Rules.duckAnchor("DINO-4", alts)
		h.ok(p ~= nil and p.X > 100, "DINO-4's duck is on Alt2")
		h.eq(Rules.duckAnchor("DINO-4", { alts[1] }), nil, "no such alternate: no duck")
		h.ok(Rules.duckEligible("SNOW-1", "race") and Rules.duckEligible("HUB-0", "hub"))
		h.ok(not Rules.duckEligible("SNOW-1", "battle") and not Rules.duckEligible("SNOW-1", "boss") and not Rules.duckEligible("SNOW-1", "rematch"))
		h.ok(not Rules.duckEligible("TEST-STRIP", "race"))
	end)

	h.test("ducks: counts, held list and toasts", function()
		h.eq(Rules.duckCount({ ["DINO-4"] = true, ["SNOW-1"] = true, bogus = true }), 2)
		h.eq(Rules.duckList({ ["SNOW-1"] = true, ["DINO-4"] = true }), { "DINO-4", "SNOW-1" })
		local all = {}
		for _, id in Rules.DUCK_TRACKS do
			all[id] = true
		end
		h.ok(Rules.hasAllDucks(all))
		h.eq(Rules.duckToast(3), "LOST DUCK 3/6")
		h.contains(Rules.duckToast(6), "GOLDEN QUACK")
	end)

	h.test("ducks: DuckHunt collects through the hidden key's swept rule, once per load", function()
		local DuckHunt = h.require("src/server/DuckHunt.luau")
		local awarded: { string } = {}
		local notes: { string } = {}
		local p = h.fakePlayer(501)
		local st: any = {
			trackId = "SNOW-1",
			pos = Vector3.new(0, 10, 0),
			radius = Rules.DUCK_RADIUS_PLANE,
			done = {},
			last = {},
			hooks = {
				records = function()
					return {}
				end,
				award = function(_pl: any, id: string, source: string): (string, { string })
					table.insert(awarded, id .. "|" .. source)
					return "awarded", {}
				end,
				notify = function(_pl: any, kind: string, _payload: any)
					table.insert(notes, kind)
				end,
				broadcast = function(kind: string, _payload: any)
					table.insert(notes, kind)
				end,
				log = function() end,
			},
		}
		h.eq(DuckHunt.check(st, p, Vector3.new(40, 10, 0), nil), nil, "out of reach")
		-- a fast pass between two checks (60 studs, the duck in the middle) still counts
		h.eq(DuckHunt.check(st, p, Vector3.new(30, 10, 2), Vector3.new(-30, 10, 2)), "awarded")
		h.eq(awarded, { "SNOW-1|duck_pickup:SNOW-1" })
		h.eq(notes, { "DuckFound", "DuckSqueak" })
		h.eq(DuckHunt.check(st, p, Vector3.new(0, 10, 0), nil), nil, "done for this load")
		h.eq(#awarded, 1)
		-- a teleport (respawn) is judged by where it ended, not the line it jumped along
		local st2 = table.clone(st)
		st2.done = {}
		h.eq(DuckHunt.check(st2, p, Vector3.new(300, 10, 0), Vector3.new(-300, 10, 0)), nil)
		-- a duck the player already holds (a later load): a quiet no-op, no celebration, no squeak for the server
		local st3 = table.clone(st)
		st3.done = {}
		st3.hooks = table.clone(st.hooks)
		st3.hooks.award = function(): (string, { string })
			return "noop", {}
		end
		h.eq(DuckHunt.check(st3, p, Vector3.new(0, 10, 0), nil), "noop")
		h.eq(notes, { "DuckFound", "DuckSqueak" }, "nothing new announced")
	end)

	---------------------------------------------------------------------------------------------------- save v2 (A14)

	local function newEnv(backing: any?, storeOverride: any?): any
		local sched = h.newScheduler()
		local logs: { string } = {}
		local store = storeOverride or SaveService.newMemoryStore(backing or {})
		local issued = 0
		local svc = SaveService.new({
			store = store,
			sessionId = "server-A",
			newToken = function(): string
				issued += 1
				return "load" .. tostring(issued)
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
		return { sched = sched, svc = svc, logs = logs, store = store, backing = store.data }
	end

	local function load(env: any, p: any): any
		return env.sched.run(function()
			return env.svc.load(p)
		end)
	end

	h.test("save v2: a duck is awarded once; a double pickup, a retry and a rejoin are no-ops (A14)", function()
		local env = newEnv()
		local p = h.fakePlayer(601)
		load(env, p)
		h.eq(env.svc.award(p, "duck", "SNOW-1", "duck_pickup:SNOW-1"), "awarded")
		local writes = env.store.writes
		h.eq(env.svc.award(p, "duck", "SNOW-1", "duck_pickup:SNOW-1"), "noop", "double pickup")
		h.eq(env.store.writes, writes, "a no-op writes nothing")
		h.eq(p:GetAttribute("Ducks"), 1)
		h.eq(p:GetAttribute("DucksHeld"), "SNOW-1")
		h.eq(env.svc.award(p, "duck", "MOON-9", "duck_pickup:MOON-9"), "rejected", "unknown track")
		p:leave()
		env.sched.run(function()
			return env.svc.release(p)
		end)
		local env2 = newEnv(env.backing)
		local p2 = h.fakePlayer(601)
		local snap = load(env2, p2)
		h.eq(snap.ducks, { ["SNOW-1"] = true })
		h.eq(env2.svc.award(p2, "duck", "SNOW-1", "duck_pickup:SNOW-1"), "noop", "rejoin")
		h.eq(p2:GetAttribute("DucksHeld"), "SNOW-1")
	end)

	h.test("save v2: a pickup queued before the profile loads lands once, a doubled one is a no-op", function()
		-- the DataStore is down while the player joins: the load keeps retrying in the background
		local inner = SaveService.newMemoryStore({})
		local down = true
		local store: any = { kind = "flaky", data = inner.data, writes = 0 }
		function store.update(key: string, transform: (any) -> any, ids: { number }?): (boolean, string?)
			if down then
				return false, "502: simulated outage"
			end
			return inner.update(key, transform, ids)
		end
		local env = newEnv(nil, store)
		local p = h.fakePlayer(602)
		env.sched.spawn(function()
			env.svc.load(p)
		end)
		h.eq(env.svc.award(p, "duck", "HUB-0", "duck_pickup:HUB-0"), "queued")
		h.eq(env.svc.award(p, "duck", "HUB-0", "duck_pickup:HUB-0"), "queued", "a double pickup while loading")
		down = false
		env.sched.advance(120)
		h.eq(env.svc.get(p).ducks, { ["HUB-0"] = true })
		-- L20/L21 (SaveService.award): the double is merged in the pending queue, so it is never applied (or logged) twice.
		h.eq(h.count(env.logs, "queued user=602 kind=duck id=HUB-0"), 1, "one queued copy for the doubled pickup")
		h.eq(h.count(env.logs, "noop user=602 kind=duck id=HUB-0"), 0, "the double never reaches the loaded profile")
		h.eq(env.svc.award(p, "duck", "HUB-0", "duck_pickup:HUB-0"), "noop")
		h.eq(inner.data.u_602.profile.ducks, { ["HUB-0"] = true }, "saved")
	end)

	h.test("save v2: all six ducks own the Golden Quack; an edit can neither grant nor remove it", function()
		local env = newEnv()
		local p = h.fakePlayer(603)
		load(env, p)
		h.eq(env.svc.edit(p, "shopBug", function(profile: any)
			profile.cosmetics.owned[Rules.GOLDEN_QUACK] = true
		end), false, "never sold")
		h.eq(env.svc.edit(p, "forged", function(profile: any)
			profile.ducks["DINO-4"] = true
		end), false, "ducks only through award")
		for i, id in Rules.DUCK_TRACKS do
			h.eq(env.svc.award(p, "duck", id, "duck_pickup:" .. id), "awarded", id)
			h.eq(env.svc.get(p).cosmetics.owned[Rules.GOLDEN_QUACK] == true, i == #Rules.DUCK_TRACKS, "owned only with all six")
		end
		h.eq(p:GetAttribute("Ducks"), 6)
		h.eq(env.svc.edit(p, "wipe", function(profile: any)
			profile.cosmetics.owned = {}
		end), false, "a progression reward cannot be removed")
		h.ok(env.svc.get(p).cosmetics.owned[Rules.GOLDEN_QUACK])
	end)

	h.test("save v2: a v1 record migrates (ducks added, nothing else touched) and the migration is idempotent", function()
		local v1: any = SaveService.newProfile()
		v1.version = 1
		v1.ducks = nil
		v1.tokens["race:DINO-4"] = true
		v1.gears = 77
		local migrated, from = SaveService.migrate(v1)
		h.eq(from, 1)
		h.eq(migrated.version, 2)
		h.eq(migrated.ducks, {})
		h.eq(migrated.tokens, { ["race:DINO-4"] = true })
		h.eq(migrated.gears, 77)
		local again, from2 = SaveService.migrate(migrated)
		h.eq(from2, nil, "a v2 record needs no migration")
		h.eq(again, migrated)
		-- a stray v1 field under that name keeps only real finds
		local odd: any = SaveService.newProfile()
		odd.version = 1
		odd.ducks = { ["SNOW-1"] = true, ["DINO-4"] = "yes", junk = true }
		h.eq(SaveService.migrate(odd).ducks, { ["SNOW-1"] = true })
		-- a v0 record walks both steps
		local v0 = SaveService.migrate({ tokens = { ["DINO-4"] = true } })
		h.eq(v0.version, SaveService.CURRENT_VERSION)
		h.eq(v0.ducks, {})
	end)

	h.test("save v2: the Golden Quack is a progression reward nobody can buy or stock", function()
		local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
		local row: any = nil
		for _, c in MonetizationConfig.COSMETICS do
			if c.key == Rules.GOLDEN_QUACK then
				row = c
			end
		end
		h.ok(row ~= nil, "catalog row")
		h.eq(row.kind, "horn")
		h.eq(row.source, "amulet")
		h.eq(row.gearsPrice, nil)
		for _, list in { MonetizationConfig.SHOP.always, MonetizationConfig.SHOP.rotating } do
			for _, key in list do
				h.ok(key ~= Rules.GOLDEN_QUACK, "never stocked")
			end
		end
		for _, prod in MonetizationConfig.PRODUCTS do
			for _, key in (prod.grants.cosmetics or {}) do
				h.ok(key ~= Rules.GOLDEN_QUACK, "never sold")
			end
		end
	end)

	---------------------------------------------------------------------------------------------------- monorail

	h.test("monorail: a continuous shuttle, parked at the stations between runs", function()
		local M = Rules.MONORAIL
		local P = Rules.monorailPeriod()
		h.ok(P > 2 * Rules.monorailRunTime())
		local x0, d0 = Rules.monorailAt(0, 0)
		near(x0, M.westX, 1e-6)
		h.eq(d0, 1)
		local prev = x0
		local worst = 0
		for i = 1, math.floor(P * 20) do
			local x = Rules.monorailAt(i / 20, 0)
			worst = math.max(worst, math.abs(x - prev))
			prev = x
		end
		h.ok(worst <= M.cruise / 20 + 1e-3, "never faster than cruise")
		local xe, de = Rules.monorailAt(Rules.monorailRunTime() + 1, 0)
		near(xe, M.eastX, 1e-6)
		h.eq(de, 0)
		local xm, dm = Rules.monorailAt(Rules.monorailRunTime() + M.dwell + 5, 0)
		h.ok(xm < M.eastX and dm == -1, "westbound after the dwell")
	end)

	h.test("monorail: anchored to GO it is abreast of the grid at crossing A and makes crossing B in about 20 s", function()
		local M = Rules.MONORAIL
		local go = 5000
		local ep = Rules.monorailEpoch(go)
		local x = Rules.monorailAt(go + 2.2, ep)
		near(x, M.crossA.x, 25, "abreast of the start straight ~2 s after GO")
		h.ok(Rules.monorailRaceOn(Rules.monorailAt(go + 2.2, ep)), "the field's crossing starts a race")
		local tA = Rules.monorailEastboundAt(M.crossA.x, go + 2, ep) :: number
		local tB = Rules.monorailEastboundAt(M.crossB.x, go + 2, ep) :: number
		h.ok(tB - tA > 18 and tB - tA < 22.5, string.format("A -> B in %.1f s", tB - tA))
		-- the train's own time agrees with its position
		near(Rules.monorailAt(tB, ep), M.crossB.x, 0.5)
		local won, margin = Rules.monorailVerdict(tB - 1.2, tB)
		h.ok(won and math.abs(margin - 1.2) < 1e-9)
		h.contains(Rules.monorailToast(true, 1.2), "+1.2 s")
		h.ok(not (Rules.monorailVerdict(tB + 0.1, tB)))
		h.eq(Rules.monorailEastboundAt(M.westX - 10, go, ep), nil, "off the viaduct")
	end)

	h.test("monorail: station crossings ignore lap wraps and respawn jumps", function()
		h.ok(Rules.crossedStation(140, 151, 150))
		h.ok(not Rules.crossedStation(151, 160, 150))
		h.ok(not Rules.crossedStation(4790, 160, 150), "lap wrap")
		h.ok(not Rules.crossedStation(10, 900, 150), "respawn jump")
		h.ok(not Rules.crossedStation(nil, 160, 150))
		h.ok(not Rules.monorailRaceOn(Rules.MONORAIL.crossA.x, -1), "westbound: no race")
	end)

	---------------------------------------------------------------------------------------------------- bosses

	local CLIPS = { DINO = "Cinderwing", SNOW = "Frosthorn", ISLAND = "Clattershell", FOREST = "Emberbeetle", HUB = "Thunderwright" }

	h.test("boss gags: every zone boss has a gag that is sorted, finite, uses its own clips and ends in a poof", function()
		for zone, clipsName in CLIPS do
			local gag = Rules.GAGS[zone]
			h.ok(gag ~= nil, zone)
			local mod = h.require("src/shared/bossclips/" .. clipsName .. ".luau")
			for i = 2, #gag.keys do
				h.ok(gag.keys[i].t > gag.keys[i - 1].t, zone .. " keys sorted")
			end
			near(gag.keys[#gag.keys].t, gag.seconds, 1e-9, zone .. " last key at the end")
			for _, c in gag.clips do
				h.ok(mod.clips[c.clip] ~= nil, zone .. " clip " .. c.clip)
			end
			local poof = false
			for _, e in gag.events do
				h.ok(e.at >= 0 and e.at <= gag.seconds, zone .. " event in range")
				poof = poof or e.kind == "poof"
			end
			h.ok(poof, zone .. " leaves in a puff")
			for i = 0, 40 do
				local p, yaw, pitch, roll = Rules.gagPose(gag, gag.seconds * i / 40)
				h.ok(p.Magnitude < 400 and yaw == yaw and pitch == pitch and roll == roll, zone .. " finite pose")
			end
			-- every event fires exactly once over a run of frame windows
			local seen = 0
			local t = 0
			while t < gag.seconds + 0.1 do
				seen += #Rules.gagEvents(gag, t, t + 1 / 60)
				t += 1 / 60
			end
			for _, e in gag.events do
				h.ok(e.at > 0, zone .. " " .. e.kind .. ": an event at exactly 0 would never fire")
			end
			h.eq(seen, #gag.events, zone .. " events")
			-- the squeak: every boss has a roar to play fast
			h.ok(mod.clips.roar ~= nil, zone .. " roar clip")
		end
	end)

	h.test("retired bosses: beaten list from the profile, LOD steps and poses", function()
		local profile: any = SaveService.newProfile()
		profile.boss.SNOW.first = true
		profile.boss.DINO.first = true
		profile.finalBoss = true
		h.eq(Rules.bossesBeaten(profile), { "DINO", "SNOW", "HUB" })
		h.eq(Rules.retiredZones({ "SNOW", "HUB", "SNOW", "SPACE", 7 }), { "HUB", "SNOW" })
		h.eq(Rules.retireStep(50), 0)
		h.eq(Rules.retireStep(300), Rules.RETIRE_LOD_STEP)
		h.eq(Rules.retireStep(900), -1)
		for zone in CLIPS do
			local spec = Rules.RETIRE[zone]
			h.ok(spec ~= nil, zone)
			local mod = h.require("src/shared/bossclips/" .. CLIPS[zone] .. ".luau")
			h.ok(mod.clips[spec.base] ~= nil, zone .. " base clip " .. spec.base)
			for i = 0, 20 do
				local off, dir = Rules.retirePose(zone, i * 0.7)
				h.ok(off.Magnitude <= spec.radius + 3, zone .. " stays home")
				near(dir.Magnitude, 1, 1e-6, zone .. " heading")
			end
		end
	end)
end
