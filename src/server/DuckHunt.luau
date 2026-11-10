--!strict
-- Lost Squeaky Ducks (docs/REMARKABLE.md item 22), server half. One big rubber duck per launch map, hidden on that
-- map's alternate line (shared/SetPieceRules.DUCK_SPOTS), each in a little outfit for its zone (lava bandana, bobble
-- hat, pirate hat, leaf crown, space helmet, sailor cap). Present in a race, quick race, time trial, coin challenge or
-- hub free roam (never a battle or a boss race). Nothing tells the player; the HUD never counts them until one is found.
-- * The duck is a shared server-built model under the map root (folder LostDuck) that bobs and turns through
--   WorldAnim's SpinRPM attributes; each client hides it once its own player holds that map's duck (player attribute
--   DucksHeld, published by SaveService).
-- * Collecting reuses the hidden key's swept proximity rule (KeyPickup.reached): the path driven or flown since the
--   previous 10 Hz check counts. The server saves at once through SaveService.award(player, "duck", trackId, ...)
--   (idempotent: a held duck is a logged no-op) and tells that client (SkyRallyRemotes.SetPieceEvent "DuckFound").
--   Every client hears the squeak from the duck ("DuckSqueak"), so a friend nearby knows something happened there.
-- * All six own the Golden Quack horn (SaveService.derive); a progression reward, secret-only, never sold.
-- * Finding a duck never touches the race: no time, rank, lap or item changes.
-- check() runs on plain values with injectable hooks, so tools/tests/setpieces_spec.luau specs it under Lune.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("SetPieceRules"))
-- Per group (systems audit v32 T0-2): one duck check per RaceScope scope, stepped in its own scope (its records).
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))
local KeyPickup = require(script.Parent:WaitForChild("KeyPickup"))

local DuckHunt = {}

DuckHunt.FOLDER = "LostDuck"

export type Hooks = {
	records: () -> { [Player]: any },
	award: ((player: Player, trackId: string, source: string) -> (string, { string }))?,
	notify: ((player: Player, kind: string, payload: { [string]: any }) -> ())?,
	broadcast: ((kind: string, payload: { [string]: any }) -> ())?,
	log: ((line: string) -> ())?,
}

export type State = {
	trackId: string,
	pos: Vector3,
	radius: number,
	done: { [Player]: boolean },
	last: { [Player]: Vector3 },
	folder: Instance?,
	hooks: Hooks,
}

local slot = ModeScopeRules.slot("DuckHunt") :: ModeScopeRules.Slot<State>
local conn: RBXScriptConnection? = nil

local function log(st: State?, line: string)
	local sink = if st then st.hooks.log else nil
	if sink then
		sink(line)
	else
		print(line)
	end
end

function DuckHunt.radiusFor(vehicle: string?): number
	return if vehicle == "car" then Rules.DUCK_RADIUS_CAR else Rules.DUCK_RADIUS_PLANE
end

local function defaultAward(player: Player, trackId: string, source: string): (string, { string })
	local SaveService = require(script.Parent.SaveService) :: any
	return SaveService.award(player, "duck", trackId, source)
end

