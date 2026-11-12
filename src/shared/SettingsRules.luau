--!strict
-- Player settings, pure rules (audit H13; TEST_LIST_LAUNCH L24 volume sliders, L40 low-end profile). No services: the
-- client panel (client/Settings), the server relay (server/SettingsService) and SaveService's load path all share these
-- definitions, so a value means the same thing on every side and a forged payload is cut down in one place.
-- Settings are NOT progression. They live in the profile's existing `settings` table (a dictionary of these keys);
-- nothing here reads or writes tokens, bosses or best times.
--   volumes   0..1 numbers   -> player attributes MusicVolume, SfxVolume, AmbienceVolume, UiVolume (the sound modules
--                               already scale by them; SfxVolume drives the SkyRallySfx SoundGroup)
--   toggles   booleans       -> player attributes AutoThrottle (ASSIST), CameraShake, LowGraphics (read through client/Settings), EngineSound, FreeDriving
--                               (the advanced flight mode, docs/design/FLIGHT_GUIDE.md 12: off = the Mario Kart default).
--                               The server also publishes the validated FREE DRIVING value as the server-owned attribute
--                               FlightMode ("mk" | "free", FLIGHT_MODE_ATTR), the one the flight code and the server's
--                               return checks read; the client never writes it.
local SettingsRules = {}

export type Kind = "volume" | "toggle"
export type Def = {
	key: string, -- the profile.settings key
	attr: string, -- the replicated player attribute the client modules read
	kind: Kind,
	default: number | boolean,
	label: string, -- short, readable at 740x360
}

SettingsRules.DEFS = {
	{ key = "musicVolume", attr = "MusicVolume", kind = "volume", default = 1, label = "MUSIC" },
	{ key = "sfxVolume", attr = "SfxVolume", kind = "volume", default = 1, label = "EFFECTS" },
	{ key = "ambienceVolume", attr = "AmbienceVolume", kind = "volume", default = 1, label = "AMBIENCE" },
	-- Same default as UiSoundRules.DEFAULT_UI_VOLUME (0.6): a player who never opens Settings hears what they always did.
	{ key = "uiVolume", attr = "UiVolume", kind = "volume", default = 0.6, label = "MENU SOUNDS" },
	{ key = "cameraShake", attr = "CameraShake", kind = "toggle", default = true, label = "CAMERA SHAKE" },
	{ key = "lowGraphics", attr = "LowGraphics", kind = "toggle", default = false, label = "LOW GRAPHICS" },
	-- ASSIST (auto throttle + steering assist, shared/AssistRules): on by default so a phone drives forward in a race; the
	-- HUD chip, the T key and the gear row flip it and it is saved. The attribute is the one FlightController mirrors.
	{ key = "assist", attr = "AutoThrottle", kind = "toggle", default = true, label = "ASSIST" },
	-- ENGINE SOUND (audio-v2, shared/EngineMixRules): on = a subtle low engine layer while driving, silent at idle; off = none.
	{ key = "engineSound", attr = "EngineSound", kind = "toggle", default = true, label = "ENGINE SOUND" },
	-- Advanced, off by default (owner 2026-10-20): fly anywhere, with the bead mist as the only path hint.
	{ key = "freeDriving", attr = "FreeDriving", kind = "toggle", default = false, label = "FREE DRIVING" },
} :: { Def }

-- The server-owned flight mode attribute (FlightGuideRules.MODE_ATTR) and its value for a FREE DRIVING setting: only a
-- boolean true is Free driving; anything else is the default.
SettingsRules.FLIGHT_MODE_ATTR = "FlightMode"
function SettingsRules.flightModeOf(freeDriving: any): string
	return if freeDriving == true then "free" else "mk"
end

local BY_KEY: { [string]: Def } = {}
for _, d in SettingsRules.DEFS do
	BY_KEY[d.key] = d
end

-- A client payload never carries more entries than there are settings; more is a forged or broken message.
SettingsRules.MAX_PAYLOAD_KEYS = #SettingsRules.DEFS
-- Slider granularity: sticks and the D-pad move one notch, storage keeps two decimals so a save stays small and equal
-- values stay equal.
SettingsRules.STEP = 0.1
-- Low graphics keeps this share of the burst particles and switches zone ambience emitters off.
SettingsRules.LOW_GFX_PARTICLE_SCALE = 0.4
-- Phone tier: a touch-only device (no keyboard) starts at this share of the particles with the heavy smoke layers off,
-- without the player touching anything. LOW GRAPHICS still wins (0.4) when it is on.
SettingsRules.PHONE_PARTICLE_SCALE = 0.6

function SettingsRules.def(key: string): Def?
	return BY_KEY[key]
end

function SettingsRules.defaults(): { [string]: number | boolean }
	local out: { [string]: number | boolean } = {}
	for _, d in SettingsRules.DEFS do
		out[d.key] = d.default
	end
	return out
end

-- Any value -> a volume in 0..1 rounded to 0.01, or nil when it is not a finite number.
function SettingsRules.cleanVolume(v: any): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.floor(math.clamp(v, 0, 1) * 100 + 0.5) / 100
end

