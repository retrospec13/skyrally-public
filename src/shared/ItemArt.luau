--!strict
-- Item art kit (owner: the item pickups "are plain looking blocks, they should actually be something").
-- One place that knows the uploaded item meshes (ItemModelAssets, each Model wraps one MeshPart; assets/models/items_v1/
-- manifest.json holds sizes, pivots and tint rules) and how a pod type maps onto them:
--   Red/Blue/Yellow/Green  item_balloon tinted by the pod colour, the item icon on top (ItemTexAssets)
--   Rainbow                item_balloon_rainbow, never tinted (its stripes are the point)
--   Speed                  the mint boost block (buildBoostBlock, cubes v3; the gold winged coin read as a Sky Token)
--   Air                    pickup_air (white/pale-blue swirl, tinted)
--   race item pods         the multicolour glass mystery cube (buildMysteryCube): parts only, no mesh to load
-- Clients cannot InsertService:LoadAsset, so the server loads every mesh once (prepare), keeps the MeshParts in
-- ReplicatedStorage.SkyRallyItemArt and every side clones from there. Server code that must not yield (a trap spawned
-- mid-race) uses peek and falls back to the old procedural look until the load has finished; clients only ever peek.
-- Pure data plus one cached loader; no per-frame work. Meshes are bbox-centred (Roblox renders a MeshPart centred on
-- its bounding box): the balloon's body therefore sits 0.8 stud above the part centre, which centres the whole
-- balloon-plus-ribbon on the pickup position instead of leaving the ribbon under it.
local Shared = script.Parent
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local ItemModelAssets = require(Shared:WaitForChild("ItemModelAssets"))

local ItemArt = {}

ItemArt.FOLDER = "SkyRallyItemArt"

export type PodSpec = {
	mesh: string, -- ItemModelAssets key
	kind: string, -- "balloon" | "boost" | "air": the client picks the idle motion from it
	scale: number, -- visual scale on the manifest size (mesh "" : built from parts, see buildPodCore)
	tint: Color3?, -- MeshPart.Color; nil = untinted white
	icon: string?, -- ItemTexAssets key for the billboard icon (item pods only)
	light: Color3, -- PointLight and halo colour
	rainbow: boolean, -- the client cycles the light/halo hue
}

local WHITE = Color3.new(1, 1, 1)
local ICON_OF_POD: { [string]: string } = {
	Red = "missile",
	Blue = "boost",
	Yellow = "shield",
	Green = "trap",
	Rainbow = "magnet",
}

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local specs: { [string]: PodSpec } = {}

-- nil for a PodType the art does not cover (the pod keeps a plain fallback ball).
function ItemArt.podSpec(podType: any): PodSpec?
	if type(podType) ~= "string" then
		return nil
	end
	local cached = specs[podType]
	if cached then
		return cached
	end
	local base = ItemRules.podRgb(podType)
	if not base then
		return nil
	end
	local color = rgb(base)
	local spec: PodSpec? = nil
	if podType == "Rainbow" then
		spec = { mesh = "item_balloon_rainbow", kind = "balloon", scale = 1.2, tint = nil, icon = ICON_OF_POD.Rainbow, light = color, rainbow = true }
	elseif ICON_OF_POD[podType] then
		spec = { mesh = "item_balloon", kind = "balloon", scale = 1.2, tint = color, icon = ICON_OF_POD[podType], light = color, rainbow = false }
	elseif podType == "Speed" then
		-- Cubes v3: the mint boost block (POD_RGB Speed is mint too), built from one part, no mesh.
		spec = { mesh = "", kind = "boost", scale = 1, tint = nil, icon = nil, light = color, rainbow = false }
	elseif podType == "Air" then
		-- The swirl is white/pale blue: a half-strength tint keeps it airy instead of olive.
		spec = { mesh = "pickup_air", kind = "air", scale = 1.2, tint = WHITE:Lerp(color, 0.55), icon = nil, light = color, rainbow = false }
	end
	if spec then
		specs[podType] = spec
	end
	return spec
end

------------------------------------------------------------------------------------------------------------------------
-- Template cache (server loads, everyone clones)
------------------------------------------------------------------------------------------------------------------------

local prepared = false
local preparing = false