-- One proximity check for one player's vehicle (fromPos: where it was at the previous check). Returns the award result
-- when this call collected (or re-confirmed) the duck, nil when out of reach or already done this load.
function DuckHunt.check(st: State, player: Player, hullPos: Vector3, fromPos: Vector3?): string?
	if st.done[player] then
		return nil
	end
	if not KeyPickup.reached(st.pos, st.radius, hullPos, fromPos) then
		return nil
	end
	-- Any answer ends this player's checks for this load (as for keys): a failing save is retried by a fresh load.
	st.done[player] = true
	local award = st.hooks.award or defaultAward
	local ok, result = pcall(award, player, st.trackId, "duck_pickup:" .. st.trackId)
	if not ok then
		log(st, string.format("[SkyRally][DUCK] award error player=%s track=%s err=%s", player.Name, st.trackId, tostring(result)))
		return nil
	end
	local outcome = tostring(result)
	log(st, string.format("[SkyRally][DUCK] pickup player=%s track=%s result=%s", player.Name, st.trackId, outcome))
	if outcome == "awarded" or outcome == "queued" then
		local count = player:GetAttribute("Ducks")
		local n = if type(count) == "number" then count else 0
		local payload = { trackId = st.trackId, pos = st.pos, count = n, golden = n >= #Rules.DUCK_TRACKS }
		if st.hooks.notify then
			pcall(st.hooks.notify :: any, player, "DuckFound", payload)
		end
		if st.hooks.broadcast then
			pcall(st.hooks.broadcast :: any, "DuckSqueak", { trackId = st.trackId, pos = st.pos, userId = player.UserId })
		end
	end
	return outcome
end

---------------------------------------------------------------------------------------------------- the duck model

local YELLOW = Color3.fromRGB(255, 214, 40)
local ORANGE = Color3.fromRGB(255, 132, 30)
local INK = Color3.fromRGB(28, 24, 26)

-- A part with an ellipsoid (SpecialMesh sphere fills the part's box).
local function blob(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = parent
	return p
end

local function block(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- Each map's duck dresses for its zone (OURS): a little hat or accessory on the head (head centre `h`, facing -Z).
local OUTFITS: { [string]: (m: Model, h: CFrame) -> () } = {
	["DINO-4"] = function(m: Model, h: CFrame)
		block("Bandana", Vector3.new(3.1, 0.55, 3.1), h * CFrame.new(0, 0.55, 0), Color3.fromRGB(230, 70, 30), m)
		block("BandanaKnot", Vector3.new(0.7, 0.7, 1.2), h * CFrame.new(0, 0.5, 1.6) * CFrame.Angles(0.5, 0, 0), Color3.fromRGB(230, 70, 30), m)
	end,
	["SNOW-1"] = function(m: Model, h: CFrame)
		blob("Bobble", Vector3.new(2.6, 1.4, 2.6), h * CFrame.new(0, 1.05, 0), Color3.fromRGB(80, 160, 255), m, Enum.Material.Fabric)
		blob("Pompom", Vector3.new(0.9, 0.9, 0.9), h * CFrame.new(0, 1.9, 0), Color3.fromRGB(250, 250, 255), m, Enum.Material.Fabric)
	end,
	["ISLAND-2"] = function(m: Model, h: CFrame)
		block("Tricorn", Vector3.new(3.4, 0.5, 2.4), h * CFrame.new(0, 1.15, 0), INK, m)
		block("TricornTop", Vector3.new(2.0, 0.9, 1.6), h * CFrame.new(0, 1.6, 0), INK, m)
		block("Skull", Vector3.new(0.5, 0.5, 0.1), h * CFrame.new(0, 1.6, -0.85), Color3.fromRGB(250, 244, 220), m)
	end,
	["FOREST-1"] = function(m: Model, h: CFrame)
		for i = 0, 4 do
			local a = i / 5 * 2 * math.pi
			block("Leaf" .. i, Vector3.new(0.7, 1.1, 0.25), h * CFrame.Angles(0, a, 0) * CFrame.new(0, 1.2, -1.05) * CFrame.Angles(-0.35, 0, 0), Color3.fromRGB(96, 190, 70), m, Enum.Material.Grass)
		end
	end,
	["SPACE-4"] = function(m: Model, h: CFrame)
		local glass = blob("Helmet", Vector3.new(3.6, 3.6, 3.6), h, Color3.fromRGB(200, 240, 255), m, Enum.Material.Glass)
		glass.Transparency = 0.6
		block("Antenna", Vector3.new(0.18, 1.4, 0.18), h * CFrame.new(0.6, 2.3, 0), Color3.fromRGB(200, 200, 210), m, Enum.Material.Metal)
		blob("AntennaTip", Vector3.new(0.5, 0.5, 0.5), h * CFrame.new(0.6, 3.05, 0), Color3.fromRGB(255, 80, 200), m, Enum.Material.Neon)
	end,
	["HUB-0"] = function(m: Model, h: CFrame)
		block("Cap", Vector3.new(2.8, 0.7, 2.8), h * CFrame.new(0, 1.1, 0), Color3.fromRGB(250, 250, 250), m)
		block("CapBand", Vector3.new(2.85, 0.25, 2.85), h * CFrame.new(0, 0.85, 0), Color3.fromRGB(40, 70, 160), m)
	end,
}

-- A rubber duck about 5 studs long (big enough to read at race speed), its pivot upright at its middle so WorldAnim
-- turns it about the vertical.
function DuckHunt.buildDuck(parent: Instance, pos: Vector3, trackId: string): Model
	local m = Instance.new("Model")
	m.Name = "LostDuck_" .. trackId
	m:SetAttribute("DuckTrack", trackId)
	m:SetAttribute("SpinRPM", 14)
	m:SetAttribute("SpinAxis", "PivotUpVector")
	local base = CFrame.new(pos)
	local body = blob("Body", Vector3.new(3.8, 3.0, 5.0), base, YELLOW, m)
	blob("Tail", Vector3.new(1.6, 1.8, 1.4), base * CFrame.new(0, 0.9, 2.3) * CFrame.Angles(-0.6, 0, 0), YELLOW, m)
	for side = -1, 1, 2 do
		blob("Wing", Vector3.new(0.6, 1.6, 2.6), base * CFrame.new(side * 1.85, 0.2, 0.3) * CFrame.Angles(0, 0, side * 0.25), Color3.fromRGB(250, 200, 30), m)
	end
	local headCF = base * CFrame.new(0, 2.2, -1.6)
	blob("Head", Vector3.new(2.8, 2.6, 2.6), headCF, YELLOW, m)
	blob("Beak", Vector3.new(1.6, 0.6, 1.4), headCF * CFrame.new(0, -0.3, -1.4), ORANGE, m)
	for side = -1, 1, 2 do
		blob("Eye", Vector3.new(0.45, 0.6, 0.3), headCF * CFrame.new(side * 0.6, 0.35, -1.15), INK, m)
		blob("EyeShine", Vector3.new(0.16, 0.18, 0.1), headCF * CFrame.new(side * 0.6 + 0.08, 0.5, -1.28), Color3.new(1, 1, 1), m, Enum.Material.Neon)
	end
	local outfit = OUTFITS[trackId]
	if outfit then
		outfit(m, headCF)
	end
	-- A soft gold twinkle so a sharp eye spots it in a tunnel (the client hides it once found).
	local glint = Instance.new("ParticleEmitter")
	glint.Name = "DuckGlint"
	glint.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	glint.Color = ColorSequence.new(Color3.fromRGB(255, 236, 140))
	glint.LightEmission = 0.8
	glint.LightInfluence = 0
	glint.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.5, 0.9), NumberSequenceKeypoint.new(1, 0) })
	glint.Lifetime = NumberRange.new(0.8, 1.2)
	glint.Rate = 3
	glint.Speed = NumberRange.new(1, 2)
	glint.SpreadAngle = Vector2.new(180, 180)
	glint.Parent = body
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 120)
	light.Range = 12
	light.Brightness = 0.8
	light.Shadows = false
	light.Parent = body
	m.PrimaryPart = body
	m.Parent = parent
	return m
