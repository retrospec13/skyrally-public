--!strict
-- Lune spec for the Studio-only QA helpers (QA V5A: give any item, put a bot ahead): shared/QAToolRules parsing and the
-- static guarantees that server/QATools and the ItemService / AIRacers entry points refuse everything outside Studio.
-- Run: tools/tests/run_lune_tests.sh tools/tests/qa_tools_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/QAToolRules.luau")
	local ItemRules = h.require("src/shared/ItemRules.luau")

	h.test("qa tools: only a Studio session is allowed", function()
		h.eq(R.allowed(true), true)
		h.eq(R.allowed(false), false)
	end)

	h.test("qa tools: parseGive reads color[:level], clamps the level, refuses junk", function()
		local c, l = R.parseGive("red:3")
		h.eq(c, "red")
		h.eq(l, 3)
		c, l = R.parseGive("  Green ")
		h.eq(c, "green")
		h.eq(l, 1, "default level")
		c, l = R.parseGive("blue:9")
		h.eq(l, ItemRules.MAX_LEVEL, "clamped to the cap")
		h.eq(R.MAX_LEVEL, ItemRules.MAX_LEVEL)
		c, l = R.parseGive("yellow:0")
		h.eq(l, 1, "at least 1")
		h.eq((R.parseGive("purple:2")), nil)
		h.eq((R.parseGive("red; drop")), nil)
		h.eq((R.parseGive(5)), nil)
		h.eq((R.parseGive("")), nil)
		for _, color in R.COLORS do
			h.ok(ItemRules.isColor(color), color .. " is an item color")
		end
	end)

	h.test("qa tools: parseAhead reads studs[:lateral] and clamps", function()
		local s, lat = R.parseAhead("60")
		h.eq(s, 60)
		h.eq(lat, 0)
		s, lat = R.parseAhead("120:-8")
		h.eq(s, 120)
		h.eq(lat, -8)
		s = R.parseAhead(80)
		h.eq(s, 80, "a number works")
		s, lat = R.parseAhead("5:999")
		h.eq(s, R.AHEAD_MIN)
		h.eq(lat, R.LATERAL_MAX)
		s = R.parseAhead("999999")
		h.eq(s, R.AHEAD_MAX)
		h.eq((R.parseAhead("abc")), nil)
		h.eq((R.parseAhead(nil)), nil)
	end)

	h.test("qa tools: stationAhead wraps over the start line", function()
		local st, laps = R.stationAhead(100, 60, 1000)
		h.eq(st, 160)
		h.eq(laps, 0)
		st, laps = R.stationAhead(980, 60, 1000)
		h.eq(st, 40)
		h.eq(laps, 1)
	end)

	h.test("static: the helpers exist only in Studio", function()
		local tools = h.readFile("src/server/QATools.luau")
		h.contains(tools, "if not Rules.allowed(RunService:IsStudio()) then")
		local startAt = string.find(tools, "function QATools.start", 1, true) or 0
		local guardAt = string.find(tools, "Rules.allowed(RunService:IsStudio())", 1, true) or 0
		local remoteAt = string.find(tools, "Instance.new(\"RemoteFunction\")", 1, true) or 0
		h.ok(startAt > 0 and guardAt > startAt and remoteAt > guardAt, "the guard comes before anything is created")
		local items = h.readFile("src/server/ItemService.luau")
		h.contains(items, 'if not ItemService.isStudio() then')
		h.contains(items, 'return false, "not_studio"')
		local ai = h.readFile("src/server/AIRacers.luau")
		local fnAt = string.find(ai, "function AIRacers.qaPlaceAhead", 1, true) or 0
		local studioAt = string.find(ai, ":IsStudio()", fnAt, true) or 0
		h.ok(fnAt > 0 and studioAt > fnAt and studioAt - fnAt < 400, "qaPlaceAhead checks IsStudio first")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "require(script.QATools).start(")
		-- AIRacers.bots is per race scope: the bot moved belongs to the player's own instance.
		h.contains(tools, "RaceScope.run(RaceScope.instanceOf(player)")
	end)

	h.test("static: the QA entry points never touch walls, adhesion, kill volumes or rescue", function()
		local tools = h.readFile("src/server/QATools.luau") .. h.readFile("src/shared/QAToolRules.luau")
		tools = string.gsub(tools, "%-%-[^\n]*", "")
		for _, bad in { "KillVolume", "adhesion", "Adhesion", "rescue", "Rescue", "Barrier", "CarServer" } do
			h.ok(string.find(tools, bad, 1, true) == nil, "no " .. bad)
		end
	end)
end
