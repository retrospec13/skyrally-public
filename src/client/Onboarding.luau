--!strict
-- First-session guide (TEST_LIST_LAUNCH L27 "controls overlay at first join (non-modal)"; audit B5). Shown once per account
-- (the server saves the "onboarded" flag and replicates it as the Onboarded player attribute; shared/OnboardingRules holds
-- every word and rule, specced in tools/tests/onboarding_spec.luau):
--   * a goal card at the first spawn in the hub: "Win races, earn Sky Tokens, open new worlds!", how to steer in the active
--     input family's words, and where to go;
--   * the first open portal (DINO) is marked "arch glow" style: its opening rim glows in the portal's own colour and a spinning
--     gem floats in front of it at vehicle height; a landing ring marks the spot with a
--     confetti burst and a chime. All of that is the "world" and only shows while the car is on the hub plaza. Off the plaza a
--     small "!" chip (right of the "?") stands in for it: tap = the way shown for a few seconds, tap again = dismissed.
--     The world and the chip are held (and the goal card with them) during a portal lobby, the Storm match, map switch,
--     loading screen or any race; any race but the Storm match retires the guide for good, the Storm match only holds it
--     (it returns on leaving). A portal driven through (TrackFlow reports it) ends it; ARROW_MAX_SECONDS of plaza time
--     hands over to the chip (docs/design/GUIDE_ARROW.md);
--   * short just-in-time tips at the first moments of the first races, each once: first item balloon (how to fire), first
--     boost, first drift (a plane's first sharp bank), first lap done.
-- Everything is small, non-blocking (no card takes input; any button, key or tap dismisses the card after 1.2 s) and sits at
-- lane A of the HUD (docs/design/HUD_LAYOUT.md: centred in the sky band, clear of the Roblox nav, both HUD columns and the
-- road ahead). The "?" button (also H on a keyboard) is the second button of the HUD's system cluster, right of the gear, and
-- runs the guide again.
-- The client only reports "ready" and "moved" to the server (OnboardingRemote); the server logs the funnels and saves the
-- flag, never this module.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local OnboardingRules = require(Shared:WaitForChild("OnboardingRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))

local LocalPlayer = Players.LocalPlayer

local Onboarding = {}

local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local CREAM = Color3.fromRGB(250, 242, 222)
local RIM = Color3.fromRGB(188, 168, 142)
local GOLD = Color3.fromRGB(255, 214, 90)
local STONE = Color3.fromRGB(128, 116, 100)
local HELP_ACTION = "SkyRallyHelp"

local state = OnboardingRules.newState(false)
local resolved = false -- the saved flag has been read (or the wait ran out)
local startedAt = os.clock()
local remote: RemoteEvent? = nil
local sent: { [string]: boolean } = {}

local gui: ScreenGui? = nil
local helpBtn: TextButton? = nil
local card: Frame? = nil
local cardTitle: TextLabel? = nil
local cardBody: TextLabel? = nil
local cardKind = "" -- "goal" | "tip" | "help" | ""
local cardShownAt = 0
local cardToken = 0

local worldFolder: Folder? = nil
local arrowParts: { { part: Part, offset: CFrame, kind: string } } = {} -- kind: "top" (painted chevron), "outline" (dark-wood underlay), "shadow" (ground patch)
local ARROW_LIFT = 1.6 -- unused since the ground arrow was removed (hub declutter); kept for the update loop's maths
local glow: { zone: string, rim: { Part }, light: PointLight, sparks: { ParticleEmitter }, diamond: Part, dlight: PointLight, dsparks: ParticleEmitter, bucket: number }? = nil
local chip: TextButton? = nil
local chipWanted = false
local ring: { part: Part, fill: Frame, edge: UIStroke, motes: ParticleEmitter, y: number, yAt: number }? = nil
local worldFade = 0 -- 0..1, the whole guide world's alpha (fades in and out over WORLD_FADE seconds)
local resumeAt = 0 -- server time a finished hold lets the guide back
local capHinted = false
local vfxModule: any = nil
local WORLD_FADE = 0.25
local DIAMOND_TILT = CFrame.Angles(math.rad(-35.264), 0, 0) * CFrame.Angles(0, 0, math.rad(45)) -- a cube stood on one corner
local portalPart: BasePart? = nil
local portalFoundFor = ""
local groundParams = RaycastParams.new()

local readyPos: Vector3? = nil
local prevBoost = "None"
local prevSharp = false
local stepAcc = 0

local flightModule: any = nil
local function flight(): any
	-- Lazy: FlightController's own requires reach HudExtras, which requires this module.
	if not flightModule then
		local ok, fc = pcall(function()
			return require(script.Parent:WaitForChild("FlightController"))
		end)
		flightModule = if ok then fc else nil
	end
	return flightModule
end

local function vfx(): any
	-- Lazy: Vfx pulls in BossIntro and the vehicle rigs; the guide only needs it for two bursts.
	if not vfxModule then
		local ok, v = pcall(function()
			return require(script.Parent:WaitForChild("Vfx"))
		end)
		vfxModule = if ok then v else nil
	end
	return vfxModule
end

local function send(action: string)
	local r = remote
	if r and not sent[action] then
		sent[action] = true
		r:FireServer(action)
	end
end

local function family(): OnboardingRules.Family
	return OnboardingRules.family(LocalPlayer:GetAttribute("InputMode"))
end

-- The local vehicle's hull. FlightController binds planes only; a car (the hub, car tracks) is CarController's
-- Car_<name>, so a guide that read FlightController.hull alone never saw a car player as ready: no goal card, ground
-- arrow or portal beacon in the hub (Studio 2026-10-19, out/verify_merge/v5_guide_goal_card.png).
local function vehicleHull(): BasePart?
	local fc = flight()
	local h: BasePart? = if fc then fc.hull else nil
	if h and h.Parent then
		return h
	end
	local planes = workspace:FindFirstChild("Planes")
	local car = planes and planes:FindFirstChild("Car_" .. LocalPlayer.Name)
	return if car and car:IsA("Model") then car.PrimaryPart else nil
end

local function raceMode(): string
	local m = RaceAttr.mine("RaceMode")
	return if type(m) == "string" then m else ""
end

local function vehicleKind(): OnboardingRules.Vehicle
	local info = TrackInfo.get(RaceAttr.mine("ActiveTrackId") :: any)
	return if info and info.vehicle == "plane" then "plane" else "car"
end

local function viewport(): Vector2
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

-- Same size classes as RaceUI.updateResponsiveLayout: desktop, phone, compact phone (740x360).
local function scaleOf(vp: Vector2): (number, number)
	if vp.Y >= 600 then
		return 1.5, 28
	elseif vp.Y <= 375 then
		return 1, 14
	end
	return 1.15, 18
end

------------------------------------------------------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------------------------------------------------------

local function stroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
end

local function textLabel(parent: Instance, name: string, font: Enum.Font, color: Color3, order: number): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.Size = UDim2.fromScale(1, 0)
	t.Font = font
	t.TextColor3 = color
	t.TextWrapped = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.LayoutOrder = order
	t.Active = false
	t.Parent = parent
	stroke(t, WOOD_DARK, 1.2)
	return t
end

-- Where the card rests: top-centre of lane A (HudLayoutRules), as wide as the lane lets it be.
local function cardRest(): (UDim2, number)
	local vp = viewport()
	local lane = HudMetrics.rects().laneA
	local want = if cardKind == "goal" then math.clamp(vp.X * 0.38, 230, 460) else math.clamp(vp.X * 0.31, 200, 380)
	local width = math.min(want, lane.w)
	-- v28 W1.26: race tips (LAP DONE, ITEM READY, drift) rest in the lower third, off the route; the goal and help cards stay up top.
	local y = if cardKind == "tip" then math.floor(vp.Y * 0.7) else math.floor(lane.y)
	return UDim2.fromOffset(math.floor(lane.x + lane.w / 2), y), math.floor(width + 0.5)
end

local function sizeCard()
	local c, tt, bb = card, cardTitle, cardBody
	if not c or not tt or not bb then
		return
	end
	local vp = viewport()
	local k = scaleOf(vp)
	local pos, width = cardRest()
	c.Size = UDim2.fromOffset(width, 0)
	tt.TextSize = math.floor(15 * k)
	bb.TextSize = math.floor(12.5 * k)
	if cardToken > 0 and c.Visible then
		c.Position = pos
	end
end

local function hideCard(kind: string?)
	local c = card
	if not c or not c.Visible then
		return
	end
	if kind and kind ~= cardKind then
		return
	end
	cardToken += 1
	local my = cardToken
	local wasTip = cardKind == "tip"
	cardKind = ""
	local out = TweenService:Create(c, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.fromOffset(c.Position.X.Offset, c.Position.Y.Offset + (if wasTip then 80 else -c.AbsoluteSize.Y - 40)) })
	out:Play()
	out.Completed:Connect(function()
		if cardToken == my then
			c.Visible = false
		end
	end)
end

-- The results card (client/RaceUI FinishPositionScreen) is up: tips and the goal card stay down, they covered its standings rows.
local function resultsUp(): boolean
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local m = if pg then pg:FindFirstChild("FinishPositionScreen", true) else nil
	return m ~= nil and m:IsA("GuiObject") and m.Visible
end

local function showCard(kind: string, title: string, body: string, seconds: number)
	local c, tt, bb = card, cardTitle, cardBody
	if not c or not tt or not bb then
		return
	end
	if kind ~= "help" and resultsUp() then
		return
	end
	cardToken += 1
	local my = cardToken
	cardKind = kind
	cardShownAt = os.clock()
	tt.Text = title
	bb.Text = body
	sizeCard()
	local pos = cardRest()
	c.Position = UDim2.fromOffset(pos.X.Offset, pos.Y.Offset + (if kind == "tip" then 80 else -80))
	c.Visible = true
	TweenService:Create(c, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = pos }):Play()
	UiSound.play("tab", nil, 0.5)
	task.delay(seconds, function()
		if cardToken == my then
			hideCard(kind)
		end
	end)
end

local function showTip(id: string)
	-- v21 (hud critic 1): in a battle the plaque and the caption lane already fill the top-centre and lane A sits on the kart
	-- on a phone; the objective line carries the guidance, so no tip card is stacked on top of them.
	if RaceAttr.mine("RaceMode") == "battle" then
		return
	end
	local lapsLeft = OnboardingRules.lapsLeft(LocalPlayer:GetAttribute("Lap") :: any, RaceAttr.mine("TotalLaps") :: any)
	local tip = OnboardingRules.tip(id, family(), vehicleKind(), lapsLeft)
	if tip then
		showCard("tip", tip.title, tip.body, OnboardingRules.TIP_SECONDS)
	end
end

local function showGoal()
	state.goalShown = true
	local lines = OnboardingRules.goalLines(family())
	showCard("goal", OnboardingRules.GOAL_TITLE, table.concat(lines, "\n"), OnboardingRules.GOAL_SECONDS)
end

local function showHelp()
	local lines = OnboardingRules.helpLines(family(), vehicleKind())
	showCard("help", "HOW TO PLAY", table.concat(lines, "\n"), 9)
end

------------------------------------------------------------------------------------------------------------------------
-- The "?" button
------------------------------------------------------------------------------------------------------------------------

-- HUD layout v2: "?" is the second button of the system cluster, right of the gear under the Roblox nav (HudLayoutRules
-- rects.help, 44 px minimum). The gear and the token chip are no longer anchors.
local function layoutHelp()
	local b = helpBtn
	if not b then
		return
	end
	local r = HudMetrics.rects().help
	b.Position = UDim2.fromOffset(r.x, r.y)
	b.Size = UDim2.fromOffset(r.w, r.h)
end

-- The "!" chip (off the plaza): see OnboardingRules.chipRect for where it sits.
local function layoutChip()
	local c = chip
	if not c then
		return
	end
	local rects = HudMetrics.rects()
	local r = OnboardingRules.chipRect(rects.help, rects.token, rects.laneA)
	if rects.minimap then
		-- Racing (HUD_MK_LAYOUT.md 3): the "?" stands left of the right column, so the chip goes under it, not beside it.
		r = { x = rects.help.x, y = rects.help.y + rects.help.h + 6, w = rects.help.w, h = rects.help.h }
	end
	c.Position = UDim2.fromOffset(r.x, r.y)
	c.Size = UDim2.fromOffset(r.w, r.h)
end

local function applyChip()
	local c = chip
	if not c then
		return
	end
	local want = chipWanted and state.guideOn
	if c.Visible ~= want then
		c.Visible = want
		if want then
			layoutChip()
		end
	end
	if want then
		c.Text = if os.clock() < state.peekUntil then "x" else "!" -- while the way is shown, tapping again dismisses
	end
end

local function replay()
	OnboardingRules.replay(state)
	capHinted = false
	resolved = true
	hideCard(nil)
	if raceMode() == "hub" then
		return -- the step loop shows the goal card again and the arrow resumes
	end
	state.goalShown = true
	showHelp()
end

------------------------------------------------------------------------------------------------------------------------
-- World: ground arrow, landing ring, arch glow and gem
------------------------------------------------------------------------------------------------------------------------

local function worldPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.Transparency = 1
	p.Parent = worldFolder
	return p
end

local function ensureWorld()
	if worldFolder and worldFolder.Parent then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "SkyRallyGuideWorld"
	f.Parent = workspace
	worldFolder = f
	table.clear(arrowParts)
	-- Hub declutter (owner 2026-10-21): the big amber ground arrow is gone ("beyond obnoxious"). No arrow part is ever
	-- built (arrowParts stays empty), so no opaque floor shape exists; the guide is the arch glow, the landing ring, the
	-- gem and the goal card. A pointer, if one is ever wanted, must be small and semi-transparent (>= 0.6 Transparency).
end

local function clearWorld()
	if worldFolder then
		worldFolder:Destroy()
	end
	worldFolder = nil
	glow = nil
	ring = nil
	worldFade = 0
	table.clear(arrowParts)
end

-- The first open race portal's fx part in the hub map (StreamingEnabled is off, so it is always there once the map is).
local function findPortal(zone: string): BasePart?
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	if not root then
		return nil
	end
	local part = root:FindFirstChild("PortalShimmer_" .. zone, true)
	return if part and part:IsA("BasePart") then part else nil
end

local lastStates = ""
local lastZone: string? = nil
local function targetZone(): string?
	local raw = LocalPlayer:GetAttribute("PortalStates")
	if type(raw) ~= "string" then
		return nil
	end
	if raw ~= lastStates then
		-- The server rewrites PortalStates on every token change; decode only when it did.
		lastStates = raw
		lastZone = nil
		local ok, decoded = pcall(function()
			return game:GetService("HttpService"):JSONDecode(raw)
		end)
		if ok and type(decoded) == "table" then
			local st = OnboardingRules.firstOpenPortal(decoded)
			lastZone = if st then st.zone else nil
		end
	end
	return lastZone
end

-- The portal's own colour (its veil), not the track accent: the rim and gem must read as that arch.
local function zoneColor(zone: string): Color3
	local hex = OnboardingRules.PORTAL_COLORS[zone]
	return if hex then Color3.fromHex(hex) else GOLD
end

-- Arch glow: a neon rim just inside the arch opening (two posts and a semicircle, in the shimmer's frame: opening 24 wide,
-- spring 9 over the pivot, base 10.2 under it; tools/map/author_hub0.py portal_arch), a soft light, sparks rising along the
-- posts, and a gem (a cube stood on its corner) floating in front of the arch. Nothing collides and nothing is tall.
local RIM_X, RIM_SPRING, RIM_BASE, RIM_ARC = 11.4, 9, -10.2, 8
local function ensureGlow(zone: string, part: BasePart)
	if glow and glow.zone == zone and glow.diamond.Parent then
		return
	end
	local color = zoneColor(zone)
	local rim: { Part } = {}
	local sparks: { ParticleEmitter } = {}
	local frame = part.CFrame
	local function bar(name: string, size: Vector3, offset: CFrame): Part
		local p = worldPart(name, size, color)
		p.CFrame = frame * offset
		table.insert(rim, p)
		return p
	end
	for _, side in { -1, 1 } do
		local len = RIM_SPRING - RIM_BASE
		local post = bar("RimPost", Vector3.new(1, len, 5), CFrame.new(side * RIM_X, RIM_BASE + len / 2, 0))
		local e = Instance.new("ParticleEmitter")
		e.Rate = 0
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		e.Lifetime = NumberRange.new(1.2, 2)
		e.Speed = NumberRange.new(2, 5)
		e.EmissionDirection = Enum.NormalId.Top
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Color = ColorSequence.new(color)
		e.Parent = post
		table.insert(sparks, e)
	end
	local chord = 2 * RIM_X * math.sin(math.pi / (2 * RIM_ARC)) + 0.3
	for i = 1, RIM_ARC do
		local th = (i - 0.5) * math.pi / RIM_ARC
		bar("RimArc", Vector3.new(1, chord, 5), CFrame.new(RIM_X * math.cos(th), RIM_SPRING + RIM_X * math.sin(th), 0) * CFrame.Angles(0, 0, th))
	end
	local anchor = worldPart("GlowLight", Vector3.new(1, 1, 1), color)
	anchor.CFrame = frame * CFrame.new(0, 0, 4) -- plaza side of the veil (the shimmer looks away from the plaza)
	local light = Instance.new("PointLight")
	light.Range = 32
	light.Brightness = 0
	light.Color = color
	light.Shadows = false
	light.Parent = anchor
	local d = worldPart("GuideDiamond", Vector3.new(1, 1, 1) * OnboardingRules.DIAMOND_SIZE, color)
	local dlight = Instance.new("PointLight")
	dlight.Range = 16
	dlight.Brightness = 0
	dlight.Color = color
	dlight.Shadows = false
	dlight.Parent = d
	local dsparks = Instance.new("ParticleEmitter")
	dsparks.Rate = 0
	dsparks.Lifetime = NumberRange.new(0.8, 1.4)
	dsparks.Speed = NumberRange.new(1, 3)
	dsparks.SpreadAngle = Vector2.new(180, 180)
	dsparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) })
	dsparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	dsparks.LightEmission = 1
	dsparks.LightInfluence = 0
	dsparks.Color = ColorSequence.new(color)
	dsparks.Parent = d
	glow = { zone = zone, rim = rim, light = light, sparks = sparks, diamond = d, dlight = dlight, dsparks = dsparks, bucket = -1 }
	portalPart = part
