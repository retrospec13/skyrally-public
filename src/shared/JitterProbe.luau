--!strict
-- Studio probe for opponent jitter (docs/audits/opponent_jitter.md; tools/jitter_probe.py drives it, never shipped
-- behaviour: nothing in the game calls run() outside a Studio QA session). For `seconds` it records, every render frame
-- after the camera, its punches and RacerView have moved (RenderPriority.Last + 10, past every camera bind), each other
-- racer's hull position RELATIVE TO THE CAMERA and its viewport pixel, and summarises the frame-to-frame second
-- differences: what the eye sees as jitter is a racer whose offset from the camera does not change smoothly. A racer
-- moving steadily alongside the camera gives second differences near 0 whatever its speed; a stall-and-leap or a surge
-- shows as a spike.
--   kinds   bot/player x plane/car (BotId; IsCar / GroundRacer / VehicleType "car"), plus whether the hull is
--           anchored (a smoothed bot) or physics-owned (a remote player).
--   filters a racer more than MAX_DISTANCE studs from the camera, off screen, or inside its first frames after a
--           teleport (a frame step over TELEPORT studs) is not counted; frames whose dt is over HITCH_DT are counted
--           apart (a local hitch, not the opponent's motion).
--   own     this player's own vehicle in CAMERA space (docs/audits/plane_stutter.md C1): the chase camera should hold it
--           still on screen, so its second difference is the own-vehicle stutter. Row own_<plane|car> skips hitch
--           frames like the others; own_<plane|car>_all keeps them (the old camera follow lurched on exactly those).
--   studsT / pxT (2026-10-20 opp-smooth, docs/audits/opponent_stream.md) the same second difference with each frame
--           placed at its own time: twice the distance of the middle offset from the straight line between its
--           neighbours at their frame times. `studs` is |r2 - 2 r1 + r0|, which for a racer moving at v relative to the
--           camera also counts v * (dt2 - dt1): a perfectly drawn opponent passing at 50 studs/s scores 0.2 studs on a
--           frame pair 16 / 20 ms, and a Studio window's frame times vary that much. studsT is 0 for any motion that
--           is smooth in time whatever the frame pacing, so it is the opponent's own jitter; studs - studsT is pacing.
--   fit     the racer's own path, camera aside: its WORLD position's distance from a least-squares parabola in time
--           through the FIT_WINDOW frames around it (centre frame). Real speed changes and turns are parabolas over
--           ~0.1 s and score ~0; a pose drawn off its own smooth path by e scores about e. The cleanest "is the drawn
--           opponent jittering" number: no camera motion, no frame pacing, no true relative acceleration in it.
--   stream  RacerView's draw counters over the run (Shared.RacerStreamRules.stats): frames drawn from the stamped
--           pose stream, from the fallback property track, extrapolated, held; packets, dropped poses, cuts.
--   remote  (2026-10-20 remote-smooth) remote players' stream counters over the run (Shared.PlayerStreamRules.stats):
--           frames drawn from the player stream (drawn), blending (blend), left to the engine (engine); player poses
--           received (packets) and cuts; this client's own poses sent (sent). A player_*_physics row with drawn >>
--           engine is a remote player drawn from his stamped stream.
local JitterProbe = {}

JitterProbe.MAX_DISTANCE = 150
JitterProbe.TELEPORT = 60
JitterProbe.HITCH_DT = 1 / 30
JitterProbe.FIT_WINDOW = 7 -- frames in the own-path fit (odd)

export type Summary = { n: number, p50: number, p95: number, p99: number, max: number }

-- p50 / p95 / p99 / max of a list (sorted in place).
function JitterProbe.summarise(xs: { number }): Summary
	table.sort(xs)
	local n = #xs
	local function at(p: number): number
		if n == 0 then
			return 0
		end
		return xs[math.clamp(math.floor(p * (n - 1) + 0.5) + 1, 1, n)]
	end
	return { n = n, p50 = at(0.5), p95 = at(0.95), p99 = at(0.99), max = if n > 0 then xs[n] else 0 }
end

-- Second difference of three successive camera-relative offsets (studs) or pixels.
function JitterProbe.secondDiff(a: Vector3, b: Vector3, c: Vector3): number
	return (c - b * 2 + a).Magnitude
end

-- The same, with the three samples at times ta < tb < tc: twice the distance of b from the chord a..c at tb. Equal to
-- secondDiff for even frame times; 0 for any straight constant-velocity motion whatever the frame times.
function JitterProbe.secondDiffT(a: Vector3, b: Vector3, c: Vector3, ta: number, tb: number, tc: number): number
	local span = tc - ta
	if span <= 1e-9 then
		return JitterProbe.secondDiff(a, b, c)
	end
	local f = (tb - ta) / span
	return ((a + (c - a) * f) - b).Magnitude * 2
end

local function kindOf(m: Model, hull: BasePart): string
	local bot = m:GetAttribute("BotId") ~= nil
	local car = m:GetAttribute("IsCar") == true or m:GetAttribute("GroundRacer") == true or m:GetAttribute("VehicleType") == "car"
	return string.format("%s_%s_%s", if bot then "bot" else "player", if car then "car" else "plane", if hull.Anchored then "anchored" else "physics")
end

-- Distance of the centre sample of `ps` (odd count, times `ts`) from the least-squares parabola through all of them.
function JitterProbe.fitResidual(ps: { Vector3 }, ts: { number }): number
	local n = #ps
	local c = (n + 1) // 2
	local t0 = ts[c]
	local s0, s1, s2, s3, s4 = n, 0, 0, 0, 0
	local b0, b1, b2 = Vector3.zero, Vector3.zero, Vector3.zero
	local p0 = ps[c]
	for i = 1, n do
		local u = ts[i] - t0
		local u2 = u * u
		s1 += u
		s2 += u2
		s3 += u2 * u
		s4 += u2 * u2
		local q = ps[i] - p0 -- relative to the centre: keeps f32 positions exact enough
		b0 += q
		b1 += q * u
		b2 += q * u2
	end
	-- c0 of [s0 s1 s2; s1 s2 s3; s2 s3 s4] [c0 c1 c2] = [b0 b1 b2] by Cramer's rule
	local det = s0 * (s2 * s4 - s3 * s3) - s1 * (s1 * s4 - s3 * s2) + s2 * (s1 * s3 - s2 * s2)
	if math.abs(det) < 1e-18 then
		return 0
	end
	local c0 = (b0 * (s2 * s4 - s3 * s3) - b1 * (s1 * s4 - s3 * s2) + b2 * (s1 * s3 - s2 * s2)) / det
	return c0.Magnitude
end

-- Records for `seconds` (yields) and returns a JSON-ready table. Client only.
function JitterProbe.run(seconds: number): { [string]: any }
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local me = Players.LocalPlayer
	type Track = { kind: string, rel: { Vector3 }, px: { Vector3 }, ts: { number }, world: { Vector3 }, wts: { number }, skip: number }
	local tracks: { [Model]: Track } = {}
	local studs: { [string]: { number } } = {}
	local pixels: { [string]: { number } } = {}
	local dts: { number } = {}
	local ownRel: { Vector3 } = {} -- the own vehicle's last camera-space offsets
	local ownT: { number } = {}
	local studsT: { [string]: { number } } = {}
	local pixelsT: { [string]: { number } } = {}
	local fits: { [string]: { number } } = {}
	local clock = 0 -- frame time: the sum of this bind's dt (the clock the chase camera steps on)
	local okStats, StreamRules = pcall(function()
		return require(script.Parent:WaitForChild("RacerStreamRules", 2) :: ModuleScript) :: any
	end)
	local stats0: { [string]: number } = if okStats and StreamRules then table.clone(StreamRules.stats) else {}
	local okP, PlayerRules = pcall(function()
		return require(script.Parent:WaitForChild("PlayerStreamRules", 2) :: ModuleScript) :: any
	end)
	local pstats0: { [string]: number } = if okP and PlayerRules then table.clone(PlayerRules.stats) else {}
	local hitches = 0
	local name = "SkyRallyJitterProbe"
	local t0 = os.clock()
	local done = false
	RunService:BindToRenderStep(name, Enum.RenderPriority.Last.Value + 10, function(dt: number)
		table.insert(dts, dt)
		clock += dt
		local hitch = dt > JitterProbe.HITCH_DT
		if hitch then
			hitches += 1
		end
		local cam = workspace.CurrentCamera
		local planes = workspace:FindFirstChild("Planes")
		if not cam or not planes then
			return
		end
		local camPos = cam.CFrame.Position
		for _, m in planes:GetChildren() do
			if not m:IsA("Model") then
				continue
			end
			if m:GetAttribute("OwnerUserId") == me.UserId then
				local own = m.PrimaryPart
				if own then
					local rel = cam.CFrame:PointToObjectSpace(own.Position)
					local car = m:GetAttribute("VehicleType") == "car" or m:GetAttribute("IsCar") == true
					local key = if car then "own_car" else "own_plane"
					local o = ownRel
					if #o > 0 and (rel - o[#o]).Magnitude > JitterProbe.TELEPORT then
						table.clear(o)
						table.clear(ownT)
					end
					table.insert(o, rel)
					table.insert(ownT, clock)
					if #o >= 3 then
						local d = JitterProbe.secondDiff(o[#o - 2], o[#o - 1], o[#o])
						if not hitch then
							studsT[key] = studsT[key] or {}
							table.insert(studsT[key], JitterProbe.secondDiffT(o[#o - 2], o[#o - 1], o[#o], ownT[#o - 2], ownT[#o - 1], ownT[#o]))
						end
						studs[key .. "_all"] = studs[key .. "_all"] or {}
						table.insert(studs[key .. "_all"], d)
						if not hitch then
							studs[key] = studs[key] or {}
							table.insert(studs[key], d)
						end
					end
					if #o > 3 then
						table.remove(o, 1)
						table.remove(ownT, 1)
					end
				end
				continue
			end
			local hull = m.PrimaryPart
			if not hull then
				continue
			end
			-- what this client shows: a remote player's visual clone while one is drawn (RemoteCloneRules)
			local shown = if okP and PlayerRules and PlayerRules.visualOf then PlayerRules.visualOf(hull).Position else hull.Position
			local rel = shown - camPos
			local vp, onScreen = cam:WorldToViewportPoint(shown)
			local tr = tracks[m]
			if not tr then
				tr = { kind = kindOf(m, hull), rel = {}, px = {}, ts = {}, world = {}, wts = {}, skip = 0 }
				tracks[m] = tr
			end
			local t = tr :: Track
			local n = #t.rel
			if n > 0 and (rel - t.rel[n]).Magnitude > JitterProbe.TELEPORT then
				table.clear(t.rel)
				table.clear(t.px)
				table.clear(t.ts)
				table.clear(t.world)
				table.clear(t.wts)
				n = 0
			end
			if rel.Magnitude > JitterProbe.MAX_DISTANCE or not onScreen or vp.Z <= 0 then
				table.clear(t.rel)
				table.clear(t.px)
				table.clear(t.ts)
				table.clear(t.world)
				table.clear(t.wts)
				continue
			end
			if hitch then
				table.clear(t.world) -- a fit window spans no hitch
				table.clear(t.wts)
			end
			table.insert(t.world, shown)
			table.insert(t.wts, clock)
			if #t.world > JitterProbe.FIT_WINDOW then
				table.remove(t.world, 1)
				table.remove(t.wts, 1)
			end
			if #t.world == JitterProbe.FIT_WINDOW then
				fits[t.kind] = fits[t.kind] or {}
				table.insert(fits[t.kind], JitterProbe.fitResidual(t.world, t.wts))
			end
			table.insert(t.rel, rel)
			table.insert(t.px, Vector3.new(vp.X, vp.Y, 0))
			table.insert(t.ts, clock)
			n += 1
			if n >= 3 and not hitch then
				local key = t.kind
				studs[key] = studs[key] or {}
				pixels[key] = pixels[key] or {}
				table.insert(studs[key], JitterProbe.secondDiff(t.rel[n - 2], t.rel[n - 1], t.rel[n]))
				table.insert(pixels[key], JitterProbe.secondDiff(t.px[n - 2], t.px[n - 1], t.px[n]))
				local ta, tb, tc = t.ts[n - 2], t.ts[n - 1], t.ts[n]
				studsT[key] = studsT[key] or {}
				pixelsT[key] = pixelsT[key] or {}
				table.insert(studsT[key], JitterProbe.secondDiffT(t.rel[n - 2], t.rel[n - 1], t.rel[n], ta, tb, tc))
				table.insert(pixelsT[key], JitterProbe.secondDiffT(t.px[n - 2], t.px[n - 1], t.px[n], ta, tb, tc))
			end
			if n > 3 then
				table.remove(t.rel, 1)
				table.remove(t.px, 1)
				table.remove(t.ts, 1)
			end
		end
		if os.clock() - t0 >= seconds then
			done = true
		end
	end)
	while not done do
		task.wait(0.25)
	end
	RunService:UnbindFromRenderStep(name)
	local out: { [string]: any } = {
		seconds = seconds,
		frames = #dts,
		hitchFrames = hitches,
		frameMs = nil,
		kinds = {},
		track = workspace:GetAttribute("ActiveTrackId"),
		player = me.Name,
	}
	local ms: { number } = {}
	for _, d in dts do
		table.insert(ms, d * 1000)
	end
	out.frameMs = JitterProbe.summarise(ms)
	for key, xs in studs do
		local px = pixels[key]
		local sT, pT = studsT[key], pixelsT[key]
		out.kinds[key] = {
			studs = JitterProbe.summarise(xs),
			px = if px then JitterProbe.summarise(px) else nil,
			studsT = if sT then JitterProbe.summarise(sT) else nil,
			fit = if fits[key] then JitterProbe.summarise(fits[key]) else nil,
			pxT = if pT then JitterProbe.summarise(pT) else nil,
		}
	end
	if okStats and StreamRules then
		local d: { [string]: number } = {}
		for k, v in StreamRules.stats do
			d[k] = v - (stats0[k] or 0)
		end
		out.stream = d
	end
	if okP and PlayerRules then
		local d: { [string]: number } = {}
		for k, v in PlayerRules.stats do
			d[k] = v - (pstats0[k] or 0)
		end
		out.remote = d
	end
	return out
end

return JitterProbe
