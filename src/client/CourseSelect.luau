--!strict
-- UI v2 course select (docs/design/UI_V2.md "Course select"): the Adventure board as a row of big zone cards (track
-- capture art, slanted zone band, progress pips, a lock overlay with one requirement line), the selected zone's modes as
-- icon tiles, and one big GO. Presentation only: client/TrackFlow owns the data (PortalStates, CompletionInfo), the
-- remotes and the open / close motion, and passes a model to CourseSelect.refresh.
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CourseArt = require(Shared:WaitForChild("CourseArt")) :: { [string]: string? }
local PayoffImages = require(Shared:WaitForChild("PayoffImages")) :: { [string]: string? }
local UiSkin = require(script.Parent:WaitForChild("UiSkin"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local CourseSelect = {}

export type Mode = { mode: string, open: boolean, why: string? }
export type Zone = {
	id: string,
	zone: string,
	name: string, -- "DINO RIDGE" / "FINAL BOSS"
	track: string, -- "Molten Cavern"
	vehicle: string, -- "plane" | "car"
	color: Color3,
	open: boolean,
	lockLine: string?, -- one short requirement ("1 more Sky Token")
	modes: { Mode },
	battleLine: string?, -- why battle is shut (BattleAccessRules.boardLockLine)
	key: boolean, -- the zone's hidden key found
	boss: boolean, -- the zone's boss beaten
}
export type Model = {
	tokens: number,
	tokensTotal: number,
	keys: number,
	keysTotal: number,
	boss: number,
	bossTotal: number,
	battle: number,
	battleTotal: number,
	completeText: string?,
	zones: { Zone },
	lobby: string?, -- the track id whose lobby this player is in
}
export type Deps = {
	go: (zone: Zone, mode: string) -> (), -- GO on an open mode (closes the board, fires the request)
	leave: () -> (), -- GO while in this zone's lobby
	close: () -> (),
	toast: (msg: string) -> (),
}

CourseSelect.EMBLEMS = false -- the iris art carries a white square: off until the track captures land
CourseSelect.MODE_LABEL = {
	race = "RACE",
	quickrace = "QUICK",
	boss = "BOSS",
	coin = "COINS",
	rematch = "REMATCH",
	timetrial = "TIME TRIAL",
	battle = "BATTLE",
	stormrace = "STORM",
} :: { [string]: string }
local MODE_ICON: { [string]: string } = {
	race = "race",
	quickrace = "quick",
	boss = "boss",
	coin = "coins",
	rematch = "rematch",
	timetrial = "stopwatch",
	battle = "battle",
	stormrace = "alert",
}
local MODE_DESC: { [string]: string } = {
	race = "3 laps against the full field",
	quickrace = "One short race, straight in",
	boss = "Take on the zone boss",
	coin = "Grab the coins before time runs out",
	rematch = "The boss again, with a twist",
	timetrial = "Solo run for your best time",
	battle = "Arena battle with items",
	stormrace = "Storm race",
}

local root: Frame
local deps: Deps
local topBar: Frame
local titleBand: Frame
local checker: Frame
local progress: Frame
local closeBtn: GuiButton
local cardRow: ScrollingFrame
local extras: Frame
local bottom: Frame
local zoneTitle: TextLabel
local tileRow: Frame
local infoLine: TextLabel
local goBtn: GuiButton
local statusLine: TextLabel
local preview: ImageLabel -- round 3: the selected zone's track picture, large, left of the mode tiles

local model: Model? = nil
local selectedId: string? = nil
local selectedMode: { [string]: string } = {} -- zone id -> last mode picked there
local focusMode: string? = nil -- the tile the info line describes (hover / gamepad focus)
local cards: { [string]: GuiButton } = {}
local tiles: { [string]: GuiButton } = {}
local pulse: Tween? = nil
local queueText: { [string]: string } = {}
local layout: () -> () -- defined with the layout section (select relays the tiles out)
local isSmall = false -- phone-class board (layout): short mode names, no card pips

local function zoneById(id: string?): Zone?
	local m = model
	if not m or not id then
		return nil
	end
	for _, z in m.zones do
		if z.id == id then
			return z
		end
	end
	return nil
end

local function modeOf(z: Zone, mode: string?): Mode?
	for _, md in z.modes do
		if md.mode == mode then
			return md
		end
	end
	return nil
end

local function defaultMode(z: Zone): string?
	local remembered = selectedMode[z.id]
	if remembered and modeOf(z, remembered) then
		return remembered
	end
	for _, md in z.modes do
		if md.open then
			return md.mode
		end
	end
	return if z.modes[1] then z.modes[1].mode else nil
end

-- CourseArt keys are the track ids lower-cased without the dash ("DINO-4" -> "dino4", tools/vfx/upload_set.py stems).
local function artOf(id: string): string?
	local k = string.lower((string.gsub(id, "-", "")))
	return CourseArt[k]
end

local function px(v: number): number
	return math.floor(v + 0.5)
end

---------------------------------------------------------------------------------------------------- cards

local function emblemFor(z: Zone): string?
	return PayoffImages["iris_" .. string.lower(z.zone)]
end

local function pip(parent: Instance, glyph: string, lit: boolean, order: number)
	local holder = Instance.new("Frame")
	holder.Name = "Pip_" .. glyph
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.SizeConstraint = Enum.SizeConstraint.RelativeYY
	holder.LayoutOrder = order
	holder.Parent = parent
	local g = UiSkin.glyph(holder, glyph, { size = UDim2.fromScale(1, 1), zIndex = 36 })
	if not lit then
		if g:IsA("ImageLabel") then
			g.ImageTransparency = 0.25
			g.ImageColor3 = Color3.fromRGB(70, 80, 110)
		else
			for _, d in g:GetDescendants() do
				if d:IsA("Frame") then
					d.BackgroundTransparency = 0.7
				end
			end
		end
	end
end

local function buildCard(z: Zone, order: number): GuiButton
	local b = Instance.new("TextButton")
	b.Name = "Card_" .. z.zone
	b.Text = z.name
	b.TextTransparency = 1
	b.AutoButtonColor = false
	b.LayoutOrder = order
	b.ZIndex = 33
	b.Selectable = true
	UiSkin.style(b, "card", { variant = "tab", S = 1 })
	b.BackgroundTransparency = 0.15
	b.SelectionImageObject = UiSkin.focusRing() -- round 3: the kit's yellow focus ring, not the engine's default
	-- v3 picture-led card: the track capture fills the card edge to edge; the label sits on a striped dark band along
	-- the bottom (zone name white with its last word in yellow, the track name small yellow under it); progress pips
	-- ride the art's top-right corner.
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundColor3 = z.color
	art.BorderSizePixel = 0
	art.Position = UDim2.fromOffset(2, 2)
	art.Size = UDim2.new(1, -4, 1, -4)
	art.ScaleType = Enum.ScaleType.Crop
	art.ZIndex = 34
	art.Image = artOf(z.id) or ""
	local ac = Instance.new("UICorner")
	ac.CornerRadius = UDim.new(0, 2)
	ac.Parent = art
	art.Parent = b
	-- v38-flow: never a bare colour block. Until the capture has loaded (first open on a fresh join), the card shows the
	-- zone's shaded fill with its emblem; both leave the moment the image is in.
	if artOf(z.id) and not art.IsLoaded then
		local gr = Instance.new("UIGradient")
		gr.Name = "Loading"
		gr.Rotation = 90
		gr.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(0.45, 0.45, 0.55))
		gr.Parent = art
		-- (no emblem stand-in: the iris art carries a white square; the shaded zone fill is enough for a moment)
		task.spawn(function()
			local t0 = os.clock()
			while gr.Parent and not art.IsLoaded and os.clock() - t0 < 6 do
				task.wait(0.2)
			end
			gr:Destroy()
		end)
		task.spawn(function()
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync({ art })
			end)
		end)
	end
	if not artOf(z.id) then
		local gr = Instance.new("UIGradient")
		gr.Rotation = 90
		gr.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(0.45, 0.45, 0.55))
		gr.Parent = art
		local em = if CourseSelect.EMBLEMS then emblemFor(z) else nil
		if em then
			local e = Instance.new("ImageLabel")
			e.Name = "Emblem"
			e.BackgroundTransparency = 1
			e.Image = em
			e.Size = UDim2.fromScale(0.62, 0.62)
			e.SizeConstraint = Enum.SizeConstraint.RelativeYY
			e.AnchorPoint = Vector2.new(0.5, 0.5)
			e.Position = UDim2.fromScale(0.5, 0.36)
			e.ZIndex = 35
			e.Parent = art
		end
	end
	local band = UiSkin.stripeBand(b, { size = UDim2.new(1, -4, 0.34, 0), position = UDim2.new(0, 2, 1, -2), zIndex = 41, alpha = 0.08 })
	band.Name = "Band"
	-- a thin zone-colour strip on the band's left edge: the world's accent
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.BorderSizePixel = 0
	accent.BackgroundColor3 = z.color
	accent.Size = UDim2.new(0, 5, 1, -2)
	accent.Position = UDim2.fromOffset(0, 2)
	accent.ZIndex = 42
	accent.Parent = band
	local words = string.split(z.name, " ")
	local last = table.remove(words)
	local name = if #words > 0 then table.concat(words, " ") .. ' <font color="#FFD21F">' .. tostring(last) .. "</font>" else tostring(last)
	local nm = UiSkin.title(band, name, { name = "ZoneName", zIndex = 43, maxText = 30, rich = true, align = "left", size = UDim2.new(1, -18, 0.56, 0), position = UDim2.fromOffset(12, 3) })
	nm.Name = "ZoneName"
	local tr = UiSkin.text(band, string.upper(z.track), "caption", { name = "Track", size = UDim2.new(1, -18, 0.32, 0), position = UDim2.new(0, 12, 0.6, 0), align = "left", maxText = 16, minText = 10, zIndex = 43, color = UiSkin.color("gold") })
	tr.TextTruncate = Enum.TextTruncate.AtEnd
	local pips = Instance.new("Frame")
	pips.Name = "Pips"
	pips.BackgroundTransparency = 1
	-- round 3: progress is a neat row of small pips riding the label band's top edge (right end), not a cluster over
	-- the picture; phones hide it (layout)
	pips.AnchorPoint = Vector2.new(1, 1)
	pips.Position = UDim2.new(1, -6, 0, -5)
	pips.Size = UDim2.new(0.8, 0, 0.26, 0)
	pips.ZIndex = 44
	pips.Parent = band
	local pl = Instance.new("UIListLayout")
	pl.FillDirection = Enum.FillDirection.Horizontal
	pl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	pl.Padding = UDim.new(0, 4)
	pl.SortOrder = Enum.SortOrder.LayoutOrder
	pl.VerticalAlignment = Enum.VerticalAlignment.Center
	pl.Parent = pips
	if z.zone ~= "HUB" and z.zone ~= "SPACE" then
		pip(pips, "key", z.key, 1)
	end
	if modeOf(z, "boss") then
		pip(pips, "boss", z.boss, 2)
	end
	local bm = modeOf(z, "battle")
	if bm then
		pip(pips, "battle", bm.open, 3)
	end
	-- lock overlay
	if not z.open then
		local veil = Instance.new("Frame")
		veil.Name = "Locked"
		veil.BackgroundColor3 = Color3.fromRGB(8, 14, 40)
		veil.BackgroundTransparency = 0.38
		veil.BorderSizePixel = 0
		veil.Position = art.Position
		veil.Size = art.Size
		veil.ZIndex = 39
		local vc = Instance.new("UICorner")
		vc.CornerRadius = UDim.new(0, 2)
		vc.Parent = veil
		veil.Parent = b
		UiSkin.glyph(veil, "lock", { size = UDim2.fromScale(0.36, 0.36), position = UDim2.fromScale(0.5, 0.3), anchor = Vector2.new(0.5, 0.5), zIndex = 40 })
		if z.lockLine then
			local chip = UiSkin.panel(veil, "chip", { variant = "inset", size = UDim2.new(0.92, 0, 0.3, 0), position = UDim2.new(0.5, 0, 0.7, 0), anchor = Vector2.new(0.5, 0.5), zIndex = 40, S = 1 })
			chip.BackgroundTransparency = 0.1
			UiSkin.text(chip, z.lockLine, "caption", { name = "Need", zIndex = 41, maxText = 18, minText = 12, wrap = true, size = UDim2.new(1, -8, 1, -4), position = UDim2.fromScale(0.5, 0.5), anchor = Vector2.new(0.5, 0.5), color = UiSkin.color("gold") })
		end
	end
	local sc = Instance.new("UIScale")
	sc.Parent = b
	-- No UiSound.bind: its hover squash would fight the selection scale; the card speaks on its own.
	b.MouseEnter:Connect(function()
		UiSound.play("hover")
	end)
	b.Activated:Connect(function()
		UiSound.play(if z.open then "tap" else "deny")
		local again = selectedId == z.id
		CourseSelect.select(z.id, true)
		-- v38-flow round 3: A on the already-chosen course moves a gamepad to GO (the screen's primary), MK-style
		if again and z.open and GuiService.SelectedObject == b and goBtn then
			GuiService.SelectedObject = goBtn
		end
		if not z.open and z.lockLine then
			deps.toast(z.name .. ": " .. z.lockLine)
		end
	end)
	b.SelectionGained:Connect(function()
		if selectedId ~= z.id then
			CourseSelect.select(z.id, false)
		end
	end)
	b.Parent = cardRow
	return b
end

local function paintSelection()
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
	for id, b in cards do
		local on = id == selectedId
		local st: UIStroke? = nil
		for _, ch in b:GetChildren() do
			if ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
				st = ch
			end
		end
		if st then
			st.Enabled = true
			-- v3: the focused card's edge brightens to yellow; the rest keep the pale steel edge
			st.Color = if on then UiSkin.color("gold") else Color3.fromRGB(201, 214, 234)
			st.Thickness = if on then 5 else 2
			st.Transparency = 0
			if on then
				pulse = TweenService:Create(st, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Thickness = 3.5 })
				st.LineJoinMode = Enum.LineJoinMode.Miter
				;(pulse :: Tween):Play()
			end
		end
		local sc = b:FindFirstChildOfClass("UIScale")
		if sc then
			TweenService:Create(sc, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = if on then (if isSmall then 1.06 else 1.1) else 0.93 }):Play()
		end
		b.BackgroundTransparency = if on then 0.05 else 0.3
	end
