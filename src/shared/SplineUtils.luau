--!strict
local TrackRegistry = require(script.Parent:WaitForChild("TrackRegistry"))
-- Economy v3 phase 2b: per group several splines are live at once (one per instance's track); the cache is then kept
-- per track id. Inert while RaceFlowRules.PER_GROUP is false.
local RaceFlowRules = require(script.Parent:WaitForChild("RaceFlowRules"))

local SplineUtils = {}

export type Waypoint = {
	pos: Vector3,
	bank: number,
	station: number,
	tangent: Vector3,
}

-- 5450 is the legacy DINO-4 length, used only while no registered track supplies one.
local function defaultLength(): number
	return TrackRegistry.length() or 5450
end

local cachedWaypoints: { Waypoint }? = nil
local cachedTrackLength: number = 5450

-- A track switch must not keep serving the previous track's spline.
workspace:GetAttributeChangedSignal("ActiveTrackId"):Connect(function()
	cachedWaypoints = nil
	cachedTrackLength = defaultLength()
end)

-- Per group: the spline of each track id, loaded once (forceReload drops that track's copy only).
local perTrack: { [string]: { wps: { Waypoint }, len: number } } = {}

local loadSingle: (forceReload: boolean?) -> ({ Waypoint }, number)

function SplineUtils.loadWaypoints(forceReload: boolean?): ({ Waypoint }, number)
	if not RaceFlowRules.PER_GROUP then
		return loadSingle(forceReload)
	end
	local id = TrackRegistry.getActiveId()
	local hit = perTrack[id]
	if hit and not forceReload then
		return hit.wps, hit.len
	end
	-- The single-track loader does the work against this track (getActiveId is the scoped id); its cache is reset
	-- around the call so another track's spline never answers.
	cachedWaypoints = nil
	cachedTrackLength = defaultLength()
	local wps, len = loadSingle(true)
	cachedWaypoints = nil
	local gTracks = (_G :: any).SkyRallyTracks
	local fromG = type(gTracks) == "table" and gTracks[id] ~= nil and #wps > 2
	if #wps >= 100 or fromG then
		perTrack[id] = { wps = wps, len = len }
	end
	return wps, len
end

loadSingle = function(forceReload: boolean?): ({ Waypoint }, number)
	if cachedWaypoints and not forceReload then
		return cachedWaypoints, cachedTrackLength
	end

	-- Server only: _G is not shared with clients, which read WaypointsData below.
	local activeId = TrackRegistry.getActiveId()
	local gTracks = (_G :: any).SkyRallyTracks
	if type(gTracks) == "table" and gTracks[activeId] then
		local td = gTracks[activeId]
		if type(td.waypoints) == "table" and #td.waypoints > 2 then
			cachedWaypoints = td.waypoints
			cachedTrackLength = td.measuredLength or td.length or defaultLength()
			return cachedWaypoints :: { Waypoint }, cachedTrackLength
		end
	end

	local wpFolder = TrackRegistry.getWaypointsFolder()
	if not wpFolder then
		return {}, defaultLength()
	end

	local totalLenAttr = wpFolder:GetAttribute("TrackLength")
	if type(totalLenAttr) == "number" and totalLenAttr > 0 then
		cachedTrackLength = totalLenAttr
	end

	local children = wpFolder:GetChildren()
	table.sort(children, function(a: Instance, b: Instance): boolean
		local ia = (a:GetAttribute("Index") :: number?) or 0
		local ib = (b:GetAttribute("Index") :: number?) or 0
		return ia < ib
	end)

	local list: { Waypoint } = {}
	for _, child in ipairs(children) do
		if child:IsA("Vector3Value") then
			local pos = child.Value
			local bank = (child:GetAttribute("Bank") :: number?) or 0
			local station = (child:GetAttribute("Station") :: number?) or 0
			local tangent = (child:GetAttribute("Tangent") :: Vector3?) or Vector3.new(0, 0, -1)
			table.insert(list, {
				pos = pos,
				bank = bank,
				station = station,
				tangent = tangent,
			})
		end
	end

	if #list >= 100 then
		cachedWaypoints = list
	end
	return list, cachedTrackLength
end

function SplineUtils.sampleAtStation(station: number): (Vector3, Vector3, number)
	local wps, totalLen = SplineUtils.loadWaypoints()
	if #wps == 0 then
		return Vector3.new(0, 146, 0), Vector3.new(0, 0, -1), 0
	end

	local s = station % totalLen
	if s < 0 then
		s = s + totalLen
	end

	local low = 1
	local high = #wps
	while low < high - 1 do
		local mid = math.floor((low + high) * 0.5)
		if wps[mid].station <= s then
			low = mid
		else
			high = mid
		end
	end

	local w1 = wps[low]
	local w2 = wps[high]
	local span = math.max(0.01, w2.station - w1.station)
	local alpha = math.clamp((s - w1.station) / span, 0, 1)

	local pos = w1.pos:Lerp(w2.pos, alpha)
	local bank = w1.bank + (w2.bank - w1.bank) * alpha
	local rawTan = w2.pos - w1.pos
	local tangent = if rawTan.Magnitude > 0.05 then rawTan.Unit else w1.tangent
	return pos, tangent, bank
end

function SplineUtils.projectPosition(worldPos: Vector3, hintStation: number?): (number, Vector3, Vector3, number)
	local wps, totalLen = SplineUtils.loadWaypoints()
	if #wps < 2 then
		return 0, Vector3.new(0, 140, 0), Vector3.new(0, 0, -1), 0
	end

	local bestDistSq = math.huge
	local bestStation = 0
	local bestPoint = wps[1].pos
	local bestTangent = Vector3.new(0, 0, -1)

	local segCount = #wps - 1
	for i = 1, segCount do
		local w1 = wps[i]
		local w2 = wps[i + 1]
		local seg = w2.pos - w1.pos
		local segLenSq = seg:Dot(seg)
		local t = 0
		if segLenSq > 0.001 then
			t = math.clamp((worldPos - w1.pos):Dot(seg) / segLenSq, 0, 1)
		end
		local proj = w1.pos + seg * t
		local dSq = (worldPos - proj):Dot(worldPos - proj)
		local segStation = w1.station + (w2.station - w1.station) * t

		-- Continuity bias around hintStation so nearby loop branches don't jump
		local score = dSq
		if hintStation ~= nil then
			local ds = math.abs(segStation - hintStation)
			ds = math.min(ds, math.abs(totalLen - ds))
			if ds > 900 then
				score = score + (ds - 900) * 12
			end
		end

		if score < bestDistSq then
			bestDistSq = score
			bestStation = segStation
			bestPoint = proj
			bestTangent = if seg.Magnitude > 0.01 then seg.Unit else w1.tangent
		end
	end

	local realDist = (worldPos - bestPoint).Magnitude
	return bestStation, bestPoint, bestTangent, realDist
end

return SplineUtils
