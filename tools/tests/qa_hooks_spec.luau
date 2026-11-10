--!strict
-- Lune spec for the campaign QA tooling gaps TG-1..TG-6 (docs/VERIFY_CAMPAIGN_V33.md): shared/QAHooksRules (pure) and the
-- static guarantees that every hook is Studio-only. Run: tools/tests/run_lune_tests.sh tools/tests/qa_hooks_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/QAHooksRules.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")

	h.test("TG-1: the save fault hits only the named op, only in Studio", function()
		h.eq(R.saveFaultHits(true, "load", "load"), true)
		h.eq(R.saveFaultHits(true, "load", "save"), false)
		h.eq(R.saveFaultHits(true, "save", "save"), true)
		h.eq(R.saveFaultHits(true, "none", "save"), false)
		h.eq(R.saveFaultHits(true, nil, "load"), false)
		h.eq(R.saveFaultHits(true, 5, "load"), false)
		h.eq(R.saveFaultHits(true, "load", "bogus"), false)
		h.eq(R.saveFaultHits(false, "load", "load"), false, "a live server never injects")
		h.eq(R.saveFaultHits(false, "save", "save"), false)
	end)

	h.test("TG-1: fault count is a whole number 1..1000, Studio only", function()
		h.eq(R.faultCount(true, 2), 2)
		h.eq(R.faultCount(true, 2.9), 2)
		h.eq(R.faultCount(true, 0), nil)
		h.eq(R.faultCount(true, -3), nil)
		h.eq(R.faultCount(true, 1001), nil)
		h.eq(R.faultCount(true, "3"), nil)
		h.eq(R.faultCount(false, 2), nil)
	end)

	h.test("TG-4: QASaveAs is a non-zero whole id, Studio only", function()
		h.eq(R.saveAs(true, 1234), 1234)
		h.eq(R.saveAs(true, -7), -7)
		h.eq(R.saveAs(true, 0), nil)
		h.eq(R.saveAs(true, 1.5), nil)
		h.eq(R.saveAs(true, "12"), nil)
		h.eq(R.saveAs(true, 0 / 0), nil)
		h.eq(R.saveAs(false, 1234), nil, "a live server ignores the attribute")
	end)

	h.test("TG-6: the QA clock runs on from the set moment; a live server reads the real clock", function()
		h.eq(R.utcNow(true, 1000, 50, 50, 9999), 1000)
		h.eq(R.utcNow(true, 1000, 50, 62.5, 9999), 1012.5)
		h.eq(R.utcNow(true, nil, 50, 62, 9999), 9999)
		h.eq(R.utcNow(true, 1000, nil, 62, 9999), 9999)
		h.eq(R.utcNow(false, 1000, 50, 62, 9999), 9999, "live: QAUtcAt is never read")
		h.eq(R.utcNow(true, -5, 50, 62, 9999), 9999)
	end)

	h.test("TG-6: two servers at the same UTC read the same cup and shop; the signature is deterministic", function()
		local rules = EconomyRules.default
		local t = 1790000000 -- an arbitrary UTC moment
		local a, b = R.signature(rules, t), R.signature(rules, t)
		h.eq(a.signature, b.signature)
		local same, diffs = R.compareServers(rules, t, t + 2)
		local window = rules.restockIndex(t)
		local crosses = rules.restockIndex(t + 2) ~= window or rules.utcDay(t + 2) ~= rules.utcDay(t)
			or rules.stormCupNext(t).index ~= rules.stormCupNext(t + 2).index
		h.eq(same, not crosses, "2 s skew only differs across a boundary")
		h.eq(#diffs == 0, same)
	end)

	h.test("TG-6: a 2 s skew across the :30 cup boundary is caught as a cup difference", function()
		local rules = EconomyRules.default
		local period = 1800
		local boundary = (math.floor(1790000000 / period) + 1) * period
		-- window/day boundaries are on 300 s / 86400 s multiples; the cup boundary at 1800 s is also a window boundary, so
		-- pick two moments straddling it and assert the cup index differs
		local same, diffs = R.compareServers(rules, boundary - 1, boundary + 1)
		h.eq(same, false)
		h.ok(table.find(diffs, "cupIndex") ~= nil, "cupIndex differs across the boundary")
		local same2 = R.compareServers(rules, boundary + 1, boundary + 3)
		h.eq(same2, true, "both servers past the boundary agree")
	end)

	h.test("TG-6: a Daily Deal rolls at the UTC day boundary only", function()
		local rules = EconomyRules.default
		local day = 86400
		local boundary = (math.floor(1790000000 / day) + 1) * day
		local same, diffs = R.compareServers(rules, boundary - 10, boundary + 10)
		h.eq(same, false)
		h.ok(table.find(diffs, "day") ~= nil)
		h.eq(R.compareServers(rules, boundary + 10, boundary + 40), true)
	end)

	h.test("TG-1/TG-4 dynamic: the Studio default service fails a load on demand, recovers after the count, maps the id", function()
		local ws = h.stubs.workspace
		local SaveService = h.require("src/server/SaveService.luau")
		local svc = SaveService.service()
		h.eq(svc.backend, "mock")
		ws:SetAttribute("QASaveFault", "load")
		ws:SetAttribute("QASaveFaultCount", 1)
		local p = h.fakePlayer(4242, "QaOne")
		local profile, state = svc.load(p)
		h.eq(state, "ok", "the retry after the one injected failure loads")
		h.ok(profile ~= nil)
		h.eq(ws:GetAttribute("QASaveFault"), nil, "the count cleared the fault")
		h.contains(h.logs, "QA fault injected: load")
		-- TG-4: the next load uses the mapped profile id (one-shot)
		ws:SetAttribute("QASaveAs", 777)
		local q = h.fakePlayer(4243, "QaTwo")
		svc.load(q)
		h.eq(ws:GetAttribute("QASaveAs"), nil)
		h.contains(h.logs, "QA save identity: next load uses profile id 777")
	end)

	local function src(path: string): string
		return h.readFile(path)
	end

	h.test("static: SaveService wraps the store and maps ids ONLY under IsStudio, and the wrapper is not exported", function()
		local s = src("src/server/SaveService.luau")
		h.contains(s, "if studio then\n\t\tstore = withQAFaults(store)")
		h.contains(s, "resolveId = if studio and backend == \"mock\"")
		h.contains(s, "saveFaultHits(true,")
		h.ok(not string.find(s, "function SaveService.withQAFaults", 1, true), "the fault wrapper is local")
		h.contains(s, "end, { st.userId }, \"load\")")
		h.contains(s, "end, { userId }, \"save\")")
	end)

	h.test("static: LiveOps memory mode and the QA clock are gated by RunService:IsStudio()", function()
		local l = src("src/server/LiveOps.luau")
		h.contains(l, "return studio and (probeFailed or workspace:GetAttribute(QAHooksRules.LIVEOPS_MEMORY_ATTR) == true)")
		local c = src("src/server/QAClock.luau")
		h.contains(c, "local studio = RunService:IsStudio()")
		h.contains(c, "if not studio then\n\t\treturn real()")
		h.contains(c, "if not studio then\n\t\treturn\n\tend")
		local m = src("src/server/QAMultiplayer.luau")
		h.contains(m, "if not RunService:IsStudio() then\n\t\treturn\n\tend")
	end)

	h.test("static: the economy and the Storm Cup read the QA clock; nothing else changed their source of time", function()
		h.contains(src("src/server/Economy.luau"), "now = (require(script.Parent.QAClock) :: any).nowSeconds,")
		h.contains(src("src/server/StormCup.luau"), "(require(script.Parent.QAClock) :: any).now()")
	end)
end
