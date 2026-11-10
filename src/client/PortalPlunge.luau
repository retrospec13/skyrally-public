--!strict
-- Portal Plunge (REMARKABLE Batch 2 item 20; trap audit H0-09). Client only, visual and sound only.
--
--   * Open arch: drive THROUGH it (shared/PortalRules.crossed; the server checks the same rule and owns the switch)
--     and the arch pulls you in: the FOV stretches 45 degrees over the 1.5 s warp, the camera twists, speed lines rush
--     to the middle, the zone accent glows in from the edges, a rising suck sound, "INTO FROSTPEAK!". Reversing out
--     of the arch cancels it (the server's "PortalWarpCancel", or no "PortalWarp" confirm within 1.2 s): "whew".
--     As the server switches, an iris in the shape of the zone's emblem (shared/PayoffImages iris_<zone>, drawn by
--     tools/vfx/make_iris_emblems.py) closes onto the car, pauses on it, and snaps shut with a "bwoomp".
--   * Arrival: the curtain lifts as the destination's emblem iris opening (TrackFlow.showCurtain hands it over).
--   * Locked arch: a car about to touch the veil is spat back out (spin, reversed at no more than its own reverse top
--     speed, PortalRules.spitSpeed), a zone-coloured puff and a raspberry sound, and the arch says why in a speech
--     bubble instead of a toast. A plane is turned round to face the plaza.
--   * The cutaway when a token wakes a portal is client/PortalWake (started from here).
-- Cost: one RenderStepped check of five dot products in the hub; GUI and camera work only while a plunge, a spit
-- bubble or an iris is on screen. Every Instance is built once and reused.
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local PortalRules = require(Shared:WaitForChild("PortalRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local CarController = require(script.Parent:WaitForChild("CarController"))
local FlightController = require(script.Parent:WaitForChild("FlightController"))

local LocalPlayer = Players.LocalPlayer

local PortalPlunge = {}

-- Iris art: the hole spans HOLE_FRACTION of the image (make_iris_emblems.py R = 0.2 of the canvas, shapes reach about
-- 1.15 R); the narrowest notch of an emblem reaches HOLE_INNER of its half span (the compass star), which sets how big
-- the image must be before the hole clears every screen corner.
PortalPlunge.HOLE_FRACTION = 0.46
PortalPlunge.HOLE_INNER = 0.3
local IRIS_CLOSE_S = 0.6
local IRIS_OPEN_S = 0.7
local UNCONFIRMED_S = 1.2 -- a local crossing the server never confirmed (Storm Cup lobby, a refusal) unwinds (portal-load: was 0.9, short of a laggy phone round trip)
local STUCK_CLOSED_S = 2.2 -- closed but no switch came: reopen
local CREAM = Color3.fromRGB(250, 242, 222)
local INK = Color3.fromRGB(40, 22, 12)
local SPEED_LINES = 14

type Portal = { zone: string, cf: CFrame, part: BasePart }
type Plunge = {
	zone: string,
	t0: number,
	confirmed: boolean,
	deadline: number,
	baseFov: number,
	closingAt: number?,
	closedAt: number?,
	switchAt: number?,
	plunged: boolean,
}

local images: { [string]: string } = {}
local gui: ScreenGui? = nil
local irisRoot: Frame
local irisCover: ImageLabel
local irisRim: ImageLabel
local irisBox: Frame -- fallback (no uploaded emblem): a rounded box wipe
local irisBoxRim: UIStroke
local irisEdges: { Frame } = {}
local warpRoot: Frame
local warpTitle: TextLabel
local warpSub: TextLabel
local warpLines: { ImageLabel } = {}
local warpGlow: { Frame } = {}
local bubble: BillboardGui? = nil
local bubbleText: TextLabel? = nil
local bubbleToken = 0
local spitAtt: Attachment? = nil
local spitPuff: ParticleEmitter? = nil
local spitStars: ParticleEmitter? = nil

local portals: { Portal } = {}
local stateByZone: { [string]: any } = {}
local lastPos: Vector3? = nil
local spitReadyAt = 0
local lastSpit: { zone: string, at: number }? = nil
local plunge: Plunge? = nil
local irisMode: "none" | "close" | "open" = "none"
local irisZone = "HUB"
local revealToken = 0

local function hubActive(): boolean
	return RaceAttr.mine("RaceMode") == "hub" and workspace:GetAttribute("TrackSwitching") ~= true
end

local function vehicleHull(): (BasePart?, string)
	local car = CarController.car
	local h = CarController.hull
	if car and h and h.Parent then
		return h, "car"
	end
	local p = FlightController.hull
	if p and p.Parent then
		return p, "plane"
	end
	return nil, ""
end

local function loadImages()
	local mod = Shared:FindFirstChild("PayoffImages")
	if mod and mod:IsA("ModuleScript") then
		local ok, t = pcall(require, mod)
		if ok and type(t) == "table" then
			for k, v in t :: { [string]: any } do
				if type(k) == "string" and type(v) == "string" then
					images[k] = v
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------- portal states

local function decodeStates(): { any }
	local raw = LocalPlayer:GetAttribute("PortalStates")
	if type(raw) ~= "string" then
		return {}
	end
	local ok, t = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	return if ok and type(t) == "table" then t else {}
end

local function refreshStates()
	table.clear(stateByZone)
	for _, st in decodeStates() do
		if type(st) == "table" and type(st.zone) == "string" then
			stateByZone[st.zone] = st
		end
	end
end

-- The player's PortalStates (the server's JSON), decoded; PortalWake diffs it.
function PortalPlunge.states(): { any }
	return decodeStates()
end

-- The hub map's arches: the PortalShimmer_<ZONE> fx parts sit on the plan's portal cf (LookVector out of the plaza).
local function scanPortals()
	table.clear(portals)
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	if not root or RaceAttr.mine("RaceMode") ~= "hub" then
		return
	end
	for _, d in root:GetDescendants() do
		local zone = string.match(d.Name, "^PortalShimmer_(%u+)$")
		if zone and d:IsA("BasePart") then
			table.insert(portals, { zone = zone, cf = d.CFrame, part = d })
		end
	end
end

function PortalPlunge.portalPart(zone: string): BasePart?
	for _, p in portals do
		if p.zone == zone and p.part.Parent then
			return p.part
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------- GUI

local function frame(parent: Instance, name: string, color: Color3): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Active = false
	f.Parent = parent
	return f
end

local function build()
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyPortalPlunge"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 21 -- over TrackFlow's curtain (20), under the Garage (26)
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = sg

	-- warp overlay
	warpRoot = frame(sg, "Warp", INK)
	warpRoot.BackgroundTransparency = 1
	warpRoot.Size = UDim2.fromScale(1, 1)
	warpRoot.Visible = false
	for i, spec in { { 0, 0, 1, 0.22, 90 }, { 0, 0.78, 1, 0.22, -90 }, { 0, 0, 0.18, 1, 0 }, { 0.82, 0, 0.18, 1, 180 } } do
		local g = frame(warpRoot, "Glow" .. i, CREAM)
		g.Position = UDim2.fromScale(spec[1], spec[2])
		g.Size = UDim2.fromScale(spec[3], spec[4])
		local grad = Instance.new("UIGradient")
		grad.Rotation = spec[5]
		grad.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		grad.Parent = g
		g.BackgroundTransparency = 1
		table.insert(warpGlow, g)
	end
	local lineTex = (VfxAssets :: any).speed_line
	for i = 1, SPEED_LINES do
		local l = Instance.new("ImageLabel")
		l.Name = "Line" .. i
		l.BackgroundTransparency = 1
		l.Image = if lineTex then lineTex.id else ""
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.ImageColor3 = CREAM
		l.ImageTransparency = 1
		l.Parent = warpRoot
		table.insert(warpLines, l)
	end
	warpTitle = Instance.new("TextLabel")
	warpTitle.Name = "Title"
	warpTitle.BackgroundTransparency = 1
	warpTitle.AnchorPoint = Vector2.new(0.5, 0)
	warpTitle.Position = UDim2.fromScale(0.5, 0.12)
	warpTitle.Size = UDim2.fromScale(0.8, 0.13)
	warpTitle.Font = Enum.Font.GothamBlack
	warpTitle.TextScaled = true
	warpTitle.TextColor3 = CREAM
	warpTitle.Parent = warpRoot
	local ts = Instance.new("UIStroke")
	ts.Color = INK
	ts.Thickness = 3
	ts.Parent = warpTitle
	Instance.new("UIScale").Parent = warpTitle
	warpSub = Instance.new("TextLabel")
	warpSub.Name = "Sub"
	warpSub.BackgroundTransparency = 1
	warpSub.AnchorPoint = Vector2.new(0.5, 0)
	warpSub.Position = UDim2.fromScale(0.5, 0.25)
	warpSub.Size = UDim2.fromScale(0.6, 0.05)
	warpSub.Font = Enum.Font.GothamBold
	warpSub.TextScaled = true
	warpSub.TextColor3 = CREAM
	warpSub.Text = "reverse out to cancel"
	warpSub.Parent = warpRoot
	local ss = Instance.new("UIStroke")
	ss.Color = INK
	ss.Thickness = 2
	ss.Parent = warpSub

	-- iris
	irisRoot = frame(sg, "Iris", INK)
	irisRoot.BackgroundTransparency = 1
	irisRoot.Size = UDim2.fromScale(1, 1)
	irisRoot.Visible = false
	irisRoot.ZIndex = 5
	for i = 1, 4 do
		local e = frame(irisRoot, "Edge" .. i, INK)
		e.ZIndex = 5
		table.insert(irisEdges, e)
	end
	irisCover = Instance.new("ImageLabel")
	irisCover.Name = "Cover"
	irisCover.BackgroundTransparency = 1
	irisCover.AnchorPoint = Vector2.new(0.5, 0.5)
	irisCover.ZIndex = 5
	irisCover.Parent = irisRoot
	irisRim = Instance.new("ImageLabel")
	irisRim.Name = "Rim"
	irisRim.BackgroundTransparency = 1
	irisRim.AnchorPoint = Vector2.new(0.5, 0.5)
	irisRim.ZIndex = 6
	irisRim.Parent = irisRoot
	irisBox = frame(irisRoot, "Box", INK)
	irisBox.BackgroundTransparency = 1
	irisBox.AnchorPoint = Vector2.new(0.5, 0.5)
	irisBox.ZIndex = 6
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0.18, 0)
	bc.Parent = irisBox
	irisBoxRim = Instance.new("UIStroke")
	irisBoxRim.Thickness = 4
	irisBoxRim.Parent = irisBox
