--!strict
-- Lune spec for the flip_v2 flipbook wiring: src/shared/FlipFx.luau against the generated VfxFlipAssets ids and
-- assets/vfx/flip_v2/manifest.json (layout, mode, framerate), the old-texture fallback, and static checks that every
-- emitter texture the VFX modules name resolves and that docs/ASSETS.md lists the 13 sheets.
-- Run: tools/tests/run_lune_tests.sh tools/tests/flipfx_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

local VFX_FILES = {
	"src/client/Vfx.luau",
	"src/client/ItemClient.luau",
	"src/client/CarController.luau",
	"src/client/TrackFlow.luau",
	"src/server/BossRace.luau",
	"src/server/KeyPickup.luau",
	"src/server/battle/modes/Egg.luau",
	"src/server/battle/modes/Hoard.luau",
}

-- manifest.json is written by tools/vfx/flipbooks.py with a one-space indent: top-level entries open with
-- `\n "<name>": {` and close with `\n }`.
local function manifest(text: string): { [string]: { grid: string, loop: boolean, mode: string?, fps: number? } }
	local out = {}
	for name, body in string.gmatch(text, '\n "([%w_]+)": {(.-)\n }') do
		out[name] = {
			grid = string.match(body, '"grid": "?(%w+)"?') or "?",
			loop = string.match(body, '"loop": (%a+)') == "true",
			mode = string.match(body, '"flipbookMode": "(%a+)"'),
			fps = tonumber(string.match(body, '"flipbookFramerate": ([%d%.]+)') or ""),
		}
	end
	return out
end