-- One value for one key: volumes clamp, toggles accept booleans only, unknown keys and wrong types give nil.
function SettingsRules.cleanValue(key: any, v: any): (number | boolean)?
	if type(key) ~= "string" then
		return nil
	end
	local d = BY_KEY[key]
	if not d then
		return nil
	end
	if d.kind == "volume" then
		return SettingsRules.cleanVolume(v)
	end
	if type(v) == "boolean" then
		return v
	end
	return nil
end

-- A client payload -> the valid part as { key = value }, or nil when nothing valid is left. Unknown keys and bad values
-- are dropped one by one; an over-long payload is refused whole.
function SettingsRules.cleanUpdate(payload: any): { [string]: number | boolean }?
	if type(payload) ~= "table" then
		return nil
	end
	local out: { [string]: number | boolean } = {}
	local seen = 0
	local any = false
	for k, v in pairs(payload :: { [any]: any }) do
		seen += 1
		if seen > SettingsRules.MAX_PAYLOAD_KEYS then
			return nil
		end
		local cleaned = SettingsRules.cleanValue(k, v)
		if cleaned ~= nil then
			out[k :: string] = cleaned
			any = true
		end
	end
	return if any then out else nil
end

-- A stored settings table, repaired in place on load: a known key holding the wrong type is removed (the default
-- applies), an out-of-range or unrounded volume is clamped. Unknown keys stay, so an older server never strips what a
-- newer build wrote. Returns whether anything changed.
function SettingsRules.sanitizeStored(settings: { [any]: any }): boolean
	local changed = false
	for key, d in BY_KEY do
		local current = settings[key]
		if current ~= nil then
			local cleaned = SettingsRules.cleanValue(d.key, current)
			if cleaned ~= current then
				settings[key] = cleaned
				changed = true
			end
		end
	end
	return changed
end

-- Merges a cleaned update into a stored table. Returns whether a value changed (an equal value is not a change, so the
-- server skips a save for it).
function SettingsRules.apply(settings: { [any]: any }, update: { [string]: number | boolean }): boolean
	local changed = false
	for key, v in update do
		if settings[key] ~= v then
			settings[key] = v
			changed = true
		end
	end
	return changed
end

-- Stored table -> every setting with defaults filled in.
function SettingsRules.resolve(settings: { [any]: any }?): { [string]: number | boolean }
	local out = SettingsRules.defaults()
	if type(settings) == "table" then
		for key in BY_KEY do
			local cleaned = SettingsRules.cleanValue(key, (settings :: any)[key])
			if cleaned ~= nil then
				out[key] = cleaned
			end
		end
	end
	return out
end

-- Player attribute value -> a setting, falling back to the default (the attribute may be unset or hold junk).
function SettingsRules.fromAttribute(key: string, attr: any): number | boolean
	local d = BY_KEY[key]
	if not d then
		return false
	end
	local cleaned = SettingsRules.cleanValue(key, attr)
	if cleaned == nil then
		return d.default
	end
	return cleaned
end

---------------------------------------------------------------------------------------------------- the player's choice wins

-- QA V5A: the client AutoThrottle went back from false to true about 20 s after a chip tap. The server publishes the SAVED
-- value as player attributes whenever a profile finishes loading (a slow or retried load in Studio lands that late), and
-- a replicated server write over a client's own attribute value wins on the client. A value the player set this session
-- is newer than anything saved, so both sides keep it:
--   * server: `touched` = every validated value the player sent; publish overlays it on the saved table.
--   * client: `chosen` = every value the player set through Settings.set; a server attribute change that disagrees is
--     refused (the client writes its own value back and re-sends it).
-- Keys the player never touched still follow the server (first load, a rejoin on another device).
function SettingsRules.overlay(resolved: { [string]: number | boolean }, touched: { [string]: number | boolean }?): { [string]: number | boolean }
	local out: { [string]: number | boolean } = {}
	for k, v in resolved do
		out[k] = v
	end
	if touched then
		for k, v in touched do
			if BY_KEY[k] and SettingsRules.cleanValue(k, v) ~= nil then
				out[k] = v
			end
		end
	end
	return out
end

-- Client: should the value the server just replicated for `key` be accepted? false = the player chose otherwise this
-- session, keep `chosen[key]` (and put it back).
function SettingsRules.acceptRemote(chosen: { [string]: number | boolean }, key: string, incoming: any): boolean
	local mine = chosen[key]
	if mine == nil then
		return true
	end
	return SettingsRules.cleanValue(key, incoming) == mine
end

---------------------------------------------------------------------------------------------------- rate limit

-- Token bucket for the server relay: a slider drag sends about two updates a second, so six in a burst and two a second
-- after that is generous for a person and a wall for a loop.
SettingsRules.BUCKET_BURST = 6
SettingsRules.BUCKET_REFILL = 2 -- tokens per second

export type Bucket = { tokens: number, at: number }

