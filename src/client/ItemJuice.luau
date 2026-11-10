--!strict
-- Item feel for REMARKABLE Batch 2 items 14 and 18, driven by client/ItemClient (which owns the ItemRemote listener):
--   * Sounds: synthesised cues (tools/audio/synth_items.py -> prep_items.sh) whose ids live in the generated
--     shared/ItemAudio. A cue with no uploaded id is silent and play() returns false, so callers can fall back (the
--     BONK falls back to the old crash thud). Every cue has a small round-robin pool: no Instance.new per trigger.
--   * Incoming warning (item 14): the server's 5 Hz ETA ("IncomingItem") becomes beeps that speed up and rise in pitch
--     as the shot closes (ItemRules.beepInterval / beepPitch), a red glow at the bottom edge and a small badge above
--     the toast plank (INCOMING! / LOCKED ON! / VOLLEY!) with an ETA bar. Animated by hand in step(): no tweens and no
--     allocations per frame. Information only.
--     Missile v3 (shared/MissileRules): a chevron on the badge points at the shot (payload dx/dz against the camera),
--     and a second line names the counterplay (DOUBLE-TAP TO DODGE, HOLD ITEM: TRAP BEHIND, SHIELD UP!; ItemClient supplies
--     it through setHintSource). The beep is the cue "missile_lock_beep": add that name to AudioAssets/ItemAudio to
--     replace it; until then it falls back to the synthesised "item_beep" stand-in.
--   * Soot (item 18): a hit vehicle goes sooty for a few seconds through a pooled Highlight overlay (the livery is
--     never repainted) plus a thin smoke wisp. At most SOOT_SLOTS at once (the oldest is reused) and nothing farther
--     than SOOT_RANGE from the camera.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local MissileRules = require(Shared:WaitForChild("MissileRules"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
-- Audit H13: item cues go through the EFFECTS slider.
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local ItemJuice = {}

------------------------------------------------------------------------------------------------------------------------
-- Sounds
------------------------------------------------------------------------------------------------------------------------

local VOLUMES: { [string]: number } = {
	item_beep = 0.4,
	item_bonk = 0.9,
	item_dizzy = 0.45,
	item_gotcha = 0.6,
	item_revenge = 0.75,
	item_flyby = 0.6,
	taunt_pop = 0.32,
}
local POOL_SIZE: { [string]: number } = { item_beep = 3, missile_lock_beep = 3, taunt_pop = 3 }

local ids: { [string]: string } = {}
local idsLoaded = false
local silentLogged = false
local folder: Folder? = nil
local pools: { [string]: { list: { Sound }, nextIndex: number } } = {}

local function loadIds()
	if idsLoaded then
		return
	end
	idsLoaded = true
	-- The shared AudioAssets first, then this lane's generated ItemAudio (which wins).
	for _, name in { "ToolboxAudio", "AudioAssets", "ItemAudio" } do
		local mod = Shared:FindFirstChild(name)
		if mod and mod:IsA("ModuleScript") then
			local ok, t = pcall(require, mod)
			if ok and type(t) == "table" then
				for k, v in t :: { [string]: any } do
					if type(k) == "string" and type(v) == "string" then
						ids[k] = v
					end
				end
			end
		end
	end
end

local function idFor(cue: string): string?
	loadIds()
	local id = ids[cue]
	if not id and not silentLogged then
		silentLogged = true
		print("[SkyRally][ITEM] item cues not uploaded yet (first missing: " .. cue .. "); they run silent")
	end
	return id
end

function ItemJuice.has(cue: string): boolean
	loadIds()
	return ids[cue] ~= nil
end

local function soundFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = SoundService:FindFirstChild("SkyRallyItems")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyItems"
	nf.Parent = SoundService
	folder = nf
	return nf
end

-- A 2D cue for this player. Returns false when the cue has no uploaded id (nothing played).
function ItemJuice.play(cue: string, pitch: number?, volume: number?): boolean
	local id = idFor(cue)
	if not id then
		return false
	end
	local p = pools[cue]
	if not p then
		local list: { Sound } = {}
		local parent = soundFolder()
		for i = 1, POOL_SIZE[cue] or 2 do
			local snd = Instance.new("Sound")
			snd.Name = cue .. "_" .. i
			snd.SoundId = id
			Settings.sfx(snd)
			snd.Parent = parent
			table.insert(list, snd)
		end
		p = { list = list, nextIndex = 1 }
		pools[cue] = p
	end
	local s = p.list[p.nextIndex]
	p.nextIndex = p.nextIndex % #p.list + 1
	s.Volume = volume or VOLUMES[cue] or 0.6
	s.PlaybackSpeed = pitch or 1
	s.TimePosition = 0
	s:Play()
	return true
end

-- A 3D cue on another racer's hull: one Sound per hull and cue, created on first use, gone with the hull.
function ItemJuice.play3D(cue: string, hull: BasePart, volume: number?): boolean
	local id = idFor(cue)
	if not id then
		return false
	end
	local name = "ItemSfx_" .. cue
	local s = hull:FindFirstChild(name)
	if not s or not s:IsA("Sound") then
		local ns = Instance.new("Sound")
		ns.Name = name
		ns.SoundId = id
		ns.RollOffMode = Enum.RollOffMode.InverseTapered
		ns.RollOffMinDistance = 14
		ns.RollOffMaxDistance = 170
		Settings.sfx(ns)
		ns.Parent = hull
		s = ns
	end
	local snd = s :: Sound
	snd.Volume = volume or (VOLUMES[cue] or 0.6) * 0.8
	snd.PlaybackSpeed = 0.93 + math.random() * 0.14
	snd.TimePosition = 0
	snd:Play()
	return true
end

-- The comic BONK for this player's own hit, with little birds circling after it. False when not uploaded.
function ItemJuice.bonk(): boolean
	if not ItemJuice.play("item_bonk", 0.95 + math.random() * 0.1) then
		return false
	end
	task.delay(0.2, function()
		ItemJuice.play("item_dizzy", 0.97 + math.random() * 0.06)
	end)
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- Incoming warning HUD (item 14)
------------------------------------------------------------------------------------------------------------------------

local WARN_RED = Color3.fromRGB(226, 46, 34)
local WARN_CREAM = Color3.fromRGB(255, 244, 214)
local WARN_INK = Color3.fromRGB(46, 22, 16)
local STALE = 0.6 -- s without an update before the warning drops by itself (the shot left the world)

type Incoming = {
	active: boolean,
	eta: number,
	at: number,
	homing: boolean,
	count: number,
	nextBeep: number,
	lastBeep: number,
	dx: number?, -- missile v3: the shot's flat offset from this racer (studs), for the chevron
	dz: number?,
}
local incoming: Incoming = { active = false, eta = 0, at = 0, homing = false, count = 0, nextBeep = 0, lastBeep = -math.huge }
local LOCK_BEEP = "missile_lock_beep" -- Creator Store ping (shared/ToolboxAudio); "item_beep" stands in if it fails to resolve
local hintSource: (() -> string?)? = nil

local hud: ScreenGui? = nil
local edge: Frame? = nil
local badge: Frame? = nil
local badgeText: TextLabel? = nil
local badgeBar: Frame? = nil
local badgeScale: UIScale? = nil
local shownText = ""
local arrow: Frame? = nil
local hintLabel: TextLabel? = nil
local shownHint: string? = nil

local function buildHud()
	if hud and hud.Parent then
		return
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyIncoming"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 7 -- over the speed lines (5), under the controls hint (40); never blocks input
	sg.Enabled = false

	local e = Instance.new("Frame")
	e.Name = "EdgeGlow"
	e.AnchorPoint = Vector2.new(0.5, 1)
	e.Position = UDim2.fromScale(0.5, 1)
	e.Size = UDim2.fromScale(1, 0.26)
	e.BackgroundColor3 = WARN_RED
	e.BorderSizePixel = 0
	e.BackgroundTransparency = 0.4
	e.Active = false
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.6, 0.85),
		NumberSequenceKeypoint.new(1, 0.25),
	})
	g.Parent = e
	e.Parent = sg

	local b = Instance.new("Frame")
	b.Name = "IncomingBadge"
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.Position = UDim2.new(0.5, 0, 1, -98) -- just above the toast plank (RaceUI banner sits at -56, 36 tall)
	b.Size = UDim2.fromOffset(172, 30)
	b.BackgroundColor3 = WARN_RED
	b.BorderSizePixel = 0
	b.Active = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 15)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = WARN_CREAM
	stroke.Thickness = 2
	stroke.Parent = b
	local sc = Instance.new("UIScale")
	sc.Parent = b
	local t = Instance.new("TextLabel")
	t.Name = "Label"
	t.BackgroundTransparency = 1
	t.Size = UDim2.new(1, 0, 1, -5)
	t.Font = Enum.Font.GothamBlack
	t.TextSize = 15
	t.TextColor3 = WARN_CREAM
	t.Text = "INCOMING!"
	local ts = Instance.new("UIStroke")
	ts.Color = WARN_INK
	ts.Thickness = 1.6
	ts.Parent = t
	t.Parent = b
	-- Missile v3: a chevron at the left end pointing where the shot comes from (0 = ahead, rotated per frame).
	local a = Instance.new("Frame")
	a.Name = "Direction"
	a.AnchorPoint = Vector2.new(0.5, 0.5)
	a.Position = UDim2.new(0, 16, 0, 15)
	a.Size = UDim2.fromOffset(18, 18)
	a.BackgroundTransparency = 1
	for i, side in { -1, 1 } do
		local leg = Instance.new("Frame")
		leg.Name = "Leg" .. i
		leg.AnchorPoint = Vector2.new(0.5, 0.5)
		leg.Position = UDim2.new(0.5, side * 3.5, 0.5, 0)
		leg.Size = UDim2.fromOffset(3, 11)
		leg.Rotation = -side * 40 -- clockwise is positive: the legs lean in to a peak (an up chevron)
		leg.BackgroundColor3 = WARN_CREAM
		leg.BorderSizePixel = 0
		leg.Parent = a
	end
	a.Parent = b
	local hl = Instance.new("TextLabel")
	hl.Name = "Hint"
	hl.BackgroundTransparency = 1
	hl.AnchorPoint = Vector2.new(0.5, 0)
	hl.Position = UDim2.new(0.5, 0, 0, 25)
	hl.Size = UDim2.new(1, -8, 0, 12)
	hl.Font = Enum.Font.GothamBold
	hl.TextSize = 11
	hl.TextColor3 = WARN_CREAM
	hl.Text = ""
	hl.Visible = false
	hl.Parent = b
	local bar = Instance.new("Frame")
	bar.Name = "EtaBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -4)
	bar.Size = UDim2.new(0.8, 0, 0, 3)
	bar.BackgroundColor3 = WARN_CREAM
	bar.BorderSizePixel = 0
	bar.Parent = b
	b.Parent = sg

	sg.Parent = pg
	hud, edge, badge, badgeText, badgeBar, badgeScale = sg, e, b, t, bar, sc
	arrow, hintLabel = a, hl
	shownHint = nil
