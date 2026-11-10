--!strict
-- Roblox badges (social lane). The rules (which badge a profile or a finish has earned, the award plan) are
-- shared/BadgeRules, specced in tools/tests/badges_spec.luau; this module is the BadgeService side.
--   * BadgeIds is empty on purpose: every id is nil until the owner creates the badges in Creator Hub (docs/BADGES.md lists
--     the rows to create). A badge with no id is logged once per server and skipped; nothing else changes.
--   * Judged after every real finish (RaceManager.finishHook, from the saved profile plus the finish) and when a profile
--     loads, so an account that already qualified is awarded retroactively.
--   * Every BadgeService call is pcall-wrapped and runs in its own task (it yields). UserHasBadgeAsync answers are cached per
--     user and badge, a failed call is retried no sooner than RETRY_SECONDS later, and a badge handled this session is never
--     asked about again. Studio awards nothing unless workspace.BadgeQA is true (so test runs do not spend real badges).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BadgeRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BadgeRules"))
local BadgeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BadgeConfig"))

local BadgeAwards = {}

local LOG = "[SkyRally][BADGE] "
local RETRY_SECONDS = 60

-- Badge key -> Roblox badge id, read from shared/BadgeConfig (nil = the owner has not created it yet; never invent ids).
-- A copy, so the Lune spec can set ids without touching the config.
local BadgeIds: { [string]: number? } = {}
for key, id in BadgeConfig.IDS do
	BadgeIds[key] = id
end
BadgeAwards.BadgeIds = BadgeIds

-- The slice of BadgeService this module uses; replaced in the Lune spec.
export type Service = {
	UserHasBadgeAsync: (self: any, userId: number, badgeId: number) -> boolean,
	AwardBadge: (self: any, userId: number, badgeId: number) -> boolean,
}

BadgeAwards.service = nil :: Service?
BadgeAwards.profileOf = nil :: ((Player) -> any)?
BadgeAwards.clock = os.clock :: () -> number
-- Called once per badge that THIS call really awarded (never for one the player already held, never for a nil id):
-- (player, key, id). init.server wires the client toast (BadgeRemote) and the progression event; nil in the Lune specs.
BadgeAwards.onAwarded = nil :: ((player: Player, key: string, id: number) -> ())?
-- Run a function in its own task (the spec runs it inline).
BadgeAwards.spawn = function(fn: () -> ())
	task.spawn(fn)
end :: (() -> ()) -> ()

local loggedUnset: { [string]: boolean } = {}
-- userId -> badge key -> true once the player is known to hold it (UserHasBadgeAsync said so, or AwardBadge succeeded).
local held: { [number]: { [string]: boolean } } = {}
-- userId -> badge key -> clock of the last failed attempt.
local failedAt: { [number]: { [string]: number } } = {}
-- userId -> badge key -> an attempt is running (the call yields; do not stack a second one).
local busy: { [number]: { [string]: boolean } } = {}

local function badgeService(): Service
	local s = BadgeAwards.service
	if s then
		return s
	end
	local real = game:GetService("BadgeService") :: any
	BadgeAwards.service = real
	return real
end

local function allowedHere(): boolean
	return not RunService:IsStudio() or workspace:GetAttribute("BadgeQA") == true
end

local function bucket(map: { [number]: { [string]: any } }, userId: number): { [string]: any }
	local b = map[userId]
	if not b then
		b = {}
		map[userId] = b
	end
	return b
end

-- One badge for one player; runs in its own task.
local function grant(player: Player, key: string, id: number)
	local userId = player.UserId
	local heldFor = bucket(held, userId)
	local busyFor = bucket(busy, userId)
	local failedFor = bucket(failedAt, userId)
	if heldFor[key] or busyFor[key] then
		return
	end
	local last = failedFor[key]
	if last and BadgeAwards.clock() - last < RETRY_SECONDS then
		return
	end
	busyFor[key] = true
	local svc = badgeService()
	local okHas, has = pcall(function()
		return svc:UserHasBadgeAsync(userId, id)
	end)
	if okHas and has == true then
		heldFor[key] = true
	elseif okHas then
		local okAward, awarded = pcall(function()
			return svc:AwardBadge(userId, id)
		end)
		if okAward and awarded == true then
			heldFor[key] = true
			print(string.format("%saward user=%d player=%s badge=%s id=%d", LOG, userId, player.Name, key, id))
			local hook = BadgeAwards.onAwarded
			if hook then
				local okHook, errHook = pcall(function(): any
					hook(player, key, id)
					return nil
				end)
				if not okHook then
					warn(LOG .. "onAwarded failed: " .. tostring(errHook))
				end
			end
		else
			failedFor[key] = BadgeAwards.clock()
			warn(string.format("%saward failed user=%d badge=%s id=%d (%s)", LOG, userId, key, id, tostring(awarded)))
		end
	else
		failedFor[key] = BadgeAwards.clock()
		warn(string.format("%sUserHasBadgeAsync failed user=%d badge=%s id=%d (%s)", LOG, userId, key, id, tostring(has)))
	end
	busyFor[key] = nil
