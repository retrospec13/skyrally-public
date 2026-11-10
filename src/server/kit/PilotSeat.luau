--!strict
-- Visible, seated pilots (owner, 2026-10-19: "the roblox character/avatar for the player will be visible inside of the
-- vehicles, so we need to account for that"). Before this the avatar rode welded inside the hull with every part at
-- Transparency 1, and bots carried a plain ball ("BotPilotHead") where a driver should be.
--
-- Players: FlightServer and CarServer call mountPlayer on every spawn, reset and hub vehicle exchange. The character
-- is scaled down (Model:ScaleTo) so the seated head sits just above the cockpit rim, its HumanoidRootPart is welded at
-- the vehicle's seat anchor, every part stays CanCollide/CanTouch/CanQuery false and Massless (the hull alone carries
-- mass and is the only thing the race code, the item rays and the camera ever hit), and Humanoid.PlatformStand keeps
-- the humanoid from fighting the weld. The character gets the attribute PilotSeated; client/PilotPose then plays the
-- default sit animation on the owning client, which replicates to everyone. Accessories that load late
-- (CharacterAppearanceLoaded, a cosmetic) are scaled to match as they arrive, and oversized back/waist/shoulder/front
-- pieces (wings, capes, swords) are hidden so they never poke metres out of the cockpit or cover the chase camera.
-- unmount puts the avatar back at its own scale; it runs when the vehicle goes away and no new one claims the seat.
--
-- Bots: the builders call attachBotPilot for every AI vehicle. A pilot is built once per preset from a
-- HumanoidDescription (Roblox-owned free catalog items only, plain skin tones; one preset per personality in
-- shared/BotPersonality) and cloned per bot, seated with the same anchor and scale, sit pose played on the server.
-- Nothing here runs per frame.
--
-- The seat anchor and scale come from the vehicle model's attributes SeatAnchor (CFrame, local to the seat part) and
-- PilotScale, which CarBuilder / PlaneBuilder set from their SEAT_ANCHOR / PILOT_SCALE constants, so a new mesh only
-- changes those two constants. The seat part is the car's BodyRoot (the driver leans, hops and spins with the body) or
-- the Hull.
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BotPersonality = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BotPersonality"))
local BotLookRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BotLookRules"))

local PilotSeat = {}

PilotSeat.SIT_ANIM_R15 = "rbxassetid://2506281703" -- Roblox default R15 sit
PilotSeat.SIT_ANIM_R6 = "rbxassetid://178130996" -- Roblox default R6 sit
PilotSeat.DEFAULT_ANCHOR = CFrame.new(0, 1.35, 0.2)
PilotSeat.DEFAULT_SCALE = 0.65
-- How long a destroyed vehicle's pilot waits for a new seat before it is put back at its own scale (a hub exchange
-- or a track switch re-seats within a frame or two).
PilotSeat.UNMOUNT_GRACE = 2

-- Accessory trim. Sizes are the largest handle edge at the avatar's own scale (an R15 avatar is ~5.5 studs tall).
local POKING_TYPES: { [string]: boolean } = { Back = true, Waist = true, Shoulder = true, Front = true }
PilotSeat.POKING_MAX = 2.4 -- back/waist/shoulder/front pieces above this hide (wings, capes, swords, big backpacks)
PilotSeat.ANY_MAX = 5 -- anything above this hides, hats included (a giant hat would fill the chase camera)

------------------------------------------------------------------------------------------------------------------------
-- Shared helpers

-- A bot pilot's Humanoid runs no state machine (no PlatformStand handling), so the engine keeps its torso
-- CanCollide; this group collides with nothing, which keeps every pilot part out of physics whatever a Humanoid sets.
PilotSeat.COLLISION_GROUP = "SkyRallyPilot"
local groupReady = false
local function pilotGroup(): string?
	if not groupReady then
		groupReady = true
		pcall(function()
			if not PhysicsService:IsCollisionGroupRegistered(PilotSeat.COLLISION_GROUP) then
				PhysicsService:RegisterCollisionGroup(PilotSeat.COLLISION_GROUP)
			end
			PhysicsService:CollisionGroupSetCollidable(PilotSeat.COLLISION_GROUP, "Default", false)
			PhysicsService:CollisionGroupSetCollidable(PilotSeat.COLLISION_GROUP, PilotSeat.COLLISION_GROUP, false)
		end)
	end
	local ok, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(PilotSeat.COLLISION_GROUP)
	end)
	return if ok and registered then PilotSeat.COLLISION_GROUP else nil
