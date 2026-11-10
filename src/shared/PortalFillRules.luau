--!strict
-- Maths for the hub portals' swirling fill (client/PortalFill; UI polish: the flat gradient veil is now layered rotating
-- discs plus motes drifting inward). Pure: no Instances, no clock; specced in tools/tests/portal_fill_spec.luau.
local PortalFillRules = {}

PortalFillRules.GRID = 8 -- magic_swirl_8x8: 8 x 8 frames of FRAME_PX each in a 1024 px sheet
PortalFillRules.FRAME_PX = 128

-- ImageRectOffset / ImageRectSize (px) of one sheet frame (0-based, row-major), so a static frame can be an ImageLabel.
function PortalFillRules.frameRect(frame: number): (number, number, number, number)
	local n = PortalFillRules.GRID * PortalFillRules.GRID
	local f = ((math.floor(frame) % n) + n) % n
	local px = PortalFillRules.FRAME_PX
	return (f % PortalFillRules.GRID) * px, math.floor(f / PortalFillRules.GRID) * px, px, px
end

-- n points evenly round a circle of `radius` (local x, y), starting at the top and going clockwise.
function PortalFillRules.ringPoints(n: number, radius: number): { { x: number, y: number } }
	local out = {}
	for i = 0, n - 1 do
		local a = (i / n) * math.pi * 2
		table.insert(out, { x = math.sin(a) * radius, y = math.cos(a) * radius })
	end
	return out
end

-- Speed that carries a mote from the rim to the centre in exactly its lifetime (it fades out at the core).
function PortalFillRules.inwardSpeed(radius: number, lifetime: number): number
	return radius / math.max(lifetime, 1e-3)
end

-- A layer's rotation in degrees (0..360) at time t: deg/s (negative = counter-clockwise) from a starting phase.
function PortalFillRules.angle(t: number, degPerSecond: number, phase: number?): number
	return ((t * degPerSecond + (phase or 0)) % 360 + 360) % 360
end

-- A portal's detail level by distance to the camera: "full" inside range, "far" up to 2 x range (rim and core only, no
-- motes), "off" beyond. Mobile halves the ranges.
function PortalFillRules.tier(distance: number, range: number, mobile: boolean): string
	local r = if mobile then range * 0.5 else range
	if distance <= r then
		return "full"
	elseif distance <= r * 2 then
		return "far"
	end
	return "off"
end

-- Texture to use for a layer: the new portal texture when its id is non-zero, else the fallback (any string).
function PortalFillRules.texOrFallback(id: number?, fallback: string): string
	if id ~= nil and id > 0 then
		return "rbxassetid://" .. tostring(math.floor(id))
	end
	return fallback
end

-- Rim pulse 0..1 (1 = brightest) at time t for a pulse of hz cycles per second.
function PortalFillRules.pulse(t: number, hz: number): number
	return 0.5 + 0.5 * math.sin(t * hz * math.pi * 2)
end

-- Breathing scale about 1: 1 + amount * pulse centred, so a layer swells and shrinks a little without drifting.
function PortalFillRules.breathe(t: number, hz: number, amount: number): number
	return 1 + amount * (PortalFillRules.pulse(t, hz) - 0.5) * 2
end

return PortalFillRules
