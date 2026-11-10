--!strict
-- Lune spec for the Studio-only QA steering hook (shared/QASteerRules): the Studio gate, line selection, join/rejoin switching,
-- clamped overrides, the live-server no-op, and source guards on the controller wiring (inputs only, no physics touched).
-- Run: tools/tests/run_lune_tests.sh tools/tests/qa_steer_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local Q = h.require("src/shared/QASteerRules.luau")
	local R = h.require("src/shared/RouteBranch.luau")

	local function line(id: string, style: string, join: number, rejoin: number, z0: number)
		local pts = {}
		for i = 0, 10 do
			table.insert(pts, Vector3.new(i * 20, 0, z0))
		end
		return R.makeLine(id, style, pts, join, rejoin)
	end
	local lines = { line("Alt1", "tunnel", 500, 900, 0), line("Alt2", "cliff", 1000, 1300, 50), line("Alt3", "span", 1500, 1700, 90) }

	h.test("gate: nothing is active outside Studio", function()
		h.eq(Q.enabled(false), false)
		h.eq(Q.enabled(true), true)
		h.eq(Q.axis(false, 0.5), nil)
		h.eq(Q.lineName(false, "Alt2"), nil)
	end)

	h.test("line selection: id (any case), then style, else nil", function()
		h.eq(Q.lineName(true, "Alt2"), "Alt2")
		h.eq(Q.lineName(true, ""), nil)
		h.eq(Q.lineName(true, 5), nil)
		h.eq(Q.findLine(lines, "Alt2").id, "Alt2")
		h.eq(Q.findLine(lines, "alt1").id, "Alt1")
		h.eq(Q.findLine(lines, "cliff").id, "Alt2")
		h.eq(Q.findLine(lines, "span").id, "Alt3")
		h.eq(Q.findLine(lines, "nope"), nil)
	end)

	h.test("join/rejoin switching", function()
		local l = lines[2]
		local s = Q.newState()
		h.eq(Q.step(s, l, 400, 0, 5000), nil, "far before the join")
		h.eq(s.phase, "main")
		h.eq(Q.target(s, l, 0, 40), nil, "main route while not on the line")
		h.eq(Q.step(s, l, 930, 0, 5000), "join", "inside JOIN_LEAD of the join")
		h.eq(s.phase, "line")
		local p = Q.target(s, l, 0, 40)
		h.ok(p ~= nil and (p :: Vector3).Z == 50, "pursuit point lies on the line")
		h.eq(Q.step(s, l, 1100, 100, 5000), nil, "mid line")
		h.eq(Q.step(s, l, 1290, l.length - 1, 5000), "rejoin", "end of the polyline")
		h.eq(s.phase, "done")
		h.eq(Q.target(s, l, l.length, 40), nil, "caller goes back to the main spline")
		h.eq(Q.step(s, l, 1250, l.length, 5000), nil, "not retaken at once")
		h.eq(Q.step(s, l, 3000, 0, 5000), "reset", "a later lap may take it again")
		h.eq(s.phase, "main")
		h.eq(Q.step(s, nil, 0, 0, 5000), nil)
		s.phase = "line"
		h.eq(Q.step(s, nil, 0, 0, 5000), "lost", "attribute cleared")
	end)

	h.test("pursuit runs past the line's end onto the main spline (V7A ISLAND-2 Alt2 laps 2-3)", function()
		local l = lines[2] -- cliff: pursuit distance max(35, 0.6 * lookahead) along the polyline
		local s = Q.newState()
		Q.step(s, l, 930, 0, 5000)
		h.eq(s.phase, "line")
		local p, st = Q.pursue(s, l, 50, 40, 1050, 5000)
		h.ok(p ~= nil and st == nil, "mid line: a point on the line")
		h.ok(math.abs((p :: Vector3).X - 85) < 1e-6 and (p :: Vector3).Z == 50, "35 studs along the polyline")
		-- the last metres: the point never collapses onto the end vertex (the old clamp), the rest runs on from the rejoin
		p, st = Q.pursue(s, l, l.length - 3, 40, 1290, 5000)
		h.eq(p, nil)
		h.eq(st, 1300 + 32, "rejoin + the overrun of the lookahead")
		for along = 0, l.length, 1 do
			local q, m = Q.pursue(s, l, along, 40, 1000 + along, 5000)
			if q then
				h.ok(((q :: Vector3) - Vector3.new(along, 0, 50)).Magnitude >= 35 - 1e-6, "on the line the point stays 35+ ahead")
			else
				h.ok(m ~= nil and (m :: number) - 1300 >= 35 - (l.length - along) - 1e-6, "past the end: never behind the rejoin + the remaining lookahead")
			end
		end
		-- after the line: from the car's own station once it is past the rejoin, never a fixed point behind it
		s.phase = "done"
		p, st = Q.pursue(s, l, l.length, 60, 1340, 5000)
		h.eq(p, nil)
		h.eq(st, 1400)
		p, st = Q.pursue(s, l, l.length, 60, 1280, 5000)
		h.eq(st, 1360, "not yet at the rejoin station: from the rejoin")
		s.phase = "main"
		p, st = Q.pursue(s, l, 0, 60, 1340, 5000)
		h.ok(p == nil and st == nil, "main: the caller keeps its own target")
	end)

	h.test("autopilot drift: held through a bend, released when locked to the wrong side", function()
		h.eq(Q.autoDrift(30, 110, false, 0), true, "bend at speed starts a drift")
		h.eq(Q.autoDrift(-30, 110, false, 0), true)
		h.eq(Q.autoDrift(15, 110, false, 0), false, "gentle")
		h.eq(Q.autoDrift(30, 60, false, 0), false, "slow")
		h.eq(Q.autoDrift(30, 110, true, 1), true, "into the drift: keep it")
		h.eq(Q.autoDrift(5, 110, true, 1), false, "straightened out: let go (as before)")
		-- V7A: a LEFT drift (-1) locked on the end clamp while the road bends right (+): let go, so grip steering turns right
		h.eq(Q.autoDrift(40, 99, true, -1), false, "wrong-way drift released")
		h.eq(Q.autoDrift(-40, 99, true, 1), false)
		h.eq(Q.autoDrift(-6, 99, true, 1), false)
	end)

	h.test("V8 DINO-4 Alt1 lap 3: a respawn drops the line pursuit until the next join", function()
		local l = lines[1] -- Alt1 tunnel, join 500, rejoin 900
		local s = Q.newState()
		h.eq(Q.step(s, l, 420, 0, 5000, 80, 2), "join")
		h.eq(Q.step(s, l, 530, 30, 5000, 20, 2), nil, "on the line: arrived")
		h.eq(s.arrived, true)
		-- the crash: respawn on the main route 110 studs back (past the join), 85 studs from the line, rock in between
		h.eq(Q.step(s, l, 560, 0, 5000, 85, 110), "lost", "teleport")
		h.eq(s.phase, "lost")
		h.eq(Q.target(s, l, 0, 40), nil, "main route, not the line through the rock")
		local p, st = Q.pursue(s, l, 0, 40, 560, 5000)
		h.ok(p == nil and st == nil, "the caller keeps the main route")
		for _, station in { 560, 600, 640, 760 } do
			h.eq(Q.step(s, l, station, 0, 5000, 85, 3), nil, "stays dropped at " .. station)
			h.eq(s.phase, "lost")
		end
		h.eq(Q.step(s, l, 1000, 0, 5000, 85, 3), "reset", "RESET_GAP past the join: the next lap may take it")
		h.eq(Q.step(s, l, 1010, 0, 5000, 85, 3), nil)
		h.eq(Q.step(s, l, 420, 0, 5000, 85, 3), "join", "next join")
		h.eq(s.arrived, false)
	end)

	h.test("V8: respawn before the join takes the line again; leaving the line after arriving drops it", function()
		local l = lines[1]
		local s = Q.newState()
		Q.step(s, l, 450, 0, 5000, 80, 2)
		h.eq(Q.step(s, l, 400, 0, 5000, 90, 100), "lost")
		h.eq(Q.step(s, l, 420, 0, 5000, 80, 2), "reset", "back inside JOIN_LEAD before the join")
		h.eq(Q.step(s, l, 421, 0, 5000, 80, 2), "join")
		-- never arrived: a long lateral distance on the approach is normal (the main route is 85 studs from the line)
		h.eq(Q.step(s, l, 460, 0, 5000, 85, 2), nil)
		h.eq(s.phase, "line")
		h.eq(Q.step(s, l, 520, 20, 5000, 30, 2), nil)
		h.eq(Q.step(s, l, 560, 60, 5000, 60, 2), nil, "inside LOST_DIST")
		h.eq(Q.step(s, l, 600, 80, 5000, 75, 2), "lost", "past LOST_DIST after arriving")
	end)

	h.test("join across the finish line wraps", function()
		local l = line("W", "ledge", 4950, 200, 0)
		local s = Q.newState()
		h.eq(Q.step(s, l, 4900, 0, 5000), "join")
	end)

	h.test("overrides are clamped numbers only", function()
		h.eq(Q.axis(true, 3), 1)
		h.eq(Q.axis(true, -9), -1)
		h.eq(Q.axis(true, 0.25), 0.25)
		h.eq(Q.axis(true, 0 / 0), nil)
		h.eq(Q.axis(true, "1"), nil)
		h.eq(Q.axis(true, nil), nil)
	end)

	h.test("live server: the guard clears every QA attribute", function()
		local attrs: { [string]: any } = { QAFollowLine = "Alt2", QASteer = 1, QAThrottle = 1, Keep = 7 }
		local ws = {
			GetAttribute = function(_, k: string) return attrs[k] end,
			SetAttribute = function(_, k: string, v: any) attrs[k] = v end,
		}
		h.eq(Q.guard(true, ws), false, "Studio leaves them")
		h.eq(attrs.QASteer, 1)
		h.eq(Q.guard(false, ws), true)
		h.eq(attrs.QAFollowLine, nil)
		h.eq(attrs.QASteer, nil)
		h.eq(attrs.QAThrottle, nil)
		h.eq(attrs.Keep, 7)
	end)

	h.test("wiring: gated by IsStudio, inputs only", function()
		local car = h.readFile("src/client/CarController.luau")
		local fly = h.readFile("src/client/FlightController.luau")
		local srv = h.readFile("src/server/init.server.luau")
		for _, src in { car, fly } do
			h.ok(src:find('local IS_STUDIO = RunService:IsStudio()', 1, true), "client gate")
			h.ok(src:find("QASteerRules.axis(IS_STUDIO", 1, true), "override gate")
			h.ok(src:find("if IS_STUDIO then", 1, true))
		end
		h.ok(srv:find("QASteerRules.guard(studio, workspace)", 1, true), "server guard")
		h.ok(car:find("QASteerRules.pursue(qaState, line, along, look, station, trackLength)", 1, true), "car pursues past the line end")
		h.ok(not car:find("sampleAtStation(line.rejoin + look)", 1, true), "no fixed post-rejoin point")
		for _, src in { car, fly } do
			h.ok(src:find("QASteerRules.step(qaState, line, station, along, trackLength, lateral, jump)", 1, true), "respawn and distance guard")
		end
		h.ok(car:find("QASteerRules.autoDrift(errDeg, CarController.speed, CarController.drifting, CarController.driftDir)", 1, true), "autopilot drift rule")
		local rules = h.readFile("src/shared/QASteerRules.luau")
		for _, bad in { "Adhesion", "Rescue", "beginRespawn", "CFrame", "AssemblyLinearVelocity" } do
			h.ok(not rules:find(bad, 1, true), "no " .. bad)
		end
	end)
end
