--!strict
-- The Garage (MONETIZATION_PROPOSAL sections 2-3; TEST_LIST_LAUNCH L50, L53, L55-L59), UI v2 look (docs/design/UI_V2.md
-- section 2 "Garage", client/ArcadeUi). One GARAGE button in the hub HUD (under ADVENTURE) and one GARAGE tab on the race
-- results panel open a navy panel: a gold GARAGE band with the Cash counter, eight icon tabs, then on the left the STAGE
-- (the selected thing, large: a turning 3D model of the vehicle, or the turntable wearing the focused tint, with its
-- actions) and on the right a grid of CARDS (3D thumbnail or a colour chip, name, rarity edge strip, equipped check,
-- lock + price). Tabs:
--   VEHICLES                  every avatar of the class (PLANES / CARS switch); SELECT / BUY / R$ / where it comes from;
--                             LOOKS opens the avatar's reskin / tint ladder on the stage (earned by racing it, never sold)
--   TINTS / TRAILS / HORNS / EMOTES  every cosmetic of the kind: owned, equipped (one tap; tints per vehicle), buy with
--                             Cash when it is in the shop now, or where it comes from; tapping a card tries it on the stage
--   SHOP      the rotating shop: offer cards with stock / SOLD OUT, the Daily Deal and the restock countdown; Robux products
--             only when the store is on AND the product has a real id (the server's GetState.products), priced from
--             GetProductInfo, never from a hardcoded label
--   WIN PASS  tiers (races finished) with the free and premium rewards and CLAIM buttons
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
-- (SelectionGroup) and comes back to the card it was on after a rebuild; every target is 44 px; the panel sits inside a
-- TV-safe 5% inset below the top bar (GarageModel.layout). Opening the Garage closes the Adventure board and opening the
-- board closes the Garage, so the two never stack.
-- State is shown with icons, colour and short labels (no "MODEL SOON" style copy): an avatar whose own model is not in
-- yet shows as a tinted silhouette of the class model it races as.
-- Toasts: shown on the panel's own plank while it is open (TrackFlow's toast sits under the panel), TrackFlow's toast
-- otherwise; EconomyEvent "Toast" (Delivered once on rejoin, Gift, Pass) takes the same path.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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
-- REMARKABLE 4: every button speaks (tap, tab flip, marimba confirm/back, deny + shake, purchase run).
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))
local UiSkinRules = require(Shared:WaitForChild("UiSkinRules"))
local ArcadeUi = require(script.Parent:WaitForChild("ArcadeUi")) -- UI v2 tokens, keys, cards, icons
local UiSkin = require(script.Parent:WaitForChild("UiSkin")) -- v3 striped label bands
local VehicleThumbs = require(script.Parent:WaitForChild("VehicleThumbs")) -- 3D card thumbnails of the real models
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics")) -- L28 / L82 and HUD layout v2: the hub button hangs under TrackFlow's bar in the safe rect
-- REMARKABLE 27: the turntable toy on the stage of the cosmetic tabs (try a tint, REV, HONK).
local GarageTurntable = require(script.Parent:WaitForChild("GarageTurntable"))
-- Audit H13: the gear in the panel header opens the Settings panel (sound sliders, camera shake, low graphics, invite).
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local Garage = {}

local C = ArcadeUi.C
local GOLD = C.gold
local CREAM = C.white
local MUTED = C.dim
local GREEN_RIM = Color3.fromHex("8CF5A0")
local FONT = ArcadeUi.FONT

-- Tab icons (shared/UiV2Icons through ArcadeUi.ART; VEHICLES has no vehicle icon in the set: the race flags stand in).
local TAB_ICON: { [string]: string } = {
	vehicles = "race",
	liveries = "paint",
	trails = "trail",
	horns = "horn",
	emotes = "emote",
	shop = "shop",
	winpass = "pass",
	daily = "calendar",
}

local request: RemoteFunction? = nil
local gui: ScreenGui
local hubButton: GuiButton
local gearsChip: TextLabel
local cashPlate: Frame
local panel: Frame
local titleBand: Frame
local gearsLabel: TextLabel
local infoLabel: TextLabel
local closeButton: GuiButton
local gearButton: GuiButton
local tabsFrame: Frame
local tabButtons: { [string]: GuiButton } = {}
local bumperHints: { TextLabel } = {} -- round 3: LB / RB (Q / E) at the ends of the tab row; hidden on touch
local content: Frame
local overlay: Frame? = nil
local resultsTab: GuiButton? = nil
local resultsGears: TextLabel? = nil
local toastRect: { x: number, y: number, w: number, h: number }? = nil -- the strip over the panel bottom (applyLayout); NotifyKit draws it
local prevSelection: GuiObject? = nil -- what gamepad selection sat on before the panel opened (results tab, ...)

local st: any = nil -- GetState data
local av: any = nil -- GetAvatars data (phase 6: the VEHICLES tab)
local avClass = "plane" -- which class the VEHICLES tab lists
local avFocus: string? = nil -- the avatar on the stage
local looksOpen = false -- the stage shows the focused avatar's LOOKS ladder
local itemFocus: { [string]: string } = {} -- kind -> the cosmetic on the stage
local stClock = 0
local shop: any = nil -- GetShop data
local shopClock = 0
local activeTab = "vehicles" -- phase 6: the Garage opens on VEHICLES (falls back to the first tab when hidden)
local isOpen = false
local busy = false
local tickers: { () -> () } = {}
local lastTick = 0
local lastShopFetch = -math.huge
local setBlur: (boolean) -> () -- round 3: the world blur behind the open Garage (defined with the backdrop below)

---------------------------------------------------------------------------------------------------- helpers

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function rarityColor(r: string?): Color3
	return ArcadeUi.RARITY[tostring(r)] or ArcadeUi.RARITY.common
end

local function text(parent: Instance, name: string, str: string, display: boolean?, maxSize: number?): TextLabel
	return ArcadeUi.text(parent, {
		name = name,
		text = str,
		font = if display then FONT.display else FONT.bodyHeavy,
		maxSize = maxSize or 20,
		minSize = 10,
	})
end

-- A key button. variant: go (the one primary action), sky (secondary), orange (buy / reward), danger, navy (neutral),
-- robux, disabled (status keys: OWNED, SOLD OUT, LOCKED still take a press so the deny knock plays).
local function button(parent: Instance, name: string, str: string, variant: string, enabled: boolean?, icon: string?): GuiButton
	local on = enabled ~= false
	local b = ArcadeUi.button(parent, if on then variant else "disabled", str, {
		name = name,
		icon = icon,
		sound = if on then "tap" else "deny",
		maxText = 18,
		minText = 10,
		selectable = on,
	})
	return b
end

-- Selected / idle tab look: the gold header key when selected, navy otherwise; compact panels label only the selected tab.
local L: GarageModel.Layout

local function tabLook(b: GuiButton, on: boolean)
	ArcadeUi.setVariant(b, if on then "header" else "navy")
	local lbl = ArcadeUi.labelOf(b)
	local face = b:FindFirstChild("Face")
	local glyph = face and face:FindFirstChild("Glyph")
	local labelled = on or not (L and L.compact)
	if lbl then
		lbl.Visible = labelled
	end
	if glyph and glyph:IsA("GuiObject") then
		glyph.AnchorPoint = if labelled then Vector2.new(0, 0.5) else Vector2.new(0.5, 0.5)
		glyph.Position = if labelled then UDim2.new(0, 8, 0.5, 0) else UDim2.fromScale(0.5, 0.5)
	end
end

local function cashText(n: number): string
	return GarageModel.formatGears(n)
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
		tabLook(b, tid == id)
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

