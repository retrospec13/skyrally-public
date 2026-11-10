--!strict
-- Flight-path guide (docs/design/FLIGHT_GUIDE.md 4.7, 8): soft particles / thin beams drawn only AHEAD of the local plane
-- along the line it is on (the main route, or the alternate tunnel / ledge / key gallery it picked), NEAR..FAR studs
-- out, faded near the camera and at both ends of the window. Every style is data in shared/FlightGuideRules.PRESETS; this
-- module only knows five element kinds (emit, chain, ring, gate, chevron). Particles and beams only, never meshes.
--
-- Cost: one pool per (preset, tier, tint), built once; nodes sit on a station grid (they do not swim with the plane) and
-- slot (grid index % pool size) is recycled to the far end as a node falls behind, so a chain's beam k always joins
-- slot k to slot k + 1 and is never rewired. Placement runs at FlightGuideRules.HZ; a slot is only written when its node
-- moved or its fade level changed (NumberSequences are cached per level). Two flight modes (FLIGHT_GUIDE.md 12): the
-- default Mario Kart mode draws nothing; Free driving draws the bead mist at FlightGuideRules.FREE_ALPHA of its
-- visibility, the only path hint. FlightController calls step() from its leash block in Free driving and hide() otherwise.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FlightGuideRules = require(Shared:WaitForChild("FlightGuideRules"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local RouteBranch = require(Shared:WaitForChild("RouteBranch"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local FlightGuide = {}

type Layer = FlightGuideRules.Layer
-- One layer's Instances for one slot: attachments, emitters, beams (by kind).
type SlotParts = { att: { Attachment }, emit: { ParticleEmitter }, beams: { Beam } }
type LayerPool = { layer: Layer, slots: { SlotParts }, floor: number }
type Pool = {
	key: string,
	preset: FlightGuideRules.Preset,
	plan: FlightGuideRules.Plan,
	layers: { LayerPool },
	slotG: { number? }, -- grid index each slot shows (nil = empty)
	slotLv: { number }, -- fade level last written per slot
	lineKey: string, -- the line the grid belongs to ("main" or an alternate id)
}

local folder: Folder? = nil
local anchor: BasePart? = nil
local pool: Pool? = nil
local shown = false
local clock = 0
local stations: { number } = {}
local wantLv: { number } = {} -- per slot this tick (reused: no table churn at the guide rate)
local wantG: { [number]: number } = {}
local seqCache: { [string]: NumberSequence } = {}

local LIFT = Vector3.new(0, RouteBranch.PLANE_LIFT, 0)

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function texOf(key: string?): string
	local entry = if key then (VfxAssets :: any)[key] else nil
	return if entry then entry.id else (VfxAssets :: any).glow_soft.id
end

-- Attachments need a BasePart parent: one invisible anchored part at the origin, so an attachment's CFrame is its world
-- frame. Client-local (never replicated), no collision, no queries, no touches.
local function ensureAnchor(): BasePart
	local a = anchor
	if a and a.Parent then
		return a
	end
	local f = Instance.new("Folder")
	f.Name = "SkyRallyFlightGuide"
	f.Parent = workspace
	folder = f
	local p = Instance.new("Part")
	p.Name = "GuideAnchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.identity
	p.Parent = f
	anchor = p
	return p
end

-- Particle transparency over a particle's life for a fade level (cached).
local function particleSeq(floor: number, lv: number): NumberSequence
	local key = string.format("p%.3f:%d", floor, lv)
	local s = seqCache[key]
	if not s then
		local t = FlightGuideRules.transparencyAt(lv / FlightGuideRules.LEVELS, floor)
		s = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, t),
			NumberSequenceKeypoint.new(0.75, t),
			NumberSequenceKeypoint.new(1, 1),
		})
		seqCache[key] = s
	end
	return s
end

-- Beam transparency from one end's level to the other's (cached).
local function beamSeq(floor: number, lv0: number, lv1: number): NumberSequence
	local key = string.format("b%.3f:%d:%d", floor, lv0, lv1)
	local s = seqCache[key]
	if not s then
		local L = FlightGuideRules.LEVELS
		s = NumberSequence.new(FlightGuideRules.transparencyAt(lv0 / L, floor), FlightGuideRules.transparencyAt(lv1 / L, floor))
		seqCache[key] = s
	end
	return s
end

local function newAttachment(parent: BasePart): Attachment
	local a = Instance.new("Attachment")
	a.Name = "GuideNode"
	a.Parent = parent
	return a
end

local function newBeam(parent: BasePart, a0: Attachment, a1: Attachment, l: Layer, color: ColorSequence): Beam
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Texture = texOf(l.tex or "trail_soft")
	b.TextureMode = Enum.TextureMode.Stretch
	b.Width0 = l.width or 0.4
	b.Width1 = l.width or 0.4
	b.FaceCamera = true
	b.Segments = if l.kind == "ring" then 10 else 4
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Color = color
	b.Transparency = NumberSequence.new(1)
	b.Enabled = false
	b.Parent = parent
	return b
end

local function newEmitter(att: Attachment, l: Layer, rateMul: number, color: ColorSequence): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = texOf(l.tex)
	e.Rate = l.rate * rateMul
	e.Lifetime = NumberRange.new(l.life * 0.85, l.life * 1.15)
	local size = l.size or 2
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size * 0.4),
		NumberSequenceKeypoint.new(0.3, size),
		NumberSequenceKeypoint.new(1, size * 0.7),
	})
	local speed = l.speed or 0
	e.Speed = NumberRange.new(speed * 0.5, speed)
	local spread = l.spread or 0
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Drag = l.drag or 0
	e.LightEmission = 1
	e.LightInfluence = 0
	e.LockedToPart = l.locked == true
	e.Color = color
	e.Transparency = NumberSequence.new(1)
	e.Enabled = false
	e.Parent = att
	return e
