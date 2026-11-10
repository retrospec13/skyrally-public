--!strict
-- Map light cap (docs/audits/perf_review_v21.md PF-01). Rules: shared/LightLodRules.
-- The active map's decor lights (MapAdapter's route lights and fx lights, compiled prefab lights) are collected once
-- the map is TrackReady (and again 3 s and 8 s later, the same wait as MapFxLod/WorldAnim), never by a per-frame scan.
-- At 4 Hz only the K nearest to the camera stay on: 24 desktop, 12 phone tier, 8 with LOW GRAPHICS or a low Roblox
-- graphics quality. A lit light ranks a bit nearer (hysteresis) and fades through half brightness for one tick.
-- Gameplay lights (item pods, boost pads, coins, hazards, keys, battle props) are never touched: they are not tagged,
-- and any light under a trigger, pod or hazard is skipped even if it is. Vehicle lights are outside the map.
-- Per pass: one Position read, arithmetic on preallocated arrays, writes only when a light's level changes.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("LightLodRules"))
local TriggerRules = require(Shared:WaitForChild("TriggerRules"))
local Prof = require(Shared:WaitForChild("Prof"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LightLod = {}

-- Struct of arrays, index 1..n; reused across passes and maps (table.clear keeps capacity).
local lights: { Light } = {}
local px: { number } = {}
local py: { number } = {}
local pz: { number } = {}
local ranges: { number } = {}
local bases: { number } = {}
local levels: { number } = {}
local rank: { number } = {}
local want: { boolean } = {}
local order: { number } = {}
local n = 0
local known: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- What the map built (Enabled, Brightness), kept across rescans so a rescan never reads back this module's writes.
local built: { [Instance]: { on: boolean, brightness: number } } = setmetatable({}, { __mode = "k" }) :: any
local scanToken = 0
local lowQuality = false

local function hasAttr(inst: Instance, names: { string }): boolean
	for _, a in names do
		if inst:GetAttribute(a) ~= nil then
			return true
		end
	end
	return false
end

local function lightPosition(l: Light): Vector3?
	local p = l.Parent
	if p and p:IsA("BasePart") then
		return p.Position
	elseif p and p:IsA("Attachment") then
		return p.WorldPosition
	end
	return nil
end

local function collect(inst: Instance, root: Instance)
	if known[inst] or not (inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight")) then
		return
	end
	local light = inst :: Light
	local b = built[light]
	if not b then
		b = { on = light.Enabled, brightness = light.Brightness }
		built[light] = b
	end
	local orig = b :: { on: boolean, brightness: number }
	local tagged = light:GetAttribute("MapLight") == true or light:GetAttribute("MapFx") == true
	local inPrefab, gameplay = false, false
	local a = light.Parent
	while a and a ~= root do
		if hasAttr(a, Rules.GAMEPLAY_ATTRS) or CollectionService:HasTag(a, TriggerRules.TAG) or a.Name == "Hazards" then
			gameplay = true
			break
		end
		if a:IsA("Model") and a:GetAttribute(Rules.PREFAB_ATTR) ~= nil then
			inPrefab = true
		end
		a = a.Parent
	end
	if not Rules.managed(orig.on, tagged, inPrefab, gameplay) then
		return
	end
	local pos = lightPosition(light)
	if not pos then
		return
	end
	known[light] = true
	n += 1
	lights[n] = light
	px[n], py[n], pz[n] = pos.X, pos.Y, pos.Z
	ranges[n] = (light :: any).Range
	bases[n] = orig.brightness
	levels[n] = Rules.FULL
	rank[n] = 0
	want[n] = true
	order[n] = n
end

local function removeAt(i: number)
	-- swap-remove; the order array is rebuilt so it stays a permutation of 1..n
	lights[i], px[i], py[i], pz[i] = lights[n], px[n], py[n], pz[n]
	ranges[i], bases[i], levels[i] = ranges[n], bases[n], levels[n]
	lights[n] = nil :: any
	n -= 1
	for j = 1, n do
		order[j] = j
	end
	order[n + 1] = nil :: any
end

local function writeLevel(i: number, level: number)
	local on, br = Rules.apply(level, bases[i])
	local l = lights[i]
	if l.Brightness ~= br then
		l.Brightness = br
	end
	if l.Enabled ~= on then
		l.Enabled = on
	end
end

local function tick()
	local cam = workspace.CurrentCamera
	if not cam or n == 0 or workspace:GetAttribute("TrackSwitching") == true then
		return
	end
	local i = 1
	while i <= n do
		if not lights[i].Parent then
			known[lights[i]] = nil
			removeAt(i)
		else
			i += 1
		end
	end
	local c = cam.CFrame.Position
	local cx, cy, cz = c.X, c.Y, c.Z
	for j = 1, n do
		local dx, dy, dz = px[j] - cx, py[j] - cy, pz[j] - cz
		rank[j] = Rules.rankDistance(math.sqrt(dx * dx + dy * dy + dz * dz), ranges[j], levels[j] ~= Rules.OFF)
	end
	local k = Rules.budget(Settings.phoneTier(), Settings.lowGraphics() or lowQuality)
	Rules.select(rank, order, n, k, want)
	for j = 1, n do
		local lv = levels[j]
		local nv = Rules.step(lv, want[j])
		if nv ~= lv then
			levels[j] = nv
			writeLevel(j, nv)
		end
	end
end

local function scan(root: Instance)
	for _, d in root:GetDescendants() do
		collect(d, root)
	end
	tick()
end

local function restoreAll()
	for i = 1, n do
		if lights[i].Parent then
			writeLevel(i, Rules.FULL)
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
	restoreAll() -- a map kept loaded (hub) must not stay half dark after a switch away
	table.clear(lights)
	table.clear(order)
	table.clear(known)
	n = 0
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

local function readQuality()
	local ok, level = pcall(function(): number
		return (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel.Value
	end)
	lowQuality = ok and Rules.lowQuality(level)
end

function LightLod.init()
	RaceAttr.changed("ActiveTrackId", watchActive)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			watchActive()
		end
	end)
	readQuality()
	pcall(function()
		local ugs = UserSettings():GetService("UserGameSettings") :: any
		ugs:GetPropertyChangedSignal("SavedQualityLevel"):Connect(readQuality)
	end)
	watchActive()
	local step = Prof.wrap("SR_LightLod", tick)
	task.spawn(function()
		while true do
			task.wait(Rules.TICK)
			step()
		end
	end)
end

return LightLod
