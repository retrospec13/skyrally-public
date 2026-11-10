--!strict
-- Pure rules for the Wood-and-Stone UI sound kit (REMARKABLE item 4; client/UiSound plays them). No Roblox services
-- here, so tools/tests/uisound_spec.luau checks the scale, the gates and the step maths under Lune.
--   * kinds -> cues (tools/audio/synth_ui.py writes the cues; shared/UiAudioAssets holds their uploaded ids; the two
--     sfx_v2 kinds, unlock and vote, use shared/SfxV2Audio cues instead)
--   * the selection marimba: one C5 sample pitched by PlaybackSpeed over a major pentatonic (1, 9/8, 5/4, 3/2, 5/3),
--     climbing an octave and a half and walking back down, so a long Garage list plays a wave, never a squeak
--   * gates: nothing under the TrackSwitching curtain (unless the caller is the curtain mini-game), a per-kind minimum
--     gap so fifty rapid taps never stack, and selection notes held back just after a press (rebuilt rows and opened
--     panels move gamepad selection in code; that must not ring a second note over the press)
local UiSoundRules = {}

export type Kind = "tap" | "stone" | "confirm" | "back" | "deny" | "select" | "hover" | "tab" | "purchase" | "unlock" | "vote"

UiSoundRules.KINDS = { "tap", "stone", "confirm", "back", "deny", "select", "hover", "tab", "purchase", "unlock", "vote" } :: { Kind }

-- The kinds whose cue is an sfx_v2 role (shared/SfxV2Audio) rather than a ui_* cue from tools/audio/synth_ui.py.
UiSoundRules.SFX_V2_KINDS = { unlock = true, vote = true } :: { [string]: boolean }

UiSoundRules.CUE = {
	tap = "ui_tap",
	stone = "ui_stone",
	confirm = "ui_confirm",
	back = "ui_back",
	deny = "ui_deny",
	select = "ui_marimba",
	hover = "ui_marimba",
	tab = "ui_tab",
	purchase = "ui_purchase",
	unlock = "unlock_fanfare",
	vote = "vote_pip",
} :: { [string]: string }

-- Sound.Volume per kind before the UI SoundGroup (UiVolume). The stone cues are louder files (-8 dB RMS against -15
-- for the marimba), so they sit lower here.
UiSoundRules.VOLUME = {
	tap = 0.75,
	stone = 0.5,
	confirm = 0.7,
	back = 0.6,
	deny = 0.5,
	select = 0.5,
	hover = 0.22,
	tab = 0.7,
	purchase = 0.8,
	unlock = 0.65,
	vote = 0.25,
} :: { [string]: number }

-- Minimum seconds between two plays of one kind (the pool of 4 caps overlap; this caps machine-gun repeats).
UiSoundRules.MIN_GAP = {
	tap = 0.035,
	stone = 0.05,
	confirm = 0.08,
	back = 0.08,
	deny = 0.12,
	select = 0.03,
	hover = 0.05,
	tab = 0.06,
	purchase = 0.25,
	unlock = 0.5,
	vote = 0.1,
} :: { [string]: number }

UiSoundRules.POOL_SIZE = 4
UiSoundRules.DEFAULT_UI_VOLUME = 0.6
-- A selection note this soon after a press is the code moving selection (panel opened, rows rebuilt): stay quiet.
UiSoundRules.SELECT_HUSH_AFTER_PRESS = 0.3

UiSoundRules.PENTATONIC = { 1, 9 / 8, 5 / 4, 3 / 2, 5 / 3 }
-- Highest scale index (0-based): 7 notes up from C5 = E6 (ratio 2.5). PlaybackSpeed above ~2.5 thins the marimba.
UiSoundRules.TOP_INDEX = 7

