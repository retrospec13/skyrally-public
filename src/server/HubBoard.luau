--!strict
-- The physical leaderboard in the hub (social lane): a wooden sign on the plaza terrace with a SurfaceGui that shows one
-- board at a time (five best-time boards, then total stars), turning the page every LeaderboardRules.PAGE_SECONDS. The data
-- comes from server/Leaderboards (a cached top 10 per board); this module only draws it. Where it stands is one constant,
-- LeaderboardRules.BOARD.
-- The sign exists only while the server is in the hub (RaceMode "hub"): a race map replaces the world, so the model is taken
-- out of the workspace then and put back on the return. Row labels carry a UserId attribute and the model carries
-- Page (the board id on show) so client/LeaderboardBoard can write the viewer's own "YOU" line into OwnLine without a remote.
local LeaderboardRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LeaderboardRules"))

local HubBoard = {}

export type Page = {
	board: LeaderboardRules.Board,
	rows: { { userId: number, name: string, value: number } },
}

local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local WOOD_MID = Color3.fromRGB(98, 64, 38)
local TERRACOTTA = Color3.fromRGB(200, 100, 58)
local PLINTH = Color3.fromRGB(201, 164, 110)
local PARCHMENT = Color3.fromRGB(239, 226, 196) -- v29 B6: #efe2c4 (was 246, 236, 210)
local INK = Color3.fromRGB(58, 38, 24)
local GOLD = Color3.fromRGB(255, 214, 90)
local ROW_A = Color3.fromRGB(236, 222, 190)
local ROW_B = Color3.fromRGB(224, 208, 172)

local PIXELS_PER_STUD = 21
local PAGE_COUNT = #LeaderboardRules.RACE_TRACKS + 1 -- five best-time boards and the stars board
-- Canvas height budget: the face is (height - 1.2) studs at 21 px per stud = 470 px; 58 + 26 + 10 * 31 + 6 + 44 + 4 + 22 = 470.
local TITLE_H, HEAD_H, ROW_H, OWN_H, DOTS_H = 58, 26, 31, 44, 22

local model: Model? = nil
local ui: {
	title: TextLabel,
	empty: TextLabel,
	own: TextLabel,
	ranks: { TextLabel },
	names: { TextLabel },
	values: { TextLabel },
	rowFrames: { Frame },
	dots: { Frame },
}? =
	nil