end

-- Flat landing ring on the ground: a SurfaceGui circle outline on a thin invisible slab (24 studs, the veil's width) and a few motes.
local function ensureRing(zone: string)
	if ring and ring.part.Parent then
		return
	end
	local color = zoneColor(zone)
	local slab = worldPart("LandingRing", Vector3.new(OnboardingRules.RING_RADIUS * 2, 0.2, OnboardingRules.RING_RADIUS * 2), color)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = Vector2.new(256, 256)
	sg.LightInfluence = 0
	sg.Adornee = slab
	sg.Parent = slab
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BackgroundTransparency = 1
	fill.BorderSizePixel = 0
	fill.Parent = sg
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = fill
	local edge = Instance.new("UIStroke")
	edge.Color = color
	edge.Thickness = 14
	edge.Transparency = 1
	edge.Parent = fill
	local motes = Instance.new("ParticleEmitter")
	motes.Rate = 0
	motes.Shape = Enum.ParticleEmitterShape.Disc
	motes.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	motes.Lifetime = NumberRange.new(1.2, 1.8)
	motes.Speed = NumberRange.new(3, 5)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	motes.LightEmission = 0.8
	motes.LightInfluence = 0
	motes.Color = ColorSequence.new(color)
	motes.Parent = slab
	ring = { part = slab, fill = fill, edge = edge, motes = motes, y = 0, yAt = -1e9 }
end

-- Why the guide world is hidden right now (OnboardingRules.holdReason). A finished hold keeps the guide down for
-- HOLD_RESUME_SECONDS more, so a cancelled lobby does not flash the arrow back mid-countdown.
local function currentHold(t: number): string?
	local now = workspace:GetServerTimeNow()
	local st = workspace:GetAttribute("StormCupState")
	local hold = OnboardingRules.holdReason({
		raceMode = RaceAttr.mine("RaceMode"),
		lobbyGoAt = workspace:GetAttribute("LobbyGoAt"),
		now = now,
		switching = workspace:GetAttribute("TrackSwitching") == true,
		stormHold = workspace:GetAttribute("StormCupEnabled") == true and (st == "lobby" or st == "due"),
		loadingOver = LocalPlayer:GetAttribute("LoadingDone") == true or t - startedAt > OnboardingRules.LOADING_MAX,
		resumeAt = resumeAt,
	})
	if hold ~= nil and hold ~= "resume" then
		resumeAt = now + OnboardingRules.HOLD_RESUME_SECONDS
	end
	return hold
end

local function ringCF(): CFrame?
	local r = ring
	return if r and r.part.Parent then r.part.CFrame else nil
end

local function arrive(cf: CFrame)
	local v = vfx()
	if v then
		v.burst("confetti", cf + Vector3.new(0, 2, 0))
	end
	UiSound.play("confirm")
	if cardKind == "goal" and cardBody then
		local lines = OnboardingRules.goalLines(family())
		lines[3] = OnboardingRules.ARRIVE_TEXT
		cardBody.Text = table.concat(lines, "\n")
	end
end

local function stepWorld(t: number, dt: number, hold: string?)
	chipWanted = false
	local hull = vehicleHull()
	local zone = targetZone()
	local part: BasePart? = nil
	if zone then
		if portalFoundFor ~= zone or not portalPart or not portalPart.Parent then
			portalPart = findPortal(zone)
			portalFoundFor = zone
		end
		part = portalPart
	end
	if not part or not hull or not zone or not hull.Parent or not OnboardingRules.arrowOn(state, raceMode(), true) then
		if worldFolder then
			clearWorld()
		end
		return
	end
	local hp = hull.Position
	OnboardingRules.watchPlaza(state, hp.X, hp.Z)
	local surface = OnboardingRules.surface(state, raceMode(), true, hold, t)
	local peeking = t < state.peekUntil
	-- The chip shows off the plaza and while a peek runs (it then turns into the dismiss button); never under a hold.
	chipWanted = hold == nil and (surface == "chip" or peeking)
	local dx, dz, dist = OnboardingRules.groundDir(hp.X, hp.Z, part.Position.X, part.Position.Z)
	local look = part.CFrame.LookVector
	local cx, cz = OnboardingRules.ringCentre(part.Position.X, part.Position.Z, look.X, look.Z)
	local ringDist = math.sqrt((hp.X - cx) ^ 2 + (hp.Z - cz) ^ 2)
	local live = surface == "world"
	-- Plaza time only: the clocks and the arrival beat do not run during a peek (it ignores the caps).
	if live and not peeking and OnboardingRules.step(state, dt, ringDist <= OnboardingRules.ARRIVE_RADIUS, nil) then
		local cf = ringCF()
		arrive(cf or CFrame.new(cx, hp.Y, cz))
	end
	if live and not peeking and OnboardingRules.spent(state) then
		live = false -- the cap or the ring's linger ran out this frame: the world fades, the chip takes over
		if state.arrowSeconds >= OnboardingRules.ARROW_MAX_SECONDS and not capHinted then
			capHinted = true
			showCard("tip", "NEED A HAND?", "Tap the ! to see the way.", OnboardingRules.TIP_SECONDS)
		end
		chipWanted = true
	end
	local phase = OnboardingRules.phase(state, dist, peeking)
	worldFade = math.clamp(worldFade + (if live then dt else -dt) / WORLD_FADE, 0, 1)
	if worldFade <= 0 and not live then
		if worldFolder then
			clearWorld()
		end
		return
	end
	ensureWorld()
	ensureGlow(zone, part)
	local g = glow
	-- Peeks glow a little harder, with a slow pulse, so the arch is easy to find from anywhere.
	local pulse = 0.5 + 0.5 * math.sin(t * 2.2)
	local gl = (if peeking then 1 else 0.8) * worldFade
	if g then
		local bucket = math.floor(gl * 20 + 0.5) * 100 + math.floor(pulse * 10)
		if bucket ~= g.bucket then
			g.bucket = bucket
			local tr = 1 - (0.6 + 0.3 * pulse) * gl
			for _, p in g.rim do
				p.Transparency = tr
			end
			g.light.Brightness = (1.2 + 1.2 * pulse) * gl
			for _, e in g.sparks do
				e.Rate = 7 * gl
			end
		end
	end
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = {}
	if hull.Parent then
		table.insert(skip, hull.Parent)
	end
	if worldFolder then
		table.insert(skip, worldFolder)
	end
	groundParams.FilterDescendantsInstances = skip
	ensureRing(zone)
	local r = ring
	local groundY = part.Position.Y - 11 -- the shimmer sits 11 over the plaza
	if r then
		if t - r.yAt > 0.5 then
			r.yAt = t
			local rh = workspace:Raycast(Vector3.new(cx, part.Position.Y + 20, cz), Vector3.new(0, -120, 0), groundParams)
			r.y = if rh then rh.Position.Y else groundY
		end
		groundY = r.y
		r.part.CFrame = CFrame.new(cx, r.y + 0.3, cz)
		local ra = if state.arrived and not peeking
			then math.clamp((OnboardingRules.RING_LINGER - state.ringSeconds) / 2, 0, 1)
			else OnboardingRules.ringAlpha(dist)
		ra *= worldFade
		local beat = 0.5 + 0.5 * math.sin(t * (if state.arrived then 3 else 5))
		r.fill.BackgroundTransparency = 1 - (0.12 + 0.1 * beat) * ra
		r.edge.Transparency = 1 - (0.6 + 0.3 * beat) * ra
		r.motes.Rate = 10 * ra
	end
	if g then
		-- The gem: slow spin, gentle bob, at vehicle height in front of the arch. It dissolves as the car closes in so that
		-- driving through never puts it in the camera's face.
		local gx, gz = OnboardingRules.diamondCentre(part.Position.X, part.Position.Z, look.X, look.Z)
		local gy = groundY + OnboardingRules.DIAMOND_HEIGHT + 0.4 * math.sin(t * 1.6)
		g.diamond.CFrame = CFrame.new(gx, gy, gz) * CFrame.Angles(0, t * 0.9, 0) * DIAMOND_TILT
		local da = OnboardingRules.diamondAlpha(math.sqrt((hp.X - gx) ^ 2 + (hp.Z - gz) ^ 2)) * gl
		g.diamond.Transparency = 1 - (0.78 + 0.12 * pulse) * da
		g.dlight.Brightness = 1.6 * da
		g.dsparks.Rate = 8 * da
	end
	if #arrowParts == 0 then
		return -- hub declutter: no ground arrow is built, so skip its per-frame raycast and placement
	end
	local alpha = if phase == "arrow" then OnboardingRules.arrowAlpha(dist) * worldFade else 0
	-- Hide once the player already faces the portal (within 20 degrees of the camera heading): the arrow has done its job.
	local cam = workspace.CurrentCamera
	if cam and dist > 0.01 then
		local cl = cam.CFrame.LookVector
		local fl = math.sqrt(cl.X * cl.X + cl.Z * cl.Z)
		if fl > 0.01 and (cl.X * dx + cl.Z * dz) / fl > math.cos(math.rad(20)) then
			alpha = 0
		end
	end
	local ahead = math.min(OnboardingRules.arrowAhead(dist), 10) -- 9-10 studs ahead of the kart
	local x, z = hp.X + dx * ahead, hp.Z + dz * ahead
	local hit = workspace:Raycast(Vector3.new(x, hp.Y + 6, z), Vector3.new(0, -60, 0), groundParams)
	local ground = (if hit then hit.Position.Y else hp.Y - 2.5)
	local y = ground + ARROW_LIFT + 0.25 * math.sin(t * 2 * math.pi * 0.8) -- bob 0.5 studs peak to peak
	local pos = Vector3.new(x, y, z)
	local pivot = CFrame.lookAt(pos, pos + Vector3.new(dx, 0, dz))
	local arrowPulse = 0.125 + 0.125 * math.sin(t * 2 * math.pi) -- Transparency pulse 0 - 0.25 at 1 Hz
	for _, a in arrowParts do
		a.part.CFrame = pivot * a.offset
		if a.kind == "shadow" then
			a.part.CFrame = CFrame.lookAt(Vector3.new(x, ground + 0.08, z), Vector3.new(x + dx, ground + 0.08, z + dz)) * CFrame.new(0, 0, 2.2 * 1.5)
			a.part.Transparency = 1 - 0.28 * alpha
		elseif a.kind == "outline" then
			a.part.Transparency = 1 - 0.95 * alpha
		else
			a.part.Transparency = 1 - (1 - arrowPulse) * alpha
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Events and the step loop
------------------------------------------------------------------------------------------------------------------------

-- "item" (HudExtras: a held item appeared), "portal" (TrackFlow: this player drove through a portal arch), plus the tip
-- events the step loop raises itself ("pad", "drift", "lap").
function Onboarding.event(name: string)
	if name == "portal" then
		OnboardingRules.retire(state, "portal")
		hideCard("goal")
		local cf = ringCF()
		local v = vfx()
		if cf and v and state.arrived then
			v.burst("confetti", cf + Vector3.new(0, 2, 0), 0.5) -- the ring collapses in a last small burst
		end
		if worldFolder then
			clearWorld()
		end
		return
	end
	local id = OnboardingRules.onEvent(state, name, raceMode(), LocalPlayer:GetAttribute("Lap") :: any, RaceAttr.mine("TotalLaps") :: any)
	if id then
		showTip(id)
	end
end

local function raceStarted(): boolean
	local go = RaceAttr.mine("RaceGoTime")
	return type(go) ~= "number" or workspace:GetServerTimeNow() >= go
end

local function step(dt: number)
	local t = os.clock()
	if card and card.Visible and cardKind ~= "help" and cardKind ~= "" and resultsUp() then
		hideCard() -- the results card rose over a tip that was still showing
	end
	if not resolved then
		local flag = LocalPlayer:GetAttribute("Onboarded")
		if type(flag) == "boolean" then
			resolved = true
			if not flag then
				state.guideOn = true
			end
		elseif t - startedAt > OnboardingRules.READY_WAIT then
			resolved = true -- no saved profile to remember it in: no guide
		end
	end
	local fc = flight()
	local hull = vehicleHull()
	local switching = workspace:GetAttribute("TrackSwitching") == true
	local ready = hull ~= nil and hull.Parent ~= nil and not switching and raceMode() ~= ""
	if ready and hull then
		local from = readyPos
		if not from then
			readyPos = hull.Position
		elseif not sent.moved and (hull.Position - from).Magnitude >= OnboardingRules.MOVE_DIST then
			send("moved")
		end
		send("ready") -- once; retried each frame until the remote has arrived
	end
	-- The card waits for the loading screen to leave (LoadingDone), or 40 s at most, so it is never shown behind it.
	local loadingOver = LocalPlayer:GetAttribute("LoadingDone") == true or t - startedAt > 40
	local hold = currentHold(t)
	-- Seen in a race with a vehicle (also a mid-race join, which the RaceMode signal below never sees change): done for good.
	if OnboardingRules.shouldRetireForRace(state, raceMode(), hull ~= nil) then
		OnboardingRules.retire(state, "race")
		clearWorld()
	end
	if resolved and loadingOver and hold == nil and OnboardingRules.goalDue(state, raceMode(), ready) then
		showGoal()
	elseif hold == "lobby" or hold == "storm" or hold == "switching" then
		hideCard("goal")
	end
	if state.guideOn then
		stepWorld(t, dt, hold)
	else
		chipWanted = false
		if worldFolder then
			clearWorld()
		end
	end
	applyChip()
	-- Hub card leaves with the hub.
	if cardKind == "goal" and raceMode() ~= "hub" then
		hideCard("goal")
	end
	-- Tip triggers, ten times a second.
	stepAcc += dt
	if stepAcc < 0.1 then
		return
	end
	stepAcc = 0
	layoutHelp()
	layoutChip()
	if not state.guideOn or not fc or raceMode() == "hub" or switching or not raceStarted() then
		prevBoost = if fc then fc.boostState else "None"
		prevSharp = if fc then fc.sharpBank == true else false
		return
	end
	if fc.boostState ~= "None" and prevBoost == "None" then
		Onboarding.event("pad")
	end
	if fc.sharpBank == true and not prevSharp then
		Onboarding.event("drift")
	end
	prevBoost = fc.boostState
	prevSharp = fc.sharpBank == true
end

local function onInput(input: InputObject)
	local kind = input.UserInputType
	local pressed = kind == Enum.UserInputType.Touch
		or kind == Enum.UserInputType.Keyboard
		or string.find(kind.Name, "MouseButton") ~= nil
		or (string.find(kind.Name, "Gamepad") ~= nil and input.KeyCode ~= Enum.KeyCode.Thumbstick1 and input.KeyCode ~= Enum.KeyCode.Thumbstick2)
	if pressed and cardKind ~= "" and os.clock() - cardShownAt >= OnboardingRules.TIP_MIN_SECONDS then
		hideCard(nil)
	end
end

local function build()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyGuide"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 19 -- over the HUD, under TrackFlow's curtain and toasts (20): a map switch covers the cards
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		sg.ScreenInsets = Enum.ScreenInsets.None -- full-bleed like the HUD; SafeArea places the pieces
	end)
	sg.Parent = pg
	gui = sg

	local c = Instance.new("Frame")
	c.Name = "GuideCard"
	c.AnchorPoint = Vector2.new(0.5, 0)
	c.AutomaticSize = Enum.AutomaticSize.Y
	c.BackgroundColor3 = WOOD_DARK
	c.BackgroundTransparency = 0.1
	c.BorderSizePixel = 0
	c.Visible = false
	c.Active = false -- non-blocking: touches go through to the controls
	c.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = c
	stroke(c, RIM, 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 7)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = c
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = c
	card = c
	cardTitle = textLabel(c, "Title", Enum.Font.GothamBlack, GOLD, 1)
	cardBody = textLabel(c, "Body", Enum.Font.GothamBold, CREAM, 2)

	local b = Instance.new("TextButton")
	b.Name = "HelpButton"
	b.Text = "?"
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.TextColor3 = CREAM
	b.BackgroundColor3 = STONE
	b.AutoButtonColor = true
	b.Selectable = true
	b.ZIndex = 5
	b.Parent = sg
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(1, 0)
	bc.Parent = b
	stroke(b, RIM, 2)
	local pb = Instance.new("UIPadding")
	pb.PaddingTop = UDim.new(0, 5)
	pb.PaddingBottom = UDim.new(0, 5)
	pb.Parent = b
	UiSound.bind(b, "tab")
	b.Activated:Connect(replay)
	helpBtn = b
	layoutHelp()

	-- The notification chip: round, small, gold "!" on the dark guide wood. Quiet on purpose (no sound, no pulse): it can be ignored.
	local n = Instance.new("TextButton")
	n.Name = "GuideChip"
	n.Text = "!"
	n.Font = Enum.Font.GothamBlack
	n.TextScaled = true
	n.TextColor3 = GOLD
	n.BackgroundColor3 = WOOD_DARK
	n.BackgroundTransparency = 0.12
	n.AutoButtonColor = true
	n.Selectable = true
	n.Visible = false
	n.ZIndex = 5
	n.Parent = sg
	local nc = Instance.new("UICorner")
	nc.CornerRadius = UDim.new(1, 0)
	nc.Parent = n
	stroke(n, GOLD, 2)
	local np = Instance.new("UIPadding")
	np.PaddingTop = UDim.new(0, 6)
	np.PaddingBottom = UDim.new(0, 6)
	np.Parent = n
	UiSound.bind(n, "tab")
	n.Activated:Connect(function()
		OnboardingRules.chipTap(state, os.clock())
		applyChip()
	end)
	chip = n
