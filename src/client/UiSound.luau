--!strict
-- Wood-and-Stone UI sound kit and button feel (REMARKABLE item 4). Every menu button gets a sound and a squash:
--   tap      hollow wood "tok"            (plank buttons, the default)
--   stone    low stone "thunk"            (the carved HUD buttons)
--   confirm  two rising marimba notes     (go / equip / play again)
--   back     a soft falling pair          (close / cancel / leave)
--   deny     two stone knocks, the second lower, and the button shakes its head (locked, sold out, rejected)
--   tab      a wooden sign flipping over  (Garage tabs, opening the Adventure board)
--   purchase a marimba run up to a bell   (a buy or claim the server accepted)
--   select   gamepad selection: one marimba note pitched along a major pentatonic by the button's place in its row,
--            so walking the D-pad across a menu plays a scale; hover is the same note, quieter, for the mouse
-- Cues come from tools/audio/synth_ui.py (synthesised, no licence) through shared/UiAudioAssets (or ui_* keys in
-- shared/AudioAssets); a cue with no id stays silent. Four pooled, preloaded Sounds per kind live in the SoundGroup
-- SoundService.SkyRallyUI (volume = LocalPlayer attribute UiVolume, default 0.6); nothing is allocated per frame, and the
-- gates (shared/UiSoundRules) keep the curtain quiet and fifty rapid taps from stacking.
-- Usage: UiSound.bind(button, kind) once per button (sound + feel); UiSound.setKind(button, kind) to change what a
-- press says later; UiSound.play(kind, step?, volumeScale?, allowCurtain?) for moments with no button (a server
-- reply, a key binding). Feel only touches the button's UIScale, Rotation and, for deny outside a layout, Position.
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("UiSoundRules"))
local UiAudioAssets = require(Shared:WaitForChild("UiAudioAssets")) :: any
local AudioAssets = require(Shared:WaitForChild("AudioAssets")) :: any
local SfxV2Audio = require(Shared:WaitForChild("SfxV2Audio")) :: any

local LocalPlayer = Players.LocalPlayer

local UiSound = {}

local KIND_ATTR = "UiSound"

local pools: { [string]: { Sound } } = {}
local nextVoice: { [string]: number } = {}
local lastAt: { [string]: number } = {}
local lastPressAt = -math.huge
local ready = false
local gateState: Rules.GateState = { now = 0, switching = false }

local function cueId(cue: string): string?
	local id = UiAudioAssets[cue] or AudioAssets[cue] or SfxV2Audio[cue]
	return if type(id) == "string" and id ~= "" then id else nil
end

local function ensure()
	if ready then
		return
	end
	ready = true
	local g = Instance.new("SoundGroup")
	g.Name = "SkyRallyUI"
	g.Volume = Rules.groupVolume(LocalPlayer:GetAttribute("UiVolume"))
	g.Parent = SoundService
	LocalPlayer:GetAttributeChangedSignal("UiVolume"):Connect(function()
		g.Volume = Rules.groupVolume(LocalPlayer:GetAttribute("UiVolume"))
	end)
	local all: { Instance } = {}
	for _, kind in Rules.KINDS do
		local id = cueId(Rules.CUE[kind])
		if id then
			local pool: { Sound } = {}
			for i = 1, Rules.POOL_SIZE do
				local s = Instance.new("Sound")
				s.Name = kind .. i
				s.SoundId = id
				s.Volume = Rules.VOLUME[kind] or 0.6
				s.SoundGroup = g
				s.Parent = g
				pool[i] = s
				table.insert(all, s)
			end
			pools[kind] = pool
		end
	end
	if #all > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(all)
			end)
		end)
	end
end

-- Plays one UI sound. step pitches select/hover along the pentatonic; volumeScale trims this play; allowCurtain lets
-- the curtain mini-game speak under TrackSwitching. Returns whether a voice started.
function UiSound.play(kind: string, step: number?, volumeScale: number?, allowCurtain: boolean?): boolean
	ensure()
	local pool = pools[kind]
	if not pool then
		return false
	end
	local now = os.clock()
	gateState.now = now
	gateState.lastAt = lastAt[kind]
	gateState.switching = workspace:GetAttribute("TrackSwitching") == true
	gateState.allowCurtain = allowCurtain
	gateState.lastPressAt = lastPressAt
	if not Rules.gate(kind, gateState) then
		return false
	end
	lastAt[kind] = now
	if Rules.isPress(kind) then
		lastPressAt = now
	end
	local i = (nextVoice[kind] or 0) % #pool + 1
	nextVoice[kind] = i
	local s = pool[i]
	if kind == "select" or kind == "hover" then
		s.PlaybackSpeed = Rules.pitch(step)
	elseif kind == "vote" then
		s.PlaybackSpeed = Rules.votePitch(step) -- another racer's vote landing: the pip climbs with the count
	elseif kind == "tap" or kind == "stone" then
		-- A hair of pitch spread: ten taps in a row sound like a hand on wood, not a sample.
		s.PlaybackSpeed = 0.96 + math.random() * 0.08
	else
		s.PlaybackSpeed = 1
	end
	s.Volume = (Rules.VOLUME[kind] or 0.6) * (volumeScale or 1)
	if s.IsPlaying then
		s:Stop()
	end
	s:Play()
	return true
