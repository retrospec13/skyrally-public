--!strict
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
-- Economy v3 phase 6: which model an avatar key renders (AvatarConfig.MESHES); never touches the hull.
local AvatarRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("AvatarRules"))

local MeshTemplate = require(script.Parent.kit.MeshTemplate)
-- Rigged creature avatars (AvatarConfig Mesh kind = "creature": the Void Dragon): load, fit under the camera bound, weld.
local CreatureMesh = require(script.Parent.kit.CreatureMesh)
local PilotSeat = require(script.Parent.kit.PilotSeat)

local PlaneBuilder = {}

-- Approved Tripo v3.1 Hero Plane asset IDs (uploaded & granted to Universe 0)
-- Model ID: 124015049418905 | MeshId: rbxassetid://119320578645739 | Refined Texture Asset: 135111632840959
-- v2 (2026-10-18): Tripo multiview smart_low_poly from the derived orthographic turnaround of 01_plane.png, with
-- the fuselage emblem replaced by an original badge; its SurfaceAppearance carries colour and normal maps.
-- v1 (model 124015049418905, mesh 119320578645739) stays recorded in ASSETS.
PlaneBuilder.HERO_PLANE_MODEL_ID = 107580586112839
PlaneBuilder.HERO_PLANE_MESH_ID = "rbxassetid://119320578645739"
PlaneBuilder.HERO_PLANE_TEX_ID = "rbxthumb://type=Asset&id=135111632840959&w=420&h=420"

-- Approved Car & Hovercraft asset IDs for catalog / hub display
-- v2 (2026-10-18): Tripo multiview smart_low_poly from the derived turnaround of 02_car.png (SurfaceAppearance maps);
-- v1 73180210314189 stays recorded in ASSETS.
PlaneBuilder.HERO_CAR_MODEL_ID = 111843268690922
PlaneBuilder.HERO_CAR_MESH_ID = "rbxassetid://98524705414193"
PlaneBuilder.HERO_CAR_TEX_ID = "rbxassetid://78243075518608"

PlaneBuilder.HERO_HOVERCRAFT_MODEL_ID = 122536889901424
PlaneBuilder.HERO_HOVERCRAFT_MESH_ID = "rbxassetid://93784605586399"
PlaneBuilder.HERO_HOVERCRAFT_TEX_ID = "rbxassetid://115513663776992"

-- Propeller (owner 2026-10-19: "The plane should have it's propeller ... rotate"). The rotor is a welded assembly on
-- the Motor6D "PropMotor" (Hull -> PropRotor, C0 = PROP_CENTER, spin axis = hull Z); every client turns it through
-- Motor6D.Transform from the plane's replicated Speed (client/VehicleMotion), so remote players' planes and bots spin
-- too and the server writes nothing per frame. Until the Blender split lands, wooden blades built from parts sit in
-- the baked prop's shroud. PROP_MODEL_ID (the split propeller mesh) replaces those blades; HERO_PLANE_BODY_MODEL_ID
-- (the body with its baked propeller removed) is used only when the propeller mesh loads, so the baked one is never
-- hidden without a turning one to replace it. Both stay nil until the integrator uploads them.
PlaneBuilder.PROP_MODEL_ID = 70418724316306 :: number? -- SkyRally_HeroPlane_v3_plane_prop (assets/models/hero_plane_v3)
PlaneBuilder.HERO_PLANE_BODY_MODEL_ID = 123393240062345 :: number? -- SkyRally_HeroPlane_v3_plane_body (prop-less)
PlaneBuilder.PROP_CENTER = CFrame.new(0, 0.45, -6.95) -- hull-local disc centre: just ahead of the baked prop, inside the shroud ring
PlaneBuilder.PROP_DIAMETER = 3.3 -- fits the shroud ring's opening (Studio captures 2026-10-19, out/vehicles_v3)
PlaneBuilder.PROP_MESH_ROTATION = CFrame.Angles(0, math.rad(-90), 0) -- propeller mesh (spin axis X, nose -X) -> rotor (axis Z), same yaw as the body weld
PlaneBuilder.PROP_CENTER_MESH = CFrame.new(0, 0.38, -6.78) -- hub of the split propeller mesh (v3 manifest), used instead of PROP_CENTER
PlaneBuilder.BODY_OFFSET_PROPLESS = CFrame.new(0, 0.3, 0.178) -- weld of the propeller-less body: its bbox ends at the ring, so it shifts back

