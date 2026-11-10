--!strict
-- One saved profile per player (docs/LAUNCH_PROGRESSION.md section 5; TEST_LIST_LAUNCH L18, L20-L23, L53, L70, L75).
-- * The server awards from its own finish, coin, boss, battle and pickup events. No RemoteEvent reaches award().
-- * A held reward is a logged no-op, so a double finish, a retry after finish or a rejoin cannot duplicate it.
-- * Records carry a session lock (server id, per-load token, timestamp, ttl). A write lands only while the lock is still
--   ours and a lock is taken over only once it is stale, so two servers never both write one record. The holder declares
--   its own ttl (lockTimeout, about 3 heartbeats: 90 s), so a crashed server's lock clears in 90 s instead of 180 s, and
--   a lock from an older build without a ttl keeps the old 180 s (LEGACY_LOCK_TTL) so a new server never steals a live
--   lock from an old one mid-publish. A takeover is recorded in the record (lastTakeover) and logged (T1-14).
-- * While a lock is held elsewhere the player sees "Saving paused" with the seconds left (SaveMessage, SaveResumeIn).
-- * A final save after leaving that fails every attempt is not dropped: it keeps retrying in the background under the
--   same lock token (orphanRetryWindow), a same-server rejoin adopts the unsaved snapshot, and BindToClose tries it
--   once more (T2-2).
-- * Every award saves, coalesced to Roblox's one write per key per 6 s; leave and BindToClose flush and unlock.
-- * A load that keeps failing leaves a readable error state and keeps retrying in the background. Nothing ever
--   substitutes a fresh profile for a record that exists but could not be read.
-- Roblox APIs sit behind Options (store, clocks, sleep/spawn, ids) so the Lune specs drive all of it with mocks.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Progression = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Progression"))
local FidelityRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FidelityRules"))
-- REMARKABLE item 22: the Lost Squeaky Ducks (one per launch map) and the Golden Quack horn they unlock.
local SetPieceRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SetPieceRules"))
-- L27: the "onboarded" flag name (settings slot; the first-session guide).
local OnboardingRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OnboardingRules"))
-- Battle access: which zones' battles are open (replicated) and the once-per-account explainer flag (settings slot).
local ExplainerRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ExplainerRules"))
local BattleAccessRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BattleAccessRules"))
-- Player settings (audit H13): the shape of profile.settings; progression never depends on it.
local SettingsRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SettingsRules"))
-- Storm Shards (economy v3 phase 5): the storm record's defaults and the attributes it replicates.
local StormRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StormRules"))
-- Economy v3 phase 6: vehicle avatars (owned, selected per class, per-avatar ladder progress, worn reskin).
local AvatarRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AvatarRules"))
-- T1-14: the session lock's ttl (holder-declared, legacy 180 s), shared with SaveAdmin and tools/save_admin.
local SaveLockRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SaveLockRules"))

local SaveService = {}