end

---------------------------------------------------------------------------------------------------- modes + GO

local function describe(z: Zone, mode: string?): string
	local md = modeOf(z, mode)
	if not md then
		return if z.open then "" else (z.lockLine or "Locked")
	end
	if not md.open then
		if md.mode == "battle" and z.battleLine then
			return z.battleLine
		end
		local why = tostring(md.why or "Locked")
		return string.upper(string.sub(why, 1, 1)) .. string.sub(why, 2)
	end
	return MODE_DESC[md.mode] or ""
end

local function paintTiles()
	local z = zoneById(selectedId)
	if not z then
		return
	end
	local cur = defaultMode(z)
	for mode, t in tiles do
		local md = modeOf(z, mode)
		local on = mode == cur
		if md and md.open then
			UiSkin.setVariant(t, if on then "header" else "tab")
		else
			UiSkin.setVariant(t, if on then "purple" else "disabled")
		end
		local lab = t:FindFirstChild("ModeName")
		if lab and lab:IsA("TextLabel") then
			local dark = on and md ~= nil and md.open
			lab.TextColor3 = if dark then UiSkin.color("ink") else Color3.new(1, 1, 1)
			local s = lab:FindFirstChildOfClass("UIStroke")
			if s then
				s.Enabled = not dark
			end
			lab.TextTransparency = if md and md.open then 0 else 0.25
		end
	end
	infoLine.Text = describe(z, focusMode or cur)
