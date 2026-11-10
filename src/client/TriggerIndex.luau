--!strict
-- Client index of the track triggers (rings, pads, item pods) the vehicle controllers test every frame (L40). Replaces the
-- per-controller GetDescendants rescan (a 10-15k instance table every 2 s, every frame while none was loaded): the server
-- tags triggers (TriggerRules.TAG) and this keeps the set live with GetInstanceAdded/RemovedSignal, so a streamed-in
-- trigger shows up and a streamed-out one drops without any scan. Legacy DINO-4 maps predate the tag: those get one scan
-- of their root, once.
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local TriggerRules = require(Shared:WaitForChild("TriggerRules"))

local TriggerIndex = {}

local all: { [BasePart]: boolean } = {}
local list: { BasePart } = {}
local dirty = true
local started = false
local legacyScanned: Instance? = nil
local lastRoot: Instance? = nil

local function add(inst: Instance)
	if inst:IsA("BasePart") then
		all[inst] = true
		dirty = true
	end
end

local function start()
	started = true
	CollectionService:GetInstanceAddedSignal(TriggerRules.TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TriggerRules.TAG):Connect(function(inst: Instance)
		if inst:IsA("BasePart") and all[inst] then
			all[inst] = nil
			dirty = true
		end
	end)
	for _, inst in CollectionService:GetTagged(TriggerRules.TAG) do
		add(inst)
	end
	RaceAttr.changed("ActiveTrackId", function()
		dirty = true
	end)
end

-- Untagged hand-built maps: scan their root once.
local function scanLegacy(root: Instance)
	legacyScanned = root
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") and TriggerRules.isTrigger(inst:GetAttribute("TriggerType"), inst:GetAttribute("ItemPodSpawn")) then
			add(inst)
		end
	end
end

-- The triggers under the active map root. The returned table is reused: do not keep or mutate it.
function TriggerIndex.get(): { BasePart }
	if not started then
		start()
	end
	local root = TrackRegistry.getRoot()
	if root ~= lastRoot then
		-- A root that appears or swaps without an ActiveTrackId change must still rebuild the list (else it stays empty).
		lastRoot = root
		dirty = true
		if root and root ~= legacyScanned and string.sub(TrackRegistry.describeRoot(), 1, 7) == "legacy:" then
			scanLegacy(root)
		end
	end
	if dirty then
		dirty = false
		table.clear(list)
		if root then
			for part in all do
				if not part.Parent then
					all[part] = nil -- destroyed untagged leftovers
				elseif part:IsDescendantOf(root) then
					table.insert(list, part)
				end
			end
		end
	end
	return list
end

return TriggerIndex
