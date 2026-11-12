--!strict
-- Track flow UI (PLAN L4, client half of TrackDirector):
--   * curtain while the server switches maps (workspace.TrackSwitching / NextTrackId), zone-coloured with the names;
--   * 3-2-1-GO over the grid hold (workspace.RaceGoTime, server time);
--   * hub mode (workspace.RaceMode == "hub"): race plaques hidden, an ADVENTURE button and board listing each zone with
--     its gate (player attribute PortalStates, JSON from the server), labels over the portal arches;
--   * toasts for locked portals and hub finds, and the "back to the hub" timer after a race (workspace.ReturnToHubAt);
--     the finish screen's CLOSE button becomes HUB.
--   * hidden keys (L70): the "KEY FOUND - <Zone> battle unlocked" toast, and the track's key hidden for this player
--     once held (player attribute KeysHeld, JSON zones);
--   * battles (RaceMode "battle", server/battle/BattleCore): a non-modal HUD plank (mode title, time left, this
--     player's objective line BattleHud) and the field board (workspace.BattleBoard JSON), toasts ("BattleToast"),
--     and the results panel ("BattleResults": winner, ranking, fragment award) with HUB / AGAIN.
--   * Storm Cup (server/StormCup): the hub line under ADVENTURE (next cup, its map and modifier; the Festival once the
--     Garage is on), the curtain's cup title and the "Storm Cup starts in" toast when the lobby minute holds a race.
--   * 2+ humans (L30-L32, shared/RaceFlowRules): the portal lobby banner and countdown on every hub client (workspace
--     LobbyTrack / LobbyMode / LobbyOpener / LobbyGoAt, the guest line from player LobbyGuest), and the vote counts on
--     the finish card's and the battle results' buttons ("AGAIN 1/3", "HUB 2/3": workspace VotesAgain / VotesHub /
--     VoteHumans); with votes the card stays up after a press, so the counts stay in view.
--   * the portal queue (economy v3 phase 3, shared/PortalQueueRules): each open arch's NotifyKit label and glow (OPEN /
--     FILLING / RACING from workspace ArchStates), the Adventure board's state line and JOIN / LEAVE per track, and the
--     joined player's "Waiting for racers 0:14 - 3/8" line with LEAVE (player attribute LobbyArch). Only the joined
--     player hears the lobby's moments (LobbyJoined / LobbyLeft / LobbyRefused).
-- Every button is gamepad selectable; sizes scale for phone landscape and desktop (D20).
-- UI overhaul phase C: the hub bar, the Adventure board (panel_wood, zone rows on row_plank tinted by the zone colour),
-- the lobby banner (sign_hanging) and the battle plank / board / results draw through client/UiSkin, buttons through
-- UiSkin.button (a TextButton in the flat fallback, an ImageButton with a "Label" once art lands: text goes through
-- UiSkin.setText). With no art uploaded the look is the same flat wood as before. The board swooshes up from the bottom
-- and back down, the battle results pop in and out (client/UiMotion); the curtain stays a plain fade.
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local GarageModel = require(Shared:WaitForChild("GarageModel")) -- Storm Cup line size and modifier names
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules")) -- lobby banner and vote labels (L30-L32)
local GroupCurtainRules = require(Shared:WaitForChild("GroupCurtainRules")) -- per-group loading curtain (phase 2b)
local MapReadyRules = require(Shared:WaitForChild("MapReadyRules")) -- v37: answer the server once the new map is in
local ResultsLayoutRules = require(Shared:WaitForChild("ResultsLayoutRules")) -- where the return countdown sits under the results card
local FidelityRules = require(Shared:WaitForChild("FidelityRules")) -- completion line on the Adventure board (M-1)
local GridOrder = require(Shared:WaitForChild("GridOrder")) -- the grid line under the countdown (GRID_ORDER.md)
local ItemRules = require(Shared:WaitForChild("ItemRules")) -- items v4: the race's rotation line in the countdown
-- REMARKABLE 4: board buttons speak wood and marimba (tab / confirm / back / deny) and squash on press.
local UiSound = require(script.Parent.UiSound)
local UiSkin = require(script.Parent:WaitForChild("UiSkin"))
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))
local CourseSelect = require(script.Parent:WaitForChild("CourseSelect")) -- UI v2 course select (the Adventure board's look)
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local SfxRules = require(Shared:WaitForChild("SfxRules"))
local UiSkinRules = require(Shared:WaitForChild("UiSkinRules")) -- the lobby banner's open cue
-- REMARKABLE 8: Curtain Kart, a playable mini track of the next map inside the curtain (start/stop in showCurtain).
local CurtainKart = require(script.Parent:WaitForChild("CurtainKart"))
-- REMARKABLE 20 and 24: Portal Plunge (warp, emblem iris, locked arches spit you out) and Token Homecoming.
local PortalPlunge = require(script.Parent:WaitForChild("PortalPlunge"))
local TokenHomecoming = require(script.Parent:WaitForChild("TokenHomecoming"))
local LadderNotices = require(script.Parent:WaitForChild("LadderNotices")) -- economy v3 phase 8: key / fragment / token / map-unlock explanations
local BattleAccessRules = require(Shared:WaitForChild("BattleAccessRules"))
local LadderRules = require(Shared:WaitForChild("LadderRules"))
-- L28 / L82: the hub bar and the battle plaques keep inside the device safe area (notch, TV overscan); the curtain stays full-bleed.
local SafeArea = require(script.Parent:WaitForChild("SafeArea"))
-- HUD layout v2: hub bar, countdown, grid line, toast, lobby banner and the battle plaque are placed from the shared rects
-- (lane A = hero / countdown, lane B = captions, top-right slot = hub bar).
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local HudLayoutRules = require(Shared:WaitForChild("HudLayoutRules"))
local WorldLabelRules = require(Shared:WaitForChild("WorldLabelRules")) -- battle world labels: distance scale, short text, occlusion
-- L27: the first-session guide (arrow and beacon end when the player drives through a portal).
local Onboarding = require(script.Parent:WaitForChild("Onboarding"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit")) -- toast queue, banners, modals (economy v3 phase 3b)
-- Economy v3 phase 3: the portal IS the queue (arch labels, board rows, the joined player's line; copy in NotifySpec).
local PortalQueueRules = require(Shared:WaitForChild("PortalQueueRules"))
local NotifySpec = require(Shared:WaitForChild("NotifySpec"))

local LocalPlayer = Players.LocalPlayer

local TrackFlow = {}

local CREAM = Color3.fromRGB(250, 242, 222)
local MUTED_CREAM = Color3.fromRGB(214, 204, 184)
local WOOD = Color3.fromRGB(108, 76, 52)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local RIM = Color3.fromRGB(188, 168, 142)
local TONE_COLOR_WARN = Color3.fromRGB(255, 226, 64) -- ARENA EDGE / TOO HIGH

local remote: RemoteEvent? = nil
local gui: ScreenGui
local hubBarLogged = false -- the one-time [SkyRally][HUD] hub bar size log (applyLayout)
local curtain: Frame
local curtainZone: TextLabel
local curtainTrack: TextLabel
local CURTAIN_NAVY = Color3.fromRGB(42, 75, 168) -- UI v2 panel top (#2A4BA8; the gradient darkens it to the bottom)
local curtainZoneColor: Color3 = Color3.fromRGB(62, 40, 24) -- the arriving zone's colour (iris reveal, map well)
local curtainHint: TextLabel
local countdownLabel: TextLabel
local numeralSize = 0 -- px of the countdown glyphs from HudLayoutRules.countdownNumeral (0: size it from lane A, as the hub does)
local lastCountdownText = "" -- v21: the countdown label carries RichText markup, so the last plain text is kept here
local gridLabel: TextLabel -- "You start 3rd - last race you finished 6th" over the grid hold (server Grid* attributes)
local hubBar: Frame
local boardFrame: Frame
local returnLabel: TextLabel
local stormLabel: TextLabel
local lastCount = -1
local lastStormText = ""
-- L31/L32: the lobby banner (top centre, under the toast) and the finish card's buttons the vote counts go on.
local lobbyFrame: Frame
local lobbyText: TextLabel
local lobbyGuest: TextLabel
local lastLobbyText = ""
-- Phase 3: arch labels (one NotifyKit arch label per open arch), the board's queue widgets and the wait line.
-- ARCH_LABELS false keeps the old "DRIVE IN TO RACE" sign line and no world label (config, never deleted).
local ARCH_LABELS = true
local ARCH_LABEL_STANDOFF = 2.5 -- studs between the shimmer face and the label anchor (clears the PortalFill disc layers)
type ArchLabel = { handle: any, trackId: string, text: string, state: string, anchor: BasePart? }
local archLabelByPart: { [BasePart]: ArchLabel } = {}
-- Hub declutter (owner 2026-10-21): one compact sign per arch. The floating "RACE - drive through to start" billboard is
-- gone (it overlapped the sign, clipped behind the posts and collided with its neighbour); an open arch's queue state
-- (filling / racing) now reads in the sign's own gate line, and an idle arch says nothing extra.
local ARCH_BILLBOARD = false
local archSignByPart: { [BasePart]: string } = {} -- shimmer -> trackId, for the sign's gate line
local boardQueue: { [string]: boolean } = {} -- open arch track ids whose queue line the course select shows
local lastWaitText = ""
local lastQueueStep = -math.huge

-- GuiButton: RaceUI's finish buttons and the results buttons are UiSkin buttons (TextButton or ImageButton + Label).
local finishAgainBtn: GuiButton? = nil
local finishHubBtn: GuiButton? = nil
local boardOnHubAt = -math.huge -- v38-flow: COURSES on the results card: open the course select when the hub is back
local resultsHub: GuiButton? = nil
local resultsAgainBtn: GuiButton? = nil

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
end

local function stroke(p: Instance, color: Color3, t: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = t
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
end

local function label(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = font or Enum.Font.GothamBlack
	-- UI v2: the theme faces (GothamBlack -> the heavy italic display face, others -> the rounded body face), white text
	-- with the ink stroke.
	l.FontFace = UiSkin.font(if font == nil or font == Enum.Font.GothamBlack then "display" else "bodyHeavy")
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Text = text
	local ink = Instance.new("UIStroke")
	ink.Color = UiSkin.color("ink")
	ink.Thickness = 1.5
	ink.LineJoinMode = Enum.LineJoinMode.Round
	ink.Parent = l
	l.Parent = parent
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = 96
	c.Parent = l
	return l
end

local function fire(action: string, arg: any?, arg2: any?)
	if remote then
		remote:FireServer(action, arg, arg2)
	end
end

-- L30: true while FLY AGAIN / HUB are votes (2+ humans in a race); the server publishes VoteHumans only then.
local function voting(): boolean
	local n = RaceAttr.mine("VoteHumans")
	return type(n) == "number" and n >= 2
end
TrackFlow.voting = voting

-- "AGAIN 1/3" / "HUB 2/3" on the finish card and the battle results; the plain labels solo or before any vote.
local function refreshVoteLabels()
	local humans = RaceAttr.mine("VoteHumans")
	local again = RaceAttr.mine("VotesAgain")
	local hub = RaceAttr.mine("VotesHub")
	local fa = finishAgainBtn
	if fa then
		-- planes fly again, cars race again (owner copy 2026-11-10)
		local tinfo = TrackInfo.get(RaceAttr.mine("ActiveTrackId") :: string?)
		local idle = if tinfo and tinfo.vehicle == "car" then "RACE AGAIN" else "FLY AGAIN"
		UiSkin.setText(fa, RaceFlowRules.voteLabel(idle, "AGAIN", again, humans))
	end
	local fh = finishHubBtn
	if fh then
		-- v38-flow: solo, the card's third key is COURSES (back to the island with the course select open, MK's
		-- "change course"); with votes it stays the HUB vote.
		UiSkin.setText(fh, RaceFlowRules.voteLabel("COURSES", "HUB", hub, humans))
	end
	local ra = resultsAgainBtn
	if ra then
		UiSkin.setText(ra, RaceFlowRules.voteLabel("AGAIN", "AGAIN", again, humans))
	end
	local rh = resultsHub
	if rh then
		UiSkin.setText(rh, RaceFlowRules.voteLabel("HUB", "HUB", hub, humans))
	end
end

-- The lobby's track name for the banner: the zone, plus the mode when it is not the standard race.
local function lobbyTrackLabel(): string
	local id = workspace:GetAttribute("LobbyTrack")
	local info = TrackInfo.get(if type(id) == "string" then id else nil)
	local name = if info then info.zoneName else tostring(id or "a race")
	local mode = workspace:GetAttribute("LobbyMode")
	if type(mode) == "string" and mode ~= "race" then
		local MODES: { [string]: string } = { quickrace = "QUICK", boss = "BOSS", coin = "COINS", rematch = "REMATCH", timetrial = "TIME TRIAL", battle = "BATTLE" }
		name ..= " " .. (MODES[mode] or string.upper(mode))
	end
	return name
end

local placeLaneA: () -> ()

-- Thin wrapper over NotifyKit (economy v3 phase 3b): the queue, skin and lane B placement live there; call sites are unchanged.
function TrackFlow.toast(msg: string, color: Color3?, seconds: number?)
	-- The battle's edge / ceiling warnings are the one caption that must not be missed: bright amber text, a hot rim, top priority.
	local warning = string.find(msg, "^ARENA EDGE") ~= nil or string.find(msg, "^TOO HIGH") ~= nil
	NotifyKit.toast(msg, {
		kind = if warning then "warn" else "info",
		priority = if warning then "high" else "normal",
		color = if warning then TONE_COLOR_WARN else color,
		seconds = seconds,
	})
end

-- Race plaques that mean nothing in the hub (position, lap chip): HudPhase is the one applier; this only asks it to
-- re-evaluate now.
local function setRaceHudVisible(_on: boolean)
	HudPhase.refresh()
end

local function portalStates(): { any }
	local raw = LocalPlayer:GetAttribute("PortalStates")
	if type(raw) ~= "string" then
		return {}
	end
	local ok, t = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	return if ok and type(t) == "table" then t else {}
end

local MODE_LABEL: { [string]: string } = {
	race = "RACE",
	quickrace = "QUICK",
	boss = "BOSS",
	coin = "COINS",
	rematch = "REMATCH",
	timetrial = "TIME TRIAL",
	battle = "BATTLE",
	stormrace = "STORM",
}
local MODE_COLOR: { [string]: Color3 } = {
	race = Color3.fromRGB(78, 148, 58),
	quickrace = Color3.fromRGB(40, 130, 120),
	boss = Color3.fromRGB(176, 52, 40),
	coin = Color3.fromRGB(150, 160, 180),
	rematch = Color3.fromRGB(120, 30, 60),
	timetrial = Color3.fromRGB(56, 110, 170),
	battle = Color3.fromRGB(196, 120, 24),
}

-- Curtain line per battle kind (workspace.NextBattleKind); the four launch kinds of LAUNCH_PROGRESSION 2b.
local BATTLE_HINT: { [string]: string } = {
	survival = "SURVIVAL BATTLE - 3 lives each, last one flying wins",
	egg = "EGG BATTLE - carry eggs to your nest, first to hatch 3 wins",
	water = "WATER BATTLE - 3 lives each while the tide rises",
	hoard = "HOARD BATTLE - carry acorns home, first to 20 wins",
}

-- Rows other modules add to the Adventure board on every rebuild (storm race v2: client/StormRaceClient).
local boardRowHooks: { (parent: Instance, layoutOrder: number) -> () } = {}
function TrackFlow.addBoardRow(fn: (parent: Instance, layoutOrder: number) -> ())
	table.insert(boardRowHooks, fn)
end

local openBoard: (on: boolean, silent: boolean?) -> () -- below; the board's buttons close it

-- UI v2 course select (client/CourseSelect draws it): the board's model from PortalStates and CompletionInfo.
local function rebuildBoard()
	table.clear(boardQueue)
	-- J3: tokens, keys, fragments and the final boss along the top; once everything is done, the full text leads.
	local info = FidelityRules.decode(LocalPlayer:GetAttribute(FidelityRules.COMPLETION_ATTRIBUTE))
	local nums = {}
	if info then
		for a, b2 in string.gmatch(info.line, "(%d+)/(%d+)") do
			table.insert(nums, { tonumber(a) or 0, tonumber(b2) or 0 })
		end
	end
	local function n(i: number, j: number, default: number): number
		local r = nums[i]
		return if r then r[j] else default
	end
	local tokens = tonumber(LocalPlayer:GetAttribute("SkyTokens")) or 0
	local function listAttr(name: string): { [string]: boolean }
		local out: { [string]: boolean } = {}
		local raw = LocalPlayer:GetAttribute(name)
		if type(raw) ~= "string" or raw == "" then
			return out
		end
		local ok, t = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(t) == "table" then
			for _, v in t do
				out[tostring(v)] = true
			end
		else
			for v in string.gmatch(raw, "[^,]+") do
				out[v] = true
			end
		end
		return out
	end
	local keys, bosses = listAttr("KeysHeld"), listAttr("BossesBeaten")
	local zones: { CourseSelect.Zone } = {}
	for _, st in portalStates() do
		local tinfo = TrackInfo.get(st.id)
		local zone = tostring(st.zone)
		local lockLine: string? = nil
		if not st.open then
			local lrow = LadderRules.row(zone, tonumber(st.have) or 0, false)
			if type(st.need) == "number" then
				lrow.need = st.need
				lrow.remaining = math.max(0, st.need - lrow.have)
			end
			if zone == "HUB" then
				lockLine = "Beat all four bosses"
			elseif lrow.need == nil then
				lockLine = "Beat the final boss"
			elseif lrow.remaining > 0 then
				lockLine = string.format("%d more Sky Token%s", lrow.remaining, if lrow.remaining == 1 then "" else "s")
			else
				lockLine = tostring(st.why or "Locked")
			end
		end
		local modes: { CourseSelect.Mode } = {}
		for _, md in (st.modes or {}) :: { any } do
			table.insert(modes, { mode = tostring(md.mode), open = md.open == true, why = if md.why then tostring(md.why) else nil })
		end
		table.insert(zones, {
			id = tostring(st.id),
			zone = zone,
			name = if zone == "HUB" then "FINAL BOSS" else (if tinfo then tinfo.zoneName:upper() else zone),
			track = if tinfo then tinfo.trackName else tostring(st.id),
			vehicle = if tinfo and tinfo.vehicle == "car" then "car" else "plane",
			color = if tinfo then tinfo.color else WOOD,
			open = st.open == true,
			lockLine = lockLine,
			modes = modes,
			-- A listed but shut battle says why (V9: the dim button only told on a click).
			battleLine = if st.open then BattleAccessRules.boardLockLine(st.modes) else nil,
			key = keys[zone] == true,
			boss = bosses[zone] == true or bosses[tostring(st.id)] == true,
		})
		if st.open and ARCH_LABELS and zone ~= "HUB" then
			boardQueue[tostring(st.id)] = true :: any
		end
	end
	local lobby = LocalPlayer:GetAttribute("LobbyArch")
	CourseSelect.refresh({
		tokens = n(1, 1, tokens),
		tokensTotal = n(1, 2, 14),
		keys = n(2, 1, 0),
		keysTotal = n(2, 2, 4),
		boss = n(3, 1, 0),
		bossTotal = n(3, 2, 4),
		battle = n(4, 1, 0),
		battleTotal = n(4, 2, 4),
		completeText = if info and info.complete then info.text else nil,
		zones = zones,
		lobby = if type(lobby) == "string" then lobby else nil,
	})
	lastQueueStep = -math.huge
	-- Storm race v2 (client/StormRaceClient): extra rows under the cards.
	local extras = CourseSelect.extras()
	for _, c in extras:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for _, addRow in boardRowHooks do
		local ok, err = pcall(function(): any
			addRow(extras, 2)
			return nil
		end)
		if not ok then
			warn("[SkyRally][TRACKFLOW] board row hook failed: " .. tostring(err))
		end
	end
end

-- Open and not on its way out (a closing board stays Visible through its swoosh).
local function boardShown(): boolean
	local f = boardFrame :: Frame? -- typed Frame but nil until the board is built
	return f ~= nil and f.Visible and not UiMotion.isHiding(f)
end

local BOARD_HOME = UDim2.fromScale(0.5, 0.5)

-- The board's fit (v37 uifix): explicit pixels from its own ScreenGui, centred, as large as the screen allows with a
-- margin (scale sizes plus a UISizeConstraint let a stray parent size or an interrupted swoosh shift it). The aspect
-- stays between 1.6 and 2.2 so cards keep their shape on a short wide window and on a phone.
local function fitBoard()
	local f = boardFrame :: Frame?
	local bg = if f then f.Parent else nil
	if not f or not bg or not bg:IsA("ScreenGui") then
		return
	end
	local vw, vh = bg.AbsoluteSize.X, bg.AbsoluteSize.Y
	if vw <= 0 or vh <= 0 then
		return
	end
	local mx = math.max(12, math.floor(vw * 0.03))
	local my = math.max(8, math.floor(vh * 0.04))
	local w = math.min(vw - 2 * mx, 1600)
	local h = math.min(vh - 2 * my, 900)
	if w / h > 2.2 then
		w = math.floor(h * 2.2)
	elseif w / h < 1.6 and vh >= 500 then
		h = math.floor(w / 1.6)
	end
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
	if not UiMotion.isBusy(f) then
		f.Position = BOARD_HOME
	end
end

-- Open: swoosh up from the bottom with the open cue. Close: swoosh back down (close cue unless silent: a curtain, a
-- mode switch or a JOIN / mode press that already spoke).
function openBoard(on: boolean, silent: boolean?)
	if on and workspace:GetAttribute("TrackSwitching") == true then
		return -- never under the map-switch curtain (it closes the board; opening there left it mid-swoosh)
	end
	if on then
		fitBoard()
		UiMotion.show(boardFrame, "swooshIn", { side = "bottom", home = BOARD_HOME })
	else
		UiMotion.hide(boardFrame, "swooshOut", nil, { side = "bottom", silent = silent == true })
	end
	if on then
		rebuildBoard()
		-- Gamepad: focus the selected zone card.
		CourseSelect.focus()
	elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(boardFrame) then
		GuiService.SelectedObject = nil
	end
end

-- The Garage (client/Garage) closes the board when it opens, and closes itself when the board opens.
function TrackFlow.closeBoard()
	if boardShown() then
		openBoard(false, true) -- the Garage's own open speaks
	end
end

function TrackFlow.isBoardOpen(): boolean
	-- boardFrame is typed Frame but stays nil until the board is built.
	return boardShown()
end

local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local PortalFill = require(script.Parent:WaitForChild("PortalFill")) -- the swirling portal fill (layered discs + inward motes)

local function vfxTex(name: string): string
	local a = (VfxAssets :: any)[name]
	return if a then a.id else ""
end

-- Hub find markers (server-built under the map's HubFinds folder): hidden for this player once held, with a glint.
local function refreshFinds()
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	local folder = root and root:FindFirstChild("HubFinds")
	if not folder then
		return
	end
	local held: { [string]: boolean } = {}
	local raw = LocalPlayer:GetAttribute("HubFindsHeld")
	if type(raw) == "string" then
		local ok, t = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(t) == "table" then
			for _, id in t do
				held[tostring(id)] = true
			end
		end
	end
	for _, m in folder:GetChildren() do
		local got = held[m.Name] == true
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = if got then 1 else 0
			elseif d:IsA("Light") or d:IsA("ParticleEmitter") then
				(d :: any).Enabled = not got
			end
		end
		local coin = m:FindFirstChild("Token")
		if coin and coin:IsA("BasePart") and not coin:FindFirstChild("FindGlint") then
			local pe = Instance.new("ParticleEmitter")
			pe.Name = "FindGlint"
			FlipFx.apply(pe, "sparkle_star_4x4") -- twinkling star loop (flip_v2); old star_twinkle if the id is missing
			pe.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150))
			pe.LightEmission = 0.8
			pe.LightInfluence = 0
			pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.5, 1.8), NumberSequenceKeypoint.new(1, 0) })
			pe.Transparency = NumberSequence.new(0.1)
			pe.Lifetime = NumberRange.new(0.8, 1.2)
			pe.Rate = if got then 0 else 6
			pe.Speed = NumberRange.new(1, 3)
			pe.SpreadAngle = Vector2.new(180, 180)
			pe.Enabled = not got
			pe.Parent = coin
		end
	end
end

-- Swirling portal fill for each arch (client/PortalFill: layered rotating discs, a dark core, a bright rim, motes drifting
-- inward, the zone name in front) plus the old accent motes, kept faint; dim for a locked zone. The flat flipbook vortex
-- is retired (OLD_VORTEX): the discs replace it.
local OLD_VORTEX = false
local function portalSwirl(d: BasePart, info: TrackInfo.Info?, open: boolean)
	-- The zone colour (green, blue, teal, red-orange, purple), not the pale cream accent: PortalFill lifts its saturation.
	PortalFill.apply(d, if info then info.color else CREAM, open, if info then info.zoneName:upper() else "PORTAL")
	local pe = d:FindFirstChild("PortalSwirl") :: ParticleEmitter?
	if not pe then
		local ne = Instance.new("ParticleEmitter")
		ne.Name = "PortalSwirl"
		ne.Texture = vfxTex("glow_soft")
		ne.LightEmission = 1
		ne.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 1.1), NumberSequenceKeypoint.new(1, 0) })
		ne.Lifetime = NumberRange.new(1.2, 2.2)
		ne.Speed = NumberRange.new(0.5, 2)
		ne.RotSpeed = NumberRange.new(-90, 90)
		ne.SpreadAngle = Vector2.new(180, 180)
		ne.Acceleration = Vector3.new(0, 1.5, 0)
		ne.Parent = d
		pe = ne
	end
	local e = pe :: ParticleEmitter
	e.Color = ColorSequence.new(if info then info.accent else CREAM)
	e.Rate = if open then 8 else 3 -- the outward motes only dust the rim now (was 26 / 6)
	e.Transparency = NumberSequence.new(if open then 0.15 else 0.6)
	-- The vortex itself: magic_swirl_8x8 looping at 30 fps, two or three overlapping swirls filling ~2/3 of the arch.
	-- Kept white (the sheet is violet/magenta/cyan and Color multiplies: a zone accent would go muddy); the accent
	-- lives in the motes above. A locked zone's vortex is faint and slow.
	local v = d:FindFirstChild("PortalVortex", true) :: ParticleEmitter?
	if not v and not OLD_VORTEX then
		return
	end
	if not v then
		local at = Instance.new("Attachment") -- a point at the arch centre, so the swirls stay concentric
		at.Name = "PortalVortexAt"
		at.Parent = d
		local nv = Instance.new("ParticleEmitter")
		nv.Name = "PortalVortex"
		FlipFx.apply(nv, "magic_swirl_8x8")
		nv.Color = ColorSequence.new(Color3.new(1, 1, 1))
		nv.LightEmission = 0.6
		nv.LightInfluence = 0
		nv.Lifetime = NumberRange.new(2)
		nv.Speed = NumberRange.new(0)
		nv.Rotation = NumberRange.new(0, 360)
		nv.RotSpeed = NumberRange.new(-25, 25)
		nv.LockedToPart = true
		nv.Parent = at
		v = nv
	end
	local vortex = v :: ParticleEmitter
	local span = math.min(d.Size.X, d.Size.Y) * 0.7
	vortex.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, span * 0.85), NumberSequenceKeypoint.new(1, span) })
	vortex.Rate = if open then 1.3 else 0.6
	vortex.FlipbookFramerate = NumberRange.new(if open then 30 else 15)
	vortex.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, if open then 0.3 else 0.7),
		NumberSequenceKeypoint.new(0.75, if open then 0.35 else 0.75),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Sign planks over the hub's portal arches (client-only parts with a SurfaceGui on both faces): zone name and gate.
