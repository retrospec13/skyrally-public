--!strict
-- Owner save tools on a live server (systems audit v32 T1-14; DECISIONS D22; docs/SAVE_ADMIN.md). Reached ONLY from
-- server/AdminService after its AdminConfig check, through "/admin save inspect|versions|restore|erase <userId> ...".
-- Rules (what a restore writes, what an erasure removes, confirm codes, the online check) are shared/SaveAdminRules and
-- shared/SaveLockRules; this module runs them against the DataStores. Every Roblox call is injected (Stores), so
-- tools/tests/save_ops_spec.luau drives it with a fake DataStore (throttling, failures, a racing server).
-- * Read only: inspect and versions. They never touch a lock and never write.
-- * restore / erase: preview + confirm code first; the second call with the code runs it. Both refuse while the player
--   is online (a fresh session lock), and restore re-checks that inside its UpdateAsync transform so a server that takes
--   the lock between the preview and the write wins and the restore is cancelled.
-- * Every action logs one "[SkyRally][SAVEADMIN] actor=... action=... target=... result=..." line and appends an entry
--   to the SkyRallySaveAdminAudit store (UTC day key). A failed audit write is logged, never blocks the action.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SaveAdminRules = require(Shared:WaitForChild("SaveAdminRules"))
local SaveLockRules = require(Shared:WaitForChild("SaveLockRules"))

local SaveAdmin = {}

-- One standard DataStore. Every call returns ok first; failures are values, never errors.
export type AdminStore = {
	get: (key: string) -> (boolean, any),
	listVersions: ((key: string, limit: number) -> (boolean, any))?, -- rows { version, createdTime, deleted }, newest first
	getVersion: ((key: string, version: string) -> (boolean, any))?,
	update: (key: string, transform: (old: any) -> any, userIds: { number }?) -> (boolean, string?),
	remove: (key: string) -> (boolean, string?),
}

export type OrderedStore = {
	remove: (key: string) -> (boolean, string?),
}

export type Deps = {
	profiles: AdminStore,
	gifts: AdminStore,
	purchases: AdminStore,
	boards: { [string]: OrderedStore }, -- OrderedDataStore name -> store (every hub leaderboard)
	audit: AdminStore?,
	migrate: (raw: any) -> any, -- SaveService.migrate
	now: () -> number,
	log: ((string) -> ())?,
}

export type Reply = { ok: boolean, text: string }

export type Service = {
	run: (actorId: number, cmd: SaveAdminRules.Command) -> Reply,
}

