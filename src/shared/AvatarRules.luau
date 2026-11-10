--!strict
-- Pure avatar rules (economy v3 phase 6): ownership, Cash purchase, selection per class, the per-avatar reskin / tint
-- ladder, the saved-state repair that keeps old profiles safe, the picker rows and the builders' mesh lookup. No
-- services, no Instances, no clock: SaveService (derive), Economy (requests, race and key counting), the Garage VEHICLES
-- tab, the pre-race pick and the builders share it; tools/tests/avatar_spec.luau drives it under Lune.
--
-- Saved shape (profile.avatars; string keys only, DataStore-safe):
--   owned    { [avatarKey]: true }               bought or granted; starters and free rows are always present
--   selected { plane: avatarKey, car: avatarKey } the last pick per class (the pre-race pick preselects it)
--   progress { [avatarKey]: { races, wins, keys } } counted only while racing that avatar
--   skin     { [avatarKey]: stepId }             the reskin / tint worn on that avatar ("" or nil = the base look)
-- Unlocked ladder steps are never stored: they are read from progress, so they can never drift from what was played.
local AvatarConfig = require(script.Parent:WaitForChild("AvatarConfig"))

local AvatarRules = {}

type Row = AvatarConfig.Row
type Step = AvatarConfig.Step
type Mesh = AvatarConfig.Mesh
type Config = any -- AvatarConfig-shaped (spec fixtures pass copies)

export type Progress = { races: number, wins: number, keys: number }
export type State = {
	owned: { [string]: boolean },
	selected: { [string]: string },
	progress: { [string]: Progress },
	skin: { [string]: string },
}

-- What derive needs from a profile to settle earned rows.
export type EarnedFacts = { campaign: boolean?, amulet: boolean?, storm: boolean? }

AvatarRules.config = AvatarConfig

local function cfgOf(cfg: Config?): Config
	return cfg or AvatarConfig
end

-- Key index of the shipping roster, rebuilt if the row count changes (a spec fixture passes its own copy instead).
local cachedRows: any = nil
local cachedCount = -1
local cachedIndex: { [string]: Row } = {}

local function index(cfg: Config?): { [string]: Row }
	local c = cfgOf(cfg)
	if c.ROWS == cachedRows and #c.ROWS == cachedCount then
		return cachedIndex
	end
	local idx: { [string]: Row } = {}
	for _, r in ipairs(c.ROWS) do
		idx[r.key] = r
	end
	cachedRows, cachedCount, cachedIndex = c.ROWS, #c.ROWS, idx
	return idx
end

function AvatarRules.row(key: any, cfg: Config?): Row?
	if type(key) ~= "string" then
		return nil
	end
	return index(cfg)[key]
end

function AvatarRules.isClass(class: any, cfg: Config?): boolean
	if type(class) ~= "string" then
		return false
	end
	for _, c in ipairs(cfgOf(cfg).CLASSES) do
		if c == class and not cfgOf(cfg).HIDDEN_CLASSES[c] then
			return true
		end
	end
	return false
end

function AvatarRules.rowsFor(class: string, cfg: Config?): { Row }
	local out: { Row } = {}
	for _, r in ipairs(cfgOf(cfg).ROWS) do
		if r.class == class then
			table.insert(out, r)
		end
	end
	return out
end

function AvatarRules.starter(class: string, cfg: Config?): string?
	return cfgOf(cfg).STARTER[class]
end

function AvatarRules.ladder(key: string, cfg: Config?): { Step }
	local r = AvatarRules.row(key, cfg)
	return (r and r.ladder) or cfgOf(cfg).LADDER
end

---------------------------------------------------------------------------------------------------- meshes

-- A row has its own model once the registry holds a non-hero entry with a model id (the hero rows count as built).
function AvatarRules.built(key: string, cfg: Config?): boolean
	local m = cfgOf(cfg).MESHES[key]
	return m ~= nil and (m.hero == true or (type(m.modelId) == "number" and m.modelId > 0))
end