-- silent: a forced close (race start, board opened, state fetch failed) pops out without its cue.
local function close(silent: boolean?)
	if overlay then
		overlay:Destroy()
		overlay = nil
	end
	isOpen = false
	if gearsChip and gearsChip.Parent then
		(gearsChip.Parent :: GuiObject).Visible = hubButton.Visible
	end
	-- Pops out, then Visible = false (UiMotion); an open in the meantime cancels the pop-out and pops back in.
	UiMotion.hide(panel, "popOut", nil, { silent = silent == true })
	setBlur(false)
	NotifyKit.dismissTag("garage")
	GarageTurntable.close() -- REMARKABLE 27
	UiSound.setKind(hubButton, "tab")
	ContextActionService:UnbindAction("SkyRallyGarageClose")
	ContextActionService:UnbindAction("SkyRallyGarageTabs")
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
	if gearsChip and gearsChip.Parent then
		(gearsChip.Parent :: GuiObject).Visible = false
	end
	av = nil -- the VEHICLES tab refetches (Cash and ladders move between visits)
	UiMotion.show(panel, "popIn")
	setBlur(true)
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
	-- v3: bumpers (and Q / E) step through the tabs, like a console menu's LB / RB tab row.
	ContextActionService:BindActionAtPriority("SkyRallyGarageTabs", function(_n: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin or not isOpen then
			return Enum.ContextActionResult.Pass
		end
		local list = GarageModel.TABS
		local at = 1
		for i, t in list do
			if t.id == activeTab then
				at = i
			end
		end
		local dir = if input.KeyCode == Enum.KeyCode.ButtonL1 or input.KeyCode == Enum.KeyCode.Q then -1 else 1
		local nxt = list[((at - 1 + dir) % #list) + 1]
		if nxt then
			UiSound.play("tab")
			setTab(nxt.id, true)
			if GuiService.SelectedObject ~= nil then
				GuiService.SelectedObject = tabButtons[nxt.id]
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1, Enum.KeyCode.Q, Enum.KeyCode.E)
	setTab(activeTab, false)
	if UserInputService.GamepadEnabled or GuiService:IsTenFootInterface() then
		GuiService.SelectedObject = tabButtons[activeTab]
	end
	task.spawn(function()
		if not fetchState() then
			close(true)
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

-- A modal list over the content: pick `need` options (a racer to gift, Season 1 tints for a set). need = 1 picks on
-- tap; more shows CONFIRM once enough are toggled.
local function openPicker(title: string, options: { { id: string, label: string } }, need: number, onDone: ({ string }) -> ())
	if overlay then
		overlay:Destroy()
	end
	local o = ArcadeUi.card(panel, { name = "Picker", position = content.Position, size = content.Size, radius = 14, z = 40 })
	o.SelectionGroup = true
	o.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	o.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	overlay = o
	local band = ArcadeUi.band(o, title, { name = "Title", position = UDim2.fromOffset(10, 8), size = UDim2.new(1, -150, 0, 40), maxText = 22 })
	band.ZIndex = 41
	local cancel = button(o, "Cancel", "CANCEL", "danger", true, "close")
	cancel.Position = UDim2.new(1, -130, 0, 6)
	cancel.Size = UDim2.fromOffset(122, 44)
	UiSound.setKind(cancel, "back")
	cancel.Activated:Connect(function()
		o:Destroy()
		overlay = nil
	end)
	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(10, 58)
	list.Size = UDim2.new(1, -20, 1, if need > 1 then -116 else -66)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ScrollBarThickness = 6
	list.Parent = o
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(190, 48)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = list
	local chosen: { [string]: boolean } = {}
	local count = 0
	local confirm: GuiButton? = nil
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
		local b = button(list, "Opt_" .. opt.id, opt.label, "navy", true)
		b.LayoutOrder = i
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
			ArcadeUi.setVariant(b, if chosen[opt.id] then "go" else "navy")
			if confirm then
				ArcadeUi.setText(confirm, string.format("CONFIRM %d/%d", count, need))
				ArcadeUi.setVariant(confirm, if count == need then "go" else "disabled")
				UiSound.setKind(confirm, if count == need then "confirm" else "deny")
			end
		end)
	end
	if need > 1 then
		local c = button(o, "Confirm", string.format("CONFIRM 0/%d", need), "disabled", true, "check")
		c.AnchorPoint = Vector2.new(0.5, 1)
		c.Position = UDim2.new(0.5, 0, 1, -8)
		c.Size = UDim2.fromOffset(220, 48)
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
		local e = text(list, "Empty", "Nobody to pick right now", false, 18)
		e.Size = UDim2.fromOffset(300, 30)
		e.TextColor3 = MUTED
	end
	UiMotion.show(o, "popIn")
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

---------------------------------------------------------------------------------------------------- stage, grid, cards

-- The stage column (left): content-local L.stage. GarageTurntable mounts into it on the cosmetic tabs.
local function section(order: number): Frame
	local f = ArcadeUi.card(content, {
		name = "Stage" .. order,
		inset = true,
		radius = 12,
		position = UDim2.fromOffset(L.stage.x, L.stage.y),
		size = UDim2.fromOffset(L.stage.w, L.stage.h),
	})
	f.LayoutOrder = order
	return f
end

-- The card grid (right of the stage, or the whole content when full is true).
local function gridArea(full: boolean?, topPad: number?): (ScrollingFrame, UIGridLayout)
	local x = if full then 0 else L.grid.x
	local w = if full then L.content.w else L.grid.w
	local tp = topPad or 0
	local g = Instance.new("ScrollingFrame")
	g.Name = "Grid"
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.Position = UDim2.fromOffset(x, tp)
	g.Size = UDim2.fromOffset(w, L.content.h - tp)
	g.CanvasSize = UDim2.new()
	g.AutomaticCanvasSize = Enum.AutomaticSize.Y
	g.ScrollBarThickness = 6
	g.ScrollBarImageColor3 = C.gold
	g.ScrollingDirection = Enum.ScrollingDirection.Y
	g.Selectable = false
	g.Parent = content
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 2)
	pad.Parent = g
	local layout = Instance.new("UIGridLayout")
	local cols = if full then math.max(2, math.floor((w - 6 + L.gap) / ((if L.compact then 110 else 200) + L.gap))) else L.cols
	local cw = math.floor((w - 8 - L.gap * (cols - 1)) / cols)
	layout.CellSize = UDim2.fromOffset(cw, L.cardH)
	layout.CellPadding = UDim2.fromOffset(L.gap, L.gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = g
	return g, layout
end

-- A full-width scrolling list (win pass tiers, daily extras).
local function listArea(topPad: number?): ScrollingFrame
	local tp = topPad or 0
	local g = Instance.new("ScrollingFrame")
	g.Name = "List"
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.Position = UDim2.fromOffset(0, tp)
	g.Size = UDim2.fromOffset(L.content.w, L.content.h - tp)
	g.CanvasSize = UDim2.new()
	g.AutomaticCanvasSize = Enum.AutomaticSize.Y
	g.ScrollBarThickness = 6
	g.ScrollBarImageColor3 = C.gold
	g.Selectable = false
	g.Parent = content
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, L.gap)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = g
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 2)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = g
	return g
end

-- An icon + text chip (timers, counters): a navy pill with an icon on the left.
local function chip(parent: Instance, name: string, icon: string, str: string, h: number, color: Color3?): (Frame, TextLabel)
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = C.inset
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	f.AutomaticSize = Enum.AutomaticSize.X
	f.Size = UDim2.fromOffset(0, h)
	ArcadeUi.corner(f, UDim.new(0.5, 0))
	ArcadeUi.stroke(f, 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = f
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = f
	local ic = ArcadeUi.icon(f, icon, { name = "Icon", size = UDim2.fromOffset(h - 6, h - 6) }, h - 6)
	ic.LayoutOrder = 1
	local l = ArcadeUi.text(f, { name = "Text", text = str, font = FONT.display, size = math.max(12, math.floor(h * 0.58)), color = color or CREAM, stroke = 1.5 })
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.fromOffset(0, h)
	l.LayoutOrder = 2
	f.Parent = parent
	return f, l
end

-- A row of chips across the top of the content (shop timers, the season line).
local function chipRow(name: string, h: number): Frame
	local r = Instance.new("Frame")
	r.Name = name
	r.BackgroundTransparency = 1
	r.Size = UDim2.fromOffset(L.content.w, h)
	r.Parent = content
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = r
	return r
end

local function setCardSelected(b: GuiObject, on: boolean)
	-- v3: the card's 9-slice frame replaces its stroke, so the focused card gets its own yellow edge on top
	local bg = b:FindFirstChild("Bg")
	local edge = bg and bg:FindFirstChild("FocusEdge")
	if on and bg and not edge then
		local e = Instance.new("Frame")
		e.Name = "FocusEdge"
		e.BackgroundTransparency = 1
		e.Size = UDim2.fromScale(1, 1)
		e.ZIndex = 20
		e.Active = false
		e.Parent = bg
		local s = Instance.new("UIStroke")
		s.Color = C.gold
		s.Thickness = if L and L.compact then 3 else 4
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = e
	elseif not on and edge then
		edge:Destroy()
	end
	b:SetAttribute("Selected", on)
end

-- A grid card: navy card, an inset art well (top), the name, the rarity edge strip along the bottom, a badge corner.
-- Returns the card button, the art well and the footer frame (price / state).
local function card(parent: Instance, order: number, name: string, title: string, rarity: string?): (TextButton, Frame, Frame)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.LayoutOrder = order
	b.Selectable = true
	b.Parent = parent
	-- v3 picture card: the render fills the card; name and price sit on a striped dark band along the bottom with the
	-- rarity as the band's left edge (docs/design/UI_V2.md section 4).
	local bg = ArcadeUi.card(b, { name = "Bg", size = UDim2.fromScale(1, 1), radius = 4 })
	bg.Active = false
	local art = ArcadeUi.card(bg, { name = "Art", inset = true, radius = 2, position = UDim2.fromOffset(3, 3), size = UDim2.new(1, -6, 0.74, -3) })
	local band = UiSkin.stripeBand(bg, { size = UDim2.new(1, -6, 0.27, 0), position = UDim2.new(0, 3, 1, -3), zIndex = bg.ZIndex + 1, alpha = 0.05 })
	band.Name = "Band"
	local strip = Instance.new("Frame")
	strip.Name = "Rarity"
	strip.BorderSizePixel = 0
	strip.BackgroundColor3 = rarityColor(rarity)
	strip.Position = UDim2.fromOffset(0, 2)
	strip.Size = UDim2.new(0, if L.compact then 4 else 6, 1, -2)
	strip.ZIndex = band.ZIndex + 1
	strip.Parent = band
	local n = ArcadeUi.text(band, {
		name = "Name",
		text = string.upper(title),
		font = FONT.display,
		maxSize = if L.compact then 15 else 24,
		minSize = 10,
		align = Enum.TextXAlignment.Left,
		stroke = 1.2,
	})
	n.Position = UDim2.new(0, 12, 0, 2)
	n.Size = UDim2.new(1, -18, 0.52, 0)
	n.ZIndex = band.ZIndex + 1
	n.TextTruncate = Enum.TextTruncate.AtEnd
	local foot = Instance.new("Frame")
	foot.Name = "Foot"
	foot.BackgroundTransparency = 1
	foot.Position = UDim2.new(0, 12, 0.54, 0)
	foot.Size = UDim2.new(1, -18, 0.42, 0)
	foot.ZIndex = band.ZIndex + 1
	foot.Parent = band
	if L.compact and L.cardH < 130 then
		-- A short phone card: art and name only (the stage shows the price and the state of the selected card).
		foot.Visible = false
		n.Size = UDim2.new(1, -18, 0.9, 0)
	end
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = foot
	UiSound.bind(b, "tap")
	return b, art, foot
end

-- The footer: icon + short text (price in gold with a coin, R$ in teal, an earn source with a trophy).
local function footer(foot: Frame, icon: string?, str: string, color: Color3?)
	local h = foot.AbsoluteSize.Y
	local px = math.max(14, if h > 0 then h else (if L.compact then 14 else 20))
	if icon then
		local ic = ArcadeUi.icon(foot, icon, { name = "Icon", size = UDim2.new(0, px, 1, 0) }, px)
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.Parent = ic
		ic.LayoutOrder = 1
	end
	local l = ArcadeUi.text(foot, { name = "Price", text = str, font = FONT.display, maxSize = if L.compact then 13 else 17, minSize = 10, color = color or GOLD, stroke = 1.5, align = Enum.TextXAlignment.Center })
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.fromScale(0, 1)
	l.LayoutOrder = 2
end

-- A corner badge on the card's art well: check (equipped / selected) or lock (not owned).
local function badge(art: Frame, kind: string)
	local s = if L.compact then 24 else 32
	ArcadeUi.icon(art, kind, { name = "Badge", anchor = Vector2.new(1, 0), position = UDim2.new(1, -3, 0, 3), size = UDim2.fromOffset(s, s), z = 3 }, s)
end

-- A tint's colour chip (primary / accent / trim bands) filling `holder`.
local function tintChip(holder: GuiObject, c: any)
	local f = Instance.new("Frame")
	f.Name = "Chip"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(0.74, 0.8)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.ClipsDescendants = true
	f.Parent = holder
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = f
	ArcadeUi.corner(f, UDim.new(0.22, 0))
	ArcadeUi.stroke(f, 3)
	local lv = c and c.livery
	if lv then
		local parts: { { any } } = { { lv.primary, 0, 0.52 }, { lv.accent, 0.52, 0.3 }, { lv.trim, 0.82, 0.18 } }
		for i, p in parts do
			local s = Instance.new("Frame")
			s.Name = "Band" .. i
			s.BorderSizePixel = 0
			s.BackgroundColor3 = rgb(p[1])
			s.Position = UDim2.fromScale(0, p[2] :: number)
			s.Size = UDim2.fromScale(1, p[3] :: number)
			s.Parent = f
		end
	end
	ArcadeUi.shine(f, 12)
end

-- A trail's preview: its colour gradient as a streak with speed lines.
local function trailChip(holder: GuiObject, c: any)
	local f = Instance.new("Frame")
	f.Name = "Streak"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(0.86, 0.36)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.Parent = holder
	ArcadeUi.corner(f, UDim.new(0.5, 0))
	ArcadeUi.stroke(f, 3)
	if c and c.trail then
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new(rgb(c.trail.color0), rgb(c.trail.color1))
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
		g.Parent = f
	end
	for i, y in { 0.22, 0.78 } do
		local line = Instance.new("Frame")
		line.Name = "Speed" .. i
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BackgroundTransparency = 0.35
		line.AnchorPoint = Vector2.new(0, 0.5)
		line.Position = UDim2.fromScale(0.1 + 0.12 * i, y)
		line.Size = UDim2.fromScale(0.36, 0.05)
		line.Parent = holder
		ArcadeUi.corner(line, UDim.new(0.5, 0))
	end
end

-- Art for a cosmetic in a well: tint chip, trail streak, or the kind's big icon.
local function cosmeticArt(holder: GuiObject, c: any)
	local kind = c and c.kind
	if kind == "livery" then
		tintChip(holder, c)
	elseif kind == "trail" then
		trailChip(holder, c)
	else
		ArcadeUi.icon(holder, if kind == "horn" then "horn" else "emote", { name = "Art", anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.62, 0.62) }, 64).SizeConstraint = Enum.SizeConstraint.RelativeYY
	end
end

-- Stage parts: a name line with a rarity pill and the actions row along the bottom.
local function stageTitle(stage: Frame, y: number, title: string, rarity: string?): number
	local h = if L.compact then 22 else 46
	local n = ArcadeUi.text(stage, { name = "StageName", text = UiSkin.twoToneLast(string.upper(title)), font = FONT.display, maxSize = if L.compact then 20 else 26, minSize = 12, stroke = 0 })
	n.RichText = true
	n.Position = UDim2.fromOffset(10, y)
	n.Size = UDim2.new(1, -20, 0, h)
	n.TextTruncate = Enum.TextTruncate.AtEnd
	UiSkin.dropShadow(n, 2)
	if rarity then
		local ph = if L.compact then 18 else 24
		local p = ArcadeUi.pill(stage, "navy", string.upper(rarity), { name = "RarityPill", position = UDim2.fromOffset(10, y + h + 2), size = UDim2.fromOffset(if L.compact then 74 else 100, ph), maxText = if L.compact then 11 else 14 })
		local fill = p:FindFirstChildOfClass("UIGradient")
		local rc = rarityColor(rarity)
		if fill then
			fill.Color = ColorSequence.new(rc, ArcadeUi.darken(rc, 0.7))
		end
		return y + h + ph + 6
	end
	return y + h + 4
end

export type Action = { label: string, variant: string, icon: string?, enabled: boolean?, sound: string?, onTap: (() -> ())?, weight: number?, keepLook: boolean? }

local function stageActions(stage: Frame, specs: { Action }): Frame
	local row = Instance.new("Frame")
	row.Name = "Actions"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.new(0, 8, 1, -8)
	row.Size = UDim2.new(1, -16, 0, if L.compact then 44 else 52)
	row.Parent = stage
	local total = 0
	for _, sp in specs do
		total += sp.weight or 1
	end
	local gap = 6
	local x = 0
	for i, sp in specs do
		local wt = (sp.weight or 1) / math.max(total, 1)
		local b = button(row, "Action" .. i, sp.label, sp.variant, sp.enabled, sp.icon)
		if sp.keepLook and sp.enabled == false then
			ArcadeUi.setVariant(b, sp.variant) -- a state key (SELECTED) keeps its colour; it still takes no action
		end
		b.Position = UDim2.new(x, if i > 1 then gap / 2 else 0, 0, 0)
		b.Size = UDim2.new(wt, -(if #specs > 1 then gap / 2 else 0), 1, 0)
		x += wt
		if sp.enabled ~= false and sp.sound then
			UiSound.setKind(b, sp.sound)
		end
		local tap = sp.onTap
		if sp.enabled ~= false and tap then
			b.Activated:Connect(tap)
		end
	end
	return row
end

local function actionsH(): number
	return (if L.compact then 44 else 52) + 8
end

local function emptyLine(parent: Instance, str: string)
	local e = text(parent, "Empty", str, true, 20)
	e.TextColor3 = MUTED
	e.TextXAlignment = Enum.TextXAlignment.Center
	e.Size = UDim2.new(1, 0, 0, 40)
end

---------------------------------------------------------------------------------------------------- actions

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

---------------------------------------------------------------------------------------------------- cosmetic tabs

local SLOT_ICON: { [string]: string } = { planeLivery = "plane", carLivery = "car" }

-- A card-sized version of a "where it comes from" note: the part before any "(...)" or " - " detail, the shop
-- rotation said in two words.
local function shortNote(note: any): string
	local s = string.upper(tostring(note or "EARN"))
	s = string.gsub(s, "%s*%b()", "")
	s = string.match(s, "^(.-)%s+%-%s+") or s
	if string.find(s, "NOT IN THE SHOP", 1, true) then
		return "SHOP ROTATION"
	end
	return s
end

local function itemView(): GarageModel.View
	return {
		owned = GarageModel.ownedSet(st.owned),
		loadout = st.loadout,
		gears = gears(),
		shop = if shop then shop.slots else nil,
		amulet = {
			keys = tonumber(LocalPlayer:GetAttribute("Keys")) or 0,
			fragments = tonumber(LocalPlayer:GetAttribute("BattleFragments")) or 0,
		},
	}
end

-- The stage of a cosmetic tab: the turntable on top, the focused item's name and its actions below.
local function itemStage(stage: Frame, kind: string, r: any?, view: GarageModel.View)
	local plus = hasPass("garagePlus")
	local bottom = actionsH() + (if L.compact then 46 else 70) + (if plus then 50 else 0)
	-- The turntable takes the top of the stage (REMARKABLE 27).
	local host = Instance.new("Frame")
	host.Name = "TurntableHost"
	host.BackgroundTransparency = 1
	host.Position = UDim2.fromOffset(4, 4)
	host.Size = UDim2.new(1, -8, 1, -bottom)
	host.Parent = stage
	host.Size = UDim2.new(1, -8, 1, -bottom)
	for _, ch in host:GetChildren() do
		if ch:IsA("GuiObject") then
			ch.Size = UDim2.fromScale(1, 1)
		end
	end
	local y = L.stage.h - bottom + 6
	if not r then
		local e = text(stage, "Hint", "Pick a card to try it", true, 18)
		e.Position = UDim2.fromOffset(10, y)
		e.Size = UDim2.new(1, -20, 0, 26)
		e.TextColor3 = MUTED
		return
	end
	y = stageTitle(stage, y, r.name, r.rarity)
	-- Where it comes from (short): owned items say nothing, the shop says its price on the key below.
	if not r.owned and not r.buyPrice and r.note then
		local n = text(stage, "Note", shortNote(r.note), false, if L.compact then 12 else 15)
		n.Position = UDim2.new(0, if L.compact then 90 else 118, 0, y - (if L.compact then 22 else 30))
		n.Size = UDim2.new(1, -(if L.compact then 98 else 126), 0, if L.compact then 18 else 24)
		n.TextColor3 = MUTED
		n.TextTruncate = Enum.TextTruncate.AtEnd
	end
	local specs: { Action } = {}
	if kind == "horn" or kind == "emote" then
		table.insert(specs, {
			label = if kind == "horn" then "PLAY" else "TRY",
			variant = "sky",
			icon = if kind == "horn" then "horn" else "emote",
			weight = 0.8,
			onTap = function()
				if kind == "horn" then
					Cosmetics.previewHorn(r.key)
					GarageTurntable.honk(r.key, false) -- REMARKABLE 27: the car on the turntable honks along
				else
					Cosmetics.previewEmote(r.key)
				end
			end,
		})
	end
	if r.owned then
		for _, slot in ipairs((GarageModel.KIND_SLOTS[kind] or {}) :: { string }) do
			local on = r.equipped[slot] == true
			local label = GarageModel.SLOT_LABEL[slot] or "EQUIP"
			table.insert(specs, {
				label = if on then (if kind == "livery" then label else "EQUIPPED") else label,
				variant = if on then "go" else "navy",
				icon = if on then "check" else SLOT_ICON[slot],
				sound = if on then "back" else "confirm",
				-- Tapping what is equipped takes it off.
				onTap = function()
					equip(slot, if on then "" else r.key)
				end,
			})
		end
	elseif r.buyPrice then
		table.insert(specs, {
			label = cashText(r.buyPrice),
			variant = if r.affordable then "orange" else "disabled",
			icon = "coin",
			enabled = true,
			sound = if r.affordable then "tap" else "deny",
			weight = 1.4,
			onTap = function()
				buy(r.key)
			end,
		})
	else
		table.insert(specs, { label = "LOCKED", variant = "disabled", icon = "lock", enabled = false, weight = 1.4 })
	end
	stageActions(stage, specs)
	if plus then
		-- Garage+ presets: save the whole loadout to a slot, load it back in one tap; FAV on the focused item.
		local bar = Instance.new("Frame")
		bar.Name = "Presets"
		bar.BackgroundTransparency = 1
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.new(0, 8, 1, -actionsH() - 4)
		bar.Size = UDim2.new(1, -16, 0, 44)
		bar.Parent = stage
		local hl = Instance.new("UIListLayout")
		hl.FillDirection = Enum.FillDirection.Horizontal
		hl.Padding = UDim.new(0, 4)
		hl.SortOrder = Enum.SortOrder.LayoutOrder
		hl.Parent = bar
		local bw = math.floor((L.stage.w - 16 - 6 * 4) / 7)
		for i = 1, 3 do
			local lb = button(bar, "Load" .. i, "L" .. i, "go", true)
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
			local sb = button(bar, "Save" .. i, "S" .. i, "navy", true)
			sb.LayoutOrder = 3 + i
			sb.Size = UDim2.fromOffset(bw, 44)
			UiSound.setKind(sb, "confirm")
			sb.Activated:Connect(function()
				act("SavePreset", function()
					toast("Loadout saved to slot " .. i, GOLD)
				end, i)
			end)
		end
		if r.owned then
			local fav = st.favorites and st.favorites[r.key] == true
			local fb = button(bar, "Fav", "", if fav then "header" else "navy", true, "star")
			fb.LayoutOrder = 7
			fb.Size = UDim2.fromOffset(bw, 44)
			fb.Activated:Connect(function()
				act("SetFavorite", function()
					st.favorites = st.favorites or {}
					st.favorites[r.key] = if fav then nil else true
				end, r.key, not fav)
			end)
		end
	end
	local _ = view
end

local function renderItems(kind: string)
	local view = itemView()
	local rows = GarageModel.itemRows(kind, view)
	-- Focus: the last card tapped, else what is equipped, else the first card.
	local focus: any = nil
	for _, r in rows do
		if r.key == itemFocus[kind] then
			focus = r
		end
	end
	if not focus then
		for _, r in rows do
			if r.anyEquipped then
				focus = r
				break
			end
		end
	end
	focus = focus or rows[1]
	local stage = section(0)
	itemStage(stage, kind, focus, view)
	GarageTurntable.mount(section(0), L.stage.w, L.compact) -- REMARKABLE 27: the turntable, on the stage
	-- mount sizes the frame it is given; the toy moves into the stage's top host and that frame goes.
	local toy = content:FindFirstChild("Showroom", true)
	local host = stage:FindFirstChild("TurntableHost")
	if toy and host and toy:IsA("GuiObject") then
		toy.Parent = host
		toy.Size = UDim2.fromScale(1, 1)
		-- The stage names the focused item under the toy: the toy's own plate would say it twice.
		local plate = toy:FindFirstChild("Plate")
		if plate and plate:IsA("GuiObject") then
			plate.Visible = false
		end
		local vpf = toy:FindFirstChild("Turntable")
		if vpf and vpf:IsA("GuiObject") then
			vpf.Size = UDim2.fromScale(1, 1)
		end
	end
	for _, ch in content:GetChildren() do
		if ch:IsA("GuiObject") and ch.Name == "Stage0" and ch ~= stage then
			ch:Destroy()
		end
	end
	if focus and focus.cosmetic and kind == "livery" then
		GarageTurntable.preview(focus.key)
	end
	local g = gridArea()
	for i, r in rows do
		local b, art, foot = card(g, i, "Item_" .. r.key, r.name, r.rarity)
		cosmeticArt(art, r.cosmetic)
		if r.anyEquipped then
			badge(art, "check")
		elseif not r.owned then
			badge(art, "lock")
		end
		if r.owned then
			-- Tints: which vehicles wear it.
			local on = {}
			for slot, v in r.equipped do
				if v and SLOT_ICON[slot] then
					table.insert(on, slot)
				end
			end
			if #on > 0 and kind == "livery" then
				for _, slot in on do
					footer(foot, SLOT_ICON[slot], "", GREEN_RIM)
				end
			else
				footer(foot, nil, if r.anyEquipped then "EQUIPPED" else "OWNED", if r.anyEquipped then GREEN_RIM else MUTED)
			end
		elseif r.buyPrice then
			footer(foot, "coin", cashText(r.buyPrice), if r.affordable then GOLD else MUTED)
		else
			footer(foot, "trophy", shortNote(r.note), MUTED)
		end
		setCardSelected(b, focus ~= nil and r.key == focus.key)
		b.Activated:Connect(function()
			itemFocus[kind] = r.key
			if kind == "livery" then
				GarageTurntable.preview(r.key) -- REMARKABLE 27: tap the card to try the tint on the turntable
			elseif kind == "horn" then
				Cosmetics.previewHorn(r.key)
				GarageTurntable.honk(r.key, false)
			end
			render()
		end)
	end
	if #rows == 0 then
		emptyLine(g, "Nothing here yet")
	end
end

---------------------------------------------------------------------------------------------------- vehicles (phase 6)

local function fetchAvatars()
	local reply = invoke("GetAvatars")
	if reply.ok and type(reply.data) == "table" then
		av = reply.data
	end
end

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

-- A dark rarity tint for an avatar whose own model is not in yet (it races as the class model: shown as its silhouette).
local function silhouetteOf(v: any): Color3?
	if v.built ~= false then
		return nil
	end
	return rarityColor(v.rarity)
end

local SOURCE_SHORT: { [string]: string } = { campaign = "ADVENTURE", amulet = "BATTLE", storm = "STORM" }

-- A soft spotlight disc in the rarity colour behind a model (showroom look).
local function spotGlow(holder: GuiObject, rarity: string?)
	local glow = Instance.new("ImageLabel")
	glow.Name = "Glow"
	glow.BackgroundTransparency = 1
	glow.Image = (require(Shared:WaitForChild("VfxAssets")) :: any).glow_soft.id
	glow.ImageColor3 = rarityColor(rarity)
	glow.ImageTransparency = 0.35
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.56)
	glow.Size = UDim2.fromScale(1.05, 1.05)
	glow.Active = false
	glow.Parent = holder
end

-- The small ribbon on a card whose own model is not in yet (it shows as a silhouette of the class model).
local function comingSoon(holder: GuiObject)
	ArcadeUi.pill(holder, "danger", "COMING SOON", {
		name = "Soon",
		anchor = Vector2.new(0, 1),
		position = UDim2.new(0, 3, 1, -3),
		size = UDim2.new(0.8, 0, 0, if L.compact then 16 else 20),
		maxText = if L.compact then 10 else 12,
		z = 4,
	})
end

local function progressCounter(parent: Instance, icon: string, n: number, order: number, h: number)
	local f, _ = chip(parent, "Count_" .. icon, icon, tostring(n), h)
	f.LayoutOrder = order
end

local function vehicleStage(stage: Frame, v: any)
	local actions = actionsH()
	local infoH = if L.compact then 46 else 96
	if looksOpen and v.owned then
		-- LOOKS: the avatar's reskin / tint ladder, earned by racing it (never sold).
		local n, total = GarageModel.ladderCount(v)
		local band = ArcadeUi.band(stage, string.format("LOOKS %d/%d", n, total), { name = "LooksBand", position = UDim2.fromOffset(8, 8), size = UDim2.new(1, -16, 0, if L.compact then 32 else 42), maxText = 22 })
		band.ZIndex = 2
		local list = Instance.new("ScrollingFrame")
		list.Name = "Ladder"
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.Position = UDim2.fromOffset(8, (if L.compact then 32 else 42) + 14)
		list.Size = UDim2.new(1, -16, 1, -((if L.compact then 32 else 42) + 14 + actions))
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.ScrollBarThickness = 4
		list.Selectable = false
		list.Parent = stage
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 4)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Parent = list
		local wornAny = false
		local steps: { any } = table.clone(v.ladder or {})
		for i, step in steps do
			wornAny = wornAny or step.worn
			local row = ArcadeUi.card(list, { name = "Step_" .. step.id, radius = 10, size = UDim2.new(1, -6, 0, 48), layoutOrder = i, shine = false, strokeWidth = 2 })
			ArcadeUi.icon(row, if step.unlocked then (if step.kind == "tint" then "paint" else "star") else "lock", { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 6, 0.5, 0), size = UDim2.fromOffset(34, 34) }, 34)
			local t = text(row, "Name", string.upper(step.name), true, 18)
			t.Position = UDim2.fromOffset(46, 3)
			t.Size = UDim2.new(1, -150, 0, if step.unlocked then 42 else 24)
			if not step.unlocked then
				local need = text(row, "Need", tostring(step.need), false, 13)
				need.Position = UDim2.fromOffset(46, 26)
				need.Size = UDim2.new(1, -54, 0, 18)
				need.TextColor3 = MUTED
				need.TextTruncate = Enum.TextTruncate.AtEnd
				t.Size = UDim2.new(1, -54, 0, 24)
			else
				local b = button(row, "Wear", if step.worn then "WORN" else "WEAR", if step.worn then "go" else "sky", true, if step.worn then "check" else nil)
				b.AnchorPoint = Vector2.new(1, 0.5)
				b.Position = UDim2.new(1, -4, 0.5, 0)
				b.Size = UDim2.fromOffset(100, 42)
				b.Activated:Connect(function()
					act("WearSkin", function()
						fetchAvatars()
					end, v.key, if step.worn then "" else step.id)
				end)
			end
		end
		if wornAny then
			local row = ArcadeUi.card(list, { name = "Step_base", radius = 10, size = UDim2.new(1, -6, 0, 48), layoutOrder = #steps + 1, shine = false, strokeWidth = 2 })
			local t = text(row, "Name", "BASE LOOK", true, 18)
			t.Position = UDim2.fromOffset(12, 3)
			t.Size = UDim2.new(1, -120, 1, -6)
			local b = button(row, "Wear", "WEAR", "sky", true)
			b.AnchorPoint = Vector2.new(1, 0.5)
			b.Position = UDim2.new(1, -4, 0.5, 0)
			b.Size = UDim2.fromOffset(100, 42)
			b.Activated:Connect(function()
				act("WearSkin", function()
					fetchAvatars()
				end, v.key, "")
			end)
		end
		stageActions(stage, {
			{ label = "BACK", variant = "navy", icon = "respawn", sound = "back", onTap = function()
				looksOpen = false
				render()
			end },
		})
		return
	end
	-- round 3 hero (docs/design/UI_V2.md section 4, Synty "Modern Menus"): no box. The model turns large over the
	-- (blurred) live world, the name in the display face with its last word in yellow, two status chips (rarity, owned
	-- state), the three facts the server keeps per vehicle (races, 1sts, keys with it) as big chips, then SELECT (lime)
	-- and LOOKS (blue). Nothing here is invented: a vehicle without progress shows no fact chips.
	local nameH = if L.compact then 26 else 64
	local chipH = if L.compact then 0 else 40 -- phones: the card under the grid already says SELECTED / OWNED
	local factH = if L.compact then 0 else 78
	local below = nameH + 6 + (if chipH > 0 then chipH + 8 else 0) + (if factH > 0 then factH + 10 else 0) + actions
	local holder = Instance.new("Frame")
	holder.Name = "Model"
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(0, 0)
	holder.Size = UDim2.new(1, 0, 1, -below)
	holder.Parent = stage
	local glow = Instance.new("ImageLabel")
	glow.Name = "Glow"
	glow.BackgroundTransparency = 1
	glow.Image = (require(Shared:WaitForChild("VfxAssets")) :: any).glow_soft.id
	glow.ImageColor3 = rarityColor(v.rarity)
	glow.ImageTransparency = 0.45
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.6)
	glow.Size = UDim2.fromScale(1.0, 0.9)
	glow.Parent = holder
	VehicleThumbs.view(holder, v.key, avClass, { name = "BigModel", spin = true, silhouette = silhouetteOf(v), yaw = 215, zoom = 0.92 })
	if v.built == false then
		comingSoon(holder)
	end
	local y = L.stage.h - below
	local title = ArcadeUi.text(stage, { name = "StageName", text = UiSkin.twoToneLast(string.upper(tostring(v.name))), font = FONT.display, maxSize = if L.compact then 26 else 34, minSize = 12, stroke = 0 })
	title.RichText = true
	title.Position = UDim2.fromOffset(4, y)
	title.Size = UDim2.new(1, -8, 0, nameH)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	UiSkin.dropShadow(title)
	y += nameH + 6
	-- Status chips: rarity (its colour) and the owned state.
	local chips = Instance.new("Frame")
	chips.Name = "Status"
	chips.BackgroundTransparency = 1
	chips.Position = UDim2.fromOffset(4, y)
	chips.Size = UDim2.new(1, -8, 0, chipH)
	chips.Parent = stage
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.Padding = UDim.new(0, 8)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.VerticalAlignment = Enum.VerticalAlignment.Center
	cl.Parent = chips
	local function statusChip(order: number, str: string, color: Color3, icon: string?)
		local f, l = chip(chips, "Chip" .. order, icon or "star", str, chipH, color)
		f.LayoutOrder = order
		if not icon then
			local ic = f:FindFirstChild("Icon")
			if ic then
				ic:Destroy()
			end
			l.Size = UDim2.fromOffset(0, chipH)
		end
		local edge = Instance.new("Frame")
		edge.Name = "Edge"
		edge.BorderSizePixel = 0
		edge.BackgroundColor3 = color
		edge.Size = UDim2.new(0, 4, 1, -6)
		edge.Position = UDim2.fromOffset(-2, 3)
		edge.Parent = f
		return f
	end
	chips.Visible = chipH > 0
	statusChip(1, string.upper(tostring(v.rarity or "common")), rarityColor(v.rarity))
	if v.selected then
		statusChip(2, "SELECTED", GREEN_RIM, "check")
	elseif v.owned then
		statusChip(2, "OWNED", CREAM, "check")
	elseif v.acquire == "cash" and type(v.price) == "number" then
		statusChip(2, cashText(v.price), if v.affordable then GOLD else MUTED, "coin")
	elseif v.acquire == "earned" then
		statusChip(2, SOURCE_SHORT[tostring(v.source)] or "EARN", MUTED, "trophy")
	else
		statusChip(2, "LOCKED", MUTED, "lock")
	end
	y += if chipH > 0 then chipH + 8 else 0
	-- The facts: big chips (icon, number, word) when the server sent this vehicle's progress.
	if factH > 0 and v.owned and type(v.progress) == "table" then
		local facts = Instance.new("Frame")
		facts.Name = "Facts"
		facts.BackgroundTransparency = 1
		facts.Position = UDim2.fromOffset(4, y)
		facts.Size = UDim2.new(1, -8, 0, factH)
		facts.Parent = stage
		local spec = {
			{ "flag", v.progress.races or 0, "RACES" },
			{ "trophy", v.progress.wins or 0, "1ST PLACES" },
			{ "key", v.progress.keys or 0, "KEYS" },
		}
		for i, f in spec do
			local box = ArcadeUi.card(facts, { name = "Fact" .. i, size = UDim2.new(1 / 3, -6, 1, 0), position = UDim2.new((i - 1) / 3, if i > 1 then 3 else 0, 0, 0), alpha = 0.08 })
			local ic = ArcadeUi.icon(box, f[1] :: string, { name = "Icon", anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 8, 0.5, 0), size = UDim2.fromScale(0.62, 0.62) }, 48)
			ic.SizeConstraint = Enum.SizeConstraint.RelativeYY
			local num = ArcadeUi.text(box, { name = "Num", text = tostring(f[2]), font = FONT.display, maxSize = 22, minSize = 12, color = GOLD, stroke = 0 })
			num.Position = UDim2.new(0.42, 0, 0.08, 0)
			num.Size = UDim2.new(0.56, 0, 0.56, 0)
			local word = ArcadeUi.text(box, { name = "Word", text = f[3] :: string, font = FONT.bodyHeavy, maxSize = 10, minSize = 9, color = MUTED, stroke = 0 })
			word.Position = UDim2.new(0.42, 0, 0.62, 0)
			word.Size = UDim2.new(0.56, 0, 0.3, 0)
		end
	end
	local a = GarageModel.avatarAction(v)
	local specs: { Action } = {}
	if a.action == "select" then
		table.insert(specs, { label = "SELECT", variant = "go", icon = "check", sound = "confirm", weight = 1.3, onTap = function()
			avatarTap(v, "select")
		end })
	elseif a.tone == "on" then
		table.insert(specs, { label = "SELECTED", variant = "go", icon = "check", enabled = false, keepLook = true, weight = 1.3 })
	elseif a.action == "buy" then
		table.insert(specs, { label = cashText(v.price), variant = if v.affordable then "orange" else "disabled", icon = "coin", enabled = true, sound = if v.affordable then "confirm" else "deny", weight = 1.3, onTap = function()
			avatarTap(v, "buy")
		end })
	elseif a.action == "robux" then
		table.insert(specs, { label = a.label, variant = "robux", icon = "cash", sound = "confirm", weight = 1.3, onTap = function()
			avatarTap(v, "robux")
		end })
	else
		table.insert(specs, { label = "LOCKED", variant = "disabled", icon = "lock", enabled = false, weight = 1.3 })
	end
	if v.owned then
		table.insert(specs, { label = "LOOKS", variant = "sky", icon = "paint", onTap = function()
			looksOpen = true
			render()
		end })
	end
	stageActions(stage, specs)