end

function Onboarding.init()
	if gui then
		return
	end
	build()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
		remote = remotes and remotes:WaitForChild("OnboardingRemote", 15) :: RemoteEvent?
	end)
	RunService.RenderStepped:Connect(Prof.wrap("SR_Onboarding", step))
	UserInputService.InputBegan:Connect(onInput)
	HudMetrics.onChanged(function() -- viewport, insets, the nav reserve, input kind
		layoutHelp()
		layoutChip()
		sizeCard()
	end)
	-- First lap done: the Lap attribute moves to 2 (the server's RaceManager); a new race starts it again at 1.
	LocalPlayer:GetAttributeChangedSignal("Lap"):Connect(function()
		if raceMode() ~= "hub" then
			Onboarding.event("lap")
		end
	end)
	-- Lane A is one message at a time: a coaching tip steps aside for a hero message (FINAL LAP! lands with the lap tip).
	LocalPlayer:GetAttributeChangedSignal("HudHeroUp"):Connect(function()
		if LocalPlayer:GetAttribute("HudHeroUp") == true then
			hideCard("tip")
		end
	end)
	-- A map switch away from the hub ends the arrow even when the player picked the race on the board.
	RaceAttr.changed("RaceMode", function()
		-- (the Storm match only holds the guide, see OnboardingRules.shouldRetireForRace)
		if raceMode() ~= "hub" and raceMode() ~= "" and raceMode() ~= OnboardingRules.STORM_MODE then
			OnboardingRules.retire(state, "race")
			clearWorld()
		end
	end)
	-- H opens the help card on a keyboard; the "?" button is selectable with a gamepad's cursor.
	ContextActionService:BindAction(HELP_ACTION, function(_name: string, inputState: Enum.UserInputState, _obj: InputObject): Enum.ContextActionResult
		if inputState == Enum.UserInputState.Begin then
			replay()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.H)
end

return Onboarding
