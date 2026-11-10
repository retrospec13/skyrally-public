--!strict
-- Lune spec for REMARKABLE Batch 2 item 19's fairness rule: the race rival's rubber band (AIRacers.rubberFactor with
-- rival = true) is tighter than the normal one but never past the same RUBBER_BAND_MAX_BOOST / RUBBER_BAND_MAX_SLOW
-- ceilings, and the normal band is exactly the pre-item-19 formula. AIRacers loads from source with token stubs (the
-- field_spec technique), so this calls the real function.
-- Usage: lune run tools/tests/rival_band_spec.luau   (also picked up by tools/tests/run_lune_tests.sh)
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any

local checks, failures = 0, 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		failures += 1
		print("FAIL " .. msg)
	end
end

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd
local function loadWithEnv(rel: string, env: { [string]: any }): any
	return luau.load(fs.readFile(root .. "/" .. rel), { debugName = rel, environment = env })()
end

local PlaneConfig = loadWithEnv("src/shared/PlaneConfig.luau", { Color3 = roblox.Color3 })
local ItemRules = loadWithEnv("src/shared/ItemRules.luau", {})
local FidelityRules = loadWithEnv("src/shared/FidelityRules.luau", {})
local TriggerRules = loadWithEnv("src/shared/TriggerRules.luau", {})
local GridOrder = loadWithEnv("src/shared/GridOrder.luau", {})
local RacerViewRules = loadWithEnv("src/shared/RacerViewRules.luau", { Vector3 = roblox.Vector3, CFrame = roblox.CFrame })
local BotPaceRules = loadWithEnv("src/shared/BotPaceRules.luau", {})
-- Economy v3 phase 2b: the real RaceScope over the real RaceFlowRules (PER_GROUP false: one field, as before) and the
-- race attribute shim, which reads nothing these pure helpers need.
local RaceFlowRules = loadWithEnv("src/shared/RaceFlowRules.luau", { Vector3 = roblox.Vector3, CFrame = roblox.CFrame })
local RaceScope = loadWithEnv("src/shared/RaceScope.luau", {
	script = { Parent = { WaitForChild = function(): any
		return "RaceFlowRules"
	end } },
	require = function(): any
		return RaceFlowRules
	end,
})
local modules: { [string]: any } = {
	PlaneConfig = PlaneConfig,
	ItemRules = ItemRules,
	FidelityRules = FidelityRules,
	TriggerRules = TriggerRules,
	SailGateRules = {},
	SplineUtils = {},
	TrackRegistry = {},
	PlaneBuilder = {},
	CarConfig = { RIDE_HEIGHT = 1.9 },
	CarBuilder = {},
	RacerPaint = { paintBot = function() end },
	GridOrder = GridOrder,
	RacerViewRules = RacerViewRules,
		BotPaceRules = BotPaceRules,
		BotDisguise = {},
	BossConfig = {},
	RaceScope = RaceScope,
	RaceAttr = { here = function(_n: string): any
		return nil
	end },
	RaceFlowRules = RaceFlowRules,
}
local function token(name: string): any
	return { __token = name }
end
local AIRacers = loadWithEnv("src/server/AIRacers.luau", {
	game = {
		GetService = function(_self: any, name: string): any
			if name == "ReplicatedStorage" then
				return { WaitForChild = function(): any
					return { WaitForChild = function(_s: any, n: string): any
						return token(n)
					end }
				end }
			end
			return {}
		end,
	},
	script = { Parent = { PlaneBuilder = token("PlaneBuilder"), kit = { CarBuilder = token("CarBuilder"), RacerPaint = token("RacerPaint"), BotDisguise = token("BotDisguise") } } },
	require = function(t: any): any
		return assert(modules[t.__token], "unexpected require " .. tostring(t.__token))
	end,
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
})

-- The pre-item-19 formula, inlined in stepMotion until this change.
local function legacy(d: number): number
	if d > PlaneConfig.RUBBER_BAND_BEHIND_DIST then
		return 1 + math.clamp((d - PlaneConfig.RUBBER_BAND_BEHIND_DIST) / 850, 0, 1) * PlaneConfig.RUBBER_BAND_MAX_BOOST
	elseif d < -PlaneConfig.RUBBER_BAND_AHEAD_DIST then
		return 1 - math.clamp((-d - PlaneConfig.RUBBER_BAND_AHEAD_DIST) / 700, 0, 1) * PlaneConfig.RUBBER_BAND_MAX_SLOW
	end
	return 1
end

local hi = 1 + PlaneConfig.RUBBER_BAND_MAX_BOOST
local lo = 1 - PlaneConfig.RUBBER_BAND_MAX_SLOW
local tighter = 0
for d = -4000, 4000, 5 do
	local n, r = AIRacers.rubberFactor(d, false), AIRacers.rubberFactor(d, true)
	check(math.abs(n - legacy(d)) < 1e-12, string.format("normal band unchanged at %d (%.4f vs %.4f)", d, n, legacy(d)))
	check(math.abs(AIRacers.rubberFactor(d) - n) < 1e-12, "rival omitted = normal")
	check(r <= hi + 1e-12 and r >= lo - 1e-12, string.format("rival inside the ceilings at %d (%.4f)", d, r))
	if d > 0 then
		check(r >= n - 1e-12, "behind: the rival never catches up softer than normal")
	elseif d < 0 then
		check(r <= n + 1e-12, "ahead: the rival never eases off softer than normal")
	end
	if math.abs(r - n) > 1e-6 then
		tighter += 1
	end
end
check(tighter > 0, "the rival's band really is tighter somewhere")
check(math.abs(AIRacers.rubberFactor(1e6, true) - hi) < 1e-12, "far behind: exactly the boost ceiling")
check(math.abs(AIRacers.rubberFactor(-1e6, true) - lo) < 1e-12, "far ahead: exactly the slow floor")

print(string.format("rival_band_spec: %d checks, %d failed", checks, failures))
process.exit(if failures == 0 then 0 else 1)
