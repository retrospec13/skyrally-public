--!strict
-- Hub plaza floor bands (v28 visual critic 1.18): a terracotta border ring, an inner ring round the fountain and a two-tone
-- tiled lane from the fountain to each of the five portal arches, laid flat on the Pavement terrain. The plaza is baked
-- terrain (no Studio here), so the bands are thin painted parts instead. Visual only, and they must never touch driving:
-- every part is CanCollide = false AND CanQuery = false (the car's ground ray ignores CanCollide but not CanQuery, so the
-- bands are invisible to it), 0.12 studs thick, no lights, no scripts. Like the stands and the board they exist only while
-- the server is in the hub (RaceMode "hub"). Owner rule: wall/mountain driving, adhesion, barriers, rescue are untouched.
local PlazaBands = {}

-- tools/map/author_hub0.py: ORIGIN (-8000, 0, 8000) + PLAZA_C (-150, 0), PLAZA_H 26, PLAZA_R 150; portal bearings.
local CENTER = Vector3.new(-8150, 26, 8000)
local GROUND_TOLERANCE = 3
local PORTAL_BEARINGS = { -80, -40, 0, 40, 80 }
local THICK = 0.12

local TERRA_A = Color3.fromRGB(201, 121, 78)
local TERRA_B = Color3.fromRGB(189, 106, 66)
local SAND_A = Color3.fromRGB(221, 196, 148)
local SAND_B = Color3.fromRGB(207, 178, 132)
local CREAM = Color3.fromRGB(234, 220, 186)

local model: Model? = nil
local started = false

local function slab(parent: Instance, y: number, x: number, z: number, length: number, width: number, yawDeg: number, color: Color3)
	local p = Instance.new("Part")
	p.Name = "Band"
	p.Size = Vector3.new(width, THICK, length)
	p.CFrame = CFrame.new(x, y + THICK / 2 + 0.02, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
	p.Color = color
	p.Material = Enum.Material.Slate
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function groundY(): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.RespectCanCollide = false
	local ok, hit = pcall(function()
		return workspace:Raycast(CENTER + Vector3.new(60, 60, 60), Vector3.new(0, -120, 0), params)
	end)
	if ok and hit and math.abs(hit.Position.Y - CENTER.Y) <= GROUND_TOLERANCE then
		return hit.Position.Y
	end
	return CENTER.Y
end

-- A ring of chord slabs at radius r (alternating two tones), width w.
local function ring(parent: Instance, y: number, r: number, w: number, count: number, a: Color3, b: Color3, from: number?, to: number?)
	local step = 2 * math.pi / count
	for i = 0, count - 1 do
		local bearing = i * step -- 0 = north (-Z), clockwise
		local deg = math.deg(bearing)
		if from and to and not (deg >= from and deg <= to) then
			continue
		end
		local mid = bearing + step / 2
		local x = CENTER.X + r * math.sin(mid)
		local z = CENTER.Z - r * math.cos(mid)
		slab(parent, y, x, z, 2 * r * math.sin(step / 2) + 0.3, w, math.deg(math.pi / 2 - mid), if i % 2 == 0 then a else b)
	end
end

local function build(y: number): Model
	local m = Instance.new("Model")
	m.Name = "PlazaBands"
	ring(m, y, 138, 6, 56, TERRA_A, TERRA_B, 98, 262) -- border ring along the south rim, between the paths and the arch arc
	ring(m, y, 138, 2.4, 64, CREAM, CREAM)
	ring(m, y, 26, 3.2, 28, TERRA_A, TERRA_B) -- inner ring round the fountain basin
	ring(m, y, 70, 1.6, 48, SAND_B, SAND_A)
	for _, bearing in PORTAL_BEARINGS do
		local b = math.rad(bearing)
		local ox, oz = math.sin(b), -math.cos(b)
		local yaw = math.deg(-b)
		for i = 0, 10 do -- tiled approach lane, 8-stud tiles from r 30 to r 114 in two tones
			local r = 32 + i * 8
			local tone = if i % 2 == 0 then SAND_A else SAND_B
			slab(m, y, CENTER.X + r * ox, CENTER.Z + r * oz, 7.6, 11, yaw, tone)
			slab(m, y, CENTER.X + r * ox, CENTER.Z + r * oz, 7.6, 4.2, yaw, if i % 2 == 0 then SAND_B else SAND_A)
		end
		for _, side in { -1, 1 } do -- terracotta kerb lines along the lane
			local px, pz = -oz * side * 6.2, ox * side * 6.2
			slab(m, y, CENTER.X + 73 * ox + px, CENTER.Z + 73 * oz + pz, 84, 1.0, yaw, TERRA_A)
		end
	end
	return m
end

function PlazaBands.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		task.wait(2)
		while true do
			local ok, err = pcall(function(): any
				local hub = workspace:GetAttribute("RaceMode") == "hub" and workspace:GetAttribute("TrackSwitching") ~= true
				if not hub then
					if model and model.Parent then
						model.Parent = nil
					end
				elseif not model then
					local m = build(groundY())
					model = m
					m.Parent = workspace
				elseif not model.Parent then
					model.Parent = workspace
				end
				return nil
			end)
			if not ok then
				warn("[SkyRally][PLAZA_BANDS] failed: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
end

return PlazaBands
