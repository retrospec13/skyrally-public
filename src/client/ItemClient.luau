--!strict
-- Client side of race items (TEST_LIST_LAUNCH L07): renders what the server decided, never decides anything.
-- * ItemRemote events: "ItemState" (what I hold) -> HUD slot; "ItemUsed" (I fired) -> HUD fire kick + sound;
--   "ItemEffect" (applies to my plane: boost, hit, magnet, shield) -> FlightController.applyItemEffect (this client
--   owns the hull) + a toast; "ItemFx" (everyone sees it) -> explosions, shield bubbles, magnet beams, dizzy stars.
-- * Projectiles and traps are server parts under workspace.SkyRallyItemFX. Missiles get a smoothed local copy with a
--   trail and flame (the replicated anchored part steps at network rate; the copy eases toward it every frame), traps
--   a blinking light and a slow spin (client-only writes, so the blink costs no bandwidth).
-- * Item pods get a soft glow of their item colour, and Rainbow pods cycle hue, so item pods read apart from the
--   Speed/Air pods at phone size.
-- * Pickup art (shared/ItemArt, owner: the pods "are plain looking blocks"): the server builds each pod's
--   <name>_CoreVisual as a balloon (item colours) or swirl (Air) MeshPart, or the mint boost block (Speed, cubes v3), with
--   a PointLight; this client drives ONE shared loop over every pod near the camera: balloons bob and sway with their item
--   icon on a billboard held on the camera side, boost blocks turn upright, swirls twist. When OnCooldown turns on the
--   balloon pops (confetti burst in the pod colour plus the PayoffAudio confetti_pop), when it turns off it re-inflates
--   with a little overshoot.
--   Race item pods are mystery cubes (ItemArt.buildMysteryCube, MysteryCube attribute): the same loop tumbles each
--   near cube through 360 degrees on three axes and bobs it, moving the glass and its 21 frame parts (12 edges, 8 corners, glow core) in ONE
--   workspace:BulkMoveTo for every cube per frame. Cubes v2 (owner 2026-10-20: "Make the ? boost/item boxes rotating
--   different colors of and have a ghost siluhouette of the items as they rotate through"): ONE shared clock walks
--   ItemRules.ghostFor (the items this racer could roll from its band, each shown for a share of the cycle equal to its
--   roll chance; holding an item, only that item, since a cube upgrades it), the glass, core, halo and light crossfade
--   through the item colours, and inside the glass a faint ghost icon of the item on show swaps with it (one billboard
--   per cube; writes only when the shared colour moves). The item itself is still rolled on the server when the cube is
--   taken. Cubes v3: every race pod is shared (OnCooldown hides it for everyone for 1.0 s); the taker's own claim
--   (client/PodLocal) pops it a round trip early. The glass and frame keep the cube's family colour (gold, blue, green,
--   red, violet: the owner's multicolour mockup); the item cycle drives the core, halo, light and ghost icon.
--   Taken: a glass-shard pop; back: it grows in with an overshoot. Cubes past CUBES.animRange (LOW GRAPHICS:
--   CUBE_LOW_RANGE) hold still; low graphics also drops the light, the halo and the shards. A fresh roll's HUD roulette
--   lives in HudExtras.setItem.
--   Missiles use the missile mesh (nose -Z, rolling) with a smoke puff at launch, mines the mine mesh the server built,
--   the Yellow shield is particles only (a faint camera-facing shield_hex billboard behind the hull, swirl, rim ring and edge
--   sparkles; ItemFxRules). Hitboxes and timings are untouched.
-- Textures: the owned flip_v2 flipbook sheets through Shared.FlipFx (explosion, smoke, shockwave, fire loop, sparkle;
-- the old VfxAssets texture only when a sheet id is missing) plus single-frame VfxAssets sparks/debris/trails. Boss
-- hazard hits (source "boss_<kind>") play the hazard's own impact from Vfx.onHazardHit. Restraint as in Vfx: nothing
-- covers the route, no full-screen flash, emitter counts capped.
-- Trap audit G2 and X-01: "respawnShield" puts a pale shimmering bubble on a vehicle for its server-side respawn
-- protection (a missile or trap that reaches it pops with the "blocked" puff, and the owner gets a SAFE! toast); an
-- "explode" with wall = true is a shot that met a wall or a hull: the blast plus a spray of chips, and a thunk and a
-- camera kick when it lands near this player. A "hit" that reaches this client inside its own respawn invulnerability
-- (FlightController / CarController invulnTimer) is ignored, as a car's spin-out already was.
-- REMARKABLE Batch 2 (items 14, 18, 19; sounds, HUD and soot in client/ItemJuice, world text in client/RivalBubbles):
-- "IncomingItem" -> beeps + the INCOMING badge, DODGED! when the shot misses; an item hit on this player is a hit
-- knock (plus circling birdies) instead of the crash thud, and every hit vehicle goes sooty for a
-- few seconds (Highlight overlay); "ItemGrudge" -> HIT <NAME> / HIT BY <NAME> / EVEN <NAME> and the PAYBACK tag over
-- whoever hit you; "BotTaunt" -> a bot's speech bubble. A homing shot locked on this player blinks with the beeps.
-- Magnet v2 (client/MagnetAim): a held Rainbow item aims at the closest racer (reticle + range readout + particle
-- tether, holder only); a press with nobody in range still spends it (server pulse); the server's "magnet" lock and the vehicle's
-- contact (FlightController.onMagnetArrive: CAUGHT! + a pop, no stun for them) drive it; "magnetMiss" is the server
-- disagreeing with the preview (lag); "magnetArrive" ItemFx pops for everyone else.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local ItemArt = require(Shared:WaitForChild("ItemArt"))
local ItemTexAssets = require(Shared:WaitForChild("ItemTexAssets")) :: { [string]: string }
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local FlightController = require(script.Parent:WaitForChild("FlightController"))
local HudExtras = require(script.Parent:WaitForChild("HudExtras"))
local SoundJuice = require(script.Parent:WaitForChild("SoundJuice"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local Vfx = require(script.Parent:WaitForChild("Vfx"))
local ItemJuice = require(script.Parent:WaitForChild("ItemJuice"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local RivalBubbles = require(script.Parent:WaitForChild("RivalBubbles"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local ItemFxRules = require(Shared:WaitForChild("ItemFxRules"))
local Sfx37 = require(script.Parent:WaitForChild("Sfx37"))
local ItemsV4Fx = require(script.Parent:WaitForChild("ItemsV4Fx")) -- items v4 look (rocket, storm, bomb, coins, rings)
local ItemShow = require(script.Parent:WaitForChild("ItemShow")) -- v37 spectacle (lightning, comet, frost, screen payoff)
local ItemsV5Fx = require(script.Parent:WaitForChild("ItemsV5Fx")) -- v38 verbs: horn ring, ink, steal, coin pouch
local PodLocal = require(script.Parent:WaitForChild("PodLocal"))
local MagnetAim = require(script.Parent:WaitForChild("MagnetAim"))
local RespawnRules = require(Shared:WaitForChild("RespawnRules"))
local MissileRules = require(Shared:WaitForChild("MissileRules"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))
local UiSkin = require(script.Parent:WaitForChild("UiSkin")) -- uifix: the hit banner icon

local LocalPlayer = Players.LocalPlayer

local ItemClient = {}

local FX_FOLDER = "SkyRallyItemFX" -- ItemEffects.FX_FOLDER (server module; not reachable from the client)

type Toast = (msg: string, color: Color3?, duration: number?) -> ()

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function rgb(t: { number }?): Color3
	if not t then
		return Color3.new(1, 1, 1)
	end
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

local function hullOf(plane: any): BasePart?
	if typeof(plane) == "Instance" and plane:IsA("Model") and plane.Parent then
		local hull = plane.PrimaryPart or plane:FindFirstChild("Hull")
		if hull and hull:IsA("BasePart") then
			return hull
		end
	end
	return nil
end

-- Whether a vehicle model is this player's own (Car_<name> / Plane_<name> under workspace.Planes), and whether an
-- item's Owner / a missile's Target attribute names this player: the sfx_v2 item cues are full volume for what happens
-- to you and quieter for everyone else's.
local function ownVehicle(plane: Instance?): boolean
	return plane ~= nil and (plane.Name == "Car_" .. LocalPlayer.Name or plane.Name == "Plane_" .. LocalPlayer.Name)
end

local function ownRacerId(): string
	return "player:" .. tostring(LocalPlayer.UserId)
end

------------------------------------------------------------------------------------------------------------------------
-- Burst presets (item effects only; same structure as Vfx's pool)
------------------------------------------------------------------------------------------------------------------------

type Burst = {
	tex: string,
	count: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: Vector2,
	size: NumberSequence,
	transparency: NumberSequence,
	color: ColorSequence,
	light: number,
	accel: Vector3?,
	drag: number?,
	flipbook: boolean?,
	orient: Enum.ParticleOrientation?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	zOffset: number?,
	fbSize: NumberSequence?, -- size when the old fallback texture stands in for a flip_v2 sheet
	flash: boolean?, -- a bright flash layer: the local victim's own variant (missileBlastSelf) leaves it out
	keepColor: boolean?, -- ignore the per-call tint (a layer with its own fixed colour, e.g. gold sparkles)
	dir: Enum.NormalId?, -- emission direction (default Front); Top for crowns that rise off the ground
}

local ORANGE = Color3.fromRGB(255, 140, 50)
local CREAM = Color3.fromRGB(255, 244, 214)
local SHIELD_YELLOW = rgb(ItemRules.COLOR_RGB.yellow)
local RESPAWN_BUBBLE = Color3.fromRGB(170, 236, 255) -- pale sky blue: reads as "safe", never as the Yellow item
local WALL_KICK_RANGE = 45 -- a shot that hits a wall this close to the local vehicle thunks and kicks the camera
local TRAP_GREEN = rgb(ItemRules.COLOR_RGB.green)

-- shockwave_8x8 ring (constant size: the ring grows inside the sheet; the old flat ring fallback grows instead).
local function ring(size: number, life: number, color: ColorSequence, count: number?): Burst
	return { tex = "shockwave_8x8", count = count or 1, lifetime = NumberRange.new(life, life * 1.15), speed = NumberRange.new(0.01), spread = Vector2.zero,
		size = ns({ { 0, size }, { 1, size } }), transparency = ns({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } }), color = color,
		light = 0.7, orient = Enum.ParticleOrientation.VelocityPerpendicular, zOffset = 0.5, fbSize = ns({ { 0, size * 0.25 }, { 1, size * 1.2 } }) }
end

local BURSTS: { [string]: { Burst } } = {
	-- Missile / trap hit: explosion_8x8 fireball rolling into smoke, a shockwave ring, sparks, debris, smoke_puff_8x8.
	-- Readability pass: the fireball is 8 studs and the smoke 4-7 (was 13 and 7-11), all pushed away from the camera
	-- (negative ZOffset, smoke rising; ItemClient.burst also offsets the origin up and away), plus a 0.1 s glow flash
	-- and a PointLight spike (LIGHT_SPIKES). The local victim gets missileBlastSelf (no flash, thinner fireball).
	missileBlast = {
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(0.8, 0.95), speed = NumberRange.new(0, 2), spread = Vector2.new(180, 180),
			size = ns({ { 0, 8 }, { 1, 8 } }), transparency = ns({ { 0, 0.05 }, { 1, 0.2 } }), color = ColorSequence.new(Color3.new(1, 1, 1)),
			light = 0.35, rotation = NumberRange.new(0, 360), zOffset = -1, fbSize = ns({ { 0, 5 }, { 1, 9 } }) },
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 9 } }), transparency = ns({ { 0, 0.25 }, { 1, 1 } }), color = ColorSequence.new(CREAM, ORANGE),
			light = 1, zOffset = -1, flash = true },
		ring(16, 0.45, ColorSequence.new(CREAM, ORANGE)),
		{ tex = "spark_streak", count = 20, lifetime = NumberRange.new(0.3, 0.6), speed = NumberRange.new(40, 90), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.5 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, ORANGE),
			light = 1, accel = Vector3.new(0, -80, 0), drag = 1.5, orient = Enum.ParticleOrientation.VelocityParallel },
		{ tex = "debris_shard", count = 8, lifetime = NumberRange.new(0.7, 1.1), speed = NumberRange.new(25, 55), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.2 }, { 1, 0.8 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(110, 96, 90), Color3.fromRGB(60, 52, 50)),
			light = 0, accel = Vector3.new(0, -120, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-360, 360) },
		{ tex = "smoke_puff_8x8", count = 3, lifetime = NumberRange.new(1, 1.3), speed = NumberRange.new(3, 7), spread = Vector2.new(60, 60),
			size = ns({ { 0, 4 }, { 1, 7 } }), transparency = ns({ { 0, 0.15 }, { 1, 0.6 } }), color = ColorSequence.new(Color3.fromRGB(140, 126, 118), Color3.fromRGB(185, 176, 168)),
			light = 0, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-30, 30), accel = Vector3.new(0, 16, 0), drag = 1.2, zOffset = -2 },
	},
	-- Shield popped (it ran out): a yellow ring, gold sparkles and streaks and a tiny flash, a little above the ball.
	shieldPop = {
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.12), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 10 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 1, zOffset = -1, flash = true },
		ring(18, 0.4, ColorSequence.new(CREAM, SHIELD_YELLOW)),
		{ tex = "sparkle_star_4x4", count = 14, lifetime = NumberRange.new(0.4, 0.8), speed = NumberRange.new(14, 32), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.4 }, { 0.6, 2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 0.8, drag = 2, rotation = NumberRange.new(-15, 15), keepColor = true },
		{ tex = "spark_streak", count = 12, lifetime = NumberRange.new(0.25, 0.5), speed = NumberRange.new(30, 60), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.3 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 1, accel = Vector3.new(0, -50, 0), drag = 1.5, orient = Enum.ParticleOrientation.VelocityParallel },
	},
	-- Hit reaction on the victim: a shockwave flash ring and a crown of sparks rising off the hull.
	hitRing = {
		ring(14, 0.4, ColorSequence.new(CREAM, ORANGE)),
		{ tex = "spark_streak", count = 14, lifetime = NumberRange.new(0.25, 0.5), speed = NumberRange.new(22, 48), spread = Vector2.new(75, 75),
			size = ns({ { 0, 1.3 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, ORANGE),
			light = 1, accel = Vector3.new(0, -70, 0), drag = 1.4, orient = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Top },
	},
	-- Spin-out smoke for cars: dark puffs kicked up off the road, rising and away from the chase camera.
	spinSmoke = {
		{ tex = "smoke_puff_8x8", count = 2, lifetime = NumberRange.new(0.8, 1.1), speed = NumberRange.new(4, 9), spread = Vector2.new(70, 70),
			size = ns({ { 0, 2 }, { 1, 3.5 } }), transparency = ns({ { 0, 0.45 }, { 1, 0.85 } }), color = ColorSequence.new(Color3.fromRGB(86, 80, 76), Color3.fromRGB(150, 142, 134)),
			light = 0, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-60, 60), accel = Vector3.new(0, 10, 0), drag = 1.4, zOffset = -2, dir = Enum.NormalId.Top },
	},
	blocked = {
		ring(16, 0.42, ColorSequence.new(SHIELD_YELLOW), 2),
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 4 }, { 1, 8 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 1, zOffset = -1, flash = true },
		{ tex = "spark_streak", count = 10, lifetime = NumberRange.new(0.25, 0.5), speed = NumberRange.new(30, 60), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.3 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 1, accel = Vector3.new(0, -50, 0), drag = 1.5, orient = Enum.ParticleOrientation.VelocityParallel },
		{ tex = "sparkle_star_4x4", count = 12, lifetime = NumberRange.new(0.35, 0.7), speed = NumberRange.new(16, 34), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.4 }, { 0.6, 2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(CREAM, SHIELD_YELLOW),
			light = 0.8, drag = 2, rotation = NumberRange.new(-15, 15) },
	},
	trapPop = {
		{ tex = "smoke_puff_8x8", count = 4, lifetime = NumberRange.new(0.9, 1.4), speed = NumberRange.new(8, 16), spread = Vector2.new(180, 180),
			size = ns({ { 0, 3 }, { 1, 6 } }), transparency = ns({ { 0, 0.2 }, { 1, 0.65 } }), color = ColorSequence.new(TRAP_GREEN, Color3.fromRGB(70, 90, 60)),
			light = 0, rotation = NumberRange.new(0, 360), drag = 1.2, accel = Vector3.new(0, 12, 0), zOffset = -2 },
		{ tex = "debris_shard", count = 12, lifetime = NumberRange.new(0.7, 1.1), speed = NumberRange.new(25, 55), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.2 }, { 1, 0.8 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = ColorSequence.new(TRAP_GREEN),
			light = 0, accel = Vector3.new(0, -120, 0), rotation = NumberRange.new(0, 360) },
	},
	-- v21: a trap dropped by the local vehicle lands behind the chase camera (trapDropBehind 14 = the camera's own distance), so
	-- the drop was never seen. This puff, ring and shards play at the tail of the hull, in front of the camera and low.
	trapDrop = {
		{ tex = "smoke_puff_8x8", count = ItemFxRules.TRAP_DROP.puffCount, lifetime = NumberRange.new(0.6, 0.9), speed = NumberRange.new(3, 8), spread = Vector2.new(70, 70), -- v22: count 3 -> 5
			size = ns({ { 0, 1.8 }, { 1, 4 } }), transparency = ns({ { 0, 0.3 }, { 1, 0.9 } }), color = ColorSequence.new(Color3.fromRGB(226, 208, 170), Color3.fromRGB(196, 178, 144)),
			light = 0, rotation = NumberRange.new(0, 360), drag = 1.4, accel = Vector3.new(0, 4, 0), zOffset = -1, dir = Enum.NormalId.Top },
		ring(ItemFxRules.TRAP_DROP.ring, 0.3, ColorSequence.new(Color3.fromRGB(210, 255, 190), Color3.fromRGB(120, 190, 100))), -- v21 (vfx critic 2): 7 -> 4.2 studs; v22: 4.2 -> 5.5 (the drop was nearly invisible)
		{ tex = "debris_shard", count = 4, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(10, 22), spread = Vector2.new(60, 60),
			size = ns({ { 0, 0.6 }, { 1, 0.3 } }), transparency = ns({ { 0, 0.1 }, { 0.8, 0.2 }, { 1, 1 } }), color = ColorSequence.new(TRAP_GREEN),
			light = 0, accel = Vector3.new(0, -60, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-300, 300), dir = Enum.NormalId.Top, keepColor = true },
	},
	-- A shot stopped by a wall or a hull (X-01): chips and dust thrown off the face, on top of missileBlast.
	wallChips = {
		{ tex = "debris_shard", count = 16, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(30, 65), spread = Vector2.new(70, 70),
			size = ns({ { 0, 1.5 }, { 1, 1 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(150, 110, 70), Color3.fromRGB(96, 84, 78)),
			light = 0, accel = Vector3.new(0, -140, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-480, 480) },
		{ tex = "smoke_puff_8x8", count = 3, lifetime = NumberRange.new(0.9, 1.3), speed = NumberRange.new(6, 14), spread = Vector2.new(60, 60),
			size = ns({ { 0, 5 }, { 1, 9 } }), transparency = ns({ { 0, 0.15 }, { 1, 0.6 } }), color = ColorSequence.new(Color3.fromRGB(175, 160, 140), Color3.fromRGB(205, 196, 184)),
			light = 0, rotation = NumberRange.new(0, 360), drag = 1.5 },
	},
	fizzle = {
		{ tex = "smoke_puff_8x8", count = 2, lifetime = NumberRange.new(0.6, 0.9), speed = NumberRange.new(3, 7), spread = Vector2.new(180, 180),
			size = ns({ { 0, 3 }, { 1, 6 } }), transparency = ns({ { 0, 0.3 }, { 1, 0.7 } }), color = ColorSequence.new(Color3.fromRGB(170, 160, 155)),
			light = 0, rotation = NumberRange.new(0, 360) },
		{ tex = "spark_streak", count = 8, lifetime = NumberRange.new(0.2, 0.4), speed = NumberRange.new(15, 35), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM),
			light = 1, orient = Enum.ParticleOrientation.VelocityParallel },
	},
	-- Tinted per call (item colour) before emitting.
	pickupGlint = {
		-- v29 A5: the glint was a 4 -> 16 stud white card; now a small soft wink
		{ tex = "pickup_glint", count = 1, lifetime = NumberRange.new(0.25), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 1.5 }, { 1, 4 } }), transparency = ns({ { 0, 0.35 }, { 1, 1 } }), color = ColorSequence.new(CREAM), light = 0.6 },
		{ tex = "sparkle_star_4x4", count = 8, lifetime = NumberRange.new(0.4, 0.75), speed = NumberRange.new(12, 28), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.4 }, { 0.6, 2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(CREAM), light = 0.8, drag = 2 },
	},
	-- A balloon pod taken (tinted per call with the pod colour): the confetti sheet, paper confetti and rubber scraps
	-- falling, a sparkle. The pop itself is PayoffAudio confetti_pop (podTaken).
	balloonPop = {
		-- v29 W1b A5: the 9-11 stud confetti sheet is a 4-stud puff and the white paper confetti is small gold star sparks.
		{ tex = "confetti_burst_4x4", count = 1, lifetime = NumberRange.new(0.5, 0.6), speed = NumberRange.new(0, 1), spread = Vector2.new(180, 180),
			size = ns({ { 0, 3.5 }, { 1, 4.5 } }), transparency = ns({ { 0, 0.2 }, { 0.7, 0.4 }, { 1, 1 } }), color = ColorSequence.new(Color3.new(1, 1, 1)),
			light = 0.2, rotation = NumberRange.new(0, 360), zOffset = -1, fbSize = ns({ { 0, 1.5 }, { 1, 4 } }) },
		{ tex = "sparkle_star_4x4", count = 8, lifetime = NumberRange.new(0.2, 0.3), speed = NumberRange.new(10, 24), spread = Vector2.new(150, 150),
			size = ns({ { 0, 0.9 }, { 0.6, 0.7 }, { 1, 0 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.5 } }), color = ColorSequence.new(Color3.fromRGB(255, 226, 130), Color3.fromRGB(255, 190, 70)),
			light = 0.8, drag = 2, rotation = NumberRange.new(-15, 15), keepColor = true },
		{ tex = "debris_shard", count = 8, lifetime = NumberRange.new(0.5, 0.9), speed = NumberRange.new(18, 40), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.4 }, { 1, 0.7 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM),
			light = 0, accel = Vector3.new(0, -90, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-360, 360) },
		{ tex = "sparkle_star_4x4", count = 6, lifetime = NumberRange.new(0.35, 0.6), speed = NumberRange.new(10, 22), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.2 }, { 0.6, 1.8 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(CREAM),
			light = 0.8, drag = 2, rotation = NumberRange.new(-15, 15) },
	},
	-- A mystery cube taken (tinted per call with the cycling hue): a flash, a burst of glass shards, gold sparkles and
	-- a short column of light streaks rising off the pod (up and away from the chase camera, 0.2 s).
	cubePop = {
		-- v28 W1.2: no glint quad (read as a white card); about a dozen small additive gold sparks.
		-- v29 W1b A5: the pale glass chips are gone too (tumbling near-white quads read as paper confetti in forest1 00/05/06).
		{ tex = "sparkle_star_4x4", count = 12, lifetime = NumberRange.new(0.15, 0.3), speed = NumberRange.new(10, 26), spread = Vector2.new(120, 120),
			size = ns({ { 0, 1.5 }, { 0.6, 1.2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(Color3.fromRGB(255, 232, 140), Color3.fromRGB(255, 190, 60)),
			light = 1, drag = 2, rotation = NumberRange.new(-15, 15), keepColor = true, dir = Enum.NormalId.Top },
		{ tex = "spark_streak", count = 4, lifetime = NumberRange.new(0.18, 0.24), speed = NumberRange.new(55, 80), spread = Vector2.new(6, 6),
			size = ns({ { 0, 1.5 }, { 1, 0.2 } }), transparency = ns({ { 0, 0.1 }, { 1, 1 } }), color = ColorSequence.new(CREAM, Color3.fromRGB(255, 214, 90)),
			light = 1, orient = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Top, keepColor = true },
	},
	-- A missile leaving the barrel: a hot puff (fire sheet), a small flash, sparks and soft smoke puffs where it spawns.
	missileLaunch = {
		{ tex = "fire_loop_8x8", count = 2, lifetime = NumberRange.new(0.2, 0.3), speed = NumberRange.new(2, 6), spread = Vector2.new(180, 180),
			size = ns({ { 0, 3 }, { 1, 1 } }), transparency = ns({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } }), color = ColorSequence.new(Color3.new(1, 1, 1)),
			light = 0.6, zOffset = -1 },
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 3 }, { 1, 6 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = ColorSequence.new(CREAM, ORANGE), light = 1, zOffset = -1, flash = true },
		{ tex = "spark_streak", count = 8, lifetime = NumberRange.new(0.2, 0.4), speed = NumberRange.new(20, 45), spread = Vector2.new(40, 40),
			size = ns({ { 0, 1 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, ORANGE),
			light = 1, drag = 2, orient = Enum.ParticleOrientation.VelocityParallel },
		{ tex = "smoke_puff_8x8", count = 3, lifetime = NumberRange.new(0.8, 1.1), speed = NumberRange.new(2, 6), spread = Vector2.new(180, 180),
			size = ns({ { 0, 3 }, { 1, 6 } }), transparency = ns({ { 0, 0.25 }, { 1, 0.8 } }), color = ColorSequence.new(Color3.fromRGB(238, 233, 226), Color3.fromRGB(190, 184, 178)),
			light = 0, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-30, 30), drag = 1.5, fbSize = ns({ { 0, 2.4 }, { 1, 5 } }), zOffset = -2 },
	},
	magnetZap = {
		{ tex = "spark_streak", count = 14, lifetime = NumberRange.new(0.25, 0.45), speed = NumberRange.new(25, 50), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.3 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, rgb(ItemRules.COLOR_RGB.rainbow)),
			light = 1, orient = Enum.ParticleOrientation.VelocityParallel },
	},
	-- v37 (client/ItemShow): a wide shock ring that reads from 100+ studs (bomb, far missile hits, reflects).
	bigRing = {
		ring(34, 0.55, ColorSequence.new(CREAM, ORANGE)),
		ring(20, 0.4, ColorSequence.new(Color3.new(1, 1, 1), CREAM)),
	},
	-- v37: a lightning strike's ground crackle: violet arcs and white-hot sparks thrown off the impact.
	stormSparks = {
		{ tex = "electric_arc_4x4", count = 5, lifetime = NumberRange.new(0.15, 0.3), speed = NumberRange.new(0, 4), spread = Vector2.new(180, 180),
			size = ns({ { 0, 9 }, { 1, 6 } }), transparency = ns({ { 0, 0 }, { 1, 0.6 } }), color = ColorSequence.new(Color3.fromRGB(230, 220, 255)),
			light = 1, rotation = NumberRange.new(0, 360), keepColor = true },
		{ tex = "spark_streak", count = 26, lifetime = NumberRange.new(0.3, 0.6), speed = NumberRange.new(50, 110), spread = Vector2.new(80, 80),
			size = ns({ { 0, 1.8 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(196, 170, 255)),
			light = 1, accel = Vector3.new(0, -90, 0), drag = 1.2, orient = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Top, keepColor = true },
	},
	-- v37: Frost Shot landing: a burst of snow and ice shards off the victim.
	frostShards = {
		{ tex = "snow_burst_4x4", count = 2, lifetime = NumberRange.new(0.5, 0.7), speed = NumberRange.new(0, 3), spread = Vector2.new(180, 180),
			size = ns({ { 0, 9 }, { 1, 12 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 232, 255)),
			light = 0.6, rotation = NumberRange.new(0, 360), keepColor = true, fbSize = ns({ { 0, 4 }, { 1, 9 } }) },
		{ tex = "debris_shard", count = 16, lifetime = NumberRange.new(0.5, 0.9), speed = NumberRange.new(25, 55), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.1 }, { 1, 0.6 } }), transparency = ns({ { 0, 0 }, { 0.8, 0.1 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(210, 245, 255), Color3.fromRGB(140, 210, 255)),
			light = 0.8, accel = Vector3.new(0, -100, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-400, 400), keepColor = true },
		ring(16, 0.4, ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 232, 255))),
	},
}