-- Seated pilot (server/kit/PilotSeat): HumanoidRootPart position, Hull-local, for the R15 sit pose at PILOT_SCALE
-- (hips in the cockpit behind the wooden hood, head and shoulders above the rim). Measured on plane v2 in Studio
-- captures 2026-10-19 (out/vehicles_v3).
PlaneBuilder.SEAT_ANCHOR = CFrame.new(0, 1.7, -0.2)
PlaneBuilder.PILOT_SCALE = 0.7

local cachedTripoMesh: MeshPart? = nil
local tripoLoadAttempted: boolean = false

local tripoLoading = false

local function tryGetTripoPlaneTemplate(): MeshPart?
	-- LoadAsset yields; a second plane spawned meanwhile (player + bots spawn concurrently on a live server) must wait
	-- for this load instead of seeing "attempted, no mesh" and building the fallback (v9 published client).
	while tripoLoading do
		task.wait()
	end
	if tripoLoadAttempted then
		return cachedTripoMesh
	end
	tripoLoadAttempted = true
	tripoLoading = true
	local ok, container = pcall(function()
		return ModelBakes.load(PlaneBuilder.HERO_PLANE_MODEL_ID)
	end)
	if ok and container then
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("LuaSourceContainer") then
				desc:Destroy()
			elseif desc:IsA("MeshPart") and not cachedTripoMesh then
				local cloned = desc:Clone()
				for _, sub in ipairs(cloned:GetDescendants()) do
					if sub:IsA("LuaSourceContainer") then
						sub:Destroy()
					end
				end
				if not cloned:FindFirstChildOfClass("SurfaceAppearance") then
					cloned.TextureID = PlaneBuilder.HERO_PLANE_TEX_ID
				end
				cloned.Material = Enum.Material.SmoothPlastic
				cloned.Anchored = false
				cloned.CanCollide = false
				cloned.CanTouch = false
				cloned.CanQuery = false
				cloned.Massless = true
				cachedTripoMesh = cloned
			end
		end
		container:Destroy()
	end
	-- D19 / L68: report mesh vs deliberate fallback once per server.
	print(string.format("[SkyRally][ASSETS] plane model=%d state=%s loadOk=%s", PlaneBuilder.HERO_PLANE_MODEL_ID, if cachedTripoMesh then "mesh" else "FALLBACK", tostring(ok)))
	workspace:SetAttribute("AssetPlaneState", if cachedTripoMesh then "mesh" else "FALLBACK")
	tripoLoading = false
	return cachedTripoMesh
end

