--!strict
-- Pure rules for the image UI skin (UI overhaul phase A; client/UiSkin draws, client/UiMotion animates). No Roblox
-- globals, so tools/tests/ui_skin_spec.luau checks them under Lune.
--   * SLICE: per shared/UiImages slot, the source image size the art must be drawn at, the 9-slice centre rect
--     {l, t, r, b} in source px, the on-screen border at S = 1 (SliceScale follows S and never lets the borders
--     overlap), and how far a caller's colour tints the art (0 = the art's own colours, 1 = full multiply).
--   * STATE: button state tints (multiplied over the slot tint) and transparencies.
--   * MOTION: swoosh / pop / bounce presets with their sound cue (a UiSoundRules kind).
--   * cueFor(event): UI events -> UiSoundRules kinds.
-- Colours are {r, g, b} in 0..255, like shared/NotifySkin.
local UiSkinRules = {}

export type RGB = { number }
export type SliceRule = {
	kind: "slice" | "icon",
	size: { number }, -- source px {w, h}
	center: { number }?, -- 9-slice centre {l, t, r, b} in source px (slice only)
	border: number?, -- on-screen px of the thickest border at S = 1 (slice only)
	tintMix: number, -- 0..1: how much of the caller's colour goes into ImageColor3
}

local function slice(w: number, h: number, l: number, t: number, r: number, b: number, border: number, tintMix: number): SliceRule
	return { kind = "slice", size = { w, h }, center = { l, t, r, b }, border = border, tintMix = tintMix }
end

local function icon(): SliceRule
	return { kind = "icon", size = { 128, 128 }, center = nil, border = nil, tintMix = 0 }
end

-- The art contract: generate each image at `size` with its corners / rope ends / bevels inside the borders.
UiSkinRules.SLICE = {
	panel_wood = slice(512, 512, 120, 120, 392, 392, 28, 0), -- coloured art: the caller's dark fill is not multiplied in
	sign_hanging = slice(512, 256, 120, 112, 392, 200, 26, 0), -- both ropes inside the top corners (t = 112 holds them)
	toast_slab = slice(512, 128, 64, 40, 448, 88, 14, 0.35), -- neutral slab; the notification kind tints it
	row_plank = slice(512, 128, 56, 36, 456, 92, 12, 0.25), -- zone colour tints the plank
	btn_primary = slice(256, 96, 44, 36, 212, 60, 12, 0),
	btn_wood = slice(256, 96, 44, 36, 212, 60, 12, 0.2),
	btn_danger = slice(256, 96, 44, 36, 212, 60, 12, 0),
	btn_round = slice(128, 128, 60, 60, 68, 68, 22, 0), -- a circle: corners take nearly all of it
	tab_idle = slice(192, 80, 40, 32, 152, 48, 10, 0.2),
	tab_selected = slice(192, 80, 40, 32, 152, 48, 10, 0),
	icon_coin = icon(),
	icon_key = icon(),
	icon_gear = icon(),
	icon_lock = icon(),
	icon_check = icon(),
	icon_trophy = icon(),
	icon_medal_1 = icon(),
	icon_medal_2 = icon(),
	icon_medal_3 = icon(),
	icon_info = icon(),
	icon_alert = icon(),
	icon_star = icon(),
	icon_close = icon(),
} :: { [string]: SliceRule }

-- SliceScale for a slot drawn at hud scale S into a w x h frame (w, h = 0 when not laid out yet: no clamp). The border
-- grows with S like every HudLayoutRules.px size, and shrinks when a small frame would make opposite borders overlap.
function UiSkinRules.sliceScale(slot: string, S: number?, w: number?, h: number?): number
	local r = UiSkinRules.SLICE[slot]
	if not r or r.kind ~= "slice" or not r.center or not r.border then
		return 1
	end
	local c = r.center :: { number }
	local sw, sh = r.size[1], r.size[2]
	local l, t, rr, b = c[1], c[2], sw - c[3], sh - c[4]
	local thick = math.max(l, t, rr, b, 1)
	local s = (r.border :: number) * (S or 1) / thick
	if w and w > 0 then
		s = math.min(s, w / math.max(1, l + rr))
	end
	if h and h > 0 then
		s = math.min(s, h / math.max(1, t + b))
	end
	return math.max(0.01, s)
end