-- The local victim's own blast: no flash layer, a thinner fireball and fewer sparks, so being hit never whites out the view.
do
	local mine: { Burst } = {}
	for _, layer in BURSTS.missileBlast do
		if layer.flash ~= true then
			local copy = table.clone(layer)
			if layer.tex == "explosion_8x8" then
				copy.size = ns({ { 0, 5.5 }, { 1, 5.5 } })
				copy.fbSize = ns({ { 0, 4 }, { 1, 6 } })
				copy.transparency = ns({ { 0, 0.4 }, { 1, 0.6 } })
				copy.light = 0.1
			elseif layer.tex == "spark_streak" then
				copy.count = 12
			elseif layer.tex == "debris_shard" then
				-- phone-size capture: 1.2-stud shards thrown past the chase camera read as ~60 px orange tiles
				copy.count = 5
				copy.size = ns({ { 0, 0.7 }, { 1, 0.4 } })
			elseif layer.tex == "smoke_puff_8x8" then
				-- phone-size capture: a 4-7 stud dark puff covered the road ahead for a second; smaller and lighter
				copy.count = 2
				copy.size = ns({ { 0, 2 }, { 1, 3.5 } })
				copy.transparency = ns({ { 0, 0.5 }, { 1, 0.95 } })
				copy.lifetime = NumberRange.new(0.5, 0.7)
				copy.color = ColorSequence.new(Color3.fromRGB(190, 178, 166), Color3.fromRGB(222, 214, 204))
			end
			table.insert(mine, copy)
		end
	end
	BURSTS.missileBlastSelf = mine
end

-- v21: the local vehicle's own shield block: the 4-8 stud flash layer and the doubled 16-stud ring washed the middle of the
-- screen yellow for several frames; same sparkles, one smaller ring, no flash.
do
	local mine: { Burst } = {}
	for _, layer in BURSTS.blocked do
		if layer.flash ~= true then
			local copy = table.clone(layer)
			if layer.tex == "shockwave_8x8" then
				copy.count = 1
				copy.size = ns({ { 0, 10 }, { 1, 10 } })
				copy.fbSize = ns({ { 0, 2.5 }, { 1, 12 } })
				copy.transparency = ns({ { 0, 0.25 }, { 0.7, 0.45 }, { 1, 1 } })
			end
			table.insert(mine, copy)
		end
	end
	BURSTS.blockedSelf = mine
end

