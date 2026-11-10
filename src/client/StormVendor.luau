--!strict
-- The Storm vendor panel (economy v3 phase 5): opened by the hub stand's prompt (server/StormVendorStand ->
-- StormEvent "OpenVendor"). Garage-style: a header with the Storm Shards balance and the storm rank, one tab per
-- reputation tier (Squall / Gale / Tempest / Eye of the Storm; a tier above the player's rank shows its rows locked
-- with the Shards still needed), and one row per item: name, type, price, and BUY / OWNED / EQUIP / EQUIPPED /
-- "EQUIP IN GARAGE" (tints, trails, horns and finish emotes are equipped in the Garage like every other cosmetic).
-- Rows whose look is not drawn yet say LOOK COMING SOON (StormConfig.SELL_PENDING_LOOKS).
-- Every number comes from the server (SkyRallyRemotes.StormRequest); every action is a request server/StormShards
-- validates. Look: NotifySkin.PANELS.stormVendor (owner art drops in there). Layout: StormRules.panelLayout (44 px targets,
-- phone-compact). Toasts: NotifyKit from NotifySpec rows (shard_gain, dragon_beaten, shard_tier_up, vendor_*).
-- Input: B / gamepad B closes; buttons are Selectable and selection stays in the panel (SelectionGroup).
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local StormRules = require(Shared:WaitForChild("StormRules"))
local StormConfig = require(Shared:WaitForChild("StormConfig"))
local NotifySkin = require(Shared:WaitForChild("NotifySkin"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local LocalPlayer = Players.LocalPlayer

local StormVendor = {}

local SKIN = NotifySkin.PANELS.stormVendor
local CLOSE_ACTION = "SkyRallyStormVendorClose"

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function font(name: string): Enum.Font
	local ok, f = pcall(function(): any
		return (Enum.Font :: any)[name]
	end)
	return if ok and f then f else Enum.Font.GothamBold
end

local request: RemoteFunction? = nil
local gui: ScreenGui? = nil
local panel: Frame? = nil
local st: any = nil
local activeTier = "squall"
local isOpen = false
local busy = false

local function invoke(action: string, ...: any): any
	local remote = request
	if not remote then
		return { ok = false, reason = "offline" }
	end
	local args = table.pack(...)
	local ok, reply = pcall(function()
		return remote:InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if not ok or type(reply) ~= "table" then
		return { ok = false, reason = "offline" }
	end
	return reply
end

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
end

-- With `name`, an existing child of that name and class is reused and refreshed in place (the header never grows a second label).
local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3, f: Enum.Font, maxText: number, align: Enum.TextXAlignment?, name: string?): TextLabel
	local found = if name then parent:FindFirstChild(name) else nil
	local l: TextLabel = if found and found:IsA("TextLabel") then found else Instance.new("TextLabel")
	if name then
		l.Name = name
	end
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Text = text
	l.TextColor3 = color
	l.Font = f
	l.TextScaled = true
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	local lim = l:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
	lim.MaxTextSize = maxText
	lim.MinTextSize = 9
	lim.Parent = l
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, color: Color3, enabled: boolean, onClick: (() -> ())?): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = enabled
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = rgb(SKIN.buttonText)
	b.Font = font(SKIN.font)
	b.TextScaled = true
	b.Selectable = enabled
	local lim = Instance.new("UITextSizeConstraint")
	lim.MaxTextSize = 18
	lim.MinTextSize = 9
	lim.Parent = b
	corner(b, 6)
	UiSound.bind(b, if enabled then "tap" else "deny")
	if onClick and enabled then
		b.Activated:Connect(onClick)
	end
	b.Parent = parent
	return b
end

local render: () -> ()

local function fetch(): boolean
	local reply = invoke("GetState")
	if reply.ok and type(reply.data) == "table" then
		st = reply.data
		if type(st.owned) ~= "table" then
			st.owned = {}
		end
		if type(st.loadout) ~= "table" then
			st.loadout = {}
		end
		return true
	end
	return false
end

local function owned(key: string): boolean
	return st ~= nil and table.find(st.owned, key) ~= nil
end

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
			UiSound.play("deny")
			NotifyKit.toast(if reply.reason == "rateLimited" then "One moment" else "Not available", { kind = "warn", priority = "normal", seconds = 2 })
		end
		fetch()
		if isOpen then
			render()
		end
	end)
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	if gui then
		gui.Enabled = false
	end
	ContextActionService:UnbindAction(CLOSE_ACTION)
	if GuiService.SelectedObject and panel and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
	UiSound.play("back")
