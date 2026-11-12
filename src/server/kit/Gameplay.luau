--!strict
-- Gameplay object kit (MAP_PLAN_SCHEMA section 4): booster rings, ground boost pads, item pods and checkpoints.
-- Ported from builder_dino4.luau (buildWedgeRing, buildBoosterRing, buildGroundBoostPad, buildItemPodSpawn, checkpoint
-- parts) with the same instance structure, names and attributes the game code scans for, placed from TrackData.
-- One change from the builder: invisible trigger volumes get CanQuery=false. FlightController's step raycast
-- (FlightController ~749) stops at the first part it hits, so a non-collidable volume in front of a wall hid the
-- wall. Nothing finds these volumes by raycast: FlightController.refreshTrackTriggers and RaceManager.loadCheckpoints
-- scan attributes and then compare distances to Position.

local CollectionService = game:GetService("CollectionService")
local TriggerRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("TriggerRules"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemArt = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemArt"))
local ItemRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRules"))

local WorldArt = require(script.Parent.WorldArt)
local ArtSwapRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ArtSwapRules"))
local SailGateRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SailGateRules")) -- FOREST-1 sail-gap timing ring
local VfxAssets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VfxAssets"))

local Gameplay = {}

local partCount: number = 0

-- Ring beacon (critic v28 1.25, FOREST-1: the booster rings melt into the haze past ~400 studs): a plum band of two beam
-- arcs just outside the housing, a slow soft glow pulse, and a chain of three small guide rings on the approach side.
-- Beams and four small rim particle emitters only (no meshes), parented to an invisible part of the ring model: nothing
-- collides, nothing is queried, and no sprite sits at the ring centre the camera flies through. Plane maps listed here only.
local BEACON_MAPS: { [string]: boolean } = { ["FOREST-1"] = true }
local BEACON_PLUM = Color3.fromRGB(150, 70, 140)
-- Wave 1b C11 (critic v29 forest1 08/11, "ghost pink guide rings"): the guide chain hung on the ring's own straight axis
-- (local +Z 60-160 studs), so on every curved approach it floated off the flight line as stray plum hoops. Removed; the
-- plum band and the pulse stay. (Was { { z = 60, r = 7 }, { z = 110, r = 5.5 }, { z = 160, r = 4 } }.)
local BEACON_GUIDES: { { z: number, r: number } } = {} -- local +Z = behind the ring (the plane flies out along -Z)

local function beaconArc(holder: BasePart, a0: Attachment, a1: Attachment, r: number, width: number, transparency: number, flip: number)
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.CurveSize0 = r * 4 / 3 * flip -- a cubic Bezier semicircle: control points 4/3 r out
	b.CurveSize1 = -r * 4 / 3 * flip
	b.Segments = 12
	b.Width0 = width
	b.Width1 = width
	b.FaceCamera = true
	b.LightEmission = 0.5
	b.LightInfluence = 0
	b.Color = ColorSequence.new(BEACON_PLUM)
	b.Transparency = NumberSequence.new(transparency)
	b.Parent = holder
end

local function beaconRing(holder: BasePart, z: number, r: number, width: number, transparency: number)
	-- the beam arcs bulge along each attachment's Axis (its X): X points up, so one arc goes over and one under
	local a0 = Instance.new("Attachment")
	a0.CFrame = CFrame.fromMatrix(Vector3.new(-r, 0, z), Vector3.yAxis, Vector3.zAxis)
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.CFrame = CFrame.fromMatrix(Vector3.new(r, 0, z), Vector3.yAxis, Vector3.zAxis)
	a1.Parent = holder
	beaconArc(holder, a0, a1, r, width, transparency, 1)
	beaconArc(holder, a0, a1, r, width, transparency, -1)
end

local function buildRingBeacon(centerCF: CFrame, mdl: Model)
	local holder = Instance.new("Part")
	holder.Name = "RingBeacon"
	holder.Size = Vector3.new(1, 1, 1)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CastShadow = false
	holder.CFrame = centerCF
	holder.Parent = mdl
	beaconRing(holder, 0, 16.5, 2.4, 0.3) -- the plum band, 3 studs outside the cream housing
	for _, g in BEACON_GUIDES do
		beaconRing(holder, g.z, g.r, 0.9, 0.45)
	end
	-- the soft pulse sits on the band's rim (four small glows), never at the ring centre: the plane and its chase camera
	-- fly through the centre, and a camera-facing sprite there would wash over the whole view for a moment
	local tex = (VfxAssets :: any).glow_soft
	for k = 0, 3 do
		local a = k * math.pi / 2
		local glow = Instance.new("Attachment")
		glow.Name = "BeaconGlow"
		glow.Position = Vector3.new(16.5 * math.cos(a), 16.5 * math.sin(a), 0)
		glow.Parent = holder
		local e = Instance.new("ParticleEmitter")
		e.Name = "BeaconPulse"
		if tex and tex.id then
			e.Texture = tex.id
		end
		e.Rate = 0.8
		e.Lifetime = NumberRange.new(2.2, 2.4)
		e.Speed = NumberRange.new(0, 0)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 11) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.55), NumberSequenceKeypoint.new(1, 1) })
		e.Color = ColorSequence.new(BEACON_PLUM)
		e.LightEmission = 0.6
		e.LightInfluence = 0
		e.LockedToPart = true
		e.Orientation = Enum.ParticleOrientation.FacingCamera
		e.Parent = glow
	end
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
	-- Non-colliding kit visuals (ring rims, clasps, pad chevrons, pod gems, coins) are never raycast targets: the car's
	-- wheel probes include non-colliding parts (pavers) and rode up onto ring rims; the plane's step ray stops at the
	-- first hit and a rim hid the wall behind it. Everything here is found by attribute and distance instead.
	p.CanQuery = p.CanCollide
	p.Parent = parent
	partCount += 1
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
	-- Non-colliding kit visuals (ring rims, clasps, pad chevrons, pod gems, coins) are never raycast targets: the car's
	-- wheel probes include non-colliding parts (pavers) and rode up onto ring rims; the plane's step ray stops at the
	-- first hit and a rim hid the wall behind it. Everything here is found by attribute and distance instead.
	w.CanQuery = w.CanCollide
	w.Parent = parent
	partCount += 1
	return w
