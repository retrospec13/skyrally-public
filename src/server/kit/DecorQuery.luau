--!strict
-- Decor query rule (X-05 and D4-11, docs/audits/traps_summary.md): visible non-collidable decor is never a raycast or
-- spatial-query target. MapAdapter runs it over the whole map root as the last world step of a build.
-- Why: the car's wheel probes and its respawn drop ray use RespectCanCollide=false (so the deck's non-colliding pavers
-- count as road), and the plane's step ray stops at the first CanQuery part it meets. So a non-colliding post, rope,
-- lamp or mesh within reach acted as ground (ISLAND-2 gangway rope posts 3.3 above the ramp edge: a wheel could stand
-- on a post with no wall behind it) or hid the wall behind it (the DINO-4 StoneSauropod mesh beside the start S).
-- kit/Gameplay already applies the same rule to its own visuals (CanQuery = CanCollide); this extends it to the
-- compiled 30MAPS art and the adapter's meshes.
-- Kept queryable:
--   * anything collidable (physics truth, and CanQuery cannot be cleared on a collidable part);
--   * invisible parts (Transparency >= 1): triggers and lethal volumes are handled where they are built;
--   * lethal volumes (HazardType attribute, LavaSeaFloor), which the car and plane find by raycast;
--   * the route deck (TrackRibbon: the pavers ARE the road surface, CanCollide=false over the collidable TrackSeg);
--   * any part under an instance with the attribute Road = true: the data escape hatch for a non-colliding surface
--     that is meant to be driven on (set it through the plan's modelAttributes on that model).

local DecorQuery = {}

DecorQuery.KEEP_FOLDERS = table.freeze({ TrackRibbon = true, Hazards = true }) :: { [string]: boolean }
DecorQuery.ROAD_ATTR = "Road"

local function keptByAncestor(p: Instance, root: Instance): boolean
	local cur: Instance? = p
	while cur and cur ~= root do
		if cur:GetAttribute(DecorQuery.ROAD_ATTR) == true then
			return true
		end
		local parent: Instance? = cur.Parent
		if parent == root and DecorQuery.KEEP_FOLDERS[cur.Name] then
			return true
		end
		cur = parent
	end
	return false
end

-- Whether the rule clears CanQuery on this part (root: the map root the part lives under).
function DecorQuery.isDecor(p: Instance, root: Instance): boolean
	if not p:IsA("BasePart") then
		return false
	end
	local part = p :: BasePart
	if part.CanCollide or not part.CanQuery or part.Transparency >= 1 then
		return false
	end
	if part:GetAttribute("HazardType") ~= nil or part.Name == "LavaSeaFloor" then
		return false
	end
	return not keptByAncestor(part, root)
end

-- Applies the rule to every part under root; returns how many parts it changed.
function DecorQuery.apply(root: Instance): number
	local n = 0
	for _, d in root:GetDescendants() do
		if DecorQuery.isDecor(d, root) then
			(d :: BasePart).CanQuery = false
			n += 1
		end
	end
	return n
end

return DecorQuery
