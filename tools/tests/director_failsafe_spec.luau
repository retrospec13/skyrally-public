-- T1-2 (systems audit v32, N2): a failed map build must not freeze the server. DirectorFailsafeRules.runGuarded runs
-- TrackDirector's load body under a watchdog; buildVerdict, nextStep, logLine and toastText decide what follows. The
-- failure paths: the builder throws, the load never returns, the build is partial (MapBuilt never set). The wiring in
-- TrackDirector/MapAdapter/TrackFlow is pinned by source checks (the director itself needs Studio).
return function(h)
	local R = h.require("src/shared/DirectorFailsafeRules.luau")

	-- Fake task library: bodies run as coroutines, sleep() parks one until the fake clock passes its wake time, and the
	-- watchdog's wait() advances the clock and wakes due sleepers.
	local function fakeDeps(timeout: number?)
		local d: any = { now = 0, sleepers = {}, cancelled = {}, waits = 0 }
		d.clock = function()
			return d.now
		end
		d.spawn = function(fn)
			local co = coroutine.create(fn)
			local ok, err = coroutine.resume(co)
			assert(ok, err)
			return co
		end
		d.cancel = function(co)
			d.cancelled[co] = true
			coroutine.close(co)
		end
		d.sleep = function(s: number)
			table.insert(d.sleepers, { co = coroutine.running(), at = d.now + s })
			coroutine.yield()
		end
		d.wait = function(s: number)
			d.waits += 1
			d.now += s
			for i = #d.sleepers, 1, -1 do
				local e = d.sleepers[i]
				if e.at <= d.now then
					table.remove(d.sleepers, i)
					if not d.cancelled[e.co] then
						local ok, err = coroutine.resume(e.co)
						assert(ok, err)
					end
				end
			end
		end
		d.timeout = timeout
		d.poll = 0.25
		return d
	end

	h.test("constants: the watchdog sits well above MapAdapter's 60 s MapBuilt wait", function()
		h.eq(R.LOAD_TIMEOUT, 180)
		h.ok(R.LOAD_TIMEOUT >= 60 * 2, "a slow but healthy cold build is never cut off")
		h.ok(R.POLL_SECONDS > 0 and R.POLL_SECONDS <= 0.5)
	end)

	h.test("runGuarded: a body that finishes (at once or after yields) is ok", function()
		local d = fakeDeps(10)
		h.eq(R.runGuarded(function()
			return true
		end, d), true)
		local d2 = fakeDeps(10)
		local ok, reason = R.runGuarded(function()
			d2.sleep(3)
			d2.sleep(2)
			return true
		end, d2)
		h.eq(ok, true)
		h.eq(reason, nil)
		h.ok(d2.now >= 5 and d2.now < 6, "returned once the body was done")
	end)

	h.test("failure path 1: the load body throws (a hook, MapAdapter, MapCache)", function()
		local d = fakeDeps(10)
		local ok, reason, detail = R.runGuarded(function()
			d.sleep(1)
			error("startMode exploded")
		end, d)
		h.eq(ok, false)
		h.eq(reason, "error")
		h.contains(detail, "startMode exploded")
		h.ok(d.now < 2, "reported at once, not at the deadline")
	end)

	h.test("failure path 2: the load never returns; the watchdog cancels its thread at the deadline", function()
		local d = fakeDeps(30)
		local after = false
		local ok, reason = R.runGuarded(function()
			d.sleep(1e9) -- a WaitForChild with no timeout, a ModelBakes fetch that never comes back
			after = true
			return true
		end, d)
		h.eq(ok, false)
		h.eq(reason, "timeout")
		h.ok(d.now >= 30 and d.now < 31, "gave up at the 30 s deadline")
		h.eq(next(d.cancelled) ~= nil, true, "the stuck thread was cancelled")
		d.wait(2e9)
		h.eq(after, false, "a cancelled load never resumes and overwrites the fallback")
	end)

	h.test("failure path 2b: the default deadline is LOAD_TIMEOUT", function()
		local d = fakeDeps(nil)
		local ok, reason = R.runGuarded(function()
			d.sleep(1e9)
			return true
		end, d)
		h.eq(ok, false)
		h.eq(reason, "timeout")
		h.ok(d.now >= R.LOAD_TIMEOUT and d.now < R.LOAD_TIMEOUT + 1)
	end)

	h.test("failure path 3: the body reports a partial build (returns false, reason, detail)", function()
		local d = fakeDeps(10)
		local ok, reason, detail = R.runGuarded(function()
			return false, "builder_error", "Maps.dino4:1419: attempt to index nil"
		end, d)
		h.eq(ok, false)
		h.eq(reason, "builder_error")
		h.contains(detail, "1419")
		local _, r2 = R.runGuarded(function()
			return false, "map_not_built"
		end, fakeDeps(10))
		h.eq(r2, "map_not_built")
		local _, r3 = R.runGuarded(function()
			return false, "something odd"
		end, fakeDeps(10))
		h.eq(r3, "failed", "unknown reasons normalize")
	end)

	h.test("buildVerdict: cached and MapBuilt builds are usable; a builder throw or a missing MapBuilt is partial", function()
		h.eq(R.buildVerdict({ cached = true }), true)
		h.eq(R.buildVerdict({ cached = false, builderOk = true, mapBuilt = true }), true)
		h.eq(R.buildVerdict({ builderOk = false, mapBuilt = true }), true, "a warning after MapBuilt keeps the built map")
		local ok, why = R.buildVerdict({ builderOk = false, mapBuilt = false })
		h.eq(ok, false)
		h.eq(why, "builder_error")
		ok, why = R.buildVerdict({ builderOk = true, mapBuilt = false })
		h.eq(ok, false)
		h.eq(why, "map_not_built", "builder never signalled within the adapter's wait")
		ok, why = R.buildVerdict({})
		h.eq(ok, false)
		h.eq(why, "map_not_built")
	end)

	h.test("keepPartial: only a map with no fallback (hub, or the fallback itself) goes live partial", function()
		h.eq(R.keepPartial("hub0", "hub0", false), true, "a slow cold hub at boot must not leave no map")
		h.eq(R.keepPartial("dino4", "hub0", true), true)
		h.eq(R.keepPartial("dino4", "hub0", nil), false, "a partial race map falls back to the hub")
	end)

	h.test("nextStep: a race map falls back to the hub once; a failed hub or a failed fallback only releases", function()
		h.eq(R.nextStep("dino4", "hub0", false), "hub")
		h.eq(R.nextStep("dino4", "hub0", nil), "hub")
		h.eq(R.nextStep("hub0", "hub0", false), "release", "no loop on the hub")
		h.eq(R.nextStep("dino4", "hub0", true), "release")
		h.eq(R.nextStep("hub0", "hub0", true), "release")
	end)

	h.test("missingStep (V1 D8): an unknown key with no live map falls back to the hub; with a live map it is refused", function()
		h.eq(R.missingStep("nope9", "hub0", nil, false), "hub", "boot on an unknown ActiveTrackKey lands on the hub, not map nil")
		h.eq(R.missingStep("nope9", "hub0", false, true), "keep", "a live map stays when a request names an unknown key")
		h.eq(R.missingStep("hub0", "hub0", nil, false), "release", "the hub itself missing: no loop")
		h.eq(R.missingStep("hub0", "hub0", true, false), "release", "the fallback load missing: no loop")
		local line = R.logLine("nope9", nil, "missing", "no TrackData or builder", 0, "hub")
		h.eq(line, "load_fail key=nope9 mode=race reason=missing after=0.0s next=hub detail=no TrackData or builder")
	end)

	h.test("wiring (V1 D8): the no-TrackData/no-builder early return routes through missingStep to the hub fallback", function()
		local src = h.readFile("src/server/TrackDirector.luau")
		local s0 = string.find(src, "no TrackData or builder for", 1, true)
		local s1 = string.find(src, "TrackDirector.switching = true", s0 or 1, true)
		h.ok(s0 ~= nil and s1 ~= nil, "early return found before the guarded load")
		local early = string.sub(src, s0 or 1, s1 or #src)
		h.contains(early, "DirectorFailsafeRules.missingStep(key, TrackDirector.HUB_KEY, isFallback, TrackDirector.currentKey ~= nil)")
		h.contains(early, "TrackDirector.load(TrackDirector.HUB_KEY, \"hub\", true)")
		h.contains(early, "DirectorFailsafeRules.logLine(key, mode, \"missing\"")
	end)

	h.test("overBudget (V1 D1): a fresh build over BUILD_BUDGET warns; a cached load never does", function()
		h.ok(R.BUILD_BUDGET > 0 and R.BUILD_BUDGET <= 9, "leaves room for boot + mount under the 10-12 s first-control limit")
		h.eq(R.overBudget(11.4, false), true, "SPACE-4 before the fix")
		h.eq(R.overBudget(R.BUILD_BUDGET, false), false)
		h.eq(R.overBudget(30, true), false)
		local src = h.readFile("src/server/TrackDirector.luau")
		h.contains(src, "DirectorFailsafeRules.overBudget(loadSeconds, cached ~= nil)")
		h.contains(src, "build_budget over key=")
	end)

	h.test("logLine: greppable load_fail line, one line, bounded", function()
		local line = R.logLine("dino4", "race", "timeout", "a\nb", 180.04, "hub")
		h.eq(line, "load_fail key=dino4 mode=race reason=timeout after=180.0s next=hub detail=a b")
		local long = R.logLine("hub0", nil, nil, string.rep("x", 500), -3, "release")
		h.contains(long, "mode=race reason=failed after=0.0s next=release")
		h.ok(#long < 320, "detail capped")
		h.ok(not string.find(long, "\n", 1, true))
	end)

	h.test("toastText: brief, informational, fits the 60-char client toast", function()
		for _, s in { "hub", "release" } do
			local t = R.toastText(s :: any)
			h.ok(#t > 0 and #t <= 60, t)
			h.ok(not string.find(t, "!", 1, true), "no exclamation (tone)")
		end
		h.contains(R.toastText("hub"), "hub")
	end)

	h.test("wiring: TrackDirector guards the load, releases flag + curtain, toasts, logs, falls back once", function()
		local src = h.readFile("src/server/TrackDirector.luau")
		h.contains(src, "DirectorFailsafeRules.runGuarded(")
		h.contains(src, "DirectorFailsafeRules.buildVerdict(")
		h.contains(src, "DirectorFailsafeRules.keepPartial(key, TrackDirector.HUB_KEY, isFallback)")
		h.contains(src, "DirectorFailsafeRules.nextStep(key, TrackDirector.HUB_KEY, isFallback)")
		h.contains(src, "DirectorFailsafeRules.logLine(")
		h.contains(src, "remote:FireAllClients(\"LoadFailed\"")
		h.contains(src, "TrackDirector.load(TrackDirector.HUB_KEY, \"hub\", true)")
		local s0, e0 = string.find(src, "local function releaseAfterFailure", 1, true)
		h.ok(s0 ~= nil, "releaseAfterFailure exists")
		local body = string.sub(src, e0 or 1, (string.find(src, "function TrackDirector.load(", e0 or 1, true)) or #src)
		h.contains(body, "TrackDirector.switching = false")
		h.contains(body, "setCurtain(false, nil, nil, nil)", "TrackSwitching down: PromptPolicyRules lets prompts show again")
		h.contains(body, "ctx.clone:Destroy()")
		h.contains(body, "suspendRace(false)")
		-- A partial build is never cached (MapCache.store comes after the verdict).
		local v = string.find(src, "DirectorFailsafeRules.buildVerdict(", 1, true)
		local st = string.find(src, "MapCache.store(", 1, true)
		h.ok(v and st and v < st, "verdict before MapCache.store")
	end)

	h.test("wiring: a builder throw wakes MapAdapter's MapBuilt wait at once (MapBuildFailed_<id>), the toast reaches clients", function()
		local adapter = h.readFile("src/server/MapAdapter.luau")
		h.contains(adapter, 'return "MapBuildFailed_" ..')
		h.contains(adapter, "if workspace:GetAttribute(failedAttr) == true then")
		-- Regression (owner 2026-10-21, "That track failed to load" + bare hub arches): every compiled builder sets
		-- MapBuilt_<id> = false when it STARTS, so false must never end the wait or read as a failed build.
		h.ok(not string.find(adapter, "v == true or v == false", 1, true), "MapBuilt = false never ends the wait")
		h.ok(not string.find(adapter, "now ~= false", 1, true), "MapBuilt = false never ends the wait (initial check)")
		h.contains(h.readFile("build/hub0/builder_module.luau"), "workspace:SetAttribute(READY_ATTR, false)")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "workspace:SetAttribute(failedAttr, true)")
		h.ok(not string.find(td, "SetAttribute(readyAttr, false)", 1, true), "the director never writes MapBuilt = false")
		h.contains(td, "workspace:SetAttribute(MapAdapter.failedAttribute(td.id), nil)")
		local flow = h.readFile("src/client/TrackFlow.luau")
		h.contains(flow, "event == \"LoadFailed\"")
	end)
end
