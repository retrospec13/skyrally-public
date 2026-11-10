--!strict
-- SPACE-4 neon pass (Star City). Pure rules for client/SpaceNeon: the hologram figures (a blocky R15-like rig, an idle pose
-- that leans over the track and turns its head to follow the local racer), their flicker, the holo billboards' copy and
-- reveal, the synthwave palette, and the placement clearance the layout (tools/map/author_space4.py ->
-- shared/SpaceNeonLayout) is checked against. No services, no Instances; Vector3/CFrame/Color3 values only.
-- Everything built from these numbers is visual only (CanCollide/CanQuery/CanTouch false): the clearance rule exists so
-- a leaning head or a swinging hand never reaches the corridor or the parapets (wall driving is untouched).
local Rules = {}

Rules.TRACK_ID = "SPACE-4"

---------------------------------------------------------------------------------------------------- palette

-- Hot pink, magenta, purple, blue, cyan, sunset orange (the road strips step through the same list at build time).
Rules.SYNTH = table.freeze({
	Color3.fromRGB(255, 47, 168),
	Color3.fromRGB(214, 60, 255),
	Color3.fromRGB(141, 92, 255),
	Color3.fromRGB(61, 139, 255),
	Color3.fromRGB(25, 230, 255),
	Color3.fromRGB(255, 138, 60),
}) :: { Color3 }

-- The figures' and billboards' looks: translucent body colour and a pale accent for eyes, rim and text.
Rules.LOOKS = table.freeze({
	table.freeze({ body = Color3.fromRGB(255, 79, 192), accent = Color3.fromRGB(255, 208, 240) }),
	table.freeze({ body = Color3.fromRGB(56, 232, 255), accent = Color3.fromRGB(216, 251, 255) }),
	table.freeze({ body = Color3.fromRGB(160, 107, 255), accent = Color3.fromRGB(230, 214, 255) }),
	table.freeze({ body = Color3.fromRGB(255, 154, 69), accent = Color3.fromRGB(255, 224, 192) }),
}) :: { { body: Color3, accent: Color3 } }

-- Smooth cycle through the synthwave list, `period` seconds for the whole loop.
function Rules.cycle(t: number, period: number, offset: number?): Color3
	local n = #Rules.SYNTH
	local x = ((t / period) + (offset or 0)) % 1 * n
	local i = math.floor(x)
	local a = Rules.SYNTH[i % n + 1]
	local b = Rules.SYNTH[(i + 1) % n + 1]
	return a:Lerp(b, x - i)
end

---------------------------------------------------------------------------------------------------- placement clearance

Rules.HOLO_K_LEAN = 0.6 -- head reach from the hip per unit height, times sin(lean)
Rules.HOLO_K_ARM = 0.26 -- plus the swinging hands (arms stay within 30 degrees of vertical in the world)
Rules.HOLO_CLEAR = 180 -- v29 W1b A8: was 55 (behind the first tower row) -- studs of plan-view clearance from the race line to the nearest reachable part

-- The farthest any part of a figure of this height and lean reaches from its feet in plan view (studs).
function Rules.reach(height: number, leanDeg: number): number
	return height * (Rules.HOLO_K_LEAN * math.sin(math.rad(leanDeg)) + Rules.HOLO_K_ARM)
end

-- True when feet standing `distToRoute` studs (plan view) from the race line keep Rules.HOLO_CLEAR to the road axis.
function Rules.clearOfRoad(distToRoute: number, height: number, leanDeg: number): boolean
	return distToRoute - Rules.reach(height, leanDeg) >= Rules.HOLO_CLEAR - 1e-6
end

---------------------------------------------------------------------------------------------------- figure rig

-- Rig units (1 unit = height / UNIT_HEIGHT studs): R15-like blocky proportions.
Rules.UNIT_HEIGHT = 5.5
local LEG = 1.0 -- upper and lower leg
local FOOT = 0.3
local HIP_Y = 2 * LEG + FOOT
local LOWER = { 2, 0.4, 1 }
local UPPER = { 2, 1.6, 1 }
local HEAD = 1.2
local ARM = { 1, 1.05, 1 }
local FORE = { 1, 1.0, 1 }
local HAND = { 1, 0.4, 1 }
local LEGSZ = { 1, LEG, 1 }
local FOOTSZ = { 1, FOOT, 1.2 }

Rules.PART_NAMES = table.freeze({
	"LowerTorso", "UpperTorso", "Head",
	"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
	"LeftEye", "RightEye", "Mouth",
}) :: { string }

