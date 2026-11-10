--!strict
-- Lune spec for the soak harness rules (audit T1-12): shared/SoakRules config parsing, step plan, sample shaping, and the
-- static guarantees that server/QASoak is Studio-only and never touches the owner-protected systems.
-- Run: tools/tests/run_lune_tests.sh tools/tests/soak_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/SoakRules.luau")

	h.test("soak: only a Studio session is allowed", function()
		h.eq(R.allowed(true), true)
		h.eq(R.allowed(false), false)
	end)

	h.test("soak: defaults and clamps", function()
		local cfg = R.parseConfig(nil)
		h.ok(cfg)
		h.eq(cfg.cycles, 3)
		h.eq(#cfg.maps, 5)
		h.eq(cfg.raceSecs, 0)
		cfg = R.parseConfig({ cycles = 9999, raceSecs = -5, frameSecs = 99, clientWait = 0 })
		h.eq(cfg.cycles, R.MAX_CYCLES)
		h.eq(cfg.raceSecs, 0)
		h.eq(cfg.frameSecs, 10)
		h.eq(cfg.clientWait, 2)
		cfg = R.parseConfig({ cycles = "x" })
		h.eq(cfg.cycles, 3, "junk falls back to the default")
	end)

	h.test("soak: map keys are validated, hub0 is never raced", function()
		local cfg = R.parseConfig({ maps = { "dino4", "hub0", "snow1" } })
		h.eq(cfg.maps, { "dino4", "snow1" })
		h.eq((R.parseConfig({ maps = { "a b" } })), nil)
		h.eq((R.parseConfig({ maps = { "../x" } })), nil)
		h.eq((R.parseConfig({ maps = { 5 } })), nil)
		h.eq((R.parseConfig({ maps = {} })), nil)
		h.eq((R.parseConfig({ maps = "dino4" })), nil)
		h.eq((R.parseConfig("x")), nil)
		local many = {}
		for i = 1, R.MAX_MAPS + 1 do
			table.insert(many, "m" .. i)
		end
		h.eq((R.parseConfig({ maps = many })), nil)
	end)

	h.test("soak: plan plays every map once per cycle, in order", function()
		local cfg = R.parseConfig({ cycles = 2, maps = { "dino4", "snow1" } })
		local steps = R.plan(cfg)
		h.eq(#steps, 4)
		h.eq(steps[1], { n = 1, cycle = 1, index = 1, key = "dino4" })
		h.eq(steps[2], { n = 2, cycle = 1, index = 2, key = "snow1" })
		h.eq(steps[3], { n = 3, cycle = 2, index = 1, key = "dino4" })
		h.eq(steps[4].n, 4)
	end)

	h.test("soak: shape rounds, clamps and drops what cannot travel", function()
		local s = R.shape({ a = 1.26, b = string.rep("x", 500), c = true, d = 0 / 0, e = math.huge, f = function() end, nested = { x = 2.04, y = { z = 1, deep = { q = 1 } } } })
		h.eq(s.a, 1.3)
		h.eq(#s.b, R.MAX_STRING)
		h.eq(s.c, true)
		h.eq(s.d, nil)
		h.eq(s.e, nil)
		h.eq(s.f, nil)
		h.eq(s.nested.x, 2)
		h.eq(s.nested.y.z, 1)
		h.eq(s.nested.y.deep, nil, "nesting stops at MAX_DEPTH")
	end)

	h.test("soak: error lines survive shaping on the server and on a client reply", function()
		-- A client reply is shaped on receipt, then the whole sample again before it goes into the attribute.
		local reply = R.shape({ seq = 1, errors = 2, errorTail = { "client boom", string.rep("y", 400) } })
		h.eq(reply.errorTail[1], "client boom")
		h.eq(#reply.errorTail[2], R.MAX_STRING)
		local s = R.shape({ server = { errors = 1, errorTail = { "server boom" } }, clients = { Solo = reply } })
		h.eq(s.server.errorTail, { "server boom" })
		h.eq(s.clients.Solo.errorTail[1], "client boom")
		local long = {}
		for i = 1, R.MAX_LIST + 5 do
			table.insert(long, "e" .. i)
		end
		h.eq(#R.shape({ l = long }).l, R.MAX_LIST)
		h.eq(R.shape({ l = { "a", {}, "b" } }).l, { "a", "b" }, "only scalars travel in a list")
	end)

	h.test("soak: error tail and missing replies", function()
		local t = R.errorTail({ "a", "b", "c", "d", string.rep("z", 400) })
		h.eq(#t, R.MAX_ERRORS_KEPT)
		h.eq(R.sampleAttr(7), "QASoakS7")
		h.eq(R.missing({ "A", "B", "C" }, { A = true, C = true }), { "B" })
		h.eq(R.missing({}, {}), {})
	end)

	h.test("soak: QASoak is Studio-only and leaves the protected systems alone", function()
		local src = h.readFile("src/server/QASoak.luau")
		h.contains(src, "SoakRules.allowed(RunService:IsStudio())")
		h.contains(src, "requestRace")
		h.contains(src, "returnToHub")
		for _, banned in { "adhesion", "Adhesion", "KillVolume", "killVolume", "rescue", "Rescue", "Barrier", "StormRace", "SetAttribute(\"Store", "PER_GROUP =" } do
			h.ok(not string.find(src, banned, 1, true), "QASoak must not mention " .. banned)
		end
		local client = h.readFile("src/client/QAMultiplayerClient.luau")
		h.contains(client, "QASoakSeq")
		h.contains(client, "IsStudio")
	end)

	h.test("soak: the server entry is wired and the protocol names agree", function()
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "require(script.QASoak).start")
		local qa = h.readFile("src/server/QAMultiplayer.luau")
		h.contains(qa, "QASoak")
		local py = h.readFile("tools/soak.py")
		h.contains(py, R.RUN_ATTR)
		h.contains(py, R.PROGRESS_ATTR)
		h.contains(py, R.SAMPLE_ATTR_PREFIX)
	end)
end
