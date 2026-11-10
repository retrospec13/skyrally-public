--!strict
-- The ISLAND-2 water battle as v27 shipped it (build/island2/TrackData.luau at 082e54e): the 150-stud disc on the cove
-- flats, six pads with the deck pad last, eight pods with three on the galleon decks. Owner 2026-10-21 widened the live
-- arena to the whole cove, gave it eight sand pads and moved every pod onto dry sand (tools/map/author_island2.py), so
-- the live data no longer has a deck pad or a deck pod. WaterRules and modes/Water still handle both (a car can drive
-- onto the galleon, a future arena may seat one there), and the rule specs (water_spec, water_flow_spec) keep
-- exercising them on this frozen geometry. The galleon, gangways, plank, tide and terrain are unchanged, so the live
-- TrackData supplies everything else.
return function(live: any): any
	local b = table.clone(live)
	b.center = Vector3.new(-5320, 21, 4230)
	b.radius = 150
	b.softBoundary = { center = Vector3.new(-5320, 21, 4230), radius = 150, softWidth = 25 }
	b.spawns = {
		Vector3.new(-5215, 27.958, 4195),
		Vector3.new(-5291.6, 28.6, 4156.8),
		Vector3.new(-5350, 24, 4320),
		Vector3.new(-5228, 27.25, 4280),
		Vector3.new(-5264.4, 28.6, 4207.2),
		Vector3.new(-5381.6, 36.5, 4146.8),
	}
	b.spawnLooks = {
		Vector3.new(-0.949, 0, 0.316),
		Vector3.new(-0.362, 0, 0.932),
		Vector3.new(0.316, 0, -0.949),
		Vector3.new(-0.879, 0, -0.478),
		Vector3.new(-0.868, 0, -0.496),
		Vector3.new(0.8, 0, 0.6),
	}
	b.pickupAnchors = {
		Vector3.new(-5354.4, 35, 4107.2),
		Vector3.new(-5398.2, 43, 4165.6),
		Vector3.new(-5343, 40, 4092),
		Vector3.new(-5330.4, 27.6, 4185.2),
		Vector3.new(-5290, 23, 4250),
		Vector3.new(-5390, 23, 4280),
		Vector3.new(-5340, 27.431, 4195),
		Vector3.new(-5232, 25, 4195),
	}
	b.venue = nil
	return b
end
