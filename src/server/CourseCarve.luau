--!strict
-- Guaranteed flight corridor (TEST_LIST_LAUNCH L02 gate; reused by the L1 map adapter for every map).
-- Runs AFTER every Terrain fill: carves an Air box along each route segment so no Terrain mass can sit in
-- the lane, then scans the same boxes for collidable parts and lethal hazards and reports them by station.
-- Parts are reported, not deleted: an intruding part is a builder defect to fix at its source.

local CourseCarve = {}

export type Waypoint = { pos: Vector3, station: number? }
export type Options = {
	halfWidth: number?, -- lateral half-width of the flyable lane (studs)
	floor: number?, -- corridor bottom above the ribbon (studs); keeps the deck and its supports intact
	ceiling: number?, -- corridor top above the ribbon (studs)
	exclude: { Instance }?, -- instances never reported (planes, racers)
	label: string?,
	scan: boolean?, -- false: carve only, no intrusion scan (the deck bed sits inside the deck's own parts)
}
export type Intrusion = { station: number, name: string, lethal: boolean }

-- Gameplay volumes and the deck itself are meant to be inside or under the lane.
local PASS_PATTERNS = { "^TrackSeg_", "^Curb", "^Paver_", "^BridgeFascia_", "^Alt", "^TunnelRamp", "Ring", "Checkpoint", "Pad", "Boost", "Trigger", "Waypoint" }

local function isPassable(p: BasePart): boolean
	local lethal = p:GetAttribute("HazardType") == "LethalLava" or p.Name == "LavaSeaFloor"
	if lethal then
		return false
	end
	if not p.CanCollide then
		return true
	end
	for _, pat in PASS_PATTERNS do
		if string.find(p.Name, pat) then
			return true
		end
	end
	return false
end

local function segmentBox(a: Vector3, b: Vector3, halfWidth: number, floor: number, ceiling: number): (CFrame?, Vector3?)
	local f = b - a
	if f.Magnitude < 0.5 then
		return nil, nil
	end
	local h = ceiling - floor
	local mid = (a + b) * 0.5 + Vector3.yAxis * (floor + h * 0.5)
	local dir = f.Unit
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	-- Length overlaps the neighbours by one half-width so curved routes leave no uncarved wedges.
	return CFrame.lookAt(mid, mid + dir, up), Vector3.new(halfWidth * 2, h, f.Magnitude + halfWidth)
end

function CourseCarve.carve(waypoints: { Waypoint }, opts: Options?): { carved: number, intrusions: { Intrusion } }
	local o: Options = opts or {}
	local halfWidth = o.halfWidth or 24
	local floor = o.floor or 5
	local ceiling = o.ceiling or 42
	local terrain = workspace.Terrain
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = o.exclude or {}

	local carved = 0
	local seen: { [Instance]: boolean } = {}
	local intrusions: { Intrusion } = {}
	for i = 1, #waypoints - 1 do
		local a, b = waypoints[i].pos, waypoints[i + 1].pos
		local cf, size = segmentBox(a, b, halfWidth, floor, ceiling)
		if cf and size then
			terrain:FillBlock(cf, size, Enum.Material.Air)
			carved += 1
			for _, part in (if o.scan == false then {} else workspace:GetPartBoundsInBox(cf, size, overlap)) do
				if not seen[part] and part ~= terrain and not isPassable(part) then
					seen[part] = true
					local lethal = part:GetAttribute("HazardType") == "LethalLava" or part.Name == "LavaSeaFloor"
					table.insert(intrusions, { station = math.floor(waypoints[i].station or i), name = part:GetFullName(), lethal = lethal })
				end
			end
		end
	end
	local label = o.label or "course"
	print(string.format("[SkyRally][CORRIDOR] %s carved=%d halfWidth=%d floor=%d ceiling=%d intrusions=%d", label, carved, halfWidth, floor, ceiling, #intrusions))
	for _, it in intrusions do
		print(string.format("[SkyRally][CORRIDOR] INTRUSION st=%d lethal=%s %s", it.station, tostring(it.lethal), it.name))
	end
	return { carved = carved, intrusions = intrusions }
end

return CourseCarve
