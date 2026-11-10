--!strict
-- Per-map Lighting profiles (MAP_PLAN_SCHEMA: plans carry no `lighting` table; the adapter applies one of these by id).
-- apply(id) is idempotent: it sets the listed Lighting properties and replaces only `SkyRally_*` children, so the
-- game's own post stack and anything another system parents to Lighting survive a map rebuild.

local Lighting = game:GetService("Lighting")

local LightingProfiles = {}

-- Ordered { property, value } pairs so a profile applies in the same order as the code it was ported from.
export type PropList = { { any } }
export type Effect = { className: string, name: string, props: PropList }
-- `sky` names a module in shared/sky (uploaded faces { up, side, down }); apply() adds SkyRally_Sky from it.
-- Optional `skyFaces` puts other images of that module on single side faces ({ Ft = "earthface" }: Ft looks north
-- (-Z), Lf east (+X), Bk south, Rt west), and `skyProps` sets further Sky properties ({ "StarCount", 0 }; a string
-- value "@name" is that module's image, "@module:name" an image of another shared/sky module, so a map can borrow a
-- sky set and keep one of its own already-uploaded discs).
export type Profile = { lighting: PropList, effects: { Effect }, sky: string?, skyFaces: { [string]: string }?, skyProps: PropList? }

local PREFIX = "SkyRally_"

-- Every map's profile lives in shared/lighting/<map>.luau (DINO-4 moved there in the L61 grade pass).
LightingProfiles.profiles = {
} :: { [string]: Profile }

-- Per-map profiles also load from shared/lighting/<map>.luau (each returns { [mapId] = Profile }), so map authors add
-- a file instead of editing this one.
do
	local folder = script.Parent:FindFirstChild("lighting")
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("ModuleScript") then
				local ok, t = pcall(require, m)
				if ok and type(t) == "table" then
					for id, prof in t :: { [string]: any } do
						LightingProfiles.profiles[id] = prof
					end
				else
					warn(string.format("[SkyRally][LIGHTING] profile module %s failed: %s", m.Name, tostring(t)))
				end
			end
		end
	end
end

function LightingProfiles.has(id: string): boolean
	return LightingProfiles.profiles[id] ~= nil
end

function LightingProfiles.get(id: string): Profile?
	return LightingProfiles.profiles[id]
end

-- Returns true when the profile exists and every property applied; an unknown id changes nothing.
function LightingProfiles.apply(id: string): boolean
	local profile = LightingProfiles.profiles[id]
	if not profile then
		warn(string.format("[SkyRally][LIGHTING] unknown profile %s; Lighting left unchanged", tostring(id)))
		return false
	end
	local allOk = true
	for _, pair in profile.lighting do
		local key = pair[1] :: string
		local ok, err = pcall(function()
			(Lighting :: any)[key] = pair[2]
		end)
		if not ok then
			allOk = false
			warn(string.format("[SkyRally][LIGHTING] %s Lighting.%s: %s", id, key, tostring(err)))
		end
	end

	for _, child in Lighting:GetChildren() do
		if string.match(child.Name, "^SkyRally_") then
			child:Destroy()
		end
	end

	for _, effect in profile.effects do
		-- Never create anything outside the SkyRally_ namespace: that is what makes the cleanup above safe.
		if string.sub(effect.name, 1, #PREFIX) ~= PREFIX then
			allOk = false
			warn(string.format("[SkyRally][LIGHTING] %s effect %s skipped: name must start with %s", id, effect.name, PREFIX))
			continue
		end
		local ok, err = pcall(function()
			local inst = Instance.new(effect.className :: any)
			inst.Name = effect.name
			for _, pair in effect.props do
				(inst :: any)[pair[1] :: string] = pair[2]
			end
			inst.Parent = Lighting
		end)
		if not ok then
			allOk = false
			warn(string.format("[SkyRally][LIGHTING] %s effect %s: %s", id, effect.name, tostring(err)))
		end
	end
	if profile.sky then
		local skyFolder = script.Parent:FindFirstChild("sky")
		local m = skyFolder and skyFolder:FindFirstChild(profile.sky)
		local ok, faces = pcall(function()
			return require(m :: ModuleScript) :: any
		end)
		if ok and type(faces) == "table" and faces.side then
			local sky = Instance.new("Sky")
			sky.Name = "SkyRally_Sky"
			sky.SkyboxBk, sky.SkyboxFt, sky.SkyboxLf, sky.SkyboxRt = faces.side, faces.side, faces.side, faces.side
			sky.SkyboxUp, sky.SkyboxDn = faces.up or faces.side, faces.down or faces.side
			sky.CelestialBodiesShown = true
			local skyFaces: { [string]: string } = profile.skyFaces or {}
			for face, image in skyFaces do
				if faces[image] then
					(sky :: any)["Skybox" .. face] = faces[image]
				else
					allOk = false
					warn(string.format("[SkyRally][LIGHTING] %s sky face %s: no image %s", id, face, image))
				end
			end
			local skyProps: PropList = profile.skyProps or {}
			for _, pair in skyProps do
				local value = pair[2]
				if type(value) == "string" and string.sub(value, 1, 1) == "@" then
					local other, image = string.match(value, "^@([%w_]+):([%w_]+)$")
					if other and image then
						local om = skyFolder and skyFolder:FindFirstChild(other)
						local okOther, otherFaces = pcall(function()
							return require(om :: ModuleScript) :: any
						end)
						value = if okOther and type(otherFaces) == "table" then otherFaces[image] else nil
					else
						value = faces[string.sub(value, 2)]
					end
				end
				local okProp, errProp = pcall(function()
					(sky :: any)[pair[1] :: string] = value
				end)
				if not okProp then
					allOk = false
					warn(string.format("[SkyRally][LIGHTING] %s Sky.%s: %s", id, tostring(pair[1]), tostring(errProp)))
				end
			end
			sky.Parent = Lighting
		else
			allOk = false
			warn(string.format("[SkyRally][LIGHTING] %s sky %s missing: %s", id, tostring(profile.sky), tostring(faces)))
		end
	end
	print(string.format("[SkyRally][LIGHTING] applied %s ok=%s", id, tostring(allOk)))
	return allOk
end

return LightingProfiles
