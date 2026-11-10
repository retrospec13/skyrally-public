--!strict
-- Profile session lock rules (systems audit v32 T1-14). Pure: no DataStore, no clock of its own. Shared by
-- server/SaveService (which lock it may take over), server/SaveAdmin and tools/save_admin (whether a player is online, so
-- a restore or an erasure never races a live server). Specs: tools/tests/save_ops_spec.luau.
-- A record's lock is { id = server JobId, token = per-load GUID, lockedAt = os.time() of the last refresh, ttl = seconds }.
-- * ttl is declared by the holder (its own lockTimeout). A lock written before T1-14 has no ttl and keeps the 180 s its
--   build was written for, so a new server never steals a live lock from an old server still running after a publish.
-- * A declared ttl is clamped so one bad record can neither pin a profile forever nor make every lock stale at once.
local SaveLockRules = {}

SaveLockRules.LEGACY_TTL = 180
SaveLockRules.MIN_TTL = 30
SaveLockRules.MAX_TTL = 600

-- Seconds a lock stays fresh after its last refresh.
function SaveLockRules.ttl(session: any): number
	local ttl = if type(session) == "table" then tonumber(session.ttl) else nil
	if ttl == nil or ttl ~= ttl then
		return SaveLockRules.LEGACY_TTL
	end
	return math.clamp(ttl, SaveLockRules.MIN_TTL, SaveLockRules.MAX_TTL)
end

export type LockState = {
	state: string, -- "free" (no lock), "held" (fresh: a server has this player now), "stale" (may be taken over)
	holder: string?,
	age: number?, -- seconds since the last refresh
	ttl: number?,
	remaining: number?, -- seconds until a held lock goes stale
}

-- What a record's lock means at wall-clock time now. A clock-skewed lockedAt in the future counts as just refreshed.
function SaveLockRules.state(record: any, now: number): LockState
	local session = if type(record) == "table" then record.session else nil
	if type(session) ~= "table" then
		return { state = "free" }
	end
	local ttl = SaveLockRules.ttl(session)
	local age = math.max(0, now - (tonumber(session.lockedAt) or 0))
	local held = age < ttl
	return {
		state = if held then "held" else "stale",
		holder = tostring(session.id),
		age = math.floor(age),
		ttl = ttl,
		remaining = if held then ttl - age else 0,
	}
end

return table.freeze(SaveLockRules)
