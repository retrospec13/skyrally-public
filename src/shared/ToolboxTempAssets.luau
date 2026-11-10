--!strict
-- Creator Store stand-ins (owner allowance 2026-10-19: free toolbox assets as tracked, replace-later gap fillers;
-- docs/ASSETS_TOOLBOX_TEMP.md is the ledger, one row per id here). Each id is a model that tools/bake_toolbox.py loaded in the
-- lane Studio (game:GetObjects: a live server cannot InsertService:LoadAsset another creator's model), STRIPPED (every
-- script, value, Configuration, Fire and the store's own particle emitters and lights; attributes and tags cleared) and
-- RESTYLED to docs/ART_BAR.md, and serialized to build/model_bakes/<id>.rbxm. src/shared/ModelBakes clones that bake, so the
-- game never calls LoadAsset on these ids and nothing from the store runs code. Without the bake the stand-in just does not
-- load and the builder art stays.
--
-- Every stand-in has a rule in ArtSwapRules marked `stopgap = true`, placed AFTER the rule for the in-house mesh it holds the
-- place of: when that mesh is uploaded (its ASSETS entry exists) the real rule matches first and the stand-in rule, its id
-- here and its ledger row are deleted (tools/tests/artswap_spec.luau fails until they are).
--
--   MESHES: single-MeshPart models, keyed like WorldModelAssets (WorldArt.world; the MeshPart keeps its restyled look).
--           (their fit numbers, in ArtSwapRules.Asset form, are ArtSwapRules.STOPGAP_ASSETS: bake report size, bbox centre, colliders)
--   PROPS:  multi-part models, keyed like PropLibrary (WorldArt.prop / WorldArt.propInfo); `size` is the bake's bounding box,
--           `ownPivot` = the model's pivot is the base of its trunk / pole (the fit stands that point on the prefab origin).
local ToolboxTempAssets = {}

ToolboxTempAssets.MESHES = {
	-- empty: the toolbox hedge was replaced by the in-house hedge (art round 7); ledger: docs/ASSETS_TOOLBOX_TEMP.md
} :: { [string]: number }

export type Prop = {
	model: number,
	size: Vector3,
	ownPivot: boolean,
	collide: boolean,
}

ToolboxTempAssets.PROPS = {
	-- empty: the toolbox autumn tree and tiki torch were replaced by the in-house meshes (art round 7)
} :: { [string]: Prop }

return ToolboxTempAssets
