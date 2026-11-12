--!strict
-- Client boot guard (audit T1-1): BootRules order and isolation, and the shape of src/client/init.client.luau.
return function(h)
	local BootRules = h.require("src/shared/BootRules.luau")

	local function newRunner(withDelay: boolean?)
		local logs, warns, reports, delayed = {}, {}, {}, {}
		local t = 0
		local r = BootRules.newRunner({
			log = function(s)
				table.insert(logs, s)
			end,
			warn = function(s)
				table.insert(warns, s)
			end,
			clock = function()
				return t
			end,
			delay = if withDelay
				then function(_s, fn)
					table.insert(delayed, fn)
				end
				else nil,
			report = function(name, err, core)
				table.insert(reports, { name = name, err = err, core = core })
			end,
		})
		return r, warns, reports, delayed, logs
	end

	h.test("boot: a throwing step is isolated, logged once with its first line, and the next step still runs", function()
		local r, warns, reports = newRunner()
		local ran = {}
		r.step("AdminPanel", function()
			error("boom at line 3\nstack traceback: ...", 0)
		end)
		r.step("FlightController", function()
			table.insert(ran, "FlightController")
		end)
		r.step("AdminPanel", function()
			error("boom again", 0)
		end)
		h.eq(ran[1], "FlightController")
		h.eq(#warns, 1, "one log line per failing name")
		h.eq(warns[1], "[SkyRally][BOOT] fail AdminPanel: boom at line 3")
		h.eq(#reports, 2, "every failure is still reported (the reporter de-duplicates)")
		h.eq(reports[1].core, false)
		h.eq(r.okCount(), 1)
		h.eq(r.failed()[1], "AdminPanel")
		h.contains(r.summary(), "ok=1 failed=1 (AdminPanel)")
	end)

	h.test("boot: a core failure is reported as core; step returns the result", function()
		local r, _, reports = newRunner()
		local ok, v = r.step("CarController", function()
			error("nil index", 0)
		end)
		h.eq(ok, false)
		h.eq(reports[1].core, true)
		local ok2, v2 = r.step("RaceUI", function(a, b)
			return a + b
		end, 2, 3)
		h.eq(ok2, true)
		h.eq(v2, 5)
		h.ok(v ~= nil)
	end)

	h.test("boot: a reporter that throws never breaks the boot", function()
		local r = BootRules.newRunner({
			log = function() end,
			warn = function() end,
			clock = function()
				return 0
			end,
			report = function()
				error("reporter down")
			end,
		})
		local ok = r.step("Music", function()
			error("x", 0)
		end)
		h.eq(ok, false)
		h.eq(r.step("Minimap", function() end), true)
	end)

	h.test("boot: a step still running at the stall timer logs one slow line; a finished one does not", function()
		local r, warns, _, delayed, logs = newRunner(true)
		r.step("Quick", function() end)
		h.eq(#delayed, 1)
		delayed[1]()
		h.eq(#logs, 0)
		r.step("Slow", function()
			delayed[2]() -- the timer fires while the step is still inside its body
		end)
		h.eq(#logs, 1)
		h.contains(logs[1], "slow Slow")
		h.eq(#warns, 0, "a slow step is a print, never a warning")
	end)

	h.test("boot: firstLine caps long errors and drops the traceback", function()
		h.eq(BootRules.firstLine("a\nb"), "a")
		h.eq(#BootRules.firstLine(string.rep("x", 500)), BootRules.MAX_ERR + 3)
	end)

	h.test("boot order: the shipped order has no problems", function()
		local p = BootRules.orderProblems()
		h.eq(#p, 0, table.concat(p, "; "))
	end)

	h.test("boot order: problems are found (core out of order, missing, spawned, unrequired, duplicates)", function()
		local steps = {
			{ name = "Settings" },
			{ name = "HudMetrics" },
			{ name = "CarController" },
			{ name = "FlightController", spawn = true },
			{ name = "Ghost" },
			{ name = "Ghost" },
		}
		local p = table.concat(BootRules.orderProblems(steps, { "Settings", "HudMetrics", "CarController", "FlightController", "Settings" }), "; ")
		h.contains(p, "HudMetrics and Settings must start first")
		h.contains(p, "core out of order")
		h.contains(p, "core missing RaceUI")
		h.contains(p, "core step must run inline: FlightController")
		h.contains(p, "not required before init: Ghost")
		h.contains(p, "duplicate init Ghost")
		h.contains(p, "duplicate require Settings")
	end)

	h.test("boot order: every listed module exists as src/client/<name>.luau", function()
		local names = {}
		for _, n in BootRules.REQUIRE_ORDER do
			table.insert(names, n)
		end
		for _, s in BootRules.INIT_ORDER do
			table.insert(names, s.name)
		end
		for _, n in names do
			local ok = pcall(h.readFile, "src/client/" .. n .. ".luau")
			h.ok(ok, "missing src/client/" .. n .. ".luau")
		end
	end)

	h.test("boot source: init.client.luau starts modules only through the runner", function()
		local src = h.readFile("src/client/init.client.luau")
		local code = {}
		for line in string.gmatch(src .. "\n", "([^\n]*)\n") do
			table.insert(code, (string.gsub(line, "%-%-.*$", "")))
		end
		local body = table.concat(code, "\n")
		-- No direct module requires besides the reporter, and no direct Module.init() calls besides the generic loop.
		for req in string.gmatch(body, "require%(script%.([%w_]+)%)") do
			h.eq(req, "ErrorReporter", "direct require of " .. req)
		end
		for mod in string.gmatch(body, "([%w_]+)%.init%(") do
			h.ok(mod == "m", "direct init call " .. mod .. ".init()")
		end
		h.contains(body, "BootRules.REQUIRE_ORDER")
		h.contains(body, "BootRules.INIT_ORDER")
		h.contains(body, "boot.step(")
		-- The reporter starts before the first module require.
		local a = string.find(body, "require(script.ErrorReporter)", 1, true)
		local b = string.find(body, "for _, name in BootRules.REQUIRE_ORDER", 1, true)
		h.ok(a ~= nil and b ~= nil and a < b, "ErrorReporter starts first")
	end)

	h.test("boot source: every client module with an init that the old boot started is still listed", function()
		-- The 44 modules the unguarded boot started (v31). A module dropped from INIT_ORDER would never run.
		local expected = {
			"HudMetrics", "Settings", "AdminPanel", "BuildLabel", "FlightController", "CarController", "RaceUI", "HudPhase",
			"ChatLayout", "Minimap", "InputMode", "AssetProbe", "WorldProbe", "WorldAnim", "SailGateFx", "TrackFlow",
			"Onboarding", "Music", "BossAnimator", "Cosmetics", "Garage", "LoginPopup", "VehiclePick", "WorldMoments",
			"RacerView", "AtmosphereFx", "MapFxLod", "LightLod", "CameraFade", "DressingLod", "AdaptiveHaze",
			"CameraNearFade", "FrameGovernor", "VehicleMotion", "PilotPose", "VehicleCreatureAnimator", "QAMultiplayerClient", "AfkBeat",
			"LeaderboardBoard", "ZoneLighting", "StormVendor", "HubStorm", "PaintShop", "StormRaceClient", "ZoneVisibility",
			"LiveOpsNotice", -- T1-5 (2026-10-21)
			"GrandPrixClient", -- v37 Grand Prix
		}
		h.eq(#BootRules.INIT_ORDER, #expected)
		for i, n in expected do
			h.eq(BootRules.INIT_ORDER[i].name, n, "init step " .. i)
		end
	end)
end
