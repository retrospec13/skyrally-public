--!strict
-- Storm race v2, client half (economy v3 phase 5 flow; server/StormRace, docs/design/STORM_RACE_V2.md). Inert unless the
-- server runs v2 (workspace.StormRaceV2).
--   * the popup: when a JOIN window opens (workspace StormRaceState "open" / "late", once per StormRaceSeq) and this player
--     is in the hub, a NotifyKit modal in the storm skin with its storm animation, the track and a live countdown; JOIN
--     asks the server for a seat, "Not now" (or ignoring it) changes nothing. It closes itself when the window ends or the
--     player leaves the hub. Nobody is ever pulled: only JOIN slots a player.
--   * the Adventure board row (TrackFlow.addBoardRow): STORM RACE with its state and JOIN / LEAVE.
--   * after JOIN: the toast (field, time) and a "Storm race 0:42 - 5 in" banner with LEAVE until the start.
-- Copy: shared/NotifySpec storm_* rows (brief, MK-like).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NotifySpec = require(Shared:WaitForChild("NotifySpec"))
local StormFlowRules = require(Shared:WaitForChild("StormFlowRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local LocalPlayer = Players.LocalPlayer

local StormRaceClient = {}

StormRaceClient.PERIOD = 0.25
local MODAL_KEY = "storm_race"
local BANNER_KEY = "storm_race_wait"

local remote: RemoteEvent? = nil
local shownSeq: any = nil -- the window the popup already showed for
local joinedSeq: any = nil -- the window this player holds a seat in (before the start)
local board: { status: TextLabel, button: TextButton }? = nil

local function v2(): boolean
	return workspace:GetAttribute("StormRaceV2") == true and workspace:GetAttribute("StormRaceEnabled") == true
end

local function inHub(): boolean
	return RaceAttr.mine("RaceMode") == "hub"
end

local function fire(action: string)
	local r = remote
	if r then
		r:FireServer(action)
	end
end

local function trackName(): string
	local info = TrackInfo.get(workspace:GetAttribute("StormRaceTrack") :: string?)
	return if info then info.trackName else "The storm track"
end

local function nextIn(now: number): string
	local _, slot = StormFlowRules.phaseAt(now, 1800, 0, 0)
	local at = workspace:GetAttribute("StormCupAt")
	return StormFlowRules.clock((if type(at) == "number" and at > now then at else slot.startsAt) - now)
end

-- The popup body for this moment (before the start: time to GO; after: late seats left).
local function body(now: number): string
	local st = workspace:GetAttribute("StormRaceState")
	if st == "late" then
		local closeAt = workspace:GetAttribute("StormRaceCloseAt")
		local row = NotifySpec.get("storm_announce_late")
		return NotifySpec.format(if row then row.copy else "", { track = trackName(), time = StormFlowRules.clock((if type(closeAt) == "number" then closeAt else now) - now) })
	end
	local at = workspace:GetAttribute("StormRaceAt")
	local row = NotifySpec.get("storm_announce")
	return NotifySpec.format(if row then row.copy else "", { track = trackName(), time = StormFlowRules.clock((if type(at) == "number" then at else now) - now) })
end

local function showPopup(now: number)
	local row = NotifySpec.get("storm_announce")
	if not row then
		return
	end
	NotifyKit.modal(MODAL_KEY, {
		title = row.title,
		body = body(now),
		primary = row.primary,
		close = row.close,
		kind = row.kind,
		priority = row.priority,
		sound = row.sound,
		anim = "storm",
		onPrimary = function()
			fire("Join")
		end,
	})
end

local function step()
	local now = workspace:GetServerTimeNow()
	local st = workspace:GetAttribute("StormRaceState")
	local seq = workspace:GetAttribute("StormRaceSeq")
	local open = v2() and (st == "open" or st == "late") and seq ~= nil
	if not open or not inHub() then
		NotifyKit.closeModalIf(MODAL_KEY)
		if open and shownSeq == seq and joinedSeq ~= seq then
			shownSeq = nil -- v6 minor D2: closed by a race starting, not answered: offered again back in the hub while open
		end
	elseif seq ~= shownSeq and joinedSeq ~= seq then
		shownSeq = seq
		showPopup(now)
	else
		NotifyKit.setModalBody(MODAL_KEY, body(now))
	end
	-- The joined player's wait line with LEAVE, until the start.
	if joinedSeq ~= nil and (joinedSeq ~= seq or st ~= "open" or not inHub()) then
		joinedSeq = nil
	end
	if joinedSeq ~= nil then
		local at = workspace:GetAttribute("StormRaceAt")
		local n = workspace:GetAttribute("StormRaceJoined")
		NotifyKit.banner(BANNER_KEY, string.format("Storm race %s - %s in", StormFlowRules.clock((if type(at) == "number" then at else now) - now), tostring(n or 1)), {
			kind = "storm",
			priority = "high",
			action = { label = "LEAVE", onActivated = function()
				fire("Leave")
			end },
		})
	else
		NotifyKit.clearBanner(BANNER_KEY)
	end
	-- The board row, while it is on screen.
	local b = board
	if b and b.status.Parent then
		local closeAt = workspace:GetAttribute("StormRaceCloseAt")
		local at = workspace:GetAttribute("StormRaceAt")
		local mine = joinedSeq ~= nil
		b.status.Text = if st == "open" and type(at) == "number" then string.format("%s - GO IN %s - %s IN", trackName(), StormFlowRules.clock(at - now), tostring(workspace:GetAttribute("StormRaceJoined") or 0))
			elseif st == "late" and type(closeAt) == "number" then string.format("%s - LATE SEATS %s", trackName(), StormFlowRules.clock(closeAt - now))
			elseif workspace:GetAttribute("StormRaceLive") == true then "IN PROGRESS - NEXT IN " .. nextIn(now)
			else "NEXT STORM RACE IN " .. nextIn(now)
		b.button.Text = if mine then "LEAVE" else "JOIN"
		local can = open and inHub()
		b.button.AutoButtonColor = can or mine
		b.button.BackgroundTransparency = if can or mine then 0 else 0.6
	else
		board = nil
	end
end

local function addBoardRow(parent: Instance, order: number)
	if not v2() then
		return
	end
	local row = Instance.new("Frame")
	row.Name = "StormRace"
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -8, 0, 54)
	row.BackgroundColor3 = Color3.fromRGB(24, 26, 46)
	row.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(150, 150, 255)
	stroke.Thickness = 2
	stroke.Parent = row
	local function text(name: string, t: string, size: UDim2, pos: UDim2, font: Enum.Font, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Size = size
		l.Position = pos
		l.Font = font
		l.Text = t
		l.TextColor3 = color
		l.TextScaled = true
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = row
		return l
	end
	text("Title", "STORM RACE", UDim2.new(1, -116, 0, 24), UDim2.new(0, 12, 0, 4), Enum.Font.GothamBlack, Color3.fromRGB(200, 200, 255))
	local status = text("Status", "", UDim2.new(1, -116, 0, 18), UDim2.new(0, 12, 0, 30), Enum.Font.GothamBold, Color3.fromRGB(230, 230, 250))
	local jb = Instance.new("TextButton")
	jb.Name = "Join"
	jb.Size = UDim2.new(0, 88, 0, 36)
	jb.Position = UDim2.new(1, -96, 0, 9)
	jb.BackgroundColor3 = Color3.fromRGB(110, 100, 230)
	jb.Font = Enum.Font.GothamBlack
	jb.TextScaled = true
	jb.TextColor3 = Color3.fromRGB(255, 255, 255)
	jb.Text = "JOIN"
	jb.Selectable = true
	jb.Parent = row
	local jc = Instance.new("UICorner")
	jc.CornerRadius = UDim.new(0, 6)
	jc.Parent = jb
	local tc = Instance.new("UITextSizeConstraint")
	tc.MaxTextSize = 18
	tc.Parent = jb
	UiSound.bind(jb, "confirm")
	jb.Activated:Connect(function()
		if joinedSeq ~= nil then
			fire("Leave")
		elseif inHub() and (workspace:GetAttribute("StormRaceState") == "open" or workspace:GetAttribute("StormRaceState") == "late") then
			fire("Join")
		else
			NotifyKit.fromSpec("storm_closed", { time = nextIn(workspace:GetServerTimeNow()) })
		end
	end)
	board = { status = status, button = jb }
	step()
end

local function onEvent(kind: any, data: any)
	local d = if type(data) == "table" then data else {}
	local now = workspace:GetServerTimeNow()
	if kind == "Joined" then
		joinedSeq = workspace:GetAttribute("StormRaceSeq")
		shownSeq = joinedSeq
		NotifyKit.closeModalIf(MODAL_KEY)
		NotifyKit.fromSpec("storm_slotted", { field = tonumber(d.field) or 1, time = StormFlowRules.clock((tonumber(d.at) or now) - now) })
	elseif kind == "Left" then
		joinedSeq = nil
		NotifyKit.fromSpec("storm_left")
	elseif kind == "Launched" then
		joinedSeq = nil
		NotifyKit.closeModalIf(MODAL_KEY)
		NotifyKit.fromSpec("storm_go")
	elseif kind == "Refused" then
		joinedSeq = nil
		local why = d.why
		if why == "racing" then
			NotifyKit.fromSpec("storm_racing")
		elseif why == "full" or why == "busy" then
			NotifyKit.fromSpec("storm_full", { time = nextIn(now) })
		elseif why == "cancelled" then
			NotifyKit.fromSpec("storm_cancelled")
		else
			NotifyKit.fromSpec("storm_closed", { time = nextIn(now) })
		end
	end
	step()
end

function StormRaceClient.init(TrackFlow: any)
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 60)
		local r = if folder then folder:WaitForChild("StormRaceRemote", 60) else nil
		if r and r:IsA("RemoteEvent") then
			remote = r
			r.OnClientEvent:Connect(onEvent)
		end
	end)
	if TrackFlow and type(TrackFlow.addBoardRow) == "function" then
		TrackFlow.addBoardRow(addBoardRow)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < StormRaceClient.PERIOD then
			return
		end
		acc = 0
		if workspace:GetAttribute("StormRaceV2") ~= true then
			return
		end
		local ok, err = pcall(function(): any
			step()
			return nil
		end)
		if not ok then
			warn("[SkyRally][STORM_RACE] client step failed: " .. tostring(err))
		end
	end)
	print("[SkyRally][STORM_RACE] client ready (" .. LocalPlayer.Name .. ")")
end

return StormRaceClient
