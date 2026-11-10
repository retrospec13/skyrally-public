--!strict
-- Magnet v2 aim (owner 2026-10-20: the magnet "needs an indicator and a target for the player to see who they are going
-- to and how far the range will actually work - really it should just take the player to the closest person").
-- Holder-only, client-side, information only: the server (kit/ItemEffects) picks the real target with the same rule.
-- * While a Rainbow (magnet) item is held: every SCAN_EVERY s the closest other vehicle under workspace.Planes is picked
--   with ItemRules.magnetPick (the server's rule) against the held level's range. A reticle (BillboardGui ring in
--   PlayerGui, AlwaysOnTop, centred on the hull under the name tag) sits on it with a "<dist> / <range>" readout: rainbow
--   when in range, grey with TOO FAR when not. A faint particle tether (three sparkle emitters on Terrain attachments
--   along the line, pointed at the target) shows only when in range.
-- * lock(target, seconds): the server's "magnet" effect. The reticle goes solid on the locked vehicle and the tether
--   runs thick until arrive() (contact, from the vehicle controller) or the time is up.
-- No meshes, no HUD lanes: the ring is UI on the target, the tether is particles (docs/design/HUD_LAYOUT.md, ART_BAR).
-- Per frame: three attachment moves while visible; the scan is ~8 vehicles at SCAN_EVERY.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local MagnetAim = {}

MagnetAim.SCAN_EVERY = 0.12
MagnetAim.STALE = 0.6
MagnetAim.TETHER_POINTS = 3
local RAINBOW = Color3.fromRGB(205, 110, 255)
local GREY = Color3.fromRGB(150, 150, 160)
local INK = Color3.fromRGB(28, 22, 40)

type State = {
	held: boolean,
	level: number,
	target: Model?,
	dist: number,
	inRange: boolean,
	scannedAt: number,
	locked: Model?,
	lockUntil: number,
}

local state: State = {
	held = false,
	level = 0,
	target = nil,
	dist = math.huge,
	inRange = false,
	scannedAt = -math.huge,
	locked = nil,
	lockUntil = 0,
}

local gui: BillboardGui? = nil
local ring: Frame? = nil
local ringStroke: UIStroke? = nil
local readout: TextLabel? = nil
local tether: { { att: Attachment, pe: ParticleEmitter } } = {}
local scanClock = 0

local function hullOf(m: Instance?): BasePart?
	if m and m:IsA("Model") and m.Parent then
		local h = m.PrimaryPart or m:FindFirstChild("Hull")
		if h and h:IsA("BasePart") then
			return h
		end
	end
	return nil
end

local function myVehicle(): Model?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	local m = planes:FindFirstChild("Car_" .. LocalPlayer.Name) or planes:FindFirstChild("Plane_" .. LocalPlayer.Name)
	return if m and m:IsA("Model") then m else nil
end

function MagnetAim.range(level: number): number
	local p = ItemRules.PARAMS.magnet[math.clamp(math.floor(level), 1, #ItemRules.PARAMS.magnet)]
	return p.range
end

local function ensureGui(): BillboardGui
	if gui and gui.Parent then
		return gui
	end
	local g = Instance.new("BillboardGui")
	g.Name = "MagnetAim"
	g.Size = UDim2.fromOffset(84, 104)
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.ResetOnSpawn = false
	g.Active = false
	g.Enabled = false
	local r = Instance.new("Frame")
	r.Name = "Ring"
	r.AnchorPoint = Vector2.new(0.5, 0)
	r.Position = UDim2.fromScale(0.5, 0)
	r.Size = UDim2.fromOffset(64, 64)
	r.BackgroundTransparency = 1
	r.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = r
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = RAINBOW
	stroke.Parent = r
	-- Four ticks make it read as a reticle, not a bubble.
	for i, pos in { UDim2.new(0.5, -2, 0, -10), UDim2.new(0.5, -2, 1, -2), UDim2.new(0, -10, 0.5, -2), UDim2.new(1, -2, 0.5, -2) } do
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. i
		tick.BorderSizePixel = 0
		tick.BackgroundColor3 = Color3.new(1, 1, 1)
		tick.Size = if i <= 2 then UDim2.fromOffset(4, 12) else UDim2.fromOffset(12, 4)
		tick.Position = pos
		tick.Parent = r
	end
	local t = Instance.new("TextLabel")
	t.Name = "Readout"
	t.AnchorPoint = Vector2.new(0.5, 1)
	t.Position = UDim2.fromScale(0.5, 1)
	t.Size = UDim2.fromOffset(84, 30)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeColor3 = INK
	t.TextStrokeTransparency = 0.2
	t.Parent = g
	g.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui, ring, ringStroke, readout = g, r, stroke, t
	return g
end

local function ensureTether()
	if #tether > 0 then
		return
	end
	local tex = (VfxAssets :: any).star_twinkle
	for i = 1, MagnetAim.TETHER_POINTS do
		local att = Instance.new("Attachment")
		att.Name = "MagnetTether" .. i
		att.Parent = workspace.Terrain
		local pe = Instance.new("ParticleEmitter")
		pe.Texture = if tex then tex.id else ""
		pe.EmissionDirection = Enum.NormalId.Front
		pe.Lifetime = NumberRange.new(0.35, 0.55)
		pe.Speed = NumberRange.new(14, 22)
		pe.SpreadAngle = Vector2.new(8, 8)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0.1) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.Rate = 0
		pe.Enabled = false
		pe.Parent = att
		table.insert(tether, { att = att, pe = pe })
	end
end

local tetherRate, tetherColor = -1, Color3.new()
local function setTether(rate: number, color: Color3)
	if rate == tetherRate and color == tetherColor then
		return
	end
	tetherRate, tetherColor = rate, color
	local seq = ColorSequence.new(Color3.new(1, 1, 1), color)
	for _, t in tether do
		t.pe.Enabled = rate > 0
		t.pe.Rate = rate
		t.pe.Color = seq
	end
end

local function hide()
	local g: any = gui
	if g then
		g.Enabled = false
		g.Adornee = nil
	end
	setTether(0, RAINBOW)
end

-- Held item from ItemClient's ItemState: only a Rainbow (magnet) item aims.
function MagnetAim.setHeld(color: string?, level: number)
	state.held = color == "rainbow" and level > 0
	state.level = if state.held then level else 0
	if not state.held then
		state.target, state.inRange, state.dist = nil, false, math.huge
		state.scannedAt = -math.huge
		if not state.locked then
			hide()
		end
	end
end

-- The server's lock ("magnet" ItemEffect to this player).
function MagnetAim.lock(target: Model, seconds: number)
	state.locked = target
	state.lockUntil = os.clock() + seconds
end

-- Contact (vehicle controller) or a miss: the lock is over.
function MagnetAim.release()
	state.locked = nil
	state.lockUntil = 0
	if not state.held then
		hide()
	end
end

function MagnetAim.preview(): (Model?, number, boolean)
	return state.target, state.dist, state.inRange
end

local function scan(mine: Model, myHull: BasePart)
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return
	end
	local cands: { ItemRules.MagnetCandidate } = {}
	local byId: { [string]: Model } = {}
	for _, m in planes:GetChildren() do
		if m ~= mine and m:IsA("Model") and m:GetAttribute("IsBoss") ~= true then
			local h = hullOf(m)
			if h then
				local id = m:GetFullName()
				byId[id] = m
				table.insert(cands, { id = id, pos = h.Position })
			end
		end
	end
	local id, dist, inRange = ItemRules.magnetPick(myHull.Position, myHull.CFrame.LookVector, cands, MagnetAim.range(state.level))
	state.target = if id then byId[id] else nil
	state.dist, state.inRange = dist, inRange
	state.scannedAt = os.clock()
end

function MagnetAim.step(dt: number)
	if not state.held and not state.locked then
		return
	end
	local now = os.clock()
	if state.locked and (now >= state.lockUntil or not hullOf(state.locked)) then
		MagnetAim.release()
		if not state.held then
			return
		end
	end
	local mine = myVehicle()
	local myHull = hullOf(mine)
	if not mine or not myHull then
		hide()
		return
	end
	scanClock += dt
	if state.held and not state.locked and scanClock >= MagnetAim.SCAN_EVERY then
		scanClock = 0
		scan(mine, myHull)
	end
	local locked = state.locked
	local target = locked or state.target
	local tHull = hullOf(target)
	if not tHull then
		hide()
		return
	end
	local g = ensureGui()
	g.Adornee = tHull
	g.Enabled = true
	local live = locked ~= nil or state.inRange
	local color = if live then RAINBOW else GREY
	local dist = (tHull.Position - myHull.Position).Magnitude
	if ringStroke and ring and readout then
		ringStroke.Color = color
		-- Locked: the ring breathes; held in range: steady; out of range: thin and faded.
		ringStroke.Thickness = if locked then 4 + 2 * math.sin(now * 12) else if live then 4 else 2
		ringStroke.Transparency = if live then 0 else 0.35
		readout.TextColor3 = if live then Color3.new(1, 1, 1) else GREY
		if locked then
			readout.Text = string.format("%d", math.floor(dist + 0.5))
		elseif live then
			readout.Text = string.format("%d / %d", math.floor(dist + 0.5), MagnetAim.range(state.level))
		else
			readout.Text = string.format("TOO FAR %d", MagnetAim.range(state.level))
		end
	end
	if not live or (Settings.lowGraphics() and not locked) then
		setTether(0, color)
		return
	end
	if #tether == 0 then
		ensureTether()
		tetherRate = -1
	end
	local from, to = myHull.Position, tHull.Position
	local dir = to - from
	if dir.Magnitude < 1 then
		setTether(0, color)
		return
	end
	local look = CFrame.lookAt(Vector3.zero, dir.Unit)
	for i, t in tether do
		local p = from + dir * (i / (MagnetAim.TETHER_POINTS + 1))
		t.att.WorldCFrame = look + p
	end
	setTether(if locked then 26 * Settings.particleScale() else 7 * Settings.particleScale(), color)
end

return MagnetAim
