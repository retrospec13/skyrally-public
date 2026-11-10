-- Bot usernames (shared/BotNames, shared/BotNamePoolRules; economy v3 phase 4): every generated name has Roblox's
-- username shape and passes the offensive / impersonation / bot-tell filters, the word parts themselves are clean, a
-- session never repeats a name, a name that resolves to a user id is dropped (fake checker), failures back off and
-- are never taken as "free", and an empty pool still hands out a name at once (never blocks a race start).
return function(h)
	local N = h.require("src/shared/BotNames.luau")
	local P = h.require("src/shared/BotNamePoolRules.luau")

	local function allParts()
		local out = {}
		for _, list in { N.ADJ, N.NOUN, N.LOWER, N.FIRST, N.SUFFIX } do
			for _, w in list do
				table.insert(out, w)
			end
		end
		return out
	end

	h.test("shape: 3-20 chars of [A-Za-z0-9_], one underscore at most, none at the ends, not all digits", function()
		h.ok(N.validShape("Noah_2011"))
		h.ok(N.validShape("abc"))
		h.ok(N.validShape("A1b2C3d4E5f6G7h8I9j0"))
		h.ok(not N.validShape("ab"), "2 chars")
		h.ok(not N.validShape("A1b2C3d4E5f6G7h8I9j0k"), "21 chars")
		h.ok(not N.validShape("_abc"))
		h.ok(not N.validShape("abc_"))
		h.ok(not N.validShape("a_b_c"), "two underscores")
		h.ok(not N.validShape("12345"), "all digits")
		h.ok(not N.validShape("a b c"))
		h.ok(not N.validShape("abc-def"))
		h.ok(not N.validShape("caf\u{e9}1"))
	end)

	h.test("filters: offensive roots, famous creators and brands, and bot tells are all refused, leet and separators included", function()
		h.eq(N.refusal("xXfuckXx"), "banned")
		h.eq(N.refusal("sh1t_lord"), "banned", "leet")
		h.eq(N.refusal("S_E_X_Y"), "banned", "separators do not hide a root")
		h.eq(N.refusal("Builderman"), "protected")
		h.eq(N.refusal("N1ke_99"), "protected", "leet brand")
		h.eq(N.refusal("MrBeast6000"), "protected")
		h.eq(N.refusal("RobloxFan"), "protected")
		h.eq(N.refusal("Official_Mia"), "protected")
		h.eq(N.refusal("AI_Ace_Aero"), "tell")
		h.eq(N.refusal("Ai_Racer"), "tell")
		h.eq(N.refusal("RacerBot"), "tell")
		h.eq(N.refusal("Guest1234"), "tell")
		h.eq(N.refusal("NPC_Falcon"), "tell")
		h.eq(N.refusal("SwiftFalcon"), nil)
		h.eq(N.refusal("Rain_2011"), nil, "ai inside a word is not a tell")
		h.eq(N.refusal("Mia_2011"), nil)
	end)

	h.test("word parts: none is refused alone or in a pair, and every part is short and plain", function()
		local parts = allParts()
		for _, w in parts do
			h.ok(N.refusal(w) == nil, "part refused: " .. w)
			h.ok(string.find(w, "^[A-Za-z0-9]+$") ~= nil, "part charset: " .. w)
		end
	end)

	h.test("generation: 6000 seeded names are all valid, filtered, and vary across the styles", function()
		local rng = N.rng(12345)
		local seen, lens, withDigits, withUnderscore = {}, {}, 0, 0
		for _ = 1, 6000 do
			local name = N.make(rng)
			h.ok(N.validShape(name), "shape: " .. name)
			h.ok(N.refusal(name) == nil, "filter: " .. name)
			seen[name] = true
			lens[#name] = true
			if string.find(name, "%d") then
				withDigits += 1
			end
			if string.find(name, "_") then
				withUnderscore += 1
			end
		end
		local distinct = 0
		for _ in seen do
			distinct += 1
		end
		h.ok(distinct > 3000, "a large space: " .. distinct .. " distinct of 6000")
		h.ok(withDigits > 1500 and withDigits < 5500, "mixed digit styles: " .. withDigits)
		h.ok(withUnderscore > 300, "some underscore styles: " .. withUnderscore)
		local nl = 0
		for _ in lens do
			nl += 1
		end
		h.ok(nl >= 8, "a spread of lengths: " .. nl)
		h.eq(N.STYLE_COUNT >= 10, true)
	end)

	h.test("generation: the same seed deals the same names, another seed does not", function()
		local a, b, c = N.rng(7), N.rng(7), N.rng(8)
		local same, diff = true, false
		for _ = 1, 50 do
			local x, y, z = N.make(a), N.make(b), N.make(c)
			same = same and x == y
			diff = diff or x ~= z
		end
		h.ok(same and diff)
	end)

	h.test("generation: avoid set is honoured and the long fallback is valid and numbered", function()
		local rng = N.rng(99)
		local avoid = {}
		for _ = 1, 500 do
			local name = N.make(rng, avoid)
			h.ok(not avoid[string.lower(name)], "repeat: " .. name)
			avoid[string.lower(name)] = true
		end
		local long = N.makeLong(N.rng(3))
		h.ok(N.valid(long) and string.find(long, "%d%d%d%d%d") ~= nil, long)
	end)

	h.test("verdict: only 'Unknown user' frees a name; an id drops it; anything else asks again", function()
		h.eq(P.verdict(true, 156), "taken")
		h.eq(P.verdict(true, nil), "retry")
		h.eq(P.verdict(false, "Players:GetUserIdFromNameAsync: Unknown user"), "free")
		h.eq(P.verdict(false, "HTTP 404 (Not Found)"), "retry", "an outage is not a verdict")
		h.eq(P.verdict(false, "HTTP 429 too many requests"), "throttle")
		h.eq(P.verdict(false, "Http requests are not enabled"), "retry")
	end)

	-- a fake Roblox: some candidates "exist"
	local function fakeChecker(takenFn, failFn)
		local calls = {}
		return function(name)
			table.insert(calls, name)
			if failFn and failFn(#calls, name) then
				return P.verdict(false, "HTTP 500")
			end
			if takenFn(name) then
				return P.verdict(true, 4242)
			end
			return P.verdict(false, "Unknown user")
		end, calls
	end

	h.test("pool: fills to the target with free names only, dropping every name the checker says exists", function()
		local pool = P.new(5, 30)
		local check, calls = fakeChecker(function(name)
			return #name % 3 == 0 -- a third of the names are real accounts
		end)
		local now = 0
		for _ = 1, 400 do
			if P.due(pool, now) then
				local name = P.candidate(pool)
				P.record(pool, name, check(name), now)
			end
			now += 0.25
		end
		h.eq(#pool.names, 30, "target reached")
		for _, name in pool.names do
			h.ok(#name % 3 ~= 0, "a real account got through: " .. name)
			h.ok(N.valid(name))
		end
		h.ok(pool.dropped > 0 and pool.kept >= 30)
		h.eq(#calls, pool.kept + pool.dropped, "one call per verdict, no failures here")
		-- no check once full
		h.ok(not P.due(pool, now + 100))
	end)

	h.test("pool: no repeats within a session across many takes (checked or fallback)", function()
		local pool = P.new(11, 40)
		local check = fakeChecker(function()
			return false
		end)
		local now = 0
		local given = {}
		for round = 1, 300 do
			if P.due(pool, now) then
				local name = P.candidate(pool)
				P.record(pool, name, check(name), now)
			end
			now += 0.5
			if round % 4 == 0 then
				local name = P.take(pool)
				h.ok(not given[string.lower(name)], "repeat: " .. name)
				given[string.lower(name)] = true
			end
		end
		-- drain the pool, then keep asking: the fallback also never repeats
		for _ = 1, 200 do
			local name = P.take(pool)
			h.ok(not given[string.lower(name)], "repeat after drain: " .. name)
			given[string.lower(name)] = true
		end
	end)

	h.test("pool: an empty pool never blocks, and flags the fallback name unchecked so the caller re-checks it", function()
		local pool = P.new(2, 0)
		local name, checked = P.take(pool)
		h.ok(N.valid(name) and not checked)
		h.eq(pool.fallbacks, 1)
		local avoid = { [string.lower(name)] = true }
		local again = P.take(pool, avoid)
		h.ok(again ~= name)
		-- with a ready name, take returns it checked and skips one already on the field
		local p2 = P.new(2, 5)
		table.insert(p2.names, "AlphaOne")
		table.insert(p2.names, "BetaTwo")
		local got, ok2 = P.take(p2, { alphaone = true })
		h.eq(got, "BetaTwo")
		h.ok(ok2)
		h.eq(#p2.names, 1)
	end)

	h.test("pool: failed checks back off (doubling), retry the same name, give it up after RETRY_MAX, never keep it", function()
		local pool = P.new(3, 10)
		local now = 0
		local name = P.candidate(pool)
		P.record(pool, name, "retry", now)
		h.eq(pool.backoff, P.BACKOFF)
		h.eq(pool.retry, name, "the same name again")
		h.ok(not P.due(pool, now + P.BACKOFF - 0.1))
		h.ok(P.due(pool, now + P.BACKOFF))
		now += P.BACKOFF
		P.record(pool, name, "throttle", now)
		h.eq(pool.backoff, P.BACKOFF * 2)
		now += pool.backoff
		P.record(pool, name, "retry", now)
		h.eq(pool.retry, nil, "given up after RETRY_MAX")
		h.eq(pool.skipped, 1)
		h.eq(#pool.names, 0, "a failing name is never kept")
		h.ok(pool.seen[string.lower(name)], "and never asked or shown again")
		h.ok(P.candidate(pool) ~= name)
		-- the back-off is capped
		for _ = 1, 20 do
			P.record(pool, "X" .. tostring(_) .. "name", "retry", now)
		end
		h.ok(pool.backoff <= P.BACKOFF_MAX)
		-- an answer clears the back-off
		P.record(pool, "ZedName", "free", now)
		h.eq(pool.backoff, 0)
	end)

	h.test("pool: the first fill is quicker (burst), then one check per GAP", function()
		local pool = P.new(1, 40)
		P.record(pool, "OneName", "free", 0)
		h.eq(pool.nextAt, P.BURST_GAP)
		for i = 1, P.BURST do
			P.record(pool, "Name" .. i .. "x", "free", 0)
		end
		P.record(pool, "LateName", "free", 10)
		h.eq(pool.nextAt, 10 + P.GAP)
	end)
end