-- Part sizes in rig units, in PART_NAMES order.
Rules.PART_SIZES = table.freeze({
	LOWER, UPPER, { HEAD, HEAD, HEAD },
	ARM, FORE, HAND, ARM, FORE, HAND,
	LEGSZ, LEGSZ, FOOTSZ, LEGSZ, LEGSZ, FOOTSZ,
	{ 0.26, 0.26, 0.06 }, { 0.26, 0.26, 0.06 }, { 0.52, 0.08, 0.06 },
}) :: { { number } }

-- Parts that carry the accent colour (face) rather than the body colour.
Rules.ACCENT_PARTS = table.freeze({ LeftEye = true, RightEye = true, Mouth = true }) :: { [string]: boolean }

local function unit(v: Vector3): Vector3
	local m = v.Magnitude
	return if m > 1e-6 then v / m else Vector3.zero
end

-- The head's yaw (radians, about the neck, clamped) that turns a figure facing `faceYawDeg` toward `target` from `from`.
-- Roblox yaw convention: Look = (-sin yaw, 0, -cos yaw).
function Rules.lookYaw(faceYawDeg: number, from: Vector3, target: Vector3, maxDeg: number?): number
	local d = unit(Vector3.new(target.X - from.X, 0, target.Z - from.Z))
	if d.Magnitude < 0.5 then
		return 0
	end
	local want = math.atan2(-d.X, -d.Z)
	local delta = (want - math.rad(faceYawDeg) + math.pi) % (2 * math.pi) - math.pi
	local lim = math.rad(maxDeg or 70)
	return math.clamp(delta, -lim, lim)
end

-- Idle pose at time t: one CFrame per PART_NAMES entry in the figure frame (feet at the origin, facing -Z, y up),
-- already scaled to `height` studs. `lean` is the forward bend at the hip in degrees; `headYaw` radians (see lookYaw).
function Rules.pose(t: number, phase: number, height: number, leanDeg: number, headYaw: number): { CFrame }
	local k = height / Rules.UNIT_HEIGHT
	local breath = math.sin(t * 0.9 + phase)
	local lean = math.rad(leanDeg + 2.5 * breath) -- a slow breathing sway about the lean
	local out: { CFrame } = {}
	local function at(cf: CFrame, off: Vector3): CFrame
		-- part centre = joint frame * (off scaled)
		return cf * CFrame.new(off * k)
	end
	local root = CFrame.new(0, HIP_Y * k, 0) * CFrame.Angles(-lean, 0, 0)
	local upperJ = root * CFrame.new(0, LOWER[2] * k, 0)
	local neckJ = upperJ * CFrame.new(0, UPPER[2] * k, 0) * CFrame.Angles(0.62 * lean, 0, 0) * CFrame.Angles(0, headYaw, 0)

	local function arm(side: number, swingDeg: number, elbowDeg: number): { CFrame }
		-- shoulder joint at the top outer corner of the upper torso; world swing alpha forward = swing, rel = alpha + lean
		local shoulder = upperJ * CFrame.new(side * (UPPER[1] / 2 + ARM[1] / 2) * k, (UPPER[2] - 0.2) * k, 0)
			* CFrame.Angles(lean + math.rad(swingDeg), 0, side * math.rad(4))
		local elbow = shoulder * CFrame.new(0, -ARM[2] * k, 0) * CFrame.Angles(math.rad(elbowDeg), 0, 0)
		local wrist = elbow * CFrame.new(0, -FORE[2] * k, 0)
		return {
			at(shoulder, Vector3.new(0, -ARM[2] / 2, 0)),
			at(elbow, Vector3.new(0, -FORE[2] / 2, 0)),
			at(wrist, Vector3.new(0, -HAND[2] / 2, 0)),
		}
	end
	-- the left arm sweeps slowly over the track (a wave), the right hangs with a faint swing
	local leftSwing = 6 + 12 * math.sin(t * 0.7 + phase) -- -6 .. 18
	local leftElbow = 8 + 4 * math.sin(t * 1.3 + phase)
	local rightSwing = 2 + 5 * math.sin(t * 0.5 + phase + 1.7)
	local rightElbow = 6

	out[1] = at(root, Vector3.new(0, LOWER[2] / 2, 0))
	out[2] = at(upperJ, Vector3.new(0, UPPER[2] / 2, 0))
	out[3] = at(neckJ, Vector3.new(0, HEAD / 2, 0))
	local la = arm(-1, leftSwing, leftElbow)
	local ra = arm(1, rightSwing, rightElbow)
	for i = 1, 3 do
		out[3 + i] = la[i]
		out[6 + i] = ra[i]
	end
	-- legs: planted, a slight knee flex that breathes with the sway; feet flat on the ground
	for s = 0, 1 do
		local side = if s == 0 then -1 else 1
		local hip = CFrame.new(side * 0.5 * k, (HIP_Y - 0.0) * k, 0)
		local top = hip * CFrame.new(0, 0, 0)
		local knee = top * CFrame.new(0, -LEG * k, 0)
		local ankle = knee * CFrame.new(0, -LEG * k, 0)
		local base = 9 + s * 3
		out[base + 1] = at(top, Vector3.new(0, -LEG / 2, 0))
		out[base + 2] = at(knee, Vector3.new(0, -LEG / 2, 0))
		out[base + 3] = at(ankle, Vector3.new(0, -FOOT / 2, -0.15))
	end
	-- face on the head's front (-Z), parented to the head frame so it turns with it
	local head = out[3]
	out[16] = head * CFrame.new(-0.28 * k, 0.12 * k, -(HEAD / 2 + 0.01) * k)
	out[17] = head * CFrame.new(0.28 * k, 0.12 * k, -(HEAD / 2 + 0.01) * k)
	out[18] = head * CFrame.new(0, -0.24 * k, -(HEAD / 2 + 0.01) * k)
	return out
