-- L1 extraction (runs in the own Studio window's Edit DataModel): executes a source-patched copy of builder_dino4
-- with a recording Terrain proxy, then serializes what it built into _G.EXTRACT for chunked reads.
-- Injected by tools/map/extract_dino4.py: __SOURCE_B64__ (builder source), __FORCE_FALLBACK__ (true/false).
local EncodingService = game:GetService('EncodingService')
local SSS = game:GetService('ServerScriptService')
local function dec(s) return buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(s))) end

local src = dec('__SOURCE_B64__')
-- Terrain proxy: every method call is recorded with the builder line that issued it, then forwarded.
local REC_HEADER = [[
local __realT = workspace.Terrain
local __ops = {}
_G.EXTRACT_TERRAIN_OPS = __ops
local function __ser(v)
	local t = typeof(v)
	if t == 'CFrame' then return {k = 'CFrame', v = {v:GetComponents()}}
	elseif t == 'Vector3' then return {k = 'Vector3', v = {v.X, v.Y, v.Z}}
	elseif t == 'EnumItem' then return {k = 'Enum', v = tostring(v)}
	elseif t == 'Color3' then return {k = 'Color3', v = {v.R, v.G, v.B}}
	elseif t == 'Region3' then return {k = 'Region3', v = {v.CFrame:GetComponents()}, size = {v.Size.X, v.Size.Y, v.Size.Z}}
	else return {k = t, v = v} end
end
local __proxy = setmetatable({}, {
	__index = function(_, key)
		local real = __realT[key]
		if type(real) == 'function' then
			return function(_, ...)
				local args = {}
				for i = 1, select('#', ...) do args[i] = __ser((select(i, ...))) end
				table.insert(__ops, {op = key, args = args, line = debug.info(2, 'l')})
				return real(__realT, ...)
			end
		end
		return real
	end,
	__newindex = function(_, key, value)
		table.insert(__ops, {op = 'set', key = key, args = {__ser(value)}, line = debug.info(2, 'l')})
		__realT[key] = value
	end,
})
]]
local patched, n = src:gsub('local terrain = workspace%.Terrain', 'local terrain = __proxy', 1)
assert(n == 1, 'terrain line not found')
if __FORCE_FALLBACK__ then
	-- Force the Tripo loads to fail so the deliberate block-built fallback is captured as its own prefab.
	patched = patched:gsub('InsertService:LoadAsset%(', '(function() error("forced fallback") end)(', 1)
end
-- The header must sit after the builder's first line (--!strict) but before any code.
patched = REC_HEADER .. '\n' .. patched

local old = workspace:FindFirstChild('DINO-4_TrackModel')
if old then old:Destroy() end
local oldF = workspace:FindFirstChild('DINO-4')
if oldF then oldF:Destroy() end

local tmp = Instance.new('ModuleScript')
tmp.Name = 'ExtractBuilder_' .. tostring(math.random(100000, 999999))
tmp.Source = patched
tmp.Parent = SSS
local ok, err = pcall(require, tmp)
tmp:Destroy()
if not ok then return 'BUILD_ERR ' .. tostring(err) end

local model = workspace:FindFirstChild('DINO-4_TrackModel')
local root = model and model:FindFirstChild('DINO-4')
if not root then return 'NO_ROOT' end