return function(h: Harness)
	local FlipFx = h.require("src/shared/FlipFx.luau")
	local VfxFlipAssets = h.require("src/shared/VfxFlipAssets.luau")
	local VfxAssets = h.require("src/shared/VfxAssets.luau")
	local man = manifest(h.readFile("assets/vfx/flip_v2/manifest.json"))

	h.test("sheets: FlipFx.SHEETS, VfxFlipAssets and the manifest name the same 13 sheets with owned ids", function()
		local n = 0
		for name, id in VfxFlipAssets do
			n += 1
			h.ok(FlipFx.SHEETS[name] ~= nil, name .. " has a FlipFx sheet entry")
			h.ok(man[name] ~= nil, name .. " is in the manifest")
			h.ok(string.match(id, "^rbxassetid://%d+$") ~= nil, name .. " id " .. tostring(id))
		end
		h.eq(n, 13, "VfxFlipAssets sheets")
		for name in FlipFx.SHEETS do
			h.ok(VfxFlipAssets[name] ~= nil, name .. " (FlipFx) has an uploaded id")
		end
		for name in man do
			h.ok(FlipFx.SHEETS[name] ~= nil, name .. " (manifest) has a FlipFx sheet entry")
		end
	end)

	h.test("sheets: layout, mode and framerate match the manifest (OneShot one-shots, Loop loops, Random bolts)", function()
		for name, sheet in FlipFx.SHEETS do
			local m = man[name]
			local grid = if m.grid == "null" or m.grid == "None" then "None" else m.grid
			h.eq(sheet.layout, grid, name .. " layout")
			if grid == "None" then
				h.eq(sheet.mode, "None", name .. " mode")
			elseif m.loop then
				h.eq(sheet.mode, "Loop", name .. " loop mode")
				h.eq(sheet.fps, m.fps, name .. " framerate")
			else
				h.eq(sheet.mode, m.mode, name .. " mode")
				h.ok(sheet.mode == "OneShot" or sheet.mode == "Random", name .. " one-shot or variants")
			end
		end
		h.eq(FlipFx.SHEETS.lightning_bolt_2x2.mode, "Random", "bolt variants")
		h.eq(FlipFx.SHEETS.lightning_bolt_2x2.layout, "Grid2x2", "bolt grid")
	end)

	h.test("resolve: every sheet resolves to its new id; every fallback is an old VfxAssets texture", function()
		for name, sheet in FlipFx.SHEETS do
			local r = FlipFx.resolve(name)
			h.ok(r.flip, name .. " uses the new sheet")
			h.eq(r.texture, VfxFlipAssets[name], name .. " texture")
			h.eq(r.layout, sheet.layout, name .. " layout")
			local old = VfxAssets[sheet.fallback]
			h.ok(old ~= nil and string.match(old.id, "^rbxassetid://%d+$") ~= nil, name .. " fallback " .. sheet.fallback .. " exists")
		end
		local smoke = FlipFx.resolve("smoke_puff_4x4")
		h.eq({ smoke.texture, smoke.layout, smoke.mode, smoke.flip }, { VfxAssets.smoke_puff_4x4.id, "Grid4x4", "OneShot", false }, "old 4x4 key")
		local spark = FlipFx.resolve("spark_streak")
		h.eq({ spark.layout, spark.mode, spark.flip }, { "None", "None", false }, "old single-frame key")
		h.eq(FlipFx.resolve("no_such_texture").texture, "", "unknown name: no texture")
	end)

	h.test("resolve: a missing sheet id falls back to the old texture with its own layout (OneShot)", function()
		local saved = VfxFlipAssets.explosion_8x8
		VfxFlipAssets.explosion_8x8 = nil
		local ok, err = pcall(function()
			local r = FlipFx.resolve("explosion_8x8")
			h.eq({ r.texture, r.layout, r.mode, r.flip }, { VfxAssets.explosion_4x4.id, "Grid4x4", "OneShot", false }, "explosion fallback")
			h.ok(not FlipFx.isFlip("explosion_8x8"), "isFlip false")
		end)
		VfxFlipAssets.explosion_8x8 = saved
		h.ok(ok, tostring(err))
		VfxFlipAssets.shockwave_8x8, saved = "", VfxFlipAssets.shockwave_8x8
		local r = FlipFx.resolve("shockwave_8x8")
		VfxFlipAssets.shockwave_8x8 = saved
		h.eq({ r.texture, r.layout, r.flip }, { VfxAssets.shockwave_ring.id, "None", false }, "empty id: flat ring")
	end)

	h.test("apply: a one-shot sheet sets texture, grid, OneShot and no random start; a single frame clears the grid", function()
		local pe: any = {}
		h.ok(FlipFx.apply(pe, "explosion_8x8"), "new sheet")
		h.eq(pe.Texture, VfxFlipAssets.explosion_8x8, "texture")
		h.eq(pe.FlipbookLayout, "ParticleFlipbookLayout.Grid8x8", "layout")
		h.eq(pe.FlipbookMode, "ParticleFlipbookMode.OneShot", "mode")
		h.eq(pe.FlipbookStartRandom, false, "one-shots start at frame 0")
		local streak: any = {}
		FlipFx.apply(streak, "spark_streak")
		h.eq(streak.FlipbookLayout, "ParticleFlipbookLayout.None", "single frame")
		h.eq(streak.FlipbookMode, nil, "mode untouched")
	end)

	h.test("static: every texture the VFX modules name resolves (presets, FlipFx.apply calls, hazard kinds)", function()
		local seen = 0
		for _, file in VFX_FILES do
			local src = h.readFile(file)
			for name in string.gmatch(src, 'tex = "([%w_]+)"') do
				seen += 1
				h.ok(FlipFx.resolve(name).texture ~= "", file .. ": tex " .. name .. " resolves")
			end
			for name in string.gmatch(src, 'FlipFx%.apply%([%w_%.]+, "([%w_]+)"') do
				seen += 1
				h.ok(FlipFx.SHEETS[name] ~= nil, file .. ": FlipFx.apply " .. name .. " is a flip_v2 sheet")
			end
		end
		h.ok(seen > 60, "found the texture references (" .. seen .. ")")
	end)

	h.test("static: migrated modules set flipbooks only through FlipFx; Vfx uses every sheet", function()
		for _, file in VFX_FILES do
			local src = h.readFile(file)
			h.ok(string.find(src, "Enum.ParticleFlipbookLayout.Grid", 1, true) == nil, file .. " hard-codes no FlipbookLayout")
		end
		local all = ""
		for _, file in VFX_FILES do
			all ..= h.readFile(file)
		end
		for name in FlipFx.SHEETS do
			h.ok(string.find(all, '"' .. name .. '"', 1, true) ~= nil, name .. " is used somewhere")
		end
		local vfx = h.readFile("src/client/Vfx.luau")
		-- Respect the tricks lane: hopDust stays a preset (CarController calls it by name) and Vfx never fires it itself.
		h.ok(string.find(vfx, "\thopDust = {", 1, true) ~= nil, "hopDust preset kept")
		h.ok(string.find(vfx, 'burst("hopDust"', 1, true) == nil, "Vfx does not fire hopDust")
	end)

	h.test("docs: ASSETS.md section 6 lists every flip_v2 sheet with its id", function()
		local doc = h.readFile("docs/ASSETS.md")
		for name, id in VfxFlipAssets do
			local num = string.match(id, "%d+")
			h.contains(doc, name, "ASSETS.md row for " .. name)
			h.contains(doc, num :: string, "ASSETS.md id for " .. name)
		end
	end)
end