-- Where a burst's origin moves before it plays: up, and horizontally away from the camera, so the fireball and smoke
-- sit past the victim instead of in the chase camera's lens.
local BURST_OFFSET: { [string]: { up: number, away: number } } = {
	missileBlast = { up = 2.5, away = 3 },
	missileBlastSelf = { up = 2.5, away = 3 },
	trapPop = { up = 1.5, away = 2 },
	shieldPop = { up = 2.5, away = 0 },
	cubePop = { up = 1, away = 1.5 },
}

-- A PointLight spike on the burst's attachment: peak brightness decaying linearly to 0 over `life` seconds.
local LIGHT_SPIKES: { [string]: { peak: number, range: number, life: number, color: Color3 } } = {
	missileBlast = { peak = 6, range = 22, life = 0.2, color = Color3.fromRGB(255, 190, 120) },
	missileBlastSelf = { peak = 3, range = 16, life = 0.2, color = Color3.fromRGB(255, 190, 120) },
	shieldPop = { peak = 3, range = 16, life = 0.2, color = SHIELD_YELLOW },
	cubePop = { peak = 4, range = 18, life = 0.25, color = Color3.fromRGB(255, 220, 130) },
}
type Spike = { light: PointLight, startedAt: number, peak: number, life: number }
local spikes: { Spike } = {} -- one per spiking burst name, created once with the pooled attachment

-- Distance cull for bursts (studs from the camera): a blast this far away is a speck on a phone.
local BURST_CULL = 420

local function cameraPos(): Vector3?
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

local burstPool: { [string]: { att: Attachment, emitters: { ParticleEmitter }, spike: Spike? } } = {}

local function getBurst(name: string): { att: Attachment, emitters: { ParticleEmitter }, spike: Spike? }?
	local existing = burstPool[name]
	if existing then
		return existing
	end
	local preset = BURSTS[name]
	if not preset then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "ItemBurst_" .. name
	att.Parent = workspace.Terrain
	local emitters = {}
	for i, p in preset do
		local pe = Instance.new("ParticleEmitter")
		pe.Name = name .. "_" .. i
		local isFlip = FlipFx.apply(pe, p.tex) -- Texture + FlipbookLayout/Mode/Framerate for the sheet
		pe.Enabled = false
		pe.Rate = 0
		pe.Lifetime = p.lifetime
		pe.Speed = p.speed
		pe.SpreadAngle = p.spread
		pe.Size = if not isFlip and p.fbSize then p.fbSize else p.size
		pe.Transparency = p.transparency
		pe.Color = p.color
		pe.LightEmission = p.light
		pe.LightInfluence = if p.light > 0.5 then 0 else 1
		pe.Acceleration = p.accel or Vector3.zero
		pe.Drag = p.drag or 0
		pe.Rotation = p.rotation or NumberRange.new(0)
		pe.RotSpeed = p.rotSpeed or NumberRange.new(0)
		pe.Orientation = p.orient or Enum.ParticleOrientation.FacingCamera
		pe.EmissionDirection = p.dir or Enum.NormalId.Front
		pe.ZOffset = p.zOffset or 0
		pe.Parent = att
		table.insert(emitters, pe)
	end
	local spike: Spike? = nil
	local spec = LIGHT_SPIKES[name]
	if spec then
		local light = Instance.new("PointLight")
		light.Name = "Spike"
		light.Color = spec.color
		light.Range = spec.range
		light.Brightness = 0
		light.Shadows = false
		light.Parent = att
		spike = { light = light, startedAt = -math.huge, peak = spec.peak, life = spec.life }
		table.insert(spikes, spike :: Spike)
	end
	local entry = { att = att, emitters = emitters, spike = spike }
	burstPool[name] = entry
	return entry
end

-- Plays a pooled burst at pos. scale multiplies the counts (on top of Settings.particleScale(): LOW GRAPHICS thins
-- every burst); bursts beyond BURST_CULL studs from the camera are skipped. Tint recolours every layer except keepColor ones.
function ItemClient.burst(name: string, pos: Vector3, tint: Color3?, scale: number?)
	local entry = getBurst(name)
	local preset = BURSTS[name]
	if not entry or not preset then
		return
	end
	local cam = cameraPos()
	if cam and (cam - pos).Magnitude > BURST_CULL then
		return
	end
	local off = BURST_OFFSET[name]
	if off then
		local away = Vector3.zero
		if cam then
			local flat = Vector3.new(pos.X - cam.X, 0, pos.Z - cam.Z)
			if flat.Magnitude > 0.5 then
				away = flat.Unit * off.away
			end
		end
		pos += Vector3.new(0, off.up, 0) + away
	end
	entry.att.WorldCFrame = CFrame.new(pos)
	local k = (scale or 1) * Settings.particleScale()
	for i, pe in entry.emitters do
		local layer = preset[i]
		if tint and layer.keepColor ~= true then
			pe.Color = ColorSequence.new(CREAM, tint)
		end
		pe:Emit(math.max(1, math.floor(layer.count * k + 0.5)))
	end
	local spike = entry.spike
	if spike and not Settings.lowGraphics() then
		spike.startedAt = os.clock()
		spike.light.Brightness = spike.peak
	end
end

-- Decays the PointLight spikes (a handful of pooled lights; nothing is created here).
local function stepSpikes(now: number)
	for _, sp in spikes do
		if sp.light.Brightness > 0 then
			local u = (now - sp.startedAt) / sp.life
			sp.light.Brightness = if u >= 1 then 0 else sp.peak * (1 - u)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Persistent visuals: missiles, traps, shields, beams, dizzy stars, pods
------------------------------------------------------------------------------------------------------------------------