end

-- Builds one layer's Instances for `n` slots.
local function buildLayer(l: Layer, n: number, rateMul: number, tint: { core: { number }, edge: { number } }): LayerPool
	local parent = ensureAnchor()
	local color = ColorSequence.new(rgb(tint.core), rgb(tint.edge))
	local beamColor = ColorSequence.new(rgb(tint.edge))
	local slots: { SlotParts } = {}
	for k = 1, n do
		slots[k] = { att = {}, emit = {}, beams = {} }
	end
	if l.kind == "emit" then
		local per = if l.spiral then 1 else #(l.offsets :: { any })
		for k = 1, n do
			for i = 1, per do
				local a = newAttachment(parent)
				slots[k].att[i] = a
				slots[k].emit[i] = newEmitter(a, l, rateMul, color)
			end
		end
	elseif l.kind == "chain" then
		for k = 1, n do
			slots[k].att[1] = newAttachment(parent)
		end
		-- Beam k joins slot k to the next slot on the grid (static: consecutive grid indices are consecutive slots).
		for k = 1, n do
			slots[k].beams[1] = newBeam(parent, slots[k].att[1], slots[k % n + 1].att[1], l, beamColor)
		end
	else
		local nAtt = if l.kind == "ring" then 2 elseif l.kind == "gate" then 4 else 3
		for k = 1, n do
			local s = slots[k]
			for i = 1, nAtt do
				s.att[i] = newAttachment(parent)
			end
			if l.kind == "ring" then
				local kk = (l.radius or FlightGuideRules.R_OUT) * 4 / 3 -- a cubic Bezier semicircle: control points 4/3 r out
				local up = newBeam(parent, s.att[1], s.att[2], l, beamColor)
				up.CurveSize0, up.CurveSize1 = kk, -kk
				local down = newBeam(parent, s.att[1], s.att[2], l, beamColor)
				down.CurveSize0, down.CurveSize1 = -kk, kk
				s.beams = { up, down }
			elseif l.kind == "gate" then
				s.beams = {
					newBeam(parent, s.att[1], s.att[2], l, beamColor),
					newBeam(parent, s.att[2], s.att[3], l, beamColor),
					newBeam(parent, s.att[3], s.att[4], l, beamColor),
				}
			else -- chevron: left and right arms meeting at the tip (att 1)
				s.beams = { newBeam(parent, s.att[2], s.att[1], l, beamColor), newBeam(parent, s.att[3], s.att[1], l, beamColor) }
			end
		end
	end
	return { layer = l, slots = slots, floor = FlightGuideRules.layerFloor(l) }
end

local function destroyLayer(lp: LayerPool?)
	if not lp then
		return
	end
	for _, s in lp.slots do
		for _, b in s.beams do
			b:Destroy()
		end
		for _, a in s.att do
			a:Destroy() -- takes its emitter with it
		end
	end
end

local function destroyPool()
	local p = pool
	if p then
		for _, lp in p.layers do
			destroyLayer(lp)
		end
	end
	pool = nil
end