end

-- ItemClient: what the second line of the badge says (MissileRules.counterHint for this vehicle and held item).
function ItemJuice.setHintSource(fn: (() -> string?)?)
	hintSource = fn
end

-- From the server ("IncomingItem"): {eta, homing, count}, or {eta = -1, dodged?} when the threat is over. Returns true
-- when this update reports a dodge (ItemClient shows DODGED!).
function ItemJuice.setIncoming(payload: any): boolean
	if type(payload) ~= "table" or type(payload.eta) ~= "number" then
		return false
	end
	local now = os.clock()
	if payload.eta < 0 then
		incoming.active = false
		return payload.dodged == true
	end
	local wasActive = incoming.active
	incoming.active = true
	incoming.eta = math.clamp(payload.eta, 0, ItemRules.INCOMING.warnSeconds)
	incoming.at = now
	incoming.homing = payload.homing == true
	incoming.count = if type(payload.count) == "number" then payload.count else 1
	incoming.dx = if type(payload.dx) == "number" then payload.dx else nil
	incoming.dz = if type(payload.dz) == "number" then payload.dz else nil
	if payload.lock == true then
		incoming.homing = true
	end
	if not wasActive then
		incoming.nextBeep = now -- the first beep lands at once: that is the panic
	end
	return false
end