end

-- Extra transparency (0 .. 0.3) on top of the base: a slow shimmer, and a short glitch about every 7 seconds.
function Rules.flicker(t: number, phase: number): number
	local shimmer = 0.06 * (0.5 + 0.5 * math.sin(t * 2.3 + phase * 3))
	local cyc = (t + phase * 1.1) % 7.3
	local glitch = if cyc < 0.14 then 0.3 elseif cyc > 0.3 and cyc < 0.38 then 0.18 else 0
	return shimmer + glitch
end

-- Seconds between pose updates for a figure `dist` studs from the camera; nil = frozen.
function Rules.updateInterval(dist: number, lowGraphics: boolean): number?
	local scale = if lowGraphics then 2 else 1
	if dist < 500 then
		return (1 / 30) * scale
	elseif dist < 1100 then
		return (1 / 15) * scale
	elseif dist < 1800 then
		return 1 / 6
	end
	return nil
end

---------------------------------------------------------------------------------------------------- billboards

Rules.COPY = table.freeze({
	table.freeze({ title = "SKYRALLY", sub = "STAR CITY CIRCUIT" }),
	table.freeze({ title = "STAR CITY", sub = "NIGHT LAP LIVE" }),
	table.freeze({ title = "KEEP YOUR LINE", sub = "THE APEX IS YOURS" }),
	table.freeze({ title = "BOOST THE NIGHT", sub = "HIT EVERY PAD" }),
	table.freeze({ title = "FIND THE SHORTCUT", sub = "THROUGH THE MESA" }),
	table.freeze({ title = "LAST LAP", sub = "NO LIFTING" }),
	table.freeze({ title = "FULL THROTTLE", sub = "SKYRALLY" }),
}) :: { { title: string, sub: string } }

Rules.COPY_SECONDS = 6 -- each message holds this long
Rules.REVEAL_SECONDS = 1.1 -- the typed reveal at the start of each message

export type BoardState = { copy: number, reveal: number, glitch: boolean }

-- Which message a billboard shows at time t, how much of it is typed out (0..1) and whether it is in a glitch frame.
function Rules.board(t: number, boardIndex: number): BoardState
	local n = #Rules.COPY
	local slot = math.floor(t / Rules.COPY_SECONDS) + boardIndex * 2
	local local_t = t % Rules.COPY_SECONDS
	local reveal = math.clamp(local_t / Rules.REVEAL_SECONDS, 0, 1)
	local tail = Rules.COPY_SECONDS - local_t
	return {
		copy = slot % n + 1,
		reveal = reveal,
		glitch = local_t < 0.12 or tail < 0.1,
	}
end

-- The first `reveal` fraction of a string (ASCII copy), at least one character once the message has started.
function Rules.typed(text: string, reveal: number): string
	if reveal >= 1 then
		return text
	end
	return string.sub(text, 1, math.max(1, math.floor(#text * reveal)))
end

return Rules
