return function(h)
	local P = h.require("src/shared/PaverRules.luau")
	local function near(a, b, m) h.ok(math.abs(a - b) < 1e-9, (m or "near") .. " " .. a .. " vs " .. b) end

	h.test("defaults reproduce the original deck formula", function()
		for _, cols in { 2, 3 } do
			local W = 30
			local pw = (W - 1.2) / cols
			local got = P.columns(W, cols)
			for c = 1, cols do
				near(got[c].x, (c - (cols + 1) * 0.5) * (pw + 0.30), "x")
				near(got[c].w, pw, "w")
			end
		end
	end)

	h.test("stagger keeps outer edges, widths sum, gap constant", function()
		for _, shift in { 1.4, -1.4 } do
			local W, gap = 30, 0.10
			local base = P.columns(W, 2, gap, 0)
			local got = P.columns(W, 2, gap, shift)
			near(got[1].x - got[1].w / 2, base[1].x - base[1].w / 2, "left edge")
			near(got[2].x + got[2].w / 2, base[2].x + base[2].w / 2, "right edge")
			near((got[2].x - got[2].w / 2) - (got[1].x + got[1].w / 2), gap, "seam")
			h.ok(got[1].w > 1 and got[2].w > 1)
		end
	end)

	h.test("seam position alternates and never forms a straight centre line", function()
		local seams = {}
		for i = 1, 6 do
			local cols = P.columns(30, 2, 0.10, P.shiftFor(1.4, i, 1))
			seams[i] = cols[1].x + cols[1].w / 2 + 0.05
		end
		for i = 2, 6 do
			h.ok(math.abs(seams[i] - seams[i - 1]) > 2, "adjacent segments jog")
		end
		h.eq(P.shiftFor(nil, 1, 1), 0)
	end)
end