function ItemJuice.clearIncoming()
	incoming.active = false
end

-- 1 on a beep, decaying to 0 before the next: ItemClient blinks the locked-on missile with it.
function ItemJuice.beepPulse(): number
	if not incoming.active then
		return 0
	end
	return math.exp(-(os.clock() - incoming.lastBeep) * 14)
end

function ItemJuice.isIncoming(): boolean
	return incoming.active
end

local function stepIncoming(now: number)
	local gui = hud
	if incoming.active and now - incoming.at > STALE then
		incoming.active = false
	end
	if not incoming.active then
		if gui and gui.Enabled then
			gui.Enabled = false
		end
		return
	end
	if not gui then
		buildHud()
		gui = hud
	end
	if not gui then
		return
	end
	gui.Enabled = true
	local eta = math.max(0, incoming.eta - (now - incoming.at))
	if now >= incoming.nextBeep then
		local pitch = ItemRules.beepPitch(eta, incoming.homing)
		if not ItemJuice.play(LOCK_BEEP, pitch, VOLUMES.item_beep) then
			ItemJuice.play("item_beep", pitch)
		end
		incoming.lastBeep = now
		incoming.nextBeep = now + ItemRules.beepInterval(eta)
	end
	local pulse = math.exp(-(now - incoming.lastBeep) * 14)
	local closeness = 1 - math.clamp(eta / ItemRules.INCOMING.warnSeconds, 0, 1)
	local e, b, t, bar, sc = edge, badge, badgeText, badgeBar, badgeScale
	if e then
		e.BackgroundTransparency = 0.72 - 0.3 * closeness - 0.25 * pulse
	end
	if t then
		local text = if incoming.homing then "LOCKED ON!" elseif incoming.count >= 3 then "VOLLEY!" else "INCOMING!"
		if text ~= shownText then
			shownText = text
			t.Text = text
		end
	end
	if bar then
		bar.Size = UDim2.new(0.8 * math.clamp(eta / ItemRules.INCOMING.warnSeconds, 0.04, 1), 0, 0, 3)
	end
	local ar = arrow
	if ar then
		local dx, dz = incoming.dx, incoming.dz
		local cam = workspace.CurrentCamera
		if dx and dz and cam then
			local look = cam.CFrame.LookVector
			ar.Visible = true
			ar.Rotation = MissileRules.arrowAngle(dx, dz, look.X, look.Z)
		else
			ar.Visible = false
		end
	end
	local hl = hintLabel
	if hl then
		local src = hintSource
		local hint: string? = nil
		if src then
			local ok, v = pcall(src)
			hint = if ok and type(v) == "string" then v else nil
		end
		if hint ~= shownHint then
			shownHint = hint
			hl.Text = hint or ""
			hl.Visible = hint ~= nil
			if b then
				b.Size = UDim2.fromOffset(172, if hint then 42 else 30)
			end
			if t then
				t.Size = if hint then UDim2.new(1, 0, 0, 26) else UDim2.new(1, 0, 1, -5)
			end
		end
	end
	if sc then
		local cam = workspace.CurrentCamera
		local base = if cam and cam.ViewportSize.Y >= 600 then 1.45 else 1
		sc.Scale = base * (1 + 0.16 * pulse)
	end
	if b then
		-- The last half second shakes: you have about one lane change left.
		local shake = if eta < 0.5 then math.sin(now * 60) * 3 * (1 - eta / 0.5) else 0
		b.Position = UDim2.new(0.5, shake, 1, -98)
		b.Rotation = shake * 0.8
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Soot overlay (item 18)
------------------------------------------------------------------------------------------------------------------------

