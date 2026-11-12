--!strict
-- World-space text for REMARKABLE Batch 2 items 18 and 19, driven by client/ItemClient:
--   * say(plane, text, rival): a bot's taunt as a speech bubble over its vehicle (server/AIRacers sends "BotTaunt"; the
--     lines and their rate limits are Shared.BotPersonality). A cream paper bubble with a tail and a name tab in the
--     bot's livery colour ("RIVAL - BLAZE WING" for the rival), popped in with an overshoot and a soft pop sound.
--   * The rival marker: the rival's name in an accent colour with a flame glyph (shared/RivalRules) over the bot whose
--     model carries Rival = true (polled once a second), on its speech tab and on its results row. No pill, nothing
--     covers text. A short sting plays when the rival and the player swap places (player attribute RivalAhead).
--   * setNemesis(plane, name): PAYBACK over the racer who last hit this player. A brief toast (ItemRules.NEMESIS_TOAST:
--     0.15 s pop, 1.2 s hold, 0.3 s fade, then disabled and un-adorned; 120x32 px, seen within 120 studs; a repeat hit by
--     the same racer re-pops it at most once per 4 s). The grudge itself (ItemRules.REVENGE_WINDOW, ended by clearNemesis
--     when the player gets even) is unchanged and no longer keeps anything on screen.
-- HUD layout v2 (docs/design/HUD_LAYOUT.md 7.1): bubbles are small (148x56, rival 160x62) and high (8.6 studs, name labels
-- stay at 4.4), shown only within 45 studs and on screen, one at a time (the rest queue; a taunt older than 3 s is dropped),
-- and skipped when their screen rect would sit under the nav, a HUD column, a hero message or the kart band
-- (HudLayoutRules.bubbleClear). While one shows (and 0.3 s after) its speaker's name label is hidden: the model carries
-- SpeechUp = true (client/RacerView reads it).
-- Everything is pooled BillboardGuis animated by hand in step() (no tweens or Instance.new per event once warm), with
-- MaxDistance culling, so a phone pays only for what is on screen.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local ItemJuice = require(script.Parent:WaitForChild("ItemJuice"))
local RivalRules = require(Shared:WaitForChild("RivalRules"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local HudLayoutRules = require(Shared:WaitForChild("HudLayoutRules"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
-- visualOf: a remote player's visual clone while RacerView draws one (RemoteCloneRules), else the hull itself
local PlayerStreamRules = require(Shared:WaitForChild("PlayerStreamRules"))

local LocalPlayer = Players.LocalPlayer

local RivalBubbles = {}

local PAPER = Color3.fromRGB(255, 248, 230)
local INK = Color3.fromRGB(40, 28, 22)
local NEMESIS_RED = Color3.fromRGB(205, 44, 40)

-- Studio verifier tuning (rival marker and sting).
local RIVAL_ACCENT = Color3.fromRGB(255, 156, 44) -- the rival's name colour everywhere (warm orange, not the nemesis red)
local RIVAL_TAB_BG = Color3.fromRGB(46, 32, 24) -- the speech tab behind the accent name
local STING_PASSED = { cue = "ring_pass", pitch = 1.3, volume = 0.4 } -- you took the lead over the rival
local STING_PASSED_BY = { cue = "magnet_lock", pitch = 1.0, volume = 0.38 } -- the rival took it from you

local BUBBLE_POOL = 1 -- one bubble at a time (7.1 rule 2)
local BUBBLE_MAX_DIST = 45 -- studs from the camera
local BUBBLE_Y = 8.6 -- studs above the hull (name labels sit at 4.4)
local BUBBLE_ALPHA = 0.08 -- 0.92 opacity
local QUEUE_MAX = 3
local QUEUE_STALE = 3 -- s: a queued taunt older than this is dropped
local SPEECH_TAIL = 0.3 -- s the name label stays hidden after the bubble goes
local BUBBLE_IN = 0.22
local BUBBLE_OUT = 0.18
local SOUND_RANGE = 170

local function hullOf(plane: any): BasePart?
	if typeof(plane) == "Instance" and plane:IsA("Model") and plane.Parent then
		local hull = plane.PrimaryPart or plane:FindFirstChild("Hull")
		if hull and hull:IsA("BasePart") then
			return hull
		end
	end
	return nil
end

-- Livery colour by roster name (the model carries BotKey; BotName is the shown username); cream for anyone else.
local function liveryOf(plane: Model): Color3
	local name = plane:GetAttribute("BotKey") or plane:GetAttribute("BotName")
	for _, cfg in PlaneConfig.AI_BOTS do
		if (cfg :: any).name == name then
			return (cfg :: any).color
		end
	end
	return Color3.fromRGB(255, 200, 90)
end

-- Overshoot ease (back-out) for pop-ins.
local function backOut(t: number): number
	local x = math.clamp(t, 0, 1) - 1
	return 1 + x * x * (2.7 * x + 1.7)
end

local container: Folder? = nil
local function holder(): Folder
	local f = container
	if f and f.Parent then
		return f
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyBubbles"
	nf.Parent = pg
	container = nf
	return nf
end

local function billboard(name: string, size: UDim2, maxDistance: number): BillboardGui
	local g = Instance.new("BillboardGui")
	g.Name = name
	g.Size = size
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.MaxDistance = maxDistance
	g.ResetOnSpawn = false
	g.Enabled = false
	g.Active = false
	g.Parent = holder()
	return g
end

local function stroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
end

------------------------------------------------------------------------------------------------------------------------
-- Speech bubbles
------------------------------------------------------------------------------------------------------------------------

type Bubble = {
	gui: BillboardGui,
	body: Frame,
	text: TextLabel,
	tab: TextLabel,
	scale: UIScale,
	plane: Model?,
	startedAt: number,
	hold: number,
}
local bubbles: { Bubble } = {}

local function newBubble(i: number): Bubble
	local g = billboard("TauntBubble" .. i, UDim2.fromOffset(148, 56), BUBBLE_MAX_DIST + 15)
	g.StudsOffsetWorldSpace = Vector3.new(0, BUBBLE_Y, 0)
	local sc = Instance.new("UIScale")
	sc.Parent = g
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.AnchorPoint = Vector2.new(0.5, 0)
	body.Position = UDim2.new(0.5, 0, 0, 9)
	body.Size = UDim2.new(1, -6, 1, -21)
	body.BackgroundColor3 = PAPER
	body.BackgroundTransparency = BUBBLE_ALPHA
	body.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 11)
	c.Parent = body
	stroke(body, INK, 2)
	body.Parent = g
	-- The tail: a small turned square under the bubble, drawn before the body so the seam hides.
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, -14, 1, -13)
	tail.Size = UDim2.fromOffset(10, 10)
	tail.Rotation = 45
	tail.BackgroundColor3 = PAPER
	tail.BackgroundTransparency = BUBBLE_ALPHA
	tail.BorderSizePixel = 0
	tail.ZIndex = 0
	stroke(tail, INK, 2)
	tail.Parent = g
	local t = Instance.new("TextLabel")
	t.Name = "Line"
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(7, 8)
	t.Size = UDim2.new(1, -14, 1, -10)
	t.Font = Enum.Font.GothamBold
	t.TextColor3 = INK
	t.TextWrapped = true
	t.TextScaled = true
	t.RichText = false -- display names are data, never markup
	t.ZIndex = 2
	local lim = Instance.new("UITextSizeConstraint")
	lim.MaxTextSize = 13
	lim.MinTextSize = 9
	lim.Parent = t
	t.Parent = body
	local tab = Instance.new("TextLabel")
	tab.Name = "Tab"
	tab.AnchorPoint = Vector2.new(0, 0)
	tab.Position = UDim2.fromOffset(10, 0)
	tab.Size = UDim2.fromOffset(96, 16)
	tab.AutomaticSize = Enum.AutomaticSize.X
	tab.BackgroundColor3 = Color3.fromRGB(255, 200, 90)
	tab.BorderSizePixel = 0
	tab.Font = Enum.Font.GothamBlack
	tab.TextSize = 12
	tab.TextColor3 = Color3.new(1, 1, 1)
	tab.RichText = false
	tab.ZIndex = 3
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 5)
	tc.Parent = tab
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = tab
	stroke(tab, INK, 1.2)
	tab.Parent = g
	return { gui = g, body = body, text = t, tab = tab, scale = sc, plane = nil, startedAt = -math.huge, hold = 0 }
end

local function bubbleFor(plane: Model): Bubble
	if #bubbles == 0 then
		for i = 1, BUBBLE_POOL do
			table.insert(bubbles, newBubble(i))
		end
	end
	local free: Bubble? = nil
	local oldest = bubbles[1]
	for _, b in bubbles do
		if b.plane == plane then
			return b
		end
		if b.plane == nil and not free then
			free = b
		end
		if b.startedAt < oldest.startedAt then
			oldest = b
		end
	end
	return free or oldest
end

local queue: { { plane: Model, text: string, rival: boolean, at: number } } = {}

local function anyActive(): boolean
	for _, b in bubbles do
		if b.plane then
			return true
		end
	end
	return false
end

-- Within 45 studs of the camera, on screen, and not under the HUD (HudLayoutRules.bubbleClear): else skipped.
local function worthShowing(hull: BasePart, size: Vector2): boolean
	local cam = workspace.CurrentCamera
	if not cam then
		return false
	end
	if (cam.CFrame.Position - hull.Position).Magnitude > BUBBLE_MAX_DIST then
		return false
	end
	local vp, onScreen = cam:WorldToViewportPoint(hull.Position + Vector3.new(0, BUBBLE_Y, 0))
	if not onScreen or vp.Z <= 0 then
		return false
	end
	local snap = HudMetrics.get()
	local rect = { x = vp.X - size.X / 2, y = vp.Y - size.Y / 2, w = size.X, h = size.Y }
	local heroUp = LocalPlayer:GetAttribute("HudHeroUp") == true
		or LocalPlayer:GetAttribute("HudCountdownUp") == true
		or LocalPlayer:GetAttribute("HudArrowUp") == true
	return HudLayoutRules.bubbleClear(rect, HudLayoutRules.reserved(snap.viewport.X, snap.viewport.Y, snap.rects, heroUp))
end

local function show(model: Model, hull: BasePart, text: string, rival: boolean)
	local size = if rival then Vector2.new(160, 62) else Vector2.new(148, 56)
	if not worthShowing(hull, size) then
		return
	end
	local b = bubbleFor(model)
	local botName = model:GetAttribute("BotName")
	local name = string.upper(if type(botName) == "string" then botName else "RACER")
	b.plane = model
	b.startedAt = os.clock()
	b.hold = 1.8 + math.min(#text, 60) * 0.03
	b.text.Text = string.sub(text, 1, 80)
	b.tab.Text = if rival then RivalRules.marked(name) else name
	b.tab.TextColor3 = if rival then RIVAL_ACCENT else Color3.new(1, 1, 1)
	b.tab.BackgroundColor3 = if rival then RIVAL_TAB_BG else liveryOf(model)
	b.gui.Adornee = PlayerStreamRules.visualOf(hull)
	b.gui.Size = UDim2.fromOffset(size.X, size.Y)
	b.scale.Scale = 0
	b.gui.Enabled = true
	model:SetAttribute("SpeechUp", true) -- RacerView hides this racer's name label meanwhile (the tab carries the name)
	local cam = workspace.CurrentCamera
	local d = if cam then (cam.CFrame.Position - hull.Position).Magnitude else 0
	if d < SOUND_RANGE then
		ItemJuice.play("taunt_pop", 1 + math.random() * 0.12, 0.32 * (1 - d / SOUND_RANGE) + 0.08)
	end
end

-- A bot says something. rival: the accent name tab with the flame glyph and a slightly bigger bubble. One bubble at a
-- time: a taunt that arrives while another shows waits its turn (3 s at most).
function RivalBubbles.say(plane: any, text: any, rival: boolean?)
	local hull = hullOf(plane)
	if not hull or type(text) ~= "string" or text == "" then
		return
	end
	local model = plane :: Model
	if anyActive() then
		table.insert(queue, { plane = model, text = text, rival = rival == true, at = os.clock() })
		while #queue > QUEUE_MAX do
			table.remove(queue, 1)
		end
		return
	end
	show(model, hull, text, rival == true)
end

local function endSpeech(model: Model)
	task.delay(SPEECH_TAIL, function()
		for _, b in bubbles do
			if b.plane == model then
				return -- spoke again meanwhile: the label stays hidden
			end
		end
		if model.Parent then
			model:SetAttribute("SpeechUp", nil)
		end
	end)
end

local function stepBubbles(now: number)
	for _, b in bubbles do
		local plane = b.plane
		if plane then
			local age = now - b.startedAt
			local total = BUBBLE_IN + b.hold + BUBBLE_OUT
			if age >= total or not plane.Parent then
				b.plane = nil
				b.gui.Enabled = false
				(b.gui :: any).Adornee = nil
				if plane.Parent then
					endSpeech(plane)
				end
			elseif age < BUBBLE_IN then
				b.scale.Scale = backOut(age / BUBBLE_IN)
			elseif age > BUBBLE_IN + b.hold then
				b.scale.Scale = 1 - (age - BUBBLE_IN - b.hold) / BUBBLE_OUT
			else
				-- A gentle bob so it reads as spoken, not printed.
				b.scale.Scale = 1 + math.sin(age * 5) * 0.015
			end
		end
	end
	-- The next queued taunt (stale ones are dropped; ones that are out of range or under the HUD are skipped).
	while #queue > 0 and not anyActive() do
		local item = table.remove(queue, 1) :: { plane: Model, text: string, rival: boolean, at: number }
		local hull = hullOf(item.plane)
		if hull and now - item.at <= QUEUE_STALE then
			show(item.plane, hull, item.text, item.rival)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- RIVAL flag and the PAYBACK nemesis tag
------------------------------------------------------------------------------------------------------------------------

local rivalGui: BillboardGui? = nil
local rivalLabel: TextLabel? = nil
local rivalPlane: Model? = nil
local rivalScanAt = 0

local function ensureRivalGui(): (BillboardGui, TextLabel)
	local g, l = rivalGui, rivalLabel
	if g and l then
		return g, l
	end
	local ng = billboard("RivalFlag", UDim2.fromOffset(160, 22), 650)
	ng.StudsOffsetWorldSpace = Vector3.new(0, 4.6, 0)
	local nl = Instance.new("TextLabel")
	nl.AnchorPoint = Vector2.new(0.5, 0.5)
	nl.Position = UDim2.fromScale(0.5, 0.5)
	nl.Size = UDim2.fromScale(1, 1)
	nl.BackgroundTransparency = 1 -- the name alone, no plate behind it
	nl.Font = Enum.Font.GothamBlack
	nl.TextSize = 13
	nl.TextColor3 = RIVAL_ACCENT
	nl.Text = RivalRules.marked("RIVAL")
	nl.RichText = false
	stroke(nl, INK, 1.6)
	nl.Parent = ng
	rivalGui, rivalLabel = ng, nl
	return ng, nl
end

local function scanRival()
	local planes = workspace:FindFirstChild("Planes")
	local found: Model? = nil
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Rival") == true then
				found = m
				break
			end
		end
	end
	if found == rivalPlane then
		return
	end
	rivalPlane = found
	local g, l = ensureRivalGui()
	local hull = if found then hullOf(found) else nil
	if found and hull then
		local botName = found:GetAttribute("BotName")
		l.Text = RivalRules.marked(string.upper(if type(botName) == "string" then botName else "RIVAL"))
		g.Adornee = PlayerStreamRules.visualOf(hull)
		g.Enabled = true
	else
		g.Enabled = false
		(g :: any).Adornee = nil
	end
end

-- The toast: nemesisPlane/nemesisUntil are the grudge (kept for the whole REVENGE_WINDOW, cleared on getting even);
-- the tag itself shows only for ItemRules.NEMESIS_TOAST (pop, hold, fade) and is then disabled and un-adorned.
local NEMESIS_MAX_DIST = 120 -- studs: a hit racer is near; the toast never reads from across the track
local nemesisGui: BillboardGui? = nil
local nemesisScale: UIScale? = nil
local nemesisFade: { { inst: Instance, prop: string, base: number } } = {}
local nemesisPlane: Model? = nil
local nemesisUntil = 0
local nemesisPopAt = -math.huge
local nemesisToastUp = false

local function ensureNemesisGui(): (BillboardGui, TextLabel)
	local g, s = nemesisGui, nemesisScale
	local nm = if g then g:FindFirstChild("Name", true) else nil
	if g and s and nm then
		return g, nm :: TextLabel
	end
	local ng = billboard("NemesisTag", UDim2.fromOffset(120, 32), NEMESIS_MAX_DIST)
	ng.StudsOffsetWorldSpace = Vector3.new(0, 6.2, 0)
	local sc = Instance.new("UIScale")
	sc.Parent = ng
	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundColor3 = NEMESIS_RED
	body.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = body
	local bs = Instance.new("UIStroke")
	bs.Color = PAPER
	bs.Thickness = 1.6
	bs.Parent = body
	body.Parent = ng
	local head = Instance.new("TextLabel")
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0.58, 0)
	head.Font = Enum.Font.GothamBlack
	head.TextSize = 13
	head.TextColor3 = PAPER
	head.Text = "PAYBACK"
	local hs = Instance.new("UIStroke")
	hs.Color = INK
	hs.Thickness = 1.2
	hs.Parent = head
	head.Parent = body
	local nm2 = Instance.new("TextLabel")
	nm2.Name = "Name"
	nm2.BackgroundTransparency = 1
	nm2.Position = UDim2.fromScale(0, 0.52)
	nm2.Size = UDim2.new(1, 0, 0.42, 0)
	nm2.Font = Enum.Font.GothamBold
	nm2.TextSize = 10
	nm2.TextColor3 = PAPER
	nm2.RichText = false
	nm2.Parent = body
	nemesisGui, nemesisScale = ng, sc
	nemesisFade = {
		{ inst = body, prop = "BackgroundTransparency", base = 0 },
		{ inst = bs, prop = "Transparency", base = 0 },
		{ inst = head, prop = "TextTransparency", base = 0 },
		{ inst = hs, prop = "Transparency", base = 0 },
		{ inst = nm2, prop = "TextTransparency", base = 0 },
	}
	return ng, nm2
end

local function hideNemesisToast()
	nemesisToastUp = false
	local g = nemesisGui
	if g then
		g.Enabled = false
		(g :: any).Adornee = nil
	end
end

-- Marks the racer who just hit this player (any vehicle model). seconds: the grudge window. The grudge is kept for the
-- whole window; the visual is a brief toast (a repeat hit by the same racer re-pops it at most once per 4 s).
function RivalBubbles.setNemesis(plane: any, name: string, seconds: number?)
	local hull = hullOf(plane)
	if not hull then
		return
	end
	local now = os.clock()
	local same = plane == nemesisPlane
	nemesisPlane = plane :: Model
	nemesisUntil = now + (seconds or ItemRules.REVENGE_WINDOW)
	if not ItemRules.nemesisRepop(same, now - nemesisPopAt) then
		return
	end
	local g, nm = ensureNemesisGui()
	nm.Text = name
	g.Adornee = PlayerStreamRules.visualOf(hull)
	nemesisPopAt = now
	nemesisToastUp = true
	local sc = nemesisScale
	if sc then
		sc.Scale = 0
	end
	g.Enabled = true
end

-- Got even (or the race reset): the grudge and the tag go. plane: only clear if it marks this vehicle (nil clears any).
function RivalBubbles.clearNemesis(plane: any?)
	if plane ~= nil and plane ~= nemesisPlane then
		return
	end
	nemesisPlane = nil
	hideNemesisToast()
end

local function stepNemesis(now: number)
	local plane = nemesisPlane
	if plane and (now >= nemesisUntil or not plane.Parent) then
		RivalBubbles.clearNemesis(nil)
		return
	end
	if not nemesisToastUp then
		return
	end
	local scale, alpha = ItemRules.nemesisToast(now - nemesisPopAt)
	local g, sc = nemesisGui, nemesisScale
	if not scale or not alpha or not g or not sc or not g.Adornee or not (g.Adornee :: Instance).Parent then
		hideNemesisToast()
		return
	end
	sc.Scale = scale
	for _, f in nemesisFade do
		(f.inst :: any)[f.prop] = alpha
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Results card (RaceUI hook): the rival's row gets its name in the accent colour with the flame glyph, in place (the
-- old pill sat on top of the name and time). standings rows: {rank, name, isPlayer, ...}; rows are Frames named Row_<i>
-- whose first TextLabel child is the "<ordinal>  <name>" text.
------------------------------------------------------------------------------------------------------------------------

