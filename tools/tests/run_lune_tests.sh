#!/usr/bin/env bash
# Runs every tools/tests/*_spec.luau (or the specs given as arguments) under Lune with a tiny assert harness and
# Roblox stubs, so server logic built on injectable interfaces is tested on the lane host without Studio.
# Usage: tools/tests/run_lune_tests.sh [spec paths...]     Exit 1 when any test fails. SKYRALLY_TEST_VERBOSE=1 echoes
# module prints.
#
# Spec contract: a harness spec has a top-level `return function(h)`; h.test registers cases, h.require("src/...luau")
# loads a module with Roblox-style globals (game, workspace, script, task, Enum, require), resolving
# ReplicatedStorage.Shared.<Name> to src/shared/<Name>.luau and script.Parent.<Name> to a sibling file; h.newScheduler
# gives fake time, h.fakePlayer an attribute-recording Player, h.fake(path, tbl) a stand-in module for a path. Modules
# and specs see Vector3/CFrame/Color3 from
# @lune/roblox. Any other *_spec.luau runs as a plain `lune run` script.
set -u
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/harness.luau" <<'LUAU'
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local specPath = process.args[1]
local verbose = process.env.SKYRALLY_TEST_VERBOSE == "1"
local captured = {}

local function capture(prefix: string, ...: any)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local line = prefix .. table.concat(parts, " ")
	table.insert(captured, line)
	if verbose then
		print("    | " .. line)
	end
end

