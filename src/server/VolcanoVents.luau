--!strict
-- DINO-4 geyser updraft vents (docs/design/TRACK_VARIETY.md 5a), server half. The plan's gameplay.geysers rows (two vents
-- on the Alt1 tunnel floor, TrackData.geysers) become a small visual-only model each; the cycle itself is a pure function
-- of server time (shared/VolcanoRules), so nothing here ticks. What the server owns is the verdict on a crossing:
-- client/VolcanoMoments reports "GeyserTriggered" when the local plane is inside an ACTIVE column, and onTriggered
-- re-checks the stage (with slack), the hull position and the per-player cooldown before the caller applies the ring
-- boost. A refused report changes nothing. A vent is never a hazard: every part is non-collidable, nothing queries it,
-- there is no damage and no stun, and a mistimed crossing costs nothing.
-- Built only where a race can use Alt1 (not the hub, not battles: the egg-battle floor stays as it is).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("VolcanoRules"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local RaceScope = require(Shared:WaitForChild("RaceScope"))

local VolcanoVents = {}

VolcanoVents.FOLDER = "VolcanoVents"

-- Per group (systems audit v32 T0-2): the vents and the crossing cooldowns are per RaceScope scope (a crossing report
-- runs in the sender's scope, RaceManager's remote), so one group's load never clears another group's vents. The
-- single path: one table each, as before.
type Book = { vents: { [string]: Rules.Vent }, lastTaken: { [Player]: { [string]: number } } }
local function scopedBook(): Book
	return RaceScope.state("VolcanoVents", function(): Book
		return { vents = {}, lastTaken = {} }
	end)
end

local function log(fmt: string, ...: any)
	print("[SkyRally][GEYSER] " .. string.format(fmt, ...))
end

local function visualOnly(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
end

-- Crater (dark basalt lip) and a neon floor the client brightens through the cycle. Both flat on the floor.
local function buildVent(parent: Instance, v: Rules.Vent)
	local model = Instance.new("Model")
	model.Name = v.id
	model:SetAttribute("GeyserVent", true)
	model:SetAttribute("Phase", v.phase)
	model:SetAttribute("Radius", v.radius)
	model:SetAttribute("Height", v.height)
	model:SetAttribute("BasePos", v.pos)
	local lay = CFrame.new(v.pos) * CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder's axis is X: stand it on end

	local lip = Instance.new("Part")
	lip.Name = "Crater"
	lip.Shape = Enum.PartType.Cylinder
	lip.Size = Vector3.new(0.8, v.radius * 1.5, v.radius * 1.5)
	lip.CFrame = lay * CFrame.new(0.4 - 0.0, 0, 0)
	lip.Material = Enum.Material.Basalt
	lip.Color = Color3.fromRGB(58, 48, 46)
	visualOnly(lip)
	lip.Parent = model

	local glow = Instance.new("Part")
	glow.Name = "Glow"
	glow.Shape = Enum.PartType.Cylinder
	glow.Size = Vector3.new(0.3, v.radius * 1.1, v.radius * 1.1)
	glow.CFrame = lay * CFrame.new(0.95, 0, 0)
	glow.Material = Enum.Material.Neon
	glow.Color = Color3.fromRGB(255, 120, 40)
	glow.Transparency = 0.75
	visualOnly(glow)
	glow.Parent = model

	model.PrimaryPart = glow
	model.Parent = parent
end

function VolcanoVents.stop()
	local b = scopedBook()
	table.clear(b.vents)
	table.clear(b.lastTaken)
end

-- After every load and replay (init.server startMode). Builds this track's vents; any other track builds none.
function VolcanoVents.start(td: any, mode: string)
	VolcanoVents.stop()
	local root = TrackRegistry.getRoot()
	if not root then
		return
	end
	local old = root:FindFirstChild(VolcanoVents.FOLDER)
	if old then
		old:Destroy()
	end
	local rows = if type(td) == "table" then td.geysers else nil
	if type(rows) ~= "table" or #rows == 0 or mode == "hub" or mode == "battle" then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = VolcanoVents.FOLDER
	-- The lap the volcano wakes on (client/VolcanoMoments reads it with the player's Lap attribute).
	local eruption = td.eruption
	if type(eruption) == "table" and type(eruption.lap) == "number" then
		folder:SetAttribute("EruptionLap", eruption.lap)
	end
	for _, row in rows do
		local v = Rules.parseVent(row)
		if not v then
			log("vent ignored: malformed row (%s)", tostring(type(row) == "table" and row.id))
			continue
		end
		scopedBook().vents[v.id] = v
		buildVent(folder, v)
	end
	folder.Parent = root
	log("vents built=%d track=%s mode=%s cycle=%.1fs", #rows, tostring(td.id), mode, Rules.CYCLE)
end

-- A reported crossing from `player` whose hull is at `pos`. Returns true when the boost may be applied; remembers the
-- crossing for the cooldown. `now` defaults to the server clock.
function VolcanoVents.onTriggered(player: Player, pos: Vector3, payload: any, now: number?, speed: number?): boolean
	local id = if type(payload) == "table" then payload.id else nil
	local scoped = scopedBook()
	local lastTaken = scoped.lastTaken
	local v = if type(id) == "string" then scoped.vents[id] else nil
	if not v then
		return false
	end
	local t = now or workspace:GetServerTimeNow()
	local book = lastTaken[player]
	if not book then
		book = {}
		lastTaken[player] = book
	end
	local claim = if type(payload) == "table" and typeof(payload.pos) == "Vector3" then payload.pos else nil
	if claim and not (claim.X == claim.X and claim.Y == claim.Y and claim.Z == claim.Z) then
		claim = nil -- NaN
	end
	local ping = player:GetNetworkPing() * 2 -- round trip
	local ok, why = Rules.validate(v, pos, t, book[v.id], claim, Rules.lagAllowance(speed or 0, ping))
	log("%s player=%s vent=%s stage=%s", if ok then "boost" else "refused " .. why, player.Name, v.id, (Rules.stage(t, v.phase)))
	if ok then
		book[v.id] = t
	end
	return ok
end

function VolcanoVents.forget(player: Player)
	RaceScope.each("VolcanoVents", function(_id: number, b: any)
		b.lastTaken[player] = nil
	end)
end

return VolcanoVents
