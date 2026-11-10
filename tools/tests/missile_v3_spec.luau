--!strict
-- Lune spec for missile v3 (owner 2026-10-20: missiles that never reach anyone, a beep warning, a barrel-roll dodge for
-- planes, an item block for other vehicles, the magnet gone; shared/MissileRules, kit/ItemEffects, ItemService):
--   * pure rules: target choice (nearest racer ahead in reach, targetable first), course -> terminal phase (never
--     through a wall), chase speed, evasion (roll window, drag block, bot dice), roll rate limit, hint copy, arrow angle,
--     the trap press semantics;
--   * the engine: every level locks the racer ahead (players and bots alike), a shot reaches a target in another lane
--     and a fast plane, a car target near the road, no racer ahead = a course shot that expires, the warning payload
--     (lock, direction), a timed roll dodges (overshoot, DODGED!), an early roll or a car's roll does not, a dragged trap
--     blocks (and is spent), a shield never spends it, bots evade on their dice;
--   * ItemService: Drag needs a held trap and ends on Use, Roll is rate limited, consumeDrag spends the trap.
-- Run: tools/tests/run_lune_tests.sh tools/tests/missile_v3_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local ItemRules = h.require("src/shared/ItemRules.luau")
	local MissileRules = h.require("src/shared/MissileRules.luau")
	local TrickRules = h.require("src/shared/TrickRules.luau")
	local ItemService = h.require("src/server/ItemService.luau")
	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")

	local T = MissileRules.TUNING
	local M1 = ItemRules.effectFor("red", 1).missile
	local M2 = ItemRules.effectFor("red", 2).missile
	local M3 = ItemRules.effectFor("red", 3).missile
	local NORTH = Vector3.new(0, 0, -1)

	------------------------------------------------------------------------------------------------------------------
	-- Pure rules
	------------------------------------------------------------------------------------------------------------------

	h.test("pickTarget: the nearest racer ahead in reach; behind, out of reach, inactive and self never", function()
		local c = {
			{ id = "me", progress = 100, active = true },
			{ id = "behind", progress = 60, active = true },
			{ id = "near", progress = 180, active = true },
			{ id = "far", progress = 180 + T.lockRange + 1, active = true },
			{ id = "gone", progress = 120, active = false },
		}
		h.eq(MissileRules.pickTarget("me", 100, c), "near")
		h.eq(MissileRules.pickTarget("me", 100, { c[1], c[2], c[4] }), nil, "nobody ahead in reach: no lock")
		h.eq(MissileRules.pickTarget("near", 180, c), nil, "the leader of this list locks nobody (far is out of reach)")
		-- A volley moves on: the nearer racer is spinning (not targetable), the next one in reach is taken.
		local v = {
			{ id = "spinning", progress = 150, active = true, targetable = false },
			{ id = "next", progress = 300, active = true },
		}
		h.eq(MissileRules.pickTarget("me", 100, v), "next")
		h.eq(MissileRules.pickTarget("me", 100, { v[1] }), "spinning", "only a spinning racer: still the lock (it overshoots)")
	end)

	h.test("phase: course path until close; terminal only on a clear line", function()
		h.eq(MissileRules.phase(300, 300, true), "course")
		h.eq(MissileRules.phase(200, T.terminalRange, true), "terminal", "close in a straight line")
		h.eq(MissileRules.phase(T.terminalGap, 150, true), "terminal", "alongside on the course")
		h.eq(MissileRules.phase(10, 20, false), "course", "never home through a wall")
	end)

	h.test("chaseSpeed: always gains on the target, capped", function()
		h.eq(MissileRules.chaseSpeed(260, nil), 260)
		h.eq(MissileRules.chaseSpeed(260, 110), 260, "a slow target: the shot's own speed")
		h.eq(MissileRules.chaseSpeed(260, 210), 210 + T.catchUp, "an overcharged plane is still caught")
		h.eq(MissileRules.chaseSpeed(260, 1000), T.maxSpeed, "capped")
		h.ok(T.maxSpeed >= 210 + T.catchUp, "the cap leaves room to catch an overcharge (PlaneConfig 210)")
		h.ok(T.lockedLifetime * T.catchUp >= T.lockRange * 0.8, "a locked shot lives long enough to close most of its reach")
	end)

	h.test("evasion: a timed plane roll dodges; early, late or in a car it does not; a dragged trap blocks", function()
		h.ok(T.dodgeWindow >= TrickRules.ROLL_TIME, "the window covers the whole roll")
		local base = { vehicle = "plane", isBot = false, now = 10, since = 9 }
		local function with(extra: any): any
			local t = table.clone(base) :: any
			for k, v in extra do
				t[k] = v
			end
			return t
		end
		h.eq(MissileRules.evasion(with({ rolledAt = 9.6 })), "roll", "rolled 0.4 s before contact")
		h.eq(MissileRules.evasion(with({ rolledAt = 10 - T.dodgeWindow - 0.05 })), nil, "too early")
		h.eq(MissileRules.evasion(with({ rolledAt = 8.9 })), nil, "a roll before the shot left never counts")
		h.eq(MissileRules.evasion(with({ rolledAt = 9.6, vehicle = "car" })), nil, "a car cannot roll")
		h.eq(MissileRules.evasion(with({ vehicle = "car", dragging = true })), "block", "a car dragging a trap")
		h.eq(MissileRules.evasion(with({ dragging = true })), "block", "a plane dragging a trap")
		h.eq(MissileRules.evasion(with({})), nil, "nothing: hit")
		h.eq(MissileRules.evasion({ isBot = true, vehicle = "plane", now = 0, random = 0 }), "roll", "bot plane rolls")
		h.eq(MissileRules.evasion({ isBot = true, vehicle = "car", now = 0, random = 0 }), "block", "bot car blocks")
		h.eq(MissileRules.evasion({ isBot = true, vehicle = "plane", now = 0, random = T.botEvadeChance }), nil, "bot dice fail")
		h.ok(T.botEvadeChance > 0 and T.botEvadeChance <= 0.25, "a small chance")
	end)

	h.test("acceptRoll, counterHint, arrowAngle, pressAction", function()
		h.ok(MissileRules.acceptRoll(5, nil))
		h.ok(not MissileRules.acceptRoll(5, 5 - T.rollMinInterval + 0.1), "a forged roll loop is held")
		h.ok(MissileRules.acceptRoll(5, 5 - T.rollMinInterval))
		h.ok(T.rollMinInterval <= TrickRules.ROLL_COOLDOWN, "a real roll every cooldown is always accepted")
		h.eq(MissileRules.counterHint("plane", nil, false), "DOUBLE-TAP TO DODGE")
		h.eq(MissileRules.counterHint("car", "green", false), "HOLD ITEM: TRAP BEHIND")
		h.eq(MissileRules.counterHint("car", "yellow", false), "SHIELD UP!")
		h.eq(MissileRules.counterHint("car", nil, false), nil)
		h.eq(MissileRules.counterHint("car", "green", true), "TRAP BEHIND")
		for _, row in { MissileRules.counterHint("plane"), MissileRules.counterHint("car", "green") } do
			h.ok(#row <= 24, "hint fits the badge: " .. row)
		end
		local function near(a: number, b: number, msg: string)
			h.ok(math.abs(a - b) < 1e-6, string.format("%s: %.3f vs %.3f", msg, a, b))
		end
		near(MissileRules.arrowAngle(0, -10, 0, -1), 0, "ahead")
		near(MissileRules.arrowAngle(0, 10, 0, -1), 180, "behind")
		near(MissileRules.arrowAngle(10, 0, 0, -1), 90, "right of a camera looking north (-Z)")
		near(MissileRules.arrowAngle(-10, 0, 0, -1), 270, "left")
		h.eq(MissileRules.pressAction("red", 0, false, false), "use", "other items fire on the press")
		h.eq(MissileRules.pressAction("red", 0.1, false, false), nil)
		h.eq(MissileRules.pressAction("green", 0, false, false), nil, "a trap waits on the press")
		h.eq(MissileRules.pressAction("green", 0.1, true, false), "use", "a tap drops it")
		h.eq(MissileRules.pressAction("green", T.dragHoldSeconds, false, false), "drag", "a hold drags it")
		h.eq(MissileRules.pressAction("green", 2, false, true), nil, "dragging: wait")
		h.eq(MissileRules.pressAction("green", 2, true, true), "use", "the release drops it")
	end)

	h.test("magnet retired by config: every level of every roll, the roulette and the battle set", function()
		h.eq(ItemRules.MAGNET_ENABLED, false)
		for band in ItemRules.MYSTERY_WEIGHTS :: any do
			for i = 0, 99 do
				h.ok(ItemRules.rollMystery(if band == "lead" then 1 elseif band == "back" then 8 else 4, 8, (i + 0.5) / 100) ~= "rainbow", "no roll hands out the magnet")
			end
		end
		local BattleRules = h.require("src/shared/battle/BattleRules.luau")
		h.ok(table.find(BattleRules.LEVEL_ONE_SET, "Rainbow") == nil, "no Rainbow pod in arenas")
		h.ok(table.find(BattleRules.LEVEL_ONE_SET_WITH_MAGNET, "Rainbow") ~= nil, "kept for a return")
		h.ok(ItemRules.PARAMS.magnet ~= nil, "the magnet's data stays (hidden, never deleted)")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- Engine fixture: course along -Z at y = 0; planes fly 12 over it, cars sit 3 over it.
	------------------------------------------------------------------------------------------------------------------

	type Racer = { pos: Vector3, forward: Vector3, station: number, progress: number, active: boolean, isPlayer: boolean, botId: number?, plane: string, vehicle: string?, vel: Vector3 }
	type World = any

	local function newWorld(order: { string }): World
		local w: World = { t = 100, racers = {}, order = order, warns = {}, fx = {}, sent = {}, logs = {}, shielded = {}, rolls = {}, drags = {}, dice = nil }
		function w.add(id: string, pos: Vector3, botId: number?, vehicle: string?, speed: number?)
			w.racers[id] = {
				pos = pos,
				forward = NORTH,
				station = -pos.Z,
				progress = -pos.Z,
				active = true,
				isPlayer = botId == nil,
				botId = botId,
				plane = "Model_" .. id,
				vehicle = vehicle or "plane",
				vel = NORTH * (speed or 0),
			}
		end
		local ctx = {
			now = function(): number
				return w.t
			end,
			order = function(): { string }
				return w.order
			end,
			racer = function(id: string): any
				return w.racers[id]
			end,
			course = function(st: number): (Vector3, Vector3)
				return Vector3.new(0, 0, -st), NORTH
			end,
			isShielded = function(id: string): boolean
				return w.shielded[id] == true
			end,
			sendPlayer = function(id: string, kind: string, _p: any)
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
			warnIncoming = function(id: string, payload: any)
				table.insert(w.warns, { racer = id, payload = payload })
			end,
			rolledAt = function(id: string): number?
				return w.rolls[id]
			end,
			consumeDrag = function(id: string): boolean
				if w.drags[id] then
					w.drags[id] = nil
					return true
				end
				return false
			end,
			random = function(): number
				return w.dice or 0.99
			end,
		}
		w.engine = ItemEffects.new(ctx :: any)
		-- Steps at 30 Hz; racers move at their own velocity. onStep(w) runs before each engine step.
		function w.run(seconds: number, onStep: ((any) -> ())?)
			for _ = 1, math.floor(seconds * 30 + 0.5) do
				w.t += 1 / 30
				for _, r in w.racers do
					if r.vel.Magnitude > 0 then
						r.pos += r.vel / 30
						r.station = -r.pos.Z
						r.progress = -r.pos.Z
					end
				end
				if onStep then
					onStep(w)
				end
				w.engine.step(1 / 30)
			end
		end
		function w.warnsFor(id: string): { any }
			local out = {}
			for _, x in w.warns do
				if x.racer == id then
					table.insert(out, x.payload)
				end
			end
			return out
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
		function w.logged(pat: string): number
			local n = 0
			for _, l in w.logs do
				if string.find(l, pat, 1, true) then
					n += 1
				end
			end
			return n
		end
		return w
	end

	------------------------------------------------------------------------------------------------------------------
	-- Engine
	------------------------------------------------------------------------------------------------------------------

	h.test("every level locks the nearest racer ahead (players and bots alike), not the leader out of reach", function()
		for lv, params in { M1, M2, M3 } do
			local w = newWorld({ "bot:5", "player:2", "player:1", "bot:9" })
			w.add("bot:9", Vector3.new(0, 12, 50), 9) -- behind the shooter
			w.add("player:1", Vector3.new(0, 12, 0)) -- shooter
			w.add("player:2", Vector3.new(20, 12, -200)) -- nearest ahead, another lane
			w.add("bot:5", Vector3.new(0, 12, -900), 5) -- out of reach
			w.engine.hooks.spawnMissile("player:1", params, lv)
			h.eq(w.logged("fx missile racer=player:1 level=" .. lv .. " count=" .. params.count .. " target=player:2"), 1, "L" .. lv .. " locks player:2")
			w.run(3)
			h.eq(h.count(w.sent, "player:2:hit"), 1, "L" .. lv .. " reaches the racer in the other lane")
			h.eq(h.count(w.sent, "bot5:hit"), 0, "never the leader out of reach")
			h.eq(h.count(w.sent, "bot9:hit"), 0, "never the racer behind")
		end
		-- A bot shooter locks a player ahead the same way.
		local b = newWorld({ "player:1", "bot:9" })
		b.add("bot:9", Vector3.new(0, 12, 0), 9)
		b.add("player:1", Vector3.new(-25, 12, -250))
		b.engine.hooks.spawnMissile("bot:9", M1, 1)
		b.run(3)
		h.contains(b.sent, "player:1:hit", "a bot's level-one shot reaches the player one lane over")
	end)

	h.test("a fast plane and a car near the road are both caught", function()
		local w = newWorld({ "player:2", "player:1" })
		w.add("player:1", Vector3.new(0, 12, 0), nil, "plane", 110)
		w.add("player:2", Vector3.new(-15, 20, -400), nil, "plane", 210) -- overcharged, 400 ahead
		w.engine.hooks.spawnMissile("player:1", M1, 1)
		w.run(T.lockedLifetime)
		h.eq(h.count(w.sent, "player:2:hit"), 1, "the overcharged plane is caught before the locked lifetime")

		local c = newWorld({ "player:2", "player:1" })
		c.add("player:1", Vector3.new(0, 3, 0), nil, "car", 90)
		c.add("player:2", Vector3.new(18, 3, -220), nil, "car", 100)
		c.engine.hooks.spawnMissile("player:1", M1, 1)
		c.run(4)
		h.eq(h.count(c.sent, "player:2:hit"), 1, "a car at road height is reached")
	end)

	h.test("no racer ahead in reach: the shot flies the course and expires (never chases the racer behind)", function()
		local w = newWorld({ "player:1", "bot:9" })
		w.add("player:1", Vector3.new(0, 12, 0))
		w.add("bot:9", Vector3.new(0, 12, 60), 9)
		w.engine.hooks.spawnMissile("player:1", M1, 1)
		h.eq(w.logged("target=none"), 1, "no lock")
		w.run(M1.lifetime + 0.5)
		h.eq(#w.sent, 0, "nobody hit")
		h.eq(#w.fxNamed("fizzle"), 1, "it expires")
		h.eq((w.engine.counts()), 0)
	end)

	h.test("the warning carries the lock and the shot's direction", function()
		local w = newWorld({ "player:2", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:2", Vector3.new(0, 12, -400))
		w.engine.hooks.spawnMissile("bot:9", M1, 1)
		w.run(1.2)
		local warns = w.warnsFor("player:2")
		h.ok(#warns >= 1, "warned")
		local last = warns[#warns]
		h.eq(last.lock, true, "locked on this player")
		h.eq(last.homing, true)
		h.ok(type(last.dx) == "number" and type(last.dz) == "number" and last.dz > 0, "the shot is behind (+Z)")
		h.ok(MissileRules.arrowAngle(last.dx, last.dz, 0, -1) > 150, "the HUD arrow points back")
	end)

	h.test("the warning ETA counts the chase speed, so the trill a roll is timed on is on time", function()
		-- An overcharged plane (210) ahead: the shot closes at 210 + catchUp, not at its base speed minus 210.
		local w = newWorld({ "player:2", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9, "plane", 110)
		w.add("player:2", Vector3.new(0, 12, -300), nil, "plane", 210)
		w.engine.hooks.spawnMissile("bot:9", M1, 1)
		local seen: { { t: number, eta: number } } = {}
		local hitAt: number? = nil
		local count = 0
		w.run(T.lockedLifetime, function(world: any)
			local warns = world.warnsFor("player:2")
			for i = count + 1, #warns do
				local p = warns[i]
				if type(p.eta) == "number" and p.eta > 0 then
					table.insert(seen, { t = world.t, eta = p.eta })
				end
			end
			count = #warns
			if hitAt == nil and h.count(world.sent, "player:2:hit") > 0 then
				hitAt = world.t
			end
		end)
		h.ok(hitAt ~= nil, "caught")
		local checked = 0
		for _, s in seen do
			local left = (hitAt :: number) - s.t
			if left >= 0.4 and left <= 1.2 then
				checked += 1
				h.ok(math.abs(s.eta - left) <= 0.2, string.format("eta %.2f vs %.2f to go", s.eta, left))
			end
		end
		h.ok(checked >= 1, "warned in the last second")
	end)

	h.test("a plane that rolls as the beeps trill dodges: the shot overshoots, DODGED!, no hit", function()
		local w = newWorld({ "player:2", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:2", Vector3.new(0, 12, -330))
		w.engine.hooks.spawnMissile("bot:9", M1, 1)
		local rolled = false
		w.run(3, function(world: any)
			if rolled then
				return
			end
			local warns = world.warnsFor("player:2")
			local last = warns[#warns]
			if last and last.eta >= 0 and last.eta <= 0.4 then
				world.rolls["player:2"] = world.t -- ItemService accepted the client's "Roll" now
				rolled = true
			end
		end)
		h.ok(rolled, "a warning came inside the window")
		h.eq(w.sent, {}, "no hit")
		h.eq(#w.fxNamed("dodge"), 1, "the dodge is shown to everyone")
		local dodged = 0
		for _, p in w.warnsFor("player:2") do
			if p.dodged then
				dodged += 1
				h.eq(p.how, "roll")
			end
		end
		h.eq(dodged, 1, "one DODGED!")
		h.eq((w.engine.counts()), 0, "the overshoot fizzled")
		h.eq(w.logged("dodged racer=player:2 shot_by=bot:9 how=roll"), 1)
	end)

	h.test("a roll too early, one before the shot left, or a car's roll does not save you", function()
		local early = newWorld({ "player:2", "bot:9" })
		early.add("bot:9", Vector3.new(0, 12, 0), 9)
		early.add("player:2", Vector3.new(0, 12, -330))
		early.rolls["player:2"] = early.t - 0.1 -- before the shot
		early.engine.hooks.spawnMissile("bot:9", M1, 1)
		early.run(3)
		h.eq(early.sent, { "player:2:hit" }, "a standing roll from before the shot")

		local soon = newWorld({ "player:2", "bot:9" })
		soon.add("bot:9", Vector3.new(0, 12, 0), 9)
		soon.add("player:2", Vector3.new(0, 12, -330))
		soon.engine.hooks.spawnMissile("bot:9", M1, 1)
		soon.t += 0.05
		soon.rolls["player:2"] = soon.t -- right after launch, a second before contact
		soon.run(3)
		h.eq(soon.sent, { "player:2:hit" }, "the roll was over long before contact")

		local car = newWorld({ "player:2", "bot:9" })
		car.add("bot:9", Vector3.new(0, 3, 0), 9, "car")
		car.add("player:2", Vector3.new(0, 3, -330), nil, "car")
		car.engine.hooks.spawnMissile("bot:9", M1, 1)
		car.run(3, function(world: any)
			world.rolls["player:2"] = world.t -- a forged roll from a car client
		end)
		h.eq(car.sent, { "player:2:hit" }, "cars cannot roll a shot off")
	end)

	h.test("a dragged trap blocks the shot and is spent; a shield never spends it", function()
		local w = newWorld({ "player:2", "player:1" })
		w.add("player:1", Vector3.new(0, 3, 0), nil, "car")
		w.add("player:2", Vector3.new(0, 3, -250), nil, "car")
		w.drags["player:2"] = true
		w.engine.hooks.spawnMissile("player:1", M1, 1)
		w.run(3)
		h.eq(w.sent, { "player:1:blocked" }, "no hit; the shooter hears BLOCKED!")
		h.eq(w.drags["player:2"], nil, "the trap is spent")
		local b = w.fxNamed("blocked")
		h.eq(#b, 1)
		h.eq(b[1].trap, true)
		local told = false
		for _, p in w.warnsFor("player:2") do
			if p.blocked then
				told = true
				h.eq(p.how, "trap")
			end
		end
		h.ok(told, "the blocker hears BLOCKED!")

		local s = newWorld({ "player:2", "player:1" })
		s.add("player:1", Vector3.new(0, 3, 0), nil, "car")
		s.add("player:2", Vector3.new(0, 3, -250), nil, "car")
		s.drags["player:2"] = true
		s.shielded["player:2"] = true
		s.engine.hooks.spawnMissile("player:1", M1, 1)
		s.run(3)
		h.eq(s.drags["player:2"], true, "the shield took it; the trap is still held")
	end)

	h.test("bots evade on their dice: a plane bot rolls, a car bot blocks; a failed throw is a hit", function()
		local p = newWorld({ "bot:5", "player:1" })
		p.add("player:1", Vector3.new(0, 12, 0))
		p.add("bot:5", Vector3.new(0, 12, -250), 5, "plane")
		p.dice = 0
		p.engine.hooks.spawnMissile("player:1", M1, 1)
		p.run(3)
		h.eq(p.sent, {}, "the plane bot rolled it off")
		h.eq(#p.fxNamed("dodge"), 1)

		local c = newWorld({ "bot:5", "player:1" })
		c.add("player:1", Vector3.new(0, 3, 0), nil, "car")
		c.add("bot:5", Vector3.new(0, 3, -250), 5, "car")
		c.dice = 0
		c.engine.hooks.spawnMissile("player:1", M1, 1)
		c.run(3)
		h.eq(c.sent, { "player:1:blocked" }, "the car bot blocked it")

		local f = newWorld({ "bot:5", "player:1" })
		f.add("player:1", Vector3.new(0, 12, 0))
		f.add("bot:5", Vector3.new(0, 12, -250), 5, "plane")
		f.dice = 0.99
		f.engine.hooks.spawnMissile("player:1", M1, 1)
		f.run(3)
		h.eq(f.sent, { "bot5:hit" }, "the dice failed: hit")
	end)

	h.test("a volley moves on to the next racer once its first target spins", function()
		local w = newWorld({ "player:3", "player:2", "player:1" })
		w.add("player:1", Vector3.new(0, 12, 0))
		w.add("player:2", Vector3.new(0, 12, -120))
		w.add("player:3", Vector3.new(10, 12, -260))
		w.engine.hooks.spawnMissile("player:1", M3, 3)
		w.run(6)
		h.eq(h.count(w.sent, "player:2:hit"), 1, "the nearest is stunned once")
		h.eq(h.count(w.sent, "player:3:hit"), 1, "the rest of the volley goes on to the next racer")
		h.eq((w.engine.counts()), 0, "every shot spent or expired")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- Bot salvo fairness (MK-style): a bot's level-3 volley spreads over the racers ahead, not all on the player
	------------------------------------------------------------------------------------------------------------------

	h.test("pickTarget taken: fewest shots first, then the nearest; no taken table = the plain nearest pick", function()
		local c = {
			{ id = "a", progress = 150, active = true },
			{ id = "b", progress = 250, active = true },
			{ id = "c", progress = 350, active = true },
		}
		h.eq(MissileRules.pickTarget("me", 100, c), "a")
		h.eq(MissileRules.pickTarget("me", 100, c, nil, nil, {}), "a", "nothing taken yet: nearest")
		h.eq(MissileRules.pickTarget("me", 100, c, nil, nil, { a = 1 }), "b")
		h.eq(MissileRules.pickTarget("me", 100, c, nil, nil, { a = 1, b = 1 }), "c")
		h.eq(MissileRules.pickTarget("me", 100, c, nil, nil, { a = 1, b = 1, c = 1 }), "a", "all even: back to the nearest")
		h.eq(MissileRules.pickTarget("me", 100, { c[1] }, nil, nil, { a = 5 }), "a", "one racer ahead: they all go there")
		local sp = { { id = "spin", progress = 150, active = true, targetable = false }, { id = "b", progress = 250, active = true } }
		h.eq(MissileRules.pickTarget("me", 100, sp, nil, nil, { b = 3 }), "b", "a racer that can be hit still beats one that cannot")
	end)

	h.test("a bot's salvo is spread: every racer ahead is hit, not only the nearest (the player)", function()
		local w = newWorld({ "bot:6", "bot:5", "bot:4", "player:1" })
		w.add("bot:6", Vector3.new(0, 12, 0), 6)
		w.add("player:1", Vector3.new(0, 12, -120))
		w.add("bot:4", Vector3.new(6, 12, -200), 4)
		w.add("bot:5", Vector3.new(-6, 12, -280), 5)
		w.engine.hooks.spawnMissile("bot:6", M3, 3)
		w.run(7)
		h.ok(h.count(w.sent, "player:1:hit") >= 1, "the player is shot")
		h.ok(h.count(w.sent, "bot4:hit") >= 1, "the second racer is shot too")
		h.ok(h.count(w.sent, "bot5:hit") >= 1, "and the third")
		h.eq((w.engine.counts()), 0, "every shot spent or expired")
	end)

	h.test("a bot's salvo with one racer ahead still goes at that racer", function()
		local w = newWorld({ "bot:6", "player:1" })
		w.add("bot:6", Vector3.new(0, 12, 0), 6)
		w.add("player:1", Vector3.new(0, 12, -150))
		w.engine.hooks.spawnMissile("bot:6", M3, 3)
		w.run(3)
		h.eq(h.count(w.sent, "player:1:hit"), 1, "stunned once; the rest fizzle on the spinning target")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- ItemService: Drag and Roll
	------------------------------------------------------------------------------------------------------------------

	local function newService(): (any, any)
		local w = { t = 100, logs = {}, drags = {}, published = {} }
		local hooks = ItemService.loggingHooks(function() end) :: any
		hooks.dragTrap = function(racerId: string, on: boolean)
			table.insert(w.drags, racerId .. ":" .. tostring(on))
		end
		local svc = ItemService.new({
			now = function(): number
				return w.t
			end,
			racerPosition = function(): any
				return Vector3.zero
			end,
			findPod = function(name: string): any
				return { position = Vector3.zero, podType = name, respawnSeconds = 1 }
			end,
			publish = function(racerId: string, state: any)
				w.published[racerId] = state
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
		} :: any, hooks)
		return svc, w
	end

	h.test("Drag needs a held trap, shows it, and the next Use drops it; consumeDrag spends it", function()
		local svc, w = newService()
		h.eq({ svc.handleRemote("player:1", "Drag") }, { false, "not_trap" }, "nothing held")
		h.ok(svc.requestPickup("player:1", "Green"), "trap picked up")
		h.ok((svc.handleRemote("player:1", "Drag")), "dragging")
		h.ok(svc.isDragging("player:1"))
		h.eq(w.drags, { "player:1:true" })
		h.ok(ItemRules.isHolding(svc.getState("player:1")), "a dragged trap is still held")
		w.t += 1
		h.ok((svc.handleRemote("player:1", "Use")), "the release drops it")
		h.ok(not svc.isDragging("player:1"))
		h.eq(w.drags, { "player:1:true", "player:1:false" })

		w.t += 5
		h.ok(svc.requestPickup("player:1", "Green"))
		svc.handleRemote("player:1", "Drag")
		h.ok(svc.consumeDrag("player:1"), "a missile ate it")
		h.ok(not ItemRules.isHolding(svc.getState("player:1")), "spent")
		h.ok(not svc.consumeDrag("player:1"), "only once")
		h.eq(w.drags[#w.drags], "player:1:false")

		w.t += 5
		h.ok(svc.requestPickup("player:1", "Red"))
		h.eq({ svc.handleRemote("player:1", "Drag") }, { false, "not_trap" }, "only a trap drags")
	end)

	h.test("Roll reports are rate limited on the server clock", function()
		local svc, w = newService()
		h.eq(svc.lastRoll("player:1"), nil)
		h.ok((svc.handleRemote("player:1", "Roll")))
		h.eq(svc.lastRoll("player:1"), w.t)
		local first = w.t
		w.t += 0.3
		h.ok(not (svc.handleRemote("player:1", "Roll")), "a second roll 0.3 s later is ignored")
		h.eq(svc.lastRoll("player:1"), first)
		w.t += T.rollMinInterval
		h.ok((svc.handleRemote("player:1", "Roll")))
		h.eq({ svc.handleRemote("player:1", "Fly") }, { false, "bad_action" }, "anything else is still refused")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- v6 minor D3 (salvo leftovers retarget or fizzle, never a wall) and D4 (lock range at fire time)
	------------------------------------------------------------------------------------------------------------------

	h.test("D3 pure: strict pick skips a spinning racer; lostTargetFate retargets or fizzles", function()
		local v = {
			{ id = "spinning", progress = 150, active = true, targetable = false },
			{ id = "next", progress = 300, active = true },
		}
		h.eq(MissileRules.pickTarget("me", 100, v, nil, true), "next")
		h.eq(MissileRules.pickTarget("me", 100, { v[1] }, nil, true), nil, "only a spinning racer ahead: strict finds nobody")
		h.eq(MissileRules.pickTarget("me", 100, { v[1] }), "spinning", "the fire-time pick is unchanged")
		h.eq(MissileRules.lostTargetFate("next"), "retarget")
		h.eq(MissileRules.lostTargetFate(nil), "fizzle")
	end)

	h.test("D3: a level-3 salvo moves on to the next racer ahead once its target is spinning, no wall blasts", function()
		local w = newWorld({ "bot:5", "bot:4", "player:1" })
		w.add("player:1", Vector3.new(0, 12, 0))
		w.add("bot:4", Vector3.new(0, 12, -150), 4) -- nearest: the volley's first target
		w.add("bot:5", Vector3.new(0, 12, -330), 5) -- the next one ahead, inside lock range of the shots
		w.engine.hooks.spawnMissile("player:1", M3, 3)
		w.run(4)
		h.ok(h.count(w.sent, "bot4:hit") >= 1, "the first target is hit")
		h.ok(h.count(w.sent, "bot5:hit") >= 1, "leftover shots retarget the next racer ahead")
		h.eq(#w.fxNamed("explode"), h.count(w.sent, "bot4:hit") + h.count(w.sent, "bot5:hit"), "every blast is a racer hit")
		for _, e in w.fxNamed("explode") do
			h.ok(e.wall ~= true, "no wall blast")
		end
		h.eq((w.engine.counts()), 0, "nothing left flying")
	end)

	h.test("D3: with nobody else ahead the leftover salvo fizzles in the air once the target is hit", function()
		local w = newWorld({ "bot:4", "player:1" })
		w.add("player:1", Vector3.new(0, 12, 0))
		w.add("bot:4", Vector3.new(0, 12, -150), 4)
		w.engine.hooks.spawnMissile("player:1", M3, 3)
		w.run(1.0)
		h.eq(h.count(w.sent, "bot4:hit"), 1, "one hit, the target is spinning for the rest")
		local _, _, queued = w.engine.counts()
		w.run(0.3)
		local flying = w.engine.counts()
		h.ok(flying <= 1, "the leftovers fizzled instead of flying on")
		w.run(4)
		h.eq((w.engine.counts()), 0)
		h.eq(h.count(w.sent, "bot4:hit"), 1, "a spinning racer is not hit again")
		h.ok(#w.fxNamed("fizzle") >= 1, "the leftovers fizzle visibly (fx), never vanish silently")
		for _, e in w.fxNamed("explode") do
			h.ok(e.wall ~= true, "no wall blast")
		end
		h.ok(queued ~= nil)
	end)

	h.test("D4: a racer just inside lockRange by course progress is locked at fire time, just outside is not", function()
		local c = { { id = "bot", progress = 100 + T.lockRange, active = true } }
		h.eq(MissileRules.pickTarget("me", 100, c), "bot", "exactly lockRange ahead is in reach")
		c[1].progress = 100 + T.lockRange + 0.5
		h.eq(MissileRules.pickTarget("me", 100, c), nil)
		for _, gap in { 350, 385, 420, 599 } do
			local w = newWorld({ "bot:6", "player:1" })
			w.add("player:1", Vector3.new(0, 12, 0))
			w.add("bot:6", Vector3.new(30, 12, -gap), 6) -- a QA-placed bot, another lane
			w.engine.hooks.spawnMissile("player:1", M3, 3)
			h.eq(w.logged("count=10 target=bot:6"), 1, "gap " .. gap .. " locks the bot")
		end
		local w = newWorld({ "bot:6", "player:1" })
		w.add("player:1", Vector3.new(0, 12, 0))
		w.add("bot:6", Vector3.new(0, 12, -(T.lockRange + 5)), 6)
		w.engine.hooks.spawnMissile("player:1", M3, 3)
		h.eq(w.logged("count=10 target=none"), 1, "just outside lockRange: no lock")
	end)

	h.test("D4: a free shooter (off the course line) still locks a racer 350-420 ahead", function()
		h.eq(MissileRules.freeLock(nil, "bot:6"), "bot:6", "no one in the 320-stud cone: the progress lock stands")
		h.eq(MissileRules.freeLock("bot:2", "bot:6"), "bot:2", "a racer in the cone wins")
		h.eq(MissileRules.freeLock(nil, nil), nil)
		local w = newWorld({ "bot:6", "player:1" })
		w.add("player:1", Vector3.new(200, 12, 0)) -- far outside the corridor: off the line
		w.add("bot:6", Vector3.new(0, 12, -400), 6)
		w.engine.hooks.spawnMissile("player:1", M2, 2)
		h.eq(w.logged("missile free racer=player:1"), 1, "the shot is free")
		h.eq(w.logged("level=2 count=1 target=bot:6"), 1, "the fire-time lock is reported")
		w.run(4)
		h.eq(h.count(w.sent, "bot6:hit"), 1, "the free shot curves onto the racer 400 ahead (old cone range 320: no target)")
	end)
end
