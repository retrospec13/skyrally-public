--!strict
-- Podium ceremony with the Participation Crate (REMARKABLE Batch 2 item 30). Client only, display only, 7 s (v38-flow).
--
-- After the local player's finish (and the photo cam, if any), the camera cuts to a floating sky island high above the
-- track: a drumroll, then the top three's real cars (display copies, liveries and all) drop onto the 3-2-1 steps one by
-- one, the winner last with a confetti pop that lands on the drumroll's crash, and does a hop and a spin. Name tags
-- float over them (YOU! on yours). If you finished off the podium, the camera swings to the grass beside it where your
-- car is parked: a whistle, and a wooden PARTICIPATION crate falls out of the sky with a thud, its lid pops off to a
-- kazoo "ta-daa" and out comes what the server already paid you this race (+N GEARS, when the Garage shows Gears) or a
-- cardboard medal with a kind line (FinaleRules.crateContents: never a new reward, never "loser" wording).
-- The first ceremony of a session always plays; from the second one on a SKIP button (and A / B / Enter / Space)
-- ends it at once. The place jingle (client/Music) plays under it, so the ceremony brings no fanfare of its own.
-- Cost: the stage (about 40 parts) is built once and parked out of the world between ceremonies; four display copies
-- per ceremony, destroyed after; one RenderStepped camera function while it runs.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local FinaleRules = require(Shared:WaitForChild("FinaleRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
local DisplayCars = require(script.Parent:WaitForChild("DisplayCars"))
local FinishLighting = require(script.Parent:WaitForChild("FinishLighting"))
local UiSkin = require(script.Parent:WaitForChild("UiSkin")) -- v3 faces and keys

local LocalPlayer = Players.LocalPlayer

local PodiumCeremony = {}

local STAGE_HEIGHT = 1600 -- above the camera's position at the finish: clear sky on every launch map
local CAR_MAX = 8.4 -- longest side of a display copy: v20 12 -> 8.4 = one step's footprint (8.5), so neighbours' wings no longer overlap
local GOLD = Color3.fromRGB(255, 206, 72)
local SILVER = Color3.fromRGB(206, 214, 226)
local BRONZE = Color3.fromRGB(205, 128, 72)
local CREAM = Color3.fromRGB(250, 242, 222)
local INK = Color3.fromRGB(40, 22, 12)
local WOOD = Color3.fromRGB(150, 104, 62)
local WOOD_DARK = Color3.fromRGB(98, 64, 36)

-- Step tops (stage space: +Z toward the camera, steps face +Z).
local STEPS = {
	{ x = 0, h = 6, color = GOLD, label = "1" },
	{ x = -9, h = 4, color = SILVER, label = "2" },
	{ x = 9, h = 2.6, color = BRONZE, label = "3" },
}
local CRATE_SPOT = Vector3.new(22, 0, 9) -- the grass beside the podium where an off-podium finisher parks
local MY_SPOT = Vector3.new(16, 0, 10)
local ISLAND_LOCAL = CFrame.new(0, -3.5, 2) * CFrame.Angles(0, 0, math.rad(90)) -- the stage's pivot part in stage space
local CRATE_LOCAL = CFrame.new(0, 1.8, 0) -- the crate's pivot (its box) above the spot it stands on

local views = 0
local stage: Model? = nil
local crate: Model? = nil
local crateLid: BasePart? = nil
local crateSign: TextLabel? = nil
local lidLocal = CFrame.new()
local prizeLocal = CFrame.new()
local tags: { BillboardGui } = {}
local gui: ScreenGui? = nil
local titleLabel: TextLabel? = nil
local skipButton: TextButton? = nil
local running = false
local skipFlag = false

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function faceLabel(p: BasePart, face: Enum.NormalId, text: string, color: Color3): TextLabel
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.LightInfluence = 0.2
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 30
	sg.Parent = p
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Font = Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = color
	l.Text = text
	l.Parent = sg
	local s = Instance.new("UIStroke")
	s.Color = INK
	s.Thickness = 3
	s.Parent = l
	return l
end

local function buildStage(): Model
	local m = Instance.new("Model")
	m.Name = "SkyRallyPodium"
	local island = part(m, Vector3.new(7, 64, 64), ISLAND_LOCAL, Color3.fromRGB(104, 178, 72), Enum.Material.Grass, Enum.PartType.Cylinder)
	m.PrimaryPart = island
	-- v19: the tilted cube's corner poked ~10 studs above the island and hid the 1st-place step; sunk so its top corner stays under the grass
	part(m, Vector3.new(24, 20, 24), CFrame.new(0, -30, 2) * CFrame.Angles(math.rad(45), math.rad(20), math.rad(45)), Color3.fromRGB(150, 120, 92), Enum.Material.Slate)
	part(m, Vector3.new(14, 14, 14), CFrame.new(-6, -40, 4) * CFrame.Angles(math.rad(30), math.rad(60), 0), Color3.fromRGB(130, 104, 80), Enum.Material.Slate)
	for i, c in { Vector3.new(-30, -6, 14), Vector3.new(30, -5, 12), Vector3.new(-18, -10, 30), Vector3.new(20, -9, 32), Vector3.new(0, -12, 34), Vector3.new(-34, -2, -10), Vector3.new(34, -3, -8) } do
		local d = 10 + (i % 3) * 4
		part(m, Vector3.new(d, d * 0.7, d), CFrame.new(c), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, Enum.PartType.Ball).Transparency = 0.08
	end
	for _, s in STEPS do
		local block = part(m, Vector3.new(8.5, s.h, 8), CFrame.new(s.x, s.h / 2, 0), s.color, Enum.Material.SmoothPlastic)
		faceLabel(block, Enum.NormalId.Back, s.label, CREAM) -- Back is +Z: the side the camera sees
		part(m, Vector3.new(8.9, 0.5, 8.4), CFrame.new(s.x, s.h + 0.25, 0), CREAM)
	end
	-- the banner arch behind the steps
	for _, x in { -15, 15 } do
		part(m, Vector3.new(1.6, 18, 1.6), CFrame.new(x, 9, -7), WOOD_DARK, Enum.Material.Wood)
	end
	local banner = part(m, Vector3.new(30, 4.5, 0.6), CFrame.new(0, 16.5, -7), WOOD, Enum.Material.WoodPlanks)
	banner.Name = "Banner"
	-- No text on the banner: the track name is the ceremony's GUI title, and at 844x390 the two lines landed on top of each
	-- other ("TOP OF THE SKY" under "MONORAIL NEON GRID", Studio 2026-10-19).
	-- the Participation Crate (lid separate, so it can pop)
	local cm = Instance.new("Model")
	cm.Name = "ParticipationCrate"
	local box = part(cm, Vector3.new(4.4, 3.6, 4.4), CFrame.new(0, 1.8, 0), WOOD, Enum.Material.WoodPlanks)
	cm.PrimaryPart = box
	for _, y in { 0.5, 3.1 } do
		part(cm, Vector3.new(4.6, 0.4, 4.6), CFrame.new(0, y, 0), WOOD_DARK, Enum.Material.Wood)
	end
	local stamp = part(cm, Vector3.new(4.42, 1.4, 4.42), CFrame.new(0, 1.8, 0), WOOD, Enum.Material.WoodPlanks)
	stamp.Transparency = 1
	faceLabel(stamp, Enum.NormalId.Back, "PARTICIPATION", Color3.fromRGB(214, 48, 40))
	local lid = part(cm, Vector3.new(4.8, 0.5, 4.8), CFrame.new(0, 3.85, 0), WOOD_DARK, Enum.Material.WoodPlanks)
	lid.Name = "Lid"
	local prize = part(cm, Vector3.new(3.6, 2.2, 0.2), CFrame.new(0, 1.4, 0), Color3.fromRGB(196, 160, 110), Enum.Material.Cardboard)
	prize.Name = "Prize"
	local sign = faceLabel(prize, Enum.NormalId.Back, "", INK)
	crate, crateLid, crateSign = cm, lid, sign
	lidLocal = box.CFrame:ToObjectSpace(lid.CFrame)
	prizeLocal = box.CFrame:ToObjectSpace(prize.CFrame)
	cm.Parent = m
	FinishLighting.buildStageLights(m) -- own key / fill / rim lights: the podium reads on any map
	return m
end

local function buildGui(): ScreenGui
	local g = gui
	if g and g.Parent then
		return g
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyPodium"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 23
	sg.Enabled = false
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0.5, 0)
	-- Under the stage's (blank) 3D banner, which the camera crops at the top edge, and the HUD's top-centre
	-- collectible sign is hidden for the ceremony (HudPhase), so the three titles never stack.
	t.Position = UDim2.fromScale(0.5, 0.14)
	t.Size = UDim2.fromScale(0.7, 0.09)
	-- v3: the kit's condensed display face, two tones (first word yellow), soft outline
	t.FontFace = UiSkin.font("display")
	t.TextScaled = true
	t.RichText = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.Parent = sg
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(11, 21, 51)
	ts.Thickness = 2
	ts.Transparency = 0.2
	ts.Parent = t
	local b = UiSkin.button(sg, "sky", "SKIP  \u{00BB}", { name = "Skip", variant = "sky", anchor = Vector2.new(1, 1), position = UDim2.new(1, -16, 1, -16), size = UDim2.fromOffset(150, 48), S = 1, sound = "tap" }) :: TextButton
	b.Visible = false
	b.Activated:Connect(function()
		skipFlag = true
	end)
	gui, titleLabel, skipButton = sg, t, b
	return sg
end

local function nameTag(adornee: BasePart, text: string, mine: boolean, color: Color3)
	local bb = Instance.new("BillboardGui")
	bb.Name = "PodiumTag"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(if mine then 110 else 150, if mine then 44 else 30)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Font = Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = color
	l.Text = text
	l.Parent = bb
	local s = Instance.new("UIStroke")
	s.Color = INK
	s.Thickness = 2.5
	s.Parent = l
	bb.Parent = LocalPlayer:WaitForChild("PlayerGui")
	table.insert(tags, bb)
end

local function displayName(row: any): string
	-- (economy v3 phase 4) the server marks only the viewer's own row isPlayer now; every row is looked up by account name
	-- (a bot's generated name is never a player's), so humans and bots read alike
	local p = Players:FindFirstChild(tostring(row.name))
	if p and p:IsA("Player") then
		return p.DisplayName
	end
	return tostring(row.name)
end

local function skipAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		skipFlag = true
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- Waits `seconds`, returning early (true) on a skip or when the race is gone.
local function hold(seconds: number, alive: () -> boolean): boolean
	local untilT = os.clock() + seconds
	while os.clock() < untilT do
		if skipFlag or not alive() then
			return true
		end
		task.wait()
	end
	return skipFlag or not alive()
end

-- Plays the ceremony for a RaceFinished payload; yields until it ends (4 s, or a skip). alive() false aborts it
-- (a replay or a track switch). Returns without doing anything when the mode or field does not qualify.
function PodiumCeremony.play(payload: any, alive: () -> boolean)
	if running or type(payload) ~= "table" or type(payload.standings) ~= "table" then
		return
	end
	local mode = RaceAttr.mine("RaceMode")
	if not FinaleRules.ceremonyEligible(mode, #payload.standings) then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	running = true
	skipFlag = false
	local canSkip = FinaleRules.canSkip(views)
	views += 1
	local pick = FinaleRules.podium(payload.standings, LocalPlayer.Name)
	local st = stage or buildStage()
	stage = st
	local base = CFrame.new(cam.CFrame.Position.X, cam.CFrame.Position.Y + STAGE_HEIGHT, cam.CFrame.Position.Z)
	st:PivotTo(base * ISLAND_LOCAL) -- the island part is the pivot: the stage's origin lands on `base`
	st.Parent = workspace
	local info = TrackInfo.get(payload.trackId)
	local sg = buildGui()
	sg.Enabled = true
	HudPhase.setPodium(true) -- hides the race HUD and the collectible sign
	local title = titleLabel :: TextLabel
	-- payload.title: the Grand Prix's final ceremony names the cup instead of the track (client/GrandPrixClient).
	title.Text = UiSkin.twoTone(if type(payload.title) == "string" then string.upper(payload.title) elseif info then string.upper(info.trackName) else "PODIUM")
	local skip = skipButton :: TextButton
	skip.Visible = false
	-- v38-flow: SKIP (and A / B / Enter / Space) arrives after SKIP_AFTER seconds, every ceremony.
	task.delay(FinaleRules.SKIP_AFTER, function()
		if running and canSkip then
			skip.Visible = true
			ContextActionService:BindActionAtPriority("SkyRallyPodiumSkip", skipAction, false, Enum.ContextActionPriority.High.Value + 20,
				Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonB, Enum.KeyCode.Return, Enum.KeyCode.Space)
		end
	end)
	-- The cars: copies of the real models, hidden above their steps until they drop.
	local copies: { Model } = {}
	local placed: { { model: Model, rest: CFrame } } = {}
	for i, row in { pick.first, pick.second, pick.third } do
		if row then
			local live = DisplayCars.findRacer(tostring(row.name), if row.isPlayer == true then true else nil)
			-- v38-flow: withPilot seats the driver's avatar (a player's character is not part of the vehicle model)
			local copy = if live then (DisplayCars.copy(live, CAR_MAX, true)) else nil
			if copy then
				local s = STEPS[i]
				-- Face the camera three-quarter (turned 30 degrees toward the middle).
				local rest = base * CFrame.new(s.x, s.h + 0.5, 0) * CFrame.Angles(0, math.rad(180 + (if s.x < 0 then -25 elseif s.x > 0 then 25 else 0)), 0)
				DisplayCars.place(copy, rest * CFrame.new(0, 40, 0))
				copy.Parent = st
				DisplayCars.pose(copy, nil) -- the sit pose now; the celebration lands after the drops
				table.insert(copies, copy)
				placed[i] = { model = copy, rest = rest }
				if i == 1 then
					-- a warm key light on the winner
					local pp = copy.PrimaryPart or copy:FindFirstChildWhichIsA("BasePart")
					if pp then
						local pl = Instance.new("PointLight")
						pl.Name = "WinnerLight"
						pl.Color = Color3.fromRGB(255, 226, 150)
						pl.Brightness = 2.5
						pl.Range = 16
						pl.Parent = pp
					end
				end
				local mine = pick.me ~= nil and row == pick.me
				nameTag(copy.PrimaryPart or (copy:FindFirstChildWhichIsA("BasePart") :: BasePart), if mine then "YOU!" else displayName(row), mine, if mine then GOLD else CREAM)
			end
		end
	end
	local offPodium = pick.me ~= nil and not pick.meOnPodium
	local myCopy: Model? = nil
	if offPodium then
		local live = DisplayCars.localVehicle()
		local copy = if live then (DisplayCars.copy(live, CAR_MAX, true)) else nil
		if copy then
			DisplayCars.place(copy, base * CFrame.new(MY_SPOT) * CFrame.Angles(0, math.rad(200), 0))
			copy.Parent = st
			DisplayCars.pose(copy, nil)
			table.insert(copies, copy)
			myCopy = copy
		end
	end
	local cr = crate :: Model
	local crateRest = base * CFrame.new(CRATE_SPOT) * CRATE_LOCAL
	cr:PivotTo(crateRest * CFrame.new(0, 60, 0))
	local lid = crateLid :: BasePart
	local sign = crateSign :: TextLabel
	local contents = FinaleRules.crateContents(payload.gears, workspace:GetAttribute("GarageEnabled") == true, if pick.me then pick.me.rank else 4)
	sign.Text = contents.text
	local prize = cr:FindFirstChild("Prize") :: BasePart
	local lidRest = crateRest * lidLocal
	local prizeRest = crateRest * prizeLocal
	-- Camera path (stage space): wide, dolly toward the winner, then either your step or the crate corner.
	-- v20: the vertical FOV is fixed, so a narrow viewport (4:3, portrait) crops the outer steps. Pull the wide and
	-- close shots back until +-REQ_HALF studs of stage fit horizontally, and widen the FOV a little below 16:10.
	local vp = cam.ViewportSize
	local aspect = math.max(vp.X, 1) / math.max(vp.Y, 1)
	local REQ_HALF = 18 -- three steps (+-13.3) plus car overhang and a margin
	local CLOSE_Z = 19 -- the held shot's distance at 16:9-ish aspect
	local camFov = 55 + math.clamp((1.6 - aspect) * 12, 0, 14)
	local fitK = math.max(1, REQ_HALF / (math.tan(math.rad(camFov / 2)) * aspect * CLOSE_Z))
	local function pull(from: Vector3, to: Vector3): Vector3
		return to + (from - to) * fitK
	end
	local wide = base * CFrame.lookAt(pull(Vector3.new(0, 11, 38), Vector3.new(0, 5, 0)), Vector3.new(0, 5, 0))
	local close = base * CFrame.lookAt(pull(Vector3.new(-3, 8, CLOSE_Z), Vector3.new(0, 6.5, 0)), Vector3.new(0, 6.5, 0))
	local mySlot = 0
	for i, row in { pick.first, pick.second, pick.third } do
		if row and pick.me and row == pick.me then
			mySlot = i
		end
	end
	-- v38-flow round 2: off the podium the held shot frames the player's own vehicle and driver (the crate beside it),
	-- not a wide corner of the island
	local finale = if offPodium
		then base * CFrame.lookAt(MY_SPOT + Vector3.new(-3, 5, 12), MY_SPOT + Vector3.new(2.5, 2, 0))
		-- v38-flow (owner: the driver must read clearly): the held shot closes in on the local driver's own step
		elseif mySlot > 0 then base * CFrame.lookAt(Vector3.new(STEPS[mySlot].x * 0.85 - 2, STEPS[mySlot].h + 6, 13), Vector3.new(STEPS[mySlot].x, STEPS[mySlot].h + 2.2, 0))
		else close
	local t0 = os.clock()
	RunService:BindToRenderStep("SkyRallyPodium", Enum.RenderPriority.Last.Value + 3, function()
		local c = workspace.CurrentCamera
		if not c then
			return
		end
		local t = os.clock() - t0
		local cf: CFrame
		if t < 2.2 then
			local k = t / 2.2
			cf = wide:Lerp(close, 1 - (1 - k) * (1 - k))
		else
			local k = math.clamp((t - 2.2) / 0.8, 0, 1)
			cf = close:Lerp(finale, k * k * (3 - 2 * k))
			-- then a slow push-in for the rest of the hold
			local push = math.clamp((t - 3) / 4, 0, 1)
			cf = cf * CFrame.new(0, 0, -3 * push * (2 - push))
		end
		c.CFrame = cf
		c.FieldOfView = camFov
	end)
	PayoffSound.play("drumroll")
	local function drop(i: number, delayS: number)
		local pl = placed[i]
		task.delay(delayS, function()
			if not pl or not pl.model.Parent then
				return
			end
			local v = Instance.new("CFrameValue")
			v.Value = pl.rest * CFrame.new(0, 40, 0)
			local conn = v.Changed:Connect(function(val: CFrame)
				if pl.model.Parent then
					DisplayCars.place(pl.model, val)
				end
			end)
			local tw = TweenService:Create(v, TweenInfo.new(0.42, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), { Value = pl.rest })
			tw.Completed:Connect(function()
				conn:Disconnect()
				v:Destroy()
			end)
			tw:Play()
			task.delay(0.16, function()
				PayoffSound.play("podium_drop", 0.9 + 0.1 * i)
			end)
		end)
	end
	drop(3, 0.25)
	drop(2, 0.65)
	drop(1, 0.9)
	task.delay(1.06, function()
		if not running then
			return
		end
		local Vfx = require(script.Parent:WaitForChild("Vfx")) :: any
		local top = base * CFrame.new(0, STEPS[1].h + 2, 0)
		Vfx.burst("confetti", CFrame.lookAt(top.Position, top.Position + Vector3.yAxis * 50))
		Vfx.burst("finish", top)
		task.spawn(pcall, function() -- moments VFX: the finish show behind the podium (the camera looks along base.LookVector)
			(require(script.Parent:WaitForChild("CelebrationFx")) :: any).finishShow(base.Position, base.LookVector, base.RightVector)
		end)
		PayoffSound.play("confetti_pop")
	end)
	-- the winner's hop and spin, once its bounce onto the top step has settled
	task.delay(1.4, function()
		if not running then
			return
		end
		local pl = placed[1]
		if pl then
			local s0 = os.clock()
			local conn: RBXScriptConnection? = nil
			conn = RunService.RenderStepped:Connect(function()
				local k = (os.clock() - s0) / 0.6
				if k >= 1 or not pl.model.Parent then
					if conn then
						conn:Disconnect()
					end
					if pl.model.Parent then
						DisplayCars.place(pl.model, pl.rest)
					end
					return
				end
				DisplayCars.place(pl.model, pl.rest * CFrame.new(0, 4 * math.sin(k * math.pi), 0) * CFrame.Angles(0, k * math.pi * 2, 0))
			end)
			PayoffSound.play("hop_boing")
		end
	end)
	-- v38-flow: the local driver's celebration by place (FinaleRules.reaction): on the podium once the cars have landed,
	-- off it as the crate opens.
	task.delay(if offPodium then 3.3 else 1.7, function()
		if not running or not pick.me then
			return
		end
		local mine: Model? = myCopy
		for i, row in { pick.first, pick.second, pick.third } do
			if row == pick.me and placed[i] then
				mine = placed[i].model
			end
		end
		-- v38-flow round 2: the drawn shoulder wave was not convincing in captures (the arm stayed in the cockpit), so the
		-- driver keeps the clean seated pose; the moment's reaction is the camera, the light and the winner's hop.
		-- FinaleRules.reaction stays for a ledgered emote later.
		local _ = mine
	end)
	if offPodium then
		task.delay(2.2, function()
			if not running then
				return
			end
			PayoffSound.play("crate_whistle")
			local v = Instance.new("CFrameValue")
			v.Value = crateRest * CFrame.new(0, 60, 0)
			local conn = v.Changed:Connect(function(val: CFrame)
				cr:PivotTo(val)
			end)
			local tw = TweenService:Create(v, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = crateRest })
			tw.Completed:Connect(function()
				conn:Disconnect()
				v:Destroy()
				if not running then
					return
				end
				PayoffSound.play("crate_thud")
				local Vfx = require(script.Parent:WaitForChild("Vfx")) :: any
				Vfx.burst("landDust", crateRest * CFrame.new(0, -1.8, 0))
				lid.CFrame = lidRest
				prize.CFrame = prizeRest
				task.delay(0.3, function()
					if not running then
						return
					end
					PayoffSound.play("crate_kazoo")
					Vfx.burst("confetti", CFrame.lookAt(crateRest.Position + Vector3.yAxis * 4, crateRest.Position + Vector3.yAxis * 60), 0.25)
					TweenService:Create(lid, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						CFrame = lidRest * CFrame.new(2.5, 5, 1.5) * CFrame.Angles(math.rad(70), math.rad(40), math.rad(25)),
					}):Play()
					TweenService:Create(prize, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
						CFrame = prizeRest * CFrame.new(0, 3.6, 0),
					}):Play()
					local mc = myCopy
					if mc and mc.Parent then
						local rest = base * CFrame.new(MY_SPOT) * CFrame.Angles(0, math.rad(200), 0)
						DisplayCars.place(mc, rest * CFrame.new(0, 1.2, 0))
						task.delay(0.15, function()
							if mc.Parent then
								DisplayCars.place(mc, rest)
							end
						end)
					end
				end)
			end)
			tw:Play()
		end)
	end
	hold(FinaleRules.CEREMONY_SECONDS, alive)
	running = false
	RunService:UnbindFromRenderStep("SkyRallyPodium")
	ContextActionService:UnbindAction("SkyRallyPodiumSkip")
	sg.Enabled = false
	HudPhase.setPodium(false)
	for _, tg in tags do
		tg:Destroy()
	end
	table.clear(tags)
	for _, c in copies do
		c:Destroy()
	end
	cr:PivotTo(crateRest)
	lid.CFrame = lidRest
	prize.CFrame = prizeRest
	st.Parent = nil
	print(string.format("[SkyRally][PODIUM] ceremony done skipped=%s offPodium=%s crate=%s", tostring(skipFlag), tostring(offPodium), contents.text))
end

function PodiumCeremony.isRunning(): boolean
	return running
end

return PodiumCeremony