-- ImageColor3 for a slot given the caller's colour: white mixed toward the colour by the slot's tintMix.
function UiSkinRules.artTint(slot: string, color: RGB?): RGB
	local r = UiSkinRules.SLICE[slot]
	local m = if r then r.tintMix else 0
	if not color or m <= 0 then
		return { 255, 255, 255 }
	end
	local out = {}
	for i = 1, 3 do
		out[i] = math.floor(255 + (color[i] - 255) * m + 0.5)
	end
	return out
end

-- Multiplies two 0..255 colours (a state tint over a base tint).
function UiSkinRules.multiply(a: RGB, b: RGB): RGB
	return { math.floor(a[1] * b[1] / 255 + 0.5), math.floor(a[2] * b[2] / 255 + 0.5), math.floor(a[3] * b[3] / 255 + 0.5) }
end

export type State = "idle" | "hover" | "pressed" | "disabled"
-- Art buttons only (the flat fallback keeps AutoButtonColor): idle sits a touch under white so hover can brighten.
UiSkinRules.STATE = {
	idle = { tint = { 236, 236, 236 }, alpha = 0 },
	hover = { tint = { 255, 255, 255 }, alpha = 0 },
	pressed = { tint = { 196, 188, 176 }, alpha = 0 },
	disabled = { tint = { 150, 150, 150 }, alpha = 0.35 },
} :: { [string]: { tint: RGB, alpha: number } }

-- Motion presets. Easing names are Enum.EasingStyle / EasingDirection names. slide: the gui travels `distance` of its
-- own size (at least minPx) from / to its side; scale: a UIScale from -> to; bounce: UIScale keyframes.
export type Step = { scale: number, time: number, style: string, dir: string }
export type Motion = {
	kind: "slide" | "scale" | "bounce",
	duration: number,
	style: string,
	dir: string,
	cue: string, -- UiSoundRules kind played on start
	from: number?, -- scale presets
	to: number?,
	distance: number?, -- slide presets: fraction of the gui's size along the axis
	minPx: number?,
	steps: { Step }?, -- bounce
}

UiSkinRules.MOTION = {
	-- v3: snappy, 80 to 150 ms (docs/design/UI_V2.md section 4).
	swooshIn = { kind = "slide", duration = 0.15, style = "Quart", dir = "Out", cue = "open", distance = 0.35, minPx = 24 },
	swooshOut = { kind = "slide", duration = 0.12, style = "Quad", dir = "In", cue = "close", distance = 0.35, minPx = 24 },
	popIn = { kind = "scale", duration = 0.14, style = "Back", dir = "Out", cue = "pop", from = 0.9, to = 1 },
	popOut = { kind = "scale", duration = 0.1, style = "Quad", dir = "In", cue = "close", from = 1, to = 0.92 },
	bounce = {
		kind = "bounce",
		duration = 0.15,
		style = "Back",
		dir = "Out",
		cue = "pop",
		steps = {
			{ scale = 1.08, time = 0.05, style = "Quad", dir = "Out" },
			{ scale = 0.97, time = 0.04, style = "Sine", dir = "InOut" },
			{ scale = 1, time = 0.06, style = "Back", dir = "Out" },
		},
	},
} :: { [string]: Motion }

-- The modal scrim's resting transparency and its fade times (NotifyKit).
UiSkinRules.SCRIM = { alpha = 0.45, fadeIn = 0.2, fadeOut = 0.16 }

-- Slide offset in px for a gui of w x h entering from / leaving to `side` ("left", "right", "top", "bottom").
function UiSkinRules.slideOffset(preset: string, side: string, w: number, h: number): (number, number)
	local m = UiSkinRules.MOTION[preset]
	local frac = if m and m.distance then m.distance else 0.6
	local minPx = if m and m.minPx then m.minPx else 24
	if side == "left" then
		return -math.max(minPx, w * frac), 0
	elseif side == "right" then
		return math.max(minPx, w * frac), 0
	elseif side == "bottom" then
		return 0, math.max(minPx, h * frac)
	end
	return 0, -math.max(minPx, h * frac)
end

-- Which side a rect enters from: its nearer screen edge horizontally, or the top when it sits in the middle fifth
-- (lane B toasts are centred under the top bar, so they drop in from above; never across the kart below).
function UiSkinRules.sideFor(x: number, w: number, vpW: number): string
	local cx = x + w / 2
	if math.abs(cx - vpW / 2) <= vpW * 0.1 then
		return "top"
	end
	return if cx < vpW / 2 then "left" else "right"
