--!strict
-- Lune spec for the combat side of the trap audit (docs/audits/traps_summary.md):
--   1. G2 respawn protection in kit/ItemEffects: a hit 0.3 s after a respawn returns "immune" with no "explode", no
--      stun and no onHit (no life, egg or sack lost); the missile or trap pops on the bubble ("blocked", respawn = true);
--      the window ends on time, is extended (never shortened) by a second stamp, and clear() ends it. BossRace's pure
--      rules: a fresh respawn is skipped, no hazard drops within RESPAWN_CLEAR of a protected frame.
--   2. X-01 world collision: an arena shot stops at a wall (explode with wall = true, nobody hit), its 9-stud blast does
--      not reach a racer behind the wall, gentle ground is skimmed (a dune does not eat the shot), a shot fired with the
--      nose on a wall goes off at once, and a race homing shot is stopped by a wall only once it leaves the course to
--      chase the hull. BattleRules.decideItem holds a missile without a clear shot or at a protected target.
-- Run: tools/tests/run_lune_tests.sh tools/tests/combat_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
}

type Box = { min: Vector3, max: Vector3 }

return function(h: Harness)
	local ItemRules = h.require("src/shared/ItemRules.luau")
	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
	local BattleRules = h.require("src/shared/battle/BattleRules.luau")
	local BossRace = h.require("src/server/BossRace.luau")

	local MISSILE1 = ItemRules.effectFor("red", 1).missile
	local MISSILE2 = ItemRules.effectFor("red", 2).missile
	local TRAP1 = ItemRules.effectFor("green", 1).trap
	local SHIELD = ItemEffects.RESPAWN_IMMUNE_SECONDS

	-- First hit of the segment a -> b on an axis-aligned box (slab test; a segment that starts inside misses it, as a
	-- Roblox ray does). Returns the fraction along the segment and the face normal.
	local function segBox(a: Vector3, b: Vector3, box: Box): (number?, Vector3?)
		local d = b - a
		local tmin, tmax = 0, 1
		local normal: Vector3? = nil
		local axes = { { "X", Vector3.new(1, 0, 0) }, { "Y", Vector3.new(0, 1, 0) }, { "Z", Vector3.new(0, 0, 1) } }
		for _, ax in axes do
			local k, unit = ax[1] :: string, ax[2] :: Vector3
			local o, dd = (a :: any)[k] :: number, (d :: any)[k] :: number
			local lo, hi = (box.min :: any)[k] :: number, (box.max :: any)[k] :: number
			if math.abs(dd) < 1e-9 then
				if o < lo or o > hi then
					return nil, nil
				end
			else
				local t0, t1 = (lo - o) / dd, (hi - o) / dd
				local face = -unit
				if t0 > t1 then
					t0, t1, face = t1, t0, unit
				end
				if t0 > tmin then
					tmin, normal = t0, face
				end
				tmax = math.min(tmax, t1)
				if tmin > tmax then
					return nil, nil
				end
			end
		end
		if normal == nil then
			return nil, nil
		end
		return tmin, normal
	end

	-- A world of boxes plus an optional ground height function (studs of height at a z; marched at 0.25 studs).
	local function caster(boxes: { Box }, ground: ((z: number) -> number)?): (Vector3, Vector3) -> (Vector3?, Vector3?)
		return function(a: Vector3, b: Vector3): (Vector3?, Vector3?)
			local bestT, bestN = math.huge, nil
			for _, box in boxes do
				local t, n = segBox(a, b, box)
				if t and t < bestT then
					bestT, bestN = t, n
				end
			end
			local g = ground
			if g then
				local len = (b - a).Magnitude
				local steps = math.max(1, math.ceil(len / 0.25))
				for i = 1, steps do
					local t = i / steps
					if t >= bestT then
						break
					end
					local p = a:Lerp(b, t)
					if p.Y < g(p.Z) then
						local slope = (g(p.Z + 0.1) - g(p.Z - 0.1)) / 0.2
						bestT, bestN = t, Vector3.new(0, 1, -slope).Unit
						break
					end
				end
			end
			if bestN == nil then
				return nil, nil
			end
			return a:Lerp(b, bestT), bestN
		end
	end

	type World = {
		t: number,
		racers: { [string]: any },
		hits: { string },
		sent: { string },
		fx: { { name: string, payload: any } },
		logs: { string },
		ctx: any,
		engine: any,
		add: (string, Vector3, Vector3, number?) -> (),
		run: (number) -> (),
		fxNamed: (string) -> { any },
	}

	local function newWorld(cast: ((Vector3, Vector3) -> (Vector3?, Vector3?))?, order: { string }?): World
		local w: World = {
			t = 100,
			racers = {},
			hits = {},
			sent = {},
			fx = {},
			logs = {},
			ctx = nil,
			engine = nil,
		} :: any
		function w.add(id: string, pos: Vector3, forward: Vector3, botId: number?)
			w.racers[id] = { pos = pos, forward = forward, station = -pos.Z, progress = -pos.Z, active = true, isPlayer = botId == nil, botId = botId, plane = "Model_" .. id }
		end
		w.ctx = {
			now = function(): number
				return w.t
			end,
			order = function(): { string }
				return order or {}
			end,
			racer = function(id: string): any
				return w.racers[id]
			end,
			course = function(st: number): (Vector3, Vector3)
				return Vector3.new(0, 0, -st), Vector3.new(0, 0, -1)
			end,
			isShielded = function(_id: string): boolean
				return false
			end,
			sendPlayer = function(id: string, kind: string, _payload: any)
				table.insert(w.sent, id .. ":" .. kind)
			end,
			broadcast = function(name: string, payload: any)
				table.insert(w.fx, { name = name, payload = payload })
			end,
			notifyUsed = function() end,
			applyToBot = function(botId: number, effect: any)
				table.insert(w.sent, "bot" .. botId .. ":" .. effect.kind)
			end,
			spawnVisual = function(): any
				return nil
			end,
			moveVisual = function() end,
			destroyVisual = function() end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			castWorld = cast,
		}
		w.engine = ItemEffects.new(w.ctx)
		function w.run(seconds: number)
			for _ = 1, math.floor(seconds * 30 + 0.5) do
				w.t += 1 / 30
				w.engine.step(1 / 30)
			end
		end
		function w.fxNamed(name: string): { any }
			local out = {}
			for _, f in w.fx do
				if f.name == name then
					table.insert(out, f.payload)
				end
			end
			return out
		end
		return w
	end

	-- Arena rules over every racer in the world: each one targets `targets[id]`; landed hits are recorded.
	local function arena(w: World, targets: { [string]: string })
		w.engine.setArena({
			order = function(): { string }
				local ids = {}
				for id in w.racers do
					table.insert(ids, id)
				end
				table.sort(ids)
				return ids
			end,
			target = function(id: string): string?
				return targets[id]
			end,
			onHit = function(victim: string, attacker: string, source: string, _pos: Vector3)
				table.insert(w.hits, victim .. "<" .. attacker .. ":" .. source)
			end,
		})
	end

	local NORTH = Vector3.new(0, 0, -1)
	local SOUTH = Vector3.new(0, 0, 1)

	---------------------------------------------------------------- 1. G2 respawn protection

	h.test("G2: a hit 0.3 s after a respawn is immune: no explode, no stun, no onHit; it pops on the bubble", function()
		local w = newWorld(nil)
		w.add("player:1", Vector3.new(0, 50, -120), SOUTH)
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		arena(w, { ["bot:101"] = "player:1" })
		w.engine.grantImmunity("player:1", SHIELD)
		h.eq(#w.fxNamed("respawnShield"), 1, "every client is told to show the bubble")
		h.eq(w.fxNamed("respawnShield")[1].plane, "Model_player:1", "on the respawned vehicle")
		w.t += 0.3
		h.eq(w.engine.hit("player:1", "bot:101", "missile", 1.2, Vector3.new(0, 50, -118)), "immune")
		h.eq(#w.fxNamed("explode"), 0, "no explosion on a fresh respawn")
		h.eq(w.sent, {}, "no spin-out sent to the player")
		h.eq(w.hits, {}, "the mode's onHit never runs (no life, egg or sack lost)")
		local blocked = w.fxNamed("blocked")
		h.eq(#blocked, 1, "the bubble eats it")
		h.eq(blocked[1].respawn, true, "and says it was the respawn bubble")
		h.contains(w.logs, "result=immune why=respawn")
		-- A real missile 0.3 s in: it pops on the bubble (spent), it does not fly on through.
		w.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		w.run(0.6)
		h.eq((w.engine.counts()), 0, "the missile is spent on the bubble")
		h.eq(w.hits, {}, "still no hit")
		h.eq(#w.fxNamed("blocked"), 2, "a second pop")
		h.ok(w.engine.isImmune("player:1"), "still protected at 0.9 s")
		-- The window ends on time; then hits land again.
		w.t += SHIELD
		h.ok(not w.engine.isImmune("player:1"), "protection over")
		h.eq(w.engine.hit("player:1", "bot:101", "missile", 1.2, Vector3.new(0, 50, -118)), "hit")
		h.eq(#w.fxNamed("explode"), 1, "the explosion is back")
		h.eq(w.hits, { "player:1<bot:101:missile" })
	end)

	h.test("G2: a trap on the respawn frame pops on the bubble; a later trap still bites", function()
		local w = newWorld(nil)
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		w.add("player:1", Vector3.new(0, 50, 300), NORTH)
		arena(w, {})
		w.engine.hooks.spawnTrap("bot:101", TRAP1, 1) -- dropped 14 behind the bot: (0, 50, 14)
		w.run(1)
		local _, traps = w.engine.counts()
		h.eq(traps, 1, "armed trap")
		-- The player is respawned right on it.
		w.racers["player:1"].pos = Vector3.new(0, 50, 14)
		w.engine.grantImmunity("player:1", SHIELD)
		w.run(0.1)
		local _, after = w.engine.counts()
		h.eq(after, 0, "the trap popped on the bubble")
		h.eq(w.sent, {}, "no stun")
		h.eq(w.hits, {}, "no onHit")
		h.eq(#w.fxNamed("blocked"), 1)
		-- Protection over: the next trap the player meets spins it out.
		w.racers["player:1"].pos = Vector3.new(0, 50, 300)
		w.run(SHIELD)
		w.racers["bot:101"].pos = Vector3.new(0, 50, 100)
		w.engine.hooks.spawnTrap("bot:101", TRAP1, 1) -- at (0, 50, 114)
		w.run(1)
		w.racers["player:1"].pos = Vector3.new(0, 50, 114)
		w.run(0.1)
		h.eq(w.sent, { "player:1:hit" }, "spun out")
	end)

	h.test("G2: a second stamp extends the window (logged once), never shortens it; clear() ends it", function()
		local w = newWorld(nil)
		w.add("player:1", Vector3.new(0, 50, 0), NORTH)
		w.engine.grantImmunity("player:1", SHIELD)
		w.t += 0.05 -- the car's one RequestRespawn reaches FlightServer and CarServer: two stamps
		w.engine.grantImmunity("player:1", SHIELD)
		h.eq(h.count(w.logs, "respawn shield racer=player:1"), 1, "one protection, one log line")
		h.eq(#w.fxNamed("respawnShield"), 2, "the extension is re-sent so the bubble lasts as long")
		w.engine.grantImmunity("player:1", 0.5) -- shorter than what runs: ignored
		h.eq(#w.fxNamed("respawnShield"), 2)
		w.t += SHIELD - 0.02
		h.ok(w.engine.isImmune("player:1"), "the later stamp counts")
		w.engine.clear()
		h.ok(not w.engine.isImmune("player:1"), "a race reset clears it")
	end)

	h.test("G2 review: an asked respawn inside the rearm time starts no new shield; a server-ordered one always does", function()
		local REARM = ItemEffects.RESPAWN_IMMUNE_REARM
		h.ok(REARM > SHIELD + 3, "a mashed RESPAWN button (3 s client cooldown) cannot chain windows")
		local w = newWorld(nil)
		w.add("player:1", Vector3.new(0, 50, 0), NORTH)
		w.add("bot:101", Vector3.new(0, 50, 100), NORTH, 101)
		arena(w, {})
		w.engine.grantImmunity("player:1", SHIELD, true) -- a crash: the client asked
		h.eq(#w.fxNamed("respawnShield"), 1, "the first asked respawn is shielded")
		-- RESPAWN pressed again as the bubble runs out, and again: no new window, no bubble, the hit lands.
		w.t += 3
		w.engine.grantImmunity("player:1", SHIELD, true)
		w.t += 0.1
		w.engine.grantImmunity("player:1", SHIELD, true)
		h.eq(#w.fxNamed("respawnShield"), 1, "no new bubble inside the rearm time")
		h.ok(not w.engine.isImmune("player:1"), "not protected")
		h.eq(h.count(w.logs, "skipped=rearm"), 1, "the refusal is logged once")
		h.eq(w.engine.hit("player:1", "bot:101", "missile", 1.2, Vector3.new(0, 50, 0)), "hit", "a shot lands")
		-- A drown or a boundary return (the server orders it) is shielded even inside the rearm time.
		w.t += 2
		w.engine.grantImmunity("player:1", SHIELD, false)
		h.ok(w.engine.isImmune("player:1"), "server-ordered: protected")
		-- Once the rearm time has passed since the last window, an asked respawn is shielded again.
		w.t += REARM
		w.engine.grantImmunity("player:1", nil, true)
		h.ok(w.engine.isImmune("player:1"), "rearmed (default seconds)")
		w.t += SHIELD - 0.05
		h.ok(w.engine.isImmune("player:1"), "for the full default window")
	end)

	h.test("G2: BossRace skips a fresh respawn and keeps new drops off a protected respawn frame", function()
		h.eq(BossRace.freshRespawn(nil, 50), false, "never respawned")
		h.eq(BossRace.freshRespawn(49.7, 50), true, "0.3 s after the stamp")
		h.eq(BossRace.freshRespawn(50 - SHIELD, 50), false, "the window has ended")
		h.eq(BossRace.freshRespawn(51, 50), false, "a stamp from the future is not trusted")
		local frame = Vector3.new(100, 20, -400)
		h.eq(BossRace.dropClear(frame + Vector3.new(0, 0, -39), { frame }), false, "39 studs ahead of the frame")
		h.eq(BossRace.dropClear(frame + Vector3.new(0, 0, -41), { frame }), true, "41 studs on")
		h.eq(BossRace.dropClear(frame, {}), true, "nobody respawning")
	end)

	---------------------------------------------------------------- 2. X-01 world collision

	-- A bulwark 4 studs thick across the line of fire, its outer face at z = -58.
	local WALL: Box = { min = Vector3.new(-30, 0, -62), max = Vector3.new(30, 100, -58) }

	h.test("X-01: an arena missile stops at a wall: one blast on the wall, nobody behind it hit", function()
		local w = newWorld(caster({ WALL }))
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		w.add("player:1", Vector3.new(0, 50, -120), SOUTH)
		arena(w, { ["bot:101"] = "player:1" })
		w.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		w.run(1)
		h.eq((w.engine.counts()), 0, "the missile is gone")
		h.eq(w.hits, {}, "the player behind the wall is not hit")
		h.eq(w.sent, {}, "no spin-out")
		local blasts = w.fxNamed("explode")
		h.eq(#blasts, 1, "one blast")
		h.eq(blasts[1].wall, true, "on the wall")
		h.ok(math.abs(blasts[1].pos.Z + 58) < 0.01, "at the wall's face (z " .. tostring(blasts[1].pos.Z) .. ")")
		h.contains(w.logs, "missile wall racer=bot:101")
	end)

	h.test("X-01: the 9-stud blast does not reach through the bulwark to a player on the deck behind it", function()
		-- The player stands 8 studs from the wall's outer face: inside the hit radius, on the far side of the wall.
		local w = newWorld(caster({ WALL }))
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		w.add("player:1", Vector3.new(0, 50, -66), SOUTH)
		arena(w, { ["bot:101"] = "player:1" })
		w.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		w.run(1)
		h.eq(w.hits, {}, "sheltered")
		h.eq(#w.fxNamed("explode"), 1, "the blast stays on the wall")
		-- The same shot with nothing in the way hits.
		local open = newWorld(caster({}))
		open.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		open.add("player:1", Vector3.new(0, 50, -66), SOUTH)
		arena(open, { ["bot:101"] = "player:1" })
		open.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		open.run(1)
		h.eq(open.hits, { "player:1<bot:101:missile" }, "no wall, a hit")
	end)

	h.test("X-01: gentle ground is skimmed: a shot over a dune still reaches its target", function()
		-- A sand hump peaking 3 studs over the line of fire at z = -60, sloped 0.15 (about 9 degrees).
		local function dune(z: number): number
			return 53 - math.abs(z + 60) * 0.15
		end
		local w = newWorld(caster({}, dune))
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		w.add("player:1", Vector3.new(0, 50, -120), SOUTH)
		arena(w, { ["bot:101"] = "player:1" })
		w.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		w.run(1)
		h.eq(w.hits, { "player:1<bot:101:missile" }, "the shot rode over the dune")
		for _, b in w.fxNamed("explode") do
			h.ok(b.wall ~= true, "no wall blast on sand")
		end
	end)

	h.test("X-01: fired with the nose on a wall, the shot goes off at once and never flies", function()
		local w = newWorld(caster({ { min = Vector3.new(-30, 0, -6), max = Vector3.new(30, 100, -3) } }))
		w.add("bot:101", Vector3.new(0, 50, 0), NORTH, 101)
		w.add("player:1", Vector3.new(0, 50, -120), SOUTH)
		arena(w, { ["bot:101"] = "player:1" })
		w.engine.hooks.spawnMissile("bot:101", MISSILE1, 1)
		h.eq((w.engine.counts()), 0, "nothing launched")
		local blasts = w.fxNamed("explode")
		h.eq(#blasts, 1)
		h.eq(blasts[1].wall, true)
		h.ok(math.abs(blasts[1].pos.Z + 3) < 0.01, "on the wall 3 studs ahead")
	end)

	h.test("X-01 + missile v3: a race shot never homes through a wall; it keeps to the course path and lands", function()
		-- Course along -Z at y = 0, racers 12 over it. Leader bot:1 at station 400, shooter player:1 at station 100.
		-- Walls across the course at station 250 and 370 stand for rock between the shot and the hull. v2 chased the hull
		-- straight into the second one (a wall blast, the owner's "missiles never reach"). v3 homes only on a clear line
		-- (MissileRules.phase); otherwise it follows the course path, which is the carved corridor and is not swept.
		local course = { min = Vector3.new(-40, 0, -252), max = Vector3.new(40, 60, -248) }
		local chase = { min = Vector3.new(-40, 0, -372), max = Vector3.new(40, 60, -368) }
		local w = newWorld(caster({ course, chase }), { "bot:1", "player:1" })
		w.add("player:1", Vector3.new(0, 12, -100), NORTH)
		w.add("bot:1", Vector3.new(0, 12, -400), NORTH, 1)
		w.engine.hooks.spawnMissile("player:1", MISSILE2, 2)
		w.run(2)
		h.eq((w.engine.counts()), 0, "spent")
		h.eq(w.sent, { "bot1:hit" }, "it reached the leader along the course")
		for _, b in w.fxNamed("explode") do
			h.ok(b.wall ~= true, "no blast into the wall")
		end
		-- Without the walls the same shot lands the same way.
		local open = newWorld(caster({}), { "bot:1", "player:1" })
		open.add("player:1", Vector3.new(0, 12, -100), NORTH)
		open.add("bot:1", Vector3.new(0, 12, -400), NORTH, 1)
		open.engine.hooks.spawnMissile("player:1", MISSILE2, 2)
		open.run(2)
		h.eq(open.sent, { "bot1:hit" }, "hit")
	end)

	h.test("X-01 / G2: a bot holds a missile without a clear shot or at a protected target", function()
		local aimed = { targetDist = 150, targetDot = 0.95, heldFor = 1 }
		h.eq(BattleRules.decideItem("missile", aimed), true, "unmeasured line of sight counts as clear")
		local blocked = table.clone(aimed) :: any
		blocked.clearShot = false
		local use, why = BattleRules.decideItem("missile", blocked)
		h.eq(use, false)
		h.eq(why, "no line of sight")
		local impatient = { targetDist = 300, targetDot = 0.7, heldFor = 12, clearShot = false }
		h.eq(BattleRules.decideItem("missile", impatient), false, "not even when impatient")
		local bubble = table.clone(aimed) :: any
		bubble.clearShot = true
		bubble.targetProtected = true
		use, why = BattleRules.decideItem("missile", bubble)
		h.eq(use, false)
		h.eq(why, "target protected")
		local clear = table.clone(aimed) :: any
		clear.clearShot = true
		h.eq(BattleRules.decideItem("missile", clear), true, "clear shot fires")
		h.eq(BattleRules.decideItem("trap", { behindDist = 50, heldFor = 1, clearShot = false }), true, "traps are unaffected")
	end)
end
