--!strict
-- Hub leaderboard rules (social lane). Pure: no Instances, no DataStore, no clock, specced in
-- tools/tests/leaderboard_spec.luau. server/Leaderboards owns the OrderedDataStores and the hub board; client/LeaderboardBoard
-- writes the viewer's own line on it.
--
-- Boards: one best-time board per race track (lowest ms first) and one total-stars board (most first).
-- A TIME is only ever taken from the server's own finish: RaceManager sets rec.finishTime from the race clock
-- (os.clock() - raceStartClock), and the entry is refused for AutoPilot or QA runs, simulated finishes, untimed modes
-- (battle, coin, boss, Storm Cup) and times no legal flight could reach.
--
-- STARS (the game has no star system of its own, so this module defines it from progression the server already saves):
--   per race track, up to 3:  1 = won the standard race (the track's race token)
--                             2 = won the coin challenge (the track's coin token)
--                             3 = beat the boss (the zone's boss first-win; SPACE-4 has no boss, so the final boss)
--   total = the sum over the five race tracks (max 15).
local LeaderboardRules = {}

LeaderboardRules.STORE_PREFIX = "SkyRallyLB_v1_" -- OrderedDataStore name = prefix .. board id
LeaderboardRules.ROWS = 10
LeaderboardRules.REFRESH_SECONDS = 120 -- how often the cached top 10 is re-read
LeaderboardRules.PAGE_SECONDS = 9 -- the physical board shows one board at a time and turns the page this often
LeaderboardRules.MAX_STARS = 15

-- Where the board stands in HUB-0: one constant. A free-standing sign on the open plaza terrace (flat paving, ground
-- y = 26), 62 studs south-east of the fountain and 62 studs dead ahead of the spawn (slightly left), outside the spawn grid (which spans
-- x -8180..-8212 behind the spawn), clear of the portal arc (north), the lamp ring (radius ~95 from the fountain) and the
-- bunting strung between its lamps. Its face looks at the spawn so arriving players read it. Checked against
-- map/hub0/plan.json: the nearest plan instance is 30 studs away.
LeaderboardRules.BOARD = {
	pos = Vector3.new(-8104, 26, 8051), -- bottom centre of the posts, at the paving (v29 B6: 15 studs further from the spawn than v28's -8119, 8054)
	faceToward = Vector3.new(-8159, 26, 8027), -- v29 B6: turned ~35 degrees from the spawn toward the fountain, so it reads obliquely from the spawn and the vendor approach
	width = 27, -- studs, along the face (v28 visual critic 1.18: 75% of the v27 36; HubBoard keeps the same pixel canvas, so rows stay laid out)
	height = 17.8, -- studs, panel height
	clearance = 2.5, -- studs between the paving and the panel's lower edge (sunk a stud lower)
	groundTolerance = 6, -- a raycast result further than this from pos.Y is ignored (a roof, bunting)
}

LeaderboardRules.RACE_TRACKS = { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" }
local RACE_TRACK_SET: { [string]: boolean } = {}
for _, id in LeaderboardRules.RACE_TRACKS do
	RACE_TRACK_SET[id] = true
end

-- Same set as RaceManager.TIMED_MODES: the finishes that may set a saved best time.
local TIMED_MODES: { [string]: boolean } = { race = true, timetrial = true, quickrace = true }

export type Board = { id: string, kind: "time" | "stars", trackId: string?, store: string, ascending: boolean, title: string }

-- The six boards in page order: five tracks, then stars. titles maps a track id to its player-facing name.
function LeaderboardRules.boards(trackNames: { [string]: string }?): { Board }
	local out: { Board } = {}
	for _, trackId in LeaderboardRules.RACE_TRACKS do
		local name = if trackNames and trackNames[trackId] then trackNames[trackId] else trackId
		table.insert(out, {
			id = "best:" .. trackId,
			kind = "time",
			trackId = trackId,
			store = LeaderboardRules.STORE_PREFIX .. "best_" .. trackId,
			ascending = true,
			title = "BEST TIMES - " .. string.upper(name),
		})
	end
	table.insert(out, {
		id = "stars",
		kind = "stars",
		trackId = nil,
		store = LeaderboardRules.STORE_PREFIX .. "stars",
		ascending = false,
		title = "TOTAL STARS",
	})
	return out
end

function LeaderboardRules.timeBoardId(trackId: string): string
	return "best:" .. trackId
end

-- ---------------------------------------------------------------------------------------------------------------- times

LeaderboardRules.ABSOLUTE_MIN_SECONDS = 20 -- no race on this game is shorter, whatever the spline says
LeaderboardRules.MAX_SECONDS = 3600
LeaderboardRules.SPEED_CEILING = 260 -- studs/s: PlaneGuardRules.SPEED_CEILING, the fastest any legal vehicle goes
LeaderboardRules.MIN_LAP_FRACTION = 0.65 -- PlaneGuardRules: shortcuts are well under 15% shorter than the spline

-- The shortest time the server accepts for a race of `laps` laps on a spline of totalLen studs.
function LeaderboardRules.minSeconds(totalLen: number?, laps: number?): number
	local floor = LeaderboardRules.ABSOLUTE_MIN_SECONDS
	if type(totalLen) ~= "number" or totalLen ~= totalLen or totalLen <= 0 then
		return floor
	end
	local n = if type(laps) == "number" and laps >= 1 then laps else 1
	return math.max(floor, n * LeaderboardRules.MIN_LAP_FRACTION * totalLen / LeaderboardRules.SPEED_CEILING)
end

export type FinishInfo = {
	trackId: string,
	mode: string,
	finished: boolean,
	time: number, -- seconds from the server's race clock
	simulated: boolean?,
}

export type FinishContext = {
	autopilot: boolean?, -- workspace.AutoPilot at the finish
	qa: boolean?, -- workspace.QAMP (the two-client QA harness)
	totalLen: number?, -- the spline length, for the lower bound
	laps: number?,
}

-- A finish -> the integer milliseconds to put on the track's board, or nil and why not.
function LeaderboardRules.timeEntry(info: FinishInfo, ctx: FinishContext?): (number?, string)
	local c: FinishContext = ctx or {}
	if info.finished ~= true then
		return nil, "not finished"
	elseif info.simulated == true then
		return nil, "simulated finish"
	elseif c.autopilot == true then
		return nil, "autopilot run"
	elseif c.qa == true then
		return nil, "qa run"
	elseif not RACE_TRACK_SET[info.trackId] then
		return nil, "not a race track"
	elseif not TIMED_MODES[info.mode] then
		return nil, "untimed mode"
	end
	local t = info.time
	if type(t) ~= "number" or t ~= t or t == math.huge or t == -math.huge then
		return nil, "bad time"
	elseif t < LeaderboardRules.minSeconds(c.totalLen, c.laps) then
		return nil, "faster than any legal flight"
	elseif t > LeaderboardRules.MAX_SECONDS then
		return nil, "too slow for a board"
	end
	return math.floor(t * 1000 + 0.5), "ok"
end

-- A saved best time (profile.bestTimes entry, ms) is acceptable for a backfill when it is a sane integer.
function LeaderboardRules.savedTimeOk(ms: any): boolean
	return type(ms) == "number" and ms == ms and ms >= LeaderboardRules.ABSOLUTE_MIN_SECONDS * 1000 and ms <= LeaderboardRules.MAX_SECONDS * 1000
end

-- ---------------------------------------------------------------------------------------------------------------- stars

export type Progress = {
	tokens: { [string]: boolean }?,
	boss: { [string]: { first: boolean?, rematch: boolean? } }?,
	finalBoss: boolean?,
}

local ZONE_HAS_BOSS: { [string]: boolean } = {
	["DINO-4"] = true,
	["SNOW-1"] = true,
	["ISLAND-2"] = true,
	["FOREST-1"] = true,
	["SPACE-4"] = false,
}

-- Stars on one race track, 0..3.
function LeaderboardRules.trackStars(p: Progress?, trackId: string): number
	if not p or not RACE_TRACK_SET[trackId] then
		return 0
	end
	local tokens = p.tokens or {}
	local n = 0
	if tokens["race:" .. trackId] == true then
		n += 1
	end
	if tokens["coin:" .. trackId] == true then
		n += 1
	end
	if ZONE_HAS_BOSS[trackId] then
		local b = if p.boss then p.boss[trackId] else nil
		if b and b.first == true then
			n += 1
		end
	elseif p.finalBoss == true then
		n += 1
	end
	return n
end

function LeaderboardRules.totalStars(p: Progress?): number
	local n = 0
	for _, trackId in LeaderboardRules.RACE_TRACKS do
		n += LeaderboardRules.trackStars(p, trackId)
	end
	return n
end

-- ---------------------------------------------------------------------------------------------------------------- text

-- 83456 -> "1:23.456"; under a minute "59.250"; anything unusable "--".
function LeaderboardRules.formatTime(ms: any): string
	if type(ms) ~= "number" or ms ~= ms or ms < 0 or ms == math.huge then
		return "--"
	end
	local total = math.floor(ms + 0.5)
	local minutes = total // 60000
	local seconds = (total % 60000) // 1000
	local millis = total % 1000
	if minutes <= 0 then
		return string.format("%d.%03d", seconds, millis)
	end
	return string.format("%d:%02d.%03d", minutes, seconds, millis)
end

function LeaderboardRules.formatValue(kind: string, value: any): string
	if kind == "stars" then
		if type(value) ~= "number" or value ~= value then
			return "--"
		end
		return string.format("%d", math.floor(value))
	end
	return LeaderboardRules.formatTime(value)
end

-- A player name cut for a board row (Roblox names are 3-20 characters; the board column is narrower).
function LeaderboardRules.shortName(name: any, maxLen: number?): string
	local limit = maxLen or 16
	if type(name) ~= "string" or name == "" then
		return "Player"
	end
	if #name <= limit then
		return name
	end
	return string.sub(name, 1, limit - 1) .. "."
end

export type Row = { userId: number, value: number }

-- Raw GetSortedAsync rows ({ key = "123", value = n }) -> clean rows, best first. Entries with a bad key or a value
-- the board cannot show are dropped; at most `limit` rows.
function LeaderboardRules.cleanRows(raw: any, limit: number?): { Row }
	local out: { Row } = {}
	if type(raw) ~= "table" then
		return out
	end
	local max = limit or LeaderboardRules.ROWS
	for _, entry in raw do
		if type(entry) == "table" then
			local uid = tonumber(entry.key)
			local v = entry.value
			if uid and uid > 0 and uid == math.floor(uid) and type(v) == "number" and v == v and v > 0 and v < math.huge then
				table.insert(out, { userId = uid, value = v })
				if #out >= max then
					break
				end
			end
		end
	end
	return out
end

-- The viewer's own line under the top 10. rows are the displayed rows (userId, value). myValue is the viewer's own
-- value on this board (best ms, or total stars) or nil when he has none. Returns the text.
function LeaderboardRules.ownLine(kind: string, rows: { Row }, myUserId: number, myValue: number?): string
	for i, row in rows do
		if row.userId == myUserId then
			return string.format("YOU  #%d  %s", i, LeaderboardRules.formatValue(kind, row.value))
		end
	end
	if myValue == nil or myValue <= 0 then
		return if kind == "stars" then "Earn stars to get on the board" else "Finish this race to get on the board"
	end
	local shown = LeaderboardRules.formatValue(kind, myValue)
	if #rows < LeaderboardRules.ROWS then
		-- The board has room, so he is simply not written yet (a finish is queued; the board re-reads every 2 minutes).
		return string.format("YOU  %s  (posting...)", shown)
	end
	return string.format("YOU  %s  (outside the top %d)", shown, LeaderboardRules.ROWS)
end

-- The name of the replicated player attribute that carries a player's own value on a board.
function LeaderboardRules.ownAttribute(boardId: string): string
	if boardId == "stars" then
		return "LbStars"
	end
	return "LbBest_" .. string.gsub(string.sub(boardId, 6), "[^%w]", "_")
end

-- ---------------------------------------------------------------------------------------------------------------- cache timing

LeaderboardRules.BACKOFF_BASE = 30
LeaderboardRules.BACKOFF_MAX = 600
LeaderboardRules.READ_RESERVE = 2 -- GetSortedAsync budget left untouched for other systems

-- Seconds until the next refresh: the normal period after a success; after `failures` failures in a row, a doubling wait
-- from BACKOFF_BASE up to BACKOFF_MAX.
function LeaderboardRules.nextRefreshDelay(failures: number): number
	if failures <= 0 then
		return LeaderboardRules.REFRESH_SECONDS
	end
	return math.min(LeaderboardRules.BACKOFF_MAX, LeaderboardRules.BACKOFF_BASE * 2 ^ (failures - 1))
end

-- A refresh reads one page per board; run it only when the request budget covers them all plus the reserve.
function LeaderboardRules.canRead(budget: number, boardCount: number): boolean
	return budget >= boardCount + LeaderboardRules.READ_RESERVE
end

-- ---------------------------------------------------------------------------------------------------------------- write queue

LeaderboardRules.WRITE_GAP = 1 -- seconds between two board writes from this server
LeaderboardRules.WRITE_RESERVE = 5 -- UpdateAsync budget left untouched for the save system
LeaderboardRules.WRITE_ATTEMPTS = 5
LeaderboardRules.WRITE_RETRY_BASE = 4

export type Job = { store: string, key: string, value: number, ascending: boolean, attempts: number, notBefore: number }

export type Queue = {
	-- Adds a write, merging with a queued one for the same store and key (the better value wins).
	push: (store: string, key: string, value: number, ascending: boolean) -> (),
	-- The next job whose retry time has come, taken off the queue; nil when none is due.
	pop: (now: number) -> Job?,
	-- A popped job failed: back on the queue with a doubling delay, or dropped after WRITE_ATTEMPTS. Returns whether it stays.
	retry: (job: Job, now: number) -> boolean,
	size: () -> number,
}

function LeaderboardRules.newQueue(): Queue
	local jobs: { Job } = {}
	local queue = {} :: Queue

	function queue.push(store, key, value, ascending)
		for _, j in jobs do
			if j.store == store and j.key == key then
				if (ascending and value < j.value) or (not ascending and value > j.value) then
					j.value = value
				end
				return
			end
		end
		table.insert(jobs, { store = store, key = key, value = value, ascending = ascending, attempts = 0, notBefore = 0 })
	end

	function queue.pop(now)
		for i, j in jobs do
			if j.notBefore <= now then
				table.remove(jobs, i)
				return j
			end
		end
		return nil
	end

	function queue.retry(job, now)
		job.attempts += 1
		if job.attempts >= LeaderboardRules.WRITE_ATTEMPTS then
			return false
		end
		job.notBefore = now + LeaderboardRules.WRITE_RETRY_BASE * 2 ^ (job.attempts - 1)
		table.insert(jobs, job)
		return true
	end

	function queue.size()
		return #jobs
	end

	return queue
end

-- The value an UpdateAsync transform stores: keeps the better of the old and new value. old may be nil.
function LeaderboardRules.merge(old: any, new: number, ascending: boolean): number
	if type(old) ~= "number" or old ~= old then
		return new
	end
	if ascending then
		return math.min(old, new)
	end
	return math.max(old, new)
end

return LeaderboardRules