SaveService.CURRENT_VERSION = 2 -- v2 (REMARKABLE item 22): ducks
SaveService.STORE_NAME = "SkyRallyProfiles"
-- Owner admin (DECISIONS D22): set by server/AdminService. (userId, source) -> true only for the admin's own "admin:grant"
-- awards (AdminConfig.awardBypass); his gameplay awards keep every gate. nil = no admin path at all.
SaveService.adminBypass = nil :: ((userId: number, source: string) -> boolean)?
-- Owner admin (DECISIONS D22): set by server/AdminService. userId -> the admin's runtime map-access bypass is on, so his
-- BattlesOpen attribute lists every battle canOpen lets him start (the results card's BATTLE button). nil = nobody.
-- Progression analytics (T1-4): called with (player, unlockedKey) for each portal or mode a real award newly opened
-- (server/Funnels.progression). Set by the boot script; never throws into the award (pcall below).
SaveService.unlockHook = nil :: ((player: Player, key: string) -> ())?
SaveService.adminPortals = nil :: ((userId: number) -> boolean)?
local PROBE_STORE_NAME = "SkyRallyApiProbe"
local LOG = "[SkyRally][SAVE] "
-- Roblox allows BindToClose 30 s; the rest is headroom for store calls already in flight.
local BIND_TO_CLOSE_DEADLINE = 25
-- Awards that arrive before the profile loads wait here; a bound keeps a stuck load from growing it forever.
local MAX_PENDING_AWARDS = 32

export type BossState = Progression.BossState

export type Profile = {
	version: number,
	tokens: { [string]: boolean },
	boss: { [string]: BossState },
	fragments: number, -- derived: boss rematch wins
	keys: { [string]: boolean },
	battles: { [string]: boolean },
	battleFragments: number, -- derived: battle wins
	battleAmulet: boolean, -- derived: all four battle fragments
	finalBoss: boolean,
	ducks: { [string]: boolean }, -- trackId -> found its Lost Squeaky Duck (v2); all six own the Golden Quack horn
	bestTimes: { [string]: number }, -- trackId -> ms; only ever improves
	settings: { [string]: any },
	-- D16 cosmetic slots; the Battle Amulet livery lands in owned as a progression reward.
	cosmetics: {
		owned: { [string]: boolean },
		loadout: { [string]: string },
	},
	-- Economy slots reserved by MONETIZATION_PROPOSAL section 3; the economy lane writes them through edit().
	gears: number,
	winPass: {
		season: number,
		wins: number, -- first places (kept; the wins-era tiers read it)
		races: number, -- races finished this season: the Win Pass tiers (economy v3). Old records reconcile to 0
		premium: boolean,
		-- Tier keys are strings: "r5" for a races-era claim, the bare number ("1", "5") for a wins-era one (both kept;
		-- EconomyRules.winPassClaimed reads them). DataStore rejects sparse numeric keys.
		claimedFree: { [string]: boolean },
		claimedPremium: { [string]: boolean },
	},
	streak: {
		dailyDay: number, -- UTC day number of the last daily claim
		dailyCount: number, -- consecutive days, 1-7
		lastClaimAt: number, -- os.time() of the last claim
		loginShownDay: number, -- UTC day number the login popup last showed (economy v3 step 7); old records reconcile to 0 = due
	},
	-- PurchaseId -> gift this player received ({key, from, at}). The offline inbox is Economy's PendingGifts store;
	-- this ledger is what makes a gift land exactly once whichever path (live or inbox) delivers it.
	pendingGifts: { [string]: any },
	passCache: { [string]: boolean }, -- pass key -> last verified ownership (fallback while the API is down)
	-- Economy bookkeeping (src/server/Economy.luau); keys are strings because DataStore rejects sparse numeric keys.
	economy: {
		receipts: { [string]: any }, -- PurchaseId -> {at, ledger}: the grant landed in this profile
		oneTime: { [string]: boolean }, -- once-per-account products already bought (Rookie Pack)
		intents: { [string]: any }, -- product key -> {to?, choices?, at}: who a gift is for, which livery a set grants
		favorites: { [string]: boolean }, -- Garage+
		presets: { [string]: { [string]: string } }, -- Garage+ loadout slots "1".."3"
	},
	-- Storm Shards (economy v3 phase 5; shared/StormRules header has the shape). Additive: a record from before Shards
	-- reconciles to all zeros and empty tables, no version bump. Written only by server/StormShards through edit().
	storm: {
		shards: number, -- spendable at the Storm vendor
		lifetime: number, -- every Shard ever earned; sets the reputation tier; spending never lowers it
		races: number, -- storm races finished (Storm Racer badge)
		dragonWins: number, -- storm dragon beaten (Dragon Slayer / Hunter / Bane / Stormbreaker badges)
		bonusDay: number, -- UTC day of the last first-storm-finish-of-the-day bonus
		owned: { [string]: boolean }, -- StormConfig.VENDOR keys bought
		loadout: { [string]: string }, -- storm-only slot -> vendor key
	},
	-- Economy v3 phase 6 (AvatarRules header). Added without a version bump, like winPass.races: reconcile fills it for
	-- an old record (starters and free rows owned, starters selected) and derive settles it after every change.
	avatars: AvatarRules.State,
}

export type AwardKind = "token" | "hubFind" | "key" | "bossFirst" | "bossRematch" | "battle" | "finalBoss" | "bestTime" | "duck"
export type AwardResult = "awarded" | "noop" | "queued" | "rejected"
export type SaveState = "loading" | "ok" | "error"

-- One atomic read-modify-write attempt. transform must not yield; returning nil cancels the write. Returns ok, error.
export type Store = {
	kind: string,
	-- op = "load" | "save": which kind of call this is (only the Studio QA fault wrapper reads it, TG-1).
	update: (key: string, transform: (old: any) -> any, userIds: { number }?, op: string?) -> (boolean, string?),
	budget: (() -> number)?,
}

export type MemoryStore = {
	kind: string,
	update: (key: string, transform: (old: any) -> any, userIds: { number }?) -> (boolean, string?),
	budget: (() -> number)?,
	data: { [string]: any },
	writes: number,
}

export type Config = {
	writeCooldown: number, -- seconds between writes to one key (Roblox limit is 6)
	lockTimeout: number, -- a lock not refreshed for this long is stale and may be taken over
	lockRetry: number, -- seconds between load attempts while another server holds the lock
	loadAttempts: number, -- failures before the error state; retries continue in the background
	saveAttempts: number,
	backoffBase: number,
	backoffMax: number,
	budgetWaitMax: number,
	autosaveInterval: number, -- heartbeat that refreshes the lock; must stay well under lockTimeout
	releaseWait: number, -- how long a rejoin on this server waits for the previous session's unlock
	orphanRetryWindow: number, -- how long a failed final save keeps retrying in the background after the player left
	keyPrefix: string,
}

export type ConfigOverrides = {
	writeCooldown: number?,
	lockTimeout: number?,
	lockRetry: number?,
	loadAttempts: number?,
	saveAttempts: number?,
	backoffBase: number?,
	backoffMax: number?,
	budgetWaitMax: number?,
	autosaveInterval: number?,
	releaseWait: number?,
	orphanRetryWindow: number?,
	keyPrefix: string?,
}

export type Options = {
	store: Store,
	backend: string?,
	sessionId: string?, -- this server; JobId live
	newToken: (() -> string)?, -- unique per load
	now: (() -> number)?, -- wall clock shared by servers (lock age)
	clock: (() -> number)?, -- local monotonic clock (cooldowns, deadlines)
	sleep: ((number) -> ())?,
	spawn: ((() -> ()) -> ())?,
	log: ((string) -> ())?,
	random: (() -> number)?,
	config: ConfigOverrides?,
	-- Owner admin (DECISIONS D22): (userId, award source) -> the admin's award gates are open. Default: SaveService.adminBypass.
	adminBypass: ((userId: number, source: string) -> boolean)?,
	-- Studio QA (TG-4): the stored profile id a joining player loads under (nil = his own UserId). Set only by the default
	-- Studio wiring (workspace QASaveAs); every spec and every live server leaves it nil.
	resolveId: ((player: Player) -> number?)?,
}

export type Service = {
	backend: string,
	config: Config,
	load: (player: Player) -> (Profile?, SaveState),
	award: (player: Player, kind: AwardKind, id: string, sourceEvent: string, value: number?) -> (AwardResult, { string }),
	edit: (player: Player, reason: string, fn: (Profile) -> ()) -> boolean,
	get: (player: Player) -> Profile?,
	status: (player: Player) -> SaveState?,
	release: (player: Player, deadline: number?) -> boolean,
	flushAll: (seconds: number) -> boolean,
	heartbeat: () -> (),
	-- Waits until every change made so far is durably written (receipts grant only after this). false on timeout,
	-- a lost session or no profile.
	flush: (player: Player, timeout: number?) -> boolean,
	-- fn(player) runs in its own task once a profile has loaded (Economy: pass checks, gift inbox, toasts).
	onLoaded: (fn: (Player) -> ()) -> (),
	-- userIds whose final save is still retrying in the background (T2-2); for logs and specs.
	orphans: () -> { number },
}

type PendingAward = {
	kind: AwardKind,
	id: string,
	source: string,
	value: number?,
}

type LoadOutcome = "ok" | "locked" | "failed" | "corrupt" | "newer"
type WriteOutcome = "ok" | "lost" | "failed"

type PlayerState = {
	player: Player,
	userId: number,
	key: string,
	token: string,
	status: SaveState,
	profile: Profile?,
	pending: { PendingAward },
	dirty: boolean,
	saving: boolean,
	writing: boolean,
	released: boolean,
	releaseResult: boolean?,
	sessionLost: boolean,
	lastWriteAt: number,
	lastOutcome: LoadOutcome?,
	changeSeq: number, -- bumped by every change that needs saving
	savedSeq: number, -- changeSeq covered by the last write that landed
	adopt: Orphan?, -- a same-server rejoin's unsaved snapshot from the previous session (T2-2)
	lockRemaining: number?, -- seconds until the other server's lock goes stale (the "Saving paused" notice)
}

-- A final save that failed every attempt after the player left: retried in the background under the same lock token.
type Orphan = {
	userId: number,
	key: string,
	token: string,
	snapshot: Profile,
	startedAt: number,
	cancelled: boolean,
	writing: boolean,
	done: boolean,
}

SaveService.DEFAULT_CONFIG = {
	writeCooldown = 6,
	-- T1-14: 3 heartbeats (was 180 s with a 60 s heartbeat). A crashed server's lock now clears in 90 s; a live holder
	-- refreshes every 30 s and may miss two refreshes (a DataStore hiccup) before another server may take over.
	lockTimeout = 90,
	lockRetry = 5,
	loadAttempts = 5,
	saveAttempts = 5,
	backoffBase = 1,
	backoffMax = 30,
	budgetWaitMax = 10,
	autosaveInterval = 30,
	releaseWait = 10,
	orphanRetryWindow = 900,
	keyPrefix = "u_",
} :: Config

-- Lock ttl rules live in shared/SaveLockRules (also read by SaveAdmin and tools/save_admin).
SaveService.LEGACY_LOCK_TTL = SaveLockRules.LEGACY_TTL
SaveService.lockTtl = SaveLockRules.ttl

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value :: any) do
		out[deepCopy(k)] = deepCopy(v)
	end
	return (out :: any) :: T
end

local function deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, v in pairs(value :: any) do
			deepFreeze(v)
		end
		table.freeze(value :: any)
	end
	return value
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- DataStore stores JSON: finite numbers, strings, booleans, proper arrays or string-keyed dictionaries.
local function checkSerializable(value: any, path: string)
	local kind = type(value)
	if kind == "string" or kind == "boolean" then
		return
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error(path .. " is not a finite number", 0)
		end
		return
	elseif kind ~= "table" then
		error(path .. " has unsupported type " .. kind, 0)
	end
	local length = #value
	local count = 0
	for k, v in pairs(value) do
		count += 1
		if type(k) == "number" then
			if length == 0 or k ~= math.floor(k) or k < 1 or k > length then
				error(path .. " mixes array and dictionary keys", 0)
			end
		elseif type(k) ~= "string" then
			error(path .. " has a " .. type(k) .. " key", 0)
		end
		checkSerializable(v, path .. "." .. tostring(k))
	end
	if length > 0 and count ~= length then
		error(path .. " mixes array and dictionary keys", 0)
	end
end

-- Flat string map -> JSON with sorted keys, so the Equipped attribute only changes when the loadout does. Client
-- side: HttpService:JSONDecode.
local function jsonString(s: string): string
	return '"' .. (string.gsub(s, '[%c"\\]', function(c: string): string
		return string.format("\\u%04x", string.byte(c))
	end)) .. '"'
end

