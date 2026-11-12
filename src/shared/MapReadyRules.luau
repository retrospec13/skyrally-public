--!strict
-- v37 client-ready handshake (pure rules; server/MapReadyGate, client/TrackFlow; specced in tools/tests/map_ready_spec.luau).
-- After a race map is built the server publishes a token and the map's descendant count on the map root. Each client
-- answers "MapReady" with that token once it holds (nearly) all of the map and has rendered a run of smooth frames after
-- it (a client still taking the map in freezes, so the run only completes once the freeze is over). The race's
-- countdown starts when every human it waits for has answered, or TIMEOUT seconds after the server was ready: a late
-- client joins the countdown already running, as before the handshake. The server decides; a client can only report
-- itself ready, so it can neither start anyone early nor hold anyone past the timeout.
local MapReadyRules = {}

MapReadyRules.TIMEOUT = 12 -- s after the server's map is ready
MapReadyRules.TOKEN_ATTR = "MapReadyToken" -- on the map root: this load's token (set after COUNT_ATTR)
MapReadyRules.COUNT_ATTR = "MapReadyCount" -- on the map root: the server's descendant count of the map
MapReadyRules.COUNT_FRACTION = 0.9 -- the client may hide or merge a few parts of its own
MapReadyRules.SMOOTH_FRAMES = 8 -- consecutive rendered frames ...
MapReadyRules.SMOOTH_DT = 0.1 -- ... each shorter than this (s)
MapReadyRules.CLIENT_GIVEUP = 30 -- s: a client that never sees the count answers anyway (the server timed out long ago)

export type Verdict = "wait" | "all" | "timeout"

-- need: the user ids the countdown waits for; acked: user id -> answered. Returns the verdict and how many are missing.
function MapReadyRules.verdict(need: { number }, acked: { [number]: boolean }, waited: number, timeout: number?): (Verdict, number)
	local missing = 0
	for _, uid in need do
		if not acked[uid] then
			missing += 1
		end
	end
	if missing == 0 then
		return "all", 0
	end
	if waited >= (timeout or MapReadyRules.TIMEOUT) then
		return "timeout", missing
	end
	return "wait", missing
end

-- The client holds the map once its descendant count reaches COUNT_FRACTION of the server's.
function MapReadyRules.countReady(have: number, expected: any): boolean
	if type(expected) ~= "number" or expected <= 0 then
		return true
	end
	return have >= expected * MapReadyRules.COUNT_FRACTION
end

-- One rendered frame of the smooth run: the new run length.
function MapReadyRules.smoothStep(run: number, dt: number): number
	return if dt < MapReadyRules.SMOOTH_DT then run + 1 else 0
end

-- An answer counts only for the load it names (a whole number the server issued and is still waiting on).
function MapReadyRules.validAck(token: any, waiting: { [number]: any }): boolean
	return type(token) == "number" and token == math.floor(token) and waiting[token] ~= nil
end

return MapReadyRules
