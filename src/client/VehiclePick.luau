--!strict
-- Pre-race vehicle pick (economy v3 phase 6). Hub declutter (owner 2026-10-21): docked bottom-left (HudLayoutRules
-- vehicleChip / vehicleStrip: left of the road band, above the controls), one "VEHICLE: <name> >" chip by default; tap
-- expands the strip, which folds back after a pick or COLLAPSE_SECONDS, and everything hides while the Garage is
-- open (the player's own filling lobby still shows it: that is the pick moment). A compact strip of the player's OWNED avatars for the class the next
-- track uses, the last pick preselected; one tap swaps (EconomyRequest "SelectAvatar"), and the race spawn builds that
-- avatar (server/AvatarSelect). It shows in the hub only: on an arch's apron when slowed down, and while the lobby this
-- player opened gathers racers (shared/VehiclePickRules). It never joins, starts or cancels anything. Looks come from
-- NotifySkin.PICKER so the owner's art drops in there; the full list lives in the Garage VEHICLES tab.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local AvatarConfig = require(Shared:WaitForChild("AvatarConfig"))
local VehiclePickRules = require(Shared:WaitForChild("VehiclePickRules"))
local NotifySkin = require(Shared:WaitForChild("NotifySkin"))
local GarageModel = require(Shared:WaitForChild("GarageModel"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local Prof = require(Shared:WaitForChild("Prof"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))

local LocalPlayer = Players.LocalPlayer
local SKIN: any = NotifySkin.PICKER

local VehiclePick = {}

local request: RemoteFunction? = nil
local gui: ScreenGui
local strip: Frame
local list: ScrollingFrame
local chip: TextButton
local expanded = false
local expandedAt = 0
local pickedWhileOpen = false

local data: any = nil -- GetAvatars reply data
local fetchedAt = -math.huge
local fetching = false
local busy = false
local shownClass: string? = nil
local shownKey = "" -- what the cards were built from (class + pick + owned list)
local dismissedFor: string? = nil -- context id the player closed the strip for
local contextId = ""
local arches: { { zone: string, cf: CFrame } } = {}
local archesFor = ""
local archesAt = -math.huge
local lastTick = 0
local warned = false

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
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

local function fetch()
	if fetching then
		return
	end
	fetching = true
	task.spawn(function()
		local reply = invoke("GetAvatars")
		fetching = false
		fetchedAt = os.clock()
		if reply.ok and type(reply.data) == "table" then
			data = reply.data
		end
	end)
end

local function ownedOf(class: string): { any }
	local out = {}
	local rows = if data and type(data.classes) == "table" then data.classes[class] else nil
	for _, v in (if type(rows) == "table" then rows else {}) do
		if v.owned then
			table.insert(out, v)
		end
	end
	return out
end

local function scanArches()
	local track = tostring(RaceAttr.mine("ActiveTrackId"))
	if track == archesFor and os.clock() - archesAt < 5 then
		return
	end
	archesFor = track
	archesAt = os.clock()
	table.clear(arches)
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(track)
	if not root then
		return
	end
	for _, d in root:GetDescendants() do
		local zone = string.match(d.Name, "^PortalShimmer_(%u+)$")
		if zone and d:IsA("BasePart") then
			table.insert(arches, { zone = zone, cf = d.CFrame })
		end
	end
end

local function classOfTrack(id: any): string?
	local info = TrackInfo.get(if type(id) == "string" then id else nil)
	return if info then info.vehicle else nil
end

---------------------------------------------------------------------------------------------------- UI

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallyVehiclePick"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundColor3 = rgb(SKIN.panel.color)
	strip.BackgroundTransparency = SKIN.panel.alpha
	strip.Visible = false
	strip.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, SKIN.corner)
	c.Parent = strip
	local s = Instance.new("UIStroke")
	s.Color = rgb(SKIN.rim)
	s.Thickness = 2
	s.Parent = strip
	if SKIN.panel.image then
		local img = Instance.new("ImageLabel")
		img.Name = "Art"
		img.BackgroundTransparency = 1
		img.Image = SKIN.panel.image
		img.Size = UDim2.fromScale(1, 1)
		if SKIN.panel.slice then
			img.ScaleType = Enum.ScaleType.Slice
			local sl = SKIN.panel.slice
			img.SliceCenter = Rect.new(sl[1], sl[2], sl[3], sl[4])
		end
		img.Parent = strip
	end

	chip = Instance.new("TextButton")
	chip.Name = "Chip"
	chip.BackgroundColor3 = rgb(SKIN.panel.color)
	chip.BackgroundTransparency = SKIN.panel.alpha
	chip.Font = (Enum.Font :: any)[SKIN.font]
	chip.TextScaled = true
	chip.TextColor3 = rgb(SKIN.header)
	chip.Text = ""
	chip.Visible = false
	chip.Parent = gui
	local cc2 = Instance.new("UICorner")
	cc2.CornerRadius = UDim.new(0, SKIN.corner)
	cc2.Parent = chip
	local cs = Instance.new("UIStroke")
	cs.Color = rgb(SKIN.rim)
	cs.Thickness = 2
	cs.Parent = chip
	local ctc = Instance.new("UITextSizeConstraint")
	ctc.MinTextSize = 12
	ctc.MaxTextSize = 20
	ctc.Parent = chip
	local cpad = Instance.new("UIPadding")
	cpad.PaddingLeft = UDim.new(0, 8)
	cpad.PaddingRight = UDim.new(0, 8)
	cpad.Parent = chip
	UiSound.bind(chip, "tap")
	chip.Activated:Connect(function()
		expanded = true
		expandedAt = os.clock()
		pickedWhileOpen = false
		shownKey = ""
	end)

	list = Instance.new("ScrollingFrame")
	list.Name = "Cards"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollingDirection = Enum.ScrollingDirection.X
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.X
	list.CanvasSize = UDim2.new()
	list.Parent = strip
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.Padding = UDim.new(0, 6)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = list
end

local function select(v: any)
	if busy or v.selected then
		return
	end
	busy = true
	task.spawn(function()
		local reply = invoke("SelectAvatar", v.key)
		busy = false
		if reply.ok and type(reply.data) == "table" and data then
			data.selected[reply.data.class] = reply.data.key
			for _, row in data.classes[reply.data.class] or {} do
				row.selected = row.key == reply.data.key
			end
			UiSound.play("confirm")
			NotifyKit.toast(string.format("%s ready", v.name), { kind = "success", seconds = 1.8 })
		else
			UiSound.play("deny")
			NotifyKit.toast(GarageModel.reasonText(reply.reason), { kind = "warn", seconds = 2 })
		end
		pickedWhileOpen = true -- the strip folds back into the chip on the next tick
		shownKey = "" -- rebuild the cards
	end)
end

local function render(class: string)
	local owned = ownedOf(class)
	local pick = if data and type(data.selected) == "table" then data.selected[class] else nil
	local keys = {}
	for _, v in owned do
		table.insert(keys, v.key)
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local id = string.format("%s|%s|%s|%dx%d|%s", class, tostring(pick), table.concat(keys, ","), vp.X, vp.Y, tostring(HudMetrics.rects().vehicleStrip.y))
	if id == shownKey then
		return
	end
	shownKey = id
	local rects = HudMetrics.rects()
	local rect = rects.vehicleStrip
	local cardW, cardH = VehiclePickRules.cardSize(rect, HudMetrics.S())
	strip.Position = UDim2.fromOffset(rect.x, rect.y)
	strip.Size = UDim2.fromOffset(rect.w, rect.h)
	local cr = rects.vehicleChip
	chip.Position = UDim2.fromOffset(cr.x, cr.y)
	chip.Size = UDim2.fromOffset(cr.w, cr.h)
	local pickName = "?"
	for _, v in owned do
		if v.key == pick then
			pickName = v.name
		end
	end
	chip.Text = string.format("VEHICLE: %s  >", pickName)
	local padY = math.floor((rect.h - cardH) / 2)
	list.Position = UDim2.fromOffset(6, padY)
	list.Size = UDim2.new(1, -12, 0, cardH)
	for _, ch in list:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	for i, v in owned do
		local on = v.key == pick
		local b = Instance.new("TextButton")
		b.Name = "Card_" .. v.key
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(cardW, cardH)
		b.BackgroundColor3 = rgb(if on then SKIN.cardSelected.color else SKIN.card.color)
		b.Font = (Enum.Font :: any)[SKIN.font]
		b.TextScaled = true
		b.TextWrapped = true
		b.TextColor3 = rgb(SKIN.cardText)
		b.Text = if on then v.name .. "\nSELECTED" else v.name
		b.Parent = list
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, SKIN.corner)
		cc.Parent = b
		local rs = Instance.new("UIStroke")
		rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		rs.Color = rgb(GarageModel.AVATAR_RARITY_RGB[v.rarity] or SKIN.cardText)
		rs.Thickness = if on then 3 else 1.5
		rs.Parent = b
		local tc = Instance.new("UITextSizeConstraint")
		tc.MaxTextSize = 18
		tc.MinTextSize = 9
		tc.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 4)
		pad.PaddingRight = UDim.new(0, 4)
		pad.Parent = b
		UiSound.bind(b, "tap")
		b.Activated:Connect(function()
			select(v)
		end)
	end