end

local function darker(c: Color3, k: number): Color3
	return Color3.new(c.R * k, c.G * k, c.B * k)
end

-- Draws the iris: hole centred on (cx, cy) with a half span of `half` px, cover and rim colours.
local function drawIris(cx: number, cy: number, half: number, cover: Color3, rim: Color3)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	local key = "iris_" .. string.lower(irisZone)
	local coverId, rimId = images[key], images[key .. "_rim"]
	local s: number
	if coverId then
		s = math.max(0, half * 2 / PortalPlunge.HOLE_FRACTION)
		irisCover.Visible = true
		irisCover.Image = coverId
		irisCover.ImageColor3 = cover
		irisCover.Position = UDim2.fromOffset(cx, cy)
		irisCover.Size = UDim2.fromOffset(s, s)
		irisRim.Visible = rimId ~= nil
		irisRim.Image = rimId or ""
		irisRim.ImageColor3 = rim
		irisRim.Position = irisCover.Position
		irisRim.Size = irisCover.Size
		irisBox.Visible = false
	else
		-- Fallback until the emblem masks are uploaded: a rounded box wipe with an accent rim.
		s = half * 2
		irisCover.Visible = false
		irisRim.Visible = false
		irisBox.Visible = half > 1
		irisBox.Position = UDim2.fromOffset(cx, cy)
		irisBox.Size = UDim2.fromOffset(s, s)
		irisBoxRim.Color = rim
	end
	local l, t, r, b = cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2
	local edges = irisEdges
	edges[1].Position = UDim2.fromOffset(0, 0)
	edges[1].Size = UDim2.fromOffset(vp.X, math.max(0, t))
	edges[2].Position = UDim2.fromOffset(0, math.max(0, b))
	edges[2].Size = UDim2.fromOffset(vp.X, math.max(0, vp.Y - b))
	edges[3].Position = UDim2.fromOffset(0, math.max(0, t))
	edges[3].Size = UDim2.fromOffset(math.max(0, l), math.max(0, math.min(vp.Y, b) - math.max(0, t)))
	edges[4].Position = UDim2.fromOffset(math.max(0, r), math.max(0, t))
	edges[4].Size = UDim2.fromOffset(math.max(0, vp.X - r), math.max(0, math.min(vp.Y, b) - math.max(0, t)))
	for _, e in edges do
		e.BackgroundColor3 = cover
	end
	if half <= 0.5 then
		-- shut: one edge covers everything
		edges[1].Size = UDim2.fromOffset(vp.X, vp.Y)
	end
