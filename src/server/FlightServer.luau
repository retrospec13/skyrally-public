--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules")) -- join slots (L31)
local GridOrder = require(Shared:WaitForChild("GridOrder")) -- late joiner's seat on a race grid (GRID_ORDER.md)
-- Economy v3 phase 2b: a player's requests run in his RaceInstance's scope and the grid reads that instance's mode
-- (shared/RaceScope, shared/RaceAttr); workspace, exactly as before, while RaceFlowRules.PER_GROUP is false.
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local RemoteGuardRules = require(Shared:WaitForChild("RemoteGuardRules")) -- T1-9: finite numbers, enums, rate limit
local PlaneBuilder = require(script.Parent.PlaneBuilder)
local AvatarSelect = require(script.Parent.AvatarSelect) -- economy v3 phase 6: the player's plane avatar
-- Garage livery: the player's equipped plane livery paints the plane as it is built (CosmeticService repaints on equip).
local LiveryPaint = require(script.Parent.kit.LiveryPaint)
local RacerPaint = require(script.Parent.kit.RacerPaint) -- default racer colours + pennant, painted as the vehicle is built
local PilotSeat = require(script.Parent.kit.PilotSeat)
-- Flight-path guide (docs/design/FLIGHT_GUIDE.md 4.3, 4.6): the server's off-course clock, best progress and the
-- validated RETURN to course.
local FlightGuideRules = require(Shared:WaitForChild("FlightGuideRules"))
local RouteBranch = require(Shared:WaitForChild("RouteBranch"))

local FlightServer = {}

export type PlayerFlightRecord = {
	player: Player,
	plane: Model,
	hull: BasePart,
	spawnTime: number,
	lastCheckpointIdx: number,
	lastCheckpointCF: CFrame,
	station: number,
	lap: number,
	speed: number,
	finished: boolean,
	finishTime: number,
	finishRank: number,
	dnf: boolean?, -- L30: still racing when the DNF deadline passed (no award, Rally Streak kept); cleared on reset
	orbs: number,
	ftueCleared: boolean,
	passedCheckpoints: { [number]: boolean },
	guide: FlightGuideRules.ServerGuide?, -- off-course clock, best progress this lap, last return (planes in races)
}

FlightServer.records = {} :: { [Player]: PlayerFlightRecord }

-- Told of every position the SERVER puts a vehicle at (spawn, reset, respawn frame), so CarServer's displacement
-- validator accepts the jump instead of reading it as a teleport hack (L30, L53). Planes are checked now too.
FlightServer.teleportHook = nil :: ((Player, CFrame) -> ())?

local planesFolder: Folder? = nil
local remotesFolder: Folder? = nil
local _flightStateRemote: RemoteEvent? = nil
local raceEventRemote: RemoteEvent? = nil

local PLAYER_COLORS = {
	{ primary = Color3.fromRGB(235, 55, 55), accent = Color3.fromRGB(255, 215, 45) },
	{ primary = Color3.fromRGB(45, 185, 255), accent = Color3.fromRGB(255, 255, 255) },
	{ primary = Color3.fromRGB(165, 85, 255), accent = Color3.fromRGB(255, 220, 75) },
	{ primary = Color3.fromRGB(255, 135, 35), accent = Color3.fromRGB(255, 245, 160) },
}

local function getPlanesFolder(): Folder
	if planesFolder and planesFolder.Parent then
		return planesFolder
	end
	local existing = workspace:FindFirstChild("Planes")
	if existing and existing:IsA("Folder") then
		planesFolder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Planes"
	f.Parent = workspace
	planesFolder = f
	return f
end

