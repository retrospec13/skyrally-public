--!strict
-- Studio-only QA helpers (QA V5A: missiles, traps and shields were not testable, nothing could hand the local player an
-- item or put a bot in front of a plane). Pure command rules: shared/QAToolRules; documented in docs/STUDIO_ROUND_V22.md
-- section 1 and driven by tools/give_item.py. Everything here is behind RunService:IsStudio(): in a live server start()
-- returns before creating anything, so there is no remote and no attribute listener to find or abuse.
--   RemoteFunction SkyRallyRemotes.QAToolsRemote   InvokeServer("give", "red:3") | InvokeServer("ahead", "60[:lateral]")
--   workspace attributes QAGiveItem = "red:3" / QABotAhead = "60"   (set from a Server-context lane.luau command; they apply
--       to the first player and clear themselves, so a command can be repeated)
-- give  : the player holds that item and level now (ItemService.qaGive; the HUD slot, the item attributes and the server
--         state agree, so a Use fires the real missile / trap / shield path).
-- ahead : a bot is moved that many studs ahead on the line, merged and moving (AIRacers.qaPlaceAhead).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QAToolRules"))
local RaceScope = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceScope"))

local QATools = {}

type Deps = { ItemService: any, AIRacers: any, FlightServer: any }

local LOG = "[SkyRally][QA] "

local function hullPosition(deps: Deps, player: Player): Vector3?
	local rec = deps.FlightServer.records[player]
	if rec and rec.hull and rec.hull.Parent then
		return (rec.hull :: BasePart).Position
	end
	local char = player.Character
	local root = if char then char:FindFirstChild("HumanoidRootPart") else nil
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- One command. Returns a short result string (also what the RemoteFunction answers).
function QATools.run(deps: Deps, player: Player, cmd: any, arg: any): string
	if cmd == "give" then
		local color, level, why = Rules.parseGive(arg)
		if not color then
			return "error:" .. why
		end
		local ok, res = deps.ItemService.qaGive(player, color, level)
		return if ok then string.format("ok:%s:%d", color, level) else "error:" .. res
	elseif cmd == "ahead" then
		local studs, lateral, why = Rules.parseAhead(arg)
		if not studs then
			return "error:" .. why
		end
		local pos = hullPosition(deps, player)
		if not pos then
			return "error:no_vehicle"
		end
		-- AIRacers.bots is per race scope (RaceFlowRules.PER_GROUP): move a bot of the player's own instance.
		local ok, res = RaceScope.run(RaceScope.instanceOf(player), function(): (boolean, string)
			return deps.AIRacers.qaPlaceAhead(pos, studs, lateral, nil)
		end)
		return if ok then string.format("ok:%s:%d", res, studs) else "error:" .. res
	end
	return "error:unknown_command"
end

function QATools.start(deps: Deps)
	if not Rules.allowed(RunService:IsStudio()) then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local fn = Instance.new("RemoteFunction")
	fn.Name = Rules.REMOTE_NAME
	fn.Parent = folder
	fn.OnServerInvoke = function(player: Player, cmd: any, arg: any): string
		local res = QATools.run(deps, player, cmd, arg)
		print(string.format("%s%s %s -> %s", LOG, tostring(cmd), tostring(arg), res))
		return res
	end
	local function watch(attr: string, cmd: string)
		workspace:GetAttributeChangedSignal(attr):Connect(function()
			local v = workspace:GetAttribute(attr)
			if v == nil then
				return
			end
			workspace:SetAttribute(attr, nil)
			local player = Players:GetPlayers()[1]
			if not player then
				warn(LOG .. attr .. ": no player")
				return
			end
			local res = QATools.run(deps, player, cmd, v)
			workspace:SetAttribute("QAResult", res)
			print(string.format("%s%s %s -> %s", LOG, cmd, tostring(v), res))
		end)
	end
	watch(Rules.GIVE_ATTR, "give")
	watch(Rules.AHEAD_ATTR, "ahead")
	print(LOG .. "Studio helpers on (give item, bot ahead)")
end

return QATools
