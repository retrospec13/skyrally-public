--!strict
-- Token Homecoming, part two (REMARKABLE Batch 2 item 24): the next portal wakes with a short cutaway. Client only.
--
-- When the player's PortalStates (the server's own JSON) shows an arch open that this session has not yet seen open,
-- the next time the player is in the hub with the curtain gone, the token flight landed and the car nearly still, the
-- camera cuts to that arch (letterbox, slow push-in): the arch sits dark and rumbling, then wakes in a burst of gold,
-- its swirl and vortex light up, a choir-ish chord swells, and "FROSTPEAK IS AWAKE!" slides in. 2.8 s, then the
-- chase camera is back. A car that never slows down gets a toast instead (no camera grab at speed).
-- What was already open when the session started is "seen": no cutaway on join. Zones without an arch (the final boss)
-- are marked seen silently.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local FinaleRules = require(Shared:WaitForChild("FinaleRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local CarController = require(script.Parent:WaitForChild("CarController"))
local FlightController = require(script.Parent:WaitForChild("FlightController"))
local Settings = require(script.Parent:WaitForChild("Settings")) -- audit H13: camera shake toggle

local LocalPlayer = Players.LocalPlayer

local PortalWake = {}

local CUT_SECONDS = 2.8
local WAKE_AT = 0.9 -- the chord in portal_wake lands at 0.85 s
local SLOW_SPEED = 25
local WAIT_LIMIT = 12
local CREAM = Color3.fromRGB(250, 242, 222)
local INK = Color3.fromRGB(40, 22, 12)

local seen: { [string]: boolean }? = nil
local queue: { string } = {}
local running = false
local started = false
local gui: ScreenGui? = nil
local bars: { Frame } = {}
local card: Frame? = nil
local cardTitle: TextLabel? = nil
local cardSub: TextLabel? = nil
local flash: PointLight? = nil
local portalPlunge: any = nil

local function inHub(): boolean
	return RaceAttr.mine("RaceMode") == "hub" and workspace:GetAttribute("TrackSwitching") ~= true
end

local function speedNow(): number
	if CarController.car and CarController.hull then
		return math.abs(CarController.speed)
	end
	return if FlightController.hull then math.abs(FlightController.currentSpeed) else 0
end

local function ensureGui(): ScreenGui
	local g = gui
	if g and g.Parent then
		return g
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyPortalWake"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 22
	sg.Enabled = false
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	for i = 1, 2 do
		local b = Instance.new("Frame")
		b.Name = "Bar" .. i
		b.BorderSizePixel = 0
		b.BackgroundColor3 = Color3.new(0, 0, 0)
		b.Size = UDim2.fromScale(1, 0.12)
		b.AnchorPoint = Vector2.new(0, if i == 1 then 1 else 0)
		b.Position = UDim2.fromScale(0, if i == 1 then 0 else 1)
		b.Parent = sg
		table.insert(bars, b)
	end
	local c = Instance.new("Frame")
	c.Name = "Card"
	c.AnchorPoint = Vector2.new(0.5, 1)
	c.Position = UDim2.fromScale(0.5, 1.3)
	c.Size = UDim2.fromScale(0.56, 0.16)
	c.BorderSizePixel = 0
	c.Parent = sg
	local cr = Instance.new("UICorner")
	cr.CornerRadius = UDim.new(0, 12)
	cr.Parent = c
	local st = Instance.new("UIStroke")
	st.Name = "Rim"
	st.Thickness = 3
	st.Parent = c
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(0.04, 0.06)
	t.Size = UDim2.fromScale(0.92, 0.58)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = CREAM
	t.Parent = c
	local ts = Instance.new("UIStroke")
	ts.Color = INK
	ts.Thickness = 2.5
	ts.Parent = t
	local s = Instance.new("TextLabel")
	s.Name = "Sub"
	s.BackgroundTransparency = 1
	s.Position = UDim2.fromScale(0.1, 0.64)
	s.Size = UDim2.fromScale(0.8, 0.3)
	s.Font = Enum.Font.GothamBold
	s.TextScaled = true
	s.TextColor3 = CREAM
	s.Text = "Drive in to race"
	s.Parent = c
	gui, card, cardTitle, cardSub = sg, c, t, s
	return sg
end

-- The arch's own emitters (the plan's shimmer, TrackFlow's swirl and vortex): dark until the wake.
local function emitters(part: BasePart): { ParticleEmitter }
	local out: { ParticleEmitter } = {}
	for _, d in part:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(out, d)
		end
	end
	return out
end

local function play(zone: string, part: BasePart)
	local info = TrackInfo.forZone(zone)
	local color = if info then info.color else INK
	local accent = if info then info.accent else CREAM
	local sg = ensureGui()
	sg.Enabled = true
	local c, title = card :: Frame, cardTitle :: TextLabel
	c.BackgroundColor3 = color
	local rim = c:FindFirstChild("Rim") :: UIStroke
	rim.Color = accent
	title.Text = string.format("%s IS AWAKE!", if info then string.upper(info.zoneName) else zone)
	title.TextColor3 = accent
	c.Position = UDim2.fromScale(0.5, 1.3)
	for i, b in bars do
		b.Position = UDim2.fromScale(0, if i == 1 then 0 else 1)
		TweenService:Create(b, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0, if i == 1 then 0.12 else 0.88),
		}):Play()
	end
	-- Dark first: the swirl and vortex go out until the wake.
	local fx = emitters(part)
	local was: { [ParticleEmitter]: boolean } = {}
	for _, e in fx do
		was[e] = e.Enabled
		e.Enabled = false
	end
	local light = flash
	if not light or not light.Parent then
		local l = Instance.new("PointLight")
		l.Name = "WakeFlash"
		l.Range = 40
		l.Shadows = false
		flash = l
		light = l
	end
	local lt = light :: PointLight
	lt.Color = accent
	lt.Brightness = 0
	lt.Parent = part
	PayoffSound.play("portal_wake")
	local cf = part.CFrame
	local look, up = cf.LookVector, Vector3.yAxis
	local focus = cf.Position + up * 2
	local from = cf.Position - look * 52 + up * 8
	local to = cf.Position - look * 26 + up * 3
	local t0 = os.clock()
	local woke = false
	RunService:BindToRenderStep("SkyRallyPortalWake", Enum.RenderPriority.Last.Value + 2, function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local t = os.clock() - t0
		local k = math.clamp(t / CUT_SECONDS, 0, 1)
		local e = 1 - (1 - k) * (1 - k)
		local shake = if t < WAKE_AT then 0.25 * (t / WAKE_AT) else 0.6 * math.max(0, 1 - (t - WAKE_AT) * 2.5)
		local wobble = Vector3.new(math.sin(t * 41) * shake, math.sin(t * 37 + 1) * shake, 0) * Settings.shakeScale()
		cam.CFrame = CFrame.lookAt(from:Lerp(to, e) + wobble, focus)
		cam.FieldOfView = 60
		if not woke and t >= WAKE_AT then
			woke = true
			for _, em in fx do
				em.Enabled = was[em] ~= false
				em:Emit(30)
			end
			local Vfx = require(script.Parent:WaitForChild("Vfx")) :: any
			Vfx.burst("finish", CFrame.lookAt(cf.Position, cf.Position - look))
			Vfx.burst("confetti", CFrame.lookAt(cf.Position - look * 4, cf.Position - look * 4 + up * 50), 0.6)
			lt.Brightness = 8
			TweenService:Create(lt, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 1.5 }):Play()
			TweenService:Create(c, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.86) }):Play()
		end
	end)
	task.wait(CUT_SECONDS)
	RunService:UnbindFromRenderStep("SkyRallyPortalWake")
	for _, em in fx do
		if em.Parent then
			em.Enabled = was[em] ~= false
		end
	end
	for i, b in bars do
		TweenService:Create(b, TweenInfo.new(0.25), { Position = UDim2.fromScale(0, if i == 1 then 0 else 1) }):Play()
	end
	TweenService:Create(c, TweenInfo.new(0.25), { Position = UDim2.fromScale(0.5, 1.3) }):Play()
	task.delay(0.3, function()
		if not running then
			sg.Enabled = false
		end
	end)
	task.delay(3, function()
		lt.Parent = nil
	end)
