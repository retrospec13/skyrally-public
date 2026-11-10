--!strict
-- The HUD lap chip's text and its FINAL LAP! state (client/RaceUI), pure: no services, no yields. Lune spec:
-- tools/tests/lap_chip_spec.luau.
-- V9 (Studio, one session, several races): the chip read "FINAL LAP!" from 0:05 into every race after the first. RaceUI
-- built "LAP n/N" into the same cache it then compared the result against, so a rebuilt lap text always "matched" and was
-- never written; only "FINAL LAP!" (which bypassed the cache) ever reached the label, and it stayed there into the next
-- race. step() keeps the text it last returned apart from the text it builds, and a lap that goes down (a new race) or
-- below the last lap ends the final-lap state.
local MusicRules = require(script.Parent:WaitForChild("MusicRules"))

local LapChipRules = {}

LapChipRules.FINAL_TEXT = "FINAL LAP!"
LapChipRules.FINAL_FLASH_S = 2.5 -- the chip reads FINAL LAP! this long, then "LAP 3/3" (in red while the state holds)

export type State = {
	shown: string, -- the text step() last returned (what the label shows)
	prevLap: number?,
	finalOn: boolean,
	finalUntil: number,
}

function LapChipRules.new(): State
	return { shown = "", prevLap = nil, finalOn = false, finalUntil = 0 }
end

function LapChipRules.lapText(lap: number, total: number): string
	return string.format("\u{1F3C1} LAP %d/%d", lap, total) -- flag glyph before the lap row (Mario Kart Tour reference)
end

-- One HUD frame. Returns the chip text, whether it differs from the last returned text (write the label only then), and
-- the lap event of this frame: "final" (entered the last lap: swing, glow, hero banner), "reset" (the final-lap state
-- ended: a new race or a lap below the last), or nil.
function LapChipRules.step(s: State, lap: number, total: number, now: number, mode: any, finished: any): (string, boolean, string?)
	local event: string? = nil
	if s.prevLap ~= lap then
		local prev = s.prevLap
		if s.finalOn and (lap < total or (prev ~= nil and lap < prev)) then
			s.finalOn = false
			s.finalUntil = 0
			event = "reset"
		end
		if not s.finalOn and MusicRules.isFinalLapEntry(prev, lap, total, mode, finished) then
			s.finalOn = true
			s.finalUntil = now + LapChipRules.FINAL_FLASH_S
			event = "final"
		end
		s.prevLap = lap
	end
	local text = if s.finalOn and now < s.finalUntil then LapChipRules.FINAL_TEXT else LapChipRules.lapText(lap, total)
	local changed = text ~= s.shown
	s.shown = text
	return text, changed, event
end

return LapChipRules