end

---------------------------------------------------------------------------------------------------- tick

local function tick()
	local enabled = AvatarConfig.ENABLED and LocalPlayer:GetAttribute("SaveState") == "ok"
	local mode = RaceAttr.mine("RaceMode")
	local lobbyClass: string? = nil
	local goAt = workspace:GetAttribute("LobbyGoAt")
	-- Only the lobby this player opened (another player's lobby never pops a strip on every hub screen).
	if type(goAt) == "number" and goAt > workspace:GetServerTimeNow() and workspace:GetAttribute("LobbyOpenerId") == LocalPlayer.UserId then
		lobbyClass = classOfTrack(workspace:GetAttribute("LobbyTrack"))
	end
	local apronClass: string? = nil
	local apronZone = ""
	local speed = 0
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if enabled and (mode == "hub" or mode == nil) and root and root:IsA("BasePart") and lobbyClass == nil then
		scanArches()
		speed = root.AssemblyLinearVelocity.Magnitude
		for _, a in arches do
			if VehiclePickRules.onApron(root.Position, a.cf) then
				local info = TrackInfo.forZone(a.zone)
				apronClass = if info then info.vehicle else nil
				apronZone = a.zone
				break
			end
		end
	end
	contextId = if lobbyClass then "lobby:" .. tostring(goAt) elseif apronClass then "apron:" .. apronZone else ""
	if contextId == "" then
		dismissedFor = nil
	end
	local wanted = lobbyClass or apronClass
	if enabled and wanted and (data == nil or os.clock() - fetchedAt > 30) then
		fetch()
	end
	-- Only the Garage hides the docked chip. A lobby / countdown banner sits in hub lane A (top), clear of the bottom-left
	-- dock, and the player's own filling lobby is exactly when the pick is wanted (lobbyClass above), so a lobby never hides it.
	local overlay = false
	local gm = script.Parent:FindFirstChild("Garage")
	if gm then
		local okG, Garage = pcall(require, gm)
		overlay = okG and type(Garage) == "table" and type(Garage.isOpen) == "function" and Garage.isOpen() == true
	end
	local show, class = VehiclePickRules.decide({
		overlay = overlay,
		enabled = enabled and data ~= nil,
		mode = if type(mode) == "string" then mode else nil,
		switching = workspace:GetAttribute("TrackSwitching") == true,
		lobbyClass = lobbyClass,
		lobbyMine = lobbyClass ~= nil,
		apronClass = apronClass,
		speed = speed,
		owned = if wanted then #ownedOf(wanted) else 0,
		dismissed = dismissedFor ~= nil and dismissedFor == contextId,
	})
	if show and class then
		if not strip.Visible and not chip.Visible then
			fetch() -- the strip opens on fresh data (a Garage purchase since the last look)
		end
		render(class)
		shownClass = class
		if expanded and VehiclePickRules.shouldCollapse(expandedAt, os.clock(), pickedWhileOpen) then
			expanded = false
		end
		strip.Visible = expanded
		chip.Visible = not expanded
	else
		strip.Visible = false
		chip.Visible = false
		expanded = false
		shownClass = nil
	end
end

function VehiclePick.init()
	if not AvatarConfig.ENABLED then
		return
	end
	build()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
		local rf = remotes and remotes:WaitForChild("EconomyRequest", 15)
		if rf and rf:IsA("RemoteFunction") then
			request = rf
		end
	end)
	-- A Garage purchase or pick changes the picks attribute: refetch so the strip matches.
	for _, attr in { "AvatarPlane", "AvatarCar", "Gears" } do
		LocalPlayer:GetAttributeChangedSignal(attr):Connect(function()
			fetchedAt = -math.huge
			if shownClass then
				fetch()
			end
		end)
	end
	RunService.Heartbeat:Connect(Prof.wrap("SR_VehiclePick", function()
		local t = os.clock()
		if t - lastTick < 0.25 then
			return
		end
		lastTick = t
		local ok: boolean, err: any = pcall(tick)
		if not ok and not warned then
			warned = true -- once per session: a broken frame must not flood the output
			warn("[SkyRally][PICK] " .. tostring(err))
		end
	end))
end

return VehiclePick
