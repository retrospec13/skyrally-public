--!strict
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local ItemTexAssets = require(Shared:WaitForChild("ItemTexAssets")) :: { [string]: string }
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local BattleAccessRules = require(Shared:WaitForChild("BattleAccessRules")) -- the finish card's BATTLE button
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry")) -- L04: the active track id, never a literal
local GridOrder = require(Shared:WaitForChild("GridOrder")) -- the position plank before GO (grid seat)
local ResultsLayoutRules = require(Shared:WaitForChild("ResultsLayoutRules")) -- the results card rectangle
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler label for the per-frame HUD step
local FlightController = require(script.Parent.FlightController)
-- RaceUI owns the HUD ScreenGui and starts the item/progress layers on it (the client entry script stays unchanged).
local HudExtras = require(script.Parent.HudExtras)
local ItemClient = require(script.Parent.ItemClient)
local Sfx = require(script.Parent.Sfx)
-- REMARKABLE 4: the Wood-and-Stone UI sound kit and press feel (squash, wobble, selection marimba).
local UiSound = require(script.Parent.UiSound)
-- L28 / L82 / audit H15: the HUD ScreenGui stays full-bleed, but its frames keep inside the device safe area (notch,
-- rounded corners, home bar) and, on a TV, a 5 percent margin: client/HudMetrics folds SafeArea in.
local HudPhase = require(script.Parent.HudPhase)
local NotifyKit = require(script.Parent.NotifyKit) -- lane B captions (economy v3 phase 3b): showBanner is a wrapper
local AssistRules = require(Shared:WaitForChild("AssistRules"))
local Settings = require(script.Parent.Settings) -- the gear panel's ASSIST row flips the same switch as the AUTO pill
-- HUD layout v2 (docs/design/HUD_LAYOUT.md): one scale S, one safe rect, one nav reserve; every rectangle comes from here.
local HudMetrics = require(script.Parent.HudMetrics)
local HudLayoutRules = require(Shared:WaitForChild("HudLayoutRules"))
local DodgeRules = require(Shared:WaitForChild("DodgeRules")) -- dodge = double tap left / right
local TouchSteerRules = require(Shared:WaitForChild("TouchSteerRules")) -- controls v2: floating-origin steer pad

local RaceUI = {}

-- Uploaded custom wood/stone HUD sprite asset IDs (granted to Universe 0)
local ASSET_IDS = {
	WoodPlaque = 96696699374497,
	StoneDPad = 92050151129479,
	StoneTurnBtn = 140120222691020,
	StoneItemBtn = 129086497166378,
}

local function thumbUrl(assetId: number, w: number, h: number): string
	return string.format("rbxthumb://type=Asset&id=%d&w=%d&h=%d", assetId, w, h)
end

local _screenGui: ScreenGui? = nil
local posBadge: Frame? = nil
local posTextLabel: TextLabel? = nil
local lapChip: Frame? = nil
local lapLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local heroLabel: TextLabel? = nil -- lane A: the hero message (FINAL LAP!, trick stamps)
local heroHideClock: number = 0
local posTextCache = ""
-- Last values written by the per-frame HUD step (perf review v21 PF-10): the timer text only changes at 10 Hz (tenths),
-- the lap text once a lap, the button tints on an input or item change, so each is written only when it differs.
local timerTextCache = ""
local timerAlphaCache = -1
local bankTintCache: boolean? = nil
local itemTintCache = ""
local posSizes = { 38, 16, 12 } -- numeral, suffix and "/8" text px (set by the layout pass)

local steerPadBtn: ImageButton? = nil
local _steerPuck: Frame? = nil
local rightZoneFrame: Frame? = nil
local _sharpBankBtn: ImageButton? = nil
local _throttleUpBtn: ImageButton? = nil
-- Controls v2: the car's BRAKE / REV pedal (left of TURN in the right zone) and the stones' captions it shifts right.
local brakeBtn: TextButton? = nil
local brakeCaption: TextLabel? = nil
local brakeTouch: InputObject? = nil
local brakeCaptionCache = ""
local stoneParts: { GuiObject } = {}
local _heldIcon: ImageLabel? = nil -- the ITEM stone's mirror of the held item
local _heldPips: { Frame } = {}

local finishModal: Frame? = nil
local finishTitleLabel: TextLabel? = nil
local finishSubLabel: TextLabel? = nil
local finishOrbBadge: Frame? = nil
local finishOrbText: TextLabel? = nil
local standingsContainer: Frame? = nil

local activeSteerTouch: InputObject? = nil
local steerDraggingMouse = false
local padOriginOffset = Vector2.zero -- controls v2: the floating stick origin, relative to the pad centre (px)
local lastDisplayedRank: number? = nil
local lastDisplayedLap: number? = nil

local ORDINALS = { "1ST", "2ND", "3RD", "4TH", "5TH", "6TH", "7TH", "8TH" }

local function getOrCreateUIScale(guiObj: GuiObject): UIScale
	local existing = guiObj:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1.0
	uiScale.Parent = guiObj
	return uiScale
end