end

local function closeAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		close()
	end
	return Enum.ContextActionResult.Sink
end

local function kindLabel(kind: string): string
	local kd = StormRules.kind(kind)
	return if kd then kd.label else kind
end

local function rowFor(parent: Instance, it: StormConfig.Item, order: number, rowH: number, tierOpen: boolean)
	local r = Instance.new("Frame")
	r.Name = it.key
	r.LayoutOrder = order
	r.Size = UDim2.new(1, 0, 0, rowH)
	r.BackgroundColor3 = if tierOpen then rgb(SKIN.row.color) else rgb(SKIN.rowLocked)
	r.BackgroundTransparency = SKIN.row.alpha
	r.BorderSizePixel = 0
	corner(r, 6)
	r.Parent = parent
	local tierRow = StormRules.tierById(it.tier)
	local accent = Instance.new("Frame")
	accent.BorderSizePixel = 0
	accent.Size = UDim2.new(0, 5, 1, -8)
	accent.Position = UDim2.fromOffset(4, 4)
	accent.BackgroundColor3 = if tierRow then rgb(tierRow.color) else rgb(SKIN.muted)
	accent.Parent = r
	local textW = -130
	label(r, it.name, UDim2.new(1, textW - 16, 0.55, 0), UDim2.fromOffset(14, 2), if tierOpen then rgb(SKIN.text) else rgb(SKIN.muted), font(SKIN.font), 20)
	local sub = kindLabel(it.kind) .. "  -  " .. it.price .. " Shards"
	if it.comingSoon then
		sub = kindLabel(it.kind) .. "  -  COMING SOON"
	elseif not StormRules.drawnToday(it) then
		sub ..= "  -  LOOK COMING SOON"
	end
	label(r, sub, UDim2.new(1, textW - 16, 0.4, 0), UDim2.new(0, 14, 0.56, 0), rgb(SKIN.muted), font(SKIN.font), 14)

	local bw = 116
	local function place(b: TextButton)
		b.Size = UDim2.new(0, bw, 0, math.max(44, rowH - 10))
		b.Position = UDim2.new(1, -bw - 6, 0.5, -math.max(44, rowH - 10) / 2)
	end
	local state = { lifetime = st.lifetime, shards = st.shards, owned = {}, loadout = st.loadout } :: any
	for _, k in st.owned do
		state.owned[k] = true
	end
	if owned(it.key) then
		local kd = StormRules.kind(it.kind)
		if kd and kd.slot == "garage" then
			place(button(r, "EQUIP IN GARAGE", rgb(SKIN.owned), false))
		elseif kd and st.loadout[kd.slot] == it.key then
			place(button(r, "EQUIPPED", rgb(SKIN.owned), true, function()
				act("Equip", nil, kd.slot, "")
			end))
		elseif kd then
			place(button(r, "EQUIP", rgb(SKIN.owned), true, function()
				act("Equip", nil, kd.slot, it.key)
			end))
		end
		return
	end
	local ok, reason = StormRules.canBuy(state, nil, it.key)
	if ok then
		place(button(r, "BUY " .. it.price, rgb(SKIN.buy), true, function()
			act("Buy", function(d: any)
				NotifyKit.fromSpec("vendor_bought", { name = if type(d) == "table" then d.name else it.name })
			end, it.key)
		end))
	elseif reason == "short" then
		place(button(r, "BUY " .. it.price, rgb(SKIN.locked), true, function()
			UiSound.play("deny")
			NotifyKit.fromSpec("vendor_short", { n = it.price - (st.shards or 0) })
		end))
	elseif reason == "locked" then
		place(button(r, "LOCKED", rgb(SKIN.locked), true, function()
			UiSound.play("deny")
			NotifyKit.fromSpec("vendor_locked", { tier = if tierRow then tierRow.name else it.tier })
		end))
	else
		place(button(r, "SOON", rgb(SKIN.locked), false))
	end