end

local function quiet(p: BasePart)
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	local group = pilotGroup()
	if group then
		p.CollisionGroup = group
	end
end

function PilotSeat.seatPartOf(vehicle: Model): BasePart?
	local body = vehicle:FindFirstChild("BodyRoot")
	if body and body:IsA("BasePart") then
		return body
	end
	local hull = vehicle:FindFirstChild("Hull")
	return if hull and hull:IsA("BasePart") then hull else nil
end

function PilotSeat.anchorOf(vehicle: Model): (CFrame, number)
	local a = vehicle:GetAttribute("SeatAnchor")
	local s = vehicle:GetAttribute("PilotScale")
	return (if typeof(a) == "CFrame" then a else PilotSeat.DEFAULT_ANCHOR), (if type(s) == "number" and s > 0 then s else PilotSeat.DEFAULT_SCALE)
end

local function scalePos(cf: CFrame, k: number): CFrame
	return CFrame.new(cf.Position * k) * cf.Rotation
end

-- Scales one accessory by k the way Model:ScaleTo would have (handle, mesh, attachments, and the side of its weld that
-- is in handle space). Used for accessories that arrive after the character was scaled.
local function scaleAccessory(acc: Accessory, k: number)
	local handle = acc:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end
	handle.Size *= k
	for _, d in handle:GetDescendants() do
		if d:IsA("SpecialMesh") then
			d.Scale *= k
			d.Offset *= k
		elseif d:IsA("Attachment") and d.Parent == handle then
			d.Position *= k
		elseif d:IsA("JointInstance") then
			if d.Part0 == handle then
				d.C0 = scalePos(d.C0, k)
			elseif d.Part1 == handle then
				d.C1 = scalePos(d.C1, k)
			end
		end
	end
end

-- Largest handle edge at unit (own) scale. `applied` = the scale factor already on the handle.
local function unitSize(acc: Accessory, applied: number): number
	local handle = acc:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return 0
	end
	local s = handle.Size
	return math.max(s.X, s.Y, s.Z) / math.max(applied, 0.01)
end

local function accessoryType(acc: Accessory): string
	local ok, t = pcall(function()
		return acc.AccessoryType.Name
	end)
	return if ok and type(t) == "string" then t else "Unknown"
end

local function setHidden(acc: Accessory, hidden: boolean)
	for _, d in acc:GetDescendants() do
		if d:IsA("BasePart") then
			if hidden then
				if d:GetAttribute("PilotHiddenFrom") == nil then
					d:SetAttribute("PilotHiddenFrom", d.Transparency)
				end
				d.Transparency = 1
			else
				local was = d:GetAttribute("PilotHiddenFrom")
				if type(was) == "number" then
					d.Transparency = was
				end
				d:SetAttribute("PilotHiddenFrom", nil)
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Light") or d:IsA("Trail") or d:IsA("Beam") then
			if hidden then
				if d:GetAttribute("PilotHiddenFrom") == nil then
					d:SetAttribute("PilotHiddenFrom", (d :: any).Enabled)
				end
				(d :: any).Enabled = false
			else
				local was = d:GetAttribute("PilotHiddenFrom")
				if type(was) == "boolean" then
					(d :: any).Enabled = was
				end
				d:SetAttribute("PilotHiddenFrom", nil)
			end
		end
	end
	acc:SetAttribute("PilotHidden", if hidden then true else nil)
end

local function trimAccessory(acc: Accessory, applied: number)
	local size = unitSize(acc, applied)
	local hide = size > PilotSeat.ANY_MAX or (POKING_TYPES[accessoryType(acc)] == true and size > PilotSeat.POKING_MAX)
	if hide and acc:GetAttribute("PilotHidden") ~= true then
		setHidden(acc, true)
	end
end

local function weldAt(hrp: BasePart, seatPart: BasePart, anchor: CFrame): Weld
	local old = hrp:FindFirstChild("PilotWeld")
	if old then
		old:Destroy()
	end
	hrp.Anchored = false
	local w = Instance.new("Weld")
	w.Name = "PilotWeld"
	w.Part0 = seatPart
	w.Part1 = hrp
	w.C0 = anchor
	w.C1 = CFrame.new()
	w.Parent = hrp
	return w
end

------------------------------------------------------------------------------------------------------------------------
-- Players

type Seat = { vehicle: Model, scale: number, conns: { RBXScriptConnection } }
local seats: { [Model]: Seat } = {}

