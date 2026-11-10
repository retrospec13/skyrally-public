local M = {}

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
	if canCollide ~= nil then
		w.CanCollide = canCollide
	else
		w.CanCollide = true
	end
	w.Parent = parent
	partCount = partCount + 1
	return w
end

local function addSphere(
	name: string,
	size: Vector3,
	cframe: CFrame,
	material: Enum.Material,
	color: Color3,
	parent: Instance,
	transparency: number?,
	canCollide: boolean?
): Part
	local p: Part = addPart(name, Enum.PartType.Block, size, cframe, material, color, parent, transparency, canCollide)
	local mesh: SpecialMesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
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
	local arcLen: number = (2 * math.pi * radius / segments) * 1.06
	for i = 1, segments do
		local angle: number = (i - 1) * (2 * math.pi / segments)
		local segCF: CFrame = centerCF
			* CFrame.Angles(0, 0, angle)
			* CFrame.new(0, radius, 0)
			* CFrame.Angles(0, math.pi / 2, 0)
		addWedge(
			name .. "_Wedge_" .. tostring(i),
			Vector3.new(width, thickness, arcLen),
			segCF,
			material,
			color,
			mdl
		)
	end
	return mdl
end

local function buildBoosterRing(name: string, centerCF: CFrame, parent: Instance): Model
	local mdl: Model = Instance.new("Model")
	mdl.Name = name
	mdl.Parent = parent

	buildWedgeRing(
		name .. "_InnerNeon",
		centerCF,
		12.5,
		3.2,
		3.2,
		12,
		Enum.Material.Neon,
		Color3.fromRGB(255, 190, 0),
		mdl
	)

	local segments: number = 12
	for i = 1, segments do
		local angle: number = (i - 1) * (2 * math.pi / segments)
		local housingCF: CFrame = centerCF * CFrame.Angles(0, 0, angle) * CFrame.new(0, 14.0, 0)
		addPart(
			name .. "_Housing_" .. tostring(i),
			Enum.PartType.Block,
			Vector3.new(7.8, 2.0, 4.0),
			housingCF,
			Enum.Material.Metal,
			Color3.fromRGB(50, 55, 65),
			mdl
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
		Enum.Material.Metal,
		Color3.fromRGB(55, 60, 70),
		mdl
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

	local color: Color3 = Color3.fromRGB(60, 160, 255)
	if podType == "Red" then
		color = Color3.fromRGB(255, 60, 60)
	elseif podType == "Speed" then
		color = Color3.fromRGB(80, 255, 110)
	end

	addSphere(
		name .. "_CoreVisual",
		Vector3.new(4.2, 4.2, 4.2),
		CFrame.new(pos),
		Enum.Material.Neon,
		color,
		spawnPart,
		0.15,
		false
	)
	return spawnPart
end

-- 6.1 Windmill Assembly (Octagonal 8-wedge frustum + drive-through archway + 4 rotating sails)
local function buildWindmillAssembly(name: string, baseCF: CFrame, parent: Instance): Model
	local wm: Model = Instance.new("Model")
	wm.Name = name
	wm.Parent = parent

	local core: Part = addPart(
		"TowerCore",
		Enum.PartType.Block,
		Vector3.new(36, 85, 36),
		baseCF * CFrame.new(0, 42.5, 0),
		Enum.Material.Brick,
		Color3.fromRGB(165, 92, 68),
		wm,
		1,
		false
	)
	wm.PrimaryPart = core

	-- Drive-through ground archway leaving 22-stud center road gap
	addPart(
		"ArchwayLeft",
		Enum.PartType.Block,
		Vector3.new(11, 22, 44),
		baseCF * CFrame.new(-16.5, 11, 0),
		Enum.Material.Cobblestone,
		Color3.fromRGB(130, 125, 120),
		wm
	)
	addPart(
		"ArchwayRight",
		Enum.PartType.Block,
		Vector3.new(11, 22, 44),
		baseCF * CFrame.new(16.5, 11, 0),
		Enum.Material.Cobblestone,
		Color3.fromRGB(130, 125, 120),
		wm
	)

	-- 8 Sloped WedgePart walls above archway height forming octagonal frustum
	for i = 1, 8 do
		local ang: number = (i - 1) * (math.pi / 4)
		local wallCF: CFrame = baseCF * CFrame.new(0, 52.5, 0) * CFrame.Angles(0, ang, 0) * CFrame.new(0, 0, -17)
		addWedge(
			"WallSlope_" .. tostring(i),
			Vector3.new(18, 65, 9),
			wallCF,
			Enum.Material.Brick,
			Color3.fromRGB(165, 92, 68),
			wm
		)
	end

	addPart(
		"RoofDome",
		Enum.PartType.Ball,
		Vector3.new(28, 22, 28),
		baseCF * CFrame.new(0, 85, 0),
		Enum.Material.Slate,
		Color3.fromRGB(70, 75, 85),
		wm
	)

	local rotorMdl: Model = Instance.new("Model")
	rotorMdl.Name = "RotorAssembly"
	rotorMdl.Parent = wm

	local hubCF: CFrame = baseCF * CFrame.new(0, 72, 22)
	local hubAxle: Part = addPart(
		"HubAxle",
		Enum.PartType.Cylinder,
		Vector3.new(8, 6, 6),
		hubCF * CFrame.Angles(0, math.pi / 2, 0),
		Enum.Material.Metal,
		Color3.fromRGB(60, 65, 70),
		rotorMdl
	)

	local att0: Attachment = Instance.new("Attachment")
	att0.Name = "TowerHingeAttachment"
	att0.CFrame = CFrame.new(0, 29.5, 22)
	att0.Parent = core

	local att1: Attachment = Instance.new("Attachment")
	att1.Name = "RotorHingeAttachment"
	att1.Parent = hubAxle

	local hinge: HingeConstraint = Instance.new("HingeConstraint")
	hinge.ActuatorType = Enum.ActuatorType.Motor
	hinge.AngularVelocity = 1.15
	hinge.MotorMaxTorque = 1e8
	hinge.Attachment0 = att0
	hinge.Attachment1 = att1
	hinge.Parent = hubAxle

	for s = 1, 4 do
		local bladeAng: number = (s - 1) * (math.pi / 2) + math.rad(25)
		local armCF: CFrame = hubCF * CFrame.Angles(0, 0, bladeAng) * CFrame.new(0, 28, 1.5)
		addPart(
			"SailArm_" .. tostring(s),
			Enum.PartType.Block,
			Vector3.new(2.5, 56, 2.5),
			armCF,
			Enum.Material.Wood,
			Color3.fromRGB(115, 80, 48),
			rotorMdl
		)
		addPart(
			"SailLattice_" .. tostring(s),
			Enum.PartType.Block,
			Vector3.new(6, 58, 1.5),
			armCF * CFrame.new(3.5, 0, 0.8),
			Enum.Material.Fabric,
			Color3.fromRGB(245, 240, 225),
			rotorMdl
		)
	end

	return wm
end

local function buildCountrysideTree(name: string, pos: Vector3, parent: Instance): Model
	local tree: Model = Instance.new("Model")
	tree.Name = name
	tree.Parent = parent
	addPart(
		"Trunk",
		Enum.PartType.Cylinder,
		Vector3.new(18, 4.5, 4.5),
		CFrame.new(pos + Vector3.new(0, 9, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Wood,
		Color3.fromRGB(110, 78, 48),
		tree
	)
	addSphere(
		"CanopyMain",
		Vector3.new(22, 18, 22),
		CFrame.new(pos + Vector3.new(0, 22, 0)),
		Enum.Material.Grass,
		Color3.fromRGB(65, 140, 55),
		tree
	)
	addSphere(
		"CanopySub",
		Vector3.new(15, 14, 15),
		CFrame.new(pos + Vector3.new(5, 25, -4)),
		Enum.Material.Grass,
		Color3.fromRGB(80, 155, 65),
		tree
	)
	return tree
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
	local root: Folder = createFolder("FOREST-1", workspace)

	local trackFolder: Folder = createFolder("TrackRibbon", root)
	local environmentFolder: Folder = createFolder("CountrysideEnvironment", root)
	local landmarksFolder: Folder = createFolder("Landmarks", root)
	local boostsFolder: Folder = createFolder("BoostsAndPods", root)
	local checkpointsFolder: Folder = createFolder("Checkpoints", root)

	-- Control nodes calibrated to hit exact spec coordinates and 6,400-stud lap length
	local controlNodes: { { pos: Vector3, bank: number, flex: Vector3 } } = {
		{ pos = Vector3.new(0, 80, 0), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(0, 80, -280), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(0, 80, -540), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(110, 42, -920), bank = 16, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(280, 48, -1180), bank = -18, flex = Vector3.new(120, 0, -60) },
		{ pos = Vector3.new(420, 68, -1420), bank = 14, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(510, 72, -1580), bank = -10, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(540, 58, -1820), bank = -16, flex = Vector3.new(90, 0, 0) },
		{ pos = Vector3.new(610, 45, -1980), bank = 20, flex = Vector3.new(150, 0, 0) },
		{ pos = Vector3.new(460, 45, -2120), bank = -20, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(280, 48, -2450), bank = -18, flex = Vector3.new(0, 0, -140) },
		{ pos = Vector3.new(-40, 65, -2380), bank = -22, flex = Vector3.new(-160, 0, -220) },
		{ pos = Vector3.new(-280, 70, -1920), bank = -18, flex = Vector3.new(-180, 0, -90) },
		{ pos = Vector3.new(-320, 76, -1380), bank = -12, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-340, 78, -820), bank = -20, flex = Vector3.new(-170, 0, 0) },
		{ pos = Vector3.new(-140, 80, -340), bank = -14, flex = Vector3.new(-90, 0, 0) },
	}

	local lowScale: number = 0.0
	local highScale: number = 3.5
	local bestWaypoints: { { pos: Vector3, bank: number, station: number } } = {}
	local measuredLength: number = 0

	for _ = 1, 24 do
		local mid: number = (lowScale + highScale) * 0.5
		local wps, len = generateWaypoints(controlNodes, mid, 10)
		bestWaypoints = wps
		measuredLength = len
		if len < 6400 then
			lowScale = mid
		else
			highScale = mid
		end
	end

	-- Build Track Ribbon, 3 Tunnels, and Water Hazard Basins
	for i = 1, #bestWaypoints - 1 do
		local wp1 = bestWaypoints[i]
		local wp2 = bestWaypoints[i + 1]
		local p1: Vector3 = wp1.pos
		local p2: Vector3 = wp2.pos
		local segLen: number = (p2 - p1).Magnitude
		if segLen > 0.1 then
			local mid: Vector3 = (p1 + p2) * 0.5
			local bankRad: number = math.rad((wp1.bank + wp2.bank) * 0.5)
			local cf: CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, bankRad)

			local st: number = wp1.station
			local isTwistyWater: boolean = (st >= 3150 and st <= 3950)
			local isTunnel1: boolean = (st >= 1450 and st <= 1980)
			local isTunnel2: boolean = (st >= 2600 and st <= 3050)
			local isTunnel3: boolean = (st >= 5350 and st <= 6050)
			local isTunnel: boolean = isTunnel1 or isTunnel2 or isTunnel3

			local roadWidth: number = isTwistyWater and 26 or 42
			local roadMat: Enum.Material = (i % 3 == 0) and Enum.Material.Ground or Enum.Material.Sandstone
			local roadCol: Color3 = Color3.fromRGB(168, 138, 96)
			if isTunnel then
				roadMat = Enum.Material.Cobblestone
				roadCol = Color3.fromRGB(130, 125, 118)
			end

			addPart(
				"RoadSeg_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(roadWidth, 2.8, segLen + 1.2),
				cf,
				roadMat,
				roadCol,
				trackFolder
			)

			-- Grassy shoulders
			addPart(
				"ShoulderL_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(6, 3.2, segLen + 1.2),
				cf * CFrame.new(-(roadWidth * 0.5 + 3), 0.4, 0),
				Enum.Material.Grass,
				Color3.fromRGB(75, 145, 65),
				trackFolder
			)
			addPart(
				"ShoulderR_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(6, 3.2, segLen + 1.2),
				cf * CFrame.new(roadWidth * 0.5 + 3, 0.4, 0),
				Enum.Material.Grass,
				Color3.fromRGB(75, 145, 65),
				trackFolder
			)

			-- Enclosed Rock/Cobblestone Tunnels (#1, #2, #3)
			if isTunnel then
				addPart("TunnelWallL_" .. tostring(i), Enum.PartType.Block, Vector3.new(5, 34, segLen + 1.5), cf * CFrame.new(-24, 17, 0), Enum.Material.Rock, Color3.fromRGB(105, 100, 95), environmentFolder)
				addPart("TunnelWallR_" .. tostring(i), Enum.PartType.Block, Vector3.new(5, 34, segLen + 1.5), cf * CFrame.new(24, 17, 0), Enum.Material.Rock, Color3.fromRGB(105, 100, 95), environmentFolder)
				addPart("TunnelRoof_" .. tostring(i), Enum.PartType.Block, Vector3.new(54, 5, segLen + 1.5), cf * CFrame.new(0, 34, 0), Enum.Material.Cobblestone, Color3.fromRGB(115, 110, 105), environmentFolder)
			end

			-- Trees along twisty water section & meadow
			if (isTwistyWater or (st >= 4450 and st <= 5300)) and i % 4 == 0 then
				local side: number = (i % 8 == 0) and -1 or 1
				local treePos: Vector3 = (cf * CFrame.new(side * (roadWidth * 0.5 + 18), 0, 0)).Position
				buildCountrysideTree("CountryTree_" .. tostring(i), treePos, environmentFolder)
			end

			-- Checkpoints every 12 segments
			if i % 12 == 1 then
				local cp: Part = addPart(
					"Checkpoint_" .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(roadWidth, 28, 3),
					cf * CFrame.new(0, 14, 0),
					Enum.Material.SmoothPlastic,
					Color3.fromRGB(100, 235, 100),
					checkpointsFolder,
					1,
					false
				)
				cp:SetAttribute("CheckpointIndex", math.floor(i / 12) + 1)
				cp:SetAttribute("Station", math.floor(st))
			end
		end
	end

	-- Rolling Green Hills & Water Hazard Pockets
	addPart(
		"CountrysideValleyFloor",
		Enum.PartType.Block,
		Vector3.new(2100, 6, 3100),
		CFrame.new(80, 34, -1350),
		Enum.Material.Grass,
		Color3.fromRGB(75, 145, 65),
		environmentFolder
	)
	local water1: Part = addPart(
		"WaterPocketBasin_1",
		Enum.PartType.Block,
		Vector3.new(420, 2.2, 420),
		CFrame.new(160, 41.5, -1020),
		Enum.Material.Glass,
		Color3.fromRGB(65, 165, 205),
		environmentFolder,
		0.35,
		false
	)
	water1:SetAttribute("HazardType", "CarWaterSlowdown")
	addPart("WaterSandFloor_1", Enum.PartType.Block, Vector3.new(420, 2, 420), CFrame.new(160, 39, -1020), Enum.Material.Sand, Color3.fromRGB(215, 195, 145), environmentFolder)

	local water2: Part = addPart(
		"WaterPocketBasin_2_SCurve",
		Enum.PartType.Block,
		Vector3.new(540, 2.2, 720),
		CFrame.new(460, 44.2, -2120),
		Enum.Material.Glass,
		Color3.fromRGB(65, 165, 205),
		environmentFolder,
		0.35,
		false
	)
	water2:SetAttribute("HazardType", "CarWaterSlowdown")
	addPart("WaterSandFloor_2", Enum.PartType.Block, Vector3.new(540, 2, 720), CFrame.new(460, 41.5, -2120), Enum.Material.Sand, Color3.fromRGB(215, 195, 145), environmentFolder)

	-- Landmark: Start/Finish Gate at CFrame.new(0, 80, 0) (76w x 45h)
	local startGate: Model = Instance.new("Model")
	startGate.Name = "StartFinishGate"
	startGate.Parent = landmarksFolder
	addPart("GatePillarL", Enum.PartType.Block, Vector3.new(8, 45, 8), CFrame.new(-38, 102.5, 0), Enum.Material.Cobblestone, Color3.fromRGB(130, 125, 120), startGate)
	addPart("GatePillarR", Enum.PartType.Block, Vector3.new(8, 45, 8), CFrame.new(38, 102.5, 0), Enum.Material.Cobblestone, Color3.fromRGB(130, 125, 120), startGate)
	addPart("GateBeam", Enum.PartType.Block, Vector3.new(84, 7, 10), CFrame.new(0, 126, 0), Enum.Material.WoodPlanks, Color3.fromRGB(135, 95, 58), startGate)
	addPart("StartLineNeon", Enum.PartType.Block, Vector3.new(42, 0.4, 4), CFrame.new(0, 81.5, 0), Enum.Material.Neon, Color3.fromRGB(120, 255, 100), startGate)

	-- Landmark 1: Three Tall Rotating Windmills (#1 at S=280, #2 at S=540, #3 at S=2350)
	buildWindmillAssembly("Windmill_1_S280", CFrame.new(0, 80, -280), landmarksFolder)
	buildWindmillAssembly("Windmill_2_S540", CFrame.new(0, 80, -540), landmarksFolder)
	buildWindmillAssembly("Windmill_3_S2350", CFrame.new(510, 72, -1580) * CFrame.Angles(0, math.rad(-25), 0), landmarksFolder)

	-- Landmark 2: Left-Side Waterfall (S = 4,150) + Concealed Challenge Coin underneath
	local waterfallMdl: Model = Instance.new("Model")
	waterfallMdl.Name = "LeftSideWaterfall"
	waterfallMdl.Parent = landmarksFolder
	local wfCF: CFrame = CFrame.new(-110, 65, -2420) * CFrame.Angles(0, math.rad(75), 0)
	addPart("WaterfallCliff", Enum.PartType.Block, Vector3.new(50, 95, 20), wfCF * CFrame.new(0, 47.5, -12), Enum.Material.Rock, Color3.fromRGB(105, 105, 105), waterfallMdl)
	local waterSheet: Part = addPart(
		"ScrollingWaterSheet",
		Enum.PartType.Block,
		Vector3.new(24, 95, 2),
		wfCF * CFrame.new(0, 47.5, 2),
		Enum.Material.Glass,
		Color3.fromRGB(110, 205, 255),
		waterfallMdl,
		0.25,
		false
	)
	waterSheet:SetAttribute("WaterfallSheet", true)

	local wfCoin: Part = addPart(
		"WaterfallChallengeCoin",
		Enum.PartType.Cylinder,
		Vector3.new(1.4, 9, 9),
		wfCF * CFrame.new(0, 12, -2) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Neon,
		Color3.fromRGB(255, 215, 0),
		waterfallMdl,
		0,
		false
	)
	wfCoin:SetAttribute("CollectibleType", "ChallengeCoin")

	-- Boost Pads, Booster Rings & Item Pods per spec
	buildGroundBoostPad("Windmill1_GroundPad", CFrame.new(0, 80.5, -280), boostsFolder)
	buildGroundBoostPad("Windmill2_GroundPad", CFrame.new(0, 80.5, -540), boostsFolder)

	buildItemPodSpawn("StartChain_BluePod_1", Vector3.new(0, 85, -160), "Blue", 160, boostsFolder)
	buildItemPodSpawn("StartChain_BluePod_2", Vector3.new(0, 85, -390), "Blue", 390, boostsFolder)
	buildItemPodSpawn("StartChain_BluePod_3", Vector3.new(25, 76, -680), "Blue", 680, boostsFolder)

	buildBoosterRing(
		"DescentBoosterRing_1_S920",
		CFrame.new(110, 68, -920) * CFrame.Angles(math.rad(-12), math.rad(-35), 0),
		boostsFolder
	)

	buildGroundBoostPad("PostTunnel1_BoostPad_S2050", CFrame.new(420, 68, -1420) * CFrame.Angles(0, math.rad(-35), 0), boostsFolder)
	buildGroundBoostPad("Windmill3_GroundPad_S2350", CFrame.new(510, 72.5, -1580) * CFrame.Angles(0, math.rad(-25), 0), boostsFolder)
	buildItemPodSpawn("Windmill3_PlanePodL", Vector3.new(485, 105, -1580), "Blue", 2350, boostsFolder)
	buildItemPodSpawn("Windmill3_PlanePodR", Vector3.new(535, 105, -1580), "Red", 2350, boostsFolder)

	buildBoosterRing(
		"HighAirBoosterRing_2_S3600",
		CFrame.new(460, 135, -2120) * CFrame.Angles(0, math.rad(140), 0),
		boostsFolder
	)

	buildItemPodSpawn("ValleyPod_1", Vector3.new(-60, 78, -2320), "Blue", 4300, boostsFolder)
	buildItemPodSpawn("ValleyPod_2", Vector3.new(-85, 78, -2300), "Red", 4300, boostsFolder)

	buildGroundBoostPad("WideMeadow_GroundPad_S5100", CFrame.new(-320, 76.5, -1380) * CFrame.Angles(0, math.rad(195), 0), boostsFolder)
	buildBoosterRing(
		"WideMeadow_AirRing_3_S5100",
		CFrame.new(-320, 112, -1380) * CFrame.Angles(0, math.rad(195), 0),
		boostsFolder
	)

	print(string.format("[Track][SELFTEST] Track=FOREST-1 | Parts=%d | Length=%.1f studs | Waypoints=%d", partCount, measuredLength, #bestWaypoints))
	return root
end

M.build()

do
	local _model = Instance.new("Model")
	_model.Name = "FOREST-1_TrackModel"
	local _root = workspace:FindFirstChild("FOREST-1")
	if _root then
		_root.Parent = _model
		_model.Parent = workspace
		_model:PivotTo(CFrame.new(0, 0, 4000))
	end
end

return M
