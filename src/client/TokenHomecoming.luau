--!strict
-- Token Homecoming (REMARKABLE Batch 2 item 24): a Sky Token the server just awarded is a real thing you watch come
-- home. It pops out where it was won (the results card's award line after a race, or the hub find on screen), spins
-- like a coin and glints, then whistles along an arc into the HUD counter, which only then counts up with its burst
-- (client/HudExtras holds the count until the token lands, or 2 s past the flight at most). The portal it may have
-- woken gets its cutaway from client/PortalWake once the player is back in the hub.
-- Display only: the award is the server's (SkyTokens attribute, RaceFinished award.tokenResult, HubFind).
-- One token and eight trail sparks, built once and reused; a RenderStepped connection only during a flight.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FinaleRules = require(Shared:WaitForChild("FinaleRules"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local HudExtras = require(script.Parent:WaitForChild("HudExtras"))

local LocalPlayer = Players.LocalPlayer

local TokenHomecoming = {}

local GOLD = Color3.fromRGB(255, 214, 90)
local GOLD_DEEP = Color3.fromRGB(214, 140, 30)
local TRAIL = 8
local TOKEN_PX = 64

local gui: ScreenGui? = nil
local coin: Frame
local coinStar: ImageLabel
local coinShine: UIGradient
local trail: { ImageLabel } = {}
local flying = false
local flightToken = 0

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function build()
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyTokenFlight"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 30 -- over the HUD, the results card and the Garage
	sg.Enabled = false
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = sg
	for i = 1, TRAIL do
		local s = Instance.new("ImageLabel")
		s.Name = "Spark" .. i
		s.BackgroundTransparency = 1
		s.Image = tex("star_twinkle")
		s.ImageColor3 = GOLD
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.ImageTransparency = 1
		s.Parent = sg
		table.insert(trail, s)
	end
	local c = Instance.new("Frame")
	c.Name = "Token"
	c.AnchorPoint = Vector2.new(0.5, 0.5)
	c.Size = UDim2.fromOffset(TOKEN_PX, TOKEN_PX)
	c.BackgroundColor3 = GOLD
	c.BorderSizePixel = 0
	c.Parent = sg
	coin = c
	local cr = Instance.new("UICorner")
	cr.CornerRadius = UDim.new(0.5, 0)
	cr.Parent = c
	local st = Instance.new("UIStroke")
	st.Color = GOLD_DEEP
	st.Thickness = 4
	st.Parent = c
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 160)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 255, 240)),
		ColorSequenceKeypoint.new(0.55, GOLD),
		ColorSequenceKeypoint.new(1, GOLD_DEEP),
	})
	grad.Rotation = 35
	grad.Offset = Vector2.new(-1, 0)
	grad.Parent = c
	coinShine = grad
	local star = Instance.new("ImageLabel")
	star.Name = "Star"
	star.BackgroundTransparency = 1
	star.AnchorPoint = Vector2.new(0.5, 0.5)
	star.Position = UDim2.fromScale(0.5, 0.5)
	star.Size = UDim2.fromScale(0.78, 0.78)
	star.Image = tex("star_twinkle")
	star.ImageColor3 = Color3.fromRGB(255, 250, 225)
	star.Parent = c
	coinStar = star
	Instance.new("UIScale").Parent = c
end

function TokenHomecoming.busy(): boolean
	return flying
end