-- A node's frame axes from the line's tangent: look along it, right level, up from both.
local function axes(tangent: Vector3): (Vector3, Vector3, Vector3)
	local look = if tangent.Magnitude > 1e-3 then tangent.Unit else Vector3.new(0, 0, -1)
	local r = look:Cross(Vector3.yAxis)
	local right = if r.Magnitude > 1e-3 then r.Unit else Vector3.xAxis
	local up = right:Cross(look).Unit
	return look, right, up
end

-- Places one slot's elements of a layer at point p with the frame (look, right, up); g = grid index (spiral phase).
local function placeSlot(lp: LayerPool, s: SlotParts, g: number, p: Vector3, look: Vector3, right: Vector3, up: Vector3)
	local l = lp.layer
	if l.kind == "emit" then
		if l.spiral then
			local ang = math.rad(g * l.spiral)
			local r = l.radius or FlightGuideRules.R_OUT
			s.att[1].CFrame = CFrame.fromMatrix(p + right * (math.cos(ang) * r) + up * (math.sin(ang) * r), right, up)
		else
			for i, off in l.offsets :: { { number } } do
				s.att[i].CFrame = CFrame.fromMatrix(p + right * off[1] + up * off[2], right, up)
			end
		end
	elseif l.kind == "chain" then
		local off = l.offset :: { number }
		s.att[1].CFrame = CFrame.new(p + right * off[1] + up * off[2])
	elseif l.kind == "ring" then
		-- The arc beams bulge along each attachment's Axis (its X): point X up, so one arc goes over and one under.
		local r = l.radius or FlightGuideRules.R_OUT
		s.att[1].CFrame = CFrame.fromMatrix(p - right * r, up, look)
		s.att[2].CFrame = CFrame.fromMatrix(p + right * r, up, look)
	elseif l.kind == "gate" then
		local hw, hh = l.halfW or 24, l.halfH or 11
		s.att[1].CFrame = CFrame.new(p - right * hw - up * hh)
		s.att[2].CFrame = CFrame.new(p - right * hw + up * hh)
		s.att[3].CFrame = CFrame.new(p + right * hw + up * hh)
		s.att[4].CFrame = CFrame.new(p + right * hw - up * hh)
	else -- chevron
		local off = l.offset :: { number }
		local c = p + right * off[1] + up * off[2]
		local hw, d = l.halfW or 3, (l.depth or 2.6) / 2
		s.att[1].CFrame = CFrame.new(c + look * d)
		s.att[2].CFrame = CFrame.new(c - look * d - right * hw)
		s.att[3].CFrame = CFrame.new(c - look * d + right * hw)
	end
end

-- Shows a slot at a fade level (0 = hidden). nextLv: the next node's level (chains fade along the segment; -1 = no
-- next node, the segment is hidden).
local function showSlot(lp: LayerPool, s: SlotParts, lv: number, nextLv: number)
	local on = lv > 0
	if lp.layer.kind == "emit" then
		local seq = particleSeq(lp.floor, lv)
		for _, e in s.emit do
			e.Enabled = on
			if on then
				e.Transparency = seq
			end
		end
	elseif lp.layer.kind == "chain" then
		local b = s.beams[1]
		local segOn = on and nextLv > 0
		b.Enabled = segOn
		if segOn then
			b.Transparency = beamSeq(lp.floor, lv, nextLv)
		end
	else
		local seq = beamSeq(lp.floor, lv, lv)
		for _, b in s.beams do
			b.Enabled = on
			if on then
				b.Transparency = seq
			end
		end
	end
end

local function hideLayer(lp: LayerPool)
	for _, s in lp.slots do
		for _, e in s.emit do
			e.Enabled = false
		end
		for _, b in s.beams do
			b.Enabled = false
		end
	end
end

local function currentTier(): FlightGuideRules.Tier
	return FlightGuideRules.tierOf(Settings.lowGraphics(), Settings.phoneTier())
end

local function overrideId(): any
	local o = LocalPlayer:GetAttribute("GuidePreset")
	if o == nil then
		o = workspace:GetAttribute("GuidePreset")
	end
	return o
end

-- The pool for the current preset / tier / map tint, rebuilt only when one of them changes.
local function ensurePool(): Pool?
	local tier = currentTier()
	local preset = FlightGuideRules.presetFor(overrideId(), tier)
	if not preset then
		destroyPool()
		return nil
	end
	local trackId = TrackRegistry.getActiveId()
	local key = preset.id .. "|" .. tier .. "|" .. tostring(trackId)
	local p = pool
	if p and p.key == key then
		return p
	end
	destroyPool()
	local plan = FlightGuideRules.plan(preset, tier)
	local tint = FlightGuideRules.tintFor(trackId)
	local layers: { LayerPool } = {}
	for _, l in FlightGuideRules.layersFor(preset, tier) do
		table.insert(layers, buildLayer(l, plan.nodes, plan.rateMul, tint))
	end
	local slotLv = table.create(plan.nodes, 0)
	local np: Pool = { key = key, preset = preset, plan = plan, layers = layers, slotG = {}, slotLv = slotLv, lineKey = "" }
	pool = np
	LocalPlayer:SetAttribute("GuideStyle", preset.id)
	print(string.format("[SkyRally][GUIDE] preset=%s tier=%s nodes=%d particles=%.0f instances=%d", preset.id, tier, plan.nodes, plan.particles, plan.instances))
	return np
