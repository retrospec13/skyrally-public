--!strict
-- HUD safe area (TEST_LIST_LAUNCH L28 phone notch and rounded corners, L82 5 percent TV-safe area; audit H15).
-- Pure: no Instances, no clock, specced in tools/tests/onboarding_spec.luau. The world stays full-bleed; only the HUD's
-- frames keep inside these insets (client/SafeArea reads the device numbers, RaceUI / HudExtras / TrackFlow apply them).
local SafeAreaRules = {}

export type Insets = { left: number, top: number, right: number, bottom: number }

SafeAreaRules.TV_FRACTION = 0.05 -- each edge, console / ten-foot interface (L82)
SafeAreaRules.MAX_FRACTION = 0.2 -- a device inset larger than this share of the short side is a bad reading, not a notch

SafeAreaRules.NONE = { left = 0, top = 0, right = 0, bottom = 0 } :: Insets

local function clean(v: any, limit: number): number
	if type(v) ~= "number" or v ~= v or v < 0 then
		return 0
	end
	return math.floor(math.min(v, limit) + 0.5)
end

-- Insets from the device's safe rectangle inside the full screen (GuiService:GetInsetArea(DeviceSafeInsets) in px).
function SafeAreaRules.fromRect(viewW: number, viewH: number, minX: number, minY: number, maxX: number, maxY: number): Insets
	local limit = math.min(viewW, viewH) * SafeAreaRules.MAX_FRACTION
	return {
		left = clean(minX, limit),
		top = clean(minY, limit),
		right = clean(viewW - maxX, limit),
		bottom = clean(viewH - maxY, limit),
	}
end

-- Insets from GuiService:GetSafeZoneOffsets-style numbers (px from each edge), for devices that report those instead.
function SafeAreaRules.fromOffsets(viewW: number, viewH: number, left: any, top: any, right: any, bottom: any): Insets
	local limit = math.min(viewW, viewH) * SafeAreaRules.MAX_FRACTION
	return { left = clean(left, limit), top = clean(top, limit), right = clean(right, limit), bottom = clean(bottom, limit) }
end

-- The insets the HUD uses: the device's, raised to 5 percent of each side on a ten-foot interface (a TV overscans).
function SafeAreaRules.compute(viewW: number, viewH: number, device: Insets?, tenFoot: boolean): Insets
	local d = device or SafeAreaRules.NONE
	local limit = math.min(viewW, viewH) * SafeAreaRules.MAX_FRACTION
	local out: Insets = {
		left = clean(d.left, limit),
		top = clean(d.top, limit),
		right = clean(d.right, limit),
		bottom = clean(d.bottom, limit),
	}
	if tenFoot then
		local tvX = math.floor(viewW * SafeAreaRules.TV_FRACTION + 0.5)
		local tvY = math.floor(viewH * SafeAreaRules.TV_FRACTION + 0.5)
		out.left = math.max(out.left, tvX)
		out.right = math.max(out.right, tvX)
		out.top = math.max(out.top, tvY)
		out.bottom = math.max(out.bottom, tvY)
	end
	return out
end

function SafeAreaRules.equal(a: Insets, b: Insets): boolean
	return a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom
end

return SafeAreaRules