local function dropConns(seat: Seat)
	for _, c in seat.conns do
		c:Disconnect()
	end
	table.clear(seat.conns)
end

local function onAccessory(character: Model, acc: Accessory)
	-- Deferred: the Humanoid builds the AccessoryWeld as the accessory is parented; scaling after it exists (or before
	-- it is built from the already scaled attachments) gives the same result.
	task.defer(function()
		local seat = seats[character]
		if not seat or acc.Parent ~= character then
			return
		end
		local applied = acc:GetAttribute("PilotScaled")
		if type(applied) ~= "number" then
			local base = character:GetAttribute("PilotBaseScale")
			local from = if type(base) == "number" then base else 1
			scaleAccessory(acc, seat.scale / from)
			acc:SetAttribute("PilotScaled", seat.scale)
		end
		for _, d in acc:GetDescendants() do
			if d:IsA("BasePart") then
				quiet(d)
			end
		end
		trimAccessory(acc, seat.scale)
	end)
end

-- Puts the character back at its own scale, standing, with every hidden accessory shown again.
function PilotSeat.unmount(character: Model)
	local seat = seats[character]
	if seat then
		dropConns(seat)
		seats[character] = nil
	end
	if not character.Parent then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local weld = if hrp then hrp:FindFirstChild("PilotWeld") else nil
	if weld then
		weld:Destroy()
	end
	local base = character:GetAttribute("PilotBaseScale")
	if type(base) == "number" and math.abs(character:GetScale() - base) > 1e-3 then
		character:ScaleTo(base)
	end
	for _, acc in character:GetChildren() do
		if acc:IsA("Accessory") then
			acc:SetAttribute("PilotScaled", nil)
			if acc:GetAttribute("PilotHidden") == true then
				setHidden(acc, false)
			end
		end
	end
	-- Back to a normal walking avatar (the Humanoid manages CanCollide on its own body parts).
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Default"
			d.CanTouch = true
			d.CanQuery = true
			d.Massless = false
		end
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer -- on foot: the default name tag again
	end
	character:SetAttribute("PilotSeated", false)
	character:SetAttribute("PilotBaseScale", nil)
end

