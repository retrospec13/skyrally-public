--!strict
-- Studio-only UI v2 kit sheet: every UiSkin factory in every state on one screen, for captures (not booted; the lane
-- tooling requires it in the Client datamodel: require(PlayerScripts.ClientMain.UiKitSheet).show()).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UiSkin = require(script.Parent:WaitForChild("UiSkin"))

local UiKitSheet = {}

local function row(parent: Instance, order: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Row" .. order
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, h)
	f.LayoutOrder = order
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.Padding = UDim.new(0, 14)
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = f
	f.Parent = parent
	return f
end

function UiKitSheet.hide()
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local old = pg and pg:FindFirstChild("UiKitSheet")
	if old then
		old:Destroy()
	end
end

function UiKitSheet.show(S: number?)
	if not RunService:IsStudio() then
		return
	end
	UiKitSheet.hide()
	local s = S or 1
	local gui = Instance.new("ScreenGui")
	gui.Name = "UiKitSheet"
	gui.DisplayOrder = 1000
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(110, 170, 230)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local panel = UiSkin.panel(bg, "panel", { name = "Sheet", size = UDim2.new(1, -40, 1, -40), position = UDim2.fromOffset(20, 20), S = s })
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingTop = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 12)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	local bh = math.floor(58 * s)

	local r0 = row(panel, 0, math.floor(56 * s))
	UiSkin.header(r0, "COURSE SELECT", { size = UDim2.fromOffset(math.floor(360 * s), math.floor(54 * s)), S = s })
	UiSkin.checker(r0, { size = UDim2.fromOffset(math.floor(220 * s), math.floor(20 * s)), cells = 16 })
	UiSkin.title(r0, "1ST", { size = UDim2.fromOffset(math.floor(120 * s), math.floor(56 * s)), color = UiSkin.color("place_1"), textSize = math.floor(52 * s) })
	UiSkin.numeral(r0, "02:22.7", { size = UDim2.fromOffset(math.floor(160 * s), math.floor(40 * s)), textSize = math.floor(34 * s) })
	UiSkin.body(r0, "1 more Sky Token", { size = UDim2.fromOffset(math.floor(200 * s), math.floor(30 * s)), textSize = math.floor(22 * s) })

	local r1 = row(panel, 1, bh + 6)
	for i, v in { "go", "sky", "orange", "danger", "disabled", "purple" } do
		UiSkin.button(r1, v, string.upper(v), { size = UDim2.fromOffset(math.floor(170 * s), bh), layoutOrder = i, S = s })
	end
	local r2 = row(panel, 2, bh + 6)
	UiSkin.button(r2, "go", "RACE AGAIN", { size = UDim2.fromOffset(math.floor(240 * s), bh), glyph = "flag", S = s })
	UiSkin.button(r2, "sky", "HUB", { size = UDim2.fromOffset(math.floor(150 * s), bh), glyph = "hub", S = s })
	UiSkin.button(r2, "orange", "GARAGE", { size = UDim2.fromOffset(math.floor(190 * s), bh), glyph = "wrench", S = s })
	UiSkin.button(r2, "danger", "LEAVE", { size = UDim2.fromOffset(math.floor(160 * s), bh), glyph = "close", S = s })
	local dis = UiSkin.button(r2, "go", "LOCKED", { size = UDim2.fromOffset(math.floor(170 * s), bh), glyph = "lock", S = s })
	UiSkin.setEnabled(dis, false)
	local small = UiSkin.button(r2, "sky", "", { size = UDim2.fromOffset(bh, bh), glyph = "gear", S = s })
	small.Name = "Gear"

	local r3 = row(panel, 3, math.floor(46 * s))
	UiSkin.tab(r3, "VEHICLES", true, { size = UDim2.fromOffset(math.floor(170 * s), math.floor(44 * s)), S = s })
	UiSkin.tab(r3, "TINTS", false, { size = UDim2.fromOffset(math.floor(140 * s), math.floor(44 * s)), S = s })
	UiSkin.tab(r3, "TRAILS", false, { size = UDim2.fromOffset(math.floor(140 * s), math.floor(44 * s)), glyph = "trail", S = s })
	UiSkin.chip(r3, "3/14", "coin", { size = UDim2.fromOffset(math.floor(120 * s), math.floor(40 * s)), S = s })
	UiSkin.chip(r3, "1/4", "key", { size = UDim2.fromOffset(math.floor(110 * s), math.floor(40 * s)), S = s })
	UiSkin.chip(r3, "0/4", "boss", { size = UDim2.fromOffset(math.floor(110 * s), math.floor(40 * s)), S = s })

	local r4 = row(panel, 4, math.floor(150 * s))
	for i, rar in { "common", "rare", "epic", "legendary" } do
		local c = UiSkin.card(r4, { size = UDim2.fromOffset(math.floor(150 * s), math.floor(146 * s)), layoutOrder = i, S = s }, rar)
		UiSkin.glyph(c, ({ "race", "stopwatch", "boss", "battle" })[i], { size = UDim2.fromScale(0.5, 0.5), position = UDim2.fromScale(0.5, 0.4), anchor = Vector2.new(0.5, 0.5), zIndex = c.ZIndex + 1 })
		UiSkin.text(c, string.upper(rar), "button", { size = UDim2.new(1, -12, 0, math.floor(28 * s)), position = UDim2.new(0.5, 0, 1, -math.floor(12 * s)), anchor = Vector2.new(0.5, 1), zIndex = c.ZIndex + 1 })
	end
	local well = UiSkin.inset(r4, { size = UDim2.fromOffset(math.floor(300 * s), math.floor(146 * s)), S = s })
	UiSkin.body(well, "Inset well: lists and stat blocks", { size = UDim2.new(1, -20, 0, math.floor(28 * s)), position = UDim2.fromOffset(10, 10), textSize = math.floor(20 * s), align = "left" })
	for i, n in { "medal_1", "medal_2", "medal_3", "trophy", "lock", "star", "info", "alert" } do
		UiSkin.iconSlot(r4, n, { size = UDim2.fromOffset(math.floor(62 * s), math.floor(62 * s)), layoutOrder = 10 + i, S = s })
	end

	local r5 = row(panel, 5, bh + 6)
	-- legacy callers (wood / green / brass / red fills) must land on theme variants
	UiSkin.button(r5, "btn_wood", "WOOD", { size = UDim2.fromOffset(math.floor(150 * s), bh), color = Color3.fromRGB(108, 76, 52), S = s })
	UiSkin.button(r5, "btn_primary", "GREEN", { size = UDim2.fromOffset(math.floor(150 * s), bh), color = Color3.fromRGB(78, 148, 58), S = s })
	UiSkin.button(r5, "btn_wood", "BRASS", { size = UDim2.fromOffset(math.floor(150 * s), bh), color = Color3.fromRGB(224, 172, 76), S = s })
	UiSkin.button(r5, "btn_danger", "CLOSE", { size = UDim2.fromOffset(math.floor(150 * s), bh), S = s })
	UiSkin.panel(r5, "row_plank", { size = UDim2.fromOffset(math.floor(150 * s), bh), color = Color3.fromRGB(200, 90, 40), S = s })
	UiSkin.panel(r5, "sign_hanging", { size = UDim2.fromOffset(math.floor(150 * s), bh), color = Color3.fromRGB(96, 60, 34), alpha = 0.1, S = s })

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

return UiKitSheet
