--!strict
-- Track trigger contract (L40, audit streaming_perf). The map builders (server/kit/Gameplay) tag every booster ring, ground
-- boost pad and item pod with TAG; the client vehicle controllers read the tagged set (client/TriggerIndex) instead of
-- walking the whole map with GetDescendants, which also keeps working once StreamingEnabled loads parts piecemeal.
-- Specced in tools/tests/probe_spec.luau.
local TriggerRules = {}

TriggerRules.TAG = "SkyRallyTrigger"

-- A part is a trigger when it carries a TriggerType attribute or is an item pod spawn (the legacy DINO-4 contract).
function TriggerRules.isTrigger(triggerType: any, itemPodSpawn: any): boolean
	return triggerType ~= nil or itemPodSpawn == true
end

-- A boost trigger that belongs to an alternate line (a ring on the ISLAND-2 Alt2 cliff line) carries the line's id in LINE_ATTR.
-- Players take it like any ring when they drive the line; the station-rail bots never ride an alternate, and projecting such a
-- ring onto the main spline would hand them a boost the main route does not have, so they skip it.
TriggerRules.LINE_ATTR = "AltLine"

function TriggerRules.botBoost(triggerType: any, altLine: any): boolean
	if triggerType ~= "BoosterRing" and triggerType ~= "GroundBoostPad" then
		return false
	end
	return not (type(altLine) == "string" and altLine ~= "")
end

return TriggerRules
