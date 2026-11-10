-- Hub portal fill maths (shared/PortalFillRules): the swirl sheet's frame rectangles, the mote ring, the inward speed,
-- layer rotation and the distance tiers. Plus a static check that the fill only decorates (no remotes, no gameplay).
return function(h)
	local R = h.require("src/shared/PortalFillRules.luau")

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end

	h.test("frameRect: frame 0 is the top-left 128 px, frame 9 is column 1 row 1, frame 63 the last", function()
		local x, y, w, hh = R.frameRect(0)
		h.eq(x, 0)
		h.eq(y, 0)
		h.eq(w, 128)
		h.eq(hh, 128)
		x, y = R.frameRect(9)
		h.eq(x, 128)
		h.eq(y, 128)
		x, y = R.frameRect(63)
		h.eq(x, 896)
		h.eq(y, 896)
	end)

	h.test("frameRect: out-of-range frames wrap inside the sheet", function()
		local x, y = R.frameRect(64)
		h.eq(x, 0)
		h.eq(y, 0)
		x, y = R.frameRect(-1)
		h.eq(x, 896)
		h.eq(y, 896)
	end)

	h.test("ringPoints: n points on the circle, first at the top, evenly spaced", function()
		local pts = R.ringPoints(6, 11)
		h.eq(#pts, 6)
		h.ok(near(pts[1].x, 0) and near(pts[1].y, 11))
		for _, p in pts do
			h.ok(near(math.sqrt(p.x * p.x + p.y * p.y), 11))
		end
		h.ok(near(pts[4].x, 0) and near(pts[4].y, -11))
	end)

	h.test("inwardSpeed: rim to centre in exactly the lifetime", function()
		h.ok(near(R.inwardSpeed(11, 1.7) * 1.7, 11))
		h.ok(R.inwardSpeed(11, 0) > 0)
	end)

	h.test("angle: wraps into 0..360 both ways and honours the phase", function()
		h.ok(near(R.angle(10, 36), 0))
		h.ok(near(R.angle(1, -90), 270))
		h.ok(near(R.angle(0, 50, 40), 40))
		h.ok(near(R.angle(100, 7), 340))
	end)

	h.test("tier: full inside range, far to twice that, off beyond; a phone halves both", function()
		h.eq(R.tier(100, 170, false), "full")
		h.eq(R.tier(300, 170, false), "far")
		h.eq(R.tier(400, 170, false), "off")
		h.eq(R.tier(100, 170, true), "far")
		h.eq(R.tier(200, 170, true), "off")
	end)

	h.test("texOrFallback: a non-zero id wins, 0 / nil / negative fall back", function()
		h.eq(R.texOrFallback(123, "fb"), "rbxassetid://123")
		h.eq(R.texOrFallback(0, "fb"), "fb")
		h.eq(R.texOrFallback(nil, "fb"), "fb")
		h.eq(R.texOrFallback(-5, "fb"), "fb")
	end)

	h.test("pulse and breathe: bounded, breathe is 1 +- amount", function()
		h.ok(near(R.pulse(0, 1), 0.5))
		h.ok(near(R.pulse(0.25, 1), 1))
		h.ok(near(R.pulse(0.75, 1), 0))
		h.ok(near(R.breathe(0.25, 1, 0.04), 1.04))
		h.ok(near(R.breathe(0.75, 1, 0.04), 0.96))
		h.ok(near(R.breathe(0, 1, 0.04), 1))
	end)

	h.test("static: PortalFill creates no remotes and touches no gameplay", function()
		local src = h.readFile("src/client/PortalFill.luau")
		h.ok(not string.find(src, "FireServer", 1, true))
		h.ok(not string.find(src, "RemoteEvent", 1, true))
		h.ok(string.find(src, "PortalFillRules", 1, true) ~= nil)
		h.ok(string.find(h.readFile("src/client/TrackFlow.luau"), "PortalFill.apply", 1, true) ~= nil)
	end)
end