end

local function paintGo()
	local m = model
	local z = zoneById(selectedId)
	if not z or not m then
		return
	end
	local mode = defaultMode(z)
	local md = modeOf(z, mode)
	if m.lobby == z.id and mode == "race" then
		UiSkin.setText(goBtn, "LEAVE")
		UiSkin.setEnabled(goBtn, true)
		UiSkin.setVariant(goBtn, "danger")
	elseif md and md.open and z.open then
		UiSkin.setText(goBtn, if mode == "race" and m.lobby ~= nil then "SWITCH" else "GO")
		UiSkin.setEnabled(goBtn, true)
		UiSkin.setVariant(goBtn, "go")
	else
		UiSkin.setText(goBtn, "LOCKED")
		UiSkin.setEnabled(goBtn, false)
	end
	local q: string? = queueText[z.id]
	-- v38-flow: the arch's idle line ("RACE - drive through to start") is the world sign's job; next to GO it only adds
	-- noise. The line shows real state only: a lobby filling, a race running.
	if q and string.find(q, "drive through", 1, true) then
		q = nil
	end
	statusLine.Text = if mode == "race" and q then string.upper(q) else ""
	statusLine.Visible = statusLine.Text ~= ""
end

local function buildTiles(z: Zone)
	for _, t in tiles do
		t:Destroy()
	end
	table.clear(tiles)
	for i, md in z.modes do
		local mode = md.mode
		local t = UiSkin.button(tileRow, "tab", "", {
			name = "Mode_" .. mode,
			variant = "tab",
			layoutOrder = i,
			size = UDim2.fromScale(1, 1),
			zIndex = 34,
			sound = if md.open then "tab" else "deny",
			S = 1,
		})
		t:SetAttribute("SkinShape", "frame") -- v3: square tiles draw the chamfer frame, not the parallelogram tab
		UiSkin.setVariant(t, "header")
		UiSkin.setVariant(t, "tab")
		UiSkin.setText(t, CourseSelect.MODE_LABEL[mode] or string.upper(mode))
		local lab = t:FindFirstChild("Label")
		if lab and lab:IsA("TextLabel") then
			lab.Visible = false
		end
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1.05
		ar.Parent = t
		UiSkin.glyph(t, MODE_ICON[mode] or "star", { name = "Icon", size = UDim2.fromScale(0.52, 0.52), position = UDim2.fromScale(0.5, 0.38), anchor = Vector2.new(0.5, 0.5), zIndex = 36 })
		UiSkin.text(t, if isSmall and mode == "timetrial" then "TRIAL" else (CourseSelect.MODE_LABEL[mode] or string.upper(mode)), "button", {
			name = "ModeName",
			size = UDim2.new(0.92, 0, 0.24, 0),
			position = UDim2.new(0.5, 0, 0.86, -3),
			anchor = Vector2.new(0.5, 1),
			zIndex = 36,
			maxText = 20,
			minText = 12,
		})
		if not md.open then
			UiSkin.glyph(t, "lock", { name = "LockBadge", size = UDim2.fromScale(0.3, 0.3), position = UDim2.new(1, -2, 0, 2), anchor = Vector2.new(1, 0), zIndex = 37 })
			t:SetAttribute("BoardLocked", true)
		end
		t.MouseEnter:Connect(function()
			focusMode = mode
			paintTiles()
		end)
		t.MouseLeave:Connect(function()
			focusMode = nil
			paintTiles()
		end)
		t.SelectionGained:Connect(function()
			focusMode = mode
			paintTiles()
		end)
		t.SelectionLost:Connect(function()
			focusMode = nil
			paintTiles()
		end)
		t.Activated:Connect(function()
			selectedMode[z.id] = mode
			focusMode = mode
			paintTiles()
			paintGo()
			if not md.open then
				deps.toast(string.format("%s: %s", CourseSelect.MODE_LABEL[mode] or mode, describe(z, mode)))
			end
		end)
		tiles[mode] = t
	end
