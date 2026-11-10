--!strict
-- Client boot order and isolation (docs/audits/systems_audit_v32.md T1-1). client/init.client.luau starts every client
-- module through a runner from this file, so one module that throws at require or at .init() is logged once
-- ("[SkyRally][BOOT] fail <name>: <first line>"), reported to client/ErrorReporter, and the boot keeps going: the
-- driving and HUD modules (CORE) start even when AdminPanel, Settings' neighbours or any decor module break.
-- Pure: the runner takes its log, warn, clock, delay and report functions as dependencies; tools/tests/boot_spec.luau
-- pins the order, the isolation and the source shape of init.client.luau.
local BootRules = {}

BootRules.TAG = "[SkyRally][BOOT] "
BootRules.STALL_SECONDS = 10 -- a step still running after this long logs one "slow" line (it is not cancelled)
BootRules.MAX_ERR = 200 -- characters of the first error line kept in the log

-- Modules a player cannot drive or read the race without. They start first (after HudMetrics and Settings, which they
-- read) and a failure among them is reported as "boot_core".
BootRules.CORE = {
	"HudMetrics",
	"Settings",
	"FlightController",
	"CarController",
	"RaceUI",
	"HudPhase",
	"InputMode",
} :: { string }

-- Phase 1: every module is required in this order before any init runs, the same order the file's top-level requires
-- had before the guard, so module top-level code sees the same state it always did.
BootRules.REQUIRE_ORDER = {
	"FlightController", "RaceUI", "HudPhase", "HudMetrics", "Minimap", "ChatLayout", "BuildLabel", "AssetProbe",
	"InputMode", "CarController", "WorldProbe", "WorldAnim", "SailGateFx", "TrackFlow", "Onboarding", "Music",
	"BossAnimator", "Cosmetics", "Garage", "LoginPopup", "VehiclePick", "WorldMoments", "VehicleMotion", "PilotPose",
	"QAMultiplayerClient", "Settings", "AfkBeat", "LeaderboardBoard", "RacerView", "AtmosphereFx", "MapFxLod", "LightLod",
	"CameraFade", "DressingLod", "AdaptiveHaze", "CameraNearFade", "FrameGovernor", "ZoneLighting", "StormVendor",
	"HubStorm", "StormRaceClient", "ZoneVisibility", "LiveOpsNotice",
} :: { string }

export type Step = { name: string, spawn: boolean?, late: boolean? }

-- Phase 2: init order (unchanged from the unguarded boot). spawn = runs in its own thread (it waits on the server);
-- late = required at its init, as before (AdminPanel, PaintShop).
BootRules.INIT_ORDER = {
	{ name = "HudMetrics" },
	{ name = "Settings" },
	{ name = "AdminPanel", late = true },
	{ name = "BuildLabel" },
	{ name = "FlightController" },
	{ name = "CarController" },
	{ name = "RaceUI" },
	{ name = "HudPhase" },
	{ name = "ChatLayout" },
	{ name = "Minimap" },
	{ name = "InputMode" },
	{ name = "AssetProbe" },
	{ name = "WorldProbe" },
	{ name = "WorldAnim" },
	{ name = "SailGateFx" },
	{ name = "TrackFlow" },
	{ name = "Onboarding" },
	{ name = "Music" },
	{ name = "BossAnimator" },
	{ name = "Cosmetics" },
	{ name = "Garage" },
	{ name = "LoginPopup" },
	{ name = "VehiclePick" },
	{ name = "WorldMoments" },
	{ name = "RacerView" },
	{ name = "AtmosphereFx" },
	{ name = "MapFxLod" },
	{ name = "LightLod" },
	{ name = "CameraFade" },
	{ name = "DressingLod" },
	{ name = "AdaptiveHaze" },
	{ name = "CameraNearFade" },
	{ name = "FrameGovernor" },
	{ name = "VehicleMotion" },
	{ name = "PilotPose" },
	{ name = "VehicleCreatureAnimator", late = true }, -- creature mounts (Void Dragon): baked wing/tail clips by flight state
	{ name = "QAMultiplayerClient" },
	{ name = "AfkBeat" },
	{ name = "LeaderboardBoard" },
	{ name = "ZoneLighting" },
	{ name = "StormVendor", spawn = true },
	{ name = "HubStorm" },
	{ name = "PaintShop", late = true },
	{ name = "StormRaceClient" },
	{ name = "ZoneVisibility" },
	{ name = "LiveOpsNotice" }, -- T1-5 server closing banner and toasts
} :: { Step }