end

-- Half span that clears every corner of the screen from (cx, cy), emblem notches included.
local function openHalf(cx: number, cy: number): number
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local far = math.max(
		Vector2.new(cx, cy).Magnitude,
		Vector2.new(vp.X - cx, cy).Magnitude,
		Vector2.new(cx, vp.Y - cy).Magnitude,
		Vector2.new(vp.X - cx, vp.Y - cy).Magnitude
	)
	return far / (if images["iris_" .. string.lower(irisZone)] then PortalPlunge.HOLE_INNER else 0.72)
end

local function carScreenPoint(): (number, number)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local hull = vehicleHull()
	if cam and hull then
		local p, onScreen = cam:WorldToViewportPoint(hull.Position)
		if onScreen then
			return p.X, p.Y
		end
	end
	return vp.X * 0.5, vp.Y * 0.62
end

---------------------------------------------------------------------------------------------------- warp

local function zoneColors(zone: string): (Color3, Color3)
	local info = TrackInfo.forZone(zone)
	return (if info then info.color else INK), (if info then info.accent else CREAM)
end

local function hideWarp()
	warpRoot.Visible = false
	RunService:UnbindFromRenderStep("SkyRallyPortalPlunge")
end

local function endPlunge()
	plunge = nil
	hideWarp()