end

function CourseSelect.select(id: string, fromPress: boolean)
	local z = zoneById(id)
	if not z then
		return
	end
	local changed = selectedId ~= id
	selectedId = id
	focusMode = nil
	paintSelection()
	if changed or next(tiles) == nil then
		buildTiles(z)
		layout()
	end
	zoneTitle.Text = string.format("%s  <font transparency=\"0.3\">%s</font>", z.name, string.upper(z.track))
	preview.Image = artOf(z.id) or ""
	preview.BackgroundColor3 = z.color
	local pa = preview:FindFirstChild("Accent")
	if pa and pa:IsA("Frame") then
		pa.BackgroundColor3 = z.color
	end
	if changed then
		local ps = preview:FindFirstChildOfClass("UIScale")
		if ps then
			ps.Scale = 0.94
			TweenService:Create(ps, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
	paintTiles()
	paintGo()
	if changed and not fromPress then
		UiSound.play("select")
	end
end

---------------------------------------------------------------------------------------------------- layout

layout = function()
	local W, H = root.AbsoluteSize.X, root.AbsoluteSize.Y
	if W <= 0 or H <= 0 then
		return
	end
	local small = H < 520
	isSmall = small
	local pad = px(math.clamp(H * 0.025, 8, 22))
	local topH = px(math.clamp(H * 0.09, 38, 72))
	local bottomH = px(math.clamp(H * (if small then 0.34 else 0.32), 112, 280))
	local extrasH = 0
	for _, c in extras:GetChildren() do
		if c:IsA("GuiObject") then
			extrasH = px(math.clamp(H * 0.095, 40, 76)) -- the Grand Prix row: tall enough for readable class chips
			c.Size = UDim2.new(1, 0, 1, 0)
		end
	end
	extras.Visible = extrasH > 0
	topBar.Position = UDim2.fromOffset(pad, pad)
	topBar.Size = UDim2.new(1, -2 * pad, 0, topH)
	titleBand.Size = UDim2.new(0, px(math.min(W * 0.3, topH * 6.2)), 1, 0)
	checker.Position = UDim2.new(0, titleBand.Size.X.Offset + px(pad * 0.8), 0.5, 0)
	checker.Size = UDim2.new(0, px(math.min(W * 0.08, topH * 2.2)), 0, px(topH * 0.34))
	closeBtn.Size = UDim2.fromOffset(topH, topH)
	local progW = px(math.min(W * 0.46, topH * 9.6))
	progress.Size = UDim2.new(0, progW, 0, px(topH * 0.78))
	progress.Position = UDim2.new(1, -(topH + pad), 0.5, 0)
	local cardsTop = pad + topH + pad
	local cardsH = H - cardsTop - bottomH - 2 * pad - (if extrasH > 0 then extrasH + pad else 0)
	cardRow.Position = UDim2.fromOffset(pad, cardsTop)
	cardRow.Size = UDim2.new(1, -2 * pad, 0, cardsH)
	local n = 0
	for _ in cards do
		n += 1
	end
	local gap = px(math.clamp(W * 0.012, 8, 18))
	local cl = cardRow:FindFirstChildOfClass("UIListLayout")
	if cl then
		cl.Padding = UDim.new(0, gap)
	end
	-- desktop leaves room for the 1.1 focus scale; phones keep the full card width (track names fit)
	local cw = math.min(cardsH * (if small then 0.78 else 0.74), (W - 2 * pad - gap * (n - 1) - 12) / math.max(1, n) * (if small then 1 else 0.95))
	local ch = math.min(if small then cardsH - 14 else cardsH * 0.88, cw / 0.7)
	for _, b in cards do
		b.Size = UDim2.fromOffset(px(cw), px(ch))
		-- Phones: the track name takes the whole foot at the 12 px floor; the pips step aside.
		local bandF = b:FindFirstChild("Band")
		local bandPips = bandF and bandF:FindFirstChild("Pips")
		if bandPips and bandPips:IsA("GuiObject") then
			bandPips.Visible = not small
		end
		local foot = b:FindFirstChild("Foot")
		local tr = foot and foot:FindFirstChild("Track")
		local pips = foot and foot:FindFirstChild("Pips")
		if tr and tr:IsA("GuiObject") and pips and pips:IsA("GuiObject") then
			pips.Visible = not small
			tr.Size = if small then UDim2.fromScale(1, 0.9) else UDim2.new(1, 0, 0.46, 0)
			-- one size for every card (TextScaled per card read uneven): the 12 px floor on phones
			local tl = tr :: TextLabel
			tl.TextScaled = false
			tl.TextSize = if small then 12 else math.clamp(math.floor(ch * 0.05), 12, 18)
		end
	end
	local canvasW = px(n * cw + (n - 1) * gap + 12)
	cardRow.CanvasSize = UDim2.fromOffset(canvasW, 0)
	cardRow.ScrollBarThickness = 0 -- drag / gamepad scroll; no bar line under the cards
	for mode, t in tiles do
		local lab = t:FindFirstChild("ModeName")
		if lab and lab:IsA("TextLabel") then
			lab.Text = if small and mode == "timetrial" then "TRIAL" else (CourseSelect.MODE_LABEL[mode] or string.upper(mode))
		end
	end
	extras.Position = UDim2.fromOffset(pad, cardsTop + cardsH + pad)
	extras.Size = UDim2.new(1, -2 * pad, 0, extrasH)
	bottom.Position = UDim2.new(0, pad, 1, -pad - bottomH)
	bottom.Size = UDim2.new(1, -2 * pad, 0, bottomH)
	local inner = px(bottomH * 0.07)
	local goW = px(math.clamp(W * 0.19, 120, 320))
	goBtn.Size = UDim2.fromOffset(goW, px(bottomH * 0.52))
	goBtn.Position = UDim2.new(1, -inner, 0, inner + px(bottomH * 0.06))
	-- two lines when the GO column is narrow (740x360 cut "drive through to start" off at one line)
	statusLine.TextWrapped = small
	statusLine.Size = UDim2.fromOffset(goW + (if small then 24 else 0), px(bottomH * (if small then 0.3 else 0.2)))
	statusLine.Position = UDim2.new(1, -inner, 1, -inner)
	-- the track picture fills the left of the detail area (desktop); phones keep the tiles the whole width
	local nT = 0
	for _ in tiles do
		nT += 1
	end
	local ph = bottomH - 2 * inner
	-- a zone with many modes gives the picture less width so its tiles stay readable
	local pw = if small then 0 else px(math.min(ph * (if nT >= 6 then 1.15 else 1.6), W * 0.26))
	preview.Visible = pw > 0
	preview.Position = UDim2.fromOffset(inner, inner)
	preview.Size = UDim2.fromOffset(pw, ph)
	local lx = inner + (if pw > 0 then pw + inner else 0)
	zoneTitle.Position = UDim2.fromOffset(lx + 4, inner)
	zoneTitle.Size = UDim2.new(1, -goW - 3 * inner - lx, 0, px(bottomH * 0.2))
	-- the mode tiles always fit beside GO: a zone with seven modes gets smaller tiles, never tiles under the GO key
	local nTiles = 0
	for _ in tiles do
		nTiles += 1
	end
	local rowW = W - 2 * pad - goW - 3 * inner - lx
	local tileH = px(bottomH * 0.52)
	if nTiles > 0 then
		tileH = math.min(tileH, math.floor((rowW - 8 * (nTiles - 1)) / nTiles / 1.05))
	end
	tileRow.Position = UDim2.fromOffset(lx, inner + px(bottomH * 0.24))
	tileRow.Size = UDim2.new(1, -goW - 3 * inner - lx, 0, tileH)
	infoLine.Position = UDim2.new(0, lx + 4, 1, -px(inner * 0.6))
	infoLine.Size = UDim2.new(1, -goW - 3 * inner - lx, 0, px(bottomH * 0.15))
end

---------------------------------------------------------------------------------------------------- build / refresh

-- Builds the board's contents into `frame` (TrackFlow's "AdventureBoard", already styled as the panel).
function CourseSelect.build(frame: Frame, d: Deps): Frame
	root = frame
	deps = d
	root.ClipsDescendants = false
	topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.BackgroundTransparency = 1
	topBar.ZIndex = 32
	topBar.Parent = root
	local tl: TextLabel
	titleBand, tl = UiSkin.header(topBar, "COURSE SELECT", { name = "Title", size = UDim2.fromScale(0.3, 1), zIndex = 33, S = 1 })
	-- v3: the screen title top-left in two colours with a chevron, straight on the backdrop (no band, no checker)
	titleBand.BackgroundTransparency = 1
	local tf = titleBand:FindFirstChild("SkinFrame")
	if tf then
		tf:Destroy()
	end
	titleBand:SetAttribute("SkinFramed", nil)
	for _, ch in titleBand:GetChildren() do
		if ch:IsA("UIStroke") then
			ch.Enabled = false
		end
	end
	tl.Name = "TitleText"
	tl.RichText = true
	tl.Text = UiSkin.twoTone("COURSE SELECT") .. "  \u{00BB}"
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.TextXAlignment = Enum.TextXAlignment.Left
	tl.FontFace = UiSkin.font("display")
	for _, ch in tl:GetChildren() do
		if ch:IsA("UIStroke") then
			ch.Enabled = true
		end
	end
	checker = UiSkin.checker(topBar, { name = "Checker", anchor = Vector2.new(0, 0.5), cells = 14, zIndex = 33 })
	checker.Visible = false
	-- v3: the bottom input legend, under the board
	UiSkin.legend(root, {
		{ gamepad = "A", keyboard = "CLICK", label = "SELECT" },
		{ gamepad = "B", keyboard = "B", label = "BACK" },
	}, { position = UDim2.new(0.5, 0, 1, 26), anchor = Vector2.new(0.5, 1), zIndex = 33 })
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 3)
	cc.Parent = checker
	progress = Instance.new("Frame")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.AnchorPoint = Vector2.new(1, 0.5)
	progress.ZIndex = 33
	progress.Parent = topBar
	local plist = Instance.new("UIListLayout")
	plist.FillDirection = Enum.FillDirection.Horizontal
	plist.HorizontalAlignment = Enum.HorizontalAlignment.Right
	plist.VerticalAlignment = Enum.VerticalAlignment.Center
	plist.Padding = UDim.new(0, 8)
	plist.SortOrder = Enum.SortOrder.LayoutOrder
	plist.Parent = progress
	closeBtn = UiSkin.button(topBar, "danger", "", { name = "CloseBoard", anchor = Vector2.new(1, 0), position = UDim2.fromScale(1, 0), glyph = "close", zIndex = 33, sound = "back", S = 1 })
	UiSkin.setText(closeBtn, "CLOSE")
	local cl = closeBtn:FindFirstChild("Label")
	if cl and cl:IsA("TextLabel") then
		cl.Visible = false
	end
	local gl = closeBtn:FindFirstChild("Glyph")
	if gl and gl:IsA("GuiObject") then
		gl.AnchorPoint = Vector2.new(0.5, 0.5)
		gl.Position = UDim2.fromScale(0.5, 0.46)
		gl.Size = UDim2.fromScale(0.62, 0.62)
	end
	closeBtn.Activated:Connect(function()
		deps.close()
	end)

	cardRow = Instance.new("ScrollingFrame")
	cardRow.Name = "List"
	cardRow.BackgroundTransparency = 1
	cardRow.BorderSizePixel = 0
	cardRow.ScrollingDirection = Enum.ScrollingDirection.X
	cardRow.ScrollBarThickness = 4
	cardRow.ZIndex = 32
	cardRow.ClipsDescendants = true
	cardRow.Parent = root
	local cpad = Instance.new("UIPadding")
	cpad.PaddingLeft = UDim.new(0, 6)
	cpad.PaddingRight = UDim.new(0, 6)
	cpad.Parent = cardRow
	local clist = Instance.new("UIListLayout")
	clist.FillDirection = Enum.FillDirection.Horizontal
	clist.HorizontalAlignment = Enum.HorizontalAlignment.Center
	clist.VerticalAlignment = Enum.VerticalAlignment.Center
	clist.SortOrder = Enum.SortOrder.LayoutOrder
	clist.Parent = cardRow

	extras = Instance.new("Frame")
	extras.Name = "Extras"
	extras.BackgroundTransparency = 1
	extras.ZIndex = 32
	extras.Parent = root

	bottom = UiSkin.inset(root, { name = "Modes", zIndex = 32, S = 1 })
	preview = Instance.new("ImageLabel")
	preview.Name = "Preview"
	preview.BorderSizePixel = 0
	preview.ScaleType = Enum.ScaleType.Crop
	preview.ZIndex = 33
	preview.Parent = bottom
	local pst = Instance.new("UIStroke")
	pst.Color = Color3.fromRGB(201, 214, 234)
	pst.Thickness = 2
	pst.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pst.Parent = preview
	Instance.new("UIScale").Parent = preview
	local pacc = Instance.new("Frame")
	pacc.Name = "Accent"
	pacc.BorderSizePixel = 0
	pacc.Size = UDim2.new(1, 0, 0, 5)
	pacc.Position = UDim2.fromScale(0, 1)
	pacc.AnchorPoint = Vector2.new(0, 1)
	pacc.ZIndex = 34
	pacc.Parent = preview
	zoneTitle = UiSkin.title(bottom, "", { name = "ZoneTitle", align = "left", maxText = 30, zIndex = 33, rich = true })
	tileRow = Instance.new("Frame")
	tileRow.Name = "Tiles"
	tileRow.BackgroundTransparency = 1
	tileRow.ZIndex = 33
	tileRow.Parent = bottom
	local tlist = Instance.new("UIListLayout")
	tlist.FillDirection = Enum.FillDirection.Horizontal
	tlist.Padding = UDim.new(0, 8)
	tlist.SortOrder = Enum.SortOrder.LayoutOrder
	tlist.VerticalAlignment = Enum.VerticalAlignment.Center
	tlist.Parent = tileRow
	infoLine = UiSkin.body(bottom, "", { name = "Info", align = "left", anchor = Vector2.new(0, 1), maxText = 22, minText = 12, zIndex = 33 })
	goBtn = UiSkin.button(bottom, "go", "GO", { name = "Go", anchor = Vector2.new(1, 0), zIndex = 34, sound = "confirm", glyph = "flag", maxText = 56, S = 1.3 })
	goBtn.Activated:Connect(function()
		local m = model
		local z = zoneById(selectedId)
		if not z or not m then
			return
		end
		local mode = defaultMode(z)
		local md = modeOf(z, mode)
		if m.lobby == z.id and mode == "race" then
			deps.leave()
		elseif md and md.open and z.open and mode then
			require(script.Parent:WaitForChild("Sfx37")).play("ui_big_confirm", 0.5) -- v37: the big GO
			deps.go(z, mode)
		else
			deps.toast(z.name .. ": " .. describe(z, mode))
		end
	end)
	statusLine = UiSkin.text(bottom, "", "caption", { name = "Status", anchor = Vector2.new(1, 1), maxText = 18, minText = 12, zIndex = 33, color = UiSkin.color("gold") })

	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	return root
