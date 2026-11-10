--!strict
-- The hub PAINT SHOP stand (economy v3 section 4: avatar = vehicle model, reskin = texture swap, TINT = colour / glow finish).
-- Pure data, no services: server/PaintShopStand builds the kiosk from it, client/PaintShop routes its prompts to the Garage, and
-- tools/tests/paint_shop_spec.luau holds the placement clearances. Players only ever read PAINT SHOP, TINTS and VEHICLES; the
-- word "livery" is an internal cosmetic kind (GarageModel.ALL_TABS id "liveries") and never shows on a label or prompt.
-- Owner rules this obeys: no change to wall / mountain driving, adhesion, barriers, kill volumes or rescue; nothing is built in
-- the hub's cliffs or walls (secret areas are planned there); every part is CanCollide = false and CanQuery = false so the kiosk
-- can never become a wall or a traversal trap.
local PaintShopConfig = {}

export type PromptSpec = { part: string, action: string, object: string, tab: string, key: string }

PaintShopConfig.NAME = "PaintShopStand"
PaintShopConfig.TITLE = "PAINT SHOP"

-- HUB-0 plaza, west side (world = plan + ORIGIN). Counter front centre at the paving (ground found by a ray; groundTolerance
-- keeps a roof or a bunting from becoming the floor). The terrain grid in map/hub0/plan.json is flat at y 26 around it.
PaintShopConfig.STAND = {
	pos = Vector3.new(-8262, 26, 8052),
	faceToward = Vector3.new(-8180, 26, 8066), -- the spawn
	groundTolerance = 6,
	promptDistance = 12,
	lampHeight = 11,
	radius = 9, -- studs: the kiosk footprint is a circle of this radius around pos (counter 11 wide, rack, easel, lamp post)
}

-- The Garage tab each prompt opens. "liveries" is the TINTS tab (GarageModel.ALL_TABS); "vehicles" the VEHICLES tab. The tint tab
-- mounts GarageTurntable, which shows the player's own current vehicle (DisplayCars.localVehicle), so no tab argument carries a
-- vehicle: the preview is whatever they are driving.
PaintShopConfig.PROMPTS = {
	paint = { part = "Counter", action = "PAINT SHOP", object = "Tints and glow", tab = "liveries", key = "E" },
	vehicles = { part = "VehicleRack", action = "VEHICLES", object = "Pick a ride", tab = "vehicles", key = "Q" },
} :: { [string]: PromptSpec }

-- Attribute the client router reads on a ProximityPrompt (server writes the Garage tab id).
PaintShopConfig.TAB_ATTR = "GarageTab"

-- Where a triggered prompt goes: nil for a prompt that is not ours (the Storm vendor's, a mystery cube's, ...).
function PaintShopConfig.tabFor(promptName: string, attr: any): string?
	for _, p in PaintShopConfig.PROMPTS do
		if promptName == "PaintShop_" .. p.action and attr == p.tab then
			return p.tab
		end
	end
	return nil
end

function PaintShopConfig.promptName(action: string): string
	return "PaintShop_" .. action
end

-- Placement clearances (studs, planar), checked against the other hub fixtures by tools/tests/paint_shop_spec.luau. The
-- sight-line rule is the Storm stand's: from every hub approach view the kiosk is at least 25 degrees off every portal arch.
PaintShopConfig.CLEARANCE = {
	archSightDegrees = 25,
	stormStand = 100,
	board = 100,
	fountain = 60,
	plazaDressing = 22, -- any plan instance (lamps, planters, stalls, balustrade), centre to kiosk centre
	loopRoad = 150, -- the nearest hub loop route node
	spawn = 40,
}

-- Every wording a player can read from the kiosk (the spec scans it for banned words).
PaintShopConfig.TEXTS = { "PAINT SHOP", "TINTS", "VEHICLES", "Tints and glow", "Pick a ride", "Fresh finishes, today" } :: { string }

return PaintShopConfig
