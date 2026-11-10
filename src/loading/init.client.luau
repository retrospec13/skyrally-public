--!strict
-- SkyRally loading screen (TEST_LIST_LAUNCH L27 transitions, L42 load to first control). A LocalScript in ReplicatedFirst:
-- it removes Roblox's default loading screen at once and shows ours, a sky with a plane silhouette that crosses it in a
-- loop, the game's name, rotating tips (controls for the device, items, portals) and a wood progress bar that moves only
-- on real milestones (shared/LoadingRules.MILESTONES):
--   game       the place has loaded (game:IsLoaded)
--   assets     ContentProvider has preloaded the wood/stone HUD sprites and the engine/impact/UI cues (8 s budget, then it
--              counts as done: a slow CDN must not hold the game)
--   character  the player's character and its root part exist
--   vehicle    the server mounted the race vehicle (player attribute MountedInPlane, set for both car and plane)
--   track      the active map's root says TrackReady and no curtain is up (the hub at join)
-- When everything is done the screen fades out (never before MIN_SHOW), and after TIMEOUT seconds it leaves anyway, so it
-- can never stick. The seconds from join to control are printed as one [SkyRally][LOAD] line (L42: hub under 10 s).
-- The player attribute LoadingDone turns true as the fade starts (other first-join UI waits for it). Everything here is
-- local; nothing is sent to the server. All text comes from LoadingRules, so the title is a single constant.
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- ReplicatedFirst starts within a frame of the client joining, so this is the join clock for L42.
local startedAt = os.clock()
pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local Rules = require(script:WaitForChild("LoadingRules"))

local player = Players.LocalPlayer
while not player do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	player = Players.LocalPlayer
end
local playerGui = player:WaitForChild("PlayerGui")

-- Wood-plank palette (RaceUI / TrackFlow / Garage)
local CREAM = Color3.fromRGB(250, 242, 222)
local WOOD = Color3.fromRGB(108, 76, 52)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local RIM = Color3.fromRGB(188, 168, 142)
local BRASS = Color3.fromRGB(224, 172, 76)
local SILHOUETTE = Color3.fromRGB(28, 34, 62)

local DESIGN_W, DESIGN_H = 740, 360 -- the smallest phone landscape the HUD is laid out for

---------------------------------------------------------------------------------------------------- state

local done: Rules.Done = {}
local stamps: { [string]: number } = {}
local assetsTotal = 0
local assetsLoaded = 0
local logged = false
local leaving = false
local shown = 0
-- The longest frame while the screen shows (the client is busy instancing the replicated map, loading scripts...):
-- appended to the LOAD line as worstFrame=<s>@<t>, so a slow join says whether the client stalled or waited.
local worstFrame, worstAt = 0, 0
local lastAsset, lastAssetAt = "", 0 -- QA: the preload's slowest item (appended to the LOAD line as lastAsset=)

local function now(): number
	return os.clock() - startedAt
end

local function mark(id: string)
	if not done[id] then
		done[id] = true
		stamps[id] = now()
	end
end

---------------------------------------------------------------------------------------------------- UI helpers

local function corner(p: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = p
end

local function stroke(p: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
end

local function frame(parent: Instance, name: string, pos: UDim2, size: UDim2, color: Color3, radius: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Active = false
	f.Parent = parent
	if radius then
		corner(f, radius)
	end
	return f
end

local function label(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, textSize: number, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = pos
	l.Size = size
	l.BackgroundTransparency = 1
	l.Font = font
	l.Text = text
	l.TextSize = textSize
	l.TextColor3 = CREAM
	l.Active = false
	l.Parent = parent
	local s = Instance.new("UIStroke")
	s.Color = WOOD_DARK
	s.Thickness = math.max(1.5, textSize / 16)
	s.Parent = l
	return l
end

---------------------------------------------------------------------------------------------------- UI

local gui = Instance.new("ScreenGui")
gui.Name = "SkyRallyLoading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000 -- over every game UI (TrackFlow's curtain is 20, the controls hint 40)
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
	gui.ScreenInsets = Enum.ScreenInsets.None
end)
gui.Parent = playerGui

-- A CanvasGroup so the whole screen fades with one GroupTransparency.
local root = Instance.new("CanvasGroup")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = Color3.new(1, 1, 1)
root.BorderSizePixel = 0
root.Active = true -- swallows touches so nothing underneath is pressed while it shows
root.Parent = gui
-- The sky gradient lives on its own backdrop: a UIGradient on the CanvasGroup itself tints everything drawn in the
-- group, which turned the wooden title plaque black and the cream text blue-grey (Studio capture
-- out/verify_merge/v5_loading_screen.png).
local skyFrame = Instance.new("Frame")
skyFrame.Name = "Sky"
skyFrame.Size = UDim2.fromScale(1, 1)
skyFrame.BackgroundColor3 = Color3.new(1, 1, 1)
skyFrame.BorderSizePixel = 0
skyFrame.ZIndex = 0 -- under every other piece of the screen
skyFrame.Active = false
skyFrame.Parent = root
local sky = Instance.new("UIGradient")
sky.Rotation = 90
sky.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 52, 120)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(86, 150, 214)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 196, 140)),
})
sky.Parent = skyFrame

