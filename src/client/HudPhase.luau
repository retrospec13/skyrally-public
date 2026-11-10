--!strict
-- The ONE applier of shared/HudPhaseRules.VISIBLE (docs/design/HUD_LAYOUT.md section 6). It works out the phase from what the
-- client already knows (workspace RaceMode / RaceGoTime, the results card via setResultsUp, the podium via setPodium) and,
-- every 0.1 s and on every change, writes each named HUD element's PhaseHudOn attribute. Elements nothing else drives (the
-- position badge, the lap/time chip, the "0/14" chip, the gear + "?" system cluster) get Visible set here; elements their
-- owner also drives (RESPAWN, the item frame, the combo meter) get hidden here when the phase says so and read PhaseHudOn to
-- stay hidden; the touch controls (steer pad + TURN / ITEM zone) are shown only on Touch and only when the phase allows.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local HudPhaseRules = require(Shared:WaitForChild("HudPhaseRules"))
-- Economy v3 phase 2b: this client's own race (its RaceInstance per group); workspace:GetAttribute while
-- RaceFlowRules.PER_GROUP is false.
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local HudPhase = {}

local LocalPlayer = Players.LocalPlayer

-- How each element is applied: "set" = Visible follows the rule exactly; "mask" = only ever forced hidden (the owner
-- shows it and ANDs PhaseHudOn); "touch" = Visible follows the rule AND the touch input mode (InputMode owns the mode).
local MODE: { [string]: string } = {
	PositionBadge = "set",
	LapTimeChip = "set",
	SkyTokenCounter = "set",
	SystemCluster = "set",
	Minimap = "set",
	ItemSlot = "mask",
	RespawnButton = "mask",
	ReturnButton = "mask",
	StyleChainMeter = "mask",
	TouchControls = "touch",
}

-- A rule row that stands for several instances: name -> { gui name, instance name } paths. A path with one entry is found
-- anywhere under the PlayerGui; with two, it is the named child of the named ScreenGui (the Garage has a gear of its own).
local GROUPS: { [string]: { { string } } } = {
	SystemCluster = { { "SkyRallyGear", "SettingsGear" }, { "HelpButton" } },
	TouchControls = { { "LeftSteerZone" }, { "RightThrottleZone" } },
}

local resultsUp = false
local podiumUp = false
local finishing = false
local phase: HudPhaseRules.Phase = "hub"
local cache: { [string]: GuiObject } = {}
local missAt: { [string]: number } = {} -- key -> os.clock() of the last failed search (an unbuilt element is looked up once a second, not every tick)
local MISS_RETRY = 1
local started = false

function HudPhase.phase(): HudPhaseRules.Phase
	return phase
end

function HudPhase.allows(name: string): boolean
	return HudPhaseRules.visible(name, phase)
end

local function find(path: { string }): GuiObject?
	local key = table.concat(path, "/")
	local g = cache[key]
	if g and g.Parent then
		return g
	end
	local missed = missAt[key]
	if missed and os.clock() - missed < MISS_RETRY then
		return nil
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local f: Instance? = nil
	if pg then
		if #path == 2 then
			local holder = pg:FindFirstChild(path[1])
			f = if holder then holder:FindFirstChild(path[2]) else nil
		else
			f = pg:FindFirstChild(path[1], true)
		end
	end
	if f and f:IsA("GuiObject") then
		cache[key] = f
		missAt[key] = nil
		return f
	end
	missAt[key] = os.clock()
	return nil
end

local function applyTo(g: GuiObject, name: string, how: string, on: boolean)
	if g:GetAttribute("PhaseHudOn") ~= on then
		g:SetAttribute("PhaseHudOn", on)
	end
	if how == "set" then
		if g.Visible ~= on then
			g.Visible = on
		end
	elseif how == "touch" then
		local want = on and LocalPlayer:GetAttribute("InputMode") == "Touch"
		if g.Visible ~= want then
			g.Visible = want
		end
	elseif not on and g.Visible then
		g.Visible = false
	end
end

local function apply()
	local goAt = RaceAttr.mine("RaceGoTime")
	phase = HudPhaseRules.phaseOf(RaceAttr.mine("RaceMode"), goAt, workspace:GetServerTimeNow(), resultsUp, podiumUp, finishing)
	for name, how in MODE do
		local on = HudPhaseRules.visible(name, phase)
		local paths: { { string } } = GROUPS[name] or { { name } }
		for _, path in paths do
			local g = find(path)
			if g then
				applyTo(g, name, how, on)
			end
		end
	end
end

function HudPhase.refresh()
	apply()
end

-- RaceUI: the results card is up.
function HudPhase.setResultsUp(up: boolean)
	if resultsUp ~= up then
		resultsUp = up
		apply()
	end
end

-- FinishShow: the local racer crossed the line and the photo cam / ceremony run; ends when the results card shows (or a reset).
function HudPhase.setFinishing(on: boolean)
	if finishing ~= on then
		finishing = on
		apply()
	end
end

-- PodiumCeremony: the ceremony starts / ends.
function HudPhase.setPodium(up: boolean)
	if podiumUp ~= up then
		podiumUp = up
		apply()
	end
end

function HudPhase.init()
	if started then
		return
	end
	started = true
	local acc = 0
	RunService.Heartbeat:Connect(Prof.wrap("SR_HudPhase", function(dt: number)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			apply()
		end
	end))
	for _, a in { "RaceMode", "RaceGoTime" } do
		RaceAttr.changed(a, apply)
	end
	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(apply)
	apply()
end

return HudPhase
