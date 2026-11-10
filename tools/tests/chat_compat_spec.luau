-- ChatCompat: chat-version detection, per-version feature plan, layout plans, filtering rules, and wiring greps.
return function(h)
	local C = h.require("src/shared/ChatCompat.luau")
	local L = h.require("src/shared/ChatLayoutRules.luau")

	h.test("detect: legacy only for LegacyChatService, everything else is text", function()
		h.eq(C.detect("LegacyChatService"), "legacy")
		h.eq(C.detect("TextChatService"), "text")
		h.eq(C.detect(nil), "text")
		h.eq(C.detect("SomethingNew"), "text")
	end)

	h.test("plan: admin command lives in exactly one place per version", function()
		local t, l = C.plan("text"), C.plan("legacy")
		h.eq(t.adminClientCommand, true)
		h.eq(t.adminServerHook, false)
		h.eq(l.adminClientCommand, false)
		h.eq(l.adminServerHook, true)
		h.eq(t.layoutKind, "chatwindow")
		h.eq(l.layoutKind, "setcore")
	end)

	h.test("pickChannel prefers RBXSystem then RBXGeneral", function()
		h.eq(C.pickChannel({ "RBXGeneral", "RBXSystem" }), "RBXSystem")
		h.eq(C.pickChannel({ "RBXGeneral" }), "RBXGeneral")
		h.eq(C.pickChannel({ "Team" }), nil)
		h.eq(C.pickChannel({}), nil)
	end)

	h.test("cleanSystemText keeps line breaks, strips other control chars, trims, caps, rejects non-strings", function()
		h.eq(C.cleanSystemText("  hi\nthere  "), "hi\nthere")
		h.eq(C.cleanSystemText("a\r\nb\tc\0d"), "a\nb c d")
		h.eq(C.cleanSystemText("   "), nil)
		h.eq(C.cleanSystemText("\n\n"), nil)
		h.eq(C.cleanSystemText(5), nil)
		h.eq(#(C.cleanSystemText(string.rep("a", 5000)) :: string), C.MAX_SYSTEM_TEXT)
		-- "/admin help" (both help blocks, as AdminService answers it) arrives whole, every line intact.
		local A = h.require("src/shared/AdminRules.luau")
		local S = h.require("src/shared/SaveAdminRules.luau")
		local help = "[Admin] " .. A.HELP .. "\n" .. S.HELP
		h.eq(C.cleanSystemText(help), help)
	end)

	h.test("layoutPlan: both versions stay bottom/centre-left and small for every view", function()
		for _, v in { { 1920, 1080 }, { 844, 390 }, { 667, 375 } } do
			for _, touch in { false, true } do
				for _, phase in { "hub", "race", "results" } do
					local cfg = L.compute(v[1], v[2], touch, phase)
					local t = C.layoutPlan("text", cfg)
					h.eq(t.kind, "chatwindow")
					h.eq(t.props.HorizontalAlignment, "Left")
					h.eq(t.props.WidthScale, cfg.widthScale)
					local g = C.layoutPlan("legacy", cfg)
					h.eq(g.kind, "setcore")
					h.eq(g.position.xs, 0)
					h.ok(g.position.ys >= 0 and g.position.ys + g.size.ys <= 1.0001, "inside the screen")
					h.ok(g.size.xs <= 0.5 and g.size.ys <= 0.5, "small window")
					if cfg.vertical == "Bottom" then
						h.ok(math.abs(g.position.ys + g.size.ys - 1) < 1e-9, "flush to the bottom")
					end
				end
			end
		end
	end)

	h.test("filterText: sanitises, caps, returns nil on filter failure or bad input (never raw text)", function()
		local seen = ""
		local function ok(s: string): any
			seen = s
			return "[" .. s .. "]"
		end
		h.eq(C.filterText(ok, "  hello\tworld "), "[hello world]")
		h.eq(seen, "hello world")
		h.eq(#seen, 11)
		C.filterText(ok, string.rep("x", 500))
		h.eq(#seen, C.MAX_TEXT)
		h.eq(C.filterText(ok, ""), nil)
		h.eq(C.filterText(ok, 12), nil)
		h.eq(C.filterText(function(_s: string): any
			error("filter down")
		end, "hi"), nil)
		h.eq(C.filterText(function(_s: string): any
			return 7
		end, "hi"), nil)
	end)

	h.test("wiring: no feature touches a chat service directly outside the adapters", function()
		local panel = h.readFile("src/client/AdminPanel.luau")
		h.contains(panel, "ChatCompatClient.systemMessage(text)")
		h.contains(panel, 'ChatCompatClient.version() == "legacy"')
		local layout = h.readFile("src/client/ChatLayout.luau")
		h.contains(layout, "return ChatCompatClient.applyLayout(cfg)")
		h.contains(layout, "if key ~= lastKey and applyChat(vpX, vpY, touch, phase) then")
		h.ok(not string.find(layout, "ChatWindowConfiguration", 1, true), "layout goes through the adapter")
		local race = h.readFile("src/client/RaceUI.luau")
		h.contains(race, ".rectString()")
		local admin = h.readFile("src/server/AdminService.luau")
		h.contains(admin, 'ChatCompat.detect(TextChatService.ChatVersion.Name) == "legacy"')
		local adapter = h.readFile("src/client/ChatCompatClient.luau")
		h.contains(adapter, "ChatMakeSystemMessage")
		h.contains(adapter, "DisplaySystemMessage")
		-- The layout never forces the chat window open (a player who closed chat keeps it closed across phases).
		h.ok(not string.find(adapter, '"ChatActive"', 1, true), "no ChatActive SetCore")
		h.contains(h.readFile("src/server/TextFilter.luau"), "FilterStringAsync")
	end)

	h.test("the repo never sets ChatVersion (the flip is the owner's, docs/CHAT_MIGRATION.md)", function()
		local proj = h.readFile("default.project.json")
		h.ok(not string.find(proj, "ChatVersion", 1, true), "ChatVersion not in the Rojo project yet")
	end)
end