end

-- The point and tangent `s` studs along the line the plane is on (main: s is a station; an alternate: s is along it,
-- continuing on the main route from its rejoin past its end). nil when the line ends with nowhere to continue.
local function lineFrame(s: number, line: RouteBranch.Line?): (Vector3?, Vector3)
	if line then
		if s <= line.length then
			local p = RouteBranch.pointAt(line, s)
			local q = RouteBranch.pointAt(line, math.min(line.length, s + 6))
			local back = RouteBranch.pointAt(line, math.max(0, s - 6))
			return p, q - back
		end
		local rejoin = line.rejoin
		if not rejoin then
			return nil, Vector3.zero
		end
		s = rejoin + (s - line.length)
	end
	local pos, tangent = SplineUtils.sampleAtStation(s)
	return pos + LIFT, tangent
end

-- Every frame from FlightController while Free driving in a race. station / line / along: the plane's place on the
-- course (FlightController.sampleCourse). The nodes are world-anchored, so all the work runs at the guide rate.
function FlightGuide.step(dt: number, planePos: Vector3, station: number, line: RouteBranch.Line?, along: number)
	clock += dt
	local due = not shown or clock >= 1 / (FlightGuideRules.HZ[currentTier()] or 10)
	if not due then
		return
	end
	clock = 0
	shown = true
	local vis = FlightGuideRules.FREE_ALPHA
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else planePos
	local p = ensurePool()
	if p then
		local lineKey = if line then line.id else "main"
		if lineKey ~= p.lineKey then
			p.lineKey = lineKey
			table.clear(p.slotG) -- a new grid: every slot is placed again
		end
		local at = if line then along else station
		local n = p.plan.nodes
		local _, count = FlightGuideRules.nodeStations(at, p.preset.spacing, FlightGuideRules.NEAR, FlightGuideRules.FAR, n, stations)
		local firstG = if count > 0 then math.floor(stations[1] / p.preset.spacing + 0.5) else 0
		-- Fade level per slot this tick (0 = not drawn).
		table.clear(wantG)
		for slot = 1, n do
			wantLv[slot] = 0
		end
		for i = 1, count do
			local s = stations[i]
			local g = firstG + i - 1
			local slot = g % n + 1
			local pt, tan = lineFrame(s, line)
			if pt then
				local look, right, up = axes(tan)
				if p.slotG[slot] ~= g then
					p.slotG[slot] = g
					for _, lp in p.layers do
						placeSlot(lp, lp.slots[slot], g, pt, look, right, up)
					end
				end
				wantG[slot] = g
				wantLv[slot] = FlightGuideRules.level(vis * FlightGuideRules.alphaAt(s - at, (pt - camPos).Magnitude))
			end
		end
		for slot = 1, n do
			local lv = if wantG[slot] ~= nil then wantLv[slot] else 0
			local nextSlot = slot % n + 1
			local g = wantG[slot]
			local nextLv = if g ~= nil and wantG[nextSlot] == g + 1 then wantLv[nextSlot] else 0
			-- Write only on a change (level, or the next node's level for chains).
			local stamp = lv * 100 + nextLv
			if p.slotLv[slot] ~= stamp then
				p.slotLv[slot] = stamp
				for _, lp in p.layers do
					showSlot(lp, lp.slots[slot], lv, nextLv)
				end
			end
		end
	end
end

-- The default mode, or not racing (hub, battle, grid, curtain, finished, a car): nothing drawn. The pool is kept.
function FlightGuide.hide()
	if not shown then
		return
	end
	shown = false
	clock = 0
	local p = pool
	if p then
		for _, lp in p.layers do
			hideLayer(lp)
		end
		table.clear(p.slotG)
		for i = 1, #p.slotLv do
			p.slotLv[i] = 0
		end
	end
end

-- The preset on screen (QA / the pick board).
function FlightGuide.presetId(): string?
	local p = pool
	return if p then p.preset.id else nil
end

return FlightGuide