function BootRules.isCore(name: string): boolean
	return table.find(BootRules.CORE, name) ~= nil
end

-- First line of an error value, capped (a traceback or a multi-line message never floods the log).
function BootRules.firstLine(err: any): string
	local s = tostring(err)
	s = string.match(s, "^[^\r\n]*") or s
	if #s > BootRules.MAX_ERR then
		s = string.sub(s, 1, BootRules.MAX_ERR) .. "..."
	end
	return s
end

-- Order problems, empty when the order is sound: every CORE module has an init step, CORE keeps its listed order,
-- HudMetrics and Settings come first, no CORE step is spawned or late, every non-late init step was required in phase 1,
-- and no name repeats.
function BootRules.orderProblems(initOrder: { Step }?, requireOrder: { string }?): { string }
	local steps: { Step } = initOrder or BootRules.INIT_ORDER
	local reqs: { string } = requireOrder or BootRules.REQUIRE_ORDER
	local problems = {}
	local at: { [string]: number } = {}
	for i, s in steps do
		if at[s.name] then
			table.insert(problems, "duplicate init " .. s.name)
		end
		at[s.name] = i
		if not s.late and not table.find(reqs, s.name) then
			table.insert(problems, "not required before init: " .. s.name)
		end
		if BootRules.isCore(s.name) and (s.spawn or s.late) then
			table.insert(problems, "core step must run inline: " .. s.name)
		end
	end
	local seen: { [string]: boolean } = {}
	for _, r in reqs do
		if seen[r] then
			table.insert(problems, "duplicate require " .. r)
		end
		seen[r] = true
	end
	local last = 0
	for _, c in BootRules.CORE do
		local i = at[c]
		if not i then
			table.insert(problems, "core missing " .. c)
		elseif i < last then
			table.insert(problems, "core out of order " .. c)
		else
			last = i
		end
	end
	if steps[1] == nil or steps[1].name ~= "HudMetrics" or steps[2] == nil or steps[2].name ~= "Settings" then
		table.insert(problems, "HudMetrics and Settings must start first")
	end
	return problems
end

export type Deps = {
	log: (string) -> (),
	warn: (string) -> (),
	clock: () -> number,
	delay: ((number, () -> ()) -> ())?,
	report: ((name: string, err: string, core: boolean) -> ())?,
}

export type Runner = {
	-- Runs fn in protected mode; on an error logs once per name, reports, and returns false. Never throws.
	step: (name: string, fn: (...any) -> ...any, ...any) -> (boolean, any),
	failed: () -> { string },
	okCount: () -> number,
	summary: () -> string,
}

function BootRules.newRunner(deps: Deps): Runner
	local failedList: { string } = {}
	local failedSet: { [string]: boolean } = {}
	local okN = 0
	local started = deps.clock()

	local function fail(name: string, err: any)
		local line = BootRules.firstLine(err)
		if not failedSet[name] then
			failedSet[name] = true
			table.insert(failedList, name)
			deps.warn(BootRules.TAG .. "fail " .. name .. ": " .. line)
		end
		if deps.report then
			pcall(deps.report, name, line, BootRules.isCore(name))
		end
	end

	local runner = {} :: Runner

	function runner.step(name: string, fn: (...any) -> ...any, ...: any): (boolean, any)
		local done = false
		if deps.delay then
			pcall(deps.delay, BootRules.STALL_SECONDS, function()
				if not done then
					-- A print, not a warning: a spawned step that waits on the server is slow by design.
					deps.log(string.format("%sslow %s: still running after %ds", BootRules.TAG, name, BootRules.STALL_SECONDS))
				end
			end)
		end
		local ok, result = pcall(fn, ...)
		done = true
		if ok then
			okN += 1
		else
			fail(name, result)
		end
		return ok, result
	end

	function runner.failed(): { string }
		return table.clone(failedList)
	end

	function runner.okCount(): number
		return okN
	end

	function runner.summary(): string
		local list = if #failedList > 0 then " (" .. table.concat(failedList, ",") .. ")" else ""
		return string.format("%sdone ok=%d failed=%d%s in %.2fs", BootRules.TAG, okN, #failedList, list, deps.clock() - started)
	end

	return runner
end

return BootRules
