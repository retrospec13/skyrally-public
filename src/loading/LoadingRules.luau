--!strict
-- Loading screen rules (TEST_LIST_LAUNCH L27 transitions, L42 load to first control). Pure: no services, so
-- tools/tests/loading_spec.luau drives all of it; the LocalScript next to this module (init.client.luau) does the drawing
-- and the waiting. This module lives in ReplicatedFirst because the script that shows the screen must not wait for
-- ReplicatedStorage.
local LoadingRules = {}

-- The game's name on the loading screen: ONE constant. It is a working title; renaming the game changes this line only.
LoadingRules.TITLE = "SkyRally"
LoadingRules.TAGLINE = "Drive. Fly. Race!"

LoadingRules.TIMEOUT = 30 -- s: the screen leaves by then whatever is still missing, so it can never stick (a cold server builds the hub first)
LoadingRules.MIN_SHOW = 1.4 -- s: long enough to read the logo; the join-to-control time is logged before this
LoadingRules.ASSET_BUDGET = 8 -- s: the preload gets this long, then counts as done (a slow CDN must not hold the game)
LoadingRules.FADE = 0.55 -- s
LoadingRules.TIP_SECONDS = 3.4
LoadingRules.PLANE_PERIOD = 5.2 -- s for one crossing of the sky
LoadingRules.BUDGET_HUB = 10 -- s, L42: hub under 10 s
LoadingRules.BUDGET_TRACK = 12 -- s, L42: track under 12 s

export type Milestone = { id: string, weight: number, text: string }

-- In the order a join normally gets through them. Weights add to 1; the bar moves by real progress only.
LoadingRules.MILESTONES = {
	{ id = "game", weight = 0.1, text = "Opening the hangar" },
	{ id = "assets", weight = 0.35, text = "Painting the signs" },
	{ id = "character", weight = 0.15, text = "Finding your pilot" },
	{ id = "vehicle", weight = 0.2, text = "Fueling up" },
	{ id = "track", weight = 0.2, text = "Rolling out the track" },
} :: { Milestone }

-- The wood/stone HUD sprites the race UI draws first (the ids RaceUI.ASSET_IDS uses; loading_spec checks they match) and
-- the engine loop SoundJuice creates at join (its SOUND_IDS). Preloading them is milestone "assets".
LoadingRules.HUD_SPRITES = { 96696699374497, 92050151129479, 140120222691020, 129086497166378 }
LoadingRules.KEY_SOUNDS = {
	"rbxassetid://91840597129266", -- EngineLoop
}
-- Shared audio keys (UiAudioAssets / AudioAssets) preloaded too when present: the button cues. Not the hub theme (perf
-- pass 2026-10-19): a multi-megabyte music stream held the first control on a phone connection; Music starts it when
-- it arrives and fades it in. The race cues (sfx_v2) are not needed at join either: client/Sfx preloads them in the hub.
LoadingRules.KEY_SOUND_CUES = { "ui_tap", "ui_confirm", "ui_back" }

function LoadingRules.thumbUrl(assetId: number, w: number, h: number): string
	return string.format("rbxthumb://type=Asset&id=%d&w=%d&h=%d", assetId, w, h) -- the form RaceUI loads its sprites with
end

---------------------------------------------------------------------------------------------------- progress

export type Done = { [string]: boolean }

-- 0..1 from the milestones reached; `assetFraction` (0..1) counts toward the assets milestone while it is under way.
function LoadingRules.progress(done: Done, assetFraction: number?): number
	local total = 0
	for _, m in LoadingRules.MILESTONES do
		if done[m.id] then
			total += m.weight
		elseif m.id == "assets" and assetFraction then
			total += m.weight * math.clamp(assetFraction, 0, 1)
		end
	end
	return math.clamp(total, 0, 1)
end

function LoadingRules.allDone(done: Done): boolean
	for _, m in LoadingRules.MILESTONES do
		if not done[m.id] then
			return false
		end
	end
	return true
end

function LoadingRules.missing(done: Done): { string }
	local out: { string } = {}
	for _, m in LoadingRules.MILESTONES do
		if not done[m.id] then
			table.insert(out, m.id)
		end
	end
	return out
end

-- The line under the bar: the first milestone still open, or the closing word.
function LoadingRules.statusText(done: Done): string
	for _, m in LoadingRules.MILESTONES do
		if not done[m.id] then
			return m.text .. "..."
		end
	end
	return "Ready for takeoff!"
end

-- What the displayed bar does each frame: ease toward the target, never backward, never past it, and always creeping
-- so a long wait on one milestone still looks alive (the creep stops just short of the target).
function LoadingRules.smooth(shown: number, target: number, dt: number): number
	if shown >= target then
		return math.max(shown, target)
	end
	local eased = shown + (target - shown) * math.min(1, dt * 6)
	return math.min(target, math.max(eased, shown + dt * 0.04))
end

export type Status = "wait" | "ready" | "timeout"

-- Whether the screen may leave. `elapsed` is seconds since the screen appeared. A finished load waits for MIN_SHOW;
-- an unfinished one leaves at TIMEOUT regardless.
function LoadingRules.status(done: Done, elapsed: number): Status
	if elapsed >= LoadingRules.TIMEOUT then
		return if LoadingRules.allDone(done) then "ready" else "timeout"
	end
	if LoadingRules.allDone(done) and elapsed >= LoadingRules.MIN_SHOW then
		return "ready"
	end
	return "wait"