local function signFace(sign: BasePart, face: Enum.NormalId, info: TrackInfo.Info?, zone: string): TextLabel
	local sg = Instance.new("SurfaceGui")
	sg.Name = "Face_" .. face.Name
	sg.Face = face
	sg.LightInfluence = 0
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 24
	sg.Parent = sign
	local name = label(sg, "Name", if info then info.zoneName:upper() else zone, UDim2.new(1, -16, 0.4, 0), UDim2.new(0, 8, 0, 4))
	name.TextColor3 = if info then info.accent else CREAM
	local ns = name:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	ns.Color = UiSkin.color("ink")
	ns.Thickness = 3
	ns.Parent = name
	-- Phase 8: a locked arch also says how to open it (one short line under the gate text).
	local hint = label(sg, "Hint", "", UDim2.new(1, -16, 0.2, 0), UDim2.new(0, 8, 0.78, 0), Enum.Font.GothamBold)
	hint.TextColor3 = MUTED_CREAM
	return label(sg, "Gate", "", UDim2.new(1, -16, 0.3, 0), UDim2.new(0, 8, 0.46, 0), Enum.Font.GothamBold)
end

local function archStates(): { [string]: any }
	local raw = workspace:GetAttribute("ArchStates")
	if type(raw) ~= "string" then
		return {}
	end
	local ok, t = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	return if ok and type(t) == "table" then t else {}
end

-- An arch entry's label text (NotifySpec copy) and its state for the skin ("open" / "filling" / "racing").
local function archText(e: any, now: number): (string, string)
	local id, vars = PortalQueueRules.label(e, now)
	local row = NotifySpec.get(id)
	local state = if id == PortalQueueRules.ROW.open then "open" elseif id == PortalQueueRules.ROW.filling then "filling" else "racing"
	return if row then NotifySpec.format(row.copy, vars) else "", state
end

local function ensureArchLabel(d: BasePart, trackId: string?, open: boolean)
	local cur = archLabelByPart[d]
	if not ARCH_BILLBOARD then
		if open and trackId then
			archSignByPart[d] = trackId
		else
			archSignByPart[d] = nil
		end
		lastQueueStep = -math.huge
		return
	end
	if not ARCH_LABELS or not open or not trackId then
		if cur then
			cur.handle.destroy()
			if cur.anchor then
				cur.anchor:Destroy()
			end
			archLabelByPart[d] = nil
		end
		return
	end
	if cur and cur.trackId == trackId then
		return
	end
	if cur then
		cur.handle.destroy()
		if cur.anchor then
			cur.anchor:Destroy()
		end
	end
	-- v28 1.9: a second plank hanging under the name sign (inside the opening, below the lintel), not above the sign
	-- where the crest and keystone clipped it. The chains are drawn in labelPortals.
	-- v29 B1 root cause: the billboard was adorned to the shimmer itself, so it sat in the same plane as the PortalFill
	-- disc's SurfaceGui faces and the swirl layers cut it (depth-tested). It now hangs from a tiny invisible anchor
	-- ARCH_LABEL_STANDOFF studs in front of the shimmer on the side facing the camera (re-aimed at 4 Hz in refreshQueue).
	local anchor = Instance.new("Part")
	anchor.Name = "ArchLabelAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = d.CFrame * CFrame.new(0, 0, -(d.Size.Z * 0.5 + ARCH_LABEL_STANDOFF))
	anchor.Parent = d
	local handle = NotifyKit.archLabel(anchor, "", "portal", d.Size.Y * 0.5 - 1.5)
	archLabelByPart[d] = { handle = handle, trackId = trackId, text = "", state = "", anchor = anchor }
	lastQueueStep = -math.huge -- fill it on the next frame
