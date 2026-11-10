--!nocheck
-- Model bakes (texpack fix 2026-10-19, docs/ASSETS.md "Model bakes"): build/model_bakes/manifest.json, the .rbxm files
-- next to it and default.project.json's ServerStorage.ModelBakes agree (every bake listed, mounted under its id, sha256
-- matching, every SurfaceAppearance carrying a non-empty TexturePack equal to the manifest's packs), and the runtime
-- (src/shared/ModelBakes) prefers a mounted bake over InsertService:LoadAsset and is the only place src/ calls LoadAsset.
-- Rerun tools/bake_models.py in the lane Studio after any model re-upload.
-- Standalone Lune script, run from the repo root by tools/tests/run_lune_tests.sh.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local failures = 0
local function check(ok: boolean, msg: string)
	if ok then
		print("  PASS " .. msg)
	else
		failures += 1
		print("  FAIL " .. msg)
	end
end

local DIR = "build/model_bakes"
local manifest = serde.decode("json", fs.readFile(DIR .. "/manifest.json"))
local project = serde.decode("json", fs.readFile("default.project.json"))
local node = project.tree.ServerStorage and project.tree.ServerStorage.ModelBakes
check(type(node) == "table" and node["$className"] == "Folder", "default.project.json mounts ServerStorage.ModelBakes as a Folder")
node = node or {}

-- 1. Every .rbxm in the directory is in the manifest, and every manifest row has its file and its mount.
local files = {}
for _, name in fs.readDir(DIR) do
	local id = string.match(name, "^(%d+)%.rbxm$")
	if id then
		files[id] = true
		check(manifest[id] ~= nil, DIR .. "/" .. name .. " is listed in manifest.json (rerun tools/bake_models.py or delete it)")
	end
end
for name, child in node do
	if string.sub(name, 1, 1) ~= "$" then
		check(manifest[name] ~= nil and type(child) == "table" and child["$path"] == DIR .. "/" .. name .. ".rbxm",
			"ServerStorage.ModelBakes." .. name .. " mounts " .. DIR .. "/" .. name .. ".rbxm and is in the manifest")
	end
end

local ids = {}
for id in manifest do
	table.insert(ids, id)
