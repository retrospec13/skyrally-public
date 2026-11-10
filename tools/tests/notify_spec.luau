-- shared/NotifyRules (toast queue, banners, modals, layout), NotifySkin and NotifySpec (economy v3 phase 3b).
return function(h)
	local R = h.require("src/shared/NotifyRules.luau")
	local Skin = h.require("src/shared/NotifySkin.luau")
	local Spec = h.require("src/shared/NotifySpec.luau")
	local HudLayoutRules = h.require("src/shared/HudLayoutRules.luau")

	local function toast(key, p, secs)
		return { key = key, text = key, priority = p or "normal", seconds = secs or 2 }
	end

	h.test("toast: first shows at once, next waits and takes over when it ends", function()
		local q = R.newToasts()
		h.eq(R.push(q, toast("a"), 0), "shown")
		h.eq(R.push(q, toast("b"), 0.1), "queued")
		local act = R.tick(q, 1)
		h.eq(act.key, "a")
		local act2, changed = R.tick(q, 2.1)
		h.eq(act2.key, "b")
		h.ok(changed, "changed on handover")
		local _, again = R.tick(q, 2.2)
		h.ok(not again, "no change while b shows")
		h.eq(R.tick(q, 5), nil)
	end)

	h.test("toast: queue orders by priority, then first come first served", function()
		local q = R.newToasts()
		R.push(q, toast("first", "normal"), 0)
		R.push(q, toast("low1", "low"), 0.1)
		R.push(q, toast("norm1", "normal"), 0.2)
		R.push(q, toast("norm2", "normal"), 0.3)
		-- a high toast preempts normal, so it shows; the rest keep order
		h.eq(R.push(q, toast("high1", "high"), 0.4), "shown")
		h.eq(q.active.key, "high1")
		local order = {}
		for _, n in q.queue do
			table.insert(order, n.key)
		end
		-- preempted "first" (normal) went back in by its original sequence
		h.eq(table.concat(order, ","), "first,norm1,norm2,low1")
	end)

	h.test("toast: equal priority never preempts; higher does; a preempted low toast is lost", function()
		local q = R.newToasts()
		R.push(q, toast("lowA", "low"), 0)
		h.eq(R.push(q, toast("lowB", "low"), 0.1), "queued")
		h.eq(R.push(q, toast("normA", "normal"), 0.2), "shown")
		h.eq(q.active.key, "normA")
		for _, n in q.queue do
			h.ok(n.key ~= "lowA", "preempted low caption is dropped, not requeued")
		end
	end)

	h.test("toast: same key while showing extends, capped; while waiting merges", function()
		local q = R.newToasts()
		R.push(q, toast("cash", "low", 2), 0)
		h.eq(R.push(q, toast("cash", "low", 2), 1.5), "refreshed")
		h.ok(math.abs(q.active.endsAt - 3.5) < 1e-9, "extended to now + seconds")
		for i = 1, 30 do
			R.push(q, toast("cash", "low", 8), 1.5 + i)
		end
		h.ok(q.active.endsAt <= q.active.startedAt + R.EXTEND_CAP_S + 1e-9, "never beyond the cap")
		R.push(q, toast("other", "low"), 2)
		h.eq(R.push(q, toast("other", "high"), 2.1), "shown", "merge upgrades, high preempts")
	end)

	h.test("toast: merge while waiting keeps one entry and takes the higher priority", function()
		local q = R.newToasts()
		R.push(q, toast("x", "high"), 0)
		R.push(q, toast("w", "low"), 0.1)
		h.eq(R.push(q, toast("w", "normal"), 0.2), "merged")
		h.eq(#q.queue, 1)
		h.eq(q.queue[1].priority, R.PRIORITY.normal)
	end)

	h.test("toast: a key that just ended is dropped for DEDUPE_S, then allowed", function()
		local q = R.newToasts()
		R.push(q, toast("k", "normal", 1.2), 0)
		R.tick(q, 1.3)
		h.eq(R.push(q, toast("k", "normal", 1.2), 1.4), "dropped")
		h.eq(R.push(q, toast("k", "normal", 1.2), 1.3 + R.DEDUPE_S + 0.1), "shown")
	end)

	h.test("toast: key defaults to the text; seconds are clamped", function()
		local q = R.newToasts()
		R.push(q, { text = "hello", seconds = 99 }, 0)
		h.eq(q.active.key, "hello")
		h.eq(q.active.seconds, R.MAX_SECONDS)
		local q2 = R.newToasts()
		R.push(q2, { text = "t", seconds = 0.1 }, 0)
		h.eq(q2.active.seconds, R.MIN_SECONDS)
	end)

	h.test("toast: queue is bounded; the worst entry goes, a newcomer that is worst is dropped", function()
		local q = R.newToasts()
		R.push(q, toast("on", "high"), 0)
		for i = 1, R.MAX_QUEUE do
			R.push(q, toast("n" .. i, "normal"), 0.1 * i)
		end
		h.eq(#q.queue, R.MAX_QUEUE)
		h.eq(R.push(q, toast("late-low", "low"), 5), "dropped")
		h.eq(R.push(q, toast("urgent", "high"), 5.1), "queued")
		h.eq(#q.queue, R.MAX_QUEUE)
		h.eq(q.queue[1].key, "urgent")
		h.eq(q.queue[#q.queue].key, "n" .. (R.MAX_QUEUE - 1), "newest normal fell off")
	end)

	h.test("toast: a stale low caption is skipped", function()
		local q = R.newToasts()
		R.push(q, toast("long", "high", 8), 0)
		R.push(q, toast("lowX", "low"), 0)
		R.push(q, toast("normX", "normal"), 0)
		-- long ends at 8; lowX would be next but normX outranks it
		h.eq(R.tick(q, 8.1).key, "normX")
		local act = R.tick(q, 12)
		h.eq(act, nil, "lowX waited past MAX_WAIT_S and is dropped")
	end)

	h.test("toast: clearToasts empties queue and active", function()
		local q = R.newToasts()
		R.push(q, toast("a"), 0)
		R.push(q, toast("b"), 0)
		R.clearToasts(q)
		h.eq(R.tick(q, 0.1), nil)
	end)

	h.test("banner: highest priority wins, newest on a tie, clear falls back", function()
		local b = R.newBanners()
		R.setBanner(b, "timer", "Next storm race in 4:00", "normal", "storm")
		R.setBanner(b, "lobby", "Waiting", "high", "portal")
		h.eq(R.topBanner(b).key, "lobby")
		R.setBanner(b, "other", "x", "high")
		h.eq(R.topBanner(b).key, "other")
		R.setBanner(b, "lobby", "Waiting 0:14", "high")
		h.eq(R.topBanner(b).key, "other", "an update keeps its place in arrival order")
		h.eq(b.items.lobby.text, "Waiting 0:14")
		h.ok(R.clearBanner(b, "other"))
		h.ok(not R.clearBanner(b, "other"))
		h.eq(R.topBanner(b).key, "lobby")
		R.clearBanner(b, "lobby")
		R.clearBanner(b, "timer")
		h.eq(R.topBanner(b), nil)
	end)

	h.test("modal: one at a time, others wait by priority, same key is dropped, never preempts", function()
		local m = R.newModals()
		h.eq(R.pushModal(m, "login", {}, "normal"), "shown")
		h.eq(R.pushModal(m, "login", {}, "normal"), "dropped")
		h.eq(R.pushModal(m, "storm", {}, "high"), "queued")
		h.eq(R.pushModal(m, "amulet", {}, "critical"), "queued")
		h.eq(R.pushModal(m, "storm", {}, "high"), "dropped")
		h.eq(m.current.key, "login")
		h.eq(R.closeModal(m).key, "amulet")
		h.eq(R.closeModal(m).key, "storm")
		h.eq(R.closeModal(m), nil)
		h.eq(m.current, nil)
	end)

	local function metricsFor(vx, vy, kind)
		return HudLayoutRules.metrics(vx, vy, { left = 0, top = 0, right = 0, bottom = 0 }, kind)
	end

	h.test("layout: a fit modal shrinks to its body (no empty gap), keeps 44 px buttons and stays inside the safe rect", function()
		for _, vp in { { 740, 360, "touch" }, { 844, 390, "touch" }, { 1280, 720, "desktop" }, { 1920, 1080, "desktop" } } do
			local m = metricsFor(vp[1], vp[2], vp[3])
			local full = R.modalLayout(vp[1], vp[2], m, true)
			local need = 3 * R.bodySizeFor(m.S) -- a three-line body
			local L = R.modalLayout(vp[1], vp[2], m, true, need)
			local c = L.card
			h.ok(c.h <= full.card.h and c.h >= R.FIT_MIN_H or c.h == full.card.h, "never taller than the default card")
			h.ok(L.bodyH >= need and L.bodyH - need <= L.pad * 2 + 4, "body room = text + padding only at " .. vp[1] .. ": " .. L.bodyH .. " vs " .. need)
			h.ok(L.buttonH >= HudLayoutRules.MIN_BUTTON and L.buttons.primary.w >= HudLayoutRules.MIN_BUTTON, "button floor")
			h.ok(c.y >= m.yTop - 1 and c.y + c.h <= m.yBot + 1, "inside safe height")
			h.ok(L.buttons.primary.y + L.buttons.primary.h <= c.y + c.h, "buttons inside card")
		end
		local m = metricsFor(740, 360, "touch")
		local huge = R.modalLayout(740, 360, m, true, 5000)
		h.eq(huge.card.h, R.modalLayout(740, 360, m, true).card.h) -- long text never exceeds the default card
	end)

	h.test("layout: modal fits the safe rect with 44 px buttons from phone to 4K", function()
		for _, vp in { { 740, 360, "touch" }, { 844, 390, "touch" }, { 1280, 720, "desktop" }, { 1920, 1080, "desktop" }, { 3840, 2160, "desktop" } } do
			for _, hasClose in { true, false } do
				local m = metricsFor(vp[1], vp[2], vp[3])
				local L = R.modalLayout(vp[1], vp[2], m, hasClose)
				local c = L.card
				h.ok(c.x >= m.x0 - 1 and c.x + c.w <= m.xr + 1, "inside safe width at " .. vp[1])
				h.ok(c.y >= m.yTop - 1 and c.y + c.h <= m.yBot + 1, "inside safe height at " .. vp[2])
				h.ok(L.buttonH >= HudLayoutRules.MIN_BUTTON, "button floor")
				h.ok(L.buttons.primary.w >= HudLayoutRules.MIN_BUTTON, "primary width")
				h.ok(L.buttons.primary.y + L.buttons.primary.h <= c.y + c.h, "buttons inside card")
				h.ok(L.titleSize >= HudLayoutRules.MIN_TEXT and L.bodySize >= HudLayoutRules.MIN_TEXT, "text floor")
				h.ok(L.bodyH >= 20, "body keeps room at " .. vp[1] .. "x" .. vp[2] .. ": " .. L.bodyH)
				if hasClose then
					local p, cl = L.buttons.primary, L.buttons.close
					h.ok(p.x + p.w <= cl.x, "buttons do not overlap")
					h.ok(cl.w >= HudLayoutRules.MIN_BUTTON, "close width")
				else
					h.eq(L.buttons.close, nil)
				end
			end
		end
	end)

	h.test("layout: toast and banner rects come from lane B / notice stack, hub variants, override wins", function()
		local rects = {
			laneB = { x = 100, y = 8, w = 300, h = 34 },
			hubLaneB = { x = 100, y = 8, w = 200, h = 34 },
			noticeStack = { x = 100, y = 46, w = 300, h = 28 },
			hubBar = { x = 340, y = 8, w = 200, h = 80 },
		}
		h.eq(R.toastRect(rects, false).w, 300)
		h.eq(R.toastRect(rects, true).w, 200)
		h.eq(R.toastRect(rects, true, { x = 1, y = 2, w = 3, h = 4 }).x, 1)
		h.eq(R.bannerRect(rects, false).w, 300)
		h.eq(R.bannerRect(rects, true).w, 340 - 8 - 100)
		local real = HudLayoutRules.compute(740, 360, { left = 0, top = 0, right = 0, bottom = 0 }, HudLayoutRules.fallbackNav(740, 360), "touch", {})
		h.ok(real.laneB and real.noticeStack and real.hubLaneB, "real compute provides the rects")
		h.ok(R.toastRect(real, true).w <= real.laneB.w)
	end)

	h.test("layout: arch label grows with the HUD scale, shrinks with distance but stays readable", function()
		local w1, h1 = R.archLabelSize(10, 1)
		local w2, h2 = R.archLabelSize(400, 1)
		h.ok(w1 > w2 and h1 > h2)
		h.ok(w2 >= 60 and h2 >= 14)
		h.ok(w1 > 170, "larger than a nest label")
	end)

	h.test("skin: every kind has a complete default skin; unknown kinds fall back; art slots default empty", function()
		for _, k in Skin.KINDS do
			local s = Skin.SKINS[k]
			h.ok(s ~= nil, "skin for " .. k)
			for _, c in { s.panel.color, s.accent, s.text, s.title, s.primary, s.primaryText } do
				h.eq(#c, 3)
				for _, v in c do
					h.ok(v >= 0 and v <= 255)
				end
			end
			h.ok(s.panel.alpha >= 0 and s.panel.alpha <= 0.2, "near-solid panel (no see-through pills)")
			h.eq(s.panel.image, nil)
			h.eq(s.icon.image, nil)
			h.ok(#s.icon.glyph == 1, "one-character glyph, no emoji")
		end
		h.eq(Skin.get("nope"), Skin.SKINS.info)
		h.eq(Skin.get(nil), Skin.SKINS.info)
		for _, sfc in Spec.SURFACES do
			h.ok(Skin.SURFACES[sfc] ~= nil, "surface shape for " .. sfc)
		end
	end)

	-- NotifySpec completeness ---------------------------------------------------------------------------------------------
	local REQUIRED = {
		"portal_open", "portal_filling", "portal_racing",
		"storm_announce", "storm_countdown", "storm_inprogress", "storm_slotted",
		"key_found", "key_first_explain", "fragment_found", "amulet_found",
		"avatar_unlock", "reskin_unlock", "tint_unlock",
		"shard_gain", "shard_tier_up", "badge_earned", "map_unlock", "token_progress", "token_gain", "login_reward", "login_info", "cash_gain",
	}

	h.test("spec: every v3 feature has a row", function()
		for _, id in REQUIRED do
			h.ok(Spec.get(id) ~= nil, "row " .. id)
		end
	end)

	h.test("spec: rows are well formed", function()
		local seen = {}
		local sounds = {}
		for _, s in Spec.SOUNDS do
			sounds[s] = true
		end
		local surfaces = {}
		for _, s in Spec.SURFACES do
			surfaces[s] = true
		end
		local banned = { "yay", "wow", "oops", "uh-oh", "hooray", "woohoo", "tada", "yippee", "awesome", "amazing", "fun!" }
		for _, row in Spec.ROWS do
			h.ok(not seen[row.id], "unique id " .. row.id)
			seen[row.id] = true
			h.ok(surfaces[row.surface], row.id .. " surface")
			h.ok(Skin.SKINS[row.kind] ~= nil, row.id .. " kind " .. row.kind)
			h.ok(R.PRIORITY[row.priority] ~= nil, row.id .. " priority")
			h.ok(#row.trigger > 0 and #row.copy > 0 and #row.feature > 0, row.id .. " text fields")
			h.ok(row.sound == nil or sounds[row.sound], row.id .. " sound is a stand-in")
			if row.surface == "toast" then
				h.ok(row.seconds >= R.MIN_SECONDS and row.seconds <= R.MAX_SECONDS, row.id .. " toast seconds")
				h.ok(#row.copy <= 44, row.id .. " toast copy fits a phone lane: " .. #row.copy)
			else
				h.eq(row.seconds, 0, row.id .. " persists until cleared")
			end
			if row.surface == "banner" then
				h.ok(#row.copy <= 40, row.id .. " banner copy length")
			end
			if row.surface == "modal" then
				h.ok(row.title ~= nil and #(row.title :: string) <= 24, row.id .. " modal title")
				h.ok(row.primary ~= nil and #(row.primary :: string) <= 14, row.id .. " primary label")
				h.ok(row.close == nil or #(row.close :: string) <= 14, row.id .. " close label")
				h.ok(#row.copy <= 110, row.id .. " modal body length")
			else
				h.eq(row.primary, nil)
				h.eq(row.close, nil)
			end
			-- placeholders in copy and title are exactly the declared vars
			local declared = {}
			for _, v in row.vars do
				declared[v] = true
			end
			local used = {}
			for _, field in { row.copy, row.title or "" } do
				for k in string.gmatch(field, "{(%w+)}") do
					used[k] = true
					h.ok(declared[k], row.id .. " undeclared var " .. k)
				end
			end
			for v in declared do
				h.ok(used[v], row.id .. " unused var " .. v)
			end
			local lower = string.lower(row.copy .. " " .. (row.title or ""))
			for _, w in banned do
				h.ok(not string.find(lower, w, 1, true), row.id .. " tone word " .. w)
			end
			h.ok(not string.find(row.copy, "!!", 1, true), row.id .. " no shouting")
		end
	end)

	h.test("spec: v3 rulings are honoured in copy", function()
		-- Cash, not Gears; Win Pass/Storm joins are opt-in so no "everyone" language; no "join for more rewards".
		for _, row in Spec.ROWS do
			local c = string.lower(row.copy)
			h.ok(not string.find(c, "gear", 1, true), row.id .. " says Cash, not gears")
			h.ok(not string.find(c, "more rewards", 1, true), row.id .. " no join-for-rewards pitch")
		end
		h.eq(Spec.get("portal_filling").surface, "arch")
		h.eq(Spec.get("storm_announce").surface, "modal")
		h.eq(Spec.get("login_reward").surface, "modal")
		h.ok(Spec.get("storm_announce").close ~= nil, "storm popup can be declined")
	end)

	h.test("spec: format fills placeholders and leaves a visible name for a missing var", function()
		h.eq(Spec.format(Spec.get("portal_filling").copy, { time = "0:14", n = 3, cap = 8 }), "STARTING 0:14 - 3/8")
		h.eq(Spec.format("+{n} Cash", {}), "+n Cash")
		h.eq(Spec.format("plain", nil), "plain")
		h.eq(Spec.format(Spec.get("key_found").copy, { n = 1, total = 4, zone = "Frostpeak" }), "KEY 1/4: Frostpeak. Toward the Amulet")
	end)
end
