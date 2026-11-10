--!strict
-- The taker's instant feedback for shared pods (item cubes v3, docs/design/ITEM_BOXES.md). Every race pod is shared:
-- the server hides it for everyone (OnCooldown) and brings it back for everyone RespawnSeconds later. That flip reaches
-- this client a round trip after the claim, so the vehicle controllers mark the pod here the moment they take it and
-- ItemClient pops it now (cooling = OnCooldown or a live mark); the regrow waits for both to end, i.e. the server's.
-- The same module applies the rank rule the server applies (ItemRules.rankLocked: one cube per rank of a staggered
-- set per pass), so a cube the server will leave standing never pops on this screen. One table, no per-frame work.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRules"))

local PodLocal = {}

local takenUntil: { [Instance]: number } = {}
local lastRank: string? = nil
local lastRankAt: number? = nil

-- The local racer just took `pod` (os.clock() time `now`); it reads as taken for `seconds`.
function PodLocal.mark(pod: Instance, now: number, seconds: number)
	takenUntil[pod] = now + seconds
end

-- A claim from a vehicle controller: false (nothing marked) when the rank rule keeps this cube standing for the
-- racers behind; otherwise the pod is marked for its respawn and the rank remembered.
function PodLocal.take(pod: Instance, now: number): boolean
	local rank = pod:GetAttribute("CubeRank")
	if ItemRules.rankLocked(lastRank, lastRankAt, rank, now) then
		return false
	end
	if type(rank) == "string" and rank ~= "" then
		lastRank, lastRankAt = rank, now
	end
	PodLocal.mark(pod, now, ItemRules.podRetrigger(pod:GetAttribute("RespawnSeconds")))
	return true
end

-- Whether `pod` is hidden for this racer by its own claim. Expired marks are dropped as they are read.
function PodLocal.isTaken(pod: Instance, now: number): boolean
	local untilT = takenUntil[pod]
	if untilT == nil then
		return false
	end
	if now >= untilT then
		takenUntil[pod] = nil
		return false
	end
	return true
end

return PodLocal
