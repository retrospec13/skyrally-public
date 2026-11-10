--!strict
-- Hidden keys (LAUNCH_PROGRESSION sections 2b and 3; TEST_LIST_LAUNCH L70). One gold key per chain zone on its launch
-- track (TrackData.hiddenKey, from the plan's skyrally.gameplay.key), present in a standard race, quick race or time
-- trial on DINO-4, SNOW-1, ISLAND-2 and FOREST-1; never on SPACE-4 or the hub (Progression.TRACKS[id].hasKey).
-- * The key is a shared server-built model under the map root (folder HiddenKey) that spins through WorldAnim's
--   SpinRPM/SpinAxis attributes and glows; each client hides it once its own player holds that zone's key (player
--   attribute KeysHeld, JSON list of zones, published by TrackDirector with the board states).
-- * A player's vehicle path within RADIUS of the key (planes get the larger radius: they pass at speed; the path since
--   the previous 10 Hz check counts, so a fast pass between two checks is not missed) collects it: the
--   server saves it at once through SaveService.award(player, "key", zone, ...) (server event, idempotent; a held key
--   is a logged no-op) and tells that client through the TrackFlowRemote ("KeyFound" -> toast "KEY FOUND - <Zone>
--   battle unlocked"). SaveService replicates Keys, so TrackDirector republishes the board and the battle appears.
-- * Collecting a key never touches the race: no time, rank, lap or item changes, and it is kept even when the race is
--   abandoned (section 5: "nothing partial is saved ... except a key already picked up").
-- * The model lives as long as the map: a replay (FLY AGAIN) reuses it, so the client's spin and "held" hiding stay
--   put; a load without a key (another mode, another track) removes it.
-- The proximity check (check/eligible) runs on plain values so tools/tests/battle_spec.luau specs it under Lune.
-- The swept test itself (sweptDistance/reached) is shared: the Lost Squeaky Ducks (server/DuckHunt, REMARKABLE item 22)
-- collect through the same rule.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared:WaitForChild("Progression"))
-- Per group (systems audit v32 T0-2): one key check per RaceScope scope, stepped in its own scope (its records).
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))

local KeyPickup = {}

