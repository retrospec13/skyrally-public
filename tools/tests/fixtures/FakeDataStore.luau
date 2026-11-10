--!strict
-- A fake Roblox DataStore for the save specs (tools/tests/save_ops_spec.luau): the behaviour SaveService and SaveAdmin
-- depend on, without Studio.
-- * Values are deep-copied in and out and must be JSON-like (no functions, no NaN).
-- * Every committed write keeps a version row (ListVersionsAsync / GetVersionAsync); RemoveAsync leaves a deleted row.
-- * Throttling: a second committed write to one key inside writeGap seconds fails like Roblox's full per-key queue, and a
--   per-store request budget (budget(), refilled per fake minute) fails requests when it is spent.
-- * Failures: failing = true fails every call; failNext = n fails the next n calls.
-- * Races: interleave(key) runs between the transform and the commit (another server's write); when the key changed
--   meanwhile the transform runs again on the new value, as UpdateAsync does.
-- Clock: pass the harness scheduler's clock (fake seconds).
local Fake = {}

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

local function checkJson(v: any, path: string)
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error(path .. " is not finite", 0)
		end
	elseif t == "table" then
		for k, x in pairs(v) do
			if type(k) ~= "string" and type(k) ~= "number" then
				error(path .. " has a " .. type(k) .. " key", 0)
			end
			checkJson(x, path .. "." .. tostring(k))
		end
	elseif t ~= "string" and t ~= "boolean" and t ~= "nil" then
		error(path .. " has a " .. t, 0)
	end
end

export type Options = {
	clock: () -> number,
	writeGap: number?, -- seconds between two writes to one key (Roblox: 6); 0 = off
	budgetPerMinute: number?, -- requests per fake minute; nil = unlimited
}

function Fake.new(o: Options): any
	local s: any = {
		kind = "fake",
		data = {},
		versions = {}, -- key -> { {version, createdTime, deleted, value} } oldest first
		userIds = {}, -- key -> userIds of the last write
		lastWrite = {}, -- key -> clock of the last committed write
		writes = 0,
		reads = 0,
		throttled = 0,
		failed = 0,
		failing = false,
		failNext = 0,
		interleave = nil,
		rev = {}, -- key -> commit counter (UpdateAsync's conflict check)
		seq = 0,
	}
	local writeGap = o.writeGap or 6
	local budgetPerMinute = o.budgetPerMinute
	local spent, minute = 0, math.floor(o.clock() / 60)

	local function gate(isWrite: boolean, key: string?): string?
		if s.failing then
			s.failed += 1
			return "502: DataStore unavailable (fake outage)"
		end
		if s.failNext > 0 then
			s.failNext -= 1
			s.failed += 1
			return "500: internal error (fake)"
		end
		if budgetPerMinute then
			local m = math.floor(o.clock() / 60)
			if m ~= minute then
				minute, spent = m, 0
			end
			if spent >= budgetPerMinute then
				s.throttled += 1
				return "DataStore request was throttled: request budget exhausted (fake)"
			end
			spent += 1
		end
		return nil
	end

	-- Per-key write rate: checked when a write would commit (a cancelled UpdateAsync never counts here).
	local function tooSoon(key: string): string?
		local last = s.lastWrite[key]
		if writeGap > 0 and last and o.clock() - last < writeGap then
			s.throttled += 1
			return "DataStore write queue full for key " .. key .. " (fake: writes inside " .. writeGap .. " s)"
		end
		return nil
	end

	local function commit(key: string, value: any, userIds: any, deleted: boolean)
		s.seq += 1
		s.writes += 1
		s.data[key] = if deleted then nil else deepCopy(value)
		s.userIds[key] = if deleted then nil else userIds
		s.lastWrite[key] = o.clock()
		s.rev[key] = (s.rev[key] or 0) + 1
		s.versions[key] = s.versions[key] or {}
		table.insert(s.versions[key], {
			version = "v" .. tostring(s.seq),
			createdTime = o.clock(),
			deleted = deleted,
			value = deepCopy(value),
		})
	end

	function s.budget(): number
		if not budgetPerMinute then
			return 1000
		end
		local m = math.floor(o.clock() / 60)
		if m ~= minute then
			return budgetPerMinute
		end
		return budgetPerMinute - spent
	end

	function s.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
		local why = gate(true, key)
		if why then
			return false, why
		end
		local ok, err = pcall(function()
			for _ = 1, 5 do
				local rev = s.rev[key]
				local new = transform(deepCopy(s.data[key]))
				local hook = s.interleave
				if hook then
					s.interleave = nil -- once: the racing server's write happens here
					hook(key)
				end
				if s.rev[key] == rev then
					if new ~= nil then
						checkJson(new, key)
						local soon = tooSoon(key)
						if soon then
							error(soon, 0)
						end
						commit(key, new, userIds, false)
					end
					return
				end
				-- The key changed under us: UpdateAsync calls the transform again with the new value.
			end
			error("UpdateAsync gave up after 5 conflicting retries (fake)", 0)
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end

	function s.get(key: string): (boolean, any)
		local why = gate(false, nil)
		if why then
			return false, why
		end
		s.reads += 1
		return true, deepCopy(s.data[key])
	end

	function s.remove(key: string): (boolean, string?)
		local why = gate(true, key)
		if why then
			return false, why
		end
		if s.data[key] ~= nil then
			local soon = tooSoon(key)
			if soon then
				return false, soon
			end
			commit(key, nil, nil, true)
		end
		return true, nil
	end

	-- Newest first, like ListVersionsAsync(key, Descending).
	function s.listVersions(key: string, limit: number): (boolean, any)
		local why = gate(false, nil)
		if why then
			return false, why
		end
		local rows = {}
		local list = s.versions[key] or {}
		for i = #list, 1, -1 do
			local v = list[i]
			table.insert(rows, { version = v.version, createdTime = v.createdTime, deleted = v.deleted })
			if #rows >= limit then
				break
			end
		end
		return true, rows
	end

	function s.getVersion(key: string, version: string): (boolean, any)
		local why = gate(false, nil)
		if why then
			return false, why
		end
		for _, v in ipairs(s.versions[key] or {}) do
			if v.version == version then
				return true, deepCopy(v.value)
			end
		end
		return false, "version " .. version .. " not found (fake)"
	end

	-- Test helper: write directly (no gate, no throttle), as if another tool or an older build had written it.
	function s.seed(key: string, value: any)
		commit(key, value, nil, false)
		s.lastWrite[key] = -math.huge
	end

	return s
end

-- An OrderedDataStore stand-in with just what the erasure needs.
function Fake.ordered(): any
	local s: any = { data = {}, failing = false }
	function s.remove(key: string): (boolean, string?)
		if s.failing then
			return false, "502 (fake ordered outage)"
		end
		s.data[key] = nil
		return true, nil
	end
	return s
end

return Fake
