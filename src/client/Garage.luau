--!strict
-- The Garage (MONETIZATION_PROPOSAL sections 2-3; TEST_LIST_LAUNCH L50, L53, L55-L59). One GARAGE button in the hub HUD
-- (under ADVENTURE) and one GARAGE tab on the race results panel open a wood-plank panel with seven tabs:
--   LIVERIES / TRAILS / HORNS / EMOTES  every cosmetic of the kind: owned, equipped (one tap; liveries per vehicle),
--                                       buy with Gears when it is in the shop now, or where it comes from
--   SHOP      the rotating shop: four always-stocked rows, the rotating rows with stock / SOLD OUT, the Daily Deal and
--             the restock countdown; Robux products only when the store is on AND the product has a real id (the
--             server's GetState.products), priced from GetProductInfo, never from a hardcoded label
--   WIN PASS  tiers (races finished) with the free and premium columns and CLAIM buttons
--   DAILY     the 7-day claim strip, streak, Rally Streak, Festival and Storm Cup times
-- MonetizationConfig.LAUNCH_HIDE (public release only) leaves the DAILY tab out (GarageModel.TABS), shows every shop item
-- always in stock with no restock line, and drops the Rally Streak and Festival chips (GetState.features).
-- Every number shown comes from the server (SkyRallyRemotes.EconomyRequest replies, the Gears attribute); every action
-- is a request the server validates (server/Economy). The panel never opens in a race, countdown or boss intro
-- (GarageModel.canOpen) and closes if one starts. Hidden entirely unless workspace.GarageEnabled (MonetizationConfig.
-- Enabled, on for private testing since 2026-10-20, or Studio QA with workspace.EconomyQA). Robux rows appear as
-- server/StoreBinder binds them (ReplicatedStorage.SkyRallyStore); none bound = a quiet COMING SOON line.
-- Input: G or L3 (left stick click) toggles it where it may open; B / gamepad B (or Y, which would open the Adventure
-- board under it) closes it. Every live button is a selectable TextButton and gamepad selection stays inside the panel
-- (SelectionGroup) and comes back to the row it was on after a rebuild; every target is 44 px; the panel sits inside a
-- TV-safe 5% inset below the top bar (GarageModel.layout). Opening the Garage closes the Adventure board and opening the
-- board closes the Garage, so the two never stack.
-- Toasts: shown on the panel's own plank while it is open (TrackFlow's toast sits under the panel), TrackFlow's toast
-- otherwise; EconomyEvent "Toast" (Delivered once on rejoin, Gift, Pass) takes the same path.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local GarageModel = require(Shared:WaitForChild("GarageModel"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local AvatarConfig = require(Shared:WaitForChild("AvatarConfig")) -- phase 6: VEHICLES tab classes
local TrackFlow = require(script.Parent:WaitForChild("TrackFlow"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit")) -- toasts (economy v3 phase 3b)
local Cosmetics = require(script.Parent:WaitForChild("Cosmetics"))
-- REMARKABLE 4: every button speaks (wood tap, tab flip, marimba confirm/back, stone deny + shake, purchase run).
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics")) -- L28 / L82 and HUD layout v2: the hub button hangs under TrackFlow's bar in the safe rect
-- REMARKABLE 27: the turntable toy at the top of the cosmetic tabs (try a livery, REV, HONK).
local GarageTurntable = require(script.Parent:WaitForChild("GarageTurntable"))
-- Audit H13: the gear in the panel header opens the Settings panel (sound sliders, camera shake, low graphics, invite).
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local Garage = {}

-- Wood-plank palette (TrackFlow / RaceUI)
local CREAM = Color3.fromRGB(250, 242, 222)
local WOOD = Color3.fromRGB(108, 76, 52)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local WOOD_ROW = Color3.fromRGB(82, 56, 36)
local RIM = Color3.fromRGB(188, 168, 142)
local BRASS = Color3.fromRGB(224, 172, 76)
local GREEN = Color3.fromRGB(78, 148, 58)
local GREEN_RIM = Color3.fromRGB(168, 232, 128)
local GOLD = Color3.fromRGB(255, 214, 90)
local ORANGE = Color3.fromRGB(196, 120, 24)
local DIM = Color3.fromRGB(120, 104, 90)
local MUTED = Color3.fromRGB(214, 200, 180)
local ROBUX = Color3.fromRGB(40, 130, 120)

local request: RemoteFunction? = nil
local gui: ScreenGui
local hubButton: TextButton
local gearsChip: TextLabel
local panel: Frame
local titleLabel: TextLabel
local gearsLabel: TextLabel
local infoLabel: TextLabel
local closeButton: TextButton
local gearButton: TextButton
local tabsFrame: Frame
local tabButtons: { [string]: TextButton } = {}
local content: ScrollingFrame
local overlay: Frame? = nil
local resultsTab: TextButton? = nil
local resultsGears: TextLabel? = nil
local toastRect: { x: number, y: number, w: number, h: number }? = nil -- the plank over the panel bottom (applyLayout); NotifyKit draws it
local prevSelection: GuiObject? = nil -- what gamepad selection sat on before the panel opened (results tab, ...)

local st: any = nil -- GetState data
local av: any = nil -- GetAvatars data (phase 6: the VEHICLES tab)
local avClass = "plane" -- which class the VEHICLES tab lists
local avFocus: string? = nil -- the avatar whose LOOKS ladder is open under the list
local stClock = 0
local shop: any = nil -- GetShop data
local shopClock = 0
local activeTab = "vehicles" -- phase 6: the Garage opens on VEHICLES (falls back to the first tab when hidden)
local isOpen = false
local busy = false
local tickers: { () -> () } = {}
local lastTick = 0
local lastShopFetch = -math.huge

---------------------------------------------------------------------------------------------------- helpers

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

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

local function text(parent: Instance, name: string, str: string, font: Enum.Font?, maxSize: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font or Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = CREAM
	l.Text = str
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = maxSize or 22
	c.MinTextSize = 8
	c.Parent = l
	return l
end

local function button(parent: Instance, name: string, str: string, color: Color3, enabled: boolean?): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.BackgroundColor3 = color
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.TextColor3 = if enabled == false then MUTED else CREAM
	b.Text = str
	b.AutoButtonColor = enabled ~= false
	-- Status buttons (OWNED, SOLD OUT, LOCKED) are not stops on the gamepad path.
	b.Selectable = enabled ~= false
	b.BackgroundTransparency = if enabled == false then 0.45 else 0
	b.Parent = parent
	corner(b, 8)
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = 18
	c.MinTextSize = 8
	c.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = b
	-- Live buttons tok like wood; status buttons (OWNED, SOLD OUT, LOCKED) knock twice and shake their heads.
	UiSound.bind(b, if enabled == false then "deny" else "tap")
	return b
end

local function toast(msg: string, color: Color3?, seconds: number?)
	-- Thin wrapper over NotifyKit: on the open panel's own plank (tagged, so closing the panel clears it), else the hub lane.
	if isOpen then
		NotifyKit.toast(msg, { kind = "info", color = color or CREAM, seconds = seconds, rect = toastRect, tag = "garage" })
		return
	end
	pcall(TrackFlow.toast, msg, color, seconds)
end

local function invoke(action: string, ...: any): any
	local remote = request
	if not remote then
		return { ok = false, reason = "unavailable" }
	end
	local args = table.pack(...)
	local ok, reply = pcall(function(): any
		return remote:InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if not ok or type(reply) ~= "table" then
		return { ok = false, reason = "unavailable" }
	end
	return reply
end

local function serverNow(data: any, at: number): number
	local t = if type(data) == "table" and type(data.serverTime) == "number" then data.serverTime else os.time()
	return t + (os.clock() - at)
end

local function gears(): number
	local g = LocalPlayer:GetAttribute("Gears")
	if type(g) == "number" then
		return g
	end
	return if st and type(st.gears) == "number" then st.gears else 0
end

local function garageEnabled(): boolean
	return workspace:GetAttribute("GarageEnabled") == true
end

local function openContext(): GarageModel.OpenContext
	local go = RaceAttr.mine("RaceGoTime")
	local mode = RaceAttr.mine("RaceMode")
	local bstate = RaceAttr.mine("BattleState")
	return {
		garageEnabled = garageEnabled(),
		mode = if type(mode) == "string" then mode else nil,
		switching = workspace:GetAttribute("TrackSwitching") == true,
		now = workspace:GetServerTimeNow(),
		goTime = if type(go) == "number" then go else nil,
		finished = LocalPlayer:GetAttribute("RaceFinished") == true,
		battleState = if type(bstate) == "string" then bstate else nil,
	}
end

local function hasPass(key: string): boolean
	if st and type(st.passes) == "table" then
		for _, k in st.passes do
			if k == key then
				return true
			end
		end
	end
	return false
end

local function visibleProduct(key: string): any?
	if st and type(st.products) == "table" then
		for _, p in st.products do
			if p.key == key then
				return p
			end
		end
	end
	return nil
end

local function configProduct(key: string): any?
	for _, p in MonetizationConfig.PRODUCTS do
		if p.key == key then
			return p
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------- data

local render: () -> ()

local function fetchState(): boolean
	local reply = invoke("GetState")
	if reply.ok and type(reply.data) == "table" then
		st = reply.data
		stClock = os.clock()
		if type(st.owned) ~= "table" then
			st.owned = {}
		end
		if type(st.loadout) ~= "table" then
			st.loadout = {}
		end
		return st.enabled ~= false
	end
	return false
end

local function fetchShop()
	lastShopFetch = os.clock()
	local reply = invoke("GetShop")
	if reply.ok and type(reply.data) == "table" then
		shop = reply.data
		shopClock = os.clock()
	end
end

-- One request at a time (a double tap never buys twice); a rejection shows the server's reason in plain words.
local function act(action: string, onOk: ((any) -> ())?, ...: any)
	if busy then
		return
	end
	busy = true
	local args = table.pack(...)
	task.spawn(function()
		local reply = invoke(action, table.unpack(args, 1, args.n))
		busy = false
		if reply.ok then
			if onOk then
				onOk(reply.data)
			end
		else
			if os.clock() - UiSound.lastPlayed("deny") > 1 then
				UiSound.play("deny")
			end
			toast(GarageModel.reasonText(reply.reason), Color3.fromRGB(255, 190, 160))
		end
		if isOpen then
			render()
		end
	end)
end

---------------------------------------------------------------------------------------------------- open / close

-- fetch: refresh the shop when the tab needs it and the copy is missing or older than 20 s (the restock countdown
-- refetches at 0:00), so tab hopping never spends the request bucket.
local function setTab(id: string, fetch: boolean?)
	activeTab = id
	for tid, b in tabButtons do
		local on = tid == id
		b.BackgroundColor3 = if on then BRASS else WOOD_DARK
		b.TextColor3 = if on then WOOD_DARK else CREAM
	end
	local needsShop = id ~= "winpass" and id ~= "daily" and id ~= "vehicles"
	if fetch ~= false and needsShop and (shop == nil or os.clock() - shopClock > 20) and os.clock() - lastShopFetch > 2 then
		task.spawn(function()
			fetchShop()
			if isOpen then
				render()
			end
		end)
	end
	render()
end

local function close()
	if overlay then
		overlay:Destroy()
		overlay = nil
	end
	isOpen = false
	panel.Visible = false
	NotifyKit.dismissTag("garage")
	GarageTurntable.close() -- REMARKABLE 27
	UiSound.setKind(hubButton, "tab")
	ContextActionService:UnbindAction("SkyRallyGarageClose")
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		-- Hand gamepad selection back to where it was (the results GARAGE tab) when that is still on screen.
		local prev = prevSelection
		GuiService.SelectedObject = if prev and prev.Parent and prev.Visible and prev:IsDescendantOf(LocalPlayer) then prev else nil
	end
	prevSelection = nil
end

local function closeAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and isOpen then
		UiSound.play("back")
		if overlay then
			overlay:Destroy()
			overlay = nil
		else
			close()
		end
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

function Garage.open(tab: string?)
	local ok, why = GarageModel.canOpen(openContext())
	if not ok then
		if why ~= "disabled" then
			UiSound.play("deny")
			toast(if why == "busy" then "The Garage opens after your race" else GarageModel.reasonText(why), Color3.fromRGB(255, 214, 160))
		end
		return
	end
	pcall(TrackFlow.closeBoard)
	local sel = GuiService.SelectedObject
	prevSelection = if sel and not sel:IsDescendantOf(panel) then sel else nil
	isOpen = true
	av = nil -- the VEHICLES tab refetches (Cash and ladders move between visits)
	panel.Visible = true
	UiSound.setKind(hubButton, "back")
	if tab then
		activeTab = tab
	end
	-- B closes; Y (and keyboard B) would toggle the Adventure board under the panel, so they close the Garage too.
	ContextActionService:BindActionAtPriority(
		"SkyRallyGarageClose",
		closeAction,
		false,
		Enum.ContextActionPriority.High.Value + 10,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonY,
		Enum.KeyCode.B
	)
	setTab(activeTab, false)
	if UserInputService.GamepadEnabled or GuiService:IsTenFootInterface() then
		GuiService.SelectedObject = tabButtons[activeTab]
	end
	task.spawn(function()
		if not fetchState() then
			close()
			return
		end
		fetchShop()
		if isOpen then
			render()
		end
	end)
end

-- True while the panel is up (the login popup waits for it to close).
function Garage.isOpen(): boolean
	return isOpen
end

function Garage.toggle()
	if isOpen then
		close()
	else
		Garage.open()
	end
end

---------------------------------------------------------------------------------------------------- overlay pickers

-- A modal list over the content: pick `need` options (a racer to gift, Season 1 liveries for a set). need = 1 picks on
-- tap; more shows CONFIRM once enough are toggled.
local function openPicker(title: string, options: { { id: string, label: string } }, need: number, onDone: ({ string }) -> ())
	if overlay then
		overlay:Destroy()
	end
	local o = Instance.new("Frame")
	o.Name = "Picker"
	o.BackgroundColor3 = WOOD_DARK
	o.Position = content.Position
	o.Size = content.Size
	o.ZIndex = 40
	o.SelectionGroup = true
	o.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	o.Parent = panel
	corner(o, 10)
	stroke(o, BRASS, 2)
	overlay = o
	local t = text(o, "Title", title, Enum.Font.GothamBlack, 20)
	t.Position = UDim2.fromOffset(10, 4)
	t.Size = UDim2.new(1, -130, 0, 30)
	t.ZIndex = 41
	local cancel = button(o, "Cancel", "CANCEL", WOOD, true)
	cancel.Position = UDim2.new(1, -114, 0, 2)
	cancel.Size = UDim2.fromOffset(108, 44)
	cancel.ZIndex = 41
	UiSound.setKind(cancel, "back")
	cancel.Activated:Connect(function()
		o:Destroy()
		overlay = nil
	end)
	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(6, 50)
	list.Size = UDim2.new(1, -12, 1, if need > 1 then -104 else -56)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ScrollBarThickness = 6
	list.ZIndex = 41
	list.Parent = o
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(170, 44)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = list
	local chosen: { [string]: boolean } = {}
	local count = 0
	local confirm: TextButton? = nil
	local function picked(): { string }
		local out = {}
		for _, opt in options do
			if chosen[opt.id] then
				table.insert(out, opt.id)
			end
		end
		return out
	end
	for i, opt in options do
		local b = button(list, "Opt_" .. opt.id, opt.label, WOOD, true)
		b.LayoutOrder = i
		b.ZIndex = 42
		b.Activated:Connect(function()
			if need == 1 then
				o:Destroy()
				overlay = nil
				onDone({ opt.id })
				return
			end
			if chosen[opt.id] then
				chosen[opt.id] = nil
				count -= 1
			elseif count < need then
				chosen[opt.id] = true
				count += 1
			end
			b.BackgroundColor3 = if chosen[opt.id] then GREEN else WOOD
			if confirm then
				confirm.Text = string.format("CONFIRM %d/%d", count, need)
				confirm.BackgroundTransparency = if count == need then 0 else 0.45
				UiSound.setKind(confirm, if count == need then "confirm" else "deny")
			end
		end)
	end
	if need > 1 then
		local c = button(o, "Confirm", string.format("CONFIRM 0/%d", need), GREEN, true)
		c.AnchorPoint = Vector2.new(0.5, 1)
		c.Position = UDim2.new(0.5, 0, 1, -6)
		c.Size = UDim2.fromOffset(200, 44)
		c.BackgroundTransparency = 0.45
		c.ZIndex = 41
		UiSound.setKind(c, "deny") -- until enough are picked
		c.Activated:Connect(function()
			if count == need then
				o:Destroy()
				overlay = nil
				onDone(picked())
			end
		end)
		confirm = c
	end
	if #options == 0 then
		local e = text(list, "Empty", "Nothing to pick right now", Enum.Font.GothamBold, 16)
		e.Size = UDim2.fromOffset(300, 30)
	end
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = cancel
	end
end

-- Robux products (store on + real id only). A set product asks which liveries first; a gift asks for the racer.
local function setChoices(base: any, recipientOwned: { [string]: boolean }?, onDone: ({ string }?) -> ())
	local grants = base and base.grants or {}
	if not grants.chooseFromSet then
		onDone(nil)
		return
	end
	local owned = recipientOwned or GarageModel.ownedSet(st and st.owned)
	local options = {}
	for _, c in MonetizationConfig.COSMETICS do
		if c.set == grants.chooseFromSet and not owned[c.key] then
			table.insert(options, { id = c.key, label = c.name })
		end
	end
	local need = math.min(grants.count or 1, #options)
	if need <= 0 then
		toast("You own every tint in this set", MUTED)
		return
	end
	openPicker(string.format("PICK %d", need), options, need, onDone)
end

local function buyProduct(p: any)
	local base = configProduct(p.key)
	setChoices(base, nil, function(choices: { string }?)
		act("PromptProduct", nil, p.key, choices)
	end)
end

local function giftProduct(twin: any, baseKey: string)
	local options = {}
	for _, pl in Players:GetPlayers() do
		if pl ~= LocalPlayer then
			table.insert(options, { id = tostring(pl.UserId), label = pl.DisplayName })
		end
	end
	openPicker("GIFT TO A RACER", options, 1, function(ids: { string })
		local uid = tonumber(ids[1])
		if not uid then
			return
		end
		-- The recipient's ownership is the server's call (recipientOwns); offer the whole set to pick from.
		setChoices(configProduct(baseKey), {}, function(choices: { string }?)
			act("Gift", function()
				toast("Gift on its way", GOLD)
			end, twin.key, uid, choices)
		end)
	end)
end

---------------------------------------------------------------------------------------------------- rows

local L: GarageModel.Layout

local function section(order: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Section" .. order
	f.BackgroundTransparency = 1
	f.LayoutOrder = order
	f.Size = UDim2.new(1, -6, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.Parent = content
	return f
end

local function grid(order: number, columns: number?): Frame
	local f = section(order)
	local g = Instance.new("UIGridLayout")
	local cols = columns or L.columns
	local w = if cols == L.columns then L.rowW else math.floor((L.content.w - 6 - L.gap * (cols - 1)) / cols)
	g.CellSize = UDim2.fromOffset(w, L.rowH)
	g.CellPadding = UDim2.fromOffset(L.gap, L.gap)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.FillDirection = Enum.FillDirection.Horizontal
	g.Parent = f
	return f
end

-- A one-line plank across the content (countdowns, season line). Returns the label for tickers.
local function strip(order: number, str: string, color: Color3?): (Frame, TextLabel)
	local f = Instance.new("Frame")
	f.Name = "Strip" .. order
	f.LayoutOrder = order
	f.BackgroundColor3 = WOOD_DARK
	f.BackgroundTransparency = 0.25
	f.Size = UDim2.new(1, -6, 0, 30)
	f.Parent = content
	corner(f, 8)
	local l = text(f, "Text", str, Enum.Font.GothamBold, 16)
	l.Position = UDim2.fromOffset(10, 3)
	l.Size = UDim2.new(1, -20, 1, -6)
	l.TextColor3 = color or CREAM
	return f, l
end

local function row(parent: Instance, order: number, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.LayoutOrder = order
	f.BackgroundColor3 = WOOD_ROW
	f.Parent = parent
	corner(f, 8)
	stroke(f, Color3.fromRGB(150, 110, 70), 1)
	return f
end

-- 44 px swatch: livery stripes, trail gradient, or a preview button for horns and emotes.
local function swatch(parent: Instance, c: any): GuiObject
	local kind = c and c.kind
	if kind == "horn" or kind == "emote" then
		local b = button(parent, "Preview", if kind == "horn" then "PLAY" else "TRY", ORANGE, true)
		b.Position = UDim2.fromOffset(4, 4)
		b.Size = UDim2.fromOffset(44, 44)
		b.Activated:Connect(function()
			if kind == "horn" then
				Cosmetics.previewHorn(c.key)
				GarageTurntable.honk(c.key, false) -- REMARKABLE 27: the car on the turntable honks along
			else
				Cosmetics.previewEmote(c.key)
			end
		end)
		return b
	end
	local f = Instance.new("Frame")
	f.Name = "Swatch"
	f.Position = UDim2.fromOffset(4, 4)
	f.Size = UDim2.fromOffset(44, 44)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.ClipsDescendants = true
	f.Parent = parent
	corner(f, 8)
	stroke(f, WOOD_DARK, 1.5)
	if kind == "livery" and c.livery then
		-- REMARKABLE 27: tap the swatch to try the livery on the turntable.
		local try = Instance.new("TextButton")
		try.Name = "Try"
		try.BackgroundTransparency = 1
		try.Text = ""
		try.Size = UDim2.fromScale(1, 1)
		try.ZIndex = 3
		try.Parent = f
		UiSound.bind(try, "tap")
		try.Activated:Connect(function()
			GarageTurntable.preview(c.key)
		end)
		local parts: { { any } } = { { c.livery.primary, 0, 0.55 }, { c.livery.accent, 0.55, 0.28 }, { c.livery.trim, 0.83, 0.17 } }
		for i, p in parts do
			local s = Instance.new("Frame")
			s.Name = "Band" .. i
			s.BorderSizePixel = 0
			s.BackgroundColor3 = rgb(p[1])
			s.Position = UDim2.fromScale(p[2] :: number, 0)
			s.Size = UDim2.fromScale(p[3] :: number, 1)
			s.Parent = f
		end
	elseif kind == "trail" and c.trail then
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new(rgb(c.trail.color0), rgb(c.trail.color1))
		g.Parent = f
	end
	return f
end

-- Name + sub line between the swatch and the buttons.
local function rowText(r: Frame, title: string, sub: string, titleColor: Color3?, buttonsW: number)
	local n = text(r, "Name", title, Enum.Font.GothamBlack, 18)
	n.Position = UDim2.fromOffset(54, 4)
	n.Size = UDim2.new(1, -(58 + buttonsW), 0, 24)
	n.TextColor3 = titleColor or CREAM
	n.TextTruncate = Enum.TextTruncate.AtEnd
	local s = text(r, "Sub", sub, Enum.Font.GothamBold, 13)
	s.Position = UDim2.fromOffset(54, 28)
	s.Size = UDim2.new(1, -(58 + buttonsW), 0, 18)
	s.TextColor3 = MUTED
	s.TextTruncate = Enum.TextTruncate.AtEnd
end

-- Right-aligned buttons, 44 px tall; widths in px, laid out right to left.
local function rowButtons(r: Frame, specs: { any }): number
	local x = 4
	local total = 0
	for i = #specs, 1, -1 do
		local sp = specs[i]
		local b = button(r, "Button" .. i, sp.label, sp.color, sp.enabled)
		b.AnchorPoint = Vector2.new(1, 0)
		b.Position = UDim2.new(1, -x, 0, 4)
		b.Size = UDim2.fromOffset(sp.w, 44)
		if sp.enabled and sp.sound then
			UiSound.setKind(b, sp.sound)
		end
		local tap = sp.onTap
		if sp.enabled and tap then
			b.Activated:Connect(tap)
		end
		x += sp.w + 4
		total += sp.w + 4
	end
	return total
end

local function buy(key: string)
	act("Buy", function(d: any)
		if type(d) ~= "table" then
			return
		end
		table.insert(st.owned, d.key)
		st.gears = d.gears
		if shop and type(shop.slots) == "table" then
			for _, s in shop.slots do
				if s.slot == d.slot then
					if type(s.stock) == "number" then
						s.stock = math.max(0, s.stock - 1)
						s.soldOut = s.stock == 0
					end
				end
				if s.key == d.key then
					s.owned = true
				end
			end
		end
		local c = GarageModel.cosmetic(d.key)
		local tabLabel = "the Garage"
		for _, t in GarageModel.TABS do
			if c and t.kind == c.kind then
				tabLabel = t.label
			end
		end
		UiSound.play("purchase")
		toast(string.format("%s is yours - equip it in %s", if c then c.name else d.key, tabLabel), GOLD)
	end, key)
end

local function equip(slot: string, key: string)
	act("Equip", function(d: any)
		if type(d) == "table" then
			st.loadout[slot] = d.key
			if slot == "carLivery" or slot == "planeLivery" then
				GarageTurntable.preview(tostring(d.key or "")) -- REMARKABLE 27: wear what was equipped ("" = default)
			end
		end
	end, slot, key)
end

local function renderItems(kind: string)
	local view: GarageModel.View = {
		owned = GarageModel.ownedSet(st.owned),
		loadout = st.loadout,
		gears = gears(),
		shop = if shop then shop.slots else nil,
		amulet = {
			keys = tonumber(LocalPlayer:GetAttribute("Keys")) or 0,
			fragments = tonumber(LocalPlayer:GetAttribute("BattleFragments")) or 0,
		},
	}
	local rows = GarageModel.itemRows(kind, view)
	local plus = hasPass("garagePlus")
	GarageTurntable.mount(section(0), L.content.w - 6, L.compact) -- REMARKABLE 27: the turntable, first in the list
	local order = 1
	if plus then
		-- Garage+ presets: save the whole loadout to a slot, load it back in one tap.
		local bar = section(order)
		bar.AutomaticSize = Enum.AutomaticSize.None
		bar.Size = UDim2.new(1, -6, 0, 44)
		local hl = Instance.new("UIListLayout")
		hl.FillDirection = Enum.FillDirection.Horizontal
		hl.Padding = UDim.new(0, L.gap)
		hl.SortOrder = Enum.SortOrder.LayoutOrder
		hl.Parent = bar
		local bw = math.floor((L.content.w - 6 - 5 * L.gap) / 6)
		for i = 1, 3 do
			local lb = button(bar, "Load" .. i, "LOAD " .. i, GREEN, true)
			lb.LayoutOrder = i
			lb.Size = UDim2.fromOffset(bw, 44)
			UiSound.setKind(lb, "confirm")
			lb.Activated:Connect(function()
				act("LoadPreset", function()
					fetchState()
				end, i)
			end)
		end
		for i = 1, 3 do
			local sb = button(bar, "Save" .. i, "SAVE " .. i, WOOD_DARK, true)
			sb.LayoutOrder = 3 + i
			sb.Size = UDim2.fromOffset(bw, 44)
			UiSound.setKind(sb, "confirm")
			sb.Activated:Connect(function()
				act("SavePreset", function()
					toast("Loadout saved to slot " .. i, GOLD)
				end, i)
			end)
		end
		order += 1
	end
	local g = grid(order)
	for i, r in rows do
		local f = row(g, i, "Item_" .. r.key)
		swatch(f, r.cosmetic)
		local specs: { any } = {}
		if r.owned then
			for _, slot in ipairs((GarageModel.KIND_SLOTS[kind] or {}) :: { string }) do
				local on = r.equipped[slot] == true
				local label = GarageModel.SLOT_LABEL[slot] or "EQUIP"
				table.insert(specs, {
					label = if on then (if kind == "livery" then label .. " ON" else "EQUIPPED") else label,
					color = if on then GREEN else WOOD,
					enabled = true,
					w = if kind == "livery" then 76 else 104,
					sound = if on then "back" else "confirm",
					-- Tapping what is equipped takes it off.
					onTap = function()
						equip(slot, if on then "" else r.key)
					end,
				})
			end
			if plus then
				local fav = st.favorites and st.favorites[r.key] == true
				table.insert(specs, 1, {
					label = if fav then "FAV ON" else "FAV",
					color = if fav then BRASS else WOOD_DARK,
					enabled = true,
					w = 60,
					onTap = function()
						act("SetFavorite", function()
							st.favorites = st.favorites or {}
							st.favorites[r.key] = if fav then nil else true
						end, r.key, not fav)
					end,
				})
			end
		elseif r.buyPrice then
			table.insert(specs, {
				label = "BUY " .. GarageModel.formatGears(r.buyPrice),
				color = if r.affordable then ORANGE else DIM,
				enabled = true,
				sound = if r.affordable then "tap" else "deny",
				w = 116,
				onTap = function()
					buy(r.key)
				end,
			})
		end
		local bw = rowButtons(f, specs)
		local sub = string.upper(r.rarity)
		if r.owned then
			sub ..= if r.anyEquipped then "  -  EQUIPPED" else "  -  OWNED"
		elseif r.buyPrice then
			sub ..= if r.deal then "  -  DAILY DEAL" else "  -  IN THE SHOP NOW"
			if not r.affordable then
				sub ..= string.format("  -  %s MORE CASH", GarageModel.formatGears(r.buyPrice - view.gears))
			end
		elseif r.note then
			sub ..= "  -  " .. r.note
		end
		rowText(f, r.name, sub, rgb(GarageModel.RARITY_RGB[r.rarity] or { 250, 242, 222 }), bw)
	end
	if #rows == 0 then
		strip(order + 1, "Nothing here yet", MUTED)
	end
end

---------------------------------------------------------------------------------------------------- vehicles (phase 6)

local function fetchAvatars()
	local reply = invoke("GetAvatars")
	if reply.ok and type(reply.data) == "table" then
		av = reply.data
	end
end

local AV_TONE: { [string]: Color3 } = { on = GREEN, go = WOOD, buy = ORANGE, dim = DIM, robux = ROBUX }

local function avatarTap(v: any, action: string)
	if action == "select" then
		act("SelectAvatar", function(d: any)
			if type(d) == "table" and av then
				av.selected[d.class] = d.key
				for _, row in av.classes[d.class] or {} do
					row.selected = row.key == d.key
				end
				UiSound.play("confirm")
				toast(string.format("%s ready for your next race", v.name), GOLD)
			end
		end, v.key)
	elseif action == "buy" then
		act("BuyAvatar", function(d: any)
			if type(d) == "table" then
				if st then
					st.gears = d.gears
				end
				UiSound.play("purchase")
				pcall(NotifyKit.fromSpec, "avatar_unlock", { name = d.name })
				fetchAvatars()
				avFocus = d.key
			end
		end, v.key)
	elseif action == "robux" then
		-- No Robux avatar product exists yet (ids are bound only from the owner's universe): the server answers "Coming soon".
		act("BuyAvatar", nil, v.key)
	end
end

local function renderVehicles()
	if not av then
		strip(1, "Loading your vehicles...", MUTED)
		task.spawn(function()
			fetchAvatars()
			if isOpen and activeTab == "vehicles" and av then
				render()
			end
		end)
		return
	end
	-- Class switch: the track picks plane or car; the player picks the model inside the class.
	local bar = section(1)
	bar.AutomaticSize = Enum.AutomaticSize.None
	bar.Size = UDim2.new(1, -6, 0, 44)
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.Padding = UDim.new(0, L.gap)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = bar
	local classes: { string } = {}
	for _, c in AvatarConfig.CLASSES do
		if not AvatarConfig.HIDDEN_CLASSES[c] and type(av.classes) == "table" and av.classes[c] then
			table.insert(classes, c)
		end
	end
	local bw = math.floor((L.content.w - 6 - (#classes - 1) * L.gap) / math.max(1, #classes))
	for i, c in classes do
		local on = c == avClass
		local b = button(bar, "Class_" .. c, AvatarConfig.CLASS_LABEL[c] or string.upper(c), if on then BRASS else WOOD_DARK, true)
		b.TextColor3 = if on then WOOD_DARK else CREAM
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(bw, 44)
		b.Activated:Connect(function()
			avClass = c
			avFocus = nil
			render()
		end)
	end
	local rows = (type(av.classes) == "table" and av.classes[avClass]) or {}
	local g = grid(2)
	for i, v in rows do
		local f = row(g, i, "Avatar_" .. v.key)
		-- Swatch: rarity colour with the class initial until the owner's thumbnails land (art in NotifySkin.PICKER).
		local sw = Instance.new("TextButton")
		sw.Name = "Looks"
		sw.Position = UDim2.fromOffset(4, 4)
		sw.Size = UDim2.fromOffset(44, 44)
		sw.BackgroundColor3 = rgb(GarageModel.AVATAR_RARITY_RGB[v.rarity] or { 226, 220, 206 })
		sw.Font = Enum.Font.GothamBlack
		sw.TextScaled = true
		sw.TextColor3 = WOOD_DARK
		local unlockedLooks = GarageModel.ladderCount(v)
		sw.Text = if v.owned then tostring(unlockedLooks) else (if avClass == "plane" then "P" else "C")
		sw.Parent = f
		corner(sw, 8)
		UiSound.bind(sw, "tap")
		sw.Activated:Connect(function()
			avFocus = if avFocus == v.key then nil else v.key
			render()
		end)
		local a = GarageModel.avatarAction(v)
		local specs: { any } = {}
		if v.owned then
			table.insert(specs, {
				label = "LOOKS",
				color = if avFocus == v.key then BRASS else WOOD_DARK,
				enabled = true,
				w = 76,
				onTap = function()
					avFocus = if avFocus == v.key then nil else v.key
					render()
				end,
			})
		end
		table.insert(specs, {
			label = a.label,
			color = AV_TONE[a.tone] or WOOD,
			enabled = a.action ~= nil,
			w = 116,
			sound = if a.tone == "dim" then "deny" else "confirm",
			onTap = if a.action
				then function()
					avatarTap(v, a.action :: string)
				end
				else nil,
		})
		local bwid = rowButtons(f, specs)
		rowText(f, v.name, GarageModel.avatarSub(v), rgb(GarageModel.AVATAR_RARITY_RGB[v.rarity] or { 250, 242, 222 }), bwid)
	end
	if #rows == 0 then
		strip(3, "Nothing here yet", MUTED)
	end
	-- LOOKS: the focused avatar's reskin / tint ladder, earned by racing it (never sold).
	local focus: any = nil
	for _, v in rows do
		if v.key == avFocus then
			focus = v
		end
	end
	if focus and focus.owned then
		local n, total = GarageModel.ladderCount(focus)
		strip(4, string.format("%s LOOKS %d/%d  -  %d RACES  %d 1ST  %d KEYS", string.upper(focus.name), n, total, focus.progress.races, focus.progress.wins, focus.progress.keys), GOLD)
		local lg = grid(5)
		local wornAny = false
		for i, step in focus.ladder do
			wornAny = wornAny or step.worn
			local f = row(lg, i, "Step_" .. step.id)
			local spec = {
				label = if step.worn then "WORN" elseif step.unlocked then "WEAR" else "LOCKED",
				color = if step.worn then GREEN elseif step.unlocked then WOOD else DIM,
				enabled = step.unlocked,
				w = 104,
				onTap = function()
					act("WearSkin", function()
						fetchAvatars()
					end, focus.key, if step.worn then "" else step.id)
				end,
			}
			local bwid = rowButtons(f, { spec })
			rowText(f, string.format("%s %s", step.name, if step.kind == "tint" then "TINT" else "RESKIN"), if step.unlocked then "UNLOCKED" else step.need, nil, bwid)
		end
		if wornAny then
			local f = row(lg, #focus.ladder + 1, "Step_base")
			local bwid = rowButtons(f, {
				{ label = "WEAR", color = WOOD, enabled = true, w = 104, onTap = function()
					act("WearSkin", function()
						fetchAvatars()
					end, focus.key, "")
				end },
			})
			rowText(f, "BASE LOOK", "The avatar's own paint", nil, bwid)
		end
	end
end

local function renderShop()
	if not shop then
		strip(1, "Loading the shop...", MUTED)
		return
	end
	local _, l = strip(1, "", GOLD)
	if shop.rotation == false then
		l.Text = "EVERY ITEM IN STOCK"
	else
		table.insert(tickers, function()
			local now = serverNow(shop, shopClock)
			local left = (shop.restockAt or now) - now
			l.Text = string.format("RESTOCK IN %s   -   DAILY DEAL ENDS IN %s", GarageModel.formatCountdown(left), GarageModel.formatCountdown((shop.dealEndsAt or now) - now))
			-- A new window: fetch the new stock (at most every 5 s while the clock sits on 0:00).
			if left <= 0 and os.clock() - lastShopFetch > 5 then
				task.spawn(function()
					fetchShop()
					if isOpen and activeTab == "shop" then
						render()
					end
				end)
			end
		end)
	end
	local g = grid(2)
	for i, r in GarageModel.shopRows(shop.slots, gears()) do
		local f = row(g, i, "Shop_" .. r.slot)
		swatch(f, r.cosmetic)
		local specs: { any } = {}
		if r.owned then
			table.insert(specs, { label = "OWNED", color = GREEN, enabled = false, w = 104 })
		elseif r.soldOut then
			table.insert(specs, { label = "SOLD OUT", color = DIM, enabled = false, w = 104 })
		else
			table.insert(specs, {
				label = "BUY " .. GarageModel.formatGears(r.price),
				color = if r.affordable then ORANGE else DIM,
				enabled = true,
				sound = if r.affordable then "tap" else "deny",
				w = 116,
				onTap = function()
					buy(r.key)
				end,
			})
		end
		local bw = rowButtons(f, specs)
		local sub = r.stockText
		if r.deal then
			sub = string.format("DAILY DEAL -%d%%  (was %s)  -  %s", math.floor(MonetizationConfig.SHOP.dealDiscount * 100 + 0.5), GarageModel.formatGears(r.basePrice), sub)
		else
			sub = string.upper(r.rarity) .. " " .. GarageModel.kindLabel(r.kind) .. "  -  " .. sub
		end
		rowText(f, r.name, sub, rgb(GarageModel.RARITY_RGB[r.rarity] or { 250, 242, 222 }), bw)
	end
	-- Robux products: only rows the server lists (store on and a real id), priced from GetProductInfo.
	local products = if st and type(st.products) == "table" then st.products else {}
	local base: { any } = {}
	for _, p in products do
		if not p.giftTwinOf then
			table.insert(base, p)
		end
	end
	if #base > 0 then
		strip(3, "STORE", GOLD)
		local pg = grid(4)
		for i, p in base do
			local f = row(pg, i, "Product_" .. p.key)
			local active = p.kind == "Pass" and hasPass(p.key)
			local priced = type(p.price) == "number"
			local specs: { any } = {}
			if active then
				table.insert(specs, { label = "ACTIVE", color = GREEN, enabled = false, w = 104 })
			else
				table.insert(specs, {
					label = if priced then "R$ " .. tostring(p.price) else "...",
					color = ROBUX,
					enabled = priced,
					w = 104,
					onTap = function()
						buyProduct(p)
					end,
				})
			end
			for _, twin in products do
				if twin.giftTwinOf == p.key and type(twin.price) == "number" then
					table.insert(specs, 1, {
						label = "GIFT",
						color = Color3.fromRGB(176, 52, 120),
						enabled = true,
						w = 72,
						onTap = function()
							giftProduct(twin, p.key)
						end,
					})
				end
			end
			local icon = Instance.new("Frame")
			icon.Position = UDim2.fromOffset(4, 4)
			icon.Size = UDim2.fromOffset(44, 44)
			icon.BackgroundColor3 = ROBUX
			icon.Parent = f
			corner(icon, 8)
			local bw = rowButtons(f, specs)
			rowText(f, p.label, if p.kind == "Pass" then "GAME PASS" else "ROBUX", CREAM, bw)
		end
	elseif st and st.storeEnabled == true then
		-- Store on but nothing bound in this universe yet: one quiet line, never a dead prompt.
		strip(3, "ROBUX STORE  -  COMING SOON", DIM)
	end
end

local WP_STATUS: { [string]: { label: string, color: Color3, enabled: boolean } } = {
	claim = { label = "CLAIM", color = GREEN, enabled = true },
	claimed = { label = "CLAIMED", color = WOOD_DARK, enabled = false },
	locked = { label = "LOCKED", color = DIM, enabled = false },
	premium = { label = "PREMIUM", color = BRASS, enabled = false },
	over = { label = "ENDED", color = DIM, enabled = false },
}

local function renderWinPass()
	local wp = st.winPass or {}
	local f, l = strip(1, "", GOLD)
	table.insert(tickers, function()
		if wp.season == nil then
			l.Text = "The season is over - the next one starts soon"
			return
		end
		local left = (wp.seasonEndsAt or 0) - serverNow(st, stClock)
		l.Text = string.format("SEASON %s  -  %d RACES  -  ENDS IN %s%s", tostring(wp.season), wp.races or 0, GarageModel.formatCountdown(left), if wp.premium then "  -  PREMIUM" else "")
	end)
	local prem = visibleProduct(MonetizationConfig.WIN_PASS.premiumProduct)
	if prem and not wp.premium and type(prem.price) == "number" then
		f.Size = UDim2.new(1, -6, 0, 50)
		l.Size = UDim2.new(1, -150, 1, -6)
		local b = button(f, "GetPremium", "PREMIUM R$ " .. tostring(prem.price), ROBUX, true)
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -4, 0.5, 0)
		b.Size = UDim2.fromOffset(140, 44)
		b.Activated:Connect(function()
			buyProduct(prem)
		end)
	end
	local g = grid(2, 1)
	for i, r in GarageModel.winPassRows(wp) do
		local f2 = row(g, i, "Tier_" .. r.tier)
		local tl = text(f2, "Tier", "TIER " .. r.tier, Enum.Font.GothamBlack, 18)
		tl.Position = UDim2.fromOffset(8, 4)
		tl.Size = UDim2.fromOffset(84, 24)
		tl.TextColor3 = if r.reached then GOLD else CREAM
		local pl = text(f2, "Progress", string.format("%d/%d RACES", math.min(wp.races or 0, r.tier), r.tier), Enum.Font.GothamBold, 13)
		pl.Position = UDim2.fromOffset(8, 28)
		pl.Size = UDim2.fromOffset(84, 18)
		pl.TextColor3 = MUTED
		local cellW = math.floor((L.content.w - 6 - 100) / 2)
		for ci, column in { "free", "premium" } do
			local cell = (r :: any)[column]
			local holder = Instance.new("Frame")
			holder.Name = column
			holder.BackgroundTransparency = 1
			holder.Position = UDim2.fromOffset(96 + (ci - 1) * cellW, 0)
			holder.Size = UDim2.new(0, cellW, 1, 0)
			holder.Parent = f2
			if cell then
				local spec = WP_STATUS[cell.status] or WP_STATUS.locked
				local b = button(holder, "Claim", spec.label, spec.color, spec.enabled)
				b.AnchorPoint = Vector2.new(1, 0)
				b.Position = UDim2.new(1, -4, 0, 4)
				b.Size = UDim2.fromOffset(92, 44)
				if spec.enabled then
					b.Activated:Connect(function()
						act("ClaimWinPass", function(d: any)
							local claimed = if column == "free" then "claimedFree" else "claimedPremium"
							wp[claimed] = wp[claimed] or {}
							wp[claimed][tostring(r.tier)] = true
							UiSound.play("purchase")
							if type(d) == "table" and d.key then
								table.insert(st.owned, d.key)
								UiSound.play("unlock")
								local c = GarageModel.cosmetic(d.key)
								toast(string.format("%s unlocked!", if c then c.name else d.key), GOLD)
							end
						end, r.tier, column)
					end)
				end
				local n = text(holder, "Name", cell.name, Enum.Font.GothamBlack, 15)
				n.Position = UDim2.fromOffset(4, 4)
				n.Size = UDim2.new(1, -104, 0, 22)
				n.TextTruncate = Enum.TextTruncate.AtEnd
				local s = text(holder, "Column", (if column == "free" then "FREE" else "PREMIUM") .. "  -  " .. GarageModel.kindLabel(cell.kind), Enum.Font.GothamBold, 12)
				s.Position = UDim2.fromOffset(4, 27)
				s.Size = UDim2.new(1, -104, 0, 18)
				s.TextColor3 = if column == "premium" then GOLD else MUTED
			end
		end
	end
end

local function renderDaily()
	local daily = st.daily or {}
	local _, l = strip(1, "", GOLD)
	table.insert(tickers, function()
		local left = (daily.resetsAt or 0) - serverNow(st, stClock)
		l.Text = string.format("DAILY STREAK: %d %s  -  NEW DAY IN %s", daily.streak or 0, if (daily.streak or 0) == 1 then "DAY" else "DAYS", GarageModel.formatCountdown(left))
	end)
	local strip7 = section(2)
	strip7.AutomaticSize = Enum.AutomaticSize.None
	strip7.Size = UDim2.new(1, -6, 0, 84)
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.Padding = UDim.new(0, L.gap)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = strip7
	for _, c in GarageModel.dailyCells(daily) do
		local cell = Instance.new("Frame")
		cell.Name = "Day" .. c.day
		cell.LayoutOrder = c.day
		cell.Size = UDim2.fromOffset(L.dailyCellW, 84)
		cell.BackgroundColor3 = if c.state == "claimed" then Color3.fromRGB(60, 96, 44) elseif c.state == "today" then ORANGE else WOOD_ROW
		cell.Parent = strip7
		corner(cell, 8)
		stroke(cell, if c.state == "today" then GOLD else Color3.fromRGB(150, 110, 70), if c.state == "today" then 2.5 else 1)
		local d = text(cell, "Day", "DAY " .. c.day, Enum.Font.GothamBlack, 15)
		d.TextXAlignment = Enum.TextXAlignment.Center
		d.Position = UDim2.fromOffset(2, 4)
		d.Size = UDim2.new(1, -4, 0, 18)
		local g = text(cell, "Gears", "+" .. GarageModel.formatGears(c.gears), Enum.Font.GothamBlack, 20)
		g.TextXAlignment = Enum.TextXAlignment.Center
		g.Position = UDim2.fromOffset(2, 26)
		g.Size = UDim2.new(1, -4, 0, 26)
		g.TextColor3 = GOLD
		local s = text(cell, "Sub", if c.state == "claimed" then "CLAIMED" elseif c.trail then "+ TRAIL" else "CASH", Enum.Font.GothamBold, 12)
		s.TextXAlignment = Enum.TextXAlignment.Center
		s.Position = UDim2.fromOffset(2, 58)
		s.Size = UDim2.new(1, -4, 0, 18)
		s.TextColor3 = MUTED
	end
	local claimRow = section(3)
	claimRow.AutomaticSize = Enum.AutomaticSize.None
	claimRow.Size = UDim2.new(1, -6, 0, 48)
	if daily.claimedToday then
		local t = text(claimRow, "Claimed", "Claimed today - come back tomorrow for the next day", Enum.Font.GothamBold, 16)
		t.Size = UDim2.new(1, 0, 0, 44)
		t.TextColor3 = MUTED
	else
		local b = button(claimRow, "ClaimDaily", string.format("CLAIM DAY %d: +%s CASH", daily.nextDay or 1, GarageModel.formatGears(daily.nextReward or 0)), GREEN, true)
		b.Size = UDim2.fromOffset(math.min(320, L.content.w - 6), 44)
		stroke(b, GREEN_RIM, 2)
		b.Activated:Connect(function()
			act("ClaimDaily", function(d: any)
				UiSound.play("purchase")
				if type(d) == "table" then
					local names = {}
					for _, k in (if type(d.cosmetics) == "table" then d.cosmetics else {}) :: { any } do
						local c = GarageModel.cosmetic(tostring(k))
						table.insert(names, if c then c.name else tostring(k))
					end
					local extra = if #names > 0 then " + " .. table.concat(names, ", ") else ""
					toast(string.format("Day %d: +%s Cash%s", d.day or 0, GarageModel.formatGears(d.gears or 0), extra), GOLD)
				end
				fetchState()
			end)
		end)
	end
	-- What else pays today: Rally Streak, passes, Festival, Storm Cup.
	local lines = {}
	local rally = st.rallyStreak or 0
	local every = MonetizationConfig.GEARS.rallyStreak.every
	table.insert(lines, string.format("RALLY STREAK %d - every %d finishes in a row pays x%s", rally, every, tostring(MonetizationConfig.GEARS.rallyStreak.multiplier)))
	if hasPass("x2Gears") then
		table.insert(lines, "2x CASH ACTIVE - race payouts doubled")
	end
	local _, fl = strip(4, "", CREAM)
	local _, cl = strip(5, "", CREAM)
	local _, rl = strip(6, lines[1], MUTED)
	if lines[2] then
		strip(7, lines[2], GREEN_RIM)
	end
	table.insert(tickers, function()
		local now = serverNow(st, stClock)
		local fest = st.festival
		local nextFest = st.nextFestival
		if type(fest) == "table" and (fest.endsAt or 0) > now then
			fl.Text = string.format("%s NOW: x%s Cash for %s", string.upper(tostring(fest.name)), tostring(fest.multiplier), GarageModel.formatCountdown(fest.endsAt - now))
			fl.TextColor3 = GOLD
		elseif type(nextFest) == "table" then
			fl.Text = string.format("%s in %s", tostring(nextFest.name), GarageModel.formatCountdown((nextFest.startsAt or now) - now))
			fl.TextColor3 = CREAM
		else
			fl.Text = "No Festival scheduled"
		end
		-- The cup as server/StormCup publishes it (the map that will really run; nothing while the cup is off).
		local at = workspace:GetAttribute("StormCupAt")
		if workspace:GetAttribute("StormCupEnabled") == true and type(at) == "number" then
			local info = TrackInfo.get(workspace:GetAttribute("StormCupTrack") :: string?)
			local modifier = GarageModel.STORM_MODIFIER_LABEL[tostring(workspace:GetAttribute("StormCupModifier"))] or "STORM"
			local wsNow = workspace:GetServerTimeNow()
			cl.Text = string.format(
				"Storm Cup %s  -  %s, %s",
				if at <= wsNow then "starting" else "in " .. GarageModel.formatCountdown(at - wsNow),
				if info then info.trackName else "?",
				modifier
			)
		else
			cl.Text = "No Storm Cup right now"
		end
		rl.Text = lines[1]
	end)
end

render = function()
	if not isOpen then
		return
	end
	table.clear(tickers)
	-- Gamepad: remember the row button selection sat on (names are key-based), to land on it again after the rebuild.
	local selPath: { string } = {}
	local selNow = GuiService.SelectedObject
	if selNow and selNow:IsDescendantOf(content) then
		local node: Instance? = selNow
		while node and node ~= content do
			table.insert(selPath, 1, node.Name)
			node = node.Parent
		end
	end
	GarageTurntable.detach() -- REMARKABLE 27: the toy survives the rebuild
	for _, c in content:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	gearsLabel.Text = GarageModel.formatGears(gears()) .. " CASH"
	if st == nil then
		strip(1, "Loading your Garage...", MUTED)
		return
	end
	local tab: GarageModel.Tab? = nil
	for _, t in GarageModel.TABS do
		if t.id == activeTab then
			tab = t
		end
	end
	if tab == nil then
		-- A tab this build hides (DAILY under LAUNCH_HIDE): land on the first one instead.
		tab = GarageModel.TABS[1]
		activeTab = GarageModel.TABS[1].id
	end
	if tab and tab.kind then
		renderItems(tab.kind)
	elseif activeTab == "vehicles" then
		renderVehicles()
	elseif activeTab == "shop" then
		renderShop()
	elseif activeTab == "winpass" then
		renderWinPass()
	else
		renderDaily()
	end
	local info = {}
	local features = if type(st.features) == "table" then st.features else {}
	if features.rallyStreak ~= false and (st.rallyStreak or 0) > 0 then
		table.insert(info, "RALLY x" .. tostring(st.rallyStreak))
	end
	if hasPass("x2Gears") then
		table.insert(info, "2x CASH")
	end
	if type(st.festival) == "table" then
		table.insert(info, "FESTIVAL")
	end
	infoLabel.Text = table.concat(info, "  -  ")
	for _, fn in tickers do
		fn()
	end
	-- Rebuilt rows drop a gamepad selection that sat on them: the same row's button, else the active tab.
	UiSound.hush() -- landing selection back on a rebuilt row is not a D-pad move: no marimba note
	local sel = GuiService.SelectedObject
	if (UserInputService.GamepadEnabled or GuiService:IsTenFootInterface()) and (sel == nil or not sel:IsDescendantOf(gui)) then
		local node: Instance? = if #selPath > 0 then content else nil
		for _, name in selPath do
			node = if node then node:FindFirstChild(name) else nil
		end
		GuiService.SelectedObject = if node and node:IsA("GuiButton") and node.Selectable then node else tabButtons[activeTab]
	end
end

---------------------------------------------------------------------------------------------------- layout and build

local function applyLayout()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	local inset = GuiService:GetGuiInset()
	L = GarageModel.layout(vp.X, vp.Y, inset.Y)
	local p = L.panel
	panel.Position = UDim2.fromOffset(p.x, p.y)
	panel.Size = UDim2.fromOffset(p.w, p.h)
	local h = L.header
	titleLabel.Position = UDim2.fromOffset(h.x + 4, h.y)
	titleLabel.Size = UDim2.fromOffset(math.floor(h.w * 0.22), h.h)
	gearsLabel.Position = UDim2.fromOffset(h.x + math.floor(h.w * 0.23), h.y + 6)
	gearsLabel.Size = UDim2.fromOffset(math.floor(h.w * 0.28), h.h - 12)
	infoLabel.Position = UDim2.fromOffset(h.x + math.floor(h.w * 0.52), h.y + 8)
	infoLabel.Size = UDim2.fromOffset(math.floor(h.w * 0.48) - 112 - (h.h + 6), h.h - 16)
	closeButton.Position = UDim2.fromOffset(h.x + h.w - 104, h.y)
	closeButton.Size = UDim2.fromOffset(104, h.h)
	-- The gear sits left of CLOSE, a square the height of the header (a thumb-sized target on a phone).
	gearButton.Position = UDim2.fromOffset(h.x + h.w - 104 - h.h - 6, h.y)
	gearButton.Size = UDim2.fromOffset(h.h, h.h)
	tabsFrame.Position = UDim2.fromOffset(L.tabs.x, L.tabs.y)
	tabsFrame.Size = UDim2.fromOffset(L.tabs.w, L.tabs.h)
	for i, t in GarageModel.TABS do
		local b = tabButtons[t.id]
		b.Position = UDim2.fromOffset((i - 1) * (L.tabW + L.gap), 0)
		b.Size = UDim2.fromOffset(L.tabW, L.tabs.h)
	end
	content.Position = UDim2.fromOffset(L.content.x, L.content.y)
	content.Size = UDim2.fromOffset(L.content.w, L.content.h)
	local toastW = math.min(p.w - 2 * L.pad, 560)
	toastRect = { x = p.x + math.floor((p.w - toastW) / 2), y = p.y + p.h - L.pad - 44, w = toastW, h = 44 }
	-- HUD layout v2: the hub bar hangs in the top-right slot of the safe rect; the GARAGE button follows it.
	local hsnap = HudMetrics.get()
	local hm = hsnap.metrics
	-- Under the hub bar: its right edge (rightLimit applied, e.g. left of the Roblox leaderboard) sets the margin.
	local hubRect = hsnap.rects.hubBar
	local hb = GarageModel.hubButtonRect(vp.X, vp.Y, if hubRect then vp.X - (hubRect.x + hubRect.w) else vp.X - hm.xr, hm.yTop)
	hubButton.Position = UDim2.fromOffset(hb.x, hb.y)
	hubButton.Size = UDim2.fromOffset(hb.w, hb.h)
	gearsChip.Position = UDim2.fromOffset(hb.x, hb.y + hb.h + 2)
	gearsChip.Size = UDim2.fromOffset(hb.w, 20)
	if isOpen then
		render()
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallyGarage"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 26 -- over the HUD and TrackFlow (20, curtain included): the panel closes on TrackSwitching
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	hubButton = button(gui, "GarageButton", "GARAGE", ORANGE, true)
	hubButton.Visible = false
	stroke(hubButton, GOLD, 2)
	UiSound.setKind(hubButton, "tab")
	hubButton.Activated:Connect(function()
		Garage.toggle()
	end)
	gearsChip = text(gui, "GearsChip", "", Enum.Font.GothamBold, 15)
	gearsChip.TextXAlignment = Enum.TextXAlignment.Center
	gearsChip.Visible = false
	local gs = Instance.new("UIStroke")
	gs.Color = WOOD_DARK
	gs.Thickness = 1.5
	gs.Parent = gearsChip

	panel = Instance.new("Frame")
	panel.Name = "GaragePanel"
	panel.BackgroundColor3 = WOOD
	panel.Visible = false
	panel.Active = true
	-- Gamepad selection never wanders out to the HUD or the results panel under it.
	panel.SelectionGroup = true
	panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	panel.Parent = gui
	corner(panel, 14)
	stroke(panel, RIM, 3)
	titleLabel = text(panel, "Title", "GARAGE", Enum.Font.GothamBlack, 30)
	gearsLabel = text(panel, "Gears", "", Enum.Font.GothamBlack, 22)
	gearsLabel.TextColor3 = GOLD
	infoLabel = text(panel, "Info", "", Enum.Font.GothamBold, 15)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Right
	infoLabel.TextColor3 = GREEN_RIM
	closeButton = button(panel, "CloseGarage", "CLOSE", WOOD_DARK, true)
	stroke(closeButton, RIM, 1.5)
	UiSound.setKind(closeButton, "back")
	closeButton.Activated:Connect(close)
	gearButton = Settings.makeGearButton(panel, "SettingsGear")
	tabsFrame = Instance.new("Frame")
	tabsFrame.Name = "Tabs"
	tabsFrame.BackgroundTransparency = 1
	tabsFrame.Parent = panel
	for i, t in GarageModel.TABS do
		local b = button(tabsFrame, "Tab_" .. t.id, t.label, WOOD_DARK, true)
		b.LayoutOrder = i
		UiSound.setKind(b, "tab")
		tabButtons[t.id] = b
		b.Activated:Connect(function()
			setTab(t.id)
		end)
	end
	content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollBarThickness = 6
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.Selectable = false
	content.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = content
	applyLayout()
end

-- The GARAGE tab on the race results panel (RaceUI's FinishPositionScreen): a bookmark on its right edge with this
-- race's Gears under it (RaceFinished payload, the server's own number).
local function hookResults()
	task.spawn(function()
		local hud = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("SkyRallyHUD", 30)
		local modal = hud and hud:FindFirstChild("FinishPositionScreen", true)
		if not modal or not modal:IsA("GuiObject") then
			return
		end
		local tab = button(modal, "GarageTab", "GARAGE", ORANGE, true)
		tab.AnchorPoint = Vector2.new(0, 0)
		tab.Position = UDim2.new(1, 2, 0, 12)
		tab.Size = UDim2.fromOffset(104, 44)
		tab.Visible = garageEnabled()
		stroke(tab, GOLD, 2)
		UiSound.setKind(tab, "tab")
		tab.Activated:Connect(function()
			Garage.open()
		end)
		resultsTab = tab
		local g = text(modal, "GarageGears", "", Enum.Font.GothamBlack, 14)
		g.Position = UDim2.new(1, 4, 0, 58)
		g.Size = UDim2.fromOffset(100, 20)
		g.TextColor3 = GOLD
		g.TextXAlignment = Enum.TextXAlignment.Center
		g.Visible = false
		local gs = Instance.new("UIStroke")
		gs.Color = WOOD_DARK
		gs.Thickness = 1.5
		gs.Parent = g
		resultsGears = g
	end)
end

local function onRaceEvent(kind: any, payload: any)
	local g = resultsGears
	if kind == "RaceFinished" and g then
		local earned = if type(payload) == "table" and type(payload.gears) == "table" then payload.gears else nil
		if earned and type(earned.gears) == "number" and garageEnabled() then
			local mult = if type(earned.multiplier) == "number" and earned.multiplier > 1 then string.format(" x%s", tostring(earned.multiplier)) else ""
			g.Text = "+" .. GarageModel.formatGears(earned.gears) .. " CASH" .. mult
			g.Visible = true
		else
			g.Visible = false
		end
	elseif kind == "RaceReset" and g then
		g.Visible = false
	end
end

local function refreshVisibility()
	local on = garageEnabled()
	local mode = RaceAttr.mine("RaceMode")
	local hub = (mode == "hub") and workspace:GetAttribute("TrackSwitching") ~= true
	hubButton.Visible = on and hub
	gearsChip.Visible = on and hub
	gearsChip.Text = GarageModel.formatGears(gears()) .. " CASH"
	if resultsTab then
		resultsTab.Visible = on
	end
	if isOpen then
		local ok = GarageModel.canOpen(openContext())
		if not ok then
			close()
		end
	end
end

local function toggleAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or UserInputService:GetFocusedTextBox() ~= nil or not garageEnabled() then
		return Enum.ContextActionResult.Pass
	end
	if isOpen then
		UiSound.play("back")
		close()
		return Enum.ContextActionResult.Sink
	end
	if GarageModel.canOpen(openContext()) then
		UiSound.play("tab")
		Garage.open()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

function Garage.init()
	build()
	hookResults()
	local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
	local rf = remotes and remotes:WaitForChild("EconomyRequest", 15)
	if rf and rf:IsA("RemoteFunction") then
		request = rf
	end
	local ev = remotes and remotes:WaitForChild("EconomyEvent", 15)
	if ev and ev:IsA("RemoteEvent") then
		ev.OnClientEvent:Connect(function(kind: any, payload: any)
			if kind == "AvatarLadder" and type(payload) == "table" and type(payload.unlocks) == "table" then
				-- Phase 6: a ladder step earned by racing (or a key found) with that avatar; NotifySpec rows.
				for i, u in payload.unlocks do
					if i > 3 or type(u) ~= "table" then
						break
					end
					pcall(NotifyKit.fromSpec, if u.kind == "tint" then "tint_unlock" else "reskin_unlock", { name = string.sub(tostring(u.avatarName), 1, 24) }, { key = "ladder_" .. tostring(u.avatar) .. "_" .. tostring(u.step) })
				end
				av = nil -- refetched when the VEHICLES tab next renders
				return
			end
			if kind == "Toast" and type(payload) == "table" and type(payload.text) == "string" then
				local color = if payload.kind == "Delivered" then GOLD elseif payload.kind == "Gift" then Color3.fromRGB(255, 170, 220) else GREEN_RIM
				toast(string.sub(payload.text, 1, 90), color, 4.5)
				if isOpen then
					task.spawn(function()
						fetchState()
						render()
					end)
				end
			end
		end)
	end
	local race = remotes and remotes:WaitForChild("RaceEventRemote", 15)
	if race and race:IsA("RemoteEvent") then
		race.OnClientEvent:Connect(onRaceEvent)
	end
	-- server/StoreBinder mirrors each Robux id it binds here; an open panel re-reads GetState so the row appears at once.
	-- Waited for in its own task so a slow or missing folder never holds up the toggle binding below.
	task.spawn(function()
		local storeIds = ReplicatedStorage:WaitForChild("SkyRallyStore", 15)
		if storeIds then
			storeIds.AttributeChanged:Connect(function()
				if isOpen then
					task.spawn(function()
						fetchState()
						render()
					end)
				end
			end)
		end
	end)
	ContextActionService:BindAction("SkyRallyGarageToggle", toggleAction, false, Enum.KeyCode.G, Enum.KeyCode.ButtonL3)
	for _, attr in { "GarageEnabled", "TrackSwitching" } do
		workspace:GetAttributeChangedSignal(attr):Connect(refreshVisibility)
	end
	for _, attr in { "RaceMode", "RaceGoTime", "BattleState" } do
		RaceAttr.changed(attr, refreshVisibility)
	end
	LocalPlayer:GetAttributeChangedSignal("Gears"):Connect(function()
		refreshVisibility()
		if isOpen then
			gearsLabel.Text = GarageModel.formatGears(gears()) .. " CASH"
		end
	end)
	LocalPlayer:GetAttributeChangedSignal("RaceFinished"):Connect(refreshVisibility)
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
	end
	HudMetrics.onChanged(applyLayout)
	-- Countdowns tick four times a second while the panel is open; the countdown/race guard runs with them.
	RunService.Heartbeat:Connect(Prof.wrap("SR_Garage", function()
		local t = os.clock()
		if t - lastTick < 0.25 then
			return
		end
		lastTick = t
		if isOpen then
			-- A race starting, or the Adventure board opening (ADVENTURE tapped above the panel), closes the Garage.
			local boardUp = false
			pcall(function()
				boardUp = TrackFlow.isBoardOpen()
			end)
			if boardUp or not GarageModel.canOpen(openContext()) then
				close()
				return
			end
			for _, fn in tickers do
				fn()
			end
		end
	end))
	refreshVisibility()
	task.delay(2, refreshVisibility)
end

return Garage
