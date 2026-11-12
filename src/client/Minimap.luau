--!strict
-- Race minimap (owner 2026-10-20: "a mini-map on screen when a player is racing ... same spot as" the Mario Kart Tour phone
-- screenshot; docs/design/HUD_MK_LAYOUT.md). The course outline comes from the same centreline the AI and the progress code use
-- (SplineUtils.loadWaypoints: WaypointsData on the client, x / z only, so planes and cars share it): a white line with a dark
-- edge, NORTH-UP, fitted into a square once per race and per size from rotated Frames (shared/MinimapRules does the maths).
-- Racers are dots in their RacerColor (RacerPaletteRules identity, set on the vehicle model by server/kit/RacerPaint), bots
-- included; this player's is larger and on top, the leader wears a gold ring. Markers move at 12 Hz from a pooled set of Frames,
-- nothing is allocated per tick, and the whole thing sleeps while HudPhase hides it (race and countdown only; never the hub
-- or a battle). Own ScreenGui, placed from HudMetrics rects.minimap; the player attribute MinimapOn tells HudMetrics to reserve it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Prof = require(Shared:WaitForChild("Prof"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local MinimapRules = require(Shared:WaitForChild("MinimapRules"))
-- visualOf: a remote player's dot follows his visual clone while RacerView draws one (RemoteCloneRules)
local PlayerStreamRules = require(Shared:WaitForChild("PlayerStreamRules"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))

local LocalPlayer = Players.LocalPlayer

local Minimap = {}

local INK = Color3.fromHex("0B1533") -- UI v2 ink
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 208, 64)
local FALLBACK = Color3.fromRGB(200, 200, 205)

type Marker = {
	dot: Frame,
	stroke: UIStroke,
	model: Model,
	hull: BasePart?,
	own: boolean,
	color: Color3,
	progress: MinimapRules.Progress,
	x: number,
	y: number,
	seen: number, -- rescan stamp
}

local gui: ScreenGui? = nil
local root: Frame? = nil
local body: Frame? = nil -- backing + outline + dots; hidden when there is nothing to show (HudPhase owns root.Visible)
local lines: Frame? = nil
local markers: { [Model]: Marker } = {}
local order: { Marker } = {} -- the markers, for allocation-free iteration
local models: { Model } = {}
local stamp = 0

local xs: { number } = {}
local zs: { number } = {}
local closed = false
local fit: MinimapRules.Fit? = nil
local builtKey = ""
local frameSide = 0
local dotOther, dotOwn = 8, 12
local throttle = { next = 0 }
local rescanAt = 0
local wantedAt = 0
local started = false

local function build()
	if gui and gui.Parent then
		return
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyMinimap"
	sg.IgnoreGuiInset = true
	sg.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied); the default added the
	-- device's top inset a second time and pushed the map 20 px down onto the token pill (UI v2 phone capture)
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 2
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local f = Instance.new("Frame")
	f.Name = "Minimap" -- the name HudPhase finds it by
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Visible = false
	f.Active = false
	local b = Instance.new("Frame")
	b.Name = "Body"
	b.Size = UDim2.fromScale(1, 1)
	-- UI v2: a navy glass card with a heavy ink outline and a thin light inner rim (docs/design/UI_V2.md).
	b.BackgroundColor3 = Color3.fromHex("0E1B45")
	b.BackgroundTransparency = 0.35
	b.BorderSizePixel = 0
	b.Visible = false
	b.Parent = f
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 14)
	c.Parent = b
	local bs = Instance.new("UIStroke")
	bs.Color = Color3.fromHex("0B1533")
	bs.Thickness = 3
	bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bs.Parent = b
	local rim = Instance.new("Frame")
	rim.Name = "Rim"
	rim.BackgroundTransparency = 1
	rim.Position = UDim2.fromOffset(3, 3)
	rim.Size = UDim2.new(1, -6, 1, -6)
	rim.Parent = b
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 11)
	rc.Parent = rim
	local rs = Instance.new("UIStroke")
	rs.Color = Color3.fromHex("5CCBFF")
	rs.Transparency = 0.55
	rs.Thickness = 1.5
	rs.Parent = rim
	local l = Instance.new("Frame")
	l.Name = "Lines"
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Parent = b
	f.Parent = sg
	sg.Parent = pg
	gui, root, body, lines = sg, f, b, l
