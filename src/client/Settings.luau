--!strict
-- Settings (audit H13; TEST_LIST_LAUNCH L24 volume sliders, L40 low-end phones, L44 touch/gamepad reach). One wood
-- plaque panel behind a gear button, in the HUD's system cluster (top-left under the Roblox nav, right of the item frame:
-- HUD layout v2) and in the Garage header:
--   * four volume sliders: MUSIC (player attr MusicVolume), EFFECTS (SfxVolume: engines, impacts, items, tricks, through
--     the SoundGroup SoundService.SkyRallySfx, see Settings.sfx), AMBIENCE (AmbienceVolume), MENU SOUNDS (UiVolume);
--   * ASSIST (auto throttle + steering assist; saved, default on; the HUD's ASSIST pill / chip and the T key are the same switch),
--     CAMERA SHAKE, LOW GRAPHICS and FREE DRIVING (the advanced flight mode, off by default; the server turns it into
--     the FlightMode attribute the flight code reads, docs/design/FLIGHT_GUIDE.md 12) toggles. Other modules read them through Settings.shakeScale() and
--     Settings.lowGraphics() / Settings.particleScale() (Vfx drops burst particles and zone ambience under low graphics);
--   * INVITE FRIENDS (SocialService:CanSendGameInviteAsync, then PromptGameInvite).
--   * One optional extra page behind a SETTINGS | <TITLE> tab pair in the header (Settings.setExtraPage). Only
--     client/AdminPanel registers one: the owner's ADMIN page (DECISIONS D22), after the server confirmed his account.
--     With no page registered nothing extra is created, so every other player's panel is exactly the settings panel.
-- A change applies at once: it sets the player attribute locally (every sound module already listens to those) and is
-- batched to the server (SkyRallyRemotes.SettingsEvent, at most one message per 0.4 s while a slider moves, flushed on
-- close). The server validates and saves it in the profile's non-progression settings table and publishes the saved
-- values as the same attributes once on load (server/SettingsService, shared/SettingsRules).
-- Touch: drag a bar. Mouse: drag or click. Gamepad: up/down moves the selection, D-pad left/right (or L1/R1) changes the
-- selected bar, A presses a button, B closes. Keyboard: O opens and closes.
-- Hub gamepad: L1 and R1 together open it (a race keeps both bumpers for banking). Opening never pauses the game.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SettingsRules"))
-- REMARKABLE 4: every button speaks and squashes; a slider ticks the marimba scale as it crosses a notch.
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))

local LocalPlayer = Players.LocalPlayer

local Settings = {}

-- Wood-plank palette (TrackFlow / Garage / RaceUI)
local CREAM = Color3.fromRGB(250, 242, 222)
local WOOD = Color3.fromRGB(108, 76, 52)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local WOOD_ROW = Color3.fromRGB(82, 56, 36)
local RIM = Color3.fromRGB(188, 168, 142)
local BRASS = Color3.fromRGB(224, 172, 76)
local GREEN = Color3.fromRGB(78, 148, 58)
local GREEN_RIM = Color3.fromRGB(168, 232, 128)
local GOLD = Color3.fromRGB(255, 214, 90)
local DIM = Color3.fromRGB(120, 104, 90)
local MUTED = Color3.fromRGB(214, 200, 180)

local SEND_DELAY = 0.4 -- s: slider moves become one SettingsEvent message
local INVITE_TEXT = "INVITE FRIENDS"
local INVITE_FAIL_TEXT = "CAN'T INVITE HERE"

---------------------------------------------------------------------------------------------------- state

local values: { [string]: number | boolean } = {}
local pending: { [string]: number | boolean } = {}
local sendQueued = false
local sendTries = 0
local remote: RemoteEvent? = nil
local remoteWaiting = false
local listeners: { (string, number | boolean) -> () } = {}
local chosen: { [string]: number | boolean } = {} -- what the player set this session: a late server publish never undoes it

local function refreshValue(key: string, attr: string)
	values[key] = Rules.fromAttribute(key, LocalPlayer:GetAttribute(attr))
end

for _, d in Rules.DEFS do
	refreshValue(d.key, d.attr)
end

local sfxGroup: SoundGroup? = nil
local previewId: string? = nil
local previewSound: Sound? = nil

local function applySfxVolume()
	local g = sfxGroup
	if g then
		g.Volume = values.sfxVolume :: number
	end
end

-- Current value of one setting (defaults until the player or the saved profile says otherwise).
function Settings.get(key: string): number | boolean
	local v = values[key]
	if v == nil then
		local d = Rules.def(key)
		return if d then d.default else false
	end
	return v
end