local function pulseGuiObject(guiObj: GuiObject, peakScale: number?, dur: number?)
	local uiScale = getOrCreateUIScale(guiObj)
	uiScale.Scale = peakScale or 1.16
	local tweenInfo = TweenInfo.new(dur or 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(uiScale, tweenInfo, { Scale = 1.0 }):Play()
end

local function tweenGuiScale(guiObj: GuiObject, targetScale: number, dur: number, style: Enum.EasingStyle, dir: Enum.EasingDirection)
	local uiScale = getOrCreateUIScale(guiObj)
	local tweenInfo = TweenInfo.new(dur, style, dir)
	TweenService:Create(uiScale, tweenInfo, { Scale = targetScale }):Play()
end

-- Press, hover and gamepad-selection feedback for one button, every tween under 150 ms (ART_BAR UI bar). Hover only
-- scales (it never sets an input state), so a mouse resting on a touch button changes nothing in flight. The feel and
-- the sound live in client/UiSound (REMARKABLE 4): hover 1.06, press squash 0.92 with a 0.18 s wobble (Rotation 0, -3,
-- 2, 0), Back-out release; the press plays `kind` (tap / confirm / back), gamepad selection plays the marimba scale.
local BUTTON_PRESS_S = 0.07
local BUTTON_RELEASE_S = 0.12
local function wireButtonFeedback(btn: GuiButton, kind: string?)
	UiSound.bind(btn, kind)
end

local function formatTime(seconds: number): string
	local s = math.max(0, seconds)
	local mins = math.floor(s / 60)
	local rem = s - mins * 60
	return string.format("%02d:%04.1f", mins, rem)
end

-- The lap/time chip: m:ss.t ("0:42.6").
local function formatChipTime(seconds: number): string
	local s = math.max(0, seconds)
	local mins = math.floor(s / 60)
	return string.format("%d:%04.1f", mins, s - mins * 60)
end

local function addCorner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function addTextStroke(lbl: TextLabel, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = lbl
end

-- Lane B (top-centre captions): ASSIST: ON, lap times, "X GOT YOU!". Drawn by NotifyKit (queued, one at a time, never over the
-- road ahead or the HUD columns: HudLayoutRules lane B).
-- The phase table's MessageLane row (hub, results and podium F) gates it; `always` is for a caption that must land anyway
-- (the token award toast under the results card).
local lastFtueVisit = ""
function RaceUI.showBanner(msg: string, color: Color3?, duration: number?, always: boolean?)
	-- Thin wrapper over NotifyKit (economy v3 phase 3b): queue, skin and lane B placement live there.
	NotifyKit.toast(msg, {
		kind = "info",
		priority = "normal",
		color = color or Color3.fromRGB(255, 240, 195),
		seconds = duration or 1.6,
		gate = if always == true then nil else "MessageLane",
	})
end

-- Lane A (hero, 30 percent of the screen height, centred): one message at a time, a newer one replaces the older.
-- Outlined text, no panel: the sky behind it is empty by design.
function RaceUI.hero(msg: string, color: Color3?, duration: number?)
	local lbl = heroLabel
	if not lbl or not HudPhase.allows("MessageLane") then
		return
	end
	lbl.Text = msg
	lbl.TextColor3 = color or Color3.fromRGB(255, 240, 195)
	lbl.Visible = true
	heroHideClock = os.clock() + (duration or 1.6)
	LocalPlayer:SetAttribute("HudHeroUp", true) -- RivalBubbles keeps its bubbles out of lane A meanwhile
	pulseGuiObject(lbl, 0.8, 0.22)
end

-- Trick-lane callouts (REMARKABLE items 5-7: STUCK IT!, PERFECT START!, FLOODED!, THREADED!), called through
-- TrickJuice.callout. Slammed into lane A like a rubber stamp: big and tilted, then settling flat.
function RaceUI.stamp(msg: string, color: Color3?, duration: number?)
	local lbl = heroLabel
	if not lbl or not HudPhase.allows("MessageLane") then
		return -- the hero is gated off (hub, results, podium): no tweens on a hidden label
	end
	RaceUI.hero(msg, color, duration or 1.1)
	local sc = getOrCreateUIScale(lbl)
	sc.Scale = 1.5
	TweenService:Create(sc, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	lbl.Rotation = -12
	TweenService:Create(lbl, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
end

-- ASSIST (auto throttle + steering assist): the player's saved switch (Settings "assist", mirrored to FlightController); this
-- adds the lane B readout. One tap anywhere (chip, T key, gear row) lands here.
function RaceUI.setAssist(on: boolean)
	Settings.set(AssistRules.KEY, on)
	Settings.flush()
	FlightController.setAssist(on)
	RaceUI.showBanner(AssistRules.bannerText(on), Color3.fromRGB(250, 242, 222), AssistRules.BANNER_S, true) -- the gear row can flip it in the hub too
end

-- Debug attributes on the HUD ScreenGui for real-client checks (read them from the Studio command bar or a remote probe):
-- HudNavRect "x,y,w,h" (the Roblox nav reserve the layout used), HudSafeInsets "l,t,r,b", HudViewport "w,h", HudScale (S).
local hudGui: ScreenGui? = nil
local function publishHudDebug()
	local g = hudGui
	if not g then
		return
	end
	local snap = HudMetrics.get()
	local n, i = snap.nav, snap.insets
	g:SetAttribute("HudNavRect", string.format("%d,%d,%d,%d", n.x, n.y, n.w, n.h))
	g:SetAttribute("HudSafeInsets", string.format("%d,%d,%d,%d", i.left, i.top, i.right, i.bottom))
	g:SetAttribute("HudViewport", string.format("%d,%d", snap.viewport.X, snap.viewport.Y))
	g:SetAttribute("HudScale", snap.metrics.S)
	-- The in-experience chat window (TextChatService) is CoreGui: the HUD does not move for it (neither TopbarInset nor
	-- GetInsetArea change when it opens), so the rect it reports is only published for real-client checks. "none" when
	-- the place has no chat window configuration or it is disabled.
	local chat = (require(script.Parent.ChatCompatClient) :: any).rectString()
	g:SetAttribute("HudChatRect", chat)
end

-- Responsive layout: every rectangle comes from HudMetrics (shared/HudLayoutRules), one scale S for the whole HUD.
local function updateResponsiveLayout()
	publishHudDebug()
	local cam = workspace.CurrentCamera
	if not cam or not steerPadBtn or not rightZoneFrame or not finishModal or not posBadge or not lapChip then
		return
	end
	local vp = cam.ViewportSize
	local snap = HudMetrics.get()
	local S = snap.metrics.S
	local inset = snap.insets
	local rects = snap.rects
	local TB = HudLayoutRules.TEXT_BASE

	-- A battle has no position readout or lap chip (compute drops both rects): skip them but keep laying out the rest. An
	-- indexing error here used to stop HudExtras.layout, leaving the item slot at its racing place on top of the board.
	local p = rects.position
	if p then
		posBadge.Position = UDim2.fromOffset(p.x, p.y)
		posBadge.Size = UDim2.fromOffset(p.w, p.h)
		posSizes = {
			math.min(math.floor(HudLayoutRules.textSize(TB.positionNumeral, S) * 1.3 + 0.5), math.floor(p.h * 0.9)), -- v21: the biggest HUD numeral

			HudLayoutRules.textSize(TB.positionSuffix, S),
			HudLayoutRules.textSize(TB.positionTotal, S),
		}
		posTextCache = "" -- the readout re-renders with the new sizes on the next frame
	end
	local c = rects.lapChip
	if c then
		lapChip.Position = UDim2.fromOffset(c.x, c.y)
		lapChip.Size = UDim2.fromOffset(c.w, c.h)
		local rowPx = HudLayoutRules.textSize(TB.lapRow, S)
		for _, lbl in { lapLabel, timerLabel } do
			if lbl then
				local lim = lbl:FindFirstChildOfClass("UITextSizeConstraint")
				if lim then
					lim.MaxTextSize = rowPx
				end
			end
		end
	end

	local la = rects.laneA
	if heroLabel then
		heroLabel.Position = UDim2.fromOffset(la.x, la.y)
		heroLabel.Size = UDim2.fromOffset(la.w, la.h)
		local lim = heroLabel:FindFirstChildOfClass("UITextSizeConstraint")
		if lim then
			lim.MaxTextSize = math.floor(vp.Y * (if HudLayoutRules.isPhoneClass(vp.Y) then 0.14 else 0.08))
		end
	end

	-- Thumb controls keep their sizes (as built); they are positioned from the same safe rect whatever the input kind.
	local touchRects = if snap.kind == "touch" then rects else HudLayoutRules.compute(vp.X, vp.Y, inset, snap.nav, "touch")
	local pad, zone = touchRects.steerPad, touchRects.rightZone
	steerPadBtn.Size = UDim2.fromOffset(pad.w, pad.h)
	steerPadBtn.Position = UDim2.fromOffset(pad.x, pad.y + pad.h)
	rightZoneFrame.Size = UDim2.fromOffset(zone.w, zone.h)
	rightZoneFrame.Position = UDim2.fromOffset(zone.x + zone.w, zone.y + zone.h)
	-- Controls v2: [BRAKE][TURN][ITEM]. The stones keep their v27 shares of the zone right of the pedal (P px).
	local br = touchRects.brake
	local P = if br then br.w + HudLayoutRules.BRAKE_GAP else 0
	for _, g in stoneParts do
		local left = g:GetAttribute("StoneLeft") :: number
		local top = g:GetAttribute("StoneTop") :: number
		local h = g:GetAttribute("StoneH") :: number
		g.Position = UDim2.new(left, P * (1 - left), top, 0)
		g.Size = UDim2.new(0.46, -0.46 * P, h, 0)
	end
	if brakeBtn and br then
		brakeBtn.Size = UDim2.new(0, br.w, 1, 0) -- the caption under the pedal is part of the hit area
	end

	-- The results card keeps clear of the left cluster (gear, "?", token chip), which stays up in results.
	local col = rects.leftColumn
	local modalW, modalTop, modalH, modalCx, modalK = ResultsLayoutRules.cardRect(vp.X, vp.Y, inset, if col then col.x + col.w else nil)
	-- Desktop: the contents keep their 420 x 252 design layout and a UIScale grows the card (cardRect's 5th value).
	local modalScale = finishModal:FindFirstChild("CardScale")
	if modalScale and modalScale:IsA("UIScale") then
		modalScale.Scale = modalK
	end
	finishModal.Size = UDim2.fromOffset(modalW / modalK, modalH / modalK)
	finishModal.Position = UDim2.fromOffset(math.floor(modalCx), modalTop)

	HudExtras.layout(snap)
end

-- L30: FLY AGAIN / HUB are votes while the server publishes VoteHumans (2+ humans in a race; TrackDirector).
local function voting(): boolean
	local n = RaceAttr.mine("VoteHumans")
	return type(n) == "number" and n >= 2
end
-- With votes the first HUB press is the vote (the card stays up showing "HUB 1/3"); a second press closes the card.
local hubVoted = false

-- Finish card button row: FLY AGAIN / HUB as before, or FLY AGAIN / BATTLE / HUB when this map's battle is open
-- (BattleAccessRules.cardButton). TrackFlow wires BATTLE (it owns the hub trip and the request).
local function layoutFinishButtons(battleOn: boolean)
	if not finishModal then
		return
	end
	local again = finishModal:FindFirstChild("FlyAgainButton")
	local battle = finishModal:FindFirstChild("BattleFinishButton")
	local hub = finishModal:FindFirstChild("CloseFinishButton")
	if not (again and again:IsA("GuiObject") and battle and battle:IsA("GuiObject") and hub and hub:IsA("GuiObject")) then
		return
	end
	local w = BattleAccessRules.cardWeights(battleOn)
	battle.Visible = battleOn
	if battleOn then
		-- Widths are weight * (card width - 40): 14 px side gutters and 6 px between the three buttons.
		again.Size = UDim2.new(w[1], -40 * w[1], 0, 40)
		battle.Position = UDim2.new(w[1], 20 - 40 * w[1], 1, -10)
		battle.Size = UDim2.new(w[2], -40 * w[2], 0, 40)
		hub.Size = UDim2.new(w[3], -40 * w[3], 0, 40)
	else
		again.Size = UDim2.new(0.64, -24, 0, 40)
		hub.Size = UDim2.new(0.36, -10, 0, 40)
	end
end

-- Results line under the placement: the award the SERVER made (RaceManager.awardFinish), never a client guess.
local function awardLine(data: any, rank: number): string
	local award = if type(data) == "table" and type(data.award) == "table" then data.award else nil
	local parts: { string } = {}
	local mode = RaceAttr.mine("RaceMode")
	if type(data) == "table" and data.dnf == true then
		-- L30: the DNF deadline caught this racer; no result, and (unlike quitting) the Rally Streak stays.
		return "NO RESULT  •  RALLY STREAK KEPT"
	elseif mode == "stormcup" then
		table.insert(parts, if rank == 1 then "STORM CUP CHAMPION!" else "STORM CUP COMPLETE")
	elseif mode == "stormrace" then
		-- Storm race v2: the server's verdict on the dragon (RaceManager FinishInfo.beatDragon).
		table.insert(parts, if type(data) == "table" and data.beatDragon == true then "DRAGON BEATEN!" else "STORM RACE COMPLETE")
	elseif rank == 1 then
		table.insert(parts, "VICTORY!")
	elseif (mode == "boss" or mode == "rematch") and type(data) == "table" and data.beatBoss == true then
		-- L30: a second human who finished ahead of the boss beat it too.
		table.insert(parts, "BOSS BEATEN!")
	else
		table.insert(parts, "RACE COMPLETE")
	end
	if award then
		local tokenResult = award.tokenResult
		if tokenResult == "awarded" then
			table.insert(parts, "+1 SKY TOKEN")
		elseif tokenResult == "noop" then
			table.insert(parts, "TOKEN ALREADY EARNED")
		elseif tokenResult == "queued" then
			table.insert(parts, "TOKEN SAVING...")
		elseif tokenResult == "rejected" then
			table.insert(parts, "TOKEN NOT SAVED")
		end
		if award.bestTimeResult == "awarded" then
			table.insert(parts, "NEW BEST TIME")
		end
	end
	if #parts == 1 then
		local track = if type(data) == "table" and type(data.trackId) == "string" then data.trackId else TrackRegistry.getActiveId()
		table.insert(parts, track)
	end
	return table.concat(parts, "  •  ")
end

-- REMARKABLE Batch 1 items 2 and 3 (the sound is client/Music; the rules are shared/MusicRules):
--   * Final lap: the lap/time chip swings (-7, 6, -3, 0 degrees over 0.9 s), glows red-hot and reads "FINAL LAP!" for 2.5 s,
--     then "LAP 3/3" in red (the hero banner in lane A says it too); it resets when the lap resets.
--   * Last place (of four or more): 0.4 s after the results sign appears, its title plank drops off its right-hand nail
--     (the nail falls away), bounces to 14 degrees on the left nail and swings back to rest at 9; the subtitle says
--     "NEXT TIME!". The title is a label, so no button's hit area moves with it.
local MusicRules = require(Shared:WaitForChild("MusicRules"))
local LAP_CREAM = Color3.fromRGB(250, 242, 222)
local CHIP_WOOD = Color3.fromRGB(96, 60, 34) -- principle 7: the small wood chip behind a numeral
local CHIP_SAND = Color3.fromRGB(188, 168, 142)
local LAP_RED_CHIP = Color3.fromRGB(176, 52, 34)
local LAP_RED_GLOW = Color3.fromRGB(232, 100, 58)
local LAP_RED_TEXT = Color3.fromRGB(255, 78, 56)
local LAP_FLASH_TEXT = Color3.fromRGB(255, 226, 95)
local CHIP_IDLE_ALPHA = 0.15 -- v21: 0.35 let the busy track through the lap and time chip
local POS_GOLD = Color3.fromRGB(255, 214, 90) -- first place
local LapChipRules = require(Shared:WaitForChild("LapChipRules")) -- the chip text and FINAL LAP! state (V9 stale-label fix)
local lapState = LapChipRules.new()
local lapGlowTween: Tween? = nil

-- The chip back to wood and cream (the final-lap state ended: a new race, or a lap below the last).
local function lapChipReset()
	if lapGlowTween then
		lapGlowTween:Cancel()
		lapGlowTween = nil
	end
	if lapChip then
		lapChip.BackgroundColor3 = CHIP_WOOD
		lapChip.BackgroundTransparency = CHIP_IDLE_ALPHA
		lapChip.Rotation = 0
	end
	if lapLabel then
		lapLabel.TextColor3 = LAP_CREAM
	end
end

-- LapChipRules.step said "final": the swing, the red-hot glow and the hero banner.
local function lapChipFinal()
	local chip = lapChip
	if not chip then
		return
	end
	chip.BackgroundColor3 = LAP_RED_CHIP
	chip.BackgroundTransparency = 0.1
	if lapLabel then
		lapLabel.TextColor3 = LAP_FLASH_TEXT
	end
	pulseGuiObject(chip, 1.32, 0.3)
	RaceUI.hero(LapChipRules.FINAL_TEXT, LAP_RED_TEXT, 1.8) -- lane A (HudLayoutRules): the hero banner
	-- Red-hot: the chip breathes between two reds until the lap resets (one looping tween, nothing per frame).
	local glow = TweenService:Create(chip, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundColor3 = LAP_RED_GLOW })
	lapGlowTween = glow
	glow:Play()
	task.spawn(function()
		for _, deg in { -7, 6, -3, 0 } do
			if not lapState.finalOn then
				return
			end
			local tw = TweenService:Create(chip, TweenInfo.new(0.225, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Rotation = deg })
			tw:Play()
			tw.Completed:Wait()
		end
	end)
	task.delay(LapChipRules.FINAL_FLASH_S, function()
		if lapState.finalOn and lapLabel then
			lapLabel.TextColor3 = LAP_RED_TEXT
		end
	end)
end

local signToken = 0
local titleBase: UDim2? = nil
local nailHeld: Frame? = nil
local nailDrop: Frame? = nil

local function nail(name: string): Frame
	local n = Instance.new("Frame")
	n.Name = name
	n.Size = UDim2.fromOffset(7, 7)
	n.AnchorPoint = Vector2.new(0.5, 0.5)
	n.BackgroundColor3 = Color3.fromRGB(196, 160, 96)
	n.BorderSizePixel = 0
	n.ZIndex = 4
	n.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = n
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(36, 20, 10)
	st.Thickness = 1.5
	st.Parent = n
	n.Parent = finishModal
	return n
end

-- Called at the end of populateFinishModal.
local function resultsSign(rank: number, total: any)
	signToken += 1
	local token = signToken
	local title = finishTitleLabel
	if not title or not finishModal then
		return
	end
	titleBase = titleBase or title.Position
	local base = titleBase :: UDim2
	title.Rotation = 0
	title.Position = base
	if nailHeld then
		nailHeld.Visible = false
	end
	if nailDrop then
		nailDrop.Visible = false
	end
	if not MusicRules.isLastPlace(rank, total) then
		return
	end
	if finishSubLabel then
		local tt = string.match(finishSubLabel.Text, "^(TOTAL [^ ]+)")
		finishSubLabel.Text = if tt then "NEXT TIME!   •   " .. tt else "NEXT TIME!"
	end
	nailHeld = nailHeld or nail("SignNailHeld")
	nailDrop = nailDrop or nail("SignNailDrop")
	task.delay(0.4, function()
		if token ~= signToken or not title.Parent then
			return
		end
		-- Pivot on the left nail at the start of the text; the right nail lets go.
		local w = title.AbsoluteSize.X
		local tb = math.min(title.TextBounds.X, w)
		local px, py = w / 2 - tb / 2 - 4, 3
		local dx, dy = w / 2 - px, title.AbsoluteSize.Y / 2 - py
		local held, drop = nailHeld :: Frame, nailDrop :: Frame
		local ox, oy = base.X.Offset, base.Y.Offset
		held.Position = UDim2.fromOffset(ox + px, oy + py)
		held.Visible = true
		drop.Position = UDim2.fromOffset(ox + w / 2 + tb / 2 + 4, oy + py)
		drop.Rotation = 0
		drop.BackgroundTransparency = 0
		drop.Visible = true
		local fall = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(drop, fall, {
			Position = UDim2.fromOffset(ox + w / 2 + tb / 2 + 18, oy + py + 70),
			Rotation = 200,
			BackgroundTransparency = 1,
		}):Play()
		task.delay(0.6, function()
			drop.Visible = false
		end)
		local t0 = os.clock()
		local conn: RBXScriptConnection? = nil
		conn = RunService.RenderStepped:Connect(function()
			local t = os.clock() - t0
			local deg: number
			if t < 0.5 then
				deg = 9 * TweenService:GetValue(t / 0.5, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
			else
				-- Settle from 9 to rest at 6 with a damped swing (a 9 degree rest dropped the far end of the title onto the subtitle).
				deg = 6 + 3 * math.cos(2 * math.pi * 1.4 * (t - 0.5)) * math.exp(-(t - 0.5) * 2.4)
			end
			local done = t > 2.6 or token ~= signToken or not title.Parent
			if done then
				deg = if token == signToken then 6 else 0
				if conn then
					conn:Disconnect()
				end
				if token ~= signToken then
					return
				end
			end
			local r = math.rad(deg)
			local c, sn = math.cos(r), math.sin(r)
			title.Rotation = deg
			title.Position = UDim2.fromOffset(ox + (dx * c - dy * sn) - dx, oy + (dx * sn + dy * c) - dy)
		end)
	end)
end

local function populateFinishModal(data: any)
	if not finishModal or not finishTitleLabel or not finishSubLabel or not finishOrbBadge or not finishOrbText or not standingsContainer then
		return
	end

	local rank = (type(data) == "table" and type(data.rank) == "number") and data.rank or 1
	local totalTime = (type(data) == "table" and type(data.totalTime) == "number") and data.totalTime or 0
	local bestLap = (type(data) == "table" and type(data.bestLap) == "number") and data.bestLap or 0

	local ord = ORDINALS[rank] or (tostring(rank) .. "TH")
	-- Storm Cup (server/StormCup): the cup's own title, and no FLY AGAIN (the server refuses a cup replay).
	-- Storm race v2 ("stormrace") gets the same: its own title and no FLY AGAIN.
	local stormCup = RaceAttr.mine("RaceMode") == "stormcup" or RaceAttr.mine("RaceMode") == "stormrace"
	local stormTitle = if RaceAttr.mine("RaceMode") == "stormrace" then "STORM RACE  " else "STORM CUP  "
	-- L30: the DNF card (RaceDNF) reuses this card: no placement, no time.
	local dnf = type(data) == "table" and data.dnf == true
	hubVoted = false
	finishTitleLabel.Text = if dnf then "DNF - TIME'S UP" elseif stormCup then stormTitle .. ord .. "!" else ord .. " PLACE!"
	local flyAgain = finishModal:FindFirstChild("FlyAgainButton")
	if flyAgain and flyAgain:IsA("GuiObject") then
		flyAgain.Visible = not stormCup
	end
	layoutFinishButtons(
		not stormCup
			and BattleAccessRules.cardButton(
				RaceAttr.mine("RaceMode"),
				TrackRegistry.getActiveId(),
				BattleAccessRules.decode(LocalPlayer:GetAttribute(BattleAccessRules.ATTR))
			)
	)
	finishTitleLabel.TextColor3 = if rank == 1 and not dnf then Color3.fromRGB(255, 226, 95) else Color3.fromRGB(235, 220, 195)
	finishSubLabel.Text = if dnf
		then "Results only count when you cross the line"
		else string.format("TOTAL %s   •   BEST LAP %s", formatTime(totalTime), formatTime(bestLap))

	if rank == 1 and not dnf then
		finishOrbBadge.BackgroundColor3 = Color3.fromRGB(88, 128, 56)
	else
		finishOrbBadge.BackgroundColor3 = Color3.fromRGB(92, 68, 48)
	end
	finishOrbText.Text = awardLine(data, rank)

	for _, child in ipairs(standingsContainer:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local function racerColorFor(name: string): Color3?
		local planes = workspace:FindFirstChild("Planes")
		if not planes then
			return nil
		end
		for _, m in planes:GetChildren() do
			if m:GetAttribute("OwnerName") == name or m:GetAttribute("BotName") == name then
				local c = m:GetAttribute("RacerColor")
				return if typeof(c) == "Color3" then c else nil
			end
		end
		return nil
	end

	local standings = if type(data) == "table" and type(data.standings) == "table" then data.standings else {}
	for i, row in ipairs(standings) do
		if i <= PlaneConfig.AI_FIELD_SIZE then
			local rowFrame = Instance.new("Frame")
			rowFrame.Name = "Row_" .. tostring(i)
			rowFrame.Size = UDim2.new(1, 0, 0, 25)
			rowFrame.BackgroundColor3 = if row.isPlayer then Color3.fromRGB(132, 86, 46) else Color3.fromRGB(82, 56, 36)
			rowFrame.BorderSizePixel = 0
			rowFrame.LayoutOrder = i
			rowFrame.Parent = standingsContainer
			addCorner(rowFrame, 6)
			addStroke(rowFrame, Color3.fromRGB(185, 138, 82), 1)

			-- Racer colour swatch (RacerColor on the vehicle, matched by account name / bot name): a 5 px bar at the row's edge.
			local swatchColor = racerColorFor(tostring(row.name))
			if swatchColor then
				local sw = Instance.new("Frame")
				sw.Name = "RacerSwatch"
				sw.Position = UDim2.fromOffset(4, 4)
				sw.Size = UDim2.new(0, 5, 1, -8)
				sw.BackgroundColor3 = swatchColor
				sw.BorderSizePixel = 0
				sw.Parent = rowFrame
				addCorner(sw, 2)
			end

			local rText = Instance.new("TextLabel")
			rText.Size = UDim2.new(0.65, -16, 1, 0)
			rText.Position = UDim2.fromOffset(16, 0)
			rText.BackgroundTransparency = 1
			rText.Font = Enum.Font.GothamBlack
			rText.TextSize = 12
			rText.TextTruncate = Enum.TextTruncate.AtEnd
			rText.TextXAlignment = Enum.TextXAlignment.Left
			rText.TextColor3 = if row.isPlayer then Color3.fromRGB(255, 240, 165) else Color3.fromRGB(240, 232, 215)
			rText.Text = string.format("%s  %s", ORDINALS[row.rank] or tostring(row.rank), tostring(row.name))
			rText.Parent = rowFrame

			local tText = Instance.new("TextLabel")
			tText.Size = UDim2.new(0.35, -10, 1, 0)
			tText.Position = UDim2.new(0.65, 0, 0, 0)
			tText.BackgroundTransparency = 1
			tText.Font = Enum.Font.GothamBold
			tText.TextSize = 11
			tText.TextXAlignment = Enum.TextXAlignment.Right
			tText.TextColor3 = Color3.fromRGB(248, 224, 175)
			tText.Text = if row.finished and row.finishTime > 0 then formatTime(row.finishTime) else ("LAP " .. tostring(row.lap) .. "/3")
			tText.Parent = rowFrame
		end
	end

	finishModal.Visible = true
	pulseGuiObject(finishModal, 0.85, 0.26)
	if not dnf then
		resultsSign(rank, if #standings > 0 then #standings else RaceAttr.mine("TotalRacers")) -- REMARKABLE 2: last-place sign drop
		require(script.Parent.StyleChain).decorateResults(finishModal) -- REMARKABLE 17: best style chain sticker
	end
	require(script.Parent.RivalBubbles).decorateResults(standingsContainer, standings) -- REMARKABLE 19: rival's row pill
	-- L81: on a gamepad the results screen must be usable without touch or mouse; select FLY AGAIN. L30: not while
	-- other humans still race (ButtonA is also the throttle, and a stray press would be a vote): the return timer's start
	-- selects it then (RaceUI.init, ReturnToHubAt).
	local othersRacing = voting() and type(RaceAttr.mine("ReturnToHubAt")) ~= "number"
	if LocalPlayer:GetAttribute("InputMode") == "Gamepad" and not othersRacing then
		local again = finishModal:FindFirstChild(if stormCup then "CloseFinishButton" else "FlyAgainButton")
		if again and again:IsA("GuiObject") then
			UiSound.hush() -- code moved the selection: no marimba note on top of the finish jingle
			GuiService.SelectedObject = again
		end
	end
end

function RaceUI.init()
	-- Enforce LANDSCAPE ONLY on mobile per owner ruling
	pcall(function()
		StarterGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
	local pGuiObj = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pGuiObj then
		pcall(function()
			pGuiObj.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
		end)
	end

	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end
	pcall(function()
		playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)

	local existing = playerGui:FindFirstChild("SkyRallyHUD")
	if existing then
		existing:Destroy()
	end

	pcall(function()
		UserInputService.ModalEnabled = true
	end)
	-- Roblox's default thumbstick GUI stays off: once when it appears and again whenever something re-enables it (this
	-- used to be a FindFirstChild every frame in the HUD step; perf review v21 PF-10).
	local function suppressDefaultTouchGui(inst: Instance)
		if inst.Name == "TouchGui" and inst:IsA("ScreenGui") then
			local tg = inst :: ScreenGui
			tg.Enabled = false
			tg:GetPropertyChangedSignal("Enabled"):Connect(function()
				if tg.Enabled then
					tg.Enabled = false
				end
			end)
		end
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		suppressDefaultTouchGui(child)
	end
	playerGui.ChildAdded:Connect(suppressDefaultTouchGui)

	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyHUD"
	hudGui = sg
	sg.IgnoreGuiInset = true
	-- Full-bleed on purpose: flashes and fades reach the screen's edges. The frames themselves are placed inside
	-- the safe rect (and under the Roblox nav) by updateResponsiveLayout and HudExtras.layout from HudMetrics (L28, L82).
	pcall(function()
		sg.ScreenInsets = Enum.ScreenInsets.None
		sg.ClipToDeviceSafeArea = false
	end)
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	_screenGui = sg

	local creamText = Color3.fromRGB(250, 242, 222)
	local darkInk = Color3.fromRGB(36, 20, 10)
	local stoneRim = Color3.fromRGB(188, 168, 142)

	-- Race HUD v2 (docs/design/HUD_LAYOUT.md principle 7): bold outlined numerals on SMALL rounded wood chips, no plank art.
	-- Sizes and positions are set by updateResponsiveLayout from HudMetrics; the values below are placeholders.
	local function chip(f: Frame, transparency: number)
		f.BackgroundColor3 = CHIP_WOOD
		f.BackgroundTransparency = transparency
		f.BorderSizePixel = 0
		addCorner(f, 10)
		addStroke(f, CHIP_SAND, 2)
	end
	local function numeralLabel(parent: Instance, name: string, align: Enum.TextXAlignment, stroke: number): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBlack
		l.TextColor3 = creamText
		l.TextXAlignment = align
		l.Active = false
		l.Parent = parent
		addTextStroke(l, darkInk, stroke)
		return l
	end

	-- 1. Top-right: race position, "3RD/8" (numeral, ordinal suffix, field size). Display only; ASSIST lives in the gear panel.
	local posFrame = Instance.new("Frame")
	posFrame.Name = "PositionBadge"
	posFrame.Position = UDim2.fromOffset(700, 6)
	posFrame.Size = UDim2.fromOffset(90, 50)
	chip(posFrame, 0.2)
	posFrame.Active = false
	posFrame.Parent = sg
	posBadge = posFrame

	local pLbl = numeralLabel(posFrame, "PositionText", Enum.TextXAlignment.Right, 3)
	pLbl.Position = UDim2.new(0, 0, 0, 0)
	pLbl.Size = UDim2.new(1, -8, 1, 0)
	pLbl.RichText = true
	pLbl.TextSize = 38
	pLbl.Text = "1/4"
	posTextLabel = pLbl

	-- 2. Below it: the lap / time chip ("LAP 2/3" over "0:42.6"); FINAL LAP turns it red-hot.
	local lapFrame = Instance.new("Frame")
	lapFrame.Name = "LapTimeChip"
	lapFrame.Position = UDim2.fromOffset(669, 60)
	lapFrame.Size = UDim2.fromOffset(114, 46)
	chip(lapFrame, CHIP_IDLE_ALPHA)
	lapFrame.Active = false
	lapFrame.Parent = sg
	lapChip = lapFrame

	local function row(name: string, y: number, text: string): TextLabel
		local l = numeralLabel(lapFrame, name, Enum.TextXAlignment.Right, 2.2)
		l.Position = UDim2.fromScale(0, y)
		l.Size = UDim2.new(1, -10, 0.5, 0)
		l.TextScaled = true
		l.Text = text
		local lim = Instance.new("UITextSizeConstraint")
		lim.MinTextSize = HudLayoutRules.MIN_TEXT
		lim.MaxTextSize = 17
		lim.Parent = l
		return l
	end
	lapLabel = row("LapCounter", 0.02, "LAP 1/3")
	timerLabel = row("RaceTimer", 0.5, "0:00.0")

	-- Lane A: the hero message (FINAL LAP!, trick stamps), 30 percent down the screen, no panel.
	local hero = numeralLabel(sg, "HeroBanner", Enum.TextXAlignment.Center, 3)
	hero.Position = UDim2.fromOffset(250, 80)
	hero.Size = UDim2.fromOffset(340, 70)
	hero.TextScaled = true
	hero.Visible = false
	hero.ZIndex = 3
	local hLim = Instance.new("UITextSizeConstraint")
	hLim.MinTextSize = 14
	hLim.MaxTextSize = 54
	hLim.Parent = hero
	heroLabel = hero

	-- 4. Bottom-Left Carved Stone D-Pad / Thumbstick ("LeftSteerZone") using uploaded hud_stone_dpad.png sprite
	local sPad = Instance.new("ImageButton")
	sPad.Name = "LeftSteerZone"
	sPad.AnchorPoint = Vector2.new(0, 1)
	sPad.Position = UDim2.new(0, 18, 1, -18)
	sPad.Size = UDim2.fromOffset(138, 138)
	sPad.BackgroundTransparency = 1
	sPad.Image = thumbUrl(ASSET_IDS.StoneDPad, 420, 420)
	sPad.ImageTransparency = 0.28
	sPad.AutoButtonColor = false
	sPad.Parent = sg
	steerPadBtn = sPad

	local puck = Instance.new("Frame")
	puck.Name = "SteerPuck"
	puck.AnchorPoint = Vector2.new(0.5, 0.5)
	puck.Position = UDim2.fromScale(0.5, 0.5)
	puck.Size = UDim2.fromOffset(38, 38)
	puck.BackgroundColor3 = Color3.fromRGB(182, 164, 144)
	puck.BackgroundTransparency = 0.18
	puck.Parent = sPad
	addCorner(puck, 19)
	addStroke(puck, creamText, 2)
	_steerPuck = puck

	-- 5. Bottom-Right Carved Stone Action Buttons ("TURN" & "ITEM") using uploaded stone button sprites
	local rZone = Instance.new("Frame")
	rZone.Name = "RightThrottleZone"
	rZone.AnchorPoint = Vector2.new(1, 1)
	rZone.Position = UDim2.new(1, -18, 1, -18)
	rZone.Size = UDim2.fromOffset(172, 104)
	rZone.BackgroundTransparency = 1
	rZone.Parent = sg
	rightZoneFrame = rZone

	-- Left Button: "TURN" (Sharp Bank) with carved stone/wood + curved cream arrow sprite and crisp caption below
	local bankBtn = Instance.new("ImageButton")
	bankBtn.Name = "SharpBankButton"
	bankBtn.Position = UDim2.new(0, 0, 0, 0)
	bankBtn.Size = UDim2.new(0.46, 0, 0.78, 0)
	bankBtn.BackgroundTransparency = 1
	bankBtn.Image = thumbUrl(ASSET_IDS.StoneTurnBtn, 420, 420)
	bankBtn.AutoButtonColor = true
	bankBtn.Parent = rZone
	_sharpBankBtn = bankBtn

	local turnLbl = Instance.new("TextLabel")
	turnLbl.Name = "TurnLabel"
	turnLbl.Position = UDim2.new(0, 0, 0.79, 0)
	turnLbl.Size = UDim2.new(0.46, 0, 0.21, 0)
	turnLbl.BackgroundTransparency = 1
	turnLbl.Font = Enum.Font.GothamBlack
	turnLbl.TextScaled = true
	turnLbl.TextColor3 = creamText
	turnLbl.Text = "TURN"
	turnLbl.Parent = rZone
	addTextStroke(turnLbl, darkInk, 2.0)
	local turnSizeConstraint = Instance.new("UITextSizeConstraint")
	turnSizeConstraint.MinTextSize = 11
	turnSizeConstraint.MaxTextSize = 22
	turnSizeConstraint.Parent = turnLbl

	-- Right Button: "ITEM" fires the held item (L07). The name stays "ThrottleUpButton": the asset ledger and the
	-- published-client probe address the sprite by this path (L67/L68). Throttle stays automatic (ASSIST: gear panel, AUTO pill).
	local itemBtn = Instance.new("ImageButton")
	itemBtn.Name = "ThrottleUpButton"
	itemBtn.Position = UDim2.new(0.54, 0, 0, 0)
	itemBtn.Size = UDim2.new(0.46, 0, 0.78, 0)
	itemBtn.BackgroundTransparency = 1
	itemBtn.Image = thumbUrl(ASSET_IDS.StoneItemBtn, 420, 420)
	itemBtn.AutoButtonColor = true
	itemBtn.Parent = rZone
	_throttleUpBtn = itemBtn

	-- HUD v2: the stone mirrors the held item (icon and level pips) so the right thumb sees what it will fire; the top-left
	-- item frame is display-only on touch.
	local heldIcon = Instance.new("ImageLabel")
	heldIcon.Name = "HeldIcon"
	heldIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	heldIcon.Position = UDim2.fromScale(0.5, 0.46)
	heldIcon.Size = UDim2.fromScale(0.5, 0.5)
	heldIcon.BackgroundTransparency = 1
	heldIcon.ScaleType = Enum.ScaleType.Fit
	heldIcon.Active = false
	heldIcon.Visible = false
	heldIcon.ZIndex = 2
	heldIcon.Parent = itemBtn
	_heldIcon = heldIcon
	local heldPipRow = Instance.new("Frame")
	heldPipRow.Name = "HeldPips"
	heldPipRow.AnchorPoint = Vector2.new(0.5, 1)
	heldPipRow.Position = UDim2.fromScale(0.5, 0.9)
	heldPipRow.Size = UDim2.fromScale(0.6, 0.1)
	heldPipRow.BackgroundTransparency = 1
	heldPipRow.Active = false
	heldPipRow.ZIndex = 2
	heldPipRow.Parent = itemBtn
	local heldPipList = Instance.new("UIListLayout")
	heldPipList.FillDirection = Enum.FillDirection.Horizontal
	heldPipList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	heldPipList.VerticalAlignment = Enum.VerticalAlignment.Center
	heldPipList.Padding = UDim.new(0, 3)
	heldPipList.Parent = heldPipRow
	for i = 1, ItemRules.MAX_LEVEL do
		local pip = Instance.new("Frame")
		pip.Name = "HeldPip" .. i
		pip.LayoutOrder = i
		pip.Size = UDim2.fromOffset(7, 7)
		pip.BorderSizePixel = 0
		pip.BackgroundColor3 = Color3.fromRGB(255, 214, 90)
		pip.Visible = false
		pip.Parent = heldPipRow
		addCorner(pip, 4)
		addStroke(pip, darkInk, 1)
		table.insert(_heldPips, pip)
	end

	local itemLbl = Instance.new("TextLabel")
	itemLbl.Name = "ItemLabel"
	itemLbl.Position = UDim2.new(0.54, 0, 0.79, 0)
	itemLbl.Size = UDim2.new(0.46, 0, 0.21, 0)
	itemLbl.BackgroundTransparency = 1
	itemLbl.Font = Enum.Font.GothamBlack
	itemLbl.TextScaled = true
	itemLbl.TextColor3 = creamText
	itemLbl.Text = "ITEM"
	itemLbl.Parent = rZone
	addTextStroke(itemLbl, darkInk, 2.0)
	local itemSizeConstraint = Instance.new("UITextSizeConstraint")
	itemSizeConstraint.MinTextSize = 11
	itemSizeConstraint.MaxTextSize = 22
	itemSizeConstraint.Parent = itemLbl

	-- Controls v2 (docs/research/MOBILE_CONTROLS_AND_REVERSE.md): the stones sit right of the BRAKE pedal; layout places them.
	local function stone(g: GuiObject, left: number, top: number, h: number)
		g:SetAttribute("StoneLeft", left)
		g:SetAttribute("StoneTop", top)
		g:SetAttribute("StoneH", h)
		table.insert(stoneParts, g)
	end
	stone(bankBtn, 0, 0, 0.78)
	stone(turnLbl, 0, 0.79, 0.21)
	stone(itemBtn, 0.54, 0, 0.78)
	stone(itemLbl, 0.54, 0.79, 0.21)

	-- BRAKE / REV pedal (cars): hold to brake; stopped, keep holding and the car backs up (shared/ReverseRules). Writes
	-- FlightController.mobileThrottle = -1, which CarController already sums into its throttle. Planes hide it.
	local pedal = Instance.new("TextButton")
	pedal.Name = "BrakeButton"
	pedal.Text = ""
	pedal.AutoButtonColor = false
	pedal.BackgroundTransparency = 1
	pedal.Position = UDim2.fromScale(0, 0)
	pedal.Size = UDim2.new(0, HudLayoutRules.BRAKE_MIN, 1, 0)
	pedal.Visible = false
	pedal.Parent = rZone
	brakeBtn = pedal
	local plate = Instance.new("Frame")
	plate.Name = "Pedal"
	plate.Active = false
	plate.Size = UDim2.fromScale(1, 0.78)
	plate.BackgroundColor3 = Color3.fromRGB(104, 90, 78)
	plate.BackgroundTransparency = 0.12
	plate.Parent = pedal
	addCorner(plate, 12)
	addStroke(plate, creamText, 2)
	for i = 1, 3 do -- pedal ridges
		local ridge = Instance.new("Frame")
		ridge.Name = "Ridge" .. i
		ridge.Active = false
		ridge.AnchorPoint = Vector2.new(0.5, 0.5)
		ridge.Position = UDim2.fromScale(0.5, 0.25 + 0.25 * (i - 1))
		ridge.Size = UDim2.new(0.62, 0, 0, 4)
		ridge.BorderSizePixel = 0
		ridge.BackgroundColor3 = creamText
		ridge.BackgroundTransparency = 0.35
		ridge.Parent = plate
		addCorner(ridge, 2)
	end
	local pedalLbl = Instance.new("TextLabel")
	pedalLbl.Name = "BrakeLabel"
	pedalLbl.Active = false
	pedalLbl.Position = UDim2.fromScale(0, 0.79)
	pedalLbl.Size = UDim2.fromScale(1, 0.21)
	pedalLbl.BackgroundTransparency = 1
	pedalLbl.Font = Enum.Font.GothamBlack
	pedalLbl.TextScaled = true
	pedalLbl.TextColor3 = creamText
	pedalLbl.Text = "BRAKE"
	pedalLbl.Parent = pedal
	addTextStroke(pedalLbl, darkInk, 2.0)
	local pedalSize = Instance.new("UITextSizeConstraint")
	pedalSize.MinTextSize = 11
	pedalSize.MaxTextSize = 22
	pedalSize.Parent = pedalLbl
	brakeCaption = pedalLbl

	-- 6. Finish Position Screen (Wooden & Stone Adventure Theme, hidden until Lap 3 completion)
	local fModal = Instance.new("Frame")
	fModal.Name = "FinishPositionScreen"
	fModal.AnchorPoint = Vector2.new(0.5, 0)
	fModal.Position = UDim2.new(0.5, 0, 0, 58)
	fModal.Size = UDim2.fromOffset(360, 236)
	fModal.BackgroundColor3 = Color3.fromRGB(64, 42, 26)
	fModal.BackgroundTransparency = 0 -- solid card: reads on any scene, however dark (finish stage lighting)
	fModal.Visible = false
	fModal.Parent = sg
	addCorner(fModal, 14)
	addStroke(fModal, Color3.fromRGB(224, 172, 76), 3)
	finishModal = fModal
	local fScale = Instance.new("UIScale")
	fScale.Name = "CardScale"
	fScale.Parent = fModal

	local fTitle = Instance.new("TextLabel")
	fTitle.Name = "FinishPlacementTitle"
	fTitle.Position = UDim2.fromOffset(12, 3)
	fTitle.Size = UDim2.new(1, -24, 0, 26)
	fTitle.BackgroundTransparency = 1
	fTitle.Font = Enum.Font.GothamBlack
	fTitle.TextSize = 21
	fTitle.TextColor3 = Color3.fromRGB(255, 226, 95)
	fTitle.Text = "1ST PLACE!"
	fTitle.Parent = fModal
	addTextStroke(fTitle, darkInk, 2.0)
	finishTitleLabel = fTitle

	local fSub = Instance.new("TextLabel")
	fSub.Name = "FinishTimeSummary"
	fSub.Position = UDim2.fromOffset(12, 33)
	fSub.Size = UDim2.new(1, -24, 0, 16)
	fSub.BackgroundTransparency = 1
	fSub.Font = Enum.Font.GothamBold
	fSub.TextSize = 12
	fSub.TextColor3 = creamText
	fSub.Text = "TOTAL 02:15.0   •   BEST LAP 00:44.2"
	fSub.Parent = fModal
	finishSubLabel = fSub

	local fOrb = Instance.new("Frame")
	fOrb.Name = "OrbRewardBanner"
	fOrb.Position = UDim2.fromOffset(14, 50)
	fOrb.Size = UDim2.new(1, -28, 0, 22)
	fOrb.BackgroundColor3 = Color3.fromRGB(88, 128, 56)
	fOrb.Parent = fModal
	addCorner(fOrb, 8)
	finishOrbBadge = fOrb

	local fOrbTxt = Instance.new("TextLabel")
	fOrbTxt.Name = "OrbRewardText"
	fOrbTxt.Size = UDim2.fromScale(1, 1)
	fOrbTxt.BackgroundTransparency = 1
	fOrbTxt.Font = Enum.Font.GothamBlack
	fOrbTxt.TextSize = 11
	-- The award line can carry three parts ("VICTORY! • +1 SKY TOKEN • NEW BEST TIME"); scale down rather than clip
	-- on a 300 px modal at 740x360.
	fOrbTxt.TextScaled = true
	local orbTextLimit = Instance.new("UITextSizeConstraint")
	orbTextLimit.MinTextSize = 9
	orbTextLimit.MaxTextSize = 13
	orbTextLimit.Parent = fOrbTxt
	fOrbTxt.TextColor3 = Color3.fromRGB(255, 248, 195)
	local circuit = TrackInfo.circuitName(TrackRegistry.getActiveId())
	fOrbTxt.Text = if circuit then "VICTORY! — " .. circuit else "VICTORY!"
	fOrbTxt.Parent = fOrb
	finishOrbText = fOrbTxt

	local stCont = Instance.new("Frame")
	stCont.Name = "StandingsList"
	stCont.Position = UDim2.fromOffset(14, 76)
	stCont.Size = UDim2.new(1, -28, 0, 108)
	stCont.BackgroundTransparency = 1
	stCont.Parent = fModal
	standingsContainer = stCont

	-- Eight entrants (L08): a 2 x 4 grid filled column-first keeps every row, the player's included, on screen at 740x360.
	local uiGrid = Instance.new("UIGridLayout")
	uiGrid.CellPadding = UDim2.fromOffset(6, 3)
	uiGrid.CellSize = UDim2.new(0.5, -3, 0, 24)
	uiGrid.FillDirection = Enum.FillDirection.Vertical
	uiGrid.FillDirectionMaxCells = 4
	uiGrid.SortOrder = Enum.SortOrder.LayoutOrder
	uiGrid.Parent = stCont

	local playAgainBtn = Instance.new("TextButton")
	playAgainBtn.Name = "FlyAgainButton"
	playAgainBtn.AnchorPoint = Vector2.new(0, 1)
	playAgainBtn.Position = UDim2.new(0, 14, 1, -10)
	playAgainBtn.Size = UDim2.new(0.64, -24, 0, 40) -- 6 px between FLY AGAIN and HUB
	playAgainBtn.BackgroundColor3 = Color3.fromRGB(78, 148, 58)
	playAgainBtn.Font = Enum.Font.GothamBlack
	playAgainBtn.TextSize = 15
	playAgainBtn.TextColor3 = creamText
	playAgainBtn.Text = "FLY AGAIN"
	playAgainBtn.AutoButtonColor = true
	playAgainBtn.Parent = fModal
	addCorner(playAgainBtn, 8)
	addStroke(playAgainBtn, Color3.fromRGB(168, 232, 128), 2)

	local battleBtn = Instance.new("TextButton")
	battleBtn.Name = "BattleFinishButton"
	battleBtn.AnchorPoint = Vector2.new(0, 1)
	battleBtn.Position = UDim2.new(0.36, -14, 1, -10)
	battleBtn.Size = UDim2.new(0.32, -13, 0, 40)
	battleBtn.BackgroundColor3 = Color3.fromRGB(196, 120, 24)
	battleBtn.Font = Enum.Font.GothamBlack
	battleBtn.TextSize = 15
	battleBtn.TextColor3 = creamText
	battleBtn.Text = "BATTLE"
	battleBtn.AutoButtonColor = true
	battleBtn.Visible = false
	battleBtn.Parent = fModal
	addCorner(battleBtn, 8)
	addStroke(battleBtn, Color3.fromRGB(255, 200, 120), 2)

	local closeModalBtn = Instance.new("TextButton")
	closeModalBtn.Name = "CloseFinishButton"
	closeModalBtn.AnchorPoint = Vector2.new(1, 1)
	closeModalBtn.Position = UDim2.new(1, -14, 1, -10)
	closeModalBtn.Size = UDim2.new(0.36, -10, 0, 40)
	closeModalBtn.BackgroundColor3 = Color3.fromRGB(108, 76, 52)
	closeModalBtn.Font = Enum.Font.GothamBlack
	closeModalBtn.TextSize = 14
	closeModalBtn.TextColor3 = creamText
	closeModalBtn.Text = "CLOSE"
	closeModalBtn.AutoButtonColor = true
	closeModalBtn.Parent = fModal
	addCorner(closeModalBtn, 8)
	addStroke(closeModalBtn, stoneRim, 1.5)

	closeModalBtn.Activated:Connect(function()
		-- L30: with 2+ humans this is a HUB vote (TrackFlow fires it); the card stays up to show the count, and a
		-- second press closes it.
		if voting() and not hubVoted then
			hubVoted = true
			return
		end
		fModal.Visible = false
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(fModal) then
			GuiService.SelectedObject = nil
		end
	end)
	wireButtonFeedback(playAgainBtn, "confirm")
	wireButtonFeedback(battleBtn, "confirm")
	wireButtonFeedback(closeModalBtn, "back")

	-- Wire Interactive Buttons (preserving full flight mechanics + squash/stretch press juice)
	bankBtn.InputBegan:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 then
			FlightController.mobileSharpBank = true
			UiSound.play("stone", nil, 0.6) -- REMARKABLE 4: a quiet carved-stone thunk under the thumb
			bankBtn.ImageColor3 = Color3.fromRGB(255, 230, 175)
			tweenGuiScale(bankBtn, 0.90, BUTTON_PRESS_S, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end)
	bankBtn.InputEnded:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 then
			FlightController.mobileSharpBank = false
			bankBtn.ImageColor3 = Color3.fromRGB(255, 255, 255)
			tweenGuiScale(bankBtn, 1.0, BUTTON_RELEASE_S, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)

	itemBtn.InputBegan:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 then
			FlightController.requestItemUse()
			UiSound.play("stone", nil, 0.6)
			itemBtn.ImageColor3 = Color3.fromRGB(185, 245, 255)
			tweenGuiScale(itemBtn, 0.90, BUTTON_PRESS_S, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end)
	itemBtn.InputEnded:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 then
			FlightController.releaseItemUse() -- missile v3: a held trap drops on the release (a hold drags it first)
			itemBtn.ImageColor3 = Color3.fromRGB(255, 255, 255)
			tweenGuiScale(itemBtn, 1.0, BUTTON_RELEASE_S, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)

	playAgainBtn.Activated:Connect(function()
		-- L30: with 2+ humans FLY AGAIN is a vote; the card stays up showing "AGAIN 1/3" until the server acts.
		if not voting() then
			fModal.Visible = false
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(fModal) then
				GuiService.SelectedObject = nil
			end
		end
		FlightController.requestPlayAgain()
	end)
	-- BATTLE (TrackFlow fires RequestBattle): solo the card goes at once, like FLY AGAIN; with 2+ humans it stays for the vote.
	battleBtn.Activated:Connect(function()
		if not voting() then
			fModal.Visible = false
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(fModal) then
				GuiService.SelectedObject = nil
			end
		end
	end)
	-- L30/L81: the gamepad selection held back while others raced lands on FLY AGAIN once everyone is done (the return
	-- timer starts), after ButtonA (the throttle) is let go.
	RaceAttr.changed("ReturnToHubAt", function()
		if type(RaceAttr.mine("ReturnToHubAt")) ~= "number" or LocalPlayer:GetAttribute("InputMode") ~= "Gamepad" then
			return
		end
		task.spawn(function()
			local waited = 0
			while UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA) and waited < 5 do
				waited += task.wait(0.1)
			end
			if fModal.Visible and playAgainBtn.Visible and GuiService.SelectedObject == nil then
				UiSound.hush()
				GuiService.SelectedObject = playAgainBtn
			end
		end)
	end)

	-- Controls v2: BRAKE / REV pedal. Held = mobileThrottle -1; released (here, or anywhere the touch ends) = 0.
	local function releaseBrake()
		if brakeTouch == nil then
			return
		end
		brakeTouch = nil
		if FlightController.mobileThrottle < 0 then
			FlightController.mobileThrottle = 0
		end
		plate.BackgroundColor3 = Color3.fromRGB(104, 90, 78)
		tweenGuiScale(pedal, 1.0, BUTTON_RELEASE_S, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
	pedal.InputBegan:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 then
			brakeTouch = inp
			FlightController.mobileThrottle = -1
			UiSound.play("stone", nil, 0.6)
			plate.BackgroundColor3 = Color3.fromRGB(150, 74, 60)
			tweenGuiScale(pedal, 0.92, BUTTON_PRESS_S, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp: InputObject)
		if inp == brakeTouch or (brakeTouch ~= nil and brakeTouch.UserInputType == Enum.UserInputType.MouseButton1 and inp.UserInputType == Enum.UserInputType.MouseButton1) then
			releaseBrake()
		end
	end)
	-- Shown for cars only; hiding it mid-press lets go of the brake.
	local function refreshPedal()
		local car = LocalPlayer:GetAttribute("VehicleType") == "car"
		pedal.Visible = car
		if not car then
			releaseBrake()
		end
	end
	LocalPlayer:GetAttributeChangedSignal("VehicleType"):Connect(refreshPedal)
	rZone:GetPropertyChangedSignal("Visible"):Connect(function()
		if not rZone.Visible then
			releaseBrake()
		end
	end)
	refreshPedal()

	-- Wire Left Thumb Steer D-Pad Touch / Drag. Controls v2: a floating origin (TouchSteerRules.origin) where the thumb
	-- lands, so a thumb that lands off centre is not an instant hard turn; the stick radius has a 48 px floor.
	local function updateSteerFromScreenPos(pos: Vector2)
		local absPos = sPad.AbsolutePosition
		local absSize = sPad.AbsoluteSize
		local center = absPos + absSize * 0.5
		local maxR = TouchSteerRules.radius(absSize.X)
		local o = center + padOriginOffset
		local dx, dy, nx, ny = TouchSteerRules.padVector(o.X, o.Y, maxR, pos.X, pos.Y)
		puck.Position = UDim2.new(0.5, padOriginOffset.X + dx, 0.5, padOriginOffset.Y + dy)
		FlightController.mobileSteer = Vector2.new(nx, ny)
		FlightController.padSideX = DodgeRules.padSide(pos.X, center.X, absSize.X) -- dodge: a tap left / right of centre
		FlightController.padHeld = true
	end

	local function beginSteer(pos: Vector2)
		local absSize = sPad.AbsoluteSize
		local center = sPad.AbsolutePosition + absSize * 0.5
		local ox, oy = TouchSteerRules.origin(center.X, center.Y, absSize.X, pos.X, pos.Y)
		padOriginOffset = Vector2.new(ox - center.X, oy - center.Y)
		updateSteerFromScreenPos(pos)
	end

	local function resetSteerPad()
		activeSteerTouch = nil
		steerDraggingMouse = false
		padOriginOffset = Vector2.zero
		puck.Position = UDim2.fromScale(0.5, 0.5)
		FlightController.mobileSteer = Vector2.zero
		FlightController.padSideX = 0
		FlightController.padHeld = false
	end

	sPad.InputBegan:Connect(function(inp: InputObject)
		if inp.UserInputType == Enum.UserInputType.Touch then
			activeSteerTouch = inp
			beginSteer(Vector2.new(inp.Position.X, inp.Position.Y))
		elseif inp.UserInputType == Enum.UserInputType.MouseButton1 then
			steerDraggingMouse = true
			beginSteer(Vector2.new(inp.Position.X, inp.Position.Y))
		end
	end)

	UserInputService.InputChanged:Connect(function(inp: InputObject)
		if inp == activeSteerTouch and inp.UserInputType == Enum.UserInputType.Touch then
			updateSteerFromScreenPos(Vector2.new(inp.Position.X, inp.Position.Y))
		elseif steerDraggingMouse and inp.UserInputType == Enum.UserInputType.MouseMovement then
			updateSteerFromScreenPos(Vector2.new(inp.Position.X, inp.Position.Y))
		end
	end)

	UserInputService.InputEnded:Connect(function(inp: InputObject)
		if inp == activeSteerTouch then
			resetSteerPad()
		elseif steerDraggingMouse and inp.UserInputType == Enum.UserInputType.MouseButton1 then
			resetSteerPad()
		end
	end)

	-- Listen to Server Race Events. The server creates RaceEventRemote only after it has built the boot map (60-70 s
	-- under load in Studio) while SkyRallyRemotes exists early, so a short WaitForChild gave up and the HUD never heard
	-- a lap, a finish or a reset for the whole session (the same root cause as the stale-respawn car): wait in the
	-- background for as long as it takes.
	task.spawn(function()
		local remotesFolder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 10)
		while not remotesFolder do
			remotesFolder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 10)
		end
		local found = (remotesFolder :: Instance):WaitForChild("RaceEventRemote", 10)
		while not found do
			warn("[SkyRally][HUD] still waiting for RaceEventRemote (server still building the map?)")
			found = (remotesFolder :: Instance):WaitForChild("RaceEventRemote", 10)
		end
		local raceEventRemote = found :: RemoteEvent
		raceEventRemote.OnClientEvent:Connect(function(eventType: string, payload: any)
			if eventType == "FTUEArchCleared" then
				-- The server sends this on every map (hub and car tracks included): name the track actually flown, and
				-- only a plane says it can fly (a car on ISLAND-2 read "I CAN FLY! — DINO-4 CIRCUIT").
				local info = TrackInfo.get(RaceAttr.mine("ActiveTrackId") :: string?)
				-- v29 B10: once per map visit. Every FTUEArchCleared pushed the same toast key again, and a repeat of an
				-- on-screen key extends it (NotifyRules.push "refreshed"), so the map title sat over the route.
				local visit = tostring(RaceAttr.mine("ActiveTrackId")) .. ":" .. tostring(RaceAttr.mine("RaceGoTime"))
				if info and info.vehicle == "plane" and RaceAttr.mine("RaceMode") ~= "hub" and visit ~= lastFtueVisit then
					lastFtueVisit = visit
					RaceUI.showBanner("I CAN FLY! — " .. string.upper(info.trackName), creamText, 1.8)
				end
			elseif eventType == "LapCompleted" and type(payload) == "table" then
				if lapChip then
					pulseGuiObject(lapChip, 1.18, 0.24)
				end
				RaceUI.showBanner(
					string.format("LAP %d / %d  •  %s", payload.lap or 2, payload.totalLaps or 3, formatTime(payload.lapTime or 0)),
					Color3.fromRGB(255, 232, 120),
					2.0
				)
			elseif eventType == "CheckpointRespawn" then
				RaceUI.showBanner("CHECKPOINT RESPAWN", Color3.fromRGB(255, 195, 110), 1.2)
			elseif eventType == "RaceFinished" then
				-- REMARKABLE 23/24/30 (client/FinishShow): photo cam, podium ceremony, then this card, polaroid and token flight.
				require(script.Parent.FinishShow).run(payload, function(p: any): GuiObject?
					populateFinishModal(p)
					return finishModal
				end)
			elseif eventType == "RaceDNF" then
				-- L30: the DNF deadline passed with this racer still flying: the card with no result (it can vote).
				populateFinishModal(payload)
			elseif eventType == "PhotoFinish" then
				require(script.Parent.FinishShow).onPhotoFinish(payload) -- REMARKABLE 23: the server-confirmed gap
			elseif eventType == "RaceReset" then
				require(script.Parent.FinishShow).cancel() -- REMARKABLE 23/24/30: a reset ends the finish sequence
				fModal.Visible = false
			elseif eventType == "LobbyTimeout" then
				HudExtras.showLobbyTimeout(if type(payload) == "table" and type(payload.seconds) == "number" then payload.seconds else nil)
			elseif eventType == "Notice" and type(payload) == "table" and type(payload.text) == "string" then
				-- Generic server notice (disconnect of the host lobby, mode change); always non-modal.
				local tone: HudExtras.Tone = if payload.tone == "error" then "error" elseif payload.tone == "ok" then "ok" else "info"
				HudExtras.showNotice(
					if type(payload.id) == "string" then payload.id else "server",
					string.sub(payload.text, 1, 160),
					tone,
					payload.spinner == true,
					if type(payload.seconds) == "number" then payload.seconds else 5
				)
			end
		end)
	end)

	HudExtras.init(sg, {
		creamText = creamText,
		darkInk = darkInk,
		toast = RaceUI.showBanner,
	})
	ItemClient.init(RaceUI.showBanner)
	-- RESPAWN button (trap audit G5): FlightController's entry points, which CarController takes over while a car is
	-- bound (cooldown, the server check and the frame all live there).
	HudExtras.setRespawnHandler(function()
		UiSound.play("stone", nil, 0.6)
		FlightController.requestManualRespawn("button")
	end, function(): (boolean, number, boolean)
		return FlightController.respawnStatus()
	end)

	-- RETURN to course (Free driving off course, FLIGHT_GUIDE.md 4.3, 12): FlightController offers it and asks the server.
	HudExtras.setReturnHandler(function()
		UiSound.play("stone", nil, 0.6)
		FlightController.requestCourseReturn("Button")
	end, function(): (boolean, number)
		return FlightController.returnStatus()
	end)

	-- ASSIST on / off from the HUD pill / chip, the T key (desktop) and the gear panel's row: the same switch.
	HudExtras.setAssistHandler(RaceUI.setAssist)
	Settings.setAssistHandler(RaceUI.setAssist)
	ContextActionService:BindAction("SkyRallyAssistToggle", function(_n, state, _o): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin or UserInputService:GetFocusedTextBox() ~= nil or not HudPhase.allows("AssistChip") then
			return Enum.ContextActionResult.Pass
		end
		RaceUI.setAssist(LocalPlayer:GetAttribute("AutoThrottle") == false)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.T)

	updateResponsiveLayout()
	-- A rotation, an emulated device, a TV mode, the chat window changing the nav reserve, touch <-> keyboard, a battle.
	HudMetrics.onChanged(updateResponsiveLayout)

	RunService.RenderStepped:Connect(Prof.wrap("SR_RaceUI", function()
		local rank = (LocalPlayer:GetAttribute("Rank") :: number?) or 1
		local totalRacers = (RaceAttr.mine("TotalRacers") :: number?) or 4
		local lap = (LocalPlayer:GetAttribute("Lap") :: number?) or 1
		local elapsed = (LocalPlayer:GetAttribute("RaceElapsed") :: number?) or (os.clock() - FlightController.joinClock)

		if lastDisplayedRank ~= nil and lastDisplayedRank ~= rank and posBadge then
			pulseGuiObject(posBadge, 1.16, 0.22)
			-- A place change in a live race (not the grid shuffle, not after the finish, not in the hub): up or down.
			if elapsed >= 3 and LocalPlayer:GetAttribute("RaceFinished") ~= true and RaceAttr.mine("RaceMode") ~= "hub" then
				Sfx.play(if rank < lastDisplayedRank then "place_up" else "place_down", 1, if rank < lastDisplayedRank then 0.31 else 0.25)
			end
		end
		lastDisplayedRank = rank

		if lastDisplayedLap ~= nil and lastDisplayedLap ~= lap and lapChip then
			pulseGuiObject(lapChip, 1.16, 0.22)
		end
		-- REMARKABLE 3: FINAL LAP! swing and red-hot chip; the chip text (LapChipRules, written below only on a change).
		local lapTotal = MusicRules.totalLaps(RaceAttr.mine("TotalLaps"), PlaneConfig.TOTAL_LAPS)
		local lapText, lapTextChanged, lapEvent = LapChipRules.step(lapState, lap, lapTotal, os.clock(), RaceAttr.mine("RaceMode"), LocalPlayer:GetAttribute("RaceFinished"))
		if lapEvent == "reset" then
			lapChipReset()
		elseif lapEvent == "final" then
			lapChipFinal()
		end
		if lastDisplayedLap ~= lap then
			if lastDisplayedLap ~= nil and lap > lastDisplayedLap and LocalPlayer:GetAttribute("RaceFinished") ~= true then
				local final = lapState.finalOn
				task.spawn(pcall, function() -- moments VFX: gate flash (final lap: light sweep + shells)
					(require(script.Parent:WaitForChild("CelebrationFx")) :: any).lap(final)
				end)
			end
		end
		lastDisplayedLap = lap

		local goAt = RaceAttr.mine("RaceGoTime")
		local started = type(goAt) ~= "number" or workspace:GetServerTimeNow() >= goAt
		if posTextLabel then
			-- "3RD/8": numeral, ordinal suffix, field size; 1st is gold. Rebuilt only when the text or the sizes change.
			local text = GridOrder.plankText(started, rank, totalRacers, LocalPlayer:GetAttribute("GridPosition"), LocalPlayer:GetAttribute("GridField"), PlaneConfig.AI_FIELD_SIZE)
			if text ~= posTextCache then
				if posTextCache ~= "" and posBadge then
					pulseGuiObject(posBadge, 1.22, 0.3) -- v21: a place change pops
				end
				posTextCache = text
				local numeral, suffix, total = HudLayoutRules.positionParts(text)
				local numColor = if started and numeral == "1" then POS_GOLD else LAP_CREAM
				posTextLabel.TextSize = posSizes[1]
				posTextLabel.Text = string.format(
					'<font size="%d" color="#%s">%s</font><font size="%d" color="#%s">%s</font><font size="%d" color="#%s">%s</font>',
					posSizes[1], numColor:ToHex(), numeral, posSizes[2], numColor:ToHex(), suffix, posSizes[3], LAP_CREAM:ToHex(), total
				)
			end
		end
		local resultsUp = finishModal ~= nil and finishModal.Visible
		HudExtras.setResultsShown(resultsUp)
		HudPhase.setResultsUp(resultsUp)
		if lapLabel and lapTextChanged then
			lapLabel.Text = lapText
		end
		if timerLabel then
			-- The grid shows a dim 0:00.0 until GO.
			local text = formatChipTime(if started then elapsed else 0)
			if text ~= timerTextCache then
				timerTextCache = text
				timerLabel.Text = text
			end
			local alpha = if started then 0 else 0.45
			if alpha ~= timerAlphaCache then
				timerAlphaCache = alpha
				timerLabel.TextTransparency = alpha
			end
		end

		if heroLabel and heroLabel.Visible and (os.clock() >= heroHideClock or not HudPhase.allows("MessageLane")) then
			heroLabel.Visible = false
			LocalPlayer:SetAttribute("HudHeroUp", false)
		end
		if _steerPuck and steerPadBtn and not activeSteerTouch and not steerDraggingMouse then
			local maxR = TouchSteerRules.radius(steerPadBtn.AbsoluteSize.X)
			local st = FlightController.steerInput
			_steerPuck.Position = UDim2.new(0.5, st.X * maxR * 0.65, 0.5, -st.Y * maxR * 0.65)
		end

		if brakeCaption then
			local cap = if LocalPlayer:GetAttribute("CarReversing") == true then "REV" else "BRAKE"
			if cap ~= brakeCaptionCache then
				brakeCaptionCache = cap
				brakeCaption.Text = cap
			end
		end
		if _sharpBankBtn and FlightController.sharpBank ~= bankTintCache then
			bankTintCache = FlightController.sharpBank
			_sharpBankBtn.ImageColor3 = if FlightController.sharpBank then Color3.fromRGB(255, 230, 175) else Color3.fromRGB(255, 255, 255)
		end
		if _throttleUpBtn then
			-- Disabled look while empty; a light tint of the held item's colour while holding one.
			local held = LocalPlayer:GetAttribute("ItemColor")
			local tint = if type(held) == "string" then ItemRules.colorRgb(held) else nil
			if tint and HudExtras.itemRolling() then
				tint = { 255, 255, 255 } -- a mystery roll is still spinning: no colour hint yet
			end
			-- The stone mirrors the held item: icon and level pips (hidden while the mystery roll is still spinning).
			local heldColor, heldLevel = HudExtras.held()
			local showHeld = heldColor ~= nil and not HudExtras.itemRolling()
			-- Written only on change: a property write each frame is wasted work on a still HUD.
			if _heldIcon then
				if _heldIcon.Visible ~= showHeld then
					_heldIcon.Visible = showHeld
				end
				if showHeld then
					local ic = ItemRules.iconOf(heldColor) -- items v4: specials too (ItemRules.ICON)
					local img = if ic then ItemTexAssets[ic.tex] or "" else ""
					if _heldIcon.Image ~= img then
						_heldIcon.Image = img
					end
				end
			end
			for i, pip in _heldPips do
				local want = showHeld and i <= heldLevel
				if pip.Visible ~= want then
					pip.Visible = want
				end
			end
			local tintKey = if tint then string.format("%g,%g,%g", tint[1], tint[2], tint[3]) else ""
			if tintKey ~= itemTintCache then
				itemTintCache = tintKey
				_throttleUpBtn.ImageTransparency = if tint then 0 else 0.35
				_throttleUpBtn.ImageColor3 = if tint
					then Color3.fromRGB(tint[1], tint[2], tint[3]):Lerp(Color3.new(1, 1, 1), 0.55)
					else Color3.new(1, 1, 1)
			end
		end
	end))
end

return RaceUI
