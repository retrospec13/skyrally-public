--!strict
-- Template pre-warm for a track load (perf pass 2026-10-19, TEST_LIST L42). A first build used to fetch its network
-- assets one at a time, each on the critical path after the compiled builder had finished: the art swap's world meshes
-- and palm props (~1.8 s on the hub), the ring meshes and item art in the gameplay step (~0.9 s), the set dressing props,
-- and then the first vehicle's four meshes when the first player's car spawned (~1.1 s). TrackDirector.load calls
-- forTrack before the builder starts, so all of those loads run in parallel while the builder writes terrain; the steps
-- that need them later find them cached or wait only for what is still in flight (every loader is single-flight).
-- Server only. Never yields; a failed load is logged by its loader and the step that needs it falls back as before.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArtSwap = require(script.Parent.ArtSwap)
local CarBuilder = require(script.Parent.CarBuilder)
local PlaneBuilder = require(script.Parent.Parent.PlaneBuilder)
local WorldArt = require(script.Parent.WorldArt)

local Prewarm = {}

-- Ring and pad art every track with booster rings or ground pads uses (kit/Gameplay ringMesh, padMesh).
Prewarm.RING_MESHES = { "ring_frame", "ring_glow", "boost_pad" }

-- What forTrack loads for `td`: world mesh names and PropLibrary keys.
function Prewarm.plan(td: any): ({ string }, { string })
	local meshes, props = ArtSwap.templatesFor(if type(td) == "table" then td.zone else nil)
	for _, name in Prewarm.RING_MESHES do
		if not table.find(meshes, name) then
			table.insert(meshes, name)
		end
	end
	if type(td) == "table" and type(td.setDressing) == "table" then
		for _, e in td.setDressing do
			if type(e) == "table" and type(e.key) == "string" and not table.find(props, e.key) then
				table.insert(props, e.key)
			end
		end
	end
	return meshes, props
end

-- Starts every load the track's first build and first vehicle will need. Returns at once.
function Prewarm.forTrack(td: any)
	local t0 = os.clock()
	local meshes, props = Prewarm.plan(td)
	CarBuilder.prewarm()
	PlaneBuilder.prewarm()
	task.spawn(function()
		local ItemArt = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemArt")) :: any
		ItemArt.prepare()
	end)
	task.spawn(function()
		WorldArt.loadAll(meshes, props)
		print(string.format("[SkyRally][ASSETS] prewarm %s meshes=%d props=%d in %.2fs", tostring(if type(td) == "table" then td.id else "?"), #meshes, #props, os.clock() - t0))
	end)
end

return Prewarm
