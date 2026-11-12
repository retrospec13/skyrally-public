--!strict
-- Login popup (economy v3 step 7): a NotifyKit modal with today's daily reward, this month's theme and the countdown to the next
-- Storm race. Once per UTC day per player (the server stamps profile.streak.loginShownDay when it answers GetLogin), only at a
-- calm hub moment (shared/LoginRules.canShowNow): never in a race, a lobby, a Storm lobby, a map switch, behind the loading
-- screen, before a first-timer finished onboarding, or over the Garage. Nobody is pulled anywhere; Later closes it.
-- CLAIM is the daily claim (Economy ClaimLoginDaily). With LAUNCH_HIDE on the Garage DAILY tab is hidden and this is the only
-- path; with it off both work and the server's once-per-day check keeps them in step. All words are NotifySpec rows
-- (login_reward / login_info); the look is NotifySkin "reward" plus the month's accent from MonetizationConfig.THEME_CALENDAR.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local LoginRules = require(Shared:WaitForChild("LoginRules"))
local NotifySpec = require(Shared:WaitForChild("NotifySpec"))
local OnboardingRules = require(Shared:WaitForChild("OnboardingRules"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local Garage = require(script.Parent:WaitForChild("Garage"))
local TrackFlow = require(script.Parent:WaitForChild("TrackFlow")) -- v38-flow round 3: never over the course board
local Settings = require(script.Parent:WaitForChild("Settings"))
local PauseMenu = require(script.Parent:WaitForChild("PauseMenu"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local LocalPlayer = Players.LocalPlayer

local LoginPopup = {}

local KEY = "login"
local POLL = 1 -- seconds between gate checks
local CALM = 2 -- the gate must stay clear this many seconds before the popup asks the server or opens
local RETRY = 4 -- seconds before asking again after "loading"
local MAX_TRIES = 10

local request: RemoteFunction? = nil
local startedAt = os.clock()

local function invoke(action: string): any
	local remote = request
	if not remote then
		return { ok = false, reason = "unavailable" }
	end
	local ok, reply = pcall(function(): any
		return remote:InvokeServer(action)
	end)
	if not ok or type(reply) ~= "table" then
		return { ok = false, reason = "unavailable" }
	end
	return reply
end

local function gate(): LoginRules.Gate
	local now = workspace:GetServerTimeNow()
	local st = workspace:GetAttribute("StormCupState")
	local hold = OnboardingRules.holdReason({
		raceMode = RaceAttr.mine("RaceMode"),
		lobbyGoAt = workspace:GetAttribute("LobbyGoAt"),
		now = now,
		switching = workspace:GetAttribute("TrackSwitching") == true,
		stormHold = workspace:GetAttribute("StormCupEnabled") == true and (st == "lobby" or st == "due"),
		loadingOver = LocalPlayer:GetAttribute("LoadingDone") == true or os.clock() - startedAt > OnboardingRules.LOADING_MAX,
	})
	return {
		hold = hold,
		raceMode = RaceAttr.mine("RaceMode"),
		onboarded = LocalPlayer:GetAttribute("Onboarded") == true,
		garageOpen = Garage.isOpen(),
		modalOpen = NotifyKit.modalOpen(),
		-- a modal board (course select, Settings, the pause card) holds every queued popup until it closes
		menuOpen = TrackFlow.isBoardOpen() or Settings.isOpen() or PauseMenu.isOpen(),
	}
end

-- Is this a calm hub moment right now? (The same gate the popup uses; LadderNotices defers the first-key explainer on it.)
function LoginPopup.calmNow(): boolean
	return LoginRules.canShowNow(gate())
end

-- Why the hub is not free (OnboardingRules.holdReason: race / lobby / switching / ...), nil when nothing holds it. Lets other
-- modal owners (LadderNotices) suspend theirs the moment a race takes the screen (v6 minor D2).
function LoginPopup.holdNow(): string?
	return gate().hold
end

-- Waits until the gate has been clear for CALM seconds. Gives up (false) when the player leaves.
local function waitCalm(): boolean
	local clearFor = 0
	while LocalPlayer.Parent do
		if LoginRules.canShowNow(gate()) then
			clearFor += POLL
			if clearFor >= CALM then
				return true
			end
		else
			clearFor = 0
		end
		task.wait(POLL)
	end
	return false
end

local function claim()
	local reply = invoke("ClaimLoginDaily")
	if reply.ok and type(reply.data) == "table" then
		UiSound.play("purchase")
		NotifyKit.fromSpec("cash_gain", { n = reply.data.gears or 0 })
		for _, name in (if type(reply.data.cosmetics) == "table" then reply.data.cosmetics else {}) :: { any } do
			NotifyKit.fromSpec("avatar_unlock", { name = tostring(name) }, { key = "login_trail" })
		end
	elseif reply.reason ~= "claimed" then
		NotifyKit.toast("Could not claim right now", { kind = "warn", seconds = 2.6 })
	end
end

-- Returns true when a race took the screen while it was up and the player had not answered: the card is closed (no popup over
-- the race HUD) and run() offers it again at the next calm hub moment (v6 minor D2).
local function present(data: any): boolean
	local view = LoginRules.view(data, workspace:GetServerTimeNow())
	local row = NotifySpec.get(view.specId)
	if not row then
		return false
	end
	local open = true
	local answered = false
	local suspended = false
	NotifyKit.fromSpec(view.specId, view.vars, {
		key = KEY,
		accent = view.accent,
		fit = true, -- the card is as tall as its text, no empty gap above the buttons
		onPrimary = function()
			open = false
			answered = true
			if view.claimable then
				claim()
			end
		end,
		onClose = function()
			open = false
			answered = answered or not suspended
		end,
	})
	-- The Storm countdown ticks while the card is up.
	task.spawn(function()
		while open and LocalPlayer.Parent do
			task.wait(1)
			local left = LoginRules.stormCountdown(workspace:GetServerTimeNow())
			view.vars.time = LoginRules.formatClock(left)
			NotifyKit.setModalBody(KEY, NotifySpec.format(row.copy, view.vars))
		end
	end)
	while open and LocalPlayer.Parent do
		task.wait(0.5)
		if LoginRules.modalFate(open, gate().hold, answered) == "suspend" then
			suspended = true
			NotifyKit.closeModalIf(KEY)
			open = false
		end
	end
	return suspended
end

local function run()
	local doneDay = -1 -- the UTC day this client has already heard about
	while LocalPlayer.Parent do
		local today = math.floor(workspace:GetServerTimeNow() / 86400)
		if today == doneDay then
			task.wait(30)
		elseif not waitCalm() then
			return
		else
			local reply = invoke("GetLogin")
			if reply.ok and type(reply.data) == "table" then
				doneDay = today
				if reply.data.show == true then
					-- The server stamped the day when it answered: wait out anything that started meanwhile, then show.
					-- A race that starts while it is up closes it; it comes back at the next calm moment until answered.
					while waitCalm() and present(reply.data) do
						task.wait(POLL)
					end
				end
			elseif reply.reason == "loading" then
				task.wait(RETRY)
			else
				MAX_TRIES -= 1
				if MAX_TRIES <= 0 then
					return
				end
				task.wait(RETRY)
			end
		end
	end
end

function LoginPopup.init()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
		local rf = remotes and remotes:WaitForChild("EconomyRequest", 15)
		if rf and rf:IsA("RemoteFunction") then
			request = rf
			run()
		end
	end)
end

return LoginPopup