end

---------------------------------------------------------------------------------------------------- tips

export type Mode = "Touch" | "Gamepad" | "KeyboardMouse"

-- The input family from the device flags (same split as client/InputMode.initialMode).
function LoadingRules.modeFor(touch: boolean, keyboard: boolean, gamepad: boolean): Mode
	if touch and not keyboard then
		return "Touch"
	end
	if gamepad and not keyboard then
		return "Gamepad"
	end
	return if keyboard then "KeyboardMouse" elseif touch then "Touch" else "KeyboardMouse"
end

local CONTROL_TIPS: { [string]: { string } } = {
	Touch = {
		"Drag the left pad to steer.",
		"Tap TURN for a sharp bank.",
		"Tap ITEM to use what you grabbed.",
		"Stuck? Tap RESPAWN to hop back on.",
		"Tap the gear for volume and more.",
	},
	Gamepad = {
		"Left stick steers. A is gas, B brakes.",
		"Press R1 for a sharp bank.",
		"Press X to use your item.",
		"Stuck? Press VIEW to hop back on.",
		"In the hub, L1 + R1 open Settings.",
	},
	KeyboardMouse = {
		"A and D steer. W is gas, S brakes.",
		"Hold Shift for a sharp bank.",
		"Press F to use your item.",
		"Stuck? Press BACKSPACE to hop back on.",
		"Press O for volume and more.",
	},
}

local GENERAL_TIPS: { string } = {
	"Drive through a portal to start a race!",
	"Drive over item balloons to grab one.",
	"Boost pads make you zoom!",
	"Win races to earn Sky Tokens.",
	"Sky Tokens open new portals.",
	"Finish a map to unlock its battle.",
}

-- The rotation for one device: the portal tip first (it is the way into the game), then general and control tips
-- interleaved so a control tip is never more than one step away.
function LoadingRules.tipsFor(mode: string): { string }
	local controls = CONTROL_TIPS[mode] or CONTROL_TIPS.KeyboardMouse
	local out: { string } = { GENERAL_TIPS[1] }
	local gi, ci = 2, 1
	while gi <= #GENERAL_TIPS or ci <= #controls do
		if ci <= #controls then
			table.insert(out, controls[ci])
			ci += 1
		end
		if gi <= #GENERAL_TIPS then
			table.insert(out, GENERAL_TIPS[gi])
			gi += 1
		end
	end
	return out
end

-- Which tip shows `elapsed` seconds in (1-based, wraps).
function LoadingRules.tipIndex(count: number, elapsed: number): number
	if count <= 0 then
		return 1
	end
	return math.floor(math.max(0, elapsed) / LoadingRules.TIP_SECONDS) % count + 1
end

-- 0..1 within the current tip's slot: the script fades the text in at the start and out at the end.
function LoadingRules.tipPhase(elapsed: number): number
	return (math.max(0, elapsed) % LoadingRules.TIP_SECONDS) / LoadingRules.TIP_SECONDS
end

-- Tip text opacity for a phase: in over the first 12 %, out over the last 12 %.
function LoadingRules.tipAlpha(phase: number): number
	return math.clamp(math.min(phase / 0.12, (1 - phase) / 0.12), 0, 1)
end

---------------------------------------------------------------------------------------------------- plane

-- The silhouette crosses the sky left to right, forever: x as a fraction of the screen width (from off the left edge to
-- off the right), a gentle bob in screen-height fractions and a tilt in degrees.
function LoadingRules.planeX(t: number): number
	local k = (t % LoadingRules.PLANE_PERIOD) / LoadingRules.PLANE_PERIOD
	return -0.16 + k * 1.32
end

function LoadingRules.planeBob(t: number): number
	return 0.018 * math.sin(t * 2.1)
end

function LoadingRules.planeTilt(t: number): number
	return -4 * math.cos(t * 2.1)
end

---------------------------------------------------------------------------------------------------- L42 log

-- Seconds budget for the mode the player landed in: the hub 10 s, a track 12 s.
function LoadingRules.budgetFor(mode: any): number
	return if mode == "hub" or mode == nil then LoadingRules.BUDGET_HUB else LoadingRules.BUDGET_TRACK
end

-- One line for the output / telemetry: [SkyRally][LOAD] join_to_control=4.20s PASS(<=10s) game=0.40 assets=2.90 ...
-- `stamps` are seconds since the screen appeared per milestone; a timeout lists what was missing.
function LoadingRules.formatLog(stamps: { [string]: number }, missing: { string }, seconds: number, mode: any, map: any): string
	local budget = LoadingRules.budgetFor(mode)
	local verdict
	if #missing > 0 then
		verdict = "TIMEOUT(missing=" .. table.concat(missing, ",") .. ")"
	elseif seconds <= budget then
		verdict = string.format("PASS(<=%ds)", budget)
	else
		verdict = string.format("SLOW(>%ds)", budget)
	end
	local parts: { string } = {}
	for _, m in LoadingRules.MILESTONES do
		local s = stamps[m.id]
		table.insert(parts, string.format("%s=%s", m.id, if s then string.format("%.2f", s) else "-"))
	end
	return string.format(
		"[SkyRally][LOAD] join_to_control=%.2fs %s %s mode=%s map=%s",
		seconds,
		verdict,
		table.concat(parts, " "),
		tostring(mode or "?"),
		tostring(map or "?")
	)
end

return LoadingRules
