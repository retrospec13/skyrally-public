--!strict
-- Lune spec for REMARKABLE Batch 2 items 14, 18 and 19 (the pure and server sides; bubbles, beeps and soot are Studio
-- checks):
--   14. ItemRules.incomingEta / beepInterval / beepPitch; kit/ItemEffects' 5 Hz incoming scan: an unguided shot warns
--       the player in its lane (ETA falling), not one in another lane; a homing shot warns only its target; a shield
--       or a post-hit grace silences it; a close call that then changes lanes gets {dodged = true}; a hit is never a
--       dodge, not even for the rest of a volley.
--   18. The grudge book (hit -> revenge -> re-revenge -> feud, the window, own traps), ItemService.noteHit telling
--       both players with display names only, lastHitBy in the state, the hit listener, reset; the explode broadcast
--       carrying no comic word.
--   19. BotPersonality: every personality has at least two lines per bucket, lines are short and never repeat back to
--       back, the rate limits, {name} filling, rival rotation. (The rival's rubber band: tools/tests/rival_band_spec.luau.)
-- Run: tools/tests/run_lune_tests.sh tools/tests/getting_even_spec.luau

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
	local ItemService = h.require("src/server/ItemService.luau")
	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
	local BotPersonality = h.require("src/shared/BotPersonality.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")

	local MISSILE1 = ItemRules.effectFor("red", 1).missile
	local MISSILE2 = ItemRules.effectFor("red", 2).missile
	local MISSILE3 = ItemRules.effectFor("red", 3).missile
	-- Missile v3 locks every level on the racer ahead; the unlocked course shot (what a shot with nobody ahead in reach
	-- flies) keeps its own lane rules, proven here with the v2 level-one shot.
	local UNGUIDED1 = table.clone(MISSILE1) :: any
	UNGUIDED1.homing = false
	UNGUIDED1.turnRateDeg = 0
	local INC = ItemRules.INCOMING
	local NORTH = Vector3.new(0, 0, -1)

	local function near(a: number, b: number, tol: number, msg: string)
		h.ok(math.abs(a - b) <= tol, string.format("%s: expected %.3f +- %.3f, got %.3f", msg, b, tol, a))
	end

	---------------------------------------------------------------- pure rules (items 14 and 18)

	h.test("14: incomingEta is gap / closing, nil behind, too slow or too far", function()
		near(ItemRules.incomingEta(140, 140) :: number, 1.0, 1e-9, "1 s out")
		h.eq(ItemRules.incomingEta(0, 140), nil, "level with the racer")
		h.eq(ItemRules.incomingEta(-20, 140), nil, "behind the racer")
		h.eq(ItemRules.incomingEta(50, INC.minClosing - 1), nil, "pacing, not closing")
		h.eq(ItemRules.incomingEta(140 * (INC.warnSeconds + 0.1), 140), nil, "further out than the warning")
		h.ok(ItemRules.incomingEta(140 * INC.warnSeconds, 140) ~= nil, "right at the edge")
	end)

	h.test("14: beeps speed up and rise in pitch as the shot closes", function()
		near(ItemRules.beepInterval(INC.warnSeconds), 0.5, 1e-9, "slow at the edge")
		near(ItemRules.beepInterval(0.25), 0.07, 1e-9, "a trill on impact")
		near(ItemRules.beepInterval(0), 0.07, 1e-9, "never faster than the trill")
		local prevI, prevP = math.huge, 0
		for i = 25, 0, -1 do
			local eta = i / 10
			local iv, p = ItemRules.beepInterval(eta), ItemRules.beepPitch(eta)
			h.ok(iv <= prevI + 1e-12, "interval never grows as it closes")
			h.ok(p >= prevP - 1e-12, "pitch never falls as it closes")
			prevI, prevP = iv, p
		end
		h.ok(ItemRules.beepPitch(1, true) > ItemRules.beepPitch(1, false), "a homing lock beeps higher")
	end)

	h.test("18: grudges: hit, REVENGE, RE-REVENGE, a feud; the window closes; own traps are self hits", function()
		local book = ItemRules.newGrudgeBook()
		h.eq({ ItemRules.recordHit(book, "player:1", "bot:2", 10) }, { "hit", 0 }, "first hit")
		h.eq(ItemRules.grudgeOf(book, "player:1", 11).by, "bot:2", "player 1 owes bot 2")
		h.eq({ ItemRules.recordHit(book, "bot:2", "player:1", 20) }, { "revenge", 1 }, "paid back")
		h.eq(ItemRules.grudgeOf(book, "player:1", 21), nil, "the debt is settled")
		h.eq({ ItemRules.recordHit(book, "player:1", "bot:2", 30) }, { "revenge", 2 }, "answered: re-revenge")
		h.eq({ ItemRules.recordHit(book, "bot:2", "player:1", 40) }, { "revenge", 3 }, "a feud")
		h.eq(ItemRules.revengeLabel(1), "EVEN")
		h.eq(ItemRules.revengeLabel(2), "EVEN x2")
		h.eq(ItemRules.revengeLabel(3), "EVEN x3")
		-- The window: bot 2 now owes player 1, but waits too long.
		h.eq({ ItemRules.recordHit(book, "player:1", "bot:2", 40 + ItemRules.REVENGE_WINDOW + 1) }, { "hit", 0 }, "too late is just a hit")
		-- A third racer: the newest attacker is the one you owe.
		local b2 = ItemRules.newGrudgeBook()
		ItemRules.recordHit(b2, "player:1", "bot:2", 0)
		ItemRules.recordHit(b2, "player:1", "bot:3", 1)
		h.eq({ ItemRules.recordHit(b2, "bot:2", "player:1", 2) }, { "hit", 0 }, "bot 2 is no longer the one owed")
		h.eq({ ItemRules.recordHit(b2, "bot:3", "player:1", 3) }, { "revenge", 1 }, "bot 3 is")
		h.eq({ ItemRules.recordHit(b2, "player:1", "player:1", 4) }, { "self", 0 }, "own trap")
	end)

	h.test("18: no comic hit word comes out of the rules; names are cut for the plank", function()
		h.eq((ItemRules :: any).comicWord, nil, "the comic word function is gone")
		h.eq((ItemRules :: any).COMIC_WORDS, nil, "the comic word table is gone")
		local banned = { "BONK", "BOINK", "DOINK", "OOPS", "WHAM", "POW", "REVENGE", "!" }
		for chain = 0, 4 do
			local label = string.upper(ItemRules.revengeLabel(chain))
			for _, w in banned do
				h.ok(not string.find(label, w, 1, true), "revengeLabel has no " .. w)
			end
		end
		h.eq(ItemRules.shortName("Ace Aero", 14), "Ace Aero")
		h.eq(ItemRules.shortName("AVeryVeryLongDisplayName", 10), "AVeryVery.")
		h.eq(ItemRules.shortName(nil, 10), "SOMEONE")
	end)

	---------------------------------------------------------------- ItemService (item 18)

	type SvcWorld = { t: number, told: { { racer: string, event: string, payload: any } }, published: { [string]: any }, logs: { string } }

	local function newService(): (any, SvcWorld)
		local w: SvcWorld = { t = 100, told = {}, published = {}, logs = {} }
		local names: { [string]: string } = { ["player:1"] = "Sky Pilot", ["player:7"] = "Zoom", ["bot:2"] = "Blaze Wing" }
		local svc = ItemService.new({
			now = function(): number
				return w.t
			end,
			racerPosition = function(): any
				return Vector3.zero
			end,
			findPod = function(): any
				return nil
			end,
			publish = function(racerId: string, state: any)
				w.published[racerId] = state
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			displayName = function(racerId: string): string
				return names[racerId] or racerId
			end,
			notify = function(racerId: string, event: string, payload: any)
				table.insert(w.told, { racer = racerId, event = event, payload = payload })
			end,
		}, ItemService.loggingHooks(function() end))
		return svc, w
	end

	h.test("18: noteHit tells both players by display name, bots get nothing, the state carries lastHitBy", function()
		local svc, w = newService()
		h.eq({ svc.noteHit("player:1", "bot:2", "missile") }, { "hit", 0 })
		h.eq(#w.told, 1, "only the player is told (a bot has no client)")
		local p = w.told[1]
		h.eq(p.racer, "player:1")
		h.eq(p.event, "ItemGrudge")
		h.eq(p.payload.role, "victim")
		h.eq(p.payload.name, "Blaze Wing", "the bot's roster name")
		h.eq(p.payload.other, "bot:2", "the live world swaps this for the vehicle")
		h.eq(svc.getState("player:1").lastHitBy, "bot:2", "ItemState carries the attacker id")
		w.t += 5
		h.eq({ svc.noteHit("bot:2", "player:1", "missile") }, { "revenge", 1 })
		local last = w.told[#w.told]
		h.eq(last.payload.role, "attacker")
		h.eq(last.payload.kind, "revenge")
		h.eq(last.payload.name, "Blaze Wing")
		h.eq(svc.getState("player:1").lastHitBy, nil, "paid back: no open grudge")
		-- Player on player: both are told, each with the other's display name.
		table.clear(w.told)
		svc.noteHit("player:7", "player:1", "trap")
		h.eq(#w.told, 2)
		for _, t in w.told do
			if t.racer == "player:1" then
				h.eq(t.payload.role, "attacker")
				h.eq(t.payload.name, "Zoom")
			else
				h.eq(t.payload.role, "victim")
				h.eq(t.payload.name, "Sky Pilot")
			end
		end
		-- Own trap: one OOPS.
		table.clear(w.told)
		h.eq({ svc.noteHit("player:1", "player:1", "trap") }, { "self", 0 })
		h.eq(#w.told, 1)
		h.eq(w.told[1].payload.role, "self")
		-- Reset clears every grudge.
		svc.resetAll()
		h.eq(svc.getState("player:7").lastHitBy, nil, "reset clears grudges")
	end)

	h.test("18: module-level noteHit runs the hit listener (a listener error never escapes); sendIncoming reaches the player", function()
		local svc, w = newService()
		local prev = ItemService.active
		ItemService.active = svc
		local heard = {}
		ItemService.setHitListener(function(victim: string, attacker: string, kind: string, chain: number)
			table.insert(heard, string.format("%s<%s:%s:%d", victim, attacker, kind, chain))
		end)
		ItemService.noteHit("bot:2", "player:1", "missile")
		h.eq(heard, { "bot:2<player:1:hit:0" })
		ItemService.setHitListener(function()
			error("boom")
		end)
		h.eq({ ItemService.noteHit("player:1", "bot:2", "missile") }, { "revenge", 1 }, "still classified")
		ItemService.sendIncoming("player:1", { eta = 1.2, homing = false, count = 1 })
		ItemService.sendIncoming("bot:2", { eta = 1.2 })
		local incoming = 0
		for _, t in w.told do
			if t.event == "IncomingItem" then
				incoming += 1
				h.eq(t.racer, "player:1", "only players get warnings")
			end
		end
		h.eq(incoming, 1)
		ItemService.setHitListener(nil)
		ItemService.active = prev
	end)

	---------------------------------------------------------------- ItemEffects (items 14 and 18)

	type FxWorld = {
		t: number,
		racers: { [string]: any },
		order: { string },
		warns: { { racer: string, payload: any } },
		fx: { { name: string, payload: any } },
		sent: { string },
		shielded: { [string]: boolean },
		engine: any,
		svc: any,
		add: (string, Vector3, number?) -> (),
		move: (string, Vector3) -> (),
		run: (number) -> (),
		warnsFor: (string) -> { any },
		fxNamed: (string) -> { any },
	}

	-- Course along -Z at y = 0; racers fly 12 over it. order: leader first.
	local function newFx(order: { string }): FxWorld
		local w: FxWorld = { t = 100, racers = {}, order = order, warns = {}, fx = {}, sent = {}, shielded = {} } :: any
		function w.add(id: string, pos: Vector3, botId: number?)
			w.racers[id] = { pos = pos, forward = NORTH, station = -pos.Z, progress = -pos.Z, active = true, isPlayer = botId == nil, botId = botId, plane = "Model_" .. id }
		end
		function w.move(id: string, pos: Vector3)
			local r = w.racers[id]
			r.pos = pos
			r.station = -pos.Z
			r.progress = -pos.Z
		end
		local svc = newService()
		w.svc = svc
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
			log = function() end,
			noteHit = function(victim: string, attacker: string, source: string): (string, number)
				return svc.noteHit(victim, attacker, source)
			end,
			warnIncoming = function(id: string, payload: any)
				table.insert(w.warns, { racer = id, payload = payload })
			end,
		}
		w.engine = ItemEffects.new(ctx :: any)
		function w.run(seconds: number)
			for _ = 1, math.floor(seconds * 30 + 0.5) do
				w.t += 1 / 30
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
		return w
	end

	h.test("14: an unguided shot warns the player in its lane with a falling ETA, then the hit ends it (no dodge)", function()
		local w = newFx({ "player:1", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:1", Vector3.new(0, 12, -330))
		w.engine.hooks.spawnMissile("bot:9", UNGUIDED1, 1)
		w.run(0.45)
		local warns = w.warnsFor("player:1")
		h.ok(#warns >= 1, "warned within a tick or two")
		local first = warns[1]
		h.ok(first.eta > 0 and first.eta <= INC.warnSeconds, "a real ETA: " .. tostring(first.eta))
		h.eq(first.homing, false)
		w.run(1.5)
		h.eq(w.sent, { "player:1:hit" }, "it lands")
		local etas: { number } = {}
		local dodged = false
		for _, p in w.warnsFor("player:1") do
			if p.eta >= 0 then
				table.insert(etas, p.eta)
			elseif p.dodged then
				dodged = true
			end
		end
		h.ok(#etas >= 3, "beeping all the way in")
		for i = 2, #etas do
			h.ok(etas[i] <= etas[i - 1] + 0.05, "the ETA only falls")
		end
		h.ok(not dodged, "a hit is not a dodge")
		local blasts = w.fxNamed("explode")
		h.eq(#blasts, 1)
		h.eq(blasts[1].comic, nil, "no comic word rides on the blast")
	end)

	h.test("14: a player in another lane is never warned; a shield or a spin-out silences the beeps", function()
		local w = newFx({ "player:1", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:1", Vector3.new(INC.laneRadius + 10, 12, -330))
		w.engine.hooks.spawnMissile("bot:9", UNGUIDED1, 1)
		w.run(2)
		h.eq(#w.warnsFor("player:1"), 0, "another lane: no panic")
		h.eq(w.sent, {}, "and no hit")
		local s = newFx({ "player:1", "bot:9" })
		s.add("bot:9", Vector3.new(0, 12, 0), 9)
		s.add("player:1", Vector3.new(0, 12, -330))
		s.shielded["player:1"] = true
		s.engine.hooks.spawnMissile("bot:9", UNGUIDED1, 1)
		s.run(2)
		h.eq(#s.warnsFor("player:1"), 0, "shielded: no beeps")
	end)

	h.test("14: a close call that changes lanes is DODGED!", function()
		local w = newFx({ "player:1", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:1", Vector3.new(0, 12, -330))
		w.engine.hooks.spawnMissile("bot:9", UNGUIDED1, 1)
		-- Wait for a warning inside the close-call ETA, then jink sideways out of the hit radius.
		local jinked = false
		for _ = 1, 90 do
			w.run(1 / 30)
			local warns = w.warnsFor("player:1")
			local last = warns[#warns]
			if last and last.eta >= 0 and last.eta <= INC.closeCallEta then
				w.move("player:1", Vector3.new(24, 12, -330))
				jinked = true
				break
			end
		end
		h.ok(jinked, "a close call happened")
		w.run(1.5)
		h.eq(w.sent, {}, "missed")
		local dodges = 0
		for _, p in w.warnsFor("player:1") do
			if p.dodged then
				dodges += 1
			end
		end
		h.eq(dodges, 1, "exactly one DODGED!")
	end)

	h.test("14: a homing shot warns only its target; a ten-shot volley that lands is never a dodge", function()
		-- Order leader first: player:3 leads, player:2 is directly ahead of the shooter bot:9.
		local w = newFx({ "player:3", "player:2", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:2", Vector3.new(0, 12, -200))
		w.add("player:3", Vector3.new(0, 12, -260))
		w.engine.hooks.spawnMissile("bot:9", MISSILE2, 2)
		w.run(0.5)
		local p2 = w.warnsFor("player:2")
		h.ok(#p2 >= 1 and p2[1].homing == true, "the target hears the lock")
		h.eq(#w.warnsFor("player:3"), 0, "the leader is not its target")
		w.run(2)
		h.contains(w.sent, "player:2:hit")

		local v = newFx({ "player:1", "bot:9" })
		v.add("bot:9", Vector3.new(0, 12, 0), 9)
		v.add("player:1", Vector3.new(0, 12, -150))
		v.engine.hooks.spawnMissile("bot:9", MISSILE3, 3)
		v.run(4)
		h.eq(h.count(v.sent, "player:1:hit"), 1, "one stun from the volley")
		for _, p in v.warnsFor("player:1") do
			h.ok(p.dodged ~= true, "the rest of a volley that hit you is not a dodge")
		end
	end)

	h.test("18: the explode broadcast says REVENGE when the victim hits back", function()
		local w = newFx({ "player:1", "bot:9" })
		w.add("bot:9", Vector3.new(0, 12, 0), 9)
		w.add("player:1", Vector3.new(0, 12, -100))
		h.eq(w.engine.hit("player:1", "bot:9", "missile", 1.2, Vector3.new(0, 12, -100)), "hit")
		w.t += 3
		h.eq(w.engine.hit("bot:9", "player:1", "missile", 1.2, Vector3.zero), "hit")
		local blasts = w.fxNamed("explode")
		h.eq(blasts[1].comic, nil)
		h.eq(blasts[2].comic, nil)
		-- A hazard is nobody's grudge: a boss hazard, or a battle hazard passing the victim as its own attacker.
		w.t += 3
		h.eq(w.engine.hit("player:1", "player:1", "cannon", 1.2, Vector3.zero), "hit")
		w.t += 3
		h.eq(w.engine.hit("player:1", "bot:9", "boss_fire", 1.2, Vector3.zero), "hit")
		blasts = w.fxNamed("explode")
		h.eq(blasts[3].comic, nil, "no comic word for a hazard")
		h.eq(blasts[4].comic, nil)
		h.eq(w.svc.getState("player:1").lastHitBy, nil, "no grudge against a boss hazard")
	end)

	---------------------------------------------------------------- BotPersonality and the rival band (item 19)

	h.test("19: every roster bot has a personality with at least two short lines per bucket", function()
		for _, cfg in PlaneConfig.AI_BOTS do
			local kind = BotPersonality.forName(cfg.name)
			h.ok(BotPersonality.KIND_OF[cfg.name] ~= nil, cfg.name .. " has a personality")
			h.ok(BotPersonality.TITLE[kind] ~= nil, kind .. " has a title")
			for _, bucket in BotPersonality.BUCKETS do
				local lines = BotPersonality.LINES[kind][bucket]
				h.ok(lines ~= nil and #lines >= 2, string.format("%s/%s has 2+ lines", kind, bucket))
				for _, line in lines do
					h.ok(#BotPersonality.format(line, "ABCDEFGHIJKL") <= 60, "bubble-sized: " .. line)
				end
			end
		end
		h.eq(BotPersonality.forName("Nobody"), BotPersonality.DEFAULT)
	end)

	h.test("19: no bot line uses toddler or onomatopoeia words (older-kid register)", function()
		local banned = { "bonk", "boop", "wheee", "oops", "hehe", "aaargh", "woo", "yay", "haha" }
		for kind, buckets in BotPersonality.LINES do
			for bucket, lines in buckets do
				for _, line in lines do
					local low = string.lower(line)
					for _, word in banned do
						h.ok(string.find(low, word, 1, true) == nil, string.format("%s/%s '%s' has '%s'", kind, bucket, line, word))
					end
				end
			end
		end
	end)

	h.test("19: rate limits: per bot, the rival's shorter gap, the global gap, urgent hits", function()
		local v = BotPersonality.newVoice()
		local always = function(): number
			return 0
		end
		h.ok(BotPersonality.decide(v, 1, "sunny", "pass", 0, false, always) ~= nil, "first line")
		h.eq(BotPersonality.decide(v, 2, "chill", "pass", 1, false, always), nil, "global gap holds another bot")
		h.ok(BotPersonality.decide(v, 2, "chill", "hitBy", 1, false, always) ~= nil, "a hit reaction is urgent")
		h.eq(BotPersonality.decide(v, 1, "sunny", "pass", 5, false, always), nil, "per-bot gap")
		h.ok(BotPersonality.decide(v, 3, "rookie", "pass", 6, true, always) ~= nil, "the rival speaks")
		h.ok(BotPersonality.decide(v, 3, "rookie", "passed", 6 + BotPersonality.RIVAL_GAP, true, always) ~= nil, "the rival's shorter gap")
		local never = function(): number
			return 0.999
		end
		h.eq(BotPersonality.decide(v, 4, "polite", "pass", 100, false, never), nil, "chance can say no")
		h.ok(BotPersonality.decide(v, 4, "polite", "pass", 100, true, never) ~= nil, "the rival always talks")
	end)

	h.test("19: a bot never repeats its last line; {name} fills, or drops cleanly", function()
		local v = BotPersonality.newVoice()
		local zero = function(): number
			return 0
		end
		local a = BotPersonality.decide(v, 1, "showboat", "pass", 0, true, zero)
		local b = BotPersonality.decide(v, 1, "showboat", "pass", 100, true, zero)
		h.ok(a ~= nil and b ~= nil and a ~= b, "different lines back to back")
		h.eq(BotPersonality.format("Good race, {name}!", "Sky Pilot"), "Good race, Sky Pilot!")
		h.eq(BotPersonality.format("Good race, {name}!", nil), "Good race!")
		h.eq(BotPersonality.format("Okay {name}, that was stylish.", nil), "Okay, that was stylish.")
		h.eq(BotPersonality.format("Hi {name}!", "100%"), "Hi 100%!", "a % in a name is plain text")
		h.eq(BotPersonality.format("Hi {name}!", "AVeryVeryLongName"), "Hi AVeryVeryLo.!")
	end)

	h.test("19: the rival rotates among the three fastest bots", function()
		local seen: { [number]: boolean } = {}
		for seq = 1, 6 do
			local r = BotPersonality.pickRival({ 5, 1, 3, 2, 4 }, seq) :: number
			h.ok(r >= 1 and r <= 3, "one of the three fastest")
			seen[r] = true
		end
		h.ok(seen[1] and seen[2] and seen[3], "each gets a turn")
		h.eq(BotPersonality.pickRival({}, 1), nil)
		h.eq(BotPersonality.pickRival({ 6 }, 4), 6)
	end)

	h.test("18: the PAYBACK tag is a toast under 1.8 s, re-popped at most once per 4 s by the same racer", function()
		local T = ItemRules.NEMESIS_TOAST
		h.ok(T.popIn + T.hold + T.fadeOut <= 1.8, "total on screen")
		local s0, a0 = ItemRules.nemesisToast(0)
		h.eq(s0, 0)
		h.eq(a0, 0)
		local sp = ItemRules.nemesisToast(T.popIn * 0.7) :: number
		h.ok(sp > 1, "overshoots on the way in")
		local sh, ah = ItemRules.nemesisToast(T.popIn + T.hold * 0.5)
		h.eq(sh, 1)
		h.eq(ah, 0)
		local _, af = ItemRules.nemesisToast(T.popIn + T.hold + T.fadeOut * 0.5)
		near(af :: number, 0.5, 1e-6, "half faded")
		h.eq(ItemRules.nemesisToast(T.popIn + T.hold + T.fadeOut), nil)
		h.eq(ItemRules.nemesisToast(60), nil)
		h.eq(ItemRules.nemesisRepop(true, 1), false)
		h.eq(ItemRules.nemesisRepop(true, 4), true)
		h.eq(ItemRules.nemesisRepop(false, 0.1), true)
	end)
end
