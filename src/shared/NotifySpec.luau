--!strict
-- Notification spec table (economy v3 phase 3b): one row per v3 feature moment, as data. Nothing here draws or listens; a feature
-- calls NotifyKit.fromSpec(id, vars) when its trigger fires. tools/tests/notify_spec.luau checks that every v3 feature has a row
-- and that every row is well formed.
--  * surface: "toast" (lane B, queued), "banner" (persistent line under the toast lane), "modal" (centre card), "arch" (label on
--    the portal arch itself).
--  * kind: a NotifySkin kind (colours and icon). priority: low / normal / high / critical (NotifyRules.PRIORITY).
--  * trigger: what fires it (plain words, for the wiring step). seconds: toast length, 0 for banner / modal / arch (they stay
--    until cleared or closed).
--  * title / copy: {name} placeholders listed in vars. Copy is short and plain, Mario Kart style: what happened, then what to do.
--  * sound: nil, or a stand-in cue: "unlock" (UiSound), "portal_wake" (PayoffSound), or the Creator Store "tier_up_sting" / "badge_chime"
--    (shared/ToolboxAudio via PayoffSound; replace-later rows in docs/ASSETS_TOOLBOX_TEMP.md).
--  * primary / close: modal button labels (primary = the main action, close = dismiss; nil close = one button).
-- Hidden at launch (config): rows whose feature sits on the v3 hide-at-launch list are simply never fired while that switch is off.
local NotifySpec = {}

export type Row = {
	id: string,
	feature: string,
	surface: string,
	kind: string,
	priority: string,
	trigger: string,
	title: string?,
	copy: string,
	vars: { string },
	seconds: number,
	sound: string?,
	primary: string?,
	close: string?,
}

NotifySpec.SURFACES = { "toast", "banner", "modal", "arch" } :: { string }
NotifySpec.SOUNDS = { "unlock", "portal_wake", "tier_up_sting", "badge_chime" } :: { string }

