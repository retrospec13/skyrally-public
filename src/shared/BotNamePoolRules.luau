--!strict
-- The per-server pool of bot names CHECKED to be nobody's Roblox account (economy v3 phase 4; the pattern is Meme Fight
-- Tactics' Logic/NamePool). Pure: the pool, the verdicts and the pacing live here (tools/tests/bot_names_spec.luau);
-- server/BotNamePool makes the one Roblox call, pcall(Players.GetUserIdFromNameAsync, Players, name), and feeds the
-- answer to verdict():
--   * it returns a user id: the name is somebody's: DROPPED, never shown;
--   * it errors "Unknown user": no such account: KEPT in the pool;
--   * any other error (web failure, throttle, HTTP 404): NOT a verdict. The same name is asked again after a back-off
--     (doubling to BACKOFF_MAX), up to RETRY_MAX times, then given up (never shown) and a fresh candidate is asked.
-- One check per GAP s while the pool holds fewer than TARGET names (a quicker pace for the first BURST answers); none
-- while full. A name is generated, checked and used once per server session (`seen`): no repeats within a session.
-- An empty pool never blocks a race: take() hands a long numbered name flagged unchecked, and the caller re-checks it
-- asynchronously and renames the bot if it turns out to be somebody's.
local BotNames = require(script.Parent:WaitForChild("BotNames"))

local Pool = {}

Pool.TARGET = 40 -- names kept ready per server
Pool.GAP = 1.0 -- s between two checks (the web call's pace)
Pool.BURST = 12 -- the first answers come faster, so the first race of a booting server rarely needs the fallback
Pool.BURST_GAP = 0.3
Pool.BACKOFF = 5 -- s before a failed or throttled check is asked again, doubling
Pool.BACKOFF_MAX = 120
Pool.RETRY_MAX = 3 -- failed checks of one name before it is given up
Pool.SEEN_MAX = 4000 -- names remembered as checked or used (older ones forgotten)

-- "free" | "taken" | "retry" | "throttle"
export type Verdict = string

export type PoolState = {
	names: { string }, -- checked, free, not used yet (oldest first)
	seen: { [string]: boolean }, -- lower-case: generated, checked or used here (never asked or shown twice)
	seenOrder: { string },
	target: number,
	nextAt: number, -- the clock (s) the next check may start
	backoff: number, -- s of the current back-off (0 = none)
	retry: string?, -- a name to ask again (its check failed)
	tries: number,
	skipped: number, -- names given up after RETRY_MAX failed checks
	kept: number,
	dropped: number,
	errors: number,
	fallbacks: number, -- long numbered names handed out unchecked
	taken: number, -- names handed to races
	rng: () -> number,
}

function Pool.new(seed: number, target: number?): PoolState
	return {
		names = {},
		seen = {},
		seenOrder = {},
		target = if type(target) == "number" and target >= 0 then math.floor(target) else Pool.TARGET,
		nextAt = 0,
		backoff = 0,
		retry = nil,
		tries = 0,
		skipped = 0,
		kept = 0,
		dropped = 0,
		errors = 0,
		fallbacks = 0,
		taken = 0,
		rng = BotNames.rng(seed),
	}
end

local function remember(p: PoolState, name: string)
	local k = string.lower(name)
	if p.seen[k] then
		return
	end
	p.seen[k] = true
	table.insert(p.seenOrder, k)
	if #p.seenOrder > Pool.SEEN_MAX then
		local old = table.remove(p.seenOrder, 1)
		if old then
			p.seen[old] = nil
		end
	end
end

function Pool.bursting(p: PoolState): boolean
	return p.kept + p.dropped < Pool.BURST and p.errors == 0
end

-- Is a check due now? (the pool is short and the pace / back-off allows)
function Pool.due(p: PoolState, now: number): boolean
	return (#p.names < p.target or p.retry ~= nil) and now >= p.nextAt
end

-- The next name to check: the one whose check failed, else a fresh filtered candidate never seen here.
function Pool.candidate(p: PoolState): string
	local r = p.retry
	if r then
		return r
	end
	for _ = 1, 50 do
		local name = BotNames.make(p.rng, p.seen)
		if not p.seen[string.lower(name)] then
			return name
		end
	end
	return BotNames.makeLong(p.rng, p.seen)
end

-- What a check's pcall said: `ok` and `res` as pcall(Players.GetUserIdFromNameAsync, Players, name) returned them.
function Pool.verdict(ok: boolean, res: unknown): Verdict
	if ok then
		return if type(res) == "number" then "taken" else "retry"
	end
	local msg = string.lower(tostring(res))
	-- only Roblox's own "Unknown user" is a verdict: "HTTP 404" from an outage must never mark names free
	if string.find(msg, "unknown user", 1, true) then
		return "free"
	end
	if string.find(msg, "429", 1, true) or string.find(msg, "too many", 1, true) or string.find(msg, "throttl", 1, true) or string.find(msg, "rate limit", 1, true) then
		return "throttle"
	end
	return "retry"
end

-- Record a check's verdict for `name` at clock `now` (and pace the next).
function Pool.record(p: PoolState, name: string, v: Verdict, now: number)
	if v == "free" or v == "taken" then
		p.retry = nil
		p.tries = 0
		p.backoff = 0
		remember(p, name)
		if v == "free" then
			if #p.names < p.target then
				table.insert(p.names, name)
			end
			p.kept += 1
		else
			p.dropped += 1
		end
		p.nextAt = now + (if Pool.bursting(p) then Pool.BURST_GAP else Pool.GAP)
		return
	end
	p.errors += 1
	p.backoff = math.clamp(if p.backoff > 0 then p.backoff * 2 else Pool.BACKOFF, Pool.BACKOFF, Pool.BACKOFF_MAX)
	p.nextAt = now + p.backoff
	p.tries = if p.retry == name then p.tries + 1 else 1
	if p.tries >= Pool.RETRY_MAX then
		remember(p, name)
		p.retry = nil
		p.tries = 0
		p.skipped += 1
		return
	end
	p.retry = name
end

-- A name for a bot: the oldest checked name, else (flagged unchecked) a long numbered one. `avoid` holds lower-case
-- names already on this field. Never blocks, never repeats within the session.
function Pool.take(p: PoolState, avoid: { [string]: boolean }?): (string, boolean)
	for i, name in p.names do
		if not (avoid and avoid[string.lower(name)]) then
			table.remove(p.names, i)
			p.taken += 1
			return name, true
		end
	end
	p.fallbacks += 1
	local name = BotNames.makeLong(p.rng, setmetatable({}, {
		__index = function(_, k: string): boolean?
			return p.seen[k] or (avoid and avoid[k]) or nil
		end,
	}) :: any)
	remember(p, name)
	p.taken += 1
	return name, false
end

function Pool.describe(p: PoolState): string
	return string.format(
		"ready=%d kept=%d dropped=%d skipped=%d errors=%d fallbacks=%d taken=%d backoff=%gs",
		#p.names, p.kept, p.dropped, p.skipped, p.errors, p.fallbacks, p.taken, p.backoff
	)
end

return Pool
