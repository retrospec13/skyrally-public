--!strict
local InsertService = game:GetService("InsertService")
local Lighting = game:GetService("Lighting")

local M = {}

-- Approved Tripo v3.1 Stone Sauropod Statue asset IDs (uploaded & granted to Universe 0)
-- Model ID: 98086222919300 | MeshId: rbxassetid://118575425896602 | Refined Texture Asset: 87703636628661
M.STONE_SAUROPOD_MODEL_ID = 98086222919300
M.STONE_SAUROPOD_MESH_ID = "rbxassetid://118575425896602"
M.STONE_SAUROPOD_TEX_ID = "rbxthumb://type=Asset&id=87703636628661&w=420&h=420"

local partCount: number = 0

local function createFolder(name: string, parent: Instance): Folder
	local existing: Instance? = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local folder: Folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function addPart(
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	cframe: CFrame,
	material: Enum.Material,
	color: Color3,
	parent: Instance,
	transparency: number?,
	canCollide: boolean?
): Part
	local p: Part = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Material = material
	p.Color = color
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = transparency or 0
	p.Reflectance = 0
	if canCollide ~= nil then
		p.CanCollide = canCollide
	else
		p.CanCollide = true
	end
	p.Parent = parent
	partCount = partCount + 1
	return p
end

local function addWedge(
	name: string,
	size: Vector3,
	cframe: CFrame,
	material: Enum.Material,
	color: Color3,
	parent: Instance,
	transparency: number?,
	canCollide: boolean?
): WedgePart
	local w: WedgePart = Instance.new("WedgePart")
	w.Name = name
	w.Size = size
	w.CFrame = cframe
	w.Material = material
	w.Color = color
	w.Anchored = true
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Transparency = transparency or 0
	w.Reflectance = 0
	if canCollide ~= nil then
		w.CanCollide = canCollide
	else
		w.CanCollide = true
	end
	w.Parent = parent
	partCount = partCount + 1
	return w
end

local function configureVolcanicSunshineLighting()
	-- Enclosed Volcanic Cavern Lighting per 04_dino4_controls.png & A17:
	-- Cool cyan/blue daylight streaming down through the ceiling skylight oculus + warm molten orange/amber bounce light from below
	Lighting.Brightness = 1.95
	Lighting.ClockTime = 13.4
	Lighting.GeographicLatitude = 22
	Lighting.Ambient = Color3.fromRGB(76, 56, 58)
	Lighting.OutdoorAmbient = Color3.fromRGB(98, 124, 152)
	Lighting.ColorShift_Bottom = Color3.fromRGB(255, 114, 34)
	Lighting.ColorShift_Top = Color3.fromRGB(145, 224, 255)
	Lighting.EnvironmentDiffuseScale = 0.42
	Lighting.EnvironmentSpecularScale = 0.16
	Lighting.ExposureCompensation = -0.06
	Lighting.GlobalShadows = true

	for _, child in ipairs(Lighting:GetChildren()) do
		if child.Name:match("^SkyRally_") then
			child:Destroy()
		end
	end

	local atmo = Instance.new("Atmosphere")
	atmo.Name = "SkyRally_Atmosphere"
	atmo.Density = 0.24
	atmo.Offset = 0.10
	atmo.Color = Color3.fromRGB(154, 210, 242)
	atmo.Decay = Color3.fromRGB(218, 112, 58)
	atmo.Glare = 0.08
	atmo.Haze = 1.15
	atmo.Parent = Lighting

	-- Restrained Bloom (Threshold >= 1.65) so narrow lava veins glow warmly without blowing out the crust or rock planes
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "SkyRally_Bloom"
	bloom.Intensity = 0.16
	bloom.Size = 16
	bloom.Threshold = 1.75
	bloom.Parent = Lighting

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "SkyRally_ColorCorrection"
	cc.Brightness = 0.01
	cc.Contrast = 0.14
	cc.Saturation = 0.14
	cc.TintColor = Color3.fromRGB(255, 245, 234)
	cc.Parent = Lighting
end

local function buildWedgeRing(
	name: string,
	centerCF: CFrame,
	radius: number,
	thickness: number,
	width: number,
	segments: number,
	material: Enum.Material,
	color: Color3,
	parent: Instance
): Model
	local mdl: Model = Instance.new("Model")
	mdl.Name = name
	mdl.Parent = parent
	local arcLen: number = (2 * math.pi * radius / segments) * 1.12
	for i = 1, segments do
		local angle: number = (i - 1) * (2 * math.pi / segments)
		local segCF: CFrame = centerCF
			* CFrame.Angles(0, 0, angle)
			* CFrame.new(0, radius, 0)
		addPart(
			name .. "_Segment_" .. tostring(i),
			Enum.PartType.Block,
			Vector3.new(arcLen, thickness, width),
			segCF,
			material,
			color,
			mdl,
			nil,
			false
		)
	end
	return mdl
end

-- Approved 04_dino4_controls.png Booster Ring:
-- Cream/Ivory outer rim, dark plum/burgundy inner rim, and 4 gold/brass cardinal clasps at 12, 3, 6, 9 o'clock
local function buildBoosterRing(name: string, centerCF: CFrame, parent: Instance, hasCoin: boolean?, coinId: number?): Model
	local mdl: Model = Instance.new("Model")
	mdl.Name = name
	mdl.Parent = parent

	buildWedgeRing(
		name .. "_InnerPlum",
		centerCF,
		11.4,
		2.2,
		3.2,
		24,
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(98, 48, 86),
		mdl
	)

	buildWedgeRing(
		name .. "_InnerGlow",
		centerCF,
		10.3,
		0.7,
		1.8,
		24,
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(224, 178, 72),
		mdl
	)

	local segments: number = 24
	local housingArcLen: number = (2 * math.pi * 13.4 / segments) * 1.12
	for i = 1, segments do
		local angle: number = (i - 1) * (2 * math.pi / segments)
		local housingCF: CFrame = centerCF * CFrame.Angles(0, 0, angle) * CFrame.new(0, 13.4, 0)
		addPart(
			name .. "_OuterCream_" .. tostring(i),
			Enum.PartType.Block,
			Vector3.new(housingArcLen, 2.4, 3.8),
			housingCF,
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(242, 232, 208),
			mdl,
			nil,
			false
		)
	end

	for c = 1, 4 do
		local cAng: number = (c - 1) * (math.pi * 0.5)
		local claspCF: CFrame = centerCF * CFrame.Angles(0, 0, cAng) * CFrame.new(0, 13.0, 0)
		addPart(
			name .. "_GoldClasp_" .. tostring(c),
			Enum.PartType.Block,
			Vector3.new(3.8, 4.2, 4.6),
			claspCF,
			Enum.Material.Metal,
			Color3.fromRGB(224, 168, 52),
			mdl,
			nil,
			false
		)
	end

	local trigger: Part = addPart(
		name .. "_BoostTriggerDisc",
		Enum.PartType.Cylinder,
		Vector3.new(2.5, 22, 22),
		centerCF * CFrame.Angles(0, math.pi / 2, 0),
		Enum.Material.Neon,
		Color3.fromRGB(255, 220, 60),
		mdl,
		1,
		false
	)
	trigger:SetAttribute("TriggerType", "BoosterRing")
	trigger:SetAttribute("BoostPower", 135)

	if hasCoin then
		local coinCF: CFrame = centerCF * CFrame.Angles(0, math.pi / 2, 0)
		local coin: Part = addPart(
			"ChallengeCoin_" .. tostring(coinId or 1),
			Enum.PartType.Cylinder,
			Vector3.new(1.4, 9, 9),
			coinCF,
			Enum.Material.Neon,
			Color3.fromRGB(255, 215, 0),
			mdl,
			0,
			false
		)
		coin:SetAttribute("CoinId", coinId or 1)
		coin:SetAttribute("CollectibleType", "ChallengeCoin")
	end

	return mdl
end

local function buildGroundBoostPad(name: string, cf: CFrame, parent: Instance): Model
	local mdl: Model = Instance.new("Model")
	mdl.Name = name
	mdl.Parent = parent

	local base: Part = addPart(
		"BasePlate",
		Enum.PartType.Block,
		Vector3.new(16, 0.8, 24),
		cf,
		Enum.Material.Sandstone,
		Color3.fromRGB(165, 128, 92),
		mdl,
		nil,
		false
	)
	base:SetAttribute("TriggerType", "GroundBoostPad")

	for i = 1, 3 do
		local zOff: number = -8 + (i - 1) * 8
		local leftCF: CFrame = cf * CFrame.new(-3.2, 0.7, zOff) * CFrame.Angles(0, math.rad(45), 0)
		local rightCF: CFrame = cf * CFrame.new(3.2, 0.7, zOff) * CFrame.Angles(0, math.rad(-45), 0)
		addWedge("ChevronL_" .. tostring(i), Vector3.new(1.2, 1.0, 6.5), leftCF, Enum.Material.Neon, Color3.fromRGB(255, 220, 40), mdl, 0, false)
		addWedge("ChevronR_" .. tostring(i), Vector3.new(1.2, 1.0, 6.5), rightCF, Enum.Material.Neon, Color3.fromRGB(255, 220, 40), mdl, 0, false)
	end
	return mdl
end

