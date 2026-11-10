--!strict
-- Route deck kit (MAP_PLAN_SCHEMA `skyrally.deck`): generates the bridge deck from the route waypoints, never stored
-- as parts in the plan. Style "dino_paver" is an exact port of builder_dino4.luau's deck loop (TrackSeg_i,
-- Paver_i_r_c, CurbL/CurbR_i_cb, BridgeFascia_i, CausewayPier_i/PierFooting_i). The per-segment Terrain cavern walls
-- of that loop are the shells op RouteCavern (MapAdapter), and its checkpoints come from TrackData (kit/Gameplay).
-- buildAlternate ports the builder's alternate-line geometry (Alt1 tunnel, Alt2 ledge), which the plan leaves to the
-- adapter.

local PaverRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("PaverRules"))

local Deck = {}

export type Waypoint = { pos: Vector3, bank: number, station: number }
export type Zone = { from: number, to: number, width: number?, paverRows: number?, curbHeights: { number }?, pierFootingY: number? }
export type Gap = { from: number, to: number }
export type Result = { segments: number, gapSegments: number, zoneSegments: number, piers: number, parts: number }

type Style = {
	-- "bridge" (default: deck on piers), "none" (no deck: open flight line, rings define the route). Road decks are
	-- bridges with piersEvery = 0 in the plan.
	kind: string?,
	paverCols: number,
	paverRows: number,
	paverGap: number?, -- mortar seam between columns in studs (default 0.30)
	paverStagger: number?, -- studs the interior column seam jogs on alternate segments/rows (default 0 = straight)
	-- Footing heights: the builder seats footings at y=16 on the caldera floor and y=108 inside its start zone.
	footingY: number,
	zoneFootingY: number,
	mortarBaseCol: Color3,
	paverWarmA: Color3,
	paverWarmB: Color3,
	paverWarmC: Color3,
	sandstoneWarm: Color3,
	terracottaCliff: Color3,
	terracottaDeep: Color3,
	basaltDark: Color3,
	basaltMid: Color3,
	upperSlatePurple: Color3,
	torchAmber: Color3,
	noTorchStrip: boolean?,
}

-- Palette from approved 04_dino4_controls.png and A16/A17 (copied from builder_dino4.luau).
local STYLES: { [string]: Style } = {
	dino_paver = {
		paverCols = 2,
		paverRows = 1,
		footingY = 16,
		zoneFootingY = 108,
		mortarBaseCol = Color3.fromRGB(48, 30, 24),
		paverWarmA = Color3.fromRGB(142, 96, 68),
		paverWarmB = Color3.fromRGB(124, 82, 56),
		paverWarmC = Color3.fromRGB(158, 108, 76),
		sandstoneWarm = Color3.fromRGB(206, 152, 102),
		terracottaCliff = Color3.fromRGB(178, 104, 66),
		terracottaDeep = Color3.fromRGB(142, 78, 52),
		basaltDark = Color3.fromRGB(48, 34, 32),
		basaltMid = Color3.fromRGB(68, 48, 44),
		upperSlatePurple = Color3.fromRGB(122, 76, 58),
		torchAmber = Color3.fromRGB(255, 168, 48),
	},
}
Deck.STYLES = STYLES

-- Per-zone styles live in kit/styles/<zone>.luau (each returns { [styleName] = partial Style }); missing fields fall
-- back to dino_paver so a zone only states its palette and differences.
do
	local folder = script.Parent:FindFirstChild("styles")
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("ModuleScript") then
				local ok, t = pcall(require, m)
				if ok and type(t) == "table" then
					for name, st in t :: { [string]: any } do
						STYLES[name] = setmetatable(st, { __index = STYLES.dino_paver }) :: any
					end
				else
					warn(string.format("[SkyRally][MAP] deck styles %s failed: %s", m.Name, tostring(t)))
				end
			end
		end
	end
end

local partCount: number = 0

local function addPart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	material: Enum.Material,
	color: Color3,
	parent: Instance,
	transparency: number?,
	canCollide: boolean?
): Part
	local p: Part = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Material = material
	p.Color = color
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = transparency or 0
	p.Reflectance = 0
	if canCollide ~= nil then
		p.CanCollide = canCollide
	else
		p.CanCollide = true
	end
	p.Parent = parent
	partCount += 1
	return p
end

-- Zones are half-open [from, to) on the segment's start station, like the builder's `station < 460`.
local function zoneAt(zones: { Zone }, station: number): Zone?
	for _, z in zones do
		if station >= z.from and station < z.to then
			return z
		end
	end
	return nil
end

