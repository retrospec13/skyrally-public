--!strict
-- HUD metrics (docs/design/HUD_LAYOUT.md section 3.1 and 9 step 2): the ONE place the client turns "what screen is this" into
-- HUD rectangles. It reads the viewport, SafeArea's insets, the input kind and the Roblox top-left nav reserve
-- (GuiService.TopbarInset, with the spec's fallbacks when the property is missing or implausible), runs
-- shared/HudLayoutRules.compute, and tells the listeners when any of those change (rotation, an emulated device, the chat
-- window opening, a switch between touch and keyboard, a battle starting). RaceUI, HudExtras, Settings, Onboarding,
-- StyleChain, TrickJuice, TrackFlow and RivalBubbles read rects() instead of keeping size tables of their own.
-- QA, Studio only by habit: LocalPlayer attribute QANav = "w,h" pretends a nav reserve. The result is mirrored on the
-- player as HudNav = "w,h", HudNavSource = "topbar" | "fallback" | "qa" and HudKind = "touch" | "desktop".
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local HudLayoutRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HudLayoutRules"))
local SafeArea = require(script.Parent.SafeArea)

local LocalPlayer = Players.LocalPlayer

local HudMetrics = {}

export type Rect = HudLayoutRules.Rect
export type Snapshot = {
	viewport: Vector2,
	insets: SafeArea.Insets,
	nav: Rect,
	kind: HudLayoutRules.Kind,
	metrics: HudLayoutRules.Metrics,
	rects: { [string]: Rect },
}

local snapshot: Snapshot? = nil
local handlers: { (Snapshot) -> () } = {}
local started = false
local pending = false

-- The ScreenGui's real size (TrackFlow reports it): a DPI-scaled client can have a gui smaller than the camera's ViewportSize,
-- and every HUD rect is placed in gui pixels, so the smaller of the two is the viewport the rects are computed for.
local guiSize: Vector2? = nil

local function viewport(): Vector2
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local g = guiSize
	if g and g.X > 0 and g.Y > 0 then
		v = Vector2.new(math.min(v.X, g.X), math.min(v.Y, g.Y))
	end
	return v
end

-- Touch layout when InputMode says Touch; before it has decided, a touch-only device is touch.
local function currentKind(): HudLayoutRules.Kind
	local mode = LocalPlayer:GetAttribute("InputMode")
	if mode == "Touch" then
		return "touch"
	elseif type(mode) == "string" then
		return "desktop"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	return "desktop"
end

local function readNav(v: Vector2): (Rect, string, number?)
	local qa = LocalPlayer:GetAttribute("QANav")
	if type(qa) == "string" then
		local w, h = string.match(qa, "^%s*(%d+)%s*,%s*(%d+)%s*$")
		if w and h then
			return { x = 0, y = 0, w = tonumber(w) :: number, h = tonumber(h) :: number }, "qa", nil
		end
	end
	local minX: number? = nil
	local maxY: number? = nil
	local maxX: number? = nil
	-- The HUD ScreenGuis are ScreenInsets.None: their origin is the top-left of the whole screen. GetInsetArea rects are in
	-- the CoreUI-safe frame (origin = below the top bar), so the top bar strip in HUD coordinates is TopbarSafeInsets minus
	-- the None rect's origin. (GuiService.TopbarInset is measured from the camera viewport, which the Studio phone emulator
	-- starts 20 px below the screen top: the nav bottom was read 20 px too high and the left column sat under the Roblox buttons.)
	local okArea = pcall(function()
		local none = GuiService:GetInsetArea(Enum.ScreenInsets.None)
		local bar = GuiService:GetInsetArea(Enum.ScreenInsets.TopbarSafeInsets)
		minX, maxY, maxX = bar.Min.X - none.Min.X, bar.Max.Y - none.Min.Y, bar.Max.X - none.Min.X
		if not (maxY :: number > 0) then
			error("no top bar strip")
		end
	end)
	if not okArea then
		minX, maxY, maxX = nil, nil, nil
		pcall(function()
			local rect = (GuiService :: any).TopbarInset
			if rect then
				minX, maxY, maxX = rect.Min.X, rect.Max.Y, rect.Max.X
			end
		end)
	end
	local nav, live = HudLayoutRules.navFromTopbar(minX, maxY, v.X, v.Y)
	return nav, (if live then "topbar" else "fallback"), (if live then HudLayoutRules.rightLimitFromTopbar(maxX, v.X) else nil)