KeyPickup.RADIUS_PLANE = 16 -- OURS: a plane passes the alcove at 110-165 studs/s; 10 Hz checks need the margin
KeyPickup.RADIUS_CAR = 12
-- The check tests the path flown since the previous check (an overcharged plane covers 21 studs between two 10 Hz
-- checks, more than the radius's chord a few studs off the key). A longer jump is a respawn or reset teleport, not a
-- flown path, so only its end point counts.
KeyPickup.SWEEP_MAX = 60
-- Section 2b: keys are found in any standard race, quick race or time trial on the key track.
KeyPickup.MODES = table.freeze({ race = true, quickrace = true, timetrial = true }) :: { [string]: boolean }

export type Hooks = {
	-- FlightServer.records (player -> { hull, plane, ... }), read every check.
	records: () -> { [Player]: any },
	-- SaveService.award(player, "key", zone, source) by default; injectable for the spec.
	award: ((player: Player, zone: string, source: string) -> (string, { string }))?,
	-- Client notification after a saved pickup (TrackFlowRemote "KeyFound" by default).
	notify: ((player: Player, payload: { [string]: any }) -> ())?,
	log: ((line: string) -> ())?,
}

export type State = {
	trackId: string,
	zone: string,
	pos: Vector3,
	radius: number,
	done: { [Player]: boolean }, -- collected (or already held) this session: never asked again
	last: { [Player]: Vector3 }, -- hull position at the previous check (swept test)
	folder: Instance?,
	hooks: Hooks,
}

local slot = ModeScopeRules.slot("KeyPickup") :: ModeScopeRules.Slot<State>
local conn: RBXScriptConnection? = nil

local function log(st: State?, line: string)
	local hooks = if st then st.hooks else nil
	local sink = if hooks then hooks.log else nil
	if sink then
		sink(line)
	else
		print(line)
	end
end

-- Whether a key belongs in this load: a key track (not SPACE-4, not the hub), key data with a position, a key mode.
function KeyPickup.eligible(td: any, mode: string): boolean
	if type(td) ~= "table" or not KeyPickup.MODES[mode] then
		return false
	end
	local info = Progression.TRACKS[td.id]
	local key = td.hiddenKey
	return info ~= nil and info.hasKey and info.zone ~= nil and type(key) == "table" and typeof(key.pos) == "Vector3"
end

function KeyPickup.radiusFor(vehicle: string?): number
	return if vehicle == "car" then KeyPickup.RADIUS_CAR else KeyPickup.RADIUS_PLANE
end

local function defaultAward(player: Player, zone: string, source: string): (string, { string })
	local SaveService = require(script.Parent.SaveService) :: any
	local result, opened = SaveService.award(player, "key", zone, source)
	if result == "awarded" then
		-- Economy v3 phase 6: a new key also counts on the ladder of the avatar being driven. Never blocks the pickup.
		pcall(function()
			local Economy = require(script.Parent.Economy) :: any
			local svc = Economy.service()
			if svc then
				svc.avatarKeyFound(player)
			end
		end)
	end
	return result, opened
end

local function defaultNotify(player: Player, payload: { [string]: any })
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local remote = remotes and remotes:FindFirstChild("TrackFlowRemote")
	if remote and remote:IsA("RemoteEvent") then
		-- Phase 8: the count after this key (SaveService replicates Keys on the award), so the client can show "KEY FOUND 1/4"
		-- and open the first-key explainer only for a first key.
		-- A queued award (profile not loaded yet) has not replicated, so the attribute is stale and no count is sent.
		local keys = player:GetAttribute("Keys")
		if payload.queued ~= true and type(keys) == "number" then
			payload.keys = keys
		end
		remote:FireClient(player, "KeyFound", payload)
	end
end

-- Distance from point p to the segment a-b.
function KeyPickup.segmentDistance(a: Vector3, b: Vector3, p: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-6 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- Closest approach to `target` of a vehicle that moved fromPos -> hullPos since the previous check (fromPos nil, or a
-- jump longer than SWEEP_MAX = a teleport: only where it ended up counts).
function KeyPickup.sweptDistance(target: Vector3, hullPos: Vector3, fromPos: Vector3?): number
	if fromPos and (hullPos - fromPos).Magnitude <= KeyPickup.SWEEP_MAX then
		return KeyPickup.segmentDistance(fromPos, hullPos, target)
	end
	return (hullPos - target).Magnitude
end

-- Whether that path passed within `radius` of `target` (keys, ducks: any hidden pickup).
function KeyPickup.reached(target: Vector3, radius: number, hullPos: Vector3, fromPos: Vector3?): boolean
	return KeyPickup.sweptDistance(target, hullPos, fromPos) <= radius
end

-- One proximity check for one player's vehicle position (and, when given, the position at the previous check: the
-- path in between counts, see SWEEP_MAX). Returns the award result when this call collected (or re-confirmed) the
-- key, nil when the vehicle is out of reach or this player was already done this session.
function KeyPickup.check(st: State, player: Player, hullPos: Vector3, fromPos: Vector3?): string?
	if st.done[player] then
		return nil
	end
	if not KeyPickup.reached(st.pos, st.radius, hullPos, fromPos) then
		return nil
	end
	local award = st.hooks.award or defaultAward
	local source = "key_pickup:" .. st.trackId
	local ok, result, unlocked = pcall(award, player, st.zone, source)
	-- Any answer, an error included, ends this player's checks for this load: "rejected" (no writable session, or a
	-- portal that is shut under the Studio UnlockAll override) or a failing save stays retryable only through a fresh
	-- load; asking again every tick would flood the save log with the same line.
	st.done[player] = true
	if not ok then
		log(st, string.format("[SkyRally][KEY] award error player=%s zone=%s err=%s", player.Name, st.zone, tostring(result)))
		return nil
	end
	local outcome = tostring(result)
	log(st, string.format("[SkyRally][KEY] pickup player=%s zone=%s track=%s result=%s", player.Name, st.zone, st.trackId, outcome))
	if outcome == "awarded" or outcome == "queued" then
		local notify = st.hooks.notify or defaultNotify
		pcall(notify, player, {
			zone = st.zone,
			trackId = st.trackId,
			pos = st.pos,
			queued = outcome == "queued",
			unlocked = if type(unlocked) == "table" then unlocked else {},
		})
	end
	return outcome
end

local function part(name: string, size: Vector3, cf: CFrame, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cf
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 196, 48)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- An upright gold key about 12 studs tall (ring bow, shaft, two bits) that reads at race speed; the pivot is upright at
-- its centre so WorldAnim spins it about the world vertical.
local KEY_SCALE = 1.6

