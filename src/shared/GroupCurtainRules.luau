--!strict
-- Per-group loading curtain (economy v3 phase 2b; docs/design/PER_GROUP_RACES.md "Loading curtain"). Pure: no
-- Instances, no clock (the caller passes `now`); specced in tools/tests/group_curtain_spec.luau.
--
-- With RaceFlowRules.PER_GROUP true the server never raises workspace.TrackSwitching, so client/TrackFlow cannot use
-- the single-race curtain signal. Instead the curtain follows the player's OWN seat, level-driven (re-evaluated at 4 Hz
-- and on every seat / Loading / map change, never only on an edge, so a missed edge or a lost iris can not strand it):
--   * up while he is seated in an instance (player RaceInstanceId) whose root has not replicated, whose Loading flag is
--     set (server/RaceGroups load: map build, grid, bots), or whose race map is not in workspace.Maps yet (or says
--     TrackReady = false);
--   * lifted as soon as none of that holds (map built AND grid formed), and at once when the seat goes (the return to
--     the hub, a failed load, a leave): a hub player who joined nothing never sees it;
--   * after CLIENT_TIMEOUT seconds up it lifts anyway ("timedout") and stays lifted until the seat changes; the server
--     watchdog (RaceGroups.LOAD_TIMEOUT, shorter) has by then sent him back to the hub with a message.
-- With PER_GROUP false every step answers nil and the phase stays "lifted": the single path is untouched.
local GroupCurtainRules = {}

-- Server: a group whose map and grid are not up this long after its request goes back to the hub ("GroupLoadFailed").
-- A cold DINO-4 build in Studio is ~18 s (out/mapboot_dino4.json bootSeconds), a MapCache hit ~1.5 s.
GroupCurtainRules.SERVER_LOAD_TIMEOUT = 45
-- Client: the curtain never stays up longer than this, whatever the server does (the server's return lands first).
GroupCurtainRules.CLIENT_TIMEOUT = 55
-- After a lift the iris reveal owns the curtain for 0.6 s + 0.7 s; past this the curtain is forced off if still visible.
GroupCurtainRules.LIFT_GUARD = 1.6
-- Client re-check period (seconds).
GroupCurtainRules.PERIOD = 0.25

export type Phase = "lifted" | "loading" | "timedout"
export type State = { phase: Phase, since: number?, seat: number? }
export type Input = {
	perGroup: boolean,
	seat: number?, -- the player's RaceInstanceId (nil: in the hub, in no instance)
	rootPresent: boolean, -- workspace.RaceInstances.<seat> has replicated
	rootLoading: boolean, -- that root's Loading attribute is true
	mapReady: boolean, -- his race map is in workspace.Maps and not TrackReady = false
	now: number,
}
export type Action = "show" | "lift" | "timeout"

function GroupCurtainRules.new(): State
	return { phase = "lifted", since = nil, seat = nil }
end

-- Whether this input wants the curtain down (before the timeout).
function GroupCurtainRules.wants(input: Input): boolean
	if not input.perGroup or input.seat == nil then
		return false
	end
	return not input.rootPresent or input.rootLoading or not input.mapReady
end

-- Advances the state; returns what the curtain must do now (nil: nothing).
function GroupCurtainRules.step(state: State, input: Input): Action?
	if not input.perGroup then
		return nil
	end
	if state.seat ~= input.seat then
		-- A new seat (or none): a fresh load. A timed-out one never holds the curtain for the next race.
		state.seat = input.seat
		if state.phase == "timedout" then
			state.phase = "lifted"
			state.since = nil
		end
	end
	if state.phase == "timedout" then
		return nil
	end
	local want = GroupCurtainRules.wants(input)
	if want then
		if state.phase == "lifted" then
			state.phase = "loading"
			state.since = input.now
			return "show"
		end
		if input.now - (state.since or input.now) >= GroupCurtainRules.CLIENT_TIMEOUT then
			state.phase = "timedout"
			state.since = nil
			return "timeout"
		end
		return nil
	end
	if state.phase == "loading" then
		state.phase = "lifted"
		state.since = nil
		return "lift"
	end
	return nil
end

-- Whether the curtain is meant to be down now.
function GroupCurtainRules.up(state: State): boolean
	return state.phase == "loading"
end

return GroupCurtainRules
