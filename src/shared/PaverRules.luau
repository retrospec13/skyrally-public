--!strict
-- Paver column layout for kit/Deck.luau (pure; tools/tests/paver_rules_spec.luau). With the defaults (gap 0.30, no stagger) it
-- returns exactly what the deck loop always computed. A style may set paverGap (narrower mortar seam) and paverStagger (studs):
-- the interior column boundaries then jog left / right on alternate segments + rows (a brick bond), so a two-column road never
-- shows one continuous dark centre line. The outer edges, paver heights and the deck envelope never change.
local PaverRules = {}

export type Column = { x: number, w: number }

PaverRules.DEFAULT_GAP = 0.30

-- shift: signed offset (studs) applied to every interior boundary.
function PaverRules.columns(localWidth: number, cols: number, gap: number?, shift: number?): { Column }
	local g = gap or PaverRules.DEFAULT_GAP
	local s = shift or 0
	local paverW = (localWidth - 1.2) / cols
	local out: { Column } = {}
	if s == 0 then
		for c = 1, cols do
			out[c] = { x = (c - (cols + 1) * 0.5) * (paverW + g), w = paverW }
		end
		return out
	end
	local pitch = paverW + g
	local ext = cols * paverW + (cols - 1) * g
	for c = 1, cols do
		local lo = -ext * 0.5 + (c - 1) * pitch + (if c > 1 then s else 0)
		local hi = -ext * 0.5 + (c - 1) * pitch + paverW + (if c < cols then s else 0)
		out[c] = { x = (lo + hi) * 0.5, w = hi - lo }
	end
	return out
end

-- Alternating sign per (segment, row): +1 / -1.
function PaverRules.shiftFor(stagger: number?, segment: number, row: number): number
	if stagger == nil or stagger == 0 then
		return 0
	end
	return if (segment + row) % 2 == 0 then stagger else -stagger
end

return PaverRules
