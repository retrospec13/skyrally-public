--!strict
-- Game pass ids for the two Pass rows in MonetizationConfig.PRODUCTS (docs/STORE_PRODUCTS_TO_CREATE.md).
-- No engine API lists a universe's passes, so unlike developer products (bound by name at server start) these ids are
-- written here from an Open Cloud response by tools/store_create.py --apply (x2Gears; D16, owner directive 2026-10-21)
-- or pasted from Creator Hub, then the place is republished. Never invent one: an id left nil keeps that pass hidden
-- and unbuyable, exactly as before.

local StorePassIds = {}

StorePassIds.PASS_IDS = {
	x2Gears = nil :: number?, -- pass named "2x Cash"
	garagePlus = nil :: number?, -- pass named "Garage+"
} :: { [string]: number? }

return StorePassIds
