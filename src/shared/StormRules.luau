--!strict
-- Storm Shards rules (economy v3 phase 5). Pure: no services, no clock (callers pass the UTC day / server time), specced
-- in tools/tests/storm_spec.luau. Data is shared/StormConfig; the server side is server/StormShards.
--   * earn / applyFinish: the Shard payout of one storm-race finish and how it lands in the saved `storm` record. Its own
--     path: 2x Cash, Festival and Rally Streak never see it (no multiplier argument exists).
--   * tiers: reputation by LIFETIME Shards; tierUps lists the tiers a payout crossed (the tier-up notifications).
--   * vendor: canBuy / applyBuy (insufficient, owned, tier-locked, coming soon), canEquip for the storm-only slots.
--   * hubState: what the hub shows (storm sky on or off, the marker text, the countdown to the next storm race).
-- Saved shape (profile.storm; SaveService.newProfile defaults it, so a profile from before Shards reads all zeros):
--   { shards, lifetime, races, dragonWins, bonusDay, owned = { [vendorKey] = true }, loadout = { [slot] = vendorKey } }
local StormConfig = require(script.Parent:WaitForChild("StormConfig"))
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))
local NotifySpec = require(script.Parent:WaitForChild("NotifySpec"))

local StormRules = {}

StormRules.config = StormConfig

export type State = {
	shards: number,
	lifetime: number,
	races: number,
	dragonWins: number,
	bonusDay: number, -- UTC day number of the last first-of-day bonus (0 = never)
	owned: { [string]: boolean },
	loadout: { [string]: string },
}

-- The finish being paid (RaceManager FinishInfo plus beatDragon).
export type Finish = {
	mode: string,
	rank: number,
	finished: boolean,
	simulated: boolean?,
	beatDragon: boolean?,
}

export type Payout = {
	total: number,
	parts: { finish: number, place: number, dragon: number, firstOfDay: number },
	beatDragon: boolean,
	firstOfDay: boolean,
}

function StormRules.defaults(): State
	return { shards = 0, lifetime = 0, races = 0, dragonWins = 0, bonusDay = 0, owned = {}, loadout = {} }
end

local function count(v: any): number
	if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
		return 0
	end
	return math.floor(v)
end

-- A safe read of a profile's storm record: nil, a missing field or a wrong type reads as the default (old profiles).
function StormRules.read(profile: any): State
	local raw = if type(profile) == "table" then profile.storm else nil
	if type(raw) ~= "table" then
		return StormRules.defaults()
	end
	local owned: { [string]: boolean } = {}
	if type(raw.owned) == "table" then
		for k, v in raw.owned do
			if type(k) == "string" and v == true then
				owned[k] = true
			end
		end
	end
	local loadout: { [string]: string } = {}
	if type(raw.loadout) == "table" then
		for k, v in raw.loadout do
			if type(k) == "string" and type(v) == "string" then
				loadout[k] = v
			end
		end
	end
	return {
		shards = count(raw.shards),
		lifetime = count(raw.lifetime),
		races = count(raw.races),
		dragonWins = count(raw.dragonWins),
		bonusDay = count(raw.bonusDay),
		owned = owned,
		loadout = loadout,
	}
end

function StormRules.isStormMode(mode: any): boolean
	return type(mode) == "string" and StormConfig.MODES[mode] == true
end

-- This racer beat the storm dragon: a storm race with a dragon in the field (the flow phase publishes it), finished,
-- and nothing of the dragon's crossed the line first (RaceManager's beatBoss: no bot ahead).
function StormRules.beatDragon(mode: any, finished: boolean, beatBoss: boolean?, dragonInField: boolean): boolean
	return StormRules.isStormMode(mode) and finished == true and dragonInField == true and beatBoss == true
end

function StormRules.utcDay(utcSeconds: number): number
	return math.floor(utcSeconds / 86400)
end

