--!strict
-- Plausible Roblox-style usernames for race bots (economy v3 phase 4: bots pass as players). Pure: word parts, styles
-- and the filters, no Roblox API, so tools/tests/bot_names_spec.luau runs it as-is. The pattern is Meme Fight Tactics'
-- (Logic/BotNames + NamePool); the pool and the Roblox call live in BotNamePoolRules / server/BotNamePool.
--
-- OFFLINE / BUILD-TIME NOTE (kid safety): a generated name is only a CANDIDATE. These parts can spell a real account
-- ("SwiftFalcon", "Noah_2011" exist), so nothing here is ever shown on its own: server/BotNamePool asks
-- Players:GetUserIdFromNameAsync (pcall, cached) in the background and drops any name that resolves to a user id, and
-- AIRacers re-checks a fallback name the pool could not vouch for. To audit the parts offline, run
-- tools/tests/bot_names_spec.luau (shape and filter sweep over thousands of candidates) and, for the final lists, check
-- the parts against the Roblox users API from a machine with network access before editing them.
--
-- Shape (Roblox's own rule): 3-20 characters of [A-Za-z0-9_], at most one underscore, not at either end, not all digits.
-- Filters: banned roots (offensive), famous creators and brands (no impersonation), and bot tells (a name that says bot).
-- Everything is checked after lower-casing and un-leeting (0 o, 1 i/l, 3 e, 4 a, 5 s, 7 t) with underscores and digits
-- dropped, so "N1ke_99" and "ni_ke" are caught too.

local BotNames = {}

BotNames.MIN_LEN = 3
BotNames.MAX_LEN = 20

-- A seeded 0..1 generator (an LCG whose state stays under 2^53, tempered by xorshift), so a seed always deals the same
-- names and the spec is repeatable.
function BotNames.rng(seed: number): () -> number
	local s = math.floor(math.abs(seed)) % 4294967296
	return function(): number
		s = (s * 1664525 + 1013904223) % 4294967296
		local t = bit32.bxor(s, bit32.rshift(s, 15))
		t = bit32.bxor(t, bit32.rshift(t, 7))
		return (t % 4294967296) / 4294967296
	end
end

-- Word parts. Plain, common, brief: nothing a child would not say aloud, no cartoon voice.
BotNames.ADJ = table.freeze({
	"Swift", "Rapid", "Silent", "Brave", "Lucky", "Cosmic", "Frosty", "Turbo", "Neon", "Rusty", "Sunny", "Stormy",
	"Hyper", "Mighty", "Shadow", "Golden", "Silver", "Crimson", "Azure", "Misty", "Wild", "Quick", "Sharp", "Ultra",
	"Lunar", "Solar", "Atomic", "Pixel", "Retro", "Icy", "Dusty", "Rogue", "Nimble", "Daring", "Fierce", "Mellow",
	"Jolly", "Epic", "Prime", "Alpha", "Zen", "Cyber", "Blazing", "Electric", "Phantom", "Velvet", "Copper", "Amber",
}) :: { string }

BotNames.NOUN = table.freeze({
	"Falcon", "Tiger", "Wolf", "Panda", "Rocket", "Comet", "Sailor", "Pilot", "Racer", "Drifter", "Viper", "Raven",
	"Otter", "Badger", "Phoenix", "Dragon", "Knight", "Ranger", "Wizard", "Hawk", "Fox", "Bear", "Shark", "Eagle",
	"Cobra", "Lynx", "Moose", "Gecko", "Panther", "Jaguar", "Orbit", "Meteor", "Thunder", "Blizzard", "Cyclone",
	"Mustang", "Bullet", "Arrow", "Spark", "Ember", "Glider", "Cruiser", "Voyager", "Nomad", "Scout", "Bandit",
	"Captain", "Maverick", "Pioneer", "Rider",
}) :: { string }

-- Lower-case handles ("cooldude2012" style): word + word, kept lower.
BotNames.LOWER = table.freeze({
	"skater", "gamer", "builder", "runner", "driver", "flyer", "pilot", "speedy", "turbo", "cool", "epic", "pro",
	"ultra", "mega", "super", "just", "its", "real", "the", "mr", "iam", "not", "only", "best", "fast", "drift",
	"zoom", "dash", "boost", "jump", "dino", "cat", "dog", "pizza", "taco", "cookie", "waffle", "noodle", "banana",
	"mango", "panda", "tiger", "wolf", "fox", "pixel", "robo", "star", "moon", "sky",
}) :: { string }

BotNames.FIRST = table.freeze({
	"Alex", "Sam", "Jordan", "Max", "Leo", "Mia", "Noah", "Emma", "Liam", "Ava", "Ben", "Zoe", "Eli", "Ivy", "Jack",
	"Kai", "Luna", "Owen", "Ruby", "Finn", "Nora", "Theo", "Cleo", "Dean", "Ella", "Hugo", "Jade", "Kira", "Milo",
	"Nina", "Omar", "Piper", "Quinn", "Remy", "Sage", "Tess", "Uri", "Vera", "Wade", "Yara",
}) :: { string }

BotNames.SUFFIX = table.freeze({
	"Plays", "Gaming", "YT", "TV", "HD", "XD", "Fan", "Main", "Alt", "2k", "Jr", "Racing", "Fly", "Drive",
}) :: { string }

-- Banned roots, matched inside the normalised name (lower-case letters only). Offensive terms first; none of the word
-- parts above may contain one (the spec sweeps them).
BotNames.BANNED = table.freeze({
	"fuck", "shit", "bitch", "cunt", "dick", "cock", "pussy", "penis", "vagina", "boob", "tits", "porn", "sex", "nude",
	"naked", "rape", "rapist", "nazi", "hitler", "kkk", "nigg", "fag", "retard", "whore", "slut", "anal", "cum", "horny",
	"suicide", "kill", "murder", "terror", "isis", "drug", "cocaine", "meth", "weed", "beer", "vodka", "gun", "bomb",
	"die", "dead", "hate", "stupid", "idiot", "ugly", "fat", "jew", "gay", "lesbian", "racist", "sucks", "poop",
}) :: { string }

-- Famous creators, staff and brands: no impersonation, nothing that reads as official.
BotNames.PROTECTED = table.freeze({
	"roblox", "robux", "rbx", "builderman", "shedletsky", "baszucki", "davidbaszucki", "kreekcraft", "kreek",
	"flamingo", "linkmon", "denis", "dennis", "sketch", "itsfunneh", "funneh", "ldshadowlady", "mrbeast", "beast",
	"pewdiepie", "markiplier", "jacksepticeye", "dream", "technoblade", "ninja", "tubers", "jelly", "ssundee",
	"nike", "adidas", "gucci", "supreme", "disney", "pixar", "nintendo", "mario", "luigi", "zelda", "pokemon",
	"pikachu", "sonic", "minecraft", "fortnite", "youtube", "tiktok", "google", "apple", "samsung", "tesla",
	"official", "verified", "admin", "moderator", "staff", "owner", "developer", "support", "system", "mod",
}) :: { string }

-- Words that say "bot" (or "not a person"). "AI_" is the old model-name prefix and must never reach a screen.
BotNames.TELLS = table.freeze({
	"bot", "npc", "cpu", "robot", "computer", "guest", "default", "test", "demo", "dummy", "player", "user", "ai",
}) :: { string }

local LEET: { [string]: string } = { ["0"] = "o", ["1"] = "i", ["3"] = "e", ["4"] = "a", ["5"] = "s", ["7"] = "t", ["8"] = "b" }

-- Lower-case letters only: digits un-leeted (0 o ...) and then dropped, underscores dropped.
function BotNames.normalise(name: string): string
	local lower = string.lower(name)
	lower = string.gsub(lower, "[0-9]", function(d: string): string
		return LEET[d] or ""
	end)
	lower = string.gsub(lower, "[^a-z]", "")
	return lower
end

-- Roblox's shape rule only.
function BotNames.validShape(name: string): boolean
	local n = #name
	if n < BotNames.MIN_LEN or n > BotNames.MAX_LEN then
		return false
	end
	if string.find(name, "[^A-Za-z0-9_]") then
		return false
	end
	if string.sub(name, 1, 1) == "_" or string.sub(name, n, n) == "_" then
		return false
	end
	local _, underscores = string.gsub(name, "_", "")
	if underscores > 1 then
		return false
	end
	if string.find(name, "^[0-9_]+$") then
		return false
	end
	return true
end

-- Why a name is refused ("banned", "protected", "tell"), or nil when its words are fine.
function BotNames.refusal(name: string): string?
	local norm = BotNames.normalise(name)
	-- the raw lower-case form too: "ai" must not hide in a leet reading, and digits split words ("ass2sin")
	local raw = string.lower((string.gsub(name, "[^A-Za-z]", "")))
	for _, form in { norm, raw } do
		for _, root in BotNames.BANNED do
			if string.find(form, root, 1, true) then
				return "banned"
			end
		end
		for _, root in BotNames.PROTECTED do
			if string.find(form, root, 1, true) then
				return "protected"
			end
		end
		for _, tell in BotNames.TELLS do
			-- short tells ("ai") only as a whole word part: start, end, or alone between separators
			if #tell <= 2 then
				if form == tell then
					return "tell"
				end
			elseif string.find(form, tell, 1, true) then
				return "tell"
			end
		end
	end
	local lower = string.lower(name)
	if string.find(lower, "^ai[_%d]") or string.find(lower, "[_%d]ai$") or string.find(lower, "^ai$") then
		return "tell"
	end
	return nil
end

function BotNames.valid(name: string): boolean
	return BotNames.validShape(name) and BotNames.refusal(name) == nil
end

local function pick(rng: () -> number, list: { string }): string
	return list[math.floor(rng() * #list) + 1]
end

local function digits(rng: () -> number, n: number): string
	local s = ""
	for _ = 1, n do
		s ..= tostring(math.floor(rng() * 10))
	end
	return s
end

local function year(rng: () -> number): string
	return tostring(2004 + math.floor(rng() * 12)) -- 2004..2015: a birth year or a join year
end

-- Styles: each takes the generator and returns a candidate (not yet filtered).
local STYLES: { (() -> number) -> string } = {
	function(r) return pick(r, BotNames.ADJ) .. pick(r, BotNames.NOUN) end, -- SwiftFalcon
	function(r) return pick(r, BotNames.ADJ) .. pick(r, BotNames.NOUN) .. digits(r, 2) end, -- SwiftFalcon42
	function(r) return pick(r, BotNames.ADJ) .. "_" .. pick(r, BotNames.NOUN) end, -- Swift_Falcon
	function(r) return pick(r, BotNames.NOUN) .. "_" .. digits(r, 2 + math.floor(r() * 3)) end, -- Falcon_731
	function(r) return pick(r, BotNames.LOWER) .. pick(r, BotNames.LOWER) .. year(r) end, -- coolskater2009
	function(r) return pick(r, BotNames.LOWER) .. pick(r, BotNames.LOWER) .. digits(r, 1 + math.floor(r() * 3)) end, -- zoomtaco77
	function(r) return pick(r, BotNames.FIRST) .. "_" .. year(r) end, -- Noah_2011
	function(r) return pick(r, BotNames.FIRST) .. pick(r, BotNames.SUFFIX) end, -- LunaPlays
	function(r) return pick(r, BotNames.FIRST) .. pick(r, BotNames.NOUN) .. digits(r, 2) end, -- MiaTiger58
	function(r) return pick(r, BotNames.NOUN) .. pick(r, BotNames.NOUN) end, -- FoxRocket
	function(r) return pick(r, BotNames.ADJ) .. pick(r, BotNames.FIRST) end, -- SwiftMilo
	function(r) return pick(r, BotNames.LOWER) .. "_" .. pick(r, BotNames.LOWER) end, -- zoom_pizza
}
BotNames.STYLE_COUNT = #STYLES

-- One filtered candidate: any style, shape and filters satisfied, not in `avoid` (lower-case keys). Retries a bounded
-- number of times, then falls back to the long numbered style, so it always returns.
function BotNames.make(rng: () -> number, avoid: { [string]: boolean }?): string
	for _ = 1, 40 do
		local name = STYLES[math.floor(rng() * #STYLES) + 1](rng)
		if BotNames.valid(name) and not (avoid and avoid[string.lower(name)]) then
			return name
		end
	end
	return BotNames.makeLong(rng, avoid)
end

-- The long numbered style (a 5-7 digit tail): the fallback when the pool is dry or the plain styles keep colliding.
function BotNames.makeLong(rng: () -> number, avoid: { [string]: boolean }?): string
	for _ = 1, 40 do
		local name = pick(rng, BotNames.ADJ) .. pick(rng, BotNames.NOUN) .. digits(rng, 5 + math.floor(rng() * 3))
		if BotNames.valid(name) and not (avoid and avoid[string.lower(name)]) then
			return name
		end
	end
	return "Racer" .. digits(rng, 8) -- unreachable in practice; still valid shape and unfiltered
end

return BotNames