end

-- round 3: the VEHICLES tab's own geometry (content-local): the hero column on the left (no box, over the world) and
-- three big picture cards a row right of it. Built from the shared layout L.
local function vehicleLayout(base: GarageModel.Layout, n: number?): GarageModel.Layout
	local l = table.clone(base)
	local cw = base.content.w
	local heroW = math.floor(cw * (if base.compact then 0.4 else 0.42))
	l.stage = { x = 0, y = 0, w = heroW, h = base.content.h }
	local gx = heroW + base.gap * 2
	l.grid = { x = gx, y = 0, w = cw - gx, h = base.content.h }
	local barH = if base.compact then 40 else 48
	-- few cards (two built vehicles a class today): two big columns, two rows that fill the column height
	local cols = if base.compact then 2 else (if (n or 0) > 4 and l.grid.w >= 760 then 3 else 2)
	l.cols = cols
	l.cardW = math.floor((l.grid.w - 6 - base.gap * (cols - 1)) / cols)
	local rowsFit = if base.compact then 1 else 2
	l.cardH = math.min(math.floor(l.cardW * 0.8), math.floor((base.content.h - barH - 20 - base.gap * (rowsFit - 1)) / rowsFit))
	return l
end

local function renderVehicles()
	if not av then
		local s = section(0)
		emptyLine(s, "Loading your vehicles...")
		task.spawn(function()
			fetchAvatars()
			if isOpen and activeTab == "vehicles" and av then
				render()
			end
		end)
		return
	end
	local base = L
	local nCards = 0
	local unbuiltN = 0
	for _, v in (type(av.classes) == "table" and av.classes[avClass]) or {} do
		if v.built ~= false then
			nCards += 1
		else
			unbuiltN = 1
		end
	end
	L = vehicleLayout(base, nCards + unbuiltN)
	-- Class switch over the grid: the track picks plane or car; the player picks the model inside the class.
	local barH = if L.compact then 40 else 48
	local bar = Instance.new("Frame")
	bar.Name = "ClassBar"
	bar.BackgroundTransparency = 1
	bar.Position = UDim2.fromOffset(L.grid.x, 0)
	bar.Size = UDim2.fromOffset(L.grid.w - 8, barH)
	bar.Parent = content
	local classes: { string } = {}
	for _, c in AvatarConfig.CLASSES do
		if not AvatarConfig.HIDDEN_CLASSES[c] and type(av.classes) == "table" and av.classes[c] then
			table.insert(classes, c)
		end
	end
	local bw = math.min(240, math.floor((L.grid.w - 8 - (#classes - 1) * L.gap) / math.max(1, #classes)))
	for i, c in classes do
		local on = c == avClass
		local b = ArcadeUi.button(bar, "navy", AvatarConfig.CLASS_LABEL[c] or string.upper(c), { name = "Class_" .. c, icon = c, sound = "tab", maxText = 18, minText = 10 })
		ArcadeUi.setVariant(b, if on then "header" else "navy")
		b.Position = UDim2.fromOffset((i - 1) * (bw + L.gap), 0)
		b.Size = UDim2.fromOffset(bw, barH)
		b.Activated:Connect(function()
			if avClass ~= c then
				avClass = c
				avFocus = nil
				looksOpen = false
				render()
			end
		end)
	end
	local rows = (type(av.classes) == "table" and av.classes[avClass]) or {}
	local focus: any = nil
	for _, v in rows do
		if v.key == avFocus then
			focus = v
		end
	end
	if not focus then
		for _, v in rows do
			if v.selected then
				focus = v
			end
		end
	end
	focus = focus or rows[1]
	-- The hero column: transparent (the model stands over the blurred world); the LOOKS ladder keeps a dark well.
	local stage = Instance.new("Frame")
	stage.Name = "Stage0"
	stage.BackgroundTransparency = 1
	stage.Position = UDim2.fromOffset(L.stage.x, L.stage.y)
	stage.Size = UDim2.fromOffset(L.stage.w, L.stage.h)
	stage.Parent = content
	if looksOpen then
		local well = ArcadeUi.card(stage, { name = "Well", inset = true, size = UDim2.fromScale(1, 1), alpha = 0.25 })
		well.ZIndex = 0
	end
	if focus then
		vehicleStage(stage, focus)
	end
	local g = gridArea(false, barH + 8)
	-- Real (built) vehicles first; the rest keep the roster order after them.
	local ordered: { any } = {}
	for _, v in rows do
		if v.built ~= false then
			table.insert(ordered, v)
		end
	end
	-- v38-flow round 2: unbuilt vehicles are not cards (a wall of COMING SOON silhouettes read unfinished); one tile
	-- says more are on the way.
	local unbuilt = 0
	for _, v in rows do
		if v.built == false then
			unbuilt += 1
		end
	end
	for i, v in ordered do
		local b, art, foot = card(g, i, "Avatar_" .. v.key, v.name, v.rarity)
		spotGlow(art, v.rarity)
		VehicleThumbs.view(art, v.key, avClass, { name = "Thumb", silhouette = silhouetteOf(v), yaw = 215, zoom = 0.95 })
		if v.selected then
			badge(art, "check")
		elseif not v.owned then
			badge(art, "lock")
		end
		if v.owned then
			footer(foot, nil, if v.selected then "SELECTED" else "OWNED", if v.selected then GREEN_RIM else MUTED)
		elseif v.acquire == "cash" and type(v.price) == "number" then
			footer(foot, "coin", cashText(v.price), if v.affordable then GOLD else MUTED)
		elseif v.acquire == "robux" then
			footer(foot, "cash", if type(v.robux) == "number" then "R$ " .. tostring(v.robux) else "ROBUX", Color3.fromHex("6FF0D2"))
		else
			footer(foot, "trophy", SOURCE_SHORT[tostring(v.source)] or "EARN", MUTED)
		end
		setCardSelected(b, focus ~= nil and v.key == focus.key)
		b.Activated:Connect(function()
			if avFocus ~= v.key or looksOpen then
				avFocus = v.key
				looksOpen = false
				render()
			end
		end)
	end
	if unbuilt > 0 then
		-- exactly one "more coming" tile: a dim framed card with the class glyph and the count
		local more = Instance.new("Frame")
		more.Name = "MoreComing"
		more.BackgroundTransparency = 1
		more.LayoutOrder = #ordered + 1
		more.Parent = g
		local mc = ArcadeUi.card(more, { name = "Bg", size = UDim2.fromScale(1, 1), alpha = 0.35 })
		local band = UiSkin.stripeBand(mc, { size = UDim2.new(1, -6, 0.27, 0), position = UDim2.new(0, 3, 1, -3), zIndex = mc.ZIndex + 1, alpha = 0.05 })
		local ic = ArcadeUi.icon(mc, avClass, { name = "Glyph", anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.38), size = UDim2.fromScale(0.42, 0.42) }, 64)
		ic.SizeConstraint = Enum.SizeConstraint.RelativeYY
		for _, d in ic:GetDescendants() do
			if d:IsA("ImageLabel") then
				d.ImageTransparency = 0.45
			end
		end
		local t = ArcadeUi.text(band, { name = "Text", text = string.format("+%d MORE COMING", unbuilt), font = FONT.display, maxSize = if L.compact then 13 else 20, minSize = 10, align = Enum.TextXAlignment.Left, color = MUTED, stroke = 0 })
		t.Position = UDim2.new(0, 12, 0, 2)
		t.Size = UDim2.new(1, -18, 0.6, 0)
		t.ZIndex = band.ZIndex + 1
	end
	if #rows == 0 then
		emptyLine(g, "Nothing here yet")
	end
	L = base
end

---------------------------------------------------------------------------------------------------- shop

local function renderShop()
	if not shop then
		emptyLine(content, "Loading the shop...")
		return
	end
	local chipH = if L.compact then 30 else 44
	local top = chipRow("Timers", chipH)
	if shop.rotation == false then
		chip(top, "AllStock", "shop", "EVERY ITEM IN STOCK", chipH)
	else
		local _, restock = chip(top, "Restock", "clock", "", chipH)
		local _, deal = chip(top, "Deal", "star", "", chipH, GOLD)
		table.insert(tickers, function()
			local now = serverNow(shop, shopClock)
			local left = (shop.restockAt or now) - now
			restock.Text = "RESTOCK " .. GarageModel.formatCountdown(left)
			deal.Text = "DEAL " .. GarageModel.formatCountdown((shop.dealEndsAt or now) - now)
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
	local g, layout = gridArea(true, chipH + 8)
	local cellW = layout.CellSize.X.Offset
	local cellH = math.min(math.floor(cellW * 1.5), math.max(140, L.content.h - chipH - 20))
	layout.CellSize = UDim2.fromOffset(cellW, cellH)
	local function offerCard(order: number, name: string, title: string, rarity: string?, art: (Frame) -> (), key: (Frame) -> (), tag: string?)
		local b, well, _foot = card(g, order, name, title, rarity)
		b.Selectable = false
		local bg = b:FindFirstChild("Bg") :: Frame
		-- round 3: the v3 picture card keeps its name in the striped band; an offer card stacks art, band, then its key
		-- (the old layout looked for a Name on the card and stopped the whole tab after the first card).
		local keyH = if L.compact then 36 else 44
		local bandH = math.floor(cellH * 0.24)
		local band = bg:FindFirstChild("Band") :: Frame
		well.Size = UDim2.new(1, -6, 1, -(3 + bandH + keyH + 12))
		band.Size = UDim2.new(1, -6, 0, bandH)
		band.Position = UDim2.new(0, 3, 1, -(keyH + 12))
		art(well)
		if tag then
			ArcadeUi.pill(well, "danger", tag, { name = "Tag", anchor = Vector2.new(0, 0), position = UDim2.fromOffset(4, 4), size = UDim2.fromOffset(if L.compact then 56 else 72, if L.compact then 18 else 22), maxText = 13 })
		end
		key(bg)
	end
	local function keyAt(parent: Frame, k: GuiButton)
		k.AnchorPoint = Vector2.new(0.5, 1)
		k.Position = UDim2.new(0.5, 0, 1, -6)
		k.Size = UDim2.new(1, -14, 0, if L.compact then 36 else 44)
		k.Parent = parent
	end
	for i, r in GarageModel.shopRows(shop.slots, gears()) do
		offerCard(i, "Shop_" .. r.slot, r.name, r.rarity, function(well)
			cosmeticArt(well, r.cosmetic)
			if r.owned then
				badge(well, "check")
			end
		end, function(bg)
			local k: GuiButton
			if r.owned then
				k = button(bg, "Buy", "OWNED", "go", false, "check")
			elseif r.soldOut then
				k = button(bg, "Buy", "SOLD OUT", "disabled", false)
			else
				k = button(bg, "Buy", cashText(r.price), if r.affordable then "orange" else "disabled", true, "coin")
				UiSound.setKind(k, if r.affordable then "tap" else "deny")
				k.Activated:Connect(function()
					buy(r.key)
				end)
			end
			keyAt(bg, k)
			local foot = (bg:FindFirstChild("Band") :: Frame):FindFirstChild("Foot") :: Frame
			-- What it is and how many are left (the stock text the model writes, e.g. "3 LEFT").
			footer(foot, nil, GarageModel.kindLabel(r.kind) .. "  " .. tostring(r.stockText or ""), MUTED)
		end, if r.deal then string.format("-%d%%", math.floor(MonetizationConfig.SHOP.dealDiscount * 100 + 0.5)) else nil)
	end
	-- Robux products: only rows the server lists (store on and a real id), priced from GetProductInfo.
	local products = if st and type(st.products) == "table" then st.products else {}
	local base: { any } = {}
	for _, p in products do
		if not p.giftTwinOf then
			table.insert(base, p)
		end
	end
	local n0 = 100
	if #base > 0 then
		for i, p in base do
			local active = p.kind == "Pass" and hasPass(p.key)
			local priced = type(p.price) == "number"
			offerCard(n0 + i, "Product_" .. p.key, p.label, "rare", function(well)
				ArcadeUi.icon(well, if p.kind == "Pass" then "pass" else "coins", { name = "Art", anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.62, 0.62) }, 64).SizeConstraint = Enum.SizeConstraint.RelativeYY
				if active then
					badge(well, "check")
				end
			end, function(bg)
				local twin: any = nil
				for _, t in products do
					if t.giftTwinOf == p.key and type(t.price) == "number" then
						twin = t
					end
				end
				local k: GuiButton
				if active then
					k = button(bg, "Buy", "ACTIVE", "go", false, "check")
				else
					k = button(bg, "Buy", if priced then "R$ " .. tostring(p.price) else "...", "robux", priced, "cash")
					k.Activated:Connect(function()
						buyProduct(p)
					end)
				end
				keyAt(bg, k)
				if twin then
					local gk = button(bg, "Gift", "", "danger", true, "gift")
					gk.AnchorPoint = Vector2.new(1, 0)
					gk.Position = UDim2.new(1, -10, 0, 10)
					gk.Size = UDim2.fromOffset(44, 44)
					gk.Activated:Connect(function()
						giftProduct(twin, p.key)
					end)
				end
				footer((bg:FindFirstChild("Band") :: Frame):FindFirstChild("Foot") :: Frame, nil, if p.kind == "Pass" then "GAME PASS" else "ROBUX", MUTED)
			end)
		end
	elseif st and st.storeEnabled == true then
		-- Store on but nothing bound in this universe yet: one quiet card, never a dead prompt.
		offerCard(n0 + 1, "StoreSoon", "ROBUX STORE", "common", function(well)
			ArcadeUi.icon(well, "cash", { name = "Art", anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.62, 0.62) }, 64).SizeConstraint = Enum.SizeConstraint.RelativeYY
		end, function(bg)
			keyAt(bg, button(bg, "Soon", "COMING SOON", "disabled", false))
		end)
	end
end

---------------------------------------------------------------------------------------------------- win pass

local WP_STATUS: { [string]: { label: string, variant: string, enabled: boolean, icon: string? } } = {
	claim = { label = "CLAIM", variant = "go", enabled = true, icon = "gift" },
	claimed = { label = "CLAIMED", variant = "navy", enabled = false, icon = "check" },
	locked = { label = "LOCKED", variant = "disabled", enabled = false, icon = "lock" },
	premium = { label = "PREMIUM", variant = "disabled", enabled = false, icon = "pass" },
	over = { label = "ENDED", variant = "disabled", enabled = false },
}

local KIND_ICON: { [string]: string } = { livery = "paint", trail = "trail", horn = "horn", emote = "emote" }

local function renderWinPass()
	local wp = st.winPass or {}
	local chipH = if L.compact then 30 else 44
	local top = chipRow("Season", chipH)
	local _, season = chip(top, "SeasonChip", "pass", "", chipH, GOLD)
	local races = wp.races or 0
	chip(top, "RacesChip", "flag", tostring(races), chipH)
	local _, ends = chip(top, "EndsChip", "clock", "", chipH)
	table.insert(tickers, function()
		if wp.season == nil then
			season.Text = "SEASON OVER"
			ends.Text = "NEXT SOON"
			return
		end
		local left = (wp.seasonEndsAt or 0) - serverNow(st, stClock)
		season.Text = string.format("SEASON %s%s", tostring(wp.season), if wp.premium then "  PREMIUM" else "")
		ends.Text = GarageModel.formatCountdown(left)
		-- Accessibility / QA readout of the whole line (one place states it in words).
		top:SetAttribute("Line", string.format("SEASON %s  -  %d RACES  -  ENDS IN %s", tostring(wp.season), races, GarageModel.formatCountdown(left)))
	end)
	local prem = visibleProduct(MonetizationConfig.WIN_PASS.premiumProduct)
	if prem and not wp.premium and type(prem.price) == "number" then
		local b = button(top, "GetPremium", "PREMIUM R$ " .. tostring(prem.price), "robux", true, "pass")
		b.LayoutOrder = 9
		b.Size = UDim2.fromOffset(if L.compact then 190 else 240, chipH + 4)
		b.Activated:Connect(function()
			buyProduct(prem)
		end)
	end
	local list = listArea(chipH + 8)
	local rowH = if L.compact then 56 else 104 -- round 3: desktop rows tall enough for the type scale
	for i, r in GarageModel.winPassRows(wp) do
		local row = ArcadeUi.card(list, { name = "Tier_" .. r.tier, radius = 12, size = UDim2.new(1, -4, 0, rowH), layoutOrder = i, strokeColor = if r.reached then C.gold else nil })
		-- Tier badge and progress to it.
		local badgeW = if L.compact then 82 else 120
		local tl = ArcadeUi.text(row, { name = "Tier", text = tostring(r.tier), font = FONT.display, maxSize = if L.compact then 26 else 34, color = if r.reached then GOLD else CREAM, align = Enum.TextXAlignment.Center, stroke = 2.5 })
		tl.Position = UDim2.fromOffset(6, 2)
		tl.Size = UDim2.new(0, badgeW - 12, 0.62, 0)
		local track = Instance.new("Frame")
		track.Name = "Track"
		track.BackgroundColor3 = C.inset
		track.BorderSizePixel = 0
		track.Position = UDim2.new(0, 10, 0.66, 0)
		track.Size = UDim2.new(0, badgeW - 20, 0, if L.compact then 8 else 10)
		track.Parent = row
		ArcadeUi.corner(track, UDim.new(0.5, 0))
		ArcadeUi.stroke(track, 1.5)
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(math.clamp(math.min(races, r.tier) / math.max(1, r.tier), 0, 1), 1)
		fill.Parent = track
		ArcadeUi.corner(fill, UDim.new(0.5, 0))
		ArcadeUi.gradient(fill, C.headerTop, C.headerBot, 0)
		local pl = text(row, "Progress", string.format("%d/%d RACES", math.min(races, r.tier), r.tier), false, 12)
		pl.Position = UDim2.new(0, 8, 0.66, if L.compact then 9 else 12)
		pl.Size = UDim2.new(0, badgeW - 16, 0, if L.compact then 12 else 16)
		pl.TextColor3 = MUTED
		pl.TextXAlignment = Enum.TextXAlignment.Center
		local cellW = math.floor((L.content.w - 24 - badgeW) / 2)
		for ci, column in { "free", "premium" } do
			local cell = (r :: any)[column]
			local holder = ArcadeUi.card(row, {
				name = column,
				inset = true,
				radius = 10,
				position = UDim2.new(0, badgeW + (ci - 1) * (cellW + 4), 0, 4),
				size = UDim2.new(0, cellW - 4, 1, -8),
			})
			if column == "premium" then
				holder.BackgroundColor3 = Color3.fromHex("3A2470")
			end
			if cell then
				local spec = WP_STATUS[cell.status] or WP_STATUS.locked
				local ic = KIND_ICON[cell.kind] or "star"
				local s = rowH - 16
				ArcadeUi.icon(holder, ic, { name = "Kind", anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 4, 0.5, 0), size = UDim2.fromOffset(s, s) }, s)
				local b = button(holder, "Claim", spec.label, spec.variant, spec.enabled, spec.icon)
				b.AnchorPoint = Vector2.new(1, 0.5)
				b.Position = UDim2.new(1, -4, 0.5, 0)
				b.Size = UDim2.fromOffset(if L.compact then 96 else 170, math.min(if L.compact then 44 else 60, rowH - 12))
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
				local n = text(holder, "Name", cell.name, true, if L.compact then 13 else 17)
				n.Position = UDim2.fromOffset(s + 10, 2)
				n.Size = UDim2.new(1, -(s + 10 + (if L.compact then 104 else 136)), 0.55, 0)
				n.TextTruncate = Enum.TextTruncate.AtEnd
				local k = text(holder, "Column", (if column == "free" then "FREE  " else "PREMIUM  ") .. GarageModel.kindLabel(cell.kind), false, 12)
				k.Position = UDim2.new(0, s + 10, 0.55, 0)
				k.Size = UDim2.new(1, -(s + 10 + (if L.compact then 104 else 136)), 0.4, 0)
				k.TextColor3 = if column == "premium" then GOLD else MUTED
			end
		end
	end
end

---------------------------------------------------------------------------------------------------- daily

local function renderDaily()
	local daily = st.daily or {}
	local chipH = if L.compact then 30 else 44
	local top = chipRow("Streak", chipH)
	local _, streak = chip(top, "StreakChip", "star", "", chipH, GOLD)
	local _, newDay = chip(top, "NewDayChip", "clock", "", chipH)
	table.insert(tickers, function()
		local left = (daily.resetsAt or 0) - serverNow(st, stClock)
		streak.Text = string.format("STREAK %d", daily.streak or 0)
		newDay.Text = "NEW DAY " .. GarageModel.formatCountdown(left)
	end)
	-- Seven tiles: claimed (check), today (gold rim, punches), upcoming.
	local tileH = if L.compact then 84 else math.min(math.floor(L.dailyCellW * 1.1), 260) -- round 3: day tiles fill the width
	local strip7 = Instance.new("Frame")
	strip7.Name = "Days"
	strip7.BackgroundTransparency = 1
	strip7.Position = UDim2.fromOffset(0, chipH + 10)
	strip7.Size = UDim2.fromOffset(L.content.w, tileH)
	strip7.Parent = content
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.Padding = UDim.new(0, L.gap)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = strip7
	local cw = math.floor((L.content.w - 6 * L.gap) / 7)
	local tiles: { GuiObject } = {}
	for _, c in GarageModel.dailyCells(daily) do
		local today = c.state == "today"
		local cell = ArcadeUi.card(strip7, {
			name = "Day" .. c.day,
			layoutOrder = c.day,
			size = UDim2.fromOffset(cw, tileH),
			radius = 12,
			top = if today then Color3.fromHex("FFB52E") elseif c.state == "claimed" then Color3.fromHex("2E8A4A") else nil,
			bottom = if today then Color3.fromHex("F57C00") elseif c.state == "claimed" then Color3.fromHex("1B5A30") else nil,
			strokeColor = if today then C.gold else nil,
			strokeWidth = if today then 4 else 3,
		})
		table.insert(tiles, cell)
		local d = ArcadeUi.text(cell, { name = "Day", text = "DAY " .. c.day, font = FONT.display, maxSize = if L.compact then 13 else 18, align = Enum.TextXAlignment.Center, stroke = 1.5 })
		d.Position = UDim2.fromScale(0.05, 0.03)
		d.Size = UDim2.fromScale(0.9, 0.2)
		local icS = math.floor(math.min(cw * 0.6, tileH * 0.42))
		ArcadeUi.icon(cell, if c.trail then "trail" else "coins", { name = "Reward", anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromOffset(icS, icS) }, icS)
		local g = ArcadeUi.text(cell, { name = "Gears", text = "+" .. cashText(c.gears), font = FONT.display, maxSize = if L.compact then 14 else 22, color = GOLD, align = Enum.TextXAlignment.Center, stroke = 2 })
		g.Position = UDim2.fromScale(0.05, 0.75)
		g.Size = UDim2.fromScale(0.9, 0.2)
		if c.state == "claimed" then
			local s = math.floor(icS * 0.7)
			ArcadeUi.icon(cell, "check", { name = "Claimed", anchor = Vector2.new(1, 0), position = UDim2.new(1, -2, 0.18, 0), size = UDim2.fromOffset(s, s), z = 3 }, s)
		end
	end
	ArcadeUi.stagger(tiles, 0.04, 0.7)
	local claimY = chipH + 10 + tileH + 10
	local claimRow = Instance.new("Frame")
	claimRow.Name = "ClaimRow"
	claimRow.BackgroundTransparency = 1
	claimRow.Position = UDim2.fromOffset(0, claimY)
	claimRow.Size = UDim2.fromOffset(L.content.w, if L.compact then 44 else 56)
	claimRow.Parent = content
	if daily.claimedToday then
		local t = text(claimRow, "Claimed", "Come back tomorrow", true, if L.compact then 16 else 22)
		t.Size = UDim2.fromScale(1, 1)
		t.TextXAlignment = Enum.TextXAlignment.Center
		t.TextColor3 = MUTED
	else
		local b = button(claimRow, "ClaimDaily", string.format("CLAIM +%s", cashText(daily.nextReward or 0)), "go", true, "gift")
		b.AnchorPoint = Vector2.new(0.5, 0)
		b.Position = UDim2.fromScale(0.5, 0)
		b.Size = UDim2.new(0, math.min(360, L.content.w - 6), 1, 0)
		UiSound.setKind(b, "confirm")
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
	-- What else pays today: Rally Streak, passes, Festival, Storm Cup (icon chips).
	local extrasY = claimY + (if L.compact then 44 else 56) + 10
	local ex = Instance.new("ScrollingFrame")
	ex.Name = "Extras"
	ex.BorderSizePixel = 0
	ex.ScrollBarThickness = 4
	ex.CanvasSize = UDim2.new()
	ex.AutomaticCanvasSize = Enum.AutomaticSize.Y
	ex.Selectable = false
	ex.BackgroundTransparency = 1
	ex.Position = UDim2.fromOffset(0, extrasY)
	ex.Size = UDim2.fromOffset(L.content.w, math.max(0, L.content.h - extrasY))
	ex.Parent = content
	local el = Instance.new("UIGridLayout")
	el.CellSize = UDim2.fromOffset(math.floor((L.content.w - L.gap) / 2), chipH)
	el.CellPadding = UDim2.fromOffset(L.gap, 6)
	el.SortOrder = Enum.SortOrder.LayoutOrder
	el.Parent = ex
	local features = if type(st.features) == "table" then st.features else {}
	local rally = st.rallyStreak or 0
	local every = MonetizationConfig.GEARS.rallyStreak.every
	local fl: TextLabel? = nil
	local cl: TextLabel? = nil
	if features.rallyStreak ~= false then
		local f = chip(ex, "Rally", "flag", string.format("RALLY %d/%d  x%s", rally % every, every, tostring(MonetizationConfig.GEARS.rallyStreak.multiplier)), chipH)
		f.LayoutOrder = 1
	end
	if hasPass("x2Gears") then
		local f = chip(ex, "Double", "cash", "2x CASH ACTIVE", chipH, GREEN_RIM)
		f.LayoutOrder = 2
	end
	if features.festival ~= false then
		local f, l = chip(ex, "Festival", "star", "", chipH)
		f.LayoutOrder = 3
		fl = l
	end
	local f2, l2 = chip(ex, "StormCup", "trophy", "", chipH)
	f2.LayoutOrder = 4
	cl = l2
	table.insert(tickers, function()
		local now = serverNow(st, stClock)
		local fest = st.festival
		local nextFest = st.nextFestival
		if fl then
			if type(fest) == "table" and (fest.endsAt or 0) > now then
				fl.Text = string.format("%s x%s  %s", string.upper(tostring(fest.name)), tostring(fest.multiplier), GarageModel.formatCountdown(fest.endsAt - now))
				fl.TextColor3 = GOLD
			elseif type(nextFest) == "table" then
				fl.Text = string.format("%s IN %s", string.upper(tostring(nextFest.name)), GarageModel.formatCountdown((nextFest.startsAt or now) - now))
				fl.TextColor3 = CREAM
			else
				fl.Text = "NO FESTIVAL"
				fl.TextColor3 = MUTED
			end
		end
		-- The cup as server/StormCup publishes it (the map that will really run; nothing while the cup is off).
		local at = workspace:GetAttribute("StormCupAt")
		if cl then
			if workspace:GetAttribute("StormCupEnabled") == true and type(at) == "number" then
				local info = TrackInfo.get(workspace:GetAttribute("StormCupTrack") :: string?)
				local modifier = GarageModel.STORM_MODIFIER_LABEL[tostring(workspace:GetAttribute("StormCupModifier"))] or "STORM"
				local wsNow = workspace:GetServerTimeNow()
				cl.Text = string.format("CUP %s  %s %s", if at <= wsNow then "NOW" else GarageModel.formatCountdown(at - wsNow), if info then string.upper(info.trackName) else "?", modifier)
			else
				cl.Text = "NO STORM CUP"
				cl.TextColor3 = MUTED
			end
		end
	end)
end

---------------------------------------------------------------------------------------------------- render

-- round 3 backdrop: the VEHICLES tab drops the panel fill so the hero stands over the live world, and a diagonal navy
-- wedge carries the header, tabs and cards (Synty "Modern Menus" main menu). Every other tab keeps the framed panel.
-- The world behind any open Garage is blurred (a Camera BlurEffect; client only).
local heroWedge: Frame? = nil
local blur: BlurEffect? = nil
setBlur = function(on: boolean)
	local cam = workspace.CurrentCamera
	if on and cam and not (blur and blur.Parent == cam) then
		if blur then
			blur:Destroy()
		end
		local b = Instance.new("BlurEffect")
		b.Name = "GarageBlur"
		b.Size = 0
		b.Parent = cam
		blur = b
	end
	local b = blur
	if b then
		local tw = TweenService:Create(b, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = if on then 10 else 0 })
		tw:Play()
		if not on then
			tw.Completed:Connect(function()
				if blur == b and not isOpen then
					b:Destroy()
					blur = nil
				end
			end)
		end
	end