end

-- The parent other modules' rows go into (TrackFlow.addBoardRow hooks).
function CourseSelect.extras(): Frame
	return extras
end

local function progressChip(glyph: string, text: string, order: number)
	local h = progress.AbsoluteSize.Y
	local f = UiSkin.chip(progress, text, glyph, { name = "P_" .. glyph, size = UDim2.new(0, px(h * 2.55), 1, 0), layoutOrder = order, zIndex = 34, S = 1 })
	f.BackgroundTransparency = 0.3
end

function CourseSelect.refresh(m: Model)
	model = m
	for _, c in progress:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	progressChip("star", string.format("%d/%d", m.tokens, m.tokensTotal), 1) -- the Sky Token star (the HUD token chip uses it too)
	progressChip("key", string.format("%d/%d", m.keys, m.keysTotal), 2)
	progressChip("boss", string.format("%d/%d", m.boss, m.bossTotal), 3)
	progressChip("battle", string.format("%d/%d", m.battle, m.battleTotal), 4)
	for _, c in cards do
		c:Destroy()
	end
	table.clear(cards)
	for _, t in tiles do
		t:Destroy()
	end
	table.clear(tiles)
	for i, z in m.zones do
		cards[z.id] = buildCard(z, i)
	end
	local keep = zoneById(selectedId)
	local pick: string? = if keep and keep.open then keep.id else nil
	if m.lobby and zoneById(m.lobby) then
		pick = m.lobby
	end
	if not pick then
		-- the furthest open zone: what the player most likely wants next
		for _, z in m.zones do
			if z.open and z.zone ~= "HUB" then
				pick = z.id
			end
		end
	end
	pick = pick or (if m.zones[1] then m.zones[1].id else nil)
	layout()
	if pick then
		selectedId = nil
		CourseSelect.select(pick, true)
	end
	-- open stagger: cards pop in 40 ms apart
	local i = 0
	for _, z in m.zones do
		local b = cards[z.id]
		local sc = b and b:FindFirstChildOfClass("UIScale")
		if sc then
			local target = if z.id == selectedId then (if isSmall then 1.06 else 1.1) else 0.93
			sc.Scale = 0.6
			task.delay(0.05 + i * 0.04, function()
				TweenService:Create(sc, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
			end)
			i += 1
		end
	end
	task.defer(layout)
end

-- 4 Hz from TrackFlow: the arch queue line per track and this player's lobby (GO <-> LEAVE).
function CourseSelect.updateQueue(texts: { [string]: string }, lobby: string?)
	queueText = texts
	local m = model
	if m then
		m.lobby = lobby
	end
	if root and root.Visible then
		paintGo()
		paintTiles()
	end
end

-- Gamepad: focus the selected card.
function CourseSelect.focus()
	local b = if selectedId then cards[selectedId] else nil
	if b and (GuiService:IsTenFootInterface() or UserInputService.GamepadEnabled) then
		GuiService.SelectedObject = b
	end
end

function CourseSelect.selected(): (string?, string?)
	local z = zoneById(selectedId)
	return selectedId, if z then defaultMode(z) else nil
end

return CourseSelect
