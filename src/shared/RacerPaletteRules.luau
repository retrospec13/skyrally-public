--!strict
-- Default racer colours (owner 2026-10-19: every car/plane was the same maroon, so players and bots could not be told
-- apart). Pure data and rules, no Roblox API, so tools/tests/racer_palette_spec.luau runs it under Lune. Colours are plain
-- {r, g, b} arrays like GarageModel's liveryPaint, so shared/LiveryPaint.applyPalette can paint them and the spec can
-- measure them.
--
-- Eight palettes, picked so every pair stays apart under normal vision AND protan / deutan / tritan simulation (the spec
-- measures CIELAB distance, >= 19 for the worst pair). A palette is
--   identity : the one colour that names the racer (name label, trails, pennant, underglow, results swatch, "you" marker)
--   primary / accent / trim : the vehicle paint roles (same roles as a Garage livery: GarageModel.PART_ROLES)
--   meshTint : multiplies the textured hero mesh (the albedo is dark, so this barely shows; the identity cues carry it)
-- Assignment is deterministic: a bot wears its signature palette (the colour of its roster entry), a player takes the
-- palette for their grid slot from PLAYER_ORDER, skipping any already worn in this race. PLAYER_ORDER is the roster read
-- backwards, because the fastest bots race first (PlaneConfig.AI_BOTS): with p players the bots that sit out are the last
-- p roster entries, so the players' colours are exactly the ones no bot in that race wears. A Garage livery still decides
-- the vehicle PAINT (LiveryPaint.applyFor); the palette then only drives the identity cues.

local RacerPaletteRules = {}

export type RGB = { number }
export type Palette = {
	id: string,
	name: string,
	identity: RGB,
	primary: RGB,
	accent: RGB,
	trim: RGB,
	meshTint: RGB,
}

local function lerp(a: RGB, b: RGB, t: number): RGB
	return {
		math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
		math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
		math.floor(a[3] + (b[3] - a[3]) * t + 0.5),
	}
end

local WHITE: RGB = { 255, 255, 255 }
local BLACK: RGB = { 0, 0, 0 }

local function make(id: string, name: string, identity: RGB, accent: RGB): Palette
	return {
		id = id,
		name = name,
		identity = identity,
		primary = identity,
		accent = accent,
		-- Wave 1b C8 (critic v29 dino4_06/09: the player's crimson plane sank into the dark DINO deck, its wings and trim
		-- near black). Trim 0.55 -> 0.3 toward black (crimson trim (86, 11, 20) -> (133, 18, 32)), hero-mesh tint 0.3 -> 0.4
		-- toward white, so every palette keeps a mid-value read on dark maps (01_plane.png: painted, never black).
		trim = lerp(identity, BLACK, 0.3),
		meshTint = lerp(identity, WHITE, 0.4),
	}
end

-- Order = roster order of the bots that wear them, then the player-only crimson.
RacerPaletteRules.PALETTES = table.freeze({
	make("sky", "Sky", { 70, 170, 255 }, { 255, 240, 120 }), -- Ace Aero
	make("ember", "Ember", { 255, 110, 20 }, { 255, 235, 120 }), -- Blaze Wing (the flame / rival colour)
	make("mint", "Mint", { 60, 215, 110 }, { 240, 255, 245 }), -- Nova Sky
	make("silver", "Silver", { 235, 235, 240 }, { 90, 150, 255 }), -- Zephyr Dash
	make("indigo", "Indigo", { 50, 60, 215 }, { 255, 210, 90 }), -- Indigo Comet
	make("rose", "Rose", { 250, 120, 190 }, { 255, 240, 248 }), -- Rosa Glide
	make("sun", "Sun", { 250, 215, 40 }, { 120, 70, 30 }), -- Sunny Rotor
	make("crimson", "Crimson", { 190, 25, 45 }, { 255, 225, 200 }), -- player
}) :: { Palette }

-- Bot name -> palette id (PlaneConfig.AI_BOTS names).
RacerPaletteRules.BOT_SIGNATURE = table.freeze({
	["Ace Aero"] = "sky",
	["Blaze Wing"] = "ember",
	["Nova Sky"] = "mint",
	["Zephyr Dash"] = "silver",
	["Indigo Comet"] = "indigo",
	["Rosa Glide"] = "rose",
	["Sunny Rotor"] = "sun",
}) :: { [string]: string }

-- Grid slot 1.. -> the palette a player prefers (see the header for why this is the roster backwards).
RacerPaletteRules.PLAYER_ORDER = table.freeze({ "crimson", "sun", "rose", "indigo", "silver", "mint", "sky", "ember" }) :: { string }

local byId: { [string]: Palette } = {}
for _, p in RacerPaletteRules.PALETTES do
	byId[p.id] = p
end

function RacerPaletteRules.byId(id: string?): Palette?
	return if id then byId[id] else nil
end

