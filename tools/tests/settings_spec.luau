--!strict
-- Lune spec for player settings (audit H13): shared/SettingsRules (validation, clamping, token bucket, slider maths),
-- server/SettingsService (relay with SaveService mocks: validated, rate limited, queued before load, published once on
-- load) and SaveService's repair of a bad stored settings table. Settings are not progression: every case that writes
-- also checks tokens and bosses stay untouched.
-- Run: tools/tests/run_lune_tests.sh tools/tests/settings_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
}

return function(h: Harness)
	local R = h.require("src/shared/SettingsRules.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local SettingsService = h.require("src/server/SettingsService.luau")
	local UiSoundRules = h.require("src/shared/UiSoundRules.luau")

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end

	---------------------------------------------------------------------------------------------- rules

	h.test("settings: nine settings, unique keys and attributes, volumes default sensibly", function()
		h.eq(#R.DEFS, 9)
		local keys, attrs = {}, {}
		for _, d in R.DEFS do
			h.ok(not keys[d.key] and not attrs[d.attr], "unique " .. d.key)
			keys[d.key], attrs[d.attr] = true, true
			h.ok(#d.label <= 14, d.label .. " is short enough for a 740 px panel")
		end
		-- The attributes the existing sound modules read, plus the new SFX group.
		for _, a in { "MusicVolume", "AmbienceVolume", "UiVolume", "SfxVolume" } do
			h.ok(attrs[a], a)
		end
		-- A player who never opens Settings hears exactly what shipped before: the UI default matches the sound kit's.
		h.eq(R.def("uiVolume").default, UiSoundRules.DEFAULT_UI_VOLUME)
		h.eq(R.def("musicVolume").default, 1)
		h.eq(R.def("cameraShake").default, true)
		h.eq(R.def("lowGraphics").default, false)
		-- ASSIST: saved, on by default (phones drive forward in a race), the attribute FlightController mirrors.
		h.eq(R.def("assist").default, true)
		h.eq(R.def("assist").kind, "toggle")
		h.eq(R.def("assist").attr, "AutoThrottle")
		h.eq(R.resolve({}).assist, true, "never saved: on")
		h.eq(R.resolve({ assist = false }).assist, false, "a saved OFF stays off")
		h.eq(R.resolve({ assist = "off" }).assist, true, "junk falls back to the default")
		-- FLIGHT_GUIDE.md 12: Free driving is the advanced option, off by default (the Mario Kart mode is the default).
		h.eq(R.def("freeDriving").default, false)
		h.eq(R.def("freeDriving").kind, "toggle")
		h.eq(R.def("freeDriving").attr, "FreeDriving")
		h.eq(R.flightModeOf(true), "free")
		h.eq(R.flightModeOf(nil), "mk")
		for _, junk in { false, "true", "free", 1, {} } :: { any } do
			h.eq(R.flightModeOf(junk), "mk", "only a boolean true is Free driving")
		end
		h.eq(R.cleanValue("freeDriving", "yes"), nil, "a string is refused")
		h.eq(R.cleanValue("freeDriving", 1), nil, "a number is refused")
		h.eq(R.cleanValue("freeDriving", true), true)
		h.eq(R.resolve({}).freeDriving, false, "never saved: the default mode")
		h.eq(R.resolve({ freeDriving = "free" }).freeDriving, false, "a junk stored value falls back to the default")
	end)

	h.test("settings: volumes clamp to 0..1 and round to two decimals; junk is nil", function()
		h.eq(R.cleanVolume(0.456), 0.46)
		h.eq(R.cleanVolume(-3), 0)
		h.eq(R.cleanVolume(7), 1)
		h.eq(R.cleanVolume(0 / 0), nil)
		h.eq(R.cleanVolume(math.huge), nil)
		h.eq(R.cleanVolume("0.5"), nil)
		h.eq(R.cleanVolume(true), nil)
		h.eq(R.cleanVolume({}), nil)
	end)

	h.test("settings: toggles accept booleans only", function()
		h.eq(R.cleanValue("lowGraphics", true), true)
		h.eq(R.cleanValue("cameraShake", false), false)
		h.eq(R.cleanValue("lowGraphics", 1), nil)
		h.eq(R.cleanValue("lowGraphics", "true"), nil)
		h.eq(R.cleanValue("cameraShake", 0), nil)
		h.eq(R.cleanValue("musicVolume", true), nil, "a boolean is not a volume")
		h.eq(R.cleanValue("gears", 5), nil, "unknown key")
		h.eq(R.cleanValue(7, 0.5), nil, "non-string key")
	end)

	h.test("settings: cleanUpdate keeps the valid entries only", function()
		h.eq(R.cleanUpdate({ musicVolume = 0.3, sfxVolume = 9, lowGraphics = true }), { musicVolume = 0.3, sfxVolume = 1, lowGraphics = true })
		h.eq(R.cleanUpdate({ musicVolume = "loud", lowGraphics = "yes" }), nil)
		h.eq(R.cleanUpdate({ tokens = { ["race:DINO-4"] = true }, gears = 99999 }), nil, "progression keys are not settings")
		h.eq(R.cleanUpdate({ musicVolume = 0.2, gears = 99999 }), { musicVolume = 0.2 })
		h.eq(R.cleanUpdate({}), nil)
		h.eq(R.cleanUpdate("musicVolume"), nil)
		h.eq(R.cleanUpdate(nil), nil)
	end)

	h.test("settings: an over-long payload is refused whole", function()
		local big: any = { musicVolume = 0.5 }
		for i = 1, R.MAX_PAYLOAD_KEYS + 2 do
			big["junk" .. i] = i
		end
		h.eq(R.cleanUpdate(big), nil)
		local list: any = {}
		for i = 1, 40 do
			list[i] = 0.5
		end
		h.eq(R.cleanUpdate(list), nil, "an array has no setting keys (and is too long)")
	end)

	h.test("settings: stored table repair keeps unknown keys and fixes known ones", function()
		local s: any = { musicVolume = 7, sfxVolume = "loud", uiVolume = 0.456, lowGraphics = "yes", cameraShake = false, futureThing = { a = 1 } }
		h.ok(R.sanitizeStored(s))
		h.eq(s, { musicVolume = 1, uiVolume = 0.46, cameraShake = false, futureThing = { a = 1 } })
		h.eq(R.sanitizeStored(s), false, "a clean table reports no change")
		local legacy: any = { musicVolume = 0.4 } -- what save_spec writes through edit()
		h.eq(R.sanitizeStored(legacy), false)
		h.eq(legacy, { musicVolume = 0.4 })
	end)

	h.test("settings: apply reports real changes only; resolve fills defaults", function()
		local s: any = { musicVolume = 0.5 }
		h.eq(R.apply(s, { musicVolume = 0.5 }), false)
		h.eq(R.apply(s, { musicVolume = 0.2, lowGraphics = true }), true)
		h.eq(s, { musicVolume = 0.2, lowGraphics = true })
		local all = R.resolve({ sfxVolume = 0.25, uiVolume = "bad" })
		h.eq(all.sfxVolume, 0.25)
		h.eq(all.uiVolume, 0.6, "bad stored value falls back to the default")
		h.eq(all.musicVolume, 1)
		h.eq(all.lowGraphics, false)
		h.eq(R.resolve(nil).cameraShake, true)
		h.eq(R.fromAttribute("musicVolume", nil), 1)
		h.eq(R.fromAttribute("musicVolume", 0.3), 0.3)
		h.eq(R.fromAttribute("lowGraphics", "x"), false)
	end)

	h.test("settings: token bucket allows a burst of six, then two a second", function()
		local b = R.newBucket(100)
		for i = 1, 6 do
			h.ok(R.take(b, 100), "burst " .. i)
		end
		h.eq(R.take(b, 100), false, "seventh in the same instant")
		h.eq(R.take(b, 100.3), false, "0.3 s later: 0.6 token")
		h.ok(R.take(b, 100.6), "0.6 s after the start: a token is back")
		h.eq(R.take(b, 100.6), false)
		h.ok(R.take(b, 101.2), "two a second")
		-- A long quiet spell refills to the burst, never beyond it.
		h.ok(R.take(b, 500))
		h.ok(b.tokens <= R.BUCKET_BURST)
		h.ok(near(b.tokens, R.BUCKET_BURST - 1))
	end)

	h.test("settings: slider maths lands on notches without float dust", function()
		h.eq(R.fractionAt(140, 100, 200), 0.2)
		h.eq(R.fractionAt(150, 100, 200), 0.3, "0.25 rounds up to the next notch")
		h.eq(R.fractionAt(0, 100, 200), 0)
		h.eq(R.fractionAt(999, 100, 200), 1)
		h.eq(R.fractionAt(130, 100, 0), 0, "zero-width track")
		h.eq(R.nudge(0.2, 1), 0.3)
		h.eq(R.nudge(0.3, -1), 0.2)
		h.eq(R.nudge(1, 1), 1)
		h.eq(R.nudge(0, -1), 0)
		h.eq(R.nudge(0.6, 1), 0.7)
		h.eq(R.percentText(0.3), "30%")
		h.eq(R.percentText(1.4), "100%")
		h.eq(R.shakeScale(true), 1)
		h.eq(R.shakeScale(false), 0)
		h.eq(R.particleScale(false), 1)
		h.ok(R.particleScale(true) < 1 and R.particleScale(true) > 0)
	end)

	h.test("settings: the panel fits its viewport at every size (the gear itself is a HudLayoutRules rect, see hud_layout_spec)", function()
		-- The panel fits its viewport at every size and stays readable.
		for _, vp in { { 740, 360 }, { 844, 390 }, { 568, 320 }, { 1440, 900 }, { 2560, 1440 } } do
			local s = R.panelScale(vp[1], vp[2])
			h.ok(R.PANEL_W * s <= vp[1] and R.PANEL_H * s <= vp[2], string.format("%dx%d fits at %.2f", vp[1], vp[2], s))
			h.ok(s >= 0.7 and s <= 1.6)
		end
		h.ok(R.panelScale(740, 360) >= 1, "no shrinking at 740x360")
	end)

	---------------------------------------------------------------------------------------------- server relay

	local function env(opts: { [string]: any }?): any
		local o: any = opts or {}
		local sched = o.sched or h.newScheduler()
		local backing: any = o.backing or {}
		local logs: { string } = {}
		local store = SaveService.newMemoryStore(backing)
		local save = SaveService.new({
			store = store,
			sessionId = o.sessionId or "server-A",
			newToken = function(): string
				return "tok-" .. tostring(math.random(1, 1e9))
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function(line: string)
				table.insert(logs, line)
			end,
			random = function(): number
				return 0.5
			end,
			config = o.config or { writeCooldown = 0 },
		})
		local svc = SettingsService.new({
			edit = save.edit,
			get = save.get,
			onLoaded = save.onLoaded,
			now = sched.clock,
			log = function(line: string)
				table.insert(logs, line)
			end,
		})
		return { sched = sched, save = save, svc = svc, logs = logs, backing = backing, store = store }
	end

	local function load(e: any, p: any): any
		local profile = e.sched.run(function()
			return e.save.load(p)
		end)
		e.sched.advance(0.1) -- the onLoaded handler runs in its own task
		return profile
	end

	h.test("settings service: a valid update lands in the profile settings and survives a rejoin", function()
		local e = env()
		local p = h.fakePlayer(310)
		load(e, p)
		h.eq(e.svc.handle(p, { musicVolume = 0.35, cameraShake = false }), "saved")
		local snap = e.save.get(p)
		h.eq(snap.settings, { musicVolume = 0.35, cameraShake = false })
		h.eq(snap.tokens, {}, "progression untouched")
		p:leave()
		e.sched.run(function()
			return e.save.release(p)
		end)
		local e2 = env({ sched = e.sched, backing = e.backing, sessionId = "server-B" })
		local p2 = h.fakePlayer(310)
		load(e2, p2)
		h.eq(e2.save.get(p2).settings, { musicVolume = 0.35, cameraShake = false })
		-- Published once on load as the attributes the client modules read.
		h.eq(p2:GetAttribute("MusicVolume"), 0.35)
		h.eq(p2:GetAttribute("CameraShake"), false)
		h.eq(p2:GetAttribute("SfxVolume"), 1, "never saved: default")
		h.eq(p2:GetAttribute("UiVolume"), 0.6)
		h.eq(p2:GetAttribute("LowGraphics"), false)
		h.eq(p2:GetAttribute("SettingsLoaded"), true)
	end)

	h.test("settings service: FREE DRIVING publishes the server-owned FlightMode at once, on load and validated", function()
		local e = env()
		local p = h.fakePlayer(320)
		load(e, p)
		h.eq(p:GetAttribute("FlightMode"), "mk", "published on load: the default mode")
		h.eq(e.svc.handle(p, { freeDriving = true }), "saved")
		h.eq(p:GetAttribute("FlightMode"), "free", "set at once by the server")
		h.eq(e.save.get(p).settings.freeDriving, true, "saved")
		h.eq(e.svc.handle(p, { freeDriving = "free" }), "empty", "a junk value is dropped")
		h.eq(p:GetAttribute("FlightMode"), "free", "unchanged by junk")
		h.eq(e.svc.handle(p, { musicVolume = 0.5 }), "saved")
		h.eq(p:GetAttribute("FlightMode"), "free", "another setting leaves the mode alone")
		h.eq(e.svc.handle(p, { freeDriving = false }), "saved")
		h.eq(p:GetAttribute("FlightMode"), "mk")
		-- Before the profile loads the mode still applies (queued for the save), and the load keeps it.
		local q = h.fakePlayer(321)
		h.eq(e.svc.handle(q, { freeDriving = true }), "queued")
		h.eq(q:GetAttribute("FlightMode"), "free")
		load(e, q)
		h.eq(q:GetAttribute("FlightMode"), "free", "the queued value was saved, then published")
		-- A rejoin reads it back.
		p:leave()
		e.sched.run(function()
			return e.save.release(p)
		end)
		local e2 = env({ sched = e.sched, backing = e.backing, sessionId = "server-B" })
		local p2 = h.fakePlayer(320)
		load(e2, p2)
		h.eq(p2:GetAttribute("FlightMode"), "mk")
		h.eq(p2:GetAttribute("FreeDriving"), false)
	end)

	h.test("settings service: forged and junk payloads change nothing", function()
		local e = env()
		local p = h.fakePlayer(311)
		load(e, p)
		h.eq(e.svc.handle(p, { tokens = { ["race:DINO-4"] = true }, boss = { DINO = { first = true } }, gears = 999999 }), "empty")
		h.eq(e.svc.handle(p, "musicVolume=1"), "empty")
		h.eq(e.svc.handle(p, { musicVolume = 0 / 0, lowGraphics = 1 }), "empty")
		h.eq(e.svc.handle(p, nil), "empty")
		local snap = e.save.get(p)
		h.eq(snap.settings, {})
		h.eq(snap.tokens, {})
		h.eq(snap.gears, 0)
		-- A mixed payload keeps only the valid part, clamped.
		h.eq(e.svc.handle(p, { sfxVolume = 5, tokens = {}, uiVolume = -1 }), "saved")
		h.eq(e.save.get(p).settings, { sfxVolume = 1, uiVolume = 0 })
	end)

	h.test("settings service: rate limited per player, other players unaffected", function()
		local e = env()
		local a, b = h.fakePlayer(312), h.fakePlayer(313)
		load(e, a)
		load(e, b)
		for i = 1, 6 do
			h.eq(e.svc.handle(a, { musicVolume = i / 10 }), "saved", "burst " .. i)
		end
		h.eq(e.svc.handle(a, { musicVolume = 0.9 }), "limited")
		h.eq(e.save.get(a).settings.musicVolume, 0.6, "the limited message did nothing")
		h.eq(e.svc.handle(b, { musicVolume = 0.9 }), "saved")
		e.sched.advance(1)
		h.eq(e.svc.handle(a, { musicVolume = 0.9 }), "saved", "tokens refill")
		-- A leaver's bucket is dropped (a rejoin starts fresh).
		e.svc.forget(a)
		h.eq(e.svc.handle(a, { musicVolume = 0.1 }), "saved")
	end)

	h.test("settings service: an update before the profile loads waits and is applied on load", function()
		local e = env()
		local p = h.fakePlayer(314)
		h.eq(e.svc.handle(p, { musicVolume = 0.2 }), "queued")
		h.eq(e.svc.handle(p, { musicVolume = 0.4, lowGraphics = true }), "queued", "newest value per key wins")
		load(e, p)
		h.eq(e.save.get(p).settings, { musicVolume = 0.4, lowGraphics = true })
		h.eq(p:GetAttribute("MusicVolume"), 0.4)
		h.eq(p:GetAttribute("LowGraphics"), true)
	end)

	h.test("settings rules: overlay lets the player's session choices win over the saved table", function()
		local saved = R.resolve({ assist = true, musicVolume = 0.5 })
		local out = R.overlay(saved, { assist = false })
		h.eq(out.assist, false, "touched wins")
		h.eq(out.musicVolume, 0.5, "untouched follows the save")
		h.eq(saved.assist, true, "input table not mutated")
		h.eq(R.overlay(saved, nil).assist, true)
		h.eq(R.overlay(saved, { bogus = true, assist = "x" }).assist, true, "unknown keys and junk values are ignored")
	end)

	h.test("settings rules: acceptRemote refuses a server value that disagrees with the player's choice", function()
		h.ok(R.acceptRemote({}, "assist", true), "no choice yet: the server's first publish is accepted")
		h.ok(not R.acceptRemote({ assist = false }, "assist", true), "chose OFF, server says ON: refused")
		h.ok(R.acceptRemote({ assist = false }, "assist", false), "agreeing value passes")
		h.ok(R.acceptRemote({ assist = false }, "cameraShake", true), "other keys follow the server")
		h.ok(not R.acceptRemote({ musicVolume = 0.3 }, "musicVolume", 0.7))
		h.ok(R.acceptRemote({ musicVolume = 0.3 }, "musicVolume", 0.3))
	end)

	h.test("settings service: a late publish never undoes the ASSIST choice made meanwhile (QA V5A revert)", function()
		local e = env()
		local p = h.fakePlayer(330)
		-- Tapped the chip before the profile finished loading: the server queued it.
		h.eq(e.svc.handle(p, { assist = false }), "queued")
		load(e, p)
		h.eq(p:GetAttribute("AutoThrottle"), false, "published value is the player's")
		-- A second publish (a retried load, a join-time loop) still reads the player's choice, not the older save.
		e.svc.publish(p)
		h.eq(p:GetAttribute("AutoThrottle"), false)
		-- Toggled back on, then a further publish keeps ON.
		h.eq(e.svc.handle(p, { assist = true }), "saved")
		e.svc.publish(p)
		h.eq(p:GetAttribute("AutoThrottle"), true)
		-- Another player is unaffected.
		local q = h.fakePlayer(331)
		load(e, q)
		h.eq(q:GetAttribute("AutoThrottle"), true, "default for a player who never touched it")
		-- A rejoin forgets the session choices (the save is the truth then).
		e.svc.forget(p)
		e.svc.publish(p)
		h.eq(p:GetAttribute("AutoThrottle"), true)
	end)

	h.test("settings service: slider updates coalesce into few writes and the last value lands", function()
		local e = env({ config = { writeCooldown = 6 } })
		local p = h.fakePlayer(317)
		load(e, p)
		e.sched.advance(7) -- past the load's own write
		local before = e.store.writes
		for i = 1, 5 do
			e.svc.handle(p, { sfxVolume = i / 10 })
			e.sched.advance(0.2)
		end
		e.sched.advance(7)
		local writes = e.store.writes - before
		h.ok(writes >= 1 and writes <= 2, "five updates cost " .. tostring(writes) .. " writes")
		h.eq(e.backing.u_317.profile.settings.sfxVolume, 0.5)
		-- A final change right before leaving is flushed by release.
		e.svc.handle(p, { sfxVolume = 0.8 })
		p:leave()
		e.sched.run(function()
			return e.save.release(p)
		end)
		h.eq(e.backing.u_317.profile.settings.sfxVolume, 0.8)
	end)

	---------------------------------------------------------------------------------------------- save repair

	h.test("save: a corrupt stored settings table is repaired on load and never blocks the profile", function()
		local raw: any = {
			version = 2,
			tokens = { ["race:DINO-4"] = true },
			settings = { musicVolume = 7, sfxVolume = "loud", lowGraphics = "yes", cameraShake = false, extra = 3 },
		}
		local profile = SaveService.migrate(raw)
		h.eq(profile.settings, { musicVolume = 1, cameraShake = false, extra = 3 })
		h.eq(profile.tokens["race:DINO-4"], true, "progression intact")
		-- settings of the wrong type altogether reset to an empty table (reconcile), still a normal load.
		local profile2 = SaveService.migrate({ version = 2, tokens = {}, settings = "garbage" })
		h.eq(profile2.settings, {})
		h.eq(SaveService.CURRENT_VERSION, 2, "no version bump: older servers keep reading these records")
	end)

	h.test("save: edit() repairs a bad settings write instead of storing it", function()
		local e = env()
		local p = h.fakePlayer(316)
		load(e, p)
		h.ok(e.save.edit(p, "bad", function(profile: any)
			profile.settings.musicVolume = 42
			profile.settings.lowGraphics = "maybe"
		end))
		h.eq(e.save.get(p).settings, { musicVolume = 1 })
	end)

	---------------------------------------------------------------------------------------------- wiring guards

	h.test("settings: every volume attribute is read by a sound module, and the sfx group is used", function()
		local function has(path: string, needle: string): boolean
			return string.find(h.readFile(path), needle, 1, true) ~= nil
		end
		h.ok(has("src/client/Music.luau", "MusicVolume"))
		h.ok(has("src/client/Soundscape.luau", "AmbienceVolume"))
		h.ok(has("src/client/UiSound.luau", "UiVolume"))
		h.ok(has("src/client/Settings.luau", "SfxVolume") or has("src/shared/SettingsRules.luau", "SfxVolume"))
		-- Engine, impact and item sounds join the SFX group.
		for _, f in { "SoundJuice", "ItemJuice", "TrickJuice", "StyleChain" } do
			h.ok(has("src/client/" .. f .. ".luau", "Settings"), f .. " routes through Settings.sfx")
		end
		-- The vehicle cameras and the other shakes honour the toggle.
		for _, f in { "CarController", "FlightController", "Music", "PortalWake" } do
			h.ok(has("src/client/" .. f .. ".luau", "shakeScale"), f .. " honours camera shake")
		end
		h.ok(has("src/client/Vfx.luau", "particleScale"), "Vfx honours low graphics")
	end)

	h.test("static: client Settings records the player's choice and refuses a disagreeing server publish (QA V5A)", function()
		local src = h.readFile("src/client/Settings.luau")
		h.contains(src, "chosen[key] = v")
		h.contains(src, "Rules.acceptRemote(chosen, d.key, incoming)")
		local server = h.readFile("src/server/SettingsService.luau")
		h.contains(server, "SettingsRules.overlay(")
		h.contains(server, "touched[player]")
	end)
end
