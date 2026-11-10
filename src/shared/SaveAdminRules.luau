--!strict
-- Owner save tools (systems audit v32 T1-14; DECISIONS D22 admin only; docs/SAVE_ADMIN.md). Pure: no DataStore, no clock
-- of its own, no Instances. server/SaveAdmin runs these against the live stores for the "/admin save ..." commands, and
-- tools/save_admin/save_admin.py mirrors them over Open Cloud for when no server is running. Specs:
-- tools/tests/save_ops_spec.luau.
-- * inspect / versions: read only.
-- * restore <userId> <version>: puts an earlier DataStore version of a profile back. Refused while the player is online
--   (a fresh session lock). The purchase bookkeeping of the current record (receipts, once-per-account products, gift
--   ledger) is kept, so a restore never lets a paid product grant twice or a gift land twice.
-- * erase <userId>: the Roblox right-to-erasure request. Removes the profile, the gift inbox, the purchase records the
--   profile names, and the player's row on every hub leaderboard. Refused while the player is online.
-- * restore and erase take two steps: the first call answers with a preview and a confirm code, the second call repeats
--   the command with the code. A code is bound to the action, the user id, the version and a 10-minute window.
-- Who may run them is not decided here: server/AdminService checks AdminConfig (D22) before any of this is reached.
local SaveLockRules = require(script.Parent:WaitForChild("SaveLockRules"))

local SaveAdminRules = {}

SaveAdminRules.LOG = "[SkyRally][SAVEADMIN] "
SaveAdminRules.PROFILE_STORE = "SkyRallyProfiles" -- SaveService.STORE_NAME
SaveAdminRules.PROFILE_PREFIX = "u_"
SaveAdminRules.GIFT_STORE = "SkyRallyPendingGifts" -- MonetizationConfig.SERVICE.giftStoreName
SaveAdminRules.GIFT_PREFIX = "g_"
SaveAdminRules.PURCHASE_STORE = "SkyRallyPurchaseHistory" -- MonetizationConfig.SERVICE.purchaseStoreName
SaveAdminRules.AUDIT_STORE = "SkyRallySaveAdminAudit"
SaveAdminRules.AUDIT_KEEP = 500 -- entries per UTC day key
SaveAdminRules.CODE_WINDOW = 600 -- seconds a confirm code stays valid (the window it was issued in and the next)
SaveAdminRules.VERSIONS_SHOWN = 10
SaveAdminRules.ACTIONS = { "inspect", "versions", "restore", "erase" }

SaveAdminRules.HELP = table.concat({
	"/admin save inspect <userId>",
	"/admin save versions <userId>",
	"/admin save restore <userId> <version> [code]",
	"/admin save erase <userId> [code]",
}, "\n")

export type Command = {
	action: string,
	userId: number,
	version: string?,
	code: string?,
}

function SaveAdminRules.profileKey(userId: number): string
	return SaveAdminRules.PROFILE_PREFIX .. tostring(userId)
end

function SaveAdminRules.giftKey(userId: number): string
	return SaveAdminRules.GIFT_PREFIX .. tostring(userId)
end

-- "/admin save ..." (any case). Everything else goes to AdminRules.parse.
function SaveAdminRules.isSaveCommand(text: any): boolean
	if type(text) ~= "string" or #text > 200 then
		return false
	end
	local a, b = string.match(text, "^%s*(%S+)%s+(%S+)")
	return a ~= nil and string.lower(a) == "/admin" and string.lower(b :: string) == "save"
end

local function parseUserId(word: string?): number?
	if not word or not string.match(word, "^%d+$") or #word > 15 then
		return nil
	end
	local n = tonumber(word)
	if not n or n < 1 then
		return nil
	end
	return n
end