local function folderOf(create: boolean): Folder?
	local RS = game:GetService("ReplicatedStorage")
	local existing = RS:FindFirstChild(ItemArt.FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if not create then
		return nil
	end
	local f = Instance.new("Folder")
	f.Name = ItemArt.FOLDER
	f.Parent = RS
	return f
end

local function loadOne(folder: Folder, key: string, id: number): boolean
	local ModelBakes = require(Shared:WaitForChild("ModelBakes")) :: any
	local ok, container = pcall(function()
		return ModelBakes.load(id)
	end)
	if not ok or not container then
		warn(string.format("[SkyRally][ASSETS] item art %s id=%d LoadAsset failed: %s", key, id, tostring(container)))
		return false
	end
	local mesh = container:FindFirstChildWhichIsA("MeshPart", true)
	if not mesh then
		warn(string.format("[SkyRally][ASSETS] item art %s id=%d has no MeshPart", key, id))
		container:Destroy()
		return false
	end
	local clone = mesh:Clone()
	for _, d in clone:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	clone.Name = key
	-- Decoration only: never a trigger, never a raycast target, no shadow to pay for on a phone.
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Parent = folder
	container:Destroy()
	return true
end

-- Server only; yields on first use. Loads every item mesh in parallel once and publishes the MeshParts under
-- ReplicatedStorage.SkyRallyItemArt. Single flight: a second caller waits for the first load instead of reading "not
-- loaded yet". Safe to call again (returns at once).
function ItemArt.prepare()
	while preparing do
		task.wait()
	end
	if prepared then
		return
	end
	preparing = true
	local folder = folderOf(true) :: Folder
	local pending, loaded, total = 0, 0, 0
	for key, id in ItemModelAssets do
		pending += 1
		total += 1
		task.spawn(function()
			local ok = loadOne(folder, key, id)
			if ok then
				loaded += 1
			end
			pending -= 1
		end)
	end
	local deadline = os.clock() + 30
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
	folder:SetAttribute("Loaded", loaded)
	workspace:SetAttribute("AssetItemArtState", string.format("%d/%d", loaded, total))
	print(string.format("[SkyRally][ASSETS] item art meshes loaded %d/%d", loaded, total))
	prepared = true
	preparing = false
end

-- Non-yielding: the cached MeshPart, or nil before the server's load has finished (clients: before it replicated).
function ItemArt.peek(key: string): MeshPart?
	local folder = folderOf(false)
	local m = if folder then folder:FindFirstChild(key) else nil
	return if m and m:IsA("MeshPart") then m else nil
end

-- Server: loads on first use (yields), then returns the template. Client: same as peek.
function ItemArt.template(key: string): MeshPart?
	if game:GetService("RunService"):IsServer() then
		ItemArt.prepare()
	end
	return ItemArt.peek(key)
end

-- Tints a mesh part. The uploaded GLB models may arrive with a SurfaceAppearance (which carries its own Color tint and
-- is not necessarily multiplied by BasePart.Color), so both are set; white restores the authored colours.
function ItemArt.setTint(part: BasePart, color: Color3)
	part.Color = color
	local sa = part:FindFirstChildOfClass("SurfaceAppearance")
	if sa then
		sa.Color = color
	end
end

-- A MeshPart draws its TextureID over BasePart.Color instead of multiplying it, so the tinted pods (item balloons, air
-- swirl) showed white in Studio (2026-10-19 capture out/verify_merge/v3_hub_pods_promenade.png). Their textures are flat
-- near-white (manifest: "rely on Color tint"), so a tinted pod drops its texture and an untinted one gets it back.
local function podTexture(part: BasePart, spec: PodSpec)
	if not part:IsA("MeshPart") then
		return
	end
	local mp = part :: MeshPart
	if spec.tint then
		if mp.TextureID ~= "" then
			mp:SetAttribute("PodTexture", mp.TextureID)
			mp.TextureID = ""
		end
	else
		local t = mp:GetAttribute("PodTexture")
		if type(t) == "string" and mp.TextureID == "" then
			mp.TextureID = t
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Pod visual
------------------------------------------------------------------------------------------------------------------------

-- The pod's `<name>_CoreVisual` (RaceManager hides it on pickup, ItemEffects.paintPods repaints it, ItemClient animates
-- it): the balloon / swirl MeshPart with a soft PointLight in the pod colour (a Speed pod: the boost block), or a plain
-- neon ball when the mesh is not available. Anchored, non-colliding, non-queryable, no shadow. Yields on the first call (mesh load).
function ItemArt.buildPodCore(podName: string, podType: string, pos: Vector3, parent: Instance): BasePart
	local spec = ItemArt.podSpec(podType)
	if spec and spec.kind == "boost" then
		return ItemArt.buildBoostBlock(podName, pos, parent)
	end
	local tpl = if spec then ItemArt.template(spec.mesh) else nil
	local core: BasePart
	if spec and tpl then
		local m = tpl:Clone()
		m.Size = tpl.Size * spec.scale
		ItemArt.setTint(m, spec.tint or WHITE)
		podTexture(m, spec)
		m:SetAttribute("PodArt", spec.kind)
		local light = Instance.new("PointLight")
		light.Name = "PodLight"
		light.Color = spec.light
		light.Brightness = 0.4 -- v29 A5: was 0.9 (no coloured light pools on the road)
		light.Range = 7 -- v29 A5: was 13
		light.Shadows = false
		light.Parent = m
		core = m
	else
		local base = ItemRules.podRgb(podType) or ItemRules.POD_RGB.Red
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.new(4, 4, 4)
		ball.Material = Enum.Material.Neon
		ball.Color = rgb(base)
		ball:SetAttribute("PodArt", "fallback")
		core = ball
	end
	core.Name = podName .. "_CoreVisual"
	core.CFrame = CFrame.new(pos)
	core.Transparency = 0
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.Parent = parent
	return core
