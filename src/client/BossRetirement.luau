--!strict
-- Boss defeat set pieces and retired bosses (docs/REMARKABLE.md item 21), client only.
-- * DEFEAT GAG. When this player wins a boss race or rematch (RaceEventRemote "RaceFinished", rank 1), the beaten boss
--   performs its own comic retreat right in front of the winner's vehicle, using the proxy technique (client/Cosmetics
--   finish emote): a local clone of the boss mesh plays the gag (keyframes in shared/SetPieceRules.GAGS, the Batch 1
--   bossclips for the body: hit, roar, walk/fly/hover...) while the real boss is hidden on this client for the rest of
--   the race. Cinderwing spirals down smoking and belly-flops; Frosthorn freezes solid and spins off like a puck before
--   shattering out; Clattershell trips onto its shell and spins like a top; Emberbeetle's rotor sputters and it bounces
--   onto its back; Thunderwright's wheels pop off one by one and a little white flag goes up. Each one roars at the end
--   and the roar comes out as a squeak (the Batch 1 roar, played fast), then it leaves in a puff: "<NAME> RETIRES TO
--   CENTRAL ISLAND!".
-- * RETIRED BOSSES. In the hub (HUB-0 free roam), every boss this player has beaten (player attribute BossesBeaten,
--   server/WorldSetPieces) hangs out beside its zone's portal arch: the flyers circle lazily overhead, Emberbeetle
--   hovers, Clattershell patrols the sand, Thunderwright sits parked by the SPACE arch it once guarded. They play their
--   idle loops and roar now and then. Distance-culled (SetPieceRules.retireStep: every frame near, 10 Hz further, frozen
--   beyond), local clones of the templates the server keeps in ReplicatedStorage.SkyRallyRetiredBosses.
-- QA (Studio): workspace.BossGagTest = "<ZONE>" plays that zone's gag in front of you now (any race with that boss on
-- the grid, or the hub with that boss retired); workspace.RetiredTest = true rebuilds the retired bosses.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SetPieceRules"))
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local bossclips = Shared:WaitForChild("bossclips")
local ClipMath = require(bossclips:WaitForChild("ClipMath"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local LocalPlayer = Players.LocalPlayer

local BossRetirement = {}

local TrackFlow: any = nil

---------------------------------------------------------------------------------------------------- clip rig

type Rig = {
	bones: { [number]: Bone }, -- module bone index -> Bone in the clone
	wheels: { Bone },
	mod: ClipMath.Module?,
	scale: number,
	clip: string?,
	prevClip: string?,
	fade: number, -- 0..1 progress of the crossfade from prevClip to clip
	t: number,
	prevT: number,
	acc: ClipMath.Acc,
}

local modules: { [string]: ClipMath.Module | false } = {}

local function clipsFor(boss: BossConfig.Boss): ClipMath.Module?
	local name = boss.clips
	if not name then
		return nil
	end
	local cached = modules[name]
	if cached ~= nil then
		return if cached then cached :: any else nil
	end
	local ms = bossclips:FindFirstChild(name)
	local ok, res = false, nil
	if ms and ms:IsA("ModuleScript") then
		ok, res = pcall(require, ms)
	end
	if ok and ClipMath.validate(res) then
		modules[name] = res :: ClipMath.Module
		return res :: ClipMath.Module
	end
	modules[name] = false
	return nil
end

local function newRig(root: Instance, boss: BossConfig.Boss, scale: number): Rig
	local mod = clipsFor(boss)
	local index: { [string]: number } = {}
	if mod then
		for i, n in mod.bones do
			index[n] = i
		end
	end
	local bones: { [number]: Bone } = {}
	local wheels: { Bone } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Bone") then
			d.Transform = CFrame.identity
			local i = index[d.Name]
			if i then
				bones[i] = d
			end
			if string.sub(d.Name, 1, 5) == "Wheel" then
				table.insert(wheels, d)
			end
		end
	end
	return { bones = bones, wheels = wheels, mod = mod, scale = scale, clip = nil, prevClip = nil, fade = 1, t = 0, prevT = 0, acc = ClipMath.newAcc() }
end

-- Advances the rig on `clip` at `rate` and writes every bone (a 0.15 s crossfade when the clip changes).
local function stepRig(r: Rig, clip: string?, rate: number, dt: number)
	local mod = r.mod
	if not mod then
		return
	end
	if clip and not mod.clips[clip] then
		clip = nil
	end
	if clip ~= r.clip then
		r.prevClip, r.prevT = r.clip, r.t
		r.clip, r.t, r.fade = clip, 0, 0
	end
	r.t += dt * rate
	r.prevT += dt
	r.fade = math.min(1, r.fade + dt / 0.15)
	local cur = if r.clip then mod.clips[r.clip :: string] else nil
	local prev = if r.prevClip and r.fade < 1 then mod.clips[r.prevClip :: string] else nil
	local acc = r.acc
	for i, bone in r.bones do
		ClipMath.resetAcc(acc)
		if prev then
			ClipMath.accumulate(acc, 1 - r.fade, ClipMath.sample(prev, i, r.prevT, mod.fps))
		end
		if cur then
			ClipMath.accumulate(acc, math.max(r.fade, 1e-3), ClipMath.sample(cur, i, r.t, mod.fps))
		end
		if acc[8] > 0 then
			local s = r.scale
			bone.Transform = CFrame.new(acc[5] * s, acc[6] * s, acc[7] * s, acc[1], acc[2], acc[3], acc[4])
		end
	end
end

local function stripPhysics(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("JointInstance") or d:IsA("Constraint") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.LocalTransparencyModifier = 0
		end
	end
end

---------------------------------------------------------------------------------------------------- defeat gag

local hiddenBoss: Model? = nil
local gagRunning = false

local function bossModel(): Model?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	for _, m in planes:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("IsBoss") == true then
			return m
		end
	end
	return nil
end

local function restoreBoss()
	local m = hiddenBoss
	hiddenBoss = nil
	if m and m.Parent then
		Kit.hideModel(m, false)
	end
end

-- The winner's frame: on the ground (cars) or a little under the plane, flat heading.
local function anchorFrame(ahead: number): CFrame?
	local mine = Kit.vehicleOf(LocalPlayer.UserId)
	local hull = mine and Kit.hullOf(mine)
	if not mine or not hull then
		return nil
	end
	local look = hull.CFrame.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.new(0, 0, -1)
	local drop = if mine:GetAttribute("IsCar") == true then 1.9 else 7
	local p = hull.Position - Vector3.yAxis * drop + fwd * ahead
	return CFrame.lookAt(p, p + fwd)
end

local function iceBlock(size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = "GagIce"
	p.Size = size
	p.Material = Enum.Material.Glass
	p.Color = Color3.fromRGB(190, 236, 255)
	p.Transparency = 0.45
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = workspace.CurrentCamera or workspace
	return p
end

local function whiteFlag(): Model
	local m = Instance.new("Model")
	m.Name = "GagFlag"
	local pole = Instance.new("Part")
	pole.Name = "Pole"
	pole.Size = Vector3.new(0.25, 5, 0.25)
	pole.Color = Color3.fromRGB(120, 86, 56)
	pole.Material = Enum.Material.Wood
	local cloth = Instance.new("Part")
	cloth.Name = "Cloth"
	cloth.Size = Vector3.new(2.4, 1.6, 0.1)
	cloth.Color = Color3.fromRGB(250, 250, 250)
	cloth.Material = Enum.Material.Fabric
	for _, p in { pole, cloth } do
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = m
	end
	m.PrimaryPart = pole
	m.Parent = workspace.CurrentCamera or workspace
	return m
end

local function playGag(zone: string, real: Model?)
	if gagRunning then
		return
	end
	local boss = BossConfig.forZone(zone)
	local gag = Rules.GAGS[zone]
	if not boss or not gag then
		return
	end
	local source = real and real:FindFirstChild("BossMesh")
	local hull = real and Kit.hullOf(real)
	local proxy: Model
	local meshInHull: CFrame
	local scale = 1
	if source and source:IsA("Model") and hull then
		proxy = source:Clone()
		meshInHull = hull.CFrame:ToObjectSpace(source:GetPivot())
		scale = (real :: Model):GetAttribute("BossScale") :: number? or 1
	else
		-- No live boss mesh (QA in the hub): use a retired template if one is here.
		local folder = ReplicatedStorage:FindFirstChild("SkyRallyRetiredBosses")
		local t = folder and folder:FindFirstChild(zone)
		if not t or not t:IsA("Model") then
			print("[SkyRally][SETPIECE] no boss mesh for the " .. zone .. " gag")
			return
		end
		proxy = t:Clone()
		meshInHull = CFrame.Angles(0, math.rad(boss.yawOffset), 0)
		scale = t:GetAttribute("BossScale") :: number? or 1
	end
	gagRunning = true
	stripPhysics(proxy)
	proxy.Name = "BossGag_" .. zone
	proxy.Parent = workspace.CurrentCamera or workspace
	if real then
		hiddenBoss = real
		Kit.hideModel(real, true)
	end
	-- the mesh's centre and half height in the creature frame (rotations go about the centre)
	local creature0 = proxy:GetPivot() * meshInHull:Inverse()
	local bcf, bsize = proxy:GetBoundingBox()
	local cIn = creature0:PointToObjectSpace(bcf.Position)
	local half = bsize.Y * 0.5
	local rig = newRig(proxy, boss, scale)
	local ahead = boss.length * gag.ahead + 18
	local last = 0
	local ice: Part? = nil
	local flag: Model? = nil
	local wheelsAt: number? = nil
	local smokeUntil = 0
	local sparkUntil = 0
	local dizzyUntil = 0
	local nextFx = 0
	local roarCue = "roar_" .. string.lower(boss.clips or boss.name)
	local poofed = false
	print(string.format("[SkyRally][SETPIECE] boss gag %s (%s)", zone, boss.name))
	Kit.animate(gag.seconds + 0.2, function(_k: number, t: number)
		local anchor = anchorFrame(ahead)
		if not anchor then
			return
		end
		local p, yaw, pitch, roll = Rules.gagPose(gag, math.min(t, gag.seconds))
		local centre = anchor * (p + Vector3.yAxis * half)
		local rot = anchor.Rotation * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.Angles(0, 0, roll)
		local creature = CFrame.new(centre) * rot * CFrame.new(-cIn)
		if not poofed then
			proxy:PivotTo(creature * meshInHull)
		end
		local clip, rate = Rules.gagClip(gag, t)
		stepRig(rig, clip, rate, t - last)
		-- events in (last, t]
		for _, ev in Rules.gagEvents(gag, last, t) do
			local ground = anchor * Vector3.new(p.X, 0.3, p.Z)
			if ev == "slam" or ev == "slam_small" then
				local big = ev == "slam"
				Kit.burst("slam", Kit.up(ground), if big then 1 else 0.5)
				Kit.sfx("gag_slam", "boss_tumble", centre, if big then 1 else 0.6, if big then 1 else 1.25, 400)
				Kit.trauma(if big then 0.35 else 0.15)
			elseif ev == "smoke" then
				smokeUntil = t + 1.0
			elseif ev == "dizzy" then
				dizzyUntil = t + 1.1
				Kit.sfx("gag_tweet", "dizzy_tweets", centre + Vector3.yAxis * half, 0.8, 1, 300)
			elseif ev == "roar" then
				Kit.sfx("gag_roar", roarCue, centre, 1, Rules.SQUEAK_SPEED, 500)
				Kit.text("gag_roar", "squeak!", Color3.fromRGB(255, 236, 160), centre + Vector3.yAxis * (half + 6), 10, 3.5, 1.2, 4)
			elseif ev == "freeze" then
				ice = iceBlock(bsize * 1.15)
				Kit.burst("ice", Kit.up(centre), 1)
				Kit.sfx("gag_ice", "ice_freeze", centre, 1, 1, 400)
			elseif ev == "shatter" then
				if ice then
					ice:Destroy()
					ice = nil
				end
				Kit.burst("shards", Kit.up(centre), 1)
				Kit.burst("ice", Kit.up(centre), 0.6)
			elseif ev == "flip" or ev == "boing" then
				Kit.sfx("gag_flip", if ev == "flip" then "shell_flip" else "hop_boing", centre, 1, 1, 400)
			elseif ev == "sputter" then
				Kit.burst("smoke", Kit.up(centre + Vector3.yAxis * half * 0.6), 1)
				Kit.sfx("gag_sputter", "start_flood", centre, 1, 0.8, 400)
			elseif ev == "wheels" then
				wheelsAt = t
				Kit.sfx("gag_wheels", "wheels_off", centre, 1, 1, 400)
			elseif ev == "sparks" then
				sparkUntil = t + 1.0
			elseif ev == "flag" then
				flag = whiteFlag()
			elseif ev == "poof" then
				poofed = true
				Kit.burst("poof", Kit.up(centre), 1.2)
				Kit.sfx("gag_poof", "retire_poof", centre, 1, 1, 400)
				Kit.hideModel(proxy, true)
				task.spawn(pcall, function() -- moments VFX: chained explosions, shockwave, debris, reward rain
					(require(script.Parent:WaitForChild("CelebrationFx")) :: any).bossFinale(centre, anchor.LookVector, math.max(bsize.X, bsize.Z), half)
				end)
			end
		end
		-- continuous bits
		if ice then
			ice.CFrame = CFrame.new(centre) * rot
		end
		if flag and flag.Parent then
			local rise = math.clamp((t - 2.0) / 0.4, 0, 1)
			local top = centre + rot.UpVector * (half * 0.7 + 1 + 2.5 * rise)
			local pole = flag:FindFirstChild("Pole") :: BasePart
			local cloth = flag:FindFirstChild("Cloth") :: BasePart
			pole.CFrame = CFrame.new(top) * rot
			cloth.CFrame = CFrame.new(top) * rot * CFrame.new(1.25, 1.6, 0) * CFrame.Angles(0, math.sin(t * 9) * 0.3, 0)
		end
		if wheelsAt then
			local u = math.clamp((t - wheelsAt) / 1.2, 0, 1)
			for i, w in rig.wheels do
				-- each wheel pops a beat after the last, flies outward, bounces and rolls away under the road
				local k = math.clamp(u * 1.6 - (i - 1) * 0.15, 0, 1)
				local side = if i % 2 == 0 then 1 else -1
				local worldOut = rot.RightVector * side * (30 * k) + Vector3.yAxis * (7 * math.sin(math.pi * math.min(k * 1.4, 1)) - 9 * k * k)
				local local_ = w.WorldCFrame:VectorToObjectSpace(worldOut)
				w.Transform = CFrame.new(local_) * CFrame.Angles(k * 20, 0, 0)
			end
		end
		if t >= nextFx then
			nextFx = t + 0.1
			if t < smokeUntil then
				Kit.burst("smoke", Kit.up(centre), 0.6)
			end
			if t < sparkUntil then
				Kit.burst("sparks", CFrame.lookAt(anchor * Vector3.new(p.X, 0.4, p.Z), anchor * Vector3.new(p.X, 0.4, p.Z + 4)), 0.8)
			end
			if t < dizzyUntil then
				local a = t * 9
				Kit.burst("stars", Kit.up(centre + Vector3.yAxis * (half + 2) + Vector3.new(math.cos(a) * 4, 0, math.sin(a) * 4)), 0.25)
			end
		end
		last = t
	end, function()
		proxy:Destroy()
		if ice then
			ice:Destroy()
		end
		if flag then
			flag:Destroy()
		end
		gagRunning = false
		if TrackFlow and type(TrackFlow.toast) == "function" then
			pcall(TrackFlow.toast, string.format("%s RETIRES TO CENTRAL ISLAND!", string.upper(boss.name)), boss.accent, 4)
		end
	end)
end

local function onRaceEvent(kind: any, payload: any)
	-- L30: with 2+ humans the boss is beaten by any human who finished ahead of it (beatBoss), not only rank 1.
	if kind == "RaceFinished" and type(payload) == "table" and (payload.rank == 1 or payload.beatBoss == true) then
		local mode = RaceAttr.mine("RaceMode")
		if mode ~= "boss" and mode ~= "rematch" then
			return
		end
		local real = bossModel()
		local zone = real and real:GetAttribute("BossZone")
		if real and type(zone) == "string" then
			playGag(zone, real)
		end
	elseif kind == "RaceReset" or kind == "CarMounted" then
		restoreBoss()
	end
end

---------------------------------------------------------------------------------------------------- retired bosses

type Retired = {
	zone: string,
	model: Model,
	rig: Rig,
	home: Vector3,
	lift: number, -- pivot height over the floor for an upright model
	yawFix: CFrame,
	pending: number,
	nextRoar: number,
	roarUntil: number,
	t: number,
}

local retired: { [string]: Retired } = {}
local retiredFolder: Folder? = nil
local retireConn: RBXScriptConnection? = nil
local buildToken = 0

local function clearRetired()
	for _, r in retired do
		r.model:Destroy()
	end
	table.clear(retired)
	if retireConn then
		retireConn:Disconnect()
		retireConn = nil
	end
end

local function hubRoot(): Instance?
	if RaceAttr.mine("ActiveTrackId") ~= "HUB-0" or RaceAttr.mine("RaceMode") ~= "hub" then
		return nil
	end
	return TrackRegistry.getRoot()
end

local function plazaCentre(root: Instance): Vector3?
	local spawn = workspace:GetAttribute("HubSpawnCF")
	if typeof(spawn) == "CFrame" then
		return spawn.Position
	end
	local sum, n = Vector3.zero, 0
	for _, z in { "DINO", "SNOW", "ISLAND", "FOREST", "SPACE" } do
		local arch = root:FindFirstChild("PortalArch_" .. z, true)
		if arch and arch:IsA("Model") then
			sum += arch:GetPivot().Position
			n += 1
		end
	end
	return if n > 0 then sum / n else nil
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundUnder(p: Vector3, skip: { Instance }): number?
	groundParams.FilterDescendantsInstances = skip
	local hit = workspace:Raycast(p + Vector3.yAxis * 80, Vector3.yAxis * -200, groundParams)
	return if hit then hit.Position.Y else nil
end

local function stepRetired(dt: number)
	local cam = Kit.camPos()
	for _, r in retired do
		r.pending = math.min(r.pending + dt, 0.5)
		local d = (r.home - cam).Magnitude
		local stepEvery = Rules.retireStep(d)
		if stepEvery < 0 or r.pending < stepEvery then
			continue
		end
		local adv = r.pending
		r.pending = 0
		r.t += adv
		local spec = Rules.RETIRE[r.zone]
		local off, heading = Rules.retirePose(r.zone, r.t)
		local pos = r.home + off + Vector3.yAxis * (spec.up + r.lift)
		r.model:PivotTo(CFrame.lookAt(pos, pos + heading) * r.yawFix)
		if r.t >= r.nextRoar then
			-- now and then the old boss remembers itself: a roar (quieter than in its race), heard close by only
			r.nextRoar = r.t + spec.roarEvery * (0.8 + math.random() * 0.4)
			r.roarUntil = r.t + 1.4
			if d < 220 then
				local boss = BossConfig.forZone(r.zone)
				if boss then
					Kit.sfx("retired_" .. r.zone, "roar_" .. string.lower(boss.clips or boss.name), pos, 0.45, 1, 220)
				end
			end
		end
		local roaring = r.t < r.roarUntil and r.rig.mod ~= nil and (r.rig.mod :: any).clips.roar ~= nil
		stepRig(r.rig, if roaring then "roar" else spec.base, if r.zone == "ISLAND" and not roaring then 0.8 else 1, adv)
	end
end

local function nameplate(model: Model, boss: BossConfig.Boss, height: number)
	local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not part then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "RetiredPlate"
	bb.Size = UDim2.fromOffset(170, 34)
	bb.StudsOffsetWorldSpace = Vector3.new(0, height + 3, 0)
	bb.MaxDistance = 130
	bb.LightInfluence = 0
	bb.Parent = part
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = boss.accent
	t.Text = string.upper(boss.name) .. " (retired)"
	t.Parent = bb
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(30, 18, 10)
	s.Thickness = 2
	s.Parent = t
end

local function buildRetired()
	buildToken += 1
	local my = buildToken
	clearRetired()
	local root = hubRoot()
	if not root then
		return
	end
	local text = LocalPlayer:GetAttribute("BossesBeaten")
	local list = {}
	if type(text) == "string" and text ~= "" then
		list = string.split(text, ",")
	end
	local zones = Rules.retiredZones(list)
	if #zones == 0 then
		return
	end
	if not retiredFolder or not retiredFolder.Parent then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRetiredBosses"
		f.Parent = workspace
		retiredFolder = f
	end
	local centre = plazaCentre(root)
	task.spawn(function()
		local templates = ReplicatedStorage:WaitForChild("SkyRallyRetiredBosses", 30)
		if not templates or my ~= buildToken then
			return
		end
		for _, zone in zones do
			local spec = Rules.RETIRE[zone]
			local boss = BossConfig.forZone(zone)
			local arch = root:FindFirstChild("PortalArch_" .. spec.portal, true)
			if not boss or not arch or not arch:IsA("Model") or not centre then
				continue
			end
			local template = templates:WaitForChild(zone, 20)
			if my ~= buildToken or not template or not template:IsA("Model") then
				continue
			end
			local m = template:Clone()
			stripPhysics(m)
			m.Name = "Retired_" .. zone
			m.Parent = retiredFolder
			local bcf, bsize = arch:GetBoundingBox()
			local archBase = Vector3.new(bcf.X, bcf.Y - bsize.Y * 0.5, bcf.Z)
			local out = Vector3.new(archBase.X - (centre :: Vector3).X, 0, archBase.Z - (centre :: Vector3).Z)
			out = if out.Magnitude > 1e-3 then out.Unit else Vector3.new(0, 0, -1)
			local right = Vector3.new(-out.Z, 0, out.X)
			local spot = archBase + out * spec.out + right * spec.side
			local floor = groundUnder(spot, { (retiredFolder :: any) :: Instance }) or archBase.Y
			-- upright model: pivot height over its lowest point
			local yawFix = CFrame.Angles(0, math.rad(boss.yawOffset), 0)
			m:PivotTo(CFrame.new(spot) * yawFix)
			local mcf, msize = m:GetBoundingBox()
			local lift = spot.Y - (mcf.Y - msize.Y * 0.5)
			local scale = template:GetAttribute("BossScale") :: number? or 1
			local r: Retired = {
				zone = zone,
				model = m,
				rig = newRig(m, boss, scale),
				home = Vector3.new(spot.X, floor, spot.Z),
				lift = lift,
				yawFix = yawFix,
				pending = 1,
				nextRoar = spec.roarEvery * (0.5 + math.random()),
				roarUntil = 0,
				t = 0,
			}
			nameplate(m, boss, msize.Y - lift)
			retired[zone] = r
			print(string.format("[SkyRally][SETPIECE] retired %s at (%.0f,%.0f,%.0f) style=%s", zone, spot.X, floor, spot.Z, spec.style))
		end
		if my == buildToken and next(retired) and not retireConn then
			retireConn = RunService.Heartbeat:Connect(function(dt: number)
				local ok, err = pcall(function()
					stepRetired(dt)
				end)
				if not ok then
					warn("[SkyRally][SETPIECE] retired bosses: " .. tostring(err))
				end
			end)
		end
	end)
end

---------------------------------------------------------------------------------------------------- init

function BossRetirement.init(trackFlow: any)
	TrackFlow = trackFlow
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		local ev = remotes and remotes:WaitForChild("RaceEventRemote", 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(onRaceEvent)
		end
	end)
	local function relevant()
		-- a new map, a new mode or a new beaten list: rebuild once the switch settles
		if workspace:GetAttribute("TrackSwitching") == true then
			clearRetired()
			restoreBoss()
			return
		end
		task.delay(1.5, buildRetired)
	end
	RaceAttr.changed("ActiveTrackId", relevant)
	RaceAttr.changed("RaceMode", relevant)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(relevant)
	LocalPlayer:GetAttributeChangedSignal("BossesBeaten"):Connect(relevant)
	RaceAttr.changed("RaceGoTime", restoreBoss)
	workspace:GetAttributeChangedSignal("BossGagTest"):Connect(function()
		local zone = workspace:GetAttribute("BossGagTest")
		if type(zone) == "string" and zone ~= "" then
			workspace:SetAttribute("BossGagTest", nil)
			local real = bossModel()
			playGag(zone, if real and real:GetAttribute("BossZone") == zone then real else nil)
		end
	end)
	workspace:GetAttributeChangedSignal("RetiredTest"):Connect(function()
		if workspace:GetAttribute("RetiredTest") == true then
			workspace:SetAttribute("RetiredTest", nil)
			buildRetired()
		end
	end)
	relevant()
end

return BossRetirement