local function signal()
	local s = { handlers = {} }
	function s:Connect(fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	function s:Fire(...)
		for _, fn in ipairs(self.handlers) do
			fn(...)
		end
	end
	return s
end

local function attributeHolder(base)
	base.attrs = base.attrs or {}
	base.history = base.history or {}
	function base:SetAttribute(name, value)
		self.attrs[name] = value
		table.insert(self.history, name .. "=" .. tostring(value))
	end
	function base:GetAttribute(name)
		return self.attrs[name]
	end
	function base:GetAttributeChangedSignal()
		return signal()
	end
	return base
end

-- Instance stubs mapped onto the repo: a folder is a directory, a ModuleScript is a .luau file.
local makeFolder, makeModuleRef, lazyRef
local function childOf(dir, name)
	local file = dir .. "/" .. name .. ".luau"
	if fs.isFile(file) then
		return makeModuleRef(file, dir)
	end
	if fs.isDir(dir .. "/" .. name) then
		return makeFolder(dir .. "/" .. name, name)
	end
	return nil
end
makeFolder = function(dir, name)
	local folder = { Name = name, ClassName = "Folder", __dir = dir }
	function folder:WaitForChild(child)
		return childOf(dir, child) or error("stub WaitForChild: no " .. tostring(child) .. " under " .. dir, 2)
	end
	function folder:FindFirstChild(child)
		return childOf(dir, child)
	end
	return setmetatable(folder, {
		-- Dot access (script.Parent.FlightServer, script.Parent.kit.X) runs inside a metamethod, where Lune's async fs
		-- may not yield: hand back a lazy reference that is both a module (__path, resolved when required) and a folder
		-- (further dot access). Method calls (WaitForChild, FindFirstChild) still check the disk.
		__index = function(_, key)
			return lazyRef(dir, key, folder)
		end,
	})
end
lazyRef = function(dir, key, parent)
	local sub = dir .. "/" .. key
	local ref = {
		Name = key,
		ClassName = "ModuleScript",
		__path = sub .. ".luau",
		__dir = sub,
		Parent = parent,
		IsA = function(_self, className)
			return className == "ModuleScript" or className == "Instance"
		end,
	}
	function ref:WaitForChild(child)
		return childOf(sub, child) or error("stub WaitForChild: no " .. tostring(child) .. " under " .. sub, 2)
	end
	function ref:FindFirstChild(child)
		return childOf(sub, child)
	end
	return setmetatable(ref, {
		__index = function(_, k)
			return lazyRef(sub, k, ref)
		end,
	})
end
makeModuleRef = function(path, dir)
	return {
		Name = path:match("([^/]+)%.luau$"),
		ClassName = "ModuleScript",
		__path = path,
		Parent = makeFolder(dir, dir:match("([^/]+)$")),
		IsA = function(_self, className)
			return className == "ModuleScript" or className == "Instance"
		end,
	}
end

local Players = attributeHolder({ ClassName = "Players", PlayerAdded = signal(), PlayerRemoving = signal(), list = {} })
function Players:GetPlayers()
	return table.clone(self.list)
end
local RunService = { ClassName = "RunService", studio = true, Heartbeat = signal(), Stepped = signal(), RenderStepped = signal() }
function RunService:IsStudio()
	return self.studio
end
function RunService:IsServer()
	return true
end
function RunService:IsClient()
	return false
end
-- No API access under Lune: anything that reaches the real DataStore path fails loudly, like Studio without access.
local DataStoreService = { ClassName = "DataStoreService" }
function DataStoreService:GetDataStore(name)
	error("DataStoreService stub: no API access under Lune (" .. tostring(name) .. ")")
end
function DataStoreService:GetRequestBudgetForRequestType()
	return 100
end
local HttpService = { ClassName = "HttpService", guids = 0 }
function HttpService:GenerateGUID()
	self.guids += 1
	return string.format("stub-guid-%04d", self.guids)
end
local ReplicatedStorage = { ClassName = "ReplicatedStorage", Shared = makeFolder("src/shared", "Shared") }
function ReplicatedStorage:WaitForChild(name)
	return self[name] or error("stub ReplicatedStorage: no " .. tostring(name), 2)
end
ReplicatedStorage.FindFirstChild = ReplicatedStorage.WaitForChild
local workspaceStub = attributeHolder({ ClassName = "Workspace", Name = "Workspace" })
function workspaceStub:FindFirstChild()
	return nil
end

local services = {
	Players = Players,
	RunService = RunService,
	DataStoreService = DataStoreService,
	HttpService = HttpService,
	ReplicatedStorage = ReplicatedStorage,
	Workspace = workspaceStub,
	ServerScriptService = makeFolder("src/server", "ServerScriptService"),
}
local game = { JobId = "", PlaceId = 0, PlaceVersion = 0, closers = {} }
function game:GetService(name)
	return services[name] or error("stub game:GetService: no stub for " .. tostring(name), 2)
end
function game:BindToClose(fn)
	table.insert(self.closers, fn)
end

local Enum = setmetatable({}, {
	__index = function(_, enumName)
		return setmetatable({}, {
			__index = function(_, item)
				return enumName .. "." .. item
			end,
		})
	end,
})

local moduleCache = {}
local loadModule
local function stubRequire(target)
	if type(target) == "table" and target.__path then
		return loadModule(target.__path)
	elseif type(target) == "string" then
		return loadModule(target)
	end
	error("stub require: unsupported target " .. tostring(target), 2)
end

local function envFor(path)
	local dir = path:match("^(.*)/[^/]+$") or "."
	return {
		game = game,
		workspace = workspaceStub,
		script = makeModuleRef(path, dir),
		require = stubRequire,
		task = task,
		Enum = Enum,
		-- Roblox datatypes from @lune/roblox, so pure modules that build vectors (battle arenas, spawns) load as-is.
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		print = function(...)
			capture("", ...)
		end,
		warn = function(...)
			capture("WARN ", ...)
		end,
	}
end

loadModule = function(path)
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end
	local chunk = luau.load(fs.readFile(path), { debugName = path, environment = envFor(path) })
	local result = chunk()
	moduleCache[path] = result
	return result
end

-- Deterministic clock and task scheduler: sleep() parks the calling coroutine until advance() reaches its wake time.
local function newScheduler(start)
	local s = { now = start or 1000, queue = {}, owned = setmetatable({}, { __mode = "k" }), seq = 0 }
	local function resume(co, ...)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			error(debug.traceback(co, tostring(err)), 0)
		end
	end
	function s.clock()
		return s.now
	end
	function s.spawn(fn, ...)
		local co = coroutine.create(fn)
		s.owned[co] = true
		resume(co, ...)
	end
	function s.sleep(dt)
		local co = coroutine.running()
		if not s.owned[co] then
			error("fake sleep called outside a scheduler task; wrap the call in sched.run or sched.spawn", 2)
		end
		s.seq += 1
		table.insert(s.queue, { co = co, at = s.now + math.max(dt or 0, 0), seq = s.seq })
		coroutine.yield()
	end
	local function nextIndex(limit)
		local best
		for i, e in ipairs(s.queue) do
			if e.at <= limit then
				local b = best and s.queue[best]
				if not b or e.at < b.at or (e.at == b.at and e.seq < b.seq) then
					best = i
				end
			end
		end
		return best
	end
	function s.advance(dt)
		local target = s.now + dt
		while true do
			local i = nextIndex(target)
			if not i then
				break
			end
			local e = table.remove(s.queue, i)
			if e.at > s.now then
				s.now = e.at
			end
			resume(e.co)
		end
		s.now = target
	end
	-- Runs fn as a task and advances time event by event until it returns; returns its results.
	function s.run(fn, limit)
		local done, results = false, nil
		local start = s.now
		s.spawn(function()
			results = table.pack(fn())
			done = true
		end)
		while not done do
			local i = nextIndex(math.huge)
			if not i or s.queue[i].at - start > (limit or 3600) then
				error("sched.run: task still waiting after " .. tostring(limit or 3600) .. " fake seconds", 2)
			end
			s.advance(math.max(0, s.queue[i].at - s.now))
		end
		return table.unpack(results, 1, results.n)
	end
	function s.pending()
		return #s.queue
	end
	return s
end

local function deepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(v)
	if type(v) ~= "table" then
		return if type(v) == "string" then string.format("%q", v) else tostring(v)
	end
	local keys = {}
	for k in pairs(v) do
		table.insert(keys, k)
	end
	table.sort(keys, function(x, y)
		return tostring(x) < tostring(y)
	end)
	local parts = {}
	for _, k in ipairs(keys) do
		table.insert(parts, tostring(k) .. "=" .. show(v[k]))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local tests = {}
local h = {}
function h.test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end
function h.eq(actual, expected, msg)
	if not deepEqual(actual, expected) then
		error(string.format("%sexpected %s, got %s", if msg then msg .. ": " else "", show(expected), show(actual)), 2)
	end
end
function h.ok(cond, msg)
	if not cond then
		error("assertion failed" .. (if msg then ": " .. msg else ""), 2)
	end
end
function h.contains(haystack, needle, msg)
	local found = false
	if type(haystack) == "string" then
		found = string.find(haystack, needle, 1, true) ~= nil
	else
		for _, line in ipairs(haystack) do
			if string.find(tostring(line), needle, 1, true) then
				found = true
				break
			end
		end
	end
	if not found then
		error(string.format("%s%q not found", if msg then msg .. ": " else "", needle), 2)
	end
end
function h.count(list, needle)
	local n = 0
	for _, line in ipairs(list) do
		if string.find(tostring(line), needle, 1, true) then
			n += 1
		end
	end
	return n
end
h.require = loadModule
-- h.fake("src/server/X.luau", tbl): every later require of that path (h.require, script.Parent.X) gets tbl. For
-- server modules whose real header builds Instances (FlightServer, PlaneBuilder, ...).
function h.fake(path, mod)
	moduleCache[path] = mod
end
h.readFile = fs.readFile
-- h.json(text): decode a JSON document (map plans) for specs that check placement against them.
function h.json(text)
	return serde.decode("json", text)
end
-- h.roblox: @lune/roblox (Instance.new and friends) for specs that build real instance trees (remote_clone_spec).
h.roblox = roblox
h.logs = captured
h.newScheduler = newScheduler
h.stubs = { game = game, Players = Players, RunService = RunService, DataStoreService = DataStoreService, workspace = workspaceStub }
function h.fakePlayer(userId, name)
	local p = attributeHolder({ UserId = userId, Name = name or ("Player" .. tostring(userId)), ClassName = "Player", Parent = Players })
	function p:leave()
		self.Parent = nil
	end
	return p
end

local specFn = loadModule(specPath)
assert(type(specFn) == "function", specPath .. " must return function(h)")
specFn(h)
-- A spec that registers nothing proves nothing; count it as a failure rather than a vacuous pass.
if #tests == 0 then
	print(specPath .. ": registered no tests")
	process.exit(1)
end

local passed, failed = 0, 0
for _, t in ipairs(tests) do
	table.clear(captured)
	local ok, err = pcall(t.fn)
	if ok then
		passed += 1
		print("  PASS " .. t.name)
	else
		failed += 1
		print("  FAIL " .. t.name .. "\n       " .. tostring(err):gsub("\n", "\n       "))
	end
end
print(string.format("%s: %d passed, %d failed", specPath, passed, failed))
process.exit(if failed == 0 then 0 else 1)
LUAU

specs=("$@")
if [ ${#specs[@]} -eq 0 ]; then
	shopt -s nullglob
	specs=(tools/tests/*_spec.luau)
fi
if [ ${#specs[@]} -eq 0 ]; then
	echo "no specs found under tools/tests"
	exit 1
fi
status=0
for spec in "${specs[@]}"; do
	# Harness specs `return function(h)`; anything else is a standalone Lune script judged by its exit code.
	if grep -qE '^return function\(h' "$spec"; then
		echo "== $spec (harness)"
		lune run "$tmp/harness.luau" "$spec" || status=1
	else
		echo "== $spec (standalone)"
		if lune run "$spec"; then echo "$spec: exit 0"; else echo "$spec: FAILED"; status=1; fi
	fi
done
[ $status -eq 0 ] && echo "LUNE_TESTS=PASS" || echo "LUNE_TESTS=FAIL"
exit $status
