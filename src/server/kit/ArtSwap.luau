--!strict
-- Runtime art swap (owner: arches are "6-7 blocks with spaces between them", trees are blocky). The compiled 30MAPS
-- builders (build/<map>/builder_module.luau, regenerated from plans and never edited) place every prefab as one Model of
-- primitive blocks; after the builder runs, MapAdapter calls ArtSwap.run, which keeps each matching Model (name, pivot,
-- attributes, so SelfTest's StoneArchway_* and BossRetirement's PortalArch_<ZONE> lookups still work) and swaps its
-- contents for the uploaded meshes fitted to the original's bounding box. What matches, and the fit maths, live in
-- shared/ArtSwapRules (Lune spec tools/tests/artswap_spec.luau).
--   * trees -> round_oak (HUB and FOREST oaks) and poplar, turned by a stable per-position yaw, bushes -> the world_v1 bush,
--     with a trunk box where the original collided;
--   * palms -> the PropLibrary palm cluster when it loads (the original's colliding trunk parts stay, invisible);
--   * DINO course arches -> world_v1 portal_arch / stone_arch (best aspect), tinted to the original's dominant stone colour,
--     with two pier boxes and a top bar (invisible) only where the original collided;
--   * hub portal arches -> arches_v3 portal_gate; they keep their veil glass (faded to near-invisible), banner cloth (hidden) and light;
--   * art v3 (foliage_v3, arches_v3, props_v3): the HUB cliff arch, the SNOW mine portals and finish gantry, the ISLAND cavern
--     arches, windmills (the sails keep their SpinRPM Model) and the HUB plaza lamps. Arch meshes sit at a fixed scale on the
--     prefab origin; the v3 meshes are textured, so there is no tint.
--   * collidersOnly rules (the HUB tunnel mouths) place no mesh: the original blocks go and the mesh's colliders stand where
--     they did, under the plan's own block-built art (CliffTunnelCollar);
--   * rules whose v3 mesh is still being redone (hedge, autumn tree, cypress, ...) have no ASSETS entry and never match.
-- A template that fails to load leaves its prefabs as built. Studio-only A/B switch: workspace attribute ArtSwapOff = true.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ArtSwapRules"))
local WorldArt = require(script.Parent.WorldArt)

local ArtSwap = {}

export type Result = { swapped: number, skipped: number, byRule: { [string]: number }, off: boolean }

ArtSwap.MARK = "ArtSwapped"

local WHITE = Color3.new(1, 1, 1)

local function decorPart(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
end

-- Small warm particle flame and a few embers at a hidden flame block's centre (ArtSwapRules.FLAME_FX; colours follow the
-- bake's flame and GroundFx's ember).
local function addFlameFx(p: BasePart)
	local cfg = Rules.FLAME_FX
	local att = Instance.new("Attachment")
	att.Name = "FlameFxAttachment"
	att.Parent = p
	local function emitter(name: string, c: any, colour: ColorSequence, texture: string)
		local pe = Instance.new("ParticleEmitter")
		pe.Name = name
		pe.Texture = texture
		pe.Rate = c.rate
		pe.Lifetime = NumberRange.new(c.life[1], c.life[2])
		pe.Speed = NumberRange.new(c.speed[1], c.speed[2])
		pe.Acceleration = Vector3.new(0, 3, 0)
		pe.SpreadAngle = Vector2.new(c.spread, c.spread)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.Rotation = NumberRange.new(0, 360)
		pe.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, c.size[1]),
			NumberSequenceKeypoint.new(0.4, c.size[2]),
			NumberSequenceKeypoint.new(1, c.size[3]),
		})
		pe.Color = colour
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.4), NumberSequenceKeypoint.new(1, 1) })
		pe.LightEmission = c.light
		pe.LockedToPart = false
		pe.Parent = att
	end
	emitter("TorchFlame", cfg.flame, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 120)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 150, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 70, 30)),
	}), "rbxasset://textures/particles/fire_main.dds")
	emitter("TorchEmbers", cfg.embers, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 80, 30)),
	}), "rbxasset://textures/particles/sparkles_main.dds")
end

