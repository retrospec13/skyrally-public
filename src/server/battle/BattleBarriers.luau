--!strict
-- Battle-only barriers (trap audit I2-05; docs/audits/traps_island2.md): plan data under modes.battle.barriers, built
-- by BattleCore.start into the battle's BattleOverlay folder, so they exist only while a battle runs and leave with it.
-- ISLAND-2 closes the cavern-mouth road at st ~255 with one: a rope line, barrels, crates and a hanging "NOPE!" board,
-- an invisible collider that holds the car's wall rays (jamb to jamb, from under the road to the arch spring), and a
-- snoring kraken somewhere inside the dark cave (a looped 3D sound and a floating "z Z z").
--
-- Data (author script -> plan -> tools/map/adapt.py -> TrackData; 3-number lists are Vector3, `cf` is a CFrame):
--   { name, station, cf,                      -- frame: origin on the ribbon, +Z faces the arena, -Z into the cave
--     collider = { center, size },            -- local box, invisible, CanCollide + CanQuery (the car's wall rays)
--     parts = { part rows },                  -- { shape B|C|S|W, x, y, z, sx, sy, sz, rx, ry, rz, "#hex", Material,
--                                             --   { nc = 1, a = alpha, l = { range, brightness, "#hex" } }? }
--     signs = { { part, face, title, text } },-- SurfaceGui text on parts[part]'s face (Back = +Z, toward the arena)
--     snore = { offset, cue, volume, rollOff, text }? }
-- The sound id comes from shared/BarrierAudio or shared/AudioAssets by cue name; a missing cue is silent.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BattleBarriers = {}

BattleBarriers.MAX_PARTS = 48 -- per barrier: a prop line, not a building

export type Row = { any }
export type Planned = {
	name: string,
	cf: CFrame,
	colliderCf: CFrame?,
	colliderSize: Vector3?,
	parts: { { row: Row, cf: CFrame } },
	signs: { any },
	snore: any?,
}

-- Local CFrame of a part row (YXZ Euler degrees, as the map builder applies them).
function BattleBarriers.rowCFrame(row: Row): CFrame
	local cf = CFrame.new(row[2], row[3], row[4])
	local rx, ry, rz = row[8] or 0, row[9] or 0, row[10] or 0
	if rx ~= 0 or ry ~= 0 or rz ~= 0 then
		cf = cf * CFrame.fromEulerAnglesYXZ(math.rad(rx), math.rad(ry), math.rad(rz))
	end
	return cf
end

local function validRow(row: any): boolean
	if type(row) ~= "table" or type(row[1]) ~= "string" then
		return false
	end
	for i = 2, 7 do
		if type(row[i]) ~= "number" then
			return false
		end
	end
	return row[5] > 0 and row[6] > 0 and row[7] > 0
end

-- World placement of every barrier in a modes.battle block (pure: no Instances). Malformed entries are skipped.
function BattleBarriers.plan(battle: any): { Planned }
	local out: { Planned } = {}
	local list = if type(battle) == "table" then battle.barriers else nil
	if type(list) ~= "table" then
		return out
	end
	for i, b in list do
		if type(b) == "table" and typeof(b.cf) == "CFrame" then
			local base: CFrame = b.cf
			local p: Planned = {
				name = if type(b.name) == "string" then b.name else ("Barrier" .. i),
				cf = base,
				colliderCf = nil,
				colliderSize = nil,
				parts = {},
				signs = if type(b.signs) == "table" then b.signs else {},
				snore = if type(b.snore) == "table" then b.snore else nil,
			}
			local c = b.collider
			if type(c) == "table" and typeof(c.center) == "Vector3" and typeof(c.size) == "Vector3" then
				p.colliderCf = base * CFrame.new(c.center)
				p.colliderSize = c.size
			end
			if type(b.parts) == "table" then
				for _, row in b.parts do
					if #p.parts >= BattleBarriers.MAX_PARTS then
						break
					end
					if validRow(row) then
						table.insert(p.parts, { row = row, cf = base * BattleBarriers.rowCFrame(row) })
					end
				end
			end
			table.insert(out, p)
		end
	end
	return out
end

-- ------------------------------------------------------------------------------------------------- Instances
local function material(name: any): Enum.Material
	if type(name) == "string" then
		local ok, m = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and typeof(m) == "EnumItem" then
			return m :: any
		end
	end
	return Enum.Material.SmoothPlastic
end

local function colour(hex: any, fallback: Color3): Color3
	if type(hex) == "string" then
		local ok, c = pcall(Color3.fromHex, hex)
		if ok then
			return c
		end
	end
	return fallback
end

local function makePart(row: Row, cf: CFrame): BasePart
	local shape = row[1]
	local sx, sy, sz = row[5], row[6], row[7]
	local extra = if type(row[13]) == "table" then row[13] else nil
	local p: BasePart
	if shape == "W" then
		p = Instance.new("WedgePart")
		p.Size = Vector3.new(sx, sy, sz)
		p.CFrame = cf
	elseif shape == "C" then
		local c = Instance.new("Part")
		c.Shape = Enum.PartType.Cylinder
		c.Size = Vector3.new(sy, sx, sz) -- Roblox cylinders run along local X; rows give the axis as local Y
		c.CFrame = cf * CFrame.Angles(0, 0, math.pi / 2)
		p = c
	elseif shape == "S" then
		local s = Instance.new("Part")
		s.Shape = Enum.PartType.Ball
		s.Size = Vector3.new(sx, sy, sz)
		s.CFrame = cf
		p = s
	else
		p = Instance.new("Part")
		p.Size = Vector3.new(sx, sy, sz)
		p.CFrame = cf
	end
	p.Anchored = true
	p.Color = colour(row[11], Color3.fromRGB(142, 95, 57))
	p.Material = material(row[12])
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		if extra.nc then
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false -- ropes and signs never count as ground or wall for the car's probes
		end
		if type(extra.a) == "number" then
			p.Transparency = extra.a
		end
		if type(extra.l) == "table" then
			local l = extra.l
			local light = Instance.new("PointLight")
			light.Range = math.clamp(tonumber(l[1]) or 12, 0, 60)
			light.Brightness = tonumber(l[2]) or 1
			light.Color = colour(l[3], Color3.fromRGB(255, 200, 120))
			light.Shadows = false
			light.Parent = p
		end
	end
	if p.Material == Enum.Material.Neon then
		p.CastShadow = false
	end
	return p
end

local FACES: { [string]: Enum.NormalId } = {
	Back = Enum.NormalId.Back,
	Front = Enum.NormalId.Front,
	Left = Enum.NormalId.Left,
	Right = Enum.NormalId.Right,
	Top = Enum.NormalId.Top,
}

local function addSign(target: BasePart, sign: any)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = FACES[tostring(sign.face)] or Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.35
	gui.MaxDistance = 260
	gui.Parent = target
	local function label(text: string, y: number, h: number, color: Color3, font: Enum.Font)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromScale(0.04, y)
		l.Size = UDim2.fromScale(0.92, h)
		l.Font = font
		l.TextScaled = true
		l.TextColor3 = color
		l.Text = text
		l.Rotation = tonumber(sign.tilt) or 0
		l.Parent = gui
		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(46, 28, 16)
		s.Thickness = 3
		s.Parent = l
	end
	local title = if type(sign.title) == "string" then sign.title else nil
	local text = if type(sign.text) == "string" then sign.text else nil
	if title and text then
		label(title, 0.05, 0.56, colour(sign.titleColor, Color3.fromRGB(255, 92, 64)), Enum.Font.LuckiestGuy)
		label(text, 0.62, 0.32, colour(sign.textColor, Color3.fromRGB(255, 244, 214)), Enum.Font.GothamBlack)
	elseif title or text then
		label((title or text) :: string, 0.1, 0.8, colour(sign.titleColor, Color3.fromRGB(255, 244, 214)), Enum.Font.GothamBlack)
	end
end

local soundIds: { [string]: string }? = nil
local function soundId(cue: string): string?
	if not soundIds then
		local ids: { [string]: string } = {}
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		for _, name in { "AudioAssets", "BarrierAudio" } do -- BarrierAudio wins
			local m = shared and shared:FindFirstChild(name)
			if m and m:IsA("ModuleScript") then
				local ok, t = pcall(require, m)
				if ok and type(t) == "table" then
					for k, v in t :: any do
						if type(k) == "string" and type(v) == "string" and v ~= "" then
							ids[k] = v
						end
					end
				end
			end
		end
		soundIds = ids
	end
	return (soundIds :: { [string]: string })[cue]
end

local function addSnore(model: Model, anchor: BasePart, base: CFrame, snore: any)
	local offset = if typeof(snore.offset) == "Vector3" then snore.offset else Vector3.new(0, 12, -24)
	local att = Instance.new("Attachment")
	att.Name = "Kraken"
	att.Parent = anchor
	att.WorldCFrame = base * CFrame.new(offset) -- after parenting: WorldCFrame is relative to the parent part
	local id = if type(snore.cue) == "string" then soundId(snore.cue) else nil
	if id then
		local s = Instance.new("Sound")
		s.Name = "KrakenSnore"
		s.SoundId = id
		s.Looped = true
		s.Volume = math.clamp(tonumber(snore.volume) or 0.7, 0, 2)
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 12
		s.RollOffMaxDistance = math.clamp(tonumber(snore.rollOff) or 140, 20, 400)
		s.Parent = att
		s:Play()
	end
	if type(snore.text) == "string" then
		local bb = Instance.new("BillboardGui")
		bb.Name = "Zzz"
		bb.Size = UDim2.fromScale(9, 4.5) -- studs (no offset: it shrinks with distance like a world prop)
		bb.LightInfluence = 0
		bb.MaxDistance = 240
		bb.Parent = att
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.fromScale(1, 1)
		l.Font = Enum.Font.LuckiestGuy
		l.TextScaled = true
		l.TextColor3 = Color3.fromRGB(196, 232, 255)
		l.TextTransparency = 0.15
		l.Text = snore.text
		l.Parent = bb
	end
	model:SetAttribute("Snore", id ~= nil)
end

-- Builds every barrier of `battle` under `folder`; returns how many were built. Never errors into BattleCore.
function BattleBarriers.build(battle: any, folder: Instance): number
	local built = 0
	for _, p in BattleBarriers.plan(battle) do
		local ok, err = pcall(function()
			local model = Instance.new("Model")
			model.Name = p.name
			local anchor: BasePart? = nil
			if p.colliderCf and p.colliderSize then
				local c = Instance.new("Part")
				c.Name = "Collider"
				c.Anchored = true
				c.CanCollide = true
				c.CanQuery = true -- the car's wall rays (RespectCanCollide) stop on it
				c.CanTouch = false
				c.CastShadow = false
				c.Transparency = 1
				c.Size = p.colliderSize :: Vector3
				c.CFrame = p.colliderCf :: CFrame
				c.Parent = model
				anchor = c
			end
			local made: { BasePart } = {}
			for i, entry in p.parts do
				local part = makePart(entry.row, entry.cf)
				part.Name = "P" .. i
				part.Parent = model
				made[i] = part
			end
			for _, sign in p.signs do
				local target = if type(sign) == "table" then made[tonumber(sign.part) or 0] else nil
				if target then
					addSign(target, sign)
				end
			end
			if p.snore and anchor then
				addSnore(model, anchor, p.cf, p.snore)
			end
			model:SetAttribute("BattleOnly", true)
			model.Parent = folder
		end)
		if ok then
			built += 1
			print(string.format("[SkyRally][BATTLE] barrier %s built at (%.0f, %.0f, %.0f)", p.name, p.cf.X, p.cf.Y, p.cf.Z))
		else
			warn("[SkyRally][BATTLE] barrier " .. p.name .. " failed: " .. tostring(err))
		end
	end
	return built
end

return BattleBarriers
