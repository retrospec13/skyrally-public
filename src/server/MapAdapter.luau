--!strict
-- SkyRally map adapter (MAP_PLAN_SCHEMA section 4, TRACK_PIPELINE P3). Turns one TrackData table (section 3) into the
-- playable map under Workspace.Maps.<id> after the compiled 30MAPS builder has placed the art.
-- Order: wait MapBuilt_<id> -> lighting -> shells -> deck (+ alternate lines) -> hazards -> gameplay -> meshes ->
-- modelAttributes -> fx -> corridor carve -> WaypointsData + _G.SkyRallyTracks -> TrackRegistry -> TrackReady.
-- Every step and every entry inside a step is pcall-isolated: a failure is logged, counted in the report and skipped,
-- so one bad op never aborts the rest of the map.

local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LightingProfiles = require(Shared:WaitForChild("LightingProfiles"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local CourseCarve = require(script.Parent.CourseCarve)
local Deck = require(script.Parent.kit.Deck)
local DecorQuery = require(script.Parent.kit.DecorQuery)
local Gameplay = require(script.Parent.kit.Gameplay)
local ArtSwap = require(script.Parent.kit.ArtSwap)
local Backdrop = require(script.Parent.kit.Backdrop)
local WorldArt = require(script.Parent.kit.WorldArt)

local MapAdapter = {}

MapAdapter.MAP_BUILT_TIMEOUT = 60

-- Marks what the adapter created so a rebuild removes exactly that and never the compiler's art.
local OWNED_ATTR = "AdapterOwned"
-- Set by the meshes step from what actually loaded; a plan value must never mask a FALLBACK.
local RUNTIME_ATTRS: { [string]: boolean } = { AssetState = true, HasTripoMesh = true }

-- shellClear: what a plan's "Clear" shell op does (RaceInstanceRules.shellClear: "all", "skip", "region"; nil = "all",
-- the single-race behaviour); clearBox: the map's own terrain box for "region".
export type Options = { activate: boolean?, mapBuiltTimeout: number?, shellClear: string?, clearBox: RaceInstanceRules.TerrainBox? }
-- MapAdapter.activate (a cached load, L42): adapterParts is the first build's count, kept for _G.SkyRallyTracks.
export type ActivateOptions = { activate: boolean?, adapterParts: number? }
export type Report = {
	id: string,
	ok: boolean,
	mapBuilt: boolean,
	counts: { [string]: number },
	errors: { string },
	parts: number,
	adapterParts: number,
	corridorIntrusions: number,
	root: Instance?,
	-- Seconds per step in run order (perf pass 2026-10-19: printed as one "[SkyRally][MAP] <id> steps ..." line).
	times: { { name: string, s: number } },
}

-- ---------------------------------------------------------------------------------------------------------------
-- Value conversion: TrackData writes Luau constructors, but plan blocks copied verbatim may still hold JSON arrays.

local function toVector3(v: any): Vector3
	if typeof(v) == "Vector3" then
		return v
	elseif type(v) == "table" and #v >= 3 then
		return Vector3.new(v[1], v[2], v[3])
	end
	error("expected Vector3 or [x,y,z], got " .. typeof(v))
end

local function toCFrame(v: any): CFrame
	if typeof(v) == "CFrame" then
		return v
	elseif typeof(v) == "Vector3" then
		return CFrame.new(v)
	elseif type(v) == "table" and #v == 12 then
		return CFrame.new(v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12])
	elseif type(v) == "table" and #v == 3 then
		return CFrame.new(v[1], v[2], v[3])
	end
	error("expected CFrame or 12 components, got " .. typeof(v))
end

local function toColor3(v: any): Color3
	if typeof(v) == "Color3" then
		return v
	elseif type(v) == "string" then
		local hex = string.match(v, "^#?(%x%x%x%x%x%x)$")
		if hex then
			local r = tonumber(string.sub(hex, 1, 2), 16) :: number
			local g = tonumber(string.sub(hex, 3, 4), 16) :: number
			local b = tonumber(string.sub(hex, 5, 6), 16) :: number
			return Color3.fromRGB(r, g, b)
		end
	elseif type(v) == "table" and #v >= 3 then
		if v[1] > 1 or v[2] > 1 or v[3] > 1 then
			return Color3.fromRGB(v[1], v[2], v[3])
		end
		return Color3.new(v[1], v[2], v[3])
	end
	error("expected colour \"#rrggbb\", got " .. tostring(v))
end

local function toMaterial(v: any): Enum.Material
	if typeof(v) == "EnumItem" then
		return v :: any
	end
	local ok, m = pcall(function()
		return (Enum.Material :: any)[v]
	end)
	if ok and typeof(m) == "EnumItem" then
		return m :: any
	end
	error("unknown material " .. tostring(v))
end

-- Accepts a number, [a,b], {seq={{t,v,env},...}} (extract_builder format) or a list of {t,v[,env]} keypoints.
local function toNumberSequence(v: any): NumberSequence
	if typeof(v) == "NumberSequence" then
		return v
	elseif type(v) == "number" then
		return NumberSequence.new(v)
	elseif type(v) == "table" then
		local list = if v.seq then v.seq else v
		if #list == 2 and type(list[1]) == "number" then
			return NumberSequence.new(list[1], list[2])
		end
		local kps = {}
		for _, k in list do
			table.insert(kps, NumberSequenceKeypoint.new(k[1], k[2], k[3] or 0))
		end
		return NumberSequence.new(kps)
	end
	error("expected NumberSequence value, got " .. typeof(v))
end

local function toColorSequence(v: any): ColorSequence
	if typeof(v) == "ColorSequence" then
		return v
	elseif type(v) == "string" or typeof(v) == "Color3" then
		return ColorSequence.new(toColor3(v))
	elseif type(v) == "table" then
		local list = if v.seq then v.seq else v
		if #list == 2 and type(list[1]) ~= "table" then
			return ColorSequence.new(toColor3(list[1]), toColor3(list[2]))
		end
		local kps = {}
		for _, k in list do
			table.insert(kps, ColorSequenceKeypoint.new(k[1], toColor3(k[2])))
		end
		return ColorSequence.new(kps)
	end
	error("expected ColorSequence value, got " .. typeof(v))
end

local function toNumberRange(v: any): NumberRange
	if typeof(v) == "NumberRange" then
		return v
	elseif type(v) == "number" then
		return NumberRange.new(v)
	elseif type(v) == "table" then
		return NumberRange.new(v[1], v[2] or v[1])
	end
	error("expected NumberRange value, got " .. typeof(v))
end

-- Converts a plan value to the type the property currently holds (read from the instance itself).
local function convertProp(current: any, value: any): any
	local t = typeof(current)
	if t == "Color3" then
		return toColor3(value)
	elseif t == "ColorSequence" then
		return toColorSequence(value)
	elseif t == "NumberSequence" then
		return toNumberSequence(value)
	elseif t == "NumberRange" then
		return toNumberRange(value)
	elseif t == "EnumItem" then
		if typeof(value) == "EnumItem" then
			return value
		end
		return (current.EnumType :: any)[value]
	elseif t == "Vector3" then
		return toVector3(value)
	elseif t == "Vector2" then
		if typeof(value) == "Vector2" then
			return value
		end
		return Vector2.new(value[1], value[2])
	elseif t == "CFrame" then
		return toCFrame(value)
	elseif t == "number" then
		return tonumber(value)
	elseif t == "string" then
		return tostring(value)
	end
	return value
end

local function applyProps(inst: Instance, props: { [string]: any }?): { string }
	local errs: { string } = {}
	local list: { [string]: any } = props or {}
	for key, value in list do
		local ok, err = pcall(function()
			local obj = inst :: any
			-- An unreadable property cannot tell us its type; the raw value is then the best guess.
			local readOk, cur = pcall(function()
				return obj[key]
			end)
			obj[key] = if readOk then convertProp(cur, value) else value
		end)
		if not ok then
			table.insert(errs, string.format("%s.%s: %s", inst.ClassName, key, tostring(err)))
		end
	end
	return errs
