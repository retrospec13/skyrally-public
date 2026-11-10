--!strict
-- Global leaderboards (social lane): a best-time board per race track and a total-stars board, OrderedDataStore backed.
-- The rules (what is a valid time, the stars, text, the cache timing and the write queue) are shared/LeaderboardRules,
-- specced in tools/tests/leaderboard_spec.luau; this module is the Roblox side.
--   * WRITE: RaceManager.finishHook hands every real finish here after the saved award. The time comes from the server's
--     own race clock (rec.finishTime); AutoPilot, QA, simulated finishes, untimed modes and impossible times are refused by
--     LeaderboardRules.timeEntry. Entries go through a throttled write queue (one UpdateAsync a second, UpdateAsync budget
--     checked, retried with a doubling wait, a failure never touches the race). UpdateAsync keeps the better of the stored
--     and the new value, so a repeat or a stale write cannot worsen a record.
--   * BACKFILL: when a profile loads, its saved best times and star total are queued once, so records set before the board
--     existed (or while the store was down) appear without a new race.
--   * READ: a cached top 10 per board, refreshed every 120 s on one thread (pcall per board, GetSortedAsync budget checked
--     first, a doubling backoff after failures). Names come from Players:GetNameFromUserIdAsync, cached.
--   * SHOW: server/HubBoard draws the physical board in the hub; each player's own value rides on player attributes
--     LbBest_<track> / LbStars for client/LeaderboardBoard's "YOU" line.
-- Studio without DataStore API access uses an in-memory backend so the board still works in a Studio session.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LeaderboardRules = require(Shared:WaitForChild("LeaderboardRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))

local Leaderboards = {}

local LOG = "[SkyRally][LB] "
local NAME_LOOKUPS_PER_REFRESH = 20 -- per pages() call
local NAME_RETRY_SECONDS = 300 -- a failed name lookup is not tried again for this long
local STEP_SECONDS = 1

export type Backend = {
	kind: string,
	update: (store: string, key: string, transform: (old: any) -> any) -> (boolean, string?),
	-- ok, then the page rows ({ key = string, value = number }) or the error text.
	top: (store: string, ascending: boolean, count: number) -> (boolean, any),
	readBudget: () -> number,
	writeBudget: () -> number,
}

export type Page = {
	board: LeaderboardRules.Board,
	rows: { { userId: number, name: string, value: number } },
}

export type Options = {
	backend: Backend,
	clock: (() -> number)?,
	-- userId -> name; may yield or error (the service pcalls it). nil: the player's own name when present, else "Player".
	nameOf: ((userId: number) -> string)?,
	profileOf: ((Player) -> any)?,
	log: ((string) -> ())?,
}

export type Service = {
	backend: Backend,
	boards: { LeaderboardRules.Board },
	-- Finish hook: info is RaceManager's FinishInfo, award its AwardSummary (or nil when the award threw).
	onFinish: (player: Player, info: any, award: any, ctx: LeaderboardRules.FinishContext?) -> string,
	-- Queues a profile's saved best times and star total once per join.
	onLoaded: (player: Player) -> (),
	forget: (player: Player) -> (),
	-- One scheduler step: at most one due write, then a refresh when it is time. Yields in live.
	step: () -> (),
	refresh: () -> boolean,
	pages: () -> { Page },
	version: () -> number,
	queueSize: () -> number,
}

-- ---------------------------------------------------------------------------------------------------------------- backends

local function cleanStoreRows(items: any): { any }
	local out = {}
	for _, item in items do
		table.insert(out, { key = item.key, value = item.value })
	end
	return out
end

function Leaderboards.liveBackend(): Backend
	local stores: { [string]: OrderedDataStore } = {}
	local function store(name: string): OrderedDataStore
		local s = stores[name]
		if not s then
			s = DataStoreService:GetOrderedDataStore(name)
			stores[name] = s
		end
		return s :: OrderedDataStore
	end
	return {
		kind = "datastore",
		update = function(name, key, transform)
			local ok, err = pcall(function()
				store(name):UpdateAsync(key, function(old: any): any
					return transform(old)
				end)
			end)
			if not ok then
				return false, tostring(err)
			end
			return true, nil
		end,
		top = function(name, ascending, count)
			local ok, result = pcall(function()
				local pages = store(name):GetSortedAsync(ascending, count)
				return cleanStoreRows(pages:GetCurrentPage())
			end)
			return ok, if ok then result else tostring(result)
		end,
		readBudget = function()
			local ok, n = pcall(function()
				return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetSortedAsync)
			end)
			return if ok and type(n) == "number" then n else 0
		end,
		writeBudget = function()
			local ok, n = pcall(function()
				return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
			end)
			return if ok and type(n) == "number" then n else 0
		end,
	}
end

-- In-memory stand-in (Studio without API access, and the Lune specs): same contract, values copied in and out.
function Leaderboards.memoryBackend(): Backend
	local data: { [string]: { [string]: number } } = {}
	local backend: Backend = {
		kind = "memory",
		update = function(name: string, key: string, transform: (old: any) -> any): (boolean, string?)
			local ok, err = pcall(function(): any
				local s = data[name]
				if not s then
					s = {}
					data[name] = s
				end
				local new = transform(s[key])
				if new ~= nil then
					if type(new) ~= "number" or new ~= math.floor(new) then
						error("OrderedDataStore values must be integers")
					end
					s[key] = new
				end
				return nil
			end)
			if not ok then
				return false, tostring(err)
			end
			return true, nil
		end,
		top = function(name: string, ascending: boolean, count: number): (boolean, any)
			local rows: { { key: string, value: number } } = {}
			local s = data[name]
			if s then
				for key, value in s do
					table.insert(rows, { key = key, value = value })
				end
			end
			table.sort(rows, function(a, b)
				if a.value == b.value then
					return a.key < b.key
				end
				return if ascending then a.value < b.value else a.value > b.value
			end)
			local out = {}
			for i = 1, math.min(count, #rows) do
				out[i] = rows[i]
			end
			return true, out
		end,
		readBudget = function(): number
			return 100
		end,
		writeBudget = function(): number
			return 100
		end,
	}
	return backend
end

-- ---------------------------------------------------------------------------------------------------------------- service

function Leaderboards.new(options: Options): Service
	local backend = options.backend
	local clock = options.clock or os.clock
	local logFn: (string) -> () = options.log or function(m: string)
		print(m)
	end
	local trackNames: { [string]: string } = {}
	for _, id in LeaderboardRules.RACE_TRACKS do
		local info = TrackInfo.get(id)
		trackNames[id] = if info then info.trackName else id
	end
	local boards = LeaderboardRules.boards(trackNames)
	local queue = LeaderboardRules.newQueue()

	local snapshot: { [string]: { LeaderboardRules.Row } } = {}
	local names: { [number]: string } = {}
	local nameFailedAt: { [number]: number } = {}
	local failures = 0
	local nextRefreshAt = 0
	local nextWriteAt = 0
	local snapshotVersion = 0
	local backfilled: { [Player]: boolean } = {}
	local lastStars: { [number]: number } = {}

	local service = {} :: Service
	service.backend = backend
	service.boards = boards

	local function log(msg: string)
		logFn(LOG .. msg)
	end

	local function profileOf(player: Player): any
		local f = options.profileOf
		return if f then f(player) else nil
	end

	local function boardFor(id: string): LeaderboardRules.Board?
		for _, b in boards do
			if b.id == id then
				return b
			end
		end
		return nil
	end

	local function enqueue(board: LeaderboardRules.Board, userId: number, value: number)
		queue.push(board.store, tostring(userId), value, board.ascending)
	end

	-- The viewer's own numbers for client/LeaderboardBoard's "YOU" line.
	local function publishOwn(player: Player, profile: any)
		if type(profile) ~= "table" then
			return
		end
		local best = profile.bestTimes
		for _, trackId in LeaderboardRules.RACE_TRACKS do
			local ms = if type(best) == "table" then best[trackId] else nil
			player:SetAttribute(LeaderboardRules.ownAttribute(LeaderboardRules.timeBoardId(trackId)), if LeaderboardRules.savedTimeOk(ms) then ms else nil)
		end
		local stars = LeaderboardRules.totalStars(profile)
		player:SetAttribute(LeaderboardRules.ownAttribute("stars"), if stars > 0 then stars else nil)
	end

	local function queueStars(player: Player, profile: any)
		local stars = LeaderboardRules.totalStars(profile)
		if stars > 0 and lastStars[player.UserId] ~= stars then
			lastStars[player.UserId] = stars
			local board = boardFor("stars")
			if board then
				enqueue(board, player.UserId, stars)
			end
		end
	end

	function service.onFinish(player, info, award, ctx)
		local profile = profileOf(player)
		publishOwn(player, profile)
		queueStars(player, profile)
		local ms, why = LeaderboardRules.timeEntry(info, ctx)
		if not ms then
			return why
		end
		local result = if type(award) == "table" then award.bestTimeResult else nil
		-- "awarded" = a new personal best; "queued" = the profile had not loaded, SaveService keeps the better. A repeat
		-- ("noop") or a missing award adds nothing the board does not already have.
		if result ~= "awarded" and result ~= "queued" then
			return "no personal best"
		end
		local board = boardFor(LeaderboardRules.timeBoardId(info.trackId))
		if not board then
			return "no board"
		end
		enqueue(board, player.UserId, ms)
		log(string.format("queued %s user=%d %d ms", info.trackId, player.UserId, ms))
		return "queued"
	end

	function service.onLoaded(player)
		if backfilled[player] then
			return
		end
		backfilled[player] = true
		local profile = profileOf(player)
		if type(profile) ~= "table" then
			return
		end
		publishOwn(player, profile)
		local best = profile.bestTimes
		if type(best) == "table" then
			for _, trackId in LeaderboardRules.RACE_TRACKS do
				local ms = best[trackId]
				local board = boardFor(LeaderboardRules.timeBoardId(trackId))
				if board and LeaderboardRules.savedTimeOk(ms) then
					enqueue(board, player.UserId, ms)
				end
			end
		end
		queueStars(player, profile)
	end

	function service.forget(player)
		backfilled[player] = nil
		lastStars[player.UserId] = nil
	end

	local function nameOf(userId: number, budget: { n: number }): string
		local cached = names[userId]
		if cached then
			return cached
		end
		for _, p in Players:GetPlayers() do
			if p.UserId == userId then
				names[userId] = p.Name
				return p.Name
			end
		end
		local lookup = options.nameOf
		local failed = nameFailedAt[userId]
		if lookup and budget.n > 0 and not (failed and clock() - failed < NAME_RETRY_SECONDS) then
			budget.n -= 1
			local ok, name = pcall(lookup, userId)
			if ok and type(name) == "string" and name ~= "" then
				names[userId] = name
				nameFailedAt[userId] = nil
				return name
			end
			nameFailedAt[userId] = clock()
		end
		return "Player"
	end

	function service.refresh()
		local now = clock()
		if not LeaderboardRules.canRead(backend.readBudget(), #boards) then
			nextRefreshAt = now + LeaderboardRules.BACKOFF_BASE
			log("refresh postponed: read budget low")
			return false
		end
		local allOk = true
		for _, board in boards do
			local ok, result = backend.top(board.store, board.ascending, LeaderboardRules.ROWS)
			if ok then
				snapshot[board.id] = LeaderboardRules.cleanRows(result, LeaderboardRules.ROWS)
			else
				allOk = false
				log(string.format("read %s failed: %s", board.id, tostring(result)))
			end
		end
		if allOk then
			failures = 0
		else
			failures += 1
		end
		snapshotVersion += 1
		nextRefreshAt = clock() + LeaderboardRules.nextRefreshDelay(failures)
		return allOk
	end

	function service.step()
		local now = clock()
		if now >= nextWriteAt and queue.size() > 0 then
			if backend.writeBudget() <= LeaderboardRules.WRITE_RESERVE then
				nextWriteAt = now + LeaderboardRules.WRITE_GAP * 5
			else
				local job = queue.pop(now)
				if job then
					nextWriteAt = now + LeaderboardRules.WRITE_GAP
					local ascending = job.ascending
					local value = job.value
					local ok, err = backend.update(job.store, job.key, function(old: any): any
						return LeaderboardRules.merge(old, value, ascending)
					end)
					if not ok then
						local stays = queue.retry(job, clock())
						log(string.format("write %s/%s failed (%s)%s", job.store, job.key, tostring(err), if stays then ", will retry" else ", dropped"))
					end
				end
			end
		end
		if clock() >= nextRefreshAt then
			service.refresh()
		end
	end

	function service.pages()
		local out: { Page } = {}
		local budget = { n = NAME_LOOKUPS_PER_REFRESH }
		for _, board in boards do
			local rows = {}
			local cached = snapshot[board.id]
			if cached then
				for _, row in cached do
					table.insert(rows, { userId = row.userId, name = nameOf(row.userId, budget), value = row.value })
				end
			end
			table.insert(out, { board = board, rows = rows })
		end
		return out
	end

	function service.version()
		return snapshotVersion
	end

	function service.queueSize()
		return queue.size()
	end

	return service
end

-- ---------------------------------------------------------------------------------------------------------------- boot

local default: Service? = nil
local starting = false

function Leaderboards.service(): Service?
	return default
end

-- RaceManager.finishHook entry: adds what only the server knows about this run (AutoPilot, the QA harness) and passes it on.
-- Never throws; a finish before the service is up is simply not posted (the backfill at profile load covers it).
function Leaderboards.onFinish(player: Player, info: any, award: any, ctx: LeaderboardRules.FinishContext?)
	local svc = default
	if not svc then
		return
	end
	local c: LeaderboardRules.FinishContext = {
		autopilot = workspace:GetAttribute("AutoPilot") == true,
		qa = workspace:GetAttribute("QAMP") == true,
		totalLen = if ctx then ctx.totalLen else nil,
		laps = if ctx then ctx.laps else nil,
	}
	local ok, result = pcall(svc.onFinish, player, info, award, c)
	if not ok then
		warn(LOG .. "onFinish failed: " .. tostring(result))
	elseif result ~= "queued" then
		print(string.format("%sskip user=%d track=%s mode=%s (%s)", LOG, player.UserId, tostring(info.trackId), tostring(info.mode), tostring(result)))
	end
end

local function chooseBackend(): Backend
	if RunService:IsStudio() then
		local live = Leaderboards.liveBackend()
		local ok, result = live.top(LeaderboardRules.STORE_PREFIX .. "probe", true, 1)
		if not ok then
			print(LOG .. "Studio without DataStore API access (" .. tostring(result) .. "); using the in-memory board")
			return Leaderboards.memoryBackend()
		end
		return live
	end
	return Leaderboards.liveBackend()
end

-- Wires the default service: backend, finish/load hooks, the step loop. profileOf reads the saved profile
-- (SaveService.get); onLoaded registers a callback for a loaded profile (SaveService.onLoaded).
function Leaderboards.init(profileOf: (Player) -> any, onLoaded: ((Player) -> ()) -> ())
	if default ~= nil or starting then
		return
	end
	starting = true
	-- Threaded: the Studio probe below yields, and the boot map build must not wait for it.
	task.spawn(function()
		local backend = chooseBackend()
		local svc = Leaderboards.new({
			backend = backend,
			profileOf = profileOf,
			nameOf = function(userId: number): string
				return Players:GetNameFromUserIdAsync(userId)
			end,
		})
		default = svc
		print(LOG .. "backend=" .. backend.kind)
		onLoaded(svc.onLoaded)
		-- Profiles that loaded while the backend was being chosen.
		for _, p in Players:GetPlayers() do
			if profileOf(p) ~= nil then
				svc.onLoaded(p)
			end
		end
		Players.PlayerRemoving:Connect(svc.forget)
		-- Best effort at shutdown: a finish in the last seconds should still reach the board.
		game:BindToClose(function()
			local deadline = os.clock() + 20
			while svc.queueSize() > 0 and os.clock() < deadline do
				pcall(svc.step)
				task.wait(LeaderboardRules.WRITE_GAP)
			end
		end)
		task.wait(3)
		while true do
			local ok, err = pcall(function(): any
				svc.step()
				return nil
			end)
			if not ok then
				warn(LOG .. "step failed: " .. tostring(err))
			end
			task.wait(STEP_SECONDS)
		end
	end)
end

return Leaderboards