-- Shards for one finish, or nil when this finish pays none (not a storm race, not finished, a simulated finish outside
-- Studio, feature off). allowSimulated: Studio only (a QA finish counts there, as it does for Cash).
function StormRules.earn(info: Finish, state: State, utcDay: number, allowSimulated: boolean?): Payout?
	if StormConfig.Enabled ~= true or not StormRules.isStormMode(info.mode) or info.finished ~= true then
		return nil
	end
	if info.simulated == true and allowSimulated ~= true then
		return nil
	end
	local e = StormConfig.EARN
	local rank = math.max(1, math.floor(tonumber(info.rank) or #e.place))
	local place = e.place[math.min(rank, #e.place)] or 0
	local dragon = if info.beatDragon == true then e.dragon else 0
	local firstOfDay = state.bonusDay ~= utcDay
	local daily = if firstOfDay then e.firstOfDay else 0
	return {
		total = e.finish + place + dragon + daily,
		parts = { finish = e.finish, place = place, dragon = dragon, firstOfDay = daily },
		beatDragon = info.beatDragon == true,
		firstOfDay = firstOfDay,
	}
end

-- Lands a payout in a storm record (inside SaveService.edit: must not yield). Lifetime only ever grows.
function StormRules.applyFinish(state: State, payout: Payout, utcDay: number)
	state.shards = count(state.shards) + payout.total
	state.lifetime = count(state.lifetime) + payout.total
	state.races = count(state.races) + 1
	if payout.beatDragon then
		state.dragonWins = count(state.dragonWins) + 1
	end
	if payout.firstOfDay then
		state.bonusDay = utcDay
	end
end

------------------------------------------------------------------------------------------------------------- tiers

function StormRules.tierIndex(lifetime: number): number
	local idx = 1
	for i, t in StormConfig.TIERS do
		if count(lifetime) >= t.at then
			idx = i
		end
	end
	return idx
end

function StormRules.tierFor(lifetime: number): StormConfig.Tier
	return StormConfig.TIERS[StormRules.tierIndex(lifetime)]
end

function StormRules.tierById(id: string?): (StormConfig.Tier?, number)
	for i, t in StormConfig.TIERS do
		if t.id == id then
			return t, i
		end
	end
	return nil, 0
end

-- The next tier and the lifetime Shards still needed, or nil at the top.
function StormRules.nextTier(lifetime: number): (StormConfig.Tier?, number)
	local nxt = StormConfig.TIERS[StormRules.tierIndex(lifetime) + 1]
	if not nxt then
		return nil, 0
	end
	return nxt, nxt.at - count(lifetime)
end

-- Tiers reached by going from `before` to `after` lifetime Shards, lowest first (one payout can cross two).
function StormRules.tierUps(before: number, after: number): { StormConfig.Tier }
	local out: { StormConfig.Tier } = {}
	local a, b = StormRules.tierIndex(before), StormRules.tierIndex(after)
	for i = a + 1, b do
		table.insert(out, StormConfig.TIERS[i])
	end
	return out
end

------------------------------------------------------------------------------------------------------------ vendor

local itemsByKey: { [string]: StormConfig.Item } = {}
for _, it in StormConfig.VENDOR do
	itemsByKey[it.key] = it
end
local kindsById: { [string]: StormConfig.KindDef } = {}
for _, k in StormConfig.KINDS do
	kindsById[k.id] = k
end
local cosmeticsByKey: { [string]: any } = {}
for _, c in MonetizationConfig.COSMETICS do
	cosmeticsByKey[c.key] = c
end

function StormRules.item(key: any): StormConfig.Item?
	return if type(key) == "string" then itemsByKey[key] else nil
end

function StormRules.kind(id: string): StormConfig.KindDef?
	return kindsById[id]
end

-- Vendor rows of one tier page, in config order.
function StormRules.page(tierId: string): { StormConfig.Item }
	local out: { StormConfig.Item } = {}
	for _, it in StormConfig.VENDOR do
		if it.tier == tierId then
			table.insert(out, it)
		end
	end
	return out
end

-- Drawn today: the four Garage kinds (the existing tint / trail / horn / emote code draws them). Every other kind is
-- data now and drawn once its art and renderer land.
function StormRules.drawnToday(it: StormConfig.Item): boolean
	local kd = kindsById[it.kind]
	return kd ~= nil and kd.slot == "garage" and it.cosmetic ~= nil
end

-- Owned: bought from the vendor, or (a Garage kind) the cosmetic already sits in cosmetics.owned.
function StormRules.owns(state: State, cosmeticsOwned: { [string]: boolean }?, key: string): boolean
	if state.owned[key] == true then
		return true
	end
	local it = itemsByKey[key]
	return it ~= nil and it.cosmetic ~= nil and cosmeticsOwned ~= nil and cosmeticsOwned[it.cosmetic] == true
end

export type BuyReason = "disabled" | "unknown" | "comingSoon" | "owned" | "locked" | "short"

-- Can this record buy `key` now? Order: unknown, coming soon, owned, tier-locked, not enough Shards.
function StormRules.canBuy(state: State, cosmeticsOwned: { [string]: boolean }?, key: any): (boolean, BuyReason?)
	if StormConfig.Enabled ~= true then
		return false, "disabled"
	end
	local it = StormRules.item(key)
	if not it then
		return false, "unknown"
	end
	if it.comingSoon == true or (StormConfig.SELL_PENDING_LOOKS ~= true and not StormRules.drawnToday(it)) then
		return false, "comingSoon"
	end
	if StormRules.owns(state, cosmeticsOwned, it.key) then
		return false, "owned"
	end
	local _, need = StormRules.tierById(it.tier)
	if StormRules.tierIndex(state.lifetime) < need then
		return false, "locked"
	end
	if state.shards < it.price then
		return false, "short"
	end
	return true, nil
end

-- Applies a purchase to a profile draft (inside SaveService.edit). Re-checks; errors on a refusal so the edit is
-- cancelled. Spends `shards` only: lifetime (the tier) never drops.
function StormRules.applyBuy(profile: any, key: string)
	local state = StormRules.read(profile)
	local ok, reason = StormRules.canBuy(state, profile.cosmetics and profile.cosmetics.owned, key)
	if not ok then
		error("storm buy refused: " .. tostring(reason), 0)
	end
	local it = itemsByKey[key]
	state.shards -= it.price
	state.owned[key] = true
	profile.storm = state
	if it.cosmetic then
		profile.cosmetics.owned[it.cosmetic] = true
	end
end

export type EquipReason = "disabled" | "badSlot" | "unknown" | "wrongSlot" | "notOwned"

-- The storm-only slots (KINDS rows whose slot is not "garage"). key nil / "" unequips.
function StormRules.canEquip(state: State, slot: any, key: any): (boolean, EquipReason?)
	if StormConfig.Enabled ~= true then
		return false, "disabled"
	end
	local slotOk = false
	for _, k in StormConfig.KINDS do
		if k.slot == slot and k.slot ~= "garage" and k.id ~= "avatar" then
			slotOk = true
		end
	end
	if type(slot) ~= "string" or not slotOk then
		return false, "badSlot"
	end
	if key == nil or key == "" then
		return true, nil
	end
	local it = StormRules.item(key)
	if not it then
		return false, "unknown"
	end
	local kd = kindsById[it.kind]
	if not kd or kd.slot ~= slot then
		return false, "wrongSlot"
	end
	if state.owned[it.key] ~= true then
		return false, "notOwned"
	end
	return true, nil
end

-- "border=Storm_Border_Gale,title=Storm_Title_Squall" (sorted): the StormLoadout player attribute other clients read.
function StormRules.encodeLoadout(loadout: { [string]: string }): string
	local parts: { string } = {}
	for slot, key in loadout do
		table.insert(parts, slot .. "=" .. key)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

function StormRules.decodeLoadout(raw: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(raw) ~= "string" then
		return out
	end
	for slot, key in string.gmatch(raw, "([%w_]+)=([%w_]+)") do
		out[slot :: string] = key :: string
	end
	return out
end

------------------------------------------------------------------------------------------------------------- panel

export type PanelLayout = { x: number, y: number, w: number, h: number, header: number, tabs: number, row: number, pad: number }

-- The vendor panel inside the safe viewport (vw x vh below topInset): centred, at most 640 x 480, at least 44 px rows and
-- tab targets, header and tabs shrink on a 360 px-tall phone so at least three rows stay visible.
function StormRules.panelLayout(vw: number, vh: number, topInset: number?): PanelLayout
	local top = topInset or 0
	local availH = math.max(200, vh - top)
	local w = math.floor(math.min(640, vw * 0.94))
	local h = math.floor(math.min(480, availH * 0.92))
	local compact = availH < 420
	local header = if compact then 52 else 66
	local tabs = 44
	local row = if compact then 48 else 56
	return { x = math.floor((vw - w) / 2), y = math.floor(top + (availH - h) / 2), w = w, h = h, header = header, tabs = tabs, row = row, pad = if compact then 6 else 10 }
end

------------------------------------------------------------------------------------------------------------- hub

function StormRules.formatCountdown(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

export type HubAttrs = {
	mode: any, -- workspace RaceMode (hub visuals only in "hub")
	live: any, -- workspace StormRaceLive: a storm race is running on this server (the per-group flow sets it)
	qa: any, -- workspace HubStormQA (Studio capture switch)
	nextAt: any, -- workspace StormCupAt (UTC seconds), when published
	cupEnabled: any?, -- workspace StormCupEnabled: false = no storm race is scheduled, so no countdown is shown
}

-- marked: the marker is shown at all (always while a storm runs; between races only while the Storm Cup is scheduled,
-- so the hub never counts down to a race that will not start).
-- text: the marker's full text; while a storm race runs it is the IN PROGRESS line plus the countdown to the next one
-- (storm race v2, owner ruling venue B: "STORM RACE IN PROGRESS", countdown to the next one).
export type HubState = { show: boolean, active: boolean, marked: boolean, nextAt: number, marker: string, text: string }

-- What the hub shows now. show = the client is in the hub at all; active = storm sky, lightning, thunder and the
-- IN PROGRESS marker; otherwise the marker counts down to the next storm race (StormCupAt, or the next :00/:30 UTC).
function StormRules.hubState(a: HubAttrs, now: number): HubState
	local show = a.mode == "hub" and StormConfig.Enabled == true
	local active = show and (a.live == true or a.qa == true)
	local period = StormConfig.HUB.periodFallback
	local nextAt = if type(a.nextAt) == "number" and a.nextAt > now then a.nextAt else (math.floor(now / period) + 1) * period
	local row = NotifySpec.get(if active then "storm_hub_live" else "storm_hub_next")
	local marker = NotifySpec.format(if row then row.copy else "", { time = StormRules.formatCountdown(nextAt - now) })
	local text = marker
	if active then
		local nextRow = NotifySpec.get("storm_hub_next")
		text = marker .. "\n" .. NotifySpec.format(if nextRow then nextRow.copy else "", { time = StormRules.formatCountdown(nextAt - now) })
	end
	return { show = show, active = active, marked = active or (show and a.cupEnabled ~= false), nextAt = nextAt, marker = marker, text = text }
end

-- Seconds until the next lightning flash, from a 0..1 random draw.
function StormRules.lightningGap(r: number): number
	local h = StormConfig.HUB
	return h.lightningMin + (h.lightningMax - h.lightningMin) * math.clamp(r, 0, 1)
end

------------------------------------------------------------------------------------------------------------ validate

-- Config sanity (the spec fails on any line): tiers rise from 0, at least 10 vendor kinds, every row's tier and kind
-- exist, prices positive and rising by tier, Garage kinds point at a "storm" cosmetic of the right kind, other kinds
-- carry no cosmetic, keys unique.
function StormRules.validate(): { string }
	local errors: { string } = {}
	local function bad(msg: string)
		table.insert(errors, msg)
	end
	local tiers = StormConfig.TIERS
	if tiers[1] == nil or tiers[1].at ~= 0 then
		bad("the first tier must start at 0")
	end
	for i = 2, #tiers do
		if tiers[i].at <= tiers[i - 1].at then
			bad("tiers must rise")
		end
	end
	local kinds: { [string]: boolean } = {}
	local seen: { [string]: boolean } = {}
	local maxPrice: { [number]: number } = {}
	local minPrice: { [number]: number } = {}
	for _, it in StormConfig.VENDOR do
		if seen[it.key] then
			bad("duplicate vendor key " .. it.key)
		end
		seen[it.key] = true
		local kd = kindsById[it.kind]
		local _, ti = StormRules.tierById(it.tier)
		if not kd then
			bad(it.key .. " has unknown kind " .. it.kind)
		end
		if ti == 0 then
			bad(it.key .. " has unknown tier " .. it.tier)
		end
		if type(it.price) ~= "number" or it.price <= 0 or it.price ~= math.floor(it.price) then
			bad(it.key .. " has a bad price")
		elseif ti > 0 and not it.comingSoon then
			maxPrice[ti] = math.max(maxPrice[ti] or 0, it.price)
			minPrice[ti] = math.min(minPrice[ti] or math.huge, it.price)
		end
		if kd and kd.slot == "garage" then
			local c = if it.cosmetic then cosmeticsByKey[it.cosmetic] else nil
			if not c then
				bad(it.key .. " points at a missing cosmetic")
			elseif c.source ~= "storm" then
				bad(it.key .. " cosmetic is not a storm cosmetic")
			elseif c.kind ~= kd.garageKind then
				bad(it.key .. " cosmetic kind " .. c.kind .. " is not " .. tostring(kd.garageKind))
			elseif c.gearsPrice ~= nil then
				bad(it.key .. " cosmetic has a Cash price")
			end
		elseif it.cosmetic ~= nil then
			bad(it.key .. " is a storm-slot kind with a Garage cosmetic")
		end
		if kd and kd.slot ~= "garage" and it.look == nil and it.comingSoon ~= true then
			bad(it.key .. " has no placeholder look")
		end
		if not it.comingSoon then
			kinds[it.kind] = true
		end
	end
	local n = 0
	for _ in kinds do
		n += 1
	end
	if n < 10 then
		bad(string.format("the vendor sells %d cosmetic types, needs at least 10", n))
	end
	for i = 2, #tiers do
		if minPrice[i] and maxPrice[i - 1] and minPrice[i] < (minPrice[i - 1] or 0) then
			bad("tier " .. tiers[i].id .. " is cheaper than the tier below")
		end
	end
	-- Every storm cosmetic is sold by exactly one vendor row (nothing else can hand one out).
	local sold: { [string]: number } = {}
	for _, it in StormConfig.VENDOR do
		if it.cosmetic then
			sold[it.cosmetic] = (sold[it.cosmetic] or 0) + 1
		end
	end
	for _, c in MonetizationConfig.COSMETICS do
		if c.source == "storm" and sold[c.key] ~= 1 then
			bad(c.key .. " is a storm cosmetic not sold by exactly one vendor row")
		end
	end
	return errors
end

return StormRules