end

-- Judges the player now. ev is the finish that just happened, or nil (profile load). Returns the earned keys (for tests).
function BadgeAwards.evaluate(player: Player, ev: BadgeRules.Event?): { string }
	local profileOf = BadgeAwards.profileOf
	local profile = if profileOf then profileOf(player) else nil
	local earned = BadgeRules.earned(profile, ev)
	local handled: { [string]: boolean } = {}
	local heldFor = held[player.UserId]
	if heldFor then
		for k in heldFor do
			handled[k] = true
		end
	end
	local award, unset = BadgeRules.plan(earned, BadgeIds, handled)
	for _, key in unset do
		if not loggedUnset[key] then
			loggedUnset[key] = true
			print(string.format("%sbadge %s earned by user=%d but BadgeIds.%s is not set yet (create it in Creator Hub, see docs/BADGES.md); skipped", LOG, key, player.UserId, key))
		end
	end
	if not allowedHere() then
		return earned
	end
	for _, row in award do
		BadgeAwards.spawn(function()
			local ok, err = pcall(function(): any
				grant(player, row.key, row.id)
				return nil
			end)
			if not ok then
				warn(LOG .. "grant crashed: " .. tostring(err))
			end
		end)
	end
	return earned
end

-- RaceManager.finishHook entry. info is the FinishInfo of the finish; never throws.
function BadgeAwards.onFinish(player: Player, info: any)
	local ok, err = pcall(BadgeAwards.evaluate, player, {
		trackId = info.trackId,
		mode = info.mode,
		rank = info.rank,
		finished = info.finished == true,
		simulated = info.simulated == true,
		beatBoss = info.beatBoss,
		beatDragon = info.beatDragon,
	} :: BadgeRules.Event)
	if not ok then
		warn(LOG .. "evaluate failed: " .. tostring(err))
	end
end

function BadgeAwards.onLoaded(player: Player)
	local ok, err = pcall(BadgeAwards.evaluate, player, nil)
	if not ok then
		warn(LOG .. "evaluate failed: " .. tostring(err))
	end
end

function BadgeAwards.forget(player: Player)
	held[player.UserId] = nil
	failedAt[player.UserId] = nil
	busy[player.UserId] = nil
end

-- The BadgeEarned remote: server -> client, one string (the badge KEY). The client looks the title up in BadgeRules.titleOf and
-- shows the badge_earned toast (NotifySpec). Created here so the spec and the live game share one name.
BadgeAwards.REMOTE = "BadgeEarned"

function BadgeAwards.toastHook(player: Player, key: string, _id: number)
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local remote = remotes and remotes:FindFirstChild(BadgeAwards.REMOTE)
	if remote and remote:IsA("RemoteEvent") and player.Parent then
		remote:FireClient(player, key)
	end
end

local function ensureRemote()
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		remotes = f
	end
	if not (remotes :: Instance):FindFirstChild(BadgeAwards.REMOTE) then
		local r = Instance.new("RemoteEvent")
		r.Name = BadgeAwards.REMOTE
		r.Parent = remotes
	end
end

function BadgeAwards.init(profileOf: (Player) -> any, onLoaded: ((Player) -> ()) -> ())
	BadgeAwards.profileOf = profileOf
	ensureRemote()
	onLoaded(BadgeAwards.onLoaded)
	Players.PlayerRemoving:Connect(BadgeAwards.forget)
	-- Profiles that loaded before this registered.
	for _, p in Players:GetPlayers() do
		if profileOf(p) ~= nil then
			task.spawn(BadgeAwards.onLoaded, p)
		end
	end
end

-- Test hook: forget the once-per-server log memory.
function BadgeAwards.resetLogs()
	table.clear(loggedUnset)
end

return BadgeAwards
