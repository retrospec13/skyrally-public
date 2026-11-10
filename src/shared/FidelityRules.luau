--!strict
-- Pure rules for the L60 fidelity fixes (docs/FIDELITY.md M-1, M-2, M-5). No services, no yields: SaveService,
-- TrackFlow, HubBossPads, CarController, AIRacers and the Lune specs all read one definition.

local FidelityRules = {}

-- M-1 (J3): the completion screen. Progression.completion builds the numbers and the exact text; this module formats the
-- compact board line and packs what one player attribute carries.
export type CompletionLike = {
	tokens: number,
	tokensTotal: number,
	keys: number,
	keysTotal: number,
	bossFragments: number,
	bossFragmentsTotal: number,
	battleFragments: number,
	battleFragmentsTotal: number,
	finalBoss: boolean,
	complete: boolean,
	text: string,
	roadmap: string,
}

export type CompletionInfo = {
	line: string,
	complete: boolean,
	text: string,
	roadmap: string,
}

FidelityRules.COMPLETION_ATTRIBUTE = "CompletionInfo"

-- "3/14 tokens | 1/4 keys | 0/4 boss | 0/4 battle | final boss: not yet"
function FidelityRules.progressLine(c: CompletionLike): string
	return string.format(
		"%d/%d tokens | %d/%d keys | %d/%d boss | %d/%d battle | final boss: %s",
		c.tokens,
		c.tokensTotal,
		c.keys,
		c.keysTotal,
		c.bossFragments,
		c.bossFragmentsTotal,
		c.battleFragments,
		c.battleFragmentsTotal,
		if c.finalBoss then "beaten" else "not yet"
	)
end

-- One attribute string: line 1 is always the short line; once complete, line 2 is the full text and line 3 the roadmap.
function FidelityRules.encode(c: CompletionLike): string
	local out = FidelityRules.progressLine(c)
	if c.complete then
		out ..= "\n" .. c.text .. "\n" .. c.roadmap
	end
	return out
end

function FidelityRules.decode(raw: any): CompletionInfo?
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local parts = string.split(raw, "\n")
	local complete = #parts >= 3
	return {
		line = parts[1],
		complete = complete,
		text = if complete then parts[2] else "",
		roadmap = if complete then parts[3] else "",
	}
end

-- M-2 (C11): hub-boss timed pads. A pad is on for `onFor` seconds at the start of each `period`, shifted by `phase`.
export type TimedPad = { name: string, period: number?, onFor: number?, phase: number? }

function FidelityRules.padLive(serverTime: number, pad: TimedPad): boolean
	local period = pad.period or 0
	if period <= 0 then
		return true
	end
	local onFor = pad.onFor or period
	local t = (serverTime - (pad.phase or 0)) % period
	return t < onFor
end

-- nil (attribute never set) means live, so every map without timed pads is unchanged.
function FidelityRules.padIsLive(attr: any): boolean
	return attr ~= false
end

FidelityRules.PAD_LOOP_HZ = 10

-- M-5 (L7): optional per-track bot pace multiplier, default 1.0. Anything that is not a finite positive number is 1.0.
FidelityRules.BOT_PACE_ATTRIBUTE = "BotPace"

function FidelityRules.botPace(value: any): number
	if type(value) == "number" and value == value and value > 0 and value < math.huge then
		return value
	end
	return 1.0
end

return FidelityRules