end

-- UI events -> UiSoundRules kinds. Motion events use the Roblox library cues; button presses keep the in-house kit
-- through UiSound.bind (tap / stone / confirm / back / deny / tab / purchase).
UiSkinRules.EVENTS = {
	open = "open",
	close = "close",
	swipe = "swipe",
	pop = "pop",
	select = "pick",
	confirm = "click",
	back = "nav_back",
	deny = "negative",
	purchase = "buy",
	notify = "notify",
	reward = "notify_high",
	hover = "hover_tick",
} :: { [string]: string }

function UiSkinRules.cueFor(event: string): string?
	return UiSkinRules.EVENTS[event]
end

---------------------------------------------------------------------------------------------------- UI v2 theme
-- docs/design/UI_V2.md section 1: the arcade-racer look every native (no art) surface draws with. One source: no
-- surface picks its own colours; legacy callers' wood / brass / green fills are classified into these variants.

local function hex(h: number): RGB
	return { bit32.rshift(h, 16) % 256, bit32.rshift(h, 8) % 256, h % 256 }
end

export type Variant = { top: RGB, bottom: RGB, text: RGB?, textAlpha: number? }

UiSkinRules.INK = hex(0x0B1533)
UiSkinRules.STEEL = hex(0xC9D6EA) -- v3: the pale steel edge on every frame (outer)
UiSkinRules.STEEL_IN = hex(0x7F93B8) -- v3: the inner edge (the 9-slice art draws both)
UiSkinRules.GOLD = hex(0xFFD21F) -- v3 yellow (emphasis, the focused item)
UiSkinRules.WHITE = { 255, 255, 255 }
-- Fills (top -> bottom gradient). Buttons get the gloss band and the bottom lip on top of these.
UiSkinRules.VARIANT = {
	-- UI direction v3 (docs/design/UI_V2.md section 4): deep navy base, electric blue working colour, yellow emphasis,
	-- a lime primary; flat fills with at most a soft two-stop gradient.
	panel = { top = hex(0x14306B), bottom = hex(0x0B1533) },
	card = { top = hex(0x1A3A80), bottom = hex(0x0F2152) },
	inset = { top = hex(0x0A1430), bottom = hex(0x08102A) },
	header = { top = hex(0xFFD21F), bottom = hex(0xF4B800), text = hex(0x0B1533) },
	go = { top = hex(0xD2EA2A), bottom = hex(0xB4CC12), text = hex(0x0B1533) },
	sky = { top = hex(0x2A86EA), bottom = hex(0x1A64C8) },
	orange = { top = hex(0xFFB020), bottom = hex(0xE88A00), text = hex(0x0B1533) },
	danger = { top = hex(0xE84A4A), bottom = hex(0xB42430) },
	disabled = { top = hex(0x3A4766), bottom = hex(0x2A3550), textAlpha = 0.45 },
	purple = { top = hex(0xB070F0), bottom = hex(0x7A3FD6) },
	tab = { top = hex(0x16295C), bottom = hex(0x0E1B45) },
} :: { [string]: Variant }
UiSkinRules.INSET_ALPHA = 0.45 -- "#0E1B45 at 55%"
UiSkinRules.RARITY = {
	common = hex(0xC9D4E8),
	rare = hex(0x4FC3FF),
	epic = hex(0xB76BFF),
	legendary = hex(0xFFC53D),
} :: { [string]: RGB }
UiSkinRules.PLACE = { hex(0xFFD23F), hex(0xD9E2F2), hex(0xF0965A) } :: { RGB }

function UiSkinRules.placeColor(place: number): RGB
	return UiSkinRules.PLACE[place] or UiSkinRules.WHITE
end

-- Shape language at S = 1 (callers scale by HudMetrics.S()).
UiSkinRules.SHAPE = {
	-- v3: angular and flat. Near-square corners, a thin steel edge, no gloss band and no fat lip; text carries a soft
	-- dark outline (a drop-shadow feel) instead of the thick ink stroke.
	corner = 3, -- buttons, cards
	panelCorner = 4,
	chipCorner = 2,
	outline = 2, -- steel edge on every control
	panelOutline = 2,
	textStroke = 1.2,
	lip = 0,
	pressedLip = 0,
	gloss = 0,
	glossLift = 0.3,
	lipShade = 0.58,
	hoverLift = 0.16,
}