end

local function labelPortals()
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	if not root then
		return
	end
	local states: { [string]: any } = {}
	for _, st in portalStates() do
		states[tostring(st.zone)] = st
	end
	for _, d in root:GetDescendants() do
		local zone = string.match(d.Name, "^PortalShimmer_(%u+)$")
		if zone and d:IsA("BasePart") then
			local info = TrackInfo.forZone(zone)
			local sign = d:FindFirstChild("PortalSign") :: BasePart?
			if not sign then
				local ns = Instance.new("Part")
				ns.Name = "PortalSign"
				ns.Anchored = true
				ns.CanCollide = false
				ns.CanQuery = false
				ns.CanTouch = false
				ns.CastShadow = false
				ns.Material = Enum.Material.WoodPlanks
				ns.Color = if info then info.color else WOOD
				ns.Size = Vector3.new(d.Size.X + 2, 7.5, 0.6)
				ns.CFrame = d.CFrame * CFrame.new(0, d.Size.Y * 0.5 + 6.5, 0)
				ns.Parent = d
				signFace(ns, Enum.NormalId.Front, info, zone)
				signFace(ns, Enum.NormalId.Back, info, zone)
				sign = ns
				-- Two short chains hang the arch label's plank from the sign's lower edge (non-colliding, client only).
				for _, sx in { -1, 1 } do
					local chain = Instance.new("Part")
					chain.Name = "PortalPlankChain"
					chain.Anchored = true
					chain.CanCollide = false
					chain.CanQuery = false
					chain.CanTouch = false
					chain.CastShadow = false
					chain.Material = Enum.Material.Metal
					chain.Color = WOOD_DARK
					chain.Size = Vector3.new(0.3, 4.0, 0.3)
					chain.CFrame = d.CFrame * CFrame.new(sx * (d.Size.X * 0.2), d.Size.Y * 0.5 + 0.9, 0)
					chain.Parent = ns
				end
			end
			local st = states[zone]
			portalSwirl(d, info, st ~= nil and st.open == true)
			ensureArchLabel(d, if st then tostring(st.id) else nil, st ~= nil and st.open == true)
			local text = if st == nil then ""
				elseif st.open then (if ARCH_LABELS then "" else "DRIVE IN TO RACE") -- the arch label carries the state
				else ("LOCKED: " .. tostring(st.why))
			local hintText = ""
			if st ~= nil and not st.open then
				-- Phase 8: "LOCKED - 1/2 TOKENS" and where tokens come from; the server's numbers (PortalStates have / need).
				local lrow = LadderRules.row(tostring(st.zone), tonumber(st.have) or 0, false)
				if type(st.need) == "number" then
					lrow.need = st.need
					lrow.remaining = math.max(0, st.need - lrow.have)
				end
				text = LadderRules.archText(lrow) or text
				hintText = LadderRules.hintText(lrow) or ""
			end
			for _, sg in (sign :: BasePart):GetChildren() do
				local gate = sg:FindFirstChild("Gate")
				if gate and gate:IsA("TextLabel") then
					gate.Text = text
					gate.TextColor3 = if st and st.open then Color3.fromRGB(255, 244, 170) else CREAM
				end
				local hint = sg:FindFirstChild("Hint")
				if hint and hint:IsA("TextLabel") then
					hint.Text = hintText
				end
			end
		end
	end
end

local coinLabel: TextLabel? = nil

-- Hidden key markers (server KeyPickup, map root folder HiddenKey): hidden for this player once its zone key is held.
local function refreshKeys()
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	local folder = root and root:FindFirstChild("HiddenKey")
	if not folder then
		return
	end
	local held: { [string]: boolean } = {}
	local raw = LocalPlayer:GetAttribute("KeysHeld")
	if type(raw) == "string" then
		local ok, t = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(t) == "table" then
			for _, zone in t do
				held[tostring(zone)] = true
			end
		end
	end
	for _, m in folder:GetChildren() do
		local got = held[tostring(m:GetAttribute("KeyZone"))] == true
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = if got then 1 else 0
			elseif d:IsA("Light") or d:IsA("ParticleEmitter") then
				(d :: any).Enabled = not got
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Battle HUD and results
------------------------------------------------------------------------------------------------------------------------

local battleHud: Frame
local battleTitle: TextLabel
local battleObjective: TextLabel
local battleBoard: Frame
local resultsFrame: Frame
local resultsTitle: TextLabel
local resultsReason: TextLabel
local resultsAward: TextLabel
local resultsList: Frame
local resultsAgain: GuiButton
local lastBoardRaw = ""

local TONE_COLOR: { [string]: Color3 } = {
	good = Color3.fromRGB(170, 255, 140),
	bad = Color3.fromRGB(255, 170, 150),
	warn = TONE_COLOR_WARN,
	info = CREAM,
}

local function isBattle(): boolean
	return RaceAttr.mine("RaceMode") == "battle"
end

local boardRowH = 20 -- px, set by applyLayout from the battle board rect
local boardW = 176 -- px, the board's width (the panel's padding included)
local boardMaxH = 8 * 22 -- px, the most the layout lets the board take
local BOARD_PAD = 5 -- px of panel padding on each side
local boardRows: { { row: Frame, name: TextLabel, score: TextLabel, mine: boolean, nameText: string } } = {}

-- One row = name column + score column. The score column is exactly as wide as its text and the name column takes the rest.
-- The whole board shares one text size: the largest (up to the base size) at which every row's full name and score fit,
-- never under the 12 px floor, so no row is cut while a smaller size would have shown it and the rows stay in one size.
-- Only when even the floor does not fit does a name truncate, and the player's own row never does while the floor fits
-- (it is the first the board shrinks for).
local function textW(txt: string, px: number): number
	return TextService:GetTextSize(txt, px, Enum.Font.GothamBold, Vector2.new(10000, 100)).X
end

local function sizeBoardRows()
	-- Touch rows are small and take the whole row; desktop text is 70 percent of the row, capped at 18 px.
	local base = math.max(HudLayoutRules.MIN_TEXT, if HudMetrics.kind() == "touch" then boardRowH - 2 else math.min(18, math.floor(boardRowH * 0.7)))
	local inner = boardW - 2 * BOARD_PAD
	local textPx = base
	while textPx > HudLayoutRules.MIN_TEXT do
		local fits = true
		for _, r in boardRows do
			if textW(r.nameText, textPx) + textW(r.score.Text, textPx) + 10 > inner then
				fits = false
				break
			end
		end
		if fits then
			break
		end
		textPx -= 1
	end
	for _, r in boardRows do
		local scoreW = textW(r.score.Text, textPx) + 4
		r.row.Size = UDim2.new(1, 0, 0, boardRowH)
		r.name.Size = UDim2.new(0, math.max(20, inner - scoreW - 6), 1, 0)
		r.name.TextSize = textPx
		r.score.Size = UDim2.new(0, scoreW, 1, 0)
		r.score.TextSize = textPx
	end
	-- The panel hugs its rows (never taller than the layout's rect).
	local h = #boardRows * (boardRowH + 2) + 2 * BOARD_PAD
	battleBoard.Size = UDim2.fromOffset(boardW, math.min(boardMaxH, math.max(2 * BOARD_PAD + boardRowH, h)))
end

local function refreshBattleBoard()
	local raw = RaceAttr.mine("BattleBoard")
	local text = if type(raw) == "string" then raw else ""
	if text == lastBoardRaw then
		return
	end
	lastBoardRaw = text
	for _, c in battleBoard:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	table.clear(boardRows)
	local ok, rows = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if not ok or type(rows) ~= "table" then
		sizeBoardRows()
		return
	end
	for i, row in rows :: { any } do
		if i > 8 then
			break
		end
		local you = row.u == LocalPlayer.UserId
		local color = if row.o then Color3.fromRGB(150, 140, 130) elseif you then Color3.fromRGB(255, 236, 140) else CREAM
		local rf = Instance.new("Frame")
		rf.Name = "Row" .. i
		rf.BackgroundTransparency = 1
		rf.LayoutOrder = i
		rf.Size = UDim2.new(1, 0, 0, boardRowH)
		rf.Parent = battleBoard
		local function cell(name: string, txt: string, right: boolean): TextLabel
			local l = label(rf, name, txt, UDim2.new(0, 60, 1, 0), if right then UDim2.new(1, 0, 0, 0) else UDim2.fromOffset(0, 0), Enum.Font.GothamBold)
			l.AnchorPoint = if right then Vector2.new(1, 0) else Vector2.zero
			l.TextScaled = false -- scaled rows overflowed the board and drew at three different sizes
			l.TextWrapped = false
			l.TextTruncate = Enum.TextTruncate.AtEnd -- last resort only: sizeBoardRows shrinks the whole board's text to the 12 px floor first
			l.TextXAlignment = if right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
			l.TextColor3 = color
			local lim = l:FindFirstChildOfClass("UITextSizeConstraint")
			if lim then
				lim:Destroy()
			end
			local st = l:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
			st.Color = UiSkin.color("ink")
			st.Thickness = 1.5
			st.Parent = l
			return l
		end
		local nameText = tostring(row.n)
		local nm = cell("Name", nameText, false)
		local sc = cell("Score", tostring(row.s), true)
		table.insert(boardRows, { row = rf, name = nm, score = sc, mine = you, nameText = nameText })
	end
	sizeBoardRows()
end

-- v21 (hud critic 1): world labels of a battle ("X'S NEST", "EGG") are billboards; one whose screen rect touches the plaque, the
-- caption lane, the board or a HUD chip is switched off (it came out clipped behind the banner).
-- v22 (phone polish, shared/WorldLabelRules): a nest label shrinks with distance (min / max size), shows a colour dot and a
-- shortened name ("ALICE'S NEST" near, "ALICE" far), and hides while geometry blocks the camera's view of its anchor (one
-- ray per label every WorldLabelRules.OCCLUSION_INTERVAL s, debounced, not every frame). Racer name labels (RacerView, tag
-- "RacerNameLabel") get the same HUD overlap check; they are hidden through a HudHidden attribute RacerView reads.
local labelClock = 0
local labelOcc: { [Instance]: { count: number, hide: boolean, nextAt: number } } = setmetatable({}, { __mode = "k" }) :: any
local function labelGeometryHidden(g: BillboardGui, camPos: Vector3, anchor: Vector3, now: number): boolean
	local st = labelOcc[g]
	if not st then
		st = { count = 0, hide = false, nextAt = now + math.random() * WorldLabelRules.OCCLUSION_INTERVAL }
		labelOcc[g] = st
	end
	if now >= st.nextAt then
		st.nextAt = now + WorldLabelRules.OCCLUSION_INTERVAL
		local ignore: { Instance } = {}
		local char = LocalPlayer.Character
		if char then
			table.insert(ignore, char)
		end
		local subject = workspace.CurrentCamera and workspace.CurrentCamera.CameraSubject
		local vehicle = if subject then subject:FindFirstAncestorOfClass("Model") else nil
		if vehicle then
			table.insert(ignore, vehicle)
		end
		local own = g:FindFirstAncestorOfClass("Model")
		if own then
			table.insert(ignore, own)
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		params.RespectCanCollide = true
		local dir = anchor - camPos
		local hit = workspace:Raycast(camPos, dir, params)
		local hitDist = if hit then (hit.Position - camPos).Magnitude else nil
		st.count, st.hide = WorldLabelRules.occlusionStep(st.count, WorldLabelRules.blocked(hitDist, dir.Magnitude))
	end
	return st.hide
end

local function ensureLabelIcon(text: TextLabel)
	if text:FindFirstChild("NestDot") then
		return
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.16, 0)
	pad.Parent = text
	local dot = Instance.new("Frame")
	dot.Name = "NestDot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(-0.08, 0.5) -- inside the padding strip (text origin is shifted by the padding)
	dot.Size = UDim2.fromScale(0.5, 0.5)
	dot.SizeConstraint = Enum.SizeConstraint.RelativeYY
	dot.BackgroundColor3 = text.TextColor3
	dot.BorderSizePixel = 0
	dot.Parent = text
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = dot
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(40, 28, 18)
	st.Thickness = 1.5
	st.Parent = dot
end

local function avoidWorldLabels()
	if os.clock() < labelClock then
		return
	end
	local now = os.clock()
	labelClock = now + 0.15
	local tagged = CollectionService:GetTagged("BattleWorldLabel")
	local racerTags = CollectionService:GetTagged("RacerNameLabel")
	if #tagged == 0 and #racerTags == 0 then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local snap = HudMetrics.get()
	local rects = snap.rects
	local keep: { any } = {}
	for _, k in { "battleHud", "laneB", "noticeStack", "battleBoard", "position", "lapChip", "item", "token", "nav", "gear", "help", "respawn", "minimap" } do
		local r = (rects :: any)[k]
		if r then
			table.insert(keep, r)
		end
	end
	local camPos = cam.CFrame.Position
	for _, g in tagged do
		if g:IsA("BillboardGui") then
			local adornee = g.Adornee or (g.Parent :: any)
			local anchor = if adornee and adornee:IsA("BasePart") then adornee.Position + g.StudsOffset else nil
			local hide = false
			local w, h = g.Size.X.Offset, g.Size.Y.Offset
			if anchor then
				local dist = (anchor - camPos).Magnitude
				local scale = WorldLabelRules.scale(dist, snap.metrics.S)
				w, h = WorldLabelRules.size(scale)
				if g.Size.X.Offset ~= w then
					g.Size = UDim2.fromOffset(w, h)
				end
				local text = g:FindFirstChildWhichIsA("TextLabel")
				if text then
					local full = g:GetAttribute("FullCaption")
					local shown = g:GetAttribute("ShownCaption")
					-- The server writes the full caption (and "+n" deposit bursts); only a full or our own shortened one is rewritten.
					if WorldLabelRules.ownerName(text.Text) then
						g:SetAttribute("FullCaption", text.Text)
						full = text.Text
					end
					if type(full) == "string" and (text.Text == full or text.Text == shown) then
						local want = WorldLabelRules.shortText(full, dist)
						if text.Text ~= want then
							text.Text = want
							g:SetAttribute("ShownCaption", want)
						end
						ensureLabelIcon(text)
					end
				end
				local v, onScreen = cam:WorldToViewportPoint(anchor)
				if onScreen and v.Z > 0 then
					hide = WorldLabelRules.overlapsAny(v.X, v.Y, w, h, keep) or labelGeometryHidden(g, camPos, anchor, now)
				end
			end
			if g.Enabled == hide then
				g.Enabled = not hide
			end
		end
	end
	-- Racer name labels: RacerView sizes and fades them; the HUD-overlap result only gates them.
	for _, g in racerTags do
		if g:IsA("BillboardGui") then
			local adornee = g.Adornee
			local text = g:FindFirstChildWhichIsA("TextLabel")
			if adornee and adornee:IsA("BasePart") and text then
				local anchor = adornee.Position + g.StudsOffsetWorldSpace
				local v, onScreen = cam:WorldToViewportPoint(anchor)
				local hide = onScreen and v.Z > 0 and WorldLabelRules.overlapsAny(v.X, v.Y, math.max(60, text.AbsoluteSize.X), math.max(20, text.AbsoluteSize.Y), keep)
				if g:GetAttribute("HudHidden") ~= hide then
					g:SetAttribute("HudHidden", hide)
				end
			end
		end
	end