local missiles: { [BasePart]: BasePart } = {} -- server part -> local smoothed copy
local missileRoll: { [BasePart]: number } = {} -- local mesh copy -> roll about its flight axis (radians)
-- v37 (owner: "missiles are being shot out the wrong direction"): my own shot's server body trails my client hull by the
-- network lag, so it appeared behind my tail and crept forward. Its copy starts at my nose and the offset fades out
-- (missileLead); every copy leads its smoothed pose by the server body's velocity so the easing never drags it back.
type MissileLead = { offset: Vector3, t0: number }
local missileLead: { [BasePart]: MissileLead } = {}
local missileVel: { [BasePart]: { pos: Vector3, vel: Vector3, t: number } } = {}
local MISSILE_LEAD_FADE = 0.45
local MISSILE_EASE = 22
local lockedOnMe: { [BasePart]: PointLight } = {} -- local copy -> its light, for shots whose Target is this player
type TrapVis = { model: Model, light: BasePart?, glow: PointLight?, pivot: CFrame, spawnedAt: number, arm: number, phase: number, bob: number, spin: number, embers: ParticleEmitter?, halo: ParticleEmitter?, wasOn: boolean }
local traps: { [Model]: TrapVis } = {}
type BubbleFx = { pe: ParticleEmitter, billboard: boolean, rate: number, edge: boolean? } -- billboard: hides with the camera close; rate: the full-strength Rate (already particleScale'd)
type Timed = { inst: Instance, plane: Model, untilT: number, total: number, respawn: boolean?, loop: Sound?, loopVol: number?, fx: { BubbleFx }?, flash: ParticleEmitter? } -- loop: the shield_loop hum; fx: the bubble's particle layers; flash: own shield's 0.4 s hex flash (v29 A2)
local shields: { [Model]: Timed } = {}
local respawnBubbles: { [Model]: Timed } = {} -- G2 respawn protection, apart from the Yellow item's shield
local dizzies: { [Model]: Timed } = {}
type BeamVis = { beam: Beam, a0: Attachment, a1: Attachment, from: Model, to: Model, untilT: number }
local beams: { BeamVis } = {}
-- A mystery cube's moving parts: the glass core first, then its frame, each with its pose and size in the core's frame.
type CubeVis = {
	parts: { BasePart },
	offsets: { CFrame },
	sizes: { Vector3 },
	inner: BillboardGui, -- the ghost icon inside the glass
	img: ImageLabel,
	ghost: string?, -- the item colour whose ghost is on show (nil: none yet)
	ghostAlpha: number, -- the ImageTransparency last written (near-camera fade)
	tint: number, -- the shared tint serial last written to the glass, core, halo and light (-1: none yet)
	scale: number, -- the scale the parts were last sized at
	glow: BasePart?, -- the Neon core inside the glass (pulses, takes the cycling hue, fades near the camera)
	marks: { SurfaceGui }, -- the "?" on each glass face (off when the camera is inside the cube)
	marksOn: boolean,
	ring: ParticleEmitter?, -- the ground/air pulse under the cube (one Emit per period)
	nextRing: number,
	frameFade: number, -- the LocalTransparencyModifier last written to the frame bars and corners (point-blank thinning)
}
type PodVis = {
	pod: BasePart,
	cube: CubeVis?,
	gui: BillboardGui?, -- soft halo (item pods)
	img: ImageLabel?,
	icon: BillboardGui?, -- item icon held on the camera side of the balloon
	core: BasePart?,
	spec: ItemArt.PodSpec?, -- set when the core is mesh art (nil: the plain fallback ball)
	light: PointLight?,
	rainbow: boolean,
	baseCF: CFrame, -- the core's replicated CFrame; the loop animates around it
	baseSize: Vector3,
	phase: number,
	cooling: boolean, -- last seen OnCooldown
	inflateAt: number, -- os.clock() when re-inflation began, 0 when none
}
local pods: { [BasePart]: PodVis } = {}
local podScanAt = 0
local hueClock = 0

-- One shared loop animates every pod near the camera (no per-pod threads, no tweens, no Instance creation).
local POD_ANIM_RANGE = 420 -- studs: further pods stay where the server put them
local POD_LIGHT_RANGE = 150 -- the PointLight only runs this close (phone lighting budget)
local POD_ICON_RANGE = 230
local POD_POP_RANGE = 260 -- confetti and the pop sound only when the pod is this near the camera
local POD_INFLATE_SECONDS = 0.6
local CUBE_LOW_RANGE = 220 -- LOW GRAPHICS: cubes further than this hold still
-- Cubes v2 ghost cycle, shared by every cube (computed once per frame in step; see ItemRules.CUBES).
local ITEM_COLOR3: { [string]: Color3 } = {} -- item colour -> Color3, built once
local GHOST_ICON_COLOR3: { [string]: Color3 } = {} -- the ghost icon's pale tint per item colour
for _, c in ItemRules.ALL_ITEMS do -- items v4: the specials ghost in their own colours too
	local rgbT = ItemRules.colorRgb(c) or { 255, 255, 255 }
	local col = Color3.fromRGB(rgbT[1], rgbT[2], rgbT[3])
	ITEM_COLOR3[c] = col
	GHOST_ICON_COLOR3[c] = Color3.new(1, 1, 1):Lerp(col, ItemRules.CUBES.ghostTint)
end
local ghostHeld: string? = nil -- the colour this player holds (onItemState), or nil
local ghostSchedule: ItemRules.GhostSchedule = ItemRules.ghostFor(1, 1, nil)
local ghostCheckAt = 0 -- os.clock() of the next band re-read
local ghostShown: string = "red" -- the item colour on show this frame
local ghostFrom, ghostTo, ghostBlend = "", "", -1 -- the tint inputs last turned into colours
local tintSerial = 0 -- bumps whenever the shared tint below changes
local tintItem = Color3.new(1, 1, 1) -- halo and light (cubes v3: the glass and frame keep their own family colour)
local tintCore = Color3.new(1, 1, 1) -- the Neon core
local CUBE_SPIN = Vector3.new(0.8, 1.3, 0.55) -- rad/s about X, Y, Z: a full turn on every axis, never in lockstep
local CUBE_BOB = 0.35
local HOMING_PINK = Color3.fromRGB(255, 90, 160)
local HOMING_TINT = Color3.fromRGB(255, 170, 205) -- the same hue as a MeshPart.Color tint on the textured missile

local function makeMissileCopy(server: BasePart): BasePart
	local homing = server:GetAttribute("Homing") == true
	-- The missile mesh (nose -Z, nozzle +Z, assets/models/items_v1) when the server's cache has replicated; the old neon
	-- bolt until then. The server's own body keeps its 1.1 x 1.1 x 3.4 block either way (hitboxes are distance checks).
	local mesh = ItemArt.peek("missile")
	-- Items v4: a Frost Shot or Coin Burst shot wears its item colour (server attribute Status).
	local status = server:GetAttribute("Status")
	local statusTint = if type(status) == "string" and ItemRules.COLOR_RGB[status] then rgb(ItemRules.COLOR_RGB[status]) else nil
	local body: BasePart
	if mesh then
		body = mesh:Clone()
		ItemArt.setTint(body, statusTint or (if homing then HOMING_TINT else Color3.new(1, 1, 1)))
	else
		local p = Instance.new("Part")
		p.Size = Vector3.new(1, 1, 3.2)
		p.Material = Enum.Material.Neon
		p.Color = statusTint or (if homing then HOMING_PINK else rgb(ItemRules.COLOR_RGB.red))
		body = p
	end
	local tailZ = if mesh then 1.75 else 1.4 -- trail starts at the nozzle end
	body.Name = "ItemMissileLocal"
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.CastShadow = false
	body.CFrame = server.CFrame
	local front = Instance.new("Attachment")
	front.Position = Vector3.new(0, 0.35, tailZ)
	front.Parent = body
	local back = Instance.new("Attachment")
	back.Position = Vector3.new(0, -0.35, tailZ)
	back.Parent = body
	local trail = Instance.new("Trail")
	trail.Attachment0 = front
	trail.Attachment1 = back
	trail.Texture = tex("trail_soft")
	-- Studio QA (workspace QALongTrails): a 3 s trail draws a shot's whole path in one capture.
	trail.Lifetime = if RunService:IsStudio() and workspace:GetAttribute("QALongTrails") == true then 3 else 0.5
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.WidthScale = ns({ { 0, 3.4 }, { 1, 0.6 } }) -- v37: thicker, so a shot's path reads from far back
	trail.Transparency = ns({ { 0, 0.1 }, { 1, 1 } })
	trail.Color = ColorSequence.new(CREAM, if homing then HOMING_PINK else ORANGE)
	trail.Parent = body
	local exhaust = Instance.new("Attachment")
	exhaust.Position = Vector3.new(0, 0, tailZ + 0.3)
	exhaust.Orientation = Vector3.new(0, 180, 0)
	exhaust.Parent = body
	local flame = Instance.new("ParticleEmitter")
	FlipFx.apply(flame, "fire_loop_8x8") -- looping fire sheet (30 fps, random start); old fire_lick_4x4 as fallback
	local pk = Settings.particleScale()
	flame.Rate = 70 * pk
	flame.Lifetime = NumberRange.new(0.18, 0.28)
	flame.Speed = NumberRange.new(10, 18)
	flame.SpreadAngle = Vector2.new(6, 6)
	flame.Size = ns({ { 0, 2.4 }, { 1, 0.7 } })
	flame.Transparency = ns({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } })
	flame.Orientation = Enum.ParticleOrientation.VelocityParallel
	flame.LightEmission = 0.6
	flame.LightInfluence = 0
	flame.EmissionDirection = Enum.NormalId.Front
	flame.Parent = exhaust
	-- Smoke plume behind the flame (smoke_puff_8x8 over each particle's life) and a few streaking sparks: the missile reads
	-- from far back down the road. Both sit at the nozzle, behind the missile, and never in the chase camera's lens.
	local smoke = Instance.new("ParticleEmitter")
	FlipFx.apply(smoke, "smoke_puff_8x8")
	smoke.Rate = 24 * pk
	smoke.Lifetime = NumberRange.new(0.55, 0.85)
	smoke.Speed = NumberRange.new(1, 3)
	smoke.SpreadAngle = Vector2.new(10, 10)
	smoke.Size = ns({ { 0, 1.2 }, { 1, 3.4 } })
	smoke.Transparency = ns({ { 0, 0.35 }, { 1, 1 } })
	smoke.Color = ColorSequence.new(Color3.fromRGB(225, 218, 210), Color3.fromRGB(150, 144, 138))
	smoke.RotSpeed = NumberRange.new(-40, 40)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.LightInfluence = 1
	smoke.ZOffset = -1
	smoke.EmissionDirection = Enum.NormalId.Front
	smoke.Parent = exhaust
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = tex("spark_streak")
	sparks.Rate = 16 * pk
	sparks.Lifetime = NumberRange.new(0.2, 0.35)
	sparks.Speed = NumberRange.new(14, 26)
	sparks.SpreadAngle = Vector2.new(14, 14)
	sparks.Size = ns({ { 0, 1 }, { 1, 0.1 } })
	sparks.Transparency = ns({ { 0, 0 }, { 1, 1 } })
	sparks.Color = ColorSequence.new(CREAM, if homing then HOMING_PINK else ORANGE)
	sparks.Orientation = Enum.ParticleOrientation.VelocityParallel
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.EmissionDirection = Enum.NormalId.Front
	sparks.Parent = exhaust
	-- v37: a hot glow core the size of a car, so a shot is a bright point from 100+ studs (one particle at a time).
	local glow = Instance.new("ParticleEmitter")
	glow.Texture = tex("glow_soft")
	glow.Rate = 30
	glow.Lifetime = NumberRange.new(0.08, 0.1)
	glow.Speed = NumberRange.new(0)
	glow.Size = NumberSequence.new(5.5)
	glow.Transparency = NumberSequence.new(0.25)
	glow.Color = ColorSequence.new(statusTint or (if homing then HOMING_PINK else ORANGE))
	glow.LightEmission = 1
	glow.LightInfluence = 0
	glow.LockedToPart = true
	glow.ZOffset = -0.5
	glow.Parent = body
	local light = Instance.new("PointLight")
	light.Color = ORANGE
	light.Range = 18
	light.Brightness = 3
	light.Shadows = false
	light.Parent = body
	ItemShow.dressShot(body, if type(status) == "string" then status else nil)
	body.Parent = workspace.CurrentCamera or workspace
	if mesh then
		missileRoll[body] = math.random() * math.pi * 2
	end
	return body
end

-- fresh: the instance just appeared (not one that was already there when this client joined), so a missile gets its
-- launch puff.
local function track(inst: Instance, fresh: boolean?)
	local kind = inst:GetAttribute("Kind")
	if kind == "missile" and inst:IsA("BasePart") then
		if missiles[inst] then
			return
		end
		inst.LocalTransparencyModifier = 1
		local copy = makeMissileCopy(inst)
		missiles[inst] = copy
		local mineShot = inst:GetAttribute("Owner") == ownRacerId()
		local launchAt = inst.Position
		if fresh == true and mineShot then
			local planesF = workspace:FindFirstChild("Planes")
			local own = if planesF then (planesF:FindFirstChild("Plane_" .. LocalPlayer.Name) or planesF:FindFirstChild("Car_" .. LocalPlayer.Name)) else nil
			local myHull = hullOf(own)
			if myHull then
				local look = myHull.CFrame.LookVector
				local nose = myHull.Position + look * (myHull.Size.Z * 0.5 + 6)
				local offset = nose - inst.Position
				if offset:Dot(look) > 0 and offset.Magnitude < 80 then
					missileLead[copy] = { offset = offset, t0 = os.clock() }
					copy.CFrame = CFrame.lookAt(nose, nose + inst.CFrame.LookVector)
					launchAt = nose
				end
			end
		end
		if fresh == true then
			local cam = cameraPos()
			if cam and (cam - inst.Position).Magnitude < 300 then
				ItemClient.burst("missileLaunch", launchAt, nil, if mineShot then 1.5 else 1.2)
				Sfx.at("missile_launch", launchAt, if mineShot then 0.6 else Sfx.quiet(0.6))
				Sfx37.at("missile_whoosh", launchAt, if mineShot then 0.7 else 0.45)
			end
		end
		local onMe = inst:GetAttribute("Target") == ownRacerId()
		if onMe then
			local light = copy:FindFirstChildOfClass("PointLight")
			if light then
				lockedOnMe[copy] = light
			end
		end
		-- The flight hum rides the copy (it ends with it in untrack / step); louder when the shot is coming for you.
		Sfx.loop3D("missile_loop", copy, if onMe then 0.32 * 1.4 elseif mineShot then 0.32 else Sfx.quiet(0.32))
	elseif kind == "trap" and inst:IsA("Model") then
		local light = inst:FindFirstChild("Light")
		local lightPart = if light and light:IsA("BasePart") then light else nil
		local glow = if lightPart then lightPart:FindFirstChildOfClass("PointLight") else nil
		local spawned = inst:GetAttribute("SpawnedAt")
		local arm = inst:GetAttribute("ArmSeconds")
		-- The oil slick lies flat (no bob, and no spin on the ground); the mine and its bubble bob and turn slowly.
		local slick = inst:GetAttribute("Form") == "slick"
		local grounded = inst:GetAttribute("Grounded") == true
		-- Danger read: low embers drifting off an armed trap and a halo that pulses on each blink (both gated in step()).
		local embers: ParticleEmitter? = nil
		local halo: ParticleEmitter? = nil
		if lightPart then
			local dangerColor = Color3.fromRGB(255, 90, 60)
			local e = Instance.new("ParticleEmitter")
			e.Name = "TrapEmbers"
			e.Texture = tex("ember")
			e.Rate = 0
			e.Enabled = false
			e.Lifetime = NumberRange.new(0.6, 1)
			e.Speed = NumberRange.new(3, 6)
			e.SpreadAngle = Vector2.new(35, 35)
			e.EmissionDirection = Enum.NormalId.Top
			e.Acceleration = Vector3.new(0, 4, 0)
			e.Size = ns({ { 0, 0.9 }, { 1, 0 } })
			e.Transparency = ns({ { 0, 0 }, { 1, 1 } })
			e.Color = ColorSequence.new(rgb({ 255, 220, 120 }), dangerColor)
			e.LightEmission = 1
			e.LightInfluence = 0
			e.Parent = lightPart
			embers = e
			local h = Instance.new("ParticleEmitter")
			h.Name = "TrapHalo"
			h.Texture = tex("glow_soft")
			h.Rate = 0
			h.Enabled = false
			h.Lifetime = NumberRange.new(0.28)
			h.Speed = NumberRange.new(0)
			h.Size = ns({ { 0, 4 }, { 1, 8 } })
			h.Transparency = ns({ { 0, 0.45 }, { 1, 1 } })
			h.Color = ColorSequence.new(dangerColor)
			h.LightEmission = 1
			h.LightInfluence = 0
			h.ZOffset = -1
			h.Parent = lightPart
			halo = h
		end
		traps[inst] = {
			embers = embers,
			halo = halo,
			wasOn = false,
			model = inst,
			light = lightPart,
			glow = glow,
			pivot = inst:GetPivot(),
			spawnedAt = if type(spawned) == "number" then spawned else workspace:GetServerTimeNow(),
			arm = if type(arm) == "number" then arm else 0.6,
			phase = math.random() * math.pi * 2,
			bob = if not slick then 0.6 elseif grounded then 0 else 0.35,
			spin = if not slick then 1.4 elseif grounded then 0 else 0.5,
		}
		if fresh == true then
			-- Dropped now: the clunk (a wet splat for the slick) at the trap, and a tick when it arms if you are close.
			local pos = inst:GetPivot().Position
			local mineTrap = inst:GetAttribute("Owner") == ownRacerId()
			local trapVol = if slick then 0.63 else 0.72
			Sfx.at(if slick then "oil_splat" else "trap_drop", pos, if mineTrap then trapVol else Sfx.quiet(trapVol))
			if mineTrap then
				-- v21: the visible drop (the trap itself lies under / behind the chase camera): puff and ring at the hull's tail.
				local planes = workspace:FindFirstChild("Planes")
				local mine = if planes then (planes:FindFirstChild("Car_" .. LocalPlayer.Name) or planes:FindFirstChild("Plane_" .. LocalPlayer.Name)) else nil
				local hull = if mine and mine:IsA("Model") then hullOf(mine) else nil
				if hull then
					ItemClient.burst("trapDrop", hull.Position - hull.CFrame.LookVector * 4.2 - Vector3.new(0, 1.3, 0), nil)
				end
			end
			-- v22: arming blink (3 quick red / white Highlight flashes over ~0.6 s) on the dropped trap so everyone sees it was armed
			-- (the trap's own light part is driven by step(), so the blink is a Highlight on the model, not a light edit).
			if not slick then
				task.spawn(function()
					local hl = Instance.new("Highlight")
					hl.Name = "ArmBlink"
					hl.FillTransparency = 1
					hl.OutlineTransparency = 1
					hl.DepthMode = Enum.HighlightDepthMode.Occluded
					hl.Adornee = inst
					hl.Parent = inst
					for i = 0, ItemFxRules.TRAP_DROP.blinks * 2 - 1 do
						if not inst.Parent then
							break
						end
						local state = ItemFxRules.armBlinkAt(i)
						local c = if state == "red" then Color3.fromRGB(255, 50, 40) elseif state == "white" then Color3.new(1, 1, 1) else nil
						hl.FillColor = c or hl.FillColor
						hl.FillTransparency = if c then 0.35 else 1
						hl.OutlineTransparency = if c then 0 else 1
						hl.OutlineColor = c or hl.OutlineColor
						task.wait(ItemFxRules.armBlinkStep())
					end
					hl:Destroy()
				end)
			end
			local armDelay = if type(arm) == "number" then arm else 0.6
			task.delay(armDelay, function()
				local cam = cameraPos()
				if inst.Parent and cam and (cam - pos).Magnitude < 40 then
					Sfx.at("trap_arm", pos, 0.24)
				end
			end)
		end
	end
end

local function untrack(inst: Instance)
	if inst:IsA("BasePart") then
		local copy = missiles[inst]
		if copy then
			missiles[inst] = nil
			lockedOnMe[copy] = nil
			missileRoll[copy] = nil
			missileLead[copy] = nil
			missileVel[copy] = nil
			copy:Destroy()
		end
	elseif inst:IsA("Model") then
		traps[inst] = nil
	end
end

local function watchFxFolder()
	-- The server creates the folder after the map build, which can outlast any single timeout; keep waiting.
	local folder: Instance? = nil
	while not folder do
		folder = workspace:WaitForChild(FX_FOLDER, 30)
	end
	assert(folder)
	for _, child in folder:GetChildren() do
		task.defer(track, child)
	end
	folder.ChildAdded:Connect(function(child: Instance)
		-- Deferred: attributes and children of a freshly replicated instance arrive with it, but give them a frame.
		task.defer(track, child, true)
	end)
	folder.ChildRemoved:Connect(untrack)
end

local BUBBLE_SIZE = 14 -- the sparkle shell's diameter (swirl, edge sparkles)
local HEX_SIZE_OWN = 6.8 -- the local vehicle's own bubble (the chase camera sits ~15 studs behind it)
local HEX_SIZE = 10.5 -- the hex billboard (the hull is ~7): small enough that it never fills the chase camera's view
local FX_CULL = 220 -- shield swirl and sparkles only run this close to the camera

local function bubbleEmitter(host: BasePart, name: string, sheet: string): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = name
	FlipFx.apply(pe, sheet)
	pe.Speed = NumberRange.new(0)
	pe.LightInfluence = 0
	pe.LockedToPart = true
	pe.Parent = host
	return pe
end

-- A particle-only bubble that follows the vehicle (step): the Yellow item's shield, or the respawn protection bubble.
-- The anchor is an invisible Part (the hum and the step() follow code hang on it); everything visible is a particle:
-- a faint shield_hex billboard pushed behind the hull (transparency >= 0.8, hidden with the camera close), and for the
-- shield a swirl, a rim ring pulse and edge sparkles (phone and low graphics keep fewer layers), for the respawn bubble
-- a star shimmer. Rates scale with Settings.particleScale() and are gated by distance in step().
local function addBubble(store: { [Model]: Timed }, plane: Model, seconds: number, name: string, color: Color3, hex: boolean?)
	local existing = store[plane]
	if existing then
		existing.untilT = math.max(existing.untilT, os.clock() + seconds)
		existing.total = math.max(existing.total, seconds)
		return
	end
	local respawn = hex ~= true
	local bubble = Instance.new("Part")
	bubble.Name = name
	bubble.Size = Vector3.one
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.CastShadow = false
	bubble.Transparency = 1
	local hull = hullOf(plane)
	if hull then
		bubble.CFrame = hull.CFrame
	end
	bubble.Parent = workspace.CurrentCamera or workspace
	-- The Yellow shield hums while it holds (the respawn bubble stays quiet); it dies with the bubble.
	local loopVol = if ownVehicle(plane) then 0.28 else 0.18
	local loop: Sound? = nil
	if not respawn then
		loop = Sfx.loop3D("shield_loop", bubble, loopVol)
	end
	local layers = ItemFxRules.bubbleLayers(respawn, Settings.phoneTier(), Settings.lowGraphics())
	local k = Settings.particleScale()
	local fx: { BubbleFx } = {}
	-- v29 W1b A2 (critic v29: the own-vehicle hex sheet sat over the road in forest1/snow1/dino4 frames, and the capture
	-- harness's respawn bubble drew it too): the LOCAL racer's bubble has no standing hex. Its held Yellow shield reads
	-- as the rim ring plus a few edge sparks, and the hex shows only as a 0.4 s flash on activation and on a block.
	-- Rivals keep the faint hex billboard.
	local ownHex = ownVehicle(plane)
	local flash: ParticleEmitter? = nil
	if layers.hex and ownHex and not respawn then
		local fl = bubbleEmitter(bubble, "ShieldHexFlash", "glow_soft")
		fl.Texture = ItemTexAssets.shield_hex
		fl.FlipbookLayout = Enum.ParticleFlipbookLayout.None
		fl.Rate = 0
		fl.Lifetime = NumberRange.new(0.4)
		fl.Size = ns({ { 0, HEX_SIZE_OWN }, { 1, HEX_SIZE_OWN + 1 } })
		fl.Transparency = ns({ { 0, 0.7 }, { 1, 1 } })
		fl.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, 0.55))
		fl.LightEmission = 0.6
		fl.ZOffset = -2
		fl:Emit(1)
		flash = fl
	end
	if layers.hex and not ownHex then
		local hexPe = bubbleEmitter(bubble, "ShieldHex", "glow_soft")
		hexPe.Texture = ItemTexAssets.shield_hex
		hexPe.FlipbookLayout = Enum.ParticleFlipbookLayout.None -- single-frame tile, not glow_soft's sheet layout
		hexPe.Rate = 1
		hexPe.Lifetime = NumberRange.new(2.5)
		local t = ItemFxRules.hexTransparency(respawn, false)
		if not respawn and not ownVehicle(plane) then
			t = ItemFxRules.REMOTE_HEX_TRANSPARENCY -- v21: a rival's shield is far from the lens and was a faint hex nobody could read
		end
		local own = ownVehicle(plane)
		local hexSize = if own then HEX_SIZE_OWN else HEX_SIZE -- v21: at the chase camera's 15 studs the 10.5-stud lattice wallpapered the left half of a phone screen
		hexPe.Size = ns({ { 0, hexSize }, { 1, hexSize + 0.8 } })
		hexPe.Transparency = ns({ { 0, 1 }, { 0.2, t }, { 0.8, t }, { 1, 1 } })
		hexPe.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, 0.55))
		hexPe.LightEmission = 0.6
		hexPe.RotSpeed = NumberRange.new(-20, 20)
		hexPe.ZOffset = -2 -- negative = away from the camera: the billboard sits behind the hull
		table.insert(fx, { pe = hexPe, billboard = true, rate = 1 })
	end
	if layers.swirl then
		-- A slow magic_swirl layer inside the bubble (faint, pushed away from the camera by ZOffset).
		local swirl = bubbleEmitter(bubble, "ShieldSwirl", "magic_swirl_8x8")
		swirl.Rate = 1.6 * k
		swirl.Lifetime = NumberRange.new(1.6, 2)
		swirl.Size = ns({ { 0, BUBBLE_SIZE * 0.7 }, { 1, BUBBLE_SIZE * 0.85 } })
		swirl.Transparency = ns({ { 0, 1 }, { 0.25, 0.6 }, { 0.75, 0.66 }, { 1, 1 } }) -- v21: was 0.72 / 0.78
		swirl.Color = ColorSequence.new(CREAM, color)
		swirl.LightEmission = 0.8
		swirl.RotSpeed = NumberRange.new(-30, 30)
		swirl.ZOffset = -2
		table.insert(fx, { pe = swirl, billboard = false, rate = 1.6 * k })
	end
	if layers.ring then
		-- A rim ring breathing out every RING_PERIOD (one particle per pulse, behind the hull like the hex).
		local rim = bubbleEmitter(bubble, "ShieldRing", "shockwave_ring")
		rim.Rate = 1 / ItemFxRules.RING_PERIOD
		rim.Lifetime = NumberRange.new(ItemFxRules.RING_PERIOD)
		local rimOwn = ownVehicle(plane)
		rim.Size = if rimOwn then ns({ { 0, 6.5 }, { 1, 8.5 } }) else ns({ { 0, 9 }, { 1, 11 } })
		rim.Transparency = if rimOwn then ns({ { 0, 0.55 }, { 1, 1 } }) else ns({ { 0, 0.4 }, { 1, 1 } }) -- v21: was 0.7, additive: gone on bright sand
		rim.Color = ColorSequence.new(CREAM, color)
		rim.LightEmission = 0.5
		rim.ZOffset = -2
		table.insert(fx, { pe = rim, billboard = true, rate = 1 / ItemFxRules.RING_PERIOD })
	end
	if layers.edge then
		-- Sparkles twinkling on the edge; x3 over the last second in place of the old mesh blink.
		local edge = bubbleEmitter(bubble, "ShieldEdge", "sparkle_star_4x4")
		local edgeRate = (if ownHex then 7 else 10) * k -- v29 A2: the own shield is a ring plus 6-8 sparks a second
		edge.Rate = edgeRate
		edge.Lifetime = NumberRange.new(0.5, 0.9)
		edge.Speed = NumberRange.new(0, 1)
		edge.Shape = Enum.ParticleEmitterShape.Sphere
		edge.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		edge.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		edge.Size = ns({ { 0, 0 }, { 0.3, 2.2 }, { 1, 0 } }) -- v21: 7/s at 1.5 studs -> 10/s at 2.2
		edge.Transparency = ns({ { 0, 0 }, { 1, 0.3 } })
		edge.Color = ColorSequence.new(CREAM, color)
		edge.LightEmission = 1
		edge.RotSpeed = NumberRange.new(-90, 90)
		table.insert(fx, { pe = edge, billboard = false, rate = edgeRate, edge = true })
	end
	if layers.shimmer then
		-- Invulnerability shimmer: soft star twinkles around the hull for the whole protection window.
		local sh = bubbleEmitter(bubble, "RespawnShimmer", "star_twinkle")
		sh.Rate = 12 * k
		sh.Lifetime = NumberRange.new(0.4, 0.5)
		sh.Speed = NumberRange.new(0, 1.5)
		sh.Shape = Enum.ParticleEmitterShape.Sphere
		sh.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		sh.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		sh.Size = ns({ { 0, 0 }, { 0.3, 1.3 }, { 1, 0 } })
		sh.Transparency = ns({ { 0, 0.2 }, { 1, 0.5 } })
		sh.Color = ColorSequence.new(CREAM, color)
		sh.LightEmission = 1
		sh.RotSpeed = NumberRange.new(-60, 60)
		table.insert(fx, { pe = sh, billboard = false, rate = 12 * k })
	end
	store[plane] = { inst = bubble, plane = plane, untilT = os.clock() + seconds, total = seconds, respawn = respawn, loop = loop, loopVol = loopVol, fx = fx, flash = flash }
