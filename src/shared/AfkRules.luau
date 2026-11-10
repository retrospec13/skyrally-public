--!strict
-- AFK rules (social lane). Pure: no Instances, no clock of its own, specced in tools/tests/afk_spec.luau. The server
-- (server/AfkService) owns the clock and the Roblox side; the client (client/AfkBeat) only reports that its player used an
-- input, at most every BEAT_SECONDS. The server decides who is AFK, from its own clock.
--
-- States, by seconds since the player's last input:
--   active   under IDLE_SECONDS
--   afk      IDLE_SECONDS or more: a small "AFK" tag over the vehicle, and the player no longer counts as a human the
--            server waits for (FLY AGAIN / HUB votes, the portal lobby's group rule). Any input clears it at once.
--   long     IDLE_SECONDS + LONG_EXTRA_SECONDS or more. Same effects as afk; the state exists so logs and a future
--            policy can tell a short stand-up from a walked-away player. This game never kicks anyone for it (Roblox's own
--            idle timeout does that in the hub). In a race the AFK racer is not touched either: he finishes as DNF when the
--            DNF deadline passes, exactly as before (TrackDirector.stepRaceEnd).
local AfkRules = {}

AfkRules.IDLE_SECONDS = 45 -- no input for this long during a race (or in the hub) marks a player AFK
AfkRules.LONG_EXTRA_SECONDS = 180 -- three more minutes idle: state "long"
AfkRules.BEAT_SECONDS = 5 -- the client sends an input heartbeat at most this often
AfkRules.MIN_BEAT_GAP = 2 -- the server ignores a second heartbeat from one player inside this many seconds
AfkRules.TAG_TEXT = "AFK"

export type State = "active" | "afk" | "long"

-- Seconds since the last input -> state. A negative or NaN idle (clock trouble) counts as active.
function AfkRules.state(idleSeconds: number): State
	if idleSeconds ~= idleSeconds or idleSeconds < AfkRules.IDLE_SECONDS then
		return "active"
	end
	if idleSeconds >= AfkRules.IDLE_SECONDS + AfkRules.LONG_EXTRA_SECONDS then
		return "long"
	end
	return "afk"
end

function AfkRules.isAfk(state: State): boolean
	return state ~= "active"
end

-- Humans the flow waits for: everyone who is not AFK, plus an AFK player who has already voted (his vote stands, so he
-- still counts toward "every human voted the same way"). isAfk and hasVoted take the player (any key type).
function AfkRules.effectiveHumans(players: { any }, isAfk: (any) -> boolean, hasVoted: (any) -> boolean): number
	local n = 0
	for _, p in players do
		if not isAfk(p) or hasVoted(p) then
			n += 1
		end
	end
	return n
end

export type Tracker = {
	join: (key: any, now: number) -> (),
	leave: (key: any) -> (),
	-- An accepted input heartbeat (or any validated request from the player). Returns false when it was rate limited.
	beat: (key: any, now: number) -> boolean,
	-- Unconditional activity (the player voted, picked a race). Always resets the idle clock.
	touch: (key: any, now: number) -> (),
	-- Time that does not count as idle for anyone (a map switch, the curtain): pushes every idle clock forward.
	hold: (now: number) -> (),
	-- Re-evaluates everyone against `now`; returns the players whose state changed as { key, from, to } rows.
	update: (now: number) -> { { key: any, from: State, to: State } },
	state: (key: any) -> State,
	isAfk: (key: any) -> boolean,
	idle: (key: any, now: number) -> number,
}

function AfkRules.newTracker(): Tracker
	local lastInput: { [any]: number } = {}
	local lastBeat: { [any]: number } = {}
	local states: { [any]: State } = {}
	local tracker = {} :: Tracker

	function tracker.join(key, now)
		lastInput[key] = now
		lastBeat[key] = nil
		states[key] = "active"
	end

	function tracker.leave(key)
		lastInput[key] = nil
		lastBeat[key] = nil
		states[key] = nil
	end

	function tracker.touch(key, now)
		if lastInput[key] ~= nil then
			lastInput[key] = math.max(lastInput[key], now)
		end
	end

	function tracker.beat(key, now)
		if lastInput[key] == nil then
			return false
		end
		local prev = lastBeat[key]
		if prev ~= nil and now - prev < AfkRules.MIN_BEAT_GAP then
			return false
		end
		lastBeat[key] = now
		lastInput[key] = math.max(lastInput[key], now)
		return true
	end

	function tracker.hold(now)
		for key, t in lastInput do
			if t < now then
				lastInput[key] = now
			end
		end
	end

	function tracker.update(now)
		local changes: { { key: any, from: State, to: State } } = {}
		for key, t in lastInput do
			local to: State = AfkRules.state(now - t)
			local from: State = states[key] or "active"
			if to ~= from then
				states[key] = to
				table.insert(changes, { key = key, from = from, to = to })
			end
		end
		return changes
	end

	function tracker.state(key)
		return states[key] or "active"
	end

	function tracker.isAfk(key)
		return AfkRules.isAfk(states[key] or "active")
	end

	function tracker.idle(key, now)
		local t = lastInput[key]
		return if t == nil then 0 else math.max(0, now - t)
	end

	return tracker
end

return AfkRules