-- Font families (Roblox-hosted). display: heavy italic for titles, numerals and buttons; body: rounded bold.
UiSkinRules.FONT = {
	-- v3: condensed heavy caps for titles, labels and numerals; a condensed sans for rows.
	display = { family = "rbxasset://fonts/families/Oswald.json", weight = "Bold", style = "Normal" },
	button = { family = "rbxasset://fonts/families/Oswald.json", weight = "Bold", style = "Normal" },
	body = { family = "rbxasset://fonts/families/RobotoCondensed.json", weight = "Bold", style = "Normal" },
	bodyHeavy = { family = "rbxasset://fonts/families/RobotoCondensed.json", weight = "Bold", style = "Normal" },
}


-- UI direction v3 frames (tools/ui/make_v3_frames.py; ids in shared/UiV3Frames once uploaded): the 9-slice image a
-- native control draws for its role and variant, and each image's source size and SliceCenter.
UiSkinRules.V3_SLICE = {
	frame = { size = { 96, 96 }, center = { 24, 24, 72, 72 } },
	bar = { size = { 128, 48 }, center = { 28, 16, 100, 32 } },
	chip = { size = { 96, 32 }, center = { 20, 10, 76, 22 } },
	tab = { size = { 112, 40 }, center = { 24, 12, 88, 28 } },
} :: { [string]: { size: { number }, center: { number } } }

local V3_BAR_FILL: { [string]: string } = {
	go = "lime",
	sky = "blue",
	purple = "blue",
	orange = "yellow",
	header = "yellow",
	danger = "danger",
	disabled = "dark",
	tab = "dark",
	card = "dark",
	panel = "dark",
	inset = "dark",
}

