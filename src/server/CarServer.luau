--!strict
-- Server side of the launch car (PLAN L2, TEST_LIST_LAUNCH L05). Cars ride the plane's race contracts unchanged:
-- - The car is a Model in workspace.Planes (kept as the race code's vehicle folder name) named "Car_<player>" with a
--   PrimaryPart "Hull", and its record is a FlightServer.PlayerFlightRecord in FlightServer.records (plane = the car
--   model). RaceManager's checkpoints/laps/finish, ItemService/ItemEffects positions and the Vfx rigs all read
--   records and Hulls, so they work for cars with no change. The "Car_" prefix keeps FlightController (which binds
--   "Plane_<player>") from flying it.
-- - install() wraps FlightServer.spawnOrResetPlane: when the active track's vehicle is "car" (TrackRegistry def.vehicle,
--   root attribute Vehicle, or the QA override workspace.ForceVehicle) every spawn/reset path builds a car instead
--   (FlightServer's PlayerAdded spawn and RaceManager.resetRaceForAll both call through the module table).
-- - Respawn reuses the plane remotes: the client fires FlightStateRemote "RequestRespawn"; for a car this module
--   answers through FlightServer.respawnAtLastCheckpoint (RaceEventRemote "CheckpointRespawn" with RaceManager's last
--   checkpoint frame), so the server picks where the car comes back.
-- - Server authority over position: the owning client simulates (network ownership, as for the plane) and the server
--   checks every replicated Hull position against CarConfig's speed bounds (CarConfig.observe). An impossible move is
--   corrected: FlightStateRemote "RequestCorrection" puts the client back on the last valid frame and the line
--   "[SkyRally][CAR] correction ..." is logged; a client that keeps ignoring corrections loses the hull to the
--   server for CarConfig.ESCALATE_HOLD seconds.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
-- Economy v3 phase 2b: a car's respawn request runs in its RaceInstance's scope (its track, its mode); a plain call
-- while RaceFlowRules.PER_GROUP is false.
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local RemoteGuardRules = require(Shared:WaitForChild("RemoteGuardRules")) -- T1-9: finite numbers, enums, rate limit
local RespawnRules = require(Shared:WaitForChild("RespawnRules")) -- manual respawn floor (trap audit G5)
local FlightServer = require(script.Parent.FlightServer)
local CarBuilder = require(script.Parent.kit.CarBuilder)
local AvatarSelect = require(script.Parent.AvatarSelect) -- economy v3 phase 6: the player's car avatar
local LiveryPaint = require(script.Parent.kit.LiveryPaint) -- Garage car livery, painted as the car is built
local RacerPaint = require(script.Parent.kit.RacerPaint)
local PilotSeat = require(script.Parent.kit.PilotSeat)
local PlaneGuardRules = require(Shared:WaitForChild("PlaneGuardRules")) -- plane displacement limits (L30, L53)

local CarServer = {}

type Record = FlightServer.PlayerFlightRecord

type PlayerState = {
	validator: CarConfig.Validator,
	lastValidCF: CFrame,
	corrections: { number }, -- os.clock() of recent corrections (escalation window)
	lastRespawnRequest: number,
	held: boolean, -- server holds the hull (escalation)
	trusted: boolean, -- false from a correction until the client is back on a validated position
	isPlane: boolean, -- the validator carries the plane's limits (rebuilt when the vehicle type changes)
}

local CAR_PALETTE = {
	{ primary = Color3.fromRGB(110, 62, 102), accent = Color3.fromRGB(228, 172, 48) }, -- approved 02_car plum + brass
	{ primary = Color3.fromRGB(45, 185, 255), accent = Color3.fromRGB(255, 255, 255) },
	{ primary = Color3.fromRGB(235, 55, 55), accent = Color3.fromRGB(255, 215, 45) },
	{ primary = Color3.fromRGB(255, 135, 35), accent = Color3.fromRGB(255, 245, 160) },
}

CarServer.states = {} :: { [Player]: PlayerState }
CarServer.slots = {} :: { [Player]: number }
CarServer.installed = false
CarServer.corrections = 0 -- total this server (QA readout)

local flightStateRemote: RemoteEvent? = nil
local raceEventRemote: RemoteEvent? = nil
local originalSpawn: ((Player, number?) -> Record)? = nil
local lastVehicle = ""

local function v3s(v: Vector3): string
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

-- Which vehicle the active track uses. QA override first, then the registered def (server), then the root attribute.
function CarServer.activeVehicle(): string
	local forced = workspace:GetAttribute("ForceVehicle")
	if forced == "car" or forced == "plane" then
		return forced
	end
	local def = TrackRegistry.getDef()
	if def and type(def.vehicle) == "string" and def.vehicle ~= "" then
		return def.vehicle
	end
	local root = TrackRegistry.getRoot()
	local attr = if root then root:GetAttribute("Vehicle") else nil
	if type(attr) == "string" and attr ~= "" then
		return attr
	end
	return "plane"
end

function CarServer.isCar(model: Instance?): boolean
	return model ~= nil and model:GetAttribute("VehicleType") == "car"
end

local function ensureRemote(folder: Instance, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end

-- Same names FlightServer.init creates or reuses, so the init order between the two does not matter.
local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	flightStateRemote = ensureRemote(folder :: Instance, "FlightStateRemote")
	raceEventRemote = ensureRemote(folder :: Instance, "RaceEventRemote")
end

local function getVehiclesFolder(): Folder
	local existing = workspace:FindFirstChild("Planes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Planes"
	f.Parent = workspace
	return f
end

-- A plane's position is checked like a car's (L30, L53): the owning client simulates it, and RaceManager credits what
-- the server's copy of the hull says. The validator is built with the limits of whatever the record holds now.
local function recordIsPlane(player: Player): boolean
	local rec = FlightServer.records[player]
	return rec ~= nil and not CarServer.isCar(rec.plane)
end

local function stateFor(player: Player, cf: CFrame): PlayerState
	local isPlane = recordIsPlane(player)
	local st = CarServer.states[player]
	if st and st.isPlane ~= isPlane then
		-- Plane <-> car on a map change: the old budgets are the wrong vehicle's.
		st.validator = CarConfig.newValidator(if isPlane then PlaneGuardRules.limits() else nil)
		st.isPlane = isPlane
		st.lastValidCF = cf
		st.held = false
		table.clear(st.corrections)
	end
	if not st then
		st = {
			validator = CarConfig.newValidator(if isPlane then PlaneGuardRules.limits() else nil),
			lastValidCF = cf,
			corrections = {},
			lastRespawnRequest = 0,
			held = false,
			trusted = true,
			isPlane = isPlane,
		}
		CarServer.states[player] = st
	end
	return st
end

-- A correction does not move the server's copy of a client-owned hull: until the client applies it (one round trip,
-- or the whole grace window for a client that ignores it) the server still sees the impossible position, and
-- RaceManager reads rec.hull.Position for checkpoints and the finish. The flag (module call and the car attribute
-- PositionTrusted, which RaceManager can read without requiring this module) says when that position is not to be
-- credited.
local function setTrusted(rec: Record, st: PlayerState, trusted: boolean)
	st.trusted = trusted
	if rec.plane and rec.plane:GetAttribute("PositionTrusted") ~= trusted then
		rec.plane:SetAttribute("PositionTrusted", trusted)
	end
end

-- True unless the player's car is between a displacement correction and its next validated position.
function CarServer.isTrusted(player: Player): boolean
	local st = CarServer.states[player]
	return st == nil or st.trusted
end

-- Any server-issued teleport goes through here so the validator accepts the jump (spawn, reset, respawn, correction,
-- and later battle-overlay or mode teleports).
function CarServer.expectTeleport(player: Player, cf: CFrame)
	local st = stateFor(player, cf)
	st.lastValidCF = cf
	local p = cf.Position
	CarConfig.expectTeleport(st.validator, p.X, p.Y, p.Z, os.clock())
end

-- REMARKABLE item 13 (server/WorldSetPieces, the galleon cannons): ONE pre-announced landing per shot. Exactly
-- expectTeleport, with the grace window stretched to the ride (load, fuse, flight: SetPieceRules.graceSeconds, never
-- past LAUNCH_GRACE_MAX) so the client's scripted arc is not corrected mid-air. The bounds are unchanged: until the car
-- arrives within TELEPORT_GRACE_RADIUS of the landing nothing it reports is accepted as valid, and the last valid
-- frame is the landing itself.
local LAUNCH_GRACE_MAX = 3.6
function CarServer.expectLaunch(player: Player, landCF: CFrame, seconds: number)
	CarServer.expectTeleport(player, landCF)
	local st = CarServer.states[player]
	if st then
		st.validator.graceUntil = os.clock() + math.clamp(seconds, CarConfig.TELEPORT_GRACE_TIME, LAUNCH_GRACE_MAX)
	end
end

-- The driver rides visible and seated, like the plane's pilot (server/kit/PilotSeat): the avatar is scaled to
-- CarBuilder.PILOT_SCALE and welded to the car's BodyRoot at CarBuilder.SEAT_ANCHOR, so it leans, hops and trick-spins
-- with the body. FlightServer's CharacterAdded handler re-seats a respawned character in the car through the same call.
local function mountCharacter(character: Model, car: Model)
	PilotSeat.mountPlayer(character, car)
end

-- Car twin of FlightServer.spawnOrResetPlane: same record shape, same player attributes, same start grid.
function CarServer.spawnOrResetCar(player: Player, slotIndex: number?): Record
	local folder = getVehiclesFolder()
	local idx = slotIndex or 1
	CarServer.slots[player] = idx
	local palette = CAR_PALETTE[((idx - 1) % #CAR_PALETTE) + 1]
	local startCF = FlightServer.getStartCFrame(idx)

	local existing = FlightServer.records[player]
	local car: Model
	local hull: BasePart
	-- Phase 6: a car built with another avatar than the current pick is rebuilt (the pick applies at the next spawn).
	local avatarKey = AvatarSelect.forPlayer(player, "car")
	player:SetAttribute("AvatarKey", avatarKey)
	local sameAvatar = if existing and existing.plane then existing.plane:GetAttribute("AvatarKey") == avatarKey else false
	if existing and CarServer.isCar(existing.plane) and existing.plane.Parent and existing.hull and existing.hull.Parent and sameAvatar then
		car = existing.plane
		hull = existing.hull
		hull.AssemblyLinearVelocity = Vector3.zero
		hull.AssemblyAngularVelocity = Vector3.zero
		hull.CFrame = startCF
		car:SetAttribute("SpawnCFrame", startCF)
		car:SetAttribute("BoostState", "None")
		car:SetAttribute("Speed", 0)
	else
		-- Track switched plane -> car: the old plane goes, the car takes its record.
		if existing and existing.plane and existing.plane.Parent then
			existing.plane:Destroy()
		end
		car = CarBuilder.createCar("Car_" .. player.Name, palette.primary, palette.accent, startCF, false, avatarKey)
		car:SetAttribute("OwnerUserId", player.UserId)
		car:SetAttribute("OwnerName", player.Name)
		RacerPaint.paintPlayer(player, car, idx)
		car.Parent = folder
		hull = car.PrimaryPart :: BasePart
	end

	pcall(function()
		hull:SetNetworkOwner(player)
	end)

	local prevOrbs = if existing then existing.orbs else ((player:GetAttribute("Orbs") :: number?) or 0)
	local rec: Record = {
		player = player,
		plane = car,
		hull = hull,
		spawnTime = os.clock(),
		lastCheckpointIdx = 1,
		lastCheckpointCF = startCF,
		station = 0,
		lap = 1,
		speed = 0,
		finished = false,
		finishTime = 0,
		finishRank = 0,
		orbs = prevOrbs,
		ftueCleared = false,
		passedCheckpoints = { [1] = true },
	}
	FlightServer.records[player] = rec
	local st = stateFor(player, startCF)
	st.held = false
	table.clear(st.corrections)
	setTrusted(rec, st, true)
	CarServer.expectTeleport(player, startCF)

	-- MountedInPlane stays true: SelfTest and the HUD read it as "mounted in the race vehicle".
	player:SetAttribute("MountedInPlane", true)
	player:SetAttribute("MountedInCar", true)
	player:SetAttribute("VehicleType", "car")
	player:SetAttribute("PlaneName", car.Name)
	player:SetAttribute("Lap", 1)
	player:SetAttribute("Checkpoint", 1)
	player:SetAttribute("Station", 0)
	player:SetAttribute("Rank", 1)
	player:SetAttribute("Speed", 0)
	player:SetAttribute("Orbs", prevOrbs)
	player:SetAttribute("RaceFinished", false)
	player:SetAttribute("FTUECleared", false)

	if player.Character then
		mountCharacter(player.Character, car)
		pcall(function()
			hull:SetNetworkOwner(player)
		end)
	end

	if raceEventRemote then
		raceEventRemote:FireClient(player, "CarMounted", {
			carName = car.Name,
			startCFrame = startCF,
			trackLength = select(2, SplineUtils.loadWaypoints()),
		})
	end
	print(string.format("[SkyRally][CAR] spawn player=%s slot=%d car=%s mesh=%s at=%s", player.Name, idx, car.Name, tostring(car:GetAttribute("HasTripoMesh")), v3s(startCF.Position)))
	return rec
end

-- Wraps FlightServer.spawnOrResetPlane once. Callers keep calling FlightServer; the vehicle is decided here.
function CarServer.install()
	if CarServer.installed then
		return
	end
	CarServer.installed = true
	local original = FlightServer.spawnOrResetPlane
	originalSpawn = original
	FlightServer.spawnOrResetPlane = function(player: Player, slotIndex: number?): Record
		if CarServer.activeVehicle() == "car" then
			return CarServer.spawnOrResetCar(player, slotIndex)
		end
		local rec = FlightServer.records[player]
		if rec and CarServer.isCar(rec.plane) then
			-- Track switched car -> plane: drop the car so the plane path builds a fresh plane.
			if rec.plane.Parent then
				rec.plane:Destroy()
			end
			FlightServer.records[player] = nil
			player:SetAttribute("MountedInCar", false)
		end
		player:SetAttribute("VehicleType", "plane")
		CarServer.states[player] = nil
		return original(player, slotIndex)
	end
end

local function correct(player: Player, rec: Record, st: PlayerState, dist: number, allowed: number, dt: number)
	local now = os.clock()
	local pos = rec.hull.Position
	CarServer.corrections += 1
	setTrusted(rec, st, false)
	table.insert(st.corrections, now)
	while #st.corrections > 0 and now - st.corrections[1] > CarConfig.ESCALATE_WINDOW do
		table.remove(st.corrections, 1)
	end
	print(string.format(
		"[SkyRally][CAR] correction player=%s dist=%.1f allowed=%.1f dt=%.3f from=%s to=%s count=%d",
		player.Name,
		dist,
		allowed,
		dt,
		v3s(pos),
		v3s(st.lastValidCF.Position),
		#st.corrections
	))
	CarServer.expectTeleport(player, st.lastValidCF)
	if flightStateRemote then
		flightStateRemote:FireClient(player, "RequestCorrection", {
			cframe = st.lastValidCF,
			speed = math.min(rec.speed, CarConfig.TOP_SPEED),
			reason = "displacement",
		})
	end
	if #st.corrections >= CarConfig.ESCALATE_COUNT and not st.held then
		-- The client ignored repeated corrections: the server holds the hull on the valid frame for a moment.
		st.held = true
		print(string.format("[SkyRally][CAR] correction escalate player=%s count=%d hold=%.1fs", player.Name, #st.corrections, CarConfig.ESCALATE_HOLD))
		local hull = rec.hull
		pcall(function()
			hull:SetNetworkOwner(nil)
		end)
		hull.AssemblyLinearVelocity = Vector3.zero
		hull.AssemblyAngularVelocity = Vector3.zero
		hull.CFrame = st.lastValidCF
		task.delay(CarConfig.ESCALATE_HOLD, function()
			local cur = FlightServer.records[player]
			if cur and cur.hull == hull and hull.Parent and player.Parent then
				pcall(function()
					hull:SetNetworkOwner(player)
				end)
				CarServer.expectTeleport(player, st.lastValidCF)
			end
			st.held = false
			table.clear(st.corrections)
		end)
	end
end

-- A plane that jumped further than any legal flight (L30, L53). Its client owns the transform and has no correction
-- handler, so the server sends it back the way a crash does (the ordinary server-ordered respawn at its last
-- checkpoint: an honest client that tripped the bound lands there and flies on) and holds the hull on that frame for
-- ESCALATE_HOLD, so one that ignores the respawn gains nothing either. Nothing it reports counts until it is
-- validated again (PositionTrusted, read by RaceManager).
local function correctPlane(player: Player, rec: Record, st: PlayerState, dist: number, allowed: number, dt: number)
	local pos = rec.hull.Position
	CarServer.corrections += 1
	setTrusted(rec, st, false)
	local cf = FlightServer.respawnAtLastCheckpoint(player, false, false) or st.lastValidCF
	print(string.format(
		"[SkyRally][PLANE] correction player=%s dist=%.1f allowed=%.1f dt=%.3f from=%s to=%s",
		player.Name,
		dist,
		allowed,
		dt,
		v3s(pos),
		v3s(cf.Position)
	))
	CarServer.expectTeleport(player, cf)
	st.held = true
	local hull = rec.hull
	pcall(function()
		hull:SetNetworkOwner(nil)
	end)
	hull.AssemblyLinearVelocity = Vector3.zero
	hull.AssemblyAngularVelocity = Vector3.zero
	hull.CFrame = cf
	-- Anchored for the hold: the owner's FlightVelocity constraint would otherwise carry the held hull off the frame.
	hull.Anchored = true
	task.delay(CarConfig.ESCALATE_HOLD, function()
		local cur = FlightServer.records[player]
		if cur and cur.hull == hull and hull.Parent and player.Parent then
			hull.Anchored = false
			pcall(function()
				hull:SetNetworkOwner(player)
			end)
			CarServer.expectTeleport(player, cf)
		end
		st.held = false
	end)
end

local function stepValidation()
	local now = os.clock()
	for player, rec in pairs(FlightServer.records) do
		if rec.hull and rec.hull.Parent then
			local st = stateFor(player, rec.hull.CFrame)
			if not st.held then
				local p = rec.hull.Position
				local verdict, dist, allowed, dt = CarConfig.observe(st.validator, p.X, p.Y, p.Z, now)
				if verdict == "violation" and (p - rec.lastCheckpointCF.Position).Magnitude <= CarConfig.TELEPORT_GRACE_RADIUS then
					-- Back at its own last checkpoint (a respawn whose server reply it did not wait for): going back
					-- never gains anything, so accept it as a respawn instead of correcting into the water it left.
					CarServer.expectTeleport(player, rec.lastCheckpointCF)
					verdict = CarConfig.observe(st.validator, p.X, p.Y, p.Z, now)
				end
				if verdict == "ok" then
					st.lastValidCF = rec.hull.CFrame
					if not st.trusted then
						setTrusted(rec, st, true)
					end
				elseif verdict == "violation" then
					if st.isPlane then
						correctPlane(player, rec, st, dist, allowed, dt)
					else
						correct(player, rec, st, dist, allowed, dt)
					end
				end
			end
		end
	end
end

-- os.clock() of each player's last accepted manual respawn (RequestRespawn handler; weak keys: a player who left goes).
local manualRespawnAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

local function onFlightState(player: Player, action: any, payload: any)
	local rec = FlightServer.records[player]
	if not rec or not CarServer.isCar(rec.plane) or not rec.hull or not rec.hull.Parent then
		return
	end
	if action == "SyncTransform" and type(payload) == "table" then
		-- Visual state for other clients (wheel steer, drift sparks). Speed/BoostState are set by FlightServer's
		-- own handler; this one only clamps the speed to the car's legal maximum on top.
		local car = rec.plane
		-- T1-9: finite numbers only (math.clamp passes NaN through, which then replicated as an attribute).
		local speed = RemoteGuardRules.num(payload.speed, 0, CarConfig.maxHorizontalSpeed())
		if speed then
			rec.speed = speed
		end
		local steerIn = RemoteGuardRules.num(payload.steer, -1, 1)
		if steerIn then
			local steer = math.floor(steerIn * 20 + 0.5) / 20
			if car:GetAttribute("Steer") ~= steer then
				car:SetAttribute("Steer", steer)
			end
		end
		local driftIn = RemoteGuardRules.num(payload.driftLevel, 0, #CarConfig.DRIFT_LEVELS)
		if driftIn then
			local lvl = math.floor(driftIn)
			if car:GetAttribute("DriftLevel") ~= lvl then
				car:SetAttribute("DriftLevel", lvl)
			end
		end
		local drifting = payload.drifting == true
		if car:GetAttribute("Drifting") ~= drifting then
			car:SetAttribute("Drifting", drifting)
		end
		local airborne = payload.airborne == true
		if car:GetAttribute("Airborne") ~= airborne then
			car:SetAttribute("Airborne", airborne)
		end
		-- Trick lane (REMARKABLE item 5), visual only: body spin degrees (client sends it wrapped in 15-degree steps)
		-- and the grid-bounce counter, so other clients animate the BodyMotor. No effect on validation.
		local trickIn = RemoteGuardRules.num(payload.trick, -720, 720)
		if trickIn then
			local spin = math.clamp(math.floor(trickIn / 15 + 0.5) * 15, -720, 720)
			if car:GetAttribute("TrickSpin") ~= spin then
				car:SetAttribute("TrickSpin", spin)
			end
		end
		local hopIn = RemoteGuardRules.num(payload.gridHop, 0, 63)
		if hopIn then
			local hop = math.floor(hopIn)
			if car:GetAttribute("GridHop") ~= hop then
				car:SetAttribute("GridHop", hop)
			end
		end
	elseif action == "RequestRespawn" then
		-- Out of a battle (trap audit X-03): the car stays where it sank and the player spectates. Before, a last life
		-- lost in deep water was followed by the client's own water respawn, answered here with its last pad: the
		-- spectator was put back on the galleon.
		if player:GetAttribute("BattleOut") == true then
			return
		end
		local st = stateFor(player, rec.lastCheckpointCF)
		local now = os.clock()
		if now - st.lastRespawnRequest < CarConfig.RESPAWN_MIN_INTERVAL then
			return
		end
		-- A rescue the player asked for (RESPAWN button, Backspace, gamepad View, or his client's stuck watchdog: trap
		-- audit G5) has its own floor on top, a little under the client's cooldown so jitter never rejects an honest
		-- press, and none while the server swaps maps. It never moves the car anywhere new: the frame below is the same
		-- server-chosen one a crash gets.
		local reason = if type(payload) == "table" and type(payload.reason) == "string" then string.sub(payload.reason, 1, 24) else "crash"
		local manual = RespawnRules.isManualReason(reason)
		if manual then
			if now - (manualRespawnAt[player] or -math.huge) < RespawnRules.SERVER_MANUAL_FLOOR or workspace:GetAttribute("TrackSwitching") == true then
				return
			end
			manualRespawnAt[player] = now
		end
		st.lastRespawnRequest = now
		-- Hub (H0-05): free roam never updates the checkpoint, so every rescue used to land on the plaza. Pick the
		-- nearest hub anchor or the route frame under the car (TrackDirector.hubRespawnFrame) from where the server
		-- sees the hull now.
		local where = "checkpoint=" .. tostring(rec.lastCheckpointIdx)
		if RaceAttr.here("RaceMode") == "hub" then
			local okTd, director = pcall(require, script.Parent.TrackDirector)
			local hubCF, name = nil, nil
			if okTd then
				hubCF, name = (director :: any).hubRespawnFrame(rec.hull.Position, reason)
			end
			if typeof(hubCF) == "CFrame" then
				rec.lastCheckpointCF = hubCF
				where = "hub=" .. tostring(name)
			end
		end
		-- FlightServer's own handler leaves a car's request to this one; the car needs the frame from the server, so
		-- ask for the server-driven branch, which fires "CheckpointRespawn" with it. The client asked for it (asked =
		-- true): the respawn shield's rearm time applies (ItemEffects.RESPAWN_IMMUNE_REARM).
		local cf = FlightServer.respawnAtLastCheckpoint(player, false, true)
		if cf then
			CarServer.expectTeleport(player, cf)
			print(string.format("[SkyRally][CAR] respawn player=%s reason=%s %s at=%s", player.Name, reason, where, v3s(cf.Position)))
		end
	end
end

-- Publishes the vehicle for clients (they cannot read the registry def) and, when a QA override changes it mid-run,
-- asks RaceManager for a reset so every racer is respawned through the wrapper in the new vehicle.
local function refreshVehicle(fromOverride: boolean)
	local v = CarServer.activeVehicle()
	workspace:SetAttribute("ActiveVehicle", v)
	local root = TrackRegistry.getRoot()
	if root and root:GetAttribute("Vehicle") == nil then
		local def = TrackRegistry.getDef()
		if def and type(def.vehicle) == "string" then
			root:SetAttribute("Vehicle", def.vehicle)
		end
	end
	if v ~= lastVehicle then
		print(string.format("[SkyRally][CAR] vehicle=%s track=%s", v, TrackRegistry.getActiveId()))
		if fromOverride and lastVehicle ~= "" then
			workspace:SetAttribute("TriggerRaceReset", true)
		end
		lastVehicle = v
	end
end

-- Call before FlightServer.init() (so the first spawn is already a car); calling it after also works: players who
-- already hold a plane on a car track are respawned in a car here.
function CarServer.init()
	ensureRemotes()
	CarServer.install()
	refreshVehicle(false)

	if flightStateRemote then
		local carLimiter = RemoteGuardRules.newLimiter(RemoteGuardRules.LIMITS.flightState)
		Players.PlayerRemoving:Connect(carLimiter.forget)
		flightStateRemote.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
			if type(action) ~= "string" or not carLimiter.allow(player, os.clock()) then
				return
			end
			RaceScope.run(RaceScope.instanceOf(player), onFlightState, player, action, payload)
		end)
	end

	workspace:GetAttributeChangedSignal("ActiveTrackId"):Connect(function()
		refreshVehicle(false)
	end)
	workspace:GetAttributeChangedSignal("ForceVehicle"):Connect(function()
		refreshVehicle(true)
	end)

	if CarServer.activeVehicle() == "car" then
		local i = 0
		for player, rec in pairs(FlightServer.records) do
			i += 1
			if not CarServer.isCar(rec.plane) then
				FlightServer.spawnOrResetPlane(player, CarServer.slots[player] or i)
			end
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		CarServer.states[player] = nil
		CarServer.slots[player] = nil
	end)

	-- Every position the server sets a vehicle at (plane spawn and respawn included) is announced to the validator.
	FlightServer.teleportHook = function(player: Player, cf: CFrame)
		CarServer.expectTeleport(player, cf)
	end

	RunService.Heartbeat:Connect(stepValidation)
	print(string.format("[SkyRally][CAR] init vehicle=%s maxH=%.0f slack=%.1f tol=%.0f", CarServer.activeVehicle(), CarConfig.maxHorizontalSpeed(), CarConfig.VALIDATION_SLACK, CarConfig.VALIDATION_TOLERANCE))
end

-- Keeps the original spawn reachable (tests, or a mode that must force a plane on a car track).
function CarServer.spawnPlane(player: Player, slotIndex: number?): Record?
	if originalSpawn then
		return originalSpawn(player, slotIndex)
	end
	return nil
end

return CarServer