end

local function cameraStep()
	local pl = plunge
	local cam = workspace.CurrentCamera
	if not pl or not cam then
		return
	end
	local t = os.clock() - pl.t0
	cam.FieldOfView = PortalRules.fovAt(t, pl.baseFov)
	local k = math.clamp(t / PortalRules.WARP_SECONDS, 0, 1)
	cam.CFrame *= CFrame.Angles(0, 0, math.rad(16) * k * k * k * math.sin(t * 3.2))
end

local function beginPlunge(zone: string, confirmed: boolean, seconds: number?)
	local now = os.clock()
	local pl = plunge
	if pl then
		if confirmed then
			pl.confirmed = true
			pl.deadline = math.min(pl.deadline, now + (seconds or PortalRules.WARP_SECONDS))
		end
		return
	end
	local cam = workspace.CurrentCamera
	local _, accent = zoneColors(zone)
	local info = TrackInfo.forZone(zone)
	plunge = {
		zone = zone,
		t0 = now,
		confirmed = confirmed,
		deadline = now + (seconds or PortalRules.WARP_SECONDS),
		baseFov = if cam then cam.FieldOfView else 70,
		closingAt = nil,
		closedAt = nil,
		switchAt = nil,
		plunged = false,
	}
	irisZone = zone
	warpTitle.Text = string.format("INTO %s!", if info then string.upper(info.zoneName) else zone)
	warpTitle.TextColor3 = accent
	for _, g in warpGlow do
		g.BackgroundColor3 = accent
		g.BackgroundTransparency = 1
	end
	for _, l in warpLines do
		l.ImageColor3 = CREAM:Lerp(accent, 0.4)
	end
	warpRoot.Visible = true
	local sc = warpTitle:FindFirstChildOfClass("UIScale")
	if sc then
		sc.Scale = 0.4
		TweenService:Create(sc, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	PayoffSound.play("portal_suck")
	local part = PortalPlunge.portalPart(zone)
	local vortex = part and part:FindFirstChild("PortalSwirl")
	if vortex and vortex:IsA("ParticleEmitter") then
		vortex:Emit(40)
	end
	RunService:BindToRenderStep("SkyRallyPortalPlunge", Enum.RenderPriority.Last.Value + 1, cameraStep)
end

local function cancelPlunge(why: string)
	local pl = plunge
	if not pl or pl.closedAt then
		return
	end
	PayoffSound.stop("portal_suck")
	PayoffSound.play("portal_cancel")
	if pl.closingAt then
		irisMode = "none"
		irisRoot.Visible = false
	end
	print("[SkyRally][PORTAL] plunge into " .. pl.zone .. " cancelled (" .. why .. ")")
	endPlunge()
end

local function stepWarp(now: number)
	local pl = plunge
	if not pl then
		return
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local t = now - pl.t0
	local k = math.clamp(t / PortalRules.WARP_SECONDS, 0, 1)
	-- Speed lines rush from the rim toward the middle, faster and brighter as the pull grows.
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local rMax = math.max(vp.X, vp.Y) * 0.62
	for i, l in warpLines do
		local a = (i - 1) / SPEED_LINES * math.pi * 2 + 0.17 * i
		local phase = ((t * (0.9 + 1.8 * k) + i * 0.37) % 1)
		local r = rMax * (1 - phase)
		l.Position = UDim2.fromOffset(cx + math.cos(a) * r, cy + math.sin(a) * r)
		l.Rotation = math.deg(a)
		l.Size = UDim2.fromOffset(rMax * (0.18 + 0.3 * k), 6 + 6 * k)
		l.ImageTransparency = 1 - (0.15 + 0.7 * k) * math.sin(phase * math.pi)
	end
	for _, g in warpGlow do
		g.BackgroundTransparency = 1 - 0.55 * k * k
	end
	warpTitle.Rotation = 3 * math.sin(t * 7) * k
	if not pl.confirmed and t > UNCONFIRMED_S then
		cancelPlunge("no server warp")
		return
	end
	-- Per group the server never raises TrackSwitching: the player's own seat (RaceInstanceId, given at GO) is his
	-- switch, so the shut iris hands over to TrackFlow's group curtain. Without it the "no switch came" branch below
	-- reopened the iris 2.2 s after it shut, and that reveal took the token of the curtain's own lift (V5B, aa6f798).
	local switching = workspace:GetAttribute("TrackSwitching") == true
		or (RaceFlowRules.PER_GROUP and LocalPlayer:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE) ~= nil)
	if switching and not pl.switchAt then
		pl.switchAt = now
	end
	if not pl.closingAt and (now >= pl.deadline - 0.15 or switching) then
		pl.closingAt = now
		irisMode = "close"
		irisRoot.Visible = true
	end
	if pl.closedAt then
		warpRoot.Visible = false
		if pl.switchAt and now - pl.switchAt > 0.65 then
			-- The curtain (zone colour, under this GUI) is opaque by now: hand the screen to it.
			irisMode = "none"
			irisRoot.Visible = false
			endPlunge()
		elseif not switching and now - pl.closedAt > STUCK_CLOSED_S then
			print("[SkyRally][PORTAL] closed on " .. pl.zone .. " but no switch came; reopening")
			endPlunge()
			PortalPlunge.irisReveal(INK, pl.zone, 0, nil)
		end
	end
