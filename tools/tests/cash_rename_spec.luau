--!strict
-- Economy v3: the currency is shown as "Cash". Save keys keep the old "gears" names, but no player-facing string may.
-- Pure checks over the config labels, the Garage reason table and the string literals of the UI/toast modules.
-- Run: tools/tests/run_lune_tests.sh tools/tests/cash_rename_spec.luau

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
	"src/shared/EconomyRules.luau",
}

-- A bare "Gears" literal is an instance name or a DataStore/attribute key, not text; anything longer is shown to players.
local function offending(lit: string): boolean
	local l = string.lower(lit)
	if not string.find(l, "%f[%a]gears%f[%A]") then
		return false
	end
	return lit ~= "Gears" and lit ~= "gears" and not string.find(lit, "gears=", 1, true) -- log lines
end

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local Config = h.require("src/shared/MonetizationConfig.luau")
	local GarageModel = h.require("src/shared/GarageModel.luau")

	h.test("currency name and product labels say Cash", function()
		h.eq(Config.CURRENCY, "Cash")
		local want = { gearsPack1 = "500 Cash", gearsPack2 = "1,200 Cash", gearsPack3 = "3,500 Cash", gearsPack4 = "8,000 Cash", x2Gears = "2x Cash", winPassPremiumS1 = "Win Pass Premium" }
		for _, p in ipairs(Config.PRODUCTS) do
			h.ok(not string.find(string.lower(p.label), "gear"), p.key .. " label still says Gears: " .. p.label)
			if p.storeName then
				h.ok(not string.find(string.lower(p.storeName), "gear"), p.key .. " storeName says Gears")
			end
			if want[p.key] then
				h.eq(p.label, want[p.key], p.key)
			end
		end
	end)

	h.test("Garage reason texts never say Gears", function()
		for _, reason in ipairs({ "gears", "owned", "soldOut", "notInShop", "claimed", "needsPremium", "notEnoughWins", "loading" }) do
			h.ok(not string.find(string.lower(GarageModel.reasonText(reason)), "gear"), reason)
		end
		h.eq(GarageModel.reasonText("gears"), "Not enough Cash")
	end)

	h.test("no player-facing string literal in the Garage, toasts or results says Gears", function()
		for _, path in ipairs(FILES) do
			local n = 0
			for line in string.gmatch(h.readFile(path), "[^\n]+") do
				n += 1
				local code = (string.gsub(line, "%-%-.*$", ""))
				if not string.find(code, "GetAttribute", 1, true) and not string.find(code, "SetAttribute", 1, true) and not string.find(code, "isPassActive", 1, true) and not string.find(code, "hasPass", 1, true) then
					for lit in string.gmatch(code, '"([^"]*)"') do
						h.ok(not offending(lit), string.format("%s:%d player-facing literal says Gears: %q", path, n, lit))
					end
				end
			end
		end
	end)
end
