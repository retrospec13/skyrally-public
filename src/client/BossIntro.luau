--!strict
-- Boss intro (client): when a boss race or rematch is holding on the grid (workspace.RaceGoTime in the future and a
-- boss model in workspace.Planes), the camera sweeps around the boss under a title card (name, title, REMATCH tag),
-- then hands back to the vehicle camera 1.4 s before GO so the player sees the 3-2-1 from the cockpit. Runs once per
-- countdown; skipped for players who join after the hold. BossIntro.onIntro(fn) registers a listener called with the
-- boss model and the sweep length as the sweep starts (BossAnimator plays the roar one-shot from it; a callback, so
-- this module needs no require back to the animator).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local Prof = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local TweenService = game:GetService("TweenService")

local BossConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BossConfig"))

local LocalPlayer = Players.LocalPlayer

local BossIntro = {}

local HANDBACK = 1.4 -- seconds before GO
local playedFor: number? = nil
local listeners: { (Model, number) -> () } = {}

-- fn(model, sweepSeconds) runs when an intro sweep starts.
function BossIntro.onIntro(fn: (Model, number) -> ())
	table.insert(listeners, fn)
end

local function card(boss: BossConfig.Boss, rematch: boolean): ScreenGui
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyBossIntro"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 15
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.86)
	bar.Size = UDim2.fromScale(0.62, 0.17)
	bar.BackgroundColor3 = Color3.fromRGB(24, 16, 12)
	bar.BackgroundTransparency = 0.25
	bar.Parent = sg
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 14)
	c.Parent = bar
	local st = Instance.new("UIStroke")
	st.Color = boss.accent
	st.Thickness = 3
	st.Parent = bar
	local function text(t: string, y: number, h: number, font: Enum.Font, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromScale(0.04, y)
		l.Size = UDim2.fromScale(0.92, h)
		l.Font = font
		l.TextScaled = true
		l.TextColor3 = color
		l.Text = t
		l.Parent = bar
		return l
	end
	text(if rematch then "BOSS REMATCH" else "BOSS RACE", 0.06, 0.22, Enum.Font.GothamBold, Color3.fromRGB(240, 226, 200))
	text(string.upper(boss.name), 0.28, 0.46, Enum.Font.GothamBlack, boss.accent)
	text(boss.title, 0.74, 0.2, Enum.Font.GothamBold, Color3.fromRGB(240, 226, 200))
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = bar
	TweenService:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	return sg
end

local function play(model: Model, goTime: number)
	local hull = model.PrimaryPart
	local boss = BossConfig.forZone(model:GetAttribute("BossZone") :: string?)
	if not hull or not boss then
		return
	end
	local rematch = RaceAttr.mine("RaceMode") == "rematch"
	local gui = card(boss, rematch)
	local t0 = os.clock()
	local dist = boss.length * 1.35 + 10
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { workspace:FindFirstChild("Planes") or model }
	rayParams.IgnoreWater = true
	RunService:BindToRenderStep("SkyRallyBossIntro", Enum.RenderPriority.Last.Value, function()
		local cam = workspace.CurrentCamera
		if not cam or not hull.Parent then
			return
		end
		local t = os.clock() - t0
		-- Start in front of the boss and sweep a half circle to its flank, slowly rising.
		local a = math.rad(-25) + t * 0.55
		local offset = Vector3.new(math.sin(a) * dist, boss.length * 0.25 + 4 + t * 0.8, -math.cos(a) * dist)
		local focus = hull.CFrame.Position + Vector3.new(0, boss.length * 0.15, 0)
		local want = hull.CFrame:PointToWorldSpace(offset)
		-- Canyon and cavern starts: pull the camera in front of any wall between it and the boss, never inside rock.
		local hit = workspace:Raycast(focus, want - focus, rayParams)
		if hit then
			want = hit.Position + (focus - hit.Position).Unit * 2.5
		end
		cam.CFrame = CFrame.lookAt(want, focus)
	end)
	local sweep = math.max(0.5, goTime - workspace:GetServerTimeNow() - HANDBACK)
	task.delay(sweep, function()
		RunService:UnbindFromRenderStep("SkyRallyBossIntro")
		gui:Destroy()
	end)
	for _, fn in listeners do
		task.spawn(fn, model, sweep)
	end
end

function BossIntro.init()
	RunService.Heartbeat:Connect(Prof.wrap("SR_BossIntro", function()
		local go = RaceAttr.mine("RaceGoTime")
		local mode = RaceAttr.mine("RaceMode")
		if type(go) ~= "number" or go == playedFor or (mode ~= "boss" and mode ~= "rematch") then
			return
		end
		if go - workspace:GetServerTimeNow() < HANDBACK + 1.2 then
			playedFor = go -- joined too late in the hold: no intro
			return
		end
		local planes = workspace:FindFirstChild("Planes")
		if not planes then
			return
		end
		for _, m in planes:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("IsBoss") == true and m.PrimaryPart then
				playedFor = go
				play(m, go)
				return
			end
		end
	end))
end

return BossIntro
