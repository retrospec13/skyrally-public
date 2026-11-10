--!strict
-- Notification skins (economy v3 phase 3b): pure data, one row per notification KIND. NotifyKit (client) reads a skin and draws it;
-- no layout or queue logic lives here, so the owner's UI art drops in by filling the optional image fields below.
--  * panel.image / panel.slice: when set (an rbxassetid string and a 9-slice rect {l, t, r, b}), NotifyKit draws that image as the
--    panel instead of the solid fill; the fill colour stays as the fallback while the image loads.
--  * icon.image: an rbxassetid shown in the icon slot; icon.glyph is the plain-text stand-in (one symbol, never an emoji).
--  * Colours are {r, g, b} in 0..255 so Lune specs and the client share the table.
-- Default look: solid dark panels, strong contrast, a bright accent bar on the left, one icon slot. No pills, no blur.
local NotifySkin = {}

export type RGB = { number }
export type Skin = {
	panel: { color: RGB, alpha: number, image: string?, slice: { number }? },
	accent: RGB, -- the accent bar and the rim
	rimWidth: number,
	text: RGB,
	title: RGB,
	font: string, -- Enum.Font name
	icon: { size: number, image: string?, glyph: string },
	primary: RGB, -- primary button fill (modal)
	primaryText: RGB,
}

local function skin(panel: RGB, accent: RGB, glyph: string, title: RGB?): Skin
	return {
		panel = { color = panel, alpha = 0.04, image = nil, slice = nil },
		accent = accent,
		rimWidth = 2,
		text = { 250, 246, 236 },
		title = title or accent,
		font = "GothamBold",
		icon = { size = 28, image = nil, glyph = glyph },
		primary = accent,
		primaryText = { 24, 20, 16 },
	}
end

NotifySkin.KINDS = { "info", "success", "reward", "warn", "storm", "portal", "unlock" } :: { string }

NotifySkin.SKINS = {
	info = skin({ 28, 32, 40 }, { 150, 190, 240 }, "i"),
	success = skin({ 24, 38, 30 }, { 120, 220, 140 }, "+"),
	reward = skin({ 40, 34, 20 }, { 255, 204, 72 }, "+"),
	warn = skin({ 44, 28, 22 }, { 255, 150, 90 }, "!"),
	storm = skin({ 24, 26, 46 }, { 150, 150, 255 }, "~"),
	portal = skin({ 22, 36, 44 }, { 90, 220, 230 }, ">"),
	unlock = skin({ 36, 28, 44 }, { 230, 150, 255 }, "*"),
} :: { [string]: Skin }

-- Per-surface shape (px at S = 1); NotifyKit scales these with HudLayoutRules.px.
NotifySkin.SURFACES = {
	toast = { corner = 6, pad = 8, textBase = 18, accentBar = 6 },
	banner = { corner = 6, pad = 8, textBase = 16, accentBar = 6 },
	modal = { corner = 10, pad = 16, textBase = 20, accentBar = 0 },
	arch = { corner = 6, pad = 6, textBase = 22, accentBar = 0 },
} :: { [string]: { corner: number, pad: number, textBase: number, accentBar: number } }

-- Full panels drawn with the kit's look (economy v3 phase 5: the Storm vendor). Same rule as the kinds: colours here, the owner's
-- art drops in through the optional image fields (panel / row / button 9-slices, the vendor portrait); nil = the solid fills.
export type PanelSkin = {
	panel: { color: RGB, alpha: number, image: string?, slice: { number }? },
	header: RGB,
	row: { color: RGB, alpha: number, image: string?, slice: { number }? },
	rowLocked: RGB,
	text: RGB,
	muted: RGB,
	title: RGB,
	buy: RGB,
	owned: RGB,
	locked: RGB,
	buttonText: RGB,
	font: string,
	titleFont: string,
	portrait: string?, -- rbxassetid of the vendor portrait (art pending)
}

NotifySkin.PANELS = {
	stormVendor = {
		panel = { color = { 20, 22, 40 }, alpha = 0.04, image = nil, slice = nil },
		header = { 30, 32, 58 },
		row = { color = { 34, 36, 64 }, alpha = 0, image = nil, slice = nil },
		rowLocked = { 28, 28, 40 },
		text = { 240, 240, 250 },
		muted = { 160, 164, 190 },
		title = { 255, 222, 110 },
		buy = { 150, 120, 255 },
		owned = { 90, 200, 150 },
		locked = { 90, 90, 110 },
		buttonText = { 250, 248, 240 },
		font = "GothamBold",
		titleFont = "GothamBlack",
		portrait = nil,
	},
} :: { [string]: PanelSkin }

-- The pre-race vehicle pick strip (economy v3 phase 6, client/VehiclePick). Same contract as the skins above: the owner's
-- art drops in through the image fields; the solid fills stay as the fallback.
NotifySkin.PICKER = {
	panel = { color = { 24, 26, 34 }, alpha = 0.12, image = nil, slice = nil },
	rim = { 255, 214, 90 },
	header = { 255, 214, 90 },
	headerText = "VEHICLE",
	card = { color = { 44, 40, 52 }, image = nil, slice = nil },
	cardSelected = { color = { 78, 148, 58 }, image = nil, slice = nil },
	cardText = { 250, 246, 236 },
	font = "GothamBlack",
	corner = 8,
	close = { 230, 220, 205 },
}
-- Arch label per queue state (economy v3 phase 3, shared/PortalQueueRules): the skin kind, the glow light on the arch
-- (PointLight brightness and range in studs; 0 = off) and the rim pulse (extra px at the peak; 0 = steady). FILLING
-- reads hottest so a gathering lobby is seen across the plaza; RACING dims. Owner art drops in through the kinds.
export type ArchState = { kind: string, glow: number, range: number, pulse: number }
NotifySkin.ARCH_STATES = {
	open = { kind = "portal", glow = 0.6, range = 14, pulse = 0 },
	filling = { kind = "reward", glow = 2.2, range = 22, pulse = 2 },
	racing = { kind = "storm", glow = 0.4, range = 12, pulse = 0 },
} :: { [string]: ArchState }

function NotifySkin.archState(state: string?): ArchState
	return NotifySkin.ARCH_STATES[state or "open"] or NotifySkin.ARCH_STATES.open
end

function NotifySkin.get(kind: string?): Skin
	return NotifySkin.SKINS[kind or "info"] or NotifySkin.SKINS.info
end

return NotifySkin