end

-- Per-frame gate for a bubble's layers: sparkles by the cull range, the hex billboard and ring also by camera
-- distance (never right in front of the lens), the hex off on blink frames, edge sparkles x3 in the last second.
local function updateBubbleFx(s: Timed, bubble: BasePart, camNow: Vector3?, left: number, blink: boolean)
	local fx = s.fx
	if not fx then
		return
	end
	local dist = if camNow then (camNow - bubble.Position).Magnitude else nil
	local sparkle = ItemFxRules.sparkleOn(dist, FX_CULL)
	local board = ItemFxRules.billboardOn(dist, FX_CULL) and not blink
	local mul = ItemFxRules.edgeRateMul(left)
	for _, f in fx do
		f.pe.Enabled = if f.billboard then board else sparkle
		if f.edge then
			f.pe.Rate = f.rate * (if s.respawn then 1 else mul)
		end
	end
end

local function addShield(plane: Model, seconds: number)
	addBubble(shields, plane, seconds, "ItemShieldBubble", SHIELD_YELLOW, true)
end

local function addDizzy(plane: Model, seconds: number)
	local existing = dizzies[plane]
	if existing then
		existing.untilT = math.max(existing.untilT, os.clock() + seconds)
		return
	end
	local hull = hullOf(plane)
	if not hull then
		return
	end
	-- Stars circling above the cockpit: the spin-out reads at phone size even on a bot the camera is far from.
	local att = Instance.new("Attachment")
	att.Name = "ItemDizzy"
	att.Position = Vector3.new(0, 3.2, 0)
	att.Parent = hull
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = tex("star_twinkle")
	pe.Rate = 16 * Settings.particleScale()
	pe.Lifetime = NumberRange.new(0.45, 0.6)
	pe.Speed = NumberRange.new(5, 7)
	pe.SpreadAngle = Vector2.new(180, 10)
	pe.EmissionDirection = Enum.NormalId.Right
	pe.RotSpeed = NumberRange.new(-200, 200)
	pe.Size = ns({ { 0, 1.3 }, { 1, 0.2 } })
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 236, 120))
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.LockedToPart = true
	pe.Parent = att
	dizzies[plane] = { inst = att, plane = plane, untilT = os.clock() + seconds, total = seconds }
end

local function addBeam(from: Model, to: Model, seconds: number)
	local h0, h1 = hullOf(from), hullOf(to)
	if not h0 or not h1 then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "ItemMagnetA"
	a0.Parent = h0
	local a1 = Instance.new("Attachment")
	a1.Name = "ItemMagnetB"
	a1.Parent = h1
	local beam = Instance.new("Beam")
	beam.Name = "ItemMagnetBeam"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Texture = tex("lightning_beam")
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.TextureLength = 10
	beam.TextureSpeed = 3
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 12
	beam.Width0 = 2.6
	beam.Width1 = 1.4
	beam.Transparency = ns({ { 0, 0.05 }, { 1, 0.25 } })
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 80)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(110, 255, 120)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(90, 190, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 110, 255)),
	})
	beam.Parent = h0
	table.insert(beams, { beam = beam, a0 = a0, a1 = a1, from = from, to = to, untilT = os.clock() + seconds })
	ItemClient.burst("magnetZap", h1.Position, nil)
end

-- Registers a mystery cube once its glass and every frame part have replicated (else the next scan retries): the parts
-- with their poses in the glass's frame, the rainbow halo, and the inner billboard (icon plus "?" label).
local function scanCube(pod: BasePart)
	local found = pod:FindFirstChild(pod.Name .. "_CoreVisual")
	if not found or not found:IsA("BasePart") or found:GetAttribute("PodArt") ~= "mystery" then
		return
	end
	local core = found :: BasePart
	local want = core:GetAttribute("FrameParts")
	local frameParts: { BasePart } = {}
	for _, c in core:GetChildren() do
		if c:IsA("BasePart") then
			table.insert(frameParts, c)
		end
	end
	if type(want) ~= "number" or #frameParts < want then
		return
	end
	local baseCF = core.CFrame
	local parts: { BasePart } = { core }
	local offsets: { CFrame } = { CFrame.identity }
	local sizes: { Vector3 } = { core.Size }
	for _, p in frameParts do
		table.insert(parts, p)
		table.insert(offsets, baseCF:ToObjectSpace(p.CFrame))
		table.insert(sizes, p.Size)
	end
	local cooling = pod:GetAttribute("OnCooldown") == true
	local low = Settings.lowGraphics()

	local g = Instance.new("BillboardGui")
	g.Name = "ItemPodGlow"
	g.Adornee = pod
	g.Size = UDim2.fromScale(10, 10)
	g.LightInfluence = 0
	g.MaxDistance = 320
	g.ResetOnSpawn = false
	g.Enabled = not cooling and not low
	local halo = Instance.new("ImageLabel")
	halo.Size = UDim2.fromScale(1, 1)
	halo.BackgroundTransparency = 1
	halo.Image = tex("glow_soft")
	halo.ImageTransparency = 0.55
	halo.Parent = g
	g.Parent = pod

	-- Inside the glass: smaller than the glass (3.8 studs), so it reads as held in the box at every angle.
	local inner = Instance.new("BillboardGui")
	inner.Name = "ItemCubeInner"
	inner.Adornee = core
	inner.Size = UDim2.fromScale(2.3, 2.3)
	inner.LightInfluence = 0
	inner.MaxDistance = POD_ICON_RANGE
	inner.ResetOnSpawn = false
	inner.Enabled = not cooling
	-- The ghost: a faint, pale-tinted icon of the item on show (a hint, not a reveal; the "?" faces stay on the glass).
	local img = Instance.new("ImageLabel")
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.ImageTransparency = ItemRules.CUBES.ghostTransparency
	img.Parent = inner
	inner.Parent = core

	local glow = core:FindFirstChild("CubeCore")
	local marks: { SurfaceGui } = {}
	for _, c in core:GetChildren() do
		if c:IsA("SurfaceGui") then
			c.Enabled = not cooling
			table.insert(marks, c)
		end
	end
	-- Ground/air pulse: a flat shockwave ring under the cube, emitted from the stepper (Rate 0), off under LOW GRAPHICS.
	local ring: ParticleEmitter? = nil
	if not low then
		local att = Instance.new("Attachment")
		att.Name = "ItemCubeRingAnchor"
		att.WorldPosition = baseCF.Position - Vector3.new(0, ItemRules.MYSTERY.hover - 0.3, 0)
		att.Parent = pod
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "ItemCubeRing"
		FlipFx.apply(pe, "shockwave_8x8")
		pe.Rate = 0
		pe.Enabled = false
		pe.Lifetime = NumberRange.new(0.9)
		pe.Speed = NumberRange.new(0)
		pe.Size = ns({ { 0, 2 }, { 1, ItemRules.CUBE_FX.ringSize * math.max(Settings.particleScale(), 0.6) } })
		pe.Transparency = ns({ { 0, 0.35 }, { 0.6, 0.65 }, { 1, 1 } })
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 220, 110))
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
		pe.Rotation = NumberRange.new(0)
		pe.Parent = att
		ring = pe
	end

	local cube: CubeVis = {
		parts = parts, offsets = offsets, sizes = sizes, inner = inner, img = img, ghost = nil,
		ghostAlpha = ItemRules.CUBES.ghostTransparency, tint = -1, scale = 1,
		glow = if glow and glow:IsA("BasePart") then glow else nil, marks = marks, marksOn = not cooling, ring = ring,
		nextRing = os.clock() + math.random() * ItemRules.CUBE_FX.ringPeriod,
		frameFade = 0,
	}
	if cooling then
		for i, p in parts do
			p.Size = sizes[i] * 0.02
		end
		cube.scale = 0.02
	end
	pods[pod] = {
		pod = pod,
		cube = cube,
		gui = g,
		img = halo,
		icon = inner,
		core = core,
		spec = nil,
		light = core:FindFirstChildOfClass("PointLight"),
		rainbow = false, -- cubes v2: stepCube tints the glass, core, halo and light from the shared ghost cycle
		baseCF = baseCF,
		baseSize = core.Size,
		phase = math.random() * math.pi * 2,
		cooling = cooling,
		inflateAt = 0,
	}
end

-- Registers a pod for the shared loop. Item pods keep their soft halo (a glow_soft billboard in the item colour); a
-- mesh-art core (ItemArt) also gets its item icon billboard. Speed and Air pods have art only. A pod whose core has not
-- replicated yet is skipped and picked up by the next scan.
local function scanPods()
	local boosts = TrackRegistry.getBoostsFolder()
	if not boosts then
		return
	end
	for _, pod in boosts:GetChildren() do
		if pod:IsA("BasePart") and pod:GetAttribute("ItemPodSpawn") == true and not pods[pod] and pod:GetAttribute("MysteryCube") == true then
			scanCube(pod)
		elseif pod:IsA("BasePart") and pod:GetAttribute("ItemPodSpawn") == true and not pods[pod] then
			local podType = pod:GetAttribute("PodType")
			local podClass = ItemRules.classifyPod(podType)
			local isItem = podClass == "item"
			if isItem or podClass == "speed" or podClass == "air" then
				local found = pod:FindFirstChild(pod.Name .. "_CoreVisual")
				local core = if found and found:IsA("BasePart") then found else nil
				local spec: ItemArt.PodSpec? = nil
				-- Mesh art, or the part-built boost block (cubes v3 Speed pods); never the plain fallback ball.
				if core and (core:IsA("MeshPart") or core:GetAttribute("PodArt") == "boost") and core:GetAttribute("PodArt") ~= "fallback" then
					spec = ItemArt.podSpec(podType)
				end
				if isItem or spec then
					local cooling = pod:GetAttribute("OnCooldown") == true
					local gui: BillboardGui? = nil
					local img: ImageLabel? = nil
					if isItem then
						local g = Instance.new("BillboardGui")
						g.Name = "ItemPodGlow"
						g.Adornee = pod
						g.Size = UDim2.fromScale(10, 10) -- studs: a halo just larger than the balloon
						g.LightInfluence = 0
						g.MaxDistance = 320
						g.ResetOnSpawn = false
						g.Enabled = not cooling
						local il = Instance.new("ImageLabel")
						il.Size = UDim2.fromScale(1, 1)
						il.BackgroundTransparency = 1
						il.Image = tex("glow_soft")
						il.ImageColor3 = rgb(ItemRules.podRgb(podType))
						il.ImageTransparency = if spec then 0.5 else 0.25 -- the balloon is the star, the halo only a hint
						il.Parent = g
						g.Parent = pod
						gui, img = g, il
					end
					local icon: BillboardGui? = nil
					if spec and core and spec.icon and ItemTexAssets[spec.icon] then
						local ig = Instance.new("BillboardGui")
						ig.Name = "ItemPodIcon"
						ig.Adornee = core
						ig.Size = UDim2.fromScale(2.7, 2.7) -- studs
						ig.LightInfluence = 0
						ig.MaxDistance = POD_ICON_RANGE
						ig.ResetOnSpawn = false
						ig.Enabled = not cooling
						local il = Instance.new("ImageLabel")
						il.Size = UDim2.fromScale(1, 1)
						il.BackgroundTransparency = 1
						il.Image = ItemTexAssets[spec.icon]
						il.Parent = ig
						ig.Parent = core
						icon = ig
					end
					local baseCF = if core then core.CFrame else pod.CFrame
					local baseSize = if core then core.Size else pod.Size
					if spec and core and cooling then
						core.Size = baseSize * 0.02 -- hidden pod: ready to inflate from nothing when it comes back
					end
					pods[pod] = {
						pod = pod,
						gui = gui,
						img = img,
						icon = icon,
						core = core,
						spec = spec,
						light = if spec and core then core:FindFirstChildOfClass("PointLight") else nil,
						rainbow = podType == "Rainbow",
						baseCF = baseCF,
						baseSize = baseSize,
						phase = math.random() * math.pi * 2,
						cooling = cooling,
						inflateAt = 0,
					}
				end
			end
		end
	end
