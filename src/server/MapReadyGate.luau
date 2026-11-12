--!strict
-- v37 client-ready handshake (shared/MapReadyRules): the server half. TrackDirector (single race) and RaceGroups (per
-- group) call await() between the map build and the grid reset, so the countdown never starts on a client that is
-- still taking the map in. Clients answer through TrackFlowRemote "MapReady" (TrackDirector routes it to ack).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapReadyRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapReadyRules"))

local MapReadyGate = {}

local lastToken = 0
-- token -> userId -> answered, for the loads still waiting
local waiting: { [number]: { [number]: boolean } } = {}

function MapReadyGate.ack(player: Player, token: any)
	if not MapReadyRules.validAck(token, waiting) then
		return
	end
	waiting[token][player.UserId] = true
end

-- Publishes this load's token on the map root and yields until every one of `players` still in the server has
-- answered, or MapReadyRules.TIMEOUT. Returns the verdict ("all" / "timeout") and the seconds waited.
function MapReadyGate.await(root: Instance?, players: { Player }, label: string): (string, number)
	local t0 = os.clock()
	if not root then
		return "all", 0
	end
	lastToken += 1
	local token = lastToken
	local acked: { [number]: boolean } = {}
	waiting[token] = acked
	root:SetAttribute(MapReadyRules.COUNT_ATTR, #root:GetDescendants())
	root:SetAttribute(MapReadyRules.TOKEN_ATTR, token)
	local verdict: MapReadyRules.Verdict, missing = "wait", 0
	while true do
		local need: { number } = {}
		for _, p in players do
			if p.Parent then
				table.insert(need, p.UserId)
			end
		end
		verdict, missing = MapReadyRules.verdict(need, acked, os.clock() - t0)
		if verdict ~= "wait" then
			break
		end
		task.wait(0.1)
	end
	waiting[token] = nil
	local waited = os.clock() - t0
	print(string.format("[SkyRally][READY] %s token=%d players=%d verdict=%s missing=%d waited=%.1fs", label, token, #players, verdict, missing, waited))
	return verdict, waited
end

return MapReadyGate
