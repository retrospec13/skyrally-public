--!strict
-- Storm Shards and the Storm vendor, server side (economy v3 phase 5; rules in shared/StormRules, data in
-- shared/StormConfig, docs/design/STORM_SHARDS.md).
-- * Earning: RaceManager.finishHook calls onFinish for every real finish; only a storm-race finish (StormConfig.MODES)
--   pays, through SaveService.edit on the profile's `storm` record. Its own path: Economy's 2x Cash / Festival / Rally
--   Streak multipliers never see it, and no product grants it. A simulated (QA) finish counts only in Studio.
-- * The dragon: a finish beats the storm dragon when the field has one (workspace.StormDragonInField, set by the storm
--   race flow of a later phase; nil today, so nobody beats a dragon that is not there) and no bot crossed first.
-- * Vendor: SkyRallyRemotes.StormRequest ("GetState", "Buy", "Equip"), validated here against StormRules (tier, Shards,
--   owned) and written through SaveService.edit. Shards are spent only here; Robux and Cash never buy them.
-- * Client events on SkyRallyRemotes.StormEvent: "Shards" (payout + tier-ups, the client toasts them from NotifySpec),
--   "OpenVendor" (the hub stand's prompt).
-- Roblox APIs sit behind Options so tools/tests/storm_spec.luau drives the service with a real SaveService and mocks.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StormRules = require(Shared:WaitForChild("StormRules"))
local StormConfig = require(Shared:WaitForChild("StormConfig"))

local StormShards = {}

local LOG = "[SkyRally][STORM_SHARDS] "
local MAX_KEY_LEN = 64

export type Saver = {
	get: (player: Player) -> any?,
	edit: (player: Player, reason: string, fn: (any) -> ()) -> boolean,
}

export type Options = {
	save: Saver,
	now: (() -> number)?, -- UTC seconds
	clock: (() -> number)?, -- monotonic (request spacing)
	isStudio: (() -> boolean)?,
	dragonInField: (() -> boolean)?,
	fire: ((player: Player, kind: string, payload: any) -> ())?,
	log: ((string) -> ())?,
}

export type Reply = { ok: boolean, reason: string?, data: any? }

export type FinishResult = { payout: StormRules.Payout?, beatDragon: boolean }

export type Service = {
	onFinish: (player: Player, info: any) -> FinishResult,
	getState: (player: Player) -> Reply,
	buy: (player: Player, key: any) -> Reply,
	equip: (player: Player, slot: any, key: any) -> Reply,
	handleRequest: (player: Player, action: any, ...any) -> Reply,
	forget: (player: Player) -> (),
	qaGrant: (player: Player, n: any) -> boolean,
}

-- Requests closer together than this are refused (a remote can be spammed; a real tap is never this fast).
StormShards.REQUEST_GAP = 0.15

function StormShards.new(options: Options): Service
	local save = options.save
	local now: () -> number = options.now or function(): number
		return os.time()
	end
	local clock: () -> number = options.clock or os.clock
	local isStudio = options.isStudio or function(): boolean
		return false
	end
	local dragonInField = options.dragonInField or function(): boolean
		return false
	end
	local fire: (Player, string, any) -> () = options.fire or function(_p: Player, _k: string, _x: any) end
	local log: (string) -> () = options.log or function(line: string)
		print(line)
	end
	local lastRequest: { [any]: number } = {}
	local readKeys: { [Player]: {} } = {}
	local function getStateKey(player: Player): {}
		local k = readKeys[player]
		if not k then
			k = {}
			readKeys[player] = k
		end
		return k
	end

	local service = {} :: Service

	local function reject(player: Player, action: string, reason: string, detail: string?): Reply
		log(string.format("%sreject user=%d action=%s reason=%s%s", LOG, player.UserId, action, reason, if detail then " (" .. string.sub(detail, 1, 80) .. ")" else ""))
		return { ok = false, reason = reason }
	end

	function service.onFinish(player: Player, info: any): FinishResult
		local mode = if type(info) == "table" then info.mode else nil
		if type(info) ~= "table" or not StormRules.isStormMode(mode) then
			return { payout = nil, beatDragon = false }
		end
		local beat = if info.beatDragon ~= nil then info.beatDragon == true else StormRules.beatDragon(mode, info.finished == true, info.beatBoss, dragonInField())
		local finish: StormRules.Finish = {
			mode = mode,
			rank = tonumber(info.rank) or 8,
			finished = info.finished == true,
			simulated = info.simulated == true,
			beatDragon = beat,
		}
		local day = StormRules.utcDay(now())
		-- Nothing to pay (not finished, a QA finish outside Studio, feature off): no write at all.
		if StormRules.earn(finish, StormRules.read(save.get(player)), day, isStudio()) == nil then
			return { payout = nil, beatDragon = beat }
		end
		local payout: StormRules.Payout? = nil
		local before, after = 0, 0
		local ok = save.edit(player, "storm:finish", function(draft: any)
			local state = StormRules.read(draft)
			before = state.lifetime
			payout = StormRules.earn(finish, state, day, isStudio())
			if payout then
				StormRules.applyFinish(state, payout, day)
				draft.storm = state
			end
			after = state.lifetime
		end)
		local p = payout
		if not ok or not p then
			if not ok then
				log(string.format("%sfinish not counted user=%d mode=%s (profile not writable)", LOG, player.UserId, tostring(mode)))
			end
			return { payout = nil, beatDragon = beat }
		end
		local ups = StormRules.tierUps(before, after)
		local upNames: { string } = {}
		for _, t in ups do
			table.insert(upNames, t.name)
		end
		local profile = save.get(player)
		local state = StormRules.read(profile)
		log(string.format("%searn user=%d mode=%s rank=%d shards=%d (finish %d place %d dragon %d daily %d) balance=%d lifetime=%d tierUps=%s", LOG, player.UserId, mode, finish.rank, p.total, p.parts.finish, p.parts.place, p.parts.dragon, p.parts.firstOfDay, state.shards, state.lifetime, table.concat(upNames, "/")))
		fire(player, "Shards", {
			n = p.total,
			parts = p.parts,
			beatDragon = p.beatDragon,
			shards = state.shards,
			lifetime = state.lifetime,
			tier = StormRules.tierFor(state.lifetime).name,
			tierUps = upNames,
		})
		return { payout = p, beatDragon = beat }
	end

	function service.getState(player: Player): Reply
		local profile = save.get(player)
		if not profile then
			return { ok = false, reason = "loading" }
		end
		local state = StormRules.read(profile)
		local tier = StormRules.tierFor(state.lifetime)
		local nxt, need = StormRules.nextTier(state.lifetime)
		local owned: { string } = {}
		local cosmeticsOwned = if type(profile.cosmetics) == "table" then profile.cosmetics.owned else nil
		for _, it in StormConfig.VENDOR do
			if StormRules.owns(state, cosmeticsOwned, it.key) then
				table.insert(owned, it.key)
			end
		end
		return {
			ok = true,
			data = {
				enabled = StormConfig.Enabled == true,
				shards = state.shards,
				lifetime = state.lifetime,
				races = state.races,
				dragonWins = state.dragonWins,
				tier = tier.id,
				nextTier = if nxt then nxt.id else nil,
				need = need,
				owned = owned,
				loadout = state.loadout,
			},
		}
	end

	function service.buy(player: Player, key: any): Reply
		if type(key) ~= "string" or #key == 0 or #key > MAX_KEY_LEN then
			return reject(player, "Buy", "badRequest")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "Buy", "loading")
		end
		local state = StormRules.read(profile)
		local can, reason = StormRules.canBuy(state, profile.cosmetics and profile.cosmetics.owned, key)
		if not can then
			return reject(player, "Buy", reason or "refused", key)
		end
		local ok = save.edit(player, "storm:buy:" .. key, function(draft: any)
			StormRules.applyBuy(draft, key)
		end)
		if not ok then
			return reject(player, "Buy", "saveRefused", key)
		end
		local it = StormRules.item(key) :: StormConfig.Item
		local after = StormRules.read(save.get(player))
		log(string.format("%sbuy user=%d item=%s price=%d balance=%d", LOG, player.UserId, key, it.price, after.shards))
		return { ok = true, data = { key = key, name = it.name, shards = after.shards } }
	end

	function service.equip(player: Player, slot: any, key: any): Reply
		local profile = save.get(player)
		if not profile then
			return reject(player, "Equip", "loading")
		end
		if key ~= nil and (type(key) ~= "string" or #key > MAX_KEY_LEN) then
			return reject(player, "Equip", "badRequest")
		end
		local can, reason = StormRules.canEquip(StormRules.read(profile), slot, key)
		if not can then
			return reject(player, "Equip", reason or "refused", tostring(key))
		end
		local unequip = key == nil or key == ""
		local ok = save.edit(player, "storm:equip:" .. tostring(slot), function(draft: any)
			local state = StormRules.read(draft)
			local again, why = StormRules.canEquip(state, slot, key)
			if not again then
				error("storm equip refused: " .. tostring(why), 0)
			end
			state.loadout[slot] = if unequip then nil else key
			draft.storm = state
		end)
		if not ok then
			return reject(player, "Equip", "saveRefused")
		end
		return { ok = true, data = { slot = slot, key = if unequip then nil else key } }
	end

	function service.handleRequest(player: Player, action: any, ...: any): Reply
		-- Reads and writes are spaced separately: the panel re-reads its state right after every Buy / Equip reply, and
		-- one shared clock refused that read (stale balance and BUY buttons after a purchase).
		local t = clock()
		local slot: any = if action == "GetState" then getStateKey(player) else player
		local last = lastRequest[slot]
		if last and t - last < StormShards.REQUEST_GAP then
			return { ok = false, reason = "rateLimited" }
		end
		lastRequest[slot] = t
		if action == "GetState" then
			return service.getState(player)
		elseif action == "Buy" then
			return service.buy(player, (...))
		elseif action == "Equip" then
			local slot, key = ...
			return service.equip(player, slot, key)
		end
		return reject(player, "Request", "badAction", tostring(action))
	end

	function service.forget(player: Player)
		lastRequest[player] = nil
		local k = readKeys[player]
		if k then
			lastRequest[k] = nil
			readKeys[player] = nil
		end
	end

	-- Studio QA only (the Studio recipe; a live server refuses): adds n Shards to the balance AND lifetime through the
	-- save, so the vendor's tiers can be checked without racing. Never reachable from a client.
	function service.qaGrant(player: Player, n: any): boolean
		if not isStudio() or type(n) ~= "number" or n ~= n or n <= 0 or n > 100000 then
			return false
		end
		local amount = math.floor(n)
		local before, after = 0, 0
		local ok = save.edit(player, "storm:qa", function(draft: any)
			local state = StormRules.read(draft)
			before = state.lifetime
			state.shards += amount
			state.lifetime += amount
			after = state.lifetime
			draft.storm = state
		end)
		if ok then
			log(string.format("%sqa grant user=%d shards=%d lifetime=%d->%d", LOG, player.UserId, amount, before, after))
		end
		return ok
	end

	return service
end

------------------------------------------------------------------------------------------------ live wiring

local defaultService: Service? = nil

local function ensure(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- Wires remotes and the hub stand. Call once from the server entry script after SaveService.init().
function StormShards.init(save: Saver): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local folder = ensure(ReplicatedStorage, "Folder", "SkyRallyRemotes")
	local event = ensure(folder, "RemoteEvent", "StormEvent") :: RemoteEvent
	local request = ensure(folder, "RemoteFunction", "StormRequest") :: RemoteFunction
	local svc = StormShards.new({
		save = save,
		isStudio = function(): boolean
			return RunService:IsStudio()
		end,
		dragonInField = function(): boolean
			return workspace:GetAttribute("StormDragonInField") == true
		end,
		fire = function(player: Player, kind: string, payload: any)
			event:FireClient(player, kind, payload)
		end,
	})
	defaultService = svc
	request.OnServerInvoke = function(player: Player, action: any, ...: any): any
		local ok, reply = pcall(svc.handleRequest, player, action, ...)
		if not ok then
			warn(LOG .. "request failed: " .. tostring(reply))
			return { ok = false, reason = "error" }
		end
		return reply
	end
	Players.PlayerRemoving:Connect(svc.forget)
	-- Studio QA: workspace.StormShardsQA = n gives every player n Shards (balance and lifetime), then clears itself.
	-- svc.qaGrant refuses outside Studio, so a live server ignores the attribute.
	if RunService:IsStudio() then
		workspace:GetAttributeChangedSignal("StormShardsQA"):Connect(function()
			local n = workspace:GetAttribute("StormShardsQA")
			if type(n) ~= "number" then
				return
			end
			workspace:SetAttribute("StormShardsQA", nil)
			for _, player in Players:GetPlayers() do
				svc.qaGrant(player, n)
			end
		end)
	end
	workspace:SetAttribute("StormVendorEnabled", StormConfig.Enabled == true)
	if StormConfig.Enabled then
		local Stand = require(script.Parent:WaitForChild("StormVendorStand")) :: any
		Stand.start(function(player: Player)
			event:FireClient(player, "OpenVendor", nil)
		end)
	end
	print(string.format("%sinit enabled=%s", LOG, tostring(StormConfig.Enabled)))
	return svc
end

function StormShards.service(): Service?
	return defaultService
end

-- RaceManager.finishHook entry; never throws. Returns whether this finish beat the storm dragon (the badge hook reads it).
function StormShards.onFinish(player: Player, info: any): boolean
	local svc = defaultService
	if not svc then
		return false
	end
	local ok, res = pcall(svc.onFinish, player, info)
	if not ok then
		warn(LOG .. "finish failed: " .. tostring(res))
		return false
	end
	return (res :: FinishResult).beatDragon
end

return StormShards
