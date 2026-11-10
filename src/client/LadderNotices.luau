--!strict
-- Economy v3 phase 8: the player-facing explanations for hidden keys and the map-unlock ladder, fired through NotifyKit / NotifySpec.
-- Client only; the numbers and words come from Shared.LadderRules, the rows from Shared.NotifySpec, and the look from NotifyKit's SKIN
-- tables (the owner supplies UI art later), so nothing here picks colours or fonts.
--  * Sky Tokens: the player attribute SkyTokens (SaveService.replicate) is watched. The first value is a baseline and says nothing;
--    each rise toasts "Sky Tokens 1/2 for ISLAND" (or "+1 Sky Token" once every token gate is open), and a crossed threshold adds
--    "<Zone> is open".
--  * Keys: TrackFlow hands the server's KeyFound payload to keyFound(); the first key ever (count 0 -> 1) opens the explainer modal.
--  * Battle: the first time any battle is open (BattlesOpen) and BattleIntroSeen is false, a 3-line explainer opens at a calm hub
--    moment; answering it tells the server (TrackFlowRemote "BattleIntroSeen"), which saves the flag.
--  * Battle fragments: TrackFlow hands the BattleResults award to battleAward().
--  * First-time explainers (T1-15, Shared.ExplainerRules): items, keys, battles, Sky Tokens and the Garage, each once per
--    account at a calm hub moment, skippable ("Skip tips" turns them all off). The answer goes to the server on
--    OnboardingRemote ("explained", topic, skip) which saves it; the Explained / ExplainSkip attributes come back.
--  * Badges: the server's BadgeEarned remote (a badge key, sent only when BadgeService really awarded it) shows the badge_earned toast.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LadderRules = require(Shared:WaitForChild("LadderRules"))
local BattleAccessRules = require(Shared:WaitForChild("BattleAccessRules"))
local LoginRules = require(Shared:WaitForChild("LoginRules"))
local ExplainerRules = require(Shared:WaitForChild("ExplainerRules"))
local BadgeRules = require(Shared:WaitForChild("BadgeRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local NotifySpec = require(Shared:WaitForChild("NotifySpec"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))

local LocalPlayer = Players.LocalPlayer

local LadderNotices = {}

local lastTokens: number? = nil
local EXPLAIN_CALM = 2 -- seconds the calm gate must stay clear before the queued explainer opens
local EXPLAIN_POLL = 1
local started = false

-- Topics answered this session before the saved attributes replicate back (so a trigger never re-queues one).
local answeredHere: { [string]: boolean } = {}
local skippedHere = false

local function explainerState(): ({ [string]: boolean }, boolean, boolean)
	local seen = ExplainerRules.decode(LocalPlayer:GetAttribute(ExplainerRules.ATTR))
	for id in answeredHere do
		seen[id] = true
	end
	local loaded = type(LocalPlayer:GetAttribute(ExplainerRules.ATTR)) == "string"
	local skip = skippedHere or LocalPlayer:GetAttribute(ExplainerRules.SKIP_ATTR) == true
	return seen, skip, loaded
end

-- Is this topic still to be shown? False until the saved profile has replicated (never a false first-time card).
local function topicDue(topic: string): boolean
	local seen, skip, loaded = explainerState()
	return loaded and ExplainerRules.due(topic, seen, skip, LocalPlayer:GetAttribute(BattleAccessRules.INTRO_ATTR) == true)
end

local function zoneName(zone: string): string?
	local info = TrackInfo.forZone(zone)
	return if info then info.zoneName else nil
end
LadderNotices.zoneName = zoneName

local function onTokens()
	local raw = LocalPlayer:GetAttribute("SkyTokens")
	if type(raw) ~= "number" then
		return
	end
	local gained, crossed = LadderRules.delta(lastTokens, raw)
	local before = lastTokens
	lastTokens = raw
	if ExplainerRules.tokenTrigger(before, raw) then
		LadderNotices.queueTopic("tokens")
	end
	if gained <= 0 then
		return
	end
	local vars = LadderRules.tokenVars(raw, zoneName)
	if vars then
		NotifyKit.fromSpec("token_progress", vars)
	else
		NotifyKit.fromSpec("token_gain")
	end
	for _, zone in crossed do
		NotifyKit.fromSpec("map_unlock", { zone = zoneName(zone) or zone }, { key = "map_unlock_" .. zone })
	end
end

local enqueue: (id: string) -> () -- defined with the explainer queue below

-- Server "KeyFound" payload: { zone, keys (count after this key, when known) }.
function LadderNotices.keyFound(data: any)
	local zone = tostring(if type(data) == "table" then data.zone else "")
	-- The server sends the count only when the award is saved; a queued award has no count, so no first-key modal (never a false one).
	local known = if type(data) == "table" and type(data.keys) == "number" then data.keys else nil
	local count = math.max(known or tonumber(LocalPlayer:GetAttribute("Keys")) or 1, 1)
	local vars = LadderRules.keyVars(count)
	vars.zone = zoneName(zone) or zone
	NotifyKit.fromSpec("key_found", vars)
	if known ~= nil and LadderRules.isFirstKey(count) then
		-- Never mid-race: only the toast now, the modal waits for a calm hub moment.
		LadderNotices.queueTopic("keys")
	end
end

local function calmNow(): boolean
	local ok, LoginPopup = pcall(function()
		return require(script.Parent:WaitForChild("LoginPopup")) :: any
	end)
	return ok and LoginPopup.calmNow() == true
end

local function holdNow(): string?
	local ok, LoginPopup = pcall(function()
		return require(script.Parent:WaitForChild("LoginPopup")) :: any
	end)
	return if ok then LoginPopup.holdNow() else nil
end

-- Explainer modals wait here (spec ids, oldest first) for a calm hub moment: the first key and the first open battle.
local queuedIds: { string } = {}
local draining = false

enqueue = function(id: string)
	if not table.find(queuedIds, id) then
		table.insert(queuedIds, id)
	end
	LadderNotices.drainExplainer()
end

local function explainerVars(id: string): { [string]: any }?
	return if id == "key_first_explain" then LadderRules.keyVars(1) else nil
end

-- Tells the server a first-time explainer was answered (and whether "Skip tips" was pressed); it saves the flag.
local function saveExplained(topic: string, skip: boolean)
	answeredHere[topic] = true
	if skip then
		skippedHere = true
	end
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local remote = remotes and remotes:FindFirstChild("OnboardingRemote")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer("explained", topic, skip)
	end
end

-- Queues a topic's card for the next calm hub moment, once: never when it was answered, skipped or the profile is not loaded.
function LadderNotices.queueTopic(topic: string): boolean
	local row = ExplainerRules.rowOf(topic)
	if row and topicDue(topic) then
		enqueue(row)
		return true
	end
	return false
end

-- Tells the server the battle explainer was answered, so it never shows again for this account.
local function saveBattleIntro()
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local remote = remotes and remotes:FindFirstChild("TrackFlowRemote")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer("BattleIntroSeen")
	end
end

-- Opens the queued explainers one at a time once the hub has been calm for EXPLAIN_CALM seconds. v6 minor D2: if a race
-- (countdown, map switch, race) takes the screen while one is up and the player has not answered it, it is closed (never
-- over the race HUD) and queued again for the next calm hub moment.
function LadderNotices.drainExplainer()
	if draining or #queuedIds == 0 then
		return
	end
	draining = true
	task.spawn(function()
		local clear = 0
		while #queuedIds > 0 and LocalPlayer.Parent do
			if LadderRules.explainerStep(true, calmNow()) == "open" then
				clear += EXPLAIN_POLL
				if clear >= EXPLAIN_CALM then
					local id = table.remove(queuedIds, 1) :: string
					local topic = ExplainerRules.topicForRow(id)
					if topic and not topicDue(topic) then
						-- Answered elsewhere, or tips were skipped while it waited: drop it.
						clear = 0
						continue
					end
					local open, answered, suspended, primaryPressed = true, false, false, false
					NotifyKit.fromSpec(id, explainerVars(id), {
						onPrimary = function()
							open, answered, primaryPressed = false, true, true
						end,
						onClose = function()
							open = false
							answered = answered or not suspended
						end,
					})
					while open and LocalPlayer.Parent do
						task.wait(0.5)
						if LoginRules.modalFate(open, holdNow(), answered) == "suspend" then
							suspended = true
							NotifyKit.closeModalIf(id)
							open = false
							table.insert(queuedIds, 1, id)
						end
					end
					if id == "battle_first_explain" and not suspended then
						saveBattleIntro()
					end
					if topic and not suspended then
						-- A card with a close button ("Skip tips") that was closed without the primary button = skip all.
						local row = NotifySpec.get(id)
						local skip = row ~= nil and row.close ~= nil and not primaryPressed
						saveExplained(topic, skip)
					end
					clear = 0
				end
			else
				clear = 0
			end
			task.wait(EXPLAIN_POLL)
		end
		draining = false
	end)
end

-- Battle access: once any battle is open (map finished or key found) and the account has not seen the explainer, queue it for the
-- next calm hub moment. A returning player whose battles opened before this change gets it once too.
local battleIntroQueued = false -- once per session: a late BattleIntroSeen reply never re-queues it
local function checkBattleIntro()
	if battleIntroQueued then
		return
	end
	local open = BattleAccessRules.decode(LocalPlayer:GetAttribute(BattleAccessRules.ATTR))
	if BattleAccessRules.introDue(open, LocalPlayer:GetAttribute(BattleAccessRules.INTRO_ATTR)) then
		-- Only latched once really queued: if the Explained attribute has not replicated yet, a later change retries.
		battleIntroQueued = LadderNotices.queueTopic("battles")
	end
end

-- BattleResults award table ({ result, fragments, total, amulet }): the server's answer, never a client guess.
function LadderNotices.battleAward(award: any)
	if type(award) ~= "table" or award.result ~= "awarded" then
		return
	end
	if award.amulet then
		NotifyKit.fromSpec("amulet_found", nil, {
			onPrimary = function()
				local ok, Garage = pcall(function()
					return require(script.Parent:WaitForChild("Garage")) :: any
				end)
				if ok then
					pcall(Garage.open, "liveries")
				end
			end,
		})
	else
		NotifyKit.fromSpec("fragment_found", LadderRules.fragmentVars(tonumber(award.fragments) or 0))
	end
end

function LadderNotices.init()
	if started then
		return
	end
	started = true
	local raw = LocalPlayer:GetAttribute("SkyTokens")
	if type(raw) == "number" then
		lastTokens = raw
	end
	LocalPlayer:GetAttributeChangedSignal("SkyTokens"):Connect(onTokens)
	LocalPlayer:GetAttributeChangedSignal(BattleAccessRules.ATTR):Connect(checkBattleIntro)
	LocalPlayer:GetAttributeChangedSignal(BattleAccessRules.INTRO_ATTR):Connect(checkBattleIntro)
	LocalPlayer:GetAttributeChangedSignal(ExplainerRules.ATTR):Connect(checkBattleIntro)
	checkBattleIntro()
	LadderNotices.initExplainers()
	LadderNotices.initBadgeToast()
end

-- Items: the held-item attribute goes from empty to something. Garage: the Garage is on and the first race has started.
function LadderNotices.initExplainers()
	local lastItem: any = LocalPlayer:GetAttribute("ItemColor")
	LocalPlayer:GetAttributeChangedSignal("ItemColor"):Connect(function()
		local now = LocalPlayer:GetAttribute("ItemColor")
		if ExplainerRules.itemTrigger(lastItem, now) then
			LadderNotices.queueTopic("items")
		end
		lastItem = now
	end)
	local function checkGarage()
		if ExplainerRules.garageTrigger(workspace:GetAttribute("GarageEnabled"), LocalPlayer:GetAttribute("Onboarded")) then
			LadderNotices.queueTopic("garage")
		end
	end
	LocalPlayer:GetAttributeChangedSignal("Onboarded"):Connect(checkGarage)
	LocalPlayer:GetAttributeChangedSignal(ExplainerRules.ATTR):Connect(checkGarage)
	workspace:GetAttributeChangedSignal("GarageEnabled"):Connect(checkGarage)
	checkGarage()
end

-- The server fires BadgeEarned (badge key) only when BadgeService really awarded it (so never for an id the owner has not
-- created, and never for a badge the player already held). The title comes from BadgeRules.
function LadderNotices.badgeEarned(key: any)
	local title = BadgeRules.titleOf(key)
	if title then
		NotifyKit.fromSpec("badge_earned", { name = title }, { key = "badge_" .. tostring(key) })
	end
end

function LadderNotices.initBadgeToast()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		local remote = remotes and remotes:WaitForChild("BadgeEarned", 30)
		if remote and remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(LadderNotices.badgeEarned)
		end
	end)
end

return LadderNotices
