--!strict
-- Lune spec for remote players' visual clone (2026-10-20 remote-clone; Shared.RemoteCloneRules, client/RacerView,
-- docs/audits/opponent_stream.md "Visual clone"). Pure lifecycle math, a real Instance tree built with @lune/roblox,
-- and source guards that nothing on the clone path writes another player's hull. No Studio.
-- Run: tools/tests/run_lune_tests.sh tools/tests/remote_clone_spec.luau
return function(h)
	local P = h.require("src/shared/PlayerStreamRules.luau")
	local R = h.require("src/shared/RemoteCloneRules.luau")
	local I = h.roblox.Instance
	local DT = 1 / 60

	local function near(a: CFrame, b: CFrame): number
		return (a.Position - b.Position).Magnitude
	end

	-- The engine's pose of a remote plane at time t (200 studs/s along X) and a stream pose `ahead` studs further on.
	local function engineAt(t: number): CFrame
		return CFrame.new(200 * t, 50, 0)
	end

	h.test("switch: OFF by default, only an explicit true turns the clone on", function()
		h.eq(R.DEFAULT, false, "config default off")
		h.eq(R.ATTR, "SkyRallyRemoteClone", "the workspace attribute")
		h.eq(R.on(nil), false, "unset: off")
		h.eq(R.on(false), false, "false: off")
		h.eq(R.on("true"), false, "a string: off")
		h.eq(R.on(true), true, "true: on")
		h.eq(P.drawOn(nil), false, "and the in-place write stays off by default")
	end)

	h.test("join: built at the engine's pose (no pop at the swap), then blends onto the stream", function()
		local st = R.newState()
		local t = 0
		local draw, action = R.step(st, { enabled = true, held = false, engine = engineAt(t), stream = nil, dt = DT })
		h.eq(draw, nil, "no stream yet: the real hull shows")
		h.eq(action, "none", "nothing built")
		local first: CFrame? = nil
		local last: CFrame? = nil
		local worstStep = 0
		for i = 1, 60 do
			t += DT
			local eng = engineAt(t)
			local s = eng * CFrame.new(5, 0, 0) -- the stream 5 studs from the engine (the two delays differ)
			local d, a = R.step(st, { enabled = true, held = false, engine = eng, stream = s, dt = DT })
			h.ok(d ~= nil, "drawn while the stream is fresh")
			if i == 1 then
				h.eq(a, "create", "the first stream frame builds the clone")
				first = d
				h.ok(near(d :: CFrame, eng) < 0.05, string.format("swapped in at the engine's pose (%.3f studs)", near(d :: CFrame, eng)))
			else
				h.eq(a, "none", "built once")
				-- the clone's extra motion per frame over the engine's own (200/60 studs) stays small: no pop
				local extra = math.abs(near(d :: CFrame, last :: CFrame) - 200 * DT)
				worstStep = math.max(worstStep, extra)
			end
			last = d
			if i >= 30 then
				h.ok(near(d :: CFrame, s) < 1e-3, "after BLEND_TIME the clone is on the stream")
			end
		end
		h.ok(first ~= nil, "built")
		h.ok(worstStep < 0.5, string.format("blend-in adds under 0.5 studs a frame (%.3f)", worstStep))
	end)

	h.test("stream gap: rides the engine with the offset fading out, handed back at the engine's pose", function()
		local st = R.newState()
		local t = 0
		for _ = 1, 40 do
			t += DT
			R.step(st, { enabled = true, held = false, engine = engineAt(t), stream = engineAt(t) * CFrame.new(5, 0, 0), dt = DT })
		end
		h.eq(st.phase, "on", "drawn")
		local last: CFrame? = nil
		local gone = false
		local frames = 0
		for _ = 1, 60 do
			t += DT
			local eng = engineAt(t)
			local d, a = R.step(st, { enabled = true, held = false, engine = eng, stream = nil, dt = DT })
			frames += 1
			if a == "destroy" then
				h.eq(d, nil, "the hand-back frame draws nothing (the real hull shows)")
				h.ok(last ~= nil and near(last :: CFrame, engineAt(t - DT)) < 0.05, "the last clone frame sat on the engine's pose")
				gone = true
				break
			end
			h.ok(d ~= nil, "the clone rides the engine pose while the offset fades")
			h.ok(near(d :: CFrame, eng) <= 5.001, "never further than the last offset")
			last = d
		end
		h.ok(gone, "handed back")
		h.ok(frames <= math.ceil(P.BLEND_TIME / DT) + 1, "within BLEND_TIME")
		h.eq(st.phase, "off", "off after the hand-back")
		local d, a = R.step(st, { enabled = true, held = false, engine = engineAt(t), stream = nil, dt = DT })
		h.eq(d, nil, "stays with the real hull")
		h.eq(a, "none", "no second destroy")
	end)

	h.test("respawn cut: stream and engine far apart -> instant hand-back, rebuilt once they agree", function()
		local st = R.newState()
		local t = 0
		for _ = 1, 30 do
			t += DT
			R.step(st, { enabled = true, held = false, engine = engineAt(t), stream = engineAt(t) * CFrame.new(2, 0, 0), dt = DT })
		end
		local respawn = CFrame.new(-500, 80, 0)
		-- the stream shows the respawn first; the engine's replicated pose is still on the old line
		local d, a, cut = R.step(st, { enabled = true, held = false, engine = engineAt(t + DT), stream = respawn, dt = DT })
		h.eq(d, nil, "no clone frame between the two poses")
		h.eq(a, "destroy", "handed back at once")
		h.eq(cut, true, "counted as a cut")
		d, a = R.step(st, { enabled = true, held = false, engine = engineAt(t + 2 * DT), stream = respawn, dt = DT })
		h.eq(a, "none", "not rebuilt while they disagree")
		h.eq(d, nil, "the real hull shows")
		d, a = R.step(st, { enabled = true, held = false, engine = respawn * CFrame.new(0, 0, -0.5), stream = respawn, dt = DT })
		h.eq(a, "create", "the engine caught up: rebuilt")
		h.ok(d ~= nil and near(d :: CFrame, respawn) < 1, "at the new spot")
	end)

	h.test("server hold (anchored real hull): no clone built, a showing clone blends back", function()
		local st = R.newState()
		local eng = CFrame.new(0, 50, 0)
		local d, a = R.step(st, { enabled = true, held = true, engine = eng, stream = eng * CFrame.new(3, 0, 0), dt = DT })
		h.eq(a, "none", "nothing built over a held hull")
		h.eq(d, nil, "the real hull shows")
		for _ = 1, 30 do
			R.step(st, { enabled = true, held = false, engine = eng, stream = eng * CFrame.new(3, 0, 0), dt = DT })
		end
		local gone = false
		for _ = 1, 40 do
			local _, act = R.step(st, { enabled = true, held = true, engine = eng, stream = eng * CFrame.new(3, 0, 0), dt = DT })
			if act == "destroy" then
				gone = true
				break
			end
		end
		h.ok(gone, "held: handed back within the blend")
	end)

	h.test("switched off (or the player leaves): handed back at once", function()
		local st = R.newState()
		for _ = 1, 10 do
			R.step(st, { enabled = true, held = false, engine = CFrame.new(), stream = CFrame.new(1, 0, 0), dt = DT })
		end
		local d, a = R.step(st, { enabled = false, held = false, engine = CFrame.new(), stream = CFrame.new(1, 0, 0), dt = DT })
		h.eq(a, "destroy", "off: destroy")
		h.eq(d, nil, "the real hull shows")
		local _, a2 = R.step(st, { enabled = false, held = false, engine = CFrame.new(), stream = CFrame.new(1, 0, 0), dt = DT })
		h.eq(a2, "none", "once")
		local rv = h.readFile("src/client/RacerView.luau")
		local dropAt = string.find(rv, "local function drop(model: Model)", 1, true)
		h.ok(dropAt ~= nil and string.find(rv, "destroyClone(r)", dropAt, true) ~= nil, "a racer that leaves (or a rebuilt vehicle) drops its clone")
	end)

	h.test("hand-back restores what each real part held (the camera-near fade moved on meanwhile)", function()
		h.eq(R.restoreValue(0, 0, 0.4), 0.4, "the fade's own value: today's fade")
		h.eq(R.restoreValue(1, 0, 0.4), 1, "another module hid it (an emote stand-in): stays hidden")
		h.eq(R.restoreValue(0.25, 0.25, 0), 0, "faded then, clear now")
	end)

	-- A remote player's vehicle and seated avatar as another client sees them.
	local function rig()
		local model = I.new("Model")
		model.Name = "Plane_Alice"
		local hull = I.new("Part")
		hull.Name = "Hull"
		hull.Transparency = 1
		hull.CFrame = CFrame.new(10, 50, 0)
		hull.Parent = model
		local drive = I.new("Attachment")
		drive.Name = "Drive"
		drive.Parent = hull
		local lv = I.new("LinearVelocity")
		lv.Attachment0 = drive
		lv.Parent = hull
		local weld = I.new("WeldConstraint")
		weld.Part0 = hull
		weld.Parent = hull
		local script = I.new("Script")
		script.Parent = hull
		local rear = I.new("Attachment")
		rear.Name = "Rear"
		rear.Parent = hull
		local pe = I.new("ParticleEmitter")
		pe.Parent = rear
		local a0 = I.new("Attachment")
		a0.Parent = hull
		local a1 = I.new("Attachment")
		a1.Parent = hull
		local trail = I.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Parent = hull
		local tag = I.new("BillboardGui")
		tag.Parent = hull
		local nozzle = I.new("Attachment")
		nozzle.Name = "FlameNozzle1" -- read by Vfx for its position: carries nothing, stays
		nozzle.Parent = hull
		local body = I.new("MeshPart")
		body.Name = "Body"
		body.CFrame = CFrame.new(10, 51, -2) * CFrame.Angles(0, 0.3, 0)
		body.Parent = model
		local decal = I.new("Decal")
		decal.Parent = body
		local sa = I.new("SurfaceAppearance")
		sa.Parent = body
		local plate = I.new("SurfaceGui") -- a number plate: moves (a hidden part still shows its SurfaceGui)
		plate.Parent = body
		local prompt = I.new("ProximityPrompt")
		prompt.Parent = body
		local motor = I.new("Motor6D")
		motor.Name = "PropMotor"
		motor.Parent = body
		local seat = I.new("Seat")
		seat.Name = "PilotSeat"
		seat.CFrame = CFrame.new(10, 51, 1)
		seat.Parent = model
		local collider = I.new("Part")
		collider.Name = "Collider"
		collider.Transparency = 1
		collider.Parent = model
		local pilot = I.new("Model")
		pilot.Name = "Alice"
		pilot.Archivable = false -- characters are not archivable
		local hum = I.new("Humanoid")
		hum.Parent = pilot
		local shirt = I.new("Shirt")
		shirt.Parent = pilot
		local bc = I.new("BodyColors")
		bc.Parent = pilot
		local hrp = I.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Transparency = 1
		hrp.Parent = pilot
		local head = I.new("Part")
		head.Name = "Head"
		head.CFrame = CFrame.new(10, 53, 1)
		head.Parent = pilot
		local face = I.new("Decal")
		face.Parent = head
		local neck = I.new("Motor6D")
		neck.Parent = head
		local acc = I.new("Accessory")
		acc.Parent = pilot
		local handle = I.new("Part")
		handle.Name = "Handle"
		handle.CFrame = CFrame.new(10, 54, 1)
		handle.Parent = acc
		local mesh = I.new("SpecialMesh")
		mesh.Parent = handle
		local animate = I.new("LocalScript")
		animate.Parent = pilot
		return {
			model = model, hull = hull, body = body, seat = seat, collider = collider, pilot = pilot, head = head,
			handle = handle, hrp = hrp, drive = drive, rear = rear, a0 = a0, a1 = a1, trail = trail, tag = tag,
			nozzle = nozzle, plate = plate,
		}
	end

	h.test("build: visible parts and the hull only, look kept, nothing that runs, joins, collides, seats or is hit", function()
		local x = rig()
		local before: { [any]: CFrame } = {}
		for _, d in x.model:GetDescendants() do
			if d:IsA("BasePart") then
				before[d] = d.CFrame
			end
		end
		local c = R.build(x.model, x.pilot, x.hull, I.new)
		h.eq(c.srcs[1], x.hull, "the hull is source 1")
		h.eq(c.root, c.dsts[1], "its counterpart is the root")
		h.eq(#c.dsts, 5, "hull, body, seat, head, accessory handle (no invisible collider, no root part)")
		h.ok(c.map[x.collider] == nil and c.map[x.hrp] == nil, "invisible parts with no effects are not cloned")
		h.ok(c.map[x.body] and c.map[x.seat] and c.map[x.head] and c.map[x.handle], "every visible part has a counterpart")
		for _, d in c.dsts do
			h.ok(d.Anchored and not d.CanCollide and not d.CanQuery and not d.CanTouch and d.Massless, d.Name .. ": anchored, no collide / query / touch")
			h.ok(not d:IsDescendantOf(x.model) and not d:IsDescendantOf(x.pilot), d.Name .. ": a new part, not a source")
		end
		h.eq((c.map[x.seat] :: any).Disabled, true, "a cloned seat seats nobody")
		for _, d in c.model:GetDescendants() do
			local bad = d:IsA("LuaSourceContainer") or d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("WeldConstraint")
				or d:IsA("Attachment") or d:IsA("ProximityPrompt") or d:IsA("ParticleEmitter") or d:IsA("Trail")
				or d:IsA("BillboardGui") or d:IsA("Accessory")
			h.ok(not bad and not d:IsA("SurfaceGui"), "nothing that runs, joins or emits in the clone: " .. d.ClassName)
		end
		h.ok(c.map[x.body]:FindFirstChildOfClass("Decal") ~= nil and c.map[x.body]:FindFirstChildOfClass("SurfaceAppearance") ~= nil, "the look is kept")
		local pm = c.model:FindFirstChild("Pilot")
		h.ok(pm ~= nil, "the avatar rides in the clone")
		local hum = (pm :: any):FindFirstChildOfClass("Humanoid")
		h.ok(hum ~= nil and hum.EvaluateStateMachine == false and hum.RequiresNeck == false, "a Humanoid for the clothing only (no state machine, no neck rule)")
		h.ok((pm :: any):FindFirstChildOfClass("Shirt") ~= nil and (pm :: any):FindFirstChildOfClass("BodyColors") ~= nil, "clothing and body colours")
		h.eq(x.pilot.Archivable, false, "the character's Archivable is put back")
		h.eq(#c.visuals, 7, "5 parts + the body decal + the face (the fade writes these)")
		for part, cf in before do
			h.ok(part.CFrame == cf, part.Name .. ": a source part never moves")
		end
		h.eq(c.model.Parent, nil, "built unparented (RacerView parents it under its own client folder)")
	end)

	h.test("effects: emitters, trails and loose billboards move onto the clone; constraint and bare attachments stay", function()
		local x = rig()
		local c = R.build(x.model, x.pilot, x.hull, I.new)
		local moved: { [any]: any } = {}
		for _, mv in c.moves do
			moved[mv.inst] = mv.to
			h.ok(mv.from == x.hull or mv.from == x.body, "from the real parts")
		end
		h.eq(moved[x.rear], c.root, "the emitter attachment goes to the root")
		h.eq(moved[x.a0], c.root, "trail attachment 0")
		h.eq(moved[x.a1], c.root, "trail attachment 1")
		h.eq(moved[x.tag], c.root, "a billboard parented to the hull")
		h.eq(moved[x.plate], c.map[x.body], "a SurfaceGui goes to its part's counterpart")
		h.eq(moved[x.drive], nil, "the LinearVelocity's attachment stays on the physics hull")
		h.eq(moved[x.nozzle], nil, "a bare attachment (FlameNozzle, read by Vfx) stays")
		h.eq(#c.trails, 1, "the trail is cleared at each swap")
		-- Vfx adds an emitter after the build: newMoves finds it once, not after it moved
		local late = I.new("Attachment")
		late.Parent = x.hull
		I.new("ParticleEmitter").Parent = late
		for _, mv in c.moves do
			mv.inst.Parent = mv.to
		end
		local nm = R.newMoves(c, { x.model, x.pilot })
		h.eq(#nm, 1, "one new effect")
		h.eq(nm[1].inst, late, "the late emitter")
		nm[1].inst.Parent = nm[1].to
		h.eq(#R.newMoves(c, { x.model, x.pilot }), 0, "nothing left on the real parts")
	end)

	h.test("poses: each part at its pose in the real hull's space carried onto the drawn pose; sources untouched", function()
		local x = rig()
		local c = R.build(x.model, x.pilot, x.hull, I.new)
		local hullCF = x.hull.CFrame
		local bodyCF = x.body.CFrame
		local draw = hullCF * CFrame.new(3, 0.5, -1) * CFrame.Angles(0, 0.1, 0)
		local cfs = R.poses(c, hullCF, draw)
		h.eq(#cfs, #c.dsts, "one pose per counterpart (BulkMoveTo)")
		h.ok(cfs[1] == draw, "the root at the drawn pose")
		local ib = table.find(c.dsts, c.map[x.body]) :: number
		local want = draw * hullCF:ToObjectSpace(bodyCF)
		h.ok((cfs[ib].Position - want.Position).Magnitude < 1e-4, "the body keeps its place on the vehicle")
		h.ok(x.hull.CFrame == hullCF and x.body.CFrame == bodyCF, "the real hull and body are read, not written")
		-- a prop turns / the avatar animates on the real model: mirrored next frame
		x.head.CFrame = x.head.CFrame * CFrame.Angles(0.4, 0, 0)
		local ih = table.find(c.dsts, c.map[x.head]) :: number
		cfs = R.poses(c, hullCF, draw)
		h.ok((cfs[ih].Position - (draw * hullCF:ToObjectSpace(x.head.CFrame)).Position).Magnitude < 1e-4, "animation mirrored")
	end)

	h.test("a whole life (join, fly, gap, rejoin, cut): the engine's hull is never written by the clone path", function()
		-- The engine owns the hull: it writes its replicated pose each frame. The clone path reads it, builds, moves
		-- counterparts. After every frame the hull holds exactly what the engine wrote.
		local x = rig()
		local st = R.newState()
		local c: any = nil
		local creates, destroys = 0, 0
		local t = 0
		for i = 1, 300 do
			t += DT
			local eng = engineAt(t)
			x.hull.CFrame = eng -- the engine
			local wrote = x.hull.CFrame -- as stored
			local s: CFrame? = eng * CFrame.new(4, 0, 0)
			if i > 100 and i < 140 then
				s = nil -- out of relay range
			elseif i == 200 then
				s = CFrame.new(-900, 50, 0) -- a respawn the stream shows first
			end
			local draw, action = R.step(st, { enabled = true, held = false, engine = x.hull.CFrame, stream = s, dt = DT })
			if action == "create" then
				c = R.build(x.model, x.pilot, x.hull, I.new)
				creates += 1
			elseif action == "destroy" then
				c = nil
				destroys += 1
			end
			if draw and c then
				local cfs = R.poses(c, x.hull.CFrame, draw)
				for k, d in c.dsts do
					d.CFrame = cfs[k] -- BulkMoveTo, counterparts only
				end
			end
			h.ok(x.hull.CFrame == wrote, "frame " .. i .. ": the real hull holds the engine's pose")
		end
		h.eq(creates, 3, "built at the join, after the gap and after the cut")
		h.eq(destroys, 2, "handed back after the gap and at the cut")
	end)

	h.test("review: the prop disc is cloned and fades with the real one; a part another module un-hid is hidden again", function()
		local x = rig()
		local disc = I.new("Part")
		disc.Name = "PropDisc" -- PlaneBuilder builds it at Transparency 1; VehicleMotion fades it in with speed
		disc.Transparency = 1
		disc.Parent = x.model
		local c = R.build(x.model, x.pilot, x.hull, I.new)
		local cd = c.map[disc]
		h.ok(cd ~= nil, "the invisible prop disc has a counterpart")
		h.eq(c.map[x.collider], nil, "an invisible collider still has none")
		h.eq(R.syncLook(c), 0, "nothing to mirror at the build")
		disc.Transparency = 0.8 -- VehicleMotion at speed
		h.eq(R.syncLook(c), 1, "one write")
		h.ok(math.abs((cd :: any).Transparency - 0.8) < 1e-4, "the clone's disc shows the blur")
		h.ok(math.abs(disc.Transparency - 0.8) < 1e-4, "the real disc is only read")
		h.eq(R.syncLook(c), 0, "mirrored once (float32 both sides)")
		local hum = (c.model:FindFirstChild("Pilot") :: any):FindFirstChildOfClass("Humanoid")
		h.eq(hum.AutomaticScalingEnabled, false, "the clone's Humanoid never rescales the copied parts")
		-- Cosmetics' emote ends with LocalTransparencyModifier = 0 on the real mesh: a ghost unless hidden again
		local hidden: { [any]: number } = { [x.body] = 0, [x.head] = 0.3 }
		x.body.LocalTransparencyModifier = 1
		x.head.LocalTransparencyModifier = 1
		h.eq(R.rehide(hidden), 0, "all hidden: nothing written")
		x.body.LocalTransparencyModifier = 0
		h.eq(R.rehide(hidden), 1, "the un-hidden mesh is hidden again")
		h.eq(x.body.LocalTransparencyModifier, 1, "no ghost at the engine's pose")
		h.eq(hidden[x.body], 0, "its prior value is kept for the hand-back")
		local rv = h.readFile("src/client/RacerView.luau")
		local body = string.sub(rv, (string.find(rv, "local function stepClone(", 1, true)) :: number, (string.find(rv, "local function stepRemote(", 1, true)) :: number)
		h.ok(string.find(body, "RClone.syncLook(c)", 1, true) ~= nil and string.find(body, "RClone.rehide(r.cloneHidden)", 1, true) ~= nil, "stepClone mirrors and re-hides each drawn frame")
	end)

	h.test("source guards: the clone path writes no real part, the switch is off by default, consumers follow the clone", function()
		local rv = h.readFile("src/client/RacerView.luau")
		local a = string.find(rv, "-- ---------------------------------------------------------------- visual clone", 1, true)
		local b = string.find(rv, "local function drop(model: Model)", 1, true)
		h.ok(a ~= nil and b ~= nil and (a :: number) < (b :: number), "the clone section")
		local section = string.sub(rv, a :: number, b :: number)
		h.ok(string.find(section, "%.CFrame%s*=") == nil, "the clone helpers write no CFrame")
		local s0 = string.find(rv, "local function stepClone(", 1, true)
		local s1 = string.find(rv, "local function stepRemote(", 1, true)
		h.ok(s0 ~= nil and s1 ~= nil and (s0 :: number) < (s1 :: number), "stepClone before stepRemote")
		local body = string.sub(rv, s0 :: number, s1 :: number)
		h.ok(string.find(body, "%.CFrame%s*=") == nil, "stepClone writes no CFrame")
		h.ok(string.find(body, "workspace:BulkMoveTo(c.dsts, RClone.poses(", 1, true) ~= nil, "it moves the clone's own parts only")
		h.ok(string.find(body, "held = hull.Anchored", 1, true) ~= nil, "a held hull hands back")
		local rules = h.readFile("src/shared/RemoteCloneRules.luau")
		h.ok(string.find(rules, "%.CFrame%s*=") == nil, "RemoteCloneRules writes no CFrame")
		-- stepRemote: the clone switch first, and it returns before the in-place code
		local remoteBody = string.sub(rv, s1 :: number, (string.find(rv, "local function stepFade(", s1, true)) :: number)
		local on = string.find(remoteBody, "if RClone.on(workspace:GetAttribute(RClone.ATTR)) then", 1, true)
		local ret = string.find(remoteBody, "stepClone(r, now, dt)\n\t\treturn", 1, true)
		local inplace = string.find(remoteBody, "hull.CFrame = drawn", 1, true)
		h.ok(on ~= nil and ret ~= nil and inplace ~= nil and (ret :: number) < (inplace :: number), "the clone path returns before the in-place write")
		h.ok(string.find(remoteBody, "if hull.Anchored or not PStream.drawOn(", 1, true) ~= nil, "the in-place write still needs its own switch")
		h.ok(string.find(rv, "elseif r.remote and not r.own then", 1, true) ~= nil, "never this player's own vehicle")
		h.ok(string.find(rv, "PStream.visuals[r.hull] = c.root", 1, true) ~= nil, "the clone is registered for visual reads")
		h.ok(string.find(h.readFile("src/client/Minimap.luau"), "PlayerStreamRules.visualOf(hull).Position", 1, true) ~= nil, "the minimap dot follows the clone")
		local rb = h.readFile("src/client/RivalBubbles.luau")
		local n = 0
		for _ in string.gmatch(rb, "Adornee = PlayerStreamRules%.visualOf%(hull%)") do
			n += 1
		end
		h.eq(n, 3, "bubbles, the rival flag and the nemesis toast adorn the clone")
		h.ok(string.find(h.readFile("src/shared/JitterProbe.luau"), "PlayerRules.visualOf(hull).Position", 1, true) ~= nil, "the probe measures what shows")
		-- the server side is unchanged: gate, relay and stamp checks stay; nothing server-side reads the clone
		local rs = h.readFile("src/server/RacerStream.luau")
		h.ok(string.find(rs, "P.admit(", 1, true) ~= nil and string.find(rs, "P.relayBuffer(", 1, true) ~= nil, "the server still gates and relays")
		for _, path in { "src/server/RacerStream.luau", "src/server/FlightServer.luau", "src/server/CarServer.luau", "src/client/CarController.luau", "src/client/FlightController.luau" } do
			h.ok(string.find(h.readFile(path), "RemoteCloneRules", 1, true) == nil, path .. " does not touch the clone")
		end
	end)
end