local function box(name: string, pivot: CFrame, centre: Vector3, size: Vector3, parent: Instance, yaw: number?)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = pivot * CFrame.new(centre) * CFrame.Angles(0, math.rad(yaw or 0), 0)
	p.Anchored = true
	p.Transparency = 1
	p.CanCollide = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
end

local function placeMesh(tpl: MeshPart, name: string, pivot: CFrame, localCF: CFrame, scale: Rules.Scale, parent: Instance): MeshPart
	local m = tpl:Clone()
	m.Name = name
	m.Size = tpl.Size * Rules.scaleVec(scale)
	m.CFrame = pivot * localCF
	decorPart(m)
	m.Parent = parent
	return m
end

-- Veil colour of a portal: the largest kept Glass part, else the largest kept part.
local function veilColour(kept: { BasePart }): Color3
	local glass, any = {}, {}
	for _, p in kept do
		local e = { color = p.Color, weight = p.Size.X * p.Size.Y * p.Size.Z }
		table.insert(any, e)
		if p.Material == Enum.Material.Glass then
			table.insert(glass, e)
		end
	end
	return Rules.dominantColour(glass) or Rules.dominantColour(any) or WHITE
end

type Templates = { meshes: { [string]: MeshPart? }, props: { [string]: Model? } }

local function swapOne(model: Model, rule: Rules.Rule, zoneTemplates: Templates): boolean
	local pivot = model:GetPivot()
	local inv = pivot:Inverse()

	-- Original bounding box in pivot space, what stays, the stone colour, and whether anything collided.
	local bmin = Vector3.new(math.huge, math.huge, math.huge)
	local bmax = Vector3.new(-math.huge, -math.huge, -math.huge)
	local parts: { BasePart } = {}
	local kept: { BasePart } = {}
	local stone: { { color: Color3, weight: number } } = {}
	local collided = false
	for _, ch in model:GetChildren() do
		if ch:IsA("BasePart") then
			local lo, hi = Rules.localExtents(inv * ch.CFrame, ch.Size)
			bmin = Vector3.new(math.min(bmin.X, lo.X), math.min(bmin.Y, lo.Y), math.min(bmin.Z, lo.Z))
			bmax = Vector3.new(math.max(bmax.X, hi.X), math.max(bmax.Y, hi.Y), math.max(bmax.Z, hi.Z))
			table.insert(parts, ch)
			if ch.CanCollide then
				collided = true
			end
			if Rules.keepPart(rule, ch.Material.Name, ch:FindFirstChildWhichIsA("Light") ~= nil) then
				table.insert(kept, ch)
			else
				table.insert(stone, { color = ch.Color, weight = ch.Size.X * ch.Size.Y * ch.Size.Z })
			end
		end
	end
	if #parts == 0 then
		return false
	end
	local size = bmax - bmin

	-- Which replacement, at what scale.
	local asset: Rules.Asset
	local tpl: MeshPart? = nil
	local propTpl: Model? = nil
	local meshName = ""
	local ownPivot = false -- a Creator Store stand-in prop whose bake pivot is the base of its trunk / pole
	if rule.prop then
		propTpl = zoneTemplates.props[rule.prop]
		local info = WorldArt.propInfo(rule.prop)
		if not propTpl or not info then
			return false
		end
		ownPivot = info.ownPivot
		asset = Rules.propAsset(info.size)
	else
		local names = rule.meshes :: { string }
		local pos = pivot.Position
		if rule.kind == "tree" then
			meshName = Rules.pickMesh(names, pos.X, pos.Z)
		elseif rule.kind == "arch" then
			meshName = Rules.pickArch(names, size.X, size.Y)
		else
			meshName = names[1]
		end
		if Rules.placesMesh(rule) then
			tpl = zoneTemplates.meshes[meshName]
			if not tpl then
				return false
			end
		end
		asset = Rules.asset(meshName) :: Rules.Asset
	end
	local scale = Rules.fitScale(rule, asset, size)
	local origin = Rules.originPosition(rule, asset, scale, bmin, bmax)
	local fit: Rules.Scale = if rule.stretch then Rules.stretchScale(rule, asset, size) else scale -- hedges: per-axis

	-- Everything below can fail halfway; build the new art first, remove the old only once it exists.
	local fresh: { Instance } = {}
	local ok, err = pcall(function()
		if tpl then
			local yaw = if rule.varyYaw then Rules.yawFor(pivot.Position.X, pivot.Position.Z) else 0
			local m = placeMesh(tpl, Rules.partName(rule), pivot, Rules.partCFrame(asset, fit, origin, yaw), fit, model)
			table.insert(fresh, m)
			if rule.tint then
				m.Color = Rules.stoneTint(Rules.dominantColour(stone) or WHITE)
			end
			if rule.trim then
				local trimTpl = zoneTemplates.meshes[rule.trim]
				local trimAsset = Rules.asset(rule.trim) :: Rules.Asset
				if trimTpl then
					local trim = placeMesh(trimTpl, "Trim", pivot, CFrame.new(Rules.partCentre(trimAsset, fit, origin)), fit, model)
					trim.Material = Enum.Material.Neon
					trim.Color = veilColour(kept)
					trim.Transparency = 0.15
					trim.CastShadow = false
					table.insert(fresh, trim)
				end
			end
		elseif propTpl then
			local inst = (propTpl :: Model):Clone()
			for _, d in inst:GetDescendants() do
				if d:IsA("BasePart") then
					decorPart(d)
				end
			end
			inst:ScaleTo(scale)
			if not ownPivot then
				local bb, bsz = inst:GetBoundingBox()
				inst.WorldPivot = CFrame.new(bb.Position - Vector3.new(0, bsz.Y * 0.5, 0))
			end
			local yaw = if rule.varyYaw then Rules.yawFor(pivot.Position.X, pivot.Position.Z) else 0
			inst:PivotTo(pivot * CFrame.new(origin) * CFrame.Angles(0, yaw, 0))
			inst.Name = if ownPivot then Rules.partName(rule) else "Palms"
			inst.Parent = model
			table.insert(fresh, inst)
		end
	end)
	if not ok then
		for _, f in fresh do
			f:Destroy()
		end
		warn(string.format("[SkyRally][MAP] artSwap %s failed: %s", model.Name, tostring(err)))
		return false
	end

	-- Old art out. Kept parts (veil, banners, lights) stay; "orig" colliders stay as invisible collision.
	local keepSet: { [BasePart]: boolean } = {}
	for _, p in kept do
		keepSet[p] = true
	end
	for _, p in parts do
		if keepSet[p] then
			continue
		elseif rule.collider == "orig" and p.CanCollide then
			p.Transparency = 1
			p.CastShadow = false
			for _, d in p:GetChildren() do
				d:Destroy()
			end
		else
			p:Destroy()
		end
	end

	-- Hub portals: the veil glass is faint (the client PortalFill disc is the portal) and the hung banners, which read as
	-- dark slabs inside the opening's edge, are hidden; both keep their collision.
	for _, p in kept do
		if p.Parent ~= model then
			continue
		end
		if rule.flameFx and p:FindFirstChildWhichIsA("Light") then
			-- the builder's bright Neon flame block: invisible and non-physical, the Light stays, particles take its place
			p.Transparency = 1
			p.CastShadow = false
			decorPart(p)
			addFlameFx(p)
		elseif rule.veilTransparency and p.Material == Enum.Material.Glass then
			p.Transparency = rule.veilTransparency
			p.CastShadow = false
		elseif rule.hideFabric and p.Material == Enum.Material.Fabric then
			p.Transparency = 1
			p.CastShadow = false
		end
	end

	-- Hung banners sit in front of the new pier faces.
	if asset.pierFront then
		for _, p in kept do
			if p.Parent == model and p.Material == Enum.Material.Fabric then
				local rel = inv * p.CFrame
				local z = Rules.bannerZ(asset, scale, origin, rel.Position.Z, p.Size.Z)
				if z ~= rel.Position.Z then
					p.CFrame = pivot * (CFrame.new(0, 0, z - rel.Position.Z) * rel)
				end
			end
		end
	end

	-- Kept parts that hang from the new art (the banner pole's flag) move by the rule's shift, in the prefab frame.
	if rule.keepShift then
		for _, p in kept do
			if p.Parent == model then
				p.CFrame = pivot * CFrame.new(rule.keepShift :: Vector3) * (inv * p.CFrame)
			end
		end
	end

	-- Collision only where the original had some.
	if collided then
		if rule.collider == "trunk" then
			local t = Rules.trunkBox(rule, asset, scale, origin)
			box("Trunk", pivot, t.centre, t.size, model)
		elseif rule.collider == "arch" then
			for i, c in Rules.archColliders(asset, fit, origin) do
				box("Collider" .. tostring(i), pivot, c.centre, c.size, model, c.yaw)
			end
		end
	end

	model.WorldPivot = pivot
	model:SetAttribute(ArtSwap.MARK, rule.id)
	return true
end

-- Every mesh and prop template a map of `zone` can ask for (each rule whose zone filter admits it), so a track load can
-- start fetching them while the compiled builder is still writing terrain (kit/Prewarm). Ignores ArtSwapOff.
function ArtSwap.templatesFor(zone: string?): ({ string }, { string })
	local meshes, props = {}, {}
	local function add(list: { string }, key: string)
		if not table.find(list, key) then
			table.insert(list, key)
		end
	end
	for _, rule in Rules.RULES do
		if (zone == nil or rule.zones == nil or table.find(rule.zones, zone) ~= nil) and Rules.ready(rule) then
			local names = if Rules.placesMesh(rule) then rule.meshes else nil
			if names then
				for _, name in names do
					add(meshes, name)
				end
			end
			if rule.trim then
				add(meshes, rule.trim)
			end
			if rule.prop then
				add(props, rule.prop)
			end
		end
	end
	return meshes, props
end

function ArtSwap.isOff(): boolean
	return RunService:IsStudio() and workspace:GetAttribute("ArtSwapOff") == true
end

-- Swaps every matching prefab Model under `root`. `zone` is TrackData.zone ("HUB", "ISLAND", ...).
function ArtSwap.run(root: Instance, zone: string?): Result
	local result: Result = { swapped = 0, skipped = 0, byRule = {}, off = false }
	if ArtSwap.isOff() then
		result.off = true
		return result
	end

	-- Collect first (the swap edits the tree), then load every template the matches need once.
	local jobs: { { model: Model, rule: Rules.Rule } } = {}
	local needMesh: { [string]: boolean } = {}
	local needProp: { [string]: boolean } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute(ArtSwap.MARK) == nil then
			local prefab = d:GetAttribute("Prefab")
			if type(prefab) == "string" then
				local rule = Rules.match(prefab, zone)
				if rule then
					table.insert(jobs, { model = d, rule = rule })
					local meshes = if Rules.placesMesh(rule) then rule.meshes else nil
					if meshes then
						for _, name in meshes do
							needMesh[name] = true
						end
					end
					if rule.trim then
						needMesh[rule.trim] = true
					end
					if rule.prop then
						needProp[rule.prop] = true
					end
				end
			end
		end
	end
	-- All templates load at once (usually already in flight from kit/Prewarm, started with the track load).
	local meshList, propList = {}, {}
	for name in needMesh do
		table.insert(meshList, name)
	end
	for key in needProp do
		table.insert(propList, key)
	end
	WorldArt.loadAll(meshList, propList)
	local templates: Templates = { meshes = {}, props = {} }
	for _, name in meshList do
		templates.meshes[name] = WorldArt.world(name)
	end
	for _, key in propList do
		templates.props[key] = WorldArt.prop(key)
	end

	for i, job in jobs do
		local ok, swapped = pcall(swapOne, job.model, job.rule, templates)
		if ok and swapped then
			result.swapped += 1
			result.byRule[job.rule.id] = (result.byRule[job.rule.id] or 0) + 1
		else
			result.skipped += 1
			if not ok then
				warn(string.format("[SkyRally][MAP] artSwap %s: %s", job.model.Name, tostring(swapped)))
			end
		end
		if i % 80 == 0 then
			task.wait()
		end
	end
	return result
end

return ArtSwap
