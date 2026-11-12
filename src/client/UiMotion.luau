--!strict
-- UI motion presets (UI overhaul phase A): panels swoosh in from a side, cards pop, counters bounce. The presets (time,
-- easing, overshoot, cue) live in shared/UiSkinRules.MOTION; this module runs them with TweenService.
--   UiMotion.show(gui, preset, opts?)          makes gui visible and plays "swooshIn" / "popIn" (or any preset)
--   UiMotion.hide(gui, preset, onDone?, opts?) plays "swooshOut" / "popOut", then Visible = false and the gui back at
--                                              rest (Position home, UIScale 1), then onDone
--   UiMotion.bounce(gui, opts?)                a settle wobble on the gui's UIScale (counters, badges); silent unless
--                                              opts.sound (counters already have their payoff sounds)
--   UiMotion.place(gui, pos)                   sets a gui's resting Position; while a slide runs it retargets the slide
--                                              instead of fighting it (NotifyKit re-lays its panels every step)
--   UiMotion.cancel(gui) / isBusy / isHiding
-- A new show / hide on the same gui cancels the one in flight (its onDone never fires). Scale presets reuse an existing
-- UIScale (UiSound's button squash, NotifyKit's panel scale) instead of stacking a second one. show / hide play the
-- preset's cue (a UiSoundRules kind) through UiSound.play unless opts.silent; opts.cue picks another kind.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("UiSkinRules"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local UiMotion = {}

export type Opts = {
	side: string?, -- slide presets: "left" / "right" / "top" / "bottom" (default "top")
	home: UDim2?, -- slide presets: the resting Position (default: the gui's Position now)
	duration: number?, -- override the preset's time (e.g. a short toast exit)
	silent: boolean?,
	cue: string?, -- a UiSoundRules kind instead of the preset's cue
	volume: number?, -- volumeScale for the cue
	onDone: (() -> ())?, -- show only (hide takes onDone as its third argument)
	sound: boolean?, -- bounce only: play the preset cue
	scale: number?, -- scale presets: the UIScale's resting value when it is also a layout scale (RaceUI's desktop
	-- CardScale); the preset's from / to multiply it and the gui settles back to it, not to 1
}

type State = { seq: number, tweens: { Tween }, home: UDim2?, hiding: boolean, side: string?, scaling: UIScale?, base: number? }

local states: { [GuiObject]: State } = setmetatable({}, { __mode = "k" }) :: any
local bounces: { [GuiObject]: State } = setmetatable({}, { __mode = "k" }) :: any

local function stateOf(g: GuiObject): State
	local st = states[g]
	if not st then
		st = { seq = 0, tweens = {}, home = nil, hiding = false, side = nil, scaling = nil }
		states[g] = st
	end
	return st :: State
end

local function enumOf(enum: any, name: string, default: any): any
	local ok, v = pcall(function()
		return enum[name]
	end)
	return if ok and v then v else default
end

local function info(time: number, style: string, dir: string): TweenInfo
	return TweenInfo.new(
		time,
		enumOf(Enum.EasingStyle, style, Enum.EasingStyle.Quad),
		enumOf(Enum.EasingDirection, dir, Enum.EasingDirection.Out)
	)
end

local function uiScale(g: GuiObject): UIScale
	local existing = g:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = "MotionScale"
	s.Parent = g
	return s
end

local function stop(st: State)
	st.seq += 1
	local interrupted = #st.tweens > 0
	for _, tw in st.tweens do
		tw:Cancel()
	end
	table.clear(st.tweens)
	-- A pop cut short would leave the gui shrunk under the next slide: back to rest.
	local sc = st.scaling
	if interrupted and sc then
		sc.Scale = st.base or 1
	end
	st.scaling = nil
	st.base = nil
end

local function sizeOf(g: GuiObject): (number, number)
	local a = g.AbsoluteSize
	local w = if a.X > 0 then a.X else g.Size.X.Offset
	local h = if a.Y > 0 then a.Y else g.Size.Y.Offset
	return w, h
end

local function offset(pos: UDim2, dx: number, dy: number): UDim2
	return UDim2.new(pos.X.Scale, pos.X.Offset + dx, pos.Y.Scale, pos.Y.Offset + dy)
end

local function run(st: State, seq: number, tw: Tween, onDone: (() -> ())?)
	table.insert(st.tweens, tw)
	tw.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and st.seq == seq then
			table.clear(st.tweens)
			if onDone then
				onDone()
			end
		end
	end)
	tw:Play()
end

local function cue(m: Rules.Motion, opts: Opts)
	if opts.silent then
		return
	end
	UiSound.play(opts.cue or m.cue, nil, opts.volume)
end

-- Cancels any running motion on gui. A slide snaps to its resting Position; the gui stays as visible as it is.
function UiMotion.cancel(g: GuiObject)
	local st = states[g]
	if not st then
		return
	end
	stop(st)
	if st.home then
		g.Position = st.home
		st.home = nil
	end
	st.hiding = false