end

-- CanQuery can only be cleared on a non-collidable part, so callers pass parts built with canCollide=false.
local function makeQueryInvisible(p: BasePart)
	p.CanCollide = false
	p.CanQuery = false
end

function Gameplay.resetPartCount()
	partCount = 0
end

function Gameplay.getPartCount(): number
	return partCount
end

function Gameplay.buildWedgeRing(
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
		local segCF: CFrame = centerCF * CFrame.Angles(0, 0, angle) * CFrame.new(0, radius, 0)
		addPart(name .. "_Segment_" .. tostring(i), Enum.PartType.Block, Vector3.new(arcLen, thickness, width), segCF, material, color, mdl, nil, false)
	end
	return mdl
end

-- Ring art (owner: "many of the arches are just 6-7 blocks with spaces between them"): two world_v1 MeshParts replace the
-- 24 plum + 24 cream + 4 clasp + 24 glow blocks. ring_frame bakes the approved 04_dino4_controls.png palette as vertex
-- colours (cream outer rim, plum inner rim, four gold clasps at 12/3/6/9) and ring_glow is a white band tinted gold and
-- set to Neon (today's InnerGlow colour). Both share the ring's CFrame: the ring lies in its XY plane with the axis along
-- Z, the same frame the old rims used, and the outer radius (14.6 with clasps) equals today's 13.4 housing + 1.2.
local RING_GLOW_COLOR = Color3.fromRGB(224, 178, 72)
local RING_HOUSING_RADIUS = 13.4 -- today's rim radius; the meshes were authored at exactly this size, so scale = 1
local RING_OPENING_DIAMETER = 20 -- ring_frame opening radius 10.0 (manifest)

local function ringMesh(tplName: string, name: string, cf: CFrame, scale: number, parent: Instance): MeshPart?
	local tpl = WorldArt.world(tplName)
	if not tpl then
		return nil
	end
	local m = tpl:Clone()
	m.Name = name
	m.Size = tpl.Size * scale
	m.CFrame = cf
	m.Anchored = true
	-- Same rule as the old rims: a non-colliding visual is never a raycast target (the wheel probes and the plane's step
	-- ray would otherwise stop on the rim).
	m.CanCollide = false
	m.CanQuery = false
	m.CanTouch = false
	m.Parent = parent
	partCount += 1
	return m
end

-- Returns false when a template did not load; the caller then builds the legacy block rims.
local function buildRingMeshes(name: string, centerCF: CFrame, mdl: Model): boolean
	local scale = RING_HOUSING_RADIUS / 13.4
	local frame = ringMesh("ring_frame", name .. "_RingFrame", centerCF, scale, mdl)
	if not frame then
		return false
	end
	local glow = ringMesh("ring_glow", name .. "_RingGlow", centerCF, scale, mdl)
	if glow then
		glow.Material = Enum.Material.Neon
		glow.Color = RING_GLOW_COLOR
	end
	return true
end

-- Legacy block rims (24 + 24 + 4 + 24 parts), kept as the fallback when the ring meshes cannot be loaded.
local function buildRingBlocks(name: string, centerCF: CFrame, mdl: Model)
	Gameplay.buildWedgeRing(name .. "_InnerPlum", centerCF, 11.4, 2.2, 3.2, 24, Enum.Material.SmoothPlastic, Color3.fromRGB(98, 48, 86), mdl)
	Gameplay.buildWedgeRing(name .. "_InnerGlow", centerCF, 10.3, 0.7, 1.8, 24, Enum.Material.SmoothPlastic, Color3.fromRGB(224, 178, 72), mdl)

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
end

-- Approved 04_dino4_controls.png booster ring: cream outer rim, plum inner rim, four gold clasps at 12/3/6/9.
function Gameplay.buildBoosterRing(
	name: string,
	centerCF: CFrame,
	parent: Instance,
	hasCoin: boolean?,
	coinId: number?,
	sailGate: SailGateRules.Config?
): Model
	local mdl: Model = Instance.new("Model")
	mdl.Name = name
	mdl.Parent = parent

	local ok, built = pcall(buildRingMeshes, name, centerCF, mdl)
	if not ok or built ~= true then
		if not ok then
			warn(string.format("[SkyRally][MAP] ring meshes failed for %s: %s", name, tostring(built)))
		end
		partCount -= #mdl:GetChildren()
		mdl:ClearAllChildren()
		buildRingBlocks(name, centerCF, mdl)
	end

	local trigger: Part = addPart(
		name .. "_BoostTriggerDisc",
		Enum.PartType.Cylinder,
		Vector3.new(2.5, RING_OPENING_DIAMETER, RING_OPENING_DIAMETER),
		centerCF * CFrame.Angles(0, math.pi / 2, 0),
		Enum.Material.Neon,
		Color3.fromRGB(255, 220, 60),
		mdl,
		1,
		false
	)
	trigger:SetAttribute("TriggerType", "BoosterRing")
	CollectionService:AddTag(trigger, TriggerRules.TAG) -- the client reads the tagged set, not the map tree (L40)
	trigger:SetAttribute("BoostPower", 135)
	if sailGate ~= nil and SailGateRules.ENABLED then
		-- FOREST-1 sail-gap ring: live only while the gap lines up (the controllers and bots read these; SailGateFx lights it).
		trigger:SetAttribute(SailGateRules.ATTR_RPM, sailGate.rpm)
		trigger:SetAttribute(SailGateRules.ATTR_PHASE, sailGate.phaseDeg)
		trigger:SetAttribute(SailGateRules.ATTR_RING_DEG, sailGate.ringDeg)
		mdl:SetAttribute("SailGateRing", true)
	end
	-- The disc spans the ring opening, exactly where the plane flies.
	makeQueryInvisible(trigger)

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

-- Pads are placed at a fixed lift over the route line, which put them under the 1.4-thick pavers on paved decks (only
-- chevron tips showed). Seat the plate on whatever surface is below, pavers included, when it is within reach.
function Gameplay.seatOnSurface(cf: CFrame, exclude: Instance): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { exclude }
	params.RespectCanCollide = false
	local up = cf.UpVector
	-- The pavers under a 16x24 pad differ in height by over a stud across segment seams, and the flat pad mesh was buried under
	-- the high ones (only a frame bar showed): sample centre + corners and seat on the highest surface within 1.6 studs of the
	-- centre one, sinking the plate 0.25 where the surface is uneven so the pad does not hover over the low side.
	local centre: number? = nil
	local best: number? = nil
	local corners: { Vector3 } = {}
	for _, off in { Vector3.zero, Vector3.new(7, 0, 11), Vector3.new(-7, 0, 11), Vector3.new(7, 0, -11), Vector3.new(-7, 0, -11) } do
		local hit = workspace:Raycast(cf:PointToWorldSpace(off) + up * 6, -up * 12, params)
		if hit and hit.Instance.Transparency < 1 then
			local o = (hit.Position - cf.Position):Dot(up)
			if off == Vector3.zero then
				centre = o
				best = o
			else
				if centre and math.abs(o - centre) <= 3 then
					table.insert(corners, hit.Position)
				end
				if centre and o <= centre + 1.6 then
					best = math.max(best :: number, o)
				end
			end
		end
	end
	-- v37 (DINO-4 pads 1 and 2 half sunk): on a cross-sloped or banked floor the flat plate buried one side. With all
	-- four corners hit, tilt the pad onto the plane through them (up to PAD_MAX_TILT) and seat it on that plane.
	if centre and #corners == 4 then
		-- corners: FR(+x,+z), FL(-x,+z), BR(+x,-z), BL(-x,-z); the two diagonals span the surface plane
		local n = (corners[2] - corners[3]):Cross(corners[1] - corners[4])
		if n.Magnitude > 1e-3 then
			n = n.Unit
			if n:Dot(up) < 0 then
				n = -n
			end
			local tilt = math.deg(math.acos(math.clamp(n:Dot(up), -1, 1)))
			if tilt > 1 and tilt <= 20 then
				local mid = (corners[1] + corners[2] + corners[3] + corners[4]) / 4
				local look = cf.LookVector - n * cf.LookVector:Dot(n)
				if look.Magnitude > 1e-3 then
					local right = look.Unit:Cross(n)
					local at = cf.Position + n * ((mid - cf.Position):Dot(n) + 0.45)
					return CFrame.fromMatrix(at, right, n, -look.Unit)
				end
			end
		end
	end
	if centre and best then
		return cf + up * (best + 0.45 - math.min(0.25, best - centre))
	end
	return cf
end

-- Pad art (art v3 props_v3 boost_pad): the mesh (hazard-striped frame, navy field, three chevron recesses) replaces the
-- sandstone slab; the game's own Neon chevrons stay and sit in the recesses (manifest glow: floor y 0.5, field top 0.67, apex z
-- -5.9 / -1.18 / 3.4 in the prefab frame, centre line z = apex + 0.83 |x|, arms to |x| 3.0), so they are the glow. BasePlate stays
-- the trigger (invisible when the mesh is there). The pad's -Z is the route direction and the chevron apexes point -Z.
local PAD_BASE_Y = -0.4 -- the old slab's underside: the mesh's ground plane sits there
local PAD_APEX_Z = { -5.9, -1.18, 3.4 }
local PAD_ARM_SLOPE = 0.83
local PAD_ARM_END_X = 3.0
local PAD_GLOW_Y = 0.58 -- between the recess floor (0.5) and the field top (0.67)

local function padMesh(name: string, cf: CFrame, parent: Instance): MeshPart?
	local tpl = WorldArt.world("boost_pad")
	if not tpl then
		return nil
	end
	local m = tpl:Clone()
	m.Name = name .. "_PadArt"
	m.CFrame = cf * CFrame.new(0, PAD_BASE_Y, 0) * CFrame.new(ArtSwapRules.partCentre(ArtSwapRules.ASSETS.boost_pad, 1, Vector3.zero))
	m.Anchored = true
	m.CanCollide = false
	m.CanQuery = false
	m.CanTouch = false
	m.Parent = parent
	partCount += 1
	return m
end

function Gameplay.buildGroundBoostPad(name: string, cf: CFrame, parent: Instance): Model
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
	CollectionService:AddTag(base, TriggerRules.TAG)
	makeQueryInvisible(base)

	if padMesh(name, cf, mdl) then
		base.Transparency = 1
		base.CastShadow = false
		local armLen = PAD_ARM_END_X * math.sqrt(1 + PAD_ARM_SLOPE * PAD_ARM_SLOPE)
		local yaw = math.atan2(1, PAD_ARM_SLOPE)
		for i, apex in PAD_APEX_Z do
			for _, side in { -1, 1 } do
				local arm = addPart(
					(if side < 0 then "ChevronL_" else "ChevronR_") .. tostring(i),
					Enum.PartType.Block,
					Vector3.new(1.2, 0.14, armLen),
					cf * CFrame.new(side * PAD_ARM_END_X * 0.5, PAD_BASE_Y + PAD_GLOW_Y, apex + PAD_ARM_SLOPE * PAD_ARM_END_X * 0.5)
						* CFrame.Angles(0, side * yaw, 0),
					Enum.Material.Neon,
					Color3.fromRGB(255, 220, 40),
					mdl,
					0,
					false
				)
				arm.CastShadow = false
				makeQueryInvisible(arm)
			end
		end
		return mdl
	end

	for i = 1, 3 do
		local zOff: number = -8 + (i - 1) * 8
		local leftCF: CFrame = cf * CFrame.new(-3.2, 0.7, zOff) * CFrame.Angles(0, math.rad(45), 0)
		local rightCF: CFrame = cf * CFrame.new(3.2, 0.7, zOff) * CFrame.Angles(0, math.rad(-45), 0)
		addWedge("ChevronL_" .. tostring(i), Vector3.new(1.2, 1.0, 6.5), leftCF, Enum.Material.Neon, Color3.fromRGB(255, 220, 40), mdl, 0, false)
		addWedge("ChevronR_" .. tostring(i), Vector3.new(1.2, 1.0, 6.5), rightCF, Enum.Material.Neon, Color3.fromRGB(255, 220, 40), mdl, 0, false)
	end
	return mdl
end

export type PodOptions = {
	colored: boolean?, -- battle pods (server/battle): the coloured balloon and the colour rules, never a mystery cube
	onRoad: boolean?, -- car maps: the cube (and a Speed/Air pod) settles at hover height over the road under it
	planeMap: boolean?, -- plane maps: Speed/Air pods get the tall pickup volume (PickupLift, ItemRules.CUBES.planeLift)
	cubeRank: string?, -- cubes v3: "<set>#<rank>" from the plan (tools/map/item_rows.py); one cube per rank per pass
}

-- Pod placement: one raycast down from just above the planned centre against collidable world (deck, terrain, walls;
-- not water, pods, rings or triggers), then ItemRules.podHoverY at `hover` (default the cube's). Build time only.
function Gameplay.hoverPodPos(pos: Vector3, exclude: Instance, onRoad: boolean, hover: number?): Vector3
	local M = ItemRules.MYSTERY
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local planes = workspace:FindFirstChild("Planes")
	params.FilterDescendantsInstances = if planes then { exclude, planes } else { exclude }
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local hit = workspace:Raycast(pos + Vector3.new(0, M.probeUp, 0), Vector3.new(0, -(M.probeUp + M.probeDown), 0), params)
	local y = ItemRules.podHoverY(pos.Y, if hit then hit.Position.Y else nil, onRoad, hover or M.hover)
	return Vector3.new(pos.X, y, pos.Z)
end

function Gameplay.buildItemPodSpawn(name: string, pos: Vector3, podType: string, station: number, parent: Instance, opts: PodOptions?): Part
	local o: PodOptions = opts or {}
	local podClass = ItemRules.classifyPod(podType)
	local mystery = podClass == "item" and o.colored ~= true
	-- Cubes v2: Speed/Air pods on road maps snap to the road too (at coinHover), so a boost block or swirl never skims
	-- the road while cubes float at +5.5. Plane-map Speed/Air pods keep their planned flight height.
	local coinSnap = not mystery and o.colored ~= true and o.onRoad == true and (podClass == "speed" or podClass == "air")
	if mystery or coinSnap then
		local seated = Gameplay.hoverPodPos(pos, parent, o.onRoad == true, if coinSnap then ItemRules.CUBES.coinHover else nil)
		if math.abs(seated.Y - pos.Y) > 0.5 then
			print(string.format("[SkyRally][MAP] pod %s hover y %.1f -> %.1f", name, pos.Y, seated.Y))
		end
		pos = seated
	end
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
	CollectionService:AddTag(spawnPart, TriggerRules.TAG)
	spawnPart:SetAttribute("PodType", podType)
	spawnPart:SetAttribute("Station", station)
	-- Cubes v3 (owner: "Shared like Mario Kart, back for everyone in 1.0 s"): one ledger entry per pod in ItemService and
	-- one OnCooldown flip in RaceManager for every racer, players and bots alike. Battle pods pass colored and keep the
	-- battle default (BattleCore sets the arena's own RespawnSeconds after this).
	spawnPart:SetAttribute("RespawnSeconds", if o.colored == true then ItemRules.CUBES.battleRespawn else ItemRules.CUBES.respawn)
	if mystery and type(o.cubeRank) == "string" and o.cubeRank ~= "" then
		spawnPart:SetAttribute("CubeRank", o.cubeRank)
	end
	if o.planeMap == true and (podClass == "speed" or podClass == "air") then
		spawnPart:SetAttribute("PickupLift", ItemRules.CUBES.planeLift)
	end
	-- RaceManager toggles this on pickup; it only tests `~= true`, so false is the same state made explicit.
	spawnPart:SetAttribute("OnCooldown", false)
	makeQueryInvisible(spawnPart)

	-- Pickup art (owner: the pods "are plain looking blocks"): a race item pod is a mystery cube (ItemArt.buildMysteryCube,
	-- its glass in the plan colour's family; MysteryCube tells ItemService to roll the item), a battle pod the balloon of
	-- its colour, the mint boost block for Speed, a swirl for Air. The visual keeps the <name>_CoreVisual name RaceManager,
	-- ItemEffects.paintPods, ItemClient and the storm twins look up; ItemClient animates it (tumble or bob, pop on pickup)
	-- and nothing here changes a trigger.
	if mystery then
		spawnPart:SetAttribute("MysteryCube", true)
		ItemArt.buildMysteryCube(name, pos, spawnPart, podType)
		partCount += ItemArt.CUBE_FRAME_PARTS
	else
		ItemArt.buildPodCore(name, podType, pos, spawnPart)
	end
	partCount += 1
	return spawnPart
end

-- Respawn checkpoint volume; RaceManager reads CheckpointIndex/Station and measures distance to its Position.
function Gameplay.buildCheckpoint(index: number, station: number, cf: CFrame, size: Vector3, parent: Instance): Part
	local cp: Part = addPart(
		"Checkpoint_" .. tostring(index),
		Enum.PartType.Block,
		size,
		cf,
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(255, 200, 50),
		parent,
		1,
		false
	)
	cp:SetAttribute("CheckpointIndex", index)
	cp:SetAttribute("Station", math.floor(station))
	makeQueryInvisible(cp)
	return cp
end

export type BuildResult = {
	checkpoints: number,
	rings: number,
	pads: number,
	pods: number,
	parts: number,
	errors: { string },
}

-- Builds every gameplay object of a normalized TrackData (CFrame/Vector3 values, MAP_PLAN_SCHEMA section 3).
-- Each object is isolated: one bad entry is logged and skipped, the rest still build.
function Gameplay.build(trackData: any, checkpointsFolder: Instance, boostsFolder: Instance): BuildResult
	local result: BuildResult = { checkpoints = 0, rings = 0, pads = 0, pods = 0, parts = 0, errors = {} }
	local before = partCount

	local function try(kind: string, label: string, fn: () -> ())
		local ok, err = pcall(function()
			fn()
		end)
		if ok then
			(result :: any)[kind] += 1
		else
			local msg = string.format("gameplay %s %s: %s", kind, label, tostring(err))
			table.insert(result.errors, msg)
			warn("[SkyRally][MAP] ERROR " .. msg)
		end
	end

	for i, cp in trackData.checkpoints or {} do
		try("checkpoints", tostring(cp.index or i), function()
			Gameplay.buildCheckpoint(cp.index or i, cp.station or 0, cp.cf, cp.size or Vector3.new(56, 42, 6), checkpointsFolder)
		end)
	end
	for _, ring in trackData.rings or {} do
		try("rings", tostring(ring.name), function()
			local mdl = Gameplay.buildBoosterRing(ring.name, ring.cf, boostsFolder, ring.coin == true, ring.coinId, ring.sailGate)
			if BEACON_MAPS[trackData.id] and type(ring.line) ~= "string" then
				local okBeacon = pcall(function()
					buildRingBeacon(ring.cf, mdl)
				end)
				if not okBeacon then
					warn(string.format("[SkyRally][MAP] ring beacon %s failed", tostring(ring.name)))
				end
			end
			-- A ring on an alternate line (ISLAND-2 Alt2 cliff line): the line's id, so the station-rail bots skip it.
			local disc = mdl:FindFirstChild(ring.name .. "_BoostTriggerDisc")
			if type(ring.line) == "string" and disc then
				disc:SetAttribute(TriggerRules.LINE_ATTR, ring.line)
			end
		end)
	end
	local onRoad = trackData.vehicle == "car"
	local planeMap = trackData.vehicle == "plane"
	for _, pad in trackData.pads or {} do
		try("pads", tostring(pad.name), function()
			local mdl = Gameplay.buildGroundBoostPad(pad.name, Gameplay.seatOnSurface(pad.cf, boostsFolder), boostsFolder)
			local base = mdl:FindFirstChild("BasePlate")
			if planeMap and base then
				-- A plane flying over the pad takes it within the same tall capsule as a Speed pod (ItemRules.CUBES).
				base:SetAttribute("PickupLift", ItemRules.CUBES.planeLift)
			end
		end)
	end
	for _, pod in trackData.pods or {} do
		try("pods", tostring(pod.name), function()
			local rank = if type(pod.cubeSet) == "string" and pod.cubeRank ~= nil then pod.cubeSet .. "#" .. tostring(pod.cubeRank) else nil
			Gameplay.buildItemPodSpawn(pod.name, pod.pos, pod.type or "Red", pod.station or 0, boostsFolder, { onRoad = onRoad, planeMap = planeMap, cubeRank = rank })
		end)
	end

	result.parts = partCount - before
	return result
end

return Gameplay