end

-- A pod was just taken (OnCooldown turned on): the balloon pops with confetti in its colour; a coin or swirl gives a
-- glint. Hidden at once (tiny) so the server's transparency flip and the re-inflation never show a full-size frame.
local function podTaken(g: PodVis, cam: Vector3?, hue: Color3)
	local cube = g.cube
	if cube then
		local pos = g.baseCF.Position
		local dist = if cam then (cam - pos).Magnitude else math.huge
		if dist < POD_POP_RANGE then
			ItemClient.burst(if Settings.lowGraphics() then "pickupGlint" else "cubePop", pos, hue)
			if not Sfx.at("pod_pop", pos, 0.71) and not Sfx.has("pod_pop") then
				PayoffSound.play("confetti_pop", 0.92 + math.random() * 0.2, math.clamp(1.25 - dist / 220, 0.15, 1))
			end
		end
		for i, p in cube.parts do
			p.Size = cube.sizes[i] * 0.02
		end
		cube.scale = 0.02
		return
	end
	local spec = g.spec
	local core = g.core
	if not spec or not core then
		return
	end
	local pos = g.baseCF.Position
	local dist = if cam then (cam - pos).Magnitude else math.huge
	if dist < POD_POP_RANGE then
		if spec.kind == "balloon" then
			ItemClient.burst("balloonPop", pos, if g.rainbow then hue else spec.light)
			-- 3D now: the roll-off does the distance scaling the old clamp(1.25 - dist / 220) did; the old pop until it has an id.
			if not Sfx.at("pod_pop", pos, 0.71) and not Sfx.has("pod_pop") then
				PayoffSound.play("confetti_pop", 0.92 + math.random() * 0.2, math.clamp(1.25 - dist / 220, 0.15, 1))
			end
		else
			ItemClient.burst("pickupGlint", pos, spec.light)
		end
	end
	core.Size = g.baseSize * 0.02
end