-- Parses "/admin save <action> <userId> [version] [code]". Returns the command or nil, why.
function SaveAdminRules.parse(text: any): (Command?, string?)
	if not SaveAdminRules.isSaveCommand(text) then
		return nil, "not a save command"
	end
	local words: { string } = {}
	for w in string.gmatch(text :: string, "%S+") do
		table.insert(words, w)
	end
	local action = if words[3] then string.lower(words[3]) else nil
	if not action or not table.find(SaveAdminRules.ACTIONS, action) then
		return nil, SaveAdminRules.HELP
	end
	local userId = parseUserId(words[4])
	if not userId then
		return nil, "save " .. action .. " needs a numeric userId"
	end
	if action == "restore" then
		local version = words[5]
		if not version or #version > 80 or not string.match(version, "^[%w%-%._:]+$") then
			return nil, "save restore needs a version id (from /admin save versions)"
		end
		return { action = action :: string, userId = userId, version = version, code = words[6] } :: Command, nil
	elseif action == "erase" then
		return { action = action :: string, userId = userId, code = words[5] } :: Command, nil
	end
	if #words > 4 then
		return nil, "save " .. action .. " takes only a userId"
	end
	return { action = action :: string, userId = userId } :: Command, nil
end

-- A short code bound to what it confirms and when (not a secret: it only proves the preview was read).
function SaveAdminRules.confirmCode(action: string, userId: number, version: string?, now: number): string
	local window = math.floor(now / SaveAdminRules.CODE_WINDOW)
	local text = string.format("%s|%d|%s|%d", action, userId, version or "", window)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	local out = {}
	for _ = 1, 6 do
		local i = h % #alphabet + 1
		table.insert(out, string.sub(alphabet, i, i))
		h = h // #alphabet
	end
	return table.concat(out)
end

function SaveAdminRules.codeValid(code: string?, action: string, userId: number, version: string?, now: number): boolean
	if type(code) ~= "string" then
		return false
	end
	local upper = string.upper(code)
	return upper == SaveAdminRules.confirmCode(action, userId, version, now)
		or upper == SaveAdminRules.confirmCode(action, userId, version, now - SaveAdminRules.CODE_WINDOW)
end

local function count(t: any): number
	local n = 0
	if type(t) == "table" then
		for _, v in pairs(t) do
			if v ~= nil and v ~= false then
				n += 1
			end
		end
	end
	return n
end

local function num(v: any): number
	return if type(v) == "number" then v else 0
end

-- Roblox's os.date accepts only "*t" / "!*t", so the text is built from the table.
local function utcParts(t: number): any
	return os.date("!*t", math.floor(t)) :: any
end

local function utc(t: any): string
	if type(t) ~= "number" then
		return "?"
	end
	local d = utcParts(t)
	return string.format("%04d-%02d-%02d %02d:%02d:%02dZ", d.year, d.month, d.day, d.hour, d.min, d.sec)
end

-- Plain-number facts about a profile (inspect and the restore preview).
function SaveAdminRules.facts(profile: any): { [string]: number }
	local p = if type(profile) == "table" then profile else {}
	local economy = if type(p.economy) == "table" then p.economy else {}
	local storm = if type(p.storm) == "table" then p.storm else {}
	local winPass = if type(p.winPass) == "table" then p.winPass else {}
	local avatars = if type(p.avatars) == "table" then p.avatars else {}
	local cosmetics = if type(p.cosmetics) == "table" then p.cosmetics else {}
	return {
		version = num(p.version),
		tokens = count(p.tokens),
		keys = count(p.keys),
		battles = count(p.battles),
		ducks = count(p.ducks),
		bestTimes = count(p.bestTimes),
		finalBoss = if p.finalBoss == true then 1 else 0,
		cash = num(p.gears),
		shards = num(storm.shards),
		winPassRaces = num(winPass.races),
		cosmetics = count(cosmetics.owned),
		avatars = count(avatars.owned),
		receipts = count(economy.receipts),
	}
end

local FACT_ORDER = { "version", "tokens", "keys", "battles", "ducks", "bestTimes", "finalBoss", "cash", "shards", "winPassRaces", "cosmetics", "avatars", "receipts" }