function SettingsRules.newBucket(now: number): Bucket
	return { tokens = SettingsRules.BUCKET_BURST, at = now }
end

-- Takes one token. false = over the limit (the caller drops the message quietly).
function SettingsRules.take(bucket: Bucket, now: number): boolean
	local dt = math.max(0, now - bucket.at)
	bucket.at = now
	bucket.tokens = math.min(SettingsRules.BUCKET_BURST, bucket.tokens + dt * SettingsRules.BUCKET_REFILL)
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

---------------------------------------------------------------------------------------------------- panel helpers

-- Notch index -> volume, rounded so 3 notches read 0.3 and not 0.30000000000000004.
local function notchValue(n: number): number
	return math.floor(n * SettingsRules.STEP * 100 + 0.5) / 100
end

-- Slider position: pointer x inside the track -> a volume notch.
function SettingsRules.fractionAt(x: number, left: number, width: number): number
	if width <= 0 then
		return 0
	end
	local f = math.clamp((x - left) / width, 0, 1)
	return notchValue(math.floor(f / SettingsRules.STEP + 0.5))
end

-- Gamepad / keyboard: one notch up or down from the current value, kept inside 0..1 and on the notch grid.
function SettingsRules.nudge(current: number, dir: number): number
	local notch = math.floor(current / SettingsRules.STEP + 0.5) + (if dir >= 0 then 1 else -1)
	local top = math.floor(1 / SettingsRules.STEP + 0.5)
	return notchValue(math.clamp(notch, 0, top))
end

function SettingsRules.percentText(v: number): string
	return string.format("%d%%", math.floor(math.clamp(v, 0, 1) * 100 + 0.5))
end

-- Camera shake multiplier for the vehicle cameras, the music punch and the portal wake.
function SettingsRules.shakeScale(enabled: boolean): number
	return if enabled then 1 else 0
end

-- phone = SettingsRules.isPhoneTier(...); omitted means a desktop-class device.
function SettingsRules.particleScale(low: boolean, phone: boolean?): number
	if low then
		return SettingsRules.LOW_GFX_PARTICLE_SCALE
	end
	return if phone == true then SettingsRules.PHONE_PARTICLE_SCALE else 1
end

-- The frame governor's session cap (nil = none) only ever lowers the scale.
function SettingsRules.cappedParticleScale(scale: number, cap: number?): number
	return if type(cap) == "number" then math.min(scale, cap) else scale
end

-- Touch-only devices (phones, small tablets) are the phone tier; a touch laptop or a tablet with a keyboard is not.
function SettingsRules.isPhoneTier(touchEnabled: boolean, keyboardEnabled: boolean): boolean
	return touchEnabled and not keyboardEnabled
end

-- Heavy smoke layers (flame smoke, heat wisp puffs) run only on a desktop-class device with LOW GRAPHICS off.
function SettingsRules.heavySmoke(low: boolean, phone: boolean?): boolean
	return not low and phone ~= true
end

-- Settings panel: design size in px and the scale that fits it in the viewport (never past 1.6, never below 0.7).
SettingsRules.PANEL_W = 600
SettingsRules.PANEL_H = 336 -- five toggle rows (ASSIST, CAMERA SHAKE, LOW GRAPHICS, ENGINE SOUND, FREE DRIVING), invite + done in one row

function SettingsRules.panelScale(viewportX: number, viewportY: number): number
	-- v38-flow round 2: up to 2.3 so the plaque fills ~70 % of a 1080p screen (1.6 left it a small box)
	local k = if viewportY >= 600 then 0.72 else 0.94 -- phones keep the near-full-screen fit
	return math.clamp(math.min(viewportX * k / SettingsRules.PANEL_W, viewportY * k / SettingsRules.PANEL_H), 0.7, 2.3)
end

-- An extra page's top edge in panel units (client/Settings.setExtraPage; D22: the owner's ADMIN tab): under the header
-- (PAGE_TOP), and under the Roblox top-left nav when the centred, scaled panel reaches beneath it (phones in landscape),
-- so no row of the page hides under the nav. Always leaves PAGE_MIN_H of page.
SettingsRules.PAGE_TOP = 50
SettingsRules.PAGE_NAV_GAP = 6
SettingsRules.PAGE_MIN_H = 160

function SettingsRules.pageTop(viewportX: number, viewportY: number, scale: number, nav: { x: number, y: number, w: number, h: number }): number
	local w, h = SettingsRules.PANEL_W * scale, SettingsRules.PANEL_H * scale
	local left, top = (viewportX - w) / 2, (viewportY - h) / 2
	local under = nav.w > 0 and nav.h > 0 and nav.x < left + w and nav.x + nav.w > left
	if not under then
		return SettingsRules.PAGE_TOP
	end
	local need = math.ceil((nav.y + nav.h + SettingsRules.PAGE_NAV_GAP - top) / scale)
	return math.clamp(need, SettingsRules.PAGE_TOP, SettingsRules.PANEL_H - SettingsRules.PAGE_MIN_H)
end

return SettingsRules
