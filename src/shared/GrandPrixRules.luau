--!strict
-- Grand Prix (v37): a cup of the race tracks the player has unlocked, raced back to back against one bot roster, with
-- Mario Kart points, three classes and a trophy per class. Pure: no Instances, no clock; server/GrandPrix runs it,
-- client/GrandPrixClient draws it, tools/tests/grand_prix_spec.luau pins it.
--
-- Rules (the numbers the orchestrator signs off):
--   * Tracks: the five race tracks in zone order (Progression.RACE_TRACKS). At least MIN_TRACKS must be open for race;
--     the cup runs every open one in zone order ("full"). With more than MIN_TRACKS open the player may pick "short":
--     MIN_TRACKS of them drawn at random, kept in zone order.
--   * Points by finishing place: 15 12 10 8 6 4 2 1 (8 racers); a DNF scores 0. Ties: the better place in the latest race.
--   * Classes: ROOKIE always open; PRO opens with any ROOKIE trophy; MASTER opens with a PRO gold.
--   * Trophy by final overall place: 1st gold (3), 2nd silver (2), 3rd bronze (1), else none (0). The save keeps the best
--     trophy and the best points per class; never lowered.
--   * Payout (Cash, once, at the end of the last race; never multiplied): BONUS[class] x PLACE_SHARE[place] x races / 5,
--     rounded; only when the player finished at least half the cup's races (an AFK cup pays nothing). Quitting or
--     leaving pays nothing beyond what each race already paid.
local GrandPrixRules = {}