end

render = function()
	local g = gui
	if not g or not st then
		return
	end
	-- One panel Frame for the session: stray copies are swept, the header labels are reused, and only the tabs and rows are rebuilt.
	for _, child in g:GetChildren() do
		if child.Name == "StormVendorPanel" and child ~= panel then
			child:Destroy()
		end
	end
	local size = g.AbsoluteSize
	local L = StormRules.panelLayout(size.X, size.Y, 0)
	local p = panel
	if not p or p.Parent ~= g then
		local fresh = Instance.new("Frame")
		fresh.Name = "StormVendorPanel"
		fresh.BackgroundColor3 = rgb(SKIN.panel.color)
		fresh.BackgroundTransparency = SKIN.panel.alpha
		fresh.BorderSizePixel = 0
		fresh.SelectionGroup = true
		corner(fresh, 10)
		if SKIN.panel.image then
			local img = Instance.new("ImageLabel")
			img.BackgroundTransparency = 1
			img.Size = UDim2.fromScale(1, 1)
			img.Image = SKIN.panel.image
			if SKIN.panel.slice then
				local s = SKIN.panel.slice
				img.ScaleType = Enum.ScaleType.Slice
				img.SliceCenter = Rect.new(s[1], s[2], s[3], s[4])
			end
			img.Parent = fresh
		end
		fresh.Parent = g
		panel = fresh
		p = fresh
	end
	local p: Frame = p :: Frame
	p.Position = UDim2.fromOffset(L.x, L.y)
	p.Size = UDim2.fromOffset(L.w, L.h)
	for _, nm in { "Tabs", "Rows" } do
		local old = p:FindFirstChild(nm)
		if old then
			old:Destroy()
		end
	end

	-- Header: title, Shards, rank, close (built once, refreshed in place).
	local headOld = p:FindFirstChild("Header")
	local head: Frame = if headOld and headOld:IsA("Frame") then headOld else Instance.new("Frame")
	if head.Parent ~= p then
		head.Name = "Header"
		head.BackgroundColor3 = rgb(SKIN.header)
		head.BorderSizePixel = 0
		corner(head, 10)
		head.Parent = p
	end
	head.Size = UDim2.new(1, 0, 0, L.header)
	local tier = StormRules.tierFor(st.lifetime or 0)
	local nxt, need = StormRules.nextTier(st.lifetime or 0)
	label(head, "STORM VENDOR", UDim2.new(0.5, 0, 0.55, 0), UDim2.fromOffset(L.pad + 4, 2), rgb(SKIN.title), font(SKIN.titleFont), 26, nil, "Title")
	local rank = "Rank: " .. tier.name .. (if nxt then string.format("  -  %d to %s", need, nxt.name) else "")
	label(head, rank, UDim2.new(0.62, 0, 0.4, 0), UDim2.new(0, L.pad + 4, 0.56, 0), rgb(tier.color), font(SKIN.font), 15, nil, "Rank")
	label(head, string.format("%d Storm Shards", st.shards or 0), UDim2.new(0.38, -60, 0.5, 0), UDim2.new(0.5, 0, 0, 4), rgb(SKIN.text), font(SKIN.font), 20, Enum.TextXAlignment.Right, "Shards")
	local xOld = head:FindFirstChild("Close")
	local x: TextButton = if xOld and xOld:IsA("TextButton") then xOld else button(head, "X", rgb(SKIN.locked), true, close)
	x.Name = "Close"
	x.Size = UDim2.fromOffset(44, 44)
	x.Position = UDim2.new(1, -50, 0.5, -22)

	-- Tier tabs.
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromOffset(L.pad, L.header + L.pad)
	tabs.Size = UDim2.new(1, -2 * L.pad, 0, L.tabs)
	tabs.Parent = p
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 6)
	list.Parent = tabs
	local n = #StormConfig.TIERS
	local myIdx = StormRules.tierIndex(st.lifetime or 0)
	local firstTab: TextButton? = nil
	for i, t in StormConfig.TIERS do
		local open = i <= myIdx
		local text = if open then string.upper(t.name) else string.format("%s %d", string.upper(t.name), t.at)
		local b = button(tabs, text, if t.id == activeTier then rgb(t.color) else rgb(SKIN.header), true, function()
			activeTier = t.id
			render()
		end)
		b.Size = UDim2.new(1 / n, -6, 1, 0)
		b.LayoutOrder = i
		if t.id == activeTier then
			b.TextColor3 = rgb({ 20, 20, 30 })
			firstTab = b
		end
	end

	-- Rows of the active tier.
	local top = L.header + L.pad + L.tabs + L.pad
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(L.pad, top)
	scroll.Size = UDim2.new(1, -2 * L.pad, 1, -top - L.pad)
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Selectable = false
	scroll.Parent = p
	local rows = Instance.new("UIListLayout")
	rows.Padding = UDim.new(0, 6)
	rows.SortOrder = Enum.SortOrder.LayoutOrder
	rows.Parent = scroll
	local _, tIdx = StormRules.tierById(activeTier)
	for i, it in StormRules.page(activeTier) do
		rowFor(scroll, it, i, L.row, tIdx <= myIdx)
	end
	if UserInputService.GamepadEnabled and isOpen then
		local sel = GuiService.SelectedObject
		if not sel or not sel:IsDescendantOf(p) then
			GuiService.SelectedObject = firstTab
		end
	end
