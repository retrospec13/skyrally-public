--!strict
-- Per-group races: a client file must read the local player's race through RaceAttr.mine / RaceAttr.changed, never
-- straight off workspace, for every name RaceInstanceRules.SHIMMED lists (RaceMode, ActiveTrackId, ...). A direct
-- workspace read sees the hub's value (or another group's) once RaceFlowRules.PER_GROUP is on.
-- A genuinely server-wide read goes on ALLOW below with the reason (see docs/design/PER_GROUP_RACES.md, client reads).
-- Plain lune script: run via tools/tests/run_lune_tests.sh (exit 1 on any offender).
local fs = require("@lune/fs")
local process = require("@lune/process")

-- file -> reason. Empty: every client read of a shimmed name goes through RaceAttr.
local ALLOW: { [string]: string } = {}
-- file -> { exact line text (trimmed) -> reason }: one line kept on workspace on purpose. Any other line of the file is
-- still checked.
local ALLOW_LINE: { [string]: { [string]: string } } = {
	["src/client/CarController.luau"] = {
		['return RespawnRules.tideAt(pos, published, workspace:GetAttribute("BattleCenter"), workspace:GetAttribute("BattleReturnRadius"))'] = "the respawn (rescue) path is untouched under the owner's hard rule; the workspace TideLevel it guards is never published today (Water publishes its tide on the TideWater part), so the branch is dormant; listed for the Studio pass (PER_GROUP_RACES.md per-group readiness)",
	},
}

local rules = fs.readFile("src/shared/RaceInstanceRules.luau")
local block = string.match(rules, "RaceInstanceRules%.SHIMMED = {(.-)} :: ")
assert(block, "SHIMMED table not found")
local names: { string } = {}
for name in string.gmatch(block, "([%w_]+) = true") do
	table.insert(names, name)
end
assert(#names >= 17 and table.find(names, "RaceMode"), "SHIMMED parse found too few names: " .. #names)

local offenders: { string } = {}
for _, file in fs.readDir("src/client") do
	if string.match(file, "%.luau$") and not ALLOW["src/client/" .. file] then
		local path = "src/client/" .. file
		local n = 0
		for line in string.gmatch(fs.readFile(path) .. "\n", "([^\n]*)\n") do
			n += 1
			local code = string.gsub(line, "%-%-.*$", "")
			local keep = ALLOW_LINE[path]
			if keep and keep[(string.gsub(code, "^%s+", ""))] then
				continue
			end
			for _, name in names do
				for _, call in { "GetAttribute", "GetAttributeChangedSignal" } do
					for _, w in { "workspace", "Workspace" } do
						if string.find(code, w .. ":" .. call .. '("' .. name .. '")', 1, true) then
							table.insert(offenders, string.format("%s:%d reads workspace %s(%q)", path, n, call, name))
						end
					end
				end
			end
		end
	end
end

if #offenders > 0 then
	print("FAIL client_race_reads_spec: use RaceAttr.mine / RaceAttr.changed (or allowlist with a reason):")
	for _, o in offenders do
		print("  " .. o)
	end
	process.exit(1)
end
print(string.format("ok client_race_reads_spec (%d names, no direct workspace reads)", #names))
