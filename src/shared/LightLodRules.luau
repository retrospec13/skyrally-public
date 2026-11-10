--!strict
-- Map light cap (docs/audits/perf_review_v21.md PF-01). Pure rules for client/LightLod: under Future lighting every
-- enabled light is shaded per pixel it reaches, and DINO-4 alone places 142 (92 route lights, 36 point, 14 spot). The
-- client keeps only the K map lights nearest the camera on: K = 24 on desktop, 12 on phone tier, 8 with LOW GRAPHICS
-- or a low Roblox graphics quality. Re-evaluated at 4 Hz with hysteresis (a lit light ranks as if a bit nearer), and a
-- light switches through half brightness for one tick on its way on or off, so nothing pops at the boundary.
--
-- Only decor lights are ever capped: lights the map adapter tags (MapLight on route lights, MapFx on the fx table's
-- PointLight/SpotLight/SurfaceLight) and lights inside a compiled prefab model (Prefab attribute). A light with a
-- gameplay ancestor (trigger tag or TriggerType, ItemPodSpawn, HazardType) is never capped, whatever its tags.
local LightLodRules = {}

LightLodRules.TICK = 0.25 -- seconds between passes (4 Hz)
LightLodRules.K_DESKTOP = 24
LightLodRules.K_PHONE = 12
LightLodRules.K_LOW = 8
-- Hysteresis: a light that is on ranks at HYST_SCALE x its distance minus HYST_MARGIN studs, so a light just past the
-- K-th never trades places with it every tick while the camera sits at the boundary.
LightLodRules.HYST_SCALE = 0.85
LightLodRules.HYST_MARGIN = 12
-- Roblox graphics quality levels 1..LOW_QUALITY_MAX (a manual slider setting) count as low; 0 = Automatic does not.
LightLodRules.LOW_QUALITY_MAX = 3

LightLodRules.TAG_ATTRS = table.freeze({ "MapLight", "MapFx" }) :: { string }
LightLodRules.PREFAB_ATTR = "Prefab"
LightLodRules.GAMEPLAY_ATTRS = table.freeze({ "TriggerType", "ItemPodSpawn", "HazardType" }) :: { string }

-- Light levels: 0 off, 1 half brightness (one tick), 2 full.
LightLodRules.OFF = 0
LightLodRules.HALF = 1
LightLodRules.FULL = 2

-- The manual graphics slider (SavedQualityLevel as a number, 0 = Automatic) is low at 1..LOW_QUALITY_MAX.
function LightLodRules.lowQuality(level: number?): boolean
	return type(level) == "number" and level >= 1 and level <= LightLodRules.LOW_QUALITY_MAX
end

function LightLodRules.budget(phone: boolean, low: boolean): number
	if low then
		return LightLodRules.K_LOW
	elseif phone then
		return LightLodRules.K_PHONE
	end
	return LightLodRules.K_DESKTOP
end

-- Ranking distance: how far the camera is outside the light's sphere (0 inside), with the hysteresis for lit lights.
function LightLodRules.rankDistance(dist: number, range: number, lit: boolean): number
	local d = math.max(0, dist - range)
	if lit then
		d = d * LightLodRules.HYST_SCALE - LightLodRules.HYST_MARGIN
	end
	return d
end

-- Whether a light should be managed, from what its owner chain says (collected once per light at map load).
-- tagged: the light carries MapLight/MapFx; inPrefab: an ancestor model has Prefab; gameplay: a gameplay ancestor.
function LightLodRules.managed(startedOn: boolean, tagged: boolean, inPrefab: boolean, gameplay: boolean): boolean
	return startedOn and (tagged or inPrefab) and not gameplay
end

-- Picks the k lowest rank values. order holds the indices 1..n (kept by the caller between passes: from the last pass
-- it is nearly sorted, so this insertion sort is close to linear); it is re-sorted in place and want[i] is set to
-- whether light i is among the k nearest. No allocation.
function LightLodRules.select(rank: { number }, order: { number }, n: number, k: number, want: { boolean })
	if k >= n then
		for i = 1, n do
			want[i] = true
		end
		return
	end
	for i = 2, n do
		local idx = order[i]
		local r = rank[idx]
		local j = i - 1
		while j >= 1 and rank[order[j]] > r do
			order[j + 1] = order[j]
			j -= 1
		end
		order[j + 1] = idx
	end
	for i = 1, n do
		want[order[i]] = i <= k
	end
end

-- One step toward the wanted state: OFF -> HALF -> FULL and back, one level per pass.
function LightLodRules.step(level: number, want: boolean): number
	if want then
		return if level >= LightLodRules.HALF then LightLodRules.FULL else LightLodRules.HALF
	end
	return if level <= LightLodRules.HALF then LightLodRules.OFF else LightLodRules.HALF
end

-- What a level means on the light: (Enabled, Brightness).
function LightLodRules.apply(level: number, base: number): (boolean, number)
	if level == LightLodRules.FULL then
		return true, base
	elseif level == LightLodRules.HALF then
		return true, base * 0.5
	end
	return false, base
end

return LightLodRules
