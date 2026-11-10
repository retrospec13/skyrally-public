-- HudPhaseRules: phase detection and the visibility table of docs/design/HUD_LAYOUT.md section 6 (HUD layout v2). Where the
-- elements sit is hud_layout_spec.luau.
return function(h)
	local R = h.require("src/shared/HudPhaseRules.luau")

	h.test("phaseOf priority and countdown", function()
		h.eq(R.phaseOf("hub", nil, 0, false, false), "hub")
		h.eq(R.phaseOf("battle", nil, 0, false, false), "battle")
		h.eq(R.phaseOf("race", 100, 90, false, false), "countdown")
		h.eq(R.phaseOf("race", 100, 100, false, false), "race")
		h.eq(R.phaseOf("race", nil, 0, false, false), "race")
		h.eq(R.phaseOf("race", 100, 200, true, false), "results")
		h.eq(R.phaseOf("race", 100, 200, true, true), "podium")
		-- The finish moment: crossed, card not up yet. The card and the podium still win; it beats the mode and the grid.
		h.eq(R.phaseOf("race", 100, 200, false, false, true), "finish")
		h.eq(R.phaseOf("battle", nil, 0, false, false, true), "finish")
		h.eq(R.phaseOf("race", 100, 200, true, false, true), "results")
		h.eq(R.phaseOf("race", 100, 200, false, true, true), "podium")
		h.eq(R.phaseOf("race", 100, 200, false, false, false), "race")
		h.eq(R.phaseOf("race", 100, 200, false, false, nil), "race")
	end)

	h.test("table: nothing of the race HUD or the collectible sign during the podium", function()
		for name, row in R.VISIBLE do
			h.ok(row.podium == false, name .. " must be hidden on the podium")
		end
	end)

	-- One row per element, the phases in the spec's column order: hub, countdown, race, finish, results, podium, battle.
	local EXPECTED = {
		PositionBadge = { false, true, true, false, false, false, false },
		LapTimeChip = { false, true, true, false, false, false, false },
		ItemSlot = { true, true, true, false, false, false, true }, -- hub: the hub has cubes (item bugs audit)
		SkyTokenCounter = { true, true, true, true, true, false, true },
		SystemCluster = { true, true, true, true, true, false, true },
		RespawnButton = { true, false, true, false, false, false, true },
		ReturnButton = { false, false, true, false, false, false, false },
		StyleChainMeter = { false, false, true, false, false, false, true },
		StartRing = { false, true, false, false, false, false, false },
		Minimap = { false, true, true, false, false, false, false }, -- race minimap (client/Minimap)
		TouchControls = { true, true, true, false, false, false, true },
		MessageLane = { false, true, true, true, false, false, true },
		AssistChip = { false, true, true, false, false, false, false }, -- the ASSIST one-tap switch
	}
	local PHASES = { "hub", "countdown", "race", "finish", "results", "podium", "battle" }

	h.test("table: every section 6 row, every phase", function()
		for name, want in EXPECTED do
			for i, phase in PHASES do
				h.eq(R.visible(name, phase), want[i], name .. " in " .. phase)
			end
		end
	end)

	h.test("table: the rows are exactly the section 6 elements (no stale plank rows)", function()
		for name in R.VISIBLE do
			h.ok(EXPECTED[name] ~= nil, "unexpected row " .. name)
		end
		for name in EXPECTED do
			h.ok(R.VISIBLE[name] ~= nil, "missing row " .. name)
		end
		h.ok(R.VISIBLE.LapPlankSign == nil and R.VISIBLE.TimerPlankSign == nil and R.VISIBLE.HelpButton == nil)
	end)

	h.test("table: results hides position and lap but keeps the token chip and the system cluster; countdown hides RESPAWN", function()
		h.ok(not R.visible("PositionBadge", "results") and not R.visible("LapTimeChip", "results"))
		h.ok(R.visible("SkyTokenCounter", "results") and R.visible("SystemCluster", "results"))
		h.ok(not R.visible("RespawnButton", "countdown"))
		h.ok(not R.visible("TouchControls", "results") and not R.visible("TouchControls", "podium"))
		h.ok(R.visible("LapTimeChip", "countdown"), "the chip shows a dim 0:00.0 on the grid")
		h.ok(R.visible("StartRing", "countdown") and not R.visible("StartRing", "race"))
		h.ok(R.visible("SomethingUnlisted", "podium"))
	end)

	h.test("table: the finish moment hides touch controls, lap/time chip, position, respawn and combo; keeps the token chip and cluster", function()
		for _, name in { "TouchControls", "LapTimeChip", "PositionBadge", "RespawnButton", "StyleChainMeter", "ItemSlot", "StartRing" } do
			h.ok(not R.visible(name, "finish"), name .. " must be hidden while the finish cam runs")
		end
		h.ok(R.visible("SkyTokenCounter", "finish") and R.visible("SystemCluster", "finish"))
		h.eq(#R.PHASES, 7)
		h.eq(R.PHASES[4], "finish")
	end)

	h.test("the legacy rightColumn adapter and the timer rect are gone", function()
		h.ok(R.rightColumn == nil and R.sizeClass == nil)
	end)
end
