-- Flight-corridor clearance audit (run in the Play SERVER after the track is built).
-- Sweeps the whole race spline and sphere-casts a plane-sized probe along the centre line at flight
-- height plus lateral/vertical offsets, recording every blocking instance (Terrain, parts, lethal lava).
-- Params injected by the caller: STEP, RADIUS, HEIGHT, OFFSETS.
local H = game:GetService('HttpService')
local Spline = require(game:GetService('ReplicatedStorage').Shared.SplineUtils)
local STEP, RADIUS, HEIGHT = __STEP__, __RADIUS__, __HEIGHT__
local OFFSETS = __OFFSETS__ -- list of {lateral, vertical}

local wps, length = Spline.loadWaypoints(true)
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
local excl = {}
for _, n in {'Planes', 'AIRacers', 'Bots'} do
	local f = workspace:FindFirstChild(n)
	if f then table.insert(excl, f) end
end
for _, p in game:GetService('Players'):GetPlayers() do
	if p.Character then table.insert(excl, p.Character) end
end
params.FilterDescendantsInstances = excl

local function isPassable(inst)
	-- Pass-through gameplay volumes the plane is meant to fly through.
	if not inst.CanCollide and inst:GetAttribute('HazardType') ~= 'LethalLava' and inst.Name ~= 'LavaSeaFloor' then
		return true
	end
	local n = inst.Name
	return n:match('^Ring') or n:match('Checkpoint') or n:match('^Pad') or n:match('Boost') or n:match('Trigger')
end

local function castFrom(origin, dir)
	local remaining, from = dir.Magnitude, origin
	local unit = dir.Unit
	for _ = 1, 6 do
		local hit = workspace:Spherecast(from, RADIUS, unit * remaining, params)
		if not hit then return nil end
		if not isPassable(hit.Instance) then return hit end
		local adv = (hit.Position - from):Dot(unit) + RADIUS + 0.5
		if adv >= remaining then return nil end
		from = from + unit * adv
		remaining -= adv
	end
	return nil
end

local blocks = {}
local widths = {}
local function clear(o, d)
	-- Distance to the first surface the plane could actually hit (non-collidable, non-lethal parts are flown through).
	local from, left = o, d.Magnitude
	for _ = 1, 12 do
		local h = workspace:Raycast(from, d.Unit * left, params)
		if not h then return -1 end
		if not isPassable(h.Instance) then return math.floor((h.Position - o).Magnitude) end
		local adv = (h.Position - from).Magnitude + 0.6
		from += d.Unit * adv
		left -= adv
		if left <= 0 then return -1 end
	end
	return -1
end
local summary = { samples = 0, blockedCentre = 0, blockedAny = 0 }
local s = 0
while s < length - STEP do
	local p0, _, bank0 = Spline.sampleAtStation(s)
	local p1 = Spline.sampleAtStation(s + STEP)
	local fwd = (p1 - p0)
	if fwd.Magnitude > 0.1 then
		local f = fwd.Unit
		local right = f:Cross(Vector3.yAxis)
		if right.Magnitude < 0.01 then right = Vector3.xAxis end
		right = right.Unit
		local up = right:Cross(f).Unit
		summary.samples += 1
		local anyHit = false
		for oi, o in OFFSETS do
			local off = right * o[1] + up * (HEIGHT + o[2])
			local hit = castFrom(p0 + off, (p1 + off) - (p0 + off))
			if hit then
				anyHit = true
				if oi == 1 then summary.blockedCentre += 1 end
				local inst = hit.Instance
				table.insert(blocks, {
					st = math.floor(s), o = oi, lat = o[1], vert = o[2],
					name = inst:GetFullName(), cls = inst.ClassName,
					mat = hit.Material.Name,
					lava = (inst:GetAttribute('HazardType') == 'LethalLava' or inst.Name == 'LavaSeaFloor' or hit.Material == Enum.Material.CrackedLava),
					x = math.floor(hit.Position.X), y = math.floor(hit.Position.Y), z = math.floor(hit.Position.Z),
					trackY = math.floor(p0.Y),
				})
			end
		end
		if anyHit then summary.blockedAny += 1 end
		local c = p0 + up * HEIGHT
		table.insert(widths, { st = math.floor(s), y = math.floor(p0.Y), L = clear(c, -right * 150), R = clear(c, right * 150), U = clear(c, up * 150), D = clear(c, -up * 60) })
	end
	s += STEP
end
summary.length = length
summary.waypoints = #wps
return H:JSONEncode({ summary = summary, blocks = blocks, widths = widths })