end

local function clearLines()
	if lines then
		lines:ClearAllChildren()
	end
end

local function segFrame(a: MinimapRules.Pt, b: MinimapRules.Pt, thick: number, color: Color3, z: number)
	local cx, cy, len, ang = MinimapRules.segment(a, b, thick)
	local fr = Instance.new("Frame")
	fr.AnchorPoint = Vector2.new(0.5, 0.5)
	fr.Position = UDim2.fromOffset(cx, cy)
	fr.Size = UDim2.fromOffset(len, thick)
	fr.Rotation = ang
	fr.BackgroundColor3 = color
	fr.BorderSizePixel = 0
	fr.ZIndex = z
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = fr
	fr.Parent = lines
end

-- Loads the course for this track and draws the outline for a square of `side` px. Returns false when the track has no centreline
-- (the hub, a map still streaming in): the minimap then stays off.
local function rebuild(side: number): boolean
	local wps = SplineUtils.loadWaypoints()
	local n = #wps
	if n < 100 or side < 16 then
		return false
	end
	local key = string.format("%s|%d|%d", tostring(RaceAttr.mine("ActiveTrackId")), n, side)
	if key == builtKey then
		return true
	end
	table.clear(xs)
	table.clear(zs)
	local pts: { MinimapRules.Pt } = {}
	for i = 1, n do
		local p = wps[i].pos
		xs[i], zs[i] = p.X, p.Z
		pts[i] = { x = p.X, y = p.Z }
	end
	closed = MinimapRules.isClosed(pts)
	local poly, f = MinimapRules.outline(pts, side, closed)
	if not poly or not f then
		return false
	end
	fit, frameSide, builtKey = f, side, key
	dotOther, dotOwn = MinimapRules.dotSizes(side)
	clearLines()
	local thick = math.clamp(math.floor(side * 0.035 + 0.5), 2, 5)
	local edge = thick + math.max(2, math.floor(thick * 0.8))
	for i = 1, #poly - 1 do
		segFrame(poly[i], poly[i + 1], edge, INK, 1)
	end
	for i = 1, #poly - 1 do
		segFrame(poly[i], poly[i + 1], thick, WHITE, 2)
	end
	-- Markers follow the new fit on the next tick; their pooled dots resize here.
	for _, mk in order do
		local d = if mk.own then dotOwn else dotOther
		mk.dot.Size = UDim2.fromOffset(d, d)
		mk.x, mk.y = -1, -1
	end
	return true
end

local function newMarker(m: Model, own: boolean, color: Color3): Marker
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BorderSizePixel = 0
	dot.BackgroundColor3 = color
	dot.ZIndex = if own then 6 else 4
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = dot
	local s = Instance.new("UIStroke")
	s.Thickness = if own then 2 else 1.5
	s.Color = if own then WHITE else INK
	s.Parent = dot
	local d = if own then dotOwn else dotOther
	dot.Size = UDim2.fromOffset(d, d)
	dot.Parent = body
	local mk: Marker = {
		dot = dot,
		stroke = s,
		model = m,
		hull = nil,
		own = own,
		color = color,
		progress = MinimapRules.newProgress(),
		x = -1,
		y = -1,
		seen = 0,
	}
	return mk
end

local function dropMarker(mk: Marker)
	markers[mk.model] = nil
	local at = table.find(order, mk)
	if at then
		table.remove(order, at)
	end
	mk.dot:Destroy()
end

-- 2 Hz: the vehicle list (workspace.Planes holds cars and planes, bots included), new / gone markers, colours.
local function rescan()
	stamp += 1
	table.clear(models)
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") then
				table.insert(models, m)
			end
		end
	end
	for _, m in models do
		local own = m:GetAttribute("OwnerUserId") == LocalPlayer.UserId
		local rc = m:GetAttribute("RacerColor")
		local color = if typeof(rc) == "Color3" then rc else FALLBACK
		local mk: Marker = markers[m] or newMarker(m, own, color)
		if not markers[m] then
			markers[m] = mk
			table.insert(order, mk)
		end
		if mk.own ~= own then
			mk.own = own
			local d = if own then dotOwn else dotOther
			mk.dot.Size = UDim2.fromOffset(d, d)
			mk.dot.ZIndex = if own then 6 else 4
			mk.stroke.Color = if own then WHITE else INK
			mk.stroke.Thickness = if own then 2 else 1.5
		end
		if mk.color ~= color then
			mk.color = color
			mk.dot.BackgroundColor3 = color
		end
		local hull = mk.hull
		if not hull or not hull.Parent then
			mk.hull = (m.PrimaryPart or m:FindFirstChild("Hull")) :: BasePart?
		end
		mk.seen = stamp
	end
	for i = #order, 1, -1 do
		local mk = order[i]
		if mk.seen ~= stamp then
			dropMarker(mk)
		end
	end
