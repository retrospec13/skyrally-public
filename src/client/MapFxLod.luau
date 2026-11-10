--!strict
-- Map effect LOD for low-end devices (docs/audits/perf_review_v21.md PF-02 and PF-05). Rules: shared/GraphicsLodRules.
-- * The map's baked effects (MapAdapter step "fx" tags each one with the MapFx attribute: 33-84 ParticleEmitters per
--   map, 52 Fire on ISLAND-2, Beams on DINO-4/SPACE-4/ISLAND-2) used to run at their full plan rate everywhere, on
--   every device. Now, at 2 Hz: an emitter's Rate is its plan rate x Settings.particleScale() (1 desktop, 0.6 phone
--   tier, 0.4 LOW GRAPHICS or the frame governor) and 0 beyond the distance where its biggest particle would be under
--   2 screen points tall (measured to the emitter's box, minus how far its particles travel). Fire and Beams use the
--   same range and are off under LOW GRAPHICS. Only Rate is written for emitters, so the modules that switch map
--   emitters on and off (PortalWake, TrackFlow, DuckMoments) keep owning Enabled; Fire and Beam Enabled is only ever
--   switched off by this module when it was on, and restored by it.
-- * Post-processing: the lighting profile's SunRays (intensity 0.06-0.12) is off on phone tier and under LOW GRAPHICS,
--   its Bloom off under LOW GRAPHICS. The shared profiles are not edited; each new SkyRally_* effect is checked as the
--   server parents it.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsLodRules"))
local Settings = require(script.Parent:WaitForChild("Settings"))
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))

local MapFxLod = {}

type Entry = {
	inst: Instance,
	kind: "pe" | "fire" | "beam",
	base: number, -- emitter: the plan's Rate
	startedOn: boolean, -- fire / beam: Enabled as built
	size: number, -- biggest particle, flame or beam width (studs)
	travel: number, -- how far a particle can drift from the box (Speed max x Lifetime max)
	inv: CFrame?, -- box frame inverse (emitter, fire)
	half: Vector3?, -- box half size
	a: Vector3?, -- beam ends
	b: Vector3?,
	last: number?, -- last Rate written, or 1/0 for Enabled
}