end

local function refreshBattleHud()
	local on = isBattle() and RaceAttr.mine("BattleKind") ~= nil
	battleHud.Visible = on
	battleBoard.Visible = on
	if not on then
		return
	end
	local hud = LocalPlayer:GetAttribute("BattleHud")
	battleObjective.Text = if type(hud) == "string" then hud else ""
	refreshBattleBoard()
end

local function showResults(data: any)
	if type(data) ~= "table" then
		return
	end
	for _, c in resultsList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local title = tostring(data.title or "BATTLE")
	resultsTitle.Text = if data.spectator then title .. " - RESULTS"
		elseif data.youWon then "VICTORY!"
		elseif data.winnerName then string.format("%s WINS", string.upper(tostring(data.winnerName)))
		else "NO WINNER"
	resultsTitle.TextColor3 = if data.youWon then UiSkin.color("gold") else Color3.new(1, 1, 1)
	resultsReason.Text = string.format("%s  -  %s", title, tostring(data.reason or ""))
	for i, row in (if type(data.rows) == "table" then data.rows else {}) :: { any } do
		if i > 8 then
			break
		end
		local you = row.userId == LocalPlayer.UserId
		-- UI v2: one chip row per racer (the gold key for you), the medal for places 1-3.
		local rank = tonumber(row.rank) or i
		-- Rows share the list's height (a phone card is short): 16-26 px each.
		local nRows = math.min(8, #((data.rows :: any) or {}))
		local rowH = math.clamp(math.floor((resultsList.AbsoluteSize.Y - 3 * (nRows - 1)) / math.max(1, nRows)), 16, 26)
		local rf = UiSkin.panel(resultsList, "chip", { name = "Row" .. i, variant = if you then "header" else "inset", size = UDim2.new(1, -8, 0, rowH), layoutOrder = i, zIndex = 33, S = 1 })
		if rank <= 3 then
			UiSkin.icon(rf, "icon_medal_" .. rank, tostring(rank), { size = UDim2.fromOffset(rowH - 4, rowH - 4), position = UDim2.new(0, 6, 0.5, 0), anchor = Vector2.new(0, 0.5), zIndex = 35 })
		end
		local l = label(rf, "Text", string.format("%d.  %s  -  %s", rank, tostring(row.name), tostring(row.text or "")), UDim2.new(1, -40, 1, -6), UDim2.new(0, 34, 0, 3), Enum.Font.GothamBold)
		l.ZIndex = 35
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextColor3 = if you then UiSkin.color("ink") else Color3.new(1, 1, 1)
		local ls = l:FindFirstChildOfClass("UIStroke")
		if ls then
			ls.Enabled = not you
		end
	end
	-- The award line says what the SERVER saved (BattleCore -> SaveService), never a client guess.
	local award = if type(data.award) == "table" then data.award else {}
	local result = award.result
	local line = ""
	if result == "awarded" then
		line = string.format("+1 BATTLE FRAGMENT  (%s/%s)", tostring(award.fragments or "?"), tostring(award.total or 4))
		if award.amulet then
			line ..= "  -  BATTLE AMULET COMPLETE! Exclusive tint unlocked"
		end
	elseif result == "noop" then
		line = "Battle fragment already earned"
	elseif result == "queued" then
		line = "Battle fragment saving..."
	elseif result == "rejected" then
		line = "Battle fragment NOT saved"
	elseif not data.youWon and not data.spectator then
		line = "Win to earn the battle fragment"
	end
	resultsAward.Text = line
	LadderNotices.battleAward(award)
	resultsAward.TextColor3 = if award.amulet then UiSkin.color("gold") else Color3.fromRGB(150, 240, 160)
	-- Pop in with its cue the first time; a later update (votes, award) leaves the card where it is.
	if not resultsFrame.Visible or UiMotion.isHiding(resultsFrame) then
		UiMotion.show(resultsFrame, "popIn")
	end
	if GuiService:IsTenFootInterface() or game:GetService("UserInputService").GamepadEnabled then
		GuiService.SelectedObject = resultsAgain
	end
end

local function hideResults()
	if resultsFrame and resultsFrame.Visible and not UiMotion.isHiding(resultsFrame) then
		-- Silent pop out: the HUB / AGAIN press already spoke, and a reset or a curtain needs no extra cue.
		UiMotion.hide(resultsFrame, "popOut", nil, { silent = true })
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(resultsFrame) then
			GuiService.SelectedObject = nil
		end
	end
end

-- Coin challenge: counter plank and this player's taken coins hidden, and a pentatonic note for each coin taken (the
-- last one adds the finale).
local lastCoins: number? = nil
local function refreshCoins()
	local total = RaceAttr.mine("CoinsTotal")
	local lbl = coinLabel
	local coinCount = (LocalPlayer:GetAttribute("Coins") :: number?) or 0
	if lbl then
		lbl.Visible = type(total) == "number"
		lbl.Text = string.format("COINS %d/%d", coinCount, if type(total) == "number" then total else 0)
	end
	local step, finale = SfxRules.coinStep(lastCoins, coinCount, if type(total) == "number" then total else nil)
	lastCoins = coinCount
	if step then
		Sfx.play("coin_pickup", SfxRules.coinPitch(step), 0.5)
		if finale then
			task.delay(0.25, Sfx.play, "coin_all", 1, 0.56)
		end
	end
	local maps = workspace:FindFirstChild("Maps")
	local root = maps and maps:FindFirstChild(tostring(RaceAttr.mine("ActiveTrackId")))
	local folder = root and root:FindFirstChild("ChallengeCoins")
	if not folder then
		return
	end
	local held: { [string]: boolean } = {}
	local raw = LocalPlayer:GetAttribute("CoinsHeld")
	if type(raw) == "string" then
		local ok, t = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(t) == "table" then
			for _, id in t do
				held[tostring(id)] = true
			end
		end
	end
	for _, m in folder:GetChildren() do
		local got = held[m.Name] == true
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = if got then 1 else 0
			elseif d:IsA("Light") then
				d.Enabled = not got
			end
		end
	end
end

local function boardAction(_name: string, state: Enum.UserInputState, _obj: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		local open = boardShown()
		UiSound.play(if open then "back" else "tab") -- the key path speaks like the ADVENTURE / CLOSE buttons
		openBoard(not open)
	end
	return Enum.ContextActionResult.Sink
end

local hintToken = 0
local function applyMode()
	local hub = RaceAttr.mine("RaceMode") == "hub"
	-- v28 W1.26: the "Drive through a portal arch ..." hint under ADVENTURE folds away 5 s after the bar appears (it sat over the portal arches).
	local hubHint = hubBar:FindFirstChild("Hint") :: GuiObject?
	if hub and not hubBar.Visible then
		hintToken += 1
		local my = hintToken
		if hubHint then
			hubHint.Visible = true
		end
		task.delay(5, function()
			if hintToken == my and hubHint and hubHint.Parent then
				hubHint.Visible = false
			end
		end)
	end
	hubBar.Visible = hub
	if placeLaneA then
		placeLaneA() -- the lobby banner / countdown stop short of the bar in the hub
	end
	-- Console and keyboard: Y / B toggles (Tab belongs to the core player list) the Adventure board in the hub (D20).
	local CAS = game:GetService("ContextActionService")
	if hub then
		CAS:BindAction("SkyRallyAdventureBoard", boardAction, false, Enum.KeyCode.ButtonY, Enum.KeyCode.B)
	else
		CAS:UnbindAction("SkyRallyAdventureBoard")
	end
	-- Battles have no position, laps or race timer: the battle plank replaces those.
	setRaceHudVisible(not hub and not isBattle())
	refreshBattleHud()
	if not isBattle() then
		hideResults()
	end
	for _, t in { 1, 4, 10 } do
		task.delay(t, refreshKeys)
	end
	if not hub then
		openBoard(false, true)
	else
		-- The hub map replicates after the mode flips; label again as it streams in.
		for _, t in { 1, 4, 10, 20 } do
			task.delay(t, labelPortals)
			task.delay(t, refreshFinds)
		end
	end
end

-- Storm Cup (server/StormCup): modifier names for the curtain and the hub line.
local function stormModifierText(modifier: any): string
	return GarageModel.STORM_MODIFIER_LABEL[tostring(modifier)] or "STORM"
end

-- Hub line under ADVENTURE, two short lines so it stays readable on a 240 px phone bar: when the next Storm Cup starts
-- (workspace.StormCupAt, UTC = server time; plus the Festival's double Gears once the Garage is on), then its map and
-- modifier. The label is only touched when the text changes (once a second).
local function stormLine(now: number): string
	if workspace:GetAttribute("StormRaceV2") == true then
		-- Storm race v2 (server/StormRace): the next storm race, its JOIN window, or the race in progress.
		if RaceAttr.mine("RaceMode") ~= "hub" or workspace:GetAttribute("StormRaceEnabled") ~= true then
			return ""
		end
		local st = workspace:GetAttribute("StormRaceState")
		local at = workspace:GetAttribute("StormRaceAt")
		local closeAt = workspace:GetAttribute("StormRaceCloseAt")
		local info = TrackInfo.get(workspace:GetAttribute("StormRaceTrack") :: string?)
		local head = if st == "open" and type(at) == "number" then "STORM RACE IN " .. GarageModel.formatCountdown(at - now) .. "  -  JOIN"
			elseif st == "late" and type(closeAt) == "number" then "STORM RACE ON  -  JOIN " .. GarageModel.formatCountdown(closeAt - now)
			elseif workspace:GetAttribute("StormRaceLive") == true then "STORM RACE IN PROGRESS"
			elseif type(at) == "number" then "STORM RACE IN " .. GarageModel.formatCountdown(at - now)
			else ""
		if head == "" then
			return ""
		end
		return head .. "\n" .. (if info then info.trackName else "") .. "  -  vs the storm dragon"
	end
	if RaceAttr.mine("RaceMode") ~= "hub" or workspace:GetAttribute("StormCupEnabled") ~= true then
		return ""
	end
	local at = workspace:GetAttribute("StormCupAt")
	local info = TrackInfo.get(workspace:GetAttribute("StormCupTrack") :: string?)
	local where = string.format("%s - %s", if info then info.trackName else "?", stormModifierText(workspace:GetAttribute("StormCupModifier")))
	local head = if workspace:GetAttribute("StormCupState") == "due" or (type(at) == "number" and at <= now) then "STORM CUP STARTING"
		elseif type(at) == "number" then "STORM CUP IN " .. GarageModel.formatCountdown(at - now)
		else ""
	if head == "" then
		return ""
	end
	if workspace:GetAttribute("FestivalActive") == true and workspace:GetAttribute("GarageEnabled") == true then
		head ..= string.format("  |  x%s CASH", tostring(workspace:GetAttribute("FestivalMultiplier") or 2))
	end
	return head .. "\n" .. where
end

-- Economy v3 phase 2b: a group's own map load shows the same curtain, named from its instance root (the Next*
-- attributes); the workspace ones (the whole server switching) on the single-race path. Per group the curtain is
-- level-driven by shared/GroupCurtainRules (stepGroupCurtain below): up while the player's own seat is loading, lifted
-- once his map is in and his grid formed, on his return to the hub, and after its timeout. Never for a hub bystander.
local groupCurtain = GroupCurtainRules.new()
local function groupCurtainUp(): boolean
	return RaceFlowRules.PER_GROUP and GroupCurtainRules.up(groupCurtain)
end
local function switching(): boolean
	return workspace:GetAttribute("TrackSwitching") == true or groupCurtainUp()
end
local function curtainAttr(name: string): any
	local root = if groupCurtainUp() then RaceAttr.rootOf(LocalPlayer) else nil
	return if root then root:GetAttribute(name) else workspace:GetAttribute(name)
end

local function showCurtain(on: boolean)
	if on then
		local info = TrackInfo.get(curtainAttr("NextTrackId") :: string?)
		curtain.BackgroundColor3 = CURTAIN_NAVY
		curtainZoneColor = if info then info.color else WOOD_DARK
		curtainZone.Text = if info then info.zoneName:upper() else "LOADING"
		curtainTrack.Text = if info then info.trackName else ""
		local mode = curtainAttr("NextMode")
		local BossConfig = require(Shared:WaitForChild("BossConfig")) :: any
		local boss = BossConfig.forZone(info and info.zone)
		local vehicle = if info and info.vehicle == "car" then "Car" else "Plane"
		curtainHint.Text = string.upper(if mode == "hub" then "Back to Central Island"
			elseif mode == "boss" and boss then string.format("BOSS RACE vs %s, %s", boss.name, boss.title)
			elseif mode == "rematch" and boss then string.format("BOSS REMATCH vs %s - harder hazards", boss.name)
			elseif mode == "coin" then "COIN CHALLENGE - take all 8 silver coins AND win"
			elseif mode == "timetrial" then "TIME TRIAL - 3 laps against the clock"
			elseif mode == "quickrace" then "QUICK RACE  -  3 laps vs 7 rivals, just for fun"
			elseif mode == "stormrace" then "STORM RACE  -  3 laps vs the storm dragon"
			elseif mode == "stormcup" then string.format("STORM CUP  -  %s  -  3 laps vs 7 rivals", stormModifierText(workspace:GetAttribute("RaceModifier")))
			elseif mode == "battle" then (BATTLE_HINT[tostring(curtainAttr("NextBattleKind"))] or "BATTLE - 3 minutes")
			else vehicle .. " race  -  3 laps vs 7 rivals")
		-- v38-flow: the curtain is a wipe, not a cross-fade: it sweeps in from the left over 0.45 s (fading up as it
		-- comes), so select -> curtain reads as one move, like a console racer's loading wipe.
		local wasUp = curtain.Visible and curtain.BackgroundTransparency < 0.5
		curtain.Visible = true
		if not wasUp then
			curtain.Position = UDim2.fromScale(-1, 0)
			curtain.BackgroundTransparency = 0.35
			TweenService:Create(curtain, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0, 0), BackgroundTransparency = 0 }):Play()
		end
		openBoard(false, true)
		-- REMARKABLE 8: the kart appears after the 0.5 s fade (CurtainKart waits for it; no outline = no kart).
		CurtainKart.start(curtain, curtainAttr("NextTrackId"), if info then info.color else nil)
	else
		-- REMARKABLE 8: kart input stops now; a counted lap becomes the record toast as the curtain lifts.
		local _, kartToast = CurtainKart.stop()
		if kartToast then
			TrackFlow.toast(kartToast, Color3.fromRGB(255, 226, 130), 4)
		end
		local tw = TweenService:Create(curtain, TweenInfo.new(0.7), { BackgroundTransparency = 1 })
		tw.Completed:Connect(function()
			if not switching() then
				curtain.Visible = false
			end
		end)
		-- REMARKABLE 20: the curtain lifts as the destination's emblem iris opening (the fade is the fallback).
		local arriving = TrackInfo.get(RaceAttr.mine("ActiveTrackId") :: string?) or TrackInfo.get(workspace:GetAttribute("NextTrackId") :: string?)
		local irisOn = PortalPlunge.irisReveal(curtainZoneColor, if arriving then arriving.zone else nil, 0.6, function()
			curtain.BackgroundTransparency = 1
			curtain.Visible = false
		end)
		task.delay(0.6, function()
			if not irisOn then
				tw:Play()
			end
		end)
	end
	for _, c in curtain:GetChildren() do
		if c:IsA("TextLabel") then
			c.Visible = on
		end
	end
