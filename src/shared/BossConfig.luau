--!strict
-- Zone bosses (LAUNCH_PROGRESSION section 2b, CONTENT boss rows; original designs from the B1-B5 guides). A boss race
-- is 1v1 on the zone's launch track: the boss is a single AIRacers bot with its own model and pace, and BossRace
-- drops the zone hazard on the course (more often, and with the rematch twist, in the rematch).
-- `model` is the uploaded Tripo boss model (assets/models/bosses/<key>, ASSETS section 8); nil falls back to the zone
-- vehicle in the boss colours, scaled up.
-- Animation (client, BossAnimator): `clips` names the baked clip module ReplicatedStorage.Shared.bossclips.<clips>
-- (tools/bake_boss_clips.py from the Blender rig's anim.glb). Flyers play fly/glide (or hover), walkers walk/idle, karts
-- drive/idle, plus hit/roar/attack one-shots; Wheel* and Prop bones are spun procedurally from Speed (wheelRadius,
-- propRps). No module (or no skinned mesh) leaves the mesh at rest.
export type Boss = {
	id: string,
	zone: string,
	track: string,
	name: string,
	title: string,
	vehicle: string,
	color: Color3,
	accent: Color3,
	model: number?,
	modelScale: number, -- metres of model per stud of hull length, applied after the model's own bounding size fit
	length: number, -- boss length in studs after fitting (the plane hull is ~16)
	yawOffset: number, -- degrees to turn the uploaded mesh so it faces the hull's LookVector (rigged GLBs import turned round: 180)
	pitch: number?, -- flyers: degrees the creature leans nose-down into the course (default 14)
	pace: number, -- base speed (studs/s); the fastest field bot is 139
	rematchPace: number,
	hazard: string, -- first race
	rematchHazard: string,
	dropEvery: number, -- seconds between drops in the first race
	rematchDropEvery: number,
	clips: string?, -- baked clip module name under Shared.bossclips (nil = no authored animation)
	wheelRadius: number?, -- studs at boss.length scale, for the procedural Wheel* spin (default length * 0.09)
	propRps: number?, -- procedural Prop spin, revolutions per second (default 3)
}

local BossConfig = {}

BossConfig.BY_ZONE = {
	DINO = {
		id = "DINO-BOSS", zone = "DINO", track = "DINO-4", name = "Cinderwing", title = "the Magma Glider", vehicle = "plane",
		color = Color3.fromRGB(46, 36, 40), accent = Color3.fromRGB(255, 110, 30), model = 134652238361077, modelScale = 1, length = 44, yawOffset = 180, pitch = 3,
		pace = 141, rematchPace = 146, hazard = "lavabomb", rematchHazard = "rockfall", dropEvery = 4.2, rematchDropEvery = 2.4,
		clips = "Cinderwing",
	},
	SNOW = {
		id = "SNOW-BOSS", zone = "SNOW", track = "SNOW-1", name = "Frosthorn", title = "the Glacier Owl", vehicle = "plane",
		color = Color3.fromRGB(150, 210, 255), accent = Color3.fromRGB(240, 250, 255), model = 92804741385165, modelScale = 1, length = 40, yawOffset = 180, pitch = 3,
		pace = 142, rematchPace = 147, hazard = "iceshard", rematchHazard = "snowball", dropEvery = 3.2, rematchDropEvery = 2.1,
		clips = "Frosthorn",
	},
	ISLAND = {
		id = "ISLAND-BOSS", zone = "ISLAND", track = "ISLAND-2", name = "Clattershell", title = "the Galleon Crab", vehicle = "car",
		color = Color3.fromRGB(230, 90, 70), accent = Color3.fromRGB(250, 236, 200), model = 73367619545738, modelScale = 1, length = 26, yawOffset = 180, pitch = 0,
		pace = 134, rematchPace = 139, hazard = "mine", rematchHazard = "bubble", dropEvery = 3.0, rematchDropEvery = 2.0,
		clips = "Clattershell",
	},
	FOREST = {
		id = "FOREST-BOSS", zone = "FOREST", track = "FOREST-1", name = "Emberbeetle", title = "the Windmill Beetle", vehicle = "plane",
		color = Color3.fromRGB(150, 70, 40), accent = Color3.fromRGB(255, 170, 60), model = 125020544671315, modelScale = 1, length = 34, yawOffset = 180, pitch = 0,
		pace = 143, rematchPace = 148, hazard = "fireball", rematchHazard = "fireball", dropEvery = 3.0, rematchDropEvery = 2.0,
		clips = "Emberbeetle", propRps = 4,
	},
	HUB = {
		id = "HUB-BOSS-1", zone = "HUB", track = "HUB-0", name = "Thunderwright", title = "the Storm Engineer", vehicle = "car",
		color = Color3.fromRGB(44, 48, 60), accent = Color3.fromRGB(110, 220, 255), model = 139069710013660, modelScale = 1, length = 20, yawOffset = 180, pitch = 0,
		pace = 138, rematchPace = 138, hazard = "lightning", rematchHazard = "lightning", dropEvery = 2.6, rematchDropEvery = 2.6,
		clips = "Thunderwright", wheelRadius = 2.15,
	},
} :: { [string]: Boss }

-- The storm dragon (economy v3 phase 5, storm race v2): the boss racer in every storm field. It is NOT a zone boss (kept out
-- of BY_ZONE, so nothing that walks the zone bosses, retirements, boss pads or clip specs sees it); forZone("STORM") /
-- forZone("STORM_CAR") return it so the client's BossAnimator, Vfx and name plate treat it like any boss model.
-- ART: TRACKED STAND-IN (docs/ASSETS_TOOLBOX_TEMP.md "Storm dragon stand-in"): until the owner's storm dragon concept and
-- model exist, a plane field draws Cinderwing's uploaded rig (the winged glider) and a car field Thunderwright's (the storm
-- engineer), with their own baked clips. Never invent art here; swap `model` / `clips` when the real dragon lands.
-- TUNING (docs/design/STORM_RACE_V2.md): beatable by a good player. pace 141 (plane) sits above the fastest field bot (139,
-- "loses to mid skill") and at the bottom of the zone bosses (141-143, which also drop hazards; the storm dragon drops none:
-- BossRace is one per server and never runs in a group). Car 136 (x0.97 road factor like every car bot) sits between the
-- car bosses (134 / 138). No skill roll, start delay or slips (AIRacers skips them for a boss), and it starts just ahead of
-- the pole like every boss (the race opens as a chase).
BossConfig.STORM = {
	plane = {
		id = "STORM-DRAGON", zone = "STORM", track = "", name = "Storm Dragon", title = "rider of the storm", vehicle = "plane",
		color = Color3.fromRGB(40, 44, 82), accent = Color3.fromRGB(150, 150, 255), model = 134652238361077, modelScale = 1, length = 44, yawOffset = 180, pitch = 3,
		pace = 141, rematchPace = 141, hazard = "lightning", rematchHazard = "lightning", dropEvery = 99, rematchDropEvery = 99,
		clips = "Cinderwing",
	},
	car = {
		id = "STORM-DRAGON-CAR", zone = "STORM_CAR", track = "", name = "Storm Dragon", title = "rider of the storm", vehicle = "car",
		color = Color3.fromRGB(40, 44, 82), accent = Color3.fromRGB(150, 150, 255), model = 139069710013660, modelScale = 1, length = 20, yawOffset = 180, pitch = 0,
		pace = 136, rematchPace = 136, hazard = "lightning", rematchHazard = "lightning", dropEvery = 99, rematchDropEvery = 99,
		clips = "Thunderwright", wheelRadius = 2.15,
	},
} :: { plane: Boss, car: Boss }

-- The storm dragon for a field of this vehicle ("car" or anything else = plane).
function BossConfig.stormDragon(vehicle: string?): Boss
	return if vehicle == "car" then BossConfig.STORM.car else BossConfig.STORM.plane
end

function BossConfig.forZone(zone: string?): Boss?
	if zone == "STORM" then
		return BossConfig.STORM.plane
	elseif zone == "STORM_CAR" then
		return BossConfig.STORM.car
	end
	return if zone then BossConfig.BY_ZONE[zone] else nil
end

function BossConfig.forTrack(trackId: string?): Boss?
	for _, b in BossConfig.BY_ZONE do
		if b.track == trackId then
			return b
		end
	end
	return nil
end

return BossConfig
