--!strict
-- The race rival's marker and sting rules (UI polish: the red RIVAL pill is gone). Pure: no Instances, no clock; specced
-- in tools/tests/rival_ui_spec.luau. client/RivalBubbles draws the marker (accent-coloured name + a glyph, never a
-- pill over text) and plays the sting; server/RaceManager publishes the player attribute RivalAhead that drives it.
local RivalRules = {}

RivalRules.GLYPH = "\u{1F525}" -- flame; Roblox's emoji fallback draws it next to GothamBold / GothamBlack text
RivalRules.STING_GAP = 2.5 -- seconds between stings, so a wheel-to-wheel scrap does not chatter

-- "FLAME NAME" (the marker text everywhere: speech tab, world flag, results row).
function RivalRules.marked(name: string): string
	return RivalRules.GLYPH .. " " .. name
end

-- RivalAhead flips are the whole signal. prev / now: nil (no rival or race not running) | true (rival ahead) | false
-- (player ahead). Returns "passed" when the player just took the lead over the rival, "passedBy" when the rival just
-- took it, else nil. lastAt is the clock of the last sting.
function RivalRules.sting(prev: boolean?, now: boolean?, clock: number, lastAt: number): string?
	if prev == nil or now == nil or prev == now then
		return nil
	end
	if clock - lastAt < RivalRules.STING_GAP then
		return nil
	end
	return if now then "passedBy" else "passed"
end

-- Results card: where the rival sits. standings rows: {rank, name, isPlayer}. Returns the 1-based row index of the
-- rival bot (by roster name), or nil when it is not on the card or the card has no player row.
function RivalRules.rivalRow(standings: any, rivalName: string): number?
	if type(standings) ~= "table" then
		return nil
	end
	local rivalIdx: number? = nil
	local playerSeen = false
	for i, row in standings do
		if type(row) == "table" then
			if row.isPlayer == true then
				playerSeen = true
			elseif rivalIdx == nil and row.name == rivalName then
				rivalIdx = i
			end
		end
	end
	return if playerSeen then rivalIdx else nil
end

return RivalRules