end

-- Per group (GroupCurtainRules): this client's seat, its instance root and its race map, read live.
local function groupCurtainInput(): GroupCurtainRules.Input
	local seat = LocalPlayer:GetAttribute(RaceAttr.PLAYER_ATTRIBUTE)
	local root = RaceAttr.rootOf(LocalPlayer)
	local map = if root then RaceAttr.myMapRoot() else nil
	return {
		perGroup = RaceFlowRules.PER_GROUP,
		seat = if type(seat) == "number" then seat elseif seat ~= nil then tonumber(seat) or -1 else nil,
		rootPresent = root ~= nil,
		rootLoading = root ~= nil and root:GetAttribute("Loading") == true,
		mapReady = map ~= nil and map:GetAttribute("TrackReady") ~= false,
		now = os.clock(),
	}
end

-- Hides the curtain outright (the lift's iris or fade did not, e.g. a reveal that lost its token).
local function forceCurtainOff()
	if switching() or not curtain or not curtain.Visible then
		return
	end
	curtain.BackgroundTransparency = 1
	curtain.Visible = false
	for _, c in curtain:GetChildren() do
		if c:IsA("TextLabel") then
			c.Visible = false
		end
	end
end

local groupLiftAt = -math.huge
local function stepGroupCurtain()
	local action = GroupCurtainRules.step(groupCurtain, groupCurtainInput())
	if action == "show" then
		showCurtain(true)
	elseif action == "lift" or action == "timeout" then
		if action == "timeout" then
			UiSound.play("back")
			TrackFlow.toast("The race took too long to load - back to Central Island", Color3.fromRGB(255, 214, 160), 3.2)
		end
		groupLiftAt = os.clock()
		showCurtain(false)
		task.delay(GroupCurtainRules.LIFT_GUARD, forceCurtainOff)
	elseif groupCurtainUp() and curtainZone.Text == "LOADING" then
		-- The seat replicated before its root: name the track once the root's Next* attributes are in.
		local info = TrackInfo.get(curtainAttr("NextTrackId") :: string?)
		if info then
			curtainZoneColor = info.color
			curtainZone.Text = info.zoneName:upper()
			curtainTrack.Text = info.trackName
		end
	elseif not groupCurtainUp() and curtain.Visible and not curtainZone.Visible
		and os.clock() - groupLiftAt > GroupCurtainRules.LIFT_GUARD then
		-- Lifted (labels already off) yet still drawn after the guard: never leave a bare curtain on screen.
		forceCurtainOff()
	end
end

-- v37 client-ready handshake (shared/MapReadyRules): when a map root gets a new MapReadyToken, answer "MapReady" once
-- this client holds the map (descendant count) and has rendered a run of smooth frames after it. The race's countdown
-- (server/MapReadyGate) waits for that answer, so it never runs while this client is frozen taking the map in.
local readyAnswered: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local function answerMapReady(root: Instance)
	local token = root:GetAttribute(MapReadyRules.TOKEN_ATTR)
	if type(token) ~= "number" or readyAnswered[root] == token then
		return
	end
	readyAnswered[root] = token
	task.spawn(function()
		local t0 = os.clock()
		local function current(): boolean
			return root.Parent ~= nil and root:GetAttribute(MapReadyRules.TOKEN_ATTR) == token and os.clock() - t0 < MapReadyRules.CLIENT_GIVEUP
		end
		while current() and not MapReadyRules.countReady(#root:GetDescendants(), root:GetAttribute(MapReadyRules.COUNT_ATTR)) do
			task.wait(0.25)
		end
		local run = 0
		while current() and run < MapReadyRules.SMOOTH_FRAMES do
			run = MapReadyRules.smoothStep(run, RunService.RenderStepped:Wait())
		end
		if root:GetAttribute(MapReadyRules.TOKEN_ATTR) == token then
			fire("MapReady", token)
		end
	end)
end
local function watchMapReady()
	local function watch(root: Instance)
		root:GetAttributeChangedSignal(MapReadyRules.TOKEN_ATTR):Connect(function()
			answerMapReady(root)
		end)
		answerMapReady(root)
	end
	task.spawn(function()
		local maps = workspace:WaitForChild("Maps", math.huge)
		maps.ChildAdded:Connect(watch)
		for _, c in maps:GetChildren() do
			watch(c)
		end
	end)
end

-- The "Back to Central Island in N" line: with the results card up it sits just under the card (ResultsLayoutRules), clear
-- of FLY AGAIN / HUB at every viewport; otherwise (card closed, DNF-free hub trips) it keeps its lower-screen spot.
local function placeReturnLabel()
	local ins = SafeArea.get()
	local hud = (LocalPlayer :: any).PlayerGui:FindFirstChild("SkyRallyHUD")
	local card = hud and hud:FindFirstChild("FinishPositionScreen")
	local cam = workspace.CurrentCamera
	if card and card:IsA("GuiObject") and card.Visible and cam then
		local vp = cam.ViewportSize
		local col = HudMetrics.get().rects.leftColumn
		local cw, top, h, cx = ResultsLayoutRules.cardRect(vp.X, vp.Y, ins, if col then col.x + col.w else nil)
		-- Centred under the card (which sits right of centre when the left cluster is in the way).
		local pw = math.min(cw, 360) -- a pill, not a bar as wide as the card
		returnLabel.Size = UDim2.fromOffset(math.floor(pw), ResultsLayoutRules.COUNTDOWN_H)
		returnLabel.Position = UDim2.fromOffset(math.floor(cx - pw / 2), ResultsLayoutRules.countdownTop(vp.Y, top, h, ins))
	else
		returnLabel.Size = UDim2.new(0.4, 0, 0.05, 0)
		returnLabel.Position = UDim2.new(0.3, 0, 0.8, -ins.bottom)
	end
end

-- Phase 3, 4 Hz: arch labels and glow, the board's queue lines and buttons, and this player's wait line with LEAVE.
local LEAVE_ACTION = {
	label = "LEAVE",
	onActivated = function()
		fire("LeaveLobby")
	end,
}
local function refreshQueue(now: number)
	if now - lastQueueStep < 0.25 then
		return
	end
	lastQueueStep = now
	local states = archStates()
	for d, trackId in archSignByPart do
		local sign = if d.Parent then d:FindFirstChild("PortalSign") else nil
		if not sign then
			archSignByPart[d] = nil
		else
			local text, state = archText(states[trackId], now)
			if state == "open" then
				text = "" -- idle: the sign needs no second line
			end
			for _, sg in sign:GetChildren() do
				local gate = sg:FindFirstChild("Gate")
				if gate and gate:IsA("TextLabel") and gate.Text ~= text then
					gate.Text = text
				end
			end
		end
	end
	for d, a in archLabelByPart do
		if not d.Parent then
			a.handle.destroy()
			archLabelByPart[d] = nil
		else
			local anchor = a.anchor
			local cam = workspace.CurrentCamera
			if anchor and anchor.Parent and cam then
				local rel = d.CFrame:PointToObjectSpace(cam.CFrame.Position)
				local side = if rel.Z >= 0 then 1 else -1 -- the face the camera is on
				anchor.CFrame = d.CFrame * CFrame.new(0, 0, side * (d.Size.Z * 0.5 + ARCH_LABEL_STANDOFF))
			end
			local text, state = archText(states[a.trackId], now)
			if text ~= a.text then
				a.text = text
				a.handle.setText(text)
			end
			if state ~= a.state then
				a.state = state
				a.handle.setState(state)
			end
		end
	end
	local mine = LocalPlayer:GetAttribute("LobbyArch")
	if boardFrame and boardFrame.Visible then
		local texts: { [string]: string } = {}
		for trackId in boardQueue do
			texts[trackId] = (archText(states[trackId], now))
		end
		CourseSelect.updateQueue(texts, if type(mine) == "string" then mine else nil)
	end
	local line = ""
	local id: string?, vars: { [string]: any } = nil, {}
	if type(mine) == "string" and RaceAttr.mine("RaceMode") == "hub" then
		id, vars = PortalQueueRules.waitLine(states[mine], now)
		local row = if id then NotifySpec.get(id) else nil
		if row then
			line = (if row.title then NotifySpec.format(row.title, vars) .. " " else "") .. NotifySpec.format(row.copy, vars)
		end
	end
	if line ~= lastWaitText then
		lastWaitText = line
		if line == "" or not id then
			NotifyKit.clearBanner("portal_wait")
		else
			NotifyKit.fromSpec(id, vars, { key = "portal_wait", action = LEAVE_ACTION })
		end
	end
end

-- Items v4: the race's item rotation, said once per race while the countdown holds ("This race: Rocket, Orbit, ...").
local poolAnnouncedFor: any = nil
local function announcePool(go: any, now: number)
	if type(go) ~= "number" or go - now <= 0 or RaceAttr.mine("RaceMode") == "hub" then
		return
	end
	local seq = RaceAttr.mine("RaceResetSeq")
	if seq == nil or seq == poolAnnouncedFor then
		return
	end
	local text = RaceAttr.mine(ItemRules.ROTATION.poolAttribute)
	if type(text) ~= "string" or text == "" then
		return
	end
	poolAnnouncedFor = seq
	local line = ItemRules.poolLine(ItemRules.parsePool(text))
	if line ~= "" then
		NotifyKit.fromSpec("item_pool", { items = line })
	end
end

local function step()
	local now = workspace:GetServerTimeNow()
	refreshQueue(now)
	-- countdown
	local go = RaceAttr.mine("RaceGoTime")
	announcePool(go, now)
	local text = ""
	if type(go) == "number" then
		local left = go - now
		if left > 0 and left <= 3 then
			text = tostring(math.ceil(left))
		elseif left <= 0 and left > -0.9 then
			text = "GO!"
		end
	end
	-- Studio-only capture hook (UI v2 verification, lane 5): SkyRallyTrackFlow.QACountdown holds a beat on screen.
	if RunService:IsStudio() then
		local qa = gui:GetAttribute("QACountdown")
		if type(qa) == "string" and qa ~= "" then
			text = qa
		end
	end
	if text ~= lastCountdownText then
		lastCountdownText = text
		countdownLabel.Visible = text ~= ""
		LocalPlayer:SetAttribute("HudCountdownUp", text ~= "") -- RivalBubbles keeps out of lane A meanwhile
		if text == "" then
			countdownLabel.Text = ""
		else
			local sc = countdownLabel:FindFirstChildOfClass("UIScale") :: UIScale
			-- v21: the hero numeral is 20 percent of the screen height, no bigger than lane A. TextSize and UITextSizeConstraint
			-- cap at 100 px and a UIScale does not enlarge text, so the size goes in a RichText font tag (works to 200).
			local cam = workspace.CurrentCamera
			local la = HudMetrics.get().rects.laneA
			local target = if numeralSize > 0
				then math.clamp(numeralSize, 24, 200)
				else math.clamp(math.floor(math.min((if cam then cam.ViewportSize.Y else 400) * 0.2, math.max(la.h, 48))), 24, 200)
			countdownLabel.TextScaled = false
			local cl = countdownLabel:FindFirstChildOfClass("UITextSizeConstraint")
			if cl then
				cl:Destroy() -- it clamps the rich-text size too (a 96 px cap)
			end
			countdownLabel.RichText = true
			countdownLabel.TextSize = math.min(100, target)
			countdownLabel.Text = string.format('<font size="%d">%s</font>', target, text)
			-- UI v2 (lane 5): each beat punches in big and tilted and settles flat; 3-2-1 in a gold-to-orange gradient, GO! in green.
			local isGo = text == "GO!"
			sc.Scale = if isGo then 1.9 else 1.6
			TweenService:Create(sc, TweenInfo.new(if isGo then 0.4 else 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			countdownLabel.Rotation = if isGo then -14 else -10
			TweenService:Create(countdownLabel, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
			countdownLabel.TextColor3 = Color3.new(1, 1, 1)
			local cg = countdownLabel:FindFirstChildOfClass("UIGradient")
			if cg then
				cg.Color = if isGo
					then ColorSequence.new(Color3.fromHex("C8FFB0"), Color3.fromHex("1FA83A"))
					else ColorSequence.new(Color3.fromHex("FFF6C8"), Color3.fromHex("FF9A1F"))
			end
			task.spawn(pcall, function() -- moments VFX: pulse ring at the car, GO ring + FOV pop + gantry confetti
				(require(script.Parent:WaitForChild("CelebrationFx")) :: any).countdown(text)
			end)
		end
	end
	-- Grid order: one line for GridOrder.HUD_SECONDS, ending half a second before GO. The server decides the seat and
	-- the reason (player attributes); this only formats them. No colour carries meaning.
	local gridText = ""
	if type(go) == "number" and GridOrder.hudVisible(go - now) then
		gridText = GridOrder.hudLine(
			LocalPlayer:GetAttribute("GridReason"),
			LocalPlayer:GetAttribute("GridPosition"),
			LocalPlayer:GetAttribute("GridLastPlace"),
			LocalPlayer:GetAttribute("GridField")
		)
	end
	if gridText ~= gridLabel.Text then
		gridLabel.Text = gridText
		gridLabel.Visible = gridText ~= ""
	end
	-- return-to-hub timer
	local back = RaceAttr.mine("ReturnToHubAt")
	if type(back) == "number" and back > now then
		-- L30: with votes, say what the timer will do (AGAIN with more than half of the humans, else the hub).
		local again = RaceAttr.mine("VotesAgain")
		local humans = RaceAttr.mine("VoteHumans")
		local replaying = voting() and type(again) == "number" and type(humans) == "number"
			and RaceFlowRules.decide(again, 0, humans, true) == "again"
		local n = math.ceil(back - now) * (if replaying then -1 else 1)
		if n ~= lastCount then
			lastCount = n
			returnLabel.Text = if replaying then string.format("RACING AGAIN IN %d", -n) else string.format("BACK TO HUB IN %d", n)
		end
		placeReturnLabel()
		-- The podium ceremony owns the screen (HudPhase "podium"): the line would sit on its stats plank. The photo cam ("finish") too.
		returnLabel.Visible = HudPhase.phase() ~= "podium" and HudPhase.phase() ~= "finish"
	else
		returnLabel.Visible = false
		lastCount = -1
	end
	-- L31/L32: the lobby banner and its countdown on every hub client.
	local goAt = workspace:GetAttribute("LobbyGoAt")
	local opener = workspace:GetAttribute("LobbyOpener")
	local lobbyLine = if type(goAt) == "number" and goAt > now - 0.5 and RaceAttr.mine("RaceMode") == "hub"
		then RaceFlowRules.lobbyText(tostring(opener or "Someone"), lobbyTrackLabel(), goAt - now)
		else ""
	if lobbyLine ~= lastLobbyText then
		local wasHidden = lastLobbyText == ""
		lastLobbyText = lobbyLine
		lobbyText.Text = lobbyLine
		lobbyFrame.Visible = lobbyLine ~= ""
		local guest = LocalPlayer:GetAttribute("LobbyGuest") == true
		lobbyGuest.Visible = guest
		lobbyText.Size = if guest then UDim2.new(1, -16, 0.58, 0) else UDim2.new(1, -16, 1, -8)
		if lobbyLine ~= "" then
			local sc = lobbyFrame:FindFirstChildOfClass("UIScale")
			if sc then
				sc.Scale = if wasHidden then 0.85 else 1.04
				TweenService:Create(sc, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
			if wasHidden then
				UiSound.play(UiSkinRules.cueFor("open") or "open") -- the banner appearing (its countdown ticks stay their own)
			end
		end
	end
	local storm = stormLine(now)
	if storm ~= lastStormText then
		lastStormText = storm
		stormLabel.Text = storm
		stormLabel.Visible = storm ~= ""
	end
	-- battle plank: title and time left (workspace.BattleEndsAt, server time)
	if battleHud.Visible then
		avoidWorldLabels()
		local endsAt = RaceAttr.mine("BattleEndsAt")
		local state = RaceAttr.mine("BattleState")
		-- Before GO the clock holds at the full cap (BattleEndsAt counts from GO), not cap plus the countdown.
		local from = if type(go) == "number" and go > now then go else now
		local left = if type(endsAt) == "number" then math.max(0, endsAt - from) else 0
		local clock = string.format("%d:%02d", math.ceil(left) // 60, math.ceil(left) % 60)
		local title = tostring(RaceAttr.mine("BattleTitle") or "BATTLE")
		battleTitle.Text = if state == "over" then title .. "  -  OVER"
			elseif state == "waiting" then title .. "  -  WAITING"
			else string.format("%s  -  %s", title, clock)
		battleTitle.TextColor3 = if left <= 10 and state == "running" then Color3.fromRGB(255, 150, 120) else CREAM
	end
end

-- The hub bar plus its Storm Cup line (rects.hubBar) is wider than the position readout it replaces in the hub (30 percent
-- of the width, 240..520 px), so while it shows, lane A (and, in NotifyKit, lane B) stop short of it (rects.hubLaneA / hubLaneB).
-- Lane A: the 3-2-1 / GO! hero text, the grid line just under it, the lobby banner (hub) at its top.
placeLaneA = function()
	local snap = HudMetrics.get()
	local vp = snap.viewport
	local la = if hubBar.Visible then snap.rects.hubLaneA else snap.rects.laneA
	-- v22: the numeral box comes from HudLayoutRules.countdownNumeral (22 percent of the height on a phone, 18 desktop), centred above
	-- the kart; it may be wider than lane A but is kept clear of the minimap, item column and chips. The hub keeps lane A.
	local nSize, nr = HudLayoutRules.countdownNumeral(vp.X, vp.Y, snap.rects)
	if hubBar.Visible then
		nSize, nr = 0, la
	end
	numeralSize = nSize
	countdownLabel.AnchorPoint = Vector2.new(0.5, 0)
	countdownLabel.Position = UDim2.fromOffset(math.floor(nr.x + nr.w / 2), math.floor(nr.y))
	countdownLabel.Size = UDim2.fromOffset(math.floor(nr.w), math.floor(nr.h))
	countdownLabel.TextWrapped = false
	local gridH = math.max(HudLayoutRules.MIN_TEXT + 6, math.floor(vp.Y * 0.055))
	-- v21: the "you start 7th" line rides ABOVE the hero numeral (outside a battle, where lane A is already low) so it stays off the
	-- gate and the kart; it was a 30 px line between them.
	local gridY = if snap.rects.battleHud or nr.y - gridH - 4 < snap.rects.laneB.y + snap.rects.laneB.h + 2 then nr.y + nr.h + 4 else nr.y - gridH - 4
	gridLabel.Position = UDim2.fromOffset(math.floor(la.x), math.floor(gridY))
	gridLabel.Size = UDim2.fromOffset(math.floor(la.w), gridH)
	lobbyFrame.AnchorPoint = Vector2.zero
	lobbyFrame.Position = UDim2.fromOffset(math.floor(la.x), math.floor(la.y))
	lobbyFrame.Size = UDim2.fromOffset(math.floor(math.min(la.w, 560)), math.clamp(math.floor(vp.Y * 0.12), 56, 92))
end

-- The hub hint under the ADVENTURE bar: an explicit TextSize (TextScaled at 12-17 px collapsed the word spaces:
-- "Drivethrough a portalarch") on a rounded dark backing with a stroke, the longest wording that fits the bar's width.
local function fitHubHint(width: number, height: number, touch: boolean)
	local hint = hubBar:FindFirstChild("Hint") :: Frame?
	local hintText = hint and hint:FindFirstChild("Text") :: TextLabel?
	if not hint or not hintText then
		return
	end
	local texts: { string } = if touch
		then { "Tap RACE or drive into a portal", "Drive into a portal" }
		else { "Press B or drive into a portal", "Drive into a portal" }
	local maxSize = math.max(HudLayoutRules.MIN_TEXT, math.floor(height))
	local pick, pickSize = texts[#texts], HudLayoutRules.MIN_TEXT
	local found = false
	for _, t in texts do
		for sz = maxSize, HudLayoutRules.MIN_TEXT, -1 do
			local b = TextService:GetTextSize(t, sz, Enum.Font.GothamBold, Vector2.new(10000, 100))
			if b.X + 16 <= width then
				pick, pickSize, found = t, sz, true
				break
			end
		end
		if found then
			break
		end
	end
	hintText.TextScaled = false
	hintText.TextWrapped = false
	hintText.TextTruncate = Enum.TextTruncate.AtEnd
	hintText.Text = pick
	hintText.TextSize = pickSize
	hint.AutomaticSize = Enum.AutomaticSize.None
	-- a compact chip right-aligned under the RACE key
	local tw = TextService:GetTextSize(pick, pickSize, Enum.Font.GothamBold, Vector2.new(10000, 100)).X
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, 0, hint.Position.Y.Scale, hint.Position.Y.Offset)
	hint.Size = UDim2.new(0, math.min(width, tw + 28), 0, math.max(pickSize, math.floor(height)) + 6)
end

-- Positions that depend on the viewport, the safe-area insets, the Roblox nav and the input kind; build() and
-- HudMetrics.onChanged call it.
local function applyLayout()
	local snap = HudMetrics.get()
	local ins = snap.insets
	local rects = snap.rects
	local vp = snap.viewport
	-- Top-right slot (the position readout is hidden in the hub): the hub bar, right edge on rects.hubBar's.
	local hb = rects.hubBar
	-- Explicit pixels, clamped into what the ScreenGui really covers: a viewport reading that disagrees with the gui
	-- (DPI scaling in a real client at 2048x1088) used to push the bar's right edge off the screen.
	local gsz = gui.AbsoluteSize
	local pl = HudLayoutRules.hubBarPlacement(hb, vp.X, vp.Y, gsz.X, gsz.Y, ins.right)
	local hw, hr, hubBarH = pl.w, pl.right, pl.h
	hubBar.AnchorPoint = Vector2.new(1, 0)
	hubBar.Position = UDim2.fromOffset(math.floor(hr), math.floor(hb.y))
	hubBar.Size = UDim2.fromOffset(math.floor(hw), math.floor(hubBarH))
	if not hubBarLogged then
		hubBarLogged = true
		-- Logged twice (Absolute* values settle a frame after the Size write; the player-list reserve arrives later). Reports the
		-- outermost visible banner (the bar, its hint and the Storm Cup lines) in absolute screen px against the gui's own box.
		for _, delay in { 0, 3 } do
			task.delay(delay, function()
				local cam = workspace.CurrentCamera
				local vpz = if cam then cam.ViewportSize else Vector2.zero
				local gp, gs = gui.AbsolutePosition, gui.AbsoluteSize
				local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
				local parts: { any } = { hubBar, hubBar:FindFirstChild("AdventureButton"), hubBar:FindFirstChild("Hint"), stormLabel }
				for _, o in parts do
					if o and (o :: GuiObject).Visible then
						local p, sz2 = (o :: GuiObject).AbsolutePosition, (o :: GuiObject).AbsoluteSize
						x0, y0, x1, y1 = math.min(x0, p.X), math.min(y0, p.Y), math.max(x1, p.X + sz2.X), math.max(y1, p.Y + sz2.Y)
					end
				end
				local lim = Players.LocalPlayer:GetAttribute("HudRightLimit")
				local rightLimit = if type(lim) == "number" then lim else gs.X - HudMetrics.get().insets.right -- no live topbar / player list reserve: the gui's own right edge
				print(string.format("[SkyRally][HUD] hubbar gui=%d,%d %dx%d vp=%dx%d banner=%d,%d..%d,%d (%dx%d) rightLimit=%d marginToGuiRight=%d",
					gp.X, gp.Y, gs.X, gs.Y, vpz.X, vpz.Y, x0, y0, x1, y1, x1 - x0, y1 - y0, rightLimit, gp.X + gs.X - x1))
			end)
		end
	end
	-- The RACE key: the GARAGE button's width (GarageModel.hubButtonRect), a touch-safe height, right-aligned.
	local adv = hubBar:FindFirstChild("AdventureButton") :: GuiObject?
	local keyW = GarageModel.hubButtonRect(vp.X, vp.Y).w
	local keyH = math.clamp(math.floor(hubBarH * 0.6), 44, 60)
	if adv then
		adv.Size = UDim2.fromOffset(keyW, keyH)
	end
	local hintEl = hubBar:FindFirstChild("Hint") :: GuiObject?
	if hintEl then
		hintEl.Position = UDim2.new(1, 0, 0, keyH + 4)
	end
	fitHubHint(hw, math.min(hubBarH * 0.26, 20), HudMetrics.get().kind == "touch")
	placeLaneA()
	returnLabel.Position = UDim2.new(0.3, 0, 0.8, -ins.bottom)
	-- Battle: the plaque in the top-centre slot (lane B drops below it), the field board under the nav column (desktop)
	-- or in the top-right (touch).
	local bh = rects.battleHud
	if bh then
		battleHud.AnchorPoint = Vector2.zero
		battleHud.Position = UDim2.fromOffset(math.floor(bh.x), math.floor(bh.y))
		battleHud.Size = UDim2.fromOffset(math.floor(bh.w), bh.h)
	end
	local bb = rects.battleBoard
	if bb then
		battleBoard.Position = UDim2.fromOffset(math.floor(bb.x), math.floor(bb.y))
		boardW = math.floor(bb.w)
		boardMaxH = math.floor(bb.h)
		-- The rect's height is 8 row pitches plus the panel padding (fewer rows' worth on a short screen); the rows are the
		-- pitch less the list's 2 px gap.
		boardRowH = math.max(15, math.floor((bb.h - 2 * BOARD_PAD) / 8) - 2)
		sizeBoardRows()
	end
end

local function build()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallyTrackFlow"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg

	-- curtain
	curtain = Instance.new("Frame")
	curtain.Name = "Curtain"
	curtain.Size = UDim2.fromScale(1, 1)
	curtain.BackgroundColor3 = CURTAIN_NAVY
	curtain.Visible = false
	curtain.ZIndex = 50
	curtain.Parent = gui
	-- UI v2 curtain (presentation only; timing lives in showCurtain / the MapReady handshake): the board's navy
	-- gradient, the zone name on a slanted gold band with a checker strip, the track name in the display face, the
	-- race line in a dark pill. The zone colour shows only in CurtainKart's map well.
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(122, 128, 140))
	grad.Parent = curtain
	curtainZone = label(curtain, "ZoneName", "", UDim2.new(0.5, 0, 0.14, 0), UDim2.new(0.25, 0, 0.3, 0))
	curtainZone.ZIndex = 51
	curtainZone.BackgroundTransparency = 0
	curtainZone.BackgroundColor3 = Color3.fromRGB(255, 216, 61)
	curtainZone.TextColor3 = UiSkin.color("ink")
	curtainZone.Rotation = -2
	do
		local zs = curtainZone:FindFirstChildOfClass("UIStroke")
		if zs then
			zs.Enabled = false
		end
		local bandGrad = Instance.new("UIGradient")
		bandGrad.Rotation = 90
		bandGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(255, 160, 50))
		bandGrad.Parent = curtainZone
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 12)
		bc.Parent = curtainZone
		local bs = Instance.new("UIStroke")
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bs.Color = UiSkin.color("ink")
		bs.Thickness = 4
		bs.Parent = curtainZone
		local bp = Instance.new("UIPadding")
		bp.PaddingTop = UDim.new(0.12, 0)
		bp.PaddingBottom = UDim.new(0.1, 0)
		bp.Parent = curtainZone
		local chk = UiSkin.checker(curtainZone, { name = "Checker", size = UDim2.new(0.9, 0, 0, 8), position = UDim2.new(0.5, 0, 1, 10), anchor = Vector2.new(0.5, 0), cells = 30, zIndex = 51 })
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 3)
		cc.Parent = chk
	end
	curtainTrack = label(curtain, "TrackName", "", UDim2.new(0.7, 0, 0.09, 0), UDim2.new(0.15, 0, 0.47, 0), Enum.Font.GothamBold)
	curtainTrack.ZIndex = 51
	curtainTrack.FontFace = UiSkin.font("display")
	curtainHint = label(curtain, "Hint", "", UDim2.new(0.6, 0, 0.06, 0), UDim2.new(0.2, 0, 0.6, 0), Enum.Font.Gotham)
	curtainHint.ZIndex = 51
	curtainHint.FontFace = UiSkin.font("bodyHeavy")
	curtainHint.BackgroundTransparency = 0.25
	curtainHint.BackgroundColor3 = Color3.fromRGB(14, 27, 69)
	do
		local hc = Instance.new("UICorner")
		hc.CornerRadius = UDim.new(0.5, 0)
		hc.Parent = curtainHint
		local hp = Instance.new("UIPadding")
		hp.PaddingTop = UDim.new(0.14, 0)
		hp.PaddingBottom = UDim.new(0.14, 0)
		hp.PaddingLeft = UDim.new(0.03, 0)
		hp.PaddingRight = UDim.new(0.03, 0)
		hp.Parent = curtainHint
	end

	-- countdown
	countdownLabel = label(gui, "Countdown", "", UDim2.new(0.3, 0, 0.22, 0), UDim2.new(0.35, 0, 0.19, 0)) -- lane A (applyLayout)
	countdownLabel.Visible = false
	countdownLabel.ZIndex = 40
	-- UI v2 hero numerals (lane 5 owns the countdown look): the heavy italic display face over a vertical gradient.
	countdownLabel.FontFace = UiSkin.font("display") -- v38-flow: the kit face
	local cdg = Instance.new("UIGradient")
	cdg.Rotation = 90
	cdg.Color = ColorSequence.new(Color3.fromHex("FFF6C8"), Color3.fromHex("FF9A1F"))
	cdg.Parent = countdownLabel
	local cs = countdownLabel:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	cs.Thickness = 7
	cs.LineJoinMode = Enum.LineJoinMode.Round
	cs.Color = UiSkin.color("ink")
	cs.Parent = countdownLabel
	local sc = Instance.new("UIScale")
	sc.Parent = countdownLabel
	gridLabel = label(gui, "GridLine", "", UDim2.new(0.4, 0, 0.055, 0), UDim2.new(0.3, 0, 0.42, 0), Enum.Font.GothamBold) -- under lane A
	gridLabel.Visible = false
	gridLabel.ZIndex = 40
	gridLabel.FontFace = UiSkin.font("display") -- v38-flow: the display face, like every other centre line
	local gs = gridLabel:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	gs.Thickness = 2.5
	gs.Color = UiSkin.color("ink")
	gs.Parent = gridLabel

	-- hub bar: ADVENTURE button + hint
	hubBar = Instance.new("Frame")
	hubBar.Name = "HubBar"
	hubBar.BackgroundTransparency = 1
	hubBar.AnchorPoint = Vector2.new(1, 0)
	hubBar.Position = UDim2.new(1, -14, 0, 10)
	hubBar.Size = UDim2.new(0.3, 0, 0.13, 0)
	hubBar.Visible = false
	hubBar.Parent = gui
	local sz = Instance.new("UISizeConstraint")
	sz.MaxSize = Vector2.new(520, 96)
	sz.MinSize = Vector2.new(160, 52) -- hubBarPlacement keeps the width >= 160 itself
	sz.Parent = hubBar
	-- UI v2: a primary hub key sized like the GARAGE button under it (applyLayout), not a bar across the sky.
	local adv = UiSkin.button(hubBar, "go", "RACE", {
		name = "AdventureButton",
		anchor = Vector2.new(1, 0),
		position = UDim2.fromScale(1, 0),
		size = UDim2.new(0, 210, 0.66, 0),
		glyph = "flag",
		maxText = 34,
		sound = "tab",
	})
	-- The hint's backing is a toast slab Frame ("Hint", which applyMode / fitHubHint look up) with the text in a child:
	-- slab art on a TextLabel would cover its own text.
	local hint = Instance.new("Frame")
	hint.Name = "Hint"
	hint.Size = UDim2.new(1, 0, 0.32, 0)
	hint.Position = UDim2.new(0, 0, 0.68, 0)
	hint.Parent = hubBar
	UiSkin.style(hint, "toast_slab", { color = WOOD_DARK, alpha = 0.35, corner = 8 })
	local hintText = label(hint, "Text", "Drive through a portal arch or open the board (B / Y)", UDim2.fromScale(1, 1), UDim2.new(), Enum.Font.GothamBold)
	hintText.TextScaled = false
	hintText.TextSize = 14
	local hc = hintText:FindFirstChildOfClass("UITextSizeConstraint")
	if hc then
		hc:Destroy()
	end
	local hs = hintText:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	hs.Color = UiSkin.color("ink")
	hs.Thickness = 1.5
	hs.Parent = hintText
	adv.Activated:Connect(function()
		openBoard(not boardShown())
	end)
	-- Two lines under the bar; the Garage's hub button sits below this band (GarageModel.hubButtonRect).
	stormLabel = label(hubBar, "StormCup", "", UDim2.new(1, 0, GarageModel.STORM_LINE_SCALE, 0), UDim2.new(0, 0, 1, 4), Enum.Font.GothamBold)
	stormLabel.TextWrapped = true
	stormLabel.TextTruncate = Enum.TextTruncate.AtEnd
	stormLabel.TextColor3 = Color3.fromRGB(190, 225, 255)
	stormLabel.Visible = false
	local ss = stormLabel:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	ss.Color = UiSkin.color("ink")
	ss.Thickness = 1.5
	ss.Parent = stormLabel

	-- adventure board (UI v2 course select: client/CourseSelect)
	boardFrame = Instance.new("Frame")
	boardFrame.Name = "AdventureBoard"
	boardFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	boardFrame.Position = BOARD_HOME
	boardFrame.Size = UDim2.fromScale(0.9, 0.86) -- fitBoard sets pixels from the gui size
	boardFrame.Visible = false
	boardFrame.ZIndex = 30
	-- Its own ScreenGui over the Garage button (26), under Settings (30) and the toasts (31), with a scrim behind it.
	local boardGui = Instance.new("ScreenGui")
	boardGui.Name = "SkyRallyCourseSelect"
	boardGui.ResetOnSpawn = false
	boardGui.DisplayOrder = 27
	boardGui.IgnoreGuiInset = gui.IgnoreGuiInset
	boardGui.ScreenInsets = gui.ScreenInsets
	boardGui.ZIndexBehavior = gui.ZIndexBehavior
	boardGui.Parent = pg
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.BackgroundColor3 = Color3.fromRGB(6, 10, 30)
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.Position = UDim2.fromScale(-0.1, -0.2)
	scrim.Size = UDim2.fromScale(1.2, 1.4)
	scrim.Visible = false
	scrim.ZIndex = 1
	scrim.Parent = boardGui
	boardFrame.Parent = boardGui
	boardFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		scrim.Visible = boardFrame.Visible
		if boardFrame.Visible then
			scrim.BackgroundTransparency = 1
			TweenService:Create(scrim, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()
		end
	end)
	UiSkin.style(boardFrame, "panel", { S = 1 })
	boardGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBoard)
	task.defer(fitBoard)
	CourseSelect.build(boardFrame, {
		go = function(z: CourseSelect.Zone, mode: string)
			openBoard(false, true) -- the press already spoke; the curtain follows
			fire("RequestRace", z.id, mode)
		end,
		leave = function()
			fire("LeaveLobby")
		end,
		close = function()
			openBoard(false)
		end,
		toast = function(msg: string)
			TrackFlow.toast(msg, Color3.fromRGB(255, 214, 160))
		end,
	})

	-- toast: NotifyKit draws it in lane B; it only needs to know when the hub bar is up (the lane stops short of it)
	NotifyKit.setHubProbe(function()
		return hubBar.Visible
	end)

	-- Lobby banner (L31/L32): lane A, below the toasts, clear of the ADVENTURE bar and the Garage button on a 740x360 phone.
	lobbyFrame = Instance.new("Frame")
	lobbyFrame.Name = "LobbyBanner"
	lobbyFrame.AnchorPoint = Vector2.zero
	lobbyFrame.Position = UDim2.new(0.5, 0, 0.26, 0)
	lobbyFrame.Size = UDim2.new(0.4, 0, 0.12, 0)
	lobbyFrame.Visible = false
	lobbyFrame.Parent = gui
	UiSkin.style(lobbyFrame, "sign_hanging", { color = WOOD, alpha = 0.08, corner = 10, stroke = Color3.fromRGB(255, 214, 120), strokeWidth = 2 })
	local lsz = Instance.new("UISizeConstraint")
	lsz.MinSize = Vector2.new(200, 56)
	lsz.MaxSize = Vector2.new(560, 92)
	lsz.Parent = lobbyFrame
	Instance.new("UIScale").Parent = lobbyFrame
	lobbyText = label(lobbyFrame, "Text", "", UDim2.new(1, -16, 1, -8), UDim2.new(0, 8, 0, 4), Enum.Font.GothamBlack)
	lobbyText.TextWrapped = true
	local lts = lobbyText:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	lts.Color = UiSkin.color("ink")
	lts.Thickness = 1.5
	lts.Parent = lobbyText
	lobbyGuest = label(lobbyFrame, "Guest", RaceFlowRules.GUEST_TEXT, UDim2.new(1, -16, 0.34, 0), UDim2.new(0, 8, 0.62, 0), Enum.Font.GothamBold)
	lobbyGuest.TextColor3 = Color3.fromRGB(255, 214, 160)
	lobbyGuest.Visible = false
	local cl = label(gui, "CoinCounter", "", UDim2.new(0.16, 0, 0.055, 0), UDim2.new(0.42, 0, 0.11, 0), Enum.Font.GothamBlack)
	cl.Visible = false
	cl.TextColor3 = Color3.fromRGB(226, 234, 248)
	local cls = cl:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	cls.Color = UiSkin.color("ink")
	cls.Thickness = 2
	cls.Parent = cl
	coinLabel = cl
	returnLabel = label(gui, "ReturnTimer", "", UDim2.new(0.4, 0, 0.05, 0), UDim2.new(0.3, 0, 0.8, 0), Enum.Font.GothamBold)
	returnLabel.Visible = false
	returnLabel.FontFace = UiSkin.font("display") -- v38-flow: the v2 display face on a navy pill
	local rs = returnLabel:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	rs.Color = UiSkin.color("ink")
	rs.Thickness = 1.5
	rs.Parent = returnLabel
	-- Pill backing: bare cream text vanished over a bright or busy scene (a lava tunnel behind the results card).
	returnLabel.BackgroundColor3 = UiSkin.color("inset")
	returnLabel.BackgroundTransparency = 0.05
	corner(returnLabel, 11)
	local rpad = Instance.new("UIPadding")
	rpad.PaddingTop = UDim.new(0, 2)
	rpad.PaddingBottom = UDim.new(0, 2)
	rpad.PaddingLeft = UDim.new(0, 12)
	rpad.PaddingRight = UDim.new(0, 12)
	rpad.Parent = returnLabel
	stroke(returnLabel, UiSkin.color("ink"), 2)

	-- battle plank (top centre, non-modal): mode and clock, this player's objective line under it
	battleHud = Instance.new("Frame")
	battleHud.Name = "BattleHud"
	battleHud.AnchorPoint = Vector2.new(0.5, 0)
	battleHud.Position = UDim2.new(0.5, 0, 0, 8)
	battleHud.Size = UDim2.new(0.34, 0, 0.1, 0)
	battleHud.Visible = false
	battleHud.Parent = gui
	UiSkin.style(battleHud, "sign_hanging", { color = WOOD_DARK, alpha = 0.25, corner = 10, stroke = RIM, strokeWidth = 2 })
	local bhs = Instance.new("UISizeConstraint")
	bhs.MaxSize = Vector2.new(560, 120)
	bhs.MinSize = Vector2.new(160, 40)
	bhs.Parent = battleHud
	battleTitle = label(battleHud, "Title", "", UDim2.new(1, -16, 0.52, 0), UDim2.new(0, 8, 0, 3))
	battleObjective = label(battleHud, "Objective", "", UDim2.new(1, -16, 0.38, 0), UDim2.new(0, 8, 0.56, 0), Enum.Font.GothamBold)
	battleObjective.TextColor3 = Color3.fromRGB(255, 236, 160)

	-- field board (left, under the item slot area): one row per entrant, this player highlighted, out rows dimmed
	battleBoard = Instance.new("Frame")
	battleBoard.Name = "BattleBoard"
	battleBoard.Position = UDim2.new(0, 12, 0.3, 0)
	battleBoard.Size = UDim2.new(0.2, 0, 0, 180)
	battleBoard.Visible = false
	battleBoard.Parent = gui
	-- alpha 0.45: a translucent panel so the rows read over any sky
	UiSkin.style(battleBoard, "panel_wood", { color = WOOD_DARK, alpha = 0.45, corner = 8, stroke = RIM, strokeWidth = 1.5 })
	local bbp = Instance.new("UIPadding")
	bbp.PaddingLeft = UDim.new(0, BOARD_PAD)
	bbp.PaddingRight = UDim.new(0, BOARD_PAD)
	bbp.PaddingTop = UDim.new(0, BOARD_PAD)
	bbp.PaddingBottom = UDim.new(0, BOARD_PAD)
	bbp.Parent = battleBoard
	local bbl = Instance.new("UIListLayout")
	bbl.Padding = UDim.new(0, 2)
	bbl.SortOrder = Enum.SortOrder.LayoutOrder
	bbl.Parent = battleBoard

	-- results panel (after the battle): winner, ranking, fragment award; HUB / AGAIN
	resultsFrame = Instance.new("Frame")
	resultsFrame.Name = "BattleResults"
	resultsFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	resultsFrame.Position = UDim2.fromScale(0.5, 0.47)
	resultsFrame.Size = UDim2.fromScale(0.5, 0.8) -- capped by the size constraint on desktop; a phone needs the height for 8 rows
	resultsFrame.Visible = false
	resultsFrame.ZIndex = 32
	resultsFrame.Parent = gui
	UiSkin.style(resultsFrame, "panel", { S = 1 })
	local rsz = Instance.new("UISizeConstraint")
	rsz.MaxSize = Vector2.new(600, 470)
	rsz.MinSize = Vector2.new(300, 230)
	rsz.Parent = resultsFrame
	resultsTitle = label(resultsFrame, "Title", "", UDim2.new(1, -20, 0, 40), UDim2.new(0, 10, 0, 6))
	resultsTitle.ZIndex = 33
	resultsReason = label(resultsFrame, "Reason", "", UDim2.new(1, -20, 0, 20), UDim2.new(0, 10, 0, 48), Enum.Font.GothamBold)
	resultsReason.ZIndex = 33
	resultsList = Instance.new("Frame")
	resultsList.Name = "Ranking"
	resultsList.BackgroundTransparency = 1
	resultsList.Position = UDim2.new(0, 12, 0, 74)
	resultsList.Size = UDim2.new(1, -24, 1, -170)
	resultsList.ZIndex = 33
	resultsList.Parent = resultsFrame
	local rll = Instance.new("UIListLayout")
	rll.Padding = UDim.new(0, 3)
	rll.SortOrder = Enum.SortOrder.LayoutOrder
	rll.Parent = resultsList
	resultsAward = label(resultsFrame, "Award", "", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 1, -92), Enum.Font.GothamBold)
	resultsAward.ZIndex = 33
	local function resultsButton(name: string, slot: string, text: string, x: number, color: Color3, sound: string): GuiButton
		return UiSkin.button(resultsFrame, slot, text, {
			name = name,
			anchor = Vector2.new(0.5, 1),
			position = UDim2.new(x, 0, 1, -10),
			size = UDim2.new(0.38, 0, 0, 44),
			color = color,
			font = Enum.Font.GothamBlack,
			textScaled = true,
			textColor = CREAM,
			zIndex = 33,
			corner = 8,
			maxText = 26,
			sound = sound,
		})
	end
	local hubBtn = resultsButton("HubButton", "sky", "HUB", 0.27, WOOD_DARK, "back")
	resultsHub = hubBtn
	resultsAgain = resultsButton("AgainButton", "go", "AGAIN", 0.73, Color3.fromRGB(78, 200, 90), "confirm")
	resultsAgainBtn = resultsAgain
	-- L30: with 2+ humans a press is a vote; the panel stays up showing the count until the server acts.
	hubBtn.Activated:Connect(function()
		if not voting() then
			hideResults()
		end
		fire("RequestHub")
	end)
	resultsAgain.Activated:Connect(function()
		if not voting() then
			hideResults()
		end
		-- Same path as the race finish screen's FLY AGAIN (FlightServer.onPlayAgainRequested on the server).
		local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
		local fsr = remotes and remotes:FindFirstChild("FlightStateRemote")
		if fsr and fsr:IsA("RemoteEvent") then
			fsr:FireServer("RequestPlayAgain")
		end
	end)