-- The v3 frame image key ("frame_dark", "bar_lime", "tab_light", ...) for a native role + variant, or nil (draw flat).
function UiSkinRules.v3Frame(role: string, variant: string): string?
	if role == "button" then
		return "bar_" .. (V3_BAR_FILL[variant] or "blue")
	elseif role == "tab" then
		return if variant == "header" then "tab_light" else "tab_dark"
	elseif role == "chip" then
		-- a chip in a light variant (the player's own results row, a gold reward chip) takes the matching bar fill
		if variant == "header" or variant == "orange" or variant == "go" or variant == "danger" then
			return "bar_" .. (V3_BAR_FILL[variant] or "yellow")
		end
		return if variant == "sky" then "chip_blue" else "chip_dark"
	elseif role == "header" then
		return "bar_" .. (V3_BAR_FILL[variant] or "yellow")
	elseif role == "panel" or role == "card" then
		return if variant == "sky" then "frame_blue" elseif variant == "go" then "frame_lime" elseif variant == "header" or variant == "orange" then "frame_yellow" elseif variant == "danger" then "frame_danger" else "frame_dark"
	end
	return nil -- inset wells stay flat
end

function UiSkinRules.v3Kind(key: string): string
	return string.match(key, "^(%a+)_") or "frame"
end

-- v38-flow round 2: the type scale. Text caps (UITextSizeConstraint maxima) were tuned on 844x390, so at 1080p
-- every label topped out phone-small in a big box. Caps grow with the viewport height: 1 on a phone (<= 540 px tall),
-- 2 at 1080p (a 20 px phone cap reads ~40 px). Box sizes stay the caller's; TextScaled still fits the box.
function UiSkinRules.typeScale(vpY: number): number
	return math.clamp(vpY / 540, 1, 2)
end

-- HSV of a 0..255 colour (h in degrees).
function UiSkinRules.hsv(c: RGB): (number, number, number)
	local r, g, b = c[1] / 255, c[2] / 255, c[3] / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 1e-6 then
		if mx == r then
			h = 60 * (((g - b) / d) % 6)
		elseif mx == g then
			h = 60 * ((b - r) / d + 2)
		else
			h = 60 * ((r - g) / d + 4)
		end
	end
	return h, (if mx > 0 then d / mx else 0), mx
end

-- A legacy fill colour -> theme variant name: wood / dark / brown -> "neutral", greys -> "disabled", greens -> "go",
-- blues -> "sky", reds -> "danger", orange / brass / gold -> "orange", purples -> "purple".
function UiSkinRules.classify(c: RGB?): string
	if not c then
		return "neutral"
	end
	local h, s, v = UiSkinRules.hsv(c)
	if s < 0.2 then
		return if v > 0.4 then "disabled" else "neutral"
	end
	if v < 0.45 then
		return "neutral"
	end
	if h < 14 or h >= 335 then
		return "danger"
	elseif h < 62 then
		return if v < 0.62 then "neutral" else "orange"
	elseif h < 170 then
		return "go"
	elseif h < 255 then
		return "sky"
	end
	return "purple"
end

-- The variant a button / panel draws as. Explicit theme slots ("go", "sky", ...) win; a legacy slot uses the caller's
-- colour (neutral buttons read as sky, neutral panels as the blue panel).
local BUTTON_SLOTS = { btn_primary = "go", btn_wood = "sky", btn_danger = "danger", btn_round = "sky" }
function UiSkinRules.variantFor(slot: string, color: RGB?, role: string?): string
	if UiSkinRules.VARIANT[slot] then
		return slot
	end
	local cls = if color then UiSkinRules.classify(color) else nil
	if role == "button" then
		if cls == nil then
			return BUTTON_SLOTS[slot] or "sky"
		end
		return if cls == "neutral" then "sky" else cls
	end
	if role == "card" or role == "chip" then
		if cls == nil or cls == "neutral" or cls == "disabled" then
			return if role == "chip" then "inset" else "card"
		end
		return cls
	end
	return "panel"
end

-- Which drawing role a slot has (legacy art slots and the v2 names).
local ROLE = {
	panel_wood = "panel",
	panel = "panel",
	sign_hanging = "chip",
	toast_slab = "chip",
	chip = "chip",
	inset = "inset",
	row_plank = "card",
	card = "card",
	header = "header",
	btn_primary = "button",
	btn_wood = "button",
	btn_danger = "button",
	btn_round = "button",
	go = "button",
	sky = "button",
	orange = "button",
	danger = "button",
	disabled = "button",
	purple = "button",
	tab_idle = "tab",
	tab_selected = "tab",
	tab = "tab",
}
function UiSkinRules.roleOf(slot: string): string
	return ROLE[slot] or "panel"
end

local function lerp(a: RGB, b: RGB, t: number): RGB
	return {
		math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
		math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
		math.floor(a[3] + (b[3] - a[3]) * t + 0.5),
	}
end
UiSkinRules.lerp = lerp

function UiSkinRules.shade(c: RGB, k: number): RGB
	return { math.floor(c[1] * k + 0.5), math.floor(c[2] * k + 0.5), math.floor(c[3] * k + 0.5) }
end

-- The bottom colour for an arbitrary top colour (a retint to a colour that is not a variant).
function UiSkinRules.bottomFor(top: RGB): RGB
	return UiSkinRules.shade(top, 0.62)
end

export type Stop = { t: number, mul: { number } } -- mul: 0..1 per channel, multiplied over the base fill
-- A face gradient as (base fill, stops): the base is the top colour lifted for the gloss band, every stop is a per-channel
-- multiplier over the base (UIGradient multiplies BackgroundColor3), so retinting the base keeps the shading.
--   gloss: the lighter band's height as a fraction (0 = none); lipFrac: the lip's height as a fraction (0 = none).
function UiSkinRules.faceStops(top: RGB, bottom: RGB, gloss: number, lipFrac: number): (RGB, { Stop })
	local Sh = UiSkinRules.SHAPE
	local base = if gloss > 0 then lerp(top, UiSkinRules.WHITE, Sh.glossLift) else top
	local function mul(c: RGB): { number }
		local out = {}
		for i = 1, 3 do
			out[i] = math.clamp(c[i] / math.max(1, base[i]), 0, 1)
		end
		return out
	end
	local stops: { Stop } = {}
	local function add(t: number, c: RGB)
		table.insert(stops, { t = math.clamp(t, 0, 1), mul = mul(c) })
	end
	local lip = math.clamp(lipFrac, 0, 0.45)
	local bodyEnd = 1 - lip
	if gloss > 0 then
		add(0, base)
		add(gloss - 0.002, lerp(top, UiSkinRules.WHITE, Sh.glossLift * 0.45))
		add(gloss, lerp(top, bottom, gloss * 0.35))
	else
		add(0, top)
	end
	if lip > 0 then
		add(bodyEnd - 0.002, bottom)
		add(bodyEnd, UiSkinRules.shade(bottom, Sh.lipShade))
		add(1, UiSkinRules.shade(bottom, Sh.lipShade * 0.85))
	else
		add(1, bottom)
	end
	return base, stops
end

return UiSkinRules
