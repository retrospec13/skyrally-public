--!nocheck
-- Terrain bakes (perf pass 2026-10-19, L42): every compiled builder with a height grid has a baked TerrainRegion mounted
-- in default.project.json under ServerStorage.TerrainBakes.<MAP-ID>, and the bake's TerrainHash equals the builder's
-- TERRAIN_HASH. A stale or missing bake does not break the game (the builder computes the terrain as before) but puts
-- 6-9 s back on every first build, so it fails here: rerun tools/bake_terrain.py (after lane sync + launch).
-- Standalone Lune script, run from the repo root by tools/tests/run_lune_tests.sh.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local failures = 0
local function check(ok: boolean, msg: string)
	if ok then
		print("  PASS " .. msg)
	else
		failures += 1
		print("  FAIL " .. msg)
	end
end

local project = serde.decode("json", fs.readFile("default.project.json"))
local mounted = {}
local bakes = project.tree.ServerStorage and project.tree.ServerStorage.TerrainBakes
for name, node in bakes or {} do
	if type(node) == "table" and node["$path"] then
		mounted[name] = node["$path"]
	end
end

for key, node in project.tree.ServerScriptService.Maps do
	if type(node) ~= "table" or not node["$path"] then
		continue
	end
	local builder = fs.readFile(node["$path"])
	local hash = string.match(builder, 'local TERRAIN_HASH = "(%x+)"')
	local name = string.match(builder, '"name":"([^"]+)"')
	check(hash ~= nil and name ~= nil, key .. ": builder stamps TERRAIN_HASH and a map name (regenerate with tools/map/adapt.py)")
	if not (hash and name) then
		continue
	end
	local hasTerrain = string.find(builder, '"heights":', 1, true) ~= nil
	local path = mounted[name]
	if not hasTerrain then
		check(path == nil, key .. ": no height grid, so no bake is mounted")
		continue
	end
	check(path ~= nil, key .. ": bake mounted as ServerStorage.TerrainBakes." .. name)
	if path and fs.isFile(path) then
		local roots = roblox.deserializeModel(fs.readFile(path))
		local region = roots[1]
		check(#roots == 1 and region.ClassName == "TerrainRegion", key .. ": " .. path .. " holds one TerrainRegion")
		local got = region:GetAttribute("TerrainHash")
		check(got == hash, string.format("%s: bake hash %s matches builder %s (else rerun tools/bake_terrain.py %s)", key, tostring(got), hash, key))
		check(typeof(region:GetAttribute("Corner")) == "Vector3", key .. ": bake records its corner cell")
	elseif path then
		check(false, key .. ": " .. path .. " exists")
	end
end

print(string.format("terrain_bake_spec: %d failure(s)", failures))
process.exit(if failures == 0 then 0 else 1)