-- ENGINE SOUND (shared/EngineMixRules): on = the subtle low engine layer while driving, off = no engine sound at all.
function Settings.engineSound(): boolean
	return values.engineSound ~= false
end

function Settings.cameraShake(): boolean
	return values.cameraShake ~= false
end

-- Multiplier for any camera shake: 1 normally, 0 with CAMERA SHAKE off.
function Settings.shakeScale(): number
	return Rules.shakeScale(values.cameraShake ~= false)
end

-- The low graphics flag other modules read (client/Vfx today): fewer particles and no zone ambience emitters.
function Settings.lowGraphics(): boolean
	return values.lowGraphics == true
end

-- Phone tier (touch device without a keyboard): decided once at load; it lowers the default particle scale to 0.6 and
-- turns the heavy smoke layers off for every module that already calls Settings.particleScale() / Settings.heavySmoke().
local phoneTier = Rules.isPhoneTier(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled)

function Settings.phoneTier(): boolean
	return phoneTier
end

-- Session cap from the frame governor (client/FrameGovernor, perf review v21 PF-22): nil until a sustained slow
-- stretch; never saved, never raised again in the session.
local particleCap: number? = nil

-- 1 on desktop, 0.6 on a phone, 0.4 with LOW GRAPHICS (either device); never above the frame governor's cap.
function Settings.particleScale(): number
	return Rules.cappedParticleScale(Rules.particleScale(values.lowGraphics == true, phoneTier), particleCap)
end

-- False on a phone or with LOW GRAPHICS: the flame smoke layer and the heat wisp stay off.
function Settings.heavySmoke(): boolean
	return Rules.heavySmoke(values.lowGraphics == true, phoneTier)
end

-- Calls fn(key, value) whenever a setting changes (a slider, a toggle, or the server publishing the saved values).
function Settings.onChanged(fn: (string, number | boolean) -> ())
	table.insert(listeners, fn)
end

-- The SoundGroup for engine, impact, item and trick sounds; its Volume is the EFFECTS slider.
function Settings.sfxGroup(): SoundGroup
	local g = sfxGroup
	if g and g.Parent then
		return g
	end
	local existing = SoundService:FindFirstChild("SkyRallySfx")
	if existing and existing:IsA("SoundGroup") then
		g = existing
	else
		local ng = Instance.new("SoundGroup")
		ng.Name = "SkyRallySfx"
		ng.Parent = SoundService
		g = ng
	end
	sfxGroup = g
	applySfxVolume()
	return g :: SoundGroup
end

-- Routes one Sound through the EFFECTS slider. Call it where the Sound is made.
function Settings.sfx(sound: Sound)
	sound.SoundGroup = Settings.sfxGroup()
end

-- A short effect the EFFECTS slider plays when you let go, so you hear the level (SoundJuice hands over its whoosh).
function Settings.setSfxPreview(soundId: string)
	previewId = soundId
end

local function playPreview()
	local id = previewId
	if not id then
		return
	end
	local s = previewSound
	if not s or not s.Parent then
		local ns = Instance.new("Sound")
		ns.Name = "SettingsPreview"
		ns.SoundId = id
		ns.Volume = 0.6
		ns.Parent = SoundService
		Settings.sfx(ns)
		previewSound = ns
		s = ns
	end
	local snd = s :: Sound
	snd.TimePosition = 0
	snd:Play()
end

---------------------------------------------------------------------------------------------------- save relay

local function remoteEvent(): RemoteEvent?
	if remote then
		return remote
	end
	if not remoteWaiting then
		remoteWaiting = true
		task.spawn(function()
			local folder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
			local ev = folder and folder:WaitForChild("SettingsEvent", 15)
			if ev and ev:IsA("RemoteEvent") then
				remote = ev
			end
			remoteWaiting = false
		end)
	end
	return remote
end

-- Sends what changed since the last message (one table, never more keys than there are settings).
function Settings.flush()
	sendQueued = false
	if next(pending) == nil then
		return
	end
	local ev = remoteEvent()
	if not ev then
		-- The remote has not arrived yet: keep the values and try again shortly. A place without the server relay
		-- (a bare test place) gives up after ten tries; the settings still work locally.
		sendTries += 1
		if sendTries > 10 then
			pending = {}
			sendTries = 0
			return
		end
		sendQueued = true
		task.delay(1, Settings.flush)
		return
	end
	sendTries = 0
	local payload = pending
	pending = {}
	ev:FireServer(payload)
end

local function queueSend()
	if sendQueued then
		return
	end
	sendQueued = true
	task.delay(SEND_DELAY, Settings.flush)
end

local function notify(key: string, v: number | boolean)
	for _, fn in listeners do
		task.spawn(fn, key, v)
	end
