--!strict
-- Lune spec for creature vehicles (owner 2026-10-21: the rideable Void Dragon): src/shared/VehicleCreatureRules.luau
-- (flight state -> clips, bank, LOD, the chase-camera bound) and static checks on the creature path in
-- server/PlaneBuilder + server/kit/CreatureMesh and client/VehicleCreatureAnimator (the boss clip math reused, no fork).
-- Run: tools/tests/run_lune_tests.sh tools/tests/vehicle_creature_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/VehicleCreatureRules.luau")
	local AvatarConfig = h.require("src/shared/AvatarConfig.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")
	local RacerViewRules = h.require("src/shared/RacerViewRules.luau")
	local PlayerStreamRules = h.require("src/shared/PlayerStreamRules.luau")

	local function input(over: { [string]: any }?): any
		local i: any = { grid = false, speed = 110, climb = 0, accel = 0, throttle = nil, boosting = false, hitAge = math.huge }
		for k, v in pairs(over or {}) do
			i[k] = v
		end
		return i
	end

	h.test("state: hover on the grid / stopped, boost while boosting, fly when throttling or climbing, glide cruising or diving", function()
		h.eq(R.wanted(input({ grid = true })), "hover", "countdown")
		h.eq(R.wanted(input({ grid = true, boosting = true })), "hover", "the grid wins over a boost")
		h.eq(R.wanted(input({ speed = 2 })), "hover", "nearly stopped")
		h.eq(R.wanted(input({ boosting = true })), "boost")
		h.eq(R.wanted(input({ throttle = 1 })), "fly", "throttling")
		h.eq(R.wanted(input({ climb = 20 })), "fly", "climbing")
		h.eq(R.wanted(input({ speed = 40 })), "fly", "slow")
		h.eq(R.wanted(input({ hitAge = 0.3 })), "fly", "just hit")
		h.eq(R.wanted(input({ accel = 12 })), "fly", "accelerating (remote: no throttle reading)")
		h.eq(R.wanted(input({ throttle = 0 })), "glide", "cruising level, no throttle")
		h.eq(R.wanted(input({})), "glide", "remote cruising level")
		h.eq(R.wanted(input({ climb = -30, accel = 15 })), "glide", "a dive speeds up by itself: still a glide")
		h.eq(R.wanted(input({ climb = -30, throttle = 1 })), "fly", "diving under throttle flaps")
	end)

	h.test("state: fly <-> glide waits HOLD (no flicker); hover and boost switch at once", function()
		local st = R.newState()
		h.eq(st.base, "hover")
		h.eq(R.stepBase(st, input({ throttle = 1 }), 1 / 60), "fly", "leaving hover is instant")
		local base = "fly"
		local t = 0
		while base == "fly" and t < 2 do
			base = R.stepBase(st, input({ throttle = 0 }), 1 / 60)
			t += 1 / 60
		end
		h.eq(base, "glide")
		h.ok(math.abs(t - R.HOLD) < 0.05, "glide after HOLD, got " .. t)
		-- A bump shorter than HOLD does not switch.
		R.stepBase(st, input({ throttle = 1 }), 0.2)
		h.eq(R.stepBase(st, input({ throttle = 0 }), 0.2), "glide")
		h.eq(R.stepBase(st, input({ boosting = true }), 1 / 60), "boost", "boost at once")
		h.eq(R.stepBase(st, input({ grid = true }), 1 / 60), "hover", "grid at once")
	end)

	h.test("bank: dead zone, signed ramp capped at BANK_MAX, eased frame-rate independently", function()
		h.eq(R.bankTarget(0), 0)
		h.eq(R.bankTarget(R.TURN_DEAD), 0)
		h.ok(R.bankTarget(40) > 0 and R.bankTarget(-40) < 0, "sign follows the turn (+ right)")
		h.eq(R.bankTarget(500), R.BANK_MAX)
		h.eq(R.bankTarget(-500), -R.BANK_MAX)
		h.eq(R.bankTarget(0 / 0), 0, "NaN is no turn")
		local a, b = R.newState(), R.newState()
		for _ = 1, 60 do
			R.stepBank(a, 90, 1 / 60)
		end
		for _ = 1, 30 do
			R.stepBank(b, 90, 1 / 30)
		end
		h.ok(math.abs(a.bank - b.bank) < 1e-6, "same weight at 60 and 30 fps")
		local has = { bankL = {}, bankR = {} }
		local l, r = R.bankWeights(0.5, has)
		h.eq({ l, r }, { 0, 0.5 })
		l, r = R.bankWeights(-0.5, has)
		h.eq({ l, r }, { 0.5, 0 })
		l, r = R.bankWeights(-0.5, {})
		h.eq({ l, r }, { 0, 0 }, "no bank clips: nothing")
	end)

	h.test("clips: missing clips fall back and never error", function()
		local full = { hover = 1, fly = 1, glide = 1, boost = 1 }
		for _, n in R.BASE do
			h.eq(R.resolve(n, full), n)
		end
		h.eq(R.resolve("boost", { fly = 1 }), "fly")
		h.eq(R.resolve("hover", { glide = 1, fly = 1 }), "glide")
		h.eq(R.resolve("glide", { fly = 1 }), "fly")
		h.eq(R.resolve("fly", {}), nil)
	end)

	h.test("LOD: the local mount always; full rate near (phone budget), throttled far, nothing out of view or past the cull", function()
		h.eq(R.lodStep(5000, true, false, false, 99), 0, "local mount always every frame")
		h.eq(R.lodStep(100, false, false, true, 0), 0)
		h.eq(R.lodStep(100, false, false, true, R.MAX_FULL_RATE), R.MID_STEP, "over the per-frame budget: throttled")
		h.eq(R.lodStep(300, false, false, true, 0), R.MID_STEP)
		h.ok((R.lodStep(600, false, false, true, 0) :: number) > R.MID_STEP, "far: slower")
		h.ok((R.lodStep(600, false, true, true, 0) :: number) >= (R.lodStep(600, false, false, true, 0) :: number), "far bots no faster than players")
		h.eq(R.lodStep(100, false, true, false, 0), nil, "bots out of view: nothing")
		h.eq(R.lodStep(R.CULL_DISTANCE + 1, false, false, true, 0), nil, "past the cull: nothing")
		h.ok(R.CULL_DISTANCE <= PlayerStreamRules.RELAY_RANGE, "inside the stream relay range")
		h.ok(R.inView(Vector3.new(0, 0, -50), Vector3.new(0, 0, -1)))
		h.ok(not R.inView(Vector3.new(0, 0, 50), Vector3.new(0, 0, -1)), "behind the camera")
	end)

	h.test("camera bound: the fitted dragon never reaches the creature chase camera or crosses its eye line", function()
		h.eq(R.CAM_DISTANCE, PlaneConfig.CAM_DISTANCE, "matches the plane chase camera (the floor)")
		h.eq(R.CAM_HEIGHT, PlaneConfig.CAM_HEIGHT)
		h.eq(R.NEAR_CLEAR, RacerViewRules.NEAR_CLEAR)
		local d = AvatarConfig.VOID_DRAGON
		local L = R.fitLength((d.length or 16) * (d.scale or 1), d.reach, d.offset)
		h.ok(L >= 24 - 1e-9, "1.5x the first 16-stud cut, not shrunk by the fit, got " .. L)
		local back, up = R.extent(L, d.reach, d.offset)
		local dist, height = R.camera(L, d.reach, d.offset)
		h.ok(dist > R.CAM_DISTANCE and dist <= R.MAX_CAM_DISTANCE, "creature camera is further back: " .. dist)
		h.ok(height >= R.CAM_HEIGHT and height <= R.MAX_CAM_HEIGHT, "and higher: " .. height)
		h.ok(dist - back >= R.NEAR_CLEAR + R.CAM_MARGIN - 1e-9, string.format("tail tip %.2f behind, camera %.2f: the near band stays empty", back, dist))
		h.ok(up <= height - R.UP_MARGIN + 1e-9, string.format("wing tips %.2f above the hull, camera %.2f: under the eye line", up, height))
		local wing, tail = R.tips(L, d.reach, d.offset)
		h.ok(wing * 2 > PlaneConfig.CAM_DISTANCE * 1.4, "wingspan " .. wing * 2 .. " clearly exceeds the plane's ~15")
		h.eq(tail, back)
		-- Any oversized entry is shrunk to the creature camera's limits, never grown, never below the floor.
		h.ok(R.fitLength(60, { 0.6, 0.4 }, nil) <= R.REAR_FIT / 0.6 + 1e-9, "shrunk")
		local big = R.fitLength(60, { 0.6, 0.4 }, nil)
		local bd, bh = R.camera(big, { 0.6, 0.4 }, nil)
		local bb, bu = R.extent(big, { 0.6, 0.4 }, nil)
		h.ok(bd - bb >= R.NEAR_CLEAR + R.CAM_MARGIN - 1e-9 and bu <= bh - R.UP_MARGIN + 1e-9, "the bound holds for any shrunk entry")
		h.eq(R.fitLength(10, { 0.1, 0.1 }, nil), 10, "never grown")
		h.eq(R.fitLength(100, { 5, 5 }, nil), R.MIN_LENGTH, "floor")
		h.eq(select(1, R.camera(8, nil, nil)), R.CAM_DISTANCE, "a small creature keeps the plane camera")
		-- Rider proportion: the seat and the rider scale up with the body, the rider stays smaller than the dragon's neck.
		h.ok(d.seat[2] >= 3 and d.riderScale <= 0.8, "rider seated on the neck base at a proportionate scale")
	end)

	h.test("creature presentation: no belly flame, violet ember trails, plane camera untouched", function()
		local pb = h.readFile("src/server/PlaneBuilder.luau")
		h.contains(pb, "if not creatureRig then\n\t\tlocal nozzle = Instance.new(\"Attachment\")")
		local cm = h.readFile("src/server/kit/CreatureMesh.luau")
		for _, a in { "ATTR_CAM_DISTANCE", "ATTR_CAM_HEIGHT", "ATTR_WING_HALF", "ATTR_TAIL_BACK" } do
			h.contains(cm, "VehicleCreatureRules." .. a)
		end
		local fc = h.readFile("src/client/FlightController.luau")
		h.contains(fc, 'plane:GetAttribute("CreatureCamDistance") :: number?) or PlaneConfig.CAM_DISTANCE')
		local vfx = h.readFile("src/client/Vfx.luau")
		h.contains(vfx, 'makeEmitter(a, "VfxEmber"')
		h.contains(vfx, "not rig.creature")
		h.eq(R.ATTR_CAM_DISTANCE, "CreatureCamDistance")
	end)

	h.test("creature entry: looks only, and isCreature needs a model id", function()
		local d = table.clone(AvatarConfig.VOID_DRAGON)
		h.eq(R.isCreature(d), false, "no id yet")
		d.modelId = 42
		h.eq(R.isCreature(d), true)
		h.eq(R.isCreature({ modelId = 42 }), false, "static meshes keep their path")
	end)

	h.test("static: same hull and physics; the creature is welded, non-colliding, massless; no propeller; rider seated", function()
		local pb = h.readFile("src/server/PlaneBuilder.luau")
		local cm = h.readFile("src/server/kit/CreatureMesh.luau")
		h.contains(pb, "local creatureRig = if avatarMesh.kind == \"creature\" then CreatureMesh.get(")
		h.contains(pb, "local heroProp = (avatarTemplate == nil and creatureRig == nil) or avatarMesh.prop == true")
		h.contains(pb, "CreatureMesh.attach(model, hull, creatureRig, avatarMesh)")
		-- The hull is built before (and without) the avatar lookup.
		local hullAt = string.find(pb, "hull.Size = Vector3.new(4.2, 3.0, 12.0)", 1, true)
		local meshAt = string.find(pb, "AvatarRules.meshFor(avatarKey, \"plane\")", 1, true)
		h.ok(hullAt and meshAt and hullAt < meshAt, "hull first")
		for _, line in { "d.CanCollide = false", "d.CanQuery = false", "d.CanTouch = false", "d.Massless = true", "w.Part0 = hull" } do
			h.contains(cm, line)
		end
		h.contains(cm, "VehicleCreatureRules.fitLength(")
		h.contains(cm, "vehicle:SetAttribute(\"SeatAnchor\"")
		h.contains(cm, "vehicle:SetAttribute(\"PilotScale\"")
		h.ok(not string.find(cm, "hull.Size", 1, true) and not string.find(cm, "CustomPhysicalProperties", 1, true), "never touches the hull")
	end)

	h.test("static: the animator reuses the boss clip math (no fork) and reads only existing state", function()
		local an = h.readFile("src/client/VehicleCreatureAnimator.luau")
		h.contains(an, "require(Shared:WaitForChild(\"bossclips\"):WaitForChild(\"ClipMath\"))")
		for _, fn in { "ClipMath.sample(", "ClipMath.accumulate(", "ClipMath.overlay(", "ClipMath.stepFader(", "ClipMath.validate(", "ClipMath.oneShotWeight(" } do
			h.contains(an, fn)
		end
		h.ok(not string.find(an, "function slerp", 1, true) and not string.find(an, "function nlerp", 1, true), "no copied quaternion math")
		h.ok(not string.find(an, ":SetAttribute(", 1, true), "writes no attributes")
		h.ok(not string.find(an, "FireServer", 1, true), "sends nothing")
		h.contains(an, "Rules.lodStep(")
		-- Started by the guarded client boot (shared/BootRules INIT_ORDER, systems audit T1-1), required at its init step.
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "VehicleCreatureAnimator", late = true }')
	end)
end