end

-- The finish screen's CLOSE becomes HUB: it returns the server to Central Island (with 2+ humans, a vote, L30).
local function hookFinishScreen()
	task.spawn(function()
		local pg = LocalPlayer:WaitForChild("PlayerGui")
		local hud = pg:WaitForChild("SkyRallyHUD", 30)
		local btn = hud and hud:FindFirstChild("CloseFinishButton", true)
		if btn and btn:IsA("GuiButton") then
			finishHubBtn = btn
			btn.Activated:Connect(function()
				fire("RequestHub")
				if not voting() then
					boardOnHubAt = os.clock()
				end
			end)
		end
		local again = hud and hud:FindFirstChild("FlyAgainButton", true)
		if again and again:IsA("GuiButton") then
			finishAgainBtn = again -- FLY AGAIN after BATTLE cancels it on the server (TrackDirector.requestExit "again")
		end
		local battle = hud and hud:FindFirstChild("BattleFinishButton", true)
		if battle and battle:IsA("GuiButton") then
			-- BATTLE: one request; the server routes it (BattleAccessRules.cardRoute): solo straight into this map's battle,
			-- with 2+ humans the HUB vote and then the battle once the hub has loaded. The server re-checks the unlock.
			battle.Activated:Connect(function()
				local trackId = RaceAttr.mine("ActiveTrackId")
				if type(trackId) ~= "string" then
					return
				end
				fire("RequestBattle", trackId)
			end)
		end
		refreshVoteLabels()
	end)
