--!strict
-- Curtain Kart (docs/REMARKABLE.md item 8): a playable top-down mini track of the NEXT map inside the map-load curtain.
-- TrackFlow calls CurtainKart.start(curtain, NextTrackId, zoneColour) when the curtain shows and CurtainKart.stop() the
-- moment it lifts; stop() returns this curtain's best lap and the toast line ("CURTAIN RECORD 7.2 s").
--
--   * Outline: shared/CurtainTracks (tools/bake_curtain_tracks.py, the real route seen from above), drawn as at most 48
--     rotated road Frames over 48 darker kerb Frames that draw themselves in from the start line, a chequered line,
--     in a 16:9 box under the curtain's title (the title, track and hint labels slide up into a header and are put
--     back on stop). An id with no baked outline (a battle arena without a route) shows no kart at all.
--   * Physics and lap rules: shared/CurtainKartSim (auto-throttle, steering, 40 percent off the road, a lap needs
--     80 percent of the loop). The kart drives itself (attract mode) until the player steers; a lap counts for the
--     record only when the player had the wheel from (near) its start.
--   * Kart in the player's equipped livery for the next vehicle (Garage loadout), cream when none; a translucent ghost
--     replays this session's best curtain lap on that track; dust and skid dots behind the kart (10 pooled dots).
--   * Input only while running: keyboard A/D/Left/Right, gamepad left stick X and D-pad, touch left half / right half.
--     The root Frame is Active so curtain touches never reach the HUD's steering pad; everything is disconnected and
--     hidden in stop(), so nothing is read after the curtain lifts. The car itself is held under TrackSwitching.
--   * Sound: chip_go, chip_engine (looped, pitched by speed), chip_blip on each lap, chip_best on a new record, from
--     shared/CurtainAudio (or shared/AudioAssets); a missing cue is silent. They play in SoundService.SkyRallyUI when
--     UiSound made it (UI volume).
--   * Shared curtain (item 28): everyone in the server races the same outline. The kart goes to the server at 5 Hz
--     (SkyRallyRemotes.CurtainKartPos, shared/CurtainKartNet packing, server/CurtainKartRelay), and every other
--     player's kart comes back as their CKPos / CKState / CKBest attributes: up to 7 rival karts in their own liveries
--     with their display names over them (a "zzz" after the name while their kart is still on autopilot), smoothed
--     between samples. A live "P2 / 4" readout, "PASSED <NAME>!" / "<NAME> SNUCK PAST!" pops with their own chip
--     cues (chip_pass / chip_passed; chip_blip pitched up or down until those are uploaded), the curtain's fastest lap
--     with its owner's name, a "YOU" tag on your kart, and the curtain-lift toast says where you finished.
-- Phone budget: every Instance is built once and reused; the per-frame step does no table allocation (numbers only,
-- text is rewritten when the shown tenth changes). The server load never waits on any of this.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sim = require(Shared:WaitForChild("CurtainKartSim"))
local Net = require(Shared:WaitForChild("CurtainKartNet"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))

local LocalPlayer = Players.LocalPlayer

local CurtainKart = {}

local MAX_SEGS = 48
local TRAIL_DOTS = 10
local TRAIL_EVERY = 0.045
local TRAIL_LIFE = TRAIL_DOTS * TRAIL_EVERY
local GHOST_HZ = 15
local GHOST_CAP = 600 -- 40 s of lap
local START_DELAY = 0.5 -- the curtain's fade-in
local DRAW_IN = 0.35
local CONTROL_GRACE = 1.0 -- taking the wheel this soon after the line still counts the lap
local STICK_DEAD = 0.2
local Z = 52 -- above the curtain (50) and its labels (51)
-- Shared curtain (item 28)
local MAX_RIVALS = 7
local SEND_EVERY = 1 / Net.SEND_HZ
local POLL_EVERY = 0.05 -- read rivals' attributes at 20 Hz (samples arrive at 5 Hz)
local ROSTER_EVERY = 1.0 -- who is on the curtain (GetPlayers allocates, so not per frame)
local PASS_POP_GAP = 0.9
local PASS_SETTLE = 1.0 -- a rival must be on screen this long before passing them counts

-- UI v2 tokens (docs/design/UI_V2.md): white text, the navy ink outline, gold numerals.
local CREAM = Color3.new(1, 1, 1)
local WOOD_DARK = Color3.fromRGB(11, 21, 51) -- (name kept) the text outline: ink
local GOLD = Color3.fromRGB(255, 225, 77)
local INK = Color3.fromRGB(11, 21, 51)
local WELL = Color3.fromRGB(14, 27, 69)
-- v38-flow: the kit's faces (shared/UiSkinRules.FONT), not a private copy
local FONT_RULES = require(Shared:WaitForChild("UiSkinRules")).FONT
local DISPLAY = Font.new(FONT_RULES.display.family, (Enum.FontWeight :: any)[FONT_RULES.display.weight], (Enum.FontStyle :: any)[FONT_RULES.display.style])
local BODY = Font.new(FONT_RULES.body.family, (Enum.FontWeight :: any)[FONT_RULES.body.weight], (Enum.FontStyle :: any)[FONT_RULES.body.style])

type Ghost = { xs: { number }, ys: { number }, hs: { number }, n: number }
type Rival = {
	frame: Frame,
	stripe: Frame,
	name: TextLabel,
	nameStroke: UIStroke,
	player: Player?,
	display: string,
	shown: boolean,
	ax: number, ay: number, ah: number, -- drawn from here ...
	bx: number, by: number, bh: number, -- ... toward the newest sample
	dx: number, dy: number, dh: number, -- where it is drawn now
	tB: number,
	interval: number,
	lastPos: Vector3?,
	lastState: number,
	progress: number,
	manual: boolean?,
	best: number?,
	side: number,
	seenAt: number,
}

-- Data (loaded on first use, never blocking the curtain)
local tracks: { [string]: any }? = nil
local audioIds: { [string]: string } = {}
local dataLoaded = false

