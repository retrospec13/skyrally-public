--!strict
-- First-time explainers beyond racing (T1-15, PO-06): src/shared/ExplainerRules.luau (topics, once-only, skip), the three new
-- NotifySpec rows, the saved settings + replicated attributes in SaveService, and static checks that the client queues them
-- once at a calm hub moment and the server validates the answer. Run: tools/tests/run_lune_tests.sh tools/tests/explainer_spec.luau
return function(h)
	local R = h.require("src/shared/ExplainerRules.luau")
	local Spec = h.require("src/shared/NotifySpec.luau")
	local SaveService = h.require("src/server/SaveService.luau")

	h.test("topics: items, keys, battles, tokens, garage, each with a NotifySpec modal row", function()
		local ids = {}
		for _, t in R.TOPICS do
			table.insert(ids, t.id)
			local row = Spec.get(t.row)
			h.ok(row ~= nil, t.row)
			h.eq((row :: any).surface, "modal")
			h.eq(R.topicForRow(t.row), t.id)
			h.eq(R.rowOf(t.id), t.row)
		end
		h.eq(ids, { "items", "keys", "battles", "tokens", "garage" })
		h.eq(R.topicForRow("badge_earned"), nil)
		h.eq(R.rowOf("nope"), nil)
		h.ok(R.isId("garage") and not R.isId("Garage") and not R.isId(5) and not R.isId(nil))
	end)

	h.test("copy: the new cards are brief (3 lines, 40 characters, 16 character title), skippable, no comic words", function()
		for _, row in { "item_first_explain", "token_first_explain", "garage_first_explain" } do
			local r: any = Spec.get(row)
			h.eq(r.close, "Skip tips", row)
			h.eq(r.primary, "Got it", row)
			h.ok(#r.title <= R.MAX_TITLE, row .. " title")
			local n = 0
			for line in string.gmatch(r.copy, "[^\n]+") do
				n += 1
				h.ok(#line <= R.MAX_LINE, row .. " line too long: " .. line)
			end
			h.ok(n <= R.MAX_LINES and n >= 2, row .. " lines")
			h.ok(not string.find(r.copy, "!"), row .. " is informational, not a toddler shout")
			h.eq(#r.vars, 0)
		end
	end)

	h.test("once-only: due until seen; seen stays seen; skip-all and unknown ids are never due", function()
		h.ok(R.due("items", {}, false))
		h.ok(not R.due("items", { items = true }, false))
		h.ok(R.due("tokens", { items = true }, false), "another topic is unaffected")
		h.ok(not R.due("tokens", {}, true), "skip tips turns every topic off")
		h.ok(not R.due("nope", {}, false))
		h.ok(not R.due(nil, {}, false))
		h.ok(not R.due("battles", {}, false, true), "the legacy BattleIntroSeen flag counts as seen")
		h.ok(R.due("battles", {}, false, false))
		h.ok(R.due("keys", {}, false, true), "the legacy flag only concerns battles")
	end)

	h.test("apply: an answer marks one topic; a repeat is not a change; skip marks everything", function()
		local s: any = {}
		h.ok(R.apply(s, "items", false))
		h.eq(s.ex_items, true)
		h.eq(s.ex_tokens, nil)
		h.eq(s.ex_skip, nil)
		h.ok(not R.apply(s, "items", false), "equal answer: no save")
		h.ok(not R.apply(s, "bogus", false) and s.ex_bogus == nil)
		h.ok(R.apply(s, "tokens", true))
		h.eq(s.ex_skip, true)
		for _, t in R.TOPICS do
			h.eq(s["ex_" .. t.id], true, t.id)
		end
		h.ok(not R.apply(s, "garage", true))
		local seen, skip = R.read(s)
		h.eq(skip, true)
		h.ok(not R.due("garage", seen, skip))
	end)

	h.test("read/encode/decode: a bad or missing table reads as nothing seen; the attribute text round-trips and drops junk", function()
		local seen, skip = R.read(nil)
		h.eq(next(seen), nil)
		h.eq(skip, false)
		local s2, k2 = R.read({ ex_items = "yes", ex_keys = true, ex_skip = 1 })
		h.eq(s2, { keys = true })
		h.eq(k2, false)
		h.eq(R.encode({ garage = true, items = true }), "items,garage", "topic order, not insertion order")
		h.eq(R.decode("items,garage,evil,,"), { items = true, garage = true })
		h.eq(R.decode(nil), {})
		h.eq(R.decode(42), {})
	end)

	h.test("triggers: item pickup, first token, garage after the first race", function()
		h.ok(R.itemTrigger("", "Red"))
		h.ok(R.itemTrigger(nil, "Red"))
		h.ok(not R.itemTrigger("Red", "Blue"), "swapping items is not a first pickup")
		h.ok(not R.itemTrigger("Red", ""))
		h.ok(not R.itemTrigger("", ""))
		h.ok(R.tokenTrigger(0, 1))
		h.ok(not R.tokenTrigger(nil, 1), "the first value is a baseline")
		h.ok(not R.tokenTrigger(2, 2))
		h.ok(not R.tokenTrigger(2, 1))
		h.ok(R.garageTrigger(true, true))
		h.ok(not R.garageTrigger(true, false), "not before the first race started")
		h.ok(not R.garageTrigger(false, true), "not while the Garage is off")
		h.ok(not R.garageTrigger(nil, nil))
	end)

	h.test("save: the answer is stored in settings, replicated as Explained / ExplainSkip, survives a rejoin and never touches progression", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local function service(session: string): any
			return SaveService.new({
				store = SaveService.newMemoryStore(backing),
				sessionId = session,
				newToken = function(): string
					return session .. "-tok"
				end,
				now = sched.clock,
				clock = sched.clock,
				sleep = sched.sleep,
				spawn = sched.spawn,
				log = function() end,
				random = function(): number
					return 0.5
				end,
				config = { writeCooldown = 0 },
			})
		end
		local a = service("server-A")
		local p = h.fakePlayer(5151)
		sched.run(function()
			return a.load(p)
		end)
		h.eq(p:GetAttribute("Explained"), "")
		h.eq(p:GetAttribute("ExplainSkip"), false)
		h.ok(a.edit(p, "explained", function(profile: any)
			R.apply(profile.settings, "items", false)
		end))
		h.eq(p:GetAttribute("Explained"), "items")
		h.ok(a.edit(p, "explained", function(profile: any)
			R.apply(profile.settings, "garage", true)
		end))
		h.eq(p:GetAttribute("ExplainSkip"), true)
		h.eq(p:GetAttribute("Explained"), "items,keys,battles,tokens,garage")
		sched.run(function()
			return a.flush(p, 5)
		end)
		sched.run(function()
			return a.release(p)
		end)
		local b = service("server-B")
		local p2 = h.fakePlayer(5151)
		sched.run(function()
			return b.load(p2)
		end)
		h.eq(p2:GetAttribute("ExplainSkip"), true, "saved across a rejoin")
		h.eq(p2:GetAttribute("Explained"), "items,keys,battles,tokens,garage")
		h.ok(SaveService.markExplained ~= nil)
		h.eq(SaveService.markExplained(p2, "not_a_topic", false), false, "an unknown id is refused before it touches the profile")
	end)

	h.test("wiring: the client queues each topic through the saved state; the server validates the id and saves once", function()
		local la = h.readFile("src/client/LadderNotices.luau")
		h.contains(la, "function LadderNotices.queueTopic")
		h.contains(la, "topicDue(topic)")
		h.contains(la, 'queueTopic("items")')
		h.contains(la, 'queueTopic("tokens")')
		h.contains(la, 'queueTopic("garage")')
		h.contains(la, 'queueTopic("keys")')
		h.contains(la, 'queueTopic("battles")')
		h.contains(la, '"explained", topic, skip')
		h.contains(la, "loaded and ExplainerRules.due", "never a card before the saved profile replicated")
		local fn = h.readFile("src/server/Funnels.luau")
		h.contains(fn, 'action == "explained"')
		h.contains(fn, "ExplainerRules.isId(id)")
		h.contains(fn, "SaveService.markExplained")
		h.contains(fn, "EXPLAIN_GAP")
		local sv = h.readFile("src/server/SaveService.luau")
		h.contains(sv, "function SaveService.markExplained")
		h.contains(sv, "ExplainerRules.ATTR")
		-- the modal still opens only inside the calm drain
		local drain = string.find(la, "function LadderNotices.drainExplainer", 1, true) or math.huge
		local open = string.find(la, "NotifyKit.fromSpec(id, explainerVars(id)", 1, true)
		h.ok(open ~= nil and open > drain)
	end)
end