end

-- Frame governor: lowers the particle scale for the rest of the session (only downward) and tells the listeners with
-- the pseudo key "particleScale", so Vfx ambience, AtmosphereFx and MapFxLod re-apply their rates at once.
function Settings.capParticleScale(cap: number)
	local before = Settings.particleScale()
	particleCap = math.min(particleCap or 1, cap)
	local after = Settings.particleScale()
	if after ~= before then
		notify("particleScale", after)
	end
end

-- Changes one setting now: the player attribute (read by every sound module), the SoundGroup, the listeners, and a
-- batched message to the server. A value the rules refuse (wrong type) changes nothing.
function Settings.set(key: string, raw: any)
	local d = Rules.def(key)
	local v = Rules.cleanValue(key, raw)
	if not d or v == nil then
		return
	end
	chosen[key] = v
	if values[key] == v then
		return
	end
	values[key] = v
	LocalPlayer:SetAttribute(d.attr, v)
	if key == "sfxVolume" then
		applySfxVolume()
	end
	pending[key] = v
	queueSend()
	notify(key, v)
end

for _, d in Rules.DEFS do
	LocalPlayer:GetAttributeChangedSignal(d.attr):Connect(function()
		-- The server publishes the saved profile when it finishes loading (a retried load can land 20 s into a session).
		-- The player's own choice is newer: refuse a disagreeing value, put ours back and tell the server again (QA V5A).
		local incoming = LocalPlayer:GetAttribute(d.attr)
		if not Rules.acceptRemote(chosen, d.key, incoming) then
			local mine = chosen[d.key]
			LocalPlayer:SetAttribute(d.attr, mine)
			values[d.key] = mine :: number | boolean
			pending[d.key] = mine :: number | boolean
			queueSend()
			return
		end
		local before = values[d.key]
		refreshValue(d.key, d.attr)
		if values[d.key] ~= before then
			if d.key == "sfxVolume" then
				applySfxVolume()
			end
			notify(d.key, values[d.key] :: number | boolean)
		end
	end)
end

---------------------------------------------------------------------------------------------------- widgets

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
end

