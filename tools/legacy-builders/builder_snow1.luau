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

local function buildFestivePineTree(name: string, basePos: Vector3, parent: Instance): Model
	local tree: Model = Instance.new("Model")
	tree.Name = name
	tree.Parent = parent

	addPart(
		"Trunk",
		Enum.PartType.Cylinder,
		Vector3.new(14, 4, 4),
		CFrame.new(basePos + Vector3.new(0, 7, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Wood,
		Color3.fromRGB(105, 72, 45),
		tree
	)

	local tierHeights: { number } = { 16, 25, 33 }
	local tierWidths: { number } = { 16, 12, 8 }
	for t = 1, 3 do
		local w: number = tierWidths[t]
		local y: number = tierHeights[t]
		addWedge(
			"PineTierL_" .. tostring(t),
			Vector3.new(w, 11, w * 0.5),
			CFrame.new(basePos + Vector3.new(0, y, -w * 0.25)),
			Enum.Material.Grass,
			Color3.fromRGB(32, 95, 48),
			tree
		)
		addWedge(
			"PineTierR_" .. tostring(t),
			Vector3.new(w, 11, w * 0.5),
			CFrame.new(basePos + Vector3.new(0, y, w * 0.25)) * CFrame.Angles(0, math.pi, 0),
			Enum.Material.Grass,
			Color3.fromRGB(32, 95, 48),
			tree
		)
	end

	local ornamentColors: { Color3 } = {
		Color3.fromRGB(255, 45, 45),
		Color3.fromRGB(45, 255, 85),
		Color3.fromRGB(255, 215, 40),
	}
	for i = 1, 12 do
		local ang: number = (i - 1) * (2 * math.pi / 12)
		local tierIdx: number = ((i - 1) % 3) + 1
		local r: number = tierWidths[tierIdx] * 0.45
		local oy: number = tierHeights[tierIdx] - 2
		local ox: number = math.cos(ang) * r
		local oz: number = math.sin(ang) * r
		addPart(
			"Ornament_" .. tostring(i),
			Enum.PartType.Ball,
			Vector3.new(1.5, 1.5, 1.5),
			CFrame.new(basePos + Vector3.new(ox, oy, oz)),
			Enum.Material.Neon,
			ornamentColors[(i % 3) + 1],
			tree,
			0,
			false
		)
	end
	return tree
end

local function buildScarfedSnowman(name: string, cf: CFrame, parent: Instance): Model
	local sm: Model = Instance.new("Model")
	sm.Name = name
	sm.Parent = parent

	addPart("BodyBottom", Enum.PartType.Ball, Vector3.new(10, 10, 10), cf * CFrame.new(0, 5, 0), Enum.Material.Snow, Color3.fromRGB(245, 250, 255), sm)
	addPart("BodyMid", Enum.PartType.Ball, Vector3.new(7, 7, 7), cf * CFrame.new(0, 12, 0), Enum.Material.Snow, Color3.fromRGB(245, 250, 255), sm)
	addPart("Head", Enum.PartType.Ball, Vector3.new(4.4, 4.4, 4.4), cf * CFrame.new(0, 16.8, 0), Enum.Material.Snow, Color3.fromRGB(245, 250, 255), sm)

	addWedge(
		"CarrotNose",
		Vector3.new(0.8, 0.8, 2.4),
		cf * CFrame.new(0, 16.8, -2.8),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(255, 130, 25),
		sm
	)
	addPart(
		"ScarfCollar",
		Enum.PartType.Cylinder,
		Vector3.new(1.2, 5.2, 5.2),
		cf * CFrame.new(0, 14.8, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Fabric,
		Color3.fromRGB(220, 30, 35),
		sm
	)
	addPart(
		"ScarfTail",
		Enum.PartType.Block,
		Vector3.new(1.2, 4.5, 0.6),
		cf * CFrame.new(1.8, 13.0, -2.2) * CFrame.Angles(0, 0, math.rad(-15)),
		Enum.Material.Fabric,
		Color3.fromRGB(220, 30, 35),
		sm
	)
	return sm
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
	local root: Folder = createFolder("SNOW-1", workspace)

	local trackFolder: Folder = createFolder("TrackRibbon", root)
	local environmentFolder: Folder = createFolder("SnowEnvironment", root)
	local landmarksFolder: Folder = createFolder("Landmarks", root)
	local boostsFolder: Folder = createFolder("BoostsAndPods", root)
	local checkpointsFolder: Folder = createFolder("Checkpoints", root)

	-- Sloppy Figure-8 Topology calibrated to 4,800 studs
	local controlNodes: { { pos: Vector3, bank: number, flex: Vector3 } } = {
		{ pos = Vector3.new(0, 90, 0), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(18, 90, -320), bank = 10, flex = Vector3.new(15, 0, 0) },
		{ pos = Vector3.new(-15, 86, -680), bank = -14, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-120, 62, -950), bank = -18, flex = Vector3.new(-40, 0, 0) },
		{ pos = Vector3.new(-320, 62, -1080), bank = -22, flex = Vector3.new(-140, 0, 80) },
		{ pos = Vector3.new(-380, 62, -1320), bank = -10, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-410, 62, -1420), bank = 0, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-440, 62, -1520), bank = -12, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(-280, 74, -1680), bank = -18, flex = Vector3.new(-80, 0, -160) },
		{ pos = Vector3.new(-20, 85, -1420), bank = 12, flex = Vector3.new(40, 0, -120) },
		{ pos = Vector3.new(210, 98, -1240), bank = 22, flex = Vector3.new(140, 0, -90) },
		{ pos = Vector3.new(310, 105, -980), bank = 20, flex = Vector3.new(0, 0, 0) },
		{ pos = Vector3.new(220, 102, -620), bank = 16, flex = Vector3.new(80, 0, 0) },
		{ pos = Vector3.new(95, 95, -310), bank = 12, flex = Vector3.new(0, 0, 0) },
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
		if len < 4800 then
			lowScale = mid
		else
			highScale = mid
		end
	end

	-- Track Surface Ribbon (Snowy Road & Frozen Glacier River)
	local trackWidth: number = 44
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

			local isRiver: boolean = (wp1.station >= 920 and wp1.station <= 2950)
			local isIceCave: boolean = (wp1.station >= 2950 and wp1.station <= 3400)

			local surfMat: Enum.Material = Enum.Material.Snow
			local surfCol: Color3 = Color3.fromRGB(235, 245, 255)
			if isRiver then
				surfMat = (i % 2 == 0) and Enum.Material.Glacier or Enum.Material.Ice
				surfCol = Color3.fromRGB(165, 215, 250)
			end

			addPart(
				"TrackSeg_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(trackWidth, 2.8, segLen + 1.2),
				cf,
				surfMat,
				surfCol,
				trackFolder
			)

			-- Snowbanks / Canyon edges
			addPart(
				"BankL_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(5.0, 4.2, segLen + 1.2),
				cf * CFrame.new(-(trackWidth * 0.5 + 2.5), 1.2, 0),
				isRiver and Enum.Material.Rock or Enum.Material.Snow,
				isRiver and Color3.fromRGB(110, 120, 135) or Color3.fromRGB(240, 248, 255),
				trackFolder
			)
			addPart(
				"BankR_" .. tostring(i),
				Enum.PartType.Block,
				Vector3.new(5.0, 4.2, segLen + 1.2),
				cf * CFrame.new(trackWidth * 0.5 + 2.5, 1.2, 0),
				isRiver and Enum.Material.Rock or Enum.Material.Snow,
				isRiver and Color3.fromRGB(110, 120, 135) or Color3.fromRGB(240, 248, 255),
				trackFolder
			)

			-- Protruding Ice Ledges at Y = 66 along frozen river
			if isRiver and i % 6 == 0 then
				local side: number = (i % 12 == 0) and -1 or 1
				local ledgeCF: CFrame = cf * CFrame.new(side * 16, 4.0, 0)
				addPart(
					"IceLedge_" .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(14, 2.5, 26),
					ledgeCF,
					Enum.Material.Glacier,
					Color3.fromRGB(185, 230, 255),
					trackFolder
				)
				buildItemPodSpawn("RiverLedgeSpeed_" .. tostring(i), (ledgeCF * CFrame.new(0, 4, 0)).Position, "Speed", math.floor(wp1.station), boostsFolder)
			end

			-- Ice Tunnel Crossover Enclosure (S = 2,950 to 3,400)
			if isIceCave then
				addPart("IceCaveWallL_" .. tostring(i), Enum.PartType.Block, Vector3.new(4, 34, segLen + 1.5), cf * CFrame.new(-24, 17, 0), Enum.Material.Ice, Color3.fromRGB(150, 210, 250), environmentFolder, 0.15)
				addPart("IceCaveWallR_" .. tostring(i), Enum.PartType.Block, Vector3.new(4, 34, segLen + 1.5), cf * CFrame.new(24, 17, 0), Enum.Material.Ice, Color3.fromRGB(150, 210, 250), environmentFolder, 0.15)
				addPart("IceCaveRoof_" .. tostring(i), Enum.PartType.Block, Vector3.new(52, 4, segLen + 1.5), cf * CFrame.new(0, 34, 0), Enum.Material.Glacier, Color3.fromRGB(175, 225, 255), environmentFolder, 0.1)
			end

			-- Festive Pine Trees (lining S = 150 to 900)
			if wp1.station >= 150 and wp1.station <= 900 and i % 3 == 0 then
				local side: number = (i % 6 == 0) and -1 or 1
				local treePos: Vector3 = (cf * CFrame.new(side * 34, -1, 0)).Position
				buildFestivePineTree("FestivePine_" .. tostring(i), treePos, landmarksFolder)
			end

			-- Scarfed Snowmen (River Banks S = 1,100 to 2,300)
			if wp1.station >= 1100 and wp1.station <= 2300 and i % 5 == 0 then
				local side: number = (i % 10 == 0) and -1 or 1
				local smCF: CFrame = cf * CFrame.new(side * 30, 1.5, 0) * CFrame.Angles(0, side * math.pi / 2, 0)
				buildScarfedSnowman("ScarfedSnowman_" .. tostring(i), smCF, landmarksFolder)
			end

			-- Checkpoints every 11 segments
			if i % 11 == 1 then
				local cp: Part = addPart(
					"Checkpoint_" .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(trackWidth, 28, 3),
					cf * CFrame.new(0, 14, 0),
					Enum.Material.SmoothPlastic,
					Color3.fromRGB(120, 215, 255),
					checkpointsFolder,
					1,
					false
				)
				cp:SetAttribute("CheckpointIndex", math.floor(i / 11) + 1)
				cp:SetAttribute("Station", math.floor(wp1.station))
			end
		end
	end

	-- Open Snowfields & Mountain Canyon Walls
	addPart(
		"LowerValleySnowfield",
		Enum.PartType.Block,
		Vector3.new(1600, 6, 2100),
		CFrame.new(-60, 54, -950),
		Enum.Material.Snow,
		Color3.fromRGB(235, 245, 255),
		environmentFolder
	)
	for i = 1, 10 do
		local ang: number = (i - 1) * (2 * math.pi / 10)
		local cliffCF: CFrame = CFrame.new(-60, 120, -950) * CFrame.Angles(0, ang, 0) * CFrame.new(0, 0, -760)
		addWedge(
			"CanyonMountainWall_" .. tostring(i),
			Vector3.new(420, 180, 140),
			cliffCF,
			Enum.Material.Rock,
			Color3.fromRGB(110, 120, 135),
			environmentFolder
		)
	end

	-- Landmark: Start/Finish Gate at CFrame.new(0, 90, 0) (68w x 40h)
	local startGate: Model = Instance.new("Model")
	startGate.Name = "StartFinishGate"
	startGate.Parent = landmarksFolder
	addPart("GatePillarL", Enum.PartType.Block, Vector3.new(8, 40, 8), CFrame.new(-34, 110, 0), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), startGate)
	addPart("GatePillarR", Enum.PartType.Block, Vector3.new(8, 40, 8), CFrame.new(34, 110, 0), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), startGate)
	addPart("GateBanner", Enum.PartType.Block, Vector3.new(76, 7, 10), CFrame.new(0, 132, 0), Enum.Material.Ice, Color3.fromRGB(165, 215, 250), startGate)
	addPart("StartLineNeon", Enum.PartType.Block, Vector3.new(44, 0.4, 4), CFrame.new(0, 91.5, 0), Enum.Material.Neon, Color3.fromRGB(120, 225, 255), startGate)

	-- Landmark: Mid-River Stone Arch (S = 2,550) at CFrame.new(-410, 92, -1420), crown at Y = 98
	local stoneArch: Model = Instance.new("Model")
	stoneArch.Name = "MidRiverStoneArch"
	stoneArch.Parent = landmarksFolder
	local archCF: CFrame = CFrame.new(-410, 92, -1420) * CFrame.Angles(0, math.rad(16), 0)
	addPart("ArchPillarL", Enum.PartType.Block, Vector3.new(18, 44, 24), archCF * CFrame.new(-36, -10, 0), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), stoneArch)
	addPart("ArchPillarR", Enum.PartType.Block, Vector3.new(18, 44, 24), archCF * CFrame.new(36, -10, 0), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), stoneArch)
	addPart("ArchBridgeCrown", Enum.PartType.Block, Vector3.new(90, 16, 26), CFrame.new(-410, 98, -1420) * CFrame.Angles(0, math.rad(16), 0), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), stoneArch)
	addWedge("ArchHaunchL", Vector3.new(24, 14, 26), archCF * CFrame.new(-20, -4, 0) * CFrame.Angles(0, math.pi / 2, math.pi), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), stoneArch)
	addWedge("ArchHaunchR", Vector3.new(24, 14, 26), archCF * CFrame.new(20, -4, 0) * CFrame.Angles(0, -math.pi / 2, math.pi), Enum.Material.Rock, Color3.fromRGB(110, 120, 135), stoneArch)

	-- Over / Under Route Waypoint Markers
	local overEntry: Part = addPart("SNOW_1_ARCH_OVER_Entry", Enum.PartType.Block, Vector3.new(18, 12, 4), CFrame.new(-380, 108, -1320), Enum.Material.Neon, Color3.fromRGB(120, 220, 255), boostsFolder, 1, false)
	overEntry:SetAttribute("ShortcutRoute", "SNOW-1-ARCH-OVER")
	local underEntry: Part = addPart("SNOW_1_ARCH_UNDER_Entry", Enum.PartType.Block, Vector3.new(18, 12, 4), CFrame.new(-380, 74, -1320), Enum.Material.Neon, Color3.fromRGB(120, 220, 255), boostsFolder, 1, false)
	underEntry:SetAttribute("ShortcutRoute", "SNOW-1-ARCH-UNDER")

	-- Booster Rings, Ground Pads & Item Pods per spec
	buildGroundBoostPad("GroundBoostPad_1_S320", CFrame.new(18, 90.5, -320), boostsFolder)
	buildBoosterRing(
		"AirBoosterRing_1_S680",
		CFrame.new(-15, 124, -680) * CFrame.Angles(0, math.rad(20), 0),
		boostsFolder
	)

	buildItemPodSpawn("PostCave_AirBluePod", Vector3.new(310, 135, -980), "Blue", 3550, boostsFolder)
	buildItemPodSpawn("PostCave_GroundBluePod", Vector3.new(310, 107, -980), "Blue", 3550, boostsFolder)
	buildItemPodSpawn("ChainingBluePod_3", Vector3.new(220, 118, -620), "Blue", 3950, boostsFolder)

	buildGroundBoostPad("PreRingGroundBoost_S4150", CFrame.new(145, 98, -440) * CFrame.Angles(0, math.rad(155), 0), boostsFolder)
	buildBoosterRing(
		"FinalBoosterRing_2_S4350",
		CFrame.new(95, 104, -310) * CFrame.Angles(0, math.rad(160), 0),
		boostsFolder
	)

	print(string.format("[Track][SELFTEST] Track=SNOW-1 | Parts=%d | Length=%.1f studs | Waypoints=%d", partCount, measuredLength, #bestWaypoints))
	return root
end

M.build()

do
	local _model = Instance.new("Model")
	_model.Name = "SNOW-1_TrackModel"
	local _root = workspace:FindFirstChild("SNOW-1")
	if _root then
		_root.Parent = _model
		_model.Parent = workspace
		_model:PivotTo(CFrame.new(0, 0, -4000))
	end
end

return M
