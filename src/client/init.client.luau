--!strict
-- Client boot (docs/audits/systems_audit_v32.md T1-1). Every client module starts through the BootRules runner: a module
-- that throws at require or at .init() is logged once ("[SkyRally][BOOT] fail <name>: ..."), reported by
-- client/ErrorReporter, and the boot goes on, so the driving and HUD modules (BootRules.CORE) are never lost to a broken
-- neighbour. The order is data in shared/BootRules (REQUIRE_ORDER, then INIT_ORDER, both unchanged from the unguarded
-- boot) and is pinned by tools/tests/boot_spec.luau. What each module does is described at its own top.
--   Settings (audit H13) starts right after HudMetrics so the sound modules read the EFFECTS group and the shake toggle;
--   AdminPanel (DECISIONS D22) builds nothing unless the server answers; StormVendor runs in its own thread;
--   PaintShop opens the Garage on a tab; StormRaceClient reads TrackFlow.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BootRules = require(Shared:WaitForChild("BootRules"))

-- The reporter starts first and on its own guard, so it is up for every failure below.
local reporter: any = nil
do
	local ok, mod = pcall(function()
		local m = require(script.ErrorReporter) :: any
		m.init()
		return m
	end)
	if ok then
		reporter = mod
	else
		warn(BootRules.TAG .. "fail ErrorReporter: " .. BootRules.firstLine(mod))
	end
end

local boot = BootRules.newRunner({
	log = print,
	warn = warn,
	clock = os.clock,
	delay = function(s: number, fn: () -> ())
		task.delay(s, fn)
	end,
	report = function(name: string, err: string, core: boolean)
		if reporter then
			reporter.bootFail(name, err, core)
		end
	end,
})

local mods: { [string]: any } = {}

local function load(name: string): any
	local inst = script:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		error("no module " .. name, 0)
	end
	return (require :: any)(inst)
end

-- Arguments some inits take (looked up at init time, so a module that failed gives nil and the callee copes).
local function initArgs(name: string): { any }
	if name == "PaintShop" then
		-- Hub PAINT SHOP kiosk prompts open the Garage on the TINTS / VEHICLES tab (server/PaintShopStand).
		return {
			function(tab: string?)
				local g = mods.Garage
				if g then
					g.open(tab)
				end
			end,
		}
	elseif name == "StormRaceClient" or name == "GrandPrixClient" then
		return { mods.TrackFlow }
	end
	return {}
end

-- Phase 1: require in the original order.
for _, name in BootRules.REQUIRE_ORDER do
	local ok, m = boot.step(name, load, name)
	if ok then
		mods[name] = m
	end
end

-- Phase 2: init in the original order; a module whose require failed is skipped (already logged).
for _, s in BootRules.INIT_ORDER do
	local name = s.name
	local function run()
		local m = mods[name]
		if m == nil and s.late then
			m = load(name)
			mods[name] = m
		end
		if m == nil then
			return
		end
		m.init(table.unpack(initArgs(name)))
	end
	if s.spawn then
		task.spawn(boot.step, name, run)
	elseif mods[name] ~= nil or s.late then
		boot.step(name, run)
	end
end

do
	-- Per-group QA switch sanity (Studio QAPerGroup is read once per DataModel): the server says PerGroupLive when its
	-- PER_GROUP is on; a client that read the flag differently would drive the wrong curtain and map visibility.
	boot.step("PerGroupCheck", function()
		local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules")) :: any
		task.delay(5, function()
			if (workspace:GetAttribute("PerGroupLive") == true) ~= (RaceFlowRules.PER_GROUP == true) then
				warn(string.format("[SkyRally][GROUPS] PER_GROUP mismatch: server %s, this client %s (set QAPerGroup in Edit before Play)",
					tostring(workspace:GetAttribute("PerGroupLive") == true), tostring(RaceFlowRules.PER_GROUP == true)))
			end
		end)
	end)
end

print(boot.summary())
pcall(function()
	Players.LocalPlayer:SetAttribute("BootOk", boot.okCount())
end)