local function stroke(p: Instance, color: Color3, t: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = t
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
end

local function textStroke(p: Instance, t: number)
	local s = Instance.new("UIStroke")
	s.Color = WOOD_DARK
	s.Thickness = t
	s.Parent = p
end

local function label(parent: Instance, name: string, str: string, size: number, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font or Enum.Font.GothamBlack
	l.TextSize = size
	l.TextColor3 = CREAM
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = str
	l.Active = false
	l.Parent = parent
	return l
end

local function fitText(l: TextLabel, maxSize: number)
	l.TextScaled = true
	local c = Instance.new("UITextSizeConstraint")
	c.MinTextSize = 10
	c.MaxTextSize = maxSize
	c.Parent = l
end

-- A cog drawn from rounded bars (no glyph or image to load): four bars cross as eight teeth, a disc covers the middle,
-- and a hole in the button colour finishes it.
local function buildCog(parent: GuiObject, color: Color3, holeColor: Color3)
	local holder = Instance.new("Frame")
	holder.Name = "Cog"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(0.62, 0.62)
	holder.BackgroundTransparency = 1
	holder.Active = false
	holder.Parent = parent
	for i = 0, 3 do
		local bar = Instance.new("Frame")
		bar.Name = "Tooth" .. i
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromScale(0.22, 1)
		bar.Rotation = i * 45
		bar.BackgroundColor3 = color
		bar.BorderSizePixel = 0
		bar.Active = false
		bar.Parent = holder
		corner(bar, 3)
	end
	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromScale(0.5, 0.5)
	disc.Size = UDim2.fromScale(0.74, 0.74)
	disc.BackgroundColor3 = color
	disc.BorderSizePixel = 0
	disc.Active = false
	disc.Parent = holder
	corner(disc, 999)
	local hole = Instance.new("Frame")
	hole.Name = "Hole"
	hole.AnchorPoint = Vector2.new(0.5, 0.5)
	hole.Position = UDim2.fromScale(0.5, 0.5)
	hole.Size = UDim2.fromScale(0.32, 0.32)
	hole.BackgroundColor3 = holeColor
	hole.BorderSizePixel = 0
	hole.Active = false
	hole.Parent = holder
	corner(hole, 999)
end

local toggle: () -> ()

-- ASSIST is a saved setting that FlightController mirrors; RaceUI installs the setter (banner + flight flags; Settings cannot require the flight code).
local assistSetter: ((on: boolean) -> ())? = nil
function Settings.setAssistHandler(fn: (on: boolean) -> ())
	assistSetter = fn
end

-- The gear button: a carved stone/wood square with a cream cog. The HUD and the Garage each make one; the caller sizes
-- and places it. Pressing it opens or closes the panel.
function Settings.makeGearButton(parent: Instance, name: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.AutoButtonColor = true
	b.BackgroundColor3 = WOOD_DARK
	b.Parent = parent
	corner(b, 10)
	stroke(b, RIM, 2)
	buildCog(b, CREAM, WOOD_DARK)
	UiSound.bind(b, "stone")
	b.Activated:Connect(function()
		toggle()
	end)
	return b
end

---------------------------------------------------------------------------------------------------- panel

type SliderRow = {
	key: string,
	button: TextButton,
	track: Frame,
	fill: Frame,
	thumb: Frame,
	pct: TextLabel,
	notch: number,
}
type ToggleRow = { key: string, button: TextButton, pill: Frame, pillText: TextLabel }

local built = false
local gui: ScreenGui
local backdrop: TextButton
local panel: Frame
local fit: UIScale
local hintLabel: TextLabel
local inviteButton: TextButton
local doneButton: TextButton
local sliders: { SliderRow } = {}
local toggles: { ToggleRow } = {}
local isOpen = false
local prevSelection: GuiObject? = nil
local dragRow: SliderRow? = nil
local dragInput: InputObject? = nil
local inviting = false

-- The optional extra page (D22 owner ADMIN page): the settings rows sit in `content`, the page in `extraFrame`; the header
-- tab pair swaps them. Nothing here is created until Settings.setExtraPage registers a page.
type ExtraPage = { title: string, build: (page: Frame) -> (), onShow: (() -> ())? }
local extra: ExtraPage? = nil
local content: Frame
local extraFrame: Frame? = nil
local mainTab: TextButton? = nil
local extraTab: TextButton? = nil
local showingExtra = false

local function paintTab(b: TextButton, active: boolean)
	b.BackgroundColor3 = if active then WOOD_DARK else WOOD_ROW
	b.TextColor3 = if active then GOLD else MUTED
	local s = b:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = if active then BRASS else RIM
	end
end

local function showPage(toExtra: boolean)
	local page, a, b, e = extraFrame, mainTab, extraTab, extra
	if not built or not page or not a or not b or not e then
		return
	end
	showingExtra = toExtra
	content.Visible = not toExtra
	page.Visible = toExtra
	paintTab(a, not toExtra)
	paintTab(b, toExtra)
	-- D-pad down from the tabs goes to the visible page: the first slider, or the engine's pick on the extra page.
	local first = sliders[1]
	local down = if not toExtra and first then first.button else nil
	a.NextSelectionDown = down :: any -- nil is valid at runtime (engine picks); the type defs say non-nil
	b.NextSelectionDown = down :: any
	local onShow = e.onShow
	if toExtra and onShow then
		task.spawn(onShow)
	end
end

-- The page fills the panel under the header, and starts under the Roblox top-left nav where the centred panel reaches
-- beneath it (SettingsRules.pageTop), so none of its rows hide under the nav on a phone.
local function placeExtra()
	local page = extraFrame
	if not built or not page then
		return
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(740, 360)
	local top = Rules.pageTop(vp.X, vp.Y, fit.Scale, HudMetrics.get().nav)
	page.Position = UDim2.fromOffset(14, top)
	page.Size = UDim2.fromOffset(Rules.PANEL_W - 28, Rules.PANEL_H - top - 12)
end

local function notchOf(v: number): number
	return math.floor(v / Rules.STEP + 0.5) + 1 -- 1..11, the marimba step
end

local function paintSlider(row: SliderRow)
	local v = values[row.key] :: number
	row.fill.Size = UDim2.fromScale(v, 1)
	row.thumb.Position = UDim2.fromScale(v, 0.5)
	row.pct.Text = Rules.percentText(v)
	row.notch = notchOf(v)
end

local function paintToggle(row: ToggleRow)
	local on = values[row.key] == true
	row.pillText.Text = if on then "ON" else "OFF"
	row.pill.BackgroundColor3 = if on then GREEN else DIM
	row.pillText.TextColor3 = if on then CREAM else MUTED
	local s = row.pill:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = if on then GREEN_RIM else RIM
	end
end

local function paintAll()
	if not built then
		return
	end
	for _, r in sliders do
		paintSlider(r)
	end
	for _, r in toggles do
		paintToggle(r)
	end
end

local function setSlider(row: SliderRow, v: number)
	local before = row.notch
	Settings.set(row.key, v)
	paintSlider(row)
	if row.notch ~= before then
		-- The marimba scale up the notches: walking a bar plays a tune. The UI sound gates keep a fast drag tidy.
		UiSound.play("select", row.notch)
	end
end

local function setFromX(row: SliderRow, x: number)
	local track = row.track
	setSlider(row, Rules.fractionAt(x, track.AbsolutePosition.X, track.AbsoluteSize.X))
end

local function endDrag()
	local row = dragRow
	dragRow, dragInput = nil, nil
	if row then
		Settings.flush()
		if row.key == "sfxVolume" then
			playPreview()
		end
	end
end

local function rowOf(obj: Instance?): SliderRow?
	for _, r in sliders do
		if r.button == obj then
			return r
		end
	end
	return nil
end

local function inviteFriends()
	if inviting then
		return
	end
	inviting = true
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(LocalPlayer)
		end)
		local opened = false
		if ok and can then
			opened = pcall(function()
				SocialService:PromptGameInvite(LocalPlayer)
			end)
		end
		if not opened then
			UiSound.play("deny")
			inviteButton.Text = INVITE_FAIL_TEXT
			task.wait(2.2)
			inviteButton.Text = INVITE_TEXT
		end
		inviting = false
	end)
end

local function closeAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and isOpen then
		UiSound.play("back")
		Settings.close()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- D-pad / bumpers / arrows change the selected bar by one notch; anything else keeps its normal job (navigation).
local function adjustAction(_n: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or not isOpen then
		return Enum.ContextActionResult.Pass
	end
	local row = rowOf(GuiService.SelectedObject)
	if not row then
		return Enum.ContextActionResult.Pass
	end
	local code = input.KeyCode
	local dir = if code == Enum.KeyCode.DPadLeft or code == Enum.KeyCode.ButtonL1 or code == Enum.KeyCode.Left then -1 else 1
	setSlider(row, Rules.nudge(values[row.key] :: number, dir))
	return Enum.ContextActionResult.Sink
end

local function layout()
	if not built then
		return
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(740, 360)
	fit.Scale = Rules.panelScale(vp.X, vp.Y)
	placeExtra()
end

local function updateHint()
	if not built then
		return
	end
	local mode = LocalPlayer:GetAttribute("InputMode")
	hintLabel.Visible = mode == "Gamepad"
end

function Settings.isOpen(): boolean
	return isOpen
end

function Settings.close()
	if not built or not isOpen then
		return
	end
	isOpen = false
	endDrag()
	Settings.flush() -- the server hears the final values as the panel closes
	gui.Enabled = false
	ContextActionService:UnbindAction("SkyRallySettingsClose")
	ContextActionService:UnbindAction("SkyRallySettingsAdjust")
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(gui) then
		local prev = prevSelection
		GuiService.SelectedObject = if prev and prev.Parent and prev.Visible and prev:IsDescendantOf(LocalPlayer) then prev else nil
	end
	prevSelection = nil
end

-- Builds the header tab pair and the extra page once the panel exists and a page is registered (no-op otherwise).
local function addExtra()
	local e = extra
	if not built or not e or extraTab then
		return
	end
	local function tab(name: string, text: string, x: number, w: number): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.Position = UDim2.fromOffset(x, 8)
		b.Size = UDim2.fromOffset(w, 28)
		b.Font = Enum.Font.GothamBlack
		b.Text = text
		b.AutoButtonColor = true
		b.Parent = panel
		corner(b, 8)
		stroke(b, RIM, 2)
		fitText(b :: any, 16)
		UiSound.bind(b, "tab")
		return b
	end
	local x2 = Rules.PANEL_W - 14 - 92
	local a = tab("SettingsTab", "SETTINGS", x2 - 6 - 112, 112)
	local b = tab("PageTab", e.title, x2, 92)
	a.Activated:Connect(function()
		showPage(false)
	end)
	b.Activated:Connect(function()
		showPage(true)
	end)
	mainTab, extraTab = a, b
	-- The gamepad hint is short with the tabs up (they take its room); D-pad still reaches the tabs from the first bar.
	hintLabel.Text = "B CLOSES"
	hintLabel.Size = UDim2.fromOffset(x2 - 6 - 112 - 8 - 220, 22)
	a.NextSelectionRight = b
	b.NextSelectionLeft = a
	a.NextSelectionDown = sliders[1].button
	sliders[1].button.NextSelectionUp = a
	local page = Instance.new("Frame")
	page.Name = "ExtraPage"
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = panel
	extraFrame = page
	placeExtra()
	HudMetrics.onChanged(placeExtra) -- the nav reserve can arrive after the panel
	e.build(page)
	showPage(false)
end

-- Registers the one extra page (D22: only client/AdminPanel, only on the owner's account after the server said so).
-- build(page) fills a transparent Frame under the header; onShow runs each time its tab is picked. A second call is ignored.
function Settings.setExtraPage(title: string, build: (page: Frame) -> (), onShow: (() -> ())?)
	if extra then
		return
	end
	extra = { title = title, build = build, onShow = onShow }
	addExtra() -- now if the panel was already built, otherwise at its first build
end

local function build()
	if built then
		return
	end
	built = true
	gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallySettings"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30 -- over the Garage (26), TrackFlow and its curtain (20); under the controls hint (40)
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	-- A tap outside the plaque closes it; the dim also keeps stray touches off the steering pad underneath.
	backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.BorderSizePixel = 0
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.Selectable = false
	backdrop.Parent = gui
	backdrop.Activated:Connect(function()
		UiSound.play("back")
		Settings.close()
	end)

	panel = Instance.new("Frame")
	panel.Name = "SettingsPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(Rules.PANEL_W, Rules.PANEL_H)
	panel.BackgroundColor3 = WOOD
	panel.Active = true
	-- Gamepad selection never wanders out to the HUD under the dim.
	panel.SelectionGroup = true
	panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	panel.Parent = gui
	corner(panel, 14)
	stroke(panel, RIM, 3)
	fit = Instance.new("UIScale")
	fit.Parent = panel
	-- Every settings row lives in `content` (same offsets as the panel), so an extra page can swap it out.
	content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Active = false
	content.Parent = panel

	local title = label(panel, "Title", "SETTINGS", 26)
	title.Position = UDim2.fromOffset(16, 6)
	title.Size = UDim2.fromOffset(200, 34)
	textStroke(title, 2)

	hintLabel = label(panel, "Hint", "D-PAD CHANGES BARS  -  B CLOSES", 13, Enum.Font.GothamBold)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Right
	hintLabel.TextColor3 = MUTED
	hintLabel.Position = UDim2.fromOffset(220, 12)
	hintLabel.Size = UDim2.fromOffset(366, 22)
	hintLabel.Visible = false

	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.Position = UDim2.fromOffset(14, 42)
	rule.Size = UDim2.fromOffset(Rules.PANEL_W - 28, 2)
	rule.BackgroundColor3 = WOOD_DARK
	rule.BorderSizePixel = 0
	rule.Active = false
	rule.Parent = content

	local selectables: { GuiObject } = {}
	local blank = Instance.new("Frame") -- no selection outline on the bars: the row lights up instead
	blank.Name = "NoOutline"
	blank.BackgroundTransparency = 1
	blank.Size = UDim2.new()
	blank.Active = false
	blank.Parent = panel

	-- Left column: the four volume bars.
	local sliderKeys = { "musicVolume", "sfxVolume", "ambienceVolume", "uiVolume" }
	for i, key in sliderKeys do
		local d = Rules.def(key) :: Rules.Def
		local b = Instance.new("TextButton")
		b.Name = "Slider_" .. key
		b.Position = UDim2.fromOffset(14, 50 + (i - 1) * 68)
		b.Size = UDim2.fromOffset(290, 56)
		b.BackgroundColor3 = WOOD_ROW
		b.BackgroundTransparency = 1
		b.Text = ""
		b.AutoButtonColor = false
		b.SelectionImageObject = blank
		b.Parent = content
		corner(b, 10)
		local name = label(b, "Label", d.label, 17)
		name.Position = UDim2.fromOffset(8, 3)
		name.Size = UDim2.fromOffset(190, 22)
		textStroke(name, 1.6)
		local pct = label(b, "Percent", "", 17)
		pct.TextXAlignment = Enum.TextXAlignment.Right
		pct.TextColor3 = GOLD
		pct.Position = UDim2.fromOffset(200, 3)
		pct.Size = UDim2.fromOffset(82, 22)
		textStroke(pct, 1.6)
		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Position = UDim2.fromOffset(18, 30)
		track.Size = UDim2.fromOffset(254, 16)
		track.BackgroundColor3 = WOOD_DARK
		track.Active = false
		track.Parent = b
		corner(track, 999)
		stroke(track, RIM, 1.5)
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = BRASS
		fill.BorderSizePixel = 0
		fill.Active = false
		fill.Parent = track
		corner(fill, 999)
		local thumb = Instance.new("Frame")
		thumb.Name = "Thumb"
		thumb.AnchorPoint = Vector2.new(0.5, 0.5)
		thumb.Size = UDim2.fromOffset(28, 28)
		thumb.BackgroundColor3 = CREAM
		thumb.Active = false
		thumb.ZIndex = 2
		thumb.Parent = track
		corner(thumb, 999)
		stroke(thumb, WOOD_DARK, 2.5)
		local row: SliderRow = { key = key, button = b, track = track, fill = fill, thumb = thumb, pct = pct, notch = 1 }
		table.insert(sliders, row)
		table.insert(selectables, b)
		-- Left/right belong to the bar while it is selected, so selection stays put (the adjust action changes the value).
		b.NextSelectionLeft = b
		b.NextSelectionRight = b
		b.SelectionGained:Connect(function()
			b.BackgroundTransparency = 0.25
			UiSound.play("select", i)
		end)
		b.SelectionLost:Connect(function()
			b.BackgroundTransparency = 1
		end)
		b.MouseEnter:Connect(function()
			if dragRow == nil and GuiService.SelectedObject ~= b then
				b.BackgroundTransparency = 0.6
			end
		end)
		b.MouseLeave:Connect(function()
			if GuiService.SelectedObject ~= b then
				b.BackgroundTransparency = 1
			end
		end)
		b.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragRow, dragInput = row, input
				setFromX(row, input.Position.X)
			end
		end)
	end

	-- Right column: toggles, invite, done.
	local TOGGLE_PITCH, TOGGLE_H = 46, 40 -- five toggles, then INVITE + DONE, inside PANEL_H
	local function rightButton(name: string, y: number, color: Color3, rim: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.Position = UDim2.fromOffset(322, y)
		b.Size = UDim2.fromOffset(264, 48)
		b.BackgroundColor3 = color
		b.Text = ""
		b.AutoButtonColor = true
		b.Parent = content
		corner(b, 10)
		stroke(b, rim, 2)
		table.insert(selectables, b)
		return b
	end
	for i, key in { "assist", "cameraShake", "lowGraphics", "engineSound", "freeDriving" } do
		local d = Rules.def(key)
		local b = rightButton("Toggle_" .. key, 50 + (i - 1) * TOGGLE_PITCH, WOOD_DARK, RIM)
		b.Size = UDim2.fromOffset(264, TOGGLE_H)
		local name = label(b, "Label", if d then d.label else "ASSIST", 16)
		name.Position = UDim2.fromOffset(12, 0)
		name.Size = UDim2.fromOffset(160, TOGGLE_H)
		fitText(name, 16)
		textStroke(name, 1.6)
		local pill = Instance.new("Frame")
		pill.Name = "Pill"
		pill.AnchorPoint = Vector2.new(1, 0.5)
		pill.Position = UDim2.new(1, -10, 0.5, 0)
		pill.Size = UDim2.fromOffset(66, 30)
		pill.BackgroundColor3 = DIM
		pill.Active = false
		pill.Parent = b
		corner(pill, 999)
		stroke(pill, RIM, 2)
		local pt = label(pill, "State", "OFF", 16)
		pt.Size = UDim2.fromScale(1, 1)
		pt.TextXAlignment = Enum.TextXAlignment.Center
		local row: ToggleRow = { key = key, button = b, pill = pill, pillText = pt }
		table.insert(toggles, row)
		UiSound.bind(b, "tap")
		b.Activated:Connect(function()
			if key == "assist" then
				local setter = assistSetter
				if setter then
					setter(values.assist ~= true)
				else
					Settings.set("assist", values.assist ~= true) -- the Garage: no flight code yet, the saved value still flips
					Settings.flush()
				end
			else
				Settings.set(key, not (values[key] == true))
				Settings.flush()
			end
			paintToggle(row)
		end)
	end
	-- The HUD chip flips the same switch (values follow the AutoThrottle attribute): keep the row honest.
	Settings.onChanged(function(key: string)
		if key == "assist" then
			paintAll()
		end
	end)

	-- INVITE and DONE share the last row (five toggles above them; PANEL_H keeps 740x360 unscaled).
	inviteButton = rightButton("InviteFriends", 50 + 5 * TOGGLE_PITCH, GREEN, GREEN_RIM)
	inviteButton.Size = UDim2.fromOffset(156, 48)
	inviteButton.Text = INVITE_TEXT
	inviteButton.Font = Enum.Font.GothamBlack
	inviteButton.TextColor3 = CREAM
	fitText(inviteButton :: any, 18)
	textStroke(inviteButton, 1.6)
	UiSound.bind(inviteButton, "confirm")
	inviteButton.Activated:Connect(inviteFriends)

	doneButton = rightButton("Done", 50 + 5 * TOGGLE_PITCH, WOOD_DARK, RIM)
	doneButton.Position = UDim2.fromOffset(322 + 164, 50 + 5 * TOGGLE_PITCH)
	doneButton.Size = UDim2.fromOffset(100, 48)
	doneButton.Text = "DONE"
	doneButton.Font = Enum.Font.GothamBlack
	doneButton.TextColor3 = CREAM
	fitText(doneButton :: any, 20)
	textStroke(doneButton, 1.6)
	UiSound.bind(doneButton, "back")
	doneButton.Activated:Connect(function()
		Settings.close()
	end)

	-- One vertical path for the gamepad: the four bars, the five toggles, invite, done (also left / right of each other).
	for i, obj in selectables do
		local prev, nxt = selectables[i - 1], selectables[i + 1]
		if prev then
			obj.NextSelectionUp = prev
		end
		if nxt then
			obj.NextSelectionDown = nxt
		end
	end
	for _, r in toggles do
		r.button.NextSelectionLeft = r.button
		r.button.NextSelectionRight = r.button
	end
	inviteButton.NextSelectionRight = doneButton
	doneButton.NextSelectionLeft = inviteButton

	-- Mouse and touch drags follow the pointer wherever it goes until released.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local row = dragRow
		if row and (input.UserInputType == Enum.UserInputType.MouseMovement or input == dragInput) then
			setFromX(row, input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragRow and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
			endDrag()
		end
	end)

	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(updateHint)
	Settings.onChanged(function()
		if isOpen then
			paintAll()
		end
	end)
	layout()
	updateHint()
	paintAll()
	addExtra()
end

function Settings.open()
	build()
	if isOpen then
		return
	end
	isOpen = true
	showPage(false) -- every open starts on the settings rows
	layout()
	updateHint()
	paintAll()
	local sel = GuiService.SelectedObject
	prevSelection = if sel and not sel:IsDescendantOf(gui) and sel:IsA("GuiObject") then sel else nil
	gui.Enabled = true
	-- A small pop, like the other plaques.
	local target = fit.Scale
	fit.Scale = target * 0.9
	TweenService:Create(fit, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
	-- B closes; the D-pad, bumpers and arrows change a selected bar and pass through otherwise.
	ContextActionService:BindActionAtPriority(
		"SkyRallySettingsClose",
		closeAction,
		false,
		Enum.ContextActionPriority.High.Value + 30,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:BindActionAtPriority(
		"SkyRallySettingsAdjust",
		adjustAction,
		false,
		Enum.ContextActionPriority.High.Value + 20,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right
	)
	if UserInputService.GamepadEnabled or GuiService:IsTenFootInterface() or LocalPlayer:GetAttribute("InputMode") == "Gamepad" then
		GuiService.SelectedObject = sliders[1].button
	end
end

toggle = function()
	if isOpen then
		Settings.close()
	else
		Settings.open()
	end
end
Settings.toggle = toggle

---------------------------------------------------------------------------------------------------- HUD gear and keys

local hudGear: TextButton? = nil

-- HUD layout v2: the gear is the first button of the system cluster, right of the item frame under the Roblox nav
-- (HudLayoutRules rects.gear), in every phase; client/HudPhase hides the cluster on the podium.
local function placeHudGear()
	local g = hudGear
	if not g then
		return
	end
	local r = HudMetrics.rects().gear
	g.Position = UDim2.fromOffset(r.x, r.y)
	g.Size = UDim2.fromOffset(r.w, r.h)
end

local inited = false
local held: { [Enum.KeyCode]: boolean } = {}

-- Builds the HUD gear and the key bindings. Idempotent. The panel itself is built on first open.
function Settings.init()
	if inited then
		return
	end
	inited = true
	remoteEvent() -- start waiting for the remote now, so the first slider move can send
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyGear"
	sg.IgnoreGuiInset = true
	sg.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 4 -- over the HUD (0), under TrackFlow's curtain (20)
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	local g = Settings.makeGearButton(sg, "SettingsGear")
	g.AnchorPoint = Vector2.zero
	hudGear = g
	placeHudGear()
	HudMetrics.onChanged(placeHudGear) -- viewport, insets, the nav reserve, the input kind
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") == true then
			Settings.close()
		end
	end)
	ContextActionService:BindAction("SkyRallySettingsToggle", function(_n, state, _o): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin or UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		UiSound.play(if isOpen then "back" else "tab")
		toggle()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.O)
	-- Hub gamepad: both bumpers together. Never sinks, so banking keeps working; in a race it does nothing.
	ContextActionService:BindAction("SkyRallySettingsChord", function(_n, state, input): Enum.ContextActionResult
		local code = input.KeyCode
		if state == Enum.UserInputState.Begin then
			held[code] = true
			if held[Enum.KeyCode.ButtonL1] and held[Enum.KeyCode.ButtonR1] and RaceAttr.mine("RaceMode") == "hub" and not isOpen then
				UiSound.play("tab")
				Settings.open()
			end
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			held[code] = nil
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
end

return Settings
