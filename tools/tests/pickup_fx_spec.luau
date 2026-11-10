-- Pickup FX rules (shared/PickupFxRules): per-kind burst colour, collect streak gating and width.
return function(h)
	local R = h.require("src/shared/PickupFxRules.luau")

	h.test("item pods take their balloon colour, secrets their own, unknown keeps cream", function()
		h.eq(R.colorRgb("Red")[1], 255)
		h.ok(R.colorRgb("Blue")[3] > R.colorRgb("Blue")[1], "blue pod is blue")
		h.ok(R.colorRgb("token")[1] == 255 and R.colorRgb("token")[3] < 100, "token is gold")
		h.ok(R.colorRgb("key") ~= R.colorRgb("token"))
		h.ok(R.colorRgb("gear")[3] > R.colorRgb("gear")[1], "gear is steel blue")
		h.ok(R.colorRgb("cube")[3] > R.colorRgb("cube")[2], "cube is violet")
		h.ok(R.colorRgb(nil) == R.DEFAULT_RGB)
		h.ok(R.colorRgb("nonsense") == R.DEFAULT_RGB)
	end)

	h.test("every colour is a valid 0..255 triple", function()
		for _, k in { "Red", "Blue", "Yellow", "Green", "Rainbow", "Speed", "Air", "token", "key", "gear", "cube" } do
			local c = R.colorRgb(k)
			h.eq(#c, 3)
			for _, v in c do
				h.ok(v >= 0 and v <= 255)
			end
		end
	end)

	h.test("streak: off on phone, off too near or too far, on in range", function()
		h.ok(R.streakOn(20, 1))
		h.ok(not R.streakOn(20, 0.5), "phone scale drops the beam")
		h.ok(not R.streakOn(1, 1))
		h.ok(not R.streakOn(R.STREAK_MAX_DIST + 1, 1))
	end)

	h.test("streak width narrows to a thin tail and stays positive", function()
		h.ok(R.streakWidth(0) > R.streakWidth(0.5))
		h.ok(R.streakWidth(1) > 0 and R.streakWidth(2) == R.streakWidth(1))
	end)
end
