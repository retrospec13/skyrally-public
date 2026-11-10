--!strict
-- Camera-occlusion fade (critic v29 Wave 1b A13; C3 reuses it): map structures the chase camera can pass right next to
-- (SPACE-4 sign gantry legs, Glass Vault ribs; any map folder named in FOLDERS) turn see-through on THIS client while
-- the lens is within RADIUS studs of them, so a gantry leg or a rib never fills the frame (space4_03). Pure numbers and
-- maths here (tools/tests/camera_fade_spec.luau); client/CameraFade applies it with LocalTransparencyModifier only:
-- collision, queries, the server copy and every other client are untouched, so wall driving and the corridor are
-- unchanged.
local CameraFadeRules = {}

CameraFadeRules.RADIUS = 12 -- studs from the camera to the part's box: inside this the part is faded
CameraFadeRules.FADE = 0.7 -- LocalTransparencyModifier while faded
CameraFadeRules.TICK = 1 / 30 -- seconds between passes
-- Leaf folder names (plan groups, e.g. "Highway/Gantries" -> Folder Highway / Gantries) whose parts may fade.
CameraFadeRules.FOLDERS = table.freeze({ Gantries = true, GlassVault = true }) :: { [string]: boolean }

-- Distance from point (in the box's own frame: `p` = box.CFrame:PointToObjectSpace(cam)) to a box of half size `half`.
function CameraFadeRules.boxDistance(px: number, py: number, pz: number, hx: number, hy: number, hz: number): number
	local dx = math.max(math.abs(px) - hx, 0)
	local dy = math.max(math.abs(py) - hy, 0)
	local dz = math.max(math.abs(pz) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The fade for a part whose box is `dist` studs from the camera.
function CameraFadeRules.fadeAt(dist: number): number
	return if dist < CameraFadeRules.RADIUS then CameraFadeRules.FADE else 0
end

-- Cheap pre-test: a part whose bounding sphere (centre distance minus radius) is farther than RADIUS cannot fade.
function CameraFadeRules.mayFade(centreDist: number, sphereRadius: number): boolean
	return centreDist - sphereRadius < CameraFadeRules.RADIUS
end

return CameraFadeRules
