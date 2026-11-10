--!strict
-- Equipped cosmetics in the world (MONETIZATION_PROPOSAL 2a; Garage):
-- * liveries: FlightServer / CarServer paint a player's vehicle as they build it (kit/LiveryPaint.applyFor); this
--   module repaints the live vehicle when the loadout changes (player attribute Equipped), so an equip in the hub shows
--   at once for everyone.
-- * horns: the client fires SkyRallyRemotes.CosmeticEvent "Horn"; the server checks the Garage is on, a horn is
--   equipped (the server's own Equipped attribute, never a client claim) and the cooldown, then tells every client
--   ("Horn", userId, key) to play it at that player's vehicle. Spam is dropped quietly.
-- Trails and finish emotes need no server step: clients read Equipped and RaceFinished (client/Vfx, client/Cosmetics).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GarageModel = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GarageModel"))
local LiveryPaint = require(script.Parent.kit.LiveryPaint)

local CosmeticService = {}

local lastHorn: { [Player]: number } = {}
local started = false

local function vehicleOf(player: Player): Model?
	local folder = workspace:FindFirstChild("Planes")
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId then
			return m
		end
	end
	return nil
end

function CosmeticService.repaint(player: Player)
	local model = vehicleOf(player)
	if model then
		LiveryPaint.applyFor(player, model)
	end
end

local function onHorn(player: Player, event: RemoteEvent)
	if workspace:GetAttribute("GarageEnabled") ~= true then
		return
	end
	local t = os.clock()
	-- 0.2 s slack for network jitter against the client's own cooldown.
	if t - (lastHorn[player] or -math.huge) < GarageModel.HORN_COOLDOWN - 0.2 then
		return
	end
	local item = GarageModel.equipped(GarageModel.decodeLoadout(player:GetAttribute("Equipped")), "horn")
	if not item or not vehicleOf(player) then
		return
	end
	lastHorn[player] = t
	event:FireAllClients("Horn", player.UserId, item.key)
end

local function watch(player: Player)
	player:GetAttributeChangedSignal("Equipped"):Connect(function()
		CosmeticService.repaint(player)
	end)
	CosmeticService.repaint(player)
end

function CosmeticService.init()
	if started then
		return
	end
	started = true
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	local event = (folder :: Instance):FindFirstChild("CosmeticEvent") :: RemoteEvent?
	if not event then
		local e = Instance.new("RemoteEvent")
		e.Name = "CosmeticEvent"
		e.Parent = folder
		event = e
	end
	local remote = event :: RemoteEvent
	remote.OnServerEvent:Connect(function(player: Player, action: any)
		if action == "Horn" then
			onHorn(player, remote)
		end
	end)
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastHorn[player] = nil
	end)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return CosmeticService