end

local function stepIris(now: number)
	local pl = plunge
	if irisMode ~= "close" or not pl or not pl.closingAt then
		return
	end
	local k = math.clamp((now - pl.closingAt) / IRIS_CLOSE_S, 0, 1)
	local cx, cy = carScreenPoint()
	local color, accent = zoneColors(pl.zone)
	drawIris(cx, cy, openHalf(cx, cy) * PortalRules.irisClose(k), darker(color, 0.22), accent)
	if k >= 1 and not pl.closedAt then
		pl.closedAt = now
		PayoffSound.play("portal_plunge")
	end
end

-- The curtain lifting as an emblem iris opening on the destination (TrackFlow.showCurtain(false)). After `delay` s the
-- iris shows fully shut in `color` (the curtain's own colour), onCovered runs (TrackFlow hides the curtain under it),
-- then it opens with a pop. Returns false when it cannot run (no GUI yet), so the caller keeps its fade.
function PortalPlunge.irisReveal(color: Color3, zone: string?, delay: number, onCovered: (() -> ())?): boolean
	if not gui then
		return false
	end
	revealToken += 1
	local my = revealToken
	task.delay(delay, function()
		if my ~= revealToken or workspace:GetAttribute("TrackSwitching") == true then
			return
		end
		local pl = plunge
		if RaceFlowRules.PER_GROUP and pl and pl.closingAt then
			-- A group map can load before the plunge's own iris has shut (MapCache hit): this reveal takes the screen
			-- over, so the plunge ends here (stepIris stops once irisMode leaves "close" and would never set closedAt).
			irisMode = "none"
			endPlunge()
		end
		irisZone = zone or "HUB"
		local _, accent = zoneColors(irisZone)
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		local cx, cy = vp.X * 0.5, vp.Y * 0.58
		irisMode = "open"
		irisRoot.Visible = true
		drawIris(cx, cy, 0, color, accent)
		if onCovered then
			onCovered()
		end
		PayoffSound.play("iris_open")
		local t0 = os.clock()
		local conn: RBXScriptConnection? = nil
		conn = RunService.RenderStepped:Connect(function()
			local k = (os.clock() - t0) / IRIS_OPEN_S
			if my ~= revealToken or irisMode ~= "open" or k >= 1 then
				if conn then
					conn:Disconnect()
				end
				if my == revealToken and irisMode == "open" then
					irisMode = "none"
					irisRoot.Visible = false
				end
				return
			end
			drawIris(cx, cy, openHalf(cx, cy) * PortalRules.irisOpen(k), color, accent)
		end)
	end)
	return true
end

---------------------------------------------------------------------------------------------------- spit

local function ensureSpitFx(): (Attachment, ParticleEmitter, ParticleEmitter)
	local att = spitAtt
	if att and att.Parent and spitPuff and spitStars then
		return att, spitPuff, spitStars
	end
	local a = Instance.new("Attachment")
	a.Name = "PortalSpitFx"
	a.Parent = workspace.Terrain
	local puff = Instance.new("ParticleEmitter")
	puff.Name = "Puff"
	FlipFx.apply(puff, "smoke_puff_8x8")
	puff.Rate = 0
	puff.Lifetime = NumberRange.new(0.6, 0.9)
	puff.Speed = NumberRange.new(18, 34)
	puff.SpreadAngle = Vector2.new(28, 28)
	puff.Drag = 3
	puff.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) })
	puff.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	puff.LightInfluence = 0.3
	puff.EmissionDirection = Enum.NormalId.Front
	puff.Parent = a
	local stars = Instance.new("ParticleEmitter")
	stars.Name = "Stars"
	local tw = (VfxAssets :: any).star_twinkle
	stars.Texture = if tw then tw.id else ""
	stars.Rate = 0
	stars.Lifetime = NumberRange.new(0.5, 0.9)
	stars.Speed = NumberRange.new(20, 45)
	stars.SpreadAngle = Vector2.new(45, 45)
	stars.Drag = 2
	stars.Acceleration = Vector3.new(0, -30, 0)
	stars.LightEmission = 0.8
	stars.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	stars.RotSpeed = NumberRange.new(-200, 200)
	stars.EmissionDirection = Enum.NormalId.Front
	stars.Parent = a
	spitAtt, spitPuff, spitStars = a, puff, stars
	return a, puff, stars
