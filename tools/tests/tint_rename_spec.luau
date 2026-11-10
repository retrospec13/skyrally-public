--!strict
-- Vocabulary ruling 2026-10-20: players see "Tint", never "livery". Internal keys (Livery_*, kind "livery", planeLivery/carLivery,
-- liverySetS1_*) are save/receipt identifiers and stay. Pure checks over config names/labels, tabs, and UI string literals.
-- Run: tools/tests/run_lune_tests.sh tools/tests/tint_rename_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

local FILES = {
	"src/client/Garage.luau",
	"src/shared/GarageModel.luau",
	"src/server/Economy.luau",
	"src/shared/FinaleRules.luau",
	"src/client/TrackFlow.luau",
	"src/client/RaceUI.luau",
	"src/client/PodiumCeremony.luau",
	"src/shared/MonetizationConfig.luau",
}

-- A literal is an identifier (not text) when it is a key or a slot/kind/tab id.
local function identifier(lit: string): boolean
	return string.find(lit, "^Livery_") ~= nil
		or string.find(lit, "^giftLivery") ~= nil
		or string.find(lit, "^livery") ~= nil -- "livery", "liverySetS1_1", "liveries" tab id
		or lit == "liveries"
		or lit == "planeLivery"
		or lit == "carLivery"
		or lit == "LiveryPaint"
		or lit == "LiveryBaseColor"
end

local function hasLivery(s: string): boolean
	return string.find(string.lower(s), "liver[iy]") ~= nil
end

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local Config = h.require("src/shared/MonetizationConfig.luau")
	local GarageModel = h.require("src/shared/GarageModel.luau")

	h.test("product labels and cosmetic names never say livery", function()
		for _, p in ipairs(Config.PRODUCTS) do
			h.ok(not hasLivery(p.label), p.key .. " label: " .. p.label)
			if p.storeName then
				h.ok(not hasLivery(p.storeName), p.key .. " storeName")
			end
		end
		for _, c in ipairs(Config.COSMETICS) do
			h.ok(not hasLivery(c.name), c.key .. " name: " .. c.name)
		end
		local want = { liverySetS1_1 = "Season 1 Tint", liverySetS1_3 = "Season 1 Tints x3", giftLiverySetS1_1 = "Gift: Season 1 Tint", giftLiverySetS1_3 = "Gift: Season 1 Tints x3" }
		local seen = 0
		for _, p in ipairs(Config.PRODUCTS) do
			if want[p.key] then
				h.eq(p.label, want[p.key], p.key)
				seen += 1
			end
		end
		h.eq(seen, 4)
	end)

	h.test("Garage tab label is TINTS (tab id stays for code)", function()
		local found = false
		for _, t in ipairs(GarageModel.TABS) do
			h.ok(not hasLivery(t.label), t.id .. " label")
			if t.kind == "livery" then
				h.eq(t.label, "TINTS")
				found = true
			end
		end
		h.ok(found, "tint tab exists")
		for _, r in ipairs({ "gears", "owned", "soldOut", "notInShop", "claimed", "needsPremium", "notEnoughWins", "loading" }) do
			h.ok(not hasLivery(GarageModel.reasonText(r)), r)
		end
		for _, l in pairs(GarageModel.SLOT_LABEL) do
			h.ok(not hasLivery(l), "slot label")
		end
		-- Row subtitles ("COMMON TINT - ...", "FREE - TINT") print the kind through kindLabel, never the raw kind id.
		h.eq(GarageModel.kindLabel("livery"), "TINT")
		h.eq(GarageModel.kindLabel("trail"), "TRAIL")
		local garage = h.readFile("src/client/Garage.luau")
		h.ok(not string.find(garage, "string.upper(r.kind)", 1, true), "shop row uses kindLabel")
		h.ok(not string.find(garage, "string.upper(cell.kind)", 1, true), "win pass row uses kindLabel")
	end)

	h.test("no player-facing string literal in the UI/economy modules says livery", function()
		for _, path in ipairs(FILES) do
			local n = 0
			for line in string.gmatch(h.readFile(path), "[^\n]+") do
				n += 1
				local code = (string.gsub(line, "%-%-.*$", ""))
				if not string.find(code, "WaitForChild", 1, true) and not string.find(code, "GetAttribute", 1, true) then
					for lit in string.gmatch(code, '"([^"]*)"') do
						h.ok(not hasLivery(lit) or identifier(lit), string.format("%s:%d player-facing literal says livery: %q", path, n, lit))
					end
				end
			end
		end
	end)
end
