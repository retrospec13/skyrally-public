--!strict
-- Pure tuning and decisions for the particle shield / respawn-protection bubble (client/ItemClient addBubble) and the
-- lakitu-style respawn return (client/Vfx respawn presets): which layers run per quality tier, how see-through the hex
-- billboard stays, when it hides near the camera, and the last-second sparkle boost. No Instances, no clock:
-- tools/tests/item_fx_spec.luau pins the camera-safety numbers down.
local ItemFxRules = {}

-- The camera-facing hex billboard is ~10 studs across; it never gets more opaque than this, so it veils nothing.
ItemFxRules.HEX_MAX_OPACITY = 0.18 -- 1 - transparency
ItemFxRules.HEX_TRANSPARENCY = 0.84
ItemFxRules.HEX_BLINK_TRANSPARENCY = 0.94
ItemFxRules.REMOTE_HEX_TRANSPARENCY = 0.74 -- v21: a RIVAL's shield (far from the chase camera, its billboard hides inside CAMERA_NEAR) reads at 26 % opacity
ItemFxRules.RESPAWN_HEX_TRANSPARENCY = 0.88 -- the respawn bubble is fainter than the Yellow shield
ItemFxRules.CAMERA_NEAR = 12 -- studs: a bubble's billboard layers hide when the camera is this close (rival in your face)
ItemFxRules.BLINK_WINDOW = 1 -- seconds left when the Yellow shield starts to blink
ItemFxRules.LAST_SPARKLE_MUL = 3 -- edge sparkle rate multiplier over the blink window
ItemFxRules.RING_PERIOD = 0.9 -- seconds between rim ring pulses

export type Layers = { hex: boolean, swirl: boolean, edge: boolean, ring: boolean, shimmer: boolean }