local function makePart(
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	material: Enum.Material,
	color: Color3,
	parent: Instance,
	transparency: number?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Material = material
	p.Color = color
	p.Transparency = transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function makeWedge(
	name: string,
	size: Vector3,
	material: Enum.Material,
	color: Color3,
	parent: Instance
): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Size = size
	w.Material = material
	w.Color = color
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Anchored = false
	w.CanCollide = false
	w.CanTouch = false
	w.CanQuery = false
	w.Massless = true
	w.Parent = parent
	return w
end

local function weldPart(part: BasePart, root: BasePart, offset: CFrame)
	part.CFrame = root.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = part
end

function PlaneBuilder.createPlane(
	planeName: string,
	primaryColor: Color3,
	accentColor: Color3,
	spawnCF: CFrame,
	isAI: boolean?,
	avatarKey: string? -- phase 6: the racer's plane avatar; nil / unknown / unbuilt = the hero plane (the starter)
): Model
	local model = Instance.new("Model")
	model.Name = planeName
	model:SetAttribute("IsPlane", true)
	model:SetAttribute("IsAI", isAI == true)
	model:SetAttribute("BoostState", "None")
	model:SetAttribute("Speed", 110)
	model:SetAttribute("SpawnCFrame", spawnCF)
	model:SetAttribute("SeatAnchor", PlaneBuilder.SEAT_ANCHOR)
	model:SetAttribute("PilotScale", PlaneBuilder.PILOT_SCALE)

	-- Approved Concept 01 Palette (Plum wings/tail, Dark Teal flanks, Varnished Wood hood/keel, Mustard wingtips, Cream stripes/shroud)
	local plumColor = if isAI then primaryColor else Color3.fromRGB(110, 62, 102)
	local tealFlank = Color3.fromRGB(46, 86, 98)
	local woodWarm = Color3.fromRGB(158, 102, 54)
	local woodDark = Color3.fromRGB(118, 74, 38)
	local mustardTip = if isAI then accentColor else Color3.fromRGB(228, 172, 48)
	local creamStripe = Color3.fromRGB(240, 232, 210)
	local shroudMetal = Color3.fromRGB(226, 220, 206)

	-- Primary physics fuselage hull (simplified invisible collision/physics root so the approved Tripo Hero Plane MeshPart renders cleanly!)
	local hull = Instance.new("Part")
	hull.Name = "Hull"
	hull.Size = Vector3.new(4.2, 3.0, 12.0)
	hull.CFrame = spawnCF
	hull.Material = Enum.Material.SmoothPlastic
	hull.Color = tealFlank
	hull.Transparency = 1
	hull.TopSurface = Enum.SurfaceType.Smooth
	hull.BottomSurface = Enum.SurfaceType.Smooth
	hull.Anchored = isAI == true
	hull.CanCollide = false
	hull.CanTouch = true
	hull.CanQuery = false
	hull.CustomPhysicalProperties = PhysicalProperties.new(1.0, 0.1, 0.0, 1.0, 1.0)
	hull.Parent = model
	model.PrimaryPart = hull

	-- Avatar swap (phase 6). The hull above is the same for every avatar (stat-neutral by construction); only the body
	-- mesh below changes. A registered avatar mesh replaces the hero body; a load failure falls back to the hero.
	local shownKey, avatarMesh = AvatarRules.meshFor(avatarKey, "plane")
	-- A creature (rigged, animated mount) loads as a whole model; a load failure falls back to the hero plane.
	local creatureRig = if avatarMesh.kind == "creature" then CreatureMesh.get(avatarMesh.modelId, "avatar_" .. shownKey) else nil
	local avatarTemplate = if avatarMesh.hero or avatarMesh.kind == "creature" then nil else MeshTemplate.get(avatarMesh.modelId, "avatar_" .. shownKey)
	local heroProp = (avatarTemplate == nil and creatureRig == nil) or avatarMesh.prop == true
	model:SetAttribute("AvatarKey", shownKey) -- the pick (class-checked), even while its mesh has not landed
	model:SetAttribute("AvatarMesh", if creatureRig then "creature" elseif avatarTemplate then "own" else "hero")

	-- Attach the approved Tripo 3D Hero Plane MeshPart (`rbxassetid://119320578645739` with refined texture `135111632840959`) by default!
	local tripoTemplate = tryGetTripoPlaneTemplate()
	local propMesh = if heroProp then MeshTemplate.get(PlaneBuilder.PROP_MODEL_ID, "plane_prop") else nil
	local propless = if propMesh and not avatarTemplate then MeshTemplate.get(PlaneBuilder.HERO_PLANE_BODY_MODEL_ID, "plane_body") else nil
	if propless then
		MeshTemplate.shareSurface(propless, propMesh)
	end
	if tripoTemplate and propless then
		tripoTemplate = propless
	end
	if avatarTemplate then
		tripoTemplate = avatarTemplate
	end
	local bodyScale = 0 -- studs per mesh unit of the body actually used: the split propeller mesh shares it
	model:SetAttribute("PropState", if propless and propMesh then "mesh" elseif propMesh then "mesh+baked" elseif heroProp then "parts" else "none")
	if creatureRig then
		-- Same hull, same physics; the skinned creature is welded on (no propeller) and the rider sits on its back.
		local fitted = CreatureMesh.attach(model, hull, creatureRig, avatarMesh)
		model:SetAttribute("HasTripoMesh", true)
		model:SetAttribute("CreatureLength", fitted)
	elseif tripoTemplate then
		local meshClone = tripoTemplate:Clone()
		meshClone.Name = "TripoHeroPlaneMesh"
		meshClone.Transparency = 0
		if isAI then
			meshClone.Color = primaryColor:Lerp(Color3.fromRGB(255, 255, 255), 0.35)
		else
			meshClone.Color = Color3.fromRGB(255, 255, 255)
		end
		local rawSize = meshClone.Size
		local scaleFactor = 16.5 / math.max(1, math.max(rawSize.X, rawSize.Z))
		if avatarTemplate then
			scaleFactor = (avatarMesh.length or 16.5) / math.max(0.001, rawSize.X, rawSize.Y, rawSize.Z)
		end
		bodyScale = scaleFactor
		meshClone.Size = rawSize * scaleFactor
		meshClone.Parent = model
		-- v2 mesh is axis-aligned with the nose on -X (verified in a race capture 2026-10-18); -90 deg yaw puts it on the
		-- hull's -Z (forward). An avatar mesh carries its own measured yaw and offset.
		if avatarTemplate then
			local o = avatarMesh.offset or { 0, 0.3, 0 }
			weldPart(meshClone, hull, CFrame.new(o[1], o[2], o[3]) * CFrame.Angles(0, math.rad(avatarMesh.yaw or -90), 0))
		else
			weldPart(meshClone, hull, (if propless then PlaneBuilder.BODY_OFFSET_PROPLESS else CFrame.new(0, 0.3, 0)) * CFrame.Angles(0, math.rad(-90), 0))
		end
		model:SetAttribute("HasTripoMesh", true)
	else
		hull.Transparency = 0
		local wingL = makePart("MainWingL", Enum.PartType.Block, Vector3.new(7.8, 0.42, 4.2), Enum.Material.SmoothPlastic, plumColor, model)
		weldPart(wingL, hull, CFrame.new(-5.1, -0.35, -1.0) * CFrame.Angles(0, math.rad(5), math.rad(4)))
		local wingR = makePart("MainWingR", Enum.PartType.Block, Vector3.new(7.8, 0.42, 4.2), Enum.Material.SmoothPlastic, plumColor, model)
		weldPart(wingR, hull, CFrame.new(5.1, -0.35, -1.0) * CFrame.Angles(0, math.rad(-5), math.rad(-4)))
		local tailFin = makeWedge("TailFin", Vector3.new(0.65, 3.8, 3.4), Enum.Material.SmoothPlastic, plumColor, model)
		weldPart(tailFin, hull, CFrame.new(0, 2.4, 6.4))
	end

	-- Propeller rotor on a Motor6D (see PROP_CENTER). PropRotor is an invisible frame at the disc centre whose Z is the
	-- spin axis; hub, blades (or the propeller mesh) and the blur disc are welded to it. The names differ from the old
	-- loose anchored PropSpinner/PropBlade1/PropBlade2 on purpose: code that still CFrames those by name finds nothing
	-- instead of yanking a welded assembly.
	-- An avatar mesh without the hero propeller (prop = false) skips the rotor; VehicleMotion turns nothing then.
	if heroProp then
		local rotor = makePart("PropRotor", Enum.PartType.Block, Vector3.new(0.2, 0.2, 0.2), Enum.Material.SmoothPlastic, woodDark, model, 1)
		local propCenter = if propless and propMesh then PlaneBuilder.PROP_CENTER_MESH else PlaneBuilder.PROP_CENTER
		rotor.CFrame = hull.CFrame * propCenter
		local propMotor = Instance.new("Motor6D")
		propMotor.Name = "PropMotor"
		propMotor.Part0 = hull
		propMotor.Part1 = rotor
		propMotor.C0 = propCenter
		propMotor.C1 = CFrame.new()
		propMotor.Parent = hull
		local d = PlaneBuilder.PROP_DIAMETER
		if propMesh then
			local m = propMesh:Clone()
			m.Name = "PropMesh"
			local raw = m.Size
			m.Size = raw * (if bodyScale > 0 and not avatarTemplate then bodyScale else d / math.max(raw.X, raw.Y, raw.Z, 0.001))
			m.Parent = model
			weldPart(m, rotor, PlaneBuilder.PROP_MESH_ROTATION)
		else
			local hub = makePart("PropHub", Enum.PartType.Cylinder, Vector3.new(0.9, 1.1, 1.1), Enum.Material.Wood, woodWarm, model)
			weldPart(hub, rotor, CFrame.new(0, 0, -0.15) * CFrame.Angles(0, math.pi / 2, 0))
			local bladeA = makePart("PropBladeA", Enum.PartType.Block, Vector3.new(d, 0.7, 0.22), Enum.Material.WoodPlanks, woodDark, model)
			weldPart(bladeA, rotor, CFrame.new())
			local bladeB = makePart("PropBladeB", Enum.PartType.Block, Vector3.new(0.7, d, 0.22), Enum.Material.WoodPlanks, woodDark, model)
			weldPart(bladeB, rotor, CFrame.new())
		end
		-- Motion-blur disc: invisible at rest, fades in with speed on each client (VehicleMotion) so a fast prop reads as a
		-- blur instead of a strobing cross.
		local disc = makePart("PropDisc", Enum.PartType.Cylinder, Vector3.new(0.05, d * 1.02, d * 1.02), Enum.Material.SmoothPlastic, Color3.fromRGB(205, 170, 120), model, 1)
		weldPart(disc, rotor, CFrame.new(0, 0, 0.05) * CFrame.Angles(0, math.pi / 2, 0))
	end

	-- Warm upward lava bounce PointLight & the thruster disc (garage accent part) on the Hero Plane
	local planeUnderLight = makePart("PlaneLavaBounce", Enum.PartType.Block, Vector3.new(0.5, 0.5, 0.5), Enum.Material.SmoothPlastic, woodDark, model, 1.0)
	weldPart(planeUnderLight, hull, CFrame.new(0, -3.2, 1.5))
	local pul = Instance.new("PointLight")
	pul.Color = Color3.fromRGB(255, 128, 38)
	pul.Brightness = 1.65
	pul.Range = 22
	pul.Shadows = false
	pul.Parent = planeUnderLight
	local thruster = makePart("ThrusterGlow", Enum.PartType.Cylinder, Vector3.new(0.4, 0.9, 0.9), Enum.Material.SmoothPlastic, woodDark, model, 0.0)
	weldPart(thruster, hull, CFrame.new(0, 0.1, 8.4) * CFrame.Angles(0, math.pi / 2, 0))
	-- The mesh plane has its own tail; the disc read as a big orange cylinder in the chase camera (owner review), so it
	-- stays only as the Garage accent anchor and the flame's visual mouth on the block fallback.
	if model:GetAttribute("HasTripoMesh") == true then
		thruster.Transparency = 1
	end

	-- Exhaust nozzle for the layered flame (client/Vfx builds the meshes from this attachment). It replaces the old
	-- ExhaustTrail ribbons and the BoostSparks emitter (owner: the flame looked bad). No rotation: the flame
	-- runs along +Z (backwards); FlameScale sizes it for this vehicle. The flame base sits in the tail disc's mouth.
	-- A creature (the Void Dragon) has no nozzle: the plane's belly flame is not dragon fire (owner V15); client/Vfx
	-- gives it ember trails from the wingtips and tail tip instead.
	if not creatureRig then
		local nozzle = Instance.new("Attachment")
		nozzle.Name = "FlameNozzle"
		nozzle.Position = Vector3.new(0, 0.1, 8.5)
		nozzle:SetAttribute("FlameScale", 1)
		nozzle.Parent = hull
	end

	if not isAI then
		local rootAtt = Instance.new("Attachment")
		rootAtt.Name = "FlightAttachment"
		rootAtt.Parent = hull

		local lv = Instance.new("LinearVelocity")
		lv.Name = "FlightVelocity"
		lv.Attachment0 = rootAtt
		lv.MaxForce = 1e7
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VectorVelocity = spawnCF.LookVector * 110
		lv.Parent = hull

		local ao = Instance.new("AlignOrientation")
		ao.Name = "FlightOrientation"
		ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		ao.Attachment0 = rootAtt
		ao.MaxTorque = 1e7
		ao.Responsiveness = 45
		ao.CFrame = spawnCF
		ao.Parent = hull
	else
		-- A seated bot pilot (asynchronous: appears once its preset is built and the plane is in the workspace).
		PilotSeat.attachBotPilot(model)
	end

	return model
end

-- Starts the plane's three mesh loads at once on their own threads (hero plane, split propeller, propeller-less body),
-- like CarBuilder.prewarm. Returns at once; createPlane waits only for loads still in flight.
function PlaneBuilder.prewarm()
	task.spawn(tryGetTripoPlaneTemplate)
	task.spawn(MeshTemplate.get, PlaneBuilder.PROP_MODEL_ID, "plane_prop")
	task.spawn(MeshTemplate.get, PlaneBuilder.HERO_PLANE_BODY_MODEL_ID, "plane_body")
end

return PlaneBuilder