local function buildItemPodSpawn(name: string, pos: Vector3, podType: string, station: number, parent: Instance): Part
	local spawnPart: Part = addPart(
		name,
		Enum.PartType.Block,
		Vector3.new(6, 6, 6),
		CFrame.new(pos),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(255, 255, 255),
		parent,
		1,
		false
	)
	spawnPart:SetAttribute("ItemPodSpawn", true)
	spawnPart:SetAttribute("PodType", podType)
	spawnPart:SetAttribute("Station", station)
	spawnPart:SetAttribute("RespawnSeconds", 4)

	local color: Color3 = Color3.fromRGB(255, 75, 65)
	if podType == "Blue" then
		color = Color3.fromRGB(65, 215, 245)
	elseif podType == "Speed" then
		color = Color3.fromRGB(95, 245, 130)
	elseif podType == "Air" then
		color = Color3.fromRGB(255, 200, 55)
	end

	local core: Part = addPart(
		name .. "_CoreVisual",
		Enum.PartType.Block,
		Vector3.new(3.8, 3.8, 3.8),
		CFrame.new(pos) * CFrame.Angles(math.rad(45), math.rad(45), 0),
		Enum.Material.Neon,
		color,
		spawnPart,
		0.1,
		false
	)
	addWedge(
		name .. "_GemTop",
		Vector3.new(2.8, 2.8, 2.8),
		CFrame.new(pos + Vector3.new(0, 2.2, 0)) * CFrame.Angles(0, math.rad(45), 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(235, 250, 255),
		core,
		0.15,
		false
	)
	return spawnPart
end

local function buildPrehistoricShrubCluster(name: string, basePos: Vector3, parent: Instance)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	local leafCol1 = Color3.fromRGB(78, 128, 62)
	local leafCol2 = Color3.fromRGB(106, 152, 74)
	for k = 1, 5 do
		local yaw = (k - 1) * (math.pi * 2 / 5)
		local cf = CFrame.new(basePos) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-28), 0, 0) * CFrame.new(0, 4.5, -3.5)
		addWedge(
			"Frond_" .. tostring(k),
			Vector3.new(3.5, 9.0, 6.5),
			cf,
			Enum.Material.Grass,
			if k % 2 == 0 then leafCol1 else leafCol2,
			m,
			0,
			false
		)
	end
end

local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2: number = t * t
	local t3: number = t2 * t
	return 0.5 * (
		(2 * p1)
		+ (-p0 + p2) * t
		+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
		+ (-p0 + 3 * p1 - 3 * p2 + p3) * t3
	)
end

