--!strict
-- The per-server pool of bot usernames checked to be NOBODY'S Roblox account (economy v3 phase 4; the pattern is Meme
-- Fight Tactics' server/BotNamePool). The rules (candidates, filters, verdicts, pacing, no repeats) are
-- shared/BotNamePoolRules and shared/BotNames, Lune-tested; this module makes the one Roblox call in the background:
--   pcall(Players.GetUserIdFromNameAsync, Players, name)
-- a user id = somebody's: DROPPED; "Unknown user" (only that) = KEPT; anything else = asked again after a back-off.
-- Nothing here blocks a race: take() answers at once from the pool, or with a long numbered name flagged unchecked,
-- which AIRacers hands to recheck() so a name that turns out to be a real account is swapped in place.
-- Log lines: [SkyRally][NAMES] ... (dropped names, the first kept ones, a summary every SUMMARY_EVERY s).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BotNamePoolRules"))

local BotNamePool = {}

local SUMMARY_EVERY = 300 -- s between two pool summaries in the log
local KEPT_LOGGED = 6 -- the first kept names are logged one by one
local TICK = 0.25 -- s between two looks at the pool

local pool = Rules.new(math.floor(os.clock() * 1000) + math.random(1, 1000000))
local started = false

local function log(line: string)
	print("[SkyRally][NAMES] " .. line)
end

-- The one Roblox call, pcall'd; the verdict is the rules'.
local function check(name: string): (Rules.Verdict, string)
	local ok, res = pcall(function(): number
		return Players:GetUserIdFromNameAsync(name)
	end)
	return Rules.verdict(ok, res), if ok then "user id" else tostring(res)
end

function BotNamePool.size(): number
	return #pool.names
end

function BotNamePool.describe(): string
	return Rules.describe(pool)
end

-- A name for a bot not already in `avoid` (lower-case keys: the field's names and the humans'). Never yields.
-- Second result false = not vouched for (the pool was dry): pass it to recheck().
function BotNamePool.take(avoid: { [string]: boolean }?): (string, boolean)
	local name, checked = Rules.take(pool, avoid)
	if not checked then
		log(string.format("pool dry: unchecked name %s (%s)", name, Rules.describe(pool)))
	end
	return name, checked
end

-- Checks an unvouched name in the background (back-off, RETRY_MAX tries). If it is somebody's account, or cannot be
-- verified at all, `swap(newName)` is called once with a checked name (when the pool has one) so the caller renames the
-- bot. A verified-free name is simply kept.
function BotNamePool.recheck(name: string, swap: (string) -> ())
	task.spawn(function()
		local delay = Rules.BACKOFF
		for _ = 1, Rules.RETRY_MAX do
			local v, what = check(name)
			if v == "free" then
				return
			elseif v == "taken" then
				log(string.format("dropped %s: a real account (%s), bot renamed", name, what))
				local fresh, checked = Rules.take(pool)
				if checked then
					swap(fresh)
				else
					-- no vouched name ready: ask the same call about the fallback before using it
					local fv = check(fresh)
					if fv == "free" then
						swap(fresh)
					end
				end
				return
			end
			task.wait(delay)
			delay = math.min(delay * 2, Rules.BACKOFF_MAX)
		end
		-- never verified: swap only for a vouched name
		local fresh, checked = Rules.take(pool)
		if checked then
			log(string.format("%s could not be verified; bot renamed to a checked name", name))
			swap(fresh)
		end
	end)
end

function BotNamePool.start()
	if started then
		return
	end
	started = true
	log(string.format("started: target %d, first %d checks %gs apart, then one per %gs", pool.target, Rules.BURST, Rules.BURST_GAP, Rules.GAP))
	local lastSummary = os.clock()
	task.spawn(function()
		while true do
			local now = os.clock()
			if Rules.due(pool, now) then
				local ok, err = pcall(function()
					local name = Rules.candidate(pool)
					local v, what = check(name)
					local skipped = pool.skipped
					Rules.record(pool, name, v, os.clock())
					if pool.skipped > skipped then
						log(string.format("check %s failed %d times (%s): given up, a fresh name in %gs", name, Rules.RETRY_MAX, what, pool.backoff))
					elseif v == "taken" then
						log(string.format("dropped %s: a real account", name))
					elseif v == "free" and pool.kept <= KEPT_LOGGED then
						log(string.format("kept %s: no account", name))
					elseif v ~= "free" and v ~= "taken" and pool.backoff >= Rules.BACKOFF_MAX then
						warn(string.format("[SkyRally][NAMES] check %s failed (%s %s): again in %gs", name, v, what, pool.backoff))
					end
				end)
				if not ok then
					warn("[SkyRally][NAMES] refill pass failed: " .. tostring(err))
					pool.nextAt = os.clock() + Rules.BACKOFF
				end
			end
			if now - lastSummary >= SUMMARY_EVERY then
				lastSummary = now
				log(Rules.describe(pool))
			end
			task.wait(TICK)
		end
	end)
end

return BotNamePool