local started = false

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, collide: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = collide
	p.CanTouch = false
	p.CanQuery = collide
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function label(parent: Instance, name: string, pos: UDim2, size: UDim2, text: string, textSize: number, color: Color3, align: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = size
	l.Text = text
	l.TextSize = textSize
	l.TextColor3 = color
	l.Font = Enum.Font.GothamBold
	l.TextXAlignment = align
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

local function build(groundY: number): Model
	local B = LeaderboardRules.BOARD
	local w, h = B.width, B.height
	local panelY = groundY + B.clearance + h / 2
	local look = CFrame.lookAt(Vector3.new(B.pos.X, panelY, B.pos.Z), Vector3.new(B.faceToward.X, panelY, B.faceToward.Z))

	local m = Instance.new("Model")
	m.Name = "HubLeaderboard"

	part(m, "Back", Vector3.new(w, h, 1), look, WOOD_DARK, Enum.Material.WoodPlanks, true)
	-- Frame trim around the face.
	part(m, "TrimTop", Vector3.new(w + 1.2, 1.2, 1.6), look * CFrame.new(0, h / 2, -0.1), WOOD_MID, Enum.Material.Wood, true)
	part(m, "TrimBottom", Vector3.new(w + 1.2, 1.2, 1.6), look * CFrame.new(0, -h / 2, -0.1), WOOD_MID, Enum.Material.Wood, true)
	part(m, "TrimLeft", Vector3.new(1.2, h, 1.6), look * CFrame.new(-w / 2, 0, -0.1), WOOD_MID, Enum.Material.Wood, true)
	part(m, "TrimRight", Vector3.new(1.2, h, 1.6), look * CFrame.new(w / 2, 0, -0.1), WOOD_MID, Enum.Material.Wood, true)
	-- Two posts from the paving (sunk a stud) up to the panel's middle, behind it.
	local postH = (panelY - groundY) + 1
	for _, side in { -1, 1 } do
		part(m, "Post", Vector3.new(1.8, postH, 1.8), look * CFrame.new(side * (w / 2 - 3), -(panelY - groundY) / 2 + 0.5, 1.4), WOOD_MID, Enum.Material.Wood, true)
	end
	-- A small roof board over the top trim so the sign reads as a notice board from the plaza.
	-- v29 B6: a terracotta mini-roof (two pitched slopes) over the dark roof board, and a stone plinth under each post.
	part(m, "Roof", Vector3.new(w + 3, 0.8, 3), look * CFrame.new(0, h / 2 + 1.3, -0.3), WOOD_DARK, Enum.Material.WoodPlanks, false)
	for _, slope in { -1, 1 } do
		local tile = part(m, "RoofTile", Vector3.new(w + 3.6, 0.5, 2.6), look * CFrame.new(0, h / 2 + 2.0, -0.3 + slope * 1.0) * CFrame.Angles(slope * math.rad(-22), 0, 0), TERRACOTTA, Enum.Material.Slate, false)
		tile.CanQuery = false
	end
	for _, side in { -1, 1 } do
		-- Sunk stone footing under each post at the paving; it only adds to the post's footprint, collision stays on the post.
		local foot = part(m, "Plinth", Vector3.new(3.4, 1.6, 3.4), look * CFrame.new(side * (w / 2 - 3), -(panelY - groundY) + 0.6, 1.4), PLINTH, Enum.Material.Sandstone, false)
		foot.CanQuery = false
	end

	local face = part(m, "Face", Vector3.new(w - 1.2, h - 1.2, 0.2), look * CFrame.new(0, 0, -0.6), INK, Enum.Material.SmoothPlastic, false)
	face.CanQuery = false

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD * (36 - 1.2) / (w - 1.2) -- the canvas keeps its v27 pixel size when the panel is scaled down
	gui.LightInfluence = 0
	gui.Brightness = 1.2
	gui.MaxDistance = 260
	gui.ResetOnSpawn = false
	gui.Parent = face

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = PARCHMENT
	root.BorderSizePixel = 0
	root.Parent = gui

	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
	titleBar.BackgroundColor3 = WOOD_DARK
	titleBar.BorderSizePixel = 0
	titleBar.Parent = root
	local title = label(titleBar, "Title", UDim2.fromOffset(16, 0), UDim2.new(1, -32, 1, 0), "LEADERBOARD", 32, GOLD, Enum.TextXAlignment.Center)

	local head = Instance.new("Frame")
	head.Name = "Head"
	head.Position = UDim2.fromOffset(0, TITLE_H)
	head.Size = UDim2.new(1, 0, 0, HEAD_H)
	head.BackgroundColor3 = WOOD_MID
	head.BorderSizePixel = 0
	head.Parent = root
	label(head, "HRank", UDim2.fromOffset(14, 0), UDim2.fromOffset(60, HEAD_H), "RANK", 16, PARCHMENT, Enum.TextXAlignment.Left)
	label(head, "HName", UDim2.fromOffset(92, 0), UDim2.fromOffset(300, HEAD_H), "PILOT", 16, PARCHMENT, Enum.TextXAlignment.Left)
	label(head, "HValue", UDim2.new(1, -250, 0, 0), UDim2.fromOffset(236, HEAD_H), "RECORD", 16, PARCHMENT, Enum.TextXAlignment.Right)

	local rowsTop = TITLE_H + HEAD_H
	local ranks, names, values, rowFrames = {}, {}, {}, {}
	for i = 1, LeaderboardRules.ROWS do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Position = UDim2.fromOffset(0, rowsTop + (i - 1) * ROW_H)
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.BackgroundColor3 = if i % 2 == 1 then ROW_A else ROW_B
		row.BorderSizePixel = 0
		row.Parent = root
		ranks[i] = label(row, "Rank", UDim2.fromOffset(14, 0), UDim2.fromOffset(60, ROW_H), tostring(i), 22, if i <= 3 then WOOD_DARK else INK, Enum.TextXAlignment.Left)
		names[i] = label(row, "Name", UDim2.fromOffset(92, 0), UDim2.fromOffset(330, ROW_H), "-", 22, INK, Enum.TextXAlignment.Left)
		values[i] = label(row, "Value", UDim2.new(1, -250, 0, 0), UDim2.fromOffset(236, ROW_H), "", 22, INK, Enum.TextXAlignment.Right)
		rowFrames[i] = row
	end

	local empty = label(root, "Empty", UDim2.fromOffset(20, rowsTop + ROW_H), UDim2.new(1, -40, 0, ROW_H * 3), "No records yet - be the first!", 26, WOOD_MID, Enum.TextXAlignment.Center)
	empty.TextWrapped = true
	empty.Visible = false

	local ownTop = rowsTop + LeaderboardRules.ROWS * ROW_H + 6
	local ownBar = Instance.new("Frame")
	ownBar.Name = "OwnBar"
	ownBar.Position = UDim2.fromOffset(0, ownTop)
	ownBar.Size = UDim2.new(1, 0, 0, OWN_H)
	ownBar.BackgroundColor3 = WOOD_DARK
	ownBar.BorderSizePixel = 0
	ownBar.Parent = root
	-- Written by client/LeaderboardBoard on each viewer's own client; the server leaves it alone.
	local own = label(ownBar, "OwnLine", UDim2.fromOffset(16, 0), UDim2.new(1, -32, 1, 0), "", 24, GOLD, Enum.TextXAlignment.Center)

	local dotsTop = ownTop + OWN_H + 4
	local dots = {}
	local dotHolder = Instance.new("Frame")
	dotHolder.Name = "Dots"
	dotHolder.BackgroundTransparency = 1
	dotHolder.Position = UDim2.fromOffset(0, dotsTop)
	dotHolder.Size = UDim2.new(1, 0, 0, DOTS_H)
	dotHolder.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 10)
	layout.Parent = dotHolder
	for i = 1, PAGE_COUNT do
		local dot = Instance.new("Frame")
		dot.Name = "Dot" .. i
		dot.Size = UDim2.fromOffset(14, 14)
		dot.BackgroundColor3 = WOOD_MID
		dot.BorderSizePixel = 0
		dot.Parent = dotHolder
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot
		dots[i] = dot
	end

	ui = { title = title, empty = empty, own = own, ranks = ranks, names = names, values = values, rowFrames = rowFrames, dots = dots }
	return m