-- Pooled UI
local root: Frame? = nil
local box: Frame
local kerbs: { Frame } = {}
local roads: { Frame } = {}
local lineA: Frame
local lineB: Frame
local kart: Frame
local kartStripe: Frame
local ghostFrame: Frame
local trail: { Frame } = {}
local trailAge: { number } = {}
local lapLabel: TextLabel
local lapCaption: TextLabel
local bestLabel: TextLabel
local popLabel: TextLabel
local popScale: UIScale
local hintLabel: TextLabel
local posLabel: TextLabel
local posScale: UIScale
local fastLabel: TextLabel
local youLabel: TextLabel
local rivals: { Rival } = {}
local sounds: { [string]: Sound } = {}

-- Run state
local runToken = 0
local active = false
local conns: { RBXScriptConnection } = {}
local stepConn: RBXScriptConnection? = nil
local track: Sim.Track? = nil
local kartState: Sim.Kart? = nil
local trackId = ""
local scale, ox, oy, kartW, kartH = 1, 0, 0, 14, 22
local touches: { [InputObject]: number } = {}
local stickX = 0
local playerControl = false
local lapEligible = false
local runBest: number? = nil
local recordBefore: number? = nil
local elapsed = 0
local revealed = 0
local shownTenth = -1
local trailNext = 1
local trailClock = 0
local popUntil = 0
local recAcc = 0
local recN = 0
local recXs: { number } = table.create(GHOST_CAP, 0)
local recYs: { number } = table.create(GHOST_CAP, 0)
local recHs: { number } = table.create(GHOST_CAP, 0)
local ghostFor: Ghost? = nil
-- Shared curtain run state
local remote: any = nil
local vehicleOfTrack: string? = nil
local sendAcc, pollAcc, rosterAcc = 0, 0, 0
local rivalProg: { number } = table.create(MAX_RIVALS, 0)
local shownPos, shownField = 0, 0
local lastPassPop = -math.huge

-- Session memory (no save, no reward)
local sessionBest: { [string]: number } = {}
local ghosts: { [string]: Ghost } = {}

-- Borrowed curtain labels and their original placement
type Saved = { pos: UDim2, size: UDim2, anchor: Vector2 }
local borrowed: { [TextLabel]: Saved } = {}
local HEADER: { [string]: { UDim2 } } = {
	-- UI v2: the gold zone band (narrower), its checker strip, the track name, the race-line pill
	ZoneName = { UDim2.new(0.5, 0, 0.022, 0), UDim2.new(0.42, 0, 0.088, 0) },
	TrackName = { UDim2.new(0.5, 0, 0.135, 0), UDim2.new(0.56, 0, 0.055, 0) },
	Hint = { UDim2.new(0.5, 0, 0.198, 0), UDim2.new(0.42, 0, 0.042, 0) },
}

local function loadData()
	if dataLoaded then
		return
	end
	dataLoaded = true
	local okT, t = pcall(function()
		return require(Shared:WaitForChild("CurtainTracks", 5) :: ModuleScript) :: any
	end)
	tracks = if okT and type(t) == "table" then t else {}
	for _, name in { "AudioAssets", "CurtainAudio" } do -- CurtainAudio wins over AudioAssets
		local m = Shared:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			local okA, a = pcall(require, m)
			if okA and type(a) == "table" then
				for _, cue in { "chip_blip", "chip_engine", "chip_go", "chip_best", "chip_pass", "chip_passed" } do
					local id = (a :: any)[cue]
					if type(id) == "string" and id ~= "" then
						audioIds[cue] = id
					end
				end
			end
		end
	end
end

