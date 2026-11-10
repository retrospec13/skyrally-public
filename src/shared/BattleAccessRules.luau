--!strict
-- Battle access (pick board 2026-10-20): a zone's battle opens once the player has finished that zone's map race (any
-- placing) or found its hidden key (Progression.battleAccess). Pure helpers, no services, no yields; the Lune spec is
-- tools/tests/battle_access_spec.luau.
--  * BattlesOpen: player attribute the server sets from the profile (SaveService.replicate), "DINO,SNOW" in chain order.
--    Clients read it for the results card button and the first-unlock explainer; the server still re-checks every request.
--  * BattleIntroSeen: player attribute (profile.settings.battleIntro) so the 3-line explainer shows once per account.
--  * The results card's BATTLE button sends RequestBattle; the SERVER routes it (cardRoute): solo it loads the battle straight
--    from the finished race; with 2+ humans it is the HUB vote and the battle request waits on the server until the hub has
--    loaded (pendingStep), then goes through the board's lobby path. V9: the old client-timed hub trip plus a second
--    request lost the battle (a plain race of that map started instead).
--  * The Adventure board names a shut battle on its row (boardLockLine), not only after a click on the dim button.
local Progression = require(script.Parent:WaitForChild("Progression"))

local BattleAccessRules = {}

BattleAccessRules.ATTR = "BattlesOpen"
BattleAccessRules.INTRO_ATTR = "BattleIntroSeen"
BattleAccessRules.INTRO_FLAG = "battleIntro" -- profile.settings key
-- Seconds a pressed BATTLE stays armed while a HUB vote waits for the other racers.
BattleAccessRules.PENDING_SECONDS = 45

-- Race modes whose end-of-race card offers BATTLE (never the battle itself, the hub, or a Storm race).
BattleAccessRules.CARD_MODES = table.freeze({
	race = true, quickrace = true, timetrial = true, boss = true, coin = true, rematch = true,
}) :: { [string]: boolean }

function BattleAccessRules.encode(zones: { string }): string
	return table.concat(zones, ",")
end

function BattleAccessRules.decode(raw: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if type(raw) ~= "string" then
		return set
	end
	for zone in string.gmatch(raw, "[^,]+") do
		if Progression.ZONE_TRACK[zone] ~= nil then
			set[zone] = true
		end
	end
	return set
end

function BattleAccessRules.count(set: { [string]: boolean }): number
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

-- Board lock line for a battle that is still shut: "Finish <map> to unlock".
function BattleAccessRules.lockReason(mapName: string): string
	return "Finish " .. mapName .. " to unlock"
end

-- Whether the end-of-race card shows BATTLE: this map's zone has a battle, the player may start it, and the race that just
-- ended is a standard kind. `open` is the decoded BattlesOpen set.
function BattleAccessRules.cardButton(raceMode: any, trackId: any, open: { [string]: boolean }): boolean
	if type(raceMode) ~= "string" or BattleAccessRules.CARD_MODES[raceMode] ~= true or type(trackId) ~= "string" then
		return false
	end
	local info = Progression.TRACKS[trackId]
	return info ~= nil and info.hasKey and info.zone ~= nil and open[info.zone] == true
end

-- The first-unlock explainer is due when any battle is open and the account has not seen it.
-- `seen` is the BattleIntroSeen attribute: nil while the profile has not loaded (never due), then false / true.
function BattleAccessRules.introDue(open: { [string]: boolean }, seen: any): boolean
	return seen == false and BattleAccessRules.count(open) > 0
end

-- Board row sub-label for a zone whose battle is listed but shut: "BATTLE: Finish Molten Cavern to unlock"; nil when the
-- row lists no battle, the battle is open, or the reason is not the unlock line. `modes` is the row's PortalStates modes list.
function BattleAccessRules.boardLockLine(modes: any): string?
	if type(modes) ~= "table" then
		return nil
	end
	for _, md in modes do
		if type(md) == "table" and md.mode == "battle" then
			-- Only the unlock reason (lockReason): not "no profile" while the save loads, nor a shut zone's token line.
			if md.open == true or type(md.why) ~= "string" or not string.match(md.why, "^Finish .+ to unlock$") then
				return nil
			end
			return "BATTLE: " .. md.why
		end
	end
	return nil
end

-- What the server does with the card's RequestBattle. `mode` is the player's RaceMode, `group` true with 2+ humans
-- (the HUB vote), `perGroup` the per-group engine, `switching` a map load in progress. "now": load the battle at once
-- (solo after a race, or already in the hub). "hub": cast the HUB vote and keep the battle pending on the server until
-- the hub has loaded. "busy": a load runs, try again. "refused".
-- Per group (systems audit v32 T0-2: battles run per RaceInstance) the hub never loads, so nothing can wait for it: a
-- player on the plaza joins that arch's battle lobby ("now"), a player still in a race picks BATTLE on the Adventure
-- board once he is back ("refused" with that hint).
function BattleAccessRules.cardRoute(mode: any, group: boolean, perGroup: boolean, switching: boolean): string
	if perGroup then
		return if mode == "hub" then "now" else "refused"
	end
	if switching then
		return "busy"
	end
	if mode == "hub" then
		return "now"
	end
	if type(mode) ~= "string" or BattleAccessRules.CARD_MODES[mode] ~= true then
		return "refused"
	end
	return if group then "hub" else "now"
end

-- After BATTLE was pressed at `pressedAt`: "go" once the hub is reached in time, "drop" when it lapsed, "wait" otherwise.
-- raceMode is the player's current RaceMode.
function BattleAccessRules.pendingStep(pressedAt: number, now: number, raceMode: any): string
	if now - pressedAt > BattleAccessRules.PENDING_SECONDS then
		return "drop"
	end
	if raceMode == "hub" then
		return "go"
	end
	return "wait"
end

-- Widths for the finish card's button row (fractions of the card minus its 28 px padding, `gap` px between): FLY AGAIN and
-- HUB as before, or FLY AGAIN, BATTLE and HUB when the battle is open. Returns { again, battle, hub } scale weights summing to 1.
function BattleAccessRules.cardWeights(battle: boolean): { number }
	if battle then
		return { 0.36, 0.32, 0.32 }
	end
	return { 0.64, 0, 0.36 }
end

return BattleAccessRules