-- What the builders render for an avatar key on a class: the row's own mesh when registered, else the class's hero
-- model. An unknown key, a key of the other class or nil all fall back to the class starter, so a bad save or a forged
-- value can only ever change looks, never the hull.
function AvatarRules.meshFor(key: string?, class: string, cfg: Config?): (string, Mesh)
	local c = cfgOf(cfg)
	local r = AvatarRules.row(key, c)
	local useKey = if r and r.class == class then r.key else (c.STARTER[class] or "")
	local m = c.MESHES[useKey]
	if m and not m.hero and type(m.modelId) == "number" and m.modelId > 0 then
		return useKey, m
	end
	return useKey, { hero = true, prop = class == "plane" }
end

---------------------------------------------------------------------------------------------------- listing

-- Whether the picker shows a row. Owned rows always show (a profile never loses sight of what it has). Unbuilt rows
-- show only while SELL_UNBUILT is on and the launch hide is off.
function AvatarRules.listed(key: string, owned: boolean, launchHide: boolean?, cfg: Config?): boolean
	local c = cfgOf(cfg)
	if not c.ENABLED or not AvatarRules.row(key, c) then
		return false
	end
	if owned or AvatarRules.built(key, c) then
		return true
	end
	return c.SELL_UNBUILT == true and launchHide ~= true
end

---------------------------------------------------------------------------------------------------- state

function AvatarRules.defaultState(cfg: Config?): State
	local c = cfgOf(cfg)
	local s: State = { owned = {}, selected = {}, progress = {}, skin = {} }
	for _, r in ipairs(c.ROWS) do
		if r.acquire.kind == "starter" or r.acquire.kind == "free" then
			s.owned[r.key] = true
		end
	end
	for class, key in pairs(c.STARTER) do
		s.selected[class] = key
	end
	return s
end

local function count(v: any): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v < 0 then
		return 0
	end
	return math.floor(v)
end

function AvatarRules.progressOf(state: any, key: string): Progress
	local p = if type(state) == "table" and type(state.progress) == "table" then state.progress[key] else nil
	if type(p) ~= "table" then
		return { races = 0, wins = 0, keys = 0 }
	end
	return { races = count(p.races), wins = count(p.wins), keys = count(p.keys) }
end

-- Settles a saved avatars table in place (SaveService.derive runs this after every load, award and edit) and returns
-- it. Old profiles reach here with the defaults reconcile filled in; anything malformed is repaired, never fatal:
-- * starters and free rows owned; earned rows owned exactly while their source holds (an edit cannot grant or remove
--   them); unknown owned keys are KEPT (a newer build may have added the row);
-- * selected[class] is a known, owned row of that class, else the class starter;
-- * progress entries are whole non-negative counts; skin entries name an unlocked step of an owned row, else go.
function AvatarRules.settle(state: any, facts: EarnedFacts?, cfg: Config?): State
	local c = cfgOf(cfg)
	local s: any = if type(state) == "table" then state else {}
	for _, field in ipairs({ "owned", "selected", "progress", "skin" }) do
		if type(s[field]) ~= "table" then
			s[field] = {}
		end
	end
	local f = facts or {}
	for _, r in ipairs(c.ROWS) do
		local a = r.acquire
		if a.kind == "starter" or a.kind == "free" then
			s.owned[r.key] = true
		elseif a.kind == "earned" then
			s.owned[r.key] = if (f :: any)[a.source or ""] == true then true else nil
		end
	end
	for k, v in pairs(s.owned) do
		if v ~= true or type(k) ~= "string" then
			s.owned[k] = nil
		end
	end
	for _, class in ipairs(c.CLASSES) do
		local pick = s.selected[class]
		local r = AvatarRules.row(pick, c)
		if not (r and r.class == class and s.owned[r.key]) then
			s.selected[class] = c.STARTER[class]
		end
	end
	for k, p in pairs(s.progress) do
		if type(k) ~= "string" or type(p) ~= "table" then
			s.progress[k] = nil
		else
			s.progress[k] = { races = count(p.races), wins = count(p.wins), keys = count(p.keys) }
		end
	end
	for k, stepId in pairs(s.skin) do
		if not (type(k) == "string" and s.owned[k] and AvatarRules.stepUnlocked(k, stepId, AvatarRules.progressOf(s, k), c)) then
			s.skin[k] = nil
		end
	end
	return s :: State
end

---------------------------------------------------------------------------------------------------- admin overlay