end

function StormVendor.open()
	if workspace:GetAttribute("StormVendorEnabled") ~= true or RaceAttr.mine("RaceMode") ~= "hub" then
		return
	end
	task.spawn(function()
		if not fetch() then
			NotifyKit.toast("Storm vendor is loading", { kind = "warn", seconds = 2 })
			return
		end
		activeTier = StormRules.tierFor(st.lifetime or 0).id
		isOpen = true
		if gui then
			gui.Enabled = true
		end
		ContextActionService:BindAction(CLOSE_ACTION, closeAction, false, Enum.KeyCode.ButtonB)
		UiSound.play("tab")
		render()
	end)
end

function StormVendor.close()
	close()
end

function StormVendor.isOpen(): boolean
	return isOpen
end

-- StormEvent "Shards": the payout toast (dragon toast when the dragon was beaten), then one toast per tier reached.
local function onShards(d: any)
	if type(d) ~= "table" or type(d.n) ~= "number" then
		return
	end
	if d.beatDragon == true then
		NotifyKit.fromSpec("dragon_beaten", { n = d.n })
	else
		NotifyKit.fromSpec("shard_gain", { n = d.n })
	end
	if type(d.tierUps) == "table" then
		for _, name in d.tierUps do
			NotifyKit.fromSpec("shard_tier_up", { tier = name })
		end
	end
	if isOpen then
		task.spawn(function()
			fetch()
			render()
		end)
	end
end

function StormVendor.init()
	local folder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
	if not folder then
		return
	end
	request = folder:WaitForChild("StormRequest", 30) :: RemoteFunction?
	local event = folder:WaitForChild("StormEvent", 30) :: RemoteEvent?
	local g = Instance.new("ScreenGui")
	g.Name = "StormVendor"
	g.ResetOnSpawn = false
	g.DisplayOrder = 27 -- over the Garage (26), under Settings (30) and NotifyKit
	g.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	g.Enabled = false
	g.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = g
	g:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if isOpen then
			render()
		end
	end)
	if event then
		event.OnClientEvent:Connect(function(kind: string, payload: any)
			if kind == "OpenVendor" then
				StormVendor.open()
			elseif kind == "Shards" then
				onShards(payload)
			end
		end)
	end
	-- Leaving the hub (a race starts) closes the panel.
	RaceAttr.changed("RaceMode", function()
		if RaceAttr.mine("RaceMode") ~= "hub" then
			close()
		end
	end)
end

return StormVendor
