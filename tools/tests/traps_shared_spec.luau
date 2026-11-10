--!nocheck
-- (nocheck: this runs under Lune, whose @lune requires the Roblox-configured luau-lsp cannot resolve)
-- Lune spec for the shared trap rules (docs/audits/traps_summary.md):
--   1. X-05 / D4-11 kit/DecorQuery: visible non-collidable decor loses CanQuery; the deck (TrackRibbon), hazards,
--      invisible volumes, collidable parts and Road-tagged models keep it. Built on REAL @lune/roblox instances.
--   2. G9 CoinChallenge: the swept pickup (the path since the previous check, SWEEP_MAX like KeyPickup), and an empty
--      coin list never completes the challenge (D4-04: 0 >= 0 awarded the coin token).
-- X-04 (lap rollover respawn frame) is specced in loop_spec.luau, next to the other completePlayerLap cases.
-- Run: tools/tests/run_lune_tests.sh tools/tests/traps_shared_spec.luau   (standalone: plain `lune run` also works)
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
local V3 = roblox.Vector3

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd

local tests = {}
local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end
local function check(cond, msg)
	if not cond then
		error("check failed: " .. msg, 2)
	end
end
local function eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

-- Loads a module from source with the few globals these two modules touch.
local heartbeat = { handlers = {} }
function heartbeat:Connect(fn)
	table.insert(self.handlers, fn)
	return { Disconnect = function() end }