end

-- Draws one page. Row labels keep the row's UserId as an attribute (0 = empty row).
local function render(m: Model, page: Page, index: number)
	local u = ui
	if not u then
		return
	end
	u.title.Text = page.board.title
	m:SetAttribute("Page", page.board.id)
	m:SetAttribute("PageKind", page.board.kind)
	u.empty.Visible = #page.rows == 0
	for i = 1, LeaderboardRules.ROWS do
		local row = page.rows[i]
		u.rowFrames[i]:SetAttribute("UserId", if row then row.userId else 0)
		u.rowFrames[i]:SetAttribute("Value", if row then row.value else 0)
		u.rowFrames[i].Visible = row ~= nil or #page.rows > 0
		u.names[i].Text = if row then LeaderboardRules.shortName(row.name, 22) else "-"
		u.values[i].Text = if row then LeaderboardRules.formatValue(page.board.kind, row.value) else ""
		u.names[i].TextTransparency = if row then 0 else 0.6
	end
	for i, dot in u.dots do
		dot.BackgroundColor3 = if i == index then GOLD else WOOD_MID
	end
end

-- Where the paving is under the sign: a ray from above, ignoring non-colliding decoration; the plan's constant otherwise.
local function groundY(): number
	local B = LeaderboardRules.BOARD
	local params = RaycastParams.new()
	params.RespectCanCollide = true
	if model then
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { model }
	end
	local ok, hit = pcall(function()
		return workspace:Raycast(Vector3.new(B.pos.X, B.pos.Y + 80, B.pos.Z), Vector3.new(0, -160, 0), params)
	end)
	if ok and hit and math.abs(hit.Position.Y - B.pos.Y) <= B.groundTolerance then
		return hit.Position.Y
	end
	return B.pos.Y
end

-- getPages: the cached boards (Leaderboards.service().pages); getVersion bumps when they were re-read.
function HubBoard.start(getPages: () -> { Page }, getVersion: () -> number)
	if started then
		return
	end
	started = true
	local index = 1
	local pageAt = 0
	local drawnVersion = -1
	local drawnIndex = 0

	local function isHub(): boolean
		return workspace:GetAttribute("RaceMode") == "hub"
	end

	local function place()
		if model and model.Parent then
			return
		end
		if not model then
			model = build(groundY())
			drawnVersion = -1
		end
		(model :: Model).Parent = workspace
	end

	local function tick()
		if not isHub() or workspace:GetAttribute("TrackSwitching") == true then
			if model and model.Parent then
				model.Parent = nil
			end
			return
		end
		place()
		local m = model :: Model
		local now = os.clock()
		if now - pageAt >= LeaderboardRules.PAGE_SECONDS then
			pageAt = now
			index = index % PAGE_COUNT + 1
		end
		-- The boards are only read from the service (names may yield) when the page turned or the cache was re-read.
		local v = getVersion()
		if v ~= drawnVersion or index ~= drawnIndex then
			local pages = getPages()
			if pages[index] == nil then
				return
			end
			drawnVersion = v
			drawnIndex = index
			render(m, pages[index], index)
		end
	end

	task.spawn(function()
		task.wait(2)
		while true do
			local ok, err = pcall(function(): any
				tick()
				return nil
			end)
			if not ok then
				warn("[SkyRally][LB] board draw failed: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
end

-- The sign while it exists (tools and the Studio checks read its Page attribute and labels).
function HubBoard.model(): Model?
	return model
end

return HubBoard
