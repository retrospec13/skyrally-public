--!strict
-- Camera-near fade (visual critic v29 Wave 1b C2: the DINO-4 fossil rib gates caged the chase camera). Pure rules for
-- client/CameraNearFade.
--
-- A map marks a decorative container (a Folder or Model, through the plan's modelAttributes) with the number attribute
-- ATTR = the fade radius in studs. Every BasePart inside it fades on this client only (LocalTransparencyModifier) when
-- the camera comes within that radius of the part's surface: fully hidden inside radius * HIDE_FRACTION, drawn again
-- at the radius, linear between. Collision, queries and the server are untouched (the marked dressing is non-colliding
-- art anyway; the wall-driving rule never sees this). Studio A/B: workspace attribute OFF_ATTR = true stops the fade.
local CameraNearFadeRules = {}

CameraNearFadeRules.ATTR = "CameraNearFade" -- number: fade radius in studs, on a Folder/Model (plan modelAttributes)
CameraNearFadeRules.OFF_ATTR = "CameraNearFadeOff" -- workspace attribute: true restores every part
CameraNearFadeRules.HIDE_FRACTION = 0.5 -- fully hidden inside radius * this
CameraNearFadeRules.MIN_RADIUS = 4
CameraNearFadeRules.MAX_RADIUS = 120
CameraNearFadeRules.SCAN_EVERY = 2.5 -- seconds between container scans (a map switch builds new containers)
CameraNearFadeRules.SCAN_DEPTH = 5 -- container search depth under workspace (Folders and Models only)

-- The radius a container asks for, or nil when the attribute is missing or not a usable number.
function CameraNearFadeRules.radius(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	if value <= 0 then
		return nil
	end
	return math.clamp(value, CameraNearFadeRules.MIN_RADIUS, CameraNearFadeRules.MAX_RADIUS)
end

-- LocalTransparencyModifier for a part whose surface is `dist` studs from the camera (dist <= 0: the camera is inside).
function CameraNearFadeRules.modifier(dist: number, radius: number): number
	local hide = radius * CameraNearFadeRules.HIDE_FRACTION
	if dist <= hide then
		return 1
	end
	if dist >= radius then
		return 0
	end
	return (radius - dist) / (radius - hide)
end

-- Approximate surface distance: centre distance less the part's bounding radius (half its diagonal), never negative.
function CameraNearFadeRules.surfaceDistance(centreDist: number, size: Vector3): number
	return math.max(0, centreDist - size.Magnitude * 0.5)
end

return CameraNearFadeRules