end

------------------------------------------------------------------------------------------------------------------------
-- Mystery cube (race item pods; ItemRules MYSTERY)
------------------------------------------------------------------------------------------------------------------------

-- Cubes v3 (owner 2026-10-20: "I want the blocks to look like the image you showed here but in the plane scene being
-- multi colored"; the 'Staggered 2 + 3' mockup): a translucent coloured glass box in a bright frame of the same family,
-- a white "?" on every face, a glowing core inside. Families gold, blue, green, red (plus violet for the fifth plan
-- colour), picked from the pod's plan colour, so the rotating plan colours make every set multicoloured on every map,
-- planes included. The colour is only the box: what the cube gives is still rolled on the server, and the cycling item
-- colour lives on the core, halo, light and ghost icon (ItemClient).
-- Block-built (ART_BAR construction rules), no mesh to load. Frame: twelve square painted bars (Neon before v29), the four along X running
-- through the corners (length L + t) and the eight along Y and Z stopping flush against them, so every corner is closed
-- without the v2 corner blocks: 12 bars + the core = 13 children of the glass (v2: 21), 14 parts a cube. The glass is the
-- <name>_CoreVisual; the frame parts are its children, placed in its frame, so a CFrame offset of every descendant
-- (StormCup twins) or the client's per-frame tumble (ItemClient: one BulkMoveTo over every near cube) keeps them
-- together. Everything is anchored and inert: no collision, query, touch or shadow.
ItemArt.CUBE_FRAME_PARTS = 13 -- 12 edges + the glowing core (the glass is the root part)
ItemArt.CUBE_PARTS = ItemArt.CUBE_FRAME_PARTS + 1 -- per cube, glass included (tools/map/item_cubes.json maxCubeParts)
local CUBE_LIGHT = Color3.fromRGB(255, 236, 190)
ItemArt.CUBE_GLASS_TRANSPARENCY = 0.4

export type CubeFamily = { glass: Color3, edge: Color3 }
-- glass: the box tint (Glass material, translucent); edge: the painted frame (v29: no longer Neon). Mockup family, saturated enough to
-- read at 844x390 and against snow, sea and the dark of SPACE-4.
local FAMILIES: { [string]: CubeFamily } = {
	gold = { glass = Color3.fromRGB(255, 200, 60), edge = Color3.fromRGB(255, 226, 90) },
	blue = { glass = Color3.fromRGB(70, 160, 255), edge = Color3.fromRGB(120, 205, 255) },
	green = { glass = Color3.fromRGB(70, 210, 90), edge = Color3.fromRGB(140, 255, 120) },
	red = { glass = Color3.fromRGB(240, 70, 80), edge = Color3.fromRGB(255, 120, 130) },
	violet = { glass = Color3.fromRGB(170, 90, 255), edge = Color3.fromRGB(210, 150, 255) },
}
local FAMILY_OF_POD: { [string]: string } = { Yellow = "gold", Blue = "blue", Green = "green", Red = "red", Rainbow = "violet" }
ItemArt.CUBE_FAMILIES = FAMILIES

-- The family name for a pod's plan colour (gold for anything unknown).
function ItemArt.cubeFamily(podType: any): string
	return if type(podType) == "string" and FAMILY_OF_POD[podType] then FAMILY_OF_POD[podType] else "gold"
end

-- v29 W1b A1 (critic v29): the frame is a painted block frame in the family colour, no longer twelve Neon bars (a full
-- Neon outline bloomed into a glowing wireframe next to the lens on every map). SmoothPlastic: no map retargets it and it
-- keeps the owner's multicolour families (cubes v3) under every grade; the glow now lives only in the small "?" glyph
-- and the pulsing core. (Was Enum.Material.Neon.)
local CUBE_MATERIAL = Enum.Material.SmoothPlastic
local CUBE_MARK_FACES = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Top, Enum.NormalId.Bottom }
local BOLT_FACES = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

