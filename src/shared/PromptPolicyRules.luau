--!strict
-- Purchase prompt policy (TEST_LIST_LAUNCH L59; docs/PUBLIC_RELEASE.md C5). Pure: no Instances, no clock of its own,
-- specced in tools/tests/prompt_policy_spec.luau. server/Economy's promptGate is the only path that opens a Roblox
-- purchase prompt (PromptProductPurchase / PromptGamePassPurchase), and it asks this module first:
--   * the player's first JOIN_GRACE_SECONDS after joining                   -> "just joined"
--   * a map switch (curtain, then straight into the grid)                    -> "loading a map"
--   * a due Storm Cup (the hub is about to be pulled into a race)            -> "Storm Cup starting"
--   * the grid hold before GO in a boss race or rematch (boss intro sweep)   -> "boss intro"
--   * the grid hold before GO in any other mode (3-2-1 countdown)            -> "countdown"
--   * any non-hub mode until this player has finished                        -> "racing (<mode>)"
-- Per group (RaceFlowRules.PER_GROUP, systems audit v32 T1-7) the race half is read from the player's own race
-- (sceneState: RaceAttr.get on his RaceInstance root), never from workspace, which holds the hub's values. On top:
--   * seated in an instance whose root is missing or still loading           -> "loading a map"
-- Waiting in an arch lobby (LobbyArch) does not block, exactly like the single-race lobby: a RACING arch queues
-- him for the next race, which can be a whole race away.
-- Anything else (hub, results screen after the player's own finish) returns nil: a prompt may open. There is no
-- auto-prompt anywhere; prompts only follow a Garage tap, and the gate still applies to it.

local PromptPolicyRules = {}

PromptPolicyRules.JOIN_GRACE_SECONDS = 10

export type State = {
	sinceJoin: number?, -- seconds since this player joined (server clock); nil = unknown, treated as just joined
	trackSwitching: boolean?, -- workspace.TrackSwitching
	stormCupState: string?, -- workspace.StormCupState
	now: number?, -- workspace:GetServerTimeNow()
	goTime: number?, -- workspace.RaceGoTime
	mode: string?, -- workspace.RaceMode ("hub", "race", "boss", "rematch", ...)
	finished: boolean?, -- player.RaceFinished
	-- Per group only (nil on the single-race path):
	seated: boolean?, -- the player has a RaceInstanceId
	instanceState: string?, -- that instance root's State ("loading", "grid", ...); nil when the root is missing
}

-- What sceneState reads; the live wiring (server/Economy liveBusy) passes workspace / RaceAttr / Player readers.
export type Reads = {
	perGroup: boolean, -- RaceFlowRules.PER_GROUP
	world: (string) -> any, -- workspace attribute
	race: (string) -> any, -- RaceAttr.get(name, player): this player's race (workspace on the single path)
	player: (string) -> any, -- player attribute
	instanceState: () -> any, -- the State attribute of the player's instance root, nil when there is no root
	now: () -> number, -- workspace:GetServerTimeNow()
}

local BOSS_MODES = { boss = true, rematch = true }

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- The join half: "just joined" inside the grace window (default JOIN_GRACE_SECONDS), else nil. A missing or bad
-- sinceJoin counts as just joined.
function PromptPolicyRules.joinBlock(sinceJoin: number?, grace: number?): string?
	local g = if finite(grace) then grace :: number else PromptPolicyRules.JOIN_GRACE_SECONDS
	if not finite(sinceJoin) or (sinceJoin :: number) < g then
		return "just joined"
	end
	return nil
end

-- Builds the scene State for one player. RaceMode and RaceGoTime come through r.race (his instance per group);
-- TrackSwitching and StormCupState are server-wide (workspace).
function PromptPolicyRules.sceneState(r: Reads): State
	local goTime = r.race("RaceGoTime")
	local hasGo = finite(goTime)
	local st: State = {
		trackSwitching = r.world("TrackSwitching") == true,
		stormCupState = r.world("StormCupState"),
		now = if hasGo then r.now() else nil,
		goTime = if hasGo then goTime else nil,
		mode = r.race("RaceMode"),
		finished = r.player("RaceFinished") == true,
	}
	if r.perGroup then
		local seated = r.player("RaceInstanceId") ~= nil
		st.seated = seated
		if seated then
			local state = r.instanceState()
			st.instanceState = if type(state) == "string" then state else nil
		end
	end
	return st
end

-- The scene half: map switch, Storm Cup due, boss intro / countdown hold, racing until this player's finish.
function PromptPolicyRules.sceneBlock(s: State): string?
	if s.trackSwitching == true then
		return "loading a map"
	end
	if s.stormCupState == "due" then
		return "Storm Cup starting"
	end
	if s.seated == true and (s.instanceState == nil or s.instanceState == "loading") then
		return "loading a map"
	end
	local mode = if type(s.mode) == "string" then s.mode else ""
	if finite(s.goTime) and (not finite(s.now) or (s.now :: number) < (s.goTime :: number)) then
		return if BOSS_MODES[mode] then "boss intro" else "countdown"
	end
	if mode ~= "" and mode ~= "hub" and s.finished ~= true then
		return "racing (" .. mode .. ")"
	end
	return nil
end

-- Why a purchase prompt must not open for this state, or nil when it may.
function PromptPolicyRules.blockReason(s: State): string?
	return PromptPolicyRules.joinBlock(s.sinceJoin) or PromptPolicyRules.sceneBlock(s)
end

function PromptPolicyRules.allowed(s: State): boolean
	return PromptPolicyRules.blockReason(s) == nil
end

return PromptPolicyRules
