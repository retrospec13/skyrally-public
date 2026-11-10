--!strict
-- ISLAND-2 galleon set pieces, client half (docs/REMARKABLE.md item 13; the fun layer on top of trap audit G1):
-- * THE CANNONS. server/WorldSetPieces fires "CannonFire" (cannon, rider, server time, start frame) to every client.
--   Everyone sees the fuse fizz and the barrel shiver, then a BOOM: muzzle blast, a rolling powder cloud, the barrel
--   recoiling on its carriage, a camera kick that fades with distance, and the car flying a barrel-rolling arc to its
--   landing (the rider's own client flies it through CarController.ride; others see the replicated hull). The rider
--   hears a slide whistle over the arc and lands with a dust thump and "ALL ABOARD!" (CrestCannon) or
--   "ABANDON SHIP!" (DeckCannon).
-- * WALK THE PLANK SALUTE. A car that leaves the plank kicker's lip at speed gets a salute from the gunport cannon
--   beside it: BOOM, smoke out of the hull side, a camera kick for the flyer (and anyone near), "WALK THE PLANK!".
-- * SPLASHDOWN GULL RESCUE (water battle, and the open sea in a race). A car that drowns and is put back on a pad (or a
--   checkpoint) is plucked out of the water by a
--   very determined seagull: for everyone else the gull dives, yanks a stand-in of the car out of the water with a
--   sploosh, carries it dripping in an arc and drops it on the pad (the real car is hidden on that client until then);
--   for the rescued player, the gull is still flapping over the car as the respawn fade clears, lets go and squawks.
-- All visual and audio, on each client only: nothing here moves a vehicle except the rider's own scripted ride, whose
-- landing the server announced. Phone budget: two pooled gulls, pooled sounds and emitters, one Heartbeat watcher
-- that runs only on ISLAND-2 and looks at the handful of cars, no per-frame allocation.
-- QA (Studio): workspace.GullTest = true plays a rescue for your own car from 40 studs out at sea to where it stands.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SetPieceRules"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local LocalPlayer = Players.LocalPlayer

local GalleonMoments = {}

local RIDE_HEIGHT = 1.9
local TRACK = "ISLAND-2"

local CarController: any = nil
local RaceUI: any = nil

local function stamp(msg: string, color: Color3?)
	if RaceUI and type(RaceUI.stamp) == "function" then
		pcall(RaceUI.stamp, msg, color, 1.4)
	end
end

local function setPieces(): Instance?
	local root = TrackRegistry.getRoot()
	return if root then root:FindFirstChild("SetPieces") else nil
end

local function launcherOf(m: Instance): Rules.Launcher?
	return Rules.parseLauncher({
		name = m.Name,
		cradle = m:GetAttribute("Cradle"),
		breech = m:GetAttribute("Breech"),
		axis = m:GetAttribute("Axis"),
		length = m:GetAttribute("Length"),
		land = m:GetAttribute("Land"),
		landLook = m:GetAttribute("LandLook"),
		ground = m:GetAttribute("Ground"),
		surface = m:GetAttribute("Surface"),
	})
end

---------------------------------------------------------------------------------------------------- cannons

local barrelBase: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function barrelOf(m: Model): Model?
	local b = m:FindFirstChild("Barrel")
	if b and b:IsA("Model") then
		if not barrelBase[b] then
			barrelBase[b] = b:GetPivot()
		end
		return b
	end
	return nil
end

local function fuseTip(m: Model, l: Rules.Launcher): Vector3
	local b = m:FindFirstChild("Barrel")
	local fuse = b and b:FindFirstChild("Fuse")
	local tip = fuse and fuse:FindFirstChild("FuseTip")
	if tip and tip:IsA("Attachment") then
		return tip.WorldPosition
	end
	return l.breech + Vector3.yAxis * 5
end

local function callout(name: string): (string, Color3)
	if name == "CrestCannon" then
		return "ALL ABOARD!", Color3.fromRGB(255, 226, 120)
	end
	return "ABANDON SHIP!", Color3.fromRGB(140, 220, 255)
end

-- The rider: CarController flies the hull along SetPieceRules.rideFrame from where this client sees it now.
local function ride(l: Rules.Launcher)
	if not CarController or not CarController.hull or CarController.respawning then
		return
	end
	local start = (CarController.hull :: BasePart).CFrame
	local t = 0
	local phase = "load"
	local landed = false
	CarController.rideLand = Rules.lookUp(l.land, l.landLook, Vector3.yAxis)
	CarController.rideLandSpeed = Rules.LAND_SPEED
	CarController.ride = function(dt: number): CFrame?
		t += dt
		local cf, now = Rules.rideFrame(l, start, t)
		if now ~= phase then
			phase = now
			if now == "flight" then
				Kit.ui("whistle", "slide_whistle", 0.75, 1) -- the BOOM's camera kick comes from cannonShow
			end
		end
		if now == "done" then
			if not landed then
				landed = true
				local text, color = callout(l.name)
				stamp(text, color)
				Kit.trauma(0.4)
			end
			return nil
		end
		return cf
	end
	print(string.format("[SkyRally][SETPIECE] riding %s", l.name))
end

-- Everyone: the cannon's own show, `elapsed` seconds after the server fired it (event latency).
local function cannonShow(m: Model, l: Rules.Launcher, elapsed: number, riderMine: boolean)
	local fuseAt = Rules.LOAD_TIME - elapsed
	local boomAt = Rules.LOAD_TIME + Rules.FUSE_TIME - elapsed
	local landAt = Rules.rideTime() - elapsed
	local barrel = barrelOf(m)
	local muzzle = Rules.muzzle(l)
	local muzzleCF = CFrame.lookAt(muzzle, muzzle + l.axis)
	-- fuse: fizz and sparks, the barrel shivering harder as it burns down
	task.delay(math.max(0, fuseAt), function()
		local tip = fuseTip(m, l)
		Kit.sfx("fuse_" .. l.name, "cannon_fuse", tip, 0.9, 1, 220)
		local nextSpark = 0
		Kit.animate(Rules.FUSE_TIME, function(k: number, tt: number)
			if tt >= nextSpark then
				nextSpark = tt + 0.06
				Kit.burst("fuse", Kit.up(fuseTip(m, l)), 1)
			end
			if barrel and barrel.Parent then
				local base = barrelBase[barrel]
				local a = (0.004 + 0.01 * k) * math.sin(tt * 90)
				barrel:PivotTo(base * CFrame.Angles(a, a * 0.6, 0))
			end
		end)
	end)
	-- BOOM
	task.delay(math.max(0, boomAt), function()
		Kit.sfx("boom_" .. l.name, "cannon_boom", muzzle, 1, 1, 900)
		Kit.burst("muzzle", muzzleCF, 1)
		Kit.burst("cannonSmoke", muzzleCF, 1)
		if riderMine then
			Kit.trauma(0.9)
		else
			Kit.traumaNear(muzzle, 0.55, 170)
		end
		if barrel and barrel.Parent then
			local base = barrelBase[barrel]
			Kit.animate(0.8, function(k: number)
				-- kick back 2.6 studs at once, then roll forward into battery
				local back = if k < 0.12 then k / 0.12 else 1 - Rules.smooth((k - 0.12) / 0.88)
				barrel:PivotTo(base * CFrame.new(0, 0, 2.6 * back) * CFrame.Angles(0.05 * back, 0, 0))
			end, function()
				if barrel.Parent then
					barrel:PivotTo(base)
				end
			end)
		end
	end)
	-- the landing thump, for everyone who can see it
	task.delay(math.max(0, landAt), function()
		local ground = Vector3.new(l.land.X, l.ground, l.land.Z)
		Kit.burst("landDust", Kit.up(ground + Vector3.yAxis * 0.5), 1)
		local text, color = callout(l.name)
		Kit.text("land_" .. l.name, text, color, ground + Vector3.yAxis * 9, 18, 5, 1.6, 5)
		if not riderMine then
			Kit.traumaNear(ground, 0.2, 90)
		end
	end)
end

local function onCannonFire(payload: any)
	if type(payload) ~= "table" or type(payload.name) ~= "string" then
		return
	end
	local folder = setPieces()
	local m = folder and folder:FindFirstChild(payload.name)
	if not m or not m:IsA("Model") then
		return
	end
	local l = launcherOf(m)
	if not l then
		return
	end
	local at = if type(payload.at) == "number" then payload.at else workspace:GetServerTimeNow()
	local elapsed = math.clamp(workspace:GetServerTimeNow() - at, 0, 1)
	local mine = payload.userId == LocalPlayer.UserId
	cannonShow(m, l, if mine then 0 else elapsed, mine)
	if mine then
		ride(l)
	end
end

---------------------------------------------------------------------------------------------------- plank salute

local saluteAt: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

local function salute(model: Model, gun: Vector3, dir: Vector3)
	local cf = CFrame.lookAt(gun, gun + dir)
	Kit.sfx("salute", "cannon_boom", gun, 0.85, 1.18, 700)
	Kit.burst("muzzle", cf, 0.6)
	Kit.burst("cannonSmoke", cf, 0.6)
	if model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		Kit.trauma(0.55)
		stamp("WALK THE PLANK!", Color3.fromRGB(255, 226, 120))
	else
		Kit.traumaNear(gun, 0.3, 120)
	end
end

---------------------------------------------------------------------------------------------------- gull rescue

type Gull = { model: Model, body: BasePart, wingL: BasePart, wingR: BasePart, busy: boolean }
local gulls: { Gull } = {}
local PARK = CFrame.new(0, -5000, 0)

local function gullPart(model: Model, name: string, size: Vector3, color: Color3, sphere: boolean): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	if sphere then
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Parent = p
	end
	p.CFrame = PARK
	p.Parent = model
	return p
end

local function newGull(): Gull
	local m = Instance.new("Model")
	m.Name = "SplashdownGull"
	local body = gullPart(m, "Body", Vector3.new(2.6, 2.4, 5.2), Color3.fromRGB(250, 250, 250), true)
	gullPart(m, "Head", Vector3.new(1.9, 1.9, 1.9), Color3.fromRGB(250, 250, 250), true)
	gullPart(m, "Beak", Vector3.new(0.5, 0.5, 1.6), Color3.fromRGB(255, 190, 40), false)
	gullPart(m, "Eye", Vector3.new(0.35, 0.35, 0.35), Color3.fromRGB(20, 20, 20), true)
	gullPart(m, "Tail", Vector3.new(1.6, 0.3, 1.8), Color3.fromRGB(150, 156, 166), false)
	local wingL = gullPart(m, "WingL", Vector3.new(5.0, 0.3, 2.2), Color3.fromRGB(176, 182, 192), false)
	local wingR = gullPart(m, "WingR", Vector3.new(5.0, 0.3, 2.2), Color3.fromRGB(176, 182, 192), false)
	gullPart(m, "Feet", Vector3.new(1.4, 0.3, 0.8), Color3.fromRGB(255, 170, 40), false)
	m.PrimaryPart = body
	m.Parent = workspace.CurrentCamera or workspace
	return { model = m, body = body, wingL = wingL, wingR = wingR, busy = false }
end

local function takeGull(): Gull?
	for _, g in gulls do
		if not g.busy and g.model.Parent then
			g.busy = true
			return g
		end
	end
	if #gulls < 2 then
		local g = newGull()
		g.busy = true
		table.insert(gulls, g)
		return g
	end
	return nil
end

-- Poses the whole gull: body frame `cf` (LookVector = flying direction), wings at `flap` radians.
local function poseGull(g: Gull, cf: CFrame, flap: number)
	local m = g.model
	g.body.CFrame = cf
	local head = m:FindFirstChild("Head") :: BasePart
	head.CFrame = cf * CFrame.new(0, 1.0, -2.8)
	local beak = m:FindFirstChild("Beak") :: BasePart
	beak.CFrame = cf * CFrame.new(0, 0.85, -4.2)
	local eye = m:FindFirstChild("Eye") :: BasePart
	eye.CFrame = cf * CFrame.new(0.75, 1.35, -3.2)
	local tail = m:FindFirstChild("Tail") :: BasePart
	tail.CFrame = cf * CFrame.new(0, 0.2, 3.2)
	local feet = m:FindFirstChild("Feet") :: BasePart
	feet.CFrame = cf * CFrame.new(0, -1.4, 1.0)
	g.wingL.CFrame = cf * CFrame.new(-1.2, 0.6, 0) * CFrame.Angles(0, 0, -flap) * CFrame.new(-2.4, 0, 0)
	g.wingR.CFrame = cf * CFrame.new(1.2, 0.6, 0) * CFrame.Angles(0, 0, flap) * CFrame.new(2.4, 0, 0)
end

local function releaseGull(g: Gull)
	poseGull(g, PARK, 0)
	g.busy = false
end

local function standIn(model: Model): BasePart?
	local mesh = model:FindFirstChild("TripoHeroCarMesh") or model:FindFirstChild("TripoHeroPlaneMesh")
	if not mesh or not mesh:IsA("BasePart") then
		return nil
	end
	local p = (mesh :: BasePart):Clone()
	for _, d in p:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") or d:IsA("Attachment") then
			d:Destroy()
		end
	end
	p.Name = "GullStandIn"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.LocalTransparencyModifier = 0
	p.Parent = workspace.CurrentCamera or workspace
	return p
end

local rescuing: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function flyAway(g: Gull, from: CFrame, dur: number)
	Kit.animate(dur, function(k: number, t: number)
		local cf = from * CFrame.new(0, 14 * k * k + 6 * k, -30 * k) * CFrame.Angles(0.35 * k, 0, 0)
		poseGull(g, cf, Rules.gullFlap(t, false))
	end, function()
		releaseGull(g)
	end)
end

-- The rescued player's own view: the gull is still holding on as the fade clears, then lets go.
local function localRescue(model: Model)
	local hull = Kit.hullOf(model)
	local g = takeGull()
	if not hull or not g then
		return
	end
	local hold = Rules.GULL_LOCAL
	Kit.text("gull_me", "SPLASHDOWN RESCUE!", Color3.fromRGB(150, 230, 255), hull.Position + Vector3.yAxis * 10, 20, 5, 1.8, 4)
	Kit.animate(hold, function(_k: number, t: number)
		if not hull.Parent then
			return
		end
		local p = hull.Position
		local look = hull.CFrame.LookVector
		poseGull(g, CFrame.lookAt(p + Vector3.yAxis * 6.5, p + Vector3.yAxis * 6.5 + Vector3.new(look.X, 0, look.Z)), Rules.gullFlap(t, true))
		if t > 0.15 and math.floor(t / 0.15) ~= math.floor((t - 1 / 60) / 0.15) then
			Kit.burst("drips", Kit.up(p + Vector3.yAxis * 1.5), 1)
		end
	end, function()
		local p = hull.Position
		Kit.sfx("gull", "gull_squawk", p + Vector3.yAxis * 6, 1, 1.05, 260)
		Kit.burst("feathers", Kit.up(p + Vector3.yAxis * 6), 1)
		flyAway(g, g.body.CFrame, 1.2)
	end)
end

-- Everyone else: dive, pluck, carry, drop.
local function remoteRescue(model: Model, from: Vector3, to: Vector3)
	if rescuing[model] then
		return
	end
	local cam = Kit.camPos()
	if (cam - from).Magnitude > Rules.GULL_RANGE and (cam - to).Magnitude > Rules.GULL_RANGE then
		return
	end
	local g = takeGull()
	if not g then
		return
	end
	rescuing[model] = true
	local proxy = standIn(model)
	local hull = Kit.hullOf(model)
	local offset = if proxy and hull then hull.CFrame:ToObjectSpace(proxy.CFrame) else CFrame.identity
	if proxy then
		Kit.hideModel(model, true)
	end
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local heading = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local carFrom = CFrame.lookAt(from, from + heading)
	local diveStart = from - heading * 34 + Vector3.yAxis * 30
	local grab = from + Vector3.yAxis * 6.5
	local D, C, R = Rules.GULL_DIVE, Rules.GULL_CARRY, Rules.GULL_DROP
	local plucked = false
	local lastDrip = 0
	local function done()
		if proxy then
			proxy:Destroy()
		end
		if model.Parent then
			Kit.hideModel(model, false)
		end
		rescuing[model] = nil
	end
	Kit.animate(D + C, function(_k: number, t: number)
		if t < D then
			local u = Rules.smooth(t / D)
			local p = diveStart:Lerp(grab, u)
			poseGull(g, CFrame.lookAt(p, p + (grab - diveStart).Unit), 0.9)
			if proxy then
				proxy.CFrame = carFrom * CFrame.new(0, -1.2 + math.sin(t * 12) * 0.3, 0) * offset
			end
			return
		end
		if not plucked then
			plucked = true
			Kit.sfx("pluck", "splash_pluck", from, 1, 1, 320)
			Kit.sfx("gull", "gull_squawk", grab, 1, 1, 320)
			Kit.burst("pluck", Kit.up(from), 1)
		end
		local u = (t - D) / C
		local carPos = Rules.gullCarry(from, to, u)
		local sway = math.sin(t * 7) * 0.22 * (1 - u)
		local carCF = CFrame.lookAt(carPos, carPos + heading) * CFrame.Angles(0, 0, sway)
		if proxy then
			proxy.CFrame = carCF * offset
		end
		local gp = carPos + Vector3.yAxis * 6.5
		poseGull(g, CFrame.lookAt(gp, gp + heading) * CFrame.Angles(0.15, 0, 0), Rules.gullFlap(t, true))
		if t - lastDrip > 0.12 then
			lastDrip = t
			Kit.burst("drips", Kit.up(carPos), 1)
		end
	end, function()
		done()
		Kit.burst("feathers", Kit.up(to + Vector3.yAxis * 6.5), 1)
		Kit.burst("landDust", Kit.up(to - Vector3.yAxis * (RIDE_HEIGHT - 0.4)), 0.5)
		flyAway(g, g.body.CFrame, R + 0.8)
	end)
end

---------------------------------------------------------------------------------------------------- watcher

local watchConn: RBXScriptConnection? = nil
local lastPos: { [Model]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any
local lastAlong: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local tidePart: BasePart? = nil
local tideLookup = 0

local function tideLevel(): number?
	if RaceAttr.mine("BattleKind") ~= "water" or RaceAttr.mine("RaceMode") ~= "battle" then
		-- not the water battle: the open sea (a race splash off the boardwalk or the bridge)
		return Rules.GULL_SEA[TRACK]
	end
	local published = workspace:GetAttribute("TideLevel")
	if type(published) == "number" then
		return published
	end
	local part = tidePart
	if not part or not part.Parent then
		local now = os.clock()
		if now - tideLookup < 1 then
			return nil
		end
		tideLookup = now
		local root = TrackRegistry.getRoot()
		local overlay = root and root:FindFirstChild("BattleOverlay")
		local found = overlay and overlay:FindFirstChild("TideWater", true)
		if not found or not found:IsA("BasePart") then
			return nil
		end
		tidePart = found
		part = found
	end
	local lv = (part :: BasePart):GetAttribute("TideLevel")
	return if type(lv) == "number" then lv else nil
end

local function step(dt: number)
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return
	end
	local folder = setPieces()
	local lip = folder and folder:GetAttribute("PlankLip")
	local dir = folder and folder:GetAttribute("PlankDir")
	local width = folder and folder:GetAttribute("PlankWidth")
	local gun = folder and folder:GetAttribute("SaluteGun")
	local gunDir = folder and folder:GetAttribute("SaluteDir")
	local tide = tideLevel()
	local now = os.clock()
	for _, m in planes:GetChildren() do
		if not m:IsA("Model") then
			continue
		end
		local hull = Kit.hullOf(m)
		if not hull then
			continue
		end
		local pos = hull.Position
		local prev = lastPos[m]
		lastPos[m] = pos
		-- gull: a jump out of the tide onto dry land
		if prev and tide and Rules.isWaterRescue(prev, pos, tide, RIDE_HEIGHT) then
			if m:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
				localRescue(m)
			else
				remoteRescue(m, prev, pos)
			end
		end
		-- plank salute: leaving the lip outward at speed, within the plank's width
		if typeof(lip) == "Vector3" and typeof(dir) == "Vector3" and typeof(gun) == "Vector3" and typeof(gunDir) == "Vector3" then
			local d = pos - lip
			local along = d:Dot(dir)
			local side = math.abs(d.X * -dir.Z + d.Z * dir.X)
			local prevAlong = lastAlong[m]
			lastAlong[m] = along
			local w = (if type(width) == "number" then width else 10) / 2 + 1.5
			if prevAlong and prevAlong < 0 and along >= 0 and side <= w and math.abs(d.Y) < 6 and (along - prevAlong) / math.max(dt, 1 / 120) > 20 then
				if now - (saluteAt[m] or -math.huge) > 2.5 then
					saluteAt[m] = now
					salute(m, gun, gunDir)
				end
			end
		end
	end
end

local function refresh()
	local on = RaceAttr.mine("ActiveTrackId") == TRACK and workspace:GetAttribute("TrackSwitching") ~= true
	if on and not watchConn then
		watchConn = RunService.Heartbeat:Connect(function(dt: number)
			local ok, err = pcall(function()
				step(dt)
			end)
			if not ok then
				warn("[SkyRally][SETPIECE] galleon watcher: " .. tostring(err))
			end
		end)
	elseif not on and watchConn then
		watchConn:Disconnect()
		watchConn = nil
		table.clear(lastPos)
		table.clear(lastAlong)
		tidePart = nil
	end
end

function GalleonMoments.init(carController: any, raceUI: any)
	CarController = carController
	RaceUI = raceUI
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		local ev = remotes and remotes:WaitForChild("SetPieceEvent", 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(kind: any, payload: any)
				if kind == "CannonFire" then
					onCannonFire(payload)
				end
			end)
		end
	end)
	RaceAttr.changed("ActiveTrackId", refresh)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(refresh)
	refresh()
	workspace:GetAttributeChangedSignal("GullTest"):Connect(function()
		if workspace:GetAttribute("GullTest") ~= true then
			return
		end
		workspace:SetAttribute("GullTest", nil)
		local m = Kit.vehicleOf(LocalPlayer.UserId)
		local hull = m and Kit.hullOf(m)
		if m and hull then
			local look = hull.CFrame.LookVector
			remoteRescue(m, hull.Position - Vector3.new(look.X, 0, look.Z).Unit * 40 - Vector3.yAxis * 3, hull.Position)
		end
	end)
end

return GalleonMoments
