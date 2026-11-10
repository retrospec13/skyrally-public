--!strict
-- Backdrop shells (visibility v1; rules and the why in shared/BackdropRules, generator tools/map/backdrop.py): builds
-- TrackData.backdrop as plain parts under <map root>.Backdrop. Purely visual: Anchored, never collides, never a raycast
-- or touch target, no shadow, massless, no children (so LightLod and MapFxLod, which only collect lights and
-- emitters, never see them) and tagged "Backdrop" (never MapLight / MapFx). Owner rule: wall/mountain driving,
-- terrain, barriers, kill volumes, rescue and course bounds are untouched.
local BackdropRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("BackdropRules"))

local Backdrop = {}

export type Deps = {
	new: (className: string) -> any,
	tag: (inst: any) -> (),
	material: (name: string) -> any,
	color: (hex: string) -> any,
	smooth: any,
}

local function defaultDeps(): Deps
	local CollectionService = game:GetService("CollectionService")
	return {
		new = function(className: string): any
			return Instance.new(className :: any)
		end,
		tag = function(inst: any)
			CollectionService:AddTag(inst, BackdropRules.TAG)
		end,
		material = function(name: string): any
			local ok, m = pcall(function()
				return (Enum.Material :: any)[name]
			end)
			return if ok and m then m else Enum.Material.SmoothPlastic
		end,
		color = function(hex: string): any
			local ok, c = pcall(Color3.fromHex, hex)
			return if ok then c else Color3.new(0.5, 0.5, 0.5)
		end,
		smooth = Enum.SurfaceType.Smooth,
	}
end

-- Builds every entry into `folder`; returns the number of parts made. A bad entry is skipped with a warning.
function Backdrop.build(td: any, folder: any, deps: Deps?): number
	local d = deps or defaultDeps()
	local list = td.backdrop
	if type(list) ~= "table" then
		return 0
	end
	local n = 0
	for i, e in list do
		local ok, err = pcall(function()
			local props = BackdropRules.props(e, td.materials)
			local p = d.new(BackdropRules.className(e))
			for k, v in props do
				if k == "Material" then
					p.Material = d.material(v)
				elseif k == "Color" then
					p.Color = d.color(v)
				elseif k == "TopSurface" or k == "BottomSurface" then
					p[k] = d.smooth
				elseif k ~= "Size" and k ~= "CFrame" then
					p[k] = v
				end
			end
			-- Size before CFrame (a resize keeps the centre), parent last
			p.Size = props.Size
			p.CFrame = props.CFrame
			p:SetAttribute("Backdrop", e.kind)
			d.tag(p)
			p.Parent = folder
		end)
		if ok then
			n += 1
		else
			warn(string.format("[SkyRally][MAP] backdrop[%d] %s: %s", i, tostring(e.name), tostring(err)))
		end
	end
	return n
end

return Backdrop