-- Sun and glow, low on the right.
local glow = frame(root, "SunGlow", UDim2.fromScale(0.8, 0.66), UDim2.fromOffset(300, 300), Color3.fromRGB(255, 232, 170), 150)
glow.AnchorPoint = Vector2.new(0.5, 0.5)
glow.BackgroundTransparency = 0.82
local sun = frame(root, "Sun", UDim2.fromScale(0.8, 0.66), UDim2.fromOffset(120, 120), Color3.fromRGB(255, 240, 190), 60)
sun.AnchorPoint = Vector2.new(0.5, 0.5)
-- layout() scales both discs with the screen: a fixed pixel radius left them rounded squares on a big screen.
for _, disc in { glow, sun } do
	local c = disc:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = UDim.new(0.5, 0)
	end
end

-- Clouds drift right at their own speeds and wrap.
type Cloud = { holder: Frame, x: number, speed: number }
local clouds: { Cloud } = {}
local CLOUD_SPEC = {
	{ y = 0.12, x = 0.1, speed = 0.014, w = 190 },
	{ y = 0.2, x = 0.62, speed = 0.022, w = 140 },
	{ y = 0.3, x = 0.35, speed = 0.011, w = 220 },
	{ y = 0.52, x = 0.85, speed = 0.027, w = 120 },
	{ y = 0.46, x = 0.2, speed = 0.016, w = 170 },
	{ y = 0.08, x = 0.9, speed = 0.019, w = 130 },
}
for i, c in CLOUD_SPEC do
	local holder = Instance.new("Frame")
	holder.Name = "Cloud" .. i
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(c.w, c.w * 0.3)
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromScale(c.x, c.y)
	holder.Active = false
	holder.Parent = root
	local base = frame(holder, "Base", UDim2.fromScale(0, 0.35), UDim2.fromScale(1, 0.65), Color3.new(1, 1, 1), 999)
	base.BackgroundTransparency = 0.35
	local bump = frame(holder, "Bump", UDim2.fromScale(0.22, 0), UDim2.fromScale(0.5, 0.7), Color3.new(1, 1, 1), 999)
	bump.BackgroundTransparency = 0.35
	table.insert(clouds, { holder = holder, x = c.x, speed = c.speed })
end

-- Two hills at the bottom edge.
local hillBack = frame(root, "HillBack", UDim2.fromScale(0.02, 0.86), UDim2.fromScale(0.82, 0.7), Color3.fromRGB(58, 128, 104), 400)
hillBack.BackgroundTransparency = 0
local hillFront = frame(root, "HillFront", UDim2.fromScale(0.5, 0.92), UDim2.fromScale(0.9, 0.7), Color3.fromRGB(34, 92, 72), 400)
hillFront.BackgroundTransparency = 0

-- The plane silhouette (nose to the right), built from rounded bars; the holder scales with the screen.
local planeHolder = Instance.new("Frame")
planeHolder.Name = "Plane"
planeHolder.AnchorPoint = Vector2.new(0.5, 0.5)
planeHolder.Size = UDim2.fromOffset(130, 52)
planeHolder.BackgroundTransparency = 1
planeHolder.Active = false
planeHolder.Parent = root
local planeScale = Instance.new("UIScale")
planeScale.Parent = planeHolder
for i = 1, 5 do -- contrail puffs behind the tail
	local puff = frame(planeHolder, "Puff" .. i, UDim2.fromOffset(6 - i * 15, 24 + (i % 2) * 2), UDim2.fromOffset(15 - i * 2, 15 - i * 2), Color3.new(1, 1, 1), 999)
	puff.BackgroundTransparency = 0.3 + i * 0.1