local SOOT_SLOTS = 4
local SOOT_SECONDS = 4.0
local SOOT_HOLD = 1.4 -- full soot for this long, then it fades
local SOOT_RANGE = 360
local SOOT_FILL = 0.22 -- FillTransparency at full soot
local SOOT_COLOR = Color3.fromRGB(38, 32, 28)
local SOOT_TRAP = Color3.fromRGB(44, 58, 34) -- a mine leaves a greener grime

type SootSlot = {
	hl: Highlight,
	att: Attachment,
	smoke: ParticleEmitter,
	plane: Model?,
	startedAt: number,
}
local sootSlots: { SootSlot } = {}

local function buildSoot()
	if #sootSlots > 0 then
		return
	end
	local cam = workspace.CurrentCamera
	local f = Instance.new("Folder")
	f.Name = "SkyRallySoot"
	f.Parent = cam or workspace
	for i = 1, SOOT_SLOTS do
		local hl = Instance.new("Highlight")
		hl.Name = "Soot" .. i
		hl.Enabled = false
		hl.FillColor = SOOT_COLOR
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Parent = f
		local att = Instance.new("Attachment")
		att.Name = "SootWisp" .. i
		local pe = Instance.new("ParticleEmitter")
		FlipFx.apply(pe, "smoke_puff_8x8") -- the owned smoke sheet (old texture as the fallback), as ItemClient uses
		pe.Rate = 0
		pe.Enabled = false
		pe.Lifetime = NumberRange.new(0.8, 1.2)
		pe.Speed = NumberRange.new(2, 4)
		pe.SpreadAngle = Vector2.new(25, 25)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.Acceleration = Vector3.new(0, 4, 0)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3.2) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		pe.Color = ColorSequence.new(Color3.fromRGB(70, 64, 60), Color3.fromRGB(120, 116, 112))
		pe.LightInfluence = 1
		pe.RotSpeed = NumberRange.new(-40, 40)
		pe.Parent = att
		table.insert(sootSlots, { hl = hl, att = att, smoke = pe, plane = nil, startedAt = -math.huge })
	end