end
local function setHeroBackdrop(on: boolean)
	local skin = panel:FindFirstChild("SkinFrame")
	if skin and skin:IsA("ImageLabel") then
		skin.Visible = not on
	end
	local gr = panel:FindFirstChildOfClass("UIGradient")
	if gr then
		gr.Enabled = not on
	end
	panel.BackgroundTransparency = if on then 1 else 0
	local w = heroWedge
	if w then
		w.Visible = on
		local edge = w:FindFirstChild("Edge") :: Frame?
		if on and edge and L then
			-- The slab leans -8 degrees about its centre: its left edge runs down and to the right, meeting the card
			-- column's left side at the bottom of the content (x0 solved from the rotation; see the slab in build()).
			local hx = L.content.x + math.floor(L.content.w * (if L.compact then 0.4 else 0.42)) + L.gap
			local H = L.panel.h
			local w = L.panel.w * 1.5
			local phi = math.rad(8)
			local yb = L.content.y + L.content.h
			local x0 = hx - (w / 2) * (1 - math.cos(phi)) - (yb - H / 2 - (w / 2) * math.sin(phi)) * math.tan(phi)
			edge.Position = UDim2.fromOffset(math.floor(x0), -H)
		end
	end
end

render = function()
	if not isOpen then
		return
	end
	table.clear(tickers)
	-- Gamepad: remember the card / button selection sat on (names are key-based), to land on it again after the rebuild.
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
	gearsLabel.Text = cashText(gears())
	setHeroBackdrop(activeTab == "vehicles")
	if st == nil then
		emptyLine(content, "Loading your Garage...")
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
	infoLabel.Text = table.concat(info, "  ")
	infoLabel.Visible = #info > 0 and not L.compact
	for _, fn in tickers do
		fn()
	end
	-- Rebuilt cards drop a gamepad selection that sat on them: the same card's button, else the active tab.
	UiSound.hush() -- landing selection back on a rebuilt card is not a D-pad move: no marimba note
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
	local closeW = h.h + 8
	local gearW = h.h
	local cashW = if L.compact then 150 else 220
	titleBand.Position = UDim2.fromOffset(h.x, h.y)
	titleBand.Size = UDim2.fromOffset(if L.compact then 190 else 300, h.h)
	local bt = titleBand:FindFirstChild("Title") :: TextLabel?
	if bt then
		bt.Position = UDim2.fromOffset(math.floor(h.h * 1.25), 0)
		bt.Size = UDim2.new(1, -math.floor(h.h * 1.25) - 8, 1, 0)
	end
	closeButton.Position = UDim2.fromOffset(h.x + h.w - closeW, h.y)
	closeButton.Size = UDim2.fromOffset(closeW, h.h)
	-- The gear sits left of CLOSE, a square the height of the header (a thumb-sized target on a phone).
	gearButton.Position = UDim2.fromOffset(h.x + h.w - closeW - 8 - gearW, h.y)
	gearButton.Size = UDim2.fromOffset(gearW, h.h)
	cashPlate.Position = UDim2.fromOffset(h.x + h.w - closeW - gearW - 16 - cashW, h.y + 4)
	cashPlate.Size = UDim2.fromOffset(cashW, h.h - 8)
	local titleRight = h.x + (if L.compact then 190 else 300) + 10
	infoLabel.Position = UDim2.fromOffset(titleRight, h.y + 8)
	infoLabel.Size = UDim2.fromOffset(math.max(0, h.x + h.w - closeW - gearW - cashW - 26 - titleRight), h.h - 16)
	local mode = LocalPlayer:GetAttribute("InputMode")
	local hintW = if mode == "Touch" or L.compact then 0 else 46
	for i, hl in bumperHints do
		hl.Visible = hintW > 0
		hl.Text = if mode == "Gamepad" then (if i == 1 then "LB" else "RB") else (if i == 1 then "Q" else "E")
		hl.Size = UDim2.fromOffset(hintW - 8, math.floor(L.tabs.h * 0.6))
		hl.Position = UDim2.fromOffset(if i == 1 then L.tabs.x else L.tabs.x + L.tabs.w - hintW + 8, L.tabs.y + math.floor(L.tabs.h * 0.2))
	end
	tabsFrame.Position = UDim2.fromOffset(L.tabs.x + hintW, L.tabs.y)
	tabsFrame.Size = UDim2.fromOffset(L.tabs.w - 2 * hintW, L.tabs.h)
	local shrink = if L.compact then 1 else (L.tabs.w - 2 * hintW) / math.max(1, L.tabs.w)
	local x = 0
	for _, t in GarageModel.TABS do
		local b = tabButtons[t.id]
		local w = if L.compact then (if t.id == activeTab then L.tabWide else L.tabUnit) else math.floor(L.tabW * shrink)
		b.Position = UDim2.fromOffset(x, 0)
		b.Size = UDim2.fromOffset(w, L.tabs.h)
		tabLook(b, t.id == activeTab)
		x += w + L.gap
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
	hubButton.Size = UDim2.fromOffset(hb.w, hb.h + 4)
	-- The Cash badge rides the GARAGE key's bottom edge (round 2: hanging under it, it sat on the touch RESPAWN key).
	local cashHub = gearsChip.Parent :: Frame
	local ch = if vp.Y >= 600 then 30 else 22
	local onEdge = hsnap.kind == "touch" -- touch: the RESPAWN key sits under the hub button's old Cash line
	cashHub.AnchorPoint = Vector2.new(1, if onEdge then 0.5 else 0)
	cashHub.Position = UDim2.fromOffset(hb.x + hb.w - 4, if onEdge then hb.y + hb.h + 6 else hb.y + hb.h + 10)
	cashHub.ZIndex = 3
	cashHub.Size = UDim2.fromOffset(math.floor(hb.w * 0.62), ch)
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

	-- Hub: the GARAGE key (orange, wrench) under ADVENTURE and the Cash counter (coin + number) under it.
	hubButton = ArcadeUi.button(gui, "orange", "GARAGE", { name = "GarageButton", icon = "wrench", sound = "tab", maxText = 24, visible = false })
	hubButton.Activated:Connect(function()
		Garage.toggle()
	end)
	local cashHub = Instance.new("Frame")
	cashHub.Name = "CashChip"
	cashHub.BackgroundColor3 = C.inset
	cashHub.BackgroundTransparency = 0.15
	cashHub.Visible = false
	cashHub.Parent = gui
	ArcadeUi.corner(cashHub, UDim.new(0.5, 0))
	ArcadeUi.stroke(cashHub, 2.5)
	local coin = ArcadeUi.icon(cashHub, "coin", { name = "Coin", anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -6, 0.5, 0), size = UDim2.fromScale(1.35, 1.35) }, 40)
	coin.SizeConstraint = Enum.SizeConstraint.RelativeYY
	gearsChip = ArcadeUi.text(cashHub, { name = "GearsChip", text = "", font = FONT.display, maxSize = 22, color = GOLD, align = Enum.TextXAlignment.Right, stroke = 2 })
	gearsChip.Position = UDim2.new(0, 0, 0, 0)
	gearsChip.Size = UDim2.new(1, -12, 1, 0)

	panel = ArcadeUi.card(nil, { name = "GaragePanel", radius = 18, strokeWidth = 4 })
	panel.Visible = false
	panel.Active = true
	-- Gamepad selection never wanders out to the HUD or the results panel under it.
	panel.SelectionGroup = true
	panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	panel.Parent = gui
	-- The hero backdrop wedge (setHeroBackdrop): a clipped holder with one tall navy slab rotated a few degrees.
	local wedge = Instance.new("Frame")
	wedge.Name = "HeroWedge"
	wedge.BackgroundTransparency = 1
	wedge.Size = UDim2.fromScale(1, 1)
	wedge.ClipsDescendants = true
	wedge.ZIndex = 0
	wedge.Visible = false
	wedge.Active = false
	wedge.Parent = panel
	local slab = Instance.new("Frame")
	slab.Name = "Edge"
	slab.BorderSizePixel = 0
	slab.BackgroundColor3 = C.panelBot
	slab.BackgroundTransparency = 0
	slab.Size = UDim2.new(1.5, 0, 3, 0)
	slab.Rotation = -8
	slab.Active = false
	slab.Parent = wedge
	ArcadeUi.gradient(slab, C.panelTop, C.panelBot, 0)
	local rim = Instance.new("Frame")
	rim.Name = "Rim"
	rim.BorderSizePixel = 0
	rim.BackgroundColor3 = C.steel
	rim.Size = UDim2.new(0, 3, 1, 0)
	rim.Active = false
	rim.Parent = slab
	heroWedge = wedge
	local band = ArcadeUi.band(panel, "GARAGE", { name = "TitleBand", maxText = 36 })
	local bandTitle = band:FindFirstChild("Title") :: TextLabel
	bandTitle.Position = UDim2.new(0.22, 0, 0, 0)
	bandTitle.Size = UDim2.new(0.76, 0, 1, 0)
	local wrench = ArcadeUi.icon(band, "wrench", { name = "Wrench", anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 4, 0.5, 0), size = UDim2.fromScale(1.2, 1.2) }, 56)
	wrench.SizeConstraint = Enum.SizeConstraint.RelativeYY
	titleBand = band
	cashPlate = Instance.new("Frame")
	cashPlate.Name = "Cash"
	cashPlate.BackgroundColor3 = C.inset
	cashPlate.BackgroundTransparency = 0.1
	cashPlate.Parent = panel
	ArcadeUi.corner(cashPlate, UDim.new(0.5, 0))
	ArcadeUi.stroke(cashPlate, 2.5)
	local pc = ArcadeUi.icon(cashPlate, "coin", { name = "Coin", anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -4, 0.5, 0), size = UDim2.fromScale(1.25, 1.25) }, 48)
	pc.SizeConstraint = Enum.SizeConstraint.RelativeYY
	gearsLabel = ArcadeUi.text(cashPlate, { name = "Gears", text = "", font = FONT.display, maxSize = 28, color = GOLD, align = Enum.TextXAlignment.Right, stroke = 2 })
	gearsLabel.Size = UDim2.new(1, -16, 1, 0)
	infoLabel = text(panel, "Info", "", true, 16)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Right
	infoLabel.TextColor3 = GREEN_RIM
	closeButton = ArcadeUi.button(panel, "danger", "", { name = "CloseGarage", icon = "close", iconOnly = true, sound = "back" })
	closeButton.Activated:Connect(function()
		close()
	end)
	gearButton = Settings.makeGearButton(panel, "SettingsGear")
	for i = 1, 2 do
		local hl = Instance.new("TextLabel")
		hl.Name = if i == 1 then "BumperL" else "BumperR"
		hl.BackgroundColor3 = C.steel
		hl.TextColor3 = C.ink
		hl.FontFace = FONT.display
		hl.TextScaled = true
		hl.Text = ""
		hl.Parent = panel
		ArcadeUi.corner(hl, 4)
		bumperHints[i] = hl
	end
	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(function()
		applyLayout()
	end)
	tabsFrame = Instance.new("Frame")
	tabsFrame.Name = "Tabs"
	tabsFrame.BackgroundTransparency = 1
	tabsFrame.Parent = panel
	for i, t in GarageModel.TABS do
		local b = ArcadeUi.button(tabsFrame, "navy", t.label, { name = "Tab_" .. t.id, icon = TAB_ICON[t.id] or "star", sound = "tab", maxText = 18, minText = 10 })
		b.LayoutOrder = i
		tabButtons[t.id] = b
		b.Activated:Connect(function()
			if activeTab ~= t.id then
				-- The page slides over: a soft swipe under the tab flip.
				UiSound.play(UiSkinRules.cueFor("swipe") or "swipe", nil, 0.7)
				setTab(t.id)
				applyLayout()
				local s = ArcadeUi.uiScale(content)
				s.Scale = 0.96
				TweenService:Create(s, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)
	end
	content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Selectable = false
	content.ClipsDescendants = true
	content.Parent = panel
	applyLayout()
	-- Studio-only capture hook (UI v2 verification): the lane sets SkyRallyGarage.QATab to open a tab, "" closes.
	if RunService:IsStudio() then
		gui:GetAttributeChangedSignal("QATab"):Connect(function()
			local t = gui:GetAttribute("QATab")
			if t == "" then
				close(true)
			elseif type(t) == "string" then
				if isOpen then
					setTab(t)
					applyLayout()
				else
					Garage.open(t)
				end
			end
		end)
		gui:GetAttributeChangedSignal("QAClass"):Connect(function()
			local c = gui:GetAttribute("QAClass")
			if type(c) == "string" then
				avClass = c
				avFocus = nil
				render()
			end
		end)
	end
end

local function hookResults()
	task.spawn(function()
		local hud = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("SkyRallyHUD", 30)
		local modal = hud and hud:FindFirstChild("FinishPositionScreen", true)
		if not modal or not modal:IsA("GuiObject") then
			return
		end
		local tab = ArcadeUi.button(modal, "orange", "GARAGE", { name = "GarageTab", icon = "wrench", sound = "tab", maxText = 18 })
		tab.AnchorPoint = Vector2.new(0, 0)
		tab.Position = UDim2.new(1, 4, 0, 12)
		tab.Size = UDim2.fromOffset(132, 48)
		-- UI v2 (coordinator 2026-11-10): the tab and its Cash line covered the card's TOTAL / BEST LAP and reward chips at
		-- 844x390; the card shows the Cash earned itself, so both stay hidden (G / L3 still open the Garage there).
		tab.Visible = false
		tab.Activated:Connect(function()
			Garage.open()
		end)
		resultsTab = tab
		local g = ArcadeUi.text(modal, { name = "GarageGears", text = "", font = FONT.display, maxSize = 16, color = GOLD, align = Enum.TextXAlignment.Center, stroke = 2 })
		g.Position = UDim2.new(1, 4, 0, 64)
		g.Size = UDim2.fromOffset(132, 22)
		g.Visible = false
		resultsGears = g
	end)
end

local function onRaceEvent(kind: any, payload: any)
	local g = resultsGears
	if kind == "RaceFinished" and g then
		local earned = if type(payload) == "table" and type(payload.gears) == "table" then payload.gears else nil
		if false and earned and type(earned.gears) == "number" and garageEnabled() then
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
	local hud = LocalPlayer.PlayerGui:FindFirstChild("SkyRallyHUD")
	local card = hud and hud:FindFirstChild("FinishPositionScreen", true)
	local cardUp = card ~= nil and card:IsA("GuiObject") and card.Visible
	hub = hub and not cardUp -- never over the results card
	hubButton.Visible = on and hub
	local cashHub = gearsChip.Parent :: GuiObject
	cashHub.Visible = on and hub and not isOpen -- the open panel shows the Cash itself (the hub chip ran over CARS at 844x390)
	gearsChip.Text = GarageModel.formatGears(gears())
	if resultsTab then
		resultsTab.Visible = false -- see hookResults
	end
	if isOpen then
		local ok = GarageModel.canOpen(openContext())
		if not ok then
			close(true)
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
			gearsLabel.Text = GarageModel.formatGears(gears())
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
				close(true)
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