end

local function resetProgress()
	for _, mk in order do
		mk.progress = MinimapRules.newProgress()
	end
end

local function tick()
	local f = fit
	if not f or #xs == 0 then
		return
	end
	local n = #xs
	local leader: Marker? = nil
	local best = -math.huge
	for _, mk in order do
		local hull = mk.hull
		if hull and hull.Parent then
			local pos = PlayerStreamRules.visualOf(hull).Position
			local idx = MinimapRules.nearest(xs, zs, pos.X, pos.Z, mk.progress.idx, closed)
			local prog = MinimapRules.step(mk.progress, idx, n)
			if prog > best then
				best, leader = prog, mk
			end
			local px, py = MinimapRules.place(f, pos.X, pos.Z)
			px, py = MinimapRules.clampInside(px, py, frameSide, dotOther / 2)
			if math.abs(px - mk.x) >= 0.4 or math.abs(py - mk.y) >= 0.4 then
				mk.x, mk.y = px, py
				mk.dot.Position = UDim2.fromOffset(px, py)
			end
			mk.dot.Visible = true
		else
			mk.dot.Visible = false
		end
	end
	for _, mk in order do
		local ring = mk == leader
		local want = if ring then GOLD elseif mk.own then WHITE else INK
		if mk.stroke.Color ~= want then
			mk.stroke.Color = want
			mk.stroke.Thickness = if ring then 2.5 elseif mk.own then 2 else 1.5
		end
		-- the leader's dot rises above the other racers (the local one stays on top of it)
		local z = if mk.own then 6 elseif ring then 5 else 4
		if mk.dot.ZIndex ~= z then
			mk.dot.ZIndex = z
		end
	end
end

-- Race (not hub, not battle) on a track that has a centreline: the minimap exists and HudMetrics reserves its rect.
local function wanted(): boolean
	local mode = RaceAttr.mine("RaceMode")
	if mode == nil or mode == "hub" or mode == "battle" then
		return false
	end
	return #SplineUtils.loadWaypoints() >= 100
end

local function setOn(on: boolean)
	if LocalPlayer:GetAttribute("MinimapOn") ~= on then
		LocalPlayer:SetAttribute("MinimapOn", on)
	end
end

local function layout()
	local r = HudMetrics.rects().minimap
	if not root or not body then
		return
	end
	if not r then
		body.Visible = false
		return
	end
	root.Position = UDim2.fromOffset(r.x, r.y)
	root.Size = UDim2.fromOffset(r.w, r.h)
	if rebuild(math.floor(r.w + 0.5)) then
		body.Visible = true
	else
		body.Visible = false
		setOn(false)
	end
end

local function refreshWanted()
	build()
	local on = wanted()
	setOn(on)
	if on then
		layout()
	end
end

function Minimap.init()
	if started then
		return
	end
	started = true
	build()
	HudMetrics.onChanged(function()
		layout()
	end)
	for _, a in { "RaceMode", "ActiveTrackId" } do
		RaceAttr.changed(a, function()
			builtKey = ""
			refreshWanted()
		end)
	end
	RaceAttr.changed("RaceGoTime", resetProgress)
	RunService.Heartbeat:Connect(Prof.wrap("SR_Minimap", function()
		local now = os.clock()
		if now >= wantedAt then
			wantedAt = now + 1 -- waypoints can arrive after the mode does
			refreshWanted()
		end
		local b = body
		if not b or not b.Visible or not root or not root.Visible or not MinimapRules.due(throttle, now) then
			return
		end
		if now >= rescanAt then
			rescanAt = now + 0.5
			rescan()
		end
		tick()
	end))
	refreshWanted()
end

return Minimap