end

local function build(): Snapshot
	local v = viewport()
	local ins = SafeArea.get()
	local nav, source, rightLimit = readNav(v)
	local kind: HudLayoutRules.Kind = currentKind()
	-- The Roblox leaderboard is not in any inset the engine reports: keep the right column left of it on desktop.
	local listShown = false
	pcall(function()
		listShown = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
	end)
	local topbarLimit = rightLimit
	rightLimit = HudLayoutRules.rightLimitWithPlayerList(rightLimit, v.X, kind, listShown)
	local battle = RaceAttr.mine("RaceMode") == "battle"
	local opts: HudLayoutRules.Options = { battle = battle, rightLimit = rightLimit, minimap = not battle and LocalPlayer:GetAttribute("MinimapOn") == true }
	local rects = HudLayoutRules.compute(v.X, v.Y, ins, nav, kind, opts)
	LocalPlayer:SetAttribute("HudNav", string.format("%d,%d", nav.w, nav.h))
	LocalPlayer:SetAttribute("HudNavSource", source)
	LocalPlayer:SetAttribute("HudRightLimit", rightLimit) -- nil (cleared) when neither TopbarInset.Max.X nor the leaderboard reserve applied
	LocalPlayer:SetAttribute("HudRightLimitSource", if rightLimit == nil then "none" elseif rightLimit ~= topbarLimit then "playerlist" else "topbar")
	LocalPlayer:SetAttribute("HudKind", kind)
	return {
		viewport = v,
		insets = ins,
		nav = nav,
		kind = kind,
		metrics = HudLayoutRules.metrics(v.X, v.Y, ins, kind),
		rects = rects,
	}
end

local function equalRects(a: { [string]: Rect }, b: { [string]: Rect }): boolean
	for k, r in a do
		local o = b[k]
		if not o or o.x ~= r.x or o.y ~= r.y or o.w ~= r.w or o.h ~= r.h then
			return false
		end
	end
	for k in b do
		if not a[k] then
			return false
		end
	end
	return true
end

local function refresh()
	local old = snapshot
	local nextSnap = build()
	if old and equalRects(old.rects, nextSnap.rects) and old.kind == nextSnap.kind then
		snapshot = nextSnap -- same layout: keep listeners quiet
		return
	end
	snapshot = nextSnap
	for _, fn in handlers do
		task.spawn(fn, nextSnap)
	end
end

-- Several triggers can fire in one frame (a rotation moves the viewport, the insets and the nav): re-layout once.
local function markDirty()
	if pending then
		return
	end
	pending = true
	task.defer(function()
		pending = false
		refresh()
	end)
end

function HudMetrics.init()
	if started then
		return
	end
	started = true
	snapshot = build()
	local function watchCamera()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(markDirty)
		end
		markDirty()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()
	SafeArea.onChanged(markDirty)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(markDirty)
	end)
	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(markDirty)
	LocalPlayer:GetAttributeChangedSignal("QANav"):Connect(markDirty)
	LocalPlayer:GetAttributeChangedSignal("MinimapOn"):Connect(markDirty) -- client/Minimap: a race with a centreline is on
	RaceAttr.changed("RaceMode", markDirty)
end

-- TrackFlow's gui.AbsoluteSize (0 until the gui has been laid out); re-lays out when it changes the viewport the rects use.
function HudMetrics.setGuiSize(size: Vector2)
	if guiSize and guiSize == size then
		return
	end
	guiSize = size
	if started then
		markDirty()
	end
end

function HudMetrics.get(): Snapshot
	if not snapshot then
		HudMetrics.init()
	end
	return snapshot :: Snapshot
end

function HudMetrics.rects(): { [string]: Rect }
	return HudMetrics.get().rects
end

function HudMetrics.nav(): Rect
	return HudMetrics.get().nav
end

function HudMetrics.S(): number
	return HudMetrics.get().metrics.S
end

function HudMetrics.kind(): HudLayoutRules.Kind
	return HudMetrics.get().kind
end

-- fn runs whenever the layout changes (not for the value at the time of the call: read HudMetrics.get() for that).
function HudMetrics.onChanged(fn: (Snapshot) -> ())
	table.insert(handlers, fn)
end

return HudMetrics