end

-- Holds selection/hover notes back for a moment: call it before code moves gamepad selection (a rebuilt list), so the
-- move does not ring a note nobody played.
function UiSound.hush()
	lastPressAt = math.max(lastPressAt, os.clock())
end

-- os.clock() of the last play of a kind (-inf when never), so a caller can skip a sound a press already made.
function UiSound.lastPlayed(kind: string): number
	return lastAt[kind] or -math.huge
end

---------------------------------------------------------------------------------------------------- feel

type FeelState = {
	seq: number,
	baseRot: number,
	basePos: UDim2?,
	hovered: boolean,
	downAt: number,
	downArmed: boolean, -- a mouse press already spoke; the Activated that follows stays quiet
}

local feel: { [GuiButton]: FeelState } = setmetatable({}, { __mode = "k" }) :: any

local PRESS_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local WOBBLE_INFO: { TweenInfo } = {}
for i, f in Rules.WOBBLE do
	WOBBLE_INFO[i] = TweenInfo.new(f[2], if i == #Rules.WOBBLE then Enum.EasingStyle.Back else Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
end
local SHAKE_INFO = TweenInfo.new(Rules.SHAKE_STEP, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local function uiScale(obj: GuiObject): UIScale
	local existing = obj:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

local function scaleTo(obj: GuiObject, target: number, info: TweenInfo)
	TweenService:Create(uiScale(obj), info, { Scale = target }):Play()
end

local function inLayout(obj: GuiObject): boolean
	local p = obj.Parent
	return p ~= nil and p:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
end

-- Rotation keyframes (wobble, or the head-shake for deny inside a layout), one tween per step; a newer press cancels
-- the older chain (a new tween on Rotation cancels the running one, and the seq check drops its follow-ups).
local function rotChain(btn: GuiButton, st: FeelState, seq: number, frames: { { number } }, infos: { TweenInfo }, i: number)
	if st.seq ~= seq or i > #frames or btn.Parent == nil then
		return
	end
	local tw = TweenService:Create(btn, infos[i], { Rotation = st.baseRot + frames[i][1] })
	tw.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			rotChain(btn, st, seq, frames, infos, i + 1)
		end
	end)
	tw:Play()
end

local SHAKE_ROT: { { number } } = {}
local SHAKE_ROT_INFO: { TweenInfo } = {}
local SHAKE_POS: { { number } } = {}
for i, px in Rules.SHAKE do
	SHAKE_ROT[i] = { px * 1.25 } -- degrees: a 4 px knock reads as about 5 degrees on a 44 px button
	SHAKE_ROT_INFO[i] = SHAKE_INFO
	SHAKE_POS[i] = { px }
end

local function posChain(btn: GuiButton, st: FeelState, seq: number, i: number)
	local base = st.basePos
	if st.seq ~= seq or base == nil or btn.Parent == nil then
		return
	end
	if i > #SHAKE_POS then
		btn.Position = base
		st.basePos = nil
		return
	end
	local goal = UDim2.new(base.X.Scale, base.X.Offset + SHAKE_POS[i][1], base.Y.Scale, base.Y.Offset)
	local tw = TweenService:Create(btn, SHAKE_INFO, { Position = goal })
	tw.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			posChain(btn, st, seq, i + 1)
		end
	end)
	tw:Play()
end

local function settle(btn: GuiButton, st: FeelState)
	scaleTo(btn, if st.hovered then Rules.HOVER_SCALE else 1, RELEASE_INFO)
end