local function generateWaypoints(rawNodes: { { pos: Vector3, bank: number, flex: Vector3 } }, flexScale: number, stepsPerSeg: number): ({ { pos: Vector3, bank: number, station: number } }, number)
	local count: number = #rawNodes
	local adjusted: { Vector3 } = {}
	for i = 1, count do
		adjusted[i] = rawNodes[i].pos + rawNodes[i].flex * flexScale
	end

	local waypoints: { { pos: Vector3, bank: number, station: number } } = {}
	local totalLen: number = 0

	for i = 1, count do
		local p0: Vector3 = adjusted[((i - 2) % count) + 1]
		local p1: Vector3 = adjusted[i]
		local p2: Vector3 = adjusted[(i % count) + 1]
		local p3: Vector3 = adjusted[((i + 1) % count) + 1]
		local b1: number = rawNodes[i].bank
		local b2: number = rawNodes[(i % count) + 1].bank

		for s = 0, stepsPerSeg - 1 do
			local t: number = s / stepsPerSeg
			local pt: Vector3 = catmullRom(p0, p1, p2, p3, t)
			local bk: number = b1 + (b2 - b1) * t
			if #waypoints > 0 then
				totalLen = totalLen + (pt - waypoints[#waypoints].pos).Magnitude
			end
			table.insert(waypoints, {
				pos = pt,
				bank = bk,
				station = totalLen,
			})
		end
	end

	local closingDist: number = (waypoints[1].pos - waypoints[#waypoints].pos).Magnitude
	totalLen = totalLen + closingDist
	table.insert(waypoints, {
		pos = waypoints[1].pos,
		bank = waypoints[1].bank,
		station = totalLen,
	})

	return waypoints, totalLen
end

function M.build(): Folder
	partCount = 0
	configureVolcanicSunshineLighting()
	local rng: Random = Random.new(40401)
	local root: Folder = createFolder("DINO-4", workspace)

	local trackFolder: Folder = createFolder("TrackRibbon", root)
	local calderaFolder: Folder = createFolder("VolcanoCaldera", root)
	local landmarksFolder: Folder = createFolder("Landmarks", root)
	local boostsFolder: Folder = createFolder("BoostsAndPods", root)
	local checkpointsFolder: Folder = createFolder("Checkpoints", root)
	local waypointsFolder: Folder = createFolder("WaypointsData", root)

	-- Control nodes calibrated to hit 5,450-stud closed loop facing -Z at Start/Finish,
	-- curving noticeably left to X=-44 at Z=-135 (through the foreground Romanesque arch) and then sweeping right to X=-12 at Z=-285
	-- so the bridge S-curve, left/right lava basin, and Principal Stone Sauropod match 04_dino4_controls.png.
	-- 2026-10-18 L02 fix: nodes 9-11 (hairpin, was R=36 studs, below the plane's sharp-bank minimum ~43) and 17-19
	-- (finish turn, was R=46) re-solved by tools/course/route_geometry.py search to R>=114 / R>=88 at length 5450.
	-- The start S-curve (R~46 at station 160) is the approved concept's causeway inside the open start chamber.
	local controlNodes: { { pos: Vector3, bank: number, flex: Vector3 } } = {
		{ pos = Vector3.new(0, 140, 0), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-8, 134, -85), bank = -5, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-30, 126, -155), bank = -10, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-10, 114, -275), bank = 8, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-125, 86, -780), bank = -18, flex = Vector3.new(-45, 0, 0) },
		{ pos = Vector3.new(-95, 92, -1120), bank = 12, flex = Vector3.new(-35, 0, 0) },
		{ pos = Vector3.new(20, 110, -1380), bank = 18, flex = Vector3.new(25, 0, 0) },
		{ pos = Vector3.new(0, 78, -1560), bank = 5, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-25, 52, -1720), bank = -10, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-150, 54, -1807), bank = -20, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-395, 58, -1735), bank = -22, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-520, 58, -1680), bank = -18, flex = Vector3.new(-120, 0, -140) },
		{ pos = Vector3.new(-820, 62, -1520), bank = -24, flex = Vector3.new(-220, 0, -120) },
		{ pos = Vector3.new(-920, 66, -1220), bank = -25, flex = Vector3.new(-240, 0, 0) },
		{ pos = Vector3.new(-740, 78, -920), bank = -20, flex = Vector3.new(-160, 0, 120) },
		{ pos = Vector3.new(-480, 98, -640), bank = -16, flex = Vector3.new(-80, 0, 80) },
		{ pos = Vector3.new(-314, 114, -320), bank = -20, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-302, 126, 117), bank = -18, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-110, 136, 205), bank = -12, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(0, 140, 115), bank = 0, flex = Vector3.new(0, 0, 0) },
	}

	local lowScale: number = 0.0
	local highScale: number = 3.5
	local bestWaypoints: { { pos: Vector3, bank: number, station: number } } = {}
	local measuredLength: number = 0

	for _ = 1, 24 do
		local mid: number = (lowScale + highScale) * 0.5
		local wps, len = generateWaypoints(controlNodes, mid, 9)
		bestWaypoints = wps
		measuredLength = len
		if len < 5450 then
			lowScale = mid
		else
			highScale = mid
		end
	end

	-- Palette from approved 04_dino4_controls.png & A16/A17:
	-- Thick modular stone paver deck with dark mortar joints, chiseled sandstone curbs & Romanesque voussoir arches,
	-- Terracotta/Amber lower cavern cliffs, Warm Ochre/Sienna upper cavern dome, dark basalt lava crust with narrow hot veins.
	local mortarBaseCol = Color3.fromRGB(48, 30, 24)
	local paverWarmA = Color3.fromRGB(142, 96, 68)
	local paverWarmB = Color3.fromRGB(124, 82, 56)
	local paverWarmC = Color3.fromRGB(158, 108, 76)
	local sandstoneWarm = Color3.fromRGB(206, 152, 102)
	local sandstoneLight = Color3.fromRGB(228, 182, 128)
	local terracottaCliff = Color3.fromRGB(178, 104, 66)
	local terracottaDeep = Color3.fromRGB(142, 78, 52)
	local upperSlatePurple = Color3.fromRGB(122, 76, 58)
	local roofDarkSlate = Color3.fromRGB(92, 56, 44)
	local basaltDark = Color3.fromRGB(48, 34, 32)
	local basaltMid = Color3.fromRGB(68, 48, 44)

	-- Continuous Subterranean Cavern Enclosure along the entire 5,450-stud circuit via Roblox Terrain (ART_BAR construction rules: zero primitive slab/wedge stacks for cavern walls/roofs)
	local terrain = workspace.Terrain
	terrain:Clear()
	pcall(function()
		terrain:SetMaterialColor(Enum.Material.Sandstone, Color3.fromRGB(178, 104, 66))
		terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(116, 70, 52))
		terrain:SetMaterialColor(Enum.Material.Basalt, Color3.fromRGB(48, 34, 32))
		terrain:SetMaterialColor(Enum.Material.CrackedLava, Color3.fromRGB(238, 78, 18))
	end)

	-- Build Thick Curved Paver Stone Bridge Deck + Continuous Subterranean Terrain Cavern Enclosure (A16 & A02)
	local trackWidth: number = 32
	for i = 1, #bestWaypoints - 1 do
		local wp1 = bestWaypoints[i]
		local wp2 = bestWaypoints[i + 1]
		local p1: Vector3 = wp1.pos
		local p2: Vector3 = wp2.pos
		local segVec: Vector3 = p2 - p1
		local segLen: number = segVec.Magnitude
		if segLen > 0.1 then
			local mid: Vector3 = (p1 + p2) * 0.5
			local bankRad: number = math.rad((wp1.bank + wp2.bank) * 0.5)
			local cf: CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, bankRad)

			local isStartVista: boolean = (mid.Z > -420 and wp1.station < 460)
			local localWidth: number = if isStartVista then 22 else trackWidth
			local isLavaGap: boolean = (wp1.station >= 1880 and wp1.station <= 2040)

			if not isLavaGap then
				-- Deep Mortar & Stone Spandrel Structural Beam (overlapped by +3.6 studs so curved bridge segments are 100% seamless with zero floating gaps)
				addPart(
					"TrackSeg_" .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(localWidth, 7.6, segLen + 3.6),
					cf * CFrame.new(0, -2.2, 0),
					Enum.Material.Slate,
					mortarBaseCol,
					trackFolder
				)
				-- Individual Beveled Stone Pavers on the upper deck with subtle mortar seams (2 staggered columns matching 04_dino4_controls.png)
				local paverCols = 2
				local paverW = (localWidth - 1.2) / paverCols
				local paverRows = if isStartVista then 2 else 1
				local rowLen = ((segLen + 1.8) - (paverRows * 0.45)) / paverRows
				for r = 1, paverRows do
					local zOff = -segLen * 0.5 + (r - 0.5) * (segLen / paverRows)
					for c = 1, paverCols do
						local xOff = (c - 1.5) * (paverW + 0.30)
						local pCol = if (i + r + c) % 3 == 0 then paverWarmC elseif (i + r + c) % 2 == 0 then paverWarmA else paverWarmB
						addPart(
							string.format("Paver_%d_%d_%d", i, r, c),
							Enum.PartType.Block,
							Vector3.new(paverW, 1.4, math.max(2.0, rowLen)),
							cf * CFrame.new(xOff, 2.0, zOff),
							Enum.Material.Sandstone,
							pCol,
							trackFolder,
							0,
							false
						)
					end
				end

				-- Low Chiseled Dark-Stone & Sandstone Edge Curbs along both deck edges
				local curbCol = if i % 2 == 0 then basaltMid else terracottaDeep
				local curbSubLen = (segLen * 0.54)
				for cb = 1, 2 do
					local cbZ = (cb == 1 and -segLen * 0.25 or segLen * 0.25)
					local cbH = if isStartVista then (if (i + cb) % 2 == 0 then 3.2 else 2.6) else (if (i + cb) % 2 == 0 then 5.2 else 4.4)
					addPart(
						string.format("CurbL_%d_%d", i, cb),
						Enum.PartType.Block,
						Vector3.new(3.6, cbH, curbSubLen),
						cf * CFrame.new(-(localWidth * 0.5 + 1.4), 0.8, cbZ),
						Enum.Material.Sandstone,
						if (i + cb) % 2 == 0 then curbCol else sandstoneWarm,
						trackFolder
					)
					addPart(
						string.format("CurbR_%d_%d", i, cb),
						Enum.PartType.Block,
						Vector3.new(3.6, cbH, curbSubLen),
						cf * CFrame.new((localWidth * 0.5 + 1.4), 0.8, cbZ),
						Enum.Material.Sandstone,
						if (i + cb) % 2 == 1 then curbCol else sandstoneWarm,
						trackFolder
					)
				end
				-- Under-deck corbelled stone trim along bridge sides
				addPart(
					"BridgeFascia_" .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(localWidth + 4.4, 3.4, segLen + 3.4),
					cf * CFrame.new(0, -4.6, 0),
					Enum.Material.Sandstone,
					terracottaCliff,
					trackFolder,
					0,
					false
				)

				-- Heavy Stepped Stone Viaduct Piers rising out of the lava every 5 segments on start vista, every 5 segments elsewhere
				local pierStep = 5
				if i % pierStep == 0 then
					local pierH = math.max(16, mid.Y - 8)
					addPart(
						"CausewayPier_" .. tostring(i),
						Enum.PartType.Block,
						Vector3.new(localWidth * 0.42, pierH, 11),
						CFrame.new(mid.X, mid.Y - pierH * 0.5 - 4.5, mid.Z) * CFrame.Angles(0, math.atan2(-segVec.X, -segVec.Z), 0),
						Enum.Material.Sandstone,
						terracottaCliff,
						calderaFolder,
						0,
						false
					)
					addPart(
						"PierFooting_" .. tostring(i),
						Enum.PartType.Block,
						Vector3.new(localWidth * 0.58, 8, 16),
						CFrame.new(mid.X, if isStartVista then 108 else 16, mid.Z) * CFrame.Angles(0, math.atan2(-segVec.X, -segVec.Z), 0),
						Enum.Material.Basalt,
						basaltDark,
						calderaFolder,
						0,
						false
					)
				end
			end

			-- Continuous Subterranean Terrain Cavern Enclosure along the non-start circuit (station 460..5220)
			if i % 3 == 0 and not (wp1.station < 460 or wp1.station > 5220) then
				local archCF: CFrame = CFrame.lookAt(mid, p2)
				local spanLen = segLen * 4.2
				terrain:FillBlock(archCF * CFrame.new(-142, 34, 0), Vector3.new(48, 136, spanLen), Enum.Material.Sandstone)
				terrain:FillBlock(archCF * CFrame.new(142, 34, 0), Vector3.new(48, 136, spanLen), Enum.Material.Sandstone)
				terrain:FillBlock(archCF * CFrame.new(0, 146, 0), Vector3.new(256, 40, spanLen + 24), Enum.Material.Rock)
				if i % 6 == 0 then
					buildPrehistoricShrubCluster("CliffShrubL_" .. tostring(i), (archCF * CFrame.new(-118, 18, 0)).Position, landmarksFolder)
					buildPrehistoricShrubCluster("CliffShrubR_" .. tostring(i), (archCF * CFrame.new(118, 18, 0)).Position, landmarksFolder)
				end
			end

			-- Respawn Checkpoints every 12 segments, never within 75 studs of start line
			if i % 12 == 1 and wp1.station < 5200 then
				local cpIndex: number = math.floor(i / 12) + 1
				local cp: Part = addPart(
					"Checkpoint_" .. tostring(cpIndex),
					Enum.PartType.Block,
					Vector3.new(trackWidth + 24, 42, 6),
					cf * CFrame.new(0, 18, 0),
					Enum.Material.SmoothPlastic,
					Color3.fromRGB(255, 200, 50),
					checkpointsFolder,
					1,
					false
				)
				cp:SetAttribute("CheckpointIndex", cpIndex)
				cp:SetAttribute("Station", math.floor(wp1.station))
			end
		end
	end

	waypointsFolder:SetAttribute("TrackLength", measuredLength)
	for idx, wp in ipairs(bestWaypoints) do
		local nextWp = bestWaypoints[math.min(idx + 1, #bestWaypoints)]
		local diff = nextWp.pos - wp.pos
		local tan = if diff.Magnitude > 0.01 then diff.Unit else Vector3.new(0, 0, -1)
		local val = Instance.new("Vector3Value")
		val.Name = "WP_" .. tostring(idx)
		val.Value = wp.pos
		val:SetAttribute("Index", idx)
		val:SetAttribute("Bank", wp.bank)
		val:SetAttribute("Station", wp.station)
		val:SetAttribute("Tangent", tan)
		val.Parent = waypointsFolder
	end

	-- Alternate Route 1: DINO-4-ALT-1 (Right Cliff Tunnel connecting directly from the Start-Vista Right Cliff Tunnel Portal at (58, 128, -148) into the right cliff)
	local alt1Pts: { Vector3 } = {
		Vector3.new(64, 126, -152),
		Vector3.new(112, 114, -360),
		Vector3.new(165, 92, -820),
		Vector3.new(180, 98, -1220),
		Vector3.new(72, 106, -1320),
	}
	for i = 1, #alt1Pts - 1 do
		local a: Vector3 = alt1Pts[i]
		local b: Vector3 = alt1Pts[i + 1]
		local len: number = (b - a).Magnitude
		local cf: CFrame = CFrame.lookAt((a + b) * 0.5, b)
		addPart("Alt1Floor_" .. tostring(i), Enum.PartType.Block, Vector3.new(28, 3.6, len + 2), cf, Enum.Material.Sandstone, paverWarmA, trackFolder)
		addPart("Alt1WallL_" .. tostring(i), Enum.PartType.Block, Vector3.new(6, 32, len + 2), cf * CFrame.new(-16, 15, 0), Enum.Material.Sandstone, terracottaCliff, trackFolder)
		addPart("Alt1WallR_" .. tostring(i), Enum.PartType.Block, Vector3.new(6, 32, len + 2), cf * CFrame.new(16, 15, 0), Enum.Material.Sandstone, terracottaCliff, trackFolder)
		addPart("Alt1Roof_" .. tostring(i), Enum.PartType.Block, Vector3.new(38, 6, len + 2), cf * CFrame.new(0, 31, 0), Enum.Material.Slate, upperSlatePurple, trackFolder)
		addPart("Alt1TorchStrip_" .. tostring(i), Enum.PartType.Block, Vector3.new(1.8, 0.8, len * 0.82), cf * CFrame.new(0, 27.5, 0), Enum.Material.Neon, Color3.fromRGB(255, 168, 48), trackFolder, 0.25, false)
	end
	buildItemPodSpawn("Alt1_BluePod", Vector3.new(165, 97, -820), "Blue", 860, boostsFolder)

	-- Alternate Route 2: DINO-4-ALT-2 (Basin Perimeter Stone Ledge)
	local alt2Pts: { Vector3 } = {
		Vector3.new(-320, 62, -1650),
		Vector3.new(-480, 64, -1580),
		Vector3.new(-540, 68, -1240),
		Vector3.new(-740, 78, -1100),
	}
	for i = 1, #alt2Pts - 1 do
		local a: Vector3 = alt2Pts[i]
		local b: Vector3 = alt2Pts[i + 1]
		local len: number = (b - a).Magnitude
		local cf: CFrame = CFrame.lookAt((a + b) * 0.5, b)
		addPart("Alt2Ledge_" .. tostring(i), Enum.PartType.Block, Vector3.new(26, 4.0, len), cf, Enum.Material.Sandstone, sandstoneWarm, trackFolder)
	end

	-- 6.2 Volcanic Lava Basin & A17 Lava Hierarchy via Continuous Roblox Terrain (ART_BAR Construction Rules):
	-- Organic masses (cavern shell, roof, cliff walls, lava basin, floor) are sculpted in Roblox Terrain, continuous and sealed.
	local volcanoMdl: Model = Instance.new("Model")
	volcanoMdl.Name = "VolcanoCalderaAssembly"
	volcanoMdl.Parent = calderaFolder

	local calderaCenter: Vector3 = Vector3.new(-380, 12, -1050)
	local lavaSea: Part = addPart(
		"LavaSeaFloor",
		Enum.PartType.Block,
		Vector3.new(2600, 4, 2800),
		CFrame.new(calderaCenter),
		Enum.Material.CrackedLava,
		Color3.fromRGB(232, 74, 18),
		volcanoMdl,
		1,
		true
	)
	lavaSea:SetAttribute("HazardType", "LethalLava")

	-- Sculpt Lower Caldera Lava Floor & Basalt Crust Islands in Terrain
	terrain:FillBlock(CFrame.new(calderaCenter + Vector3.new(0, -4, 0)), Vector3.new(2400, 12, 2600), Enum.Material.CrackedLava)
	for v = 1, 14 do
		local vz = -460 - (v - 1) * 115
		local vx = -380 + math.sin(v * 1.3) * 260
		terrain:FillBlock(
			CFrame.new(vx, 12, vz) * CFrame.Angles(0, math.rad((v % 3 - 1) * 18), 0),
			Vector3.new(420, 8, 68),
			Enum.Material.Basalt
		)
	end

	-- =========================================================================
	-- A16 & A17 START-VISTA CONTINUOUS TERRAIN CAVERN SHELL, CLIFFS, ROOF & LAVA BASIN
	-- Zero primitive slab/wedge stacks for organic masses; 100% continuous sealed Roblox Terrain!
	-- =========================================================================
	-- L02 fix 2026-10-18: the route descends from y~120 to y~93 through the start chamber, so the start lava
	-- (previously top y=117, above the deck) is dropped to sit well below the causeway everywhere.
	local START_LAVA_DROP = 40
	local startLavaShelf = Instance.new("Model")
	startLavaShelf.Name = "StartVistaLavaChannels"
	startLavaShelf.Parent = volcanoMdl

	-- Invisible hazard detector matching the Terrain CrackedLava floor at Y=115
	local startLavaBed = addPart(
		"StartLavaBed",
		Enum.PartType.Block,
		Vector3.new(540, 4, 620),
		CFrame.new(0, 115.0 - START_LAVA_DROP, -240),
		Enum.Material.CrackedLava,
		Color3.fromRGB(235, 76, 18),
		startLavaShelf,
		1,
		false
	)
	startLavaBed:SetAttribute("HazardType", "LethalLava")

	-- 1. Continuous Molten CrackedLava Floor across the Start Chamber (Y = 108..117)
	terrain:FillBlock(CFrame.new(0, 112 - START_LAVA_DROP, -230), Vector3.new(440, 10, 560), Enum.Material.CrackedLava)

	-- 2. Organic Basalt Crust Islands rising slightly out of the CrackedLava floor (~55% coverage, leaving natural winding molten channels around the bridge and pedestal)
	local terrainCrustIslands = {
		{ pos = Vector3.new(-88, 115.5, -52), r = 34, h = 6 },
		{ pos = Vector3.new(86, 115.5, -54), r = 32, h = 6 },
		{ pos = Vector3.new(-92, 115.5, -148), r = 36, h = 6 },
		{ pos = Vector3.new(92, 115.5, -156), r = 34, h = 6 },
		{ pos = Vector3.new(-22, 115.0, -84), r = 18, h = 5 },
		{ pos = Vector3.new(-38, 115.0, -198), r = 20, h = 5 },
		{ pos = Vector3.new(34, 115.0, -88), r = 16, h = 5 },
		{ pos = Vector3.new(-88, 115.5, -258), r = 38, h = 6 },
		{ pos = Vector3.new(88, 115.5, -262), r = 36, h = 6 },
		{ pos = Vector3.new(-36, 115.5, -328), r = 26, h = 6 },
		{ pos = Vector3.new(40, 115.5, -332), r = 26, h = 6 },
	}
	for _, ci in ipairs(terrainCrustIslands) do
		terrain:FillCylinder(CFrame.new(ci.pos - Vector3.new(0, START_LAVA_DROP, 0)), ci.h, ci.r, Enum.Material.Basalt)
	end

	-- 2b. Organic Cylindrical Molten Lava Pools & Winding Channels (SmoothPlastic with subtle warm glow so narrow lava veins read warmly without blowing out the crust or rock planes)
	local lavaPools = {
		{ pos = Vector3.new(-54, 116.8, -62), r = 22 },
		{ pos = Vector3.new(-62, 116.8, -112), r = 24 },
		{ pos = Vector3.new(-58, 116.8, -168), r = 25 },
		{ pos = Vector3.new(-52, 116.8, -225), r = 24 },
		{ pos = Vector3.new(10, 116.8, -62), r = 20 },
		{ pos = Vector3.new(18, 116.8, -116), r = 24 },
		{ pos = Vector3.new(22, 116.8, -162), r = 32 },
		{ pos = Vector3.new(48, 116.8, -142), r = 22 },
		{ pos = Vector3.new(-6, 116.8, -148), r = 22 },
		{ pos = Vector3.new(2, 116.8, -212), r = 24 },
	}
	for idx, lp in ipairs(lavaPools) do
		addPart(
			"MoltenPoolOuter_" .. tostring(idx),
			Enum.PartType.Cylinder,
			Vector3.new(1.2, lp.r * 2, lp.r * 2),
			CFrame.new(lp.pos - Vector3.new(0, START_LAVA_DROP, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(224, 72, 18),
			startLavaShelf,
			0.12,
			false
		)
		addPart(
			"MoltenPoolCore_" .. tostring(idx),
			Enum.PartType.Cylinder,
			Vector3.new(1.3, lp.r * 1.15, lp.r * 1.15),
			CFrame.new(lp.pos + Vector3.new(0, 0.08 - START_LAVA_DROP, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(252, 142, 32),
			startLavaShelf,
			0.08,
			false
		)
	end

	-- Warm upward-facing PointLights along the start vista so the undersides of the bridge, arches, pedestal, and cliffs catch rich molten orange bounce light
	for lp = 1, 12 do
		local lpX = if lp % 3 == 0 then 18 elseif lp % 2 == 0 then 38 else -38
		local lpZ = -32 - (lp - 1) * 32
		local lpPart = addPart(
			"StartLavaBounceEmitter_" .. tostring(lp),
			Enum.PartType.Block,
			Vector3.new(2, 2, 2),
			CFrame.new(lpX, 123 - START_LAVA_DROP + 6, lpZ),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(255, 128, 32),
			startLavaShelf,
			1,
			false
		)
		local ptLight = Instance.new("PointLight")
		ptLight.Color = Color3.fromRGB(255, 134, 42)
		ptLight.Brightness = 1.65
		ptLight.Range = 52
		ptLight.Shadows = false
		ptLight.Parent = lpPart
	end

	-- 3. Continuous Sealed Start-Vista Terrain Cavern Dome, Stratified Left/Right Sandstone Cliffs, and Circular Skylight Oculus at (18, 198, -142)
	local startVistaRoof = Instance.new("Model")
	startVistaRoof.Name = "StartVistaCavernVault"
	startVistaRoof.Parent = volcanoMdl

	local oculusCenter = Vector3.new(16, 184, -142)
	local oculusRadius = 21

	-- Fill solid outer Sandstone & Rock cavern mountain mass enclosing X = -220..220, Y = 114..236, Z = 40..-520
	-- Shell extended down by START_LAVA_DROP so the deeper lava sits inside a sealed cavern (was Y = 110..206).
	terrain:FillBlock(CFrame.new(0, 158 - START_LAVA_DROP * 0.5, -240), Vector3.new(420, 96 + START_LAVA_DROP, 540), Enum.Material.Sandstone)
	terrain:FillBlock(CFrame.new(0, 204, -240), Vector3.new(440, 44, 560), Enum.Material.Rock)

	-- Carve out the continuous vaulted interior chamber with organic overlapping Air spheres & cylinders so the walls and ceiling curve naturally with zero flat slabs or sky gaps!
	local chamberHollows = {
		{ pos = Vector3.new(0, 148, 10), r = 68 },
		{ pos = Vector3.new(-8, 148, -45), r = 70 },
		{ pos = Vector3.new(-10, 148, -98), r = 74 },
		{ pos = Vector3.new(4, 148, -152), r = 76 },
		{ pos = Vector3.new(-4, 144, -215), r = 72 },
		{ pos = Vector3.new(-10, 138, -278), r = 70 },
		{ pos = Vector3.new(-16, 132, -345), r = 68 },
		{ pos = Vector3.new(-28, 124, -415), r = 66 },
	}
	for _, ch in ipairs(chamberHollows) do
		terrain:FillBall(ch.pos, ch.r, Enum.Material.Air)
	end
	-- Widen the lower chamber floor horizon between the left and right canyon walls (Y = 117..158) so the bridge, Sauropod pedestal, and right tunnel ramp sit in a broad volcanic cavern
	terrain:FillBlock(CFrame.new(-2, 138 - (START_LAVA_DROP - 8) * 0.5, -175), Vector3.new(148, 42 + START_LAVA_DROP - 8, 330), Enum.Material.Air)

	-- Sculpt organic stepped Sandstone canyon strata & ledges along the Left Cliff (X = -82..-118) and Right Cliff (X = +74..+112)
	for zStep = -45, -345, -55 do
		terrain:FillBall(Vector3.new(-92, 144, zStep), 26, Enum.Material.Sandstone)
		terrain:FillBall(Vector3.new(-82, 172, zStep - 18), 24, Enum.Material.Rock)
		terrain:FillBall(Vector3.new(92, 146, zStep), 24, Enum.Material.Sandstone)
		terrain:FillBall(Vector3.new(82, 174, zStep - 18), 22, Enum.Material.Rock)
	end

	-- Carve the Right-Hand Cliff Tunnel Bore directly into the Right Sandstone Cliff at (54, 132, -138) angled along the Alt1 tunnel
	local cliffPortalCF = CFrame.new(54, 132, -138) * CFrame.Angles(0, math.rad(-28), 0)
	for tb = 0, 5 do
		local borePos = (cliffPortalCF * CFrame.new(0, 0, -tb * 10)).Position
		terrain:FillBall(borePos, 13.5, Enum.Material.Air)
	end

	-- Carve the single localized Circular Skylight Oculus through the Terrain Cavern Roof at (16, 184, -142) with stepped natural rock rim
	terrain:FillCylinder(CFrame.new(oculusCenter + Vector3.new(0, 14, 0)), 72, oculusRadius, Enum.Material.Air)
	terrain:FillCylinder(CFrame.new(oculusCenter + Vector3.new(0, 4, 0)), 14, oculusRadius + 3.5, Enum.Material.Air)

	-- Warm Amber Cliff Fill PointLight illuminating the right-hand Terrain canyon strata above and beside the tunnel portal
	local rightCliffLightHolder = addPart("RightCliffWarmFill", Enum.PartType.Block, Vector3.new(2, 2, 2), CFrame.new(74, 156, -118), Enum.Material.SmoothPlastic, sandstoneLight, startVistaRoof, 1, false)
	local rclPt = Instance.new("PointLight")
	rclPt.Color = Color3.fromRGB(255, 168, 84)
	rclPt.Brightness = 1.65
	rclPt.Range = 54
	rclPt.Shadows = false
	rclPt.Parent = rightCliffLightHolder

	buildPrehistoricShrubCluster("LeftCliffFoliage_1", Vector3.new(-84, 154, -75), landmarksFolder)
	buildPrehistoricShrubCluster("LeftCliffFoliage_2", Vector3.new(-86, 152, -185), landmarksFolder)
	buildPrehistoricShrubCluster("RightCliffFoliage_1", Vector3.new(82, 164, -85), landmarksFolder)
	buildPrehistoricShrubCluster("RightCliffFoliage_2", Vector3.new(86, 166, -195), landmarksFolder)
	buildPrehistoricShrubCluster("RightCliffFoliage_3", Vector3.new(74, 160, -138), landmarksFolder)

	-- Cool Cyan Downward PointLight + SpotLight directly illuminating the Principal Stone Sauropod & Pedestal through the open sky oculus bore
	local skylightEmitter = addPart(
		"SkylightCoolLightEmitter",
		Enum.PartType.Block,
		Vector3.new(24, 2, 24),
		CFrame.new(oculusCenter - Vector3.new(0, 6, 0)) * CFrame.Angles(math.rad(-90), 0, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(160, 230, 255),
		startVistaRoof,
		1,
		false
	)
	local skyPt = Instance.new("PointLight")
	skyPt.Color = Color3.fromRGB(148, 224, 255)
	skyPt.Brightness = 1.45
	skyPt.Range = 50
	skyPt.Shadows = true
	skyPt.Parent = skylightEmitter

	local skySpot = Instance.new("SpotLight")
	skySpot.Color = Color3.fromRGB(142, 220, 255)
	skySpot.Brightness = 1.65
	skySpot.Range = 52
	skySpot.Angle = 76
	skySpot.Face = Enum.NormalId.Front
	skySpot.Shadows = true
	skySpot.Parent = skylightEmitter

	-- Volumetric Cool Cyan Daylight Shafts (Beam instances with soft edge fade) angling from the round oculus behind the Principal Sauropod
	for sb = 1, 3 do
		local offX = (sb - 2) * 8
		local beamHolder = addPart(
			"SkylightBeamHolder_" .. tostring(sb),
			Enum.PartType.Block,
			Vector3.new(1, 1, 1),
			CFrame.new(oculusCenter + Vector3.new(offX, 0, -4)),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(160, 232, 255),
			startVistaRoof,
			1,
			false
		)
		local att0 = Instance.new("Attachment")
		att0.Position = Vector3.new(0, 2, 0)
		att0.Parent = beamHolder
		local att1 = Instance.new("Attachment")
		att1.Position = Vector3.new(-8, -56, 4)
		att1.Parent = beamHolder
		local bm = Instance.new("Beam")
		bm.Name = "SkylightVolumetricBeam_" .. tostring(sb)
		bm.Attachment0 = att0
		bm.Attachment1 = att1
		bm.Width0 = 24
		bm.Width1 = 42
		bm.FaceCamera = true
		bm.LightEmission = 0.35
		bm.Color = ColorSequence.new(Color3.fromRGB(156, 224, 252), Color3.fromRGB(128, 198, 238))
		bm.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.88),
			NumberSequenceKeypoint.new(0.5, 0.93),
			NumberSequenceKeypoint.new(1, 0.99),
		})
		bm.Parent = beamHolder
	end

	-- Helper to build Romanesque Cut-Stone Voussoir Arches matching 04_dino4_controls.png
	local function buildRomanesqueMasonryArch(archName: string, baseCF: CFrame, halfSpan: number, colHeight: number, parent: Instance)
		local arch: Model = Instance.new("Model")
		arch.Name = archName
		arch.Parent = parent

		-- Stepped Plinth Bases rising from the lava / rock
		addPart("PlinthL", Enum.PartType.Block, Vector3.new(22, 26, 22), baseCF * CFrame.new(-halfSpan, -colHeight * 0.5 - 6, 0), Enum.Material.Sandstone, terracottaCliff, arch, 0, false)
		addPart("PlinthR", Enum.PartType.Block, Vector3.new(22, 26, 22), baseCF * CFrame.new(halfSpan, -colHeight * 0.5 - 6, 0), Enum.Material.Sandstone, terracottaCliff, arch, 0, false)

		-- Cut-Stone Pillars with Horizontal Ashlar Coursing Bands
		addPart("ColumnL", Enum.PartType.Block, Vector3.new(15, colHeight, 15), baseCF * CFrame.new(-halfSpan, 0, 0), Enum.Material.Sandstone, sandstoneWarm, arch, 0, false)
		addPart("ColumnR", Enum.PartType.Block, Vector3.new(15, colHeight, 15), baseCF * CFrame.new(halfSpan, 0, 0), Enum.Material.Sandstone, sandstoneWarm, arch, 0, false)
		addPart("ColumnBandL", Enum.PartType.Block, Vector3.new(16.5, 4, 16.5), baseCF * CFrame.new(-halfSpan, 0, 0), Enum.Material.Sandstone, sandstoneLight, arch, 0, false)
		addPart("ColumnBandR", Enum.PartType.Block, Vector3.new(16.5, 4, 16.5), baseCF * CFrame.new(halfSpan, 0, 0), Enum.Material.Sandstone, sandstoneLight, arch, 0, false)

		-- Flared Impost Capitals
		local capY = colHeight * 0.5 + 2.5
		addPart("CapitalL", Enum.PartType.Block, Vector3.new(19, 5, 19), baseCF * CFrame.new(-halfSpan, capY, 0), Enum.Material.Sandstone, sandstoneLight, arch, 0, false)
		addPart("CapitalR", Enum.PartType.Block, Vector3.new(19, 5, 19), baseCF * CFrame.new(halfSpan, capY, 0), Enum.Material.Sandstone, sandstoneLight, arch, 0, false)

		-- Semicircular Voussoir Arch Crown (17 tightly interlocked voussoir blocks + prominent keystone so there are zero sawtooth gaps)
		local voussoirs = 17
		local archRadius = halfSpan
		local chord = (math.pi * archRadius / voussoirs) * 1.32
		for v = 1, voussoirs do
			local frac = (v - 0.5) / voussoirs
			local ang = math.pi * frac
			local vx = -math.cos(ang) * archRadius
			local vy = capY + math.sin(ang) * (archRadius * 0.82)
			local vCF = baseCF * CFrame.new(vx, vy, 0) * CFrame.Angles(0, 0, ang - math.pi * 0.5)
			local isKeystone = (v == 9)
			addPart(
				"Voussoir_" .. tostring(v),
				Enum.PartType.Block,
				Vector3.new(if isKeystone then chord * 1.15 else chord, if isKeystone then 16 else 13.5, 16),
				vCF,
				Enum.Material.Sandstone,
				if v % 2 == 1 then sandstoneLight else sandstoneWarm,
				arch,
				0,
				false
			)
		end
		return arch
	end

	-- Landmark 1: Start/Finish Romanesque Masonry Gate at CFrame.new(0, 144, 0)
	local startGate = buildRomanesqueMasonryArch("StartFinishGate", CFrame.new(0, 144, 0), 42, 30, landmarksFolder)
	addPart("StartLineNeon", Enum.PartType.Block, Vector3.new(28, 0.4, 4), CFrame.new(0, 141.6, 0), Enum.Material.Neon, Color3.fromRGB(255, 165, 35), startGate, nil, false)
	local finishTrigger: Part = addPart("StartFinishTrigger", Enum.PartType.Block, Vector3.new(108, 44, 8), CFrame.new(0, 162, 0), Enum.Material.Neon, Color3.fromRGB(255, 180, 0), startGate, 1, false)
	finishTrigger:SetAttribute("TriggerType", "FinishLine")

	-- FTUE Start Straight Rings & Arches calibrated to 04_dino4_controls.png screen coordinates:
	-- Ring 1 at X≈38%, Y≈47%; Ring 2 at X≈49%, Y≈48%; Ring 3 at X≈55%, Y≈45%
	buildBoosterRing(
		"BoosterRing_Start_1",
		CFrame.new(-22, 134, -128) * CFrame.Angles(math.rad(-5), math.rad(10), 0),
		boostsFolder,
		false,
		nil
	)
	buildBoosterRing(
		"BoosterRing_Start_2",
		CFrame.new(-16, 126, -198) * CFrame.Angles(math.rad(-6), 0, 0),
		boostsFolder,
		false,
		nil
	)
	buildBoosterRing(
		"BoosterRing_Start_3",
		CFrame.new(-8, 118, -272) * CFrame.Angles(math.rad(-5), math.rad(-8), 0),
		boostsFolder,
		false,
		nil
	)

	-- Primary Foreground Romanesque Arch at X≈36%, Y≈36% (`CFrame.new(-30, 134, -112)`) & Secondary Midground Arch at X≈50%, Y≈44% (`CFrame.new(-16, 116, -268)`)
	-- Placed at X=-30 with halfSpan=23 so the bridge passes cleanly under its center and its right column sits at X=-7, leaving the Principal Stone Sauropod at X=20 100% unobstructed!
	buildRomanesqueMasonryArch("StartForegroundArch", CFrame.new(-30, 134, -112) * CFrame.Angles(0, math.rad(14), 0), 23, 28, landmarksFolder)
	local ftueArch = buildRomanesqueMasonryArch("FTUEFinishArch", CFrame.new(-16, 116, -268) * CFrame.Angles(0, math.rad(-8), 0), 24, 22, landmarksFolder)
	local ftueTrigger: Part = addPart("FTUEArchTrigger", Enum.PartType.Block, Vector3.new(104, 42, 8), CFrame.new(-16, 116, -268), Enum.Material.Neon, Color3.fromRGB(80, 230, 255), ftueArch, 1, false)
	ftueTrigger:SetAttribute("TriggerType", "FTUEArch")

	-- Landmark 2: Mid-Track Romanesque Arch & Speed Pickups at S = 380
	buildRomanesqueMasonryArch("MidTrackRockPillar", CFrame.new(-12, 108, -365) * CFrame.Angles(0, math.rad(-10), 0), 42, 32, landmarksFolder)
	buildItemPodSpawn("PillarSpeedPickup_1", Vector3.new(-10, 98, -412), "Speed", 395, boostsFolder)
	buildItemPodSpawn("PillarSpeedPickup_2", Vector3.new(0, 98, -412), "Speed", 395, boostsFolder)
	buildItemPodSpawn("PillarSpeedPickup_3", Vector3.new(10, 98, -412), "Speed", 395, boostsFolder)

	-- 6.3 Right-Wall Cliff Tunnel Cut Directly Into the Sheer Cliff Face + Broad Stepped Stone Causeway Ramp (framed at X≈84%, Y≈34% below the top-right LAP plaque in 844x390, 740x360, and Desktop views)
	local portalMdl = buildRomanesqueMasonryArch("DualLevelTunnelPortal", CFrame.new(-35, 88, -485), 52, 42, landmarksFolder)
	local cliffPortal = buildRomanesqueMasonryArch("RightCliffTunnelPortal", cliffPortalCF, 14, 17, portalMdl)
	-- Deep Recessed Tunnel Bore & Warm Amber Interior Backlighting cut into the right cliff wall (-Z in portal-local space)
	addPart("TunnelBoreRecess", Enum.PartType.Block, Vector3.new(28, 30, 18), cliffPortalCF * CFrame.new(0, 2, -20), Enum.Material.Sandstone, Color3.fromRGB(64, 34, 24), cliffPortal, 0, false)
	addPart("TunnelBoreFloor", Enum.PartType.Block, Vector3.new(26, 3, 24), cliffPortalCF * CFrame.new(0, -8, -10), Enum.Material.Sandstone, terracottaCliff, cliffPortal, 0, false)
	local tunnelGlowPart = addPart("TunnelInnerWarmGlow", Enum.PartType.Block, Vector3.new(18, 14, 2.0), cliffPortalCF * CFrame.new(0, 1, -15.5), Enum.Material.SmoothPlastic, Color3.fromRGB(224, 108, 34), cliffPortal, 1, false)
	local tunnelPt = Instance.new("PointLight")
	tunnelPt.Color = Color3.fromRGB(255, 148, 46)
	tunnelPt.Brightness = 2.4
	tunnelPt.Range = 42
	tunnelPt.Shadows = false
	tunnelPt.Parent = tunnelGlowPart
	-- Broad Stepped Masonry Causeway Ramp rising from (32, 120, -82) up to the tunnel threshold (52, 128, -132)
	local rampStart = Vector3.new(32, 120, -82)
	local rampEnd = Vector3.new(52, 128, -132)
	local rampVec = rampEnd - rampStart
	local rampCF = CFrame.lookAt((rampStart + rampEnd) * 0.5, rampEnd)
	addPart("TunnelRampSpine", Enum.PartType.Block, Vector3.new(16, 5.0, rampVec.Magnitude + 4), rampCF * CFrame.new(0, -2.0, 0), Enum.Material.Sandstone, terracottaCliff, cliffPortal, 0, false)
	for stp = 1, 8 do
		local zStep = -rampVec.Magnitude * 0.5 + (stp - 0.5) * (rampVec.Magnitude / 8)
		addPart(
			"TunnelRampTread_" .. tostring(stp),
			Enum.PartType.Block,
			Vector3.new(16.5, 1.4, (rampVec.Magnitude / 8) * 0.94),
			rampCF * CFrame.new(0, 0.5, zStep),
			Enum.Material.Sandstone,
			if stp % 2 == 0 then terracottaCliff else sandstoneWarm,
			cliffPortal,
			0,
			false
		)
	end

	-- Landmark 3: Romanesque Stone Archways along the circuit (S = 1050, S = 2100, S = 3150, S = 4350, S = 5350)
	local function splinePoseAtStation(station: number): (Vector3, Vector3)
		for i = 1, #bestWaypoints - 1 do
			local w1 = bestWaypoints[i]
			local w2 = bestWaypoints[i + 1]
			if station >= w1.station and station <= w2.station then
				local span = math.max(0.01, w2.station - w1.station)
				local alpha = (station - w1.station) / span
				local pos = w1.pos:Lerp(w2.pos, alpha)
				local tan = w2.pos - w1.pos
				if tan.Magnitude < 0.05 then
					tan = Vector3.new(0, 0, -1)
				end
				return pos, tan.Unit
			end
		end
		return bestWaypoints[1].pos, Vector3.new(0, 0, -1)
	end

	local function buildStoneArchway(archName: string, atStation: number)
		local pos, tan = splinePoseAtStation(atStation)
		local baseCF: CFrame = CFrame.lookAt(Vector3.new(pos.X, pos.Y, pos.Z), Vector3.new(pos.X, pos.Y, pos.Z) + tan)
		buildRomanesqueMasonryArch(archName, baseCF, 58, 76, landmarksFolder)
	end

	buildStoneArchway("StoneArchway_S1050", 1050)
	buildStoneArchway("StoneArchway_S2100", 2100)
	buildStoneArchway("StoneArchway_S3150", 3150)
	buildStoneArchway("StoneArchway_S4350", 4350)
	buildStoneArchway("StoneArchway_S5350", 5350)

	-- =========================================================================
	-- Landmark 4 (A16): SINGLE Principal Long-Neck Stone Sauropod Monument on 3-Tiered Megalithic Pedestal
	-- Placed directly beneath the localized circular skylight oculus at (20, 115, -158) to the right of StartForegroundArch (-42, 134, -108)
	-- and cleanly to the left of the Right Cliff Tunnel Ramp (X=32..52) so both are 100% unobstructed in 844x390, 740x360, and Desktop views!
	-- =========================================================================
	local principalPedestalPos = Vector3.new(20, 115, -158)
	local pedestalMdl = Instance.new("Model")
	pedestalMdl.Name = "SauropodTieredPedestal"
	pedestalMdl.Parent = landmarksFolder

	-- 3 Stepped Monolithic Sandstone Pedestal Tiers with Chiseled Buttresses rising directly from the lava
	addPart("PedestalTier1", Enum.PartType.Block, Vector3.new(48, 9, 48), CFrame.new(principalPedestalPos + Vector3.new(0, 4.5, 0)), Enum.Material.Sandstone, terracottaDeep, pedestalMdl, 0, false)
	addPart("PedestalTier2", Enum.PartType.Block, Vector3.new(36, 8, 36), CFrame.new(principalPedestalPos + Vector3.new(0, 13.0, 0)) * CFrame.Angles(0, math.rad(12), 0), Enum.Material.Sandstone, terracottaCliff, pedestalMdl, 0, false)
	addPart("PedestalTier3", Enum.PartType.Block, Vector3.new(26, 7, 26), CFrame.new(principalPedestalPos + Vector3.new(0, 20.5, 0)), Enum.Material.Sandstone, sandstoneWarm, pedestalMdl, 0, false)
	-- Corner stepped buttress blocks on the pedestal
	for bCorner = 1, 4 do
		local cAng = math.rad((bCorner - 1) * 90 + 45)
		local bx = math.cos(cAng) * 19
		local bz = math.sin(cAng) * 19
		addWedge(
			"PedestalButtress_" .. tostring(bCorner),
			Vector3.new(8, 12, 10),
			CFrame.new(principalPedestalPos + Vector3.new(bx, 9, bz)) * CFrame.Angles(0, -cAng - math.pi * 0.5, 0),
			Enum.Material.Sandstone,
			sandstoneWarm,
			pedestalMdl,
			0,
			false
		)
	end

	-- Lower-Basin Ancient Megalithic Ruin Altar at (-580, 14, -1340) (NOT a duplicate dinosaur statue) so the lower basin turn has a landmark platform for Alt-2
	local basinAltarMdl = Instance.new("Model")
	basinAltarMdl.Name = "LowerBasinVolcanicAltar"
	basinAltarMdl.Parent = landmarksFolder
	local basinAltarPos = Vector3.new(-580, 14, -1340)
	addPart("BasinAltarTier1", Enum.PartType.Block, Vector3.new(220, 18, 220), CFrame.new(basinAltarPos + Vector3.new(0, 9, 0)), Enum.Material.Sandstone, terracottaCliff, basinAltarMdl)
	addPart("BasinAltarTier2", Enum.PartType.Block, Vector3.new(150, 16, 150), CFrame.new(basinAltarPos + Vector3.new(0, 26, 0)), Enum.Material.Sandstone, sandstoneWarm, basinAltarMdl)
	buildRomanesqueMasonryArch("BasinAltarCrownArch", CFrame.new(basinAltarPos + Vector3.new(0, 62, 0)) * CFrame.Angles(0, math.rad(35), 0), 46, 54, basinAltarMdl)

	local function buildPrincipalStoneSauropodModel(modelName: string, basePos: Vector3, scale: number, yawDeg: number, parent: Instance): Model
		local dinoMdl = Instance.new("Model")
		dinoMdl.Name = modelName
		dinoMdl:SetAttribute("BasePivotPos", basePos)
		dinoMdl:SetAttribute("BaseYawDeg", yawDeg)
		dinoMdl.Parent = parent

		local rootCF = CFrame.new(basePos) * CFrame.Angles(0, math.rad(yawDeg), 0)
		local plinth = addPart("PlinthRoot", Enum.PartType.Block, Vector3.new(30, 3, 22) * scale, rootCF, Enum.Material.Sandstone, terracottaCliff, dinoMdl, 0, false)
		dinoMdl.PrimaryPart = plinth

		-- Dedicated warm-gold & cool-cyan rim PointLights on the Sauropod so its chiseled sandstone planes pop with balanced contrast against the dark slate cavern background
		local dinoKeyLightPart = addPart("DinoKeyLight", Enum.PartType.Block, Vector3.new(2, 2, 2), rootCF * CFrame.new(-16 * scale, 42 * scale, 18 * scale), Enum.Material.SmoothPlastic, sandstoneLight, dinoMdl, 1, false)
		local dkl = Instance.new("PointLight")
		dkl.Color = Color3.fromRGB(255, 214, 148)
		dkl.Brightness = 1.15
		dkl.Range = 46
		dkl.Shadows = false
		dkl.Parent = dinoKeyLightPart

		local dinoUnderWarmPart = addPart("DinoUnderWarmLight", Enum.PartType.Block, Vector3.new(2, 2, 2), rootCF * CFrame.new(-8 * scale, 10 * scale, 12 * scale), Enum.Material.SmoothPlastic, sandstoneLight, dinoMdl, 1, false)
		local duwl = Instance.new("PointLight")
		duwl.Color = Color3.fromRGB(255, 138, 46)
		duwl.Brightness = 1.25
		duwl.Range = 42
		duwl.Shadows = false
		duwl.Parent = dinoUnderWarmPart

		local dinoTopCoolPart = addPart("DinoTopCoolLight", Enum.PartType.Block, Vector3.new(2, 2, 2), rootCF * CFrame.new(-10 * scale, 68 * scale, 6 * scale), Enum.Material.SmoothPlastic, sandstoneLight, dinoMdl, 1, false)
		local dtcl = Instance.new("PointLight")
		dtcl.Color = Color3.fromRGB(148, 224, 255)
		dtcl.Brightness = 1.15
		dtcl.Range = 42
		dtcl.Shadows = false
		dtcl.Parent = dinoTopCoolPart

		-- Load the approved Tripo v3.1 Stone Sauropod MeshPart (Asset 98086222919300) VISIBLE (Transparency = 0) with its refined sandstone texture,
		-- oriented +90 deg around Y so its long neck and head face camera-left (-X) in full profile directly under the skylight oculus!
		local tripoLoaded = false
		local ok, container = pcall(function()
			return InsertService:LoadAsset(M.STONE_SAUROPOD_MODEL_ID)
		end)
		if ok and container then
			for _, desc in ipairs(container:GetDescendants()) do
				if desc:IsA("LuaSourceContainer") then
					desc:Destroy()
				elseif desc:IsA("MeshPart") and not tripoLoaded then
					local mp = desc:Clone()
					for _, sub in ipairs(mp:GetDescendants()) do
						if sub:IsA("SurfaceAppearance") or sub:IsA("LuaSourceContainer") then
							sub:Destroy()
						end
					end
					mp.Name = "TripoStoneSauropodMesh"
					mp.TextureID = M.STONE_SAUROPOD_TEX_ID
					mp.Material = Enum.Material.SmoothPlastic
					mp.Color = Color3.fromRGB(224, 182, 136)
					mp.Transparency = 0
					mp.Anchored = true
					mp.CanCollide = false
					local rawSz = mp.Size
					local targetH = 84 * scale
					local sf = targetH / math.max(1, rawSz.Y)
					mp.Size = rawSz * sf
					-- Verified in Studio: rotating +90 deg around Y makes the Tripo Sauropod face camera-left (-X) in full profile!
					mp.CFrame = rootCF * CFrame.new(0, (mp.Size.Y * 0.5) + 1.5 * scale, 0) * CFrame.Angles(0, math.rad(90), 0)
					mp.Parent = dinoMdl
					tripoLoaded = true
					dinoMdl:SetAttribute("HasTripoMesh", true)
				end
			end
			container:Destroy()
		end
		-- D19 / L68: a missing asset and the deliberate block-built fallback are reported separately.
		dinoMdl:SetAttribute("AssetState", if tripoLoaded then "mesh" else "FALLBACK")
		print(string.format("[SkyRally][ASSETS] sauropod model=%d state=%s loadOk=%s", M.STONE_SAUROPOD_MODEL_ID, if tripoLoaded then "mesh" else "FALLBACK", tostring(ok)))

		if not tripoLoaded then
			local legCoords = {
				Vector3.new(-10, 12, -4.5),
				Vector3.new(-10, 12, 4.5),
				Vector3.new(10, 11, -4.5),
				Vector3.new(10, 11, 4.5),
			}
			for idx, lc in ipairs(legCoords) do
				addPart("Leg_" .. tostring(idx), Enum.PartType.Block, Vector3.new(6.8, 22, 6.8) * scale, rootCF * CFrame.new(lc * scale), Enum.Material.Sandstone, sandstoneLight, dinoMdl, 0, false)
			end
			addPart("Torso", Enum.PartType.Block, Vector3.new(28, 15, 14) * scale, rootCF * CFrame.new(0, 25 * scale, 0) * CFrame.Angles(0, 0, math.rad(10)), Enum.Material.Sandstone, sandstoneLight, dinoMdl, 0, false)
			addPart("ChestShoulder", Enum.PartType.Block, Vector3.new(15, 14, 12.5) * scale, rootCF * CFrame.new(-10 * scale, 29 * scale, 0) * CFrame.Angles(0, 0, math.rad(16)), Enum.Material.Sandstone, Color3.fromRGB(244, 198, 136), dinoMdl, 0, false)
			addPart("Neck1", Enum.PartType.Block, Vector3.new(8.5, 18, 8.5) * scale, rootCF * CFrame.new(-16 * scale, 41 * scale, 0) * CFrame.Angles(0, 0, math.rad(22)), Enum.Material.Sandstone, Color3.fromRGB(246, 202, 142), dinoMdl, 0, false)
			addPart("Neck2", Enum.PartType.Block, Vector3.new(7.4, 18, 7.4) * scale, rootCF * CFrame.new(-21 * scale, 54 * scale, 0) * CFrame.Angles(0, 0, math.rad(18)), Enum.Material.Sandstone, Color3.fromRGB(248, 208, 148), dinoMdl, 0, false)
			addPart("Neck3", Enum.PartType.Block, Vector3.new(6.5, 17, 6.5) * scale, rootCF * CFrame.new(-25 * scale, 67 * scale, 0) * CFrame.Angles(0, 0, math.rad(12)), Enum.Material.Sandstone, Color3.fromRGB(248, 208, 148), dinoMdl, 0, false)
			addPart("Head", Enum.PartType.Block, Vector3.new(12.5, 7.2, 7.2) * scale, rootCF * CFrame.new(-31 * scale, 75.5 * scale, 0), Enum.Material.Sandstone, Color3.fromRGB(252, 214, 156), dinoMdl, 0, false)
			addWedge("HeadCrest", Vector3.new(6.5, 5.6, 6.8) * scale, rootCF * CFrame.new(-28.0 * scale, 80.5 * scale, 0) * CFrame.Angles(0, math.rad(-90), 0), Enum.Material.Sandstone, Color3.fromRGB(252, 214, 156), dinoMdl, 0, false)
			addPart("Tail1", Enum.PartType.Block, Vector3.new(18, 9.5, 9.5) * scale, rootCF * CFrame.new(19 * scale, 21 * scale, 0) * CFrame.Angles(0, 0, math.rad(-14)), Enum.Material.Sandstone, sandstoneLight, dinoMdl, 0, false)
			addPart("Tail2", Enum.PartType.Block, Vector3.new(18, 6.8, 6.8) * scale, rootCF * CFrame.new(33 * scale, 17.5 * scale, 0) * CFrame.Angles(0, 0, math.rad(-8)), Enum.Material.Sandstone, Color3.fromRGB(244, 198, 136), dinoMdl, 0, false)
		end

		dinoMdl.WorldPivot = rootCF
		return dinoMdl
	end

	-- SINGLE Principal Stone Sauropod Monument on its 3-tier pedestal directly under the localized round skylight oculus (scale = 0.78 -> height = 65 studs, head at Y≈194 right under the oculus at Y=184)
	buildPrincipalStoneSauropodModel("RoamingGreenSauropod", principalPedestalPos + Vector3.new(0, 24, 0), 0.78, 0, landmarksFolder)

	-- Booster Rings, Item Pods & Coins per spec (placed downstream past Z=-360 so the start vista around the Sauropod & Tunnel is 100% clean)
	buildItemPodSpawn("StartDropPod_Red1", Vector3.new(-12, 82, -385), "Red", 385, boostsFolder)
	buildItemPodSpawn("StartDropPod_Red2", Vector3.new(12, 82, -385), "Red", 385, boostsFolder)
	buildItemPodSpawn("StartDropPod_Plane1", Vector3.new(-12, 108, -385), "Air", 385, boostsFolder)
	buildItemPodSpawn("StartDropPod_Plane2", Vector3.new(12, 108, -385), "Air", 385, boostsFolder)

	buildItemPodSpawn("SlopePod_RedLeft", Vector3.new(-22, 76, -1560), "Red", 1650, boostsFolder)
	buildItemPodSpawn("SlopePod_BlueRight", Vector3.new(22, 76, -1560), "Blue", 1650, boostsFolder)

	buildBoosterRing(
		"BoosterRing_1_SlopeBottom",
		CFrame.new(-45, 52, -1720) * CFrame.Angles(0, math.rad(15), 0),
		boostsFolder,
		false,
		nil
	)

	buildItemPodSpawn("ArchPod_Red1", Vector3.new(-175, 52, -1810), "Red", 2120, boostsFolder)
	buildItemPodSpawn("ArchPod_Red2", Vector3.new(-168, 52, -1815), "Red", 2120, boostsFolder)
	buildItemPodSpawn("ArchPod_Blue1", Vector3.new(-152, 52, -1825), "Blue", 2120, boostsFolder)
	buildItemPodSpawn("ArchPod_Blue2", Vector3.new(-145, 52, -1830), "Blue", 2120, boostsFolder)

	buildBoosterRing(
		"BoosterRing_2_SauropodLeft",
		CFrame.new(-480, 64, -1580) * CFrame.Angles(0, math.rad(110), 0),
		boostsFolder,
		false,
		nil
	)
	buildBoosterRing(
		"BoosterRing_3_SauropodRight",
		CFrame.new(-540, 68, -1240) * CFrame.Angles(0, math.rad(145), 0),
		boostsFolder,
		false,
		nil
	)
	buildBoosterRing(
		"BoosterRing_4_Penultimate",
		CFrame.new(-310, 118, -320) * CFrame.Angles(math.rad(6), math.rad(195), 0),
		boostsFolder,
		true,
		7
	)
	buildBoosterRing(
		"BoosterRing_5_Final",
		CFrame.new(-85, 138, 185) * CFrame.Angles(math.rad(4), math.rad(235), 0),
		boostsFolder,
		true,
		8
	)

	-- Ground Boost Pads on cavern decks
	buildGroundBoostPad("GroundBoost_Start", CFrame.new(-35, 86.2, -485), boostsFolder)
	buildGroundBoostPad("GroundBoost_Crest", CFrame.new(20, 111.6, -1380), boostsFolder)
	buildGroundBoostPad("GroundBoost_SauropodFloor", CFrame.new(-620, 33.4, -1480), boostsFolder)

	-- Lower basin floor Speed Pickups & stalagmites
	for i = 1, 6 do
		local ang: number = rng:NextNumber(0, math.pi * 2)
		local rad: number = rng:NextNumber(145, 220)
		local px: number = -580 + math.cos(ang) * rad
		local pz: number = -1340 + math.sin(ang) * rad
		buildItemPodSpawn("CavernFloorSpeed_" .. tostring(i), Vector3.new(px, 38, pz), "Speed", 2900 + i * 80, boostsFolder)
		addWedge(
			"CavernStalagmite_" .. tostring(i),
			Vector3.new(22, 34, 22),
			CFrame.new(px + 22, 28, pz + 18) * CFrame.Angles(0, ang, 0),
			Enum.Material.Sandstone,
			terracottaCliff,
			calderaFolder,
			0,
			false
		)
	end

	-- Corridor clearance gate: every waypoint must have a clear 30x26-stud flight box.
	do
		local params: OverlapParams = OverlapParams.new()
		params.RespectCanCollide = true
		params.MaxParts = 8
		local ribbon = root:FindFirstChild("TrackRibbon")
		local excludeList: { Instance } = {}
		if ribbon then
			table.insert(excludeList, ribbon)
		end
		params.FilterDescendantsInstances = excludeList
		params.FilterType = Enum.RaycastFilterType.Exclude

		local violations: number = 0
		local reported: number = 0
		local maxRadial: number = 0
		for i = 1, #bestWaypoints - 1, 2 do
			local wp = bestWaypoints[i]
			local nxt = bestWaypoints[i + 1]
			local tan = nxt.pos - wp.pos
			local boxCF: CFrame
			if tan.Magnitude > 0.05 then
				boxCF = CFrame.lookAt(wp.pos, wp.pos + tan.Unit)
			else
				boxCF = CFrame.new(wp.pos)
			end
			local hits = workspace:GetPartBoundsInBox(boxCF, Vector3.new(30, 26, 8), params)
			for _, hit in ipairs(hits) do
				violations = violations + 1
				if reported < 40 then
					reported = reported + 1
					print(string.format(
						"[Track][CLEARANCE] BLOCKED station=%.0f pos=(%.0f,%.0f,%.0f) part=%s parent=%s",
						wp.station, wp.pos.X, wp.pos.Y, wp.pos.Z, hit.Name, if hit.Parent then hit.Parent.Name else "?"
					))
				end
			end
		end
		for _, wp in ipairs(bestWaypoints) do
			local d = (Vector3.new(wp.pos.X, 0, wp.pos.Z) - Vector3.new(calderaCenter.X, 0, calderaCenter.Z)).Magnitude
			if d > maxRadial then
				maxRadial = d
			end
		end
		print(string.format(
			"[Track][CLEARANCE] Track=DINO-4 corridor=30x26 violations=%d maxRadialFromCaldera=%.0f (coneInner=940)",
			violations, maxRadial
		))
		if violations > 0 then
			print("[Track][SELFTEST] FAIL: DINO-4 corridor blocked by " .. tostring(violations) .. " collidable intrusions")
		else
			print("[Track][SELFTEST] PASS: DINO-4 corridor clear (30x26 at every waypoint)")
		end
	end

	-- L02: guaranteed flight corridor along the main route and both alternate lines, carved after every
	-- Terrain fill so no Terrain mass can close the lane; intruding parts are reported for a source fix.
	do
		local ServerScriptService = game:GetService("ServerScriptService")
		local CourseCarve = require(ServerScriptService:WaitForChild("ServerMain"):WaitForChild("CourseCarve"))
		local corridor = CourseCarve.carve(bestWaypoints :: any, { halfWidth = 34, floor = 5, ceiling = 44, label = "DINO-4 main" })
		local alt1: { { pos: Vector3, station: number? } } = {}
		for _, pt in alt1Pts do
			table.insert(alt1, { pos = pt })
		end
		local alt2: { { pos: Vector3, station: number? } } = {}
		for _, pt in alt2Pts do
			table.insert(alt2, { pos = pt })
		end
		local c1 = CourseCarve.carve(alt1, { halfWidth = 13, floor = 4, ceiling = 28, label = "DINO-4 alt1" })
		local c2 = CourseCarve.carve(alt2, { halfWidth = 20, floor = 4, ceiling = 40, label = "DINO-4 alt2" })
		root:SetAttribute("CorridorIntrusions", #corridor.intrusions + #c1.intrusions + #c2.intrusions)
	end

	M.waypoints = bestWaypoints
	M.measuredLength = measuredLength
	M.partCount = partCount
	local g = (_G :: any)
	g.SkyRallyTracks = g.SkyRallyTracks or {}
	g.SkyRallyTracks["DINO-4"] = {
		waypoints = bestWaypoints,
		measuredLength = measuredLength,
		partCount = partCount,
		root = root,
	}

	print(string.format("[Track][SELFTEST] Track=DINO-4 | Parts=%d | Length=%.1f studs | Waypoints=%d", partCount, measuredLength, #bestWaypoints))
	return root
end

M.build()

do
	local existingModel = workspace:FindFirstChild("DINO-4_TrackModel")
	if existingModel then
		existingModel:Destroy()
	end
	local _model = Instance.new("Model")
	_model.Name = "DINO-4_TrackModel"
	local _root = workspace:FindFirstChild("DINO-4")
	if _root then
		_root.Parent = _model
		_model.WorldPivot = CFrame.new(0, 0, 0)
		_model.Parent = workspace
	end
end

return M
