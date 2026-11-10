--!strict
-- Camera-near fade (visual critic v29 Wave 1b C2). Rules and the why: shared/CameraNearFadeRules.
-- Every SCAN_EVERY seconds the containers marked with the CameraNearFade attribute are collected (Folders/Models under
-- workspace, SCAN_DEPTH deep), each model's bounding sphere cached; every frame only the models whose sphere reaches
-- within the radius of the camera have their parts' LocalTransparencyModifier written, and parts leaving the radius
-- are restored to 0 once. Client-only visual: never CanCollide, CanQuery, Transparency or anything on the server.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CameraNearFadeRules"))

local CameraNearFade = {}

type Group = { parts: { BasePart }, centre: Vector3, reach: number, radius: number }

local groups: { Group } = {}
local faded: { [BasePart]: boolean } = {}
local started = false

local function collectParts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function groupOf(parts: { BasePart }, radius: number): Group?
	if #parts == 0 then
		return nil
	end
	local sum = Vector3.zero
	for _, p in parts do
		sum += p.Position
	end
	local centre = sum / #parts
	local reach = 0
	for _, p in parts do
		reach = math.max(reach, (p.Position - centre).Magnitude + p.Size.Magnitude * 0.5)
	end
	return { parts = parts, centre = centre, reach = reach, radius = radius }
end

local function addContainer(c: Instance, radius: number, into: { Group })
	-- one group per direct child model (a rib, a spine, the skull), so the per-frame sphere test stays coarse and cheap
	local loose: { BasePart } = {}
	for _, child in c:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(loose, child)
		elseif child:IsA("Model") or child:IsA("Folder") then
			local g = groupOf(collectParts(child), radius)
			if g then
				table.insert(into, g)
			end
		end
	end
	local g = groupOf(loose, radius)
	if g then
		table.insert(into, g)
	end
end

local function scan()
	local found: { Group } = {}
	local function walk(inst: Instance, depth: number)
		for _, child in inst:GetChildren() do
			if child:IsA("Folder") or child:IsA("Model") then
				local r = Rules.radius(child:GetAttribute(Rules.ATTR))
				if r then
					addContainer(child, r, found)
				elseif depth < Rules.SCAN_DEPTH then
					walk(child, depth + 1)
				end
			end
		end
	end
	walk(workspace, 1)
	groups = found
end

local function restoreAll()
	for p in faded do
		if p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
	table.clear(faded)
end

local function step()
	local cam = workspace.CurrentCamera
	if not cam or workspace:GetAttribute(Rules.OFF_ATTR) == true then
		if next(faded) then
			restoreAll()
		end
		return
	end
	local eye = cam.CFrame.Position
	local still: { [BasePart]: boolean } = {}
	for _, g in groups do
		if (g.centre - eye).Magnitude - g.reach < g.radius then
			for _, p in g.parts do
				if p.Parent then
					local m = Rules.modifier(Rules.surfaceDistance((p.Position - eye).Magnitude, p.Size), g.radius)
					if m > 0 then
						if math.abs(p.LocalTransparencyModifier - m) > 0.02 then
							p.LocalTransparencyModifier = m
						end
						still[p] = true
					end
				end
			end
		end
	end
	for p in faded do
		if not still[p] and p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
	faded = still
end

function CameraNearFade.init()
	if started then
		return
	end
	started = true
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				scan()
			end)
			if not ok then
				warn("[SkyRally][NEARFADE] " .. tostring(err))
			end
			task.wait(Rules.SCAN_EVERY)
		end
	end)
	RunService.RenderStepped:Connect(function()
		if #groups > 0 or next(faded) then
			step()
		end
	end)
end

return CameraNearFade