-- easeOutBack: re-inflates with a little overshoot (about ten percent) before settling.
local function easeOutBack(u: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	local x = u - 1
	return 1 + c3 * x * x * x + c1 * x * x
end

-- One BulkMoveTo per frame for every animated cube part (filled by stepCube, flushed at the end of step).
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

-- Missile v3: a trap dragged behind a racer (ItemFx "trapDrag"). One small non-colliding ball per vehicle, low and
-- behind the hull, so it never sits in the chase camera's line to the kart; client-only (under the camera).
local DRAG_BEHIND = 6.5
local DRAG_DROP = 0.9
local dragged: { [Model]: BasePart } = {}

local function setDragged(model: Model?, on: boolean)
	if not model then
		return
	end
	local old = dragged[model]
	if old then
		old:Destroy()
		dragged[model] = nil
	end
	if not on then
		return
	end
	local p = Instance.new("Part")
	p.Name = "DraggedTrap"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(1.6, 1.6, 1.6)
	p.Material = Enum.Material.Neon
	p.Color = rgb(ItemRules.COLOR_RGB.green)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = workspace.CurrentCamera
	dragged[model] = p
end

local function stepDragged()
	if next(dragged) == nil then
		return
	end
	for model, part in dragged do
		local hull = hullOf(model)
		if not hull then
			part:Destroy()
			dragged[model] = nil
		else
			local cf = hull.CFrame
			part.CFrame = CFrame.new(cf.Position - cf.LookVector * DRAG_BEHIND - cf.UpVector * DRAG_DROP)
			part.LocalTransparencyModifier = if ownVehicle(model) then 0.35 else 0
		end
	end
end

-- One cube for one frame: light and halo by distance and graphics level, the regrow after a respawn, the tumble and bob
-- (queued for the shared BulkMoveTo), and the inner icon cycle. Hidden or out-of-range cubes cost a distance check.
local viewVehicleDist = math.huge -- camera-to-own-vehicle distance this frame (math.huge: no vehicle, e.g. a spectator)
local viewIsPlane = false -- set once per frame in step: the chase camera is further back on a plane (ItemRules.CUBE_CAMERA_BANDS)

local function stepCube(g: PodVis, cube: CubeVis, cooling: boolean, now: number, cam: Vector3, range: number, low: boolean)
	local base = g.baseCF
	local dist = (cam - base.Position).Magnitude
	-- box-range: a cube is thinned / shrunk / faded only once it is between the lens and the vehicle (already passed).
	-- A cube ahead of the vehicle is always farther from the camera than the vehicle is, so it stays whole until taken.
	local nearD = ItemRules.cubeLensDist(dist, viewVehicleDist)
	local light = g.light
	if light then
		local want = not cooling and not low and dist < POD_LIGHT_RANGE
		if light.Enabled ~= want then
			light.Enabled = want
		end
	end
	local halo = g.gui
	if halo then
		local want = not cooling and not low
		if halo.Enabled ~= want then
			halo.Enabled = want
		end
	end
	-- Point-blank thinning: the halo fades out and the Neon frame turns see-through over the last few studs, so a
	-- drive-through is never a wall of yellow bloom (the core already fades by nearFadeEnd).
	local F = ItemRules.CUBE_FX
	local B = ItemRules.cubeBand(viewIsPlane)
	local haloImg = g.img
	if haloImg and not cooling then
		local ht = F.haloBase + (1 - F.haloBase) * ItemRules.cubeNearAmount(nearD, B.fadeStart, B.fadeEnd)
		if math.abs(haloImg.ImageTransparency - ht) > 0.01 then
			haloImg.ImageTransparency = ht
		end
	end
	local ff = if cooling then 0 else F.frameFadeMax * ItemRules.cubeNearAmount(nearD, B.fadeStart, B.fadeEnd)
	if math.abs(ff - cube.frameFade) > 0.01 or (ff == 0 and cube.frameFade ~= 0) then
		cube.frameFade = ff
		local glowPart = cube.glow
		for _, p in cube.parts do
			if p ~= glowPart then
				p.LocalTransparencyModifier = ff
			end
		end
	end
	-- The "?" faces are off during the cooldown and while the camera is inside the cube.
	local marksWant = not cooling and nearD > B.fadeEnd
	if marksWant ~= cube.marksOn then
		cube.marksOn = marksWant
		for _, m in cube.marks do
			m.Enabled = marksWant
		end
	end
	-- v21: the cycling item icon (a 2.3-stud billboard) hides near the camera like the "?" faces: at 1 stud it filled the screen.
	local innerWant = not cooling and nearD > B.fadeEnd
	if cube.inner.Enabled ~= innerWant then
		cube.inner.Enabled = innerWant
	end
	if cooling or dist >= range then
		return
	end
	-- The shared item colour on the core, halo and light (step computes it once per frame; nothing is written while it
	-- holds still). The glass and frame keep the cube's own family colour from the build (cubes v3 multicolour look).
	if cube.tint ~= tintSerial then
		cube.tint = tintSerial
		local glowPart = cube.glow
		if glowPart then
			glowPart.Color = tintCore
		end
		if haloImg then
			haloImg.ImageColor3 = tintItem
		end
		if light then
			light.Color = tintItem
		end
	end
	-- The core pulses and fades out as the camera nears.
	local glow = cube.glow
	if glow then
		local tr = ItemRules.cubeCoreTransparency(now + g.phase, nearD, viewIsPlane)
		if math.abs(glow.Transparency - tr) > 0.01 then
			glow.Transparency = tr
		end
	end
	local ring = cube.ring
	if ring and now >= cube.nextRing then
		local period = ItemRules.cubeRingPeriod(Settings.particleScale())
		cube.nextRing = now + (period or 1e9)
		-- v29 A1: no ground pulse once the cube is inside its near-fade (it flashed beside the lens on plane routes)
		if period and not low and dist < ItemRules.CUBE_FX.ringRange and dist > B.fadeStart then
			ring:Emit(1)
		end
	end
	-- Regrow after the cooldown: scale up with overshoot, then settle at exactly the built sizes.
	local scale = 1
	if g.inflateAt > 0 then
		local u = (now - g.inflateAt) / POD_INFLATE_SECONDS
		if u >= 1 then
			g.inflateAt = 0
		else
			scale = math.max(easeOutBack(u), 0.02)
		end
	elseif cube.scale ~= 1 then
		scale = 1 -- came back while out of range: snap to the built sizes
	end
	-- v31: the visible cube shrinks as the lens closes in (never a big frame beside the chase camera); trigger unchanged.
	scale = math.min(scale, ItemRules.cubeNearScale(nearD, viewIsPlane))
	if math.abs(scale - cube.scale) > 0.004 or (scale == 1 and cube.scale ~= 1) then
		cube.scale = scale
		for i, p in cube.parts do
			p.Size = cube.sizes[i] * scale
		end
	end
	local t = now + g.phase
	local cf = base
		* CFrame.new(0, math.sin(t * 1.6) * CUBE_BOB, 0)
		* CFrame.fromEulerAnglesYXZ(t * CUBE_SPIN.X, t * CUBE_SPIN.Y, t * CUBE_SPIN.Z)
	for i, p in cube.parts do
		local off = cube.offsets[i]
		table.insert(moveParts, p)
		table.insert(moveCFrames, if scale == 1 then cf * off else cf * (off - off.Position + off.Position * scale))
	end
	if dist < POD_ICON_RANGE then
		-- The ghost swaps with the shared cycle and fades out with the core as the camera nears (CUBE_FX near fade).
		if cube.ghost ~= ghostShown then
			cube.ghost = ghostShown
			local ic = ItemRules.iconOf(ghostShown)
			local id = if ic then ItemTexAssets[ic.tex] else nil
			cube.img.Visible = id ~= nil
			if id then
				cube.img.Image = id
				cube.img.ImageColor3 = GHOST_ICON_COLOR3[ghostShown] or cube.img.ImageColor3
			end
		end
		local base0 = ItemRules.CUBES.ghostTransparency
		local ga = base0 + (1 - base0) * ItemRules.cubeNearAmount(nearD, B.fadeStart, B.fadeEnd)
		if math.abs(ga - cube.ghostAlpha) > 0.02 or (ga == 1 and cube.ghostAlpha ~= 1) then
			cube.ghostAlpha = ga
			cube.img.ImageTransparency = ga
		end
	end
end

local function step(dt: number)
	ItemsV4Fx.step(dt)
	ItemShow.step(dt)
	do
		local planesFolder = workspace:FindFirstChild("Planes")
		local own = if planesFolder then planesFolder:FindFirstChild("Plane_" .. LocalPlayer.Name) else nil
		viewIsPlane = own ~= nil
		if not own and planesFolder then
			own = planesFolder:FindFirstChild("Car_" .. LocalPlayer.Name)
		end
		local hull = hullOf(own)
		local camP = cameraPos()
		viewVehicleDist = if hull and camP then (camP - hull.Position).Magnitude else math.huge
	end
	local now = os.clock()
	hueClock = (hueClock + dt * 0.4) % 1
	stepDragged()
	stepSpikes(now)
	local alpha = 1 - math.exp(-dt * MISSILE_EASE)
	for server, copy in missiles do
		if not server.Parent then
			missiles[server] = nil
			lockedOnMe[copy] = nil
			missileRoll[copy] = nil
			missileLead[copy] = nil
			missileVel[copy] = nil
			copy:Destroy()
		else
			local goal = server.CFrame
			-- Lead the easing by the body's own velocity (the steady lag of an exponential ease is velocity / rate).
			local sp = server.Position
			local mv = missileVel[copy]
			if mv then
				if (sp - mv.pos).Magnitude > 0.01 then
					local span = now - mv.t
					local v = if span > 1e-3 then (sp - mv.pos) / span else mv.vel
					mv.vel = if v.Magnitude > 700 then mv.vel else mv.vel:Lerp(v, 0.5)
					mv.pos, mv.t = sp, now
				end
			else
				mv = { pos = sp, vel = server.CFrame.LookVector * 300, t = now }
				missileVel[copy] = mv
			end
			goal = goal + mv.vel / MISSILE_EASE
			local lead = missileLead[copy]
			if lead then
				local k = 1 - (now - lead.t0) / MISSILE_LEAD_FADE
				if k > 0 then
					goal = goal + lead.offset * k
				else
					missileLead[copy] = nil
				end
			end
			-- The mesh rolls about its flight axis: take last frame's roll off before easing toward the server pose.
			local roll = missileRoll[copy]
			local cur = if roll then copy.CFrame * CFrame.Angles(0, 0, -roll) else copy.CFrame
			local nextCF = if (cur.Position - goal.Position).Magnitude > 45 then goal else cur:Lerp(goal, alpha)
			if roll then
				roll += dt * 6
				missileRoll[copy] = roll
				nextCF = nextCF * CFrame.Angles(0, 0, roll)
			end
			copy.CFrame = nextCF
		end
	end
	local serverNow = workspace:GetServerTimeNow()
	local camNow = cameraPos()
	for model, t in traps do
		if not model.Parent then
			traps[model] = nil
		else
			local armed = serverNow - t.spawnedAt >= t.arm
			local rate = if armed then 5 else 2
			local on = math.sin((now + t.phase) * rate * math.pi * 2) > 0
			local light = t.light
			if light then
				light.Color = if on then Color3.fromRGB(255, 70, 50) else Color3.fromRGB(90, 20, 15)
			end
			local glow = t.glow
			if glow then
				glow.Enabled = on and armed
			end
			local near = camNow ~= nil and (camNow - t.pivot.Position).Magnitude < 170
			local embers = t.embers
			if embers then
				embers.Rate = if armed and near then 5 * Settings.particleScale() else 0
			end
			local halo = t.halo
			if halo and on and not t.wasOn and armed and near then
				halo:Emit(1) -- one pulse per blink
			end
			t.wasOn = on
			-- Slow spin and bob, local only: the server never moves a placed trap, so nothing overwrites it.
			model:PivotTo(t.pivot * CFrame.new(0, math.sin(now * 2 + t.phase) * t.bob, 0) * CFrame.Angles(0, now * t.spin + t.phase, 0))
		end
	end
	for plane, s in shields do
		local hull = hullOf(plane)
		local bubble = s.inst :: BasePart
		if not hull or now >= s.untilT then
			if hull then
				-- Ran out (not a hull that went away): the shell pops.
				Sfx.at("shield_break", bubble.Position, if ownVehicle(plane) then 0.82 else Sfx.quiet(0.82))
				ItemClient.burst("shieldPop", bubble.Position, nil, if ownVehicle(plane) then 0.7 else 1)
			end
			shields[plane] = nil
			bubble:Destroy()
		else
			bubble.CFrame = hull.CFrame
			-- The last second: the hex billboard blinks and the edge sparkles triple (ItemFxRules).
			local left = s.untilT - now
			local blink = ItemFxRules.blinking(left)
			local loop = s.loop
			if loop then
				loop.Volume = (s.loopVol or 0.28) * (if left < 1 then 0.6 else 1)
			end
			updateBubbleFx(s, bubble, camNow, left, blink)
		end
	end
	for plane, s in respawnBubbles do
		local hull = hullOf(plane)
		local bubble = s.inst :: BasePart
		if not hull or now >= s.untilT then
			respawnBubbles[plane] = nil
			bubble:Destroy()
		else
			bubble.CFrame = hull.CFrame
			-- A soft shimmer while it runs, then the hex billboard blinks over the last 0.6 s: "safe, but not for long".
			local left = s.untilT - now
			updateBubbleFx(s, bubble, camNow, left, left < 0.6 and math.floor(left * 12) % 2 == 0)
		end
	end
	for plane, d in dizzies do
		if now >= d.untilT or not plane.Parent then
			dizzies[plane] = nil
			d.inst:Destroy()
		end
	end
	for i = #beams, 1, -1 do
		local b = beams[i]
		if now >= b.untilT or not b.from.Parent or not b.to.Parent then
			table.remove(beams, i)
			b.beam:Destroy()
			b.a0:Destroy()
			b.a1:Destroy()
		else
			-- A little curve jitter each frame makes the textured beam read as lightning.
			b.beam.CurveSize0 = math.sin(now * 37) * 4
			b.beam.CurveSize1 = math.cos(now * 29) * 4
		end
	end
	-- Item 14: a shot locked on this player flashes white-hot on every beep.
	if next(lockedOnMe) ~= nil then
		local pulse = ItemJuice.beepPulse()
		for copy, light in lockedOnMe do
			light.Brightness = 2 + 6 * pulse
			light.Range = 12 + 10 * pulse
			if copy:IsA("MeshPart") then
				ItemArt.setTint(copy, if pulse > 0.5 then Color3.new(1, 1, 1) else HOMING_TINT)
			else
				copy.Color = if pulse > 0.5 then Color3.new(1, 1, 1) else HOMING_PINK
			end
		end
	end
	ItemJuice.step(dt)
	RivalBubbles.step(dt)
	if now >= podScanAt then
		podScanAt = now + 2
		scanPods()
	end
	local cam = cameraPos()
	local hue = Color3.fromHSV(hueClock, 0.6, 1)
	local low = Settings.lowGraphics()
	local cubeRange = if low then CUBE_LOW_RANGE else ItemRules.CUBES.animRange
	-- Cubes v2: one ghost clock for every cube. The band is re-read twice a second (Rank publishes at about 7 Hz).
	if now >= ghostCheckAt then
		ghostCheckAt = now + 0.5
		local rank = LocalPlayer:GetAttribute("Rank")
		local field = RaceAttr.mine("TotalRacers")
		-- Items v4: only what this race's rotation can roll (RaceAttr ItemPool; "" = the classic table).
		local poolText = RaceAttr.mine(ItemRules.ROTATION.poolAttribute)
		ghostSchedule = ItemRules.ghostFor(
			if type(rank) == "number" then rank else 1,
			if type(field) == "number" then field else 1,
			ghostHeld,
			if type(poolText) == "string" then poolText else nil,
			LocalPlayer:GetAttribute("LeaderGap") :: number? -- v38: the server's gap bands (ItemRules.CATCHUP)
		)
	end
	local gFrom, gTo, gBlend = ItemRules.ghostAt(ghostSchedule, now)
	ghostShown = gFrom
	gBlend = math.floor(gBlend * 20 + 0.5) / 20 -- 5 % steps: a crossfade writes about 7 times, a dwell never
	if gFrom ~= ghostFrom or gTo ~= ghostTo or gBlend ~= ghostBlend then
		ghostFrom, ghostTo, ghostBlend = gFrom, gTo, gBlend
		local a = ITEM_COLOR3[gFrom] or Color3.new(1, 1, 1)
		tintItem = if gBlend > 0 then a:Lerp(ITEM_COLOR3[gTo] or a, gBlend) else a
		tintCore = Color3.new(1, 1, 1):Lerp(tintItem, 0.7)
		tintSerial += 1
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
	for pod, g in pods do
		if not pod.Parent then
			pods[pod] = nil
		else
			-- Pods hide for everyone on OnCooldown; this racer's own claim (PodLocal) hides it before that arrives.
			local cooling = pod:GetAttribute("OnCooldown") == true or PodLocal.isTaken(pod, now)
			local spec = g.spec
			local core = g.core
			local gui = g.gui
			if cooling ~= g.cooling then
				g.cooling = cooling
				if gui then
					gui.Enabled = not cooling
				end
				if g.icon then
					g.icon.Enabled = not cooling
				end
				if cooling then
					podTaken(g, cam, hue)
				else
					g.inflateAt = now
				end
			end
			if g.rainbow then
				local halo = g.img
				if halo then
					halo.ImageColor3 = hue
				end
				if g.light then
					g.light.Color = hue
				end
				local glow = if g.cube then g.cube.glow else nil
				if glow and not cooling then
					glow.Color = Color3.new(1, 1, 1):Lerp(hue, 0.7)
				end
				if not spec and not g.cube and core then
					core.Color = hue -- the plain fallback ball cycles; the striped rainbow balloon never does
				end
			end
			local cube = g.cube
			if cube then
				if cam then
					stepCube(g, cube, cooling, now, cam, cubeRange, low)
				end
			elseif spec and core and cam then
				local base = g.baseCF
				local dist = (cam - base.Position).Magnitude
				local light = g.light
				if light then
					local want = not cooling and dist < POD_LIGHT_RANGE
					if light.Enabled ~= want then
						light.Enabled = want
					end
				end
				if not cooling and dist < POD_ANIM_RANGE then
					local t = now + g.phase
					local kind = spec.kind
					if kind == "balloon" then
						-- Gentle bob and a slow sway (yaw plus a touch of pitch and roll).
						core.CFrame = base * CFrame.new(0, math.sin(t * 1.7) * 0.5, 0)
							* CFrame.Angles(math.sin(t * 1.1) * 0.05, math.sin(t * 0.8) * 0.5, math.sin(t * 1.3) * 0.07)
						local icon = g.icon
						if icon and dist < POD_ICON_RANGE then
							-- The icon sits on the camera side of the balloon body (0.8 stud-scale above the part centre),
							-- just outside its surface, so the depth-tested billboard is never inside the mesh. The body's
							-- radius is 1.68 * scale (manifest), so the old 1.65 left the icon's middle under the skin: Studio
							-- captures showed it clipped to a sliver at the balloon's edge (out/verify_merge/v3_pop_red_1.8.png).
							local s = spec.scale
							local centre = base.Position + Vector3.new(0, 0.8 * s, 0)
							local toCam = cam - centre
							local m = toCam.Magnitude
							if m > 0.1 then
								icon.StudsOffsetWorldSpace = Vector3.new(0, 0.8 * s, 0) + toCam / m * (2.2 * s)
							end
						end
					elseif kind == "boost" then
						-- The boost block stays upright (its bolts read) and turns, with a little rock on the bob.
						core.CFrame = base * CFrame.new(0, math.sin(t * 2) * 0.4, 0) * CFrame.Angles(0, t * 1.8, math.sin(t * 1.3) * 0.12)
					else
						core.CFrame = base * CFrame.new(0, math.sin(t * 1.5) * 0.35, 0) * CFrame.Angles(0, t * 1.1, 0)
					end
				end
				-- Re-inflation after the cooldown: scale up with overshoot, then settle at the exact base size.
				if g.inflateAt > 0 and not cooling then
					local u = (now - g.inflateAt) / POD_INFLATE_SECONDS
					if u >= 1 then
						g.inflateAt = 0
						core.Size = g.baseSize
					else
						core.Size = g.baseSize * math.max(easeOutBack(u), 0.02)
					end
				end
			end
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Server events
------------------------------------------------------------------------------------------------------------------------

local toast: Toast? = nil
local heldColor: string? = nil
local heldLevel = 0

local function say(msg: string, color: Color3, seconds: number)
	local t = toast
	if t then
		t(msg, color, seconds)
	end
end

local function onItemState(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local color = if ItemRules.isColor(payload.color) then payload.color :: string else nil
	local level = if type(payload.level) == "number" then payload.level else 0
	local gained = color ~= nil and (color ~= heldColor or level > heldLevel)
	heldColor, heldLevel = color, if color then level else 0
	if ghostHeld ~= color then
		ghostHeld = color
		ghostCheckAt = 0 -- the cube ghosts switch to "upgrade this" (or back to the roll table) on the next frame
	end
	local roulette = if type(payload.roulette) == "number" then payload.roulette else nil
	HudExtras.setItem(color, level, roulette, if type(payload.charges) == "number" then payload.charges else nil)
	MagnetAim.setHeld(color, level)
	if gained then
		SoundJuice.triggerFeedback("small", "Pickup")
		local hull = FlightController.hull
		if hull then
			-- A fresh mystery roll glints cream: the item's colour is the HUD roulette's reveal, not this.
			local tint = if roulette then Color3.fromRGB(255, 244, 214) else rgb(ItemRules.colorRgb(color))
			ItemClient.burst("pickupGlint", hull.Position + hull.CFrame.LookVector * 6, tint)
		end
	end
end

local function onItemUsed(payload: any)
	local color = if type(payload) == "table" and ItemRules.isColor(payload.color) then payload.color :: string else nil
	HudExtras.itemFired(color)
	-- No cue here: the missile launch, the trap drop and the shield each sound from their own site (track, onItemFx).
end

-- Car tracks: CarController listens on the same remote and applies boost/hit/magnet to the car itself (CarServer names
-- the model "Car_<player>" under workspace.Planes). Feeding the plane controller too would double the sounds and leave
-- its stun flag set with no plane stepping to clear it.
local function drivingCar(): boolean
	local planes = workspace:FindFirstChild("Planes")
	return planes ~= nil and planes:FindFirstChild("Car_" .. LocalPlayer.Name) ~= nil
end

-- CarController, loaded on first use (a sibling client module; requiring it at load would tie the two modules' load
-- order together for no reason).
local carModule: any = nil
local function carController(): any
	if carModule == nil then
		local inst = script.Parent:FindFirstChild("CarController")
		local ok, mod = pcall(function(): any
			return if inst then (require :: any)(inst) else nil
		end)
		carModule = if ok and type(mod) == "table" then mod else false
	end
	return if carModule then carModule else nil
end

-- Camera kick on whichever controller drives this client's vehicle.
local function kick(amount: number)
	if drivingCar() then
		local cc = carController()
		if cc and type(cc.addTrauma) == "function" then
			cc.addTrauma(amount)
		end
	else
		FlightController.addTrauma(amount)
	end
end

-- This client's vehicle (car or plane) and its hull, for "is that mine / is that near me".
local function myVehicle(): (Model?, BasePart?)
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil, nil
	end
	local m = planes:FindFirstChild("Car_" .. LocalPlayer.Name) or planes:FindFirstChild("Plane_" .. LocalPlayer.Name)
	if m and m:IsA("Model") then
		return m, hullOf(m)
	end
	return nil, nil
end

-- Whether an item "hit" on this client's own vehicle is a stale one to drop (G2, H0-07: RespawnRules.clientIgnoresHit):
-- still respawning, inside HIT_STALE_WINDOW of the respawn, or under the server's own respawn bubble. Any other hit
-- the server sent is applied, even inside the controllers' longer invulnTimer (which still guards walls, lava, water).
local function staleHit(): boolean
	local respawning, lastAt = false, -math.huge
	if drivingCar() then
		local cc = carController()
		if cc ~= nil then
			respawning = cc.respawning == true
			lastAt = if type(cc.lastRespawnAt) == "number" then cc.lastRespawnAt else -math.huge
		end
	else
		respawning = FlightController.crashing == true
		lastAt = FlightController.lastRespawnAt
	end
	local untilT = LocalPlayer:GetAttribute("RespawnShieldUntil")
	local shieldLeft = if type(untilT) == "number" then math.max(0, untilT - os.clock()) else 0
	return RespawnRules.clientIgnoresHit(respawning, os.clock() - lastAt, shieldLeft)
end

local lastSafeToast = 0

local function onItemEffect(kind: any, payload: any)
	if type(kind) ~= "string" then
		return
	end
	local data = if type(payload) == "table" then payload else {}
	if kind == "hit" and staleHit() then
		-- G2: just respawned. The server's protection normally stops the hit before it is sent; this covers a hit
		-- that was already on its way when the respawn began.
		return
	end
	if not drivingCar() then
		FlightController.applyItemEffect(kind, data)
	end
	ItemsV4Fx.onEffect(kind, data) -- items v4: callouts, the storm siren (the controllers apply the speed side)
	ItemShow.onEffect(kind, data)
	ItemsV5Fx.onEffect(kind, data)
	if kind == "hit" then
		-- Item 14: the hit knock (and birdies) replaces the crash thud the controllers used to play for an item hit;
		-- before the cues are uploaded the old thud stands in. The warning is over either way.
		ItemJuice.clearIncoming()
		if not ItemJuice.bonk() then
			SoundJuice.triggerFeedback("large", "Crash")
		end
		if data.source == "trap" and data.form == "slick" then
			Sfx.play("oil_slip", 1, 0.5) -- under the knock
		end
		say(if data.source == "trap" then "TRAPPED" else "SPIN-OUT", Color3.fromRGB(255, 120, 90), 1.4)
	elseif kind == "shield" then
		say("SHIELD UP", SHIELD_YELLOW, 1.2)
	elseif kind == "magnet" then
		Sfx.play("magnet_lock", 1, 0.59)
		say("MAGNET LOCK", rgb(ItemRules.COLOR_RGB.rainbow), 1.2)
		local target = data.target
		if typeof(target) == "Instance" and target:IsA("Model") then
			MagnetAim.lock(target, math.clamp(tonumber(data.seconds) or 2.5, 0.1, 5))
		end
	elseif kind == "magnetMiss" then
		-- The server saw nobody in range (the preview was a frame behind): the item is spent, say why.
		MagnetAim.release()
		TrickJuice.callout("MAGNET: NO ONE IN RANGE", rgb(ItemRules.COLOR_RGB.rainbow), 1.2)
	elseif kind == "blocked" then
		-- Item bugs audit: my missile met a shield or a respawn bubble. Said outright, so a block never looks like a hit
		-- that did no damage (the puff and the shield_block cue already play at the target).
		TrickJuice.callout(if data.respawn == true then "BLOCKED (RESPAWN)" else "BLOCKED", SHIELD_YELLOW, 1.1)
	end
end

-- Item bugs audit: the server's answer to every pickup this client claimed. A capped upgrade and a cube another racer
-- took first get a caption (ItemRules.pickupNotice); every refusal is logged here, so a Studio session shows why a cube
-- that popped on screen gave nothing (too_far: the server saw the hull out of reach; blocked:*: the race phase).
local lastPickupNoticeAt = 0
local function onPickupAnswer(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local reason = if type(payload.reason) == "string" then payload.reason else nil
	if reason then
		print(string.format("[SkyRally][ITEM] client pickup refused reason=%s", reason))
	end
	local label = if type(payload.color) == "string" then ItemRules.DISPLAY_NAME[payload.color] else nil
	local notice = ItemRules.pickupNotice(payload.outcome, reason, label)
	local now = os.clock()
	-- v28 W1.26: a capped item ("MISSILE MAXED") repeats on every cube in a row; one caption per 3 s, never a stack.
	local gap = if payload.outcome == "capped" then 3 else 0.8
	if notice and now - lastPickupNoticeAt > gap then
		lastPickupNoticeAt = now
		say(notice, if payload.outcome == "capped" then Color3.fromRGB(255, 214, 90) else Color3.fromRGB(235, 235, 235), 1.1)
		if payload.outcome == "capped" then
			HudExtras.itemMaxed()
		end
	end
end

-- The form of the tracked trap nearest a blast within 14 studs: the fallback when the server's payload has no form.
local function trapFormNear(pos: Vector3): string?
	local best: string? = nil
	local bestD = 14
	for model, t in traps do
		local d = (t.pivot.Position - pos).Magnitude
		local form = model:GetAttribute("Form")
		if d < bestD and type(form) == "string" then
			bestD = d
			best = form
		end
	end
	return best
end

local function onItemFx(fx: any, payload: any)
	if type(fx) ~= "string" or type(payload) ~= "table" then
		return
	end
	local pos = payload.pos
	local plane = payload.plane
	local planeModel = if typeof(plane) == "Instance" and plane:IsA("Model") then plane else nil
	ItemsV4Fx.onFx(fx, payload) -- items v4 (it ignores the classic events it does not draw)
	ItemShow.onFx(fx, payload)
	ItemsV5Fx.onFx(fx, payload)
	if fx == "explode" then
		if typeof(pos) == "Vector3" then
			local source = if type(payload.source) == "string" then payload.source else ""
			local hazard = string.match(source, "^boss_(%w+)$")
			if source == "trap" then
				ItemClient.burst("trapPop", pos, nil) -- green smoke and shards say "trap", the blast says "hit"
			end
			if payload.wall == true then
				-- X-01: the shot met a wall or a hull. Chips off the face; up close it thunks and kicks the camera, so
				-- the cover that saved you is something you feel.
				ItemClient.burst("wallChips", pos, nil)
				local _, hull = myVehicle()
				local d = if hull then (hull.Position - pos).Magnitude else math.huge
				if d < WALL_KICK_RANGE then
					kick(0.3 * (1 - d / WALL_KICK_RANGE) + 0.08) -- the thud is the blast cue below, 3D at the wall
				end
			end
			-- A boss hazard hit shows the hazard's own impact (snow burst, bubble splash, bolt, fire); a mine or a
			-- missile shows the blast, with its own sound: loud when it is on this player, quieter for anyone else's.
			if not (hazard and Vfx.onHazardHit(hazard, pos)) then
				local onMe = ownVehicle(planeModel)
				-- The local victim gets the softer variant (no flash, thin fireball): being hit must not white out the view.
				-- Frost Shot / Coin Burst hits stay small and never start on the lens (ItemFxRules, Studio V9 g3).
				local cam = cameraPos()
				local burstK = ItemFxRules.statusBurstScale(source, onMe, if cam then (cam - pos).Magnitude else nil)
				if burstK then
					ItemClient.burst(if onMe then "missileBlastSelf" else "missileBlast", pos, nil, if burstK ~= 1 then burstK else nil)
				end
				if source == "trap" then
					local form = if type(payload.form) == "string" then payload.form else trapFormNear(pos)
					local cue = if form == "slick" then "oil_splat" else "mine_blast"
					local vol = if form == "slick" then 0.63 else 0.76
					Sfx.at(cue, pos, if onMe then vol else Sfx.quiet(vol))
				else
					Sfx.at("missile_explode", pos, if onMe then 0.9 else Sfx.quiet(0.9))
				end
			end
		end
		if planeModel and type(payload.seconds) == "number" then
			addDizzy(planeModel, math.clamp(payload.seconds, 0.2, 4))
			-- Items 14 and 18: a landed hit (wall blasts carry no plane) soots the victim and, on anyone but this player,
			-- knocks in 3D (ring, sparks and spin smoke below carry the hit).
			local source = if type(payload.source) == "string" then payload.source else ""
			if source == "missile" or source == "trap" then
				ItemJuice.soot(planeModel, source == "trap")
				local victimHull = hullOf(planeModel)
				if victimHull then
					local mineHit = ownVehicle(planeModel)
					-- Shockwave ring and a crown of sparks on the victim (smaller on the local one), spin-out smoke for cars.
					ItemClient.burst("hitRing", victimHull.Position + Vector3.new(0, 1.5, 0), nil, if mineHit then 0.6 else 1)
					if string.sub(planeModel.Name, 1, 4) == "Car_" then
						ItemClient.burst("spinSmoke", victimHull.Position - Vector3.new(0, 1, 0), nil, if mineHit then 0.7 else 1)
					end
					if mineHit then
						kick(0.25)
					end
				end
				local mine = myVehicle()
				local hull = hullOf(planeModel)
				if mine ~= planeModel and hull then
					ItemJuice.play3D("item_bonk", hull)
				end
			end
		end
	elseif fx == "trapDrag" then
		-- Missile v3: a held trap trailing a vehicle (on), or gone (dropped, spent, replaced).
		setDragged(planeModel, payload.on == true)
	elseif fx == "dodge" then
		-- Missile v3: a barrel roll took the shot off (a player or a bot); the shot itself flies on and fizzles.
		if typeof(pos) == "Vector3" then
			ItemClient.burst("fizzle", pos, nil)
		end
	elseif fx == "blocked" then
		if typeof(pos) == "Vector3" then
			ItemClient.burst(if ownVehicle(planeModel) then "blockedSelf" else "blocked", pos, nil)
			-- v29 A2: the own shield's hex shows for 0.4 s on a block
			local held = if planeModel then shields[planeModel] else nil
			local fl = if held then held.flash else nil
			if fl and fl.Parent then
				fl:Emit(1)
			end
			if payload.trap == true then
				ItemClient.burst("trapPop", pos, nil) -- missile v3: a dragged trap ate it
			end
			Sfx.at("shield_block", pos, if ownVehicle(planeModel) then 0.76 else Sfx.quiet(0.76), if payload.respawn == true then 0.8 else 1)
		end
		if payload.respawn == true and planeModel then
			-- G2: it popped on a respawn bubble. The owner hears about it once a second at most.
			local mine = myVehicle()
			local now = os.clock()
			if mine == planeModel and now - lastSafeToast > 1 then
				lastSafeToast = now
				say("SAFE: RESPAWNING", RESPAWN_BUBBLE, 1.2)
			end
		end
	elseif fx == "respawnShield" then
		if planeModel and type(payload.seconds) == "number" then
			local secs = math.clamp(payload.seconds, 0.1, 5)
			addBubble(respawnBubbles, planeModel, secs, "RespawnBubble", RESPAWN_BUBBLE)
			if planeModel == myVehicle() then
				-- Local only (a client's own attribute never replicates): the car and plane read it to drop stale hits.
				LocalPlayer:SetAttribute("RespawnShieldUntil", os.clock() + secs)
			end
		end
	elseif fx == "fizzle" then
		if typeof(pos) == "Vector3" then
			ItemClient.burst("fizzle", pos, nil)
		end
	elseif fx == "shield" then
		if planeModel and type(payload.seconds) == "number" then
			addShield(planeModel, math.clamp(payload.seconds, 0.1, 12))
			local shieldHull = hullOf(planeModel)
			if ownVehicle(planeModel) then
				Sfx.play("shield_up", 1, 0.56)
			elseif shieldHull then
				Sfx.play3D("shield_up", shieldHull, Sfx.quiet(0.56))
			end
		end
	elseif fx == "magnetArrive" then
		-- Contact: a pop on the target for everyone else (the holder's own client popped it on contact).
		if not ownVehicle(payload.from) and typeof(payload.pos) == "Vector3" then
			ItemClient.burst("magnetZap", payload.pos, nil, 0.7)
		end
	elseif fx == "magnet" then
		local from, to = payload.from, payload.to
		if typeof(from) == "Instance" and from:IsA("Model") and typeof(to) == "Instance" and to:IsA("Model") and type(payload.seconds) == "number" then
			addBeam(from, to, math.clamp(payload.seconds, 0.1, 6))
			-- The locking racer heard its own lock in onItemEffect; everyone else hears it on the locked vehicle.
			local lockedHull = hullOf(to)
			if not ownVehicle(from) and lockedHull then
				Sfx.play3D("magnet_lock", lockedHull, 0.5)
			end
		end
	end
end

-- Item 14: the server's ETA updates. A dodge (a close call that missed) gets a stamp and a fly-by whistle.
local lastDodgeAt = 0
local MINT = Color3.fromRGB(140, 255, 170)
local lockTaught = false
local function vehicleKind(): string
	local m = myVehicle()
	if m and m:GetAttribute("VehicleType") == "car" then
		return "car"
	end
	-- BarrelRoll = false turns the roll off: then the plane has the item answers only.
	return if LocalPlayer:GetAttribute("BarrelRoll") == false then "car" else "plane"
end

local function onIncoming(payload: any)
	if type(payload) == "table" and payload.blocked == true then
		ItemJuice.setIncoming(payload)
		FlightController.itemDragging = false -- the dragged trap is spent
		TrickJuice.callout("BLOCKED", MINT, 1.0)
		return
	end
	if ItemJuice.setIncoming(payload) then
		local now = os.clock()
		if now - lastDodgeAt > 1 then
			lastDodgeAt = now
			ItemJuice.play("item_flyby")
			TrickJuice.callout("DODGED", MINT, 1.0)
		end
		return
	end
	-- Missile v3: the first lock of the session teaches the answer once (NotifySpec missile_lock_*).
	if not lockTaught and type(payload) == "table" and payload.lock == true then
		lockTaught = true
		NotifyKit.fromSpec(if vehicleKind() == "plane" then "missile_lock_roll" else "missile_lock_block")
	end
end

-- Item 18: getting even. Display names only (the server sends Player.DisplayName or a bot's roster name).
local GOT_GOLD = Color3.fromRGB(255, 214, 90)
local OWN_TRAP_LILAC = Color3.fromRGB(205, 170, 255)
local function onGrudge(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local role, kind = payload.role, payload.kind
	local chain = if type(payload.chain) == "number" then payload.chain else 0
	local name = string.upper(ItemRules.shortName(payload.name, 14))
	local plane = payload.plane
	if role == "self" then
		TrickJuice.callout("OWN TRAP", OWN_TRAP_LILAC, 1.3)
	elseif role == "robbed" then
		-- v38 Item Steal: who took it, and what.
		local what = if type(payload.item) == "string" then ItemRules.DISPLAY_NAME[payload.item] else nil
		say(name .. " TOOK YOUR " .. (what or "ITEM"), Color3.fromRGB(255, 150, 110), 1.8)
		if typeof(plane) == "Instance" then
			RivalBubbles.setNemesis(plane, name, ItemRules.REVENGE_WINDOW)
		end
	elseif role == "thief" then
		local what = if type(payload.item) == "string" then ItemRules.DISPLAY_NAME[payload.item] else nil
		TrickJuice.callout("STOLE " .. (what or "AN ITEM"), GOT_GOLD, 1.4)
	elseif role == "attacker" then
		if kind == "revenge" then
			-- v38-flow: the same compact banner as a plain hit ("EVEN  NAME", "EVEN x2  NAME"), not hero callout text.
			local short = string.gsub(string.upper(ItemRules.shortName(payload.name, 12)), "[%.!]+$", "")
			NotifyKit.toast(ItemRules.revengeLabel(chain) .. "  " .. short, { key = "item_hit", kind = "success", seconds = 1.6, icon = UiSkin.artFor("icon_battle") })
			ItemJuice.play("item_revenge")
			RivalBubbles.clearNemesis(plane)
		else
			-- uifix: a compact banner in the upper message lane, never hero text over the road. One line: "HIT  NAME",
			-- the name cut to 12 characters without the "." shortName adds.
			local short = string.gsub(string.upper(ItemRules.shortName(payload.name, 12)), "[%.!]+$", "")
			NotifyKit.toast("HIT  " .. short, { key = "item_hit", kind = "success", seconds = 1.4, icon = UiSkin.artFor("icon_battle") })
			ItemJuice.play("item_gotcha", 0.98 + math.random() * 0.06)
		end
	elseif role == "victim" then
		say("HIT BY " .. name, Color3.fromRGB(255, 150, 110), 1.8)
		if typeof(plane) == "Instance" then
			RivalBubbles.setNemesis(plane, name, ItemRules.REVENGE_WINDOW)
		end
	end
end

-- Item 19: a bot's taunt.
local function onTaunt(payload: any)
	if type(payload) ~= "table" then
		return
	end
	RivalBubbles.say(payload.plane, payload.text, payload.rival == true)
end

-- toast: RaceUI.showBanner (bottom-centre plank), so item callouts share the existing toast slot.
function ItemClient.init(toastFn: Toast?)
	toast = toastFn
	-- An early fire press during the roulette waits for the reveal (FlightController.requestItemUse).
	FlightController.itemRollLeft = HudExtras.rollLeft
	for name in BURSTS do
		getBurst(name) -- warm the pools so the first explosion never hitches
	end
	ItemJuice.init()
	ItemsV4Fx.init(ItemClient.burst)
	ItemJuice.setHintSource(function(): string?
		return MissileRules.counterHint(vehicleKind(), LocalPlayer:GetAttribute("ItemColor") :: string?, FlightController.itemDragging)
	end)
	RivalBubbles.init()
	-- Magnet v2: contact with the locked target pops (a press with nobody in range is spent server-side as a pulse).
	FlightController.onMagnetArrive = function(target: Model)
		MagnetAim.release()
		local h = hullOf(target)
		if h then
			ItemClient.burst("magnetZap", h.Position, nil)
		end
		kick(0.12)
		TrickJuice.callout("CAUGHT", rgb(ItemRules.COLOR_RGB.rainbow), 0.9)
	end
	ItemShow.init(ItemClient.burst, kick)
	ItemsV5Fx.init(ItemClient.burst)
	task.spawn(watchFxFolder)
	RunService.RenderStepped:Connect(Prof.wrap("SR_ItemClient", step))
	RunService.RenderStepped:Connect(Prof.wrap("SR_MagnetAim", MagnetAim.step))
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		-- The server creates ItemRemote after the map builds; keep waiting quietly rather than give up.
		local remote: Instance? = nil
		while remotes and not remote do
			remote = remotes:WaitForChild("ItemRemote", 10)
		end
		if not remote or not remote:IsA("RemoteEvent") then
			warn("[SkyRally][ITEM] client: ItemRemote missing; items render nothing")
			return
		end
		remote.OnClientEvent:Connect(function(event: any, a: any, b: any)
			if event == "ItemState" then
				onItemState(a)
			elseif event == "ItemUsed" then
				onItemUsed(a)
			elseif event == "ItemEffect" then
				onItemEffect(a, b)
			elseif event == "ItemFx" then
				onItemFx(a, b)
			elseif event == "IncomingItem" then
				onIncoming(a)
			elseif event == "ItemGrudge" then
				onGrudge(a)
			elseif event == "BotTaunt" then
				onTaunt(a)
			elseif event == "ItemPickup" then
				onPickupAnswer(a)
			end
		end)
		-- Late join or reload: show what the server says we hold right now.
		local color = LocalPlayer:GetAttribute("ItemColor")
		local level = LocalPlayer:GetAttribute("ItemLevel")
		local charges = LocalPlayer:GetAttribute("ItemCharges")
		onItemState({
			color = color,
			level = if type(level) == "number" then level else 0,
			charges = if type(charges) == "number" and charges > 0 then charges else nil,
		})
	end)
end

return ItemClient
