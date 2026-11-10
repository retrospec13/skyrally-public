--!strict
-- Random Roblox-style pilot outfits and cosmetic picks for race bots (economy v3 phase 4: bots pass as players). Pure:
-- the catalog item ids are the Roblox-owned, free, for-sale items server/kit/PilotSeat already uses for its seven
-- presets (checked 2026-10-19), recombined here, so no item is new and no real user's avatar is ever copied. Specced in
-- tools/tests/bot_looks_spec.luau.
--
-- A look = an outfit (hat or hair, shirt, pants: one catalog combination, encoded in a key PilotSeat parses back), a
-- skin tone, and optionally a livery and a trail from the Garage catalog. Bots only wear shop-grade cosmetics (common
-- or rare, bought with Cash or in the S1 set): never the earned-only rows (Win Pass, Founder, daily, exclusive), so the
-- top tier still looks rare when a real player wears it.
local BotLookRules = {}

BotLookRules.SKINS = table.freeze({
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(255, 204, 153),
	Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(124, 92, 70),
	Color3.fromRGB(175, 148, 131),
	Color3.fromRGB(160, 95, 53),
	Color3.fromRGB(245, 205, 48),
	Color3.fromRGB(240, 213, 160),
	Color3.fromRGB(218, 134, 122),
	Color3.fromRGB(149, 121, 105),
	Color3.fromRGB(105, 64, 40),
	Color3.fromRGB(253, 234, 141),
}) :: { Color3 }

-- Head items: slot "hat" (HatAccessory) or "hair" (HairAccessory); id 0 = bare head.
BotLookRules.HEADS = table.freeze({
	{ slot = "none", id = 0 },
	{ slot = "hat", id = 48474313 },
	{ slot = "hat", id = 607702162 },
	{ slot = "hat", id = 1772336109 },
	{ slot = "hair", id = 2956239660 },
	{ slot = "hair", id = 451221329 },
	{ slot = "hair", id = 376548738 },
	{ slot = "hair", id = 63690008 },
}) :: { { slot: string, id: number } }

BotLookRules.SHIRTS = table.freeze({ 4047884046, 144076358, 382538059, 398633584, 144076436 }) :: { number }
BotLookRules.PANTS = table.freeze({ 382537569, 144076760, 398635338 }) :: { number }

export type Look = {
	outfit: string, -- "o:<slot><headId>:<shirt>:<pants>"
	skin: Color3,
	livery: string?, -- Garage livery key
	trail: string?, -- Garage trail key
}

export type Outfit = { hat: number?, hair: number?, shirt: number, pants: number }

function BotLookRules.outfitKey(head: { slot: string, id: number }, shirt: number, pants: number): string
	return string.format("o:%s%d:%d:%d", head.slot, head.id, shirt, pants)
end

local function inList(list: { number }, v: number): boolean
	return table.find(list, v) ~= nil
end

-- The outfit a key spells, or nil for anything that is not one of ours (only catalogued ids parse).
function BotLookRules.parseOutfit(key: any): Outfit?
	if type(key) ~= "string" then
		return nil
	end
	local slot, headId, shirt, pants = string.match(key, "^o:(%a+)(%d+):(%d+):(%d+)$")
	if not slot then
		return nil
	end
	local h, s, p = tonumber(headId) :: number, tonumber(shirt) :: number, tonumber(pants) :: number
	if not inList(BotLookRules.SHIRTS, s) or not inList(BotLookRules.PANTS, p) then
		return nil
	end
	local out: Outfit = { shirt = s, pants = p }
	if slot == "none" and h == 0 then
		return out
	end
	for _, head in BotLookRules.HEADS do
		if head.slot == slot and head.id == h then
			if slot == "hat" then
				out.hat = h
			else
				out.hair = h
			end
			return out
		end
	end
	return nil
end

BotLookRules.OUTFIT_COUNT = #BotLookRules.HEADS * #BotLookRules.SHIRTS * #BotLookRules.PANTS

-- Chance a bot wears a Garage livery / a trail (a field where nobody has either looks wrong; all of them too).
BotLookRules.LIVERY_CHANCE = 0.55
BotLookRules.TRAIL_CHANCE = 0.4

-- Garage rows a bot may wear: kind "livery" or "trail", source shop or set, rarity common or rare. `cosmetics` is
-- MonetizationConfig.COSMETICS (passed in so this stays pure).
function BotLookRules.wearable(cosmetics: { any }, kind: string): { string }
	local out: { string } = {}
	for _, c in cosmetics do
		if c.kind == kind and (c.source == "shop" or c.source == "set") and (c.rarity == "common" or c.rarity == "rare") then
			table.insert(out, c.key)
		end
	end
	return out
end

-- Deals `n` looks from a seeded generator: no two share an outfit (nor a livery, while there are enough to go round).
-- `liveries` / `trails`: BotLookRules.wearable lists (may be empty). `rng`: () -> 0..1.
function BotLookRules.deal(rng: () -> number, n: number, liveries: { string }, trails: { string }): { Look }
	local out: { Look } = {}
	local usedOutfit: { [string]: boolean } = {}
	local usedLivery: { [string]: boolean } = {}
	local function pickIdx(len: number): number
		return math.floor(rng() * len) + 1
	end
	for _ = 1, n do
		local key = ""
		for _ = 1, 30 do
			key = BotLookRules.outfitKey(
				BotLookRules.HEADS[pickIdx(#BotLookRules.HEADS)],
				BotLookRules.SHIRTS[pickIdx(#BotLookRules.SHIRTS)],
				BotLookRules.PANTS[pickIdx(#BotLookRules.PANTS)]
			)
			if not usedOutfit[key] then
				break
			end
		end
		usedOutfit[key] = true
		local livery: string? = nil
		if #liveries > 0 and rng() < BotLookRules.LIVERY_CHANCE then
			for _ = 1, 8 do
				local k = liveries[pickIdx(#liveries)]
				if not usedLivery[k] or #liveries <= n then
					livery = k
					if not usedLivery[k] then
						break
					end
				end
			end
			if livery then
				usedLivery[livery] = true
			end
		end
		local trail: string? = nil
		if #trails > 0 and rng() < BotLookRules.TRAIL_CHANCE then
			trail = trails[pickIdx(#trails)]
		end
		table.insert(out, { outfit = key, skin = BotLookRules.SKINS[pickIdx(#BotLookRules.SKINS)], livery = livery, trail = trail })
	end
	return out
end

return BotLookRules