-- Ownership of one avatar. Owner admin (DECISIONS D22a "all vehicles unlocked"): when the admin's runtime switch is on
-- (allUnlocked, which only server/AdminService can make true, for his account only) every listed row of a live class
-- counts as owned; this branch comes FIRST and never touches the saved table. Everyone else: the saved owned set.
function AvatarRules.owns(state: any, key: any, allUnlocked: boolean?, cfg: Config?): boolean
	if allUnlocked == true then
		local r = AvatarRules.row(key, cfg)
		return r ~= nil and AvatarRules.isClass(r.class, cfg)
	end
	return type(state) == "table" and type(state.owned) == "table" and type(key) == "string" and state.owned[key] == true
end

-- The state the picker, the select request and the spawn read for one player: the saved state itself when the switch is
-- off (nil overlay, the normal path, byte-for-byte unchanged), else a COPY with every row owned and the admin's runtime
-- picks (class -> key, kept in server memory only) over the saved picks. The copy is never written back: SaveService
-- keeps settling the saved table, so turning the switch off (or leaving) shows exactly his saved garage again.
function AvatarRules.overlay(state: State, allUnlocked: boolean?, picks: { [string]: string }?, cfg: Config?): State
	if allUnlocked ~= true then
		return state
	end
	local c = cfgOf(cfg)
	local owned: { [string]: boolean } = table.clone(state.owned or {})
	for _, r in ipairs(c.ROWS) do
		if AvatarRules.owns(state, r.key, true, c) then
			owned[r.key] = true
		end
	end
	local selected: { [string]: string } = table.clone(state.selected or {})
	for class, key in pairs(picks or {}) do
		local r = AvatarRules.row(key, c)
		if r and r.class == class and owned[key] then
			selected[class] = key
		end
	end
	return { owned = owned, selected = selected, progress = state.progress or {}, skin = state.skin or {} }
end

---------------------------------------------------------------------------------------------------- ladder

function AvatarRules.meets(need: AvatarConfig.Need, p: Progress): boolean
	return (need.races ~= nil and p.races >= need.races)
		or (need.wins ~= nil and p.wins >= need.wins)
		or (need.keys ~= nil and p.keys >= need.keys)
end

function AvatarRules.stepUnlocked(key: string, stepId: any, p: Progress, cfg: Config?): boolean
	if type(stepId) ~= "string" then
		return false
	end
	for _, step in ipairs(AvatarRules.ladder(key, cfg)) do
		if step.id == stepId then
			return AvatarRules.meets(step.need, p)
		end
	end
	return false
end