end
local tailFin = frame(planeHolder, "TailFin", UDim2.fromOffset(10, 0), UDim2.fromOffset(13, 28), SILHOUETTE, 5)
tailFin.Rotation = -18
frame(planeHolder, "TailPlane", UDim2.fromOffset(6, 24), UDim2.fromOffset(28, 7), SILHOUETTE, 4)
frame(planeHolder, "Fuselage", UDim2.fromOffset(14, 18), UDim2.fromOffset(104, 19), SILHOUETTE, 10)
local canopy = frame(planeHolder, "Canopy", UDim2.fromOffset(70, 14), UDim2.fromOffset(26, 11), Color3.fromRGB(70, 92, 150), 6)
canopy.BackgroundTransparency = 0.2
local wing = frame(planeHolder, "Wing", UDim2.fromOffset(36, 26), UDim2.fromOffset(58, 10), SILHOUETTE, 5)
wing.Rotation = 16
local propeller = frame(planeHolder, "Propeller", UDim2.fromOffset(120, 12), UDim2.fromOffset(5, 32), Color3.fromRGB(190, 200, 225), 3)
propeller.AnchorPoint = Vector2.new(0, 0.5)
propeller.Position = UDim2.fromOffset(120, 27)
propeller.BackgroundTransparency = 0.35

-- The 740x360 design canvas: title, bar and tip, centred and scaled to fit any landscape screen.
local canvas = Instance.new("Frame")
canvas.Name = "Canvas"
canvas.AnchorPoint = Vector2.new(0.5, 0.5)
canvas.Position = UDim2.fromScale(0.5, 0.5)
canvas.Size = UDim2.fromOffset(DESIGN_W, DESIGN_H)
canvas.BackgroundTransparency = 1
canvas.Active = false
canvas.Parent = root
local canvasScale = Instance.new("UIScale")
canvasScale.Parent = canvas

local plaque = frame(canvas, "TitlePlaque", UDim2.fromOffset(170, 24), UDim2.fromOffset(400, 94), WOOD, 16)
stroke(plaque, RIM, 4)
local grain = Instance.new("UIGradient")
grain.Rotation = 90
grain.Color = ColorSequence.new(Color3.fromRGB(142, 102, 70), Color3.fromRGB(92, 64, 42))
grain.Parent = plaque
local title = label(plaque, "Title", Rules.TITLE, UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.94, 0.8), 56, Enum.Font.GothamBlack)
title.TextScaled = true
local titleLimit = Instance.new("UITextSizeConstraint")
titleLimit.MaxTextSize = 60
titleLimit.MinTextSize = 16
titleLimit.Parent = title
label(canvas, "Tagline", Rules.TAGLINE, UDim2.fromOffset(370, 134), UDim2.fromOffset(400, 26), 21, Enum.Font.GothamBold)

local statusLabel = label(canvas, "Status", Rules.statusText(done), UDim2.fromOffset(370, 262), UDim2.fromOffset(440, 24), 18, Enum.Font.GothamBold)
local trough = frame(canvas, "Trough", UDim2.fromOffset(150, 280), UDim2.fromOffset(440, 26), WOOD_DARK, 13)
stroke(trough, RIM, 2.5)
local fillClip = frame(trough, "FillClip", UDim2.fromOffset(4, 4), UDim2.fromOffset(432, 18), WOOD_DARK, 9)
fillClip.ClipsDescendants = true
local fill = frame(fillClip, "Fill", UDim2.new(), UDim2.fromScale(0, 1), BRASS, 9)
local fillGradient = Instance.new("UIGradient")
fillGradient.Rotation = 90
fillGradient.Color = ColorSequence.new(Color3.fromRGB(255, 218, 120), Color3.fromRGB(206, 138, 46))
fillGradient.Parent = fill
local tipLabel = label(canvas, "Tip", "", UDim2.fromOffset(370, 328), UDim2.fromOffset(700, 28), 20, Enum.Font.GothamBold)

