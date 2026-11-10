-- Compile gate: every .luau under src/, build/ and the repo-root builder_*.luau must compile, and no file may exceed
-- MAX_TOP_LOCALS top-level locals (Roblox fails a chunk at 200 registers: "Out of local registers", V13 CarController).
-- Standalone Lune script; run from the repo root (run_lune_tests.sh does).
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local MAX_TOP_LOCALS = 190

local files = {}
local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif name:match("%.luau$") then
			table.insert(files, path)
		end
	end
end
for _, root in { "src", "build" } do
	if fs.isDir(root) then
		walk(root)
	end
end
for _, name in fs.readDir(".") do
	if name:match("^builder_.*%.luau$") and fs.isFile(name) then
		table.insert(files, name)
	end
end
table.sort(files)

local failures = {}
for _, path in files do
	local source = fs.readFile(path)
	local ok, err = pcall(luau.compile, source)
	if not ok then
		table.insert(failures, path .. ": compile error: " .. (tostring(err):match("^[^\n]*")))
	end
	local count = 0
	for line in source:gmatch("[^\n]+") do
		if line:match("^local[%s]") then
			count += 1
		end
	end
	if count > MAX_TOP_LOCALS then
		table.insert(failures, string.format("%s: %d top-level locals (max %d)", path, count, MAX_TOP_LOCALS))
	end
end

for _, f in failures do
	print("FAIL " .. f)
end
print(string.format("compile_spec: %d files, %d failures", #files, #failures))
process.exit(if #failures == 0 then 0 else 1)
