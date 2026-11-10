--!strict
-- Lune spec: the Void Dragon's REST pose has its legs hanging (front legs straight down, hind legs dangling), which the
-- owner rejected ("fix how those legs lay when flying"). R5 re-rigged the feet/paws but kept the rest legs, so every
-- base flight clip in src/shared/vehicleclips/VoidDragon.luau must hold the legs in a flight pose on EVERY frame:
--   * each base clip (fly, glide, boost, hover, hit) exists and is not additive
--   * on every frame, each of the four limbs (upper + lower bone) has a joint at least MIN_DEG from rest (the R4 tucks
--     are 30-70 deg; hover's deliberately lowered, ready-to-land pose is the gentlest at ~10)
--   * bankL / bankR are additive overlays (never a base layer that could show the rest legs)
-- Integration rule this protects: whenever the dragon is spawned or mounted, the player keeps one base clip running
-- (hover on the grid, fly / glide / boost in flight); the bare rest pose is never shown.
-- Usage: lune run tools/tests/voiddragon_legs_spec.luau   (run_lune_tests.sh picks it up). Errors on the first failure.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd
local mod = luau.load(fs.readFile(root .. "/src/shared/vehicleclips/VoidDragon.luau"), { debugName = "VoidDragon" })()

local MIN_DEG = 8
local BASE = { "fly", "glide", "boost", "hover", "hit" }
-- R5: each limb is upper + lower + wrist/ankle + fingers/toes (the ankle, wrist and digit bones were added)
local LEGS = {
	{ "ArmL1", "ArmL2", "ArmL3", "FingersL" },
	{ "ArmR1", "ArmR2", "ArmR3", "FingersR" },
	{ "LegL1", "LegL2", "LegL3", "ToesL" },
	{ "LegR1", "LegR2", "LegR3", "ToesR" },
}

local checks = 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		error("FAIL " .. msg, 2)
	end
end

local index: { [string]: number } = {}
for i, b in mod.bones do
	index[b] = i
end
for _, pair in LEGS do
	for _, b in pair do
		check(index[b] ~= nil, "bone " .. b .. " in VoidDragon.bones")
	end
end

local function angleDeg(q: { number }, f: number): number
	local n = #q // 4
	local i = (if n == 1 then 0 else f % n) * 4
	local w = math.min(1, math.abs(q[i + 4]))
	return math.deg(2 * math.acos(w))
end

for _, name in BASE do
	local c = mod.clips[name]
	check(c ~= nil, "clip " .. name .. " exists")
	check(c.blend == nil, "clip " .. name .. " is a base (non-additive) clip")
	for f = 0, c.frames - 1 do
		for _, limb in LEGS do
			local a = 0
			for _, b in limb do
				a = math.max(a, angleDeg(c.channels[index[b]].q, f))
			end
			check(a >= MIN_DEG, string.format("%s f%d %s.. is %.1f deg from rest (< %d): the hanging rest legs show", name, f, limb[1], a, MIN_DEG))
		end
	end
end
for _, name in { "bankL", "bankR" } do
	local c = mod.clips[name]
	check(c ~= nil and c.blend == "additive", name .. " is an additive overlay")
end

print(string.format("voiddragon_legs_spec: %d checks passed", checks))
