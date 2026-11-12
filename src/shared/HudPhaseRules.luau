--!strict
-- HUD phase rules (pure, no Roblox globals; tools/tests/hud_phase_spec.luau runs it under Lune).
--  * phaseOf: which phase the client is in, from the attributes TrackFlow / RaceUI / PodiumCeremony already know.
--  * VISIBLE: HUD element name -> visible per phase (docs/design/HUD_LAYOUT.md section 6). client/HudPhase.luau is the ONE
--    applier of this table. Where the elements go is shared/HudLayoutRules (HUD layout v2); this file only says when.

local HudPhaseRules = {}

export type Phase = "hub" | "countdown" | "race" | "finish" | "results" | "podium" | "battle"
export type Insets = { left: number, top: number, right: number, bottom: number }
export type Rect = { x: number, y: number, w: number, h: number }

HudPhaseRules.PHASES = { "hub", "countdown", "race", "finish", "results", "podium", "battle" } :: { Phase }

-- Priority: the podium covers everything; the results card next; then the finish moment (the local racer crossed, the photo
-- cam / ceremony run, the card is not up yet); then the mode (hub / battle); then the grid countdown.
function HudPhaseRules.phaseOf(mode: any, goAt: any, now: number, resultsUp: boolean, podiumUp: boolean, finishing: boolean?): Phase
	if podiumUp then
		return "podium"
	elseif resultsUp then
		return "results"
	elseif finishing == true then
		return "finish"
	elseif mode == "hub" then
		return "hub"
	elseif mode == "battle" then
		return "battle"
	elseif type(goAt) == "number" and now < goAt then
		return "countdown"
	end
	return "race"
end

-- Element name (the Instance's Name, or a virtual group client/HudPhase maps to several) -> phase -> visible. An element its
-- owner also drives (RESPAWN shown/hidden by its status, the combo meter by the chain) is shown only when BOTH allow it:
-- the owner reads the PhaseHudOn attribute. Final lap is a state inside `race` (the chip and the position style), not a row.
local T, F = true, false
HudPhaseRules.VISIBLE = {
	--                       hub  countdown race finish results podium battle
	PositionBadge = { hub = F, countdown = T, race = T, finish = F, results = F, podium = F, battle = F },
	LapTimeChip = { hub = F, countdown = T, race = T, finish = F, results = F, podium = F, battle = F }, -- replaces LapPlankSign + TimerPlankSign; dim 0:00.0 on the grid
	-- hub = T (item bugs audit): hub0 has 12 mystery cubes and ItemService grants them in free roam, so a hidden slot was
	-- "nothing appeared in my inventory". HudExtras still hides the empty slot in the hub (shown while holding or rolling).
	ItemSlot = { hub = T, countdown = T, race = T, finish = F, results = F, podium = F, battle = T },
	SkyTokenCounter = { hub = T, countdown = T, race = T, finish = T, results = T, podium = F, battle = T }, -- the "0/14" chip
	SystemCluster = { hub = T, countdown = T, race = T, finish = T, results = F, podium = F, battle = T }, -- the gear and the "?" (HelpButton); v38-flow: off over the results card (it sat on TOTAL at 844x390)
	RespawnButton = { hub = T, countdown = F, race = T, finish = F, results = F, podium = F, battle = T },
	ReturnButton = { hub = F, countdown = F, race = T, finish = F, results = F, podium = F, battle = F }, -- RETURN to course (planes, off course)
	StyleChainMeter = { hub = F, countdown = F, race = T, finish = F, results = F, podium = F, battle = T },
	StartRing = { hub = F, countdown = T, race = F, finish = F, results = F, podium = F, battle = F }, -- the GAS! / TAP! button
	Minimap = { hub = F, countdown = T, race = T, finish = F, results = F, podium = F, battle = F }, -- race minimap (client/Minimap), top-left under the nav
	TouchControls = { hub = T, countdown = T, race = T, finish = F, results = F, podium = F, battle = T }, -- steer pad + TURN / ITEM zone; touch only
	AssistChip = { hub = F, countdown = T, race = T, finish = F, results = F, podium = F, battle = F }, -- the ASSIST one-tap switch (touch pill / desktop chip)
	MessageLane = { hub = F, countdown = T, race = T, finish = T, results = F, podium = F, battle = T }, -- lanes A / B: hero text and captions
} :: { [string]: { [string]: boolean } }

function HudPhaseRules.visible(element: string, phase: Phase): boolean
	local row = HudPhaseRules.VISIBLE[element]
	if not row then
		return true
	end
	return row[phase] == true
end

return HudPhaseRules