local function buildKey(parent: Instance, pos: Vector3, zone: string): Model
	local m = Instance.new("Model")
	m.Name = "HiddenKey_" .. zone
	m:SetAttribute("KeyZone", zone)
	m:SetAttribute("SpinRPM", 36)
	m:SetAttribute("SpinAxis", "PivotUpVector")
	local base = CFrame.new(pos)
	local k = KEY_SCALE
	local shaft = part("Shaft", Vector3.new(0.7, 4.6, 0.7) * k, base * CFrame.new(0, -0.9 * k, 0), m)
	local ringR = 1.45 * k
	for i = 0, 9 do
		local a = i / 10 * 2 * math.pi
		-- Bow: ten short bars on a vertical circle above the shaft (a ring without unions).
		part("Bow" .. i, Vector3.new(0.6, 0.98, 0.6) * k, base * CFrame.new(math.cos(a) * ringR, 2.9 * k + math.sin(a) * ringR, 0) * CFrame.Angles(0, 0, a), m)
	end
	part("Bit1", Vector3.new(1.3, 0.55, 0.6) * k, base * CFrame.new(0.95 * k, -2.5 * k, 0), m)
	part("Bit2", Vector3.new(0.9, 0.55, 0.6) * k, base * CFrame.new(0.75 * k, -1.6 * k, 0), m)
	local gem = part("Gem", Vector3.new(1.1, 1.1, 1.1) * k, base * CFrame.new(0, 2.9 * k, 0), m, Enum.PartType.Ball)
	gem.Color = Color3.fromRGB(255, 244, 196)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 210, 110)
	light.Range = 20
	light.Brightness = 2.2
	light.Parent = gem
	-- Key glow (flip_v2 through Shared.FlipFx): twinkling sparkle_star glints off the gem and a slow magic_swirl
	-- vortex behind the key (white: the sheet is violet/cyan, Color multiplies). TrackFlow.refreshKeys disables both
	-- for a player who already holds this key.
	local okFlip, FlipFx = pcall(require, Shared:WaitForChild("FlipFx"))
	local glint = Instance.new("ParticleEmitter")
	glint.Name = "KeyGlint"
	if okFlip then
		FlipFx.apply(glint, "sparkle_star_4x4")
	end
	glint.Color = ColorSequence.new(Color3.fromRGB(255, 232, 140))
	glint.LightEmission = 0.8
	glint.LightInfluence = 0
	glint.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.5, 1.6), NumberSequenceKeypoint.new(1, 0) })
	glint.Lifetime = NumberRange.new(0.8, 1.2)
	glint.Rate = 6
	glint.Speed = NumberRange.new(1, 3)
	glint.SpreadAngle = Vector2.new(180, 180)
	glint.Parent = gem
	local swirl = Instance.new("ParticleEmitter")
	swirl.Name = "KeySwirl"
	if okFlip then
		FlipFx.apply(swirl, "magic_swirl_8x8")
	end
	swirl.Color = ColorSequence.new(Color3.new(1, 1, 1))
	swirl.LightEmission = 0.6
	swirl.LightInfluence = 0
	swirl.Size = NumberSequence.new(6 * k)
	swirl.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 0.45), NumberSequenceKeypoint.new(0.75, 0.5), NumberSequenceKeypoint.new(1, 1) })
	swirl.Lifetime = NumberRange.new(2)
	swirl.Rate = 0.8
	swirl.Speed = NumberRange.new(0)
	swirl.Rotation = NumberRange.new(0, 360)
	swirl.RotSpeed = NumberRange.new(-15, 15)
	swirl.LockedToPart = true
	swirl.ZOffset = -1
	local centre = Instance.new("Attachment")
	centre.Name = "KeySwirlAt"
	centre.CFrame = shaft.CFrame:ToObjectSpace(base) -- the key's centre: the swirl emits from a point there
	centre.Parent = shaft
	swirl.Parent = centre
	m.PrimaryPart = shaft
	shaft.PivotOffset = shaft.CFrame:ToObjectSpace(base)
	m.Parent = parent
	return m
end

local function step(st: State)
	local folder = st.folder
	if folder and not folder.Parent then
		KeyPickup.stop() -- the map went away under us (track switch)
		return
	end
	for player, rec in st.hooks.records() do
		local hull = rec.hull
		if hull and hull.Parent and player.Parent then
			local pos = hull.Position
			local prev = st.last[player]
			st.last[player] = pos
			KeyPickup.check(st, player, pos, prev)
		end
	end
end

-- Stops the proximity check; the key model stays with the map (see the header).
function KeyPickup.stop()
	slot:set(nil)
end

-- Starts the 10 Hz proximity check for this load, building the key (or reusing the one a replay left on this map).
-- root: the active map root (TrackRegistry). A load with no key removes any key model from root. Returns the state
-- (nil when this load has no key).
function KeyPickup.start(root: Instance?, td: any, mode: string, vehicle: string?, hooks: Hooks): State?
	KeyPickup.stop()
	local existing = if root then root:FindFirstChild("HiddenKey") else nil
	if not KeyPickup.eligible(td, mode) then
		if existing then
			existing:Destroy()
		end
		return nil
	end
	local info = Progression.TRACKS[td.id]
	local zone: string = if info and info.zone then info.zone else tostring(td.zone)
	local pos: Vector3 = td.hiddenKey.pos
	local folder: Instance? = nil
	if existing and existing:GetAttribute("KeyZone") == zone then
		folder = existing
	elseif root then
		if existing then
			existing:Destroy()
		end
		local f = Instance.new("Folder")
		f.Name = "HiddenKey"
		f:SetAttribute("KeyZone", zone)
		buildKey(f, pos, zone)
		f.Parent = root
		folder = f
	end
	local st: State = {
		trackId = td.id,
		zone = zone,
		pos = pos,
		radius = KeyPickup.radiusFor(vehicle or td.vehicle),
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
	log(st, string.format("[SkyRally][KEY] placed zone=%s track=%s mode=%s at=(%.0f,%.0f,%.0f) radius=%d", zone, td.id, mode, pos.X, pos.Y, pos.Z, st.radius))
	return st
end

function KeyPickup.isActive(): boolean
	return slot:get() ~= nil
end

return KeyPickup