GrandPrixRules.TRACKS = { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" } :: { string }
GrandPrixRules.MIN_TRACKS = 3
GrandPrixRules.POINTS = { 15, 12, 10, 8, 6, 4, 2, 1 } :: { number }
GrandPrixRules.CLASSES = { "rookie", "pro", "master" } :: { string }
GrandPrixRules.LABEL = { rookie = "ROOKIE", pro = "PRO", master = "MASTER" } :: { [string]: string }
GrandPrixRules.DESC = {
	rookie = "Relaxed rivals. Learn the cup.",
	pro = "The full-pace field you race every day.",
	master = "Faster bots, sharp starts, no mercy.",
} :: { [string]: string }
GrandPrixRules.TROPHY = { [0] = "NONE", [1] = "BRONZE", [2] = "SILVER", [3] = "GOLD" } :: { [number]: string }

-- What each class does to the bots (server/AIRacers.classTune). pace multiplies the roster pace after the per-race skill
-- roll; rubber scales the catch-up boost ceiling (PlaneConfig.RUBBER_BAND_MAX_BOOST); delay adds seconds to each bot's
-- start delay (BotPaceRules) and delayScale multiplies the rolled one; itemHold is the least time a bot holds an item
-- before it may fire it. PRO is the everyday race exactly (all neutral). The race speed itself is never changed:
-- the server's car / plane speed validation stays as it is.
export type Tune = { pace: number, rubber: number, delay: number, delayScale: number, itemHold: number }
GrandPrixRules.TUNE = {
	rookie = { pace = 0.93, rubber = 0.5, delay = 0.35, delayScale = 1, itemHold = 3.0 },
	pro = { pace = 1.0, rubber = 1.0, delay = 0, delayScale = 1, itemHold = 0 },
	master = { pace = 1.05, rubber = 1.25, delay = 0, delayScale = 0.4, itemHold = 0 },
} :: { [string]: Tune }

GrandPrixRules.BONUS = { rookie = 150, pro = 250, master = 400 } :: { [string]: number }
GrandPrixRules.PLACE_SHARE = { 1.0, 0.65, 0.45 } :: { number }
GrandPrixRules.OTHER_SHARE = 0.2 -- 4th or lower: finishing the cup still pays a little

-- Seconds (server) between a race's end and the next track's load; CONTINUE cuts it to NEXT_CARD.
GrandPrixRules.HOLD = 26
GrandPrixRules.FINAL_HOLD = 60 -- the final standings, the trophy ceremony and its card
GrandPrixRules.NEXT_CARD = 4 -- the "NEXT: <track>" card's length (also how early it shows before an automatic move)

export type Record = {
	best: { [string]: number }, -- class -> best trophy 0..3
	points: { [string]: number }, -- class -> best total points
	cups: number, -- cups completed (any place)
}

function GrandPrixRules.defaults(): Record
	return { best = { rookie = 0, pro = 0, master = 0 }, points = { rookie = 0, pro = 0, master = 0 }, cups = 0 }
end

local function isClass(c: any): boolean
	return type(c) == "string" and GrandPrixRules.TUNE[c] ~= nil
end
GrandPrixRules.isClass = isClass

-- A saved record read defensively (missing or wrong-typed parts are zero).
function GrandPrixRules.read(raw: any): Record
	local out = GrandPrixRules.defaults()
	if type(raw) ~= "table" then
		return out
	end
	for _, c in GrandPrixRules.CLASSES do
		local b = if type(raw.best) == "table" then raw.best[c] else nil
		local p = if type(raw.points) == "table" then raw.points[c] else nil
		out.best[c] = if type(b) == "number" then math.clamp(math.floor(b), 0, 3) else 0
		out.points[c] = if type(p) == "number" and p >= 0 then math.floor(p) else 0
	end
	out.cups = if type(raw.cups) == "number" and raw.cups >= 0 then math.floor(raw.cups) else 0
	return out
end

function GrandPrixRules.classOpen(rec: Record, class: string): boolean
	if class == "rookie" then
		return true
	elseif class == "pro" then
		return (rec.best.rookie or 0) >= 1
	elseif class == "master" then
		return (rec.best.pro or 0) >= 3
	end
	return false
end

function GrandPrixRules.lockLine(class: string): string
	if class == "pro" then
		return "Win any ROOKIE trophy"
	elseif class == "master" then
		return "Win the PRO gold trophy"
	end
	return ""
end

-- The open race tracks in zone order (open: { [trackId]: true }).
function GrandPrixRules.openTracks(open: { [string]: boolean }): { string }
	local out = {}
	for _, id in GrandPrixRules.TRACKS do
		if open[id] == true then
			table.insert(out, id)
		end
	end
	return out
end

-- Which lengths are on offer: none below MIN_TRACKS, "full" from MIN_TRACKS, and "short" as well with more open.
function GrandPrixRules.lengths(openCount: number): { string }
	if openCount < GrandPrixRules.MIN_TRACKS then
		return {}
	elseif openCount == GrandPrixRules.MIN_TRACKS then
		return { "full" }
	end
	return { "short", "full" }
end

-- The cup's tracks: every open one ("full"), or MIN_TRACKS drawn with rng (0..1) kept in zone order ("short").
function GrandPrixRules.pickTracks(open: { string }, length: string, rng: () -> number): { string }?
	if #open < GrandPrixRules.MIN_TRACKS then
		return nil
	end
	if length ~= "short" or #open == GrandPrixRules.MIN_TRACKS then
		return table.clone(open)
	end
	local pool = table.clone(open)
	local keep: { [string]: boolean } = {}
	for _ = 1, GrandPrixRules.MIN_TRACKS do
		local i = math.clamp(math.floor(rng() * #pool) + 1, 1, #pool)
		keep[pool[i]] = true
		table.remove(pool, i)
	end
	local out = {}
	for _, id in open do
		if keep[id] then
			table.insert(out, id)
		end
	end
	return out
end

function GrandPrixRules.pointsFor(place: number, dnf: boolean?): number
	if dnf then
		return 0
	end
	return GrandPrixRules.POINTS[place] or 0
end

export type Entry = { key: string, name: string, human: boolean, place: number, dnf: boolean }
export type Row = {
	key: string,
	name: string,
	human: boolean,
	total: number,
	gained: number,
	place: number, -- this race's place (0 = did not race it)
	rank: number, -- overall after this race
	prevRank: number, -- overall before this race (0 on the first race)
	dnf: boolean, -- did not finish this race (0 points)
}

-- Applies one race to the standings. `prev`: rows by key from the races before (nil on race 1); `race`: this race's
-- entries (places 1..n with no gaps; DNFs last). A racer in prev who missed this race keeps his total with 0 gained.
-- Returns the new rows sorted by rank.
function GrandPrixRules.apply(prev: { [string]: Row }?, race: { Entry }): { Row }
	local rows: { [string]: Row } = {}
	local before: { [string]: Row } = prev or {}
	for key, r in before do
		rows[key] = { key = key, name = r.name, human = r.human, total = r.total, gained = 0, place = 0, rank = 0, prevRank = r.rank, dnf = false }
	end
	for _, e in race do
		local row = rows[e.key]
		if not row then
			row = { key = e.key, name = e.name, human = e.human, total = 0, gained = 0, place = 0, rank = 0, prevRank = 0, dnf = false }
			rows[e.key] = row
		end
		local r = row :: Row
		r.name = e.name
		r.gained = GrandPrixRules.pointsFor(e.place, e.dnf)
		r.total += r.gained
		r.place = e.place
		r.dnf = e.dnf == true
	end
	local list: { Row } = {}
	for _, r in rows do
		table.insert(list, r)
	end
	table.sort(list, function(a: Row, b: Row): boolean
		if a.total ~= b.total then
			return a.total > b.total
		end
		local pa = if a.place > 0 then a.place else math.huge
		local pb = if b.place > 0 then b.place else math.huge
		if pa ~= pb then
			return pa < pb
		end
		return a.key < b.key
	end)
	for i, r in list do
		r.rank = i
	end
	return list
end

function GrandPrixRules.trophyFor(rank: number): number
	if rank == 1 then
		return 3
	elseif rank == 2 then
		return 2
	elseif rank == 3 then
		return 1
	end
	return 0
end

-- finishes: races of this cup the player crossed the line in; under half of them (an idle cup the bots finished for
-- him) pays nothing.
function GrandPrixRules.payout(class: string, rank: number, races: number, finishes: number?): number
	local bonus = GrandPrixRules.BONUS[class]
	if not bonus or races < GrandPrixRules.MIN_TRACKS then
		return 0
	end
	if finishes ~= nil and finishes < math.ceil(races / 2) then
		return 0
	end
	local share = GrandPrixRules.PLACE_SHARE[rank] or GrandPrixRules.OTHER_SHARE
	return math.floor(bonus * share * math.min(races, #GrandPrixRules.TRACKS) / #GrandPrixRules.TRACKS + 0.5)
end

-- The record after a completed cup (best trophy and best points per class only ever rise). Second result: the classes
-- this cup newly opened.
function GrandPrixRules.record(raw: any, class: string, trophy: number, points: number): (Record, { string })
	local rec = GrandPrixRules.read(raw)
	local before: { [string]: boolean } = {}
	for _, c in GrandPrixRules.CLASSES do
		before[c] = GrandPrixRules.classOpen(rec, c)
	end
	if isClass(class) then
		rec.best[class] = math.max(rec.best[class] or 0, math.clamp(math.floor(trophy), 0, 3))
		rec.points[class] = math.max(rec.points[class] or 0, math.max(0, math.floor(points)))
	end
	rec.cups += 1
	local opened = {}
	for _, c in GrandPrixRules.CLASSES do
		if not before[c] and GrandPrixRules.classOpen(rec, c) then
			table.insert(opened, c)
		end
	end
	return rec, opened
end

-- Replicated as the player attribute GPTrophies: "<rookie>,<pro>,<master>" trophies then best points, e.g. "3,1,0;52,34,0".
function GrandPrixRules.encode(rec: Record): string
	local b, p = {}, {}
	for _, c in GrandPrixRules.CLASSES do
		table.insert(b, tostring(rec.best[c] or 0))
		table.insert(p, tostring(rec.points[c] or 0))
	end
	return table.concat(b, ",") .. ";" .. table.concat(p, ",")
end

function GrandPrixRules.decode(s: any): Record
	local rec = GrandPrixRules.defaults()
	if type(s) ~= "string" then
		return rec
	end
	local bs, ps = string.match(s, "^([%d,]*);([%d,]*)$")
	local function fill(src: string?, into: { [string]: number }, cap: number?)
		if not src then
			return
		end
		local i = 0
		for n in string.gmatch(src, "%d+") do
			i += 1
			local c = GrandPrixRules.CLASSES[i]
			if c then
				local v = tonumber(n) or 0
				into[c] = if cap then math.clamp(v, 0, cap) else v
			end
		end
	end
	fill(bs, rec.best, 3)
	fill(ps, rec.points, nil)
	return rec
end

return GrandPrixRules