NotifySpec.ROWS = {
	-- Portals (arch states, economy v3 section 2). No pop-ups: the arch carries the state.
	{ id = "portal_open", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "arch has no lobby and no race running", copy = "RACE - drive through to start", vars = {}, seconds = 0 },
	{ id = "portal_filling", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "lobby open on this arch; refreshed every second", copy = "STARTING {time} - {n}/{cap}", vars = { "time", "n", "cap" }, seconds = 0 },
	{ id = "portal_racing", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "a race from this arch is running", copy = "RACING - next lobby opens in {time}", vars = { "time" }, seconds = 0 },
	{ id = "portal_wait_line", feature = "portal", surface = "banner", kind = "portal", priority = "high",
		trigger = "this player joined a lobby and waits on the apron", title = "Waiting for racers", copy = "{time} - {n}/{cap}", vars = { "time", "n", "cap" }, seconds = 0 },
	{ id = "portal_busy", feature = "portal", surface = "toast", kind = "portal", priority = "normal",
		trigger = "per-group races: this player picked a track whose race is already running (server RaceBusy)",
		copy = "{zone} is racing - try again soon", vars = { "zone" }, seconds = 2.6 },
	-- Portal queue (phase 3, shared/PortalQueueRules): the RACING label once its estimate has passed, the queue count on a
	-- racing arch, and the joined player's own moments. Only the joined player hears any of these.
	{ id = "portal_racing_soon", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "a race from this arch is running past its estimated end", copy = "RACING - next lobby opens soon", vars = {}, seconds = 0 },
	{ id = "portal_queued", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "a race from this arch is running and players wait for the next one", copy = "RACING - next race in {time} - {n}/{cap}",
		vars = { "time", "n", "cap" }, seconds = 0 },
	{ id = "portal_queued_soon", feature = "portal", surface = "arch", kind = "portal", priority = "normal",
		trigger = "players wait for the next race; the running one is past its estimate", copy = "RACING - next race soon - {n}/{cap}",
		vars = { "n", "cap" }, seconds = 0 },
	{ id = "portal_wait_soon", feature = "portal", surface = "banner", kind = "portal", priority = "high",
		trigger = "this player waits for the next race; the running one is past its estimate", title = "Waiting for racers",
		copy = "next race soon - {n}/{cap}", vars = { "n", "cap" }, seconds = 0 },
	{ id = "portal_joined", feature = "portal", surface = "toast", kind = "portal", priority = "high",
		trigger = "this player drove through an arch or pressed JOIN: he is in its lobby", copy = "You're in - {zone} starts in {time}",
		vars = { "zone", "time" }, seconds = 2.6 },
	{ id = "portal_queued_in", feature = "portal", surface = "toast", kind = "portal", priority = "high",
		trigger = "this player joined while the arch races: he is in the next lobby", copy = "You're in the next {zone} race",
		vars = { "zone" }, seconds = 2.6 },
	{ id = "portal_left", feature = "portal", surface = "toast", kind = "portal", priority = "normal",
		trigger = "this player pressed LEAVE or backed out of the arch", copy = "You left the {zone} race", vars = { "zone" }, seconds = 2.2 },
	{ id = "portal_full", feature = "portal", surface = "toast", kind = "portal", priority = "normal",
		trigger = "the lobby on this arch holds a full field of players", copy = "{zone} is full - next race soon", vars = { "zone" }, seconds = 2.4 },
	{ id = "portal_other_mode", feature = "portal", surface = "toast", kind = "portal", priority = "normal",
		trigger = "a board pick of another mode while this track's lobby gathers", copy = "{zone} has a {mode} race forming",
		vars = { "zone", "mode" }, seconds = 2.4 },
	{ id = "portal_cancelled", feature = "portal", surface = "toast", kind = "portal", priority = "normal",
		trigger = "the lobby this player is in was dropped (Storm Cup hold, refused start)", copy = "{zone} race cancelled",
		vars = { "zone" }, seconds = 2.6 },

	-- Storm race (section 3).
	{ id = "storm_announce", feature = "storm", surface = "modal", kind = "storm", priority = "high",
		trigger = "storm race JOIN window opens (~60 s before :00 / :30 UTC), hub only; body counts down live (anim storm)", title = "Storm Race",
		copy = "{track} in {time}. Fields of 8. Beat the storm dragon.",
		vars = { "track", "time" }, seconds = 0, sound = "portal_wake", primary = "Join", close = "Not now" },
	{ id = "storm_announce_late", feature = "storm", surface = "modal", kind = "storm", priority = "high",
		trigger = "the same popup after the start, while late seats are open (storm race v2)", title = "Storm Race",
		copy = "{track} has started. Late seats for {time}.", vars = { "track", "time" }, seconds = 0, primary = "Join", close = "Not now" },
	{ id = "storm_left", feature = "storm", surface = "toast", kind = "storm", priority = "normal",
		trigger = "this player pressed LEAVE on the storm race before its start", copy = "You left the storm race", vars = {}, seconds = 2.2 },
	{ id = "storm_closed", feature = "storm", surface = "toast", kind = "storm", priority = "normal",
		trigger = "JOIN pressed after the storm race window closed", copy = "Storm race closed. Next in {time}", vars = { "time" }, seconds = 2.6 },
	{ id = "storm_racing", feature = "storm", surface = "toast", kind = "storm", priority = "normal",
		trigger = "JOIN (or the start) while this player races elsewhere", copy = "Finish your race first", vars = {}, seconds = 2.4 },
	{ id = "storm_full", feature = "storm", surface = "toast", kind = "storm", priority = "normal",
		trigger = "no free track for this player's storm field", copy = "Storm race is full. Next in {time}", vars = { "time" }, seconds = 2.6 },
	{ id = "storm_cancelled", feature = "storm", surface = "toast", kind = "storm", priority = "normal",
		trigger = "the storm race was switched off before its start", copy = "Storm race cancelled", vars = {}, seconds = 2.4 },
	{ id = "storm_go", feature = "storm", surface = "toast", kind = "storm", priority = "high",
		trigger = "this player's storm field launches (he leaves the hub)", copy = "Storm race! Beat the dragon", vars = {}, seconds = 2.6, sound = "portal_wake" },
	{ id = "storm_countdown", feature = "storm", surface = "banner", kind = "storm", priority = "normal",
		trigger = "hub, until the next storm race", copy = "Next storm race in {time}", vars = { "time" }, seconds = 0 },
	{ id = "storm_inprogress", feature = "storm", surface = "banner", kind = "storm", priority = "high",
		trigger = "a storm race is running; hub sky is on", copy = "Storm race in progress", vars = {}, seconds = 0 },
	{ id = "storm_slotted", feature = "storm", surface = "toast", kind = "storm", priority = "high",
		trigger = "server slots this player into a field", copy = "You're in! Field {field}. Starts in {time}", vars = { "field", "time" }, seconds = 3.2, sound = "portal_wake" },

	-- Collecting (section 5).
	{ id = "key_found", feature = "keys", surface = "toast", kind = "unlock", priority = "high",
		trigger = "hidden key picked up", copy = "KEY {n}/{total}: {zone}. Toward the Amulet", vars = { "n", "total", "zone" }, seconds = 3.6, sound = "unlock" },
	{ id = "key_first_explain", feature = "keys", surface = "modal", kind = "unlock", priority = "normal",
		trigger = "first key ever found by this player", title = "Hidden key", copy = "Keys open battles early. Win a battle for a fragment; four make the Battle Amulet. Keys {n}/{total}.",
		vars = { "n", "total" }, seconds = 0, primary = "Got it" },
	{ id = "battle_first_explain", feature = "keys", surface = "modal", kind = "unlock", priority = "normal",
		trigger = "first calm hub moment once any battle is open (finish a map or find its key); once per account", title = "Battle open",
		copy = "4 modes: Survival, Egg, Water, Hoard.\nOne per zone. Beat rivals to win.\nWins earn Battle Amulet fragments.",
		vars = {}, seconds = 0, primary = "Got it" },
	-- First-time explainers beyond racing (T1-15, shared/ExplainerRules): each once per account, queued for a calm hub moment by
	-- client/LadderNotices, brief, three short lines. "Skip tips" turns every explainer off for the account.
	{ id = "item_first_explain", feature = "items", surface = "modal", kind = "info", priority = "normal",
		trigger = "first item ever picked up; shown at the next calm hub moment, once per account", title = "Items",
		copy = "Drive through cubes to get an item.\nFire it with the ITEM button.\nShields block incoming hits.",
		vars = {}, seconds = 0, primary = "Got it", close = "Skip tips" },
	{ id = "token_first_explain", feature = "maps", surface = "modal", kind = "unlock", priority = "normal",
		trigger = "first Sky Token ever earned; shown at the next calm hub moment, once per account", title = "Sky Tokens",
		copy = "Win races to earn Sky Tokens.\nEnough tokens open a new world.\nGlowing gates in the hub show it.",
		vars = {}, seconds = 0, primary = "Got it", close = "Skip tips" },
	{ id = "garage_first_explain", feature = "vehicles", surface = "modal", kind = "info", priority = "normal",
		trigger = "first calm hub moment after the first race started, Garage on; once per account", title = "Garage",
		copy = "Pick your ride and paint it.\nTap GARAGE in the hub.\nCash and rewards are in there.",
		vars = {}, seconds = 0, primary = "Got it", close = "Skip tips" },
	{ id = "fragment_found", feature = "keys", surface = "toast", kind = "unlock", priority = "high",
		trigger = "battle won, fragment awarded", copy = "Battle fragment {n}/{total}", vars = { "n", "total" }, seconds = 3.6, sound = "unlock" },
	{ id = "amulet_found", feature = "keys", surface = "modal", kind = "unlock", priority = "critical",
		trigger = "last fragment collected", title = "Battle Amulet", copy = "All fragments collected. The Battle Amulet is yours.",
		vars = {}, seconds = 0, sound = "unlock", primary = "Open Garage", close = "Close" },

	-- Vehicles (section 4).
	{ id = "avatar_unlock", feature = "vehicles", surface = "toast", kind = "unlock", priority = "high",
		trigger = "a new avatar is owned", copy = "{name} unlocked", vars = { "name" }, seconds = 3.6, sound = "unlock" },
	{ id = "reskin_unlock", feature = "vehicles", surface = "toast", kind = "unlock", priority = "high",
		trigger = "a reskin ladder step is earned", copy = "{name}: new reskin", vars = { "name" }, seconds = 3.2, sound = "unlock" },
	{ id = "tint_unlock", feature = "vehicles", surface = "toast", kind = "unlock", priority = "high",
		trigger = "a tint ladder step is earned", copy = "{name}: new tint", vars = { "name" }, seconds = 3.2, sound = "unlock" },

	-- Storm Shards and badges (section 3).
	{ id = "shard_gain", feature = "shards", surface = "toast", kind = "storm", priority = "low",
		trigger = "storm race results", copy = "+{n} Storm Shards", vars = { "n" }, seconds = 2.4 },
	{ id = "shard_tier_up", feature = "shards", surface = "toast", kind = "storm", priority = "high",
		trigger = "shard total crosses a tier", copy = "Storm rank: {tier}. New vendor page.", vars = { "tier" }, seconds = 4, sound = "tier_up_sting" },
	{ id = "dragon_beaten", feature = "shards", surface = "toast", kind = "storm", priority = "high",
		trigger = "storm race results: this racer beat the storm dragon", copy = "Storm dragon beaten. +{n} Shards", vars = { "n" }, seconds = 3.6, sound = "unlock" },
	{ id = "vendor_bought", feature = "shards", surface = "toast", kind = "reward", priority = "normal",
		trigger = "Storm vendor purchase saved", copy = "{name} is yours", vars = { "name" }, seconds = 3, sound = "unlock" },
	{ id = "vendor_locked", feature = "shards", surface = "toast", kind = "warn", priority = "normal",
		trigger = "Storm vendor: item above this racer's storm rank", copy = "Reach {tier} to unlock this", vars = { "tier" }, seconds = 2.4 },
	{ id = "vendor_short", feature = "shards", surface = "toast", kind = "warn", priority = "normal",
		trigger = "Storm vendor: not enough Storm Shards", copy = "Need {n} more Storm Shards", vars = { "n" }, seconds = 2.4 },
	{ id = "storm_hub_live", feature = "storm", surface = "arch", kind = "storm", priority = "normal",
		trigger = "hub, over the Storm vendor stand, while a storm race runs", copy = "STORM RACE IN PROGRESS", vars = {}, seconds = 0 },
	{ id = "storm_hub_next", feature = "storm", surface = "arch", kind = "storm", priority = "normal",
		trigger = "hub, over the Storm vendor stand, between storm races", copy = "NEXT STORM RACE {time}", vars = { "time" }, seconds = 0 },
	{ id = "badge_earned", feature = "badges", surface = "toast", kind = "reward", priority = "high",
		trigger = "a badge is awarded", copy = "Badge: {name}", vars = { "name" }, seconds = 3.6, sound = "badge_chime" },

	-- Maps and tokens (section 5b).
	{ id = "map_unlock", feature = "maps", surface = "toast", kind = "unlock", priority = "high",
		trigger = "token threshold reached for a portal", copy = "{zone} is open", vars = { "zone" }, seconds = 3.6, sound = "portal_wake" },
	{ id = "token_gain", feature = "maps", surface = "toast", kind = "info", priority = "low",
		trigger = "a Sky Token is earned and every token gate is already open", copy = "+1 Sky Token", vars = {}, seconds = 2 },
	{ id = "token_progress", feature = "maps", surface = "toast", kind = "info", priority = "low",
		trigger = "a Sky Token is earned", copy = "Sky Tokens {n}/{need} for {zone}", vars = { "n", "need", "zone" }, seconds = 2.4 },

	-- Login and Cash (sections 6, 7).
	{ id = "login_reward", feature = "login", surface = "modal", kind = "reward", priority = "normal",
		trigger = "first hub moment of the UTC day, nothing else on screen (once per day, saved)", title = "Daily reward",
		copy = "Day {day}: {reward}.\n{theme}: {pitch}\nNext storm race in {time}.",
		vars = { "day", "reward", "theme", "pitch", "time" }, seconds = 0, sound = "unlock", primary = "Claim", close = "Later" },
	{ id = "login_info", feature = "login", surface = "modal", kind = "reward", priority = "normal",
		trigger = "same popup when today's reward is already claimed (Garage claim, or a claim before this join)", title = "Welcome back",
		copy = "Daily reward claimed.\n{theme}: {pitch}\nNext storm race in {time}.",
		vars = { "theme", "pitch", "time" }, seconds = 0, primary = "Got it" },
	{ id = "cash_gain", feature = "cash", surface = "toast", kind = "reward", priority = "low",
		trigger = "Cash awarded outside the results card", copy = "+{n} Cash", vars = { "n" }, seconds = 2 },

	-- Missile v3 (owner 2026-10-20): the first missile lock on this player in a session teaches the answer once. The
	-- beeps and the badge (client/ItemJuice) carry every lock after that.
	{ id = "missile_lock_roll", feature = "items", surface = "toast", kind = "warn", priority = "high",
		trigger = "first missile lock on this player this session, in a plane", copy = "Missile lock! Double-tap left/right to dodge", vars = {}, seconds = 2.6 },
	{ id = "missile_lock_block", feature = "items", surface = "toast", kind = "warn", priority = "high",
		trigger = "first missile lock on this player this session, in a car", copy = "Missile locked on! Hold a trap or shield up", vars = {}, seconds = 2.6 },
	-- Items v4 (docs/design/ITEMS_V4.md): the race's rotation, said once in the countdown (client TrackFlow), and the
	-- Storm Bolt siren on its target (client ItemsV4Fx), with the answer for the vehicle.
	{ id = "item_pool", feature = "items", surface = "toast", kind = "info", priority = "normal",
		trigger = "race countdown starts with specials in the item rotation", copy = "This race: {items}", vars = { "items" }, seconds = 4 },
	{ id = "storm_warn_roll", feature = "items", surface = "toast", kind = "warn", priority = "high",
		trigger = "a Storm Bolt is about to strike this player, in a plane", copy = "Storm Bolt! Double-tap left/right or shield", vars = {}, seconds = 2 },
	{ id = "storm_warn_block", feature = "items", surface = "toast", kind = "warn", priority = "high",
		trigger = "a Storm Bolt is about to strike this player, in a car", copy = "Storm Bolt on you! Shield up", vars = {}, seconds = 2 },
} :: { Row }

local byId: { [string]: Row }? = nil

function NotifySpec.get(id: string): Row?
	if not byId then
		local t: { [string]: Row } = {}
		for _, r in NotifySpec.ROWS do
			t[r.id] = r
		end
		byId = t
	end
	return (byId :: { [string]: Row })[id]
end

-- Fill {name} placeholders; a missing var stays visible as the bare name so a wiring slip shows up in a capture.
function NotifySpec.format(text: string, vars: { [string]: any }?): string
	return (string.gsub(text, "{(%w+)}", function(k)
		local v = if vars then vars[k] else nil
		return if v ~= nil then tostring(v) else k
	end))
end

return NotifySpec