-- A bot's signature palette; a name outside the roster (a boss, a future bot) hashes onto the table, stable by name.
function RacerPaletteRules.forBot(name: string): Palette
	local id = RacerPaletteRules.BOT_SIGNATURE[name]
	if id and byId[id] then
		return byId[id]
	end
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 100003
	end
	return RacerPaletteRules.PALETTES[(h % #RacerPaletteRules.PALETTES) + 1]
end

-- A player's palette for grid slot `slot` (1-based), skipping ids in `taken` (palettes other racers already wear).
-- When every palette is taken (more than eight racers) the slot's own palette is used again.
function RacerPaletteRules.forPlayer(slot: number, taken: { [string]: boolean }?): Palette
	local order = RacerPaletteRules.PLAYER_ORDER
	local n = #order
	local start = (math.max(1, math.floor(slot)) - 1) % n
	for k = 0, n - 1 do
		local id = order[((start + k) % n) + 1]
		if not (taken and taken[id]) then
			return byId[id]
		end
	end
	return byId[order[start + 1]]
end

-- Maps dark enough for the faint underglow (ActiveTrackId): the SPACE circuit and the DINO cave. Off under LOW GRAPHICS.
RacerPaletteRules.DARK_TRACKS = table.freeze({ ["SPACE-4"] = true, ["DINO-4"] = true }) :: { [string]: boolean }

function RacerPaletteRules.underglowOn(trackId: any, lowGraphics: boolean): boolean
	return not lowGraphics and type(trackId) == "string" and RacerPaletteRules.DARK_TRACKS[trackId] == true
end

-- The "you" marker over the local vehicle: 0 inside NEAR studs of the camera (the chase view sits ~14 back), fading in to
-- 1 by FAR, so it only ever shows in wide shots (grid overview, podium, replays).
RacerPaletteRules.YOU_NEAR = 40
RacerPaletteRules.YOU_FAR = 65
function RacerPaletteRules.youAlpha(cameraDistance: number): number
	return math.clamp((cameraDistance - RacerPaletteRules.YOU_NEAR) / (RacerPaletteRules.YOU_FAR - RacerPaletteRules.YOU_NEAR), 0, 1)
end

function RacerPaletteRules.color3(rgb: RGB): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- ---------------------------------------------------------------- colour-blind separation (spec + tuning)

local function lin(c: number): number
	c /= 255
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

-- Machado et al. 2009, severity 1.0, on linear RGB.
local CVD = {
	normal = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
	protan = { { 0.152286, 1.052583, -0.204868 }, { 0.114503, 0.786281, 0.099216 }, { -0.003882, -0.048116, 1.051998 } },
	deutan = { { 0.367322, 0.860646, -0.227968 }, { 0.280085, 0.672501, 0.047413 }, { -0.011820, 0.042940, 0.968881 } },
	tritan = { { 1.255528, -0.076749, -0.178779 }, { -0.078411, 0.930809, 0.147602 }, { 0.004733, 0.691367, 0.303900 } },
}
RacerPaletteRules.VISION = table.freeze({ "normal", "protan", "deutan", "tritan" }) :: { string }

local function f(t: number): number
	return if t > 0.008856 then t ^ (1 / 3) else 7.787 * t + 16 / 116
end

local function lab(rgb: { number }): (number, number, number)
	local X = 0.4124 * rgb[1] + 0.3576 * rgb[2] + 0.1805 * rgb[3]
	local Y = 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3]
	local Z = 0.0193 * rgb[1] + 0.1192 * rgb[2] + 0.9505 * rgb[3]
	local fx, fy, fz = f(X / 0.95047), f(Y), f(Z / 1.08883)
	return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

local function seen(c: RGB, vision: string): { number }
	local m = (CVD :: any)[vision]
	local v = { lin(c[1]), lin(c[2]), lin(c[3]) }
	local out = {}
	for i = 1, 3 do
		out[i] = math.clamp(m[i][1] * v[1] + m[i][2] * v[2] + m[i][3] * v[3], 0, 1)
	end
	return out
end

-- CIELAB distance between two colours as seen by `vision` ("normal" | "protan" | "deutan" | "tritan").
function RacerPaletteRules.distance(a: RGB, b: RGB, vision: string): number
	local l1, a1, b1 = lab(seen(a, vision))
	local l2, a2, b2 = lab(seen(b, vision))
	return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

-- The smallest identity distance over all palette pairs and all vision types (and which pair).
function RacerPaletteRules.worstPair(): (number, string, string)
	local worst, wa, wb = math.huge, "", ""
	local ps = RacerPaletteRules.PALETTES
	for i = 1, #ps do
		for j = i + 1, #ps do
			for _, v in RacerPaletteRules.VISION do
				local d = RacerPaletteRules.distance(ps[i].identity, ps[j].identity, v)
				if d < worst then
					worst, wa, wb = d, ps[i].id, ps[j].id
				end
			end
		end
	end
	return worst, wa, wb
end

return RacerPaletteRules
