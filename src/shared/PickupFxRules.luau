--!strict
-- Pure tuning for the pickup burst colour and collect streak (client/Vfx.onPickup; specced in
-- tools/tests/pickup_fx_spec.luau). No Instances, no clock. Item pods take the colour of their balloon (ItemRules.POD_RGB),
-- the secrets get their own: token gold, key warm gold, gear steel blue, cube violet. Anything else keeps the old cream.
local ItemRules = require(script.Parent:WaitForChild("ItemRules"))

local PickupFxRules = {}

PickupFxRules.DEFAULT_RGB = table.freeze({ 255, 244, 214 }) -- the old cream pickup
local EXTRA_RGB: { [string]: { number } } = {
	token = { 255, 214, 70 },
	key = { 255, 176, 60 },
	gear = { 150, 205, 255 },
	cube = { 190, 120, 255 },
}

function PickupFxRules.colorRgb(kind: string?): { number }
	if kind == nil then
		return PickupFxRules.DEFAULT_RGB
	end
	return EXTRA_RGB[kind] or ItemRules.podRgb(kind) or PickupFxRules.DEFAULT_RGB
end

-- Collect streak (a pooled Beam from the pod to the local vehicle): short, thin at the vehicle end. Phone: no beam.
PickupFxRules.STREAK_LIFE = 0.3
PickupFxRules.STREAK_MAX_DIST = 90 -- a pod farther than this from the vehicle (a hub find across the map) gets no streak
PickupFxRules.STREAK_MIN_SCALE = 0.6

function PickupFxRules.streakOn(dist: number, scale: number): boolean
	return scale >= PickupFxRules.STREAK_MIN_SCALE and dist > 2 and dist <= PickupFxRules.STREAK_MAX_DIST
end

-- Beam width at the vehicle end for the streak's progress 0..1 (the head stays wide, the tail narrows and fades).
function PickupFxRules.streakWidth(k: number): number
	return 1.2 * (1 - math.clamp(k, 0, 1)) + 0.2
end

return PickupFxRules