-- Which bubble layers exist for a quality tier. Phone drops the swirl and the ring (audit item 6); low graphics keeps
-- just the hex billboard and the edge sparkles (shield) or the shimmer (respawn).
-- v39 (owner: "I don't like the shields and bubbles"): respawn protection draws no hex shell any more, only the star
-- shimmer round the hull (and the local car's invulnerability blink, CarController); the hex stays for the shield.
function ItemFxRules.bubbleLayers(respawn: boolean, phone: boolean, low: boolean): Layers
	return {
		hex = not respawn,
		swirl = not respawn and not phone and not low,
		edge = not respawn,
		ring = not respawn and not phone and not low,
		shimmer = respawn,
	}
end

-- Transparency of the hex billboard. Always >= 0.8 so the 10 stud sprite never fills the chase camera's view.
function ItemFxRules.hexTransparency(respawn: boolean, blink: boolean): number
	if blink then
		return ItemFxRules.HEX_BLINK_TRANSPARENCY
	end
	return if respawn then ItemFxRules.RESPAWN_HEX_TRANSPARENCY else ItemFxRules.HEX_TRANSPARENCY
end

-- ---------------------------------------------------------------- dropped trap (mine) read
-- v22: after v21 the dropped mine was nearly invisible (tiny puff, one shard). Old -> new: ring 4.2 -> 5.5 studs, puff count 3 -> 5,
-- shards 4 (unchanged), plus a short arming blink on the trap itself. Everything stays at the hull's tail, low, never over the camera.
ItemFxRules.TRAP_DROP = {
	ring = 5.5, -- studs across (ItemClient trapDrop ring)
	puffCount = 5,
	blinks = 3, -- quick red / white flashes on the dropped trap
	blinkSeconds = 0.6, -- the whole blink sequence
}

-- State of the arming blink at step i (0-based, two steps per flash: on then off): "red", "white" or nil (off). Flashes alternate
-- red, white, red; nil past the last step.
function ItemFxRules.armBlinkAt(i: number): string?
	local D = ItemFxRules.TRAP_DROP
	if i < 0 or i >= D.blinks * 2 or i % 2 == 1 then
		return nil
	end
	return if (i // 2) % 2 == 0 then "red" else "white"
end

-- Seconds per blink step (on or off).
function ItemFxRules.armBlinkStep(): number
	return ItemFxRules.TRAP_DROP.blinkSeconds / (ItemFxRules.TRAP_DROP.blinks * 2)
end

-- Whether the Yellow shield is in its blink window (the last second).
function ItemFxRules.blinking(left: number): boolean
	return left < ItemFxRules.BLINK_WINDOW and math.floor(left * 8) % 2 == 0
end

-- Edge sparkle rate multiplier: x3 over the last second instead of the old mesh blink.
function ItemFxRules.edgeRateMul(left: number): number
	return if left < ItemFxRules.BLINK_WINDOW then ItemFxRules.LAST_SPARKLE_MUL else 1
end

-- Billboard layers (hex, ring) run only with the camera at a safe distance and inside the cull range.
function ItemFxRules.billboardOn(camDist: number?, cull: number): boolean
	return camDist ~= nil and camDist >= ItemFxRules.CAMERA_NEAR and camDist < cull
end

-- Sparkle layers (swirl, edge, shimmer) only need the cull range.
function ItemFxRules.sparkleOn(camDist: number?, cull: number): boolean
	return camDist ~= nil and camDist < cull
end

-- ---------------------------------------------------------------- respawn return
export type Respawn = { cloud: boolean, column: boolean, sparkle: boolean }

-- Respawn burst layers: clouds always (halved by particleScale on phone), the descending light column not on phone.
function ItemFxRules.respawnLayers(phone: boolean, low: boolean): Respawn
	return { cloud = true, column = not phone and not low, sparkle = true }
end

-- The light column starts this far above the hull and lowers onto it (studs); it ends on the hull, never past it.
ItemFxRules.COLUMN_HEIGHT = 16
ItemFxRules.COLUMN_LIFE = 0.6

function ItemFxRules.columnSpeed(): number
	return ItemFxRules.COLUMN_HEIGHT / ItemFxRules.COLUMN_LIFE
end

-- ---------------------------------------------------------------- status shots (Frost Shot, Coin Burst): camera safety
-- Studio V9 (g3, i2s_dino4_B): the frost shard burst and the server's 2.4 stud coin discs filled most of the chase view.
-- Bursts for these two stay small and never start inside CAMERA_NEAR; coins are drawn at COIN_SCALE and fade out well
-- before they reach the lens; no single sprite may cover more than MAX_COVERAGE of the view height.
ItemFxRules.STATUS_BURST_SCALE = 0.5 -- of the classic blast
ItemFxRules.STATUS_BURST_SCALE_SELF = 0.3 -- when it is this player's own kart (the camera sits just behind it)
ItemFxRules.COIN_SCALE = 0.5 -- the server's coin disc (2.4 studs) is drawn this fraction of its size on the client
ItemFxRules.COIN_FADE_FAR = 26 -- studs: a coin is fully visible from here out
ItemFxRules.MAX_COVERAGE = 0.12 -- fraction of the view height one effect sprite may fill

function ItemFxRules.isStatusSource(source: string?): boolean
	return source == "frost_shot" or source == "coin_burst"
end

-- Scale for the hit burst of a status shot at camDist studs from the camera; nil: skip it (too close or no camera).
-- Other sources keep their own look (1).
function ItemFxRules.statusBurstScale(source: string?, onMe: boolean, camDist: number?): number?
	if not ItemFxRules.isStatusSource(source) then
		return 1
	end
	if camDist == nil or camDist < ItemFxRules.CAMERA_NEAR then
		return nil
	end
	return if onMe then ItemFxRules.STATUS_BURST_SCALE_SELF else ItemFxRules.STATUS_BURST_SCALE
end

-- Transparency of a coin disc at camDist: 1 (gone) inside CAMERA_NEAR, easing to 0 at COIN_FADE_FAR.
function ItemFxRules.coinTransparency(camDist: number): number
	local near, far = ItemFxRules.CAMERA_NEAR, ItemFxRules.COIN_FADE_FAR
	if camDist <= near then
		return 1
	end
	if camDist >= far then
		return 0
	end
	return 1 - (camDist - near) / (far - near)
end

-- Fraction of the view height a sprite of `size` studs fills at camDist (vertical field of view in degrees).
function ItemFxRules.screenFraction(size: number, camDist: number, fovDeg: number): number
	local d = math.max(camDist, 0.01)
	return size / (2 * d * math.tan(math.rad(fovDeg) * 0.5))
end

-- The biggest sprite (studs) that stays within MAX_COVERAGE at camDist.
function ItemFxRules.maxSpriteSize(camDist: number, fovDeg: number): number
	return ItemFxRules.MAX_COVERAGE * 2 * math.max(camDist, 0.01) * math.tan(math.rad(fovDeg) * 0.5)
end

return ItemFxRules
