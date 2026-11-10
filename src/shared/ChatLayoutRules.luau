--!strict
-- Chat window + PlayerList placement rules (pure, no Roblox globals; tools/tests/chat_layout_spec.luau runs it under Lune).
-- The default Roblox chat sits top-left over the HUD and the PlayerList (top-right) sits over the minimap / position badge.
-- Owner request: chat small and bottom-left, PlayerList out of the way while racing. client/ChatLayout.luau is the applier.
-- Geometry mirrors docs/design/HUD_MK_LAYOUT.md and HudLayoutRules without requiring it (the steer pad is the bottom-left
-- thumb control on touch, the minimap owns the left edge under the Roblox nav during countdown / race).

local ChatLayoutRules = {}

export type Phase = "hub" | "countdown" | "race" | "finish" | "results" | "podium" | "battle"
export type Config = {
	horizontal: string, -- Enum.HorizontalAlignment name
	vertical: string, -- Enum.VerticalAlignment name
	widthScale: number,
	heightScale: number,
	textSize: number,
	backgroundTransparency: number,
}

ChatLayoutRules.COMPACT_W = 700 -- touch widths at or below this are "compact"
ChatLayoutRules.NAV_BOTTOM = 76 -- Roblox nav owns y 0-76 at the left
ChatLayoutRules.DESKTOP_NAV_BOTTOM = 78 -- desktop top bar as measured in Studio (HudLayoutRules falls back to 58)
-- Racing left column (HudLayoutRules MK layout): touch = minimap with the token chip (28 px) and the AUTO pill (44 px) stacked right of it,
-- so the column is as tall as max(minimap, token + 4 + pill); desktop = minimap, 4 px, token chip (46 * S).
ChatLayoutRules.TOUCH_SIDE_STACK = 28 + 4 + 44
ChatLayoutRules.MIN_PX_W = 200
ChatLayoutRules.MIN_PX_H = 84
ChatLayoutRules.MIN_TEXT = 12

local function clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

function ChatLayoutRules.racing(phase: string): boolean
	return phase == "countdown" or phase == "race"
end

-- Steer pad side (shared with HudLayoutRules.thumbSizes, kept in sync by chat_layout_spec).
function ChatLayoutRules.padSide(vpY: number): number
	if vpY >= 600 then
		return 226
	elseif vpY <= 375 then
		return 126
	end
	return 146
end

-- Minimap side on touch (HudLayoutRules.minimapSize: 23% of the height, 72-110; 64 on compact phones).
function ChatLayoutRules.minimapSide(vpX: number, vpY: number): number
	if vpX <= ChatLayoutRules.COMPACT_W then
		return 64
	end
	return clamp(math.floor(vpY * 0.23), 72, 110)
end

-- Minimap side on desktop (HudLayoutRules.minimapSize: 22% of the height, 90-220).
function ChatLayoutRules.desktopMinimapSide(vpY: number): number
	return clamp(math.floor(vpY * 0.22 + 0.5), 90, 220)
end

-- Pixel rect the window occupies for a Config (HorizontalAlignment Left; Bottom or Center), for the tests.
function ChatLayoutRules.rect(cfg: Config, vpX: number, vpY: number): { x: number, y: number, w: number, h: number }
	local w, h = cfg.widthScale * vpX, cfg.heightScale * vpY
	local y = if cfg.vertical == "Bottom" then vpY - h elseif cfg.vertical == "Top" then 0 else (vpY - h) / 2
	return { x = 0, y = y, w = w, h = h }
end

function ChatLayoutRules.compute(vpX: number, vpY: number, touch: boolean, phase: string): Config
	vpX = math.max(vpX, 1)
	vpY = math.max(vpY, 1)
	local compact = touch and vpX <= ChatLayoutRules.COMPACT_W
	local w = clamp(if compact then 0.30 else 0.26, 0, 0.5)
	w = math.max(w, ChatLayoutRules.MIN_PX_W / vpX)
	local textSize = if vpY >= 600 then 16 elseif vpY >= 420 then 14 else ChatLayoutRules.MIN_TEXT
	local hPx = clamp(vpY * (if touch then 0.22 else 0.24), ChatLayoutRules.MIN_PX_H, 260)
	if not touch then
		-- Desktop: bottom-left in the hub, results, podium and battle. While racing the controls hint chip owns the bottom-left corner
		-- (and the window cannot be offset), so the window is centred on the left edge instead, shortened to fit under the minimap and
		-- the token chip. Too short a window for that falls back to the bottom.
		if ChatLayoutRules.racing(phase) and vpY > 450 then
			local S = clamp(vpY / 1080, 0.75, 1)
			local stack = ChatLayoutRules.DESKTOP_NAV_BOTTOM + 8 + ChatLayoutRules.desktopMinimapSide(vpY) + 4 + math.floor(46 * S + 0.5) + 6
			local fit = 2 * (vpY / 2 - stack)
			if fit >= ChatLayoutRules.MIN_PX_H then
				return {
					horizontal = "Left",
					vertical = "Center",
					widthScale = w,
					heightScale = math.min(hPx, fit) / vpY,
					textSize = textSize,
					backgroundTransparency = 0.6,
				}
			end
		end
		return {
			horizontal = "Left",
			vertical = "Bottom",
			widthScale = w,
			heightScale = hPx / vpY,
			textSize = textSize,
			backgroundTransparency = 0.45,
		}
	end
	-- Touch: the steer pad owns the bottom-left corner, so the window is centred on the left edge instead, in the band
	-- between the minimap (or the nav) and the pad. A centred window cannot be asymmetric, so it is cut to what fits.
	local top = ChatLayoutRules.NAV_BOTTOM + 6
	if ChatLayoutRules.racing(phase) then
		top = ChatLayoutRules.NAV_BOTTOM + 8 + math.max(ChatLayoutRules.minimapSide(vpX, vpY), ChatLayoutRules.TOUCH_SIDE_STACK) + 6
	end
	local bottom = vpY - ChatLayoutRules.padSide(vpY) - 34 -- 34 = the pad's bottom margin (10) + a notch phone's 21 px bottom inset + 3 air
	local half = math.min(vpY / 2 - top, bottom - vpY / 2)
	local fit = math.max(2 * half, 0)
	-- Never smaller than two lines of text (so it stays usable); the background goes lighter while racing.
	local minH = textSize * 2 + 8
	hPx = math.max(math.min(hPx, fit), minH)
	return {
		horizontal = "Left",
		vertical = "Center",
		widthScale = w,
		heightScale = hPx / vpY,
		textSize = textSize,
		backgroundTransparency = if ChatLayoutRules.racing(phase) then 0.6 else 0.45,
	}
end

-- The Roblox PlayerList: hidden while racing (countdown / race); on compact touch also hidden in the finish moment is not
-- needed (the results card owns the screen). Shown in the hub, results, podium and battle.
function ChatLayoutRules.playerListVisible(vpX: number, touch: boolean, phase: string): boolean
	if ChatLayoutRules.racing(phase) then
		return false
	end
	if touch and vpX <= ChatLayoutRules.COMPACT_W and phase == "finish" then
		return false
	end
	return true
end

return ChatLayoutRules