function SaveAdminRules.factLine(profile: any): string
	local f = SaveAdminRules.facts(profile)
	local parts = {}
	for _, k in ipairs(FACT_ORDER) do
		table.insert(parts, k .. "=" .. tostring(f[k]))
	end
	return table.concat(parts, " ")
end

-- The inspect reply: what the record holds and whether a server has the player right now. No other player's data.
function SaveAdminRules.summarize(userId: number, record: any, now: number): string
	if record == nil then
		return string.format("user %d: no saved profile", userId)
	end
	if type(record) ~= "table" then
		return string.format("user %d: record is a %s (unreadable; restore an earlier version)", userId, type(record))
	end
	local lock = SaveLockRules.state(record, now)
	local lockText = if lock.state == "free"
		then "free"
		else string.format("%s by %s, refreshed %ds ago (ttl %ds)", lock.state, tostring(lock.holder), lock.age or 0, lock.ttl or 0)
	local lines = {
		string.format("user %d: saved %s, lock %s", userId, utc(record.savedAt), lockText),
		SaveAdminRules.factLine(record.profile),
	}
	local takeover = record.lastTakeover
	if type(takeover) == "table" then
		table.insert(lines, string.format("last takeover %s: %s -> %s (lock was %ss old)", utc(takeover.at), tostring(takeover.from), tostring(takeover.by), tostring(takeover.age)))
	end
	local restored = record.restoredFrom
	if type(restored) == "table" then
		table.insert(lines, string.format("restored %s from version %s", utc(restored.at), tostring(restored.version)))
	end
	return table.concat(lines, "\n")
end

export type VersionRow = { version: string, createdTime: number?, deleted: boolean? }