function SaveAdmin.new(deps: Deps): Service
	local log = deps.log or function(line: string)
		print(line)
	end
	local svc = {} :: Service

	local function record(actorId: number, action: string, target: number, result: string, detail: string?)
		log(SaveAdminRules.logLine(actorId, action, target, result, detail))
		local audit = deps.audit
		if not audit then
			return
		end
		local now = deps.now()
		local entry = { at = now, actor = actorId, action = action, target = target, result = result }
		local ok, err = audit.update(SaveAdminRules.auditKey(now), function(old: any): any
			return SaveAdminRules.auditAppend(old, entry)
		end, nil)
		if not ok then
			log(SaveAdminRules.LOG .. "audit write failed: " .. tostring(err))
		end
	end

	local function readProfile(userId: number): (boolean, any)
		return deps.profiles.get(SaveAdminRules.profileKey(userId))
	end

	local function inspect(actorId: number, userId: number): Reply
		local ok, rec = readProfile(userId)
		if not ok then
			record(actorId, "inspect", userId, "failed", tostring(rec))
			return { ok = false, text = "Read failed: " .. tostring(rec) }
		end
		record(actorId, "inspect", userId, "ok", nil)
		return { ok = true, text = SaveAdminRules.summarize(userId, rec, deps.now()) }
	end

	local function versions(actorId: number, userId: number): Reply
		local list = deps.profiles.listVersions
		if not list then
			return { ok = false, text = "Versions are not available on this server." }
		end
		local ok, rows = list(SaveAdminRules.profileKey(userId), SaveAdminRules.VERSIONS_SHOWN)
		if not ok or type(rows) ~= "table" then
			record(actorId, "versions", userId, "failed", tostring(rows))
			return { ok = false, text = "Listing versions failed: " .. tostring(rows) }
		end
		record(actorId, "versions", userId, "ok", "rows=" .. tostring(#rows))
		return { ok = true, text = SaveAdminRules.versionLines(userId, rows) }
	end

	local function restore(actorId: number, cmd: SaveAdminRules.Command): Reply
		local userId, version = cmd.userId, cmd.version :: string
		local getVersion = deps.profiles.getVersion
		if not getVersion then
			return { ok = false, text = "Restore is not available on this server." }
		end
		local okV, candidate = getVersion(SaveAdminRules.profileKey(userId), version)
		if not okV then
			record(actorId, "restore", userId, "failed", "version=" .. version .. " read: " .. tostring(candidate))
			return { ok = false, text = "Reading version " .. version .. " failed: " .. tostring(candidate) }
		end
		local now = deps.now()
		if not SaveAdminRules.codeValid(cmd.code, "restore", userId, version, now) then
			local okC, current = readProfile(userId)
			if not okC then
				return { ok = false, text = "Read failed: " .. tostring(current) }
			end
			local plan = SaveAdminRules.planRestore(current, candidate, version, now, deps.migrate)
			if not plan.ok then
				record(actorId, "restore", userId, "refused", "version=" .. version .. " " .. tostring(plan.why))
				return { ok = false, text = "Restore refused: " .. tostring(plan.why) }
			end
			local code = SaveAdminRules.confirmCode("restore", userId, version, now)
			record(actorId, "restore", userId, "preview", "version=" .. version)
			return {
				ok = true,
				text = string.format(
					"Restore user %d to version %s?\nnow:   %s\nafter: %s\nPurchases and gifts already granted stay marked. Confirm: /admin save restore %d %s %s",
					userId, version, tostring(plan.before), tostring(plan.after), userId, version, code
				),
			}
		end
		local refused: string? = nil
		local after: string? = nil
		local okW, err = deps.profiles.update(SaveAdminRules.profileKey(userId), function(old: any): any
			refused, after = nil, nil
			-- Re-planned inside the transform: a server that took the lock since the preview cancels the restore.
			local plan = SaveAdminRules.planRestore(old, candidate, version, deps.now(), deps.migrate)
			if not plan.ok then
				refused = plan.why
				return nil
			end
			after = plan.after
			return plan.record
		end, { userId })
		if not okW then
			record(actorId, "restore", userId, "failed", "version=" .. version .. " " .. tostring(err))
			return { ok = false, text = "Restore failed: " .. tostring(err) }
		end
		if refused then
			record(actorId, "restore", userId, "refused", "version=" .. version .. " " .. refused)
			return { ok = false, text = "Restore refused: " .. refused }
		end
		record(actorId, "restore", userId, "done", "version=" .. version .. " " .. tostring(after))
		return { ok = true, text = string.format("Restored user %d to version %s. The previous record stays in the version history.", userId, version) }
	end

	local function erase(actorId: number, cmd: SaveAdminRules.Command): Reply
		local userId = cmd.userId
		local okP, rec = readProfile(userId)
		if not okP then
			record(actorId, "erase", userId, "failed", "profile read: " .. tostring(rec))
			return { ok = false, text = "Read failed: " .. tostring(rec) }
		end
		local now = deps.now()
		local lock = SaveLockRules.state(rec, now)
		if lock.state == "held" then
			record(actorId, "erase", userId, "refused", "online")
			return { ok = false, text = string.format("Erase refused: user %d is online (lock held by %s). Run it after they leave.", userId, tostring(lock.holder)) }
		end
		local boardNames: { string } = {}
		for name in pairs(deps.boards) do
			table.insert(boardNames, name)
		end
		local targets = SaveAdminRules.erasureTargets(userId, rec, boardNames)
		if not SaveAdminRules.codeValid(cmd.code, "erase", userId, nil, now) then
			local code = SaveAdminRules.confirmCode("erase", userId, nil, now)
			record(actorId, "erase", userId, "preview", "targets=" .. tostring(#targets))
			return {
				ok = true,
				text = string.format(
					"Erase ALL SkyRally data of user %d (%d entries: profile, gift inbox, purchase records, leaderboard rows)? This cannot be undone in game. Confirm: /admin save erase %d %s",
					userId, #targets, userId, code
				),
			}
		end
		local failed: { string } = {}
		local removed = 0
		for _, t in ipairs(targets) do
			local ok: boolean, err: string? = true, nil
			if t.kind == "ordered" then
				local store = deps.boards[t.store]
				if store then
					ok, err = store.remove(t.key)
				end
			elseif t.kind == "purchase" then
				local okR, pr = deps.purchases.get(t.key)
				if not okR then
					ok, err = false, tostring(pr)
				elseif pr ~= nil and not SaveAdminRules.purchaseBelongsTo(pr, userId) then
					ok, err = true, nil -- names another buyer: left alone
				elseif pr ~= nil then
					ok, err = deps.purchases.remove(t.key)
				end
			elseif t.store == SaveAdminRules.GIFT_STORE then
				ok, err = deps.gifts.remove(t.key)
			elseif t.store == SaveAdminRules.PROFILE_STORE then
				if #failed > 0 then
					-- Keep the profile (it names the purchase records) so a rerun can finish the job.
					ok, err = false, "kept for a rerun: earlier removals failed"
				else
					-- Re-checked atomically: a player who joined since the preview keeps the profile.
					local online = false
					local okU, errU = deps.profiles.update(t.key, function(old: any): any
						online = SaveLockRules.state(old, deps.now()).state == "held"
						return nil
					end, nil)
					if not okU then
						ok, err = false, tostring(errU)
					elseif online then
						ok, err = false, "player came online"
					else
						ok, err = deps.profiles.remove(t.key)
					end
				end
			end
			if ok then
				removed += 1
			else
				table.insert(failed, string.format("%s/%s: %s", t.store, t.key, tostring(err)))
			end
		end
		if #failed > 0 then
			record(actorId, "erase", userId, "partial", string.format("removed=%d failed=%d", removed, #failed))
			return { ok = false, text = string.format("Erase incomplete for user %d (%d of %d). Run the same command again.\n%s", userId, removed, #targets, table.concat(failed, "\n")) }
		end
		record(actorId, "erase", userId, "done", "removed=" .. tostring(removed))
		return { ok = true, text = string.format("Erased user %d: %d entries removed. Old DataStore versions expire on Roblox's 30-day schedule.", userId, removed) }
	end

	function svc.run(actorId: number, cmd: SaveAdminRules.Command): Reply
		local a = cmd.action
		if a == "inspect" then
			return inspect(actorId, cmd.userId)
		elseif a == "versions" then
			return versions(actorId, cmd.userId)
		elseif a == "restore" then
			return restore(actorId, cmd)
		elseif a == "erase" then
			return erase(actorId, cmd)
		end
		return { ok = false, text = SaveAdminRules.HELP }
	end

	return svc
end

-- Live stores. Not created until the first save command (no DataStore request at server start for this).
function SaveAdmin.live(migrate: (any) -> any, boardStoreNames: { string }): Service
	local DataStoreService = game:GetService("DataStoreService")
	local function standard(name: string): AdminStore
		local ds = DataStoreService:GetDataStore(name)
		return {
			get = function(key: string): (boolean, any)
				return pcall(function()
					return ds:GetAsync(key)
				end)
			end,
			listVersions = function(key: string, limit: number): (boolean, any)
				return pcall(function()
					local pages = ds:ListVersionsAsync(key, Enum.SortDirection.Descending, nil, nil, limit)
					local rows = {}
					for _, info in ipairs(pages:GetCurrentPage()) do
						table.insert(rows, {
							version = info.Version,
							createdTime = math.floor(info.CreatedTime / 1000),
							deleted = info.IsDeleted,
						})
						if #rows >= limit then
							break
						end
					end
					return rows
				end)
			end,
			getVersion = function(key: string, version: string): (boolean, any)
				return pcall(function()
					return ds:GetVersionAsync(key, version)
				end)
			end,
			update = function(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
				local ok, err = pcall(function()
					ds:UpdateAsync(key, function(old: any): (any, { number }?)
						local new = transform(old)
						if new == nil then
							return nil
						end
						return new, userIds
					end)
				end)
				return ok, if ok then nil else tostring(err)
			end,
			remove = function(key: string): (boolean, string?)
				local ok, err = pcall(function()
					ds:RemoveAsync(key)
				end)
				return ok, if ok then nil else tostring(err)
			end,
		}
	end
	local boards: { [string]: OrderedStore } = {}
	for _, name in ipairs(boardStoreNames) do
		local ods = DataStoreService:GetOrderedDataStore(name)
		boards[name] = {
			remove = function(key: string): (boolean, string?)
				local ok, err = pcall(function()
					ods:RemoveAsync(key)
				end)
				return ok, if ok then nil else tostring(err)
			end,
		}
	end
	return SaveAdmin.new({
		profiles = standard(SaveAdminRules.PROFILE_STORE),
		gifts = standard(SaveAdminRules.GIFT_STORE),
		purchases = standard(SaveAdminRules.PURCHASE_STORE),
		audit = standard(SaveAdminRules.AUDIT_STORE),
		boards = boards,
		migrate = migrate,
		now = os.time,
	})
end

return SaveAdmin
