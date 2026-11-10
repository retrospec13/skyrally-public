--!strict
-- Asset access probe (D19, TEST_LIST_LAUNCH L67-L68). After the scene settles, collects every content id
-- the client references (embedded MeshId/TextureID, images, sounds, rbxthumb ids) and preloads each,
-- logging per-id status. In a published client a missing Use grant shows up here as a Failure.
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")

local RunService = game:GetService("RunService")
local ProbeRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ProbeRules"))

local AssetProbe = {}

local PROPS: { [string]: { string } } = {
	MeshPart = { "MeshId", "TextureID" },
	SpecialMesh = { "MeshId", "TextureId" },
	Decal = { "Texture" },
	Texture = { "Texture" },
	Sound = { "SoundId" },
	ImageLabel = { "Image" },
	ImageButton = { "Image", "HoverImage", "PressedImage" },
	ParticleEmitter = { "Texture" },
	Beam = { "Texture" },
	Trail = { "Texture" },
	Sky = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" },
	SurfaceAppearance = { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap" },
}

local function isAvatar(inst: Instance, lp: Player): boolean
	local ch = lp.Character
	if ch and inst:IsDescendantOf(ch) then
		return true
	end
	local pg = lp:FindFirstChild("PlayerGui")
	local chat = pg and pg:FindFirstChild("Chat")
	return chat ~= nil and inst:IsDescendantOf(chat)
end

function AssetProbe.collect(): ({ [string]: string }, { [string]: Instance })
	local lp = Players.LocalPlayer
	local ids: { [string]: string } = {}
	local owners: { [string]: Instance } = {}
	local roots: { Instance } = { workspace, SoundService, Lighting }
	local pg = lp:FindFirstChild("PlayerGui")
	if pg then
		table.insert(roots, pg)
	end
	for _, r in roots do
		for _, inst in r:GetDescendants() do
			local props = PROPS[inst.ClassName]
			if props and not isAvatar(inst, lp) then
				for _, p in props do
					local ok, v = pcall(function()
						return (inst :: any)[p]
					end)
					if ok and type(v) == "string" and v ~= "" and string.find(v, "%d%d%d%d%d%d") then
						-- Built-in rbxasset:// content needs no grant; only network ids are probed.
						if string.sub(v, 1, 11) == "rbxassetid:" or string.sub(v, 1, 9) == "rbxthumb:" or string.sub(v, 1, 4) == "http" then
							if not ids[v] then
								ids[v] = inst:GetFullName() .. "." .. p
								owners[v] = inst
							end
						end
					end
				end
			end
		end
	end
	return ids, owners
end

local function engineStatus(contentId: string): string?
	-- The engine's own fetch status for content it already requested for rendering or playback.
	local ok, st = pcall(function()
		return (ContentProvider :: any):GetAssetFetchStatus(contentId)
	end)
	if ok and typeof(st) == "EnumItem" then
		return st.Name
	end
	return nil
end

function AssetProbe.run(): (number, number)
	local ids, owners = AssetProbe.collect()
	local list: { string } = {}
	local insts: { Instance } = {}
	local seenInst: { [Instance]: boolean } = {}
	for k in ids do
		table.insert(list, k)
		local o = owners[k]
		if o and not seenInst[o] then
			seenInst[o] = true
			table.insert(insts, o)
		end
	end
	table.sort(list)
	-- Preload the instances (MeshPart, Sound, ImageLabel...) so each id is fetched as its real type; a bare id
	-- string is fetched as an image, which reports Failure for meshes and audio regardless of access.
	local status: { [string]: string } = {}
	pcall(function()
		ContentProvider:PreloadAsync(insts, function(contentId: string, st: Enum.AssetFetchStatus)
			status[contentId] = st.Name
		end)
	end)
	local okN, failN = 0, 0
	local failed: { string } = {}
	for _, k in list do
		local pre = status[k] or "NoCallback"
		local eng = engineStatus(k)
		local extra = ""
		local o = owners[k]
		local good = pre == "Success" or eng == "Success"
		if o and o:IsA("Sound") then
			local snd = o :: Sound
			local t0 = os.clock()
			while not snd.IsLoaded and os.clock() - t0 < 6 do
				task.wait(0.2)
			end
			extra = string.format(" isLoaded=%s length=%.2f", tostring(snd.IsLoaded), snd.TimeLength)
			good = good or (snd.IsLoaded and snd.TimeLength > 0)
		end
		if good then
			okN += 1
		else
			failN += 1
			table.insert(failed, k)
		end
		print(string.format("[SkyRally][ASSETPROBE] %s %s preload=%s engine=%s%s at=%s", if good then "OK" else "FAIL", k, pre, tostring(eng), extra, ids[k]))
	end
	-- Presence (L68): a mesh that never loaded leaves no id to probe, so every model that should carry an approved mesh
	-- reports mesh vs FALLBACK explicitly; an unexpected fallback counts as a failure.
	local function reportState(model: Instance, state: string)
		print(string.format("[SkyRally][ASSETSTATE] %s %s", model:GetFullName(), state))
		if state ~= "mesh" then
			failN += 1
			table.insert(failed, "FALLBACK:" .. model.Name)
		end
	end
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") then
				reportState(m, if m:GetAttribute("HasTripoMesh") == true then "mesh" else "FALLBACK")
			end
		end
	end
	local maps = workspace:FindFirstChild("Maps")
	if maps then
		for _, d in maps:GetDescendants() do
			local st = d:GetAttribute("AssetState")
			if type(st) == "string" then
				reportState(d, st)
			end
		end
	end
	print(string.format("[SkyRally][ASSETPROBE] place=%d version=%d probed=%d ok=%d fail=%d", game.PlaceId, game.PlaceVersion, #list, okN, failN))
	local lp = Players.LocalPlayer
	lp:SetAttribute("AssetProbeOk", okN)
	lp:SetAttribute("AssetProbeFail", failN)
	lp:SetAttribute("AssetProbeFailed", table.concat(failed, ","))
	return okN, failN
end

function AssetProbe.init()
	-- QA accounts and Studio only (L41/L42): the sweep is a hitch and log burst on a phone player.
	if not ProbeRules.shouldRun(RunService:IsStudio(), Players.LocalPlayer.UserId) then
		return
	end
	task.delay(12, function()
		AssetProbe.run()
	end)
end

return AssetProbe
