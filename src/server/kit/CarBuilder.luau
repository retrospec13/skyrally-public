--!strict
-- Launch car model (PLAN L2, TEST_LIST_LAUNCH L05/L06). Same contract as PlaneBuilder.createPlane so the race code
-- treats both vehicles alike: a Model under workspace.Planes (the race code's vehicle folder) whose PrimaryPart is a
-- part named "Hull" (RaceManager, ItemService/ItemEffects and the Vfx rigs read Hull positions), the attributes
-- BoostState/Speed/SpawnCFrame/HasTripoMesh, and for a player a LinearVelocity + AlignOrientation pair that the owning
-- client drives every frame (CarController keeps one authoritative simulated position, like FlightController).
--
-- Rig (all welds hang off the Hull, which is the only part with mass):
--   Hull            invisible physics root, CanQuery=false so no raycast ever stops on a car
--   BodyRoot        Motor6D "BodyMotor" from the Hull; the owner's client animates its Transform locally for lean,
--                   landing squash and the drift hop (Transform is not replicated, so others see the plain pose)
--     TripoHeroCarMesh   approved Tripo car (PlaneBuilder.HERO_CAR_*), welded to BodyRoot, or
--     Fallback_*         deliberate block-built body when the mesh cannot load (named, logged as FALLBACK; L68)
--   Wheel_FL/FR/RL/RR  cylinders on Motor6Ds "<name>Motor" (C0 = wheel centre); clients set Transform for spin,
--                   steer and suspension travel (CarController: the local car and every other car, bots included).
--                   Hub + spoke parts welded to each wheel make the spin readable; with a wheel mesh (WHEEL_MODEL_ID)
--                   a "<name>_Mesh" rides the cylinder instead and the cylinder itself stays invisible.
--   Pilot           the seated avatar (server/kit/PilotSeat), welded to BodyRoot at SEAT_ANCHOR: a player's character
--                   (FlightServer/CarServer mount it) or, for a bot, a HumanoidDescription pilot model under the car
--   DriftSparkL/R   attachments at the rear contact patches (CarController hangs its spark emitters here)
-- Wheel geometry comes from CarConfig.WHEELS so the probes the controller casts sit exactly under these wheels.
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CarConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CarConfig"))
-- Economy v3 phase 6: which model an avatar key renders (AvatarConfig.MESHES); never touches the hull or the wheels' probes.
local AvatarRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AvatarRules"))
local PlaneBuilder = require(script.Parent.Parent.PlaneBuilder)
local MeshTemplate = require(script.Parent.MeshTemplate)
local PilotSeat = require(script.Parent.PilotSeat)

local CarBuilder = {}

-- Asset ids live in PlaneBuilder (one place for the asset preflight scan and the grant ledger).
CarBuilder.HERO_CAR_MODEL_ID = PlaneBuilder.HERO_CAR_MODEL_ID
CarBuilder.HERO_CAR_TEX_ID = PlaneBuilder.HERO_CAR_TEX_ID

-- Visible length the mesh is scaled to (studs). CarConfig.HULL_SIZE is the gameplay footprint (10.5 long).
CarBuilder.CAR_MESH_LENGTH = 10.8
-- Mesh-to-body rotation. TODO(integrator, Studio): the Tripo meshes are baked with an arbitrary roll/yaw (the plane
-- needed a measured 17.3 deg roll / -54 deg yaw, see PlaneBuilder). Measure the car the same way (thinnest principal
-- axis -> +Y, left/right mirror symmetry -> X, nose -> -Z) and set this to that rotation. While it is nil the builder
-- uses a bounding-box guess (longest axis -> Z, shortest -> Y) and logs rotation=guess.
-- Measured 2026-10-18 on car v2 (top/side captures with a -Z marker): the nose sits on -X; -90 deg yaw maps it to -Z.
CarBuilder.CAR_MESH_ROTATION = CFrame.Angles(0, math.rad(-90), 0) :: CFrame?
-- Under the guess the nose may point backwards (a box cannot tell front from back): flip it here if so.
CarBuilder.CAR_MESH_GUESS_FLIP = false
CarBuilder.CAR_MESH_OFFSET = CFrame.new(0, 0.15, 0) -- body-local offset of the mesh centre
-- The approved mesh has its wheels baked into the body. Until the Blender refine separates them (ASSETS hero car row:
-- separable wheel meshes with hub pivots) the spinning cylinders sit over the baked wheels; set false to hide them.
CarBuilder.SHOW_WHEELS_WITH_MESH = false -- car v2 has crisp baked wheels; overlay cylinders read as doubled wheels

-- Split meshes (owner 2026-10-19: "the wheels ... are not moving, currently they look like floating bricks"). The
-- Blender split delivers one wheel mesh and the body without its baked wheels; both ids stay nil until uploaded. Only
-- when the wheel mesh loads does the car use the wheel-less body (if that is set and loads too) and show turning
-- wheels; otherwise it keeps the baked-wheel body with the procedural wheels hidden, exactly as before.
-- The front and rear tyres are different sizes, so the split has one mesh per axle (v3 manifest).
CarBuilder.WHEEL_FRONT_MODEL_ID = 140501870412096 :: number? -- SkyRally_HeroCar_v3_wheel_front (assets/models/hero_car_v3)
CarBuilder.WHEEL_REAR_MODEL_ID = 83360206067759 :: number? -- SkyRally_HeroCar_v3_wheel_rear
CarBuilder.HERO_CAR_BODY_MODEL_ID = 95757652390974 :: number? -- SkyRally_HeroCar_v3_car_body (wheel-less)
-- The wheel-less body is taller at the bottom edge, so its weld moves up to keep the body where the baked one sat.
CarBuilder.CAR_MESH_OFFSET_WHEELLESS = CFrame.new(0, 0.33, 0)
-- Wheel mesh -> wheel part (axle on part X, outer face on +X for the right-hand wheels; left wheels get a half turn).
CarBuilder.WHEEL_MESH_ROTATION = CFrame.new()
-- Where the split wheels sit on the body (v3 manifest, hull-local hub centres) and their visible diameters (studs),
-- FL, FR, RL, RR. These are not the CarConfig.WHEELS probe positions: the probes stay where the physics wants them, but
-- the motors of mesh wheels sit at the visual hubs so each tyre meets its fender and the road.
CarBuilder.WHEEL_MESH_HUBS = {
	Vector3.new(-2.467, -0.851, -2.821),
	Vector3.new(2.467, -0.851, -2.821),
	Vector3.new(-2.403, -0.676, 3.42),
	Vector3.new(2.403, -0.676, 3.42),
} :: { Vector3 }
CarBuilder.WHEEL_MESH_DIAMETERS = { 2.096, 2.096, 2.436, 2.436 } :: { number }

-- Seated pilot (server/kit/PilotSeat). SEAT_ANCHOR = where the pilot's HumanoidRootPart sits, BodyRoot-local, for the
-- default R15 sit pose at PILOT_SCALE (hips on the seat cushion, head just above the cockpit rim). Measured on car v2
-- in Studio captures 2026-10-19 (out/vehicles_v3); a new body mesh only changes these two numbers.
CarBuilder.SEAT_ANCHOR = CFrame.new(0, 1.05, 1.1)
CarBuilder.PILOT_SCALE = 0.72

local cachedTripoMesh: MeshPart? = nil
local tripoLoadAttempted = false
local tripoLoading = false

-- Same concurrency-safe single load as PlaneBuilder.tryGetTripoPlaneTemplate: a car built while the first LoadAsset
-- yields waits for that load instead of reading "attempted, no mesh" and building the fallback.
local function tryGetTripoCarTemplate(): MeshPart?
	while tripoLoading do
		task.wait()
	end
	if tripoLoadAttempted then
		return cachedTripoMesh
	end
	tripoLoadAttempted = true
	tripoLoading = true
	local ok, container = pcall(function()
		return ModelBakes.load(CarBuilder.HERO_CAR_MODEL_ID)
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
				-- Same guard as PlaneBuilder's v2 plane: a model that ships a SurfaceAppearance (hero_car_v2 path)
				-- carries its own colour/normal maps, so the v1 texture is only a fallback for a bare mesh.
				if not cloned:FindFirstChildOfClass("SurfaceAppearance") then
					cloned.TextureID = CarBuilder.HERO_CAR_TEX_ID
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
	local raw = if cachedTripoMesh then cachedTripoMesh.Size else Vector3.zero
	-- D19 / L68: report mesh vs deliberate fallback once per server; raw size helps measure CAR_MESH_ROTATION.
	print(string.format(
		"[SkyRally][ASSETS] car model=%d state=%s loadOk=%s rawSize=(%.3f,%.3f,%.3f) rotation=%s",
		CarBuilder.HERO_CAR_MODEL_ID,
		if cachedTripoMesh then "mesh" else "FALLBACK",
		tostring(ok),
		raw.X,
		raw.Y,
		raw.Z,
		if CarBuilder.CAR_MESH_ROTATION then "measured" else "guess"
	))
	workspace:SetAttribute("AssetCarState", if cachedTripoMesh then "mesh" else "FALLBACK")
	tripoLoading = false
	return cachedTripoMesh
end

-- Bounding-box orientation guess: longest local axis -> body Z (length), shortest -> body Y (height).
local function guessMeshRotation(size: Vector3): CFrame
	local axes = {
		{ v = size.X, dir = Vector3.xAxis },
		{ v = size.Y, dir = Vector3.yAxis },
		{ v = size.Z, dir = Vector3.zAxis },
	}
	table.sort(axes, function(a, b)
		return a.v > b.v
	end)
	local longLocal, shortLocal = axes[1].dir, axes[3].dir
	-- Rotation R with R*longLocal = Z and R*shortLocal = Y; build it as the inverse of the frame whose
	-- columns are where the body axes come from in mesh space (X = Y x Z keeps it a proper rotation).
	local zFrom, yFrom = longLocal, shortLocal
	local xFrom = yFrom:Cross(zFrom)
	local meshToBody = CFrame.fromMatrix(Vector3.zero, xFrom, yFrom, zFrom):Inverse()
	if CarBuilder.CAR_MESH_GUESS_FLIP then
		meshToBody = CFrame.Angles(0, math.pi, 0) * meshToBody
	end
	return meshToBody
end

local function makePart(name: string, shape: Enum.PartType, size: Vector3, material: Enum.Material, color: Color3, parent: Instance, transparency: number?): Part
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

local function makeWedge(name: string, size: Vector3, material: Enum.Material, color: Color3, parent: Instance): WedgePart
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

local function weldTo(part: BasePart, root: BasePart, offset: CFrame)
	part.CFrame = root.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = part
end

local function motor(name: string, hull: BasePart, part: BasePart, c0: CFrame): Motor6D
	part.CFrame = hull.CFrame * c0
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = hull
	m.Part1 = part
	m.C0 = c0
	m.C1 = CFrame.new()
	m.Parent = hull
	return m
end

-- Deliberate block-built body (shown only when the Tripo mesh cannot load). Proportions follow 02_car.png: low plum
-- tub, wooden side planks, cream nose, brass trim, open cockpit.
local function buildFallbackBody(model: Model, bodyRoot: BasePart, primary: Color3, accent: Color3)
	local wood = Color3.fromRGB(150, 98, 54)
	local cream = Color3.fromRGB(240, 232, 210)
	local dark = Color3.fromRGB(42, 30, 34)
	local chassis = makePart("Fallback_Chassis", Enum.PartType.Block, Vector3.new(4.6, 1.3, 9.8), Enum.Material.SmoothPlastic, primary, model)
	weldTo(chassis, bodyRoot, CFrame.new(0, -0.1, 0))
	local nose = makeWedge("Fallback_Nose", Vector3.new(4.2, 1.1, 3.0), Enum.Material.SmoothPlastic, cream, model)
	weldTo(nose, bodyRoot, CFrame.new(0, 1.1, -3.4))
	local cockpit = makePart("Fallback_CockpitRim", Enum.PartType.Block, Vector3.new(3.4, 0.7, 2.8), Enum.Material.SmoothPlastic, dark, model)
	weldTo(cockpit, bodyRoot, CFrame.new(0, 0.85, 0.6))
	local seat = makePart("Fallback_Seat", Enum.PartType.Block, Vector3.new(2.4, 1.6, 0.6), Enum.Material.SmoothPlastic, accent, model)
	weldTo(seat, bodyRoot, CFrame.new(0, 1.3, 2.0))
	for side = -1, 1, 2 do
		local plank = makePart(if side < 0 then "Fallback_PlankL" else "Fallback_PlankR", Enum.PartType.Block, Vector3.new(0.5, 0.9, 7.6), Enum.Material.WoodPlanks, wood, model)
		weldTo(plank, bodyRoot, CFrame.new(side * 2.45, 0.1, 0.2))
	end
	local spoiler = makePart("Fallback_Spoiler", Enum.PartType.Block, Vector3.new(5.0, 0.35, 1.2), Enum.Material.Metal, accent, model)
	weldTo(spoiler, bodyRoot, CFrame.new(0, 1.9, 4.5))
	for side = -1, 1, 2 do
		local strut = makePart(if side < 0 then "Fallback_StrutL" else "Fallback_StrutR", Enum.PartType.Block, Vector3.new(0.3, 1.2, 0.4), Enum.Material.Metal, dark, model)
		weldTo(strut, bodyRoot, CFrame.new(side * 1.6, 1.25, 4.5))
	end
	local bumper = makePart("Fallback_Bumper", Enum.PartType.Block, Vector3.new(5.4, 0.5, 0.6), Enum.Material.Metal, accent, model)
	weldTo(bumper, bodyRoot, CFrame.new(0, -0.3, -5.0))
end

local function buildWheel(model: Model, hull: BasePart, index: number, accent: Color3, visible: boolean, wheelMesh: MeshPart?): BasePart
	local w = CarConfig.WHEELS[index]
	if wheelMesh then
		local hub = CarBuilder.WHEEL_MESH_HUBS[index]
		w = { hub.X, hub.Y, hub.Z }
	end
	local name = CarConfig.WHEEL_NAMES[index]
	local r = CarConfig.WHEEL_RADIUS
	local alpha = if visible and not wheelMesh then 0 else 1
	-- Cylinder axis = part X = the axle (hull X).
	local tyre = makePart(name, Enum.PartType.Cylinder, Vector3.new(CarConfig.WHEEL_WIDTH, r * 2, r * 2), Enum.Material.SmoothPlastic, Color3.fromRGB(34, 28, 30), model, alpha)
	motor(name .. "Motor", hull, tyre, CFrame.new(w[1], w[2], w[3]))
	local outward = if w[1] < 0 then -1 else 1
	if wheelMesh then
		-- The mesh rides the (invisible) cylinder, so the same Motor6D spins, steers and bounces it.
		local mesh = wheelMesh:Clone()
		mesh.Name = name .. "_Mesh"
		local raw = mesh.Size
		mesh.Size = raw * (CarBuilder.WHEEL_MESH_DIAMETERS[index] / math.max(raw.X, raw.Y, raw.Z, 0.001))
		mesh.Parent = model
		local face = if outward < 0 then CFrame.Angles(0, math.pi, 0) else CFrame.new()
		weldTo(mesh, tyre, face * CarBuilder.WHEEL_MESH_ROTATION)
		return tyre
	end
	local hub = makePart(name .. "_Hub", Enum.PartType.Cylinder, Vector3.new(CarConfig.WHEEL_WIDTH + 0.12, r * 1.1, r * 1.1), Enum.Material.Metal, accent, model, alpha)
	weldTo(hub, tyre, CFrame.new(0, 0, 0))
	-- One spoke across the hub face: the only cue that a round wheel is spinning.
	local spoke = makePart(name .. "_Spoke", Enum.PartType.Block, Vector3.new(0.12, r * 1.5, 0.32), Enum.Material.Metal, Color3.fromRGB(240, 232, 210), model, alpha)
	weldTo(spoke, tyre, CFrame.new(outward * (CarConfig.WHEEL_WIDTH * 0.5 + 0.08), 0, 0))
	return tyre
end

-- avatarKey (phase 6): the racer's car avatar; nil / unknown / unbuilt = the hero car (the starter).
function CarBuilder.createCar(carName: string, primaryColor: Color3, accentColor: Color3, spawnCF: CFrame, isAI: boolean?, avatarKey: string?): Model
	local model = Instance.new("Model")
	model.Name = carName
	model:SetAttribute("IsCar", true)
	model:SetAttribute("VehicleType", "car")
	model:SetAttribute("IsAI", isAI == true)
	model:SetAttribute("BoostState", "None")
	model:SetAttribute("Speed", 0)
	model:SetAttribute("Steer", 0)
	model:SetAttribute("DriftLevel", 0)
	model:SetAttribute("Drifting", false)
	model:SetAttribute("SpawnCFrame", spawnCF)
	model:SetAttribute("SeatAnchor", CarBuilder.SEAT_ANCHOR)
	model:SetAttribute("PilotScale", CarBuilder.PILOT_SCALE)

	local hs = CarConfig.HULL_SIZE
	local hull = Instance.new("Part")
	hull.Name = "Hull"
	hull.Size = Vector3.new(hs[1], hs[2], hs[3])
	hull.CFrame = spawnCF
	hull.Material = Enum.Material.SmoothPlastic
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

	local bodyRoot = makePart("BodyRoot", Enum.PartType.Block, Vector3.new(1, 1, 1), Enum.Material.SmoothPlastic, Color3.new(1, 1, 1), model, 1)
	motor("BodyMotor", hull, bodyRoot, CFrame.new(0, 0, 0))

	-- Avatar swap (phase 6). The hull above and CarConfig.WHEELS are the same for every avatar (stat-neutral by
	-- construction); only the body mesh changes. A registered avatar mesh replaces the hero body (its wheels show only
	-- when the mesh is wheel-less, Mesh.wheels); a load failure falls back to the hero car.
	local shownKey, avatarMesh = AvatarRules.meshFor(avatarKey, "car")
	local avatarTemplate = if avatarMesh.hero then nil else MeshTemplate.get(avatarMesh.modelId, "avatar_" .. shownKey)
	model:SetAttribute("AvatarKey", shownKey) -- the pick (class-checked), even while its mesh has not landed
	model:SetAttribute("AvatarMesh", if avatarTemplate then "own" else "hero")

	local template = tryGetTripoCarTemplate()
	local wheelFront = MeshTemplate.get(CarBuilder.WHEEL_FRONT_MODEL_ID, "car_wheel_front")
	local wheelRear = MeshTemplate.get(CarBuilder.WHEEL_REAR_MODEL_ID, "car_wheel_rear")
	local haveWheels = wheelFront ~= nil and wheelRear ~= nil -- both axles or neither: never one bald axle
	local body = if haveWheels and not avatarTemplate then MeshTemplate.get(CarBuilder.HERO_CAR_BODY_MODEL_ID, "car_body") else nil
	if body then
		MeshTemplate.shareSurface(body, wheelFront)
		MeshTemplate.shareSurface(body, wheelRear)
	end
	if template and body then
		template = body -- the wheel-less body: the turning wheel meshes replace the baked ones
	end
	if avatarTemplate then
		template = avatarTemplate
		if avatarMesh.wheels and haveWheels then
			body = avatarTemplate -- a wheel-less avatar body: the turning wheels show
		end
	end
	if template then
		local mesh = template:Clone()
		mesh.Name = "TripoHeroCarMesh"
		mesh.Transparency = 0
		mesh.Color = if isAI then primaryColor:Lerp(Color3.fromRGB(255, 255, 255), 0.35) else Color3.fromRGB(255, 255, 255)
		local raw = mesh.Size
		local longest = math.max(raw.X, raw.Y, raw.Z, 0.001)
		mesh.Size = raw * ((if avatarTemplate then avatarMesh.length else nil) or CarBuilder.CAR_MESH_LENGTH) / longest
		mesh.Parent = model
		local rotation = CarBuilder.CAR_MESH_ROTATION or guessMeshRotation(raw)
		if avatarTemplate then
			local o = avatarMesh.offset or { 0, 0.15, 0 }
			weldTo(mesh, bodyRoot, CFrame.new(o[1], o[2], o[3]) * CFrame.Angles(0, math.rad(avatarMesh.yaw or -90), 0))
		else
			weldTo(mesh, bodyRoot, (if body then CarBuilder.CAR_MESH_OFFSET_WHEELLESS else CarBuilder.CAR_MESH_OFFSET) * rotation)
		end
		model:SetAttribute("HasTripoMesh", true)
		model:SetAttribute("MeshRotation", if CarBuilder.CAR_MESH_ROTATION then "measured" else "guess")
	else
		buildFallbackBody(model, bodyRoot, primaryColor, accentColor)
		model:SetAttribute("HasTripoMesh", false)
	end

	-- Baked-wheel body: the procedural wheels stay hidden (the code path still turns them). Wheel-less body (or no
	-- mesh at all): the wheels show, as meshes when the wheel template loaded.
	local bakedWheels = template ~= nil and body == nil
	local wheelsVisible = not bakedWheels or CarBuilder.SHOW_WHEELS_WITH_MESH
	model:SetAttribute("WheelState", if bakedWheels then "baked" elseif haveWheels then "mesh" else "procedural")
	for i = 1, #CarConfig.WHEELS do
		buildWheel(model, hull, i, accentColor, wheelsVisible, if bakedWheels or not haveWheels then nil elseif i <= 2 then wheelFront else wheelRear)
	end

	-- Rear contact patches for drift sparks (hull-local, at road level under the rear wheels).
	local rearWheels: { { side: string, idx: number } } = { { side = "L", idx = 3 }, { side = "R", idx = 4 } }
	for _, rw in rearWheels do
		local w = CarConfig.WHEELS[rw.idx]
		local att = Instance.new("Attachment")
		att.Name = "DriftSpark" .. rw.side
		att.CFrame = CFrame.new(w[1], w[2] - CarConfig.WHEEL_RADIUS + 0.15, w[3] + 0.6) * CFrame.Angles(0, math.pi, 0)
		att.Parent = hull
	end

	-- Twin tailpipes and their flame nozzles (owner: the vehicle's exhaust looked bad). client/Vfx builds one layered flame
	-- per "FlameNozzle*" attachment (no rotation: the flame runs along +Z, backwards; FlameScale sizes it, two small flames
	-- side by side). They hang off BodyRoot so the flames ride the body's lean and hop like the pipes do.
	-- TODO(Studio): the pipe/nozzle spot is a guess on the rear of the v2 mesh; check it and nudge x/y/z.
	local pipeDark = Color3.fromRGB(42, 30, 34)
	for _, side in { "L", "R" } do
		local x = if side == "L" then -1.15 else 1.15
		local pipe = makePart("Tailpipe_" .. side, Enum.PartType.Cylinder, Vector3.new(0.9, 0.85, 0.85), Enum.Material.Metal, pipeDark, model)
		weldTo(pipe, bodyRoot, CFrame.new(x, 0.35, 5.4) * CFrame.Angles(0, math.pi / 2, 0)) -- cylinder axis X -> Z
		local nozzle = Instance.new("Attachment")
		nozzle.Name = "FlameNozzle" .. side
		nozzle.Position = Vector3.new(x, 0.35, 5.8)
		nozzle:SetAttribute("FlameScale", 0.55)
		nozzle.Parent = bodyRoot
	end

	-- Warm under-glow so the car reads on dark decks at phone size (the plane carries the same kind of light).
	local glowAtt = Instance.new("Attachment")
	glowAtt.Name = "UnderGlow"
	glowAtt.Position = Vector3.new(0, -1.2, 0)
	glowAtt.Parent = hull
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 196, 120)
	glow.Brightness = 0.9
	glow.Range = 12
	glow.Shadows = false
	glow.Parent = glowAtt

	if not isAI then
		local att = Instance.new("Attachment")
		att.Name = "DriveAttachment"
		att.Parent = hull
		-- Zero on the server copy on purpose: while the server holds the hull (correction escalation) the constraint
		-- pins it in place instead of flying it along a stale client velocity.
		local lv = Instance.new("LinearVelocity")
		lv.Name = "DriveVelocity"
		lv.Attachment0 = att
		lv.MaxForce = 1e7
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VectorVelocity = Vector3.zero
		lv.Parent = hull
		local ao = Instance.new("AlignOrientation")
		ao.Name = "DriveOrientation"
		ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		ao.Attachment0 = att
		ao.MaxTorque = 1e7
		ao.Responsiveness = 60
		ao.CFrame = spawnCF
		ao.Parent = hull
	else
		-- A seated bot driver (asynchronous: appears once its preset is built and the car is in the workspace).
		PilotSeat.attachBotPilot(model)
	end

	return model
end

-- For QA and the asset probe: did this server get the mesh?
function CarBuilder.meshState(): string
	if not tripoLoadAttempted then
		return "NOT_LOADED"
	end
	return if cachedTripoMesh then "mesh" else "FALLBACK"
end

-- Starts the car's four mesh loads at once on their own threads (hero car, both wheels, wheel-less body). createCar used
-- to fetch them one after another when the first car spawned, ~1 s on the first joiner's critical path; with the loads
-- already in flight it only waits for whatever has not arrived (each loader is single-flight). Returns at once.
function CarBuilder.prewarm()
	task.spawn(tryGetTripoCarTemplate)
	task.spawn(MeshTemplate.get, CarBuilder.WHEEL_FRONT_MODEL_ID, "car_wheel_front")
	task.spawn(MeshTemplate.get, CarBuilder.WHEEL_REAR_MODEL_ID, "car_wheel_rear")
	task.spawn(MeshTemplate.get, CarBuilder.HERO_CAR_BODY_MODEL_ID, "car_body")
end

return CarBuilder
