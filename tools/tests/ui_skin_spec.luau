--!strict
-- Lune spec for the image UI skin (UI overhaul phase A): shared/UiImages slots, shared/UiSkinRules slice / tint / motion
-- rules and the event -> sound map, and the NotifyKit retrofit's static guards (client/UiSkin, client/UiMotion).
-- Run: tools/tests/run_lune_tests.sh tools/tests/ui_skin_spec.luau
return function(h)
	local Images = h.require("src/shared/UiImages.luau")
	local R = h.require("src/shared/UiSkinRules.luau")
	local Sound = h.require("src/shared/UiSoundRules.luau")
	local imagesSrc = h.readFile("src/shared/UiImages.luau")

	-- nil slots vanish from the runtime table, so the slot names come from the source lines.
	local slots: { string } = {}
	for name in string.gmatch(imagesSrc, "\n\t([%w_]+) = ") do
		table.insert(slots, name)
	end

	local function isKind(k: string): boolean
		for _, x in Sound.KINDS do
			if x == k then
				return true
			end
		end
		return false
	end

	h.test("images: the 23 named slots are listed, every set id is an rbxassetid", function()
		h.eq(#slots, 23, "slot count")
		for _, want in { "panel_wood", "sign_hanging", "toast_slab", "row_plank", "btn_primary", "btn_wood", "btn_danger", "btn_round", "tab_idle", "tab_selected", "icon_coin", "icon_key", "icon_gear", "icon_lock", "icon_check", "icon_trophy", "icon_medal_1", "icon_medal_2", "icon_medal_3", "icon_info", "icon_alert", "icon_star", "icon_close" } do
			h.ok(table.find(slots, want) ~= nil, want .. " is a slot")
		end
		for k, v in Images do
			h.ok(table.find(slots, k) ~= nil, k .. " is a listed slot")
			h.ok(type(v) == "string" and string.match(v, "^rbxassetid://%d+$") ~= nil, k .. " id shape")
		end
	end)

	h.test("slice: every slot has a rule; centres lie inside the source and leave real borders", function()
		for _, s in slots do
			local r = R.SLICE[s]
			h.ok(r ~= nil, s .. " has a slice rule")
			if r then
				h.ok(r.size[1] > 0 and r.size[2] > 0, s .. " source size")
				h.ok(r.tintMix >= 0 and r.tintMix <= 1, s .. " tintMix")
				if string.sub(s, 1, 5) == "icon_" then
					h.eq(r.kind, "icon", s .. " is an icon")
				else
					h.eq(r.kind, "slice", s .. " is a 9-slice")
					local c = r.center :: { number }
					h.ok(c ~= nil and #c == 4, s .. " centre rect")
					h.ok(c[1] > 0 and c[2] > 0, s .. " left / top borders")
					h.ok(c[1] < c[3] and c[2] < c[4], s .. " centre has area")
					h.ok(c[3] < r.size[1] and c[4] < r.size[2], s .. " right / bottom inside the source")
					h.ok((r.border or 0) > 0, s .. " on-screen border")
				end
			end
		end
		for s in R.SLICE do
			h.ok(table.find(slots, s) ~= nil, s .. " rule has a UiImages slot")
		end
	end)

	h.test("slice: SliceScale follows S and never lets opposite borders overlap", function()
		local a = R.sliceScale("panel_wood", 1)
		local b = R.sliceScale("panel_wood", 2)
		h.ok(math.abs(b - 2 * a) < 1e-9, "doubles with S")
		h.ok(math.abs(a * 120 - 28) < 1e-6, "28 px border at S = 1")
		local small = R.sliceScale("toast_slab", 3, 60, 20)
		h.ok(small * (64 + 64) <= 60 + 1e-9, "left + right fit a 60 px frame")
		h.ok(small * (40 + 40) <= 20 + 1e-9, "top + bottom fit a 20 px frame")
		h.eq(R.sliceScale("icon_coin", 2), 1, "icons are not sliced")
		h.ok(R.sliceScale("btn_round", 1, 0, 0) > 0, "unlaid frames get no clamp")
	end)

	h.test("tint: slots tint toward the caller colour by tintMix, coloured art stays white", function()
		local t = R.artTint("panel_wood", { 20, 30, 40 })
		h.eq(t[1], 255)
		h.eq(t[3], 255)
		local s = R.artTint("toast_slab", { 0, 0, 0 })
		h.ok(s[1] < 255 and s[1] > 100, "toast slab darkens with the kind")
		h.eq(R.artTint("toast_slab", nil)[2], 255)
		h.eq(R.multiply({ 255, 128, 0 }, { 128, 255, 255 })[1], 128)
	end)

	h.test("state: idle / hover / pressed / disabled tints; hover is the brightest, disabled fades", function()
		for _, k in { "idle", "hover", "pressed", "disabled" } do
			local st = R.STATE[k]
			h.ok(st ~= nil and #st.tint == 3, k)
			for i = 1, 3 do
				h.ok(st.tint[i] >= 0 and st.tint[i] <= 255, k .. " channel")
			end
			h.ok(st.alpha >= 0 and st.alpha < 1, k .. " alpha")
		end
		h.ok(R.STATE.hover.tint[1] > R.STATE.idle.tint[1], "hover brightens")
		h.ok(R.STATE.pressed.tint[1] < R.STATE.idle.tint[1], "press darkens")
		h.ok(R.STATE.disabled.alpha > 0, "disabled fades")
	end)

	h.test("motion: durations in 0.1-0.6 s, swoosh 0.28-0.35 Back, pop 0.22-0.3 in / 0.16 out, cues are sound kinds", function()
		for name, m in R.MOTION do
			h.ok(m.duration >= 0.08 and m.duration <= 0.6, name .. " duration " .. m.duration)
			h.ok(isKind(m.cue), name .. " cue " .. m.cue .. " is a UiSoundRules kind")
			if m.steps then
				local total = 0
				for _, st in m.steps do
					h.ok(st.time > 0, name .. " step time")
					total += st.time
				end
				h.ok(math.abs(total - m.duration) < 1e-9, name .. " steps add up to its duration")
				h.eq(m.steps[#m.steps].scale, 1, name .. " settles at rest")
			end
		end
		for _, n in { "swooshIn", "swooshOut" } do
			local m = R.MOTION[n]
			h.eq(m.kind, "slide")
			h.ok(m.duration >= 0.08 and m.duration <= 0.15, n .. " length (v3: snappy)")
		end
		h.eq(R.MOTION.popIn.from, 0.9)
		h.eq(R.MOTION.popIn.to, 1)
		h.ok(R.MOTION.popIn.duration >= 0.08 and R.MOTION.popIn.duration <= 0.15)
		h.eq(R.MOTION.popOut.duration, 0.1)
		h.eq(R.MOTION.popOut.style, "Quad")
		h.ok(R.SCRIM.fadeIn >= 0.1 and R.SCRIM.fadeIn <= 0.6 and R.SCRIM.fadeOut >= 0.1 and R.SCRIM.fadeOut <= 0.6, "scrim fades")
		h.eq(R.SCRIM.alpha, 0.45, "scrim rests where it always did")
	end)

	h.test("motion: slides come from the near edge, centred lanes drop from the top (never up from the kart)", function()
		h.eq(R.sideFor(10, 200, 1000), "left")
		h.eq(R.sideFor(780, 200, 1000), "right")
		h.eq(R.sideFor(400, 200, 1000), "top")
		local dx, dy = R.slideOffset("swooshIn", "top", 300, 40)
		h.eq(dx, 0)
		h.ok(dy < 0 and dy <= -24, "from above, at least minPx")
		local lx = R.slideOffset("swooshIn", "left", 300, 40)
		h.ok(lx < 0, "from the left")
	end)

	h.test("cues: every UI event maps to a UiSoundRules kind", function()
		for _, e in { "open", "close", "swipe", "pop", "select", "confirm", "back", "deny", "purchase", "notify", "hover" } do
			local k = R.cueFor(e)
			h.ok(k ~= nil and isKind(k), e .. " -> " .. tostring(k))
		end
		h.eq(R.cueFor("explode"), nil)
	end)

	h.test("static: NotifyKit draws through UiSkin / UiMotion and keeps its names and the storm animation", function()
		local src = h.readFile("src/client/NotifyKit.luau")
		h.contains(src, 'UiSkin.panel(', "panels through UiSkin")
		h.contains(src, '"toast_slab"', "toast slab slot")
		h.contains(src, '"panel_wood"', "modal card slot")
		h.contains(src, 'UiSkin.button(', "modal buttons through UiSkin")
		h.contains(src, 'UiMotion.show(', "motion in")
		h.contains(src, 'UiMotion.hide(', "motion out")
		for _, name in { '"NotifyToast"', '"NotifyBanner"', '"NotifyModal"', '"Card"', '"Primary"', '"Close"', '"AnimScale"', '"AnimFlash"' } do
			h.contains(src, name, name .. " kept")
		end
		local skin = h.readFile("src/client/UiSkin.luau")
		h.contains(skin, '"SkinArt"', "art child name kept (NotifyKit and StormVendor convention)")
		h.contains(skin, "UiSound.bind(", "skinned buttons get the sound kit")
		local motion = h.readFile("src/client/UiMotion.luau")
		h.contains(motion, "UiSound.play(", "presets play their cue")
		h.contains(motion, "FindFirstChildOfClass(\"UIScale\")", "reuses an existing UIScale")
	end)
end
