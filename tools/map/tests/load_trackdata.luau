--!nocheck
-- (nocheck: this runs under lune, whose @lune requires the Roblox-configured luau-lsp cannot resolve)
-- Lune check that a generated TrackData.luau parses and evaluates with real Roblox datatypes.
-- Usage: lune run tools/map/tests/load_trackdata.luau <TrackData.luau> <expectedWaypoints>
-- Prints "OK <waypoints> <length>" or "FAIL <reason>" and exits non-zero on failure.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local function fail(msg: string)
	print("FAIL " .. msg)
	process.exit(1)
end

local path, expected = process.args[1], tonumber(process.args[2])
if not path or not expected then
	fail("usage: load_trackdata.luau <TrackData.luau> <expectedWaypoints>")
end

local source = fs.readFile(path)
local ok, chunk = pcall(luau.load, source, {
	debugName = path,
	environment = { Vector3 = Vector3, CFrame = CFrame, math = math },
})
if not ok then
	fail("parse: " .. tostring(chunk))
end
local td = (chunk :: any)()
if type(td) ~= "table" then
	fail("module did not return a table")
end

local wps = td.waypoints
if #wps ~= expected then
	fail(string.format("waypoints %d ~= %d", #wps, expected))
end
for i, w in wps do
	if typeof(w.pos) ~= "Vector3" or typeof(w.tangent) ~= "Vector3" or type(w.station) ~= "number" then
		fail("waypoint " .. i .. " has wrong field types")
	end
	if i > 1 and w.station <= wps[i - 1].station then
		fail("stations not increasing at " .. i)
	end
end
local first, last = wps[1], wps[#wps]
if (first.pos - last.pos).Magnitude > 1e-6 or math.abs(last.station - td.length) > 1e-3 then
	fail("closing waypoint is not the first at station = length")
end

-- Gameplay CFrames face along the route: LookVector equals the station tangent
for _, cp in td.checkpoints do
	if typeof(cp.cf) ~= "CFrame" or typeof(cp.size) ~= "Vector3" then
		fail("checkpoint " .. tostring(cp.index) .. " types")
	end
end
for _, ring in td.rings do
	if math.abs(ring.cf.LookVector.Magnitude - 1) > 1e-3 or math.abs(ring.cf.UpVector:Dot(ring.cf.LookVector)) > 1e-3 then
		fail("ring " .. ring.name .. " CFrame is not orthonormal")
	end
end
if #td.startGrid ~= 8 then
	fail("startGrid has " .. #td.startGrid .. " slots")
end
if typeof(td.finish.pos) ~= "Vector3" then
	fail("finish.pos is not a Vector3")
end
print(string.format("OK %d %.4f", #wps, td.length))