-- Gaps are closed [from, to], like the builder's `station >= 1880 and station <= 2040`.
local function inGap(gaps: { Gap }, station: number): boolean
	for _, g in gaps do
		if station >= g.from and station <= g.to then
			return true
		end
	end
	return false
end

-- trackData.waypoints: closed route, last = first at station = length. trackData.deck: the plan block verbatim.
-- Piers go to pierFolder when given (the builder kept them under VolcanoCaldera), else to folder.
function Deck.build(trackData: any, folder: Instance, pierFolder: Instance?): Result
	local deck = trackData.deck or {}
	local style = STYLES[deck.style or "dino_paver"]
	if not style then
		warn(string.format("[SkyRally][MAP] deck style %s unknown; using dino_paver", tostring(deck.style)))
		style = STYLES.dino_paver
	end
	local waypoints: { Waypoint } = trackData.waypoints
	local trackWidth: number = deck.width or 32
	local zones: { Zone } = deck.zones or {}
	local gaps: { Gap } = deck.gaps or {}
	local baseCurbs: { number } = deck.curbHeights or { 5.2, 4.4 }
	local baseRows: number = deck.paverRows or style.paverRows
	local pierStep: number = deck.piersEvery or 5
	local baseFootingY: number = deck.pierFootingY or style.footingY
	local piersTo: Instance = pierFolder or folder

	local result: Result = { segments = 0, gapSegments = 0, zoneSegments = 0, piers = 0, parts = 0 }
	if style.kind == "none" then
		return result
	end
	local before = partCount

	for i = 1, #waypoints - 1 do
		local wp1 = waypoints[i]
		local wp2 = waypoints[i + 1]
		local p1: Vector3 = wp1.pos
		local p2: Vector3 = wp2.pos
		local segVec: Vector3 = p2 - p1
		local segLen: number = segVec.Magnitude
		if segLen <= 0.1 then
			continue
		end
		local mid: Vector3 = (p1 + p2) * 0.5
		local bankRad: number = math.rad(((wp1.bank or 0) + (wp2.bank or 0)) * 0.5)
		local cf: CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, bankRad)

		local zone = zoneAt(zones, wp1.station)
		local localWidth: number = if zone and zone.width then zone.width else trackWidth
		if zone then
			result.zoneSegments += 1
		end
		if inGap(gaps, wp1.station) then
			result.gapSegments += 1
			continue
		end
		result.segments += 1

		-- Deep mortar spandrel beam, overlapped +3.6 so curved segments leave no gaps.
		addPart("TrackSeg_" .. tostring(i), Vector3.new(localWidth, 7.6, segLen + 3.6), cf * CFrame.new(0, -2.2, 0), Enum.Material.Slate, style.mortarBaseCol, folder)

		-- Staggered stone pavers with mortar seams.
		local paverCols = style.paverCols
		local paverRows: number = if zone and zone.paverRows then zone.paverRows else baseRows
		local rowLen = ((segLen + 1.8) - (paverRows * 0.45)) / paverRows
		for r = 1, paverRows do
			local zOff = -segLen * 0.5 + (r - 0.5) * (segLen / paverRows)
			local cols = PaverRules.columns(localWidth, paverCols, style.paverGap, PaverRules.shiftFor(style.paverStagger, i, r))
			for c = 1, paverCols do
				local pCol = if (i + r + c) % 3 == 0 then style.paverWarmC elseif (i + r + c) % 2 == 0 then style.paverWarmA else style.paverWarmB
				addPart(
					string.format("Paver_%d_%d_%d", i, r, c),
					Vector3.new(cols[c].w, 1.4, math.max(2.0, rowLen)),
					cf * CFrame.new(cols[c].x, 2.0, zOff),
					Enum.Material.Sandstone,
					pCol,
					folder,
					0,
					false
				)
			end
		end

		-- Chiseled edge curbs, two per side, alternating heights and colours.
		local curbs: { number } = if zone and zone.curbHeights then zone.curbHeights else baseCurbs
		local curbCol = if i % 2 == 0 then style.basaltMid else style.terracottaDeep
		local curbSubLen = segLen * 0.54
		for cb = 1, 2 do
			local cbZ = if cb == 1 then -segLen * 0.25 else segLen * 0.25
			local cbH = if (i + cb) % 2 == 0 then curbs[1] else curbs[2]
			addPart(
				string.format("CurbL_%d_%d", i, cb),
				Vector3.new(3.6, cbH, curbSubLen),
				cf * CFrame.new(-(localWidth * 0.5 + 1.4), 0.8, cbZ),
				Enum.Material.Sandstone,
				if (i + cb) % 2 == 0 then curbCol else style.sandstoneWarm,
				folder
			)
			addPart(
				string.format("CurbR_%d_%d", i, cb),
				Vector3.new(3.6, cbH, curbSubLen),
				cf * CFrame.new(localWidth * 0.5 + 1.4, 0.8, cbZ),
				Enum.Material.Sandstone,
				if (i + cb) % 2 == 1 then curbCol else style.sandstoneWarm,
				folder
			)
		end

		-- Under-deck corbelled trim.
		addPart(
			"BridgeFascia_" .. tostring(i),
			Vector3.new(localWidth + 4.4, 3.4, segLen + 3.4),
			cf * CFrame.new(0, -4.6, 0),
			Enum.Material.Sandstone,
			style.terracottaCliff,
			folder,
			0,
			false
		)

		-- Stepped viaduct pier and footing every Nth segment; yaw only, so piers stay plumb on banked segments.
		if pierStep > 0 and i % pierStep == 0 then
			local pierH = math.max(16, mid.Y - 8)
			local yaw = CFrame.Angles(0, math.atan2(-segVec.X, -segVec.Z), 0)
			local footingY: number = if zone then (zone.pierFootingY or style.zoneFootingY) else baseFootingY
			addPart(
				"CausewayPier_" .. tostring(i),
				Vector3.new(localWidth * 0.42, pierH, 11),
				CFrame.new(mid.X, mid.Y - pierH * 0.5 - 4.5, mid.Z) * yaw,
				Enum.Material.Sandstone,
				style.terracottaCliff,
				piersTo,
				0,
				false
			)
			addPart(
				"PierFooting_" .. tostring(i),
				Vector3.new(localWidth * 0.58, 8, 16),
				CFrame.new(mid.X, footingY, mid.Z) * yaw,
				Enum.Material.Basalt,
				style.basaltDark,
				piersTo,
				0,
				false
			)
			result.piers += 1
		end
	end

	result.parts = partCount - before
	return result
