--!strict
-- Player settings relay (audit H13; shared/SettingsRules, client/Settings). The client changes its own sound and
-- graphics settings at once (player attributes, local); this module persists them:
--   * SkyRallyRemotes.SettingsEvent: the client sends ONE table of { key = value }; every entry is cut down by
--     SettingsRules (known keys only, numbers clamped 0..1, booleans only), the sender gets a token bucket (burst 6, then
--     2 a second), and an over-limit or empty message is dropped quietly. Nothing is ever read back out of the payload
--     except through SettingsRules.
--   * The values land in the profile's non-progression `settings` table through SaveService.edit, so they ride the same
--     coalesced write as every other change (one write per key per 6 s, flushed on leave) and edit() itself refuses to
--     touch progression. An update that arrives before the profile has loaded waits and is applied when it does.
--   * On load the saved values are published as the player attributes the client modules already read, once, so a
--     later server write never echoes an older slider position back over the client's own. What the player sent this
--     session is overlaid on the saved table (SettingsRules.overlay), so a profile that finishes loading late, or is
--     retried, never publishes an older saved value over a choice made meanwhile (QA V5A: ASSIST back to on).
--   * FREE DRIVING (the flight mode, FLIGHT_GUIDE.md 12) is also published as the server-owned attribute FlightMode
--     ("mk" | "free"): on load, and at once whenever a validated update carries it (saved, queued or not), so the
--     flight code and the server's return checks agree with the toggle within one message.
-- Roblox APIs and the save layer sit behind Deps so tools/tests/settings_spec.luau drives all of it with mocks.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SettingsRules"))

local SettingsService = {}

local LOG = "[SkyRally][SETTINGS] "

export type Update = { [string]: number | boolean }

export type Deps = {
	edit: (player: Player, reason: string, fn: (any) -> ()) -> boolean,
	get: (player: Player) -> any?,
	onLoaded: ((Player) -> ()) -> (),
	now: () -> number,
	log: (string) -> (),
}

export type Service = {
	handle: (player: Player, payload: any) -> string,
	publish: (player: Player) -> (),
	forget: (player: Player) -> (),
}

function SettingsService.new(deps: Deps): Service
	local buckets: { [Player]: SettingsRules.Bucket } = {}
	local waiting: { [Player]: Update } = {}
	local touched: { [Player]: Update } = {} -- what the player sent this session: newer than anything saved
	local service = {} :: Service

	-- Sets the player attributes from the saved table (defaults for anything never saved).
	function service.publish(player: Player)
		local profile = deps.get(player)
		-- The player's own changes this session win over the saved table (a late or retried load must not undo them).
		local resolved = SettingsRules.overlay(SettingsRules.resolve(if profile then profile.settings else nil), touched[player])
		for _, d in SettingsRules.DEFS do
			player:SetAttribute(d.attr, resolved[d.key])
		end
		player:SetAttribute(SettingsRules.FLIGHT_MODE_ATTR, SettingsRules.flightModeOf(resolved.freeDriving))
		player:SetAttribute("SettingsLoaded", true)
	end

	local function persist(player: Player, update: Update): boolean
		return deps.edit(player, "settings", function(profile: any)
			SettingsRules.apply(profile.settings, update)
		end)
	end

	-- Returns what happened, for the log and the spec: "saved", "queued", "empty", "limited" or "failed".
	function service.handle(player: Player, payload: any): string
		local now = deps.now()
		local bucket = buckets[player]
		if not bucket then
			bucket = SettingsRules.newBucket(now)
			buckets[player] = bucket
		end
		if not SettingsRules.take(bucket, now) then
			return "limited"
		end
		local update = SettingsRules.cleanUpdate(payload)
		if not update then
			return "empty"
		end
		local mine = touched[player]
		if not mine then
			mine = {}
			touched[player] = mine
		end
		for k, v in update do
			(mine :: Update)[k] = v
		end
		if update.freeDriving ~= nil then
			player:SetAttribute(SettingsRules.FLIGHT_MODE_ATTR, SettingsRules.flightModeOf(update.freeDriving))
		end
		if deps.get(player) == nil then
			-- Profile still loading (or in the error state): keep the newest value per key for onLoaded.
			local held = waiting[player]
			if not held then
				held = {}
				waiting[player] = held
			end
			for k, v in update do
				held[k] = v
			end
			return "queued"
		end
		if not persist(player, update) then
			deps.log(LOG .. "save refused user=" .. tostring(player.UserId))
			return "failed"
		end
		return "saved"
	end

	function service.forget(player: Player)
		buckets[player] = nil
		waiting[player] = nil
		touched[player] = nil
	end

	deps.onLoaded(function(player: Player)
		local held = waiting[player]
		waiting[player] = nil
		if held then
			persist(player, held)
		end
		service.publish(player)
	end)

	return service
end

local started = false

function SettingsService.init()
	if started then
		return
	end
	started = true
	local SaveService = require(script.Parent.SaveService)
	local service = SettingsService.new({
		edit = SaveService.edit,
		get = SaveService.get,
		onLoaded = SaveService.onLoaded,
		now = os.clock,
		log = print,
	})
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local event = (folder :: Instance):FindFirstChild("SettingsEvent") :: RemoteEvent?
	if not event then
		local e = Instance.new("RemoteEvent")
		e.Name = "SettingsEvent"
		e.Parent = folder
		event = e
	end
	(event :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
		service.handle(player, payload)
	end)
	Players.PlayerRemoving:Connect(service.forget)
	-- A profile that finished loading before this ran (a fast Studio join) still gets its values published.
	for _, p in Players:GetPlayers() do
		if SaveService.get(p) then
			service.publish(p)
		end
	end
end

return SettingsService