end
table.sort(ids)
for _, id in ids do
	local row = manifest[id]
	local path = DIR .. "/" .. id .. ".rbxm"
	check(string.match(id, "^%d+$") ~= nil, id .. ": manifest key is a model id")
	check(files[id] == true, id .. ": " .. path .. " exists")
	check(node[id] ~= nil, id .. ": mounted as ServerStorage.ModelBakes." .. id)
	if not files[id] then
		continue
	end
	local bytes = fs.readFile(path)
	check(serde.hash("sha256", bytes) == row.sha256, id .. ": sha256 matches the manifest")
	local roots = roblox.deserializeModel(bytes)
	check(#roots == 1, id .. ": the bake holds one root (rojo mounts it as the instance named " .. id .. ")")
	local packs = {}
	local empty = 0
	for _, r in roots do
		local list = r:GetDescendants()
		table.insert(list, 1, r)
		for _, d in list do
			if d.ClassName == "SurfaceAppearance" then
				local ok, c = pcall(function()
					-- Lune's current reflection migrates saved ContentId fields to Content.
					return d.TexturePackContent.Uri
				end)
				local n = tonumber(string.match(if ok and c ~= nil then tostring(c) else "", "(%d+)$") or "")
				if n then
					table.insert(packs, n)
				else
					empty += 1
				end
			end
		end
	end
	if row.toolbox then
		-- Creator Store stand-in (tools/bake_toolbox.py, docs/ASSETS_TOOLBOX_TEMP.md): no SurfaceAppearance, and nothing that can run
		-- code or off the strip allow list (Model / Part / MeshPart / UnionOperation / legacy meshes / our own ParticleEmitter + Attachment)
		local ALLOW = { Model = true, Folder = true, Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, SpecialMesh = true,
			CylinderMesh = true, BlockMesh = true, ParticleEmitter = true, Attachment = true }
		local classes, bad, scripts = 0, {}, 0
		for _, r in roots do
			local all = r:GetDescendants()
			table.insert(all, 1, r)
			for _, d in all do
				classes += 1
				if not ALLOW[d.ClassName] then
					table.insert(bad, d.ClassName)
				end
				if d:IsA("LuaSourceContainer") or string.find(d.ClassName, "Script", 1, true) or string.find(d.ClassName, "Module", 1, true) then
					scripts += 1
				end
				check(next(d:GetAttributes()) == nil, id .. ": " .. d.Name .. " carries no attributes")
			end
		end
		check(scripts == 0, id .. ": toolbox bake holds no script instances")
		check(#bad == 0, id .. ": toolbox bake holds only allow-listed classes " .. table.concat(bad, ","))
		check(#packs + empty == 0 and row.surfaceAppearances == 0 and #(row.packs or {}) == 0, id .. ": toolbox bake has no SurfaceAppearance")
		check(type(row.creator) == "string" and type(row.creator_id) == "number", id .. ": toolbox row names its creator")
		continue
	end
	check(#packs + empty == row.surfaceAppearances and #packs > 0, string.format("%s: %d SurfaceAppearances as recorded", id, #packs + empty))
	check(empty == 0, id .. ": every SurfaceAppearance carries a TexturePack")
	local same = #packs == #(row.packs or {})
	for i, p in packs do
		same = same and row.packs[i] == p
	end
	check(same, id .. ": TexturePack ids equal the manifest's packs (numbers the asset preflight grants)")
end

-- 2. Runtime: ModelBakes.load prefers the mounted bake, falls back to LoadAsset, and nothing else in src/ loads assets.
local loaded = {}
local env = setmetatable({
	game = {
		GetService = function(_, name)
			error("ModelBakes must not reach " .. name .. " when injected")
		end,
	},
	print = function() end,
}, { __index = _G })
local ModelBakes = luau.load(fs.readFile("src/shared/ModelBakes.luau"), { debugName = "ModelBakes", environment = env })()
local folder = roblox.Instance.new("Folder")
local baked = roblox.Instance.new("Model")
baked.Name = "111843268690922"
local sa = roblox.Instance.new("SurfaceAppearance")
sa.Parent = baked
baked.Parent = folder
ModelBakes._inject(folder, function(id)
	table.insert(loaded, id)
	local m = roblox.Instance.new("Model")
	m.Name = "Inserted"
	return m
end)
local a = ModelBakes.load(111843268690922)
check(a ~= baked and a.Name == "111843268690922" and a:FindFirstChildOfClass("SurfaceAppearance") ~= nil and #loaded == 0,
	"load(id) returns a clone of the mounted bake without calling LoadAsset")
check(a.Parent == nil and baked.Parent == folder, "the bake itself stays in ServerStorage.ModelBakes")
local b = ModelBakes.load(95757652390974)
check(b.Name == "Inserted" and loaded[1] == 95757652390974, "an id without a bake falls back to InsertService:LoadAsset")
check(ModelBakes.has(111843268690922) and not ModelBakes.has(95757652390974), "has(id) reports mounted bakes")

-- ModelBakeSources: on the server each id is appended once ("<id>=<source>"). A stand-in game whose RunService says
-- IsServer records the attribute on a stand-in ReplicatedStorage.
local attrs = {}
local rs = {
	GetAttribute = function(_, k)
		return attrs[k]
	end,
	SetAttribute = function(_, k, v)
		attrs[k] = v
	end,
}
local serverEnv = setmetatable({
	game = {
		GetService = function(_, name)
			if name == "RunService" then
				return { IsServer = function() return true end }
			elseif name == "ReplicatedStorage" then
				return rs
			end
			error("unexpected service " .. name)
		end,
	},
	print = function() end,
}, { __index = _G })
local Server = luau.load(fs.readFile("src/shared/ModelBakes.luau"), { debugName = "ModelBakes", environment = serverEnv })()
local sFolder = roblox.Instance.new("Folder")
local sBaked = roblox.Instance.new("Model")
sBaked.Name = "111843268690922"
sBaked.Parent = sFolder
Server._inject(sFolder, function()
	return roblox.Instance.new("Model")
end)
Server.load(111843268690922)
Server.load(111843268690922)
Server.load(95757652390974)
check(attrs.ModelBakeSources == "111843268690922=bake,95757652390974=insert",
	"server appends one ModelBakeSources entry per id: " .. tostring(attrs.ModelBakeSources))

local function walk(dir, out)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			walk(p, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, p)
		end
	end
	return out
end
local offenders = {}
for _, p in walk("src", {}) do
	if p ~= "src/shared/ModelBakes.luau" then
		for n, line in string.split(fs.readFile(p), "\n") do
			local code = string.match(line, "^(.-)%-%-") or line
			if string.find(code, ":LoadAsset(", 1, true) then
				table.insert(offenders, p .. ":" .. n)
			end
		end
	end
end
check(#offenders == 0, "src/ loads models only through ModelBakes.load (" .. table.concat(offenders, ", ") .. ")")

print(string.format("model_bakes: %d bakes, %d failures", #ids, failures))
process.exit(if failures == 0 then 0 else 1)
