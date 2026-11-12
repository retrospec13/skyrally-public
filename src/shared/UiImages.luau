--!strict
-- UI image slots (UI overhaul phase A): slot name -> rbxassetid string, or nil. Hand-written for now; the UI art set
-- (9-slice panels and buttons, icons per docs/ART_BAR.md "UI and sound": hanging wooden signs with ropes, carved stone
-- buttons, concept assets/concepts/skyrally_mockups_v1/04_dino4_controls.png) will be uploaded and written here by a
-- tools/vfx/upload_set.py-style run, the same pattern as shared/UiAudioAssets.luau. Each slot's source size and 9-slice
-- centre live in shared/UiSkinRules (the art must be drawn to them); tools/tests/ui_skin_spec.luau pins both.
-- nil means "draw the flat fallback": client/UiSkin then builds today's Frame + UICorner + UIStroke look, so an empty
-- table is zero visual change and each slot lights up on its own as its id lands.
-- Keep one `name = value,` line per slot (the spec reads the slot names from this file, since nil keys vanish at runtime).
-- Icon slots point at the UI v2 icon set (shared/UiV2Icons, generated); other UiV2Icons keys are reached through
-- UiSkin.artFor directly.
local Icons = require(script.Parent:WaitForChild("UiV2Icons")) :: { [string]: string }
return {
	-- 9-slice frames
	panel_wood = nil, -- large card frame: Adventure board, Garage, Settings, NotifyKit modal, results
	sign_hanging = nil, -- HUD chip hung on two ropes: position, lap/time, token counter
	toast_slab = nil, -- toast / banner / portal arch pill
	row_plank = nil, -- list rows (board zones, Garage rows, standings)
	btn_primary = nil, -- green go / confirm button
	btn_wood = nil, -- neutral wood button
	btn_danger = nil, -- red leave / sell / reset button
	btn_round = nil, -- round icon button (gear, close)
	tab_idle = nil,
	tab_selected = nil,
	-- icons (Fit, no slice)
	icon_coin = Icons.icon_coin,
	icon_key = Icons.icon_key,
	icon_gear = Icons.icon_gear,
	icon_lock = Icons.icon_lock,
	icon_check = Icons.icon_check,
	icon_trophy = Icons.icon_trophy,
	icon_medal_1 = Icons.icon_medal_1,
	icon_medal_2 = Icons.icon_medal_2,
	icon_medal_3 = Icons.icon_medal_3,
	icon_info = Icons.icon_info,
	icon_alert = Icons.icon_alert,
	icon_star = Icons.icon_star,
	icon_close = Icons.icon_close,
} :: { [string]: string? }