-- The squash and wobble (or the shake for deny) without a sound: for buttons whose press sound is played elsewhere.
function UiSound.feelPress(btn: GuiButton, kind: string?)
	local st = feel[btn]
	if not st then
		return
	end
	st.seq += 1
	local seq = st.seq
	scaleTo(btn, Rules.PRESS_SCALE, PRESS_INFO)
	if kind == "deny" then
		if inLayout(btn) then
			rotChain(btn, st, seq, SHAKE_ROT, SHAKE_ROT_INFO, 1)
		else
			if st.basePos == nil then
				st.basePos = btn.Position
			end
			posChain(btn, st, seq, 1)
		end
	else
		rotChain(btn, st, seq, Rules.WOBBLE, WOBBLE_INFO, 1)
	end
end

local function kindOf(btn: GuiButton): string
	local k = btn:GetAttribute(KIND_ATTR)
	return if type(k) == "string" then k else "tap"
end

local function press(btn: GuiButton)
	local kind = kindOf(btn)
	if kind ~= "none" then
		UiSound.play(kind)
	end
	UiSound.feelPress(btn, kind)
end

-- The note for this button: its place among the selectable sibling buttons, lifted by the row it sits in.
local function stepFor(btn: GuiButton): number
	local parent = btn.Parent
	if not parent then
		return 1
	end
	local slots: { Rules.Slot } = {}
	local me: Rules.Slot = { order = btn.LayoutOrder, x = btn.AbsolutePosition.X, y = btn.AbsolutePosition.Y }
	for _, c in parent:GetChildren() do
		if c == btn then
			table.insert(slots, me)
		elseif c:IsA("GuiButton") and c.Visible and c.Selectable then
			table.insert(slots, { order = c.LayoutOrder, x = c.AbsolutePosition.X, y = c.AbsolutePosition.Y })
		end
	end
	local rowOrder: number? = nil
	local node: Instance? = parent
	for _ = 1, 3 do
		if node == nil then
			break
		end
		local up = node.Parent
		if node:IsA("GuiObject") and node.LayoutOrder > 0 and up and up:FindFirstChildWhichIsA("UIGridStyleLayout") then
			rowOrder = node.LayoutOrder
			break
		end
		node = up
	end
	return Rules.step(Rules.rank(slots, me), rowOrder)
end

local function mouseHover(): boolean
	return UserInputService:GetLastInputType() == Enum.UserInputType.MouseMovement
end

-- Wires sound and feel into a button once (later calls only change its kind). kind defaults to "tap"; "none" keeps
-- the feel and drops the press sound (the handler plays its own).
function UiSound.bind(btn: GuiButton, kind: string?)
	if kind then
		btn:SetAttribute(KIND_ATTR, kind)
	end
	if feel[btn] then
		return
	end
	ensure() -- build and preload the pools with the first button, not on the first press
	local st: FeelState = {
		seq = 0,
		baseRot = btn.Rotation,
		basePos = nil,
		hovered = false,
		downAt = -math.huge,
		downArmed = false,
	}
	feel[btn] = st
	btn.MouseEnter:Connect(function()
		st.hovered = true
		settle(btn, st)
		if mouseHover() then
			UiSound.play("hover", stepFor(btn))
		end
	end)
	btn.MouseLeave:Connect(function()
		st.hovered = false
		settle(btn, st)
	end)
	btn.SelectionGained:Connect(function()
		st.hovered = true
		settle(btn, st)
		UiSound.play("select", stepFor(btn))
	end)
	btn.SelectionLost:Connect(function()
		st.hovered = false
		settle(btn, st)
	end)
	btn.MouseButton1Down:Connect(function()
		st.downAt = os.clock()
		if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
			-- Touch: squash now, speak and wobble on release (Activated), so scrolling a list by dragging over its
			-- buttons never clicks.
			st.downArmed = false
			scaleTo(btn, Rules.PRESS_SCALE, PRESS_INFO)
			-- A drag that scrolls away may never send Up or Leave to this button: spring back on its own.
			local at = st.downAt
			task.delay(0.3, function()
				if st.downAt == at then
					settle(btn, st)
				end
			end)
		else
			st.downArmed = true
			press(btn)
		end
	end)
	btn.MouseButton1Up:Connect(function()
		settle(btn, st)
	end)
	-- Touch release, gamepad A and keyboard Enter land here; a mouse press already spoke on the way down.
	btn.Activated:Connect(function()
		local recent = os.clock() - st.downAt < 3
		if st.downArmed and recent then
			st.downArmed = false
			return
		end
		st.downArmed = false
		press(btn)
		task.delay(0.08, settle, btn, st)
	end)
end

-- Changes what a bound button's press plays (equip vs unequip, open vs locked).
function UiSound.setKind(btn: GuiButton, kind: string)
	btn:SetAttribute(KIND_ATTR, kind)
end

return UiSound