end
local services = {
	RunService = { Heartbeat = heartbeat },
	HttpService = {
		JSONEncode = function(_, v)
			return tostring(#v)
		end,
	},
}
local gameStub = {
	GetService = function(_, name)
		return services[name] or error("no stub service " .. name)
	end,
}
local workspaceStub = { attrs = {} }
function workspaceStub:SetAttribute(k, v)
	self.attrs[k] = v
end
function workspaceStub:GetAttribute(k)
	return self.attrs[k]
end
-- Shared modules a server module requires at load (CoinChallenge: ModeScopeRules, RaceAttr; systems audit v32 T0-2):
-- ReplicatedStorage.Shared:WaitForChild(name) hands back a token that `require` loads from src/shared.
local load
local sharedCache = {}
local sharedFolder = {
	WaitForChild = function(_, name)
		return { __shared = name }
	end,
}
services.ReplicatedStorage = {
	WaitForChild = function(_, name)
		assert(name == "Shared", "ReplicatedStorage child " .. tostring(name))
		return sharedFolder
	end,
}
services.Players = { LocalPlayer = nil }
local function requireStub(target)
	assert(type(target) == "table" and target.__shared, "require of a non-Shared module")
	local name = target.__shared
	if sharedCache[name] == nil then
		sharedCache[name] = load("src/shared/" .. name .. ".luau")
	end
	return sharedCache[name]
end
function load(rel)
	local env = {
		game = gameStub,
		workspace = workspaceStub,
		Vector3 = V3,
		print = function() end,
		warn = function() end,
		require = requireStub,
		script = { Parent = sharedFolder },
	}
	return luau.load(fs.readFile(root .. "/" .. rel), { debugName = rel, environment = env })()
end

local DecorQuery = load("src/server/kit/DecorQuery.luau")
local CoinChallenge = load("src/server/CoinChallenge.luau")

------------------------------------------------------------------------------------------------------------------------
-- 1. DecorQuery

local function part(parent, name, props)
	local p = Instance.new(props and props.class or "Part")
	p.Name = name
	p.CanCollide = if props and props.collide ~= nil then props.collide else false
	p.Transparency = props and props.alpha or 0
	p.Parent = parent
	return p
end

local function folder(parent, name, class)
	local f = Instance.new(class or "Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- A map root shaped like a built car map: compiled art (Models under group folders), the adapter's deck, hazards,
-- checkpoints and a loaded mesh.
local function mapRoot()
	local r = folder(nil, "ISLAND-2")
	local art = folder(folder(r, "Galleon"), "GalleonGangway", "Model")
	local ramp = part(art, "Ramp", { collide = true })
	local post = part(art, "RopePost")
	local rope = part(art, "RopeBeam", { class = "Part" })
	local lantern = part(art, "Lantern", { alpha = 0.3 })
	local ghost = part(art, "Ghost", { alpha = 1 })
	local ribbon = folder(r, "TrackRibbon")
	local paver = part(ribbon, "Paver_1_1_1")
	local seg = part(ribbon, "TrackSeg_1", { collide = true })
	local hazards = folder(r, "Hazards")
	local lava = part(hazards, "StartLavaBed", { alpha = 0.6 })
	lava:SetAttribute("HazardType", "LethalLava")
	local seaFloor = part(art, "LavaSeaFloor")
	local boardwalk = folder(r, "Boardwalk", "Model")
	boardwalk:SetAttribute("Road", true)
	local plank = part(folder(boardwalk, "Planks", "Model"), "Plank")
	local mesh = part(folder(r, "Landmarks"), "StoneSauropod", { class = "MeshPart" })
	-- A lookalike folder name deeper down is NOT the deck: only the root's own TrackRibbon is kept.
	local fakeRibbon = folder(art, "TrackRibbon")
	local fakePaver = part(fakeRibbon, "Paver_9_9_9")
	return r, {
		ramp = ramp, post = post, rope = rope, lantern = lantern, ghost = ghost, paver = paver, seg = seg, lava = lava,
		seaFloor = seaFloor, plank = plank, mesh = mesh, fakePaver = fakePaver,
	}
end

test("X-05: visible non-collidable decor (posts, ropes, lanterns, meshes) loses CanQuery", function()
	local r, p = mapRoot()
	local n = DecorQuery.apply(r)
	check(not p.post.CanQuery, "gangway rope post")
	check(not p.rope.CanQuery, "rope beam")
	check(not p.lantern.CanQuery, "semi-transparent lantern")
	check(not p.mesh.CanQuery, "non-collidable MeshPart (D4-11 sauropod)")
	check(not p.fakePaver.CanQuery, "a nested folder named TrackRibbon is not the deck")
	eq(n, 5, "changed count")
end)

test("X-05: the deck, hazards, invisible volumes, collidable parts and Road models stay queryable", function()
	local r, p = mapRoot()
	DecorQuery.apply(r)
	check(p.paver.CanQuery, "deck paver (the road surface the wheel probes stand on)")
	check(p.seg.CanQuery and p.seg.CanCollide, "collidable deck beam")
	check(p.ramp.CanQuery and p.ramp.CanCollide, "collidable ramp")
	check(p.lava.CanQuery, "HazardType volume (the lava check is a raycast)")
	check(p.seaFloor.CanQuery, "LavaSeaFloor by name")
	check(p.ghost.CanQuery, "invisible parts are left to whoever built them")
	check(p.plank.CanQuery, "a part under a Road = true model")
end)

test("X-05: the rule is idempotent and only ever clears CanQuery", function()
	local r, p = mapRoot()
	DecorQuery.apply(r)
	eq(DecorQuery.apply(r), 0, "second pass changes nothing")
	check(not p.post.CanCollide and p.post.Transparency == 0, "collision and looks untouched")
	check(DecorQuery.isDecor(p.post, r) == false, "already off is not counted again")
	check(DecorQuery.isDecor(folder(r, "Empty"), r) == false, "non-parts are ignored")
end)

------------------------------------------------------------------------------------------------------------------------
-- 2. CoinChallenge

local function coins()
	return {
		{ id = "Coin_1", pos = V3.new(0, 20, -100) },
		{ id = "Coin_2", pos = V3.new(0, 20, -300) },
	}
end

test("G9: a fast pass between two checks collects the coin (swept, not point-sampled)", function()
	local held = {}
	-- 18 studs per check at 9 off-centre: neither sample is within 11 (13.5 each), the path is.
	local a, b = V3.new(9, 20, -91), V3.new(9, 20, -109)
	check((a - coins()[1].pos).Magnitude > CoinChallenge.RADIUS_CAR, "first sample outside")
	check((b - coins()[1].pos).Magnitude > CoinChallenge.RADIUS_CAR, "second sample outside")
	eq(#CoinChallenge.collectAlong(coins(), held, CoinChallenge.RADIUS_CAR, b, nil), 0, "point test alone misses it")
	local taken = CoinChallenge.collectAlong(coins(), held, CoinChallenge.RADIUS_CAR, b, a)
	eq(#taken, 1, "swept test takes it")
	eq(taken[1], "Coin_1", "the coin passed")
	check(held.Coin_1 == true and held.Coin_2 == nil, "held set updated, the far coin untouched")
	eq(#CoinChallenge.collectAlong(coins(), held, CoinChallenge.RADIUS_CAR, b, a), 0, "taken once")
end)

test("G9: a jump longer than SWEEP_MAX is a teleport: only its end point counts", function()
	local held = {}
	local from, to = V3.new(0, 20, -60), V3.new(0, 20, -60 - CoinChallenge.SWEEP_MAX - 20)
	eq(#CoinChallenge.collectAlong(coins(), held, CoinChallenge.RADIUS_PLANE, to, from), 0, "respawn across a coin")
	eq(#CoinChallenge.collectAlong(coins(), held, CoinChallenge.RADIUS_PLANE, V3.new(0, 20, -105), V3.new(0, 20, -600)), 1, "end point still counts")
end)

test("G9: radii (plane 14, car 11) and the off-path miss", function()
	eq(CoinChallenge.RADIUS_PLANE, 14, "F9 plane radius")
	eq(CoinChallenge.RADIUS_CAR, 11, "S4-02 car radius")
	eq(CoinChallenge.SWEEP_MAX, 60, "KeyPickup's sweep limit")
	local held = {}
	eq(#CoinChallenge.collectAlong(coins(), held, 11, V3.new(12, 20, -110), V3.new(12, 20, -90)), 0, "12 off a car coin: no")
	eq(#CoinChallenge.collectAlong(coins(), held, 14, V3.new(12, 20, -110), V3.new(12, 20, -90)), 1, "12 off a plane coin: yes")
	eq(CoinChallenge.segmentDistance(V3.new(0, 0, 0), V3.new(0, 0, 0), V3.new(3, 4, 0)), 5, "degenerate segment")
end)

test("D4-04: an empty coin list never completes the challenge; a full held set does", function()
	check(not CoinChallenge.isComplete({}, {}), "0 coins, nothing held")
	check(not CoinChallenge.isComplete({}, { Coin_1 = true }), "0 coins, stray id held")
	check(not CoinChallenge.isComplete(coins(), nil), "no held set")
	check(not CoinChallenge.isComplete(coins(), { Coin_1 = true, Coin_9 = true }), "ids off the list do not count")
	check(CoinChallenge.isComplete(coins(), { Coin_1 = true, Coin_2 = true }), "all held")
	check(not CoinChallenge.allCollected({ Name = "P" }), "no active challenge")
end)

test("D4-04: a started challenge with no coins reports CoinsTotal 0 and never all-collected", function()
	if not Instance then
		return
	end
	-- start() builds Instances; give the module the real constructor for this case.
	local env = {
		game = gameStub,
		workspace = workspaceStub,
		Vector3 = V3,
		Instance = Instance,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
		typeof = roblox.typeof or typeof,
		print = function() end,
		warn = function() end,
		require = requireStub,
		script = { Parent = sharedFolder },
	}
	local CC = luau.load(fs.readFile(root .. "/src/server/CoinChallenge.luau"), { debugName = "CoinChallenge", environment = env })()
	local player = { Name = "P", attrs = {} }
	function player:SetAttribute(k, v)
		self.attrs[k] = v
	end
	function player:GetAttribute(k)
		return self.attrs[k]
	end
	local hull = { Parent = true, Position = V3.new(0, 0, 0) }
	CC.start(folder(nil, "Root"), {}, "plane", function()
		return { [player] = { hull = hull } }
	end)
	eq(workspaceStub.attrs.CoinsTotal, 0, "CoinsTotal 0")
	for _, fn in heartbeat.handlers do
		fn(0.016)
	end
	check(not CC.allCollected(player), "0 >= 0 must not award all coins")
	CC.stop()
end)

local passed, failed = 0, 0
for _, t in tests do
	local ok, err = pcall(t.fn)
	if ok then
		passed += 1
		print("  PASS " .. t.name)
	else
		failed += 1
		print("  FAIL " .. t.name .. "\n       " .. tostring(err))
	end
end
print(string.format("traps_shared_spec: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
