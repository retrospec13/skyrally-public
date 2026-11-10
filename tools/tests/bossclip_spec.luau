--!strict
-- Lune spec for the boss clip player's math (src/shared/bossclips/ClipMath.luau) and the baked clip modules beside it
-- (tools/bake_boss_clips.py output): quaternion normalize / nlerp / slerp edge cases, frame sampling with loop wrap and
-- one-shot clamp, crossfade and one-shot weights, pose accumulation, mask sets, the shape validator, and a shape check
-- of every src/shared/bossclips/*.luau module except ClipMath (clip names per boss kind from BossConfig, unit
-- quaternions, Wheel* / Prop bones left at rest for the procedural spin).
-- Usage: lune run tools/tests/bossclip_spec.luau   (any cwd; run_lune_tests.sh picks it up). Errors on the first failure.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd
local clipDir = root .. "/src/shared/bossclips"

local CM = luau.load(fs.readFile(clipDir .. "/ClipMath.luau"), { debugName = "ClipMath" })()

local checks, tests = 0, 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		error("FAIL " .. msg, 2)
	end
end
local function near(a: number, b: number, tol: number, msg: string)
	checks += 1
	if math.abs(a - b) > tol then
		error(string.format("FAIL %s: expected %.6f, got %.6f", msg, b, a), 2)
	end
end
local function sameRot(q: { number }, want: { number }, tol: number, msg: string)
	local d = math.abs(q[1] * want[1] + q[2] * want[2] + q[3] * want[3] + q[4] * want[4])
	checks += 1
	if 1 - d > tol then
		error(string.format("FAIL %s: {%.4f,%.4f,%.4f,%.4f} vs {%.4f,%.4f,%.4f,%.4f}", msg, q[1], q[2], q[3], q[4], want[1], want[2], want[3], want[4]), 2)
	end
end
local function test(name: string, fn: () -> ())
	tests += 1
	fn()
	print("  PASS " .. name)
end

local function aa(x: number, y: number, z: number, deg: number): { number }
	local h = math.rad(deg) / 2
	local s = math.sin(h)
	return { x * s, y * s, z * s, math.cos(h) }
end
local function pack(...: number): { number }
	return { ... }
end

-- A 4-frame loop yawing 0/30/60/90 deg on bone 1, bone 2 sliding along X; bone 3 constant (single row).
local function yawClip(loop: boolean): any
	local q, t = {}, {}
	for f = 0, 3 do
		for _, v in aa(0, 1, 0, f * 30) do
			table.insert(q, v)
		end
		for _, v in { f * 1.0, 0, 0 } do
			table.insert(t, v)
		end
	end
	return {
		frames = 4,
		loop = loop,
		channels = { { q = q }, { q = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, t = t }, { q = aa(1, 0, 0, 20), t = { 0, 2, 0 } } },
	}
end

test("normalize", function()
	local x, y, z, w = CM.normalize(0, 0, 0, 2)
	near(w, 1, 1e-9, "w")
	x, y, z, w = CM.normalize(0, 0, 0, 0)
	check(x == 0 and y == 0 and z == 0 and w == 1, "zero quaternion falls back to identity")
	x, y, z, w = CM.normalize(1, 1, 1, 1)
	near(x * x + y * y + z * z + w * w, 1, 1e-9, "unit")
end)

test("nlerp takes the short arc", function()
	local a = aa(0, 1, 0, 10)
	local b = aa(0, 1, 0, 30)
	local nb = { -b[1], -b[2], -b[3], -b[4] }
	local m = pack(CM.nlerp(a[1], a[2], a[3], a[4], nb[1], nb[2], nb[3], nb[4], 0.5))
	sameRot(m, aa(0, 1, 0, 20), 1e-6, "nlerp with b in the far hemisphere")
end)

test("slerp edge cases", function()
	local id = { 0, 0, 0, 1 }
	local q = aa(0, 0, 1, 180)
	sameRot(pack(CM.slerp(id[1], id[2], id[3], id[4], q[1], q[2], q[3], q[4], 0)), id, 1e-9, "u = 0")
	sameRot(pack(CM.slerp(id[1], id[2], id[3], id[4], q[1], q[2], q[3], q[4], 1)), q, 1e-9, "u = 1")
	sameRot(pack(CM.slerp(id[1], id[2], id[3], id[4], q[1], q[2], q[3], q[4], 0.5)), aa(0, 0, 1, 90), 1e-6, "180 deg halfway")
	-- constant angular velocity: a quarter of the way along 120 deg is 30 deg
	local b = aa(1, 0, 0, 120)
	local m = pack(CM.slerp(0, 0, 0, 1, b[1], b[2], b[3], b[4], 0.25))
	near(math.deg(CM.angle(0, 0, 0, 1, m[1], m[2], m[3], m[4])), 30, 1e-4, "slerp quarter angle")
	-- antipodal inputs are the same rotation: no spin through 360
	local a = aa(0, 1, 0, 40)
	m = pack(CM.slerp(a[1], a[2], a[3], a[4], -a[1], -a[2], -a[3], -a[4], 0.5))
	sameRot(m, a, 1e-9, "q vs -q")
	-- nearly equal: falls back without NaN
	local c = aa(0, 1, 0, 40.001)
	m = pack(CM.slerp(a[1], a[2], a[3], a[4], c[1], c[2], c[3], c[4], 0.5))
	check(m[4] == m[4], "no NaN")
	sameRot(m, aa(0, 1, 0, 40.0005), 1e-9, "nearly equal")
	-- out of [0, 1] clamps
	sameRot(pack(CM.slerp(id[1], id[2], id[3], id[4], b[1], b[2], b[3], b[4], 1.5)), b, 1e-9, "u > 1 clamps")
end)

test("sample: frames, interpolation, loop wrap", function()
	local clip = yawClip(true)
	local fps = 30
	near(CM.duration(clip, fps), 4 / 30, 1e-12, "loop duration = frames / fps")
	sameRot(pack(CM.sample(clip, 1, 0, fps)), aa(0, 1, 0, 0), 1e-9, "frame 0")
	sameRot(pack(CM.sample(clip, 1, 2 / 30, fps)), aa(0, 1, 0, 60), 1e-9, "frame 2")
	sameRot(pack(CM.sample(clip, 1, 1.5 / 30, fps)), aa(0, 1, 0, 45), 1e-5, "between frames 1 and 2")
	-- wrap: frame 3.5 blends frame 3 (90) back into frame 0 (0)
	sameRot(pack(CM.sample(clip, 1, 3.5 / 30, fps)), aa(0, 1, 0, 45), 1e-5, "3 -> 0 wrap blend")
	sameRot(pack(CM.sample(clip, 1, 4 / 30, fps)), aa(0, 1, 0, 0), 1e-9, "one period later = frame 0")
	sameRot(pack(CM.sample(clip, 1, 9 / 30, fps)), aa(0, 1, 0, 30), 1e-9, "two periods + 1")
	sameRot(pack(CM.sample(clip, 1, -1 / 30, fps)), aa(0, 1, 0, 90), 1e-9, "negative time wraps")
	local s = pack(CM.sample(clip, 2, 1.25 / 30, fps))
	near(s[5], 1.25, 1e-9, "translation lerp x")
	near(s[6], 0, 1e-12, "translation y")
	s = pack(CM.sample(clip, 2, 3.5 / 30, fps))
	near(s[5], 1.5, 1e-9, "translation wraps 3 -> 0")
	s = pack(CM.sample(clip, 3, 2.7 / 30, fps))
	sameRot(s, aa(1, 0, 0, 20), 1e-9, "constant single-row channel")
	near(s[6], 2, 1e-12, "constant translation")
	s = pack(CM.sample(clip, 9, 0.1, fps))
	check(s[4] == 1 and s[5] == 0, "missing channel = identity")
end)

test("sample: one-shot clamps", function()
	local clip = yawClip(false)
	near(CM.duration(clip, 30), 3 / 30, 1e-12, "one-shot duration = (frames - 1) / fps")
	sameRot(pack(CM.sample(clip, 1, 10, 30)), aa(0, 1, 0, 90), 1e-9, "holds the last frame")
	sameRot(pack(CM.sample(clip, 1, -1, 30)), aa(0, 1, 0, 0), 1e-9, "clamps before start")
	local one = { frames = 1, loop = true, channels = { { q = aa(0, 0, 1, 15) } } }
	sameRot(pack(CM.sample(one, 1, 0.37, 30)), aa(0, 0, 1, 15), 1e-9, "single-frame clip")
end)

test("crossfade weights", function()
	local f = CM.newFader("fly", 0.35)
	check(f.weights.fly == 1, "starts on the initial clip")
	CM.fadeTo(f, "glide")
	CM.stepFader(f, 0.175)
	near(f.weights.glide, 0.5, 1e-9, "half way")
	near(f.weights.fly, 0.5, 1e-9, "half way out")
	CM.stepFader(f, 0.175)
	near(f.weights.glide, 1, 1e-9, "done")
	check(f.weights.fly == nil, "faded-out clip pruned")
	-- retarget mid-fade: weights always sum to 1 and never go negative
	CM.fadeTo(f, "fly")
	CM.stepFader(f, 0.1)
	CM.fadeTo(f, "glide")
	for _ = 1, 20 do
		CM.stepFader(f, 0.03)
		local sum = 0
		for _, w in f.weights do
			check(w >= 0, "non-negative")
			sum += w
		end
		near(sum, 1, 1e-9, "sum 1")
	end
	near(f.weights.glide, 1, 1e-9, "back on glide")
	-- three-way: the two outgoing clips keep their ratio
	local g = CM.newFader("a", 1)
	CM.fadeTo(g, "b")
	CM.stepFader(g, 0.5)
	CM.fadeTo(g, "c")
	CM.stepFader(g, 0.5)
	near(g.weights.c, 0.5, 1e-9, "c")
	near(g.weights.a, 0.25, 1e-9, "a keeps its share of the rest")
	near(g.weights.b, 0.25, 1e-9, "b")
	-- fadeTime 0 snaps; same target is a no-op
	local h = CM.newFader("x", 0)
	CM.fadeTo(h, "y")
	CM.stepFader(h, 0.016)
	check(h.weights.y == 1 and h.weights.x == nil, "snap")
	CM.fadeTo(h, "y", 0.5)
	CM.stepFader(h, 0.016)
	check(h.weights.y == 1, "no-op retarget")
end)

test("one-shot weight ramps", function()
	near(CM.oneShotWeight(0, 0.8, 0.12, 0.2), 0, 1e-12, "starts at 0")
	near(CM.oneShotWeight(0.06, 0.8, 0.12, 0.2), 0.5, 1e-9, "half way in (smoothstep)")
	near(CM.oneShotWeight(0.4, 0.8, 0.12, 0.2), 1, 1e-12, "full in the middle")
	near(CM.oneShotWeight(0.7, 0.8, 0.12, 0.2), 0.5, 1e-9, "half way out")
	near(CM.oneShotWeight(0.8, 0.8, 0.12, 0.2), 0, 1e-12, "ends at 0")
	check(CM.oneShotWeight(-0.1, 0.8, 0.12, 0.2) == 0 and CM.oneShotWeight(0.9, 0.8, 0.12, 0.2) == 0, "0 outside")
	local prev = 0
	for i = 0, 12 do
		local w = CM.oneShotWeight(i * 0.01, 0.8, 0.12, 0.2)
		check(w >= prev, "monotone fade in")
		prev = w
	end
	-- shorter than both fades: never reaches 1, still 0 at both ends
	check(CM.oneShotWeight(0.1, 0.2, 0.12, 0.2) < 1, "short clip")
end)

test("pose accumulation and overlay", function()
	local acc = CM.newAcc()
	local a, b = aa(0, 1, 0, 0), aa(0, 1, 0, 60)
	CM.accumulate(acc, 0.5, a[1], a[2], a[3], a[4], 0, 0, 0)
	CM.accumulate(acc, 0.5, b[1], b[2], b[3], b[4], 2, 0, 0)
	sameRot(acc, aa(0, 1, 0, 30), 1e-4, "equal weights blend half way")
	near(acc[5], 1, 1e-9, "translation average")
	CM.accumulate(acc, 0, 1, 0, 0, 0, 9, 9, 9)
	near(acc[5], 1, 1e-9, "zero weight ignored")
	CM.resetAcc(acc)
	CM.accumulate(acc, 0.25, b[1], b[2], b[3], b[4], 4, 0, 0)
	sameRot(acc, b, 1e-9, "a single pose at any weight is itself")
	CM.accumulate(acc, 0.75, a[1], a[2], a[3], a[4], 0, 0, 0)
	near(acc[5], 1, 1e-9, "weighted translation")
	local c = aa(1, 0, 0, 90)
	CM.resetAcc(acc)
	CM.accumulate(acc, 1, 0, 0, 0, 1, 0, 0, 0)
	CM.overlay(acc, 0.5, c[1], c[2], c[3], c[4], 0, 4, 0)
	sameRot(acc, aa(1, 0, 0, 45), 1e-6, "overlay slerps by its weight")
	near(acc[6], 2, 1e-9, "overlay translation")
	CM.overlay(acc, 1, c[1], c[2], c[3], c[4], 0, 4, 0)
	sameRot(acc, c, 1e-9, "full overlay replaces")
end)

test("mask set and validator", function()
	local good = { fps = 30, bones = { "Root", "Head", "WheelFL" }, clips = { idle = yawClip(true), hit = yawClip(false) } }
	good.clips.hit.mask = { "Head" }
	local ok, err = CM.validate(good)
	check(ok, "valid module rejected: " .. tostring(err))
	local set = CM.maskSet(good, good.clips.hit)
	check(set ~= nil and set[2] == true and set[1] == nil, "mask -> bone indices")
	check(CM.maskSet(good, good.clips.idle) == nil, "no mask = all bones")
	local function bad(mutate: (any) -> (), why: string)
		local m = { fps = 30, bones = { "Root", "Head", "WheelFL" }, clips = { idle = yawClip(true) } }
		mutate(m)
		local okb = CM.validate(m)
		check(not okb, "validator accepted " .. why)
	end
	bad(function(m)
		m.fps = 0
	end, "fps 0")
	bad(function(m)
		m.bones = { "Root", "Root", "X" }
	end, "duplicate bones")
	bad(function(m)
		table.remove(m.clips.idle.channels)
	end, "missing channel")
	bad(function(m)
		m.clips.idle.channels[1].q[1] = 0.9
	end, "non-unit quaternion")
	bad(function(m)
		local q = m.clips.idle.channels[1].q
		q[5], q[6], q[7], q[8] = -q[5], -q[6], -q[7], -q[8]
	end, "hemisphere flip")
	bad(function(m)
		m.clips.idle.mask = { "Tail" }
	end, "mask on an unknown bone")
	bad(function(m)
		m.clips.idle.frames = 2.5
	end, "fractional frames")
	bad(function(m)
		table.remove(m.clips.idle.channels[2].t :: any)
	end, "short translation track")
	bad(function(m)
		m.clips.idle.speedRef = -3
	end, "negative speedRef")
	bad(function(m)
		m.clips = {}
	end, "no clips")
end)

-- Every baked module in the folder: shape, clip set for the boss kind, unit quaternions, mechanical bones at rest.
test("baked modules in src/shared/bossclips", function()
	local BossConfig = luau.load(fs.readFile(root .. "/src/shared/BossConfig.luau"), {
		debugName = "BossConfig",
		environment = { Color3 = roblox.Color3 },
	})()
	local byModule: { [string]: any } = {}
	for _, b in BossConfig.BY_ZONE do
		if b.clips then
			byModule[b.clips] = b
		end
	end
	local n = 0
	for _, file in fs.readDir(clipDir) do
		local name = string.match(file, "^(.+)%.luau$")
		if not name or name == "ClipMath" then
			continue
		end
		n += 1
		local text = fs.readFile(clipDir .. "/" .. file)
		check(#text < 200 * 1024, name .. " is under 200 KB")
		check(string.sub(text, 1, 9) == "--!strict", name .. " starts with --!strict")
		local mod = luau.load(text, { debugName = name })()
		local ok, err = CM.validate(mod)
		check(ok, name .. ": " .. tostring(err))
		local boss = byModule[name]
		check(boss ~= nil, name .. " is referenced by a BossConfig clips field")
		local required: { string }
		if boss.vehicle == "plane" then
			required = { "fly", "hit", "roar", "attack" }
			check(mod.clips.glide ~= nil or mod.clips.hover ~= nil, name .. " has glide or hover")
		elseif mod.clips.walk then
			required = { "walk", "idle", "hit", "roar", "attack" }
			check(mod.clips.walk.speedRef ~= nil, name .. " walk has speedRef")
		else
			required = { "drive", "idle", "hit", "roar", "attack" }
		end
		for _, c in required do
			check(mod.clips[c] ~= nil, name .. " has clip " .. c)
		end
		for _, c in { "fly", "glide", "hover", "walk", "idle", "drive" } do
			if mod.clips[c] then
				check(mod.clips[c].loop, name .. " " .. c .. " loops")
			end
		end
		for _, c in { "hit", "roar", "attack" } do
			if mod.clips[c] then
				check(not mod.clips[c].loop, name .. " " .. c .. " is a one-shot")
			end
		end
		for cname, clip in mod.clips do
			for bi, bone in mod.bones do
				local mechanical = string.sub(bone, 1, 5) == "Wheel" or bone == "Prop"
				for _, tt in { 0, 0.21, 0.5, 1.37 } do
					local s = pack(CM.sample(clip, bi, tt, mod.fps))
					near(s[1] * s[1] + s[2] * s[2] + s[3] * s[3] + s[4] * s[4], 1, 1e-3, name .. " " .. cname .. " " .. bone .. " unit")
					if mechanical then
						sameRot(s, { 0, 0, 0, 1 }, 1e-6, name .. " " .. cname .. " " .. bone .. " stays at rest (procedural spin)")
					end
				end
			end
		end
		print(string.format("    %s: %d bones, %d bytes", name, #mod.bones, #text))
	end
	print(string.format("    %d baked module(s) checked", n))
end)

print(string.format("bossclip_spec: %d tests, %d checks passed", tests, checks))