end

-- No camera grab at speed: the title card alone (no letterbox), with the wake sound a little quieter.
local function toast(zone: string)
	local info = TrackInfo.forZone(zone)
	local sg = ensureGui()
	sg.Enabled = true
	local c, title = card :: Frame, cardTitle :: TextLabel
	c.BackgroundColor3 = if info then info.color else INK
	local rim = c:FindFirstChild("Rim") :: UIStroke
	rim.Color = if info then info.accent else CREAM
	title.Text = string.format("%s IS AWAKE!", if info then string.upper(info.zoneName) else zone)
	title.TextColor3 = if info then info.accent else CREAM
	c.Position = UDim2.fromScale(0.5, 1.3)
	TweenService:Create(c, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.96) }):Play()
	PayoffSound.play("portal_wake", 1, 0.6)
	task.delay(3, function()
		TweenService:Create(c, TweenInfo.new(0.25), { Position = UDim2.fromScale(0.5, 1.3) }):Play()
		task.delay(0.3, function()
			if not running then
				sg.Enabled = false
			end
		end)
	end)
end

local function pump()
	if running or #queue == 0 then
		return
	end
	running = true
	task.spawn(function()
		while #queue > 0 do
			local zone = queue[1]
			-- Wait for a calm moment: in the hub, curtain and iris gone, token flight landed, car nearly still.
			local waited = 0
			local calm = false
			while waited < WAIT_LIMIT do
				local flying = false
				pcall(function()
					flying = (require(script.Parent:WaitForChild("TokenHomecoming")) :: any).busy()
				end)
				local plunging = portalPlunge and portalPlunge.busy()
				if inHub() and not flying and not plunging and speedNow() < SLOW_SPEED then
					calm = true
					break
				end
				task.wait(0.25)
				waited += 0.25
			end
			table.remove(queue, 1)
			if inHub() then
				local part = portalPlunge and portalPlunge.portalPart(zone)
				if calm and part then
					play(zone, part)
				else
					toast(zone)
				end
			else
				-- Left the hub while waiting: wake it on the next visit.
				if seen then
					seen[zone] = nil
				end
			end
			task.wait(0.4)
		end
		running = false
	end)
end

local function check()
	local states = portalPlunge and portalPlunge.states() or {}
	if #states == 0 then
		return
	end
	local s = seen
	if not s then
		local first: { [string]: boolean } = {}
		for _, st in states do
			if type(st) == "table" and st.open == true and type(st.zone) == "string" then
				first[st.zone] = true
			end
		end
		seen = first
		return
	end
	if not inHub() then
		return -- a portal opened mid-race wakes when the player is back on Central Island
	end
	for _, zone in FinaleRules.newlyOpened(s, states) do
		s[zone] = true
		if zone == "HUB" then
			continue -- no arch for the final boss: the Adventure board shows it
		end
		table.insert(queue, zone)
	end
	pump()
end

-- plunge: client/PortalPlunge (passed in, so the two modules never require each other): states(), portalPart(), busy().
function PortalWake.init(plunge: any)
	if started then
		return
	end
	started = true
	portalPlunge = plunge
	LocalPlayer:GetAttributeChangedSignal("PortalStates"):Connect(check)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			-- Arriving: let the iris open and the arches stream in first.
			task.delay(2.5, check)
		end
	end)
	task.delay(4, check)
end

return PortalWake