local function textLabel(parent: Instance, name: string, font: Enum.Font, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.FontFace = if font == Enum.Font.GothamBlack then DISPLAY else BODY
	l.TextScaled = true
	l.TextColor3 = color
	l.ZIndex = Z + 4
	l.Text = ""
	l.Parent = parent
	local s = Instance.new("UIStroke")
	s.Color = WOOD_DARK
	s.Thickness = 2
	s.Parent = l
	return l
end

local function plainFrame(parent: Instance, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.ZIndex = z
	f.Parent = parent
	return f
end

local function corner(p: Instance, r: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = r
	c.Parent = p
end

local function build(parent: Frame)
	local r = Instance.new("Frame")
	r.Name = "CurtainKart"
	r.BackgroundTransparency = 1
	r.Size = UDim2.fromScale(1, 1)
	r.Active = true -- sinks curtain touches so the HUD's steering pad below never sees them
	r.ZIndex = Z
	r.Visible = false
	r.Parent = parent
	root = r

	box = Instance.new("Frame")
	box.Name = "Box"
	box.BackgroundColor3 = WELL -- the inset map well (layout mixes in a zone-colour wash)
	box.BackgroundTransparency = 0.15
	box.BorderSizePixel = 0
	box.ZIndex = Z
	box.Parent = r
	corner(box, UDim.new(0, 16))
	local boxInk = Instance.new("UIStroke")
	boxInk.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	boxInk.Color = INK
	boxInk.Thickness = 3
	boxInk.Parent = box
	-- readout chips (DEMO LAP left, BEST right) and the steer-hint pill: navy chips behind the labels (layout sizes them)
	for _, nm in { "LapChip", "BestChip" } do
		local c = plainFrame(r, nm, Z + 3)
		c.AnchorPoint = Vector2.zero -- plainFrame centres (road segments); the chips are placed by their corner
		c.BackgroundColor3 = WELL
		c.BackgroundTransparency = 0.2
		corner(c, UDim.new(0, 12))
		local cs = Instance.new("UIStroke")
		cs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		cs.Color = INK
		cs.Thickness = 3
		cs.Parent = c
	end

	for i = 1, MAX_SEGS do
		local k = plainFrame(box, "Kerb" .. i, Z + 1)
		k.Visible = false
		corner(k, UDim.new(0.5, 0))
		kerbs[i] = k
		local rd = plainFrame(box, "Road" .. i, Z + 2)
		rd.Visible = false
		corner(rd, UDim.new(0.5, 0))
		roads[i] = rd
	end
	-- Chequered start line: two strips, each a hard-stepped gradient, offset by one cell.
	local function strip(name: string, flip: boolean): Frame
		local f = plainFrame(box, name, Z + 3)
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		local g = Instance.new("UIGradient")
		local keys = {}
		local cells = 6
		for c = 0, cells - 1 do
			local on = (c % 2 == 0) ~= flip
			local col = if on then Color3.new(1, 1, 1) else INK
			table.insert(keys, ColorSequenceKeypoint.new(c / cells, col))
			table.insert(keys, ColorSequenceKeypoint.new(math.min(1, (c + 1) / cells - 0.001), col))
		end
		keys[#keys] = ColorSequenceKeypoint.new(1, keys[#keys].Value)
		g.Color = ColorSequence.new(keys)
		g.Parent = f
		return f
	end
	lineA = strip("StartA", false)
	lineB = strip("StartB", true)

	for i = 1, TRAIL_DOTS do
		local d = plainFrame(box, "Dot" .. i, Z + 3)
		d.BackgroundTransparency = 1
		corner(d, UDim.new(0.5, 0))
		trail[i] = d
		trailAge[i] = math.huge
	end

	ghostFrame = plainFrame(box, "Ghost", Z + 4)
	ghostFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	ghostFrame.BackgroundTransparency = 0.55
	ghostFrame.Visible = false
	corner(ghostFrame, UDim.new(0, 4))

	-- The kart, nose up before rotation: body, accent stripe, dark windscreen, four wheels. Rival karts (item 28) are
	-- the same build one layer lower, so your own kart always draws on top.
	local function kartFrames(name: string, z: number): (Frame, Frame)
		local body = plainFrame(box, name, z)
		corner(body, UDim.new(0, 4))
		local ks = Instance.new("UIStroke")
		ks.Color = INK
		ks.Thickness = 1.5
		ks.Parent = body
		local stripe = plainFrame(body, "Stripe", z + 1)
		stripe.AnchorPoint = Vector2.new(0.5, 0)
		stripe.Position = UDim2.fromScale(0.5, 0.52)
		stripe.Size = UDim2.fromScale(1, 0.16)
		local screen = plainFrame(body, "Screen", z + 1)
		screen.AnchorPoint = Vector2.new(0.5, 0)
		screen.Position = UDim2.fromScale(0.5, 0.2)
		screen.Size = UDim2.fromScale(0.64, 0.2)
		screen.BackgroundColor3 = INK
		corner(screen, UDim.new(0, 2))
		for _, wpos in { { -0.08, 0.22 }, { 1.08, 0.22 }, { -0.08, 0.8 }, { 1.08, 0.8 } } do
			local w = plainFrame(body, "Wheel", z - 1)
			w.Position = UDim2.fromScale(wpos[1], wpos[2])
			w.Size = UDim2.fromScale(0.28, 0.26)
			w.BackgroundColor3 = INK
			corner(w, UDim.new(0, 2))
		end
		return body, stripe
	end
	kart, kartStripe = kartFrames("Kart", Z + 6)

	-- Name tags ride above the karts (siblings in the box, so they stay upright while the karts turn).
	local function tag(name: string, color: Color3): (TextLabel, UIStroke)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 1)
		l.Font = Enum.Font.GothamBlack
		l.TextColor3 = color
		l.TextSize = 12
		l.ZIndex = Z + 8
		l.Visible = false
		l.Parent = box
		local st = Instance.new("UIStroke")
		st.Color = INK
		st.Thickness = 2
		st.Parent = l
		return l, st
	end
	for i = 1, MAX_RIVALS do
		local body, stripe = kartFrames("Rival" .. i, Z + 5)
		body.Visible = false
		local nm, nst = tag("RivalName" .. i, Color3.new(1, 1, 1))
		rivals[i] = {
			frame = body, stripe = stripe, name = nm, nameStroke = nst, player = nil, display = "", shown = false,
			ax = 0, ay = 0, ah = 0, bx = 0, by = 0, bh = 0, dx = 0, dy = 0, dh = 0,
			tB = 0, interval = SEND_EVERY, lastPos = nil, lastState = -1, progress = 0, manual = nil, best = nil,
			side = 0, seenAt = 0,
		}
	end
	youLabel = tag("YouTag", GOLD)
	youLabel.Text = "YOU"

	lapCaption = textLabel(r, "LapCaption", Enum.Font.GothamBold, CREAM)
	lapLabel = textLabel(r, "LapTime", Enum.Font.GothamBlack, GOLD)
	bestLabel = textLabel(r, "Best", Enum.Font.GothamBlack, GOLD) -- v38-flow: numerals in the display face
	hintLabel = textLabel(r, "SteerHint", Enum.Font.GothamBold, CREAM)
	popLabel = textLabel(box, "Pop", Enum.Font.GothamBlack, GOLD)
	popLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	popLabel.Position = UDim2.fromScale(0.5, 0.5)
	popLabel.Size = UDim2.fromScale(0.7, 0.2)
	popLabel.ZIndex = Z + 8
	popLabel.Visible = false
	popScale = Instance.new("UIScale")
	popScale.Parent = popLabel
	posLabel = textLabel(r, "Position", Enum.Font.GothamBlack, CREAM)
	posLabel.Visible = false
	posScale = Instance.new("UIScale")
	posScale.Parent = posLabel
	fastLabel = textLabel(r, "Fastest", Enum.Font.GothamBold, GOLD)
	fastLabel.Visible = false
end

local function sound(cue: string, looped: boolean, volume: number): Sound?
	local s = sounds[cue]
	if s then
		local group = SoundService:FindFirstChild("SkyRallyUI")
		s.SoundGroup = if group and group:IsA("SoundGroup") then group else nil
		return s
	end
	local id = audioIds[cue]
	if not id then
		return nil
	end
	local ns = Instance.new("Sound")
	ns.Name = "CurtainKart_" .. cue
	ns.SoundId = id
	ns.Looped = looped
	ns.Volume = volume
	ns.Parent = SoundService
	sounds[cue] = ns
	local group = SoundService:FindFirstChild("SkyRallyUI")
	ns.SoundGroup = if group and group:IsA("SoundGroup") then group else nil
	return ns
end

local function play(cue: string, volume: number, speed: number?)
	local s = sound(cue, false, volume)
	if s then
		s.PlaybackSpeed = speed or 1
		s.TimePosition = 0
		s:Play()
	end
end

-- A cue, or chip_blip at a pitch until that cue is uploaded (so the shared-curtain pops are never silent).
local function playOr(cue: string, volume: number, blipSpeed: number)
	if audioIds[cue] then
		play(cue, volume)
	else
		play("chip_blip", volume, blipSpeed)
	end
end

local function pop(text: string, color: Color3, seconds: number)
	popLabel.Text = text
	popLabel.TextColor3 = color
	popLabel.Visible = true
	popScale.Scale = 1.7
	TweenService:Create(popScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	popUntil = elapsed + seconds
end

local function hintText(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return "TAP LEFT / RIGHT TO TAKE THE WHEEL"
	elseif string.find(last.Name, "Gamepad") then
		return "LEFT STICK TO TAKE THE WHEEL"
	end
	return "A / D TO TAKE THE WHEEL"
end

local function liveryColors(vehicle: string?, who: Player?): (Color3, Color3)
	local ok, prim, acc = pcall(function()
		local GarageModel = require(Shared:WaitForChild("GarageModel", 2) :: ModuleScript) :: any
		local item = GarageModel.equipped(GarageModel.decodeLoadout((who or LocalPlayer):GetAttribute("Equipped")), if vehicle == "car" then "carLivery" else "planeLivery")
		local lv = item and item.livery
		if lv and type(lv.primary) == "table" then
			local a = if type(lv.accent) == "table" then lv.accent else lv.primary
			return Color3.fromRGB(lv.primary[1], lv.primary[2], lv.primary[3]), Color3.fromRGB(a[1], a[2], a[3])
		end
		error("no livery equipped")
	end)
	if ok and typeof(prim) == "Color3" and typeof(acc) == "Color3" then
		return prim, acc
	end
	return CREAM, Color3.fromRGB(196, 72, 34)
end

-- Header: the curtain's title labels slide up out of the track's way (restored on stop).
local function borrowLabels(parent: Frame)
	for name, slot in HEADER do
		local l = parent:FindFirstChild(name)
		if l and l:IsA("TextLabel") and not borrowed[l] then
			borrowed[l] = { pos = l.Position, size = l.Size, anchor = l.AnchorPoint }
			l.AnchorPoint = Vector2.new(0.5, 0)
			l.Size = slot[2]
			l.Position = UDim2.new(slot[1].X.Scale, 0, l.Position.Y.Scale, 0)
			TweenService:Create(l, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = slot[1] }):Play()
		end
	end
end

local function restoreLabels()
	for l, saved in borrowed do
		l.Position = saved.pos
		l.Size = saved.size
		l.AnchorPoint = saved.anchor
	end
	table.clear(borrowed)
end

local function px(x: number, y: number): (number, number)
	return ox + x * scale, oy + y * scale
end

-- Lays out the 16:9 box, the outline and the side readouts for the parent's current pixel size.
local function layout(parent: Frame, tr: Sim.Track, color: Color3)
	local vw, vh = parent.AbsoluteSize.X, parent.AbsoluteSize.Y
	local side = math.max(16, math.floor(vw * 0.04))
	local top, bottom = math.floor(vh * 0.255), math.floor(vh * 0.95)
	local bh = bottom - top
	local bw = math.floor(bh * 16 / 9)
	if bw > vw - side * 2 then
		bw = vw - side * 2
		bh = math.floor(bw * 9 / 16)
	end
	local bx = math.floor((vw - bw) / 2)
	box.Position = UDim2.fromOffset(bx, top)
	box.Size = UDim2.fromOffset(bw, bh)

	-- Track scale: the road is 2 x HALF_WIDTH units wide, so the drawn road is exactly where the kart is "on".
	local pad = math.max(14, bh * 0.08)
	scale = math.min((bw - pad * 2) / tr.w, (bh - pad * 2) / tr.h)
	ox = (bw - tr.w * scale) / 2
	oy = (bh - tr.h * scale) / 2
	local thick = math.max(8, Sim.HALF_WIDTH * 2 * scale)
	kartW = math.clamp(math.floor(thick * 1.15), 12, 26)
	kartH = math.floor(kartW * 1.55)

	-- UI v2: a white road with an ink kerb on the navy well, a faint zone-colour wash in the well
	box.BackgroundColor3 = WELL:Lerp(color, 0.22)
	local roadCol = Color3.new(1, 1, 1):Lerp(color, 0.12)
	local kerbCol = INK
	for i = 1, MAX_SEGS do
		local k, rd = kerbs[i], roads[i]
		if i <= tr.n then
			local j = if i == tr.n then 1 else i + 1
			local ax, ay = px(tr.xs[i], tr.ys[i])
			local bx2, by2 = px(tr.xs[j], tr.ys[j])
			local len = math.sqrt((bx2 - ax) ^ 2 + (by2 - ay) ^ 2)
			local rot = math.deg(math.atan2(by2 - ay, bx2 - ax))
			local mid = UDim2.fromOffset((ax + bx2) / 2, (ay + by2) / 2)
			rd.Position, k.Position = mid, mid
			rd.Rotation, k.Rotation = rot, rot
			rd.Size = UDim2.fromOffset(len + thick, thick)
			k.Size = UDim2.fromOffset(len + thick + 6, thick + 6)
			rd.BackgroundColor3 = roadCol
			k.BackgroundColor3 = kerbCol
			-- Round caps: the overlapping segment ends join into a smooth band.
			local rc, kc = rd:FindFirstChildOfClass("UICorner"), k:FindFirstChildOfClass("UICorner")
			if rc and kc then
				rc.CornerRadius = UDim.new(0, math.floor(thick / 2))
				kc.CornerRadius = UDim.new(0, math.floor(thick / 2) + 3)
			end
		end
		rd.Visible, k.Visible = false, false
	end
	-- Start line across segment 1 at point 1: two chequer strips, one either side of the line.
	local h = Sim.segHeading(tr, 1)
	local sx, sy = px(tr.xs[1], tr.ys[1])
	local cx, cy = math.cos(h), math.sin(h)
	for idx, f in { lineA, lineB } do
		local off = (if idx == 1 then -1.6 else 1.6)
		f.Position = UDim2.fromOffset(sx + cx * off, sy + cy * off)
		f.Size = UDim2.fromOffset(thick + 4, 3.2)
		f.Rotation = math.deg(h) + 90
		f.Visible = false
	end

	kart.Size = UDim2.fromOffset(kartW, kartH)
	ghostFrame.Size = UDim2.fromOffset(kartW, kartH)
	for _, d in trail do
		local ds = math.max(3, math.floor(kartW * 0.32))
		d.Size = UDim2.fromOffset(ds, ds)
		d.BackgroundTransparency = 1
	end

	-- Readouts beside the box when there is room (phone landscape and desktop), else inside its top corners.
	local room = bx - side
	local lw = math.floor(if room >= 110 then room - 8 else bw * 0.24)
	local lx = if room >= 110 then side else bx + 10
	local rx = if room >= 110 then bx + bw + 8 else bx + bw - lw - 10
	local ly = top + (if room >= 110 then math.floor(bh * 0.3) else 8)
	local unit = math.clamp(math.floor(bh * 0.13), 20, 72)
	lapCaption.Position = UDim2.fromOffset(lx, ly)
	lapCaption.Size = UDim2.fromOffset(lw, math.floor(unit * 0.6))
	lapLabel.Position = UDim2.fromOffset(lx, ly + math.floor(unit * 0.6))
	lapLabel.Size = UDim2.fromOffset(lw, unit)
	bestLabel.Position = UDim2.fromOffset(rx, ly + math.floor(unit * 0.3))
	bestLabel.Size = UDim2.fromOffset(lw, math.floor(unit * 0.8))
	-- Steer hint along the bottom edge inside the box (hidden once the player takes the wheel).
	local hh = math.max(14, math.floor(bh * 0.08))
	-- a dark pill, about 22 px tall, along the well's bottom edge
	hh = math.clamp(hh, 18, 30)
	hintLabel.Position = UDim2.fromOffset(bx + math.floor(bw * 0.25), top + bh - hh - 10)
	hintLabel.Size = UDim2.fromOffset(math.floor(bw * 0.5), hh)
	hintLabel.BackgroundTransparency = 0.2
	hintLabel.BackgroundColor3 = INK
	if not hintLabel:FindFirstChildOfClass("UICorner") then
		corner(hintLabel, UDim.new(0.5, 0))
		local hp = Instance.new("UIPadding")
		hp.PaddingTop = UDim.new(0.16, 0)
		hp.PaddingBottom = UDim.new(0.16, 0)
		hp.Parent = hintLabel
	end
	-- the readout chips behind DEMO LAP and BEST
	local root0 = root
	local lapChip = if root0 then root0:FindFirstChild("LapChip") :: Frame? else nil
	local bestChip = if root0 then root0:FindFirstChild("BestChip") :: Frame? else nil
	if lapChip then
		lapChip.Position = UDim2.fromOffset(lx - 6, ly - 6)
		lapChip.Size = UDim2.fromOffset(lw + 12, math.floor(unit * 1.6) + 12)
		lapChip.Visible = true
	end
	if bestChip then
		bestChip.Position = UDim2.fromOffset(rx - 6, ly + math.floor(unit * 0.3) - 6)
		bestChip.Size = UDim2.fromOffset(lw + 12, math.floor(unit * 0.8) + 12)
		bestChip.Visible = true
	end
	-- Shared curtain (item 28): position under BEST, the curtain's fastest lap under that; name tags sized to the karts.
	posLabel.Position = UDim2.fromOffset(rx, ly + math.floor(unit * 1.2))
	posLabel.Size = UDim2.fromOffset(lw, unit)
	fastLabel.Position = UDim2.fromOffset(rx, ly + math.floor(unit * 2.3))
	fastLabel.Size = UDim2.fromOffset(lw, math.floor(unit * 0.5))
	local ts = math.clamp(math.floor(kartW * 0.75), 10, 16)
	for _, rv in rivals do
		rv.frame.Size = UDim2.fromOffset(kartW, kartH)
		rv.name.TextSize = ts
		rv.name.Size = UDim2.fromOffset(ts * 12, ts + 4)
	end
	youLabel.TextSize = ts
	youLabel.Size = UDim2.fromOffset(ts * 4, ts + 4)
end

local function steerInput(): number
	local s = 0
	if UserInputService:GetFocusedTextBox() == nil then -- typing in chat never steers
		if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
			s -= 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
			s += 1
		end
	end
	if UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.DPadLeft) then
		s -= 1
	end
	if UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.DPadRight) then
		s += 1
	end
	if math.abs(stickX) > STICK_DEAD then
		s += (stickX - math.sign(stickX) * STICK_DEAD) / (1 - STICK_DEAD)
	end
	local l, r = false, false
	for _, side in touches do
		if side < 0 then
			l = true
		else
			r = true
		end
	end
	if l then
		s -= 1
	end
	if r then
		s += 1
	end
	return math.clamp(s, -1, 1)
end

local function setLapText(t: number)
	local tenth = math.floor(t * 10)
	if tenth ~= shownTenth then
		shownTenth = tenth
		lapLabel.Text = Sim.formatLap(tenth / 10)
	end
end

local function setBestText()
	local b = sessionBest[trackId]
	bestLabel.Text = if b then "BEST " .. Sim.formatLap(b) else "BEST --"
end

local function onLap(tr: Sim.Track, k: Sim.Kart, t: number)
	play("chip_blip", 0.45)
	if lapEligible then
		if runBest == nil or t < (runBest :: number) then
			runBest = t
		end
		local prev = sessionBest[trackId]
		if prev == nil or t < prev then
			sessionBest[trackId] = t
			-- Keep the ghost of the new best (copy the lap's samples into this track's ghost buffers).
			if recN > 0 then
				local g = ghosts[trackId]
				if not g then
					g = { xs = table.create(GHOST_CAP, 0), ys = table.create(GHOST_CAP, 0), hs = table.create(GHOST_CAP, 0), n = 0 }
					ghosts[trackId] = g
				end
				local gg = g :: Ghost
				for i = 1, recN do
					gg.xs[i], gg.ys[i], gg.hs[i] = recXs[i], recYs[i], recHs[i]
				end
				gg.n = recN
				ghostFor = gg
			end
			play("chip_best", 0.5)
			pop(if prev then "NEW BEST " .. Sim.formatLap(t) else "LAP " .. Sim.formatLap(t) .. "!", GOLD, 1.4)
			setBestText()
			bestLabel.TextColor3 = Color3.new(1, 1, 1)
			TweenService:Create(bestLabel, TweenInfo.new(0.8), { TextColor3 = GOLD }):Play()
		else
			pop("LAP " .. Sim.formatLap(t), CREAM, 1.1)
		end
	end
	lapEligible = playerControl
	recN, recAcc = 0, 0
	shownTenth = -1
end

-- ------------------------------------------------------------------ shared curtain (item 28)
local function displayName(p: Player): string
	local n = if p.DisplayName ~= "" then p.DisplayName else p.Name
	local cut = utf8.offset(n, 15)
	if cut then
		n = string.sub(n, 1, cut - 1) .. "."
	end
	return n
end

-- Name tag: a kart still on autopilot reads "Name zzz" and goes a little see-through.
local function setRivalTag(rv: Rival)
	local napping = rv.manual == false
	rv.name.Text = if napping then rv.display .. " zzz" else rv.display
	rv.name.TextTransparency = if napping then 0.35 else 0
	rv.frame.BackgroundTransparency = if napping then 0.35 else 0
end

local function hideRival(rv: Rival)
	rv.shown = false
	rv.frame.Visible = false
	rv.name.Visible = false
	rv.side = 0
end

local function releaseRival(rv: Rival)
	hideRival(rv)
	rv.player = nil
	rv.lastPos = nil
	rv.lastState = -1
	rv.manual = nil
	rv.best = nil
end

-- Who is racing this curtain: other players whose kart the server relays (CKPos). Stable slots, 1 Hz.
local function refreshRoster(now: number)
	for _, rv in rivals do
		local p = rv.player
		if p and (p.Parent == nil or typeof(p:GetAttribute(Net.ATTR_POS)) ~= "Vector3") then
			releaseRival(rv)
		end
	end
	for _, p in Players:GetPlayers() do
		if p ~= LocalPlayer and typeof(p:GetAttribute(Net.ATTR_POS)) == "Vector3" then
			local have, free = false, nil :: Rival?
			for _, rv in rivals do
				if rv.player == p then
					have = true
					break
				elseif free == nil and rv.player == nil then
					free = rv
				end
			end
			if not have and free then
				local rv = free :: Rival
				rv.player = p
				rv.display = displayName(p)
				local prim, acc = liveryColors(vehicleOfTrack, p)
				rv.frame.BackgroundColor3 = prim
				rv.stripe.BackgroundColor3 = acc
				rv.nameStroke.Color = prim:Lerp(INK, 0.55)
				rv.seenAt = now
				rv.side = 0
				rv.lastPos = nil
				rv.lastState = -1
				rv.manual = nil
				setRivalTag(rv)
			end
		end
	end
end

local shownFastT: number? = nil
local shownFastName = ""

-- 20 Hz: new samples, progress, the position readout, the fastest lap and overtake pops (no table allocation).
local function pollRivals(now: number, tr: Sim.Track, k: Sim.Kart)
	local mine = k.laps + k.station / tr.total
	local n = 0
	local bestT: number? = runBest
	local bestName = "YOU"
	for _, rv in rivals do
		local p = rv.player
		if p then
			local v = p:GetAttribute(Net.ATTR_POS)
			if typeof(v) == "Vector3" and v ~= rv.lastPos then
				if rv.lastPos == nil or not rv.shown then -- first sample (or back from stale): appear in place
					rv.dx, rv.dy, rv.dh = v.X, v.Y, v.Z
				end
				rv.ax, rv.ay, rv.ah = rv.dx, rv.dy, rv.dh
				rv.bx, rv.by, rv.bh = v.X, v.Y, v.Z
				rv.interval = if rv.lastPos and rv.shown then math.clamp(now - rv.tB, 0.1, 0.4) else SEND_EVERY
				rv.tB = now
				rv.lastPos = v
				if not rv.shown then
					rv.shown = true
					rv.frame.Visible = true
					rv.name.Visible = true
					rv.seenAt = now
				end
			elseif rv.shown and now - rv.tB > Net.STALE then
				hideRival(rv)
			end
			local st = p:GetAttribute(Net.ATTR_STATE)
			if type(st) == "number" and st ~= rv.lastState then
				rv.lastState = st
				rv.progress = Net.progress(st)
				local _, _, manual = Net.unpackState(st)
				if manual ~= rv.manual then
					rv.manual = manual
					setRivalTag(rv)
				end
			end
			local b = p:GetAttribute(Net.ATTR_BEST)
			rv.best = if type(b) == "number" then b else nil
			if rv.shown then
				n += 1
				rivalProg[n] = rv.progress
				local rb = rv.best
				if rb and (bestT == nil or rb < (bestT :: number)) then
					bestT, bestName = rb, rv.display
				end
				-- Overtakes count only while you drive, once the rival has been on screen a moment.
				local side, ev = Net.overtake(rv.side, mine, rv.progress)
				rv.side = side
				if ev ~= 0 and playerControl and now - rv.seenAt > PASS_SETTLE and elapsed > popUntil and now - lastPassPop > PASS_POP_GAP then
					lastPassPop = now
					if ev > 0 then
						pop("PASSED " .. string.upper(rv.display) .. "!", GOLD, 0.9)
						playOr("chip_pass", 0.5, 1.5)
					else
						pop(string.upper(rv.display) .. " SNUCK PAST!", CREAM, 0.9)
						playOr("chip_passed", 0.45, 0.62)
					end
				end
			end
		end
	end
	if n == 0 then
		if shownPos ~= 0 then
			shownPos, shownField = 0, 0
			posLabel.Visible = false
			fastLabel.Visible = false
			youLabel.Visible = false
		end
		return
	end
	local pos = Net.position(mine, rivalProg, n)
	if pos ~= shownPos or n + 1 ~= shownField then
		local gained = shownPos ~= 0 and pos < shownPos
		shownPos, shownField = pos, n + 1
		posLabel.Text = string.format("P%d / %d", pos, n + 1)
		posLabel.TextColor3 = if pos == 1 then GOLD else CREAM
		posLabel.Visible = true
		youLabel.Visible = true
		if gained then
			posScale.Scale = 1.45
			TweenService:Create(posScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
	if bestT ~= shownFastT or bestName ~= shownFastName then
		shownFastT, shownFastName = bestT, bestName
		fastLabel.Text = if bestT then string.format("FASTEST  %s  %s", bestName, Sim.formatLap(bestT :: number)) else ""
		fastLabel.Visible = bestT ~= nil
	end
end

-- Every frame: rivals glide from where they are drawn toward their newest sample over one sample interval.
local function drawRivals(now: number)
	for _, rv in rivals do
		if rv.shown then
			local a = math.clamp((now - rv.tB) / rv.interval, 0, 1)
			rv.dx = rv.ax + (rv.bx - rv.ax) * a
			rv.dy = rv.ay + (rv.by - rv.ay) * a
			rv.dh = Net.lerpAngle(rv.ah, rv.bh, a)
			local x, y = px(rv.dx, rv.dy)
			rv.frame.Position = UDim2.fromOffset(x, y)
			rv.frame.Rotation = math.deg(rv.dh) + 90
			rv.name.Position = UDim2.fromOffset(x, y - kartH * 0.62)
		end
	end
end

local function sendSample(tr: Sim.Track, k: Sim.Kart)
	local r = remote
	if r then
		r:FireServer(Vector3.new(k.x, k.y, k.heading), Net.packState(k.laps, k.station / tr.total, playerControl), runBest)
	end
end

local function step(dt: number)
	local tr, k = track, kartState
	if not (active and tr and k) then
		return
	end
	dt = math.min(dt, 0.1)
	elapsed += dt

	-- Draw-in from the start line.
	if revealed < tr.n then
		local want = math.min(tr.n, math.ceil(tr.n * elapsed / DRAW_IN))
		for i = revealed + 1, want do
			kerbs[i].Visible = true
			roads[i].Visible = true
		end
		revealed = want
		if revealed >= tr.n then
			lineA.Visible, lineB.Visible = true, true
		end
	end

	local input = steerInput()
	if not playerControl and input ~= 0 then
		playerControl = true
		if k.clock - k.lapStart < CONTROL_GRACE then
			lapEligible = true
		end
		hintLabel.Visible = false
		lapCaption.Text = "LAP"
	end
	local steer = if playerControl then input else Sim.autoSteer(tr, k) * 0.9
	local lap = Sim.step(tr, k, dt, steer)
	if lap then
		onLap(tr, k, lap)
	end

	-- Ghost recording (this lap) and playback (the session best on this track).
	recAcc += dt
	while recAcc >= 1 / GHOST_HZ do
		recAcc -= 1 / GHOST_HZ
		if recN < GHOST_CAP then
			recN += 1
			recXs[recN], recYs[recN], recHs[recN] = k.x, k.y, k.heading
		end
	end
	local g = ghostFor
	if g and g.n > 1 then
		local f = (k.clock - k.lapStart) * GHOST_HZ + 1
		local i = math.floor(f)
		if i < g.n then
			local a = f - i
			local gx = g.xs[i] + (g.xs[i + 1] - g.xs[i]) * a
			local gy = g.ys[i] + (g.ys[i + 1] - g.ys[i]) * a
			local gpx, gpy = px(gx, gy)
			ghostFrame.Position = UDim2.fromOffset(gpx, gpy)
			ghostFrame.Rotation = math.deg(g.hs[i]) + 90
			ghostFrame.Visible = true
		else
			ghostFrame.Visible = false
		end
	end

	-- Kart: position, heading plus a little drift lean into the steer.
	local kx, ky = px(k.x, k.y)
	kart.Position = UDim2.fromOffset(kx, ky)
	kart.Rotation = math.deg(k.heading) + 90 + steer * 14

	-- Dust off the road, skid marks at full lock.
	trailClock += dt
	if trailClock >= TRAIL_EVERY then
		trailClock = 0
		if k.offTrack or math.abs(steer) > 0.85 then
			local d = trail[trailNext]
			local back = kartH * 0.4
			d.Position = UDim2.fromOffset(kx - math.cos(k.heading) * back, ky - math.sin(k.heading) * back)
			d.BackgroundColor3 = if k.offTrack then Color3.fromRGB(196, 168, 120) else INK
			trailAge[trailNext] = 0
			trailNext = trailNext % TRAIL_DOTS + 1
		end
	end
	for i = 1, TRAIL_DOTS do
		local age = trailAge[i]
		if age < TRAIL_LIFE then
			age += dt
			trailAge[i] = age
			trail[i].BackgroundTransparency = math.min(1, 0.25 + age / TRAIL_LIFE)
		end
	end

	setLapText(k.clock - k.lapStart)
	if popLabel.Visible and elapsed > popUntil then
		popLabel.Visible = false
	end
	local eng = sounds.chip_engine
	if eng then
		eng.PlaybackSpeed = 0.75 + 0.85 * (k.speed / tr.top)
	end

	-- Shared curtain (item 28): send at 5 Hz, roster at 1 Hz, rivals' samples at 20 Hz, draw every frame.
	local now = os.clock()
	sendAcc += dt
	if sendAcc >= SEND_EVERY then
		sendAcc = math.min(sendAcc - SEND_EVERY, SEND_EVERY)
		sendSample(tr, k)
	end
	rosterAcc += dt
	if rosterAcc >= ROSTER_EVERY then
		rosterAcc = 0
		refreshRoster(now)
	end
	pollAcc += dt
	if pollAcc >= POLL_EVERY then
		pollAcc = 0
		pollRivals(now, tr, k)
	end
	drawRivals(now)
	if youLabel.Visible then
		youLabel.Position = UDim2.fromOffset(kx, ky - kartH * 0.62)
	end
end

local function disconnectAll()
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	table.clear(touches)
	stickX = 0
end

local function begin(parent: Frame, id: string, color: Color3)
	local data = (tracks :: any)[id]
	if not data or parent.AbsoluteSize.X < 100 or parent.AbsoluteSize.Y < 100 then
		return
	end
	if not root or root.Parent ~= parent then
		if root then
			root:Destroy()
		end
		table.clear(kerbs)
		table.clear(roads)
		table.clear(trail)
		table.clear(rivals)
		build(parent)
	end
	local tr = Sim.prepare(data.points, data.w, data.h)
	if tr.n > MAX_SEGS then
		return
	end
	trackId = id
	track = tr
	local k = Sim.newKart(tr, data.startIndex or 1)
	kartState = k
	playerControl = false
	lapEligible = false
	runBest = nil
	recordBefore = sessionBest[id]
	elapsed, revealed, shownTenth = 0, 0, -1
	trailNext, trailClock = 1, 0
	recAcc, recN = 0, 0
	ghostFor = ghosts[id]
	ghostFrame.Visible = false
	for i = 1, TRAIL_DOTS do
		trailAge[i] = math.huge
	end
	layout(parent, tr, color)
	local info = TrackInfo.get(id)
	vehicleOfTrack = info and info.vehicle
	-- Shared curtain (item 28): fresh slots, the relay remote if the server made it (none = a solo curtain).
	for _, rv in rivals do
		releaseRival(rv)
	end
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local rr = remotes and remotes:FindFirstChild(Net.REMOTE)
	remote = if rr and (rr:IsA("UnreliableRemoteEvent") or rr:IsA("RemoteEvent")) then rr else nil
	sendAcc, pollAcc, rosterAcc = 0, POLL_EVERY, ROSTER_EVERY
	shownPos, shownField = 0, 0
	shownFastT, shownFastName = nil, ""
	lastPassPop = -math.huge
	posLabel.Visible = false
	fastLabel.Visible = false
	youLabel.Visible = false
	local prim, acc = liveryColors(info and info.vehicle)
	kart.BackgroundColor3 = prim
	kartStripe.BackgroundColor3 = acc
	local kx, ky = px(k.x, k.y)
	kart.Position = UDim2.fromOffset(kx, ky)
	kart.Rotation = math.deg(k.heading) + 90
	lapCaption.Text = "DEMO LAP"
	lapLabel.Text = "0.0"
	setBestText()
	bestLabel.TextColor3 = GOLD
	hintLabel.Text = hintText()
	hintLabel.Visible = true
	popLabel.Visible = false
	borrowLabels(parent)
	local r = root :: Frame
	r.Visible = true
	active = true

	-- Input lives only while the kart runs (disconnected in stop()).
	table.insert(conns, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			stickX = input.Position.X
		end
	end))
	table.insert(conns, UserInputService.TouchStarted:Connect(function(input: InputObject)
		local w = parent.AbsoluteSize.X
		touches[input] = if input.Position.X < w / 2 then -1 else 1
	end))
	table.insert(conns, UserInputService.TouchEnded:Connect(function(input: InputObject)
		touches[input] = nil
	end))
	stepConn = RunService.RenderStepped:Connect(step)

	play("chip_go", 0.45)
	local eng = sound("chip_engine", true, 0.3)
	if eng then
		eng.PlaybackSpeed = 0.75
		eng:Play()
	end
end

-- Shows the kart on `id`'s outline once the curtain has faded in (START_DELAY). Safe to call repeatedly; an id with
-- no baked outline does nothing.
function CurtainKart.start(parent: Frame, id: string?, color: Color3?)
	CurtainKart.stop()
	if type(id) ~= "string" then
		return
	end
	runToken += 1
	local token = runToken
	task.delay(START_DELAY, function()
		if token ~= runToken or not parent.Visible then
			return
		end
		loadData() -- may wait for the data module once; re-check that this curtain is still the current one
		if token ~= runToken or not (tracks :: any)[id] then
			return
		end
		local ok, err = pcall(function(): boolean
			begin(parent, id, color or WOOD_DARK)
			return true
		end)
		if not ok then
			warn("[SkyRally][CURTAINKART] " .. tostring(err))
			CurtainKart.stop()
		end
	end)
end

-- Stops input and hides the kart this frame. Returns this curtain's best counted lap and the toast line (nil when no
-- lap counted); the session best goes on the player attribute CurtainBest_<id> (session only, no save, no reward).
function CurtainKart.stop(): (number?, string?)
	runToken += 1
	disconnectAll()
	restoreLabels()
	local was = active
	active = false
	if root then
		root.Visible = false
	end
	local eng = sounds.chip_engine
	if eng then
		eng:Stop()
	end
	-- Shared curtain (item 28): where you finished among the karts on screen, if you drove.
	local finish = ""
	if was and playerControl and shownPos > 0 and shownField >= 2 then
		finish = if shownPos == 1
			then string.format("  -  P1 of %d!", shownField)
			else string.format("  -  P%d of %d", shownPos, shownField)
	end
	remote = nil
	for _, rv in rivals do
		releaseRival(rv)
	end
	if posLabel then
		posLabel.Visible = false
		fastLabel.Visible = false
		youLabel.Visible = false
	end
	if not was or runBest == nil then
		if finish ~= "" then
			return nil, (if shownPos == 1 then "CURTAIN KART WINNER" else "CURTAIN KART") .. finish
		end
		return nil, nil
	end
	local best = runBest :: number
	runBest = nil
	local id = trackId
	pcall(function()
		LocalPlayer:SetAttribute("CurtainBest_" .. (string.gsub(id, "%W", "_")), sessionBest[id])
	end)
	if recordBefore == nil or best < (recordBefore :: number) then
		return best, string.format("CURTAIN RECORD %s s", Sim.formatLap(best)) .. finish
	end
	return best, string.format("CURTAIN LAP %s s  -  record %s s", Sim.formatLap(best), Sim.formatLap(recordBefore :: number)) .. finish
end

function CurtainKart.isActive(): boolean
	return active
end

return CurtainKart