-- Seats a player's character in a vehicle (any VehicleType). Safe to call again for the same or another vehicle.
function PilotSeat.mountPlayer(character: Model, vehicle: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = character:WaitForChild("HumanoidRootPart", 3) :: BasePart?
	end
	local seatPart = PilotSeat.seatPartOf(vehicle)
	if not hrp or not seatPart or not character.Parent then
		return
	end
	local anchor, scale = PilotSeat.anchorOf(vehicle)
	local prev = seats[character]
	if prev then
		dropConns(prev)
	end
	-- Old builds hung the weld on the hull; never leave two welds pulling at one root.
	local legacy = seatPart:FindFirstChild("PilotWeld")
	if legacy then
		legacy:Destroy()
	end
	local stale = hrp:FindFirstChild("PilotWeld")
	if stale then
		stale:Destroy()
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:UnequipTools()
		hum.PlatformStand = true
		hum.AutoRotate = false
		-- The Roblox name tag rides the scaled head and bobbed with the sit pose; client/RacerView draws the racer's name
		-- instead (near only, semi-transparent, adorned to the hull).
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	-- Scale before the weld: ScaleTo moves parts about the pivot, and a welded root would drag the vehicle with it.
	if character:GetAttribute("PilotBaseScale") == nil then
		character:SetAttribute("PilotBaseScale", character:GetScale())
	end
	if math.abs(character:GetScale() - scale) > 1e-3 then
		character:ScaleTo(scale)
	end
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			quiet(d)
		end
	end
	for _, acc in character:GetChildren() do
		if acc:IsA("Accessory") then
			acc:SetAttribute("PilotScaled", scale)
			trimAccessory(acc, scale)
		end
	end

	weldAt(hrp, seatPart, anchor)
	character:SetAttribute("PilotSeated", true)

	local seat: Seat = { vehicle = vehicle, scale = scale, conns = {} }
	seats[character] = seat
	table.insert(seat.conns, character.DescendantAdded:Connect(function(d: Instance)
		if d:IsA("BasePart") then
			quiet(d)
		end
	end))
	table.insert(seat.conns, character.ChildAdded:Connect(function(c: Instance)
		if c:IsA("Accessory") then
			onAccessory(character, c)
		end
	end))
	table.insert(seat.conns, character.Destroying:Connect(function()
		local s = seats[character]
		if s then
			dropConns(s)
			seats[character] = nil
		end
	end))
	table.insert(seat.conns, vehicle.Destroying:Connect(function()
		task.delay(PilotSeat.UNMOUNT_GRACE, function()
			local s = seats[character]
			if s and s.vehicle == vehicle then
				PilotSeat.unmount(character)
			end
		end)
	end))
end

function PilotSeat.isSeated(character: Model): boolean
	return seats[character] ~= nil
end

------------------------------------------------------------------------------------------------------------------------
-- Bot pilots

export type Preset = {
	skin: Color3,
	shirt: number?,
	pants: number?,
	hat: number?,
	hair: number?,
}

-- Roblox-owned, free, for-sale catalog items (MarketplaceService:GetProductInfo checked 2026-10-19: Creator Roblox,
-- PriceInRobux 0, IsForSale true). Classic shirts/pants and rigid hats/hair only (no layered clothing to wrap).
PilotSeat.PRESETS = {
	-- Ace Aero: red cap, guitar tee with a black jacket, black jeans
	showboat = { skin = Color3.fromRGB(234, 184, 146), hat = 48474313, shirt = 4047884046, pants = 382537569 },
	-- Blaze Wing: long red hair, blue and black motorcycle shirt, black jeans
	hothead = { skin = Color3.fromRGB(255, 204, 153), hair = 2956239660, shirt = 144076358, pants = 382537569 },
	-- Nova Sky: Roblox baseball cap, green jersey, dark green jeans
	sunny = { skin = Color3.fromRGB(204, 142, 105), hat = 607702162, shirt = 382538059, pants = 144076760 },
	-- Zephyr Dash: Down to Earth hair, denim jacket with white hoodie, ripped skater pants
	chill = { skin = Color3.fromRGB(124, 92, 70), hat = 1772336109, shirt = 398633584, pants = 398635338 },
	-- Indigo Comet: true blue hair, grey striped shirt with denim jacket, black jeans
	dreamer = { skin = Color3.fromRGB(175, 148, 131), hair = 451221329, shirt = 144076436, pants = 382537569 },
	-- Rosa Glide: brown charmer hair, denim jacket with white hoodie, dark green jeans
	polite = { skin = Color3.fromRGB(160, 95, 53), hair = 376548738, shirt = 398633584, pants = 144076760 },
	-- Sunny Rotor: Pal hair, green jersey, ripped skater pants
	rookie = { skin = Color3.fromRGB(245, 205, 48), hair = 63690008, shirt = 382538059, pants = 398635338 },
} :: { [string]: Preset }

-- (economy v3 phase 4) A disguised bot's pilot is a random outfit (shared/BotLookRules, the same catalog items as the
-- presets above) in a random skin tone, named by the vehicle's PilotOutfit / PilotSkin attributes; its template key is
-- the outfit key, built once and reused.
-- "AI_Ace_Aero" (the builders' bot model names) -> "Ace Aero" -> personality key.
function PilotSeat.presetKeyFor(vehicleName: string): string
	local display = string.gsub(string.gsub(vehicleName, "^AI_", ""), "_", " ")
	local key = BotPersonality.forName(display)
	if PilotSeat.PRESETS[key] then
		return key
	end
	return BotPersonality.DEFAULT
end

-- A random-outfit key (BotLookRules.outfitKey) as a Preset; nil for anything else. The skin tone is applied per pilot.
function PilotSeat.outfitPreset(key: string): Preset?
	local o = BotLookRules.parseOutfit(key)
	if not o then
		return nil
	end
	return { skin = Color3.fromRGB(234, 184, 146), hat = o.hat, hair = o.hair, shirt = o.shirt, pants = o.pants }
end

local templates: { [string]: Model } = {}
local built: { [string]: boolean } = {} -- tried once (a failed build stays nil: the bot races without a pilot)
local loading: { [string]: boolean } = {}

local function describe(p: Preset): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	for _, prop in { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" } do
		(d :: any)[prop] = p.skin
	end
	if p.shirt then
		d.Shirt = p.shirt
	end
	if p.pants then
		d.Pants = p.pants
	end
	if p.hat then
		d.HatAccessory = tostring(p.hat)
	end
	if p.hair then
		d.HairAccessory = tostring(p.hair)
	end
	return d
end

-- One unscaled pilot model per preset, built on first use (CreateHumanoidModelFromDescription yields while the
-- catalog items load). A failed load falls back to plain skin tones; false means even that failed.
local function templateFor(key: string): Model?
	while loading[key] do
		task.wait()
	end
	if built[key] then
		return templates[key]
	end
	loading[key] = true
	local preset = PilotSeat.PRESETS[key] or PilotSeat.outfitPreset(key) or PilotSeat.PRESETS[BotPersonality.DEFAULT]
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(describe(preset), Enum.HumanoidRigType.R15)
	end)
	if not ok then
		warn(string.format("[SkyRally][PILOT] preset=%s catalog load failed (%s); plain body colours", key, tostring(model)))
		ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(describe({ skin = preset.skin }), Enum.HumanoidRigType.R15)
		end)
	end
	if ok and model then
		local m = model :: Model
		m.Name = "Pilot"
		for _, d in m:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				quiet(d)
				d.Anchored = false
			end
		end
		local hum = m:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			hum.BreakJointsOnDeath = false
			hum.RequiresNeck = false
			hum.PlatformStand = true
			hum.EvaluateStateMachine = false -- a passenger: no state machine work on the server
			if not hum:FindFirstChildOfClass("Animator") then
				Instance.new("Animator").Parent = hum
			end
		end
		for _, acc in m:GetChildren() do
			if acc:IsA("Accessory") then
				trimAccessory(acc, 1)
			end
		end
		templates[key] = m
	else
		warn(string.format("[SkyRally][PILOT] preset=%s pilot build failed (%s)", key, tostring(model)))
	end
	built[key] = true
	loading[key] = false
	return templates[key]
