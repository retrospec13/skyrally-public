--!strict
-- Per-group races, server side (systems audit v32 T0-2): a server file reads and writes a race attribute
-- (RaceInstanceRules.SHIMMED: RaceMode, RaceGoTime, CoinsTotal, Battle*, ...) through RaceAttr.here / RaceAttr.set (the
-- running RaceScope's instance root per group, workspace on the single path) or RaceAttr.get(name, player). A direct
-- workspace access sees the hub's value (or writes over it) once RaceFlowRules.PER_GROUP is on.
-- The direct accesses left are pinned below by file and COUNT with the reason each is safe per group; a new one fails
-- this spec until it is converted or listed (docs/design/PER_GROUP_RACES.md "Per-group readiness").
-- Plain lune script: run via tools/tests/run_lune_tests.sh (exit 1 on any offender).
local fs = require("@lune/fs")
local process = require("@lune/process")

type Allow = { count: number, why: string }
local ALLOW: { [string]: Allow } = {
	["src/server/TrackDirector.luau"] = {
		count = 29,
		why = "the whole-server flow (load, lobby, votes, race end, joiner, leaver) runs only with PER_GROUP false; per group the workspace values are the hub's (RaceMode 'hub') and every group's flow is RaceGroups'",
	},
	["src/server/init.server.luau"] = {
		count = 6,
		why = "boot prints and the single path's replayCurrent (incl. its liveReplayBlock mode read); per group a replay goes through RaceGroups (replayScope)",
	},
	["src/server/CarServer.luau"] = {
		count = 2,
		why = "refreshVehicle publishes the hub / single-path vehicle when workspace ActiveTrackId changes; per group RaceGroups sets ActiveVehicle on the instance root",
	},
	["src/server/FlightServer.luau"] = {
		count = 2,
		why = "setupPlayer seats a joiner, and per group a joiner always lands in the hub (workspace is the hub's)",
	},
	["src/server/HubBoard.luau"] = { count = 1, why = "hub sign: workspace RaceMode is the hub's per group" },
	["src/server/PaintShopStand.luau"] = { count = 1, why = "hub stand: workspace RaceMode is the hub's per group" },
	["src/server/PlazaBands.luau"] = { count = 1, why = "hub bands: workspace RaceMode is the hub's per group" },
	["src/server/StormVendorStand.luau"] = { count = 1, why = "hub stand: workspace RaceMode is the hub's per group" },
	["src/server/kit/ItemEffects.luau"] = {
		count = 1,
		why = "freeRoam's single-path fallback; per group ItemEffects.scopeMode answers the stepping instance's mode",
	},
	["src/server/QASoak.luau"] = { count = 2, why = "Studio QA soak drives the single-path whole-server flow (inHub, RaceGoTime wait); not run with PER_GROUP" },
	["src/server/LiveOps.luau"] = {
		count = 1,
		why = "shutdown 'racing' check reads the whole-server mode; per group it sees the hub's value, so PER_GROUP needs it routed through RaceGroups (listed in the per-group readiness checklist) before it is switched on",
	},
	["src/server/QAMultiplayer.luau"] = { count = 1, why = "Studio QA of the single-path switch" },
	["src/server/RaceManager.luau"] = {
		count = 1,
		why = "the workspace ActiveTrackId signal clears the single path's checkpoints; per group each instance loads its own list in its scope",
	},
	["src/server/StormCup.luau"] = {
		count = 1,
		why = "Storm Cup v1 is a whole-server cup by design (per group it is refused and storm race v2 runs instead)",
	},
}

local rules = fs.readFile("src/shared/RaceInstanceRules.luau")
local block = string.match(rules, "RaceInstanceRules%.SHIMMED = {(.-)} :: ")
assert(block, "SHIMMED table not found")
local names: { string } = {}
for name in string.gmatch(block, "([%w_]+) = true") do
	table.insert(names, name)
end
assert(table.find(names, "CoinsTotal") and table.find(names, "BattleState"), "the mode systems' attributes are shimmed")

local function walk(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			walk(path, out)
		elseif string.match(entry, "%.luau$") then
			table.insert(out, path)
		end
	end
end
local files: { string } = {}
walk("src/server", files)
table.sort(files)

local failures: { string } = {}
local counts: { [string]: number } = {}
local lines: { [string]: { string } } = {}
for _, path in files do
	local n = 0
	for line in string.gmatch(fs.readFile(path) .. "\n", "([^\n]*)\n") do
		n += 1
		local code = string.gsub(line, "%-%-.*$", "")
		for _, name in names do
			for _, call in { "GetAttribute", "SetAttribute", "GetAttributeChangedSignal" } do
				for _, w in { "workspace", "Workspace" } do
					local needle = w .. ":" .. call .. '("' .. name .. '"'
					local from = 1
					while true do
						local at = string.find(code, needle, from, true)
						if not at then
							break
						end
						counts[path] = (counts[path] or 0) + 1
						lines[path] = lines[path] or {}
						table.insert(lines[path], string.format("%s:%d %s(%q)", path, n, call, name))
						from = at + #needle
					end
				end
			end
		end
	end
end

for path, c in counts do
	local allow = ALLOW[path]
	if not allow then
		table.insert(failures, string.format("%s: %d direct workspace race attribute access(es), none allowed:", path, c))
		for _, l in lines[path] do
			table.insert(failures, "    " .. l)
		end
	elseif c ~= allow.count then
		table.insert(failures, string.format("%s: %d direct accesses, %d allowed (%s); convert to RaceAttr or update the pin:", path, c, allow.count, allow.why))
		for _, l in lines[path] do
			table.insert(failures, "    " .. l)
		end
	end
end
for path, allow in ALLOW do
	if (counts[path] or 0) == 0 then
		table.insert(failures, string.format("%s: pinned at %d but has none: drop it from ALLOW", path, allow.count))
	end
end

if #failures > 0 then
	print("FAIL server_race_reads_spec: use RaceAttr.here / RaceAttr.set / RaceAttr.get (or pin with a reason):")
	for _, f in failures do
		print("  " .. f)
	end
	process.exit(1)
end
local total = 0
for _, c in counts do
	total += c
end
print(string.format("ok server_race_reads_spec (%d names, %d pinned direct accesses in %d files)", #names, total, #files))
