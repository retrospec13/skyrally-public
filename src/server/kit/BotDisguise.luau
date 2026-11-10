--!strict
-- Economy v3 phase 4 (bots pass as players), server side: deals a race or battle bot its generated username, pilot
-- outfit and Garage cosmetics, and writes them on the vehicle model. The rules are shared/BotNames, BotNamePoolRules and
-- BotLookRules (Lune-tested); the name pool is server/BotNamePool. Gated by PlaneConfig.BOT_DISGUISE in the callers.
--
-- Model attributes written: BotName (the shown name), BotKey (the roster name: internal lookups), PilotOutfit and
-- PilotSkin (read by kit/PilotSeat when the pilot is seated), CosmeticTrail (read by client/Vfx where a player's equipped
-- trail would be). The livery goes through RacerPaint.paintBot.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotLookRules = require(Shared:WaitForChild("BotLookRules"))
local BotNames = require(Shared:WaitForChild("BotNames"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))

local BotDisguise = {}

export type Look = BotLookRules.Look

-- server/BotNamePool is optional: without it a bot takes a fresh unchecked long name that nothing rechecks.
local poolModule: any = nil
local poolTried = false
local function pool(): any
	if not poolTried then
		poolTried = true
		local ok, mod = pcall(function(): any
			return require(script.Parent.Parent.BotNamePool)
		end)
		poolModule = if ok and type(mod) == "table" then mod else nil
	end
	return poolModule
end

local rng = BotNames.rng(math.floor(os.clock() * 1000) % 2147483647 + math.random(1, 1000000))

-- Lower-case names in use: the given bots' and every human's (account and display name).
local function namesInUse(bots: { { name: string } }): { [string]: boolean }
	local used: { [string]: boolean } = {}
	for _, b in bots do
		used[string.lower(b.name)] = true
	end
	for _, p in Players:GetPlayers() do
		for _, n in { p.Name, p.DisplayName } do
			if type(n) == "string" then
				used[string.lower(n)] = true
			end
		end
	end
	return used
end

-- A username and a look for one new bot. `bots`: the bots already on the field ({ name, plane }): the name and the
-- outfit differ from theirs. Third result false = the name is not vouched for (pool dry): pass it to recheck().
function BotDisguise.deal(bots: { any }): (string, Look, boolean)
	local used = namesInUse(bots)
	local p = pool()
	local name: string, checked: boolean
	if p then
		name, checked = p.take(used)
	else
		name, checked = BotNames.makeLong(rng, used), false
	end
	local outfits: { [string]: boolean } = {}
	for _, b in bots do
		local plane = b.plane
		local o = if plane then plane:GetAttribute("PilotOutfit") else nil
		if type(o) == "string" then
			outfits[o] = true
		end
	end
	local liveries = BotLookRules.wearable(MonetizationConfig.COSMETICS, "livery")
	local trails = BotLookRules.wearable(MonetizationConfig.COSMETICS, "trail")
	local look = BotLookRules.deal(rng, 1, liveries, trails)[1]
	for _ = 1, 12 do
		if not outfits[look.outfit] then
			break
		end
		look = BotLookRules.deal(rng, 1, liveries, trails)[1]
	end
	return name, look, checked
end

function BotDisguise.setNames(model: Model, displayName: string, rosterName: string)
	model:SetAttribute("BotName", displayName)
	model:SetAttribute("BotKey", rosterName) -- internal: personality, livery colour and palette lookups
end

-- Before the pilot is attached (PilotSeat reads these when it seats the pilot, one frame later).
function BotDisguise.setLook(model: Model, look: Look)
	model:SetAttribute("PilotOutfit", look.outfit)
	model:SetAttribute("PilotSkin", look.skin)
	if look.trail then
		model:SetAttribute("CosmeticTrail", look.trail)
	end
end

-- Background check of an unvouched name; swap(newName) renames the bot if it is somebody's account.
function BotDisguise.recheck(name: string, swap: (string) -> ())
	local p = pool()
	if p then
		p.recheck(name, swap)
	end
end

return BotDisguise