-- Mode override for spawn frames (server/battle/BattleCore: the arena's spawn pads while RaceMode is "battle").
-- Returns nil to fall through to the hub plaza, the registered grid or the legacy grid.
FlightServer.startOverride = nil :: ((slotIndex: number) -> CFrame?)?

-- Battle respawn guard (server/battle/BattleCore, set while a battle runs): given a player, its respawn frame and
-- whether its own client asked for the respawn, returns a replacement frame (the seat, when the frame is not the
-- arena's; the mode's safe frame for an asked respawn) and whether the player may not respawn at all (out of the
-- battle). See respawnAtLastCheckpoint.
FlightServer.respawnGuard = nil :: ((player: Player, cf: CFrame, asked: boolean) -> (CFrame?, boolean))?

-- L19: TrackDirector sets this for the one reset that lands the server back in the hub: the grid then forms in front
-- of the arch of the zone just left instead of on the plaza (HubSpawnCF stays the plaza for every other reader).
FlightServer.hubReturnCF = nil :: CFrame?

-- Slots the bots hold on the grid (init.server sets AIRacers.heldSlots), so a joiner's seat choice knows which rear
-- seats are empty and which a bot gives up.
FlightServer.botSlots = nil :: (() -> { [number]: boolean })?

function FlightServer.getStartCFrame(slotIndex: number): CFrame
	local override = FlightServer.startOverride
	local overridden = if override then override(slotIndex) else nil
	if overridden then
		return overridden
	end
	-- Hub mode (TrackDirector): spawn on the plaza facing the portal arc, four abreast.
	local hubSpawn = FlightServer.hubReturnCF or workspace:GetAttribute("HubSpawnCF")
	if RaceAttr.here("RaceMode") == "hub" and typeof(hubSpawn) == "CFrame" then
		-- Rows of four, PlaneConfig.HUB_SEATS seats (independent of the field and server sizes): a slot past the last seat
		-- wraps instead of landing in the upper town (L31).
		local s = (slotIndex - 1) % PlaneConfig.HUB_SEATS
		local col = s % 4
		local row = s // 4
		return hubSpawn * CFrame.new((col - 1.5) * 12, 3, row * 16)
	end
	local registered = TrackRegistry.startCFrame(slotIndex)
	if registered then
		return registered
	end
	-- Legacy DINO-4 grid (no registered track yet)
	if slotIndex == 1 then
		return CFrame.lookAt(Vector3.new(-2, 151, -18), Vector3.new(-4, 141, -145))
	end
	local col = ((slotIndex - 1) % 2)
	local row = math.floor((slotIndex - 1) / 2)
	local xOff = if col == 0 then -12 else 12
	local zOff = -16 - row * 28 -- rows and lanes as PlaneConfig.AI_GRID (the chase camera clears the row behind)
	local startPos = Vector3.new(xOff, 151, zOff)
	local targetPos = Vector3.new(-4 + xOff * 0.4, 141, -145)
	return CFrame.lookAt(startPos, targetPos)
end

-- The pilot rides visible and seated (server/kit/PilotSeat: scaled avatar welded at the vehicle's SeatAnchor, sit pose
-- on the owning client). CarServer seats a car's driver the same way, and CharacterAdded below re-seats a respawned
-- character in whatever vehicle the record holds.
local function mountCharacterToPlane(character: Model, vehicle: Model)
	PilotSeat.mountPlayer(character, vehicle)
end

function FlightServer.spawnOrResetPlane(player: Player, slotIndex: number?): PlayerFlightRecord
	local folder = getPlanesFolder()
	local idx = slotIndex or 1
	local palette = PLAYER_COLORS[((idx - 1) % #PLAYER_COLORS) + 1]
	local startCF = FlightServer.getStartCFrame(idx)

	local existing = FlightServer.records[player]
	local plane: Model
	local hull: BasePart
	-- Phase 6: a plane built with another avatar than the current pick is rebuilt here (the pick applies at the next
	-- spawn: race grid or hub return); the hull and tuning are the same either way.
	local avatarKey = AvatarSelect.forPlayer(player, "plane")
	player:SetAttribute("AvatarKey", avatarKey)
	local sameAvatar = if existing and existing.plane then existing.plane:GetAttribute("AvatarKey") == avatarKey else false
	if existing and existing.plane and existing.plane.Parent and existing.hull and existing.hull.Parent and sameAvatar then
		plane = existing.plane
		hull = existing.hull
		hull.AssemblyLinearVelocity = Vector3.zero
		hull.AssemblyAngularVelocity = Vector3.zero
		hull.CFrame = startCF
		plane:SetAttribute("BoostState", "None")
		plane:SetAttribute("Speed", PlaneConfig.BASE_SPEED)
		-- This player's own grid slot (PlaneBuilder sets it on a new plane): the owning client poses its plane here on
		-- a race reset, not on the shared RaceStartCF (slot 1), which stacked every human on pole (L30).
		plane:SetAttribute("SpawnCFrame", startCF)
	else
		if existing and existing.plane and existing.plane.Parent and not sameAvatar then
			existing.plane:Destroy() -- the old avatar's plane; its record is replaced below
		end
		plane = PlaneBuilder.createPlane(
			"Plane_" .. player.Name,
			palette.primary,
			palette.accent,
			startCF,
			false,
			avatarKey
		)
		plane:SetAttribute("OwnerUserId", player.UserId)
		plane:SetAttribute("OwnerName", player.Name)
		RacerPaint.paintPlayer(player, plane, idx)
		plane.Parent = folder
		hull = plane.PrimaryPart :: BasePart
	end

	pcall(function()
		hull:SetNetworkOwner(player)
	end)

	local prevOrbs = if existing then existing.orbs else (player:GetAttribute("Orbs") :: number? or 0)
	local rec: PlayerFlightRecord = {
		player = player,
		plane = plane,
		hull = hull,
		spawnTime = os.clock(),
		lastCheckpointIdx = 1,
		lastCheckpointCF = startCF,
		station = 0,
		lap = 1,
		speed = PlaneConfig.BASE_SPEED,
		finished = false,
		finishTime = 0,
		finishRank = 0,
		orbs = prevOrbs,
		ftueCleared = false,
		passedCheckpoints = { [1] = true },
		guide = FlightGuideRules.newServerGuide(),
	}
	FlightServer.records[player] = rec
	if FlightServer.teleportHook then
		FlightServer.teleportHook(player, startCF)
	end

	player:SetAttribute("MountedInPlane", true)
	player:SetAttribute("PlaneName", plane.Name)
	player:SetAttribute("Lap", 1)
	player:SetAttribute("Checkpoint", 1)
	player:SetAttribute("Station", 0)
	player:SetAttribute("Rank", 1)
	player:SetAttribute("Speed", PlaneConfig.BASE_SPEED)
	player:SetAttribute("Orbs", prevOrbs)
	player:SetAttribute("RaceFinished", false)
	player:SetAttribute("FTUECleared", false)

	if player.Character then
		mountCharacterToPlane(player.Character, plane)
		pcall(function()
			hull:SetNetworkOwner(player)
		end)
	end

	if raceEventRemote then
		raceEventRemote:FireClient(player, "PlaneMounted", {
			planeName = plane.Name,
			startCFrame = startCF,
			trackLength = select(2, SplineUtils.loadWaypoints()),
		})
	end

	return rec
end

-- asked: the player's own client asked for this respawn (a crash, the RESPAWN button, the stuck watchdog), as opposed
-- to one the server orders (a drown, a boundary return, a seat); defaults to clientDriven. It is published as
-- LastRespawnAsked with the LastRespawnClock stamp: ItemEffects holds asked respawns to its shield rearm time.
function FlightServer.respawnAtLastCheckpoint(player: Player, clientDriven: boolean?, asked: boolean?): CFrame?
	local rec = FlightServer.records[player]
	if not rec or not rec.hull or not rec.hull.Parent then
		return nil
	end
	local wasAsked = if asked ~= nil then asked else clientDriven == true

	local respawnCF = rec.lastCheckpointCF
	-- While a battle runs (BattleCore): a player out of it is not respawned (trap audit X-03), and a frame that is not
	-- the arena's (left over from the previous map: Studio put a car back at the hub's coordinates, under the world) is
	-- replaced by the player's seat. The client's cache held that stale frame too, so it is sent the seat even when it
	-- asked on its own (a plane's client-driven respawn).
	local guard = FlightServer.respawnGuard
	if guard then
		local fixed, blocked = guard(player, respawnCF, wasAsked)
		if blocked then
			return nil
		end
		if fixed then
			rec.lastCheckpointCF = fixed
			respawnCF = fixed
			clientDriven = false
		end
	end
	if not clientDriven then
		-- Transform is client-owned; the CheckpointRespawn event below applies it.
		-- Only reset server-side velocity bookkeeping here.
		rec.hull.AssemblyLinearVelocity = Vector3.zero
		rec.hull.AssemblyAngularVelocity = Vector3.zero
	end

	if FlightServer.teleportHook then
		FlightServer.teleportHook(player, respawnCF)
	end

	rec.speed = PlaneConfig.BASE_SPEED
	player:SetAttribute("Speed", PlaneConfig.BASE_SPEED)
	player:SetAttribute("LastRespawnAsked", wasAsked)
	player:SetAttribute("LastRespawnClock", os.clock())

	if raceEventRemote and not clientDriven then
		raceEventRemote:FireClient(player, "CheckpointRespawn", {
			cframe = respawnCF,
			checkpoint = rec.lastCheckpointIdx,
		})
	end

	return respawnCF
end

-- ---------------------------------------------------------------- flight-path guide (FLIGHT_GUIDE.md 4.3, 4.6)
local function guideOf(rec: PlayerFlightRecord): FlightGuideRules.ServerGuide
	local g = rec.guide
	if not g then
		g = FlightGuideRules.newServerGuide()
		rec.guide = g
	end
	return g :: FlightGuideRules.ServerGuide
end

local function isRacing(): boolean
	local mode = RaceAttr.here("RaceMode")
	if mode == "hub" or mode == "battle" or workspace:GetAttribute("TrackSwitching") == true then
		return false
	end
	local goTime = RaceAttr.here("RaceGoTime")
	return not (type(goTime) == "number" and workspace:GetServerTimeNow() < goTime)
end

-- RaceManager's per-player step, right after it projects the (trusted) hull onto the spline: st and ribbonPoint are that
-- projection. The server's own off-course clock (beyond SERVER_OUT of the main line AND every alternate line, at flight
-- height) and best progress, which only advances on course and only as fast as a legal plane flies. Cars, finished
-- racers and anything outside a race only clear the clock.
function FlightServer.stepGuide(rec: PlayerFlightRecord, st: number, ribbonPoint: Vector3, dt: number)
	local g = guideOf(rec)
	if rec.finished or rec.plane:GetAttribute("VehicleType") == "car" or not isRacing() then
		FlightGuideRules.idleServer(g)
		return
	end
	local pos = rec.hull.Position
	local dist = (pos - (ribbonPoint + Vector3.new(0, RouteBranch.PLANE_LIFT, 0))).Magnitude
	if dist > FlightGuideRules.SERVER_OUT then
		-- A tunnel, ledge or the key gallery is on course: only checked once the main line is far.
		for _, line in RouteBranch.load(TrackRegistry.getRoot(), RouteBranch.PLANE_LIFT) do
			-- A cliff line (ISLAND-2 Alt2) is car progress only: the plane's course stays as before.
			local d = if line.style == RouteBranch.CLIFF_STYLE then math.huge else RouteBranch.nearest(line, pos)
			if d < dist then
				dist = d
			end
		end
	end
	FlightGuideRules.stepServer(g, dist, st, dt)
	-- QA / exploit review: whole seconds, written on change.
	local shownOff = math.floor(g.offTime)
	if rec.player:GetAttribute("OffCourseSeconds") ~= shownOff then
		rec.player:SetAttribute("OffCourseSeconds", shownOff)
	end
end

-- The checkpoint rule's view of a plane (RaceManager, FlightGuideRules.checkpointCounts): the server's last course
-- distance (main line and alternates, from stepGuide this step) and whether it is inside an allow-pocket (only looked
-- up past CP_COURSE_DIST, so the path costs nothing).
local pocketRoot: Instance? = nil
local pocketList: { FlightGuideRules.Pocket } = {}
function FlightServer.courseFix(rec: PlayerFlightRecord): (number, boolean)
	local dist = guideOf(rec).dist
	if dist <= FlightGuideRules.CP_COURSE_DIST or not rec.hull then
		return dist, false
	end
	local root = TrackRegistry.getRoot()
	if root ~= pocketRoot then
		pocketRoot = root
		pocketList = FlightGuideRules.readPockets(root)
	end
	return dist, FlightGuideRules.inPocket(pocketList, rec.hull.Position)
end

-- A lap was credited: best progress restarts from the line.
function FlightServer.guideNewLap(rec: PlayerFlightRecord)
	FlightGuideRules.newLap(guideOf(rec))
end

-- RETURN to course (FLIGHT_GUIDE.md 4.3, 12): the default mode's bounds reset, Free driving's button and lost return, and
-- the leash's far rescue. The client sends no position or frame: the server checks the race state, that the reason
-- belongs to the player's FlightMode (the server-owned attribute), its own off-course clock and the cooldowns, then
-- places the plane on the main route at or behind its best progress (FlightGuideRules.returnStation), level and facing
-- along it, at RETURN_SPEED. Refusals answer "CourseReturnRefused" so the client can fall back at once. Returns the
-- frame, or nil and the reason.
function FlightServer.returnToCourse(player: Player, reason: string): (CFrame?, string)
	local rec = FlightServer.records[player]
	if not rec or not rec.hull or not rec.hull.Parent then
		return nil, "noVehicle"
	end
	local g = guideOf(rec)
	local now = os.clock()
	local goTime = RaceAttr.here("RaceGoTime")
	local lastRespawn = player:GetAttribute("LastRespawnClock")
	local ok, why = FlightGuideRules.canReturn({
		mode = RaceAttr.here("RaceMode"),
		started = not (type(goTime) == "number" and workspace:GetServerTimeNow() < goTime),
		switching = workspace:GetAttribute("TrackSwitching") == true,
		battleOut = player:GetAttribute("BattleOut") == true,
		finished = rec.finished,
		trusted = rec.plane:GetAttribute("PositionTrusted") ~= false,
		isCar = rec.plane:GetAttribute("VehicleType") == "car",
		offTime = g.offTime,
		sinceReturn = now - g.lastReturn,
		sinceRespawn = if type(lastRespawn) == "number" then now - lastRespawn else math.huge,
		reason = reason,
		flightMode = FlightGuideRules.modeOf(player:GetAttribute(FlightGuideRules.MODE_ATTR)),
	})
	if not ok then
		print(string.format("[SkyRally][GUIDE] return refused player=%s reason=%s why=%s off=%.1f", player.Name, reason, why, g.offTime))
		if raceEventRemote then
			raceEventRemote:FireClient(player, "CourseReturnRefused", { reason = reason, why = why })
		end
		return nil, why
	end
	local nearest = SplineUtils.projectPosition(rec.hull.Position, rec.station)
	local returnSt = FlightGuideRules.returnStation(nearest, g.best)
	local point, tangent = SplineUtils.sampleAtStation(returnSt)
	local cf = FlightGuideRules.returnFrame(point, tangent)
	if FlightServer.teleportHook then
		FlightServer.teleportHook(player, cf)
	end
	g.lastReturn = now
	g.offTime = 0
	g.inT = 0
	rec.speed = FlightGuideRules.RETURN_SPEED
	player:SetAttribute("Speed", FlightGuideRules.RETURN_SPEED)
	player:SetAttribute("LastRespawnAsked", true) -- ItemEffects: an asked respawn (shield rearm rules)
	player:SetAttribute("LastRespawnClock", now)
	player:SetAttribute("CourseReturns", ((player:GetAttribute("CourseReturns") :: number?) or 0) + 1)
	print(string.format("[SkyRally][GUIDE] return player=%s reason=%s nearest=%.0f best=%s to=%.0f", player.Name, reason, nearest, tostring(g.best and math.floor(g.best)), returnSt))
	-- Not CheckpointRespawn: that would overwrite the client's checkpoint frame, and a return must not move it.
	if raceEventRemote then
		raceEventRemote:FireClient(player, "CourseReturn", { cframe = cf, speed = FlightGuideRules.RETURN_SPEED, reason = reason })
	end
	return cf, "ok"
end

-- A new respawn frame with no respawn (a battle seat, BattleCore): the record and the client's cache agree on it.
-- CarController and FlightController take respawnCFrame from "CheckpointPassed" (a car's even before it is bound), and
-- they fall back on that cache when a respawn reply is late, so a frame from the previous map never survives a seat.
function FlightServer.setRespawnFrame(player: Player, cf: CFrame)
	local rec = FlightServer.records[player]
	if not rec then
		return
	end
	rec.lastCheckpointCF = cf
	if raceEventRemote then
		raceEventRemote:FireClient(player, "CheckpointPassed", {
			checkpoint = rec.lastCheckpointIdx,
			respawnCFrame = cf,
			seat = true,
		})
	end
end

-- One [ANTICHEAT] line per player per second (RemoteGuardRules.LOG).
local lastGuardLog: { [Player]: number } = {}
local function guardLog(player: Player, line: string)
	local now = os.clock()
	if now - (lastGuardLog[player] or -math.huge) < 1 then
		return
	end
	lastGuardLog[player] = now
	print(string.format("%suser=%d %s", RemoteGuardRules.LOG, player.UserId, line))
end

function FlightServer.init()
	getPlanesFolder()

	local existingRemotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if existingRemotes and existingRemotes:IsA("Folder") then
		remotesFolder = existingRemotes
	else
		local rf = Instance.new("Folder")
		rf.Name = "SkyRallyRemotes"
		rf.Parent = ReplicatedStorage
		remotesFolder = rf
	end

	local existingFsr = (remotesFolder :: Folder):FindFirstChild("FlightStateRemote")
	local fsr: RemoteEvent
	if existingFsr and existingFsr:IsA("RemoteEvent") then
		fsr = existingFsr
	else
		local newFsr = Instance.new("RemoteEvent")
		newFsr.Name = "FlightStateRemote"
		newFsr.Parent = remotesFolder
		fsr = newFsr
	end
	_flightStateRemote = fsr

	local existingRer = (remotesFolder :: Folder):FindFirstChild("RaceEventRemote")
	local rer: RemoteEvent
	if existingRer and existingRer:IsA("RemoteEvent") then
		rer = existingRer
	else
		local newRer = Instance.new("RemoteEvent")
		newRer.Name = "RaceEventRemote"
		newRer.Parent = remotesFolder
		rer = newRer
	end
	raceEventRemote = rer

	local function onFlightState(player: Player, action: string, payload: any)
		local rec = FlightServer.records[player]
		if not rec or not rec.hull or not rec.hull.Parent then
			return
		end

		if action == "SyncTransform" and type(payload) == "table" then
			if os.clock() - rec.spawnTime < 0.35 then
				return
			end
			-- NOTE: the client owns the plane's transform (network ownership).
			-- Server-side CFrame writes here fight the owner and cause violent
			-- position/orientation snapping. Sync attributes only.
			-- T1-9: a finite number only (NaN / inf never reach rec.speed or an attribute), BoostState from the enum only.
			local speed = RemoteGuardRules.num(payload.speed, 0, RemoteGuardRules.TRAIL.maxSpeed)
			if speed then
				rec.speed = speed
				-- Whole studs/s: every client spins this vehicle's propeller or wheels from it (client/VehicleMotion,
				-- CarController remote rigs), and an unrounded float re-replicated on every sync.
				local shown = math.floor(rec.speed + 0.5)
				if rec.plane:GetAttribute("Speed") ~= shown then
					rec.plane:SetAttribute("Speed", shown)
				end
				player:SetAttribute("Speed", math.floor(rec.speed + 0.5))
			end
			local boost = RemoteGuardRules.boostState(payload.boostState)
			if boost then
				if rec.plane:GetAttribute("BoostState") ~= boost then
					rec.plane:SetAttribute("BoostState", boost)
				end
			elseif payload.boostState ~= nil then
				guardLog(player, "flightstate reject field=boostState value=" .. RemoteGuardRules.shown(payload.boostState))
			end
		elseif action == "RequestRespawn" then
			-- Out of a battle (trap audit X-03): no respawn, the spectator stays where it went out.
			if player:GetAttribute("BattleOut") == true then
				return
			end
			-- A car's request is CarServer's (its own handler on this remote): it holds the request to the respawn
			-- floors and answers with the frame. Stamping it here as well gave a car that fired RequestRespawn in a loop
			-- a fresh respawn shield each time, even for requests CarServer's floors refused.
			if rec.plane:GetAttribute("VehicleType") == "car" then
				return
			end
			FlightServer.respawnAtLastCheckpoint(player, true)
		elseif action == "RequestCourseReturn" then
			-- RETURN to course (FLIGHT_GUIDE.md 4.3, 12): only the reason is read from the payload; canReturn checks it is a
			-- known reason that belongs to the player's flight mode.
			local reason = if type(payload) == "table" and type(payload.reason) == "string" then payload.reason else "Button"
			FlightServer.returnToCourse(player, reason)
		elseif action == "RequestPlayAgain" then
			if FlightServer.onPlayAgainRequested then
				FlightServer.onPlayAgainRequested(player)
			end
		end
	end
	local flightLimiter = RemoteGuardRules.newLimiter(RemoteGuardRules.LIMITS.flightState)
	Players.PlayerRemoving:Connect(function(p: Player)
		flightLimiter.forget(p)
		lastGuardLog[p] = nil
	end)
	fsr.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
		if type(action) ~= "string" or not flightLimiter.allow(player, os.clock()) then
			return
		end
		-- Per group a request (respawn, RETURN, FLY AGAIN) belongs to the sender's race; a plain call otherwise.
		RaceScope.run(RaceScope.instanceOf(player), onFlightState, player, action, payload)
	end)

	-- L31/L32: each joiner takes a slot nobody present holds (a counter that only grew spawned joiners on a churned
	-- public server 100+ studs behind the plaza). On a race grid (GridOrder.isGridded) that is a random rear-half seat,
	-- an empty one before a bot's (AIRacers.refreshField then trims the bot on it); in the hub, a boss race, a time
	-- trial or a battle the lowest free slot as before.
	local slotOf: { [Player]: number } = {}
	local function setupPlayer(player: Player)
		local used: { [number]: boolean } = {}
		for p, s in slotOf do
			if p.Parent then
				used[s] = true
			end
		end
		for _, p in Players:GetPlayers() do
			local s = p:GetAttribute("GridSlot")
			if p ~= player and type(s) == "number" then
				used[s] = true
			end
		end
		local mode = workspace:GetAttribute("RaceMode")
		local mySlot: number
		if GridOrder.isGridded(mode) then
			local botsAt = FlightServer.botSlots
			local seed = ((workspace:GetAttribute("RaceResetSeq") :: number?) or 0) * 7919 + player.UserId
			local position
			mySlot, position = GridOrder.lateJoinSlot(used, if botsAt then botsAt() else {}, PlaneConfig.AI_FIELD_SIZE, seed)
			player:SetAttribute("GridSlot", mySlot)
			player:SetAttribute("GridPosition", position)
			player:SetAttribute("GridField", PlaneConfig.AI_FIELD_SIZE)
			player:SetAttribute("GridReason", "late")
			player:SetAttribute("GridLastPlace", nil)
		else
			mySlot = RaceFlowRules.freeSlot(used)
			player:SetAttribute("GridSlot", mySlot)
			player:SetAttribute("GridReason", nil)
		end
		slotOf[player] = mySlot
		FlightServer.spawnOrResetPlane(player, mySlot)

		player.CharacterAdded:Connect(function(char: Model)
			task.defer(function()
				local rec = FlightServer.records[player]
				if rec and rec.hull and rec.hull.Parent then
					mountCharacterToPlane(char, rec.plane)
					pcall(function()
						rec.hull:SetNetworkOwner(player)
					end)
				end
			end)
		end)
	end

	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		setupPlayer(p)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		slotOf[player] = nil
		local rec = FlightServer.records[player]
		if rec then
			if rec.plane and rec.plane.Parent then
				rec.plane:Destroy()
			end
			FlightServer.records[player] = nil
		end
	end)
end

FlightServer.onPlayAgainRequested = nil :: ((Player) -> ())?

return FlightServer