local function inert(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
end

-- Twelve frame bars round a box of edge length L centred on `origin`, bar side t, parented to `root`.
local function buildFrame(root: BasePart, origin: CFrame, L: number, t: number, color: Color3)
	local d = L / 2
	local n = 0
	local function bar(size: Vector3, cf: CFrame)
		n += 1
		local p = Instance.new("Part")
		p.Name = "CubeEdge_" .. n
		p.Size = size
		p.CFrame = origin * cf
		p.Material = CUBE_MATERIAL
		p.MaterialVariant = "" -- never a map's MaterialService variant (SPACE-4 turned the gold into brown scaffolding)
		p.Color = color
		inert(p)
		p.Parent = root
	end
	for _, a in { -1, 1 } do
		for _, b in { -1, 1 } do
			bar(Vector3.new(L + t, t, t), CFrame.new(0, a * d, b * d)) -- through the corners
			bar(Vector3.new(t, L - t, t), CFrame.new(a * d, 0, b * d))
			bar(Vector3.new(t, t, L - t), CFrame.new(a * d, b * d, 0))
		end
	end
end

function ItemArt.buildMysteryCube(podName: string, pos: Vector3, parent: Instance, podType: any?): BasePart
	local S = ItemRules.MYSTERY.cubeSize
	local t = S * 0.1 -- bar side
	local L = S - t -- bar centre line to bar centre line: the frame's outside is the cube size
	local origin = CFrame.new(pos)
	local familyName = ItemArt.cubeFamily(podType)
	local family = FAMILIES[familyName]

	local glass = Instance.new("Part")
	glass.Name = podName .. "_CoreVisual"
	glass.Size = Vector3.new(L, L, L) -- the faces pass through the bar centre lines
	glass.CFrame = origin
	glass.Material = Enum.Material.Glass
	glass.MaterialVariant = ""
	glass.Color = family.glass
	glass.Transparency = ItemArt.CUBE_GLASS_TRANSPARENCY
	glass.Reflectance = 0.15
	inert(glass)
	glass:SetAttribute("PodArt", "mystery")
	glass:SetAttribute("CubeFamily", familyName)
	glass:SetAttribute("FrameParts", ItemArt.CUBE_FRAME_PARTS)

	buildFrame(glass, origin, L, t, family.edge)

	-- The glowing core: a Neon block inside the glass (the client pulses its transparency, cycles its hue and fades it
	-- near the camera). Real geometry, not a billboard, so it renders for every player and in captures.
	local cs = L * ItemRules.CUBE_FX.coreSize
	local core = Instance.new("Part")
	core.Name = "CubeCore"
	core.Size = Vector3.new(cs, cs, cs)
	core.CFrame = origin
	core.Material = Enum.Material.Neon
	core.MaterialVariant = ""
	core.Color = CUBE_LIGHT
	core.Transparency = ItemRules.CUBE_FX.coreTransparencyMin
	inert(core)
	core.Parent = glass

	-- A bold "?" on every glass face (white, dark outline). SurfaceGuis are not BaseParts: they do not count in FrameParts.
	for _, face in CUBE_MARK_FACES do
		local sg = Instance.new("SurfaceGui")
		sg.Name = "CubeMark_" .. face.Name
		sg.Face = face
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 50
		sg.LightInfluence = 0
		sg.Brightness = 2
		sg.AlwaysOnTop = false
		sg.MaxDistance = 260
		local q = Instance.new("TextLabel")
		q.Size = UDim2.fromScale(0.56, 0.56) -- v29 A1: a small emissive glyph (was 0.8 of the face)
		q.Position = UDim2.fromScale(0.22, 0.22)
		q.BackgroundTransparency = 1
		q.Text = "?"
		q.Font = Enum.Font.FredokaOne
		q.TextScaled = true
		q.TextColor3 = Color3.new(1, 1, 1)
		q.Parent = sg
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(40, 20, 70)
		stroke.Thickness = 5
		stroke.Parent = q
		sg.Parent = glass
	end

	-- v29 W1b A5: Range 14 -> 7, Brightness 1 -> 0.4 (the cube lights pooled pink/violet on ISLAND-2 sand and roads)
	local light = Instance.new("PointLight")
	light.Name = "PodLight"
	light.Color = CUBE_LIGHT
	light.Brightness = 0.4
	light.Range = 7
	light.Shadows = false
	light.Parent = glass

	glass.Parent = parent
	return glass
end

------------------------------------------------------------------------------------------------------------------------
-- Boost block (Speed pods, cubes v3)
------------------------------------------------------------------------------------------------------------------------

-- Owner 2026-10-20: the gold winged coin beside the cubes read as a Sky Token nobody wanted. A Speed pod is now a mint
-- boost block: one translucent teal glass part, a bright mint edge frame (a SelectionBox: an adornment, not 12 more
-- parts, and it follows the part when the client spins it), a lightning bolt on the four sides and a mint light. One
-- part, so ItemClient's single-part spin and pop work unchanged. Effects stay particles (Vfx.onPickup, the glint).
ItemArt.BOOST_SIZE = 3.6
ItemArt.BOOST_GLASS = Color3.fromRGB(40, 210, 180)
ItemArt.BOOST_EDGE = Color3.fromRGB(150, 255, 225)
local BOLT_INK = Color3.fromRGB(10, 70, 64)

-- A lightning bolt from three slanted strokes: a dark copy a little fatter underneath, white on top, so the outline
-- never shows a seam where the strokes meet.
local function boltGlyph(sg: SurfaceGui)
	local strokes = {
		{ 0.53, 0.29, 0.17, 0.48, 24 }, -- x, y (centre), w, h (scale), rotation: upper slash, top right to middle
		{ 0.51, 0.5, 0.34, 0.13, -8 }, -- the jog across
		{ 0.47, 0.71, 0.17, 0.48, 24 }, -- lower slash down to the point
	}
	for layer = 1, 2 do
		local grow = if layer == 1 then 0.07 else 0
		for i, s in strokes do
			local f = Instance.new("Frame")
			f.Name = (if layer == 1 then "BoltInk" else "Bolt") .. i
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(s[1], s[2])
			f.Size = UDim2.fromScale(s[3] + grow, s[4] + grow)
			f.Rotation = s[5]
			f.BorderSizePixel = 0
			f.BackgroundColor3 = if layer == 1 then BOLT_INK else Color3.new(1, 1, 1)
			f.ZIndex = layer
			f.Parent = sg
		end
	end
end

function ItemArt.buildBoostBlock(podName: string, pos: Vector3, parent: Instance): BasePart
	local S = ItemArt.BOOST_SIZE
	local block = Instance.new("Part")
	block.Name = podName .. "_CoreVisual"
	block.Size = Vector3.new(S, S, S)
	block.CFrame = CFrame.new(pos)
	block.Material = Enum.Material.Glass
	block.MaterialVariant = ""
	block.Color = ItemArt.BOOST_GLASS
	block.Transparency = 0.3
	block.Reflectance = 0.15
	inert(block)
	block:SetAttribute("PodArt", "boost")
	local edge = Instance.new("SelectionBox")
	edge.Name = "BoostEdge"
	edge.Adornee = block
	edge.Color3 = ItemArt.BOOST_EDGE
	edge.LineThickness = 0.16
	edge.SurfaceColor3 = ItemArt.BOOST_EDGE
	edge.SurfaceTransparency = 0.85 -- a faint mint fill on top of the glass: the glow
	edge.Parent = block
	for _, face in BOLT_FACES do
		local sg = Instance.new("SurfaceGui")
		sg.Name = "BoostBolt_" .. face.Name
		sg.Face = face
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 50
		sg.LightInfluence = 0
		sg.Brightness = 2
		sg.MaxDistance = 220
		boltGlyph(sg)
		sg.Parent = block
	end
	local light = Instance.new("PointLight")
	light.Name = "PodLight"
	light.Color = ItemArt.BOOST_EDGE
	light.Brightness = 0.45 -- v29 A5: was 1.1
	light.Range = 7 -- v29 A5: was 13
	light.Shadows = false
	light.Parent = block
	block.Parent = parent
	return block
end

-- ItemEffects.paintPods: re-tint a balloon core from the pod type (idempotent). Other cores are left to the caller.
function ItemArt.paintCore(core: BasePart, podType: any): boolean
	local spec = ItemArt.podSpec(podType)
	if not spec or core:GetAttribute("PodArt") ~= spec.kind then
		return false
	end
	ItemArt.setTint(core, spec.tint or WHITE)
	podTexture(core, spec)
	local light = core:FindFirstChildOfClass("PointLight")
	if light then
		light.Color = spec.light
	end
	return true
end

return ItemArt
