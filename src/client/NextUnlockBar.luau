--!strict
-- v38 (design lane): the results card's "what is next" bar. ONE goal (server: Progression.nextUnlock, sent as
-- RaceFinished.award.nextUnlock) as one progress bar: "NEXT  SNOW WORLD" on the left, "1/1" on the right, a gold fill
-- that grows from the value before this race to the value after it. Full: "UNLOCKED" in green. The results screen
-- belongs to the flow lane; this module only builds the widget and the card places it (RaceUI populateFinishModal).
local TweenService = game:GetService("TweenService")

local ArcadeUi = require(script.Parent:WaitForChild("ArcadeUi"))

local NextUnlockBar = {}

local UNIT_ICON = { token = "\u{2605}", fragment = "\u{25C6}", boss = "" } :: { [string]: string }

export type Info = { key: string?, label: string?, have: number?, need: number?, unit: string? }

-- The bar for `info` (nil or malformed: nil, nothing built). `before`: the value before this race (the fill animates
-- from it after `delay` seconds). width/height in px.
function NextUnlockBar.build(parent: Instance, info: any, before: number?, width: number, height: number, delay: number?): Frame?
	if type(info) ~= "table" or type(info.label) ~= "string" or type(info.need) ~= "number" or info.need <= 0 then
		return nil
	end
	local have = math.clamp(if type(info.have) == "number" then info.have else 0, 0, info.need)
	local from = math.clamp(if type(before) == "number" then before else have, 0, have)
	local done = have >= info.need

	local root = Instance.new("Frame")
	root.Name = "NextUnlockBar"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(width, height)
	root.Parent = parent

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.BorderSizePixel = 0
	well.BackgroundColor3 = ArcadeUi.C.inset
	well.BackgroundTransparency = 0.15
	well.Size = UDim2.fromScale(1, 1)
	well.ClipsDescendants = false
	well.Parent = root
	ArcadeUi.corner(well, UDim.new(0.5, 0))
	ArcadeUi.stroke(well, 2, ArcadeUi.C.ink)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(from / info.need, 1)
	fill.Parent = well
	ArcadeUi.corner(fill, UDim.new(0.5, 0))
	if done then
		ArcadeUi.gradient(fill, Color3.fromHex("6CF08A"), Color3.fromHex("1FA83A"))
	else
		ArcadeUi.gradient(fill, ArcadeUi.C.headerTop, ArcadeUi.C.headerBot)
	end

	local icon = UNIT_ICON[info.unit or ""] or ""
	local left = ArcadeUi.text(well, {
		name = "Goal",
		text = string.format('<font color="#AFC0E8">NEXT</font>  %s', string.upper(info.label)),
		font = ArcadeUi.FONT.display,
		maxSize = math.floor(height * 0.62),
		minSize = 9,
		position = UDim2.new(0, math.floor(height * 0.5), 0, 0),
		sizeUDim = UDim2.new(0.7, 0, 1, 0),
		z = 3,
	})
	left.RichText = true
	ArcadeUi.text(well, {
		name = "Count",
		text = if done then "UNLOCKED" else string.format("%d/%d %s", have, info.need, icon),
		font = ArcadeUi.FONT.display,
		maxSize = math.floor(height * 0.62),
		minSize = 9,
		align = Enum.TextXAlignment.Right,
		anchor = Vector2.new(1, 0),
		position = UDim2.new(1, -math.floor(height * 0.5), 0, 0),
		sizeUDim = UDim2.new(0.3, 0, 1, 0),
		color = if done then Color3.fromHex("8CFFA4") else ArcadeUi.C.gold,
		z = 3,
	})

	if have > from then
		task.delay(delay or 0.6, function()
			if fill.Parent then
				TweenService:Create(fill, TweenInfo.new(0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.fromScale(have / info.need, 1) }):Play()
				task.delay(0.7, function()
					if root.Parent then
						ArcadeUi.punch(root, 1.08, 0.25)
					end
				end)
			end
		end)
	end
	return root
end

return NextUnlockBar
