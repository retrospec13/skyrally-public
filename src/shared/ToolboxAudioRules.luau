--!strict
-- Mix table and pure rules for the Creator Store sounds (shared/ToolboxAudio, docs/ASSETS_TOOLBOX_TEMP.md), pinned by
-- tools/tests/toolbox_audio_spec.luau. vol = the cue's level before the EFFECTS slider (all sit under the music bed and the
-- engine layer's peak), pitch = PlaybackSpeed, where = the moment that plays it.
--   * missile lock-on beep: ItemJuice (the pitch and interval come from ItemRules.beepPitch / beepInterval, so it accelerates).
--   * storm thunder: a far roll after a hub bolt (HubStorm) and now and then over a Storm Cup race (Soundscape); three variants.
--   * Storm Shard tier-up sting and badge chime: NotifySpec rows shard_tier_up / badge_earned via client/NotifyKit.
--   * hologram hum (one loop on the nearest figure) and glitch (a board tears): SPACE-4 client/SpaceNeon.
--   * eruption rumble, geyser whoosh, sail gate chime: DINO / FOREST set pieces call ToolboxCues.playAt with these names.
--   * SNOW crossing horn: the owned foghorn (WorldMomentsAudio ans_foghorn, lowered); no Roblox horn exists, so it has no row here.
local ToolboxAudioRules = {}

export type Cue = { vol: number, pitch: number, loop: boolean?, spatial: boolean?, where: string }

ToolboxAudioRules.CUES = {
	missile_lock_beep = { vol = 0.5, pitch = 1, where = "client/ItemJuice incoming-missile warning" },
	storm_thunder_1 = { vol = 0.34, pitch = 0.9, where = "HubStorm bolt, Soundscape storm layer" },
	storm_thunder_2 = { vol = 0.3, pitch = 0.8, where = "HubStorm bolt, Soundscape storm layer" },
	storm_thunder_3 = { vol = 0.36, pitch = 0.45, where = "HubStorm bolt, Soundscape storm layer (a low far roll)" },
	tier_up_sting = { vol = 0.5, pitch = 1, where = "NotifySpec shard_tier_up" },
	badge_chime = { vol = 0.5, pitch = 1, where = "NotifySpec badge_earned" },
	holo_hum = { vol = 0.12, pitch = 0.8, loop = true, spatial = true, where = "SPACE-4 nearest hologram figure" },
	holo_glitch = { vol = 0.3, pitch = 1, spatial = true, where = "SPACE-4 billboard tear" },
	eruption_rumble = { vol = 0.5, pitch = 0.4, spatial = true, where = "DINO eruption set pieces" },
	geyser_whoosh = { vol = 0.4, pitch = 0.85, spatial = true, where = "DINO / SNOW geyser jets" },
	sail_gate_chime = { vol = 0.4, pitch = 1, spatial = true, where = "FOREST sail gate" },
} :: { [string]: Cue }

ToolboxAudioRules.THUNDER = { "storm_thunder_1", "storm_thunder_2", "storm_thunder_3" }
ToolboxAudioRules.THUNDER_GAP = { 14, 30 } -- seconds between claps over a Storm Cup race
ToolboxAudioRules.THUNDER_DELAY = { 0.35, 1.4 } -- seconds from a hub bolt to its clap
ToolboxAudioRules.MAX_CUE_VOL = 0.6 -- no Creator Store cue is mixed louder (the music bed sits at 1.0 of its own slider)
ToolboxAudioRules.HOLO_RANGE = 260 -- studs: the hum's audible distance (RollOffMaxDistance)

local function lerp(range: { number }, r: number): number
	return range[1] + (range[2] - range[1]) * math.clamp(r, 0, 1)
end

-- A clap for a random draw r in 0..1: which variant, a little pitch spread (so a repeat is not the same clap) and the level.
function ToolboxAudioRules.thunder(r: number, r2: number): (string, number, number)
	local list = ToolboxAudioRules.THUNDER
	local i = math.clamp(math.floor(math.clamp(r, 0, 0.999999) * #list) + 1, 1, #list)
	local cue = list[i]
	local c = ToolboxAudioRules.CUES[cue]
	return cue, c.pitch * (0.92 + 0.16 * math.clamp(r2, 0, 1)), c.vol
end

function ToolboxAudioRules.thunderGap(r: number): number
	return lerp(ToolboxAudioRules.THUNDER_GAP, r)
end

function ToolboxAudioRules.thunderDelay(r: number): number
	return lerp(ToolboxAudioRules.THUNDER_DELAY, r)
end

return ToolboxAudioRules
