--!strict
-- World set pieces, server half (docs/REMARKABLE.md Batch 2 items 13, 21, 22 and 25). Visual set pieces run on the
-- clients; this module owns only what must be authoritative or shared:
-- * GALLEON CANNONS (item 13). The ISLAND-2 plan's modes.battle.launchers rows (names allow-listed in
--   shared/SetPieceRules.LAUNCHER_NAMES) are built into cannons under the map root (folder SetPieces, visible on every
--   ISLAND-2 load) and armed only while a water battle runs. A player's car that drives into a cradle is fired: the
--   server pre-announces the one landing (CarServer.expectLaunch: expectTeleport with the grace stretched to the ride)
--   and tells every client ("CannonFire": who, which cannon, when, the start frame). The rider's client flies the arc
--   (CarController.ride); every client plays the fuse, the BOOM, the recoil and the smoke (client/GalleonMoments).
--   Per-player cooldown; a spectator (BattleOut) is never fired; nothing here adds speed or touches lives, items or
--   the validator's bounds. If the rider's client never flies, the grace runs out and the validator's ordinary
--   correction puts the car on the announced landing.
--   The plank salute gun and the cannons' data ride on the folder's and models' attributes for the clients.
-- * LOST SQUEAKY DUCKS (item 22): server/DuckHunt, started from here on every load.
-- * RETIRED BOSSES (item 21): publishes each player's beaten bosses (player attribute BossesBeaten, "DINO,SNOW,...")
--   from the profile and, while the hub is loaded, keeps a template of every boss someone present has beaten in
--   ReplicatedStorage.SkyRallyRetiredBosses (clients clone their own into the hub; client/BossRetirement).
-- * MOON MONORAIL (item 25): nothing; it is a pure function of server time and RaceGoTime on every client.
-- QA (Studio): player attribute QACannon = "CrestCannon" | "DeckCannon" fires that cannon now in any ISLAND-2 car mode.
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("SetPieceRules"))
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local ArtSwapRules = require(Shared:WaitForChild("ArtSwapRules"))
-- Per group (systems audit v32 T0-2): the cannons (and the duck, server/DuckHunt) are armed per RaceScope scope, each
-- stepped in its own scope; CannonFire and the duck lines go to that scope's players only; the retired-boss templates
-- follow the hub scope alone (a group's start never says "the hub is gone").
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local SaveService = require(script.Parent:WaitForChild("SaveService"))
local DuckHunt = require(script.Parent:WaitForChild("DuckHunt"))
local WorldArt = require(script.Parent:WaitForChild("kit"):WaitForChild("WorldArt"))

local WorldSetPieces = {}

-- The race systems this module leans on, handed in by init.server.luau (FlightServer records, CarServer's car test,
-- vehicle and the one validator call it makes), so nothing here reaches into them on its own.
export type Deps = {
	records: () -> { [Player]: any },
	isCar: (model: Instance?) -> boolean,
	activeVehicle: () -> string,
	expectLaunch: (player: Player, landCF: CFrame, seconds: number) -> (),
}
local deps: Deps? = nil

WorldSetPieces.FOLDER = "SetPieces"
WorldSetPieces.TEMPLATES = "SkyRallyRetiredBosses"

local remote: RemoteEvent? = nil

type Armed = {
	launchers: { Rules.Launcher },
	book: Rules.Cooldowns,
	last: { [Player]: Vector3 },
	riding: { [Player]: number },
	water: boolean, -- armed for players (the water battle); QA shots work on any ISLAND-2 load
}
local slot = ModeScopeRules.slot("WorldSetPieces") :: ModeScopeRules.Slot<Armed>

local function log(fmt: string, ...: any)
	print("[SkyRally][SETPIECE] " .. string.format(fmt, ...))
end

local function ensureRemote(): RemoteEvent
	if remote and remote.Parent then
		return remote
	end
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local existing = (folder :: Instance):FindFirstChild("SetPieceEvent")
	if existing and existing:IsA("RemoteEvent") then
		remote = existing
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = "SetPieceEvent"
	r.Parent = folder
	remote = r
	return r
end

-- Everyone in the calling scope: every client on the single path (FireAllClients, as before); per group the players
-- seated in this race (the hub scope: the players on the plaza).
local function fireAll(kind: string, payload: { [string]: any })
	local r = ensureRemote()
	local to = ModeScopeRules.audience(Players:GetPlayers())
	if to == nil then
		r:FireAllClients(kind, payload)
		return
	end
	for _, p in to do
		r:FireClient(p, kind, payload)
	end
end

local function fireOne(player: Player, kind: string, payload: { [string]: any })
	ensureRemote():FireClient(player, kind, payload)
end

---------------------------------------------------------------------------------------------------- cannon models

local BRONZE = Color3.fromRGB(176, 120, 60)
local IRON = Color3.fromRGB(52, 50, 56)
local WOOD = Color3.fromRGB(122, 82, 50)
local WOOD_DARK = Color3.fromRGB(84, 56, 36)
local GOLD = Color3.fromRGB(240, 196, 80)

local function prop(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	-- Scenery only: never a wall, never ground (the car's probes ignore it), never a touch.
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

-- Sign art (art v3, props_v3 sign_post): two timber posts and a plank board replace the plain post. The mesh's plank board
-- (x -2.9..2.9, y 3.0..6.4, faces at z +0.25 / -0.23) is wider than the SignBoard, so the SignBoard stays as the invisible
-- carrier of the SurfaceGui: it moves to the board's middle (y 4.7) with its Back face (4.6 x 2.2) 0.02 in front of the +Z
-- plank face, and the text still lands on the planks. The mesh loads off the build path (LoadAsset yields); until it
-- arrives, or if it never does, the plain post and board show.
local SIGN_BOARD_Y = 4.7 -- the plank board's middle in the sign_post mesh
local SIGN_BOARD_Z = 0.12 -- SignBoard is 0.3 deep: its Back face lands at z 0.27, the plank face is at 0.25

local function seatSignArt(m: Model, signCF: CFrame, post: Part, board: Part)
	local tpl = WorldArt.world("sign_post")
	if not tpl or not post.Parent then
		return
	end
	local art = tpl:Clone()
	art.Name = "SignArt"
	art.CFrame = signCF * CFrame.new(ArtSwapRules.partCentre(ArtSwapRules.ASSETS.sign_post, 1, Vector3.zero))
	art.CanCollide = false
	art.CanQuery = false
	art.CanTouch = false
	art.Parent = m
	post:Destroy()
	board.CFrame = signCF * CFrame.new(0, SIGN_BOARD_Y, SIGN_BOARD_Z)
	board.Transparency = 1
end

-- A comically big cannon on a wooden carriage, its bore wide enough to swallow a car, and a plank sled for a cradle.
-- The barrel lives in a sub-model "Barrel" (pivot at the breech, LookVector = the axis) that the clients shiver and
-- recoil locally.
local function buildCannon(parent: Instance, l: Rules.Launcher, floor: number): Model
	local m = Instance.new("Model")
	m.Name = l.name
	local axis = l.axis
	local flatDir = Vector3.new(axis.X, 0, axis.Z).Unit
	local barrelCF = Rules.lookUp(l.breech, axis, Vector3.yAxis)
	local barrel = Instance.new("Model")
	barrel.Name = "Barrel"
	-- cylinder parts run along their X axis: turn the barrel frame so +X follows the axis (breech -> muzzle)
	local along = barrelCF * CFrame.Angles(0, math.rad(90), 0)
	local tube = prop("Tube", Enum.PartType.Cylinder, Vector3.new(l.length, 9.4, 9.4), along * CFrame.new(l.length / 2, 0, 0), BRONZE, Enum.Material.Metal, barrel)
	prop("Bore", Enum.PartType.Cylinder, Vector3.new(0.4, 7.2, 7.2), along * CFrame.new(l.length + 0.05, 0, 0), Color3.fromRGB(16, 12, 10), Enum.Material.SmoothPlastic, barrel)
	prop("MuzzleRing", Enum.PartType.Cylinder, Vector3.new(1.6, 11, 11), along * CFrame.new(l.length - 0.6, 0, 0), BRONZE, Enum.Material.Metal, barrel)
	prop("MidRing", Enum.PartType.Cylinder, Vector3.new(1.0, 10.2, 10.2), along * CFrame.new(l.length * 0.45, 0, 0), GOLD, Enum.Material.Metal, barrel)
	prop("BreechRing", Enum.PartType.Cylinder, Vector3.new(1.4, 10.6, 10.6), along * CFrame.new(0.6, 0, 0), BRONZE, Enum.Material.Metal, barrel)
	prop("Cascabel", Enum.PartType.Ball, Vector3.new(3.2, 3.2, 3.2), barrelCF * CFrame.new(0, 0, 2.2), BRONZE, Enum.Material.Metal, barrel)
	prop("Trunnion", Enum.PartType.Cylinder, Vector3.new(12.6, 2.0, 2.0), barrelCF * CFrame.new(0, 0, -l.length * 0.4), IRON, Enum.Material.Metal, barrel)
	-- the fuse: a short neon wick on the top of the breech (the clients light its sparks)
	local fuse = prop("Fuse", Enum.PartType.Block, Vector3.new(0.35, 1.4, 0.35), barrelCF * CFrame.new(0, 4.9, -1.2), Color3.fromRGB(255, 200, 90), Enum.Material.Neon, barrel)
	local fuseAt = Instance.new("Attachment")
	fuseAt.Name = "FuseTip"
	fuseAt.Position = Vector3.new(0, 0.7, 0)
	fuseAt.Parent = fuse
	barrel.PrimaryPart = tube
	barrel.WorldPivot = barrelCF
	barrel.Parent = m
	-- carriage: two cheeks under the trunnions, an axle and four solid wheels, standing on the floor
	local base = CFrame.lookAt(Vector3.new(l.breech.X, floor, l.breech.Z), Vector3.new(l.breech.X, floor, l.breech.Z) + flatDir)
	local mid = base * CFrame.new(0, 0, -l.length * 0.3)
	for side = -1, 1, 2 do
		prop("Cheek", Enum.PartType.Block, Vector3.new(1.4, 5.5, l.length * 0.75), mid * CFrame.new(side * 5.4, 2.75, 0), WOOD, Enum.Material.WoodPlanks, m)
		for _, z in { -l.length * 0.25, l.length * 0.25 } do
			prop("Wheel", Enum.PartType.Cylinder, Vector3.new(1.2, 4.6, 4.6), mid * CFrame.new(side * 6.8, 2.3, z), WOOD_DARK, Enum.Material.Wood, m)
		end
	end
	prop("Axle", Enum.PartType.Block, Vector3.new(14.8, 1.2, 1.2), mid * CFrame.new(0, 2.3, 0), IRON, Enum.Material.Metal, m)
	-- the cradle: a plank sled flush on the floor where the car loads, with gold "drive in" chevrons
	local cr = CFrame.lookAt(Vector3.new(l.cradle.X, floor, l.cradle.Z), Vector3.new(l.cradle.X, floor, l.cradle.Z) + flatDir)
	prop("Sled", Enum.PartType.Block, Vector3.new(8.5, 0.3, 11), cr * CFrame.new(0, 0.15, 0), WOOD, Enum.Material.WoodPlanks, m)
	for i = 0, 2 do
		prop("Chevron", Enum.PartType.Block, Vector3.new(4.2, 0.12, 0.9), cr * CFrame.new(-1.3, 0.34, 3.6 - i * 3.2) * CFrame.Angles(0, math.rad(35), 0), GOLD, Enum.Material.Neon, m)
		prop("Chevron", Enum.PartType.Block, Vector3.new(4.2, 0.12, 0.9), cr * CFrame.new(1.3, 0.34, 3.6 - i * 3.2) * CFrame.Angles(0, math.rad(-35), 0), GOLD, Enum.Material.Neon, m)
	end
	-- a little sign on a post: what this cannon is for
	local signCF = cr * CFrame.new(-6.5, 0, 2)
	local post = prop("SignPost", Enum.PartType.Block, Vector3.new(0.5, 6, 0.5), signCF * CFrame.new(0, 3, 0), WOOD_DARK, Enum.Material.Wood, m)
	local board = prop("SignBoard", Enum.PartType.Block, Vector3.new(4.6, 2.2, 0.3), signCF * CFrame.new(0, 5.6, 0), WOOD, Enum.Material.WoodPlanks, m)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.CanvasSize = Vector2.new(230, 110)
	gui.LightInfluence = 0.6
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 244, 214)
	label.Text = if l.name == "CrestCannon" then "ALL ABOARD!" else "ABANDON SHIP!"
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(40, 26, 18)
	stroke.Thickness = 3
	stroke.Parent = label
	task.spawn(seatSignArt, m, signCF, post, board)
	-- the launcher data the clients need (SetPieceRules.parseLauncher reads these)
	m:SetAttribute("Launcher", true)
	m:SetAttribute("Cradle", l.cradle)
	m:SetAttribute("Breech", l.breech)
	m:SetAttribute("Axis", l.axis)
	m:SetAttribute("Length", l.length)
	m:SetAttribute("Land", l.land)
	m:SetAttribute("LandLook", l.landLook)
	m:SetAttribute("Ground", l.ground)
	m:SetAttribute("Surface", l.surface)
	m.WorldPivot = base
	m.Parent = parent
	return m
end

---------------------------------------------------------------------------------------------------- firing

local function fire(player: Player, rec: any, l: Rules.Launcher, why: string)
	local a = slot:get()
	if not a then
		return
	end
	local now = os.clock()
	Rules.noteFire(a.book, player, now)
	a.riding[player] = now + Rules.rideTime() + 0.5
	local landCF = Rules.lookUp(l.land, l.landLook, Vector3.yAxis)
	if deps then
		deps.expectLaunch(player, landCF, Rules.graceSeconds())
	end
	local hull = rec.hull :: BasePart
	fireAll("CannonFire", {
		name = l.name,
		userId = player.UserId,
		at = workspace:GetServerTimeNow(),
		start = hull.CFrame,
	})
	log("cannon %s fired player=%s from=(%.0f,%.0f,%.0f) land=(%.0f,%.0f,%.0f) grace=%.1fs (%s)", l.name, player.Name, hull.Position.X,
		hull.Position.Y, hull.Position.Z, l.land.X, l.land.Y, l.land.Z, Rules.graceSeconds(), why)
end

local lastStep = os.clock()

local function stepLaunchers(a: Armed, now: number, dt: number)
	local d = deps
	if not d or not a.water or RaceAttr.here("BattleState") ~= "running" then
		return
	end
	for player, rec in d.records() do
		local hull = rec.hull
		if hull and hull.Parent and player.Parent and d.isCar(rec.plane) and player:GetAttribute("BattleOut") ~= true then
			local pos = hull.Position
			local prev = a.last[player]
			a.last[player] = pos
			local busy = a.riding[player]
			if prev and not (busy and now < busy) and Rules.canFire(a.book, player, now) then
				local vel = (pos - prev) / dt
				for _, l in a.launchers do
					if Rules.inCradle(l, pos, vel) then
						fire(player, rec, l, "cradle")
						break
					end
				end
			end
		end
	end
end

-- Builds the cannons for this load (ISLAND-2 only) and arms them in the water battle.
local function startLaunchers(root: Instance?, td: any, mode: string)
	slot:set(nil)
	if not root then
		return
	end
	local old = root:FindFirstChild(WorldSetPieces.FOLDER)
	if old then
		old:Destroy()
	end
	local modes = if type(td) == "table" then td.modes else nil
	local battle = if type(modes) == "table" then modes.battle else nil
	local rows = if type(battle) == "table" then battle.launchers else nil
	if type(rows) ~= "table" or #rows == 0 then
		return
	end
	local lastTide = 0
	if type(battle.tideSteps) == "table" then
		for _, s in battle.tideSteps do
			if type(s) == "table" and type(s.level) == "number" then
				lastTide = math.max(lastTide, s.level)
			end
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = WorldSetPieces.FOLDER
	local launchers: { Rules.Launcher } = {}
	for _, row in rows do
		local l = Rules.parseLauncher(row)
		if not l then
			log("launcher ignored: unknown or malformed (%s)", tostring(type(row) == "table" and row.name))
			continue
		end
		local ok, why = Rules.validateLauncher(l, lastTide)
		if not ok then
			log("launcher %s not armed: %s", l.name, tostring(why))
			continue
		end
		buildCannon(folder, l, if type(row.floor) == "number" then row.floor else l.cradle.Y - 1.9)
		table.insert(launchers, l)
	end
	local salute = battle.salute
	if type(salute) == "table" and typeof(salute.gun) == "Vector3" and typeof(salute.dir) == "Vector3" then
		folder:SetAttribute("SaluteGun", salute.gun)
		folder:SetAttribute("SaluteDir", salute.dir)
	end
	local plank = battle.plank
	if type(plank) == "table" and typeof(plank.lip) == "Vector3" and typeof(plank.dir) == "Vector3" then
		folder:SetAttribute("PlankLip", plank.lip)
		folder:SetAttribute("PlankDir", plank.dir)
		folder:SetAttribute("PlankWidth", if type(plank.width) == "number" then plank.width else 10)
	end
	folder.Parent = root
	local water = mode == "battle" and battle.kind == "water"
	slot:set({ launchers = launchers, book = {}, last = {}, riding = {}, water = water })
	log("cannons built=%d armed=%s track=%s mode=%s", #launchers, tostring(water), tostring(td.id), mode)
end

---------------------------------------------------------------------------------------------------- retired bosses

local templatesLoading: { [string]: boolean } = {}

local function templatesFolder(): Folder
	local f = ReplicatedStorage:FindFirstChild(WorldSetPieces.TEMPLATES)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = WorldSetPieces.TEMPLATES
	nf.Parent = ReplicatedStorage
	return nf
end

-- One retired boss template: the uploaded rigged model fitted to BossConfig.length, as BossBuilder fits it, anchored
-- scenery (no collision, no query), BossScale for the clip player. Loaded once per server, only when needed.
local function ensureTemplate(zone: string)
	local folder = templatesFolder()
	if folder:FindFirstChild(zone) or templatesLoading[zone] then
		return
	end
	local boss = BossConfig.forZone(zone)
	if not boss or not boss.model then
		return
	end
	templatesLoading[zone] = true
	task.spawn(function()
		local ok, res = pcall(function()
			return ModelBakes.load(boss.model :: number)
		end)
		if not ok or not res then
			log("retired boss %s model failed: %s", zone, tostring(res))
			return -- stays marked loading: no retry storm
		end
		local m = Instance.new("Model")
		m.Name = zone
		for _, d in (res :: Instance):GetDescendants() do
			if d:IsA("BasePart") then
				d.Parent = m
			end
		end
		res:Destroy()
		if #m:GetChildren() == 0 then
			return
		end
		local _, size = m:GetBoundingBox()
		local longest = math.max(size.X, size.Y, size.Z)
		if longest > 0 then
			m:ScaleTo(boss.length / longest * boss.modelScale)
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		m:SetAttribute("BossScale", m:GetScale())
		m:SetAttribute("BossZone", zone)
		m.Parent = folder
		templatesLoading[zone] = nil
		log("retired boss template %s ready", zone)
	end)
end

local function publishBosses(player: Player): { string }
	local ok, profile = pcall(SaveService.get, player)
	local list = Rules.bossesBeaten(if ok then profile else nil)
	local text = table.concat(list, ",")
	if player:GetAttribute("BossesBeaten") ~= text then
		player:SetAttribute("BossesBeaten", text)
	end
	return list
end

local inHub = false

local function refreshRetired()
	for _, p in Players:GetPlayers() do
		local list = publishBosses(p)
		if inHub then
			for _, zone in list do
				ensureTemplate(zone)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------- lifecycle

-- Called by the server's startMode after every load and replay (init.server.luau).
function WorldSetPieces.start(td: any, mode: string)
	local root = TrackRegistry.getRoot()
	local ok, err = pcall(function()
		startLaunchers(root, td, mode)
	end)
	if not ok then
		warn("[SkyRally][SETPIECE] cannons failed: " .. tostring(err))
	end
	local d = deps
	DuckHunt.start(root, td, mode, if d then d.activeVehicle() else nil, {
		records = function(): { [Player]: any }
			return if deps then (deps :: Deps).records() else {}
		end,
		notify = fireOne,
		broadcast = fireAll,
	})
	-- Only the hub scope's own load says where the hub stands; a group's race next to the live hub never does.
	if not ModeScopeRules.inGroup() then
		inHub = mode == "hub"
	end
	refreshRetired()
end

function WorldSetPieces.stop()
	slot:set(nil)
	DuckHunt.stop()
end

function WorldSetPieces.init(d: Deps)
	deps = d
	ensureRemote()
	SaveService.onLoaded(function(player: Player)
		publishBosses(player)
		if inHub then
			refreshRetired()
		end
	end)
	local function watch(player: Player)
		-- A boss race just finished: the beaten list may have grown (ready for the trip back to the hub).
		player:GetAttributeChangedSignal("FinishRank"):Connect(function()
			task.delay(0.5, function()
				if player.Parent then
					publishBosses(player)
				end
			end)
		end)
		if RunService:IsStudio() then
			player:GetAttributeChangedSignal("QACannon"):Connect(function()
				local name = player:GetAttribute("QACannon")
				ModeScopeRules.runFor(player, function()
					local dd = deps
					local rec = if dd then dd.records()[player] else nil
					local a = slot:get()
					if type(name) ~= "string" or name == "" or not rec or not a or not dd or not dd.isCar(rec.plane) then
						return
					end
					player:SetAttribute("QACannon", nil)
					for _, l in a.launchers do
						if l.name == name then
							fire(player, rec, l, "QA")
						end
					end
				end)
			end)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		slot:each(function(a: Armed)
			a.book[player] = nil
			a.last[player] = nil
			a.riding[player] = nil
		end)
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			local now = os.clock()
			local stepDt = math.max(now - lastStep, 1 / 60)
			lastStep = now
			slot:each(function(a: Armed)
				stepLaunchers(a, now, stepDt)
			end)
		end
	end)
end

return WorldSetPieces