-- Pitch ratio for a 1-based selection step. Steps climb the pentatonic (1 -> C5, 2 -> D5, ... 6 -> C6, 8 -> E6) and
-- then walk back down and up again (ping-pong), so any list length stays in the sweet range.
function UiSoundRules.pitch(step: number?): number
	if step == nil or step < 1 then
		return 1
	end
	local top = UiSoundRules.TOP_INDEX
	local i = (math.floor(step) - 1) % (2 * top)
	if i > top then
		i = 2 * top - i
	end
	local n = #UiSoundRules.PENTATONIC
	local octave = math.floor(i / n)
	return UiSoundRules.PENTATONIC[(i % n) + 1] * (2 ^ octave)
end

-- Pitch of the vote pip for the Nth vote in (1 = the first): each vote a little higher, so a room filling up climbs.
function UiSoundRules.votePitch(votes: number?): number
	return 1 + 0.06 * math.clamp(votes or 0, 0, 8)
end

-- Step for a button: its 1-based rank among sibling buttons, lifted by the row it sits in (a Garage grid row or an
-- Adventure board zone carries LayoutOrder), so moving right or down both climb.
function UiSoundRules.step(rank: number, rowOrder: number?): number
	local lift = if rowOrder and rowOrder > 1 then math.floor(rowOrder) - 1 else 0
	return math.max(1, math.floor(rank)) + lift
end

export type Slot = { order: number, x: number, y: number }

-- 1-based rank of `self` among `slots` (the visible sibling buttons, self included): by LayoutOrder when any sibling
-- sets one, else reading order (rows top to bottom by y within 4 px, then x).
function UiSoundRules.rank(slots: { Slot }, self: Slot): number
	local anyOrder = false
	for _, s in slots do
		if s.order ~= 0 then
			anyOrder = true
			break
		end
	end
	local function before(a: Slot, b: Slot): boolean
		if anyOrder and a.order ~= b.order then
			return a.order < b.order
		end
		if math.abs(a.y - b.y) > 4 then
			return a.y < b.y
		end
		return a.x < b.x
	end
	local r = 1
	for _, s in slots do
		if s ~= self and before(s, self) then
			r += 1
		end
	end
	return r
end

export type GateState = {
	now: number,
	lastAt: number?, -- last play of this kind
	switching: boolean, -- workspace.TrackSwitching
	allowCurtain: boolean?, -- the curtain mini-game's own sounds
	lastPressAt: number?, -- last press sound of any kind
}

-- Whether a sound of `kind` may start now.
function UiSoundRules.gate(kind: string, st: GateState): boolean
	if UiSoundRules.CUE[kind] == nil then
		return false
	end
	if st.switching and not st.allowCurtain then
		return false
	end
	if st.lastAt and st.now - st.lastAt < (UiSoundRules.MIN_GAP[kind] or 0.03) then
		return false
	end
	if (kind == "select" or kind == "hover") and st.lastPressAt and st.now - st.lastPressAt < UiSoundRules.SELECT_HUSH_AFTER_PRESS then
		return false
	end
	return true
end

-- Press kinds count as presses for the selection hush; selection/hover notes and another racer's vote pip do not.
function UiSoundRules.isPress(kind: string): boolean
	return kind ~= "select" and kind ~= "hover" and kind ~= "vote"
end

-- UiVolume attribute -> SoundGroup volume.
function UiSoundRules.groupVolume(attr: any): number
	if type(attr) == "number" and attr == attr then
		return math.clamp(attr, 0, 1)
	end
	return UiSoundRules.DEFAULT_UI_VOLUME
end

-- Press feel keyframes (client/UiSound): squash scale and the wobble Rotation steps with their durations (0.18 s in
-- all), and the deny shake as X offsets in px.
UiSoundRules.PRESS_SCALE = 0.92
UiSoundRules.HOVER_SCALE = 1.06
UiSoundRules.WOBBLE = { { -3, 0.04 }, { 2, 0.06 }, { 0, 0.08 } }
UiSoundRules.SHAKE = { 4, -4, 3, -2, 0 }
UiSoundRules.SHAKE_STEP = 0.035

return UiSoundRules
