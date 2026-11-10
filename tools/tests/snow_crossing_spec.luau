-- SNOW-1 crossing cue (shared/SnowCrossingRules): an under pass and an over pass within 1 s fire the cue once, same-level
-- pairs (the start pack) never do, cooldown, departed racers, and the spotlight sweep stays on its own side of the deck edge.
return function(h)
	local R = h.require("src/shared/SnowCrossingRules.luau")
	local C = R.CENTRE
	local function at(dx: number, y: number, dz: number)
		return Vector3.new(C.X + dx, y, C.Z + dz)
	end
	local FAR = at(400, 60, 0)

	h.test("levels split by height and plan distance", function()
		h.eq(R.level(at(0, 42, 10)), "under", "river pass")
		h.eq(R.level(at(-20, 140, 0)), "over", "deck pass")
		h.eq(R.level(at(R.RADIUS + 1, 42, 0)), nil, "outside the radius")
		h.eq(R.level(at(0, 300, 0)), nil, "above both lines")
	end)

	h.test("under then over within 1 s fires once", function()
		local st = R.new()
		h.eq(R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = FAR } }, 0), nil)
		h.eq(R.step(st, { { id = "a", pos = at(0, 42, 30) }, { id = "b", pos = FAR } }, 10), nil, "one racer alone")
		local ev = R.step(st, { { id = "a", pos = at(0, 42, 0) }, { id = "b", pos = at(30, 140, 0) } }, 10.6)
		h.ok(ev ~= nil, "event")
		h.eq(ev.a, "a", "earlier pass")
		h.eq(ev.b, "b", "completing pass")
		h.ok(math.abs(ev.dt - 0.6) < 1e-6, "dt")
		h.eq(R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = at(0, 140, 0) } }, 10.7), nil, "still inside, no second event")
	end)

	h.test("passes more than 1 s apart do not fire", function()
		local st = R.new()
		R.step(st, { { id = "a", pos = at(0, 42, 20) }, { id = "b", pos = FAR } }, 5)
		local ev = R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = at(0, 140, 20) } }, 6.2)
		h.eq(ev, nil)
	end)

	h.test("same level pairs never fire (the start pack passes under together)", function()
		local st = R.new()
		h.eq(R.step(st, { { id = "a", pos = at(0, 42, 20) }, { id = "b", pos = at(0, 42, 25) } }, 1), nil, "same tick under")
		h.eq(R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = FAR }, { id = "c", pos = at(0, 42, 0) } }, 1.3), nil, "third under racer")
		h.eq(R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = FAR }, { id = "c", pos = FAR }, { id = "d", pos = at(0, 140, 0) }, { id = "e", pos = at(10, 140, 0) } }, 5), nil, "two over racers")
	end)

	h.test("over then under fires, cooldown holds, then it rearms", function()
		local st = R.new()
		local ev = R.step(st, { { id = "a", pos = at(0, 140, 20) }, { id = "b", pos = at(0, 42, 25) } }, 1)
		h.ok(ev ~= nil and ev.dt == 0, "same tick, different levels")
		R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = FAR } }, 1.5)
		h.eq(R.step(st, { { id = "a", pos = at(0, 140, 20) }, { id = "b", pos = at(0, 42, 22) } }, 2.0), nil, "cooldown")
		R.step(st, { { id = "a", pos = FAR }, { id = "b", pos = FAR } }, 3)
		local again = R.step(st, { { id = "a", pos = at(0, 140, 20) }, { id = "b", pos = at(0, 42, 22) } }, 1 + R.COOLDOWN + 0.1)
		h.ok(again ~= nil, "rearmed")
	end)

	h.test("the partner is the other level even when a same-level pass is nearer in time", function()
		local st = R.new()
		local function tick(t: number, o: Vector3, u1: Vector3, u2: Vector3)
			return R.step(st, { { id = "o", pos = o }, { id = "u1", pos = u1 }, { id = "u2", pos = u2 } }, t)
		end
		h.ok(tick(5.5, at(0, 140, 0), at(0, 42, 30), FAR) ~= nil, "first crossing starts the cooldown")
		tick(6, FAR, FAR, FAR)
		h.eq(tick(10, at(0, 140, 0), FAR, FAR), nil, "over pass inside the cooldown")
		h.eq(tick(10.4, FAR, at(0, 42, 30), FAR), nil, "under pass inside the cooldown")
		local ev = tick(10.9, FAR, FAR, at(0, 42, 30))
		h.ok(ev ~= nil, "u2 crosses o's pass once the cooldown is over")
		h.eq(ev.a, "o", "not u1, which is nearer in time but on the same level")
		h.ok(math.abs(ev.dt - 0.9) < 1e-6, "dt to the over pass")
	end)

	h.test("a racer who left is forgotten", function()
		local st = R.new()
		R.step(st, { { id = "a", pos = at(0, 140, 20) } }, 1)
		local ev = R.step(st, { { id = "b", pos = at(0, 42, 20) } }, 1.4)
		h.eq(ev, nil, "a is gone, b passes alone")
		h.eq(st.lastPass.a, nil)
	end)

	h.test("lamps sweep away from the route on their own side and aim down", function()
		for _, side in { 1, -1 } do
			for i = 0, 20 do
				local pos, look = R.lamp(side, i / 20)
				h.ok(look.Y < -0.3, "aimed down")
				h.ok(look.Z * side > 0.4, "outward from the deck edge")
				h.ok(math.abs(look.Magnitude - 1) < 1e-6, "unit")
				h.ok(math.abs(pos.Z - C.Z) > 34, "lamp outside the 34 stud half-width corridor")
				-- the beam, at full length, stays on its side of the centre line
				local tip = pos + look * R.BEAM_LENGTH
				h.ok((tip.Z - C.Z) * side > 0, "beam tip on its own side")
			end
		end
		local _, a = R.lamp(1, 0)
		local _, b = R.lamp(1, 1)
		h.ok(a.X ~= b.X, "it actually sweeps")
	end)

	h.test("envelope is 0 at the ends and 1 in the middle", function()
		h.eq(R.envelope(0), 0)
		h.eq(R.envelope(1), 0)
		h.eq(R.envelope(0.5), 1)
		h.ok(R.envelope(0.075) > 0.4 and R.envelope(0.075) < 0.6)
	end)
end