end

-- Alternate line geometry per segment of alt.points. Names start with the alt id ("Alt1Floor_1"): FlightController
-- treats ^Alt parts as track surface and CourseCarve lets them sit in the corridor.
function Deck.buildAlternate(alt: any, folder: Instance, styleId: string?): number
	local style = STYLES[styleId or "dino_paver"] or STYLES.dino_paver
	local id = tostring(alt.id)
	local pts: { Vector3 } = alt.points or {}
	if #pts < 2 then
		error(string.format("alternate %s needs at least 2 points, has %d", id, #pts))
	end
	if alt.style == "cliff" then
		-- A cliff line (ISLAND-2 Alt2) is the existing rock face: nothing is built and nothing is carved for it.
		return 0
	end
	local before = partCount
	for i = 1, #pts - 1 do
		local a: Vector3 = pts[i]
		local b: Vector3 = pts[i + 1]
		local len: number = (b - a).Magnitude
		local cf: CFrame = CFrame.lookAt((a + b) * 0.5, b)
		if alt.style == "tunnel" then
			addPart(id .. "Floor_" .. tostring(i), Vector3.new(28, 3.6, len + 2), cf, Enum.Material.Sandstone, style.paverWarmA, folder)
			addPart(id .. "WallL_" .. tostring(i), Vector3.new(6, 32, len + 2), cf * CFrame.new(-16, 15, 0), Enum.Material.Sandstone, style.terracottaCliff, folder)
			addPart(id .. "WallR_" .. tostring(i), Vector3.new(6, 32, len + 2), cf * CFrame.new(16, 15, 0), Enum.Material.Sandstone, style.terracottaCliff, folder)
			addPart(id .. "Roof_" .. tostring(i), Vector3.new(38, 6, len + 2), cf * CFrame.new(0, 31, 0), Enum.Material.Slate, style.upperSlatePurple, folder)
			if not style.noTorchStrip then -- v29 D6: SNOW-1 swaps the Neon strip for plan lanterns on timber ribs
				addPart(id .. "TorchStrip_" .. tostring(i), Vector3.new(1.8, 0.8, len * 0.82), cf * CFrame.new(0, 27.5, 0), Enum.Material.Neon, style.torchAmber, folder, 0.25, false)
			end
		elseif alt.style == "ledge" then
			addPart(id .. "Ledge_" .. tostring(i), Vector3.new(26, 4.0, len), cf, Enum.Material.Sandstone, style.sandstoneWarm, folder)
		elseif alt.style == "span" then
			-- plan-owned geometry (SPACE-4 rooftop line: slabs, walls and blocks are plan parts): a course line only
		else
			error(string.format("alternate %s has unknown style %s", id, tostring(alt.style)))
		end
	end
	return partCount - before
end

return Deck