end

function UiMotion.isBusy(g: GuiObject): boolean
	local st = states[g]
	return st ~= nil and #st.tweens > 0
end

function UiMotion.isHiding(g: GuiObject): boolean
	local st = states[g]
	return st ~= nil and st.hiding
end

-- Resting Position for gui: written straight through, or handed to the running slide as its new target.
function UiMotion.place(g: GuiObject, pos: UDim2)
	local st = states[g]
	if st and st.home and #st.tweens > 0 then
		st.home = pos
		return
	end
	g.Position = pos
end

function UiMotion.show(g: GuiObject, preset: string, opts: Opts?)
	local o: Opts = opts or {}
	local st = stateOf(g)
	local wasHome = st.home
	stop(st)
	st.hiding = false
	local seq = st.seq
	local m = Rules.MOTION[preset]
	g.Visible = true
	if not m then
		if wasHome then
			g.Position = wasHome
		end
		st.home = nil
		return
	end
	local time = o.duration or m.duration
	if m.kind == "slide" then
		local home = o.home or wasHome or g.Position
		st.home = home
		local side = o.side or "top"
		st.side = side
		local w, h = sizeOf(g)
		local dx, dy = Rules.slideOffset(preset, side, w, h)
		g.Position = offset(home, dx, dy)
		run(st, seq, TweenService:Create(g, info(time, m.style, m.dir), { Position = home }), function()
			g.Position = st.home or home
			st.home = nil
			if o.onDone then
				o.onDone()
			end
		end)
	elseif m.kind == "scale" then
		if wasHome then
			g.Position = wasHome
		end
		st.home = nil
		local sc = uiScale(g)
		local base = o.scale or 1
		st.scaling = sc
		st.base = base
		sc.Scale = (m.from or 0.85) * base
		run(st, seq, TweenService:Create(sc, info(time, m.style, m.dir), { Scale = (m.to or 1) * base }), o.onDone)
	else
		UiMotion.bounce(g, o)
		return
	end
	cue(m, o)
end

function UiMotion.hide(g: GuiObject, preset: string, onDone: (() -> ())?, opts: Opts?)
	local o: Opts = opts or {}
	local st = stateOf(g)
	if not g.Visible then
		UiMotion.cancel(g)
		if onDone then
			onDone()
		end
		return
	end
	local wasHome = st.home
	stop(st)
	st.hiding = true
	local seq = st.seq
	local m = Rules.MOTION[preset]
	local function finish(home: UDim2?)
		g.Visible = false
		if home then
			g.Position = home
		end
		st.home = nil
		st.hiding = false
		if onDone then
			onDone()
		end
	end
	if not m then
		finish(wasHome)
		return
	end
	local time = o.duration or m.duration
	if m.kind == "slide" then
		local home = wasHome or g.Position
		st.home = home
		local w, h = sizeOf(g)
		local dx, dy = Rules.slideOffset(preset, o.side or st.side or "top", w, h)
		run(st, seq, TweenService:Create(g, info(time, m.style, m.dir), { Position = offset(home, dx, dy) }), function()
			finish(st.home or home)
		end)
	elseif m.kind == "scale" then
		if wasHome then
			g.Position = wasHome
		end
		st.home = nil
		local sc = uiScale(g)
		local base = o.scale or 1
		st.scaling = sc
		st.base = base
		run(st, seq, TweenService:Create(sc, info(time, m.style, m.dir), { Scale = (m.to or 0.85) * base }), function()
			sc.Scale = base
			finish(nil)
		end)
	else
		finish(wasHome)
		return
	end
	cue(m, o)
end

-- A settle wobble on gui's UIScale (1 -> peak -> under -> 1). Restarting mid-bounce starts over from the current scale.
function UiMotion.bounce(g: GuiObject, opts: Opts?)
	local o: Opts = opts or {}
	local m = Rules.MOTION.bounce
	local steps = m.steps
	if not steps then
		return
	end
	-- Its own state, so a bounce never cancels a slide or pop running on the same gui.
	local st = bounces[g]
	if not st then
		st = { seq = 0, tweens = {}, home = nil, hiding = false, side = nil, scaling = nil }
		bounces[g] = st
	end
	local bst = st :: State
	stop(bst)
	local seq = bst.seq
	local sc = uiScale(g)
	bst.scaling = sc
	local function step(i: number)
		if bst.seq ~= seq or i > #steps or g.Parent == nil then
			return
		end
		local s = steps[i]
		run(bst, seq, TweenService:Create(sc, info(s.time, s.style, s.dir), { Scale = s.scale }), function()
			step(i + 1)
		end)
	end
	step(1)
	if o.sound then
		UiSound.play(o.cue or m.cue, nil, o.volume)
	end
end

return UiMotion
