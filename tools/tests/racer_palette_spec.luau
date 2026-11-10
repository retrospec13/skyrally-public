--!strict
-- Lune spec for Shared.RacerPaletteRules (default racer colours) plus static checks that every racer vehicle is painted
-- through it and that the identity cues exist (labels, trails, pennant, underglow, "you" marker, results swatch).
-- Usage: tools/tests/run_lune_tests.sh tools/tests/racer_palette_spec.luau

return function(h)
	local Rules = h.require("src/shared/RacerPaletteRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")
	local GarageModel = h.require("src/shared/GarageModel.luau")

	h.test("at least eight palettes with every field", function()
		h.ok(#Rules.PALETTES >= 8, "need 8+ palettes")
		local ids = {}
		for _, p in Rules.PALETTES do
			h.ok(not ids[p.id], "duplicate id " .. p.id)
			ids[p.id] = true
			for _, k in { "identity", "primary", "accent", "trim", "meshTint" } do
				local c = (p :: any)[k]
				h.ok(type(c) == "table" and #c == 3, p.id .. "." .. k)
				for i = 1, 3 do
					h.ok(c[i] >= 0 and c[i] <= 255 and c[i] == math.floor(c[i]), p.id .. "." .. k .. " channel")
				end
			end
		end
	end)

	h.test("palettes stay apart under normal, protan, deutan and tritan vision", function()
		local worst, a, b = Rules.worstPair()
		h.ok(worst >= 19, string.format("%s vs %s only %.1f apart", a, b, worst))
	end)

	h.test("every roster bot has its own signature palette", function()
		local seen = {}
		for _, cfg in PlaneConfig.AI_BOTS do
			local p = Rules.forBot(cfg.name)
			h.eq(Rules.BOT_SIGNATURE[cfg.name], p.id, cfg.name .. " uses its signature")
			h.ok(not seen[p.id], cfg.name .. " shares " .. p.id)
			seen[p.id] = true
		end
		h.eq(Rules.forBot("Blaze Wing").id, "ember", "the flame bot keeps the orange identity")
		h.eq(Rules.forBot("Mystery Racer").id, Rules.forBot("Mystery Racer").id, "unknown names hash stably")
	end)

	h.test("players on slots 1..8 get eight distinct palettes", function()
		local seen = {}
		for slot = 1, 8 do
			local p = Rules.forPlayer(slot, nil)
			h.ok(not seen[p.id], "slot " .. slot .. " repeats " .. p.id)
			seen[p.id] = true
		end
	end)

	h.test("a player never shares a palette with a bot that races (the fastest bots race first)", function()
		for players = 1, 4 do
			local worn = {}
			for i = 1, #PlaneConfig.AI_BOTS - (players - 1) do
				worn[Rules.forBot(PlaneConfig.AI_BOTS[i].name).id] = true
			end
			-- Server-side flow: bots already hold their palettes; each player skips whatever is taken.
			for slot = 1, players do
				local p = Rules.forPlayer(slot, worn)
				h.ok(not worn[p.id], string.format("%d players: slot %d collides on %s", players, slot, p.id))
				worn[p.id] = true
			end
		end
	end)

	h.test("a taken palette is skipped, a full table falls back to the slot's own", function()
		local first = Rules.forPlayer(1, nil)
		h.ok(Rules.forPlayer(1, { [first.id] = true }).id ~= first.id, "skips a taken palette")
		local all = {}
		for _, p in Rules.PALETTES do
			all[p.id] = true
		end
		h.eq(Rules.forPlayer(1, all).id, first.id, "full table")
	end)

	h.test("underglow only on the dark maps and never under LOW GRAPHICS", function()
		h.ok(Rules.underglowOn("SPACE-4", false))
		h.ok(Rules.underglowOn("DINO-4", false))
		h.ok(not Rules.underglowOn("SPACE-4", true))
		h.ok(not Rules.underglowOn("CITY-1", false))
		h.ok(not Rules.underglowOn(nil, false))
	end)

	h.test("the you marker is gone in the chase view and full in wide shots", function()
		h.eq(Rules.youAlpha(14), 0, "chase camera distance")
		h.eq(Rules.youAlpha(40), 0)
		h.ok(Rules.youAlpha(52) > 0 and Rules.youAlpha(52) < 1, "fades in")
		h.eq(Rules.youAlpha(120), 1, "start grid overview")
	end)

	h.test("a livery still wins: the palette is only the fallback paint", function()
		local lp = h.readFile("src/shared/LiveryPaint.luau")
		h.contains(lp, "local paint = livery or palettePaint(model)", "livery first, palette second")
		h.contains(lp, "function LiveryPaint.applyPalette", "applyPalette")
		h.contains(lp, 'SetAttribute("RacerColor"', "RacerColor attribute")
		h.contains(lp, "LiveryBaseColor", "base colours kept for Garage unequip")
		-- palette paint has the same shape as a livery paint, so the part roles stay the livery's.
		local p = Rules.PALETTES[1]
		local lv = GarageModel.liveryPaint({ primary = p.primary, accent = p.accent, trim = p.trim, finish = "Matte" } :: any)
		h.eq(#lv.meshTint, 3)
	end)

	h.test("every racer vehicle is painted from the palette", function()
		h.contains(h.readFile("src/server/FlightServer.luau"), "RacerPaint.paintPlayer(player, plane, idx)", "planes")
		h.contains(h.readFile("src/server/CarServer.luau"), "RacerPaint.paintPlayer(player, car, idx)", "cars")
		h.contains(h.readFile("src/server/AIRacers.luau"), "RacerPaint.paintBot(plane, rosterName, if look then look.livery else nil)", "race bots")
		h.contains(h.readFile("src/server/battle/BattleBots.luau"), "RacerPaint.paintBot(model, cfg.name, if look then look.livery else nil)", "battle bots")
		local rp = h.readFile("src/server/kit/RacerPaint.luau")
		h.contains(rp, "LiveryPaint.applyFor(player, model)", "players keep their Garage livery")
		h.contains(rp, "RacerPennant", "pennant")
		h.contains(rp, "RacerGlow", "underglow part")
		h.contains(rp, "light.Enabled = false", "underglow is off until the client turns it on")
		for _, role in { "RacerPennant", "RacerAntenna", "RacerGlow" } do
			h.ok(GarageModel.partRole(role) == nil, role .. " must not be a Garage part role")
		end
	end)

	h.test("client cues read RacerColor", function()
		local rv = h.readFile("src/client/RacerView.luau")
		h.contains(rv, 'GetAttribute("RacerColor")', "label colour")
		h.contains(rv, "RacerColorBar", "label colour bar")
		h.contains(rv, "Palette.underglowOn", "underglow rule")
		h.contains(rv, "Settings.lowGraphics()", "LOW GRAPHICS gate")
		h.contains(rv, "Palette.youAlpha", "you marker rule")
		local vfx = h.readFile("src/client/Vfx.luau")
		h.contains(vfx, 'GetAttribute("RacerColor")', "trail tint")
		h.contains(vfx, "rig.racer or CYAN", "boost ribbon tint")
		h.contains(h.readFile("src/client/RaceUI.luau"), "RacerSwatch", "results swatch")
	end)
end
