--!strict
-- Pre-race vehicle pick (economy v3 phase 6). Hub declutter (owner 2026-10-21): docked bottom-left (HudLayoutRules
-- vehicleChip / vehicleStrip: left of the road band, above the controls), one "VEHICLE: <name> >" chip by default; tap
-- expands the strip, which folds back after a pick or COLLAPSE_SECONDS, and everything hides while the Garage is
-- open (the player's own filling lobby still shows it: that is the pick moment). A compact strip of the player's OWNED avatars for the class the next
-- track uses, the last pick preselected; one tap swaps (EconomyRequest "SelectAvatar"), and the race spawn builds that
-- avatar (server/AvatarSelect). It shows in the hub only: on an arch's apron when slowed down, and while the lobby this
-- player opened gathers racers (shared/VehiclePickRules). It never joins, starts or cancels anything. Looks come from
-- NotifySkin.PICKER so the owner's art drops in there; the full list lives in the Garage VEHICLES tab.
-- UI overhaul phase B: strip, chip and cards draw through UiSkin (a NotifySkin.PICKER image wins, then the UiImages slot,
-- then today's flat fill); the strip swooshes up from the bottom when the chip opens it and back down when it folds; a
-- card press plays the pick cue.
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
local UiSkin = require(script.Parent:WaitForChild("UiSkin"))
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))
local UiSkinRules = require(Shared:WaitForChild("UiSkinRules"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
-- UI v2 (round 2): the chip is a navy key with the class icon, the strip a navy card of small vehicle cards with the
-- real model's thumbnail (client/VehicleThumbs), the pick ringed in gold.
local ArcadeUi = require(script.Parent:WaitForChild("ArcadeUi"))
local VehicleThumbs = require(script.Parent:WaitForChild("VehicleThumbs"))

local LocalPlayer = Players.LocalPlayer
local SKIN: any = NotifySkin.PICKER

local VehiclePick = {}

local request: RemoteFunction? = nil
local gui: ScreenGui
local strip: Frame
local list: ScrollingFrame
local chip: GuiButton
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

	strip = ArcadeUi.card(gui, { name = "Strip", radius = 12, strokeWidth = 3 })
	strip.Visible = false
	chip = ArcadeUi.button(gui, "navy", "", { name = "Chip", icon = "plane", sound = "tap", maxText = 18, minText = 12, visible = false, radius = 12 })
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
	UiMotion.place(strip, UDim2.fromOffset(rect.x, rect.y)) -- a running swoosh lands on the new rect
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
	ArcadeUi.setText(chip, string.format("%s  >", string.upper(pickName)))
	local face = chip:FindFirstChild("Face")
	local glyph = face and face:FindFirstChild("Glyph")
	if glyph and glyph:IsA("Frame") and glyph:GetAttribute("IconKind") ~= class then
		local ni = ArcadeUi.icon(face, class, { name = "Glyph", anchor = glyph.AnchorPoint, position = glyph.Position, size = glyph.Size }, 32)
		for _, c in glyph:GetChildren() do
			if c:IsA("UIAspectRatioConstraint") then
				c.Parent = ni
			end
		end
		glyph:Destroy()
	end
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
		-- A small card: the model's thumbnail on the left, the name on the right; the pick is gold-ringed with a check.
		local b = Instance.new("TextButton")
		b.Name = "Card_" .. v.key
		b.Text = ""
		b.AutoButtonColor = false
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(cardW, cardH)
		b.BackgroundColor3 = Color3.new(1, 1, 1)
		ArcadeUi.gradient(b, if on then Color3.fromHex("3A63D0") else ArcadeUi.C.panelTop, ArcadeUi.C.panelBot)
		ArcadeUi.corner(b, 10)
		local st = ArcadeUi.stroke(b, if on then 3 else 2)
		st.Color = if on then ArcadeUi.C.gold else ArcadeUi.C.ink
		b.Parent = list
		local well = Instance.new("Frame")
		well.Name = "Thumb"
		well.BackgroundColor3 = ArcadeUi.C.inset
		well.BackgroundTransparency = 0.3
		well.Position = UDim2.fromOffset(3, 3)
		well.Size = UDim2.new(0, cardH - 6, 1, -6)
		well.Active = false
		well.Parent = b
		ArcadeUi.corner(well, 8)
		VehicleThumbs.view(well, v.key, class, { name = "Model", yaw = 215, silhouette = if v.built == false then ArcadeUi.RARITY[tostring(v.rarity)] else nil })
		local n = ArcadeUi.text(b, { name = "Name", text = string.upper(v.name), font = ArcadeUi.FONT.display, maxSize = 16, minSize = 10, stroke = 1.5, wrap = true })
		n.Position = UDim2.fromOffset(cardH + 2, 2)
		n.Size = UDim2.new(1, -(cardH + 6), 1, -4)
		if on then
			ArcadeUi.icon(b, "check", { name = "Picked", anchor = Vector2.new(1, 0), position = UDim2.new(1, 2, 0, -4), size = UDim2.fromOffset(18, 18) }, 18)
		end
		UiSound.bind(b, UiSkinRules.cueFor("select") or "pick")
		b.Activated:Connect(function()
			select(v)
		end)
	end
end

---------------------------------------------------------------------------------------------------- tick

-- The strip swooshes up from the bottom edge (its open cue: the chip tap opened it) and folds back down quietly (after a
-- pick the confirm already spoke; a timeout or leaving the apron should not make a sound).
local function setStrip(on: boolean)
	local shown = strip.Visible and not UiMotion.isHiding(strip)
	if on and not shown then
		UiMotion.show(strip, "swooshIn", { side = "bottom" })
	elseif not on and shown then
		UiMotion.hide(strip, "swooshOut", nil, { side = "bottom", silent = true })
	end
end

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
		setStrip(expanded)
		chip.Visible = not expanded
	else
		setStrip(false)
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
