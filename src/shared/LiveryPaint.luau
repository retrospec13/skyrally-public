--!strict
-- Paints a vehicle with a livery (MONETIZATION_PROPOSAL 2a; Garage). Shared (REMARKABLE Batch 2 item 27: the livery
-- palette moved here from server/kit so the Garage turntable can try a livery on its own display copy, client-side):
-- the server paints the real vehicle (server/kit/LiveryPaint re-exports this module, so every client sees it), the
-- client only ever paints copies it owns. Works on the models PlaneBuilder.createPlane / CarBuilder.createCar return
-- (and their clones): parts are found by name
-- (GarageModel.PART_ROLES) and the builder's own colour and material are kept as attributes on first paint, so
-- unequipping restores the default palette exactly. The textured hero mesh is tinted (MeshPart.Color and, where the
-- engine has it, SurfaceAppearance.Color); flat parts take the livery's primary / accent / trim.
local GarageModel = require(script.Parent:WaitForChild("GarageModel"))
local RacerPaletteRules = require(script.Parent:WaitForChild("RacerPaletteRules"))

local LiveryPaint = {}

local function color(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function material(name: string, fallback: Enum.Material): Enum.Material
	local ok, m = pcall(function(): any
		return (Enum.Material :: any)[name]
	end)
	return if ok and m then m else fallback
end

-- SurfaceAppearance.Color multiplies the colour map; pcall keeps an engine without the property (or a locked
-- appearance) from failing the build.
local function tintAppearance(part: BasePart, c: Color3)
	local sa = part:FindFirstChildOfClass("SurfaceAppearance")
	if sa then
		pcall(function()
			(sa :: any).Color = c
		end)
	end
end

-- The default racer palette a vehicle wears when no livery is equipped (model attribute RacerPalette, set on spawn by
-- LiveryPaint.applyPalette): same shape as GarageModel.liveryPaint, plain finish.
local function palettePaint(model: Model): GarageModel.LiveryPaint?
	local pal = RacerPaletteRules.byId(model:GetAttribute("RacerPalette") :: string?)
	if not pal then
		return nil
	end
	return {
		meshTint = pal.meshTint,
		primary = pal.primary,
		accent = pal.accent,
		trim = pal.trim,
		material = "SmoothPlastic",
		trimMaterial = "SmoothPlastic",
	}
end

-- key = a livery cosmetic key, or nil / "" for the racer's default palette (or the builder's own colours when the model
-- has no RacerPalette, e.g. the Garage turntable's display copy). An equipped livery always wins over the palette.
function LiveryPaint.apply(model: Model, key: string?)
	local item = GarageModel.cosmetic(key)
	local style = if item and item.kind == "livery" then item.livery else nil
	local livery = if style then GarageModel.liveryPaint(style) else nil
	local paint = livery or palettePaint(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local role = GarageModel.partRole(d.Name)
			if role then
				if d:GetAttribute("LiveryBaseColor") == nil then
					d:SetAttribute("LiveryBaseColor", d.Color)
					d:SetAttribute("LiveryBaseMaterial", d.Material.Name)
				end
				local baseColor = d:GetAttribute("LiveryBaseColor")
				local baseMaterial = material(tostring(d:GetAttribute("LiveryBaseMaterial")), d.Material)
				if paint then
					if role == "mesh" then
						local tint = color(paint.meshTint)
						d.Color = tint
						tintAppearance(d, tint)
					else
						d.Color = color((paint :: any)[role])
						-- Finish: body panels follow it; trim pieces only change for Metal / Neon so wooden props stay wood.
						if role == "primary" then
							d.Material = material(paint.material, baseMaterial)
						elseif paint.trimMaterial ~= "SmoothPlastic" then
							d.Material = material(paint.trimMaterial, baseMaterial)
						else
							d.Material = baseMaterial
						end
					end
				else
					if typeof(baseColor) == "Color3" then
						d.Color = baseColor
					end
					d.Material = baseMaterial
					if role == "mesh" then
						tintAppearance(d, Color3.new(1, 1, 1))
					end
				end
			end
		end
	end
	model:SetAttribute("Livery", if livery then key else "")
end

-- Gives a vehicle its default racer palette and paints it (a livery key, when given, still wins). The builder's base
-- colours stay in the LiveryBase* attributes, so Garage equip / unequip restores correctly: unequip falls back to this
-- palette. Sets RacerPalette (id) and RacerColor (the identity Color3) on the model.
function LiveryPaint.applyPalette(model: Model, palette: RacerPaletteRules.Palette, key: string?)
	model:SetAttribute("RacerPalette", palette.id)
	model:SetAttribute("RacerColor", RacerPaletteRules.color3(palette.identity))
	LiveryPaint.apply(model, key)
end

-- The livery slot a vehicle model reads (each vehicle keeps its own).
function LiveryPaint.slotFor(model: Model): string
	return if model:GetAttribute("IsCar") == true then "carLivery" else "planeLivery"
end

-- Paints a player's vehicle from their replicated loadout (player attribute Equipped, set by SaveService).
function LiveryPaint.applyFor(player: Player, model: Model)
	local loadout = GarageModel.decodeLoadout(player:GetAttribute("Equipped"))
	local item = GarageModel.equipped(loadout, LiveryPaint.slotFor(model))
	LiveryPaint.apply(model, if item then item.key else nil)
end

return LiveryPaint
