--!strict
-- Coin challenge (LAUNCH_PROGRESSION section 3, N64 rule kept): the track's eight silver coins (TrackData.coins, from
-- the plan's skyrally.gameplay.coins) must all be collected AND the race won for the coin token. Coins are shared
-- visuals; collection is per player (player attributes Coins and CoinsHeld, workspace CoinsTotal), and each client
-- hides the coins its own player has taken.
-- Pickup (G9, docs/audits/traps_summary.md; S4-02, F9): the check runs every Heartbeat and tests the PATH since the
-- previous check, not just the current point, as KeyPickup does. A boosted car covers 16-18 studs and an overcharged plane
-- 21 between two 10 Hz samples, more than the chord of the pickup sphere a few studs off-centre, so "I drove through it
-- and it didn't count" happened on the fast coins. A jump longer than SWEEP_MAX is a respawn or reset teleport, not a
-- driven path, so only its end point counts. An empty coin list never counts as "all coins" (D4-04: 0 >= 0 awarded the
-- coin token for a plain win on DINO-4).
-- Per group (systems audit v32 T0-2, shared/ModeScopeRules): one challenge per RaceScope scope. A group's start / stop
-- touches only its own coins, the one Heartbeat steps every scope's challenge inside that scope (its records), and
-- CoinsTotal goes on the race's own root (RaceAttr.set; workspace on the single path, unchanged).
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local CoinChallenge = {}

CoinChallenge.RADIUS_PLANE = 14 -- F9: coins 11-14 off the assist line are meant to be taken
CoinChallenge.RADIUS_CAR = 11 -- S4-02: matches the 11-stud trap hit radius
CoinChallenge.SWEEP_MAX = 60 -- same rule as KeyPickup.SWEEP_MAX

export type Coin = { id: string, pos: Vector3 }
type State = {
	folder: Instance,
	coins: { Coin },
	held: { [Player]: { [string]: boolean } },
	-- Hull and its position at the previous check (swept test); a new hull (respawned vehicle) starts a new path.
	last: { [Player]: { hull: BasePart, pos: Vector3 } },
	radius: number,
	records: () -> { [Player]: any },
}
local slot = ModeScopeRules.slot("CoinChallenge") :: ModeScopeRules.Slot<State>
local conn: RBXScriptConnection? = nil

