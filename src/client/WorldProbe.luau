--!strict
-- World presence probe (L68 companion to AssetProbe): what a joined client actually has, over time. Logs every 5 s for
-- 60 s after join: map readiness, terrain around the camera (rays), the Lighting sky and the server adapter's per-step
-- results mirrored on the map root. Needed because server output never reaches the client log of a published place.
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local ProbeRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ProbeRules"))

local WorldProbe = {}

local function terrainHits(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return -1
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hits = 0
	for _, d in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis, Vector3.yAxis, -Vector3.yAxis } do
		if workspace:Raycast(cam.CFrame.Position, d * 600, params) then
			hits += 1
		end
	end
	return hits
end

local function mapRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	if maps and type(id) == "string" then
		return maps:FindFirstChild(id)
	end
	return nil
end

function WorldProbe.sample(t: number)
	local root = mapRoot()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	local okO, ovr = pcall(function()
		return MaterialService:GetBaseMaterialOverride(Enum.Material.Sandstone)
	end)
	local music = "none"
	for _, snd in game:GetService("SoundService"):GetChildren() do
		if snd:IsA("Sound") and string.sub(snd.Name, 1, 15) == "SkyRally_music_" then
			music = string.format("%s loaded=%s playing=%s len=%.0f", string.sub(snd.Name, 10), tostring(snd.IsLoaded), tostring(snd.IsPlaying), snd.TimeLength)
		end
	end
	print(string.format("[SkyRally][WORLD] t=%d music=%s", t, music))
	print(string.format("[SkyRally][WORLD] t=%d track=%s ready=%s terrainRays=%d/6 sky=%s sandstoneOverride=%s",
		t, tostring(RaceAttr.mine("ActiveTrackId")), tostring(root and root:GetAttribute("TrackReady")),
		terrainHits(), if sky then sky.Name else "none", if okO then tostring(ovr) else "unreadable"))
end

function WorldProbe.dumpSteps()
	local root = mapRoot()
	if not root then
		print("[SkyRally][WORLD] no map root")
		return
	end
	local names = {}
	for k in root:GetAttributes() do
		if string.sub(k, 1, 13) == "AdapterStep_" then
			table.insert(names, k)
		end
	end
	table.sort(names)
	for _, k in names do
		print(string.format("[SkyRally][WORLD] %s %s", k, tostring(root:GetAttribute(k))))
	end
end

function WorldProbe.init()
	-- QA accounts and Studio only (L41/L42): the sweep is a hitch and log burst on a phone player.
	if not ProbeRules.shouldRun(RunService:IsStudio(), Players.LocalPlayer.UserId) then
		return
	end
	task.spawn(function()
		for t = 5, 60, 5 do
			task.wait(5)
			WorldProbe.sample(t)
			if t == 15 or t == 60 then
				WorldProbe.dumpSteps()
			end
		end
	end)
end

return WorldProbe