function AvatarRules.unlockedSteps(key: string, p: Progress, cfg: Config?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, step in ipairs(AvatarRules.ladder(key, cfg)) do
		if AvatarRules.meets(step.need, p) then
			out[step.id] = true
		end
	end
	return out
end

-- "12/30 races, 1/3 wins": the step's conditions against the progress, in a fixed order.
function AvatarRules.needText(need: AvatarConfig.Need, p: Progress): string
	local parts = {}
	if need.races then
		table.insert(parts, string.format("%d/%d races", math.min(p.races, need.races), need.races))
	end
	if need.wins then
		table.insert(parts, string.format("%d/%d wins", math.min(p.wins, need.wins), need.wins))
	end
	if need.keys then
		table.insert(parts, string.format("%d/%d keys", math.min(p.keys, need.keys), need.keys))
	end
	return table.concat(parts, " or ")
end

export type Unlock = { avatar: string, avatarName: string, step: string, stepName: string, kind: string }

local function bump(state: State, key: string, cfg: Config?, fn: (p: Progress) -> ()): { Unlock }
	local r = AvatarRules.row(key, cfg)
	if not r or not state.owned[key] then
		return {}
	end
	local before = AvatarRules.progressOf(state, key)
	local after = table.clone(before)
	fn(after)
	state.progress[key] = after
	local out: { Unlock } = {}
	for _, step in ipairs(AvatarRules.ladder(key, cfg)) do
		if AvatarRules.meets(step.need, after) and not AvatarRules.meets(step.need, before) then
			table.insert(out, { avatar = key, avatarName = r.name, step = step.id, stepName = step.name, kind = step.kind :: string })
		end
	end
	return out
end

-- One race finished with this avatar (any place); won = first place. Only an owned, known avatar counts. Returns the
-- ladder steps this finish unlocked.
function AvatarRules.recordRace(state: State, key: any, won: boolean, cfg: Config?): { Unlock }
	if type(key) ~= "string" then
		return {}
	end
	return bump(state, key, cfg, function(p: Progress)
		p.races += 1
		if won then
			p.wins += 1
		end
	end)
end

-- A hidden key found (a new one, saved) while driving this avatar.
function AvatarRules.recordKey(state: State, key: any, cfg: Config?): { Unlock }
	if type(key) ~= "string" then
		return {}
	end
	return bump(state, key, cfg, function(p: Progress)
		p.keys += 1
	end)
end

---------------------------------------------------------------------------------------------------- requests

-- Cash price of a row, or nil when it is not sold for Cash.
function AvatarRules.cashPrice(key: string, cfg: Config?): number?
	local r = AvatarRules.row(key, cfg)
	if r and r.acquire.kind == "cash" and type(r.acquire.price) == "number" and r.acquire.price > 0 then
		return r.acquire.price
	end
	return nil
end

-- Whether a Cash purchase may go ahead. Reasons map to GarageModel.reasonText.
function AvatarRules.canBuy(state: State, key: any, gears: number, launchHide: boolean?, cfg: Config?): (boolean, string?, number?)
	local r = AvatarRules.row(key, cfg)
	if not r then
		return false, "unknown", nil
	end
	if state.owned[r.key] then
		return false, "owned", nil
	end
	if not AvatarRules.listed(r.key, false, launchHide, cfg) then
		return false, "unavailable", nil
	end
	local kind = r.acquire.kind
	if kind == "earned" then
		return false, "earnedOnly", nil
	elseif kind == "robux" then
		return false, "robuxOnly", nil
	end
	local price = AvatarRules.cashPrice(r.key, cfg)
	if not price then
		return false, "notForSale", nil
	end
	if gears < price then
		return false, "gears", price
	end
	return true, nil, price
end

-- Applies a Cash purchase to a draft (inside SaveService.edit; re-checked there). Returns the new balance. The ladder
-- starts at zero for a bought avatar.
function AvatarRules.buy(profile: any, key: string, launchHide: boolean?, cfg: Config?): number
	local ok, reason, price = AvatarRules.canBuy(profile.avatars, key, profile.gears, launchHide, cfg)
	if not ok then
		error(reason or "refused", 0)
	end
	profile.gears -= price :: number
	profile.avatars.owned[key] = true
	return profile.gears
end

function AvatarRules.canSelect(state: State, key: any, cfg: Config?): (boolean, string?)
	local r = AvatarRules.row(key, cfg)
	if not r then
		return false, "unknown"
	end
	if not AvatarRules.isClass(r.class, cfg) then
		return false, "unavailable"
	end
	if not state.owned[r.key] then
		return false, "notOwned"
	end
	return true, nil
end

-- stepId "" (or nil) takes the reskin off. Only an unlocked step of an owned avatar can be worn.
function AvatarRules.canWear(state: State, key: any, stepId: any, cfg: Config?): (boolean, string?)
	local r = AvatarRules.row(key, cfg)
	if not r then
		return false, "unknown"
	end
	if not state.owned[r.key] then
		return false, "notOwned"
	end
	if stepId == nil or stepId == "" then
		return true, nil
	end
	if not AvatarRules.stepUnlocked(r.key, stepId, AvatarRules.progressOf(state, r.key), cfg) then
		return false, "locked"
	end
	return true, nil
end

---------------------------------------------------------------------------------------------------- picker rows

export type StepView = { id: string, kind: string, name: string, unlocked: boolean, need: string, worn: boolean }
export type View = {
	key: string,
	class: string,
	name: string,
	rarity: string,
	acquire: string, -- AcquireKind
	price: number?, -- Cash
	robux: number?, -- default label only (the live price comes from the product when it exists)
	source: string?,
	owned: boolean,
	selected: boolean,
	built: boolean,
	affordable: boolean,
	progress: Progress,
	ladder: { StepView },
	note: string, -- short plain line: "OWNED", "1,500 CASH", "BATTLE AMULET", ...
}

AvatarRules.SOURCE_TEXT = {
	campaign = "BEAT THE FINAL BOSS",
	amulet = "BATTLE AMULET",
	storm = "STORM VENDOR",
} :: { [string]: string }

-- Picker rows for one class in config order: only listed rows. Pure data for the Garage tab and the pre-race pick.
function AvatarRules.view(state: State, class: string, gears: number, launchHide: boolean?, cfg: Config?): { View }
	local out: { View } = {}
	for _, r in ipairs(AvatarRules.rowsFor(class, cfg)) do
		local owned = state.owned[r.key] == true
		if AvatarRules.listed(r.key, owned, launchHide, cfg) then
			local p = AvatarRules.progressOf(state, r.key)
			local steps: { StepView } = {}
			for _, step in ipairs(AvatarRules.ladder(r.key, cfg)) do
				table.insert(steps, {
					id = step.id,
					kind = step.kind :: string,
					name = step.name,
					unlocked = AvatarRules.meets(step.need, p),
					need = AvatarRules.needText(step.need, p),
					worn = state.skin[r.key] == step.id,
				})
			end
			local a = r.acquire
			local price = AvatarRules.cashPrice(r.key, cfg)
			local note: string
			if owned then
				note = if state.selected[class] == r.key then "SELECTED" else "OWNED"
			elseif a.kind == "earned" then
				note = AvatarRules.SOURCE_TEXT[a.source or ""] or "EARNED"
			elseif a.kind == "robux" then
				note = "ROBUX"
			else
				note = "CASH"
			end
			table.insert(out, {
				key = r.key,
				class = r.class :: string,
				name = r.name,
				rarity = r.rarity :: string,
				acquire = a.kind :: string,
				price = price,
				robux = a.robux,
				source = a.source :: string?,
				owned = owned,
				selected = state.selected[class] == r.key,
				built = AvatarRules.built(r.key, cfg),
				affordable = price ~= nil and gears >= price,
				progress = p,
				ladder = steps,
				note = note,
			})
		end
	end
	return out
end

-- The next locked step of an avatar and its need line ("Pro: 12/30 races or 1/3 wins"), or nil when the ladder is done.
function AvatarRules.nextStep(key: string, p: Progress, cfg: Config?): (Step?, string?)
	for _, step in ipairs(AvatarRules.ladder(key, cfg)) do
		if not AvatarRules.meets(step.need, p) then
			return step, AvatarRules.needText(step.need, p)
		end
	end
	return nil, nil
end

---------------------------------------------------------------------------------------------------- bots (later)

-- A bot's avatar: a built, non-earned row of the class picked by rnd() in [0, 1). Not wired yet (bots keep the hero
-- model until meshes land); kept here so the pick is specced with the rest.
function AvatarRules.botAvatar(class: string, rnd: () -> number, cfg: Config?): string?
	local pool: { string } = {}
	for _, r in ipairs(AvatarRules.rowsFor(class, cfg)) do
		if r.acquire.kind ~= "earned" and AvatarRules.built(r.key, cfg) then
			table.insert(pool, r.key)
		end
	end
	if #pool == 0 then
		return cfgOf(cfg).STARTER[class]
	end
	return pool[math.clamp(math.floor(rnd() * #pool) + 1, 1, #pool)]
end

---------------------------------------------------------------------------------------------------- validation

-- Words that would make an avatar a stat class. A row (or its acquire / ladder data) holding any of these fails.
AvatarRules.TUNING_WORDS = {
	"speed", "accel", "handling", "turn", "grip", "drift", "boost", "mass", "weight", "drag", "lift", "thrust",
	"hull", "size", "power", "stat", "tuning", "brake", "steer", "jump", "gravity",
} :: { string }

local function scanTuning(t: any, path: string, errs: { string })
	if type(t) ~= "table" then
		return
	end
	for k, v in pairs(t) do
		if type(k) == "string" then
			local lower = string.lower(k)
			for _, w in ipairs(AvatarRules.TUNING_WORDS) do
				if string.find(lower, w, 1, true) then
					table.insert(errs, string.format("%s.%s looks like a tuning field", path, k))
				end
			end
		end
		scanTuning(v, path .. "." .. tostring(k), errs)
	end
end

-- Every rule the roster must keep. Returns a list of problems (empty = valid).
function AvatarRules.validate(cfg: Config?): { string }
	local c = cfgOf(cfg)
	local errs: { string } = {}
	local seen: { [string]: boolean } = {}
	local bandOk = function(rarity: string, price: number): boolean
		local band = c.CASH_BANDS[rarity]
		return band ~= nil and price >= band[1] and price <= band[2]
	end
	local robuxOk = function(n: any): boolean
		for _, p in ipairs(c.ROBUX_POINTS) do
			if p == n then
				return true
			end
		end
		return false
	end
	for _, r in ipairs(c.ROWS) do
		local tag = tostring(r.key)
		if seen[r.key] then
			table.insert(errs, tag .. " duplicate key")
		end
		seen[r.key] = true
		for k in pairs(r :: any) do
			if not c.ROW_FIELDS[k] then
				table.insert(errs, string.format("%s has field %s (not allowed on an avatar)", tag, tostring(k)))
			end
		end
		scanTuning(r, tag, errs)
		local known = false
		for _, cl in ipairs(c.CLASSES) do
			known = known or cl == r.class
		end
		if not known then
			table.insert(errs, tag .. " unknown class " .. tostring(r.class))
		end
		local a = r.acquire
		if a.kind == "cash" then
			if type(a.price) ~= "number" or not bandOk(r.rarity, a.price) then
				table.insert(errs, string.format("%s Cash price %s outside the %s band", tag, tostring(a.price), r.rarity))
			end
		elseif a.kind == "robux" then
			if not robuxOk(a.robux) then
				table.insert(errs, tag .. " Robux label not 399/599/799")
			end
			if a.productId ~= nil then
				table.insert(errs, tag .. " product id must stay nil (bound at runtime)")
			end
			if type(a.productKey) ~= "string" then
				table.insert(errs, tag .. " Robux row without a product key")
			end
			if r.rarity == "legendary" then
				table.insert(errs, tag .. " top tier is earned only")
			end
		elseif a.kind == "earned" then
			if a.price ~= nil or a.productKey ~= nil or a.robux ~= nil then
				table.insert(errs, tag .. " earned row carries a price")
			end
			if c.EARNED_SOURCES and not c.EARNED_SOURCES[a.source or ""] then
				table.insert(errs, tag .. " unknown earned source")
			end
		elseif a.kind ~= "starter" and a.kind ~= "free" then
			table.insert(errs, tag .. " unknown acquire kind " .. tostring(a.kind))
		end
		if r.rarity == "legendary" and a.kind ~= "earned" then
			table.insert(errs, tag .. " legendary must be earned")
		end
		-- Ladder: unique ids, at least one reskin, tints only after the last reskin, needs grow step by step.
		local steps = r.ladder or c.LADDER
		local ids: { [string]: boolean } = {}
		local lastReskin, firstTint = 0, math.huge
		for i, step in ipairs(steps) do
			if ids[step.id] then
				table.insert(errs, tag .. " ladder duplicate step " .. step.id)
			end
			ids[step.id] = true
			if step.kind == "reskin" then
				lastReskin = i
			elseif step.kind == "tint" then
				firstTint = math.min(firstTint, i)
			else
				table.insert(errs, tag .. " ladder step kind " .. tostring(step.kind))
			end
			if not (step.need.races or step.need.wins or step.need.keys) then
				table.insert(errs, tag .. " ladder step " .. step.id .. " has no condition")
			end
			local prev = steps[i - 1]
			if prev and prev.need.races and step.need.races and step.need.races <= prev.need.races then
				table.insert(errs, tag .. " ladder races must grow at " .. step.id)
			end
		end
		if lastReskin == 0 then
			table.insert(errs, tag .. " ladder has no reskin")
		end
		if firstTint < lastReskin then
			table.insert(errs, tag .. " tints must come after the reskins")
		end
	end
	for _, class in ipairs(c.CLASSES) do
		local s = AvatarRules.row(c.STARTER[class], c)
		if not s or s.class ~= class or s.acquire.kind ~= "starter" then
			table.insert(errs, "starter for " .. class .. " must be a starter row of that class")
		end
		local m = c.MESHES[c.STARTER[class]]
		if not m then
			table.insert(errs, "starter for " .. class .. " has no mesh entry")
		end
	end
	for key, m in pairs(c.MESHES) do
		if not seen[key] then
			table.insert(errs, "mesh entry for unknown avatar " .. key)
		end
		scanTuning(m, "MESHES." .. key, errs)
	end
	return errs
end

return AvatarRules
