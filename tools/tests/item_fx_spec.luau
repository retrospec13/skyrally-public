-- Shield / respawn bubble rules (shared/ItemFxRules): tier layers, camera-safe transparency, blink and sparkle window.
return function(h)
	local R = h.require("src/shared/ItemFxRules.luau")

	h.test("hex billboard never gets more opaque than the camera-safe cap", function()
		for _, respawn in { false, true } do
			for _, blink in { false, true } do
				local t = R.hexTransparency(respawn, blink)
				h.ok(t >= 0.8, "transparency >= 0.8")
				h.ok(1 - t <= R.HEX_MAX_OPACITY + 1e-9)
			end
		end
		h.ok(R.hexTransparency(true, false) >= R.hexTransparency(false, false), "respawn bubble is the fainter one")
	end)

	h.test("phone drops swirl and ring; low graphics keeps the minimum", function()
		local full = R.bubbleLayers(false, false, false)
		h.ok(full.hex and full.swirl and full.edge and full.ring and not full.shimmer)
		local phone = R.bubbleLayers(false, true, false)
		h.ok(phone.hex and phone.edge and not phone.swirl and not phone.ring)
		local low = R.bubbleLayers(false, false, true)
		h.ok(low.hex and low.edge and not low.swirl and not low.ring)
		local rs = R.bubbleLayers(true, false, false)
		h.ok(rs.shimmer and not rs.hex and not rs.edge and not rs.swirl and not rs.ring, "respawn: shimmer only, no hex shell (v39)")
	end)

	h.test("blink window and last-second sparkle boost", function()
		h.ok(R.edgeRateMul(5) == 1 and R.edgeRateMul(0.9) == 3)
		h.ok(not R.blinking(2))
		local on, off = 0, 0
		for i = 0, 99 do
			if R.blinking(i / 100) then on += 1 else off += 1 end
		end
		h.ok(on > 30 and off > 30, "blinks both ways inside the last second")
	end)

	h.test("billboard hides with the camera in your face or out of range", function()
		h.ok(not R.billboardOn(5, 220))
		h.ok(R.billboardOn(14, 220))
		h.ok(not R.billboardOn(300, 220))
		h.ok(not R.billboardOn(nil, 220))
		h.ok(R.sparkleOn(5, 220) and not R.sparkleOn(nil, 220))
	end)

	h.test("respawn column is dropped on phone and lowers onto the hull", function()
		h.ok(R.respawnLayers(false, false).column)
		h.ok(not R.respawnLayers(true, false).column and R.respawnLayers(true, false).cloud)
		h.ok(math.abs(R.columnSpeed() * R.COLUMN_LIFE - R.COLUMN_HEIGHT) < 1e-6)
	end)

	h.test("mine drop: bigger ring and puff, three quick red / white arming blinks in ~0.6 s", function()
		local D = R.TRAP_DROP
		h.eq(D.ring, 5.5)
		h.eq(D.puffCount, 5)
		h.ok(D.ring < 7, "still no dome round the kart (v21 critic: 7 studs was too big)")
		local seq = {}
		for i = 0, D.blinks * 2 + 1 do
			table.insert(seq, R.armBlinkAt(i) or "-")
		end
		h.eq(table.concat(seq, ","), "red,-,white,-,red,-,-,-")
		h.ok(math.abs(R.armBlinkStep() * D.blinks * 2 - 0.6) < 1e-9, "the sequence lasts 0.6 s")
		local src = h.readFile("src/client/ItemClient.luau")
		h.contains(src, "ItemFxRules.TRAP_DROP.ring")
		h.contains(src, "ItemFxRules.TRAP_DROP.puffCount")
		h.contains(src, "ItemFxRules.armBlinkAt(i)")
	end)

	h.test("status shots (Frost Shot, Coin Burst): small bursts, none on the lens, coins fade before the camera", function()
		h.ok(R.isStatusSource("frost_shot") and R.isStatusSource("coin_burst") and not R.isStatusSource("missile"))
		h.eq(R.statusBurstScale("missile", true, 3), 1, "other sources keep their look")
		h.eq(R.statusBurstScale("frost_shot", false, R.CAMERA_NEAR - 0.1), nil, "inside ~12 studs: skipped")
		h.eq(R.statusBurstScale("coin_burst", true, nil), nil, "no camera: skipped")
		h.eq(R.statusBurstScale("frost_shot", false, 30), R.STATUS_BURST_SCALE)
		local selfK: number = R.statusBurstScale("coin_burst", true, 30) or 1
		local otherK: number = R.statusBurstScale("coin_burst", false, 30) or 0
		h.ok(selfK < otherK, "own kart smaller")
		h.ok(R.STATUS_BURST_SCALE <= 0.5 and R.CAMERA_NEAR >= 12)
		h.eq(R.coinTransparency(0), 1)
		h.eq(R.coinTransparency(R.CAMERA_NEAR), 1, "gone at 12 studs")
		h.eq(R.coinTransparency(R.COIN_FADE_FAR), 0)
		h.ok(R.coinTransparency(19) > 0 and R.coinTransparency(19) < 1)
		local prev = 1
		for d = 12, 26 do
			h.ok(R.coinTransparency(d) <= prev, "fades monotonically")
			prev = R.coinTransparency(d)
		end
		-- The 2.4 stud server disc, drawn at COIN_SCALE, covers at most MAX_COVERAGE of the view from the first visible stud.
		for _, fov in { 60, 70, 90 } do
			h.ok(R.screenFraction(2.4 * R.COIN_SCALE, R.CAMERA_NEAR, fov) <= R.MAX_COVERAGE, "a coin stays small at " .. fov)
			h.ok(math.abs(R.screenFraction(R.maxSpriteSize(20, fov), 20, fov) - R.MAX_COVERAGE) < 1e-9)
		end
		h.ok(R.screenFraction(2.4, 6, 70) > 0.25, "the old full-size coin at 6 studs filled the view (the V9 slab)")
		local src = h.readFile("src/client/ItemsV4Fx.luau")
		h.contains(src, "ItemFxRules.coinTransparency")
		h.contains(src, "ItemFxRules.COIN_SCALE")
		h.contains(h.readFile("src/client/ItemClient.luau"), "ItemFxRules.statusBurstScale(")
	end)
end