function RivalBubbles.decorateResults(container: Instance?, standings: any)
	local plane = rivalPlane
	if not container or not plane then
		return
	end
	local rivalName = plane:GetAttribute("BotName")
	if type(rivalName) ~= "string" then
		return
	end
	local idx = RivalRules.rivalRow(standings, rivalName)
	local frame = if idx then container:FindFirstChild("Row_" .. tostring(idx)) else nil
	-- the name label by name: the first TextLabel in the row can be the medal's fallback digit (v38-flow)
	local found = if frame then (frame:FindFirstChild("NameText") or frame:FindFirstChildWhichIsA("TextLabel")) else nil
	local nameLabel = if found and found:IsA("TextLabel") then found else nil
	if nameLabel and frame and not frame:FindFirstChild("RivalMark") then -- once per row (the card can be re-decorated)
		-- v38-flow round 3: the flame rides AFTER the name as its own mark (prefixing it into the text truncated the name
		-- to "Copper..." in narrow results columns); the label gives up the mark's width and the name keeps its colour.
		nameLabel.TextColor3 = RIVAL_ACCENT
		local mark = Instance.new("TextLabel")
		mark.Name = "RivalMark"
		mark.BackgroundTransparency = 1
		mark.Text = RivalRules.GLYPH
		mark.TextScaled = true
		mark.AnchorPoint = Vector2.new(0, 0.5)
		mark.ZIndex = nameLabel.ZIndex + 1
		mark.Parent = frame
		-- scale-only geometry (the results card sits under a fit UIScale): the name gives up 8 % of the row, the flame
		-- stands at the end of the name column, square, 60 % of the row tall
		local base = nameLabel.Size
		nameLabel.Size = UDim2.new(base.X.Scale - 0.08, base.X.Offset, base.Y.Scale, base.Y.Offset)
		mark.AnchorPoint = Vector2.new(0, 0.5)
		mark.Position = UDim2.new(nameLabel.Position.X.Scale + base.X.Scale - 0.08, nameLabel.Position.X.Offset + base.X.Offset + 2, 0.5, 0)
		mark.Size = UDim2.fromScale(0.6, 0.6)
		mark.SizeConstraint = Enum.SizeConstraint.RelativeYY
	end
