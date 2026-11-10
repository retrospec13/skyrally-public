--!strict
-- Storm race v2 flow rules (economy v3 phase 5; SKYRALLY_ECONOMY_V3 section 3, owner ruling venue B; docs/design/STORM_RACE_V2.md).
-- Pure: no services, no clock (callers pass UTC seconds), specced in tools/tests/storm_flow_spec.luau. The server side is
-- server/StormRace; the popup and board row are client/StormRaceClient.
--   * schedule: a storm race starts every PERIOD seconds on the UTC clock (:00 / :30), its JOIN window opens ANNOUNCE
--     seconds before and closes LATE seconds after the start.
--   * fields: joiners are slotted into fields of FIELD in join order (a full field opens the next); bots fill each field
--     at the start (the storm dragon is one of the bots).
--   * late join (inside the window, after the start): the last field if its grid still forms and has room, else a new field.
--   * dragon: a racer beat the storm dragon when the dragon was in the field and had not crossed the line before him.
--   * flags: RACE_V2 needs PER_GROUP; without it the old Storm Cup runs and the server warns.
local StormFlowRules = {}

export type Slot = {
	index: number, -- UTC slot number (startsAt / period); a Studio QA slot is negative
	startsAt: number,
	announceAt: number,
	lateUntil: number,
	forced: boolean?,
}

export type Phase = "idle" | "announce" | "late"

-- The slot whose start is `index * period`.
function StormFlowRules.slot(index: number, period: number, announce: number, late: number): Slot
	local startsAt = index * period
	return { index = index, startsAt = startsAt, announceAt = startsAt - announce, lateUntil = startsAt + late }
end

-- Where the schedule is at UTC time t: "announce" (JOIN window before the start), "late" (JOIN window after the start) or
-- "idle"; the slot returned is the one that window belongs to (idle: the next one).
function StormFlowRules.phaseAt(t: number, period: number, announce: number, late: number): (Phase, Slot)
	local cur = math.floor(t / period)
	local here = StormFlowRules.slot(cur, period, announce, late)
	if t < here.lateUntil then
		return "late", here
	end
	local nxt = StormFlowRules.slot(cur + 1, period, announce, late)
	if t >= nxt.announceAt then
		return "announce", nxt
	end
	return "idle", nxt
end

-- Studio QA: a slot that announces now and starts `window` seconds from now.
function StormFlowRules.qaSlot(t: number, window: number, late: number, seq: number): Slot
	local startsAt = t + window
	return { index = -seq, startsAt = startsAt, announceAt = t, lateUntil = startsAt + late, forced = true }
end

-- The QA window clamp (StormQAWindow): nil or junk = the normal announce length.
function StormFlowRules.qaWindow(v: any, default: number, lo: number, hi: number): number
	if type(v) ~= "number" or v ~= v then
		return default
	end
	return math.clamp(math.floor(v), lo, hi)
end

------------------------------------------------------------------------------------------------------------ fields

export type Fields = { { number } } -- user ids per field, in join order

-- The field holding this user, or nil.
function StormFlowRules.fieldOf(fields: Fields, userId: number): number?
	for i, f in fields do
		if table.find(f, userId) then
			return i
		end
	end
	return nil
end

-- Slots a joiner: already in = his field; else the last field when it has room, else a new field. Returns the field
-- number and whether it was a new join.
function StormFlowRules.join(fields: Fields, userId: number, size: number): (number, boolean)
	local have = StormFlowRules.fieldOf(fields, userId)
	if have then
		return have, false
	end
	local last = fields[#fields]
	if last == nil or #last >= size then
		last = {}
		table.insert(fields, last)
	end
	table.insert(last, userId)
	return #fields, true
end

-- Takes a joiner out (LEAVE before the start, or he left the server). The fields keep their order; an emptied field is
-- dropped at the start (compact). Returns the field he was in.
function StormFlowRules.leave(fields: Fields, userId: number): number?
	local i = StormFlowRules.fieldOf(fields, userId)
	if i then
		local f = fields[i]
		table.remove(f, table.find(f, userId) :: number)
	end
	return i
end

-- The fields that go at the start: empty ones dropped, then refilled in join order so every field but the last is full
-- (a LEAVE in an early field never leaves a hole while a later field has players).
function StormFlowRules.compact(fields: Fields, size: number): Fields
	local out: Fields = {}
	for _, f in fields do
		for _, id in f do
			StormFlowRules.join(out, id, size)
		end
	end
	return out
end

function StormFlowRules.total(fields: Fields): number
	local n = 0
	for _, f in fields do
		n += #f
	end
	return n
end

-- Human seats per field: the field size minus the storm dragon's seat. A field of 8 racers is at most 7 humans, so the
-- dragon races in EVERY field (owner: "storm boss in every field"; 8 humans would leave RaceInstance.botsNeeded 0 bots).
function StormFlowRules.seats(size: number): number
	return math.max(1, math.floor(size) - 1)
end

-- Bots per field (the storm dragon counts as one of them): the field size minus its humans.
function StormFlowRules.botsFor(fields: Fields, size: number): { number }
	local out: { number } = {}
	for i, f in fields do
		out[i] = math.max(0, size - #f)
	end
	return out
end

-- A JOIN after the start, inside the window. last: the newest launched field (its humans and whether its grid still forms,
-- i.e. a seat can be taken), nil when none launched. "last" = take a seat there, "new" = open a new field.
function StormFlowRules.lateJoin(last: { count: number, open: boolean }?, size: number): "last" | "new"
	if last and last.open and last.count < size then
		return "last"
	end
	return "new"
end

-- The track for one field: the cup rotation from the slot's own track, skipping tracks that are not mounted or already
-- race (one map per track: two groups never share pods). Field 1 gets the slot's track when free, field 2 the next, ...
function StormFlowRules.trackFor(slotIndex: number, tracks: { string }, usable: (trackId: string) -> boolean, taken: { [string]: boolean }): string?
	local n = #tracks
	if n == 0 then
		return nil
	end
	local base = slotIndex % n
	for i = 0, n - 1 do
		local id = tracks[((base + i) % n) + 1]
		if not taken[id] and usable(id) then
			return id
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------ dragon

-- At a human's finish (finishOrder = the entries before his): he beat the storm dragon when the dragon raced in this field
-- and no boss entry crossed before him. Other bots ahead do not matter (that is beatBoss's rule, not this one).
function StormFlowRules.beatDragon(finishOrderBefore: { any }, dragonInField: boolean): boolean
	if not dragonInField then
		return false
	end
	for _, e in finishOrderBefore do
		if type(e) == "table" and e.isBoss == true then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------------------------------------------ flags

-- Which storm flow this server runs: "v2" (per-group storm race), "legacy" (the whole-server Storm Cup, RACE_V2 off) or
-- "fallback" (RACE_V2 on without PER_GROUP: the old Storm Cup, and the server warns).
function StormFlowRules.flow(raceV2: boolean, perGroup: boolean): "v2" | "legacy" | "fallback"
	if not raceV2 then
		return "legacy"
	end
	return if perGroup then "v2" else "fallback"
end

StormFlowRules.FALLBACK_WARNING =
	"[SkyRally][STORM_RACE] StormConfig.RACE_V2 is on but RaceFlowRules.PER_GROUP is off: storm race v2 needs per-group races; running the old Storm Cup"

-- Countdown text m:ss (never negative).
function StormFlowRules.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return StormFlowRules
