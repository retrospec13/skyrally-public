--!strict
-- World labels of a battle on a phone (v22 HUD polish): "X'S NEST" billboards used to be one fixed size, overlap each other,
-- get cut by pillars and sit under the HUD. Pure rules, no Instances; specced in tools/tests/world_label_spec.luau.
-- client/TrackFlow applies them every 0.15 s (size, text) and every ~0.5 s per label (the occlusion raycast).
local WorldLabelRules = {}

WorldLabelRules.BASE_W = 170 -- the server's billboard size (Egg / Hoard) at scale 1
WorldLabelRules.BASE_H = 28
WorldLabelRules.REF_DIST = 70 -- studs: full size inside this, shrinking as 1 / distance beyond it
WorldLabelRules.MIN_K = 0.5 -- the distance factor never goes below this (a far label stays readable)
WorldLabelRules.NEAR_TEXT = 90 -- studs: inside this the label reads "NAME'S NEST", beyond it only the (shorter) name
WorldLabelRules.NAME_NEAR = 10 -- characters of the owner's name kept near / far
WorldLabelRules.NAME_FAR = 7
WorldLabelRules.OCCLUDED_TICKS = 2 -- consecutive blocked rays before a label hides (one stray ray does not flicker it)
WorldLabelRules.OCCLUSION_INTERVAL = 0.5 -- seconds between a label's rays
WorldLabelRules.WALL_SLACK = 4 -- studs: a hit this close to the anchor is the anchor's own ring, not a wall

-- Size factor of a label at `dist` studs. hudScale = the HUD scale (HudLayoutRules.metrics S), which already shrinks phones.
function WorldLabelRules.scale(dist: number, hudScale: number): number
	local base = math.clamp(hudScale + 0.2, 0.7, 1)
	local k = math.clamp(WorldLabelRules.REF_DIST / math.max(dist, 1), WorldLabelRules.MIN_K, 1)
	return base * k
end

-- Pixel size of the billboard at that scale (never under 60 x 14).
function WorldLabelRules.size(scale: number): (number, number)
	return math.max(60, math.floor(WorldLabelRules.BASE_W * scale)), math.max(14, math.floor(WorldLabelRules.BASE_H * scale))
end

local function clip(name: string, n: number): string
	if #name <= n then
		return name
	end
	return string.sub(name, 1, n - 1) .. "."
end

-- "ALEXANDRIA'S NEST" -> the owner's name ("ALEXANDRIA"), or nil when the caption is not a nest caption ("EGG", "+5").
function WorldLabelRules.ownerName(caption: string): string?
	return string.match(caption, "^(.+)'S NEST$")
end

-- The text for a label `dist` studs away: nest captions are shortened (near: "NAME'S NEST", far: "NAME"); anything else is kept.
function WorldLabelRules.shortText(caption: string, dist: number): string
	local name = WorldLabelRules.ownerName(caption)
	if not name then
		return caption
	end
	if dist <= WorldLabelRules.NEAR_TEXT then
		return clip(name, WorldLabelRules.NAME_NEAR) .. "'S NEST"
	end
	return clip(name, WorldLabelRules.NAME_FAR)
end

-- Did a ray from the camera to the label's anchor hit geometry in front of it? hitDist = distance of the first hit (nil: clear).
function WorldLabelRules.blocked(hitDist: number?, anchorDist: number): boolean
	return hitDist ~= nil and hitDist < anchorDist - WorldLabelRules.WALL_SLACK
end

-- Debounce: the new count of consecutive blocked rays and whether the label hides.
function WorldLabelRules.occlusionStep(count: number, isBlocked: boolean): (number, boolean)
	local n = if isBlocked then math.min(count + 1, WorldLabelRules.OCCLUDED_TICKS) else 0
	return n, n >= WorldLabelRules.OCCLUDED_TICKS
end

-- Does a label of w x h px centred on (x, y) touch any keep-clear rect (4 px margin)?
function WorldLabelRules.overlapsAny(x: number, y: number, w: number, h: number, keep: { { x: number, y: number, w: number, h: number } }): boolean
	for _, r in keep do
		if x + w / 2 > r.x - 4 and x - w / 2 < r.x + r.w + 4 and y + h / 2 > r.y - 4 and y - h / 2 < r.y + r.h + 4 then
			return true
		end
	end
	return false
end

return WorldLabelRules