end

function TrackFlow.init()
	build()
	applyLayout()
	HudMetrics.onChanged(applyLayout)
	-- A gui size the camera reading missed (DPI-scaled client): HudMetrics recomputes every rect for it, then the hub bar re-clamps.
	HudMetrics.setGuiSize(gui.AbsoluteSize)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		HudMetrics.setGuiSize(gui.AbsoluteSize)
		applyLayout()
	end)
	PortalPlunge.init() -- REMARKABLE 20 (and PortalWake, item 24)
	local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 15)
	remote = remotes and remotes:WaitForChild("TrackFlowRemote", 15) :: RemoteEvent?
	if remote then
		remote.OnClientEvent:Connect(function(event: string, data: any)
			if event == "PortalLocked" and type(data) == "table" then
				-- REMARKABLE 20: at the arch, the arch spits the car out and says why; the toast is for the board.
				if not PortalPlunge.onLocked(data) then
					UiSound.play("deny")
					local info = TrackInfo.get(data.id)
					TrackFlow.toast(string.format("%s is locked: %s", if info then info.zoneName else "This zone", tostring(data.why)), Color3.fromRGB(255, 214, 160))
				end
			elseif event == "RaceBusy" and type(data) == "table" then
				-- Per-group races (RaceGroups): that track's race is already running. Only the asker hears it; a portal
				-- plunge that was waiting for the trip unwinds.
				PortalPlunge.onWarpCancel()
				UiSound.play("deny")
				local info = TrackInfo.get(data.id)
				NotifyKit.fromSpec("portal_busy", { zone = if info then info.zoneName else "That track" })
			elseif event == "GroupLoadFailed" and type(data) == "table" then
				-- Per group (RaceGroups): his race map failed or timed out; the server returns him to the plaza and the
				-- seat going lifts the curtain (GroupCurtainRules). The short why is said here.
				UiSound.play("back")
				local info = TrackInfo.get(data.id)
				TrackFlow.toast(
					string.format("%s could not load%s - back to Central Island", if info then info.trackName else "The race", if data.why == "timeout" then " in time" else ""),
					Color3.fromRGB(255, 214, 160),
					3.2
				)
			elseif event == "PortalWarp" and type(data) == "table" then
				-- REMARKABLE 20 / H0-09: the 1.5 s warp; everyone else hears who is taking the server where.
				if data.userId == LocalPlayer.UserId then
					Onboarding.event("portal") -- L27: the guide's arrow and beacon have done their job
					PortalPlunge.onWarp(data)
				else
					local info = TrackInfo.forZone(tostring(data.zone))
					TrackFlow.toast(string.format("%s is diving into %s!", string.sub(tostring(data.name), 1, 20), if info then info.zoneName else "a portal"), if info then info.accent else CREAM, 2)
				end
			elseif event == "PortalWarpCancel" and type(data) == "table" then
				if data.userId == LocalPlayer.UserId then
					PortalPlunge.onWarpCancel()
					if data.why == "backed out" then
						-- portal-load: a refused or cancelled pass always says why.
						TrackFlow.toast("Warp cancelled - you backed out of the arch", Color3.fromRGB(255, 214, 160), 2.4)
					end
				end
			elseif event == "HubFind" then
				TrackFlow.toast("Hub find! +1 Sky Token", Color3.fromRGB(255, 236, 120), 3.2)
				local Music = require(script.Parent.Music) :: any -- REMARKABLE 9: Secret Stinger (chip jingle + cartridge filter)
				Music.secret("find")
				if type(data) == "table" and typeof(data.pos) == "Vector3" then
					local Vfx = require(script.Parent.Vfx) :: any
					Vfx.burst("confetti", CFrame.lookAt(data.pos, data.pos + Vector3.new(0, 50, 0)))
					Vfx.onPickup(data.pos + Vector3.new(0, 4, 0), "token")
					TokenHomecoming.flyFromWorld(data.pos + Vector3.new(0, 4, 0)) -- REMARKABLE 24: the token flies home
				end
			elseif event == "KeyFound" and type(data) == "table" then
				local Music = require(script.Parent.Music) :: any -- REMARKABLE 9: Secret Stinger (chip fanfare + cartridge filter)
				Music.secret("key")
				LadderNotices.keyFound(data) -- KEY FOUND n/4 toast, plus the first-key explainer modal
				if typeof(data.pos) == "Vector3" then
					local Vfx = require(script.Parent.Vfx) :: any
					Vfx.burst("confetti", CFrame.lookAt(data.pos, data.pos + Vector3.new(0, 50, 0)))
					Vfx.onPickup(data.pos, "token")
				end
				task.delay(0.5, refreshKeys)
			elseif event == "BattleToast" and type(data) == "table" and type(data.text) == "string" then
				TrackFlow.toast(string.sub(data.text, 1, 80), TONE_COLOR[tostring(data.tone)] or CREAM, 2.4)
			elseif event == "BattleResults" then
				showResults(data)
			elseif event == "StormCupHold" and type(data) == "table" then
				TrackFlow.toast(string.sub(tostring(data.why), 1, 60), Color3.fromRGB(190, 225, 255), 3)
			elseif event == "LobbyOpen" and type(data) == "table" then
				-- L31/L32: the banner reads the workspace attributes; this is the moment's sound and the opener's note.
				if data.userId == LocalPlayer.UserId then
					if data.portal == true then
						Onboarding.event("portal") -- L27: a portal crossing that opened the lobby counts too
					end
					PortalPlunge.hold()
					UiSound.play("confirm")
					TrackFlow.toast(string.format("Gathering racers - go in %d", math.ceil(tonumber(data.seconds) or RaceFlowRules.LOBBY_SECONDS)), Color3.fromRGB(255, 226, 130), 3)
				else
					UiSound.play("tab")
				end
			elseif event == "LobbyJoined" and type(data) == "table" then
				-- Phase 3: this player is in an arch's lobby (or the next one while it races). The arch and the wait
				-- line carry the count; the plunge he started at the veil unwinds quietly until the lobby goes.
				if data.portal == true then
					Onboarding.event("portal") -- L27: driving through counts
				end
				PortalPlunge.hold()
				UiSound.play("confirm")
				local info = TrackInfo.get(data.id)
				local zone = if info then info.zoneName else tostring(data.id)
				if data.queued == true then
					NotifyKit.fromSpec("portal_queued_in", { zone = zone })
				else
					local goAt = tonumber(data.goAt) or (workspace:GetServerTimeNow() + RaceFlowRules.LOBBY_SECONDS)
					NotifyKit.fromSpec("portal_joined", { zone = zone, time = PortalQueueRules.clock(goAt - workspace:GetServerTimeNow()) })
				end
				lastQueueStep = -math.huge
			elseif event == "LobbyLeft" and type(data) == "table" then
				local info = TrackInfo.get(data.id)
				local zone = if info then info.zoneName else tostring(data.id)
				local why = tostring(data.why)
				if why == "leave" or why == "backed out" then
					UiSound.play("back")
					NotifyKit.fromSpec("portal_left", { zone = zone })
				elseif why == "storm cup" or why == "refused" then
					UiSound.play("back")
					NotifyKit.fromSpec("portal_cancelled", { zone = zone })
				end
				lastQueueStep = -math.huge
			elseif event == "LobbyRefused" and type(data) == "table" then
				PortalPlunge.hold()
				UiSound.play("deny")
				local info = TrackInfo.get(data.id)
				local zone = if info then info.zoneName else tostring(data.id)
				if data.why == "full" then
					NotifyKit.fromSpec("portal_full", { zone = zone })
				else
					NotifyKit.fromSpec("portal_other_mode", { zone = zone, mode = MODE_LABEL[tostring(data.mode)] or "another" })
				end
			elseif event == "LobbyBusy" and type(data) == "table" then
				PortalPlunge.hold()
				local info = TrackInfo.get(data.id)
				local text = RaceFlowRules.lobbyBusyText(data.same == true, tostring(data.name), if info then info.zoneName else tostring(data.id), tonumber(data.seconds) or 0)
				UiSound.play(if data.same == true then "confirm" else "deny")
				TrackFlow.toast(text, Color3.fromRGB(255, 226, 130), 2.6)
			elseif event == "LobbyCancel" and type(data) == "table" then
				local why = tostring(data.why)
				local who = string.sub(tostring(data.name), 1, 20)
				UiSound.play("back")
				TrackFlow.toast(
					if why == "backed out" then string.format("%s backed out - race cancelled", who)
						elseif why == "left" then string.format("%s left - race cancelled", who)
						elseif why == "storm cup" then "Race cancelled - the Storm Cup is starting"
						else "Race cancelled",
					Color3.fromRGB(255, 214, 160),
					2.6
				)
			elseif event == "LoadFailed" and type(data) == "table" then
				-- T1-2: the server could not build the map and fell back (DirectorFailsafeRules.toastText).
				UiSound.play("deny")
				TrackFlow.toast(string.sub(tostring(data.text or "Map load failed"), 1, 60), Color3.fromRGB(255, 214, 160), 3.2)
			elseif event == "VoteRefused" and type(data) == "table" then
				UiSound.play("deny")
				TrackFlow.toast(string.sub(tostring(data.why), 1, 60), Color3.fromRGB(255, 214, 160), 2.4)
			end
		end)
	end
	RaceAttr.changed("RaceMode", applyMode)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		showCurtain(workspace:GetAttribute("TrackSwitching") == true)
	end)
	watchMapReady() -- v37 client-ready handshake
	LadderNotices.init()
	if RaceFlowRules.PER_GROUP then
		-- Phase 2b: this player's own group curtain (GroupCurtainRules), level-driven: on his seat or its Loading flag
		-- changing (RaceAttr.changed fires on both), his map arriving, and at 4 Hz, so no missed edge can strand it.
		local function safeStep()
			local ok, err = pcall(function()
				stepGroupCurtain()
			end)
			if not ok then
				warn("[SkyRally][CURTAIN] " .. tostring(err))
			end
		end
		RaceAttr.changed("Loading", safeStep)
		RaceAttr.changed("ActiveTrackId", safeStep)
		task.spawn(function()
			while true do
				task.wait(GroupCurtainRules.PERIOD)
				safeStep()
			end
		end)
	end
	LocalPlayer:GetAttributeChangedSignal("HubFindsHeld"):Connect(refreshFinds)
	LocalPlayer:GetAttributeChangedSignal("KeysHeld"):Connect(refreshKeys)
	LocalPlayer:GetAttributeChangedSignal(FidelityRules.COMPLETION_ATTRIBUTE):Connect(function()
		if boardFrame and boardFrame.Visible then
			rebuildBoard()
		end
	end)
	LocalPlayer:GetAttributeChangedSignal("BattleHud"):Connect(refreshBattleHud)
	for _, attr in { "BattleKind", "BattleBoard", "BattleState" } do
		RaceAttr.changed(attr, function()
			refreshBattleHud()
			setRaceHudVisible(RaceAttr.mine("RaceMode") ~= "hub" and not isBattle())
		end)
	end
	-- A replay (AGAIN / FLY AGAIN) or a track switch closes the battle results.
	RaceAttr.changed("RaceResetSeq", hideResults)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(hideResults)
	for _, attr in { "VoteHumans", "VotesAgain", "VotesHub" } do
		RaceAttr.changed(attr, refreshVoteLabels)
	end
	-- Another racer's vote landing: a pip that climbs with the count (a press of your own already spoke).
	for _, attr in { "VotesAgain", "VotesHub" } do
		local seen = (RaceAttr.mine(attr) :: number?) or 0
		RaceAttr.changed(attr, function()
			local votes = (RaceAttr.mine(attr) :: number?) or 0
			local pressed = os.clock() - math.max(UiSound.lastPlayed("tap"), UiSound.lastPlayed("stone")) < 0.5
			if votes > seen and not pressed then
				UiSound.play("vote", votes)
			end
			seen = votes
		end)
	end
	-- Phase 3: the queue's widgets refresh at once when this player's lobby or any arch's state changes.
	LocalPlayer:GetAttributeChangedSignal("LobbyArch"):Connect(function()
		lastQueueStep = -math.huge
	end)
	workspace:GetAttributeChangedSignal("ArchStates"):Connect(function()
		lastQueueStep = -math.huge
	end)
	LocalPlayer:GetAttributeChangedSignal("LobbyGuest"):Connect(function()
		lastLobbyText = "" -- re-lay the banner (guest line) on the next frame
	end)
	LocalPlayer:GetAttributeChangedSignal("Coins"):Connect(refreshCoins)
	LocalPlayer:GetAttributeChangedSignal("CoinsHeld"):Connect(refreshCoins)
	RaceAttr.changed("CoinsTotal", function()
		refreshCoins()
		task.delay(2, refreshCoins)
	end)
	LocalPlayer:GetAttributeChangedSignal("PortalStates"):Connect(function()
		if boardFrame.Visible then
			rebuildBoard()
		end
		if RaceAttr.mine("RaceMode") == "hub" then
			labelPortals()
		end
	end)
	-- The arches' signs and swirls are client-built: also draw them when the hub map (re)appears and once after boot, so
	-- a PortalStates value that arrived before this listener (or an unchanged value on the way back to the hub) never
	-- leaves the arches bare. labelPortals is idempotent (it reuses an existing sign and recolours the fill).
	local function labelIfHub()
		if RaceAttr.mine("RaceMode") == "hub" then
			labelPortals()
		end
	end
	RaceAttr.changed("RaceMode", function()
		task.delay(0.5, labelIfHub)
		-- COURSES: once the island is back and the curtain is up, the course select swooshes in (within 60 s of the press).
		if RaceAttr.mine("RaceMode") == "hub" and os.clock() - boardOnHubAt < 60 then
			boardOnHubAt = -math.huge
			task.spawn(function()
				local waited = 0
				while workspace:GetAttribute("TrackSwitching") == true and waited < 20 do
					waited += task.wait(0.25)
				end
				task.wait(0.9)
				if RaceAttr.mine("RaceMode") == "hub" and not boardShown() then
					openBoard(true)
				end
			end)
		end
	end)
	RaceAttr.changed("ActiveTrackId", function()
		task.delay(0.5, labelIfHub)
	end)
	task.delay(1, labelIfHub)
	task.delay(5, labelIfHub)
	if workspace:GetAttribute("TrackSwitching") == true then
		showCurtain(true)
	end
	task.delay(2, applyMode)
	hookFinishScreen()
	RunService.RenderStepped:Connect(Prof.wrap("SR_TrackFlow", step))
end

return TrackFlow