-- Flies a token from screen point (x0, y0) into the HUD counter. HudExtras holds the count-up until it lands.
-- follow: a GUI object the token sits on while it spins (the results card pops in under it: its live centre, not the
-- point it had when the flight started; that stale point put the coin over the "1ST" title).
function TokenHomecoming.flyFrom(x0: number, y0: number, follow: GuiObject?)
	if not gui then
		build()
	end
	local sg = gui :: ScreenGui
	HudExtras.holdTokenAward(FinaleRules.TOKEN_HOLD_SECONDS + FinaleRules.TOKEN_FLIGHT_SECONDS + 2)
	flightToken += 1
	local my = flightToken
	flying = true
	sg.Enabled = true
	local sc = coin:FindFirstChildOfClass("UIScale") :: UIScale
	sc.Scale = 0
	coin.Position = UDim2.fromOffset(x0, y0)
	coin.Size = UDim2.fromOffset(TOKEN_PX, TOKEN_PX)
	coin.Rotation = 0
	coinShine.Offset = Vector2.new(-1, 0)
	TweenService:Create(sc, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.25 }):Play()
	TweenService:Create(coinShine, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, false, 0.1), { Offset = Vector2.new(1, 0) }):Play()
	PayoffSound.play("token_land", 1.25, 0.5) -- a bright "ting" as it appears
	local t0 = os.clock()
	local hold = FinaleRules.TOKEN_HOLD_SECONDS
	local fly = FinaleRules.TOKEN_FLIGHT_SECONDS
	local whooshed = false
	local trailAt = 0
	local trailIndex = 1
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if my ~= flightToken then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local t = os.clock() - t0
		-- Coin spin: squash the width with a cosine so the flat token reads as turning in 3D.
		local spin = math.abs(math.cos(t * (if t < hold then 9 else 16)))
		local target = HudExtras.tokenTarget()
		local x1, y1 = x0, y0
		local endPx = 26
		if target and target.Parent then
			x1 = target.AbsolutePosition.X + target.AbsoluteSize.X / 2
			y1 = target.AbsolutePosition.Y + target.AbsoluteSize.Y / 2
			endPx = math.max(14, target.AbsoluteSize.X)
		end
		if t < hold then
			if follow and follow.Parent and follow.AbsoluteSize.X > 0 then
				x0 = follow.AbsolutePosition.X + follow.AbsoluteSize.X / 2
				y0 = follow.AbsolutePosition.Y + follow.AbsoluteSize.Y / 2
				coin.Position = UDim2.fromOffset(x0, y0)
			end
			coin.Size = UDim2.fromOffset(TOKEN_PX * (0.15 + 0.85 * spin), TOKEN_PX)
			return
		end
		if not whooshed then
			whooshed = true
			PayoffSound.play("token_whoosh")
		end
		local k = math.clamp((t - hold) / fly, 0, 1)
		local x, y = FinaleRules.tokenArc(x0, y0, x1, y1, k, 120)
		local px = TOKEN_PX + (endPx - TOKEN_PX) * k
		coin.Position = UDim2.fromOffset(x, y)
		coin.Size = UDim2.fromOffset(px * (0.15 + 0.85 * spin), px)
		sc.Scale = 1.25 - 0.25 * k
		-- Sparks drop off the token every 60 ms and fade where they fell.
		if t - trailAt > 0.06 then
			trailAt = t
			local s = trail[trailIndex]
			trailIndex = trailIndex % TRAIL + 1
			s.Position = UDim2.fromOffset(x, y)
			s.Size = UDim2.fromOffset(px * 0.55, px * 0.55)
			s.ImageTransparency = 0
			s.Rotation = math.random(0, 360)
			TweenService:Create(s, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				ImageTransparency = 1,
				Size = UDim2.fromOffset(4, 4),
				Position = UDim2.fromOffset(x + math.random(-12, 12), y + 18),
			}):Play()
		end
		if k >= 1 then
			if conn then
				conn:Disconnect()
			end
			PayoffSound.play("token_land")
			HudExtras.releaseTokenAward()
			flying = false
			task.delay(0.5, function()
				if my == flightToken then
					sg.Enabled = false
				end
			end)
			coin.Size = UDim2.fromOffset(0, 0)
		end
	end)
	-- Safety: never leave the flag up (a destroyed GUI, a stalled frame loop).
	task.delay(hold + fly + 2.5, function()
		if my == flightToken and flying then
			flying = false
			sg.Enabled = false
			HudExtras.releaseTokenAward()
		end
	end)
end

-- From a GUI object (the results card's award line).
function TokenHomecoming.flyFromGui(obj: GuiObject?)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	if obj and obj.Parent and obj.AbsoluteSize.X > 0 then
		TokenHomecoming.flyFrom(obj.AbsolutePosition.X + obj.AbsoluteSize.X / 2, obj.AbsolutePosition.Y + obj.AbsoluteSize.Y / 2, obj)
	else
		TokenHomecoming.flyFrom(vp.X * 0.5, vp.Y * 0.45)
	end
end

-- From a point in the world (a hub find): where it is on screen, else the middle of the screen.
function TokenHomecoming.flyFromWorld(pos: Vector3)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local p, onScreen = cam:WorldToViewportPoint(pos)
	local vp = cam.ViewportSize
	if onScreen then
		TokenHomecoming.flyFrom(math.clamp(p.X, 40, vp.X - 40), math.clamp(p.Y, 40, vp.Y - 40))
	else
		TokenHomecoming.flyFrom(vp.X * 0.5, vp.Y * 0.55)
	end
end

return TokenHomecoming
