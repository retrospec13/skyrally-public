--!strict
-- Studio-only QA hooks for the systems verification campaign (docs/VERIFY_CAMPAIGN_V33.md TG-1..TG-6), pure rules (no
-- Roblox globals; tools/tests/qa_hooks_spec.luau runs it under Lune). Every function takes `isStudio` first and answers
-- "no effect" when it is false: a live server never reads a QA attribute, whatever is set on workspace. The wiring is in
-- server/SaveService (TG-1, TG-4), server/LiveOps (TG-2), server/QAClock (TG-6) and server/QAMultiplayer (TG-3).
--   TG-1  workspace QASaveFault = "load" | "save" | "none"   (+ optional QASaveFaultCount = N: fail N store calls, then clear)
--   TG-4  workspace QASaveAs = <number>   the NEXT player to load gets that stored profile id (one-shot, then cleared)
--   TG-2  workspace QALiveOpsMemory = true   LiveOps uses an in-memory flag row (it also does when the Studio probe fails)
--   TG-6  workspace QAUtcAt = <epoch seconds>   the economy and the Storm Cup read UTC as that moment, then it runs on
--         workspace QATimingDump = true         prints the schedule/stock signature ([SkyRally][QATIME]); see compareServers
local QAHooksRules = {}

QAHooksRules.FAULT_ATTR = "QASaveFault"
QAHooksRules.FAULT_COUNT_ATTR = "QASaveFaultCount"
QAHooksRules.SAVE_AS_ATTR = "QASaveAs"
QAHooksRules.LIVEOPS_MEMORY_ATTR = "QALiveOpsMemory"
QAHooksRules.UTC_ATTR = "QAUtcAt"
QAHooksRules.DUMP_ATTR = "QATimingDump"
QAHooksRules.FAULT_VALUES = table.freeze({ "load", "save", "none" })

-- TG-1: does the store call of kind `op` ("load" | "save") fail now?
function QAHooksRules.saveFaultHits(isStudio: boolean, attr: any, op: string): boolean
	return isStudio == true and type(attr) == "string" and attr == op and (op == "load" or op == "save")
end

-- A positive whole count, or nil (no count: the fault stays until the attribute is cleared).
function QAHooksRules.faultCount(isStudio: boolean, attr: any): number?
	if isStudio ~= true or type(attr) ~= "number" or attr ~= attr or attr < 1 or attr > 1000 then
		return nil
	end
	return math.floor(attr)
end

-- TG-4: the stored profile id the next load uses instead of the player's own UserId, or nil.
function QAHooksRules.saveAs(isStudio: boolean, attr: any): number?
	if isStudio ~= true or type(attr) ~= "number" or attr ~= attr or attr % 1 ~= 0 or attr == 0 or math.abs(attr) > 2 ^ 52 then
		return nil
	end
	return attr
end

-- TG-6: the QA UTC clock. `setClock` = os.clock() when QAUtcAt was last seen changed; real = the real UTC reading.
function QAHooksRules.utcNow(isStudio: boolean, attr: any, setClock: number?, clockNow: number, real: number): number
	if isStudio ~= true or type(attr) ~= "number" or attr ~= attr or attr < 0 or setClock == nil then
		return real
	end
	return attr + math.max(0, clockNow - setClock)
end

-- TG-6: what two servers must agree on at UTC time t: the next Storm Cup, the shop window with its stock list and the
-- Daily Deal. `rules` is an EconomyRules instance. Returns a flat table of scalars plus one signature string.
function QAHooksRules.signature(rules: any, t: number): { [string]: any }
	local cup = rules.stormCupNext(t)
	local shop = rules.shopAt(t)
	local parts = {}
	for _, s in shop.slots do
		table.insert(parts, string.format("%s=%s@%d/%s", s.slot, s.key, s.price, tostring(s.stock)))
	end
	local sig = {
		cupIndex = cup.index,
		cupStartsAt = cup.startsAt,
		cupTrack = cup.trackId,
		cupModifier = cup.modifier,
		window = shop.window,
		windowEndsAt = shop.endsAt,
		day = shop.day,
		dealEndsAt = shop.dealEndsAt,
		slots = table.concat(parts, ";"),
	}
	sig.signature = string.format("cup=%d/%s/%s window=%d day=%d slots=%s", cup.index, cup.trackId, cup.modifier, shop.window, shop.day, sig.slots)
	return sig
end

-- Two servers whose clocks differ by `skew` seconds read the same schedule unless a boundary falls between them.
-- Returns same (every field equal) and the names of the fields that differ.
function QAHooksRules.compareServers(rules: any, tA: number, tB: number): (boolean, { string })
	local a, b = QAHooksRules.signature(rules, tA), QAHooksRules.signature(rules, tB)
	local diffs = {}
	for k, v in a do
		if k ~= "signature" and b[k] ~= v then
			table.insert(diffs, k)
		end
	end
	table.sort(diffs)
	return #diffs == 0, diffs
end

return QAHooksRules
