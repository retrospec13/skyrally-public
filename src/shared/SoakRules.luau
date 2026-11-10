--!strict
-- Soak harness, pure rules (audit T1-12; no Roblox globals; tools/tests/soak_spec.luau runs it under Lune). The
-- Studio-only server/QASoak loops hub -> race -> results -> hub across maps for N cycles and samples the server and
-- every client at each step; this file says what a config means, which steps a run has, how a sample is shaped (so it
-- fits a workspace attribute and a RemoteEvent) and what a Studio-only gate looks like. Leak detection (monotonic
-- growth thresholds) runs offline in tools/soak_analysis.py on the sample series. Nothing here touches the race,
-- adhesion, walls, barriers, kill volumes or rescue.
local SoakRules = {}

SoakRules.RUN_ATTR = "QASoakRun" -- workspace attribute (JSON config), set from a Server-context command, Studio only
SoakRules.SEQ_ATTR = "QASoakSeq" -- workspace attribute the server bumps at each sample point; clients answer
SoakRules.PROGRESS_ATTR = "QASoakProgress" -- "running <step>/<total>" | "done" | "error:<why>"
SoakRules.SAMPLE_ATTR_PREFIX = "QASoakS" -- QASoakS1, QASoakS2 ... one JSON sample each
SoakRules.REMOTE_NAME = "QASoakLog" -- RemoteEvent in ReplicatedStorage: client -> server sample replies
SoakRules.DEFAULT_MAPS = table.freeze({ "dino4", "snow1", "island2", "forest1", "space4" })
SoakRules.MAX_CYCLES = 200
SoakRules.MAX_MAPS = 12
SoakRules.MAX_STRING = 160
SoakRules.MAX_ERRORS_KEPT = 3
SoakRules.MAX_DEPTH = 2 -- sample.clients.<name>.<metric>
SoakRules.MAX_JSON = 12000 -- a sample longer than this drops its per-client detail (attribute size)

export type Config = {
	cycles: number,
	maps: { string },
	raceSecs: number, -- 0 = run the race to the results; >0 = leave the race this many seconds after GO
	raceTimeout: number, -- give up waiting for the results and force the hub after this many seconds
	frameSecs: number, -- length of each client frame-time sample
	clientWait: number, -- how long the server waits for client replies at a sample point
	hubWait: number, -- how long the server waits for the hub after a return
}

export type Step = { n: number, cycle: number, index: number, key: string }

function SoakRules.allowed(isStudio: boolean): boolean
	return isStudio == true
end

local function num(v: any, default: number, lo: number, hi: number): number
	local n = tonumber(v)
	if n == nil or n ~= n then
		return default
	end
	return math.clamp(n, lo, hi)
end

-- JSON-decoded table (or nil) -> Config, or nil + reason. Map keys must look like TrackData module names.
function SoakRules.parseConfig(raw: any): (Config?, string)
	if raw == nil then
		raw = {}
	end
	if type(raw) ~= "table" then
		return nil, "not_table"
	end
	local maps: { string } = {}
	local given = raw.maps
	if given == nil then
		maps = table.clone(SoakRules.DEFAULT_MAPS) :: any
	elseif type(given) == "table" then
		for _, k in given do
			if type(k) ~= "string" or string.match(k, "^[%a][%w_]*$") == nil or #k > 24 then
				return nil, "bad_map"
			end
			if k ~= "hub0" then
				table.insert(maps, k)
			end
		end
	else
		return nil, "bad_maps"
	end
	if #maps == 0 or #maps > SoakRules.MAX_MAPS then
		return nil, "map_count"
	end
	return {
		cycles = math.floor(num(raw.cycles, 3, 1, SoakRules.MAX_CYCLES)),
		maps = maps,
		raceSecs = num(raw.raceSecs, 0, 0, 900),
		raceTimeout = num(raw.raceTimeout, 420, 30, 1200),
		frameSecs = num(raw.frameSecs, 3, 1, 10),
		clientWait = num(raw.clientWait, 20, 2, 60),
		hubWait = num(raw.hubWait, 120, 20, 300),
	},
		"ok"
end

-- Every race step in order: cycle 1 plays each map once, then cycle 2, ... (a hub visit follows each one).
function SoakRules.plan(cfg: Config): { Step }
	local steps: { Step } = {}
	for c = 1, cfg.cycles do
		for i, key in cfg.maps do
			table.insert(steps, { n = #steps + 1, cycle = c, index = i, key = key })
		end
	end
	return steps
end

function SoakRules.sampleAttr(seq: number): string
	return SoakRules.SAMPLE_ATTR_PREFIX .. tostring(seq)
end

-- Rounds numbers to 0.1, clamps strings, drops anything that is not a number, string or boolean, so a sample always
-- survives JSON and the attribute size limit. Nested tables (MAX_DEPTH levels) are shaped the same way; a list (an
-- errorTail) is kept at any depth as up to MAX_LIST shaped scalars (string-keyed only would turn every list into {}).
SoakRules.MAX_LIST = 20

local function scalar(v: any): any
	local t = type(v)
	if t == "number" then
		if v == v and v ~= math.huge and v ~= -math.huge then
			return math.floor(v * 10 + 0.5) / 10
		end
		return nil
	elseif t == "string" then
		return string.sub(v, 1, SoakRules.MAX_STRING)
	elseif t == "boolean" then
		return v
	end
	return nil
end

function SoakRules.shape(sample: any, depth: number?): any
	local d = depth or 0
	local out: { [string]: any } = {}
	for k, v in sample do
		if type(k) == "string" then
			if type(v) == "table" then
				if #v > 0 then
					local list = {}
					for i = 1, math.min(#v, SoakRules.MAX_LIST) do
						local s = scalar(v[i])
						if s ~= nil then
							table.insert(list, s)
						end
					end
					out[k] = list
				elseif d < SoakRules.MAX_DEPTH then
					out[k] = SoakRules.shape(v, d + 1)
				end
			else
				local s = scalar(v)
				if s ~= nil then
					out[k] = s
				end
			end
		end
	end
	return out
end

-- Keeps the first MAX_ERRORS_KEPT lines (clamped) of an error list; the count stays exact elsewhere.
function SoakRules.errorTail(lines: { string }): { string }
	local out: { string } = {}
	for i = 1, math.min(#lines, SoakRules.MAX_ERRORS_KEPT) do
		table.insert(out, string.sub(lines[i], 1, SoakRules.MAX_STRING))
	end
	return out
end

-- Which expected player names have not answered yet.
function SoakRules.missing(expected: { string }, answered: { [string]: boolean }): { string }
	local out: { string } = {}
	for _, name in expected do
		if not answered[name] then
			table.insert(out, name)
		end
	end
	return out
end

return SoakRules