function SaveAdminRules.versionLines(userId: number, rows: { VersionRow }): string
	if #rows == 0 then
		return string.format("user %d: no versions", userId)
	end
	local lines = { string.format("user %d: %d newest versions (restore with /admin save restore %d <version>)", userId, #rows, userId) }
	for _, r in ipairs(rows) do
		table.insert(lines, string.format("%s  %s%s", r.version, utc(r.createdTime), if r.deleted then "  (deleted)" else ""))
	end
	return table.concat(lines, "\n")
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = deepCopy(x)
	end
	return out
end

-- Union of string-keyed maps: every entry of keep survives, base fills the rest.
local function union(base: any, keep: any): { [string]: any }
	local out = if type(base) == "table" then deepCopy(base) else {}
	if type(keep) == "table" then
		for k, v in pairs(keep) do
			out[k] = deepCopy(v)
		end
	end
	return out
end

export type RestorePlan = {
	ok: boolean,
	why: string?,
	record: any, -- the record to write (nil when refused)
	before: string?, -- fact line of the current profile
	after: string?, -- fact line of the restored profile
}

-- Builds the record a restore writes. current: the record now; candidate: the record stored under the chosen version;
-- migrate: SaveService.migrate (errors on data it cannot read). Run inside the write's transform so the online check and
-- the write are one atomic step.
function SaveAdminRules.planRestore(current: any, candidate: any, version: string, now: number, migrate: (any) -> any): RestorePlan
	local lock = SaveLockRules.state(current, now)
	if lock.state == "held" then
		return {
			ok = false,
			why = string.format("player is online (lock held by %s, %ds ago); restore after they leave", tostring(lock.holder), lock.age or 0),
			record = nil,
		}
	end
	if type(candidate) ~= "table" or type(candidate.profile) ~= "table" then
		return { ok = false, why = "version " .. version .. " holds no profile", record = nil }
	end
	local okMigrate, profile = pcall(migrate, candidate.profile)
	if not okMigrate then
		return { ok = false, why = "version " .. version .. " cannot be read: " .. tostring(profile), record = nil }
	end
	local restored: any = deepCopy(profile)
	local curProfile = if type(current) == "table" and type(current.profile) == "table" then current.profile else nil
	if curProfile then
		-- Purchase bookkeeping never goes back in time: a receipt or gift already granted stays marked as granted.
		local curEconomy = if type(curProfile.economy) == "table" then curProfile.economy else {}
		restored.economy = if type(restored.economy) == "table" then restored.economy else {}
		restored.economy.receipts = union(restored.economy.receipts, curEconomy.receipts)
		restored.economy.oneTime = union(restored.economy.oneTime, curEconomy.oneTime)
		restored.pendingGifts = union(restored.pendingGifts, curProfile.pendingGifts)
	end
	local record: any = {}
	if type(current) == "table" then
		for k, v in pairs(current) do
			record[k] = deepCopy(v)
		end
	end
	record.profile = restored
	record.session = nil
	record.savedAt = now
	record.restoredFrom = { version = version, at = now }
	return {
		ok = true,
		why = nil,
		record = record,
		before = SaveAdminRules.factLine(curProfile),
		after = SaveAdminRules.factLine(restored),
	}
end

export type Target = { store: string, key: string, kind: string } -- kind: "standard" | "ordered" | "purchase"

-- Every DataStore entry SkyRally keeps for this user (right to erasure). profileRecord: the profile record if it could be
-- read (its receipts name the purchase records); boardStores: every hub leaderboard's OrderedDataStore name. The profile
-- itself comes last, so an erasure stopped midway can be run again and still find the purchase ids.
function SaveAdminRules.erasureTargets(userId: number, profileRecord: any, boardStores: { string }): { Target }
	local out: { Target } = {}
	table.insert(out, { store = SaveAdminRules.GIFT_STORE, key = SaveAdminRules.giftKey(userId), kind = "standard" })
	local profile = if type(profileRecord) == "table" then profileRecord.profile else nil
	local economy = if type(profile) == "table" then profile.economy else nil
	local receipts = if type(economy) == "table" then economy.receipts else nil
	if type(receipts) == "table" then
		local ids = {}
		for purchaseId in pairs(receipts) do
			if type(purchaseId) == "string" then
				table.insert(ids, purchaseId)
			end
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			table.insert(out, { store = SaveAdminRules.PURCHASE_STORE, key = id, kind = "purchase" })
		end
	end
	local boards = table.clone(boardStores)
	table.sort(boards)
	for _, name in ipairs(boards) do
		table.insert(out, { store = name, key = tostring(userId), kind = "ordered" })
	end
	table.insert(out, { store = SaveAdminRules.PROFILE_STORE, key = SaveAdminRules.profileKey(userId), kind = "standard" })
	return out
end

-- A purchase record is removed only when it names this buyer (PurchaseId keys are Roblox's, never chosen by a player).
function SaveAdminRules.purchaseBelongsTo(record: any, userId: number): boolean
	return type(record) == "table" and tonumber(record.userId) == userId
end

-- One log line per admin save action (and the audit store entry's text).
function SaveAdminRules.logLine(actorId: number, action: string, target: number, result: string, detail: string?): string
	return string.format(
		"%sactor=%d action=%s target=%d result=%s%s",
		SaveAdminRules.LOG,
		actorId,
		action,
		target,
		result,
		if detail and detail ~= "" then " " .. detail else ""
	)
end

function SaveAdminRules.auditKey(now: number): string
	local d = utcParts(now)
	return string.format("audit_%04d-%02d-%02d", d.year, d.month, d.day)
end

-- Appends one entry to a day's audit list (oldest dropped past AUDIT_KEEP).
function SaveAdminRules.auditAppend(old: any, entry: { [string]: any }): { any }
	local list = if type(old) == "table" then old else {}
	table.insert(list, entry)
	while #list > SaveAdminRules.AUDIT_KEEP do
		table.remove(list, 1)
	end
	return list
end

return table.freeze(SaveAdminRules)
