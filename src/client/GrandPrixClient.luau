--!strict
-- Grand Prix (v37), client side. Presentation only: server/GrandPrix decides and pays; shared/GrandPrixRules has the
-- numbers. What it draws:
--   * the course select row (TrackFlow.addBoardRow): GRAND PRIX, the three class trophies, and the button that opens
--   * the class picker: ROOKIE / PRO / MASTER cards (best trophy and points, lock line), the cup's tracks, the length
--     (3 races or all of them when more than 3 are open) and START (GrandPrixRemote "Start");
--   * the grid chip "GRAND PRIX  RACE 2/5  ROOKIE" for the countdown;
--   * after each race ("Standings"): the standings panel (rank, name, points this race, total; the player's row in
--     gold; rows slide from the old order to the new one while the totals count up), NEXT RACE / QUIT;
--   * the NEXT card before the next track loads (track art and name, countdown);
--   * after the last race: FINAL STANDINGS, then the podium ceremony of the cup's top three (client/PodiumCeremony with
--     the cup's title) and the trophy card (gold / silver / bronze, points, Cash, a class it opened), then the hub.
-- The local attribute GPPanelUp keeps the HUD in its results phase while a panel is up (client/RaceUI reads it).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GrandPrixRules = require(Shared:WaitForChild("GrandPrixRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local CourseArt = require(Shared:WaitForChild("CourseArt")) :: { [string]: string? }
local UiSkin = require(script.Parent:WaitForChild("UiSkin"))
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

-- v38-flow round 3: a gamepad lands on the screen's primary button (START / NEXT RACE / BACK TO HUB) when it opens.
local function focusPrimary(root: Instance?, name: string)
	if not root or not (UserInputService.GamepadEnabled or GuiService:IsTenFootInterface()) then
		return
	end
	task.defer(function()
		local b = root:FindFirstChild(name, true)
		if b and b:IsA("GuiButton") and b.Visible then
			GuiService.SelectedObject = b
		end
	end)
end
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
-- v37 generated cues (gp_fanfare, trophy_sting, tally_tick, ui_big_confirm); a missing module or id is silent.
local Sfx37 = require(script.Parent:WaitForChild("Sfx37")) :: any
local function sfx(name: string, vol: number, pitch: number?)
	if Sfx37 and type(Sfx37.play) == "function" then
		pcall(Sfx37.play, name, vol, pitch)
	end
end

local LocalPlayer = Players.LocalPlayer

local GrandPrixClient = {}

local INK = UiSkin.color("ink")
local GOLD = UiSkin.color("gold")
local WHITE = Color3.new(1, 1, 1)
local TROPHY_COLOR = {
	[1] = UiSkin.color("place_3"),
	[2] = UiSkin.color("place_2"),
	[3] = UiSkin.color("place_1"),
} :: { [number]: Color3 }
local MEDAL_ICON = { [3] = "icon_medal_1", [2] = "icon_medal_2", [1] = "icon_medal_3" } :: { [number]: string }

local remote: RemoteEvent? = nil
local gui: ScreenGui
local trackFlow: any = nil

local pickerRoot: Frame? = nil
local standRoot: Frame? = nil
local nextRoot: Frame? = nil
local trophyRoot: Frame? = nil
local gridChip: Frame? = nil

local pickClass = "rookie"
local pickLength = "full"
local lastStandings: any = nil
local standingsSeq = 0
local nextShownFor = 0 -- the race index whose NEXT card has shown
local trophyPlayed = false
local qaMode = false -- Studio qaShow: panels stay up outside a cup

-- The art for a trophy level: the gold cup for gold; silver and bronze use their medal art (a tint cannot turn the gold
-- cup silver); none = the cup, dimmed by the caller.
local function trophyArt(t: number): string
	return if t == 2 then "icon_medal_2" elseif t == 1 then "icon_medal_3" else "icon_trophy"
end

local function fire(action: string, a: any?, b: any?)
	local r = remote
	if r then
		r:FireServer(action, a, b)
	end
end

local function record(): GrandPrixRules.Record
	return GrandPrixRules.decode(LocalPlayer:GetAttribute("GPTrophies"))
end

local function trackName(id: any): string
	local info = TrackInfo.get(if type(id) == "string" then id else nil)
	return if info then info.trackName else tostring(id)
end

local function artFor(id: any): string?
	if type(id) ~= "string" then
		return nil
	end
	return CourseArt[string.lower((string.gsub(id, "%-", "")))]
end

-- Race tracks open for a race on this player's board (PortalStates, server-published).
local function openTracks(): { string }
	local raw = LocalPlayer:GetAttribute("PortalStates")
	local open: { [string]: boolean } = {}
	if type(raw) == "string" then
		local ok, states = pcall(function(): any
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(states) == "table" then
			for _, st in states do
				if type(st) == "table" and st.open == true and type(st.id) == "string" then
					local raceOpen = false
					for _, md in (if type(st.modes) == "table" then st.modes else {}) :: { any } do
						if type(md) == "table" and md.mode == "race" and md.open == true then
							raceOpen = true
						end
					end
					open[st.id] = raceOpen
				end
			end
		end
	end
	return GrandPrixRules.openTracks(open)
end

local function scaleFor(designW: number, designH: number): number
	local vp = gui.AbsoluteSize
	if vp.X <= 0 or vp.Y <= 0 then
		return 1
	end
	return math.clamp(math.min(vp.X * 0.94 / designW, vp.Y * 0.92 / designH), 0.5, 1.35)
end

local function setPanelUp()
	local up = (standRoot ~= nil and standRoot.Visible) or (nextRoot ~= nil and nextRoot.Visible) or (trophyRoot ~= nil and trophyRoot.Visible)
	LocalPlayer:SetAttribute("GPPanelUp", if up then true else nil)
end

-- A dimmed full-screen layer that holds one centred panel of design size w x h (scaled to the screen).
local function layer(name: string, w: number, h: number, dim: number): (Frame, Frame)
	local back = Instance.new("Frame")
	back.Name = name
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(4, 8, 24)
	back.BackgroundTransparency = dim
	back.BorderSizePixel = 0
	back.Active = true
	back.Visible = false
	back.ZIndex = 1
	back.Parent = gui
	local panel = UiSkin.panel(back, "panel", {
		name = "Panel",
		size = UDim2.fromOffset(w, h),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		zIndex = 2,
		S = 1,
	})
	local sc = Instance.new("UIScale")
	sc.Name = "Fit"
	sc.Parent = panel
	local function fit()
		sc.Scale = scaleFor(w, h)
		GrandPrixClient.textFloor(panel)
	end
	fit()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	panel.DescendantAdded:Connect(function(d: Instance)
		if d:IsA("TextLabel") then
			task.defer(GrandPrixClient.textFloor, panel)
		end
	end)
	return back, panel
end

-- Phones: a panel scaled down to fit (UIScale Fit) would shrink its text under 12 screen px. Every label's size is raised
-- so it lands at TEXT_FLOOR or more on screen (fixed sizes through TextSize, scaled text through its size constraint).
local TEXT_FLOOR = 12
function GrandPrixClient.textFloor(panel: Frame)
	local sc = panel:FindFirstChild("Fit") :: UIScale?
	local s = if sc then sc.Scale else 1
	local min = math.ceil(TEXT_FLOOR / math.max(s, 0.05))
	for _, d in panel:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local t = d :: TextLabel
			if t.TextScaled then
				-- scaled text fills its own box (raising its floor only overflows the box): left as it is
			else
				local base = t:GetAttribute("GPSize")
				if type(base) ~= "number" then
					base = t.TextSize
					t:SetAttribute("GPSize", base)
				end
				t.TextSize = math.max(base :: number, min)
			end
		end
	end
end

-- Studio QA only: show a panel from a fake payload (captures without racing a whole cup).
function GrandPrixClient.qaShow(kind: string, data: any)
	if not RunService:IsStudio() then
		return
	end
	qaMode = true
	lastStandings = data
	nextShownFor = 0
	trophyPlayed = false
	if kind == "picker" then
		GrandPrixClient.openPicker()
	elseif kind == "standings" then
		GrandPrixClient.showStandings(data)
	elseif kind == "next" then
		GrandPrixClient.showNext()
	elseif kind == "trophy" then
		GrandPrixClient.trophyMoment()
	end
end

local function hideLayer(f: Frame?)
	if f and f.Visible then
		f.Visible = false
	end
	setPanelUp()
end

----------------------------------------------------------------------------------------------------------------- picker

local pickerCards: { [string]: GuiButton } = {}
local pickerThumbs: Frame? = nil
local pickerCupLine: TextLabel? = nil
local pickerInfo: TextLabel? = nil
local pickerStart: GuiButton? = nil
local lengthTabs: { [string]: GuiButton } = {}

local DIM = Color3.fromRGB(60, 72, 116)
local SOFT = Color3.fromRGB(214, 224, 248)

-- One course thumbnail for the cup row: the course art, its number in the cup and its name under it.
local function thumb(parent: Instance, id: string, n: number, dim: boolean, w: number)
	local f = Instance.new("Frame")
	f.Name = "T_" .. id
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromOffset(w, 96)
	f.LayoutOrder = n
	f.ZIndex = 5
	f.Parent = parent
	local img = Instance.new("ImageLabel")
	img.Name = "Art"
	img.Image = artFor(id) or ""
	img.ScaleType = Enum.ScaleType.Crop
	img.BackgroundColor3 = (TrackInfo.get(id) or { color = DIM } :: any).color
	img.Size = UDim2.fromOffset(w, 68)
	img.ZIndex = 5
	img.ImageTransparency = if dim then 0.45 else 0
	img.Parent = f
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = img
	local st = Instance.new("UIStroke")
	st.Color = INK
	st.Thickness = 3
	st.Parent = img
	local badge = UiSkin.panel(img, "chip", { name = "N", variant = "header", size = UDim2.fromOffset(28, 28), position = UDim2.fromOffset(-6, -6), zIndex = 7, S = 0.8 })
	UiSkin.numeral(badge, if dim then "?" else tostring(n), { size = UDim2.fromScale(1, 1), maxText = 20, zIndex = 8, color = INK, stroke = 0 })
	-- the name under the art only where it fits (a phone shows the art and its number)
	local small = scaleFor(860, 590) < 0.8
	if not small then
		UiSkin.text(f, trackName(id), "caption", { name = "Name", size = UDim2.new(1, 0, 0, 22), position = UDim2.fromOffset(0, 72), textSize = 14, zIndex = 5, color = SOFT })
	end
end

local function paintPicker()
	local rec = record()
	local open = openTracks()
	local lengths = GrandPrixRules.lengths(#open)
	if not table.find(lengths, pickLength) then
		pickLength = "full"
	end
	if not GrandPrixRules.classOpen(rec, pickClass) then
		pickClass = "rookie"
	end
	for c, card in pickerCards do
		local isOpen = GrandPrixRules.classOpen(rec, c)
		local sel = c == pickClass
		local stroke = card:FindFirstChild("SelStroke") :: UIStroke?
		if stroke then
			stroke.Enabled = sel
		end
		local sc = card:FindFirstChildOfClass("UIScale")
		if sc then
			TweenService:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = if sel then 1.04 else 0.97 }):Play()
		end
		local lock = card:FindFirstChild("Lock") :: GuiObject?
		if lock then
			lock.Visible = not isOpen
		end
		for _, name in { "Star1", "Star2", "Star3", "Slot", "Trophy", "Points", "Desc" } do
			local g = card:FindFirstChild(name) :: GuiObject?
			if g then
				g.Visible = isOpen -- the lock veil alone speaks for a shut class
			end
		end
		local best = rec.best[c] or 0
		local slot = card:FindFirstChild("Slot") :: Frame?
		local cup = slot and slot:FindFirstChild("Cup") :: ImageLabel?
		if slot and cup then
			if cup:IsA("ImageLabel") then
				cup.Image = UiSkin.artFor(trophyArt(best)) or cup.Image
				cup.ImageColor3 = if best > 0 then WHITE else Color3.fromRGB(70, 84, 128)
				cup.ImageTransparency = if best > 0 then 0 else 0.35
			end
			local ring = slot:FindFirstChildOfClass("UIStroke")
			if ring then
				ring.Color = if best > 0 then TROPHY_COLOR[best] else DIM
			end
		end
		local trophyLine = card:FindFirstChild("Trophy") :: TextLabel?
		if trophyLine then
			trophyLine.Text = if best > 0 then GrandPrixRules.TROPHY[best] .. " TROPHY" else "NO TROPHY YET"
			trophyLine.TextColor3 = if best > 0 then TROPHY_COLOR[best] else SOFT
		end
		local pts = card:FindFirstChild("Points") :: TextLabel?
		if pts then
			local p = rec.points[c] or 0
			pts.Text = if p > 0 then string.format("BEST %d PTS", p) else ""
		end
	end
	local multi = #lengths > 1
	for len, tab in lengthTabs do
		tab.Visible = multi
		UiSkin.setTab(tab, len == pickLength)
	end
	local fullTab = lengthTabs.full
	if fullTab then
		UiSkin.setText(fullTab, string.format("ALL %d", #open))
	end
	local thumbs = pickerThumbs
	if thumbs then
		for _, ch in thumbs:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local w = math.clamp(math.floor((816 - 290 - 10 * (#open - 1)) / math.max(1, #open)), 72, 130)
		for n, id in open do
			thumb(thumbs, id, n, pickLength == "short", w)
		end
	end
	if pickerCupLine then
		pickerCupLine.Text = if pickLength == "short" and multi then "3 OF THESE, DRAWN AT RANDOM" else string.format("THE CUP  ·  %d RACES", #open)
	end
	local can = #open >= GrandPrixRules.MIN_TRACKS
	local solo = #Players:GetPlayers() <= 1
	if pickerInfo then
		pickerInfo.Text = if not can
			then string.format("Open %d race tracks to enter (%d open)", GrandPrixRules.MIN_TRACKS, #open)
			elseif not solo then "Solo for now: other racers are on this server"
			else ""
	end
	if pickerStart then
		UiSkin.setEnabled(pickerStart, can and solo)
	end
end

local function buildPicker(): Frame
	local W, H = 860, 590
	local back, panel = layer("GPPicker", W, H, 0.45)
	local band = UiSkin.header(panel, "GRAND PRIX", { name = "Title", size = UDim2.fromOffset(330, 58), position = UDim2.fromOffset(22, -18), zIndex = 4, S = 1 })
	band.Rotation = -2
	UiSkin.icon(band, "icon_trophy", "", { size = UDim2.fromOffset(50, 50), position = UDim2.new(1, -8, 0.5, 0), anchor = Vector2.new(1, 0.5), zIndex = 6 })
	local close = UiSkin.button(panel, "danger", "", { name = "Close", size = UDim2.fromOffset(74, 74), position = UDim2.new(1, -14, 0, 8), anchor = Vector2.new(1, 0), glyph = "close", zIndex = 4, sound = "back", S = 1 })
	local cl = close:FindFirstChild("Label") :: GuiObject?
	if cl then
		cl.Visible = false
	end
	close.Activated:Connect(function()
		UiMotion.hide(back, "popOut", function()
			setPanelUp()
		end)
	end)
	UiSkin.body(panel, "Race the cup back to back. Points every race, a trophy for the top three.", {
		size = UDim2.new(1, -140, 0, 26), position = UDim2.fromOffset(28, 54), align = "left", textSize = 19, zIndex = 3,
	})
	-- class cards
	local row = Instance.new("Frame")
	row.Name = "Classes"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -44, 0, 282)
	row.Position = UDim2.fromOffset(22, 92)
	row.ZIndex = 3
	row.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 16)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row
	for i, c in GrandPrixRules.CLASSES do
		local card = UiSkin.button(row, "card", "", { name = "Class_" .. c, variant = "card", size = UDim2.new(1 / 3, -11, 1, -8), layoutOrder = i, zIndex = 4, sound = "select", S = 1 })
		local lab = card:FindFirstChild("Label") :: GuiObject?
		if lab then
			lab.Visible = false
		end
		local sc = Instance.new("UIScale")
		sc.Parent = card
		local sel = Instance.new("UIStroke")
		sel.Name = "SelStroke"
		sel.Color = GOLD
		sel.Thickness = 5
		sel.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		sel.Enabled = false
		sel.Parent = card
		UiSkin.title(card, GrandPrixRules.LABEL[c], { name = "Name", size = UDim2.new(1, -16, 0, 44), position = UDim2.fromOffset(8, 8), maxText = 40, zIndex = 6 })
		for s = 1, 3 do
			UiSkin.icon(card, "icon_star", "*", {
				name = "Star" .. s,
				size = UDim2.fromOffset(30, 30),
				position = UDim2.new(0.5, (s - 2) * 34, 0, 54),
				anchor = Vector2.new(0.5, 0),
				zIndex = 6,
				color = if s <= i then WHITE else Color3.fromRGB(40, 50, 90),
				tintArt = true,
			})
		end
		-- the trophy slot: an empty dark cup until won, then bronze / silver / gold
		local slot = Instance.new("Frame")
		slot.Name = "Slot"
		slot.BackgroundColor3 = Color3.fromRGB(14, 26, 66)
		slot.BackgroundTransparency = 0.2
		slot.Size = UDim2.fromOffset(84, 84)
		slot.Position = UDim2.new(0.5, 0, 0, 92)
		slot.AnchorPoint = Vector2.new(0.5, 0)
		slot.ZIndex = 5
		slot.Parent = card
		local sco = Instance.new("UICorner")
		sco.CornerRadius = UDim.new(1, 0)
		sco.Parent = slot
		local ring = Instance.new("UIStroke")
		ring.Thickness = 3
		ring.Color = DIM
		ring.Parent = slot
		UiSkin.icon(slot, "icon_trophy", "", { name = "Cup", size = UDim2.fromScale(0.78, 0.78), position = UDim2.fromScale(0.5, 0.5), anchor = Vector2.new(0.5, 0.5), zIndex = 6 })
		UiSkin.text(card, "", "button", { name = "Trophy", size = UDim2.new(1, -12, 0, 24), position = UDim2.fromOffset(6, 180), maxText = 22, zIndex = 6 })
		UiSkin.numeral(card, "", { name = "Points", size = UDim2.new(1, -12, 0, 22), position = UDim2.fromOffset(6, 205), maxText = 20, zIndex = 6 })
		UiSkin.body(card, GrandPrixRules.DESC[c], { name = "Desc", size = UDim2.new(1, -18, 0, 36), position = UDim2.new(0, 9, 1, -40), textSize = 17, wrap = true, zIndex = 6, color = SOFT })
		local lock = UiSkin.panel(card, "inset", { name = "Lock", variant = "inset", size = UDim2.new(1, -8, 1, -58), position = UDim2.new(0.5, 0, 1, -4), anchor = Vector2.new(0.5, 1), zIndex = 8, S = 1 })
		lock.BackgroundTransparency = 0.04
		UiSkin.icon(lock, "icon_lock", "", { size = UDim2.fromOffset(62, 62), position = UDim2.fromScale(0.5, 0.3), anchor = Vector2.new(0.5, 0.5), zIndex = 9 })
		UiSkin.text(lock, "LOCKED", "button", { size = UDim2.new(1, -16, 0, 26), position = UDim2.fromScale(0.5, 0.52), anchor = Vector2.new(0.5, 0), maxText = 22, zIndex = 9, color = SOFT })
		UiSkin.body(lock, GrandPrixRules.lockLine(c), { size = UDim2.new(1, -20, 0, 48), position = UDim2.fromScale(0.5, 0.68), anchor = Vector2.new(0.5, 0), wrap = true, textSize = 19, zIndex = 9, color = GOLD })
		card.Activated:Connect(function()
			if GrandPrixRules.classOpen(record(), c) then
				pickClass = c
				paintPicker()
			else
				NotifyKit.toast(GrandPrixRules.LABEL[c] .. ": " .. GrandPrixRules.lockLine(c))
			end
		end)
		pickerCards[c] = card
	end
	-- the cup: course thumbnails in order, and the length
	local cupWell = UiSkin.inset(panel, { name = "Cup", size = UDim2.new(1, -44, 0, 112), position = UDim2.fromOffset(22, 380), zIndex = 3, S = 1 })
	pickerCupLine = UiSkin.text(cupWell, "", "caption", { name = "CupLine", size = UDim2.new(0, 360, 0, 18), position = UDim2.fromOffset(14, 4), align = "left", textSize = 14, zIndex = 5, color = GOLD })
	local thumbs = Instance.new("Frame")
	thumbs.Name = "Thumbs"
	thumbs.BackgroundTransparency = 1
	thumbs.Size = UDim2.new(1, -290, 0, 96)
	thumbs.Position = UDim2.fromOffset(18, 22)
	thumbs.ZIndex = 5
	thumbs.Parent = cupWell
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.Padding = UDim.new(0, 10)
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Parent = thumbs
	pickerThumbs = thumbs
	for i, len in { "short", "full" } do
		local tab = UiSkin.tab(cupWell, if len == "short" then "3 RACES" else "ALL", len == pickLength, {
			name = "Len_" .. len, size = UDim2.fromOffset(124, 74), position = UDim2.new(1, -10 - (2 - i) * 132, 0.5, 0), anchor = Vector2.new(1, 0.5), zIndex = 5, S = 1,
		})
		tab.Activated:Connect(function()
			pickLength = len
			paintPicker()
		end)
		lengthTabs[len] = tab
	end
	pickerInfo = UiSkin.text(panel, "", "caption", { name = "Info", size = UDim2.new(1, -320, 0, 26), position = UDim2.new(0, 28, 1, -44), align = "left", textSize = 17, zIndex = 3, color = GOLD })
	local start = UiSkin.button(panel, "go", "START", { name = "Start", size = UDim2.fromOffset(250, 76), position = UDim2.new(1, -22, 1, -10), anchor = Vector2.new(1, 1), glyph = "flag", zIndex = 4, sound = false, maxText = 42, S = 1.2 })
	start.Activated:Connect(function()
		if not start.Active then
			return
		end
		sfx("ui_big_confirm", 0.5)
		fire("Start", pickClass, pickLength)
		UiMotion.hide(back, "popOut", function()
			setPanelUp()
		end, { silent = true })
		if trackFlow and type(trackFlow.closeBoard) == "function" then
			trackFlow.closeBoard()
		end
	end)
	pickerStart = start
	return back
end

function GrandPrixClient.openPicker()
	local p = pickerRoot or buildPicker()
	pickerRoot = p
	paintPicker()
	UiMotion.show(p, "popIn")
	focusPrimary(p, "Start")
end

----------------------------------------------------------------------------------------------------------------- board row

local function addBoardRow(parent: Instance, order: number)
	local row = UiSkin.panel(parent, "card", { name = "GrandPrix", variant = "card", size = UDim2.fromScale(1, 1), layoutOrder = order, zIndex = 33, S = 1 })
	row.BackgroundTransparency = 0.1
	local function fit()
		local h = row.AbsoluteSize.Y
		local w = row.AbsoluteSize.X
		if h <= 0 then
			return
		end
		local ic = row:FindFirstChild("Trophy") :: GuiObject?
		if ic then
			ic.Size = UDim2.fromOffset(h * 0.8, h * 0.8)
			ic.Position = UDim2.new(0, h * 0.25, 0.5, 0)
		end
		local t = row:FindFirstChild("Title") :: GuiObject?
		if t then
			t.Position = UDim2.new(0, h * 1.2, 0, 0)
			t.Size = UDim2.new(0, math.min(w * 0.26, h * 4.2), 1, 0)
		end
		local chips = row:FindFirstChild("Chips") :: GuiObject?
		if chips then
			chips.Position = UDim2.new(0, h * 1.3 + math.min(w * 0.26, h * 4.2), 0.5, 0)
			-- never under the GRAND PRIX button: the room between the title and the button
			local room = w - (h * 1.3 + math.min(w * 0.26, h * 4.2)) - math.clamp(w * 0.2, 110, 260) - 24
			chips.Size = UDim2.new(0, math.max(60, math.min(w * 0.5, h * 9.5, room)), 0.78, 0)
		end
		local b = row:FindFirstChild("Open") :: GuiObject?
		if b then
			b.Size = UDim2.new(0, math.clamp(w * 0.2, 110, 260), 0.84, 0)
		end
	end
	UiSkin.icon(row, "icon_trophy", "", { name = "Trophy", anchor = Vector2.new(0, 0.5), zIndex = 35 })
	UiSkin.title(row, "GRAND PRIX", { name = "Title", align = "left", maxText = 30, zIndex = 35 })
	local chips = Instance.new("Frame")
	chips.Name = "Chips"
	chips.BackgroundTransparency = 1
	chips.AnchorPoint = Vector2.new(0, 0.5)
	chips.ZIndex = 35
	chips.Parent = row
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.Padding = UDim.new(0, 8)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.VerticalAlignment = Enum.VerticalAlignment.Center
	cl.Parent = chips
	local rec = record()
	for i, c in GrandPrixRules.CLASSES do
		local best = rec.best[c] or 0
		local open = GrandPrixRules.classOpen(rec, c)
		local chip = UiSkin.panel(chips, "chip", { name = "C_" .. c, variant = "inset", size = UDim2.new(1 / 3, -6, 1, 0), layoutOrder = i, zIndex = 36, S = 1 })
		chip.BackgroundTransparency = 0.25
		local iconName = if best > 0 then MEDAL_ICON[best] elseif open then "icon_star" else "icon_lock"
		local ic = UiSkin.icon(chip, iconName, "", { size = UDim2.fromScale(0.8, 0.8), position = UDim2.new(0, 4, 0.5, 0), anchor = Vector2.new(0, 0.5), zIndex = 37,
			color = if best == 0 and open then Color3.fromRGB(80, 95, 140) else nil, tintArt = best == 0 and open })
		ic.SizeConstraint = Enum.SizeConstraint.RelativeYY
		-- the label right of the icon, as large as the chip allows (uifix: right-aligned 18 px caps read tiny)
		local l = UiSkin.text(chip, GrandPrixRules.LABEL[c], "button", { size = UDim2.new(1, 0, 0.66, 0), position = UDim2.new(0, 0, 0.5, 0), anchor = Vector2.new(0, 0.5), align = "left", maxText = 30, minText = 12, zIndex = 37,
			color = if best > 0 then TROPHY_COLOR[best] elseif open then WHITE else Color3.fromRGB(150, 160, 190) })
		l.Name = "Label"
		local function place()
			local hh = chip.AbsoluteSize.Y
			l.Position = UDim2.new(0, math.floor(hh * 0.8 + 10), 0.5, 0)
			l.Size = UDim2.new(1, -math.floor(hh * 0.8 + 14), 0.62, 0)
		end
		chip:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		place()
	end
	local b = UiSkin.button(row, "orange", "GRAND PRIX", { name = "Open", variant = "orange", anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -8, 0.5, 0), glyph = "race", zIndex = 36, sound = "confirm", maxText = 24, S = 1 })
	b.Activated:Connect(GrandPrixClient.openPicker)
	row:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	task.defer(fit)
end

----------------------------------------------------------------------------------------------------------------- standings

local ROW_H, ROW_GAP = 40, 5

local function placeColor(place: number): Color3
	return if place >= 1 and place <= 3 then UiSkin.color("place_" .. place) else WHITE
end

local function buildStandings(): Frame
	local back, panel = layer("GPStandings", 700, 590, 0.35)
	local band, bandText = UiSkin.header(panel, "GRAND PRIX", { name = "Title", size = UDim2.fromOffset(360, 52), position = UDim2.new(0.5, 0, 0, -18), anchor = Vector2.new(0.5, 0), zIndex = 4, S = 1 })
	band.Rotation = -2
	bandText.Name = "TitleText"
	UiSkin.text(panel, "", "caption", { name = "Sub", size = UDim2.new(1, -40, 0, 24), position = UDim2.fromOffset(20, 40), maxText = 20, zIndex = 3, color = GOLD })
	-- column heads
	local heads = Instance.new("Frame")
	heads.Name = "Heads"
	heads.BackgroundTransparency = 1
	heads.Size = UDim2.new(1, -40, 0, 20)
	heads.Position = UDim2.fromOffset(20, 68)
	heads.ZIndex = 3
	heads.Parent = panel
	UiSkin.text(heads, "RACE", "caption", { size = UDim2.new(0, 84, 1, 0), position = UDim2.new(1, -176, 0, 0), maxText = 20, zIndex = 3, color = Color3.fromRGB(190, 205, 240) })
	UiSkin.text(heads, "TOTAL", "caption", { size = UDim2.new(0, 70, 1, 0), position = UDim2.new(1, -70, 0, 0), maxText = 20, zIndex = 3, color = Color3.fromRGB(190, 205, 240) })
	local well = UiSkin.inset(panel, { name = "Rows", size = UDim2.new(1, -40, 0, 8 * (ROW_H + ROW_GAP) + 10), position = UDim2.fromOffset(20, 90), zIndex = 3, S = 1 })
	well.ClipsDescendants = false
	UiSkin.text(panel, "", "caption", { name = "Count", size = UDim2.new(1, -300, 0, 26), position = UDim2.new(0, 22, 1, -60), align = "left", maxText = 20, zIndex = 3, color = Color3.fromRGB(205, 215, 240) })
	local nextBtn = UiSkin.button(panel, "go", "NEXT RACE", { name = "Next", size = UDim2.fromOffset(220, 76), position = UDim2.new(1, -20, 1, -10), anchor = Vector2.new(1, 1), glyph = "flag", zIndex = 4, sound = "confirm", maxText = 30, S = 1.1 })
	local quitBtn = UiSkin.button(panel, "danger", "QUIT", { name = "Quit", size = UDim2.fromOffset(130, 76), position = UDim2.new(1, -252, 1, -10), anchor = Vector2.new(1, 1), zIndex = 4, sound = "back", maxText = 26, S = 1.1 })
	local armedAt = -math.huge
	quitBtn.Activated:Connect(function()
		local now = os.clock()
		if now - armedAt > 3 then
			armedAt = now
			UiSkin.setText(quitBtn, "SURE?")
			task.delay(3, function()
				if os.clock() - armedAt >= 3 then
					UiSkin.setText(quitBtn, "QUIT")
				end
			end)
			return
		end
		fire("Quit")
		hideLayer(back)
	end)
	nextBtn.Activated:Connect(function()
		local data = lastStandings
		if data and data.final then
			GrandPrixClient.trophyMoment()
		else
			fire("Continue")
			GrandPrixClient.showNext()
		end
	end)
	return back
end

local function rowFor(well: Frame, r: any, i: number): Frame
	local f = UiSkin.panel(well, if r.me then "header" else "card", {
		name = "Row" .. i,
		variant = if r.me then "header" else "card",
		size = UDim2.new(1, -12, 0, ROW_H),
		zIndex = 5,
		S = 0.7,
	})
	local ink = if r.me then INK else WHITE
	local stroke = if r.me then 0 else nil
	local rankL = UiSkin.numeral(f, tostring(r.rank), { name = "Rank", size = UDim2.new(0, 44, 1, -4), position = UDim2.fromOffset(6, 2), maxText = 28, zIndex = 7,
		color = if r.me then INK else placeColor(r.rank), stroke = stroke })
	rankL.Name = "Rank"
	UiSkin.text(f, tostring(r.name), "button", { name = "Name", size = UDim2.new(1, -220, 1, -10), position = UDim2.fromOffset(56, 5), align = "left", maxText = 22, zIndex = 7, color = ink, stroke = stroke })
	local gainedText = if r.place == 0 then "" elseif r.gained > 0 then "+" .. r.gained elseif r.dnf then "DNF" else "+0"
	if gainedText ~= "" then
		-- the points this race as a pill: gold on the field's rows, green on the player's gold row, red for a DNF
		local variant = if r.dnf then "danger" elseif r.gained <= 0 then "inset" elseif r.me then "go" else "header"
		local chip = UiSkin.panel(f, "chip", { name = "GainChip", variant = variant, size = UDim2.new(0, 76, 1, -8), position = UDim2.new(1, -138, 0.5, 0), anchor = Vector2.new(0.5, 0.5), zIndex = 7, S = 0.7 })
		local dark = variant == "header"
		UiSkin.text(chip, gainedText, "numeral", { name = "Gained", size = UDim2.new(1, -8, 1, -4), position = UDim2.fromScale(0.5, 0.5), anchor = Vector2.new(0.5, 0.5), maxText = 26, zIndex = 8,
			color = if dark then INK else WHITE, stroke = if dark then 0 else nil })
		local csc = Instance.new("UIScale")
		csc.Parent = chip
		local flash = Instance.new("Frame")
		flash.Name = "Flash"
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = WHITE
		flash.BackgroundTransparency = 1
		flash.ZIndex = 9
		flash.Parent = chip
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(1, 0)
		fc.Parent = flash
	end
	if r.me then
		local glow = Instance.new("UIStroke")
		glow.Name = "MeGlow"
		glow.Color = WHITE
		glow.Thickness = 3
		glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		glow.Parent = f
		local msc = Instance.new("UIScale")
		msc.Scale = 1.03
		msc.Parent = f
	end
	UiSkin.numeral(f, tostring(r.total - r.gained), { name = "Total", size = UDim2.new(0, 70, 1, -6), position = UDim2.new(1, -74, 0, 3), maxText = 28, zIndex = 7,
		color = if r.me then INK else WHITE, stroke = stroke })
	f.Parent = well
	return f
end

local function rowPos(rank: number): UDim2
	return UDim2.fromOffset(6, 6 + (rank - 1) * (ROW_H + ROW_GAP))
end

function GrandPrixClient.showStandings(data: any)
	local root = standRoot or buildStandings()
	standRoot = root
	hideLayer(nextRoot)
	hideLayer(trophyRoot)
	local panel = root:FindFirstChild("Panel") :: Frame
	local band = panel:FindFirstChild("Title") :: Frame
	local title = band:FindFirstChild("TitleText", true) :: TextLabel
	title.Text = if data.final then "FINAL STANDINGS" else "GRAND PRIX"
	local sub = panel:FindFirstChild("Sub") :: TextLabel
	sub.Text = string.format("%s CUP  ·  RACE %d/%d  ·  %s", GrandPrixRules.LABEL[data.class] or "", data.race, data.races, string.upper(trackName(data.trackId)))
	local well = panel:FindFirstChild("Rows") :: Frame
	for _, c in well:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local nextBtn = panel:FindFirstChild("Next") :: GuiButton
	local quitBtn = panel:FindFirstChild("Quit") :: GuiButton
	UiSkin.setText(nextBtn, if data.final then "CONTINUE" else "NEXT RACE")
	quitBtn.Visible = not data.final
	UiSkin.setText(quitBtn, "QUIT")
	local rows: { any } = if type(data.rows) == "table" then data.rows else {}
	local frames: { [number]: Frame } = {}
	for i, r in rows do
		local f = rowFor(well, r, i)
		local start = if type(r.prevRank) == "number" and r.prevRank > 0 then r.prevRank else r.rank
		f.Position = rowPos(start)
		frames[i] = f
	end
	root.Visible = true
	setPanelUp()
	UiMotion.show(root, "popIn") -- the backdrop: the panel's UIScale is its screen fit
	focusPrimary(root, "Next")
	if data.final then
		sfx("gp_fanfare", 0.5)
	end
	local my = standingsSeq
	-- the move: rows slide to their new places while the totals count up (0.5 s in, 0.7 s long)
	task.delay(0.6, function()
		if my ~= standingsSeq or not root.Visible then
			return
		end
		for i, r in rows do
			local f = frames[i]
			if f and f.Parent then
				TweenService:Create(f, TweenInfo.new(0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), { Position = rowPos(r.rank) }):Play()
				local total = f:FindFirstChild("Total") :: TextLabel?
				local gained = r.gained or 0
				local chip = f:FindFirstChild("GainChip")
				if chip and gained > 0 then
					local csc = chip:FindFirstChildOfClass("UIScale")
					local flash = chip:FindFirstChild("Flash") :: Frame?
					task.delay(0.05 * r.rank, function()
						if csc then
							csc.Scale = 1.45
							TweenService:Create(csc, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
						end
						if flash then
							flash.BackgroundTransparency = 0.15
							TweenService:Create(flash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
						end
					end)
				end
				if total and gained > 0 then
					task.spawn(function()
						local from = r.total - gained
						local t0 = os.clock()
						local lastTick = -1
						while os.clock() - t0 < 0.7 do
							local n = math.floor((os.clock() - t0) / 0.14)
							if r.me and n ~= lastTick then
								lastTick = n
								sfx("tally_tick", 0.4, 1 + n * 0.06)
							end
							total.Text = tostring(math.floor(from + gained * (os.clock() - t0) / 0.7 + 0.5))
							task.wait()
						end
						total.Text = tostring(r.total)
						if r.me then
							UiMotion.bounce(total)
						end
					end)
				end
			end
		end
		UiSound.play("vote", nil, 0.7)
	end)
end

----------------------------------------------------------------------------------------------------------------- next card

local function buildNext(): Frame
	local back, panel = layer("GPNext", 560, 330, 0.2)
	local band, bandText = UiSkin.header(panel, "NEXT RACE", { name = "Title", size = UDim2.fromOffset(300, 52), position = UDim2.new(0.5, 0, 0, -18), anchor = Vector2.new(0.5, 0), zIndex = 4, S = 1 })
	band.Rotation = -2
	bandText.Name = "TitleText"
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.ScaleType = Enum.ScaleType.Crop
	art.Size = UDim2.new(1, -40, 0, 170)
	art.Position = UDim2.fromOffset(20, 44)
	art.ZIndex = 3
	art.Parent = panel
	local ac = Instance.new("UICorner")
	ac.CornerRadius = UDim.new(0, 12)
	ac.Parent = art
	local as = Instance.new("UIStroke")
	as.Color = INK
	as.Thickness = 3
	as.Parent = art
	UiSkin.title(panel, "", { name = "Track", size = UDim2.new(1, -40, 0, 46), position = UDim2.fromOffset(20, 220), maxText = 42, zIndex = 4 })
	UiSkin.text(panel, "", "caption", { name = "Zone", size = UDim2.new(1, -40, 0, 22), position = UDim2.fromOffset(20, 266), maxText = 18, zIndex = 4, color = GOLD })
	UiSkin.text(panel, "", "caption", { name = "Count", size = UDim2.new(1, -40, 0, 22), position = UDim2.fromOffset(20, 294), maxText = 17, zIndex = 4, color = Color3.fromRGB(205, 215, 240) })
	return back
end

function GrandPrixClient.showNext()
	local data = lastStandings
	if not data or data.final or nextShownFor == data.race then
		return
	end
	nextShownFor = data.race
	local root = nextRoot or buildNext()
	nextRoot = root
	hideLayer(standRoot)
	local panel = root:FindFirstChild("Panel") :: Frame
	local title = panel:FindFirstChild("TitleText", true) :: TextLabel
	title.Text = string.format("NEXT  ·  RACE %d/%d", data.race + 1, data.races)
	local art = panel:FindFirstChild("Art") :: ImageLabel
	art.Image = artFor(data.nextId) or ""
	local tr = panel:FindFirstChild("Track") :: TextLabel
	tr.Text = string.upper(trackName(data.nextId))
	local info = TrackInfo.get(data.nextId)
	local zone = panel:FindFirstChild("Zone") :: TextLabel
	zone.Text = if info then string.upper(info.zoneName) else ""
	root.Visible = true
	setPanelUp()
	UiMotion.show(panel, "swooshIn", { side = "right", home = UDim2.fromScale(0.5, 0.5) })
end

----------------------------------------------------------------------------------------------------------------- trophy

local function buildTrophy(): Frame
	local back, panel = layer("GPTrophy", 520, 470, 0.3)
	local band, bandText = UiSkin.header(panel, "GRAND PRIX", { name = "Title", size = UDim2.fromOffset(320, 52), position = UDim2.new(0.5, 0, 0, -18), anchor = Vector2.new(0.5, 0), zIndex = 4, S = 1 })
	band.Rotation = -2
	bandText.Name = "TitleText"
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.Size = UDim2.fromOffset(190, 190)
	glow.Position = UDim2.new(0.5, 0, 0, 140)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.BackgroundColor3 = GOLD
	glow.BackgroundTransparency = 0.75
	glow.ZIndex = 3
	glow.Parent = panel
	local gc = Instance.new("UICorner")
	gc.CornerRadius = UDim.new(1, 0)
	gc.Parent = glow
	UiSkin.text(panel, "", "title", { name = "Place", size = UDim2.new(1, -40, 0, 50), position = UDim2.fromOffset(20, 246), maxText = 46, zIndex = 4 })
	UiSkin.text(panel, "", "caption", { name = "Line", size = UDim2.new(1, -40, 0, 24), position = UDim2.fromOffset(20, 298), maxText = 20, zIndex = 4, color = WHITE })
	local chips = Instance.new("Frame")
	chips.Name = "Chips"
	chips.BackgroundTransparency = 1
	chips.Size = UDim2.new(1, -40, 0, 36)
	chips.Position = UDim2.fromOffset(20, 330)
	chips.ZIndex = 4
	chips.Parent = panel
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cl.Padding = UDim.new(0, 10)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.Parent = chips
	local home = UiSkin.button(panel, "go", "BACK TO HUB", { name = "Home", size = UDim2.fromOffset(240, 56), position = UDim2.new(0.5, 0, 1, -16), anchor = Vector2.new(0.5, 1), glyph = "back", zIndex = 4, sound = "confirm", maxText = 30, S = 1.1 })
	home.Activated:Connect(function()
		fire("Continue")
		hideLayer(back)
	end)
	return back
end

local function celebrate(trophy: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local ok, Fx = pcall(function(): any
		return require(script.Parent:WaitForChild("CelebrationFx"))
	end)
	if not ok or type(Fx) ~= "table" or type(Fx.shell) ~= "function" then
		return
	end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis
	local right = flat:Cross(Vector3.yAxis)
	local tint = TROPHY_COLOR[trophy] or GOLD
	local n = if trophy == 3 then 6 else 4
	for i = 1, n do
		local side = (i % 2 == 0) and 1 or -1
		local base = cam.CFrame.Position + flat * (70 + (i % 3) * 18) + right * side * (24 + i * 6) - Vector3.new(0, 20, 0)
		pcall(Fx.shell, base, 34 + (i % 3) * 8, if i % 2 == 0 then tint else WHITE, (i - 1) * 0.22)
	end
end

function GrandPrixClient.trophyMoment()
	local data = lastStandings
	if not data or not data.final or trophyPlayed then
		return
	end
	trophyPlayed = true
	hideLayer(standRoot)
	local result = if type(data.result) == "table" then data.result else {}
	local seq = standingsSeq
	task.spawn(function()
		-- the cup's top three on the podium (the same ceremony as a race; the cars are still on the track)
		local okP, Podium = pcall(function(): any
			return require(script.Parent:WaitForChild("PodiumCeremony"))
		end)
		if okP and type(Podium) == "table" then
			local st = {}
			for _, r in (data.rows or {}) :: { any } do
				table.insert(st, { rank = r.rank, name = if r.me then LocalPlayer.Name else r.name, isPlayer = r.me == true })
			end
			pcall(Podium.play, {
				standings = st,
				trackId = data.trackId,
				title = string.format("%s CUP", GrandPrixRules.LABEL[data.class] or ""),
				gears = if type(result.cash) == "number" and result.cash > 0 then { gears = result.cash } else nil,
			}, function(): boolean
				return seq == standingsSeq and workspace:GetAttribute("GPActive") == true
			end)
		end
		if seq ~= standingsSeq then
			return
		end
		local root = trophyRoot or buildTrophy()
		trophyRoot = root
		local panel = root:FindFirstChild("Panel") :: Frame
		local trophy = tonumber(result.trophy) or 0
		local title = panel:FindFirstChild("TitleText", true) :: TextLabel
		title.Text = string.format("%s CUP", GrandPrixRules.LABEL[data.class] or "")
		for _, c in panel:GetChildren() do
			if c.Name == "Cup" then
				c:Destroy()
			end
		end
		local icon = UiSkin.icon(panel, if trophy > 0 then trophyArt(trophy) else "icon_flag", "", {
			name = "Cup", size = UDim2.fromOffset(170, 170), position = UDim2.new(0.5, 0, 0, 140), anchor = Vector2.new(0.5, 0.5), zIndex = 5,
		})
		local glow = panel:FindFirstChild("Glow") :: Frame
		glow.BackgroundColor3 = TROPHY_COLOR[trophy] or Color3.fromRGB(90, 110, 170)
		glow.Visible = trophy > 0
		local place = panel:FindFirstChild("Place") :: TextLabel
		local rank = tonumber(result.rank) or 0
		place.Text = if trophy > 0 then GrandPrixRules.TROPHY[trophy] .. " TROPHY" else string.format("CUP COMPLETE  ·  %dTH", rank)
		place.TextColor3 = TROPHY_COLOR[trophy] or WHITE
		local line = panel:FindFirstChild("Line") :: TextLabel
		line.Text = string.format("%d POINTS  ·  %d RACES%s", tonumber(result.points) or 0, data.races, if result.newBest then "  ·  NEW BEST" else "")
		local chips = panel:FindFirstChild("Chips") :: Frame
		for _, c in chips:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if type(result.cash) == "number" and result.cash > 0 and workspace:GetAttribute("GarageEnabled") == true then
			UiSkin.chip(chips, string.format("+%d CASH", result.cash), "cash", { size = UDim2.fromOffset(150, 36), layoutOrder = 1, zIndex = 5, S = 1 })
		end
		for i, c in (if type(result.opened) == "table" then result.opened else {}) :: { any } do
			UiSkin.chip(chips, string.format("%s UNLOCKED", GrandPrixRules.LABEL[c] or tostring(c)), "star", { size = UDim2.fromOffset(190, 36), layoutOrder = 1 + i, zIndex = 5, S = 1 })
		end
		root.Visible = true
		setPanelUp()
		UiMotion.show(root, "popIn") -- the backdrop: the panel's UIScale is its screen fit
		focusPrimary(root, "Home")
		local sc = Instance.new("UIScale")
		sc.Scale = 0.2
		sc.Parent = icon
		TweenService:Create(sc, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		if trophy > 0 then
			PayoffSound.play("confetti_pop", 1, 1)
			sfx("trophy_sting", 0.55)
			celebrate(trophy)
			task.spawn(function()
				while root.Visible and icon.Parent do
					TweenService:Create(icon, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Rotation = 6 }):Play()
					task.wait(1.2)
					if not icon.Parent then
						break
					end
					TweenService:Create(icon, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Rotation = -6 }):Play()
					task.wait(1.2)
				end
			end)
		end
	end)
end

----------------------------------------------------------------------------------------------------------------- grid chip

local function buildGridChip(): Frame
	local f, l = UiSkin.chip(gui, "", "trophy", { name = "GPGridChip", size = UDim2.fromOffset(340, 40), position = UDim2.new(0.5, 0, 0, 64), anchor = Vector2.new(0.5, 0), zIndex = 5, S = 1 })
	l.Name = "Label"
	f.Visible = false
	return f
end

----------------------------------------------------------------------------------------------------------------- flow

local function onStandings(data: any)
	if type(data) ~= "table" then
		return
	end
	standingsSeq += 1
	lastStandings = data
	trophyPlayed = false
	local my = standingsSeq
	-- After the race's own finish sequence (photo cam, podium, a look at the results card), then the cup's panel.
	task.spawn(function()
		local t0 = os.clock()
		local cardSince: number? = nil
		while my == standingsSeq and os.clock() - t0 < 14 do
			local ph = HudPhase.phase()
			if ph == "finish" or ph == "podium" then
				cardSince = nil
			else
				cardSince = cardSince or os.clock()
				if os.clock() - (cardSince :: number) >= 2.5 then
					break
				end
			end
			task.wait(0.1)
		end
		if my ~= standingsSeq or workspace:GetAttribute("GPActive") ~= true then
			return
		end
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local card = pg and pg:FindFirstChild("FinishPositionScreen", true)
		if card and card:IsA("GuiObject") then
			card.Visible = false
		end
		GrandPrixClient.showStandings(data)
		if data.final then
			-- the trophy moment on its own if the player does not press CONTINUE
			task.delay(9, function()
				if my == standingsSeq and not trophyPlayed then
					GrandPrixClient.trophyMoment()
				end
			end)
		end
	end)
end

local function hideAll()
	for _, f in { standRoot, nextRoot, trophyRoot } do
		if f then
			f.Visible = false
		end
	end
	setPanelUp()
end

local function step()
	local now = workspace:GetServerTimeNow()
	local active = workspace:GetAttribute("GPActive") == true
	local data = lastStandings
	-- NEXT card before the move (and its countdown)
	local nextAt = workspace:GetAttribute("GPNextAt")
	if active and data and not data.final and type(nextAt) == "number" and workspace:GetAttribute("GPRace") == data.race then
		local left = nextAt - now
		if left <= GrandPrixRules.NEXT_CARD + 0.3 and left > -2 then
			GrandPrixClient.showNext()
		end
		local root = nextRoot
		if root and root.Visible then
			local c = (root:FindFirstChild("Panel") :: Frame):FindFirstChild("Count") :: TextLabel
			c.Text = string.format("Starting in %d", math.max(0, math.ceil(left)))
		end
		local sr = standRoot
		if sr and sr.Visible then
			local c = (sr:FindFirstChild("Panel") :: Frame):FindFirstChild("Count") :: TextLabel
			c.Text = string.format("Next race in %d", math.max(0, math.ceil(left)))
		end
	elseif active and data and data.final and type(nextAt) == "number" then
		local sr = standRoot
		if sr and sr.Visible then
			local c = (sr:FindFirstChild("Panel") :: Frame):FindFirstChild("Count") :: TextLabel
			c.Text = string.format("BACK TO HUB IN %d", math.max(0, math.ceil(nextAt - now)))
		end
	end
	-- a track switch (the curtain) or the cup's end clears every panel
	if qaMode then
		return
	end
	if workspace:GetAttribute("TrackSwitching") == true or (not active and (standRoot and standRoot.Visible or nextRoot and nextRoot.Visible)) then
		if not (trophyRoot and trophyRoot.Visible and workspace:GetAttribute("TrackSwitching") ~= true) then
			hideAll()
		end
	end
	if RaceAttr.mine("RaceMode") == "hub" and trophyRoot and trophyRoot.Visible then
		hideAll()
	end
	-- the grid chip through the countdown
	local chip = gridChip
	if chip then
		local go = RaceAttr.mine("RaceGoTime")
		local show = active and RaceAttr.mine("RaceMode") == "race" and type(go) == "number" and now < go + 3 and workspace:GetAttribute("TrackSwitching") ~= true
		if show then
			local l = chip:FindFirstChild("Label") :: TextLabel
			l.Text = string.format("GRAND PRIX  ·  RACE %d/%d  ·  %s", tonumber(workspace:GetAttribute("GPRace")) or 1, tonumber(workspace:GetAttribute("GPRaces")) or 1,
				GrandPrixRules.LABEL[tostring(workspace:GetAttribute("GPClass"))] or "")
		end
		if chip.Visible ~= show then
			if show and workspace:GetAttribute("GPRace") == 1 then
				sfx("gp_fanfare", 0.45)
			end
			chip.Visible = show
		end
	end
end

function GrandPrixClient.init(tf: any)
	trackFlow = tf
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyGrandPrix"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 32 -- over NotifyKit (31): a tip or daily popup never sits on the picker or the cup panels
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = sg
	-- Studio-only capture hook (the running module: an execute_luau require() is a fresh copy without this gui):
	-- set QAData (JSON payload) then QAShow ("picker" / "standings" / "next" / "trophy") on SkyRallyGrandPrix.
	if RunService:IsStudio() then
		sg:GetAttributeChangedSignal("QAShow"):Connect(function()
			local k = sg:GetAttribute("QAShow")
			if type(k) == "string" and k ~= "" then
				local ok, data = pcall(function(): any
					return HttpService:JSONDecode(tostring(sg:GetAttribute("QAData") or "{}"))
				end)
				GrandPrixClient.qaShow(k, if ok then data else {})
			end
		end)
	end
	gridChip = buildGridChip()
	if tf and type(tf.addBoardRow) == "function" then
		tf.addBoardRow(addBoardRow)
	end
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 60)
		local r = if folder then folder:WaitForChild("GrandPrixRemote", 60) else nil
		if r and r:IsA("RemoteEvent") then
			remote = r
			r.OnClientEvent:Connect(function(kind: any, data: any)
				if kind == "Standings" then
					onStandings(data)
				elseif kind == "Refused" and type(data) == "table" and type(data.why) == "string" then
					NotifyKit.toast(data.why)
				end
			end)
		end
	end)
	LocalPlayer:GetAttributeChangedSignal("GPTrophies"):Connect(function()
		local p = pickerRoot
		if p and p.Visible then
			paintPicker()
		end
	end)
	workspace:GetAttributeChangedSignal("GPActive"):Connect(function()
		if workspace:GetAttribute("GPActive") == true then
			nextShownFor = 0
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		step()
	end)
end

return GrandPrixClient
