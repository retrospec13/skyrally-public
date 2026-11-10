--!strict
-- Pure-Luau math for the boss clip player (BossAnimator): quaternions as (x, y, z, w) tuples, sampling of the baked clip
-- modules in this folder (tools/bake_boss_clips.py writes them from the Blender anim.glb), crossfade and one-shot weights,
-- weighted pose accumulation and a shape validator. No Roblox types, so the Lune spec (tools/tests/bossclip_spec.luau)
-- runs it as-is.
--
-- Module shape: { fps, boss?, bones = { name, ... }, clips = { [name] = Clip } }. Clip.channels[i] belongs to bones[i]
-- and holds per frame the delta D = inverse(rest) * pose in glTF node-local space: q = flat {x,y,z,w, ...} (4 per frame),
-- t = flat {x,y,z, ...} (3 per frame, glTF units; nil = never translates). A channel with a single row is constant.
-- Frame i sits at time i / fps. A loop clip lasts frames / fps and wraps from frame frames-1 back to frame 0; a one-shot
-- lasts (frames - 1) / fps and holds its last frame.

export type Channel = { q: { number }, t: { number }? }
export type Clip = { frames: number, loop: boolean, speedRef: number?, mask: { string }?, channels: { Channel } }
export type Module = { fps: number, boss: string?, bones: { string }, clips: { [string]: Clip } }
-- Crossfade state: weights sum to 1; `target` gains weight at 1 / fadeTime per second, the others give it up in proportion.
export type Fader = { weights: { [string]: number }, target: string, fadeTime: number }
-- Weighted pose accumulator: {qx, qy, qz, qw, tx, ty, tz, weightSum}.
export type Acc = { number }

local ClipMath = {}

local EPS = 1e-9

function ClipMath.normalize(x: number, y: number, z: number, w: number): (number, number, number, number)
	local n = math.sqrt(x * x + y * y + z * z + w * w)
	if n < EPS then
		return 0, 0, 0, 1
	end
	return x / n, y / n, z / n, w / n
end