local function v3(v) return {v.X, v.Y, v.Z} end
local function c3(c) return string.format('#%02x%02x%02x', math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end
local function pathOf(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= root do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, '/')
end
-- The "unit" an art part belongs to: the outermost Model under the folder tree, else its folder.
local function unitOf(inst)
	local cur, unit = inst.Parent, nil
	while cur and cur ~= root do
		if cur:IsA('Model') then unit = cur end
		cur = cur.Parent
	end
	return unit
end
local function propsOf(inst)
	local p = {}
	local function try(name)
		local ok2, v = pcall(function() return (inst :: any)[name] end)
		if not ok2 then return end
		local t = typeof(v)
		if t == 'Color3' then p[name] = c3(v)
		elseif t == 'EnumItem' then p[name] = v.Name
		elseif t == 'number' or t == 'boolean' or t == 'string' then p[name] = v
		elseif t == 'ColorSequence' then p[name] = c3(v.Keypoints[1].Value)
		elseif t == 'NumberSequence' then
			local ks = {}
			for _, k in v.Keypoints do table.insert(ks, {k.Time, k.Value, k.Envelope}) end
			p[name] = {seq = ks}
		end
	end
	for _, name in {'Brightness', 'Range', 'Color', 'Shadows', 'Enabled', 'Angle', 'Face', 'Width0', 'Width1', 'Transparency',
		'LightEmission', 'LightInfluence', 'FaceCamera', 'Texture', 'TextureLength', 'TextureMode', 'TextureSpeed', 'Segments',
		'CurveSize0', 'CurveSize1', 'ZOffset'} do
		try(name)
	end
	return p
end

local out = {parts = {}, meshes = {}, fx = {}, units = {}, hazards = {}, gameplay = {}, skipped = {}, attrs = {}}
local SKIP_RIBBON = {'^TrackSeg_', '^Paver_', '^Curb[LR]_', '^BridgeFascia_', '^CausewayPier', '^PierFooting'}
local function isRibbon(inst)
	if not inst:IsDescendantOf(root:FindFirstChild('TrackRibbon') or Instance.new('Folder')) then return false end
	for _, pat in SKIP_RIBBON do if string.find(inst.Name, pat) then return true end end
	return false
end
local seenUnits = {}
for _, inst in root:GetDescendants() do
	local top = string.match(pathOf(inst), '^([^/]+)')
	if top == 'WaypointsData' or top == 'Checkpoints' then
		-- route-derived; regenerated by the adapter
	elseif top == 'BoostsAndPods' then
		if inst:IsA('BasePart') and (inst:GetAttribute('TriggerType') or inst:GetAttribute('ItemPodSpawn')) then
			table.insert(out.gameplay, {name = inst.Name, parent = inst.Parent.Name, pos = v3(inst.Position), look = v3(inst.CFrame.LookVector),
				trigger = inst:GetAttribute('TriggerType'), pod = inst:GetAttribute('ItemPodSpawn'), podType = inst:GetAttribute('PodType'),
				coin = inst:GetAttribute('HasCoin'), boost = inst:GetAttribute('BoostPower')})
		end
	elseif inst:IsA('MeshPart') then
		local unit = unitOf(inst)
		table.insert(out.meshes, {name = inst.Name, path = pathOf(inst), parent = unit and pathOf(unit) or pathOf(inst.Parent),
			cf = {inst.CFrame:GetComponents()}, size = v3(inst.Size), meshId = inst.MeshId, textureId = inst.TextureID,
			material = inst.Material.Name, color = c3(inst.Color), collide = inst.CanCollide, transparency = inst.Transparency})
	elseif inst:IsA('BasePart') then
		if isRibbon(inst) then
			-- regenerated by kit/Deck from the route
		elseif inst:GetAttribute('HazardType') or inst.Name == 'LavaSeaFloor' then
			table.insert(out.hazards, {name = inst.Name, path = pathOf(inst), kind = inst:GetAttribute('HazardType') or 'LethalLava',
				cf = {inst.CFrame:GetComponents()}, size = v3(inst.Size), transparency = inst.Transparency, collide = inst.CanCollide,
				material = inst.Material.Name, color = c3(inst.Color)})
		elseif inst:GetAttribute('TriggerType') then
			table.insert(out.skipped, {path = pathOf(inst), why = 'trigger ' .. tostring(inst:GetAttribute('TriggerType')) .. ' (unused by game code)'})
		else
			local hasFx = false
			for _, ch in inst:GetChildren() do
				if ch:IsA('Light') or ch:IsA('Beam') or ch:IsA('ParticleEmitter') or ch:IsA('Attachment') then hasFx = true end
			end
			local holderOnly = hasFx and inst.Transparency >= 1 and not inst.CanCollide
			local unit = unitOf(inst)
			local unitPath = unit and pathOf(unit) or ('folder:' .. pathOf(inst.Parent))
			if unit and not seenUnits[unit] then
				seenUnits[unit] = true
				table.insert(out.units, {path = pathOf(unit), name = unit.Name, pivot = {unit.WorldPivot:GetComponents()}})
				local a = unit:GetAttributes()
				if next(a) then
					local ser = {}
					for k, v in a do ser[k] = if typeof(v) == 'Vector3' then {v.X, v.Y, v.Z} else v end
					table.insert(out.attrs, {path = pathOf(unit), attrs = ser})
				end
			end
			if not holderOnly then
				local shape = 'B'
				if inst:IsA('WedgePart') then shape = 'W'
				elseif inst:IsA('CornerWedgePart') then shape = 'CW'
				elseif inst:IsA('Part') then
					if inst.Shape == Enum.PartType.Cylinder then shape = 'C'
					elseif inst.Shape == Enum.PartType.Ball then shape = 'S' end
				end
				table.insert(out.parts, {unit = unitPath, name = inst.Name, shape = shape, cf = {inst.CFrame:GetComponents()}, size = v3(inst.Size),
					color = c3(inst.Color), material = inst.Material.Name, transparency = inst.Transparency, collide = inst.CanCollide,
					query = inst.CanQuery, castShadow = inst.CastShadow, mesh = inst:FindFirstChildOfClass('SpecialMesh') ~= nil})
			end
			for _, ch in inst:GetChildren() do
				if ch:IsA('Light') then
					table.insert(out.fx, {class = ch.ClassName, cf = {inst.CFrame:GetComponents()}, group = unitPath, props = propsOf(ch)})
				elseif ch:IsA('Beam') and ch.Attachment0 and ch.Attachment1 then
					table.insert(out.fx, {class = 'Beam', a0 = v3(ch.Attachment0.WorldPosition), a1 = v3(ch.Attachment1.WorldPosition), group = unitPath, props = propsOf(ch)})
				elseif ch:IsA('ParticleEmitter') then
					table.insert(out.fx, {class = 'ParticleEmitter', cf = {inst.CFrame:GetComponents()}, size = v3(inst.Size), group = unitPath, props = propsOf(ch)})
				end
			end
		end
	end
end
out.meta = {waypoints = #(root:FindFirstChild('WaypointsData') and root.WaypointsData:GetChildren() or {}),
	trackLength = root:FindFirstChild('WaypointsData') and root.WaypointsData:GetAttribute('TrackLength'),
	checkpoints = #(root:FindFirstChild('Checkpoints') and root.Checkpoints:GetChildren() or {}),
	terrainOps = #(_G.EXTRACT_TERRAIN_OPS or {}), parts = #out.parts, meshes = #out.meshes, fx = #out.fx,
	hazards = #out.hazards, gameplay = #out.gameplay, units = #out.units, skipped = #out.skipped}
-- Checkpoint stations as built (route contract evidence for L02)
local cps = {}
for _, c in (root:FindFirstChild('Checkpoints') and root.Checkpoints:GetChildren() or {}) do
	table.insert(cps, {index = c:GetAttribute('CheckpointIndex'), station = c:GetAttribute('Station')})
end
out.checkpoints = cps
_G.EXTRACT = out
-- Leave the Edit DataModel as it was: remove the built map and the Terrain it wrote.
model:Destroy()
workspace.Terrain:Clear()
return game:GetService('HttpService'):JSONEncode(out.meta)
