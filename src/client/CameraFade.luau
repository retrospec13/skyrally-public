--!strict
-- Camera-occlusion fade (critic v29 Wave 1b A13; rules and numbers in shared/CameraFadeRules). The active map's parts
-- under a folder named in CameraFadeRules.FOLDERS (SPACE-4: Highway/Gantries and Landmarks/GlassVault) are indexed once
-- the map is TrackReady (and again 3 s and 8 s later, like LightLod), never by a per-frame scan. At 30 Hz each part whose
-- box is within RADIUS studs of the camera gets LocalTransparencyModifier FADE on this client; it returns to 0 when the
-- camera moves away. Writes only on a change. VISUAL ONLY: collision, CanQuery, the server copy and other clients are
-- untouched (wall driving, the corridor, barriers and rescue are unchanged).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("CameraFadeRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local CameraFade = {}

type Entry = { part: BasePart, radius: number, faded: boolean }

local entries: { Entry } = {}
local known: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local scanToken = 0
local since = 0

local function restoreAll()
	for _, e in entries do
		if e.faded and e.part.Parent then
			e.part.LocalTransparencyModifier = 0
		end
	end
	table.clear(entries)
	table.clear(known)
end

local function scan(root: Instance)
	for _, folder in root:GetDescendants() do
		if (folder:IsA("Folder") or folder:IsA("Model")) and Rules.FOLDERS[folder.Name] then
			for _, d in folder:GetDescendants() do
				if d:IsA("BasePart") and not known[d] and d.Transparency < 1 then
					known[d] = true
					table.insert(entries, { part = d, radius = d.Size.Magnitude * 0.5, faded = false })
				end
			end
		end
	end
end

local function activeRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

local function watchActive()
	scanToken += 1
	local my = scanToken
	restoreAll()
	task.spawn(function()
		local root: Instance? = nil
		for _ = 1, 240 do
			if my ~= scanToken then
				return
			end
			root = activeRoot()
			if root and root:GetAttribute("TrackReady") == true then
				break
			end
			task.wait(0.5)
		end
		if root and my == scanToken then
			scan(root)
			for _, t in { 3, 8 } do
				task.delay(t, function()
					if my == scanToken and root.Parent then
						scan(root)
					end
				end)
			end
		end
	end)
end

local function step(dt: number)
	since += dt
	if since < Rules.TICK or #entries == 0 then
		return
	end
	since = 0
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	for _, e in entries do
		local p = e.part
		local want = false
		if Rules.mayFade((p.Position - camPos).Magnitude, e.radius) then
			local o = p.CFrame:PointToObjectSpace(camPos)
			local h = p.Size * 0.5
			want = Rules.fadeAt(Rules.boxDistance(o.X, o.Y, o.Z, h.X, h.Y, h.Z)) > 0
		end
		if want ~= e.faded then
			e.faded = want
			p.LocalTransparencyModifier = if want then Rules.FADE else 0
		end
	end
end

function CameraFade.init()
	RaceAttr.changed("ActiveTrackId", watchActive)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			watchActive()
		end
	end)
	watchActive()
	RunService.RenderStepped:Connect(step)
end

return CameraFade
