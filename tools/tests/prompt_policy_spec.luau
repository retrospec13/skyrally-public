--!strict
-- Purchase prompt policy (shared/PromptPolicyRules; TEST_LIST_LAUNCH L59, PUBLIC_RELEASE C5): no purchase prompt in the
-- first 10 s after join, during a map switch or a due Storm Cup, during the grid countdown or the boss intro hold, or
-- while racing until the player's own finish; the hub and the results screen allow one. Static checks: server/Economy
-- gates every prompt through this rule, and no client code calls MarketplaceService prompt APIs itself.
-- Run: tools/tests/run_lune_tests.sh tools/tests/prompt_policy_spec.luau
return function(h)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local R = h.require("src/shared/PromptPolicyRules.luau")
	local HUB = { sinceJoin = 60, mode = "hub" }

	local function with(over: { [string]: any }): any
		local s = table.clone(HUB)
		for k, v in over do
			s[k] = v
		end
		return s
	end

	h.test("first 10 s after join: blocked; from 10 s: allowed in the hub; unknown join time counts as just joined", function()
		h.eq(R.JOIN_GRACE_SECONDS, 10)
		h.eq(R.blockReason(with({ sinceJoin = 0 })), "just joined")
		h.eq(R.blockReason(with({ sinceJoin = 9.99 })), "just joined")
		h.eq(R.blockReason(with({ sinceJoin = 10 })), nil)
		h.eq(R.blockReason({ mode = "hub" }), "just joined")
		h.eq(R.blockReason(with({ sinceJoin = 0 / 0 })), "just joined", "NaN")
		h.eq(R.joinBlock(4, 3), nil, "a custom grace (tests) is honoured")
		h.eq(R.joinBlock(2, 3), "just joined")
		h.ok(R.allowed(HUB))
	end)

	h.test("countdown and boss intro hold: blocked until GO, named by mode", function()
		h.eq(R.blockReason(with({ mode = "race", now = 100, goTime = 104 })), "countdown")
		h.eq(R.blockReason(with({ mode = "boss", now = 100, goTime = 112 })), "boss intro")
		h.eq(R.blockReason(with({ mode = "rematch", now = 111.9, goTime = 112 })), "boss intro")
		h.eq(R.blockReason(with({ mode = "boss", goTime = 112 })), "boss intro", "GO set but no server time: still held")
		h.eq(R.blockReason(with({ mode = "boss", now = 112, goTime = 112 })), "racing (boss)", "after GO: racing")
	end)

	h.test("racing until the player's own finish; results screen and hub allow", function()
		h.eq(R.blockReason(with({ mode = "race", now = 200, goTime = 100 })), "racing (race)")
		h.eq(R.blockReason(with({ mode = "race", now = 200, goTime = 100, finished = true })), nil, "results screen")
		h.eq(R.blockReason(with({ mode = "hub", now = 200, goTime = 100 })), nil)
		h.eq(R.blockReason(with({ mode = "", now = 200 })), nil)
	end)

	h.test("map switch and due Storm Cup: blocked, even in the hub and after a finish", function()
		h.eq(R.blockReason(with({ trackSwitching = true })), "loading a map")
		h.eq(R.blockReason(with({ trackSwitching = true, finished = true, mode = "race" })), "loading a map")
		h.eq(R.blockReason(with({ stormCupState = "due" })), "Storm Cup starting")
		h.eq(R.blockReason(with({ stormCupState = "lobby" })), nil)
	end)

	---------------------------------------------------------------------------------------------- per group (T1-7)

	-- Readers for sceneState: world = workspace (the hub's values), race = the player's own race, player = his attrs.
	local function reads(perGroup: boolean, world: { [string]: any }, race: { [string]: any }, player: { [string]: any }, state: any, now: number?): any
		return {
			perGroup = perGroup,
			world = function(n: string): any
				return world[n]
			end,
			race = function(n: string): any
				return race[n]
			end,
			player = function(n: string): any
				return player[n]
			end,
			instanceState = function(): any
				return state
			end,
			now = function(): number
				return now or 0
			end,
		}
	end
	local HUBW = { RaceMode = "hub" }

	h.test("T1-7: per group, the player's own countdown / boss intro / race blocks while workspace says hub", function()
		local seated = { RaceInstanceId = 3 }
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "race", RaceGoTime = 104 }, seated, "grid", 100))), "countdown")
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "boss", RaceGoTime = 112 }, seated, "grid", 100))), "boss intro")
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "rematch", RaceGoTime = 112 }, seated, "grid", 105))), "boss intro")
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "race", RaceGoTime = 100 }, seated, "racing", 200))), "racing (race)")
		local done = { RaceInstanceId = 3, RaceFinished = true }
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "race", RaceGoTime = 100 }, done, "results", 200))), nil, "his results screen")
	end)

	h.test("T1-7: per group, a missing or loading instance root blocks; an arch lobby queue does not", function()
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, HUBW, { RaceInstanceId = 3 }, nil))), "loading a map", "root not there yet")
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, { RaceMode = "race" }, { RaceInstanceId = 3 }, "loading"))), "loading a map")
		-- Same as the single-race lobby: queued for a RACING arch can be a whole race away, the Garage stays open.
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, HUBW, { LobbyArch = "SNOW-1" }, nil))), nil, "queued in the hub")
	end)

	h.test("T1-7: per group, a hub player is not blocked by another group's race; server-wide blocks still apply", function()
		-- Another group's countdown lives on its own root; this hub player reads workspace (hub) through RaceAttr.
		h.eq(R.sceneBlock(R.sceneState(reads(true, HUBW, HUBW, {}, nil, 100))), nil)
		h.eq(R.sceneBlock(R.sceneState(reads(true, { RaceMode = "hub", StormCupState = "due" }, HUBW, {}, nil))), "Storm Cup starting")
		h.eq(R.sceneBlock(R.sceneState(reads(true, { RaceMode = "hub", TrackSwitching = true }, HUBW, {}, nil))), "loading a map")
	end)

	h.test("T1-7: single-race path unchanged (no seat / lobby fields; race reads are workspace)", function()
		local st = R.sceneState(reads(false, {}, { RaceMode = "race", RaceGoTime = 104 }, { RaceInstanceId = 3, LobbyArch = "SNOW-1" }, nil, 100))
		h.eq(st.seated, nil)
		h.eq(st.instanceState, nil)
		h.eq(R.sceneBlock(st), "countdown")
		h.eq(R.sceneBlock(R.sceneState(reads(false, {}, { RaceMode = "hub" }, {}, nil))), nil)
		h.eq(R.sceneBlock(R.sceneState(reads(false, {}, { RaceMode = "race", RaceGoTime = 0 / 0 }, {}, nil, 5))), "racing (race)", "NaN GO is no hold")
	end)

	h.test("T1-7: Economy.liveBusy reads the player's instance when PER_GROUP is on", function()
		local econ = h.readFile("src/server/Economy.luau")
		local body = string.match(econ, "local function liveBusy%(player: Player%): string%?(.-)\nend\n")
		h.ok(body ~= nil, "liveBusy found")
		h.ok(not string.find(body :: string, 'workspace:GetAttribute%("RaceMode"%)'), "no workspace RaceMode read")
		h.ok(not string.find(body :: string, 'workspace:GetAttribute%("RaceGoTime"%)'), "no workspace RaceGoTime read")
		h.contains(body, "RaceAttr.rootOf(player)")
	end)

	h.test("static: every purchase prompt goes through promptGate, which asks this rule; clients never prompt", function()
		local econ = h.readFile("src/server/Economy.luau")
		h.contains(econ, 'require(Shared:WaitForChild("PromptPolicyRules"))')
		h.contains(econ, "PromptPolicyRules.joinBlock(clock() - st.joinedAt, svcCfg.joinPromptGraceSeconds)")
		h.contains(econ, "return PromptPolicyRules.sceneBlock(PromptPolicyRules.sceneState({")
		h.contains(econ, "return RaceAttr.get(name, player)", "T1-7: race attributes come from the player's own race")
		h.contains(econ, "perGroup = RaceFlowRules.PER_GROUP")
		local _, prompts = string.gsub(econ, ":Prompt%a*Purchase%(", "")
		h.eq(prompts, 2, "exactly two prompt call sites (live market adapter)")
		local cfg = h.readFile("src/shared/MonetizationConfig.luau")
		h.contains(cfg, "joinPromptGraceSeconds = 10")
		for _, path in { "src/client/Garage.luau", "src/client/Hud.client.luau" } do
			local ok, text = pcall(h.readFile, path)
			if ok and text then
				h.ok(not string.find(text, "Prompt%a*Purchase"), path .. " opens no prompt itself")
			end
		end
	end)
end