end

local function showBubble(part: BasePart, text: string, accent: Color3)
	local bb = bubble
	if not bb then
		local nb = Instance.new("BillboardGui")
		nb.Name = "PortalBubble"
		nb.Size = UDim2.fromOffset(260, 74)
		nb.StudsOffset = Vector3.new(0, 4, 0)
		nb.AlwaysOnTop = true
		nb.MaxDistance = 260
		nb.LightInfluence = 0
		nb.ResetOnSpawn = false
		local f = frame(nb, "Bubble", CREAM)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.42)
		f.Size = UDim2.fromScale(1, 0.78)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.4, 0)
		c.Parent = f
		local s = Instance.new("UIStroke")
		s.Name = "Rim"
		s.Thickness = 3
		s.Color = INK
		s.Parent = f
		local tail = frame(nb, "Tail", CREAM)
		tail.AnchorPoint = Vector2.new(0.5, 0.5)
		tail.Position = UDim2.fromScale(0.5, 0.82)
		tail.Size = UDim2.fromOffset(16, 16)
		tail.Rotation = 45
		local l = Instance.new("TextLabel")
		l.Name = "Text"
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromScale(0.06, 0.1)
		l.Size = UDim2.fromScale(0.88, 0.8)
		l.Font = Enum.Font.GothamBlack
		l.TextScaled = true
		l.TextColor3 = INK
		l.Parent = f
		Instance.new("UIScale").Parent = f
		nb.Parent = LocalPlayer:WaitForChild("PlayerGui") -- a BillboardGui renders from PlayerGui, not inside a ScreenGui
		bubble = nb
		bubbleText = l
		bb = nb
	end
	local b = bb :: BillboardGui
	b.Adornee = part
	b.StudsOffset = Vector3.new(0, part.Size.Y * 0.5 + 9, 0)
	local l = bubbleText :: TextLabel
	l.Text = text
	local f = b:FindFirstChild("Bubble") :: Frame
	local rim = f:FindFirstChild("Rim") :: UIStroke
	rim.Color = darker(accent, 0.6)
	b.Enabled = true
	local sc = f:FindFirstChildOfClass("UIScale") :: UIScale
	sc.Scale = 0.2
	TweenService:Create(sc, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	f.Rotation = -8
	TweenService:Create(f, TweenInfo.new(0.6, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
	bubbleToken += 1
	local my = bubbleToken
	task.delay(2.8, function()
		if my == bubbleToken then
			b.Enabled = false
		end
	end)
end

local function spit(p: Portal, why: any)
	local now = os.clock()
	spitReadyAt = now + PortalRules.SPIT_COOLDOWN
	lastSpit = { zone = p.zone, at = now }
	local hull, kind = vehicleHull()
	local look = p.cf.LookVector
	if hull then
		if kind == "car" then
			-- The same spin a wall spin gives, then backwards at no more than the car's own reverse top speed.
			CarController.spinOut("PortalSpit", 0.75, hull.Position, -look)
			CarController.speed = PortalRules.spitSpeed(CarController.speed, CarConfig.REVERSE_SPEED)
			CarController.addTrauma(0.35)
		else
			local pos = hull.Position
			FlightController.setPoseFromCFrame(CFrame.lookAt(pos, pos - Vector3.new(look.X, 0, look.Z)))
			FlightController.addTrauma(0.35)
		end
	end
	local _, accent = zoneColors(p.zone)
	local att, puff, stars = ensureSpitFx()
	local veil = p.cf.Position - Vector3.new(0, 6, 0)
	att.WorldCFrame = CFrame.lookAt(veil, veil - look)
	puff.Color = ColorSequence.new(CREAM, accent)
	stars.Color = ColorSequence.new(accent)
	puff:Emit(16)
	stars:Emit(22)
	PayoffSound.play("portal_spit", 0.95 + 0.1 * math.random())
	showBubble(p.part, PortalRules.bubbleText(why), accent)
end

-- TrackFlow's "PortalLocked". At the arch (the server saw a crossing of a locked arch): the spit and the bubble,
-- unless the client already spat this car out of it; returns true (no toast). Anywhere else (a board request the
-- server refused): false, so TrackFlow toasts as before.
function PortalPlunge.onLocked(data: any): boolean
	local id = if type(data) == "table" then data.id else nil
	local info = TrackInfo.get(id)
	local zone = if info then info.zone else nil
	local hull = vehicleHull()
	if plunge then
		cancelPlunge("refused") -- the server changed its mind mid-warp (a token spent, the Storm Cup lobby)
	end
	for _, p in portals do
		if p.zone == zone then
			local ls = lastSpit
			if ls and ls.zone == zone and os.clock() - ls.at < 1.5 then
				return true
			end
			if not hull or (hull.Position - p.cf.Position).Magnitude > 45 then
				return false
			end
			spit(p, if type(data) == "table" then data.why else nil)
			return true
		end
	end
	return false
end

-- TrackFlow's "PortalWarp" / "PortalWarpCancel" for this player.
function PortalPlunge.onWarp(data: any)
	if type(data) == "table" and type(data.zone) == "string" then
		beginPlunge(data.zone, true, if type(data.seconds) == "number" then data.seconds else nil)
	end
end

function PortalPlunge.onWarpCancel()
	cancelPlunge("server")
end

-- TrackFlow's "LobbyOpen" / "LobbyBusy" for this player (L31, L32): with 2+ humans a crossing opens a 12 s lobby (or
-- joins one), not a 1.5 s warp, so the local plunge unwinds quietly instead of with the cancel sound; the server's
-- PortalWarp near the end of the lobby starts the real one.
function PortalPlunge.hold()
	local pl = plunge
	if pl and not pl.confirmed and not pl.closingAt then
		PayoffSound.stop("portal_suck")
		endPlunge()
	end
end

function PortalPlunge.busy(): boolean
	return plunge ~= nil or irisMode ~= "none"
end

---------------------------------------------------------------------------------------------------- loop

local function step(dt: number)
	local now = os.clock()
	if plunge then
		stepWarp(now)
		stepIris(now)
	end
	if not hubActive() or #portals == 0 then
		lastPos = nil
		return
	end
	local hull, _ = vehicleHull()
	if not hull then
		lastPos = nil
		return
	end
	local pos = hull.Position
	local prev = lastPos
	lastPos = pos
	if not prev or dt <= 0 or plunge then
		return
	end
	local vel = (pos - prev) / dt
	for _, p in portals do
		local st = stateByZone[p.zone]
		if st and st.open == false then
			if now >= spitReadyAt and PortalRules.inSpitZone(pos, vel, p.cf) then
				spit(p, st.why)
				return
			end
		elseif st and st.open == true and PortalRules.crossed(prev, pos, p.cf) then
			beginPlunge(p.zone, false, nil)
			return
		end
	end
end

local function onMode()
	lastPos = nil
	scanPortals()
	if RaceAttr.mine("RaceMode") == "hub" then
		-- The hub map streams in after the mode flips: scan again as it lands.
		for _, t in { 1, 4, 10 } do
			task.delay(t, scanPortals)
		end
	end
end

function PortalPlunge.init()
	if gui then
		return
	end
	loadImages()
	build()
	refreshStates()
	LocalPlayer:GetAttributeChangedSignal("PortalStates"):Connect(refreshStates)
	RaceAttr.changed("RaceMode", onMode)
	RaceAttr.changed("ActiveTrackId", onMode)
	onMode()
	RunService.RenderStepped:Connect(Prof.wrap("SR_PortalPlunge", step))
	-- REMARKABLE 24: the cutaway when a new token wakes a portal (needs the arches above).
	require(script.Parent:WaitForChild("PortalWake")).init(PortalPlunge)
end

return PortalPlunge