local function layout()
	local size = root.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local s = math.clamp(math.min(size.X / DESIGN_W, size.Y / DESIGN_H), 0.7, 2.4)
	canvasScale.Scale = s
	planeScale.Scale = s
	glow.Size = UDim2.fromOffset(300 * s, 300 * s)
	sun.Size = UDim2.fromOffset(120 * s, 120 * s)
end
root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
layout()

-- Roblox's own top-bar buttons and chat would draw over the screen: hide them until it leaves.
local coreHidden = pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
end)

---------------------------------------------------------------------------------------------------- milestones

-- Two batches (perf pass 2026-10-19): the HUD sprites and engine/impact cues are constants here, so they start at once,
-- alongside the map download, instead of after game.Loaded; the button cues need the shared audio tables and follow
-- when the game has loaded. The milestone is reached when both batches are done (or the budget is spent).
local function preloadBatch(items: { Instance }, onDone: () -> ())
	assetsTotal += #items
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(items, function(contentId: string)
				assetsLoaded += 1
				lastAsset, lastAssetAt = contentId, now()
			end)
		end)
		for _, inst in items do
			inst:Destroy()
		end
		onDone()
	end)
end

local function soundItem(soundId: string): Sound
	local s = Instance.new("Sound")
	s.SoundId = soundId
	return s
end

local batchesLeft = 2
local function batchDone()
	batchesLeft -= 1
	if batchesLeft == 0 then
		mark("assets")
	end
end

local function preloadConstants()
	local items: { Instance } = {}
	for _, id in Rules.HUD_SPRITES do
		local img = Instance.new("ImageLabel")
		img.Image = Rules.thumbUrl(id, 420, 420)
		table.insert(items, img)
	end
	for _, soundId in Rules.KEY_SOUNDS do
		table.insert(items, soundItem(soundId))
	end
	preloadBatch(items, batchDone)
end

-- The button cues come from the shared audio tables (ReplicatedStorage has replicated once the game is loaded).
local function preloadCues()
	local items: { Instance } = {}
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if shared then
		for _, moduleName in { "UiAudioAssets", "AudioAssets", "SfxV2Audio" } do
			local m = shared:FindFirstChild(moduleName)
			if m and m:IsA("ModuleScript") then
				local ok, t = pcall(require, m)
				if ok and type(t) == "table" then
					for _, cue in Rules.KEY_SOUND_CUES do
						local id = (t :: any)[cue]
						if type(id) == "string" and id ~= "" then
							table.insert(items, soundItem(id))
						end
					end
				end
			end
		end
	end
	preloadBatch(items, batchDone)
end

preloadConstants()
task.delay(Rules.ASSET_BUDGET, function()
	mark("assets") -- the budget is spent: carry on, the rest streams in behind the game (mark is once-only)
end)

task.spawn(function()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	mark("game")
	preloadCues()
end)

