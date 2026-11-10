-- Enumerate every content id referenced by live instances (embedded MeshId/TextureID included).
local H = game:GetService('HttpService')
local PROPS = {
	MeshPart = {'MeshId', 'TextureID'}, SpecialMesh = {'MeshId', 'TextureId'}, FileMesh = {'MeshId', 'TextureId'},
	Decal = {'Texture'}, Texture = {'Texture'}, Sound = {'SoundId'}, Animation = {'AnimationId'},
	ImageLabel = {'Image'}, ImageButton = {'Image', 'HoverImage', 'PressedImage'},
	ParticleEmitter = {'Texture'}, Beam = {'Texture'}, Trail = {'Texture'},
	Sky = {'SkyboxBk', 'SkyboxDn', 'SkyboxFt', 'SkyboxLf', 'SkyboxRt', 'SkyboxUp', 'SunTextureId', 'MoonTextureId'},
	SurfaceAppearance = {'ColorMap', 'NormalMap', 'RoughnessMap', 'MetalnessMap'},
	MaterialVariant = {'ColorMap', 'NormalMap', 'RoughnessMap', 'MetalnessMap'},
	ShirtGraphic = {'Graphic'}, Shirt = {'ShirtTemplate'}, Pants = {'PantsTemplate'},
}
local found = {}
local function add(id, inst, prop)
	if type(id) ~= 'string' or id == '' then return end
	local num = id:match('(%d%d%d%d%d+)')
	local key = num or id
	local e = found[key]
	if not e then e = {id = key, raw = id, n = 0, where = {}} found[key] = e end
	e.n += 1
	if #e.where < 3 then table.insert(e.where, inst:GetFullName() .. '.' .. prop) end
end
local roots = {workspace, game:GetService('ReplicatedStorage'), game:GetService('Lighting'), game:GetService('SoundService'), game:GetService('StarterGui'), game:GetService('MaterialService')}
local ok, lp = pcall(function() return game:GetService('Players').LocalPlayer end)
if ok and lp then
	local pg = lp:FindFirstChild('PlayerGui') if pg then table.insert(roots, pg) end
	local ps = lp:FindFirstChild('PlayerScripts') if ps then table.insert(roots, ps) end
end
pcall(function() table.insert(roots, game:GetService('ServerStorage')) end)
-- Player avatars and core chat UI are the player's/Roblox's, not the game's; they are excluded.
local skip = {}
for _, pl in game:GetService('Players'):GetPlayers() do
	if pl.Character then table.insert(skip, pl.Character) end
	local pg = pl:FindFirstChild('PlayerGui')
	if pg and pg:FindFirstChild('Chat') then table.insert(skip, pg.Chat) end
end
local function skipped(inst)
	for _, s in skip do if inst:IsDescendantOf(s) then return true end end
	return false
end
for _, r in roots do
	for _, inst in r:GetDescendants() do
		local props = PROPS[inst.ClassName]
		if props and not skipped(inst) then
			for _, p in props do
				local okp, v = pcall(function() return (inst :: any)[p] end)
				if okp then
					if typeof(v) == 'Content' then v = v.Uri end
					add(v, inst, p)
				end
			end
		end
	end
end
local list = {}
for _, e in found do table.insert(list, e) end
return H:JSONEncode(list)
