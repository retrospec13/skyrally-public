--!strict
-- Login popup rules (economy v3 step 7): pure logic, no services, no clocks. Every function takes the time it needs.
--  * once per UTC day per player: profile.streak.loginShownDay holds the last day the popup showed (0 = never, so old records
--    are due the first time). The server stamps the day in the same save edit that answers "show", so a second join, a second
--    server or a repeated request on the same day gets nothing.
--  * the client shows it only when nothing else owns the screen (canShowNow): hub, no lobby, no race, no map switch, no
--    loading screen, no Storm lobby, onboarding finished, no Garage panel or other modal open.
--  * content: today's daily reward (the existing streak), this month's theme (MonetizationConfig.THEME_CALENDAR), and the
--    countdown to the next Storm race (:00 / :30 UTC, STORM_CUP.periodSeconds).
-- Specced in tools/tests/login_rules_spec.luau.
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))

local LoginRules = {}

local DAY = 86400

export type Theme = { name: string, pitch: string, accent: { number }, month: number }

-- Civil month (1-12) of a UTC time in seconds (Howard Hinnant's days-to-civil; no os.date, so it runs the same everywhere).
function LoginRules.monthOf(t: number): number
	local z = math.floor(t / DAY) + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	return if mp < 10 then mp + 3 else mp - 9
end

-- The theme for the month `t` falls in. A month missing from the table (a config slip) falls back to the nearest earlier
-- listed month, then to a plain entry, so the popup never errors.
function LoginRules.theme(t: number, cfg: any?): Theme
	local table12 = (cfg or MonetizationConfig).THEME_CALENDAR
	local month = LoginRules.monthOf(t)
	for back = 0, 11 do
		local m = ((month - 1 - back) % 12) + 1
		local row = if type(table12) == "table" then table12[m] else nil
		if type(row) == "table" and type(row.name) == "string" then
			return { name = row.name, pitch = tostring(row.pitch or ""), accent = row.accent or { 150, 190, 240 }, month = month }
		end
	end
	return { name = "SkyRally", pitch = "", accent = { 150, 190, 240 }, month = month }
end

-- Is the popup due on `today` (UTC day number)? A missing or wrong-typed saved day counts as never shown.
function LoginRules.due(shownDay: any, today: number): boolean
	return type(shownDay) ~= "number" or shownDay ~= today
end

-- Seconds until the next Storm race start (the next multiple of the period strictly after t) and its time. At exactly :00 the
-- race starts now, so the next one is a full period away.
function LoginRules.stormCountdown(t: number, period: number?): (number, number)
	local p = period or MonetizationConfig.STORM_CUP.periodSeconds
	local nextAt = (math.floor(t / p) + 1) * p
	return nextAt - t, nextAt
end

-- "12:04" under an hour, "1:02:03" above (the Garage's clock style).
function LoginRules.formatClock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	if s >= 3600 then
		return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

export type Gate = {
	hold: string?, -- OnboardingRules.holdReason: race / lobby / switching / storm / loading
	raceMode: any, -- workspace RaceMode attribute
	onboarded: boolean, -- the Onboarded player attribute
	garageOpen: boolean,
	modalOpen: boolean,
	menuOpen: boolean?, -- v38-flow round 3: a modal board is up (course select, Settings, pause)
}
-- May the popup appear this instant? Never in a race, a lobby, the Storm lobby, a map switch or behind the loading screen;
-- a first-timer sees it only after onboarding; never over the Garage or another modal.
function LoginRules.canShowNow(g: Gate): boolean
	return g.hold == nil and g.raceMode == "hub" and g.onboarded == true and not g.garageOpen and not g.modalOpen and g.menuOpen ~= true
end

-- A race taking the screen (v6 minor D2): the countdown (lobby), the map switch and the race itself. A non-race modal that
-- is open when this happens (login popup, first-key explainer) is suspended, not left over the race HUD.
function LoginRules.raceTakesOver(hold: string?): boolean
	return hold == "race" or hold == "lobby" or hold == "switching"
end

-- What an open non-race modal does this instant: "suspend" (close it now; it was not answered, so it is offered again),
-- or "keep". `answered`: the player pressed its button or Later (closing it is theirs, nothing to re-offer).
function LoginRules.modalFate(open: boolean, hold: string?, answered: boolean): "suspend" | "keep"
	if open and not answered and LoginRules.raceTakesOver(hold) then
		return "suspend"
	end
	return "keep"
end

export type Reward = { day: number, cash: number, trail: string?, claimable: boolean }
export type View = { specId: string, vars: { [string]: any }, accent: { number }, claimable: boolean }

-- What the popup says. reward is the server's GetLogin data (day / cash / trail name for day 7 / claimable); t is the server
-- time now. Claimable -> the Claim card; claimed already today -> the same facts with one "Got it" button.
function LoginRules.view(reward: any, t: number, cfg: any?): View
	local theme = LoginRules.theme(t, cfg)
	local left = LoginRules.stormCountdown(t)
	local claimable = type(reward) == "table" and reward.claimable == true
	local cash = if type(reward) == "table" and type(reward.cash) == "number" then reward.cash else 0
	local day = if type(reward) == "table" and type(reward.day) == "number" then reward.day else 1
	local text = string.format("+%d Cash", cash)
	if claimable and type(reward.trail) == "string" then
		text ..= " and " .. reward.trail
	end
	return {
		specId = if claimable then "login_reward" else "login_info",
		vars = { day = day, reward = text, theme = theme.name, pitch = theme.pitch, time = LoginRules.formatClock(left) },
		accent = theme.accent,
		claimable = claimable,
	}
end

return LoginRules