local function mapRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = workspace:GetAttribute("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

local function vehicleThere(): boolean
	if player:GetAttribute("MountedInPlane") == true then
		return true
	end
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId then
				return true
			end
		end
	end
	return false
end

local mapSeenAt: number? = nil -- QA: when the active map's root first replicated (appended to the LOAD line)
-- QA: when the replicated world (workspace instances, terrain cells) last grew before control (appended to the LOAD
-- line as wsLast=/terrainLast=), so a slow join says how long the map download itself took.
local wsAdded, wsLastAt = 0, 0
local wsConn = workspace.DescendantAdded:Connect(function()
	wsAdded += 1
	wsLastAt = now()
end)
local terrainCells, terrainLastAt, terrainClock = 0, 0, 0

local function poll()
	if not done.character then
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			mark("character")
		end
	end
	if not done.vehicle and vehicleThere() then
		mark("vehicle")
	end
	if not mapSeenAt and mapRoot() then
		mapSeenAt = now()
	end
	if RunService:IsStudio() and now() - terrainClock >= 0.5 then -- QA only: CountCells walks the voxel store
		terrainClock = now()
		local okC, n = pcall(function(): number
			return workspace.Terrain:CountCells()
		end)
		if okC and n ~= terrainCells then
			terrainCells, terrainLastAt = n, now()
		end
	end
	if not done.track then
		local r = mapRoot()
		if r and r:GetAttribute("TrackReady") == true and workspace:GetAttribute("TrackSwitching") ~= true then
			mark("track")
		end
	end
end

---------------------------------------------------------------------------------------------------- leaving

local function logLoad(timedOut: boolean)
	if logged then
		return
	end
	logged = true
	local line = Rules.formatLog(stamps, if timedOut then Rules.missing(done) else {}, now(), workspace:GetAttribute("RaceMode"), workspace:GetAttribute("ActiveTrackId"))
		.. string.format(
			" mapSeen=%s wsLast=%.2f(n=%d) terrainLast=%.2f(cells=%d) worstFrame=%.2f@%.2f lastAsset=%s@%.2f",
			if mapSeenAt then string.format("%.2f", mapSeenAt) else "-",
			wsLastAt,
			wsAdded,
			terrainLastAt,
			terrainCells,
			worstFrame,
			worstAt,
			lastAsset,
			lastAssetAt
		)
	wsConn:Disconnect()
	print(line)
	player:SetAttribute("LoadLog", line) -- local only (never replicates): QA reads it after the output has scrolled
end

local function leave()
	if leaving then
		return
	end
	leaving = true
	player:SetAttribute("LoadingDone", true)
	if coreHidden then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, true)
		end)
	end
	root.Active = false
	local tween = TweenService:Create(root, TweenInfo.new(Rules.FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { GroupTransparency = 1 })
	tween.Completed:Once(function()
		gui:Destroy()
	end)
	tween:Play()
	-- Even if the tween never completes (a hidden window), the screen is gone shortly after.
	task.delay(Rules.FADE + 1, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

---------------------------------------------------------------------------------------------------- frame step

local mode = Rules.modeFor(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, UserInputService.GamepadEnabled)
local tips = Rules.tipsFor(mode)
local lastStatus = ""
local lastTip = 0
local pollClock = 0

local function step(dt: number)
	local t = now()
	if not logged and dt > worstFrame then
		worstFrame, worstAt = dt, t
	end
	-- Plane and clouds
	planeHolder.Position = UDim2.fromScale(Rules.planeX(t), 0.5 + Rules.planeBob(t))
	planeHolder.Rotation = Rules.planeTilt(t)
	propeller.Size = UDim2.fromOffset(5, 6 + 26 * math.abs(math.sin(t * 38)))
	for _, c in clouds do
		c.x += c.speed * dt
		if c.x > 1.2 then
			c.x = -0.2
		end
		c.holder.Position = UDim2.new(c.x, 0, c.holder.Position.Y.Scale, 0)
	end
	if leaving then
		return -- the fade runs; only the sky keeps moving
	end
	-- Milestones, ten times a second
	pollClock += dt
	if pollClock >= 0.1 then
		pollClock = 0
		poll()
	end
	local fraction = if assetsTotal > 0 then assetsLoaded / assetsTotal else 0
	shown = Rules.smooth(shown, Rules.progress(done, fraction), dt)
	fill.Size = UDim2.fromScale(shown, 1)
	local text = Rules.statusText(done)
	if text ~= lastStatus then
		lastStatus = text
		statusLabel.Text = text
	end
	-- Tips
	local idx = Rules.tipIndex(#tips, t)
	if idx ~= lastTip then
		lastTip = idx
		tipLabel.Text = tips[idx]
	end
	local alpha = Rules.tipAlpha(Rules.tipPhase(t))
	tipLabel.TextTransparency = 1 - alpha
	local tipStroke = tipLabel:FindFirstChildOfClass("UIStroke")
	if tipStroke then
		tipStroke.Transparency = 1 - alpha
	end
	-- Leaving: log the moment control is ready, fade after MIN_SHOW, or give up at TIMEOUT
	if not logged and Rules.allDone(done) then
		logLoad(false)
	end
	local st = Rules.status(done, t)
	if st == "timeout" then
		logLoad(true)
		leave()
	elseif st == "ready" then
		logLoad(false)
		leave()
	end
end

-- Backup for the 30 s promise: if RenderStepped never runs (hidden window, a stalled frame loop) the screen still leaves.
task.delay(Rules.TIMEOUT + 2, function()
	if not leaving then
		logLoad(true)
		leave()
	end
end)

local connection: RBXScriptConnection
connection = RunService.RenderStepped:Connect(function(dt: number)
	if not gui.Parent then
		connection:Disconnect()
		return
	end
	step(dt)
end)