local function encodeLoadout(loadout: { [string]: string }): string
	local keys = {}
	for k, v in pairs(loadout) do
		if type(k) == "string" and type(v) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		table.insert(parts, jsonString(k) .. ":" .. jsonString(loadout[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
SaveService.encodeLoadout = encodeLoadout

local function newBossTable(): { [string]: BossState }
	local boss: { [string]: BossState } = {}
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		boss[zone] = { first = false, rematch = false }
	end
	return boss
end

function SaveService.newProfile(): Profile
	return {
		version = SaveService.CURRENT_VERSION,
		tokens = {},
		boss = newBossTable(),
		fragments = 0,
		keys = {},
		battles = {},
		battleFragments = 0,
		battleAmulet = false,
		finalBoss = false,
		ducks = {},
		bestTimes = {},
		settings = {},
		cosmetics = { owned = {}, loadout = {} },
		gears = 0,
		winPass = { season = 1, wins = 0, races = 0, premium = false, claimedFree = {}, claimedPremium = {} },
		streak = { dailyDay = 0, dailyCount = 0, lastClaimAt = 0, loginShownDay = 0 },
		pendingGifts = {},
		passCache = {},
		economy = { receipts = {}, oneTime = {}, intents = {}, favorites = {}, presets = {} },
		storm = StormRules.defaults(),
		avatars = AvatarRules.defaultState(),
	}
end

-- Fills fields added after a record was written and resets wrong-typed ones. Unknown fields are kept so a server
-- running older code never strips what a newer build wrote.
local function reconcile(target: { [any]: any }, defaults: { [any]: any })
	for k, default in pairs(defaults) do
		local current = target[k]
		if type(current) ~= type(default) then
			target[k] = deepCopy(default)
		elseif type(default) == "table" then
			reconcile(current, default)
		end
	end
end

-- Stored counters are recomputed from their source flags so they can never drift from what was actually won.
local function derive(profile: Profile)
	profile.fragments = Progression.bossFragmentCount(profile)
	profile.battleFragments = Progression.battleFragmentCount(profile)
	profile.battleAmulet = profile.battleFragments >= Progression.BATTLE_FRAGMENTS_TOTAL
	-- Owned exactly when the amulet is complete: an economy edit or shop bug can never grant this livery.
	if profile.battleAmulet then
		profile.cosmetics.owned[Progression.BATTLE_AMULET_LIVERY] = true
	else
		profile.cosmetics.owned[Progression.BATTLE_AMULET_LIVERY] = nil
	end
	-- The Golden Quack horn (item 22) the same way: owned exactly when all six ducks are home; secret-only, never sold.
	if SetPieceRules.hasAllDucks(profile.ducks) then
		profile.cosmetics.owned[SetPieceRules.GOLDEN_QUACK] = true
	else
		profile.cosmetics.owned[SetPieceRules.GOLDEN_QUACK] = nil
	end
	-- Avatars (phase 6): earned rows follow their source the same way (final boss, Battle Amulet; the Storm vendor's top
	-- tier joins when Storm Shards land), starters stay owned, a bad pick falls back to the class starter.
	profile.avatars = AvatarRules.settle(profile.avatars, {
		campaign = profile.finalBoss == true,
		amulet = profile.battleAmulet == true,
		storm = false,
	})
end

-- MIGRATIONS[v] turns a version-v record into version v + 1. Add a step and bump CURRENT_VERSION; never edit a step
-- that has shipped.
local MIGRATIONS: { [number]: (any) -> any } = {
	-- v0: records from before the versioned schema (no `version`). Race wins were keyed by bare track id, section 5's
	-- tokens{trackId:bool}; v1 keys them "race:<trackId>" because every track also carries a coin token.
	[0] = function(old: any): any
		local tokens = if type(old.tokens) == "table" then old.tokens else {}
		for _, trackId in ipairs(Progression.RACE_TRACKS) do
			if tokens[trackId] == true then
				tokens[Progression.raceTokenId(trackId)] = true
			end
			tokens[trackId] = nil
		end
		old.tokens = tokens
		return old
	end,
	-- v1 -> v2 (REMARKABLE item 22): the Lost Squeaky Ducks. Only `true` entries for the launch maps carry over; anything
	-- else a v1 record held under that name is dropped (no v1 build wrote it).
	[1] = function(old: any): any
		local ducks = {}
		if type(old.ducks) == "table" then
			for _, id in ipairs(SetPieceRules.DUCK_TRACKS) do
				if old.ducks[id] == true then
					ducks[id] = true
				end
			end
		end
		old.ducks = ducks
		return old
	end,
}
SaveService.MIGRATIONS = MIGRATIONS

-- Returns the current-version profile and the version it migrated from (nil when already current). Errors on data
-- it cannot read, so the caller cancels the write instead of overwriting it.
function SaveService.migrate(raw: any): (Profile, number?)
	if type(raw) ~= "table" then
		error("profile is a " .. type(raw) .. ", not a table", 0)
	end
	local data = deepCopy(raw)
	local version = tonumber(data.version) or 0
	-- A newer build wrote this. Loading it here would let reconcile reset fields whose type changed and write them
	-- back, so an old server still running after a publish refuses the record instead of downgrading it.
	if version > SaveService.CURRENT_VERSION then
		error(string.format("record version %d is newer than this server's %d", version, SaveService.CURRENT_VERSION), 0)
	end
	local from: number? = nil
	while version < SaveService.CURRENT_VERSION do
		local step = MIGRATIONS[version]
		if not step then
			error("no migration from version " .. tostring(version), 0)
		end
		from = from or version
		data = step(data)
		version += 1
		data.version = version
	end
	reconcile(data, SaveService.newProfile() :: any)
	local profile = data :: Profile
	-- H13: a bad settings value (wrong type, volume outside 0..1) is repaired here, never allowed to fail the load; the
	-- version stays 2 because settings was always part of v2 and a bump would lock out servers still on the old build.
	SettingsRules.sanitizeStored(profile.settings)
	derive(profile)
	return profile, from
end

local PROGRESSION_FIELDS = { "tokens", "boss", "keys", "battles", "finalBoss", "ducks", "bestTimes", "version" }

local function ownedReward(profile: any, key: string): any
	local cosmetics = profile.cosmetics
	local owned = if type(cosmetics) == "table" then cosmetics.owned else nil
	return if type(owned) == "table" then owned[key] else nil
end

local function progressionChanged(before: Profile, after: Profile): boolean
	for _, field in ipairs(PROGRESSION_FIELDS) do
		if not deepEqual((before :: any)[field], (after :: any)[field]) then
			return true
		end
	end
	-- The Battle Amulet livery and the Golden Quack horn are progression rewards that live in the cosmetics slot; edit()
	-- can neither sell nor remove them.
	return ownedReward(before, Progression.BATTLE_AMULET_LIVERY) ~= ownedReward(after, Progression.BATTLE_AMULET_LIVERY)
		or ownedReward(before, SetPieceRules.GOLDEN_QUACK) ~= ownedReward(after, SetPieceRules.GOLDEN_QUACK)
end

local function mergeConfig(overrides: ConfigOverrides?): Config
	local d = SaveService.DEFAULT_CONFIG
	local o: ConfigOverrides = overrides or {}
	return {
		writeCooldown = o.writeCooldown or d.writeCooldown,
		lockTimeout = o.lockTimeout or d.lockTimeout,
		lockRetry = o.lockRetry or d.lockRetry,
		loadAttempts = o.loadAttempts or d.loadAttempts,
		saveAttempts = o.saveAttempts or d.saveAttempts,
		backoffBase = o.backoffBase or d.backoffBase,
		backoffMax = o.backoffMax or d.backoffMax,
		budgetWaitMax = o.budgetWaitMax or d.budgetWaitMax,
		autosaveInterval = o.autosaveInterval or d.autosaveInterval,
		releaseWait = o.releaseWait or d.releaseWait,
		orphanRetryWindow = o.orphanRetryWindow or d.orphanRetryWindow,
		keyPrefix = o.keyPrefix or d.keyPrefix,
	}
end

local ERROR_MESSAGES: { [string]: string } = {
	failed = "Could not load your progress: the Roblox data service is not answering. Retrying; nothing is lost.",
	corrupt = "Your save could not be read. Retrying; it has not been overwritten.",
	locked = "Your progress is still open on another server. Retrying until it closes.",
	newer = "Your progress was saved by a newer version of SkyRally. Rejoin to get the update; nothing is lost.",
}

-- T1-14: the notice while another server still holds this player's lock. Awards are queued and land after the load;
-- Cash payouts (Economy edits) are refused until then, so the notice says so instead of failing silently.
function SaveService.pausedMessage(remaining: number?): string
	if type(remaining) == "number" and remaining > 0 then
		return string.format(
			"Saving paused: your progress is still open on another server. Back in about %d s; Cash earned until then is not saved.",
			math.max(5, 5 * math.ceil(remaining / 5))
		)
	end
	return "Saving paused: your progress is still open on another server. Waiting for it to close."
end

function SaveService.new(options: Options): Service
	local store = options.store
	local cfg = mergeConfig(options.config)
	local sessionId = options.sessionId or "server"
	local newToken = options.newToken or function(): string
		return HttpService:GenerateGUID(false)
	end
	local now = options.now or function(): number
		return os.time()
	end
	local clock = options.clock or function(): number
		return os.clock()
	end
	local sleep = options.sleep or function(seconds: number)
		task.wait(seconds)
	end
	local spawnTask = options.spawn or function(fn: () -> ())
		task.spawn(fn)
	end
	local log = options.log or function(line: string)
		print(line)
	end
	local random = options.random or function(): number
		return math.random()
	end
	-- Owner admin (DECISIONS D22): whether this user's award gates are open for this source (server/AdminService sets
	-- SaveService.adminBypass; nil everywhere else, so the answer is false for every player).
	local adminBypass = options.adminBypass or function(userId: number, source: string): boolean
		local hook = SaveService.adminBypass
		return hook ~= nil and hook(userId, source) == true
	end

	local states: { [Player]: PlayerState } = {}
	local releasing: { [number]: boolean } = {}
	local orphans: { [number]: Orphan } = {}
	local loadedHandlers: { (Player) -> () } = {}

	local function setStatus(st: PlayerState, status: SaveState, message: string)
		st.status = status
		st.player:SetAttribute("SaveState", status)
		st.player:SetAttribute("SaveMessage", message)
	end

	-- Compact HUD summary; the full profile never replicates.
	local function replicate(st: PlayerState)
		local profile = st.profile
		if not profile then
			return
		end
		st.player:SetAttribute("SkyTokens", Progression.tokenCount(profile))
		st.player:SetAttribute("Keys", Progression.keyCount(profile))
		-- J3: the board's progress line, plus the full completion text and roadmap once everything is done.
		st.player:SetAttribute(FidelityRules.COMPLETION_ATTRIBUTE, FidelityRules.encode(Progression.completion(profile)))
		st.player:SetAttribute("BossFragments", profile.fragments)
		st.player:SetAttribute("BattleFragments", profile.battleFragments)
		-- Economy HUD bits (MONETIZATION_PROPOSAL section 3): wallet, equipped loadout (other clients draw trails and
		-- liveries from it) and Win Pass wins.
		st.player:SetAttribute("Gears", profile.gears)
		st.player:SetAttribute("Equipped", encodeLoadout(profile.cosmetics.loadout))
		st.player:SetAttribute("WinPassWins", profile.winPass.wins)
		st.player:SetAttribute("WinPassRaces", profile.winPass.races)
		-- Storm Shards (economy v3 phase 5): balance, lifetime (the tier), dragon wins and the storm-only loadout (other
		-- clients draw titles, borders, flags and effects from it once their art lands).
		local storm = StormRules.read(profile)
		st.player:SetAttribute("StormShards", storm.shards)
		st.player:SetAttribute("StormShardsLifetime", storm.lifetime)
		st.player:SetAttribute("StormTier", StormRules.tierFor(storm.lifetime).id)
		st.player:SetAttribute("StormDragonWins", storm.dragonWins)
		st.player:SetAttribute("StormLoadout", StormRules.encodeLoadout(storm.loadout))
		-- Phase 6: the pick per class (the pre-race pick preselects it; the spawners read the profile itself).
		st.player:SetAttribute("AvatarPlane", profile.avatars.selected.plane)
		st.player:SetAttribute("AvatarCar", profile.avatars.selected.car)
		-- Lost Squeaky Ducks (item 22): the count and the held maps ("DINO-4,SNOW-1"); clients hide a found duck.
		st.player:SetAttribute("Ducks", SetPieceRules.duckCount(profile.ducks))
		st.player:SetAttribute("DucksHeld", table.concat(SetPieceRules.duckList(profile.ducks), ","))
		-- L27: the first-session guide runs once per account; the client reads this once the profile has loaded.
		st.player:SetAttribute("Onboarded", profile.settings[OnboardingRules.FLAG] == true)
		-- Battle access: zones whose battle is open (map finished or key found) and whether the explainer was shown.
		-- The flag goes first: the client treats a missing BattleIntroSeen as "profile not loaded yet".
		-- T1-15: the first-time explainers already answered ("items,keys") and the skip-all switch.
		local seenExplainers, skipExplainers = ExplainerRules.read(profile.settings)
		st.player:SetAttribute(ExplainerRules.ATTR, ExplainerRules.encode(seenExplainers))
		st.player:SetAttribute(ExplainerRules.SKIP_ATTR, skipExplainers)
		st.player:SetAttribute(BattleAccessRules.INTRO_ATTR, profile.settings[BattleAccessRules.INTRO_FLAG] == true)
		st.player:SetAttribute(BattleAccessRules.ATTR, BattleAccessRules.encode(Progression.battleZones(profile)))
		-- D22: the admin's map-access bypass (runtime only, nothing saved) also opens his battles; nil hook = nobody.
		local portalsHook = SaveService.adminPortals
		if portalsHook and portalsHook(st.userId) == true then
			st.player:SetAttribute(BattleAccessRules.ATTR, BattleAccessRules.encode(Progression.battleZones(profile, true)))
		end
	end

	local function backoff(attempt: number): number
		local base = math.min(cfg.backoffMax, cfg.backoffBase * 2 ^ (attempt - 1))
		-- Jitter keeps many servers recovering from one outage from retrying in lockstep.
		return base * (0.75 + 0.5 * random())
	end

	local function active(st: PlayerState): boolean
		return not st.released and st.player.Parent ~= nil
	end

	local function waitForBudget(deadline: number?)
		local budgetFn = store.budget
		if not budgetFn then
			return
		end
		local waited = 0
		while waited < cfg.budgetWaitMax do
			local ok, remaining = pcall(budgetFn)
			if not ok or remaining >= 1 then
				return
			end
			if deadline and clock() >= deadline then
				return
			end
			if waited == 0 then
				log(LOG .. "request budget exhausted; waiting")
			end
			sleep(0.5)
			waited += 0.5
		end
	end

	local claimOrphan: (userId: number, deadline: number?) -> Orphan? -- defined with the background retry below

	local function loadOnce(st: PlayerState): (LoadOutcome, string?)
		-- T2-2: a same-server rejoin while the previous session's final save is still retrying adopts that snapshot
		-- (checked on every attempt: the earlier release may hand over its snapshot while this load waits).
		if st.adopt == nil and orphans[st.userId] then
			st.adopt = claimOrphan(st.userId, nil)
		end
		local outcome: LoadOutcome = "failed"
		local detail: string? = nil
		local loaded: Profile? = nil
		local migratedFrom: number? = nil
		local isNew = false
		local adopted = false
		local takeover: any = nil
		local remaining: number? = nil
		local stamp = now()
		st.writing = true
		local ok, err = store.update(st.key, function(old: any): any
			-- DataStore may run the transform more than once; every run starts from scratch.
			outcome, detail, loaded, migratedFrom, isNew, adopted, takeover, remaining =
				"failed", nil, nil, nil, false, false, nil, nil
			if old ~= nil and type(old) ~= "table" then
				outcome = "corrupt"
				detail = "record is a " .. type(old)
				return nil
			end
			local record = if old == nil then {} else old
			local session = record.session
			local adopt = st.adopt
			if type(session) == "table" and session.token ~= st.token then
				local age = stamp - (tonumber(session.lockedAt) or 0)
				local ttl = SaveService.lockTtl(session)
				-- This server's own lock is takeable at once, unless that user's previous session is still making its
				-- final write: a takeover then would make that write "lost" and drop the last changes (L20).
				if (session.id ~= sessionId or releasing[st.userId]) and age < ttl then
					outcome = "locked"
					remaining = math.max(0, ttl - age)
					detail = if session.id == sessionId
						then string.format("this server's earlier session is still saving, refreshed %ds ago", math.floor(age))
						else string.format("held by %s, refreshed %ds ago, stale in %ds", tostring(session.id), math.floor(age), math.ceil(ttl - age))
					return nil
				end
				detail = if session.id == sessionId
					then "took over this server's earlier session"
					else string.format("took over stale lock from %s (%ds old, ttl %ds)", tostring(session.id), math.floor(age), ttl)
				-- T2-2: this server's earlier session left with its final save still retrying; its snapshot is newer than
				-- the stored profile (same lock token), so the rejoin starts from it instead of the older record.
				adopted = adopt ~= nil and session.id == sessionId and session.token == adopt.token
				if session.id ~= sessionId then
					takeover = { from = tostring(session.id), age = math.floor(age), at = stamp, by = sessionId }
				end
			end
			local storedVersion = if type(record.profile) == "table" then tonumber(record.profile.version) else nil
			if adopted and adopt then
				loaded = deepCopy(adopt.snapshot)
			elseif record.profile == nil then
				loaded = SaveService.newProfile()
				isNew = true
			elseif storedVersion and storedVersion > SaveService.CURRENT_VERSION then
				outcome = "newer"
				detail = string.format("record version %d, server version %d", storedVersion, SaveService.CURRENT_VERSION)
				return nil
			else
				local okMigrate, result, from = pcall(SaveService.migrate, record.profile)
				if not okMigrate then
					outcome = "corrupt"
					detail = tostring(result)
					return nil
				end
				loaded = result
				migratedFrom = from
			end
			record.profile = deepCopy(loaded)
			record.session = { id = sessionId, token = st.token, lockedAt = stamp, ttl = cfg.lockTimeout }
			record.savedAt = stamp
			if takeover then
				-- Kept in the record for the save inspect tool (tools/save_admin, /admin save inspect).
				record.lastTakeover = takeover
			end
			outcome = "ok"
			return record
		end, { st.userId }, "load")
		st.writing = false
		st.lockRemaining = remaining
		if not ok then
			return "failed", err
		end
		if outcome == "ok" and adopted then
			log(string.format("%sadopted unsaved final snapshot user=%d (same-server rejoin)", LOG, st.userId))
		elseif outcome == "ok" and st.adopt then
			-- The record moved on (another server took the lock, or a restore cleared it): the stored record wins.
			log(string.format("%sfinal save DROPPED user=%d: record no longer under the earlier session's lock", LOG, st.userId))
		end
		if outcome == "ok" then
			st.adopt = nil
		end
		if outcome == "ok" and loaded then
			st.profile = loaded
			st.lastWriteAt = clock()
			log(
				string.format(
					"%sload user=%d version=%d new=%s migratedFrom=%s tokens=%d session=%s%s",
					LOG,
					st.userId,
					loaded.version,
					tostring(isNew),
					tostring(migratedFrom),
					Progression.tokenCount(loaded),
					sessionId,
					if detail then " (" .. detail .. ")" else ""
				)
			)
		end
		return outcome, detail
	end

	-- Loads until success, until maxFailures store failures, or until a held lock outlasts its own timeout.
	local function attemptLoad(st: PlayerState, maxFailures: number): boolean
		local failures = 0
		local lockWaited = 0
		local lockBudget = cfg.lockTimeout + 2 * cfg.lockRetry
		while active(st) do
			waitForBudget(nil)
			if not active(st) then
				-- The player left during the budget wait; loading now would take a lock nobody releases.
				break
			end
			local outcome: LoadOutcome, detail: string? = loadOnce(st)
			st.lastOutcome = outcome
			if outcome == "ok" then
				return true
			elseif outcome == "locked" then
				-- Not a failure: the other server unlocks on leave, or its lock goes stale after lockTimeout.
				if lockWaited == 0 then
					log(string.format("%slock wait user=%d: %s", LOG, st.userId, tostring(detail)))
					-- The holder's own ttl (a legacy 180 s lock outlasts this server's 90 s) sets how long this wait runs.
					lockBudget = math.max(cfg.lockTimeout, st.lockRemaining or 0) + 2 * cfg.lockRetry
				end
				if lockWaited >= lockBudget then
					return false
				end
				if st.status ~= "error" then
					setStatus(st, "loading", SaveService.pausedMessage(st.lockRemaining))
				end
				st.player:SetAttribute("SaveResumeIn", if st.lockRemaining then math.ceil(st.lockRemaining) else nil)
				sleep(cfg.lockRetry)
				lockWaited += cfg.lockRetry
			else
				failures += 1
				log(string.format("%sload %s user=%d attempt=%d: %s", LOG, outcome, st.userId, failures, tostring(detail)))
				if failures >= maxFailures then
					return false
				end
				sleep(backoff(failures))
			end
		end
		return false
	end

	-- One write of snapshot under lock token; final also clears the lock. Lands only while the lock is still token's.
	local function writeRecord(key: string, token: string, userId: number, snapshot: Profile, final: boolean): (WriteOutcome, string?)
		local stamp = now()
		local outcome: WriteOutcome = "failed"
		local ok, err = store.update(key, function(old: any): any
			outcome = "failed"
			if type(old) ~= "table" or type(old.session) ~= "table" or old.session.token ~= token then
				outcome = "lost"
				return nil
			end
			old.profile = snapshot
			old.savedAt = stamp
			if final then
				old.session = nil
			else
				old.session.lockedAt = stamp
				old.session.ttl = cfg.lockTimeout
			end
			outcome = "ok"
			return old
		end, { userId }, "save")
		if not ok then
			return "failed", err
		end
		return outcome, nil
	end

	local function writeOnce(st: PlayerState, final: boolean): (WriteOutcome, string?)
		local profile = st.profile
		if not profile then
			return "failed", "no profile"
		end
		local seq = st.changeSeq
		st.writing = true
		local outcome: WriteOutcome, err: string? = writeRecord(st.key, st.token, st.userId, deepCopy(profile), final)
		st.writing = false
		st.lastWriteAt = clock()
		if outcome == "failed" then
			return "failed", err
		end
		if outcome == "ok" then
			st.savedSeq = math.max(st.savedSeq, seq)
		end
		return outcome, nil
	end

	local function onSessionLost(st: PlayerState)
		if st.sessionLost then
			return
		end
		st.sessionLost = true
		log(string.format("%ssession lost user=%d: another server took the lock; this server stops writing", LOG, st.userId))
		setStatus(st, "error", "Your progress was opened on another server. Rejoin to keep playing; nothing here saves.")
	end

	-- T2-2: the final save after a leave failed every attempt. The snapshot keeps retrying under the same lock token
	-- (budget-aware, backoff up to backoffMax) until it lands, another server takes the lock over ("lost"), a same-server
	-- rejoin adopts it, or orphanRetryWindow runs out. Every outcome logs one line.
	local function startOrphan(userId: number, key: string, token: string, snapshot: Profile)
		local o: Orphan = {
			userId = userId,
			key = key,
			token = token,
			snapshot = deepCopy(snapshot),
			startedAt = clock(),
			cancelled = false,
			writing = false,
			done = false,
		}
		orphans[userId] = o
		log(string.format("%sfinal save queued for background retry user=%d window=%ds", LOG, o.userId, cfg.orphanRetryWindow))
		spawnTask(function()
			local attempt = 0
			local result = "window expired"
			while not o.cancelled and not o.done do
				attempt += 1
				sleep(backoff(cfg.saveAttempts + attempt))
				if o.cancelled or o.done then
					break
				end
				if clock() - o.startedAt > cfg.orphanRetryWindow then
					break
				end
				waitForBudget(nil)
				if o.cancelled or o.done then
					break
				end
				o.writing = true
				local outcome, err = writeRecord(o.key, o.token, o.userId, o.snapshot, true)
				o.writing = false
				if outcome == "ok" then
					result = "saved"
					break
				elseif outcome == "lost" then
					result = "lost (another server took the lock)"
					break
				end
				log(string.format("%sbackground final save failed user=%d attempt=%d: %s", LOG, o.userId, attempt, tostring(err)))
			end
			if o.cancelled then
				return -- adopted by a rejoin or written by flushAll; they log their own line
			end
			o.done = true
			if orphans[o.userId] == o then
				orphans[o.userId] = nil
			end
			if result == "saved" then
				log(string.format("%sbackground final save landed user=%d after %d tries", LOG, o.userId, attempt))
			else
				log(string.format("%sfinal save DROPPED user=%d after %d background tries: %s", LOG, o.userId, attempt, result))
			end
		end)
	end

	-- Stops an orphan's loop (waiting out a write in flight) and hands it back; nil when there is none.
	claimOrphan = function(userId: number, deadline: number?): Orphan?
		local o = orphans[userId]
		if not o or o.done then
			return nil
		end
		o.cancelled = true
		while o.writing and (not deadline or clock() < deadline) do
			sleep(0.1)
		end
		orphans[userId] = nil
		return o
	end

	local function runSaves(st: PlayerState)
		if st.saving then
			return
		end
		st.saving = true
		local failures = 0
		while st.dirty and st.profile and not st.sessionLost and not st.released do
			local since = clock() - st.lastWriteAt
			if since < cfg.writeCooldown then
				sleep(cfg.writeCooldown - since)
			end
			if st.released then
				break -- release() makes the final write itself
			end
			waitForBudget(nil)
			if st.released then
				break
			end
			st.dirty = false
			local outcome, err = writeOnce(st, false)
			if outcome == "ok" then
				failures = 0
				if st.status == "error" then
					setStatus(st, "ok", "")
				end
			elseif outcome == "lost" then
				onSessionLost(st)
			else
				st.dirty = true
				failures += 1
				log(string.format("%ssave failed user=%d attempt=%d: %s", LOG, st.userId, failures, tostring(err)))
				if failures >= cfg.saveAttempts and st.status ~= "error" then
					setStatus(st, "error", "Progress not saved yet: the Roblox data service is not answering. Retrying.")
				end
				sleep(backoff(failures))
			end
		end
		st.saving = false
	end

	local function requestSave(st: PlayerState)
		if not st.profile or st.released or st.sessionLost then
			return
		end
		st.dirty = true
		st.changeSeq += 1
		if not st.saving then
			spawnTask(function()
				runSaves(st)
			end)
		end
	end

	local function applyAward(st: PlayerState, kind: string, id: string, source: string, value: number?): AwardResult
		local profile = st.profile :: Profile
		local function noop(reason: string): AwardResult
			log(string.format("%snoop user=%d kind=%s id=%s source=%s (%s)", LOG, st.userId, kind, id, source, reason))
			return "noop"
		end
		local function reject(reason: string): AwardResult
			log(string.format("%sreject user=%d kind=%s id=%s source=%s (%s)", LOG, st.userId, kind, id, source, reason))
			return "rejected"
		end
		-- Owner admin (DECISIONS D22): only the admin's own explicit grants ("admin:" sources, written by server/AdminService
		-- alone) skip the unlock gates. Decided first; false for everyone else, so every gate below is unchanged.
		local adminOpen = adminBypass(st.userId, source)
		-- Order matters: a held reward is a no-op before any gate is consulted, so replays always log noop.
		if kind == "token" or kind == "hubFind" then
			local info = Progression.TOKEN_INFO[id]
			if not info or (info.kind == "hub") ~= (kind == "hubFind") then
				return reject("unknown " .. kind)
			end
			if profile.tokens[id] then
				return noop("already held")
			end
			local trackId = info.trackId
			if trackId and not Progression.isModeUnlocked(profile, trackId, info.kind, adminOpen) then
				return reject(info.kind .. " not unlocked")
			end
			profile.tokens[id] = true
		elseif kind == "key" then
			local zone = Progression.zoneOf(id)
			if not zone or not Progression.isChainZone(zone) then
				return reject("no key in this zone")
			end
			if profile.keys[zone] then
				return noop("already held")
			end
			if not Progression.isPortalOpen(profile, zone, adminOpen) then
				return reject("portal closed")
			end
			profile.keys[zone] = true
		elseif kind == "bossFirst" or kind == "bossRematch" or kind == "battle" then
			local zone = Progression.zoneOf(id)
			if not zone or not Progression.isChainZone(zone) then
				return reject("no " .. kind .. " in this zone")
			end
			local trackId = Progression.ZONE_TRACK[zone]
			if kind == "battle" then
				if profile.battles[zone] then
					return noop("already held")
				end
				if not Progression.isModeUnlocked(profile, trackId, "battle", adminOpen) then
					return reject("battle not unlocked")
				end
				profile.battles[zone] = true
			else
				local boss = profile.boss[zone]
				local isFirst = kind == "bossFirst"
				if (isFirst and boss.first) or (not isFirst and boss.rematch) then
					return noop("already held")
				end
				if not Progression.isModeUnlocked(profile, trackId, if isFirst then "boss" else "rematch", adminOpen) then
					return reject((if isFirst then "boss" else "rematch") .. " not unlocked")
				end
				if isFirst then
					boss.first = true
				else
					boss.rematch = true
				end
			end
		elseif kind == "finalBoss" then
			if profile.finalBoss then
				return noop("already held")
			end
			if not Progression.isModeUnlocked(profile, Progression.HUB_TRACK, "boss", adminOpen) then
				return reject("final boss not unlocked")
			end
			profile.finalBoss = true
		elseif kind == "duck" then
			-- A Lost Squeaky Duck (item 22): secret, so no unlock gate; one per launch map, kept forever.
			if not SetPieceRules.isDuckTrack(id) then
				return reject("no duck on this track")
			end
			if profile.ducks[id] then
				return noop("already held")
			end
			profile.ducks[id] = true
		elseif kind == "bestTime" then
			local info = Progression.TRACKS[id]
			if not info or not info.zone then
				return reject("no time trial on this track")
			end
			if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
				return reject("bad time " .. tostring(value))
			end
			local ms = math.floor(value + 0.5)
			local previous = profile.bestTimes[id]
			if type(previous) == "number" and previous <= ms then
				return noop(string.format("%d ms is not faster than %d ms", ms, previous))
			end
			if not Progression.isModeUnlocked(profile, id, "timetrial", adminOpen) then
				return reject("track not unlocked")
			end
			profile.bestTimes[id] = ms
		else
			return reject("unknown kind")
		end
		derive(profile)
		log(
			string.format(
				"%saward user=%d kind=%s id=%s source=%s tokens=%d",
				LOG,
				st.userId,
				kind,
				id,
				source,
				Progression.tokenCount(profile)
			)
		)
		return "awarded"
	end

	-- Awards that arrived before the profile loaded apply to the real profile, never to a stand-in.
	local function drainPending(st: PlayerState): boolean
		if not st.profile or #st.pending == 0 then
			return false
		end
		local pending = st.pending
		st.pending = {}
		for _, item in ipairs(pending) do
			applyAward(st, item.kind, item.id, item.source .. "+queued", item.value)
		end
		return true
	end

	local function onLoaded(st: PlayerState)
		st.player:SetAttribute("SaveResumeIn", nil)
		setStatus(st, "ok", "")
		local applied = drainPending(st)
		replicate(st)
		if applied then
			requestSave(st)
		end
		for _, fn in ipairs(loadedHandlers) do
			spawnTask(function()
				local ok, err = pcall(function()
					fn(st.player)
				end)
				if not ok then
					log(string.format("%sonLoaded handler failed user=%d: %s", LOG, st.userId, tostring(err)))
				end
			end)
		end
	end

	local service = {} :: Service
	service.backend = options.backend or store.kind
	service.config = cfg

	function service.get(player: Player): Profile?
		local st = states[player]
		if not st or not st.profile then
			return nil
		end
		return deepFreeze(deepCopy(st.profile))
	end

	function service.status(player: Player): SaveState?
		local st = states[player]
		return if st then st.status else nil
	end

	function service.load(player: Player): (Profile?, SaveState)
		local existing = states[player]
		if existing then
			return service.get(player), existing.status
		end
		-- A rejoin onto this same server waits for the previous session's final write and unlock.
		local profileId = player.UserId
		if options.resolveId then
			profileId = options.resolveId(player) or profileId
		end
		local waited = 0
		while releasing[profileId] and waited < cfg.releaseWait do
			sleep(0.25)
			waited += 0.25
		end
		if player.Parent == nil then
			-- Left before loading started (PlayerRemoving already ran): no state, so nothing outlives the player.
			return nil, "error"
		end
		local st: PlayerState = {
			adopt = nil,
			lockRemaining = nil,
			player = player,
			userId = profileId,
			key = cfg.keyPrefix .. tostring(profileId),
			token = newToken(),
			status = "loading",
			profile = nil,
			pending = {},
			dirty = false,
			saving = false,
			writing = false,
			released = false,
			releaseResult = nil,
			sessionLost = false,
			lastWriteAt = -math.huge,
			lastOutcome = nil,
			changeSeq = 0,
			savedSeq = 0,
		}
		states[player] = st
		setStatus(st, "loading", "Loading your progress")
		if attemptLoad(st, cfg.loadAttempts) then
			if st.released then
				return nil, st.status -- release() made the final write for this load
			end
			onLoaded(st)
			return service.get(player), "ok"
		end
		if not active(st) then
			return nil, st.status
		end
		setStatus(st, "error", ERROR_MESSAGES[st.lastOutcome or "failed"] or ERROR_MESSAGES.failed)
		spawnTask(function()
			local round = 0
			while active(st) and not st.profile do
				round += 1
				sleep(backoff(cfg.loadAttempts + round))
				if not active(st) then
					break
				end
				if attemptLoad(st, 1) then
					if not st.released then
						log(string.format("%sload recovered user=%d after background retry %d", LOG, st.userId, round))
						onLoaded(st)
					end
					break
				end
				if active(st) then
					setStatus(st, "error", ERROR_MESSAGES[st.lastOutcome or "failed"] or ERROR_MESSAGES.failed)
				end
			end
		end)
		return nil, "error"
	end

	function service.award(player: Player, kind: AwardKind, id: string, sourceEvent: string, value: number?): (AwardResult, { string })
		local st = states[player]
		local source = sourceEvent or "?"
		if not st or st.released or st.sessionLost then
			log(
				string.format(
					"%sreject user=%d kind=%s id=%s source=%s (no writable session)",
					LOG,
					player.UserId,
					tostring(kind),
					tostring(id),
					source
				)
			)
			return "rejected", {}
		end
		local profile = st.profile
		if not profile then
			-- L20/L21: the same award asked again while the profile loads (a hub find polled at 5 Hz) is already
			-- queued; a copy per call filled the queue and real awards after it (race token, key, duck) were rejected.
			-- A best time keeps the faster one.
			for _, it in st.pending do
				if it.kind == kind and it.id == id then
					if kind == "bestTime" and type(value) == "number" and (type(it.value) ~= "number" or value < it.value) then
						it.value = value
					end
					return "queued", {}
				end
			end
			if #st.pending >= MAX_PENDING_AWARDS then
				log(string.format("%sreject user=%d kind=%s id=%s source=%s (pending queue full)", LOG, st.userId, kind, id, source))
				return "rejected", {}
			end
			table.insert(st.pending, { kind = kind, id = id, source = source, value = value })
			log(string.format("%squeued user=%d kind=%s id=%s source=%s (profile not loaded yet)", LOG, st.userId, kind, id, source))
			return "queued", {}
		end
		local before = Progression.unlockSet(profile)
		local result: AwardResult = applyAward(st, kind, id, source, value)
		if result ~= "awarded" then
			return result, {}
		end
		replicate(st)
		requestSave(st)
		local opened = Progression.newlyUnlocked(before, Progression.unlockSet(profile))
		local hook = SaveService.unlockHook
		if hook then
			for _, key in opened do
				pcall(hook, player, key)
			end
		end
		return result, opened
	end

	-- Economy and settings writes (MONETIZATION_PROPOSAL section 3). fn edits a draft that replaces the live profile
	-- only if fn returned without yielding, left progression alone (award() owns it) and the result is still
	-- DataStore-serializable: one bad economy edit must never block the writes that carry progression.
	function service.edit(player: Player, reason: string, fn: (Profile) -> ()): boolean
		local st = states[player]
		local profile = if st then st.profile else nil
		if not st or not profile or st.released or st.sessionLost then
			log(string.format("%sreject edit user=%d reason=%s (no writable session)", LOG, player.UserId, reason))
			return false
		end
		local draft = deepCopy(profile)
		-- A yield would let an award land on the live profile and then be overwritten when the draft is committed.
		local co = coroutine.create(fn)
		local ok: boolean, err: any = coroutine.resume(co, draft)
		if ok and coroutine.status(co) ~= "dead" then
			ok, err = false, "edit callbacks must not yield"
		end
		if ok and progressionChanged(profile, draft) then
			ok, err = false, "progression fields change only through award()"
		end
		if ok then
			reconcile(draft :: any, SaveService.newProfile() :: any)
			SettingsRules.sanitizeStored(draft.settings)
			derive(draft)
			ok, err = pcall(checkSerializable, draft, "profile")
		end
		if not ok then
			log(string.format("%sreject edit user=%d reason=%s (%s)", LOG, st.userId, reason, tostring(err)))
			return false
		end
		st.profile = draft
		replicate(st)
		requestSave(st)
		log(string.format("%sedit user=%d reason=%s", LOG, st.userId, reason))
		return true
	end

	-- Final write with the lock cleared. deadline is an absolute clock() value (BindToClose); nil means attempts only.
	function service.release(player: Player, deadline: number?): boolean
		local st = states[player]
		if not st then
			return true
		end
		if st.released then
			while st.releaseResult == nil and (not deadline or clock() < deadline) do
				sleep(0.1)
			end
			return st.releaseResult == true
		end
		st.released = true
		releasing[st.userId] = true
		-- Let a write already in flight land so the final write is the last one.
		while st.writing and (not deadline or clock() < deadline) do
			sleep(0.1)
		end
		-- true only when nothing was waiting to be saved or the final write landed
		local saved = not st.sessionLost
		if st.profile and not st.sessionLost then
			drainPending(st)
			saved = false
			for attempt = 1, cfg.saveAttempts do
				local cooldown = cfg.writeCooldown - (clock() - st.lastWriteAt)
				if deadline then
					-- Near the deadline a throttled write beats no write.
					cooldown = math.min(cooldown, deadline - clock() - 2)
				end
				if cooldown > 0 then
					sleep(cooldown)
				end
				if deadline and clock() >= deadline then
					break
				end
				waitForBudget(deadline)
				local outcome, err = writeOnce(st, true)
				if outcome == "ok" then
					saved = true
					break
				elseif outcome == "lost" then
					onSessionLost(st)
					break
				end
				log(string.format("%sfinal save failed user=%d attempt=%d: %s", LOG, st.userId, attempt, tostring(err)))
				local delay = backoff(attempt)
				if attempt == cfg.saveAttempts or (deadline and clock() + delay >= deadline) then
					break
				end
				sleep(delay)
			end
			-- T2-2: an ordinary leave keeps retrying in the background; at shutdown (deadline) there is no background.
			if not saved and not st.sessionLost and deadline == nil then
				startOrphan(st.userId, st.key, st.token, st.profile :: Profile)
			end
		elseif st.adopt then
			-- Left again before the rejoin's load landed: the adopted snapshot goes back to the background retry, or at
			-- shutdown (deadline) gets one last write of its own.
			local o = st.adopt :: Orphan
			st.adopt = nil
			saved = false
			if deadline == nil then
				startOrphan(o.userId, o.key, o.token, o.snapshot)
			elseif clock() < deadline then
				waitForBudget(deadline)
				local outcome, err = writeRecord(o.key, o.token, o.userId, o.snapshot, true)
				saved = outcome == "ok"
				log(string.format("%sshutdown final save user=%d (adopted snapshot): %s%s", LOG, o.userId, outcome, if err then " " .. err else ""))
			end
		elseif #st.pending > 0 then
			saved = false
			log(string.format("%sdropped %d queued awards user=%d: profile never loaded", LOG, #st.pending, st.userId))
		end
		states[player] = nil
		releasing[st.userId] = nil
		st.releaseResult = saved
		log(string.format("%srelease user=%d saved=%s", LOG, st.userId, tostring(saved)))
		return saved
	end

	function service.flushAll(seconds: number): boolean
		local deadline = clock() + seconds
		local list: { Player } = {}
		for player in pairs(states) do
			table.insert(list, player)
		end
		local orphanIds: { number } = {}
		for userId in pairs(orphans) do
			table.insert(orphanIds, userId)
		end
		local remaining = #list + #orphanIds
		local allSaved = true
		-- T2-2: final saves still retrying from earlier leaves get one last attempt inside the deadline.
		for _, userId in ipairs(orphanIds) do
			spawnTask(function()
				local o = claimOrphan(userId, deadline)
				if o and clock() < deadline then
					waitForBudget(deadline)
					local outcome, err = writeRecord(o.key, o.token, o.userId, o.snapshot, true)
					log(string.format("%sshutdown final save user=%d (background retry): %s%s", LOG, userId, outcome, if err then " " .. err else ""))
					if outcome ~= "ok" then
						allSaved = false
					end
				elseif o then
					allSaved = false
				end
				remaining -= 1
			end)
		end
		for _, player in ipairs(list) do
			spawnTask(function()
				if not service.release(player, deadline) then
					allSaved = false
				end
				remaining -= 1
			end)
		end
		while remaining > 0 and clock() < deadline do
			sleep(0.1)
		end
		if remaining > 0 then
			allSaved = false
		end
		log(string.format("%sflushAll players=%d orphans=%d unfinished=%d saved=%s", LOG, #list, #orphanIds, remaining, tostring(allSaved)))
		return allSaved
	end

	function service.flush(player: Player, timeout: number?): boolean
		local st = states[player]
		if not st or not st.profile or st.sessionLost then
			return false
		end
		local target = st.changeSeq
		if st.savedSeq >= target then
			return true
		end
		local deadline = clock() + (timeout or 15)
		requestSave(st)
		-- release() makes the final write itself and updates savedSeq through the same st.
		while st.savedSeq < target do
			if st.sessionLost or clock() >= deadline then
				return false
			end
			if st.released and st.releaseResult ~= nil then
				return st.savedSeq >= target
			end
			sleep(0.1)
		end
		return true
	end

	function service.onLoaded(fn: (Player) -> ())
		table.insert(loadedHandlers, fn)
	end

	function service.orphans(): { number }
		local out: { number } = {}
		for userId, o in pairs(orphans) do
			if not o.done then
				table.insert(out, userId)
			end
		end
		table.sort(out)
		return out
	end

	-- Periodic write that refreshes every held lock; without it a long session would look stale to other servers.
	function service.heartbeat()
		for _, st in pairs(states) do
			if st.profile and not st.released and not st.sessionLost then
				requestSave(st)
			end
		end
	end

	return service
end

-- In-memory stand-in with the DataStore behaviour that matters here: values are copied in and out (no shared
-- tables) and must be JSON-serializable. Two services on one backing table behave like two servers on one store.
function SaveService.newMemoryStore(backing: { [string]: any }?): MemoryStore
	local memory = {} :: MemoryStore
	memory.kind = "memory"
	memory.data = backing or {}
	memory.writes = 0
	memory.budget = nil
	function memory.update(key: string, transform: (old: any) -> any, _userIds: { number }?): (boolean, string?)
		local ok, err = pcall(function()
			local new = transform(deepCopy(memory.data[key]))
			if new ~= nil then
				checkSerializable(new, key)
				memory.data[key] = deepCopy(new)
				memory.writes += 1
			end
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end
	return memory
end

function SaveService.newDataStoreStore(name: string): Store
	local dataStore = DataStoreService:GetDataStore(name)
	local function update(key: string, transform: (old: any) -> any, userIds: { number }?): (boolean, string?)
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any, _keyInfo: DataStoreKeyInfo): (any, { number }?, {}?)
				local new = transform(old)
				if new == nil then
					return nil, nil, nil
				end
				-- userIds tags the key for Roblox's right-to-erasure tooling.
				return new, userIds, nil
			end)
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end
	local function budget(): number
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end
	return { kind = "datastore", update = update, budget = budget }
end

-- Studio without API access gets the mock (kept for the whole Studio session so leave/rejoin works). Live servers
-- always use DataStore: a failure there must surface as the error state, never as a store that forgets.
local studioBacking: { [string]: any } = {}

-- TG-1 (Studio only): workspace QASaveFault = "load" | "save" | "none" makes that kind of store call fail, so the readable
-- error state (SaveState/SaveMessage), the background retry and the save-failure notice can be shown. Optional
-- QASaveFaultCount = N fails N calls and then clears the fault itself (shows the recovery). Wrapped around the default
-- store ONLY when RunService:IsStudio(); a live server never wraps it and never reads the attribute.
local function withQAFaults(inner: Store): Store
	local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QAHooksRules")) :: any
	local wrapped: Store = {
		kind = inner.kind,
		budget = inner.budget,
		update = function(key: string, transform: (old: any) -> any, userIds: { number }?, op: string?): (boolean, string?)
			if op ~= nil and Rules.saveFaultHits(true, workspace:GetAttribute(Rules.FAULT_ATTR), op) then
				local left = Rules.faultCount(true, workspace:GetAttribute(Rules.FAULT_COUNT_ATTR))
				if left ~= nil then
					if left <= 1 then
						workspace:SetAttribute(Rules.FAULT_ATTR, nil)
						workspace:SetAttribute(Rules.FAULT_COUNT_ATTR, nil)
					else
						workspace:SetAttribute(Rules.FAULT_COUNT_ATTR, left - 1)
					end
				end
				print(LOG .. "QA fault injected: " .. op .. " failed (" .. key .. ")")
				return false, "QA fault injection (QASaveFault=" .. op .. ")"
			end
			return inner.update(key, transform, userIds, op)
		end,
	}
	return wrapped
end

local function chooseDefaultStore(): (Store, string)
	if RunService:IsStudio() then
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(PROBE_STORE_NAME):GetAsync("probe")
		end)
		if not ok then
			print(LOG .. "Studio without DataStore API access (" .. tostring(err) .. "); using the in-memory mock")
			return SaveService.newMemoryStore(studioBacking), "mock"
		end
	end
	return SaveService.newDataStoreStore(SaveService.STORE_NAME), "datastore"
end

local defaultService: Service? = nil
local initialized = false

local function getDefault(): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local store, backend = chooseDefaultStore()
	local studio = RunService:IsStudio()
	if studio then
		store = withQAFaults(store)
	end
	local created = SaveService.new({
		store = store,
		backend = backend,
		-- TG-4 (Studio, mock backend only): workspace QASaveAs = <id> loads the NEXT joining player under that stored
		-- profile id (one-shot), so a second client can rejoin as the same saved user when the local server hands out a
		-- new UserId. Never on a real DataStore, never live.
		resolveId = if studio and backend == "mock"
			then function(_player: Player): number?
				local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QAHooksRules")) :: any
				local id = Rules.saveAs(true, workspace:GetAttribute(Rules.SAVE_AS_ATTR))
				if id ~= nil then
					workspace:SetAttribute(Rules.SAVE_AS_ATTR, nil)
					print(LOG .. "QA save identity: next load uses profile id " .. tostring(id))
				end
				return id
			end
			else nil,
		sessionId = if game.JobId ~= "" then game.JobId else "studio",
	})
	defaultService = created
	workspace:SetAttribute("SaveBackend", backend)
	print(LOG .. "backend=" .. backend)
	return created
end

-- Wires the default service to the server: load on join, flush and unlock on leave and on shutdown, lock heartbeat.
-- options replaces the default service (tests); call once from the server entry script.
function SaveService.init(options: Options?)
	if initialized then
		return
	end
	initialized = true
	if options then
		defaultService = SaveService.new(options)
	end
	local service = getDefault()
	Players.PlayerAdded:Connect(function(player: Player)
		service.load(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		service.release(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(service.load, player)
	end
	game:BindToClose(function()
		service.flushAll(BIND_TO_CLOSE_DEADLINE)
	end)
	task.spawn(function()
		while true do
			task.wait(service.config.autosaveInterval)
			service.heartbeat()
		end
	end)
end

function SaveService.service(): Service
	return getDefault()
end

function SaveService.load(player: Player): (Profile?, SaveState)
	return getDefault().load(player)
end

function SaveService.award(player: Player, kind: AwardKind, id: string, sourceEvent: string, value: number?): (AwardResult, { string })
	return getDefault().award(player, kind, id, sourceEvent, value)
end

function SaveService.edit(player: Player, reason: string, fn: (Profile) -> ()): boolean
	return getDefault().edit(player, reason, fn)
end

function SaveService.get(player: Player): Profile?
	return getDefault().get(player)
end

-- L27: the first-session guide's saved flag. It lives in the settings slot, so it goes through edit() (never award(),
-- which owns progression) and is replicated as the Onboarded attribute. true when it is held, already or now.
function SaveService.isOnboarded(profile: Profile?): boolean
	return profile ~= nil and profile.settings[OnboardingRules.FLAG] == true
end

function SaveService.markOnboarded(player: Player): boolean
	local service = getDefault()
	if SaveService.isOnboarded(service.get(player)) then
		return true
	end
	return service.edit(player, "onboarded", function(profile: Profile)
		profile.settings[OnboardingRules.FLAG] = true
	end)
end

-- The first-unlock battle explainer's saved flag (settings slot, like markOnboarded); replicated as BattleIntroSeen.
function SaveService.markBattleIntro(player: Player): boolean
	local service = getDefault()
	local profile = service.get(player)
	if profile == nil then
		return false
	end
	if profile.settings[BattleAccessRules.INTRO_FLAG] == true then
		return true
	end
	return service.edit(player, "battleIntro", function(draft: Profile)
		draft.settings[BattleAccessRules.INTRO_FLAG] = true
	end)
end

-- T1-15: a first-time explainer was answered (settings slot, like markOnboarded). skipAll also turns every explainer off.
-- true when it is held, already or now; false for an unknown id or no writable session.
function SaveService.markExplained(player: Player, id: string, skipAll: boolean?): boolean
	if not ExplainerRules.isId(id) then
		return false
	end
	local service = getDefault()
	local profile = service.get(player)
	if profile == nil then
		return false
	end
	local probe = table.clone(profile.settings)
	if not ExplainerRules.apply(probe, id, skipAll) then
		return true
	end
	return service.edit(player, "explained", function(draft: Profile)
		ExplainerRules.apply(draft.settings, id, skipAll)
	end)
end

function SaveService.release(player: Player): boolean
	return getDefault().release(player)
end

function SaveService.flush(player: Player, timeout: number?): boolean
	return getDefault().flush(player, timeout)
end

function SaveService.onLoaded(fn: (Player) -> ())
	getDefault().onLoaded(fn)
end

return SaveService