local entries: { Entry } = {}
local known: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- What the server built (plan Rate, Enabled), kept across rescans: a rescan of the same map must never read back a
-- value this module wrote (a culled emitter's Rate 0, a Fire it switched off).
local built: { [Instance]: { rate: number, on: boolean } } = setmetatable({}, { __mode = "k" }) :: any
local scanToken = 0
local dirty = true

local function seqMax(seq: NumberSequence): number
	local keys: { { number } } = {}
	for _, k in seq.Keypoints do
		table.insert(keys, { k.Value, k.Envelope })
	end
	return Rules.maxKeypoint(keys)
end

local function collect(inst: Instance)
	if known[inst] or inst:GetAttribute(Rules.FX_ATTR) ~= true then
		return
	end
	local holder = inst.Parent
	local b = built[inst]
	if not b then
		b = { rate = if inst:IsA("ParticleEmitter") then inst.Rate else 0, on = (inst :: any).Enabled == true }
		built[inst] = b
	end
	local orig = b :: { rate: number, on: boolean }
	if inst:IsA("ParticleEmitter") and holder and holder:IsA("BasePart") then
		known[inst] = true
		table.insert(entries, {
			inst = inst :: Instance, kind = "pe", base = orig.rate, startedOn = orig.on, size = seqMax(inst.Size),
			travel = inst.Speed.Max * inst.Lifetime.Max, inv = holder.CFrame:Inverse(), half = holder.Size * 0.5,
		})
	elseif inst:IsA("Fire") and holder and holder:IsA("BasePart") then
		known[inst] = true
		table.insert(entries, {
			inst = inst :: Instance, kind = "fire", base = 0, startedOn = orig.on, size = inst.Size,
			travel = 0, inv = holder.CFrame:Inverse(), half = holder.Size * 0.5,
		})
	elseif inst:IsA("Beam") and inst.Attachment0 and inst.Attachment1 then
		known[inst] = true
		local a0, a1 = inst.Attachment0 :: Attachment, inst.Attachment1 :: Attachment
		table.insert(entries, {
			inst = inst :: Instance, kind = "beam", base = 0, startedOn = orig.on, size = math.max(inst.Width0, inst.Width1),
			travel = 0, a = a0.WorldPosition, b = a1.WorldPosition,
		})
	end
end

local function distance(e: Entry, cam: Vector3): number
	if e.kind == "beam" then
		local a, b = e.a :: Vector3, e.b :: Vector3
		return Rules.segmentDistance(cam.X, cam.Y, cam.Z, a.X, a.Y, a.Z, b.X, b.Y, b.Z)
	end
	local p = (e.inv :: CFrame) * cam
	local h = e.half :: Vector3
	return math.max(0, Rules.boxDistance(p.X, p.Y, p.Z, h.X, h.Y, h.Z) - e.travel)
end

local function tick()
	local cam = workspace.CurrentCamera
	if not cam or #entries == 0 then
		return
	end
	local camPos = cam.CFrame.Position
	local pps = Rules.pointsPerStud(cam.ViewportSize.Y, cam.FieldOfView)
	local pscale = Settings.particleScale()
	local low = Settings.lowGraphics()
	local force = dirty
	dirty = false
	local i = 1
	while i <= #entries do
		local e = entries[i]
		local inst = e.inst
		if not inst.Parent then
			known[inst] = nil
			entries[i] = entries[#entries]
			entries[#entries] = nil
			continue
		end
		local range = math.max(Rules.MIN_RANGE, e.size * pps / Rules.MIN_PX)
		local inRange = distance(e, camPos) <= range
		if e.kind == "pe" then
			local r = Rules.emitterRate(e.base, pscale, inRange)
			if force or r ~= e.last then
				e.last = r;
				(inst :: ParticleEmitter).Rate = r
			end
		elseif e.startedOn then
			local on = Rules.solidOn(true, inRange, low)
			local v = if on then 1 else 0
			if force or v ~= e.last then
				e.last = v;
				(inst :: any).Enabled = on
			end
		end
		i += 1
	end
end

local function scan(root: Instance)
	for _, d in root:GetDescendants() do
		collect(d)
	end
	dirty = true
	tick()
end

local function activeRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

-- Same wait as client/WorldAnim: the active map once TrackReady, again a few seconds later, on every switch.
local function watchActive()
	scanToken += 1
	local my = scanToken
	table.clear(entries)
	table.clear(known)
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

---------------------------------------------------------------------------------------------------- post-processing

local postBase: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function applyPost(inst: Instance)
	if not (inst:IsA("SunRaysEffect") or inst:IsA("BloomEffect")) or string.sub(inst.Name, 1, 9) ~= "SkyRally_" then
		return
	end
	local fx = inst :: PostEffect
	local base = postBase[inst]
	if base == nil then
		base = fx.Enabled
		postBase[inst] = base
	end
	local want = Rules.postOn(inst.ClassName, base, Settings.phoneTier(), Settings.lowGraphics())
	if fx.Enabled ~= want then
		fx.Enabled = want
	end
end

local function applyAllPost()
	for _, ch in Lighting:GetChildren() do
		applyPost(ch)
	end
end

function MapFxLod.init()
	RaceAttr.changed("ActiveTrackId", watchActive)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			watchActive()
		end
	end)
	watchActive()
	Lighting.ChildAdded:Connect(applyPost)
	applyAllPost()
	Settings.onChanged(function(key: string)
		if key == "lowGraphics" or key == "particleScale" then
			dirty = true
			tick()
			applyAllPost()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(Rules.FX_TICK)
			tick()
		end
	end)
end

return MapFxLod
