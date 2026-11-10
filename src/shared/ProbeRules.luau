--!strict
-- Who runs the QA probes (L41/L42, audit streaming_perf). AssetProbe and WorldProbe walk workspace/PlayerGui, call
-- PreloadAsync and print hundreds of lines: fine in Studio and on QA accounts (the L67/L68 published-client evidence
-- path), a needless hitch on a phone player. Specced in tools/tests/probe_spec.luau.
local ProbeRules = {}

-- UserIds of the QA accounts whose published client runs the probes. Add the owner's/testers' ids here.
ProbeRules.QA_USER_IDS = {} :: { number }

function ProbeRules.shouldRun(isStudio: boolean, userId: number, allow: { number }?): boolean
	if isStudio then
		return true
	end
	for _, id in allow or ProbeRules.QA_USER_IDS do
		if id == userId then
			return true
		end
	end
	return false
end

return ProbeRules
