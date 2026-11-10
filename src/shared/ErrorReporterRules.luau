--!strict
-- Error and memory telemetry rules (docs/audits/systems_audit_v32.md T1-4, error and memory part; progression events
-- are another branch's). Used by server/ErrorReporter and client/ErrorReporter; pinned by tools/tests/error_reporter_spec.luau.
--   * scrub: first line only, player names and long digit runs (user ids, asset ids) replaced, capped. No PII leaves.
--   * fingerprint: source + message with every digit run folded, hashed to 8 hex characters, so "index 3" and
--     "index 4" from the same script are one error.
--   * tracker: the first sighting of a fingerprint is reported at once; repeats only count and go out in the next
--     flush as one report with the count. A fixed window budget and a session cap bound what one machine can send.
--   * cleanClient: what the server accepts from a client relay (types, kinds, lengths, characters); anything else drops.
--   * build label, memory samples (peak and p95 in MB) and their cleaning.
-- Pure: no Roblox calls; the clock is a dependency.
local ErrorReporterRules = {}

ErrorReporterRules.TAG = "[SkyRally][ERR] "
ErrorReporterRules.MEM_TAG = "[SkyRally][MEM] "
ErrorReporterRules.REMOTE = "ErrorRemote"

ErrorReporterRules.MAX_MSG = 160
ErrorReporterRules.MAX_SOURCE = 40
ErrorReporterRules.WINDOW = 60 -- seconds per budget window
ErrorReporterRules.BUDGET = 10 -- reports (first sightings plus flushed repeats) per window
ErrorReporterRules.SESSION_CAP = 60 -- reports per session (per player on the server's relay)
ErrorReporterRules.MAX_DISTINCT = 200 -- fingerprints remembered; past this, new ones only count as dropped
ErrorReporterRules.FLUSH_EVERY = 120 -- seconds between repeat-count flushes
ErrorReporterRules.MAX_COUNT = 100000

-- Analytics custom event names (AnalyticsService:LogCustomEvent). Fields: build label, source, kind.
ErrorReporterRules.EVENT_CLIENT = "client_error"
ErrorReporterRules.EVENT_SERVER = "server_error"
ErrorReporterRules.EVENT_CLIENT_MEM_PEAK = "client_mem_peak_mb"
ErrorReporterRules.EVENT_CLIENT_MEM_P95 = "client_mem_p95_mb"
ErrorReporterRules.EVENT_SERVER_MEM_P95 = "server_mem_p95_mb"
ErrorReporterRules.EVENT_SERVER_FRAME_P95 = "server_heartbeat_p95_ms"

-- error: a script error (ScriptContext.Error); boot / boot_core: a client module that failed to start (BootRules).
ErrorReporterRules.KINDS = { error = true, boot = true, boot_core = true } :: { [string]: boolean }

---------------------------------------------------------------------------------------------------------------- text

local function plainReplace(s: string, find: string, repl: string): string
	if find == "" then
		return s
	end
	local out, i = {}, 1
	while true do
		local a, b = string.find(s, find, i, true)
		if not a then
			break
		end
		table.insert(out, string.sub(s, i, a - 1))
		table.insert(out, repl)
		i = (b :: number) + 1
	end
	table.insert(out, string.sub(s, i))
	return table.concat(out)
end

-- One clean line: first line, control characters out, the given player names (and display names) replaced with
-- "<player>", any run of 6+ digits (user ids, asset ids) replaced with "#", whitespace collapsed, capped at MAX_MSG.
function ErrorReporterRules.scrub(msg: any, names: { string }?): string
	local s = if type(msg) == "string" then msg else tostring(msg)
	s = string.match(s, "^[^\r\n]*") or ""
	s = string.gsub(s, "[%c]", " ")
	if names then
		-- Longest first, so "Bob" never cuts "Bobby" in half.
		local sorted = table.clone(names)
		table.sort(sorted, function(a, b)
			return #a > #b
		end)
		for _, n in sorted do
			if type(n) == "string" and #n >= 3 then
				s = plainReplace(s, n, "<player>")
			end
		end
	end
	s = string.gsub(s, "%d%d%d%d%d%d+", "#")
	s = string.gsub(s, "%s+", " ")
	s = string.match(s, "^%s*(.-)%s*$") or s
	if #s > ErrorReporterRules.MAX_MSG then
		s = string.sub(s, 1, ErrorReporterRules.MAX_MSG)
	end
	return s
end

-- Short script name from a full name ("Players.x.PlayerScripts.Client.CarController" -> "CarController").
function ErrorReporterRules.sourceName(fullName: any): string
	if type(fullName) ~= "string" or fullName == "" then
		return "unknown"
	end
	local last = string.match(fullName, "([^%.]+)$") or fullName
	last = string.gsub(last, "[^%w_]", "")
	if last == "" then
		return "unknown"
	end
	return string.sub(last, 1, ErrorReporterRules.MAX_SOURCE)
end

-- djb2 over the source and the digit-folded message, as 8 lowercase hex characters.
function ErrorReporterRules.fingerprint(source: string, msg: string): string
	local folded = string.gsub(msg, "%d+", "#")
	local key = source .. "|" .. folded
	local h = 5381
	for i = 1, #key do
		h = (h * 33 + string.byte(key, i)) % 4294967296
	end
	return string.format("%08x", h)
end

-- "v29-abc1234" from the stamped commit and the place version (Studio: "v0-dev").
function ErrorReporterRules.buildLabel(commit: any, placeVersion: any): string
	local c = if type(commit) == "string" and commit ~= "" then string.gsub(commit, "[^%w]", "") else "dev"
	c = string.sub(c, 1, 7)
	local v = if type(placeVersion) == "number" and placeVersion == placeVersion then math.max(0, math.floor(placeVersion)) else 0
	return string.format("v%d-%s", v, c)
end

------------------------------------------------------------------------------------------------------------- tracker

export type Report = { kind: string, source: string, fp: string, msg: string, count: number }
export type Stats = { seen: number, sent: number, dropped: number, distinct: number }

export type Tracker = {
	note: (kind: string, source: string, msg: string) -> Report?,
	flush: () -> { Report },
	stats: () -> Stats,
}

export type TrackerOpts = { now: () -> number, budget: number?, window: number?, sessionCap: number? }

export type Budget = {
	-- true when one more report fits this window's budget and the session cap (and spends it).
	take: () -> boolean,
	sent: () -> number,
}

-- The window budget plus session cap on its own: the tracker spends it, and the server's client relay uses one per
-- player (the client already fingerprinted and de-duplicated, so the relay only bounds the volume).
function ErrorReporterRules.newBudget(opts: TrackerOpts): Budget
	local budget = opts.budget or ErrorReporterRules.BUDGET
	local window = opts.window or ErrorReporterRules.WINDOW
	local cap = opts.sessionCap or ErrorReporterRules.SESSION_CAP
	local windowStart = opts.now()
	local used = 0
	local sent = 0
	local b = {} :: Budget
	function b.take(): boolean
		local t = opts.now()
		if t - windowStart >= window then
			windowStart = t
			used = 0
		end
		if used >= budget or sent >= cap then
			return false
		end
		used += 1
		sent += 1
		return true
	end
	function b.sent(): number
		return sent
	end
	return b
end

function ErrorReporterRules.newTracker(opts: TrackerOpts): Tracker
	local spend = ErrorReporterRules.newBudget(opts)
	local stats: Stats = { seen = 0, sent = 0, dropped = 0, distinct = 0 }
	-- fp -> the entry; pending = repeats not yet sent.
	local known: { [string]: { kind: string, source: string, msg: string, pending: number } } = {}
	local order: { string } = {}

	local function take(): boolean
		if not spend.take() then
			return false
		end
		stats.sent += 1
		return true
	end

	local tracker = {} :: Tracker

	function tracker.note(kind: string, source: string, msg: string): Report?
		stats.seen += 1
		local k = if ErrorReporterRules.KINDS[kind] then kind else "error"
		local fp = ErrorReporterRules.fingerprint(source, msg)
		local e = known[fp]
		if e then
			e.pending = math.min(e.pending + 1, ErrorReporterRules.MAX_COUNT)
			return nil
		end
		if stats.distinct >= ErrorReporterRules.MAX_DISTINCT then
			stats.dropped += 1
			return nil
		end
		stats.distinct += 1
		if take() then
			known[fp] = { kind = k, source = source, msg = msg, pending = 0 }
			table.insert(order, fp)
			return { kind = k, source = source, fp = fp, msg = msg, count = 1 }
		end
		-- Over budget: remembered with one pending sighting, so a later flush still carries it.
		known[fp] = { kind = k, source = source, msg = msg, pending = 1 }
		table.insert(order, fp)
		stats.dropped += 1
		return nil
	end

	function tracker.flush(): { Report }
		local out = {}
		for _, fp in order do
			local e = known[fp]
			if e.pending > 0 then
				if not take() then
					break
				end
				table.insert(out, { kind = e.kind, source = e.source, fp = fp, msg = e.msg, count = e.pending })
				e.pending = 0
			end
		end
		return out
	end

	function tracker.stats(): Stats
		return table.clone(stats)
	end

	return tracker
end

--------------------------------------------------------------------------------------------------------- client relay

-- A client's report as the server accepts it, or nil. The message is scrubbed again with the server's names.
function ErrorReporterRules.cleanClient(kind: any, source: any, fp: any, count: any, msg: any, names: { string }?): Report?
	if type(kind) ~= "string" or not ErrorReporterRules.KINDS[kind] then
		return nil
	end
	if type(source) ~= "string" or #source < 1 or #source > ErrorReporterRules.MAX_SOURCE or string.find(source, "[^%w_]") then
		return nil
	end
	if type(fp) ~= "string" or not string.match(fp, "^%x%x%x%x%x%x%x%x$") then
		return nil
	end
	if type(count) ~= "number" or count ~= count or count < 1 or count > ErrorReporterRules.MAX_COUNT or count % 1 ~= 0 then
		return nil
	end
	if type(msg) ~= "string" or #msg > ErrorReporterRules.MAX_MSG * 2 then
		return nil
	end
	return { kind = kind, source = source, fp = string.lower(fp), msg = ErrorReporterRules.scrub(msg, names), count = count }
end

-- One log line for a report (server output; no player name, no user id).
function ErrorReporterRules.line(origin: string, build: string, r: Report): string
	return string.format("%s%s %s %s %s %s x%d: %s", ErrorReporterRules.TAG, origin, build, r.kind, r.source, r.fp, r.count, r.msg)
end

------------------------------------------------------------------------------------------------------------- memory

ErrorReporterRules.MEM_MAX_SAMPLES = 900 -- 15 min at 1 Hz; older samples drop
ErrorReporterRules.MEM_MAX_MB = 16384

export type MemStats = { samples: { number } }

function ErrorReporterRules.newMem(): MemStats
	return { samples = {} }
end

function ErrorReporterRules.addMem(m: MemStats, mb: any)
	if type(mb) ~= "number" or mb ~= mb or mb <= 0 or mb > ErrorReporterRules.MEM_MAX_MB then
		return
	end
	table.insert(m.samples, mb)
	if #m.samples > ErrorReporterRules.MEM_MAX_SAMPLES then
		table.remove(m.samples, 1)
	end
end

function ErrorReporterRules.clearMem(m: MemStats)
	table.clear(m.samples)
end

-- Peak and p95 in whole MB (nearest-rank), or nil with no samples.
function ErrorReporterRules.memSummary(m: MemStats): (number?, number?)
	local n = #m.samples
	if n == 0 then
		return nil, nil
	end
	local sorted = table.clone(m.samples)
	table.sort(sorted)
	local rank = math.clamp(math.ceil(0.95 * n), 1, n)
	return math.floor(sorted[n] + 0.5), math.floor(sorted[rank] + 0.5)
end

-- A client's per-race memory report as the server accepts it: whole MB, 1..MEM_MAX_MB, p95 <= peak.
function ErrorReporterRules.cleanMem(peak: any, p95: any): (number?, number?)
	local function ok(v: any): number?
		if type(v) ~= "number" or v ~= v or v < 1 or v > ErrorReporterRules.MEM_MAX_MB then
			return nil
		end
		return math.floor(v + 0.5)
	end
	local a, b = ok(peak), ok(p95)
	if not a or not b or b > a then
		return nil, nil
	end
	return a, b
end

return ErrorReporterRules
