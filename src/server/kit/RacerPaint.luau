--!strict
-- Server side of the default racer colours (shared/RacerPaletteRules): picks a palette per racer on spawn, paints it
-- through shared/LiveryPaint (a Garage livery still wins the vehicle paint), sets the RacerPalette / RacerColor model
-- attributes the client cues read, and builds the two physical cues from crisp block parts:
--   * RacerAntenna + RacerPennant: a slim mast with a thin painted flag in the racer colour, on the hull's right rear. The flag
--     is a sliver edge-on to the chase camera (0.12 studs wide from behind), so it never blocks the view down the road.
--   * RacerGlow: an invisible part under the hull carrying a PointLight, DISABLED here; client/RacerView switches it on
--     for dark maps only (SPACE-4, DINO-4) and never under LOW GRAPHICS.
-- None of these part names are in GarageModel.PART_ROLES, so a livery never repaints them. Cost: three welded parts and
-- one light per racer, built once at spawn; nothing runs per frame.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RacerPaletteRules = require(Shared:WaitForChild("RacerPaletteRules"))
local LiveryPaint = require(Shared:WaitForChild("LiveryPaint"))
local CarConfig = require(Shared:WaitForChild("CarConfig"))

local RacerPaint = {}

local function block(name: string, size: Vector3, color: Color3, material: Enum.Material, transparency: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weld(part: BasePart, hull: BasePart, offset: CFrame)
	part.CFrame = hull.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = hull
	w.Part1 = part
	w.Parent = part
end

-- Pennant and underglow in the palette's identity colour. Idempotent: a second call recolours what is there.
function RacerPaint.attachMarks(model: Model, palette: RacerPaletteRules.Palette)
	local hull = model.PrimaryPart
	if not hull then
		return
	end
	local identity = RacerPaletteRules.color3(palette.identity)
	local flag = model:FindFirstChild("RacerPennant")
	if flag and flag:IsA("BasePart") then
		flag.Color = identity
		local glow = model:FindFirstChild("RacerGlow")
		local light = if glow then glow:FindFirstChildOfClass("PointLight") else nil
		if light then
			light.Color = identity
		end
		return
	end
	local isCar = model:GetAttribute("IsCar") == true
	local base: Vector3, glowY: number
	if isCar then
		local hs = CarConfig.HULL_SIZE
		base = Vector3.new(hs[1] * 0.36, hs[2] * 0.5, hs[3] * 0.5 - 1.2)
		glowY = -hs[2] * 0.5
	else
		-- Hero plane mesh (hull space, measured in Studio 2026-10-20): the right half of the horizontal tailplane tops out at
		-- about y 0.5 and spans z 5.2..7.4, so the mast stands ON it (1.3 off the fin) and the flag streams aft over it.
		-- The old base (y 1.5, z 4.2) hung ~1 stud above the tailplane and ahead of it, over nothing.
		base = Vector3.new(1.3, 0.45, 6.0)
		glowY = -2.2
	end
	local mastH = 1.7
	local mast = block("RacerAntenna", Vector3.new(0.14, mastH, 0.14), Color3.fromRGB(40, 36, 36), Enum.Material.Metal, 0, model)
	weld(mast, hull, CFrame.new(base + Vector3.new(0, mastH * 0.5 - 0.1, 0)))
	-- v28 W1.27: a painted cloth pennant (SmoothPlastic, smaller), not a Neon sliver: edge-on from the chase camera the 0.75-stud
	-- neon flag read as a yellow bar on the wing in every capture.
	local fl = block("RacerPennant", Vector3.new(0.1, 0.5, 1.1), identity, Enum.Material.SmoothPlastic, 0, model)
	weld(fl, hull, CFrame.new(base + Vector3.new(0, mastH - 0.4, 0.55)))
	local glow = block("RacerGlow", Vector3.new(0.4, 0.4, 0.4), identity, Enum.Material.SmoothPlastic, 1, model)
	weld(glow, hull, CFrame.new(0, glowY, 0))
	local light = Instance.new("PointLight")
	light.Name = "RacerGlowLight"
	light.Color = identity
	light.Range = 15
	light.Brightness = 1.1
	light.Shadows = false
	light.Enabled = false -- RacerView turns it on for dark maps (not under LOW GRAPHICS)
	light.Parent = glow
end

-- Palette ids other racers in workspace.Planes already wear (skipping `except`'s own model).
local function takenIds(except: Model?): { [string]: boolean }
	local taken: { [string]: boolean } = {}
	local folder = workspace:FindFirstChild("Planes")
	if folder then
		for _, m in folder:GetChildren() do
			if m ~= except then
				local id = m:GetAttribute("RacerPalette")
				if type(id) == "string" then
					taken[id] = true
				end
			end
		end
	end
	return taken
end

-- A bot (race, battle): its signature palette, by roster name.
-- liveryKey (economy v3 phase 4: bots dress like players): a Garage livery the bot wears over its palette, nil = palette only.
function RacerPaint.paintBot(model: Model, botName: string, liveryKey: string?)
	local pal = RacerPaletteRules.forBot(botName)
	-- Cosmetic only: a failure here must never cost a bot its spawn.
	local ok, err = pcall(function()
		LiveryPaint.applyPalette(model, pal, liveryKey)
		RacerPaint.attachMarks(model, pal)
	end)
	if not ok then
		warn("[SkyRally][RacerPaint] bot paint failed: " .. tostring(err))
	end
end

-- A player's vehicle: the palette for their grid slot (none already worn in this race), then their equipped livery on
-- top (the livery wins the vehicle paint; the palette stays the identity colour).
function RacerPaint.paintPlayer(player: Player, model: Model, slot: number)
	local pal = RacerPaletteRules.forPlayer(slot, takenIds(model))
	model:SetAttribute("RacerPalette", pal.id)
	model:SetAttribute("RacerColor", RacerPaletteRules.color3(pal.identity))
	LiveryPaint.applyFor(player, model)
	RacerPaint.attachMarks(model, pal)
end

return RacerPaint
