--!strict
-- Lune spec for shared/ToolboxAudio + shared/ToolboxAudioRules (audio-v2): every Creator Store sound is a Roblox-uploaded id with
-- a complete replace-later row in docs/ASSETS_TOOLBOX_TEMP.md, mixed under the music, and the thunder rules behave.
-- Run: tools/tests/run_lune_tests.sh tools/tests/toolbox_audio_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local Ids = h.require("src/shared/ToolboxAudio.luau")
	local R = h.require("src/shared/ToolboxAudioRules.luau")
	local Notify = h.require("src/shared/NotifySpec.luau")
	local ledger = h.readFile("docs/ASSETS_TOOLBOX_TEMP.md")

	h.test("toolbox audio: every cue has an id and a mix row, and no row is orphaned", function()
		for cue, id in Ids do
			h.ok(string.match(id, "^rbxassetid://%d+$") ~= nil, cue .. " is an asset id")
			h.ok(R.CUES[cue] ~= nil, cue .. " has a mix row")
		end
		for cue in R.CUES do
			h.ok(Ids[cue] ~= nil, cue .. " has an id")
		end
	end)

	h.test("toolbox audio: each distinct id has a complete ledger row (id, title, creator, type, used, why, replace, date)", function()
		local seen = {}
		for _, id in Ids do
			local num = string.match(id, "(%d+)$")
			if not seen[num] then
				seen[num] = true
				local row = string.match(ledger, "\n(| " .. num .. " |[^\n]*)")
				h.ok(row ~= nil, num .. " is listed")
				if row then
					local cols = 0
					for cell in string.gmatch(row, "|([^|]*)") do
						if string.match(cell, "%S") then
							cols += 1
						end
					end
					h.ok(cols >= 8, num .. " row has all eight columns")
					h.ok(string.match(row, "Roblox %(1%)") ~= nil, num .. " creator is Roblox (1)")
					h.ok(string.match(row, "%d%d%d%d%-%d%d%-%d%d |$") ~= nil, num .. " row ends with a date")
				end
			end
		end
	end)

	h.test("toolbox audio: levels sit under the cap and loops/positional flags are sane", function()
		for cue, c in R.CUES do
			h.ok(c.vol > 0 and c.vol <= R.MAX_CUE_VOL, cue .. " level " .. c.vol)
			h.ok(c.pitch > 0.3 and c.pitch < 2, cue .. " pitch")
			h.ok(#c.where > 0, cue .. " says where it plays")
		end
		h.ok(R.CUES.holo_hum.loop == true and R.CUES.holo_hum.vol <= 0.15, "the hum is a quiet loop")
	end)

	h.test("toolbox audio: thunder picks all three variants with a spread pitch and bounded timing", function()
		local seen = {}
		for i = 0, 29 do
			local cue, pitch, vol = R.thunder(i / 30, (i % 7) / 6)
			seen[cue] = true
			local base = R.CUES[cue]
			h.ok(pitch >= base.pitch * 0.92 - 1e-9 and pitch <= base.pitch * 1.08 + 1e-9, "pitch spread")
			h.eq(vol, base.vol)
		end
		for _, cue in R.THUNDER do
			h.ok(seen[cue], cue .. " is reachable")
		end
		h.eq(select(1, R.thunder(1, 1)), R.THUNDER[#R.THUNDER], "r = 1 is the last variant, not past it")
		h.eq(R.thunderGap(0), 14)
		h.eq(R.thunderGap(1), 30)
		h.ok(R.thunderDelay(0.5) > 0.35 and R.thunderDelay(0.5) < 1.4)
	end)

	h.test("toolbox audio: every UI toolbox kind names a ToolboxAudio cue whose mix row mirrors the UiSound volume", function()
		local Ui = h.require("src/shared/UiSoundRules.luau")
		local n = 0
		for kind in Ui.TOOLBOX_KINDS do
			n += 1
			local cue = Ui.CUE[kind]
			h.ok(cue ~= nil and Ids[cue] ~= nil, kind .. " cue " .. tostring(cue) .. " has a ToolboxAudio id")
			if cue and R.CUES[cue] and cue ~= "badge_chime" then
				h.eq(R.CUES[cue].vol, Ui.VOLUME[kind], kind .. " mix row mirrors UiSoundRules.VOLUME")
			end
		end
		h.ok(n >= 12, "the UI overhaul kinds are wired: " .. n)
		h.eq(Ui.CUE.notify_high, "badge_chime", "the reward notice reuses the badge chime file")
		for _, cue in { "rbx_ui_whoosh_1", "rbx_ui_whoosh_2", "rbx_ui_swipe", "rbx_ui_cute_pop", "rbx_ui_select", "rbx_ui_bright_click", "rbx_ui_notify_low", "rbx_ui_back", "rbx_ui_negative", "rbx_ui_purchase", "rbx_ui_hover" } do
			h.ok(Ids[cue] ~= nil, cue .. " is in ToolboxAudio")
		end
	end)

	h.test("toolbox audio: NotifySpec sounds resolve to a cue or an existing stand-in", function()
		for _, row in Notify.ROWS do
			if row.sound == "tier_up_sting" or row.sound == "badge_chime" then
				h.ok(Ids[row.sound] ~= nil, row.id .. " sound has an id")
			end
		end
		h.eq(Notify.get("shard_tier_up").sound, "tier_up_sting")
		h.eq(Notify.get("badge_earned").sound, "badge_chime")
	end)
end