-- Normalized lerp along the short arc (b is flipped into a's hemisphere). Cheap and exact enough between adjacent frames.
function ClipMath.nlerp(
	ax: number, ay: number, az: number, aw: number,
	bx: number, by: number, bz: number, bw: number,
	u: number
): (number, number, number, number)
	if ax * bx + ay * by + az * bz + aw * bw < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
	end
	return ClipMath.normalize(ax + (bx - ax) * u, ay + (by - ay) * u, az + (bz - az) * u, aw + (bw - aw) * u)
end

-- Constant-velocity spherical interpolation along the short arc; falls back to nlerp for nearly equal rotations.
function ClipMath.slerp(
	ax: number, ay: number, az: number, aw: number,
	bx: number, by: number, bz: number, bw: number,
	u: number
): (number, number, number, number)
	if u <= 0 then
		return ClipMath.normalize(ax, ay, az, aw)
	elseif u >= 1 then
		local d = ax * bx + ay * by + az * bz + aw * bw
		if d < 0 then
			return ClipMath.normalize(-bx, -by, -bz, -bw)
		end
		return ClipMath.normalize(bx, by, bz, bw)
	end
	local d = ax * bx + ay * by + az * bz + aw * bw
	if d < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
		d = -d
	end
	if d > 0.9995 then
		return ClipMath.nlerp(ax, ay, az, aw, bx, by, bz, bw, u)
	end
	local th = math.acos(math.min(d, 1))
	local s = math.sin(th)
	local wa = math.sin((1 - u) * th) / s
	local wb = math.sin(u * th) / s
	return ClipMath.normalize(ax * wa + bx * wb, ay * wa + by * wb, az * wa + bz * wb, aw * wa + bw * wb)
end

-- Rotation angle in radians between two unit quaternions (sign-agnostic).
function ClipMath.angle(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number): number
	local d = math.abs(ax * bx + ay * by + az * bz + aw * bw)
	return 2 * math.acos(math.min(d, 1))
end

function ClipMath.smoothstep(x: number): number
	local c = math.clamp(x, 0, 1)
	return c * c * (3 - 2 * c)
end

function ClipMath.duration(clip: Clip, fps: number): number
	if clip.loop then
		return clip.frames / fps
	end
	return math.max(clip.frames - 1, 0) / fps
end

-- Frame indices (1-based row numbers) and blend factor for `time` seconds into the clip.
function ClipMath.frameAt(clip: Clip, time: number, fps: number): (number, number, number)
	local n = clip.frames
	if n <= 1 then
		return 1, 1, 0
	end
	local f = time * fps
	if clip.loop then
		f = f % n
		local i0 = math.floor(f)
		local i1 = if i0 + 1 >= n then 0 else i0 + 1
		return i0 + 1, i1 + 1, f - i0
	end
	f = math.clamp(f, 0, n - 1)
	local i0 = math.floor(f)
	local i1 = math.min(i0 + 1, n - 1)
	return i0 + 1, i1 + 1, f - i0
end

-- Delta of bone `boneIndex` at `time`: qx, qy, qz, qw, tx, ty, tz (translation in glTF units).
function ClipMath.sample(clip: Clip, boneIndex: number, time: number, fps: number): (number, number, number, number, number, number, number)
	local ch = clip.channels[boneIndex]
	if not ch then
		return 0, 0, 0, 1, 0, 0, 0
	end
	local r0, r1, u = ClipMath.frameAt(clip, time, fps)
	local q = ch.q
	local qx, qy, qz, qw
	if #q <= 4 then
		qx, qy, qz, qw = q[1], q[2], q[3], q[4]
	else
		local a, b = (r0 - 1) * 4, (r1 - 1) * 4
		qx, qy, qz, qw = ClipMath.nlerp(q[a + 1], q[a + 2], q[a + 3], q[a + 4], q[b + 1], q[b + 2], q[b + 3], q[b + 4], u)
	end
	local t = ch.t
	if not t then
		return qx, qy, qz, qw, 0, 0, 0
	elseif #t <= 3 then
		return qx, qy, qz, qw, t[1], t[2], t[3]
	end
	local a, b = (r0 - 1) * 3, (r1 - 1) * 3
	return qx, qy, qz, qw, t[a + 1] + (t[b + 1] - t[a + 1]) * u, t[a + 2] + (t[b + 2] - t[a + 2]) * u, t[a + 3] + (t[b + 3] - t[a + 3]) * u
end

-- Weighted pose accumulation (incremental nlerp): add poses in any order, read acc[1..7] once acc[8] > 0.
function ClipMath.newAcc(): Acc
	return { 0, 0, 0, 1, 0, 0, 0, 0 }
end

function ClipMath.resetAcc(acc: Acc)
	acc[1], acc[2], acc[3], acc[4], acc[5], acc[6], acc[7], acc[8] = 0, 0, 0, 1, 0, 0, 0, 0
end

function ClipMath.accumulate(acc: Acc, weight: number, qx: number, qy: number, qz: number, qw: number, tx: number, ty: number, tz: number)
	if weight <= 0 then
		return
	end
	local sum = acc[8]
	if sum <= 0 then
		acc[1], acc[2], acc[3], acc[4], acc[5], acc[6], acc[7], acc[8] = qx, qy, qz, qw, tx, ty, tz, weight
		return
	end
	local u = weight / (sum + weight)
	acc[1], acc[2], acc[3], acc[4] = ClipMath.nlerp(acc[1], acc[2], acc[3], acc[4], qx, qy, qz, qw, u)
	acc[5] += (tx - acc[5]) * u
	acc[6] += (ty - acc[6]) * u
	acc[7] += (tz - acc[7]) * u
	acc[8] = sum + weight
end

-- Overlay a pose on the accumulated one with weight w in [0, 1] (one-shot layer): slerp / lerp toward it.
function ClipMath.overlay(acc: Acc, w: number, qx: number, qy: number, qz: number, qw: number, tx: number, ty: number, tz: number)
	if w <= 0 then
		return
	end
	acc[1], acc[2], acc[3], acc[4] = ClipMath.slerp(acc[1], acc[2], acc[3], acc[4], qx, qy, qz, qw, w)
	acc[5] += (tx - acc[5]) * w
	acc[6] += (ty - acc[6]) * w
	acc[7] += (tz - acc[7]) * w
end

function ClipMath.newFader(initial: string, fadeTime: number): Fader
	return { weights = { [initial] = 1 }, target = initial, fadeTime = fadeTime }
end

-- Start fading toward `name` (no-op when it is already the target). A fadeTime <= 0 snaps on the next step.
function ClipMath.fadeTo(f: Fader, name: string, fadeTime: number?)
	if fadeTime then
		f.fadeTime = fadeTime
	end
	if f.target == name then
		return
	end
	f.target = name
	if not f.weights[name] then
		f.weights[name] = 0
	end
end

function ClipMath.stepFader(f: Fader, dt: number)
	local w = f.weights
	local target = f.target
	local wt = if f.fadeTime <= 0 then 1 else math.min(1, (w[target] or 0) + dt / f.fadeTime)
	local others = 0
	for name, v in w do
		if name ~= target then
			others += v
		end
	end
	local rest = 1 - wt
	local scale = if others > EPS then rest / others else 0
	local kept = 0
	for name, v in w do
		if name ~= target then
			local nv = v * scale
			if nv < 1e-4 then
				w[name] = nil
			else
				w[name] = nv
				kept += nv
			end
		end
	end
	w[target] = 1 - kept
end

-- One-shot layer weight `t` seconds into a clip of `dur` seconds: smooth ramps in and out, 0 outside [0, dur].
function ClipMath.oneShotWeight(t: number, dur: number, fadeIn: number, fadeOut: number): number
	if t < 0 or t > dur then
		return 0
	end
	local a = if fadeIn > 0 then ClipMath.smoothstep(t / fadeIn) else 1
	local b = if fadeOut > 0 then ClipMath.smoothstep((dur - t) / fadeOut) else 1
	return math.min(a, b)
end

-- Set of bone indices a clip's mask covers (nil = every bone).
function ClipMath.maskSet(mod: Module, clip: Clip): { [number]: boolean }?
	local mask = clip.mask
	if not mask then
		return nil
	end
	local index: { [string]: number } = {}
	for i, n in mod.bones do
		index[n] = i
	end
	local set: { [number]: boolean } = {}
	for _, n in mask do
		local i = index[n]
		if i then
			set[i] = true
		end
	end
	return set
end

-- Shape check for a baked module: returns false and the first problem found.
function ClipMath.validate(mod: any): (boolean, string?)
	if type(mod) ~= "table" then
		return false, "module is not a table"
	end
	if type(mod.fps) ~= "number" or mod.fps <= 0 then
		return false, "fps must be a positive number"
	end
	if type(mod.bones) ~= "table" or #mod.bones == 0 then
		return false, "bones must be a non-empty list"
	end
	local names: { [string]: boolean } = {}
	for i, n in mod.bones do
		if type(n) ~= "string" or n == "" then
			return false, "bones[" .. tostring(i) .. "] is not a name"
		end
		if names[n] then
			return false, "duplicate bone " .. n
		end
		names[n] = true
	end
	if type(mod.clips) ~= "table" or next(mod.clips) == nil then
		return false, "clips must be a non-empty map"
	end
	for cname, clip in mod.clips do
		local where = "clip " .. tostring(cname)
		if type(clip) ~= "table" then
			return false, where .. " is not a table"
		end
		local n = clip.frames
		if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
			return false, where .. ": frames must be a positive integer"
		end
		if type(clip.loop) ~= "boolean" then
			return false, where .. ": loop must be a boolean"
		end
		if clip.speedRef ~= nil and (type(clip.speedRef) ~= "number" or clip.speedRef <= 0) then
			return false, where .. ": speedRef must be nil or positive"
		end
		if clip.mask ~= nil then
			if type(clip.mask) ~= "table" then
				return false, where .. ": mask must be a list"
			end
			for _, m in clip.mask do
				if not names[m] then
					return false, where .. ": mask names unknown bone " .. tostring(m)
				end
			end
		end
		if type(clip.channels) ~= "table" or #clip.channels ~= #mod.bones then
			return false, where .. ": needs one channel per bone (" .. #mod.bones .. ")"
		end
		for bi, ch in clip.channels do
			local bwhere = where .. " bone " .. mod.bones[bi]
			if type(ch) ~= "table" or type(ch.q) ~= "table" then
				return false, bwhere .. ": missing q"
			end
			local rows = #ch.q / 4
			if rows ~= 1 and rows ~= n then
				return false, bwhere .. ": q has " .. tostring(#ch.q) .. " numbers, want 4 or " .. 4 * n
			end
			local px, py, pz, pw = 0, 0, 0, 1
			for r = 1, rows do
				local o = (r - 1) * 4
				local x, y, z, w = ch.q[o + 1], ch.q[o + 2], ch.q[o + 3], ch.q[o + 4]
				local len = math.sqrt(x * x + y * y + z * z + w * w)
				if math.abs(len - 1) > 2e-3 then
					return false, bwhere .. ": quaternion " .. r .. " not unit (" .. len .. ")"
				end
				if r > 1 and px * x + py * y + pz * z + pw * w < 0 then
					return false, bwhere .. ": hemisphere flip at frame " .. r
				end
				px, py, pz, pw = x, y, z, w
			end
			if ch.t ~= nil then
				if type(ch.t) ~= "table" then
					return false, bwhere .. ": t must be a list"
				end
				local trows = #ch.t / 3
				if trows ~= 1 and trows ~= n then
					return false, bwhere .. ": t has " .. tostring(#ch.t) .. " numbers, want 3 or " .. 3 * n
				end
			end
		end
	end
	return true, nil
end

return ClipMath