end

-- Attribute values: [x,y,z] -> Vector3, 12 numbers -> CFrame; strings stay strings (no guessing at colours).
local function toAttribute(v: any): any
	if type(v) == "table" then
		if #v == 3 then
			return toVector3(v)
		elseif #v == 12 then
			return toCFrame(v)
		end
		error("unsupported attribute table of length " .. tostring(#v))
	end
	return v
end

-- ---------------------------------------------------------------------------------------------------------------
-- Instance tree helpers

local function findPath(root: Instance, path: string): Instance?
	local cur: Instance? = root
	for seg in string.gmatch(path, "[^/]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(seg)
	end
	return cur
end

-- Creates missing segments: top level as Folder (schema groups are Folders), deeper ones as leafClass.
local function ensurePath(root: Instance, path: string, leafClass: string): Instance
	local cur: Instance = root
	local depth = 0
	for seg in string.gmatch(path, "[^/]+") do
		depth += 1
		local nxt: Instance? = cur:FindFirstChild(seg)
		if not nxt then
			local created = Instance.new((if depth == 1 then "Folder" else leafClass) :: any)
			created.Name = seg
			created:SetAttribute(OWNED_ATTR, true)
			created.Parent = cur
			nxt = created
		end
		cur = nxt :: Instance
	end
	return cur
end

local function adapterFolder(root: Instance, name: string): Instance
	local existing = root:FindFirstChild(name)
	if existing then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	f:SetAttribute(OWNED_ATTR, true)
	f.Parent = root
	return f
end

local function clearOwned(root: Instance): number
	local n = 0
	for _, d in root:GetDescendants() do
		if d.Parent and d:GetAttribute(OWNED_ATTR) == true then
			d:Destroy()
			n += 1
		end
	end
	return n
end

local function getRoot(id: string): Instance
	local maps = workspace:FindFirstChild("Maps")
	if not maps then
		maps = Instance.new("Folder")
		maps.Name = "Maps"
		maps.Parent = workspace
	end
	local root = (maps :: Instance):FindFirstChild(id)
	if root then
		return root
	end
	local created = Instance.new("Folder")
	created.Name = id
	created.Parent = maps
	return created
end

local function isFxHolder(p: BasePart): boolean
	for _, ch in p:GetChildren() do
		if ch:IsA("Light") or ch:IsA("Beam") or ch:IsA("ParticleEmitter") or ch:IsA("Attachment") then
			return true
		end
	end
	return false
end

-- Hide keeps the original values in attributes so a later show restores them exactly.
local function setGroupVisible(group: Instance, visible: boolean)
	local list = group:GetDescendants()
	table.insert(list, group)
	for _, d in list do
		if d:IsA("BasePart") then
			if visible then
				local saved = d:GetAttribute("FallbackTransparency")
				if type(saved) == "number" then
					d.Transparency = saved
					d.CanCollide = d:GetAttribute("FallbackCanCollide") == true
					d.CanQuery = d:GetAttribute("FallbackCanQuery") ~= false
					d.CanTouch = d:GetAttribute("FallbackCanTouch") ~= false
				elseif d.Transparency >= 1 and not isFxHolder(d) then
					d.Transparency = 0
				end
			else
				if d:GetAttribute("FallbackTransparency") == nil then
					d:SetAttribute("FallbackTransparency", d.Transparency)
					d:SetAttribute("FallbackCanCollide", d.CanCollide)
					d:SetAttribute("FallbackCanQuery", d.CanQuery)
					d:SetAttribute("FallbackCanTouch", d.CanTouch)
				end
				d.Transparency = 1
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		elseif d:IsA("Decal") then
			d.Transparency = if visible then 0 else 1
		elseif d:IsA("Light") or d:IsA("ParticleEmitter") or d:IsA("Beam") then
			(d :: any).Enabled = visible
		end
	end
end

-- Same rule as tools/map30/build_plan.py ready_attribute(): attribute names allow only [A-Za-z0-9_], so the compiled
-- builder of "DINO-4" sets MapBuilt_DINO_4. Waiting on the raw id would never see it.
function MapAdapter.readyAttribute(id: string): string
	return "MapBuilt_" .. (string.gsub(id, "[^A-Za-z0-9_]", "_"))
end

-- T1-2: TrackDirector sets this when the builder throws, so the MapBuilt wait stops at once (the build reads as partial).
-- Not MapBuilt_<id> = false: every compiled builder sets that when it STARTS ("building"), so false never meant failure.
function MapAdapter.failedAttribute(id: string): string
	return "MapBuildFailed_" .. (string.gsub(id, "[^A-Za-z0-9_]", "_"))
end

-- Wakes on the attribute itself (a 0.25 s poll used to add up to a quarter second to every first build).
local function waitForMapBuilt(id: string, timeout: number): boolean
	local attr = MapAdapter.readyAttribute(id)
	local failedAttr = MapAdapter.failedAttribute(id)
	if workspace:GetAttribute(attr) == true then
		return true
	end
	if workspace:GetAttribute(failedAttr) == true then
		return false
	end
	local signal = Instance.new("BindableEvent")
	local conn = workspace:GetAttributeChangedSignal(attr):Connect(function()
		if workspace:GetAttribute(attr) == true then
			signal:Fire()
		end
	end)
	local failConn = workspace:GetAttributeChangedSignal(failedAttr):Connect(function()
		if workspace:GetAttribute(failedAttr) == true then
			signal:Fire()
		end
	end)
	local timer = task.delay(timeout, function()
		signal:Fire()
	end)
	if workspace:GetAttribute(attr) ~= true and workspace:GetAttribute(failedAttr) ~= true then
		signal.Event:Wait()
	end
	conn:Disconnect()
	failConn:Disconnect()
	pcall(task.cancel, timer)
	signal:Destroy()
	return workspace:GetAttribute(attr) == true
end

-- ---------------------------------------------------------------------------------------------------------------
-- TrackData normalization (per entry; a bad entry keeps its raw value and fails, logged, in its own step)

local function conv(f: (any) -> any, v: any): any
	if v == nil then
		return nil
	end
	local ok, r = pcall(f, v)
	return if ok then r else v
end

function MapAdapter.normalize(trackData: any): any
	local td = table.clone(trackData)

	local wps = {}
	local src = trackData.waypoints or {}
	for _, w in src do
		table.insert(wps, { pos = conv(toVector3, w.pos), bank = w.bank or 0, station = w.station or 0, tangent = conv(toVector3, w.tangent) })
	end
	-- Missing tangents are derived the way builder_dino4 did: towards the next waypoint, last one -Z.
	for i, w in wps do
		if typeof(w.tangent) ~= "Vector3" then
			local nxt = wps[math.min(i + 1, #wps)]
			local diff = if typeof(nxt.pos) == "Vector3" and typeof(w.pos) == "Vector3" then nxt.pos - w.pos else Vector3.zero
			w.tangent = if diff.Magnitude > 0.01 then diff.Unit else Vector3.new(0, 0, -1)
		end
	end
	td.waypoints = wps
	if type(td.length) ~= "number" and #wps > 0 then
		td.length = wps[#wps].station
	end

	local function mapList(list: any, fn: (any) -> ()): { any }
		local out = {}
		for _, e in list or {} do
			local c = table.clone(e)
			fn(c)
			table.insert(out, c)
		end
		return out
	end
	td.checkpoints = mapList(trackData.checkpoints, function(c)
		c.cf = conv(toCFrame, c.cf)
		c.size = conv(toVector3, c.size)
	end)
	td.rings = mapList(trackData.rings, function(c)
		c.cf = conv(toCFrame, c.cf)
	end)
	td.pads = mapList(trackData.pads, function(c)
		c.cf = conv(toCFrame, c.cf)
	end)
	td.pods = mapList(trackData.pods, function(c)
		c.pos = conv(toVector3, c.pos)
	end)
	td.alternates = mapList(trackData.alternates, function(c)
		local pts = {}
		for _, p in c.points or {} do
			table.insert(pts, conv(toVector3, p))
		end
		c.points = pts
	end)
	local grid = {}
	for _, cf in trackData.startGrid or {} do
		table.insert(grid, conv(toCFrame, cf))
	end
	td.startGrid = grid
	if type(trackData.finish) == "table" then
		td.finish = table.clone(trackData.finish)
		td.finish.pos = conv(toVector3, trackData.finish.pos)
	end
	-- Section 3 writes shells as the op list; the plan block wraps it in {ops = ...}.
	local shells = trackData.shells
	td.shellOps = if type(shells) == "table" and shells.ops then shells.ops else (shells or {})
	return td
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shells (Terrain), applied in plan order after the compiled builder

local function pair(v: any, default: { number }): (number, number)
	if typeof(v) == "Vector2" then
		return v.X, v.Y
	elseif type(v) == "table" then
		return v[1], v[2]
	end
	return default[1], default[2]
end

-- RouteCavern: the builder's per-segment cavern walls and roof (builder_dino4 ~632-638), one wall pair and one roof
-- slab every `every` segments whose start station lies in [fromStation, toStation]. Returns the FillBlock count.
function MapAdapter.routeCavern(waypoints: { any }, op: any, terrain: Terrain?): number
	local t = terrain or workspace.Terrain
	local every: number = op.every or 3
	local fromSt: number = op.fromStation or 0
	local toSt: number = op.toStation or math.huge
	local wallOffset: number = op.wallOffset or 142
	local wallY: number = op.wallY or 34
	local wallW, wallH = pair(op.wallSize, { 48, 136 })
	local lenFactor: number = op.wallLenFactor or 4.2
	local roofOffset: number = op.roofOffset or 146
	local roofW, roofH = pair(op.roofSize, { 256, 40 })
	local roofExtra: number = op.roofExtraLen or 24
	local wallMat = toMaterial(op.wallMat or "Sandstone")
	local roofMat = toMaterial(op.roofMat or "Rock")

	local fills = 0
	for i = 1, #waypoints - 1 do
		local wp1 = waypoints[i]
		local p1: Vector3 = wp1.pos
		local p2: Vector3 = waypoints[i + 1].pos
		local segLen = (p2 - p1).Magnitude
		if segLen > 0.1 and i % every == 0 and wp1.station >= fromSt and wp1.station <= toSt then
			local mid = (p1 + p2) * 0.5
			local archCF = CFrame.lookAt(mid, p2)
			local spanLen = segLen * lenFactor
			t:FillBlock(archCF * CFrame.new(-wallOffset, wallY, 0), Vector3.new(wallW, wallH, spanLen), wallMat)
			t:FillBlock(archCF * CFrame.new(wallOffset, wallY, 0), Vector3.new(wallW, wallH, spanLen), wallMat)
			t:FillBlock(archCF * CFrame.new(0, roofOffset, 0), Vector3.new(roofW, roofH, spanLen + roofExtra), roofMat)
			fills += 3
		end
	end
	return fills
end

-- Sealed-cavern construction (ART_BAR construction rules: continuous, sealed Terrain shells). Three route-driven ops:
-- FillRouteBounds fills a solid mass around the whole course, CarveRouteTube carves an organic tube along the route
-- (radius varied by smooth noise, an upper lobe for headroom), RouteFloorFill lays a floor material under the tube.
-- Chambers and openings are ordinary FillBlock/FillBall Air ops in the plan. The flight corridor is carved last.
local function routeBounds(waypoints: { any }): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, w in waypoints do
		lo = lo:Min(w.pos)
		hi = hi:Max(w.pos)
	end
	return lo, hi
end

function MapAdapter.fillRouteBounds(waypoints: { any }, op: any, terrain: Terrain?): number
	local t = terrain or workspace.Terrain
	local lo, hi = routeBounds(waypoints)
	local margin: number = op.margin or 280
	local yMin: number = op.yMin or 0
	local top: number = hi.Y + (op.above or 230)
	local a = Vector3.new(lo.X - margin, yMin, lo.Z - margin)
	local b = Vector3.new(hi.X + margin, top, hi.Z + margin)
	local mat = toMaterial(op.mat or "Sandstone")
	if op.crownThickness then
		-- a crown layer of a second material across the top of the mass (cavern ceilings read darker)
		local c = op.crownThickness :: number
		t:FillBlock(CFrame.new((a + Vector3.new(b.X, top - c, b.Z)) * 0.5), Vector3.new(b.X - a.X, top - c - yMin, b.Z - a.Z), mat)
		t:FillBlock(CFrame.new(Vector3.new((a.X + b.X) * 0.5, top - c * 0.5, (a.Z + b.Z) * 0.5)), Vector3.new(b.X - a.X, c, b.Z - a.Z), toMaterial(op.crownMat or "Rock"))
		return 2
	end
	t:FillBlock(CFrame.new((a + b) * 0.5), b - a, mat)
	return 1
end

function MapAdapter.carveRouteTube(waypoints: { any }, op: any, terrain: Terrain?): number
	local t = terrain or workspace.Terrain
	local rMin: number = op.radiusMin or 66
	local rMax: number = op.radiusMax or 112
	local lift: number = op.lift or 26
	local upperLift: number = op.upperLift or 70
	local upperScale: number = op.upperScale or 0.8
	local freq: number = op.noiseFreq or 0.13
	local seed: number = op.seed or 7
	local fromSt: number = op.fromStation or 0
	local toSt: number = op.toStation or math.huge
	local calls = 0
	for i, w in waypoints do
		if w.station >= fromSt and w.station <= toSt then
			local n = math.noise(i * freq + seed * 0.37, seed * 0.11) * 0.5 + 0.5
			local r = rMin + n * (rMax - rMin)
			t:FillBall(w.pos + Vector3.new(0, lift, 0), r, Enum.Material.Air)
			calls += 1
			if i % 2 == 0 then
				t:FillBall(w.pos + Vector3.new(0, upperLift + n * 30, 0), r * upperScale, Enum.Material.Air)
				calls += 1
			end
		end
	end
	return calls
end

function MapAdapter.routeFloorFill(waypoints: { any }, op: any, terrain: Terrain?): number
	local t = terrain or workspace.Terrain
	local depth: number = op.depth or 44
	local width: number = op.width or 230
	local thick: number = op.thickness or 10
	local mat = toMaterial(op.mat or "CrackedLava")
	local fromSt: number = op.fromStation or 0
	local toSt: number = op.toStation or math.huge
	local calls = 0
	for i = 1, #waypoints - 1 do
		local a: Vector3, b: Vector3 = waypoints[i].pos, waypoints[i + 1].pos
		local len = (b - a).Magnitude
		if len > 0.5 and waypoints[i].station >= fromSt and waypoints[i].station <= toSt then
			local cf = CFrame.lookAt((a + b) * 0.5, b, Vector3.yAxis)
			t:FillBlock(cf * CFrame.new(0, -depth, 0), Vector3.new(width, thick, len + 40), mat)
			calls += 1
			-- Crust islands (concept: dark cooled crust with bright channels between), deterministic per segment.
			if op.crustMat and (i % (op.crustEvery or 2)) == 0 then
				local rng = Random.new((op.seed or 11) * 1000 + i)
				for _ = 1, op.crustPerSegment or 2 do
					local side = (rng:NextNumber() * 2 - 1) * width * 0.42
					local along = (rng:NextNumber() - 0.5) * len
					local r = (op.crustRadius or 22) * (0.6 + rng:NextNumber() * 0.8)
					t:FillCylinder(cf * CFrame.new(side, -depth + thick * 0.5 + 1, along), 4, r, toMaterial(op.crustMat))
					calls += 1
				end
			end
		end
	end
	return calls
end

-- A "Clear" op per RaceInstanceRules.shellClear: the whole Terrain (single race), nothing, or Air over the map's own box
-- only (per group, where the hub and other zones share the Terrain). Returns the number of Terrain calls.
local function applyClear(t: Terrain, mode: string?, box: RaceInstanceRules.TerrainBox?): number
	if mode == nil or mode == "all" then
		t:Clear()
		return 1
	elseif mode == "region" and box then
		local calls = 0
		for _, c in RaceInstanceRules.clearChunks(box) do
			t:FillBlock(CFrame.new((c.lo + c.hi) * 0.5), c.hi - c.lo, Enum.Material.Air)
			calls += 1
		end
		return calls
	end
	return 0
end

-- Returns the number of Terrain calls the op made. clearMode/clearBox: Options.shellClear/clearBox (nil: the whole Terrain).
function MapAdapter.applyShellOp(op: any, waypoints: { any }, terrain: Terrain?, clearMode: string?, clearBox: RaceInstanceRules.TerrainBox?): number
	local t = terrain or workspace.Terrain
	local kind = op.op
	if kind == "Clear" then
		return applyClear(t, clearMode, clearBox)
	elseif kind == "SetMaterialColor" then
		t:SetMaterialColor(toMaterial(op.mat), toColor3(op.color))
	elseif kind == "FillBlock" then
		t:FillBlock(toCFrame(op.cf), toVector3(op.size), toMaterial(op.mat))
	elseif kind == "FillBall" then
		t:FillBall(toVector3(op.center), op.r, toMaterial(op.mat))
	elseif kind == "FillCylinder" then
		t:FillCylinder(toCFrame(op.cf), op.h, op.r, toMaterial(op.mat))
	elseif kind == "FillWedge" then
		t:FillWedge(toCFrame(op.cf), toVector3(op.size), toMaterial(op.mat))
	elseif kind == "RouteCavern" then
		return MapAdapter.routeCavern(waypoints, op, t)
	elseif kind == "FillRouteBounds" then
		return MapAdapter.fillRouteBounds(waypoints, op, t)
	elseif kind == "CarveRouteTube" then
		return MapAdapter.carveRouteTube(waypoints, op, t)
	elseif kind == "RouteFloorFill" then
		return MapAdapter.routeFloorFill(waypoints, op, t)
	else
		error("unknown shell op " .. tostring(kind))
	end
	return 1
end

-- ---------------------------------------------------------------------------------------------------------------
-- Report and steps, shared by build and activate

local function newReport(id: string): Report
	return {
		id = id,
		ok = false,
		mapBuilt = false,
		counts = {},
		errors = {},
		parts = 0,
		adapterParts = 0,
		corridorIntrusions = 0,
		root = nil,
		times = {},
	}
end

-- "[SkyRally][MAP] <id> steps wait=9.41 lighting=0.00 ... total=12.80": where a build or an activation spent its time.
local function logTimes(report: Report, label: string, t0: number)
	local parts: { string } = {}
	for _, e in report.times do
		table.insert(parts, string.format("%s=%.2f", e.name, e.s))
	end
	local line = string.format("%s %s total=%.2f", label, table.concat(parts, " "), os.clock() - t0)
	print(string.format("[SkyRally][MAP] %s steps %s", report.id, line))
	local root = report.root
	if root then
		root:SetAttribute("BuildSteps", line) -- QA: readable after the output has scrolled (tools/boot_probe.py)
	end
end

local function stepper(report: Report): ((string, () -> number) -> (), (string, any) -> ())
	local id = report.id
	local function logError(where: string, err: any)
		local msg = string.format("%s: %s", where, tostring(err))
		table.insert(report.errors, msg)
		warn(string.format("[SkyRally][MAP] ERROR %s %s", id, msg))
	end

	-- Per-step results are mirrored onto the map root (AdapterStep_<name>) so a joined client can prove what the live
	-- server built: server output never reaches a client log (2026-10-18 v11: terrain missing in the published client).
	local function step(name: string, fn: () -> number)
		local t0 = os.clock()
		local ok, res = pcall(fn)
		table.insert(report.times, { name = name, s = os.clock() - t0 })
		if ok then
			report.counts[name] = res
		else
			report.counts[name] = report.counts[name] or 0
			logError(name, res)
		end
		local r = report.root
		if r then
			r:SetAttribute("AdapterStep_" .. name, string.format("%s n=%s %.2fs%s", if ok then "ok" else "ERROR", tostring(report.counts[name]), os.clock() - t0, if ok then "" else (" " .. string.sub(tostring(res), 1, 120))))
		end
	end
	return step, logError
end

-- What a build changes outside Workspace.Maps.<id> and Terrain voxels (Lighting, MaterialService, _G, the registry):
-- one function each, so a cached load (MapAdapter.activate, L42) redoes exactly these.
local function applyLighting(td: any, id: string): number
	-- Per group (economy v3 phase 2) every client applies its own zone's profile (client/ZoneLighting); the server's
	-- Lighting would replicate one zone's look onto every map.
	if not RaceInstanceRules.serverWritesLighting(RaceFlowRules.PER_GROUP) then
		return 0
	end
	if not LightingProfiles.apply(td.lighting or id) then
		error("profile " .. tostring(td.lighting or id) .. " missing or incomplete")
	end
	return 1
end

-- Zone terrain materials: base-material overrides and their tints (the global half of the materials step).
local function applyTerrainOverrides(m: any): number
	if type(m) ~= "table" or not RaceInstanceRules.serverWritesLighting(RaceFlowRules.PER_GROUP) then
		return 0 -- per group: client/ZoneLighting applies the zone's overrides and water locally
	end
	local MaterialService = game:GetService("MaterialService")
	local n = 0
	-- Optional per-map water look (colour, transparency, reflectance) over what the builder set from terrain.water:
	-- changing terrain.water or the builder template would invalidate the baked terrain hash, so the plan carries it here.
	if type(m.waterReflectance) == "number" then
		workspace.Terrain.WaterReflectance = m.waterReflectance
	end
	if type(m.waterTransparency) == "number" then
		workspace.Terrain.WaterTransparency = m.waterTransparency
	end
	if type(m.waterColor) == "string" then
		workspace.Terrain.WaterColor = toColor3(m.waterColor)
	end
	for base, variant in (m.terrainOverrides or {}) :: { [string]: string } do
		MaterialService:SetBaseMaterialOverride(toMaterial(base), variant)
		-- Per-material tint (terrainColors) wins over the single terrainColor: low-graphics clients render terrain
		-- with this colour only, high-graphics clients multiply it with the neutral detail map.
		local tint = (m.terrainColors and m.terrainColors[base]) or m.terrainColor
		if tint then
			workspace.Terrain:SetMaterialColor(toMaterial(base), toColor3(tint))
		end
		n += 1
	end
	return n
end

local function publishGlobals(id: string, td: any, root: Instance, adapterParts: number): number
	local g = _G :: any
	g.SkyRallyTracks = g.SkyRallyTracks or {}
	g.SkyRallyTracks[id] = {
		waypoints = td.waypoints,
		measuredLength = td.length,
		partCount = adapterParts,
		root = root,
	}
	return 1
end

local function registerTrack(id: string, td: any, root: Instance, activate: boolean?): number
	local mod = Shared:FindFirstChild("TrackRegistry")
	if not mod then
		error("ReplicatedStorage.Shared.TrackRegistry not found")
	end
	local TrackRegistry = (require :: any)(mod)
	TrackRegistry.register({
		id = id,
		root = root,
		length = td.length,
		startCFrames = td.startGrid,
		finish = td.finish,
		laps = td.laps,
		key = td.key,
		zone = td.zone,
		vehicle = td.vehicle,
		lavaFloorY = if type(td.lavaFloorY) == "number" then td.lavaFloorY else nil,
	})
	if activate then
		TrackRegistry.setActive(id)
	end
	return 1
end

local function countParts(report: Report, root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			report.parts += 1
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------

function MapAdapter.build(trackData: any, opts: Options?): Report
	local o: Options = opts or {}
	local id = tostring(trackData.id)
	local report = newReport(id)
	local step, logError = stepper(report)
	local buildT0 = os.clock()

	-- 1. The compiled builder signals completion; a missing signal is an error but the map still builds.
	local timeout = o.mapBuiltTimeout or MapAdapter.MAP_BUILT_TIMEOUT
	report.mapBuilt = waitForMapBuilt(id, timeout)
	table.insert(report.times, { name = "wait", s = os.clock() - buildT0 })
	if not report.mapBuilt then
		logError("wait", string.format("%s not set after %s s; continuing with what exists", MapAdapter.readyAttribute(id), tostring(timeout)))
	end

	local root = getRoot(id)
	report.root = root
	-- Client gull templates (clients cannot LoadAsset): loaded once per server on their own thread, idempotent.
	WorldArt.publishBirdTemplates()
	-- A rebuild of a live root must not read as ready while its parts are being replaced.
	root:SetAttribute("TrackReady", false)
	report.counts.cleared = clearOwned(root)
	local td = MapAdapter.normalize(trackData)
	local waypoints: { any } = td.waypoints

	-- RaceManager pivots a Model that carries BasePivotPos to that point plus a small sway yaw every Heartbeat, so the
	-- adapter can find such a model mid-sway. Plan cfs are rest-pose coordinates: the model is put back at rest in
	-- the same synchronous stretch as the placement (no Heartbeat runs in between); otherwise the placed part keeps
	-- a random yaw offset for good. The rest pivot comes from the model's attributes or, before the modelAttributes
	-- step has run, from the plan entry for its path.
	local function restPivotOf(model: Instance): CFrame?
		local pos: any = model:GetAttribute("BasePivotPos")
		local yaw: any = model:GetAttribute("BaseYawDeg")
		if typeof(pos) ~= "Vector3" then
			for _, entry in td.modelAttributes or {} do
				if type(entry.path) == "string" and type(entry.attrs) == "table" and findPath(root, entry.path) == model then
					local ok, v = pcall(toVector3, entry.attrs.BasePivotPos)
					if ok then
						pos, yaw = v, entry.attrs.BaseYawDeg
					end
				end
			end
		end
		if typeof(pos) ~= "Vector3" then
			return nil
		end
		return CFrame.new(pos) * CFrame.Angles(0, math.rad(if type(yaw) == "number" then yaw else 0), 0)
	end

	-- Returns true when the nearest swayed Model at or above `inst` was pivoted back to rest. Only a model whose pivot
	-- already sits on its base point is touched: that is the state RaceManager's sway leaves it in.
	local function settleForPlacement(inst: Instance): boolean
		local cur: Instance? = inst
		while cur and cur ~= root do
			if cur:IsA("Model") then
				local rest = restPivotOf(cur)
				if rest then
					if (cur:GetPivot().Position - rest.Position).Magnitude < 0.05 then
						cur:PivotTo(rest)
						return true
					end
					return false
				end
			end
			cur = cur.Parent
		end
		return false
	end

	-- 2. Lighting
	step("lighting", function(): number
		return applyLighting(td, id)
	end)

	-- 3. Shells in plan order; each op isolated.
	step("shells", function(): number
		local terrain = workspace.Terrain
		local applied, calls = 0, 0
		for i, op in td.shellOps do
			local ok, res = pcall(MapAdapter.applyShellOp, op, waypoints, terrain, o.shellClear, o.clearBox)
			if ok then
				applied += 1
				calls += res
			else
				logError(string.format("shells[%d] %s", i, tostring(op.op)), res)
			end
		end
		report.counts.terrainCalls = calls
		return applied
	end)

	-- 4. Deck from the route
	local ribbon = adapterFolder(root, "TrackRibbon")
	step("deck", function(): number
		local r = Deck.build(td, ribbon)
		report.counts.deckSegments = r.segments
		report.counts.deckGapSegments = r.gapSegments
		report.counts.piers = r.piers
		report.adapterParts += r.parts
		return r.parts
	end)

	-- 4b. Alternate-line geometry (Alt1 tunnel, Alt2 ledge), same folder as the builder used
	step("alternates", function(): number
		local n = 0
		for i, alt in td.alternates do
			local ok, res = pcall(Deck.buildAlternate, alt, ribbon, if td.deck then td.deck.style else nil)
			if ok then
				n += res
			else
				logError(string.format("alternates[%d] %s", i, tostring(alt.id)), res)
			end
		end
		report.adapterParts += n
		return n
	end)

	-- 5. Hazards: invisible lethal volumes. CanQuery stays on because the lava check is FlightController's raycast.
	step("hazards", function(): number
		local hazFolder = adapterFolder(root, "Hazards")
		local n = 0
		for i, hz in td.hazards or {} do
			local ok, err = pcall(function()
				local parent = if type(hz.group) == "string" and hz.group ~= "" then ensurePath(root, hz.group, "Folder") else hazFolder
				local p = Instance.new("Part")
				p.Name = hz.name or ("Hazard_" .. tostring(i))
				p.Size = toVector3(hz.size)
				p.CFrame = toCFrame(hz.cf)
				p.Material = if hz.material then toMaterial(hz.material) else Enum.Material.CrackedLava
				p.Color = if hz.color then toColor3(hz.color) else Color3.fromRGB(235, 76, 18)
				p.Anchored = true
				p.TopSurface = Enum.SurfaceType.Smooth
				p.BottomSurface = Enum.SurfaceType.Smooth
				p.Transparency = if hz.visible == true then 0 else 1
				-- Non-collidable unless the data says otherwise (builder_dino4's LavaSeaFloor was collidable).
				p.CanCollide = hz.collide == true
				p.CanQuery = true
				p:SetAttribute("HazardType", hz.kind or "LethalLava")
				p:SetAttribute(OWNED_ATTR, true)
				p.Parent = parent
			end)
			if ok then
				n += 1
			else
				logError(string.format("hazards[%d] %s", i, tostring(hz.name)), err)
			end
		end
		report.adapterParts += n
		return n
	end)

	-- 6. Gameplay objects (kit builders)
	local cpFolder = adapterFolder(root, "Checkpoints")
	local boostsFolder = adapterFolder(root, "BoostsAndPods")
	step("gameplay", function(): number
		local r = Gameplay.build(td, cpFolder, boostsFolder)
		report.counts.checkpoints = r.checkpoints
		report.counts.rings = r.rings
		report.counts.pads = r.pads
		report.counts.pods = r.pods
		for _, e in r.errors do
			table.insert(report.errors, e)
		end
		report.adapterParts += r.parts
		return r.parts
	end)

	-- 7. Meshes: load, scale to height, place; AssetState records what really loaded (D19 / L68).
	step("meshes", function(): number
		local loadedCount, fallbackCount = 0, 0
		for i, m in td.meshes or {} do
			local ok, err = pcall(function()
				local parentInst = ensurePath(root, m.parent, "Model")
				-- A bad id is a load failure like any other: it must end in FALLBACK with the fallback shown, not in an
				-- error that leaves neither the mesh nor (after an earlier successful build hid it) the fallback.
				local modelId = tonumber(m.model)
				if modelId and (modelId <= 0 or modelId ~= math.floor(modelId)) then
					modelId = nil
				end
				local loaded = false
				local reason: string? = nil
				local loadOk: boolean, container: any = false, nil
				if modelId then
					loadOk, container = pcall(function()
						return ModelBakes.load(modelId :: number)
					end)
					if not loadOk then
						-- Kept for the ASSETS line: a permission or moderation failure must be diagnosable from the log.
						reason = tostring(container)
						container = nil
					end
				else
					reason = "model id missing or not a number: " .. tostring(m.model)
					logError(string.format("meshes[%d] %s", i, tostring(m.name)), reason)
				end
				if loadOk and container then
					local firstMesh: MeshPart? = nil
					for _, desc in container:GetDescendants() do
						if desc:IsA("LuaSourceContainer") then
							desc:Destroy()
						elseif desc:IsA("MeshPart") and not firstMesh then
							firstMesh = desc
						end
					end
					if firstMesh then
						-- Placement is isolated too: a bad plan value must end in a visible FALLBACK, not a half state.
						local mp = firstMesh:Clone()
						local placeOk, placeErr = pcall(function()
							for _, sub in mp:GetDescendants() do
								-- A SurfaceAppearance overrides TextureID, so it goes when the plan names a texture.
								if sub:IsA("LuaSourceContainer") or (m.textureId and sub:IsA("SurfaceAppearance")) then
									sub:Destroy()
								end
							end
							mp.Name = m.name or "Mesh"
							if m.textureId then
								mp.TextureID = m.textureId
							end
							if m.material then
								mp.Material = toMaterial(m.material)
							end
							if m.color then
								mp.Color = toColor3(m.color)
							end
							mp.Transparency = 0
							mp.Anchored = true
							mp.CanCollide = m.collide == true
							if type(m.height) == "number" then
								local raw = mp.Size
								mp.Size = raw * (m.height / math.max(1, raw.Y))
							end
							-- Identity offset so the placed CFrame equals the plan cf exactly.
							mp.PivotOffset = CFrame.new()
							mp:PivotTo(toCFrame(m.cf))
							mp:SetAttribute(OWNED_ATTR, true)
							settleForPlacement(parentInst)
							mp.Parent = parentInst
						end)
						if placeOk then
							loaded = true
						else
							mp:Destroy()
							reason = "placement: " .. tostring(placeErr)
							logError(string.format("meshes[%d] %s placement", i, tostring(m.name)), placeErr)
						end
					else
						reason = "asset has no MeshPart"
					end
					container:Destroy()
				elseif loadOk then
					reason = "LoadAsset returned nothing"
				end
				local state = if loaded then "mesh" else "FALLBACK"
				parentInst:SetAttribute("AssetState", state)
				-- Cleared on FALLBACK so a rebuild never keeps the flag of an earlier successful load.
				parentInst:SetAttribute("HasTripoMesh", if loaded then true else nil)
				if loaded then
					loadedCount += 1
				else
					fallbackCount += 1
				end
				print(string.format(
					"[SkyRally][ASSETS] %s model=%s state=%s loadOk=%s%s",
					tostring(m.label or m.name),
					if modelId then string.format("%d", modelId) else tostring(m.model),
					state,
					tostring(loadOk),
					if reason then " reason=" .. reason else ""
				))

				if type(m.fallbackGroup) == "string" then
					local group = findPath(root, m.fallbackGroup)
					if group then
						setGroupVisible(group, not loaded)
					elseif not loaded then
						error("FALLBACK but fallbackGroup " .. m.fallbackGroup .. " not found")
					end
				end
			end)
			if not ok then
				logError(string.format("meshes[%d] %s", i, tostring(m.name)), err)
			end
		end
		report.counts.meshFallback = fallbackCount
		report.adapterParts += loadedCount
		return loadedCount
	end)

	-- 7b. Set dressing: original props from Shared.PropLibrary (assets/models/props) placed by the plan's setDressing
	-- list ({key, pos, yaw?, scale?, snap?, collide?}). Each prop model loads once and is cloned per placement; scripts are
	-- stripped. The library pivot is the base centre, so pos is where the prop stands; snap = true drops it onto the
	-- first solid surface under pos. Decor never blocks a build: a prop that is not uploaded or fails to load is
	-- skipped with one log line. Collision follows the library's collide flag (decor stays out of queries).
	step("setDressing", function(): number
		local list = td.setDressing
		if type(list) ~= "table" or #list == 0 then
			return 0
		end
		local PropLibrary = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PropLibrary")) :: any
		local folder = adapterFolder(root, "SetDressing")
		-- Templates come from WorldArt's per-server cache (same shape: every BasePart of the asset, scripts stripped),
		-- all loaded at once and usually already in flight from kit/Prewarm (perf pass 2026-10-19).
		local keys: { string } = {}
		for _, e in list do
			if type(e.key) == "string" and not table.find(keys, e.key) then
				table.insert(keys, e.key)
			end
		end
		WorldArt.loadAll({}, keys)
		local templates: { [string]: Model | false } = {}
		local snapParams = RaycastParams.new()
		snapParams.FilterType = Enum.RaycastFilterType.Exclude
		snapParams.FilterDescendantsInstances = { folder }
		snapParams.RespectCanCollide = true
		snapParams.IgnoreWater = true
		local placed, skipped = 0, 0
		for i, e in list do
			local info = PropLibrary[e.key]
			local id = if info then tonumber(info.model) else nil
			if not id then
				skipped += 1
				continue
			end
			local tpl = templates[e.key]
			if tpl == nil then
				local m = WorldArt.prop(e.key)
				if not m then
					logError(string.format("setDressing %s model=%d", tostring(e.key), id), "template did not load")
				end
				local entry: Model | false = if m then m else false
				tpl = entry
				templates[e.key] = entry
			end
			if not tpl then
				skipped += 1
				continue
			end
			-- optional per-placement `collide` (bool) overrides the library flag: a solid prop used as far or over-lava
			-- dressing (DINO-4 totems, ruins, ribcages) must not add a new obstacle to the flying space
			local collide = if type(e.collide) == "boolean" then e.collide else info.collide == true
			local ok, err = pcall(function()
				local inst = (tpl :: Model):Clone()
				for _, d in inst:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = collide
						d.CanQuery = collide
						d.CanTouch = false
					end
				end
				local scale = tonumber(e.scale) or 1
				if scale ~= 1 then
					inst:ScaleTo(scale)
				end
				local bb, size = inst:GetBoundingBox()
				inst.WorldPivot = CFrame.new(bb.Position - Vector3.new(0, size.Y * 0.5, 0))
				local pos = toVector3(e.pos)
				if e.snap == true then
					local hit = workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -200, 0), snapParams)
					if hit then
						pos = hit.Position
					end
				end
				inst:PivotTo(CFrame.new(pos) * CFrame.Angles(0, math.rad(tonumber(e.yaw) or 0), 0))
				inst:SetAttribute(OWNED_ATTR, true)
				inst.Parent = folder
			end)
			if ok then
				placed += 1
			else
				skipped += 1
				logError(string.format("setDressing[%d] %s", i, tostring(e.key)), err)
			end
		end
		print(string.format("[SkyRally][MAP] %s setDressing placed=%d skipped=%d models=%d", tostring(td.id), placed, skipped, (function()
			local n = 0
			for _, t in templates do
				if t then
					n += 1
				end
			end
			return n
		end)()))
		report.adapterParts += placed
		return placed
	end)

	-- 7c. Art swap (owner: arches are "6-7 blocks with spaces between them", trees are blocky): the compiled builder's
	-- prefab Models keep their names and pivots, their block contents become world_v1 meshes fitted to the original's
	-- bounding box (kit/ArtSwap, rules in shared/ArtSwapRules). Before decorQuery so the new decor is covered too, and
	-- before activation. Studio A/B: workspace attribute ArtSwapOff = true skips it.
	step("artSwap", function(): number
		local r = ArtSwap.run(root, td.zone)
		if r.off then
			print(string.format("[SkyRally][MAP] %s artSwap skipped (ArtSwapOff)", id))
			return 0
		end
		local detail = {}
		for rule, n in r.byRule do
			table.insert(detail, string.format("%s=%d", rule, n))
		end
		table.sort(detail)
		print(string.format("[SkyRally][MAP] %s artSwap swapped=%d skipped=%d %s", id, r.swapped, r.skipped, table.concat(detail, " ")))
		return r.swapped
	end)

	-- 8. Model attributes (e.g. the sauropod's BasePivotPos/BaseYawDeg read by RaceManager's sway)
	step("modelAttributes", function(): number
		local n = 0
		for i, entry in td.modelAttributes or {} do
			local ok, err = pcall(function()
				local target = findPath(root, entry.path)
				if not target then
					error("path not found")
				end
				for key, value in entry.attrs or {} do
					if RUNTIME_ATTRS[key] then
						print(string.format("[SkyRally][MAP] %s modelAttributes %s.%s skipped: set by the meshes step", id, entry.path, key))
					else
						target:SetAttribute(key, toAttribute(value))
						n += 1
					end
				end
				-- RaceManager pivots this model to BasePivotPos every frame, so its pivot must sit there (the builder
				-- set WorldPivot = rootCF). A pivot already on the base point may carry a sway yaw: PivotTo removes it.
				-- Anywhere else the parts are in their rest pose and only the pivot moves (WorldPivot moves no parts).
				if target:IsA("Model") then
					local rest = restPivotOf(target)
					if rest and not settleForPlacement(target) then
						target.WorldPivot = rest
					end
				end
			end)
			if not ok then
				logError(string.format("modelAttributes[%d] %s", i, tostring(entry.path)), err)
			end
		end
		return n
	end)

	-- 8b. Zone materials (owned painterly MaterialVariants, declared statically in default.project.json MaterialService):
	-- Terrain base-material overrides, neutral terrain colours (the textures carry the colour), and per-part rules
	-- (first matching rule wins; `name` is a Lua pattern on the part name, `material` matches the current material).
	step("materials", function(): number
		local m = td.materials
		if type(m) ~= "table" then
			return 0
		end
		local n = applyTerrainOverrides(m)
		local rules = (m.partRules or {}) :: { any }
		if #rules > 0 then
			for _, d in root:GetDescendants() do
				if d:IsA("BasePart") then
					for _, r in rules do
						local nameOk = r.name == nil or string.find(d.Name, r.name) ~= nil
						local matOk = r.material == nil or d.Material == toMaterial(r.material)
						-- optional `prefab`: exact prefab key (the Prefab attribute on the part's parent model), so terrain-like
						-- rock prefabs can take a different variant from built structures that share the same Material
						local prefabOk = r.prefab == nil or (d.Parent ~= nil and d.Parent:GetAttribute("Prefab") == r.prefab)
						if nameOk and matOk and prefabOk then
							if r.setMaterial then
								d.Material = toMaterial(r.setMaterial)
							end
							d.MaterialVariant = r.variant or ""
							if r.color then
								d.Color = toColor3(r.color)
							end
							n += 1
							break
						end
					end
				end
			end
		end
		return n
	end)

	-- 8b2. Backdrop shells (visibility v1, kit/Backdrop, shared/BackdropRules): plain non-colliding parts behind and
	-- inside far terrain, drawn where the client's terrain render distance drops the real walls. After materials, so no
	-- part rule (DINO's catch-all Sandstone -> Masonry) restyles them; they keep the terrain's own override variant.
	-- Inside the root, so a cached load (MapAdapter.activate) gets them back with the clone. Studio A/B: workspace
	-- attribute BackdropOff = true skips the step.
	step("backdrop", function(): number
		if workspace:GetAttribute("BackdropOff") == true then
			return 0
		end
		local n = Backdrop.build(td, adapterFolder(root, "Backdrop"))
		report.counts.backdrop = n
		report.adapterParts += n
		return n
	end)

	-- 8c. Route light rig (plan `routeLights`): bounce light along the course, e.g. lava glow under the causeway in a
	-- sealed cave where no sun reaches. Anchored invisible holders, shadows off (mobile budget), every Nth segment.
	step("routeLights", function(): number
		local rl = td.routeLights
		if type(rl) ~= "table" then
			return 0
		end
		local folder = adapterFolder(root, "RouteLights")
		local wps = td.waypoints or {}
		local every: number = rl.every or 3
		local n = 0
		for i = 1, #wps - 1, every do
			local w = wps[i]
			if w.station >= (rl.fromStation or 0) and w.station <= (rl.toStation or math.huge) then
				local a: Vector3, b: Vector3 = w.pos, wps[i + 1].pos
				local cf = CFrame.lookAt(a, b, Vector3.yAxis)
				for _, off in (rl.offsets or { { 0, -30 } }) :: { { number } } do
					local holder = Instance.new("Part")
					holder.Name = "RouteLight_" .. tostring(i)
					holder.Anchored = true
					holder.CanCollide = false
					holder.CanQuery = false
					holder.CanTouch = false
					holder.CastShadow = false
					holder.Transparency = 1
					holder.Size = Vector3.new(1, 1, 1)
					holder.CFrame = cf * CFrame.new(off[1], off[2], 0)
					holder:SetAttribute(OWNED_ATTR, true)
					local l = Instance.new("PointLight")
					l.Color = toColor3(rl.color or "#ff7a2a")
					l.Range = rl.range or 60
					l.Brightness = rl.brightness or 2
					l.Shadows = false
					-- client/LightLod keeps only the nearest K map lights on (perf PF-01); gameplay lights carry no tag.
					l:SetAttribute("MapLight", true)
					l.Parent = holder
					holder.Parent = folder
					n += 1
				end
			end
		end
		return n
	end)

	-- 9. FX the compiler cannot express: each effect sits on an anchored invisible holder that no query sees.
	step("fx", function(): number
		local fxFolder = adapterFolder(root, "FX")
		local n = 0
		for i, fx in td.fx or {} do
			local ok, err = pcall(function()
				local className = tostring(fx.class)
				local parent = if type(fx.group) == "string" and fx.group ~= "" then ensurePath(root, fx.group, "Folder") else fxFolder
				local holder = Instance.new("Part")
				holder.Name = fx.name or string.format("FX_%s_%d", className, i)
				holder.Anchored = true
				holder.CanCollide = false
				holder.CanQuery = false
				holder.CanTouch = false
				holder.CastShadow = false
				holder.Transparency = 1
				holder.Size = if fx.size then toVector3(fx.size) else Vector3.one
				local effect = Instance.new(className :: any)
				if className == "Beam" then
					local a0 = toVector3(fx.a0)
					local a1 = toVector3(fx.a1)
					holder.CFrame = CFrame.new(a0)
					local att0 = Instance.new("Attachment")
					att0.Name = "A0"
					att0.Position = Vector3.zero
					att0.Parent = holder
					local att1 = Instance.new("Attachment")
					att1.Name = "A1"
					att1.Position = a1 - a0
					att1.Parent = holder
					local beam = effect :: Beam
					beam.Attachment0 = att0
					beam.Attachment1 = att1
				else
					holder.CFrame = toCFrame(fx.cf)
				end
				for _, e in applyProps(effect, fx.props) do
					logError(string.format("fx[%d] prop", i), e)
				end
				-- client/MapFxLod finds the map's own effects by this (rate x particle scale, distance cull; perf PF-02).
				effect:SetAttribute("MapFx", true)
				effect.Parent = holder
				holder:SetAttribute(OWNED_ATTR, true)
				settleForPlacement(parent)
				holder.Parent = parent
			end)
			if ok then
				n += 1
			else
				logError(string.format("fx[%d] %s", i, tostring(fx.class)), err)
			end
		end
		report.adapterParts += n
		return n
	end)

	-- 10. Guaranteed flight corridor over the main route and every alternate: the last Terrain op.
	step("carve", function(): number
		local corridor = if td.flight and td.flight.corridor then td.flight.corridor else {}
		local main = CourseCarve.carve(waypoints, {
			halfWidth = corridor.halfWidth,
			floor = corridor.floor,
			ceiling = corridor.ceiling,
			label = id .. " main",
		})
		local carved = main.carved
		local intrusions = #main.intrusions
		-- Car maps: a full 4-stud voxel renders its surface ~2 studs above the voxel top, so terrain filled to the
		-- corridor floor (+1) showed 0.3 above the paver tops and buried the road (ISLAND-2, 2026-10-18). Clear a bed
		-- the width of the deck down to 3.5 under the line; the shoulders beyond the curbs keep their deck-level fill.
		if td.vehicle == "car" and td.deck and td.deck.width then
			local bed = CourseCarve.carve(waypoints, {
				halfWidth = td.deck.width * 0.5 - 0.5,
				floor = -3.5,
				ceiling = (corridor.floor or 1) + 0.5,
				label = id .. " deck bed",
				scan = false,
			})
			carved += bed.carved
		end
		for i, alt in td.alternates do
			if alt.style == "cliff" then
				continue -- a cliff line rides the untouched rock: nothing is carved for it (owner rule: wall driving as is)
			end
			local ok, err = pcall(function()
				local pts: { CourseCarve.Waypoint } = {}
				for _, p in alt.points do
					table.insert(pts, { pos = p })
				end
				local tunnel = alt.style == "tunnel"
				-- A "span" is a raised line whose geometry the plan owns: nothing to carve, and the scan must not
				-- read its own slabs as intrusions.
				if alt.style ~= "span" then
					local r = CourseCarve.carve(pts, {
						halfWidth = if tunnel then 13 else 20,
						floor = 4,
						ceiling = if tunnel then 28 else 40,
						label = id .. " " .. tostring(alt.id or i),
					})
					carved += r.carved
					intrusions += #r.intrusions
				end
			end)
			if not ok then
				logError(string.format("carve alternate %s", tostring(alt.id or i)), err)
			end
		end
		report.corridorIntrusions = intrusions
		root:SetAttribute("CorridorIntrusions", intrusions)
		return carved
	end)

	-- 10b. Decor query rule (X-05, D4-11; kit/DecorQuery): visible non-collidable art is never a raycast target, so
	-- it can neither act as ground for a wheel probe nor hide a wall from the plane's step ray. After every part exists
	-- (meshes, fallbacks, materials) and after the carve, whose intrusion scan keeps seeing what it saw before.
	step("decorQuery", function(): number
		local n = DecorQuery.apply(root)
		root:SetAttribute("DecorQueryOff", n)
		return n
	end)

	-- 11. Route data for SplineUtils.loadWaypoints (client reads the folder, server reads _G).
	step("waypoints", function(): number
		local wpFolder = adapterFolder(root, "WaypointsData")
		wpFolder:SetAttribute("TrackLength", td.length)
		for idx, wp in waypoints do
			local val = Instance.new("Vector3Value")
			val.Name = "WP_" .. tostring(idx)
			val.Value = wp.pos
			val:SetAttribute("Index", idx)
			val:SetAttribute("Bank", wp.bank)
			val:SetAttribute("Station", wp.station)
			val:SetAttribute("Tangent", wp.tangent)
			val.Parent = wpFolder
		end
		return #waypoints
	end)

	-- 11b. Trap audit G8: alternate lines (and FOREST-1's key gallery) for the client's course assist and leash
	-- (shared/RouteBranch: Folder AltRoutes, Vector3 attributes only).
	step("altRoutes", function(): number
		return (require(Shared:WaitForChild("RouteBranch")) :: any).publish(root, td.alternates, td.hiddenKey)
	end)

	-- 11c. Flight allow-pockets (FLIGHT_GUIDE.md 12): volumes where the default flight mode never resets a plane
	-- (secret routes off the path), as attributes on the root (shared/FlightGuideRules.publishPockets).
	step("allowPockets", function(): number
		local fl = td.flight
		return (require(Shared:WaitForChild("FlightGuideRules")) :: any).publishPockets(root, if type(fl) == "table" then fl.allowPockets else nil)
	end)

	step("globals", function(): number
		return publishGlobals(id, td, root, report.adapterParts)
	end)

	-- 12. Registry (shared module written per schema section 4)
	step("registry", function(): number
		return registerTrack(id, td, root, o.activate)
	end)

	countParts(report, root)
	report.ok = #report.errors == 0
	root:SetAttribute("AdapterErrors", #report.errors)
	root:SetAttribute("TrackReady", true)
	logTimes(report, "build", buildT0)

	local c = report.counts
	print(string.format(
		"[SkyRally][MAP] %s built parts=%d adapterParts=%d deck=%d segments=%d shells=%d terrainCalls=%d hazards=%d checkpoints=%d rings=%d pads=%d pods=%d meshes=%d fallback=%d fx=%d decorNoQuery=%d waypoints=%d length=%.1f intrusions=%d mapBuilt=%s errors=%d",
		id,
		report.parts,
		report.adapterParts,
		c.deck or 0,
		c.deckSegments or 0,
		c.shells or 0,
		c.terrainCalls or 0,
		c.hazards or 0,
		c.checkpoints or 0,
		c.rings or 0,
		c.pads or 0,
		c.pods or 0,
		c.meshes or 0,
		c.meshFallback or 0,
		c.fx or 0,
		c.decorQuery or 0,
		c.waypoints or 0,
		tonumber(td.length) or 0,
		report.corridorIntrusions,
		tostring(report.mapBuilt),
		#report.errors
	))
	return report
end

-- A cached load (server/MapCache, L42): the map root is a clone of the first build's and its terrain is pasted back,
-- so only what a build does outside the root and the voxels runs again: lighting, the zone's terrain material
-- overrides, the _G route data, the registry, then TrackReady. Everything else a build makes lives inside the root and
-- came back with the clone: the art, deck, hazards, gameplay triggers (with their CollectionService tags), meshes and
-- their fallback state, set dressing, model attributes, part materials, route lights, fx, the decor query flags, the
-- WaypointsData and AltRoutes folders, and the AdapterStep_ attributes of that build.
function MapAdapter.activate(trackData: any, root: Instance, opts: ActivateOptions?): Report
	local o: ActivateOptions = opts or {}
	local id = tostring(trackData.id)
	local report = newReport(id)
	local activateT0 = os.clock()
	report.mapBuilt = true
	report.root = root
	report.adapterParts = o.adapterParts or 0
	local step = stepper(report)
	root:SetAttribute("TrackReady", false)
	local td = MapAdapter.normalize(trackData)
	step("lighting", function(): number
		return applyLighting(td, id)
	end)
	step("materials", function(): number
		return applyTerrainOverrides(td.materials)
	end)
	step("globals", function(): number
		return publishGlobals(id, td, root, report.adapterParts)
	end)
	step("registry", function(): number
		return registerTrack(id, td, root, o.activate)
	end)
	countParts(report, root)
	report.ok = #report.errors == 0
	root:SetAttribute("AdapterErrors", #report.errors)
	root:SetAttribute("TrackReady", true)
	logTimes(report, "activate", activateT0)
	print(string.format("[SkyRally][MAP] %s activated from cache parts=%d adapterParts=%d errors=%d", id, report.parts, report.adapterParts, #report.errors))
	return report
end

return MapAdapter