end

-- Builds every preset in the background (server start), so the first race's bots are seated at once.
function PilotSeat.preload()
	for key in PilotSeat.PRESETS do
		task.spawn(templateFor, key)
	end
end

local sitAnim: Animation? = nil

-- Seats a pilot in an AI vehicle. Asynchronous: the builder returns at once and the pilot appears when its preset is
-- ready and the vehicle is in the workspace (the server Animator plays only in the DataModel).
function PilotSeat.attachBotPilot(vehicle: Model, presetKey: string?)
	-- deferred: the caller (AIRacers / BattleBots) writes PilotOutfit / PilotSkin on the model right after the builder returns
	task.defer(function()
		local outfit = vehicle:GetAttribute("PilotOutfit")
		local key = presetKey or (if type(outfit) == "string" and PilotSeat.outfitPreset(outfit) then outfit else PilotSeat.presetKeyFor(vehicle.Name))
		local template = templateFor(key)
		if not template then
			return
		end
		local t0 = os.clock()
		while not vehicle:IsDescendantOf(workspace) do
			if os.clock() - t0 > 10 or (vehicle.Parent == nil and os.clock() - t0 > 2) then
				return
			end
			task.wait(0.1)
		end
		local seatPart = PilotSeat.seatPartOf(vehicle)
		if not seatPart or vehicle:FindFirstChild("Pilot") then
			return
		end
		local anchor, scale = PilotSeat.anchorOf(vehicle)
		local pilot = template:Clone()
		local skin = vehicle:GetAttribute("PilotSkin")
		if typeof(skin) == "Color3" then
			-- a random-outfit bot's own skin tone over the template's (the body parts only; accessories keep their colours)
			for _, part in pilot:GetChildren() do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					part.Color = skin
				end
			end
			-- and the rig's BodyColors, which the Humanoid may re-apply over the parts once the pilot is in the workspace
			local bc = pilot:FindFirstChildOfClass("BodyColors")
			if bc then
				for _, prop in { "HeadColor3", "TorsoColor3", "LeftArmColor3", "RightArmColor3", "LeftLegColor3", "RightLegColor3" } do
					(bc :: any)[prop] = skin
				end
			end
		end
		pilot:ScaleTo(scale)
		local hrp = pilot:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			pilot:Destroy()
			return
		end
		pilot:PivotTo(seatPart.CFrame * anchor)
		weldAt(hrp, seatPart, anchor)
		pilot:SetAttribute("PilotPreset", key)
		pilot.Parent = vehicle
		local hum = pilot:FindFirstChildOfClass("Humanoid")
		local animator = if hum then hum:FindFirstChildOfClass("Animator") else nil
		if animator then
			if not sitAnim then
				local a = Instance.new("Animation")
				a.AnimationId = PilotSeat.SIT_ANIM_R15
				sitAnim = a
			end
			local ok, track = pcall(function()
				return animator:LoadAnimation(sitAnim :: Animation)
			end)
			if ok and track then
				track.Priority = Enum.AnimationPriority.Action
				track.Looped = true
				track:Play(0)
			end
		end
	end)
end

return PilotSeat
