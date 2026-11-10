--!strict
-- T1-2 (systems audit v32, N2): a failed map build must not freeze the server. TrackDirector.load sets
-- TrackDirector.switching and the TrackSwitching curtain; while either is up the hub portals do not step and the client
-- prompt policy (PromptPolicyRules.trackSwitching) holds every purchase prompt. Before this module a builder error, a
-- hook that threw or a yield that never came back left both up for the life of the server.
--
-- Pure logic, so tools/tests/director_failsafe_spec.luau drives every failure path under Lune:
--   runGuarded  runs the load body on its own thread under a watchdog (body throws / never returns / returns a failure)
--   buildVerdict decides whether a finished build is usable (the builder's MapBuilt signal is the proof; a cached map is)
--   nextStep    what the director does after a failure: a race map falls back to the hub, a failed hub only releases
--   logLine / toastText  the "[DIRECTOR] load_fail" line and the player-facing toast
local DirectorFailsafeRules = {}

-- Watchdog for one whole load. Must stay well above MapAdapter.MAP_BUILT_TIMEOUT (60 s: a builder that never signals is
-- already reported as a partial build after that) plus the adapter steps, the hooks and the curtain fade, so a slow but
-- healthy cold build is never cut off. A cancelled load costs the players this long under the curtain, once.
DirectorFailsafeRules.LOAD_TIMEOUT = 180
-- How often the director checks that the load body finished. V1 D1: was 0.25, which added up to a quarter second
-- (more on a slow frame) to every load, boot included, after the map was already live; one check per frame is free.
DirectorFailsafeRules.POLL_SECONDS = 0.03

export type Reason = "error" | "timeout" | "builder_error" | "map_not_built" | "failed"
export type Deps = {
	spawn: (fn: () -> ()) -> any, -- task.spawn; returns the thread
	cancel: (thread: any) -> (), -- task.cancel
	clock: () -> number, -- os.clock
	wait: (seconds: number) -> (), -- task.wait
	timeout: number?,
	poll: number?,
}

-- Runs body() on its own thread and waits for it, at most deps.timeout seconds. Returns ok, reason, detail:
--   true                         the body returned true (or nothing falsy)
--   false, "error", message      the body threw
--   false, "timeout", nil        the body was still running at the deadline; its thread is cancelled
--   false, <reason>, detail      the body returned false, reason, detail (a partial build, say)
function DirectorFailsafeRules.runGuarded(body: () -> (boolean?, string?, string?), deps: Deps): (boolean, Reason?, string?)
	local timeout = deps.timeout or DirectorFailsafeRules.LOAD_TIMEOUT
	local poll = deps.poll or DirectorFailsafeRules.POLL_SECONDS
	local done = false
	local okCall, ret, why, detail = false, nil, nil, nil
	local t0 = deps.clock()
	local thread = deps.spawn(function()
		local a, b, c, d = pcall(body)
		okCall, ret, why, detail = a, b, c, d
		done = true
	end)
	while not done do
		if deps.clock() - t0 >= timeout then
			pcall(deps.cancel, thread)
			return false, "timeout", nil
		end
		deps.wait(poll)
	end
	if not okCall then
		return false, "error", tostring(ret)
	end
	if ret == false then
		local r: any = why
		if r ~= "builder_error" and r ~= "map_not_built" and r ~= "error" and r ~= "timeout" then
			r = "failed"
		end
		return false, r, detail
	end
	return true, nil, nil
end

-- Is a finished build usable? A map restored from MapCache is (it was a good build before). A fresh build is when its
-- compiled builder set MapBuilt_<id>; a builder that threw before that, or never signalled within the adapter's wait,
-- left a partial map: not raceable (missing road, gates, spawns).
function DirectorFailsafeRules.buildVerdict(info: { cached: boolean?, builderOk: boolean?, mapBuilt: boolean? }): (boolean, Reason?)
	if info.cached then
		return true, nil
	end
	if info.mapBuilt == true then
		-- A builder warning after its MapBuilt signal is logged by the director but does not throw away a built map.
		return true, nil
	end
	if info.builderOk == false then
		return false, "builder_error"
	end
	return false, "map_not_built"
end

-- After a failed load of `key`: "hub" loads the hub in its place (players land on the plaza), "release" only lowers the
-- flag and the curtain (the hub itself failed; loading it again would loop). One fallback per failure: a fallback load
-- that fails releases.
function DirectorFailsafeRules.nextStep(key: string, hubKey: string, isFallback: boolean?): string
	if key == hubKey or isFallback then
		return "release"
	end
	return "hub"
end

-- A partial build of a map with nowhere to fall back to (the hub, or a load that already is the fallback) goes live as
-- before T1-2 ("continuing with what exists", never cached): a cold hub build past MapAdapter's 60 s wait (a slow
-- server at boot) must not leave the server with no live map, no RaceMode and no portals. Throws and the watchdog
-- still release.
function DirectorFailsafeRules.keepPartial(key: string, hubKey: string, isFallback: boolean?): boolean
	return DirectorFailsafeRules.nextStep(key, hubKey, isFallback) == "release"
end

-- V1 D8: TrackDirector.load got a key with no TrackData module or no compiled builder. With no map live yet (a Studio
-- boot on an ActiveTrackKey this build does not mount) the server used to stay on `map nil` with an empty world; it now
-- falls back to the hub like any failed load ("hub"). With a map live the request is only refused and that map stays
-- ("keep"). No loop: the hub itself missing, or the fallback load, gives "release" (nothing was started, nothing to do).
function DirectorFailsafeRules.missingStep(key: string, hubKey: string, isFallback: boolean?, hasLiveMap: boolean): string
	if hasLiveMap then
		return "keep"
	end
	return DirectorFailsafeRules.nextStep(key, hubKey, isFallback)
end

-- V1 D1 budget guard: a fresh (uncached) build of one map, director start to map live, in seconds. TEST_LIST L42 wants
-- first control under 12 s on a track (T01: 10 s); boot and the vehicle mount add about 1.5 s around the build, so a
-- build over this warns "[DIRECTOR] build_budget over" (Studio boot logs, tools/map_boot_check.py) before the
-- player-facing limit is missed. SPACE-4 built in 11.1-11.4 s before the time-sliced builder yield (V1, 2026-10-22).
DirectorFailsafeRules.BUILD_BUDGET = 8

function DirectorFailsafeRules.overBudget(seconds: number, cached: boolean): boolean
	return not cached and (tonumber(seconds) or 0) > DirectorFailsafeRules.BUILD_BUDGET
end

local function clean(s: string?, n: number): string
	local t = string.gsub(tostring(s or ""), "[%c]", " ")
	return string.sub(t, 1, n)
end

-- The server log line (TrackDirector prefixes "[SkyRally][DIRECTOR] "). Greppable: "load_fail".
function DirectorFailsafeRules.logLine(key: string, mode: string?, reason: string?, detail: string?, seconds: number, step: string): string
	return string.format(
		"load_fail key=%s mode=%s reason=%s after=%.1fs next=%s detail=%s",
		clean(key, 40),
		clean(mode or "race", 16),
		clean(reason or "failed", 20),
		math.max(0, tonumber(seconds) or 0),
		step,
		clean(detail, 200)
	)
end

-- What every player reads (TrackFlow toast). Brief and informational (tone: not a toddler game).
function DirectorFailsafeRules.toastText(step: string): string
	if step == "hub" then
		return "That track failed to load - back to the hub"
	end
	return "Map load failed - try again in a moment"
end

return DirectorFailsafeRules