end

-- Where the duck sits: a plane duck floats on the alternate's flight line; a car duck sits on the surface found under
-- the line (a 30-stud ray down from 8 over it), else on the line itself.
local function settle(anchor: Vector3, vehicle: string?): Vector3
	if vehicle ~= "car" then
		return anchor + Vector3.yAxis * Rules.DUCK_LIFT_PLANE
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip = {}
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		table.insert(skip, planes)
	end
	params.FilterDescendantsInstances = skip
	local ok, hit = pcall(function(): RaycastResult?
		return workspace:Raycast(anchor + Vector3.yAxis * 8, Vector3.yAxis * -30, params)
	end)
	if ok and hit then
		return hit.Position + Vector3.yAxis * (Rules.DUCK_LIFT_CAR + 1.5)
	end
	return anchor + Vector3.yAxis * Rules.DUCK_LIFT_CAR
end

local function step(st: State)
	local folder = st.folder
	if folder and not folder.Parent then
		DuckHunt.stop()
		return
	end
	for player, rec in st.hooks.records() do
		local hull = rec.hull
		if hull and hull.Parent and player.Parent then
			local pos = hull.Position
			local prev = st.last[player]
			st.last[player] = pos
			DuckHunt.check(st, player, pos, prev)
		end
	end
end

function DuckHunt.stop()
	slot:set(nil)
end

-- Places this load's duck (or reuses the one a replay left on this map) and starts the 10 Hz check. A load without a
-- duck removes any duck model from root. Returns the state (nil when this load has none).
function DuckHunt.start(root: Instance?, td: any, mode: string, vehicle: string?, hooks: Hooks): State?
	DuckHunt.stop()
	local existing = if root then root:FindFirstChild(DuckHunt.FOLDER) else nil
	local trackId = if type(td) == "table" then td.id else nil
	local anchor = if Rules.duckEligible(trackId, mode) then Rules.duckAnchor(trackId, td.alternates) else nil
	if not anchor then
		if existing then
			existing:Destroy()
		end
		return nil
	end
	local folder: Instance? = nil
	local pos: Vector3
	if existing and existing:GetAttribute("DuckTrack") == trackId and typeof(existing:GetAttribute("DuckPos")) == "Vector3" then
		folder = existing
		pos = existing:GetAttribute("DuckPos") :: Vector3
	else
		if existing then
			existing:Destroy()
		end
		pos = settle(anchor, vehicle)
		if root then
			local f = Instance.new("Folder")
			f.Name = DuckHunt.FOLDER
			f:SetAttribute("DuckTrack", trackId)
			f:SetAttribute("DuckPos", pos)
			DuckHunt.buildDuck(f, pos, trackId)
			f.Parent = root
			folder = f
		end
	end
	local st: State = {
		trackId = trackId,
		pos = pos,
		radius = DuckHunt.radiusFor(vehicle),
		done = {},
		last = {},
		folder = folder,
		hooks = hooks,
	}
	slot:set(st)
	if not conn and RunService:IsServer() then
		local acc = 0
		conn = RunService.Heartbeat:Connect(function(dt: number)
			acc += dt
			if acc >= 0.1 then
				acc = 0
				slot:each(step)
			end
		end)
	end
	log(st, string.format("[SkyRally][DUCK] placed track=%s mode=%s at=(%.0f,%.0f,%.0f) radius=%d", trackId, mode, pos.X, pos.Y, pos.Z, st.radius))
	return st
end

function DuckHunt.isActive(): boolean
	return slot:get() ~= nil
end

return DuckHunt