end
-- (bubbles and the flag use RivalRules.marked; the results row draws RivalRules.GLYPH as its own mark)

------------------------------------------------------------------------------------------------------------------------

function RivalBubbles.step(_dt: number)
	local now = os.clock()
	if #bubbles > 0 then
		stepBubbles(now)
	end
	stepNemesis(now)
	if now >= rivalScanAt then
		rivalScanAt = now + 1
		scanRival()
	end
	-- The RIVAL flag steps aside while the rival is talking (its bubble carries the same tab).
	local rg = rivalGui
	if rg and rivalPlane then
		local talking = false
		for _, b in bubbles do
			if b.plane == rivalPlane then
				talking = true
				break
			end
		end
		rg.Enabled = not talking and (rg :: any).Adornee ~= nil
	end
end

-- Who is ahead, from the server's standings (RaceManager). A flip plays the sting; a race reset forgets the old side.
local rivalAheadPrev: boolean? = nil
local lastStingAt = -math.huge

local function onRivalAhead()
	local v = LocalPlayer:GetAttribute("RivalAhead")
	local now: boolean? = if type(v) == "boolean" then v else nil
	local now_t = os.clock()
	local kind = RivalRules.sting(rivalAheadPrev, now, now_t, lastStingAt)
	rivalAheadPrev = now
	if kind then
		lastStingAt = now_t
		local s = if kind == "passed" then STING_PASSED else STING_PASSED_BY
		Sfx.play(s.cue, s.pitch, s.volume)
	end
end

function RivalBubbles.init()
	holder()
	LocalPlayer:GetAttributeChangedSignal("RivalAhead"):Connect(onRivalAhead)
	-- A new race clears the old grudge marker.
	RaceAttr.changed("RaceResetSeq", function()
		RivalBubbles.clearNemesis(nil)
		rivalAheadPrev = nil
	end)
end

return RivalBubbles