local function publish(player: Player, held: { [string]: boolean }, total: number)
	local list = {}
	for id in held do
		table.insert(list, id)
	end
	player:SetAttribute("Coins", #list)
	player:SetAttribute("CoinsHeld", HttpService:JSONEncode(list))
	RaceAttr.set("CoinsTotal", total)
end

-- Distance from point p to the segment a-b.
function CoinChallenge.segmentDistance(a: Vector3, b: Vector3, p: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-6 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- One check for one vehicle: marks in `held` (and returns, in coin order) every coin within radius of the path from
-- fromPos to pos, or of pos alone when there is no previous position or the jump is longer than SWEEP_MAX.
function CoinChallenge.collectAlong(coins: { Coin }, held: { [string]: boolean }, radius: number, pos: Vector3, fromPos: Vector3?): { string }
	local swept = fromPos ~= nil and (pos - fromPos).Magnitude <= CoinChallenge.SWEEP_MAX
	local taken = {}
	for _, c in coins do
		if not held[c.id] then
			local d = if swept then CoinChallenge.segmentDistance(fromPos :: Vector3, pos, c.pos) else (pos - c.pos).Magnitude
			if d < radius then
				held[c.id] = true
				table.insert(taken, c.id)
			end
		end
	end
	return taken
end

-- Whether `held` covers every coin of a non-empty list (only ids on the list count).
function CoinChallenge.isComplete(coins: { Coin }, held: { [string]: boolean }?): boolean
	if #coins == 0 or not held then
		return false
	end
	for _, c in coins do
		if not held[c.id] then
			return false
		end
	end
	return true
end

function CoinChallenge.allCollected(player: Player): boolean
	local a = slot:get()
	if not a then
		return false
	end
	return CoinChallenge.isComplete(a.coins, a.held[player])
end

function CoinChallenge.isActive(): boolean
	return slot:get() ~= nil
end

function CoinChallenge.resetPlayers()
	local a = slot:get()
	if not a then
		return
	end
	for player in a.held do
		a.held[player] = {}
		publish(player, {}, #a.coins)
	end
	table.clear(a.last) -- a reset teleports every racer: no path from the old position
end

local function step(a: State)
	for player, rec in a.records() do
		local hull = rec.hull
		if hull and hull.Parent then
			local held: { [string]: boolean } = a.held[player] or {}
			if not a.held[player] then
				a.held[player] = held
				publish(player, held, #a.coins)
			end
			local pos = hull.Position
			local prev = a.last[player]
			a.last[player] = { hull = hull, pos = pos }
			local fromPos = if prev and prev.hull == hull then prev.pos else nil
			for _, id in CoinChallenge.collectAlong(a.coins, held, a.radius, pos, fromPos) do
				publish(player, held, #a.coins)
				print(string.format("[SkyRally][COIN] %s took %s (%d/%d)%s", player.Name, id, (player:GetAttribute("Coins") :: number?) or 0, #a.coins, if fromPos then " swept" else ""))
			end
		else
			a.last[player] = nil
		end
	end
end

function CoinChallenge.stop()
	local a = slot:get()
	if a then
		a.folder:Destroy()
		for player in a.held do
			player:SetAttribute("Coins", nil)
			player:SetAttribute("CoinsHeld", nil)
		end
	end
	RaceAttr.set("CoinsTotal", nil)
	slot:set(nil)
end

-- One check of every scope's challenge, each in its own scope (the single path: the one challenge, as before).
function CoinChallenge.stepAll()
	slot:each(step)
end

function CoinChallenge.start(root: Instance, coins: { any }, vehicle: string, records: () -> { [Player]: any })
	CoinChallenge.stop()
	local folder = Instance.new("Folder")
	folder.Name = "ChallengeCoins"
	folder.Parent = root
	CoinChallenge.arm(folder, CoinChallenge.build(folder, coins), vehicle, records)
end

-- The coin models under folder; returns the coin list (id, pos) in plan order.
function CoinChallenge.build(folder: Instance, coins: { any }): { Coin }
	local list = {}
	for i, c in coins do
		if typeof(c.pos) == "Vector3" then
			local id = "Coin_" .. tostring(c.id or i)
			local m = Instance.new("Model")
			m.Name = id
			m:SetAttribute("CoinId", id)
			m:SetAttribute("SpinRPM", 50)
			m:SetAttribute("SpinAxis", "PivotUpVector")
			local disc = Instance.new("Part")
			disc.Name = "Coin"
			disc.Shape = Enum.PartType.Cylinder
			disc.Size = Vector3.new(0.8, 5, 5)
			disc.Material = Enum.Material.Metal
			disc.Color = Color3.fromRGB(214, 222, 236)
			disc.Reflectance = 0.25
			disc.Anchored = true
			disc.CanCollide = false
			disc.CanQuery = false
			disc.CanTouch = false
			disc.CFrame = CFrame.new(c.pos)
			disc.Parent = m
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(220, 236, 255)
			glow.Range = 12
			glow.Brightness = 1.2
			glow.Parent = disc
			m.PrimaryPart = disc
			m.Parent = folder
			table.insert(list, { id = id, pos = c.pos })
		end
	end
	return list
end

-- Arms this scope's challenge over built coins (the spec arms fake folders in two scopes at once).
function CoinChallenge.arm(folder: Instance, list: { Coin }, vehicle: string, records: () -> { [Player]: any })
	if slot:get() then
		CoinChallenge.stop()
	end
	slot:set({
		folder = folder,
		coins = list,
		held = {},
		last = {},
		radius = if vehicle == "car" then CoinChallenge.RADIUS_CAR else CoinChallenge.RADIUS_PLANE,
		records = records,
	})
	RaceAttr.set("CoinsTotal", #list)
	if not conn then
		-- Every Heartbeat (S4-02): eight coins per racer is trivially cheap, and short segments keep the sweep honest.
		conn = RunService.Heartbeat:Connect(function()
			CoinChallenge.stepAll()
		end)
	end
	print(string.format("[SkyRally][COIN] challenge coins=%d", #list))
end

return CoinChallenge