end

local function hullOf(plane: Model): BasePart?
	local hull = plane.PrimaryPart or plane:FindFirstChild("Hull")
	return if hull and hull:IsA("BasePart") then hull else nil
end

local function releaseSoot(slot: SootSlot)
	slot.plane = nil
	slot.hl.Enabled = false
	slot.hl.Adornee = nil
	slot.smoke.Enabled = false
	slot.att.Parent = nil
end

-- Soots a hit vehicle (any racer). trap: the greener mine grime.
function ItemJuice.soot(plane: Model, trap: boolean?)
	local hull = hullOf(plane)
	local cam = workspace.CurrentCamera
	if not hull or (cam and (cam.CFrame.Position - hull.Position).Magnitude > SOOT_RANGE) then
		return
	end
	buildSoot()
	local now = os.clock()
	local pick: SootSlot? = nil
	for _, slot in sootSlots do
		if slot.plane == plane then
			pick = slot
			break
		end
	end
	if not pick then
		for _, slot in sootSlots do
			if slot.plane == nil then
				pick = slot
				break
			end
		end
	end
	if not pick then
		local oldest = sootSlots[1]
		for _, slot in sootSlots do
			if slot.startedAt < oldest.startedAt then
				oldest = slot
			end
		end
		releaseSoot(oldest)
		pick = oldest
	end
	local slot = pick :: SootSlot
	slot.plane = plane
	slot.startedAt = now
	slot.hl.FillColor = if trap then SOOT_TRAP else SOOT_COLOR
	slot.hl.Adornee = plane
	slot.hl.FillTransparency = SOOT_FILL
	slot.hl.Enabled = true
	slot.att.Parent = hull
	slot.att.Position = Vector3.new(0, 1.5, 0)
	slot.smoke.Rate = 9 * Settings.particleScale()
	slot.smoke.Enabled = true
end

local function stepSoot(now: number)
	for _, slot in sootSlots do
		local plane = slot.plane
		if plane then
			local age = now - slot.startedAt
			if age >= SOOT_SECONDS or not plane.Parent then
				releaseSoot(slot)
			elseif age > SOOT_HOLD then
				local k = (age - SOOT_HOLD) / (SOOT_SECONDS - SOOT_HOLD)
				slot.hl.FillTransparency = SOOT_FILL + (1 - SOOT_FILL) * k
				slot.smoke.Rate = 9 * Settings.particleScale() * (1 - k)
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------

function ItemJuice.step(_dt: number)
	local now = os.clock()
	stepIncoming(now)
	if #sootSlots > 0 then
		stepSoot(now)
	end
end

function ItemJuice.init()
	loadIds()
	buildHud()
	-- A respawn or a track switch drops any warning in flight (the server stops sending; STALE also covers it).
	LocalPlayer:GetAttributeChangedSignal("Crashing"):Connect(function()
		if LocalPlayer:GetAttribute("Crashing") == true then
			incoming.active = false
		end
	end)
end

return ItemJuice
