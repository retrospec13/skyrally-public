--!strict
-- Boss race hazards (LAUNCH_PROGRESSION 2b): while a boss race or rematch runs, the boss leaves its zone hazard on the
-- course behind itself every BossConfig.dropEvery seconds (rematch: faster, two at a time). A player vehicle that
-- passes within RADIUS of a live hazard is hit through the item system (spin-out stun + explosion VFX), so shields
-- block hazards exactly like missiles. Motion per hazard kind: fall (lava bombs, rock fall), float (fireballs, ice
-- shards, bubbles), roll (snowballs roll back down the course toward the chasers), sit (mines), strike (lightning:
-- a warning ring, then the bolt). Hazard particles are flip_v2 flipbooks through Shared.FlipFx (fire_loop on lava bombs
-- and fireballs, snow_burst powder off a rolling snowball, sparkle glints on ice shards, smoke dust behind falling rock,
-- electric_arc crackle on the lightning warning and lightning_bolt_2x2 bolts while it strikes); the hit itself plays
-- on every client (ItemClient "explode" source boss_<kind> -> Vfx.onHazardHit).
-- Hazards move in whole RacerViewRules.SERVER_STEP steps on their own sim clock (docs/audits/opponent_jitter.md): the
-- clients draw them through the same sim-time snapshot track as the bots, which times every replicated pose as a
-- whole number of steps after the last one. Hits are still checked every Heartbeat.
-- Respawn grace (trap audit G2, I2-16, F4, D4-03): a player inside ItemEffects.RESPAWN_IMMUNE_SECONDS of a respawn
-- (FlightServer's LastRespawnClock stamp) is never hit (the hazard stays for whoever comes next), and no hazard is
-- dropped within RESPAWN_CLEAR studs of a fresh respawn frame, so a respawn never lands in front of a live bomb.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local RacerViewRules = require(Shared:WaitForChild("RacerViewRules")) -- the fixed step the clients' hazard view counts on
local FlipFx = require(Shared:WaitForChild("FlipFx"))
-- Per group (systems audit v32 T0-2): one boss race per RaceScope scope; each steps in its own scope (its boss bot,
-- spline, GO time and records), its hazards sit in the shared workspace.BossHazards folder (RacerView tracks that one
-- folder) and a stop takes only its own.
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local ItemEffects = require(script.Parent:WaitForChild("kit"):WaitForChild("ItemEffects")) :: any

local BossRace = {}

local RADIUS = 6 -- with 0.3 x hazard size: a near miss is a miss (a 6-hit first boss race read as unfair)
local LIFETIME = 9
local STUN = 1.3
local RELEASE = 0.3 -- seconds from the attack one-shot's start to its release frame (authored at ~f9 of 30 fps)
local RESPAWN_CLEAR = 40 -- OURS (G2): no new hazard this close to a respawn frame while its protection runs

-- fx: the hazard's particle look (FX below); tex: texture name for FlipFx (a flip_v2 sheet or an old VfxAssets key).
type Kind = { color: Color3, glow: Color3, tex: string, fx: string, size: number, motion: string }
local KINDS: { [string]: Kind } = {
	lavabomb = { color = Color3.fromRGB(255, 96, 20), glow = Color3.fromRGB(255, 160, 60), tex = "fire_loop_8x8", fx = "fire", size = 5, motion = "fall" },
	rockfall = { color = Color3.fromRGB(110, 70, 60), glow = Color3.fromRGB(255, 120, 40), tex = "smoke_puff_8x8", fx = "dust", size = 6, motion = "fall" },
	iceshard = { color = Color3.fromRGB(150, 230, 255), glow = Color3.fromRGB(210, 245, 255), tex = "sparkle_star_4x4", fx = "glint", size = 4.5, motion = "float" },
	snowball = { color = Color3.fromRGB(240, 248, 255), glow = Color3.fromRGB(200, 230, 255), tex = "snow_burst_4x4", fx = "powder", size = 7, motion = "roll" },
	mine = { color = Color3.fromRGB(60, 60, 70), glow = Color3.fromRGB(255, 70, 70), tex = "spark_streak", fx = "sparks", size = 4, motion = "sit" },
	bubble = { color = Color3.fromRGB(160, 230, 255), glow = Color3.fromRGB(200, 250, 255), tex = "bubble", fx = "sparks", size = 6, motion = "float" },
	fireball = { color = Color3.fromRGB(255, 120, 30), glow = Color3.fromRGB(255, 200, 90), tex = "fire_loop_8x8", fx = "fire", size = 5, motion = "float" },
	lightning = { color = Color3.fromRGB(120, 220, 255), glow = Color3.fromRGB(200, 245, 255), tex = "electric_arc_4x4", fx = "arc", size = 4, motion = "strike" },
}

type Hazard = { part: Part, kind: string, born: number, sim: number, live: boolean, station: number, baseY: number, groundY: number }
type Active = {
	boss: BossConfig.Boss,
	rematch: boolean,
	nextDrop: number,
	hazards: { Hazard },
	sim: number, -- hazard motion clock (whole SERVER_STEP steps)
	clock: RacerViewRules.ServerClock,
	folder: Folder,
	ownsFolder: boolean, -- single path: this race's own BossHazards folder; per group: the shared one
	hit: (Player, string, Vector3) -> (),
	records: () -> { [Player]: any },
	bossHull: () -> BasePart?,
	bossStation: () -> number?,
	immune: ((Player) -> boolean)?,
}

local slot = ModeScopeRules.slot("BossRace") :: ModeScopeRules.Slot<Active>
local conn: RBXScriptConnection? = nil

local function seq(a: number, b: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

-- The hazard's own emitter. Kept small (the hazard ball is 4-7 studs) and low-rate; server-built because the hazard
-- part is, so every client sees the same thing without a remote.
local function hazardEmitter(k: Kind, p: Part)
	local s = k.size
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "HazardFx"
	FlipFx.apply(pe, k.tex)
	pe.LightEmission = 1
	pe.Color = ColorSequence.new(k.glow, k.color)
	pe.Size = seq(s * 0.35, 0)
	pe.Transparency = seq(0.1, 1)
	pe.Lifetime = NumberRange.new(0.4, 0.8)
	pe.Rate = 24
	pe.Speed = NumberRange.new(2, 6)
	pe.SpreadAngle = Vector2.new(180, 180)
	if k.fx == "fire" then
		-- Looping fire tongues licking up off the ball (upright whatever the camera does; the sheet is coloured).
		-- Sized past the ball's radius and drawn s/2 toward the camera, so the opaque Neon ball does not hide them.
		pe.Color = ColorSequence.new(Color3.new(1, 1, 1))
		pe.LightEmission = 0.45
		pe.LightInfluence = 0
		pe.ZOffset = s * 0.5
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, s * 0.8), NumberSequenceKeypoint.new(0.6, s * 0.7), NumberSequenceKeypoint.new(1, s * 0.35) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.75, 0.2), NumberSequenceKeypoint.new(1, 1) })
		pe.Lifetime = NumberRange.new(0.5, 0.8)
		pe.Rate = 14
		pe.Speed = NumberRange.new(2, 4)
		pe.SpreadAngle = Vector2.new(25, 25)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.Acceleration = Vector3.new(0, 6, 0)
		pe.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	elseif k.fx == "dust" then
		pe.Color = ColorSequence.new(Color3.fromRGB(170, 140, 120), Color3.fromRGB(200, 186, 170))
		pe.LightEmission = 0
		pe.Size = seq(s * 0.35, s * 0.6)
		pe.Transparency = seq(0.2, 1)
		pe.Lifetime = NumberRange.new(0.8, 1.2)
		pe.Rate = 10
		pe.Speed = NumberRange.new(1, 3)
		pe.Rotation = NumberRange.new(0, 360)
	elseif k.fx == "glint" then
		pe.Color = ColorSequence.new(k.glow)
		pe.LightEmission = 0.8
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, s * 0.4), NumberSequenceKeypoint.new(0.6, s * 0.35), NumberSequenceKeypoint.new(1, 0) })
		pe.Transparency = seq(0, 0.4)
		pe.Lifetime = NumberRange.new(0.6, 1)
		pe.Rate = 6
		pe.Speed = NumberRange.new(0.5, 2)
		-- From the ball's surface and drawn toward the camera: glints spawned inside the opaque ball were hidden.
		pe.Shape = Enum.ParticleEmitterShape.Sphere
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		pe.ZOffset = s * 0.3
	elseif k.fx == "powder" then
		-- A rolling snowball kicks up powder: snow_burst puffs left behind on the course.
		pe.Color = ColorSequence.new(Color3.new(1, 1, 1))
		pe.LightEmission = 0.2
		pe.Size = seq(s * 0.55, s * 0.7)
		pe.Transparency = seq(0.15, 0.5)
		pe.Lifetime = NumberRange.new(0.7, 1)
		pe.Rate = 8
		pe.Speed = NumberRange.new(0, 2)
		pe.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	elseif k.fx == "arc" then
		-- Warning phase: electric arcs crackle round the strike point (Loop, 24 fps).
		pe.Color = ColorSequence.new(Color3.new(1, 1, 1))
		pe.LightEmission = 0.6
		pe.Size = seq(s, s * 1.15)
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.2), NumberSequenceKeypoint.new(1, 1) })
		pe.Lifetime = NumberRange.new(0.4, 0.6)
		pe.Rate = 6
		pe.Speed = NumberRange.new(0)
		pe.Rotation = NumberRange.new(0, 360)
		-- Strike phase: lightning_bolt_2x2 (FlipbookMode Random: one of four bolts per particle) along the column,
		-- enabled by step() when the bolt goes live.
		local bolt = Instance.new("ParticleEmitter")
		bolt.Name = "HazardBolt"
		FlipFx.apply(bolt, "lightning_bolt_2x2")
		bolt.Color = ColorSequence.new(Color3.new(1, 1, 1))
		bolt.LightEmission = 0.7
		bolt.LightInfluence = 0
		bolt.Size = seq(16, 16)
		bolt.Transparency = seq(0, 0.3)
		bolt.Lifetime = NumberRange.new(0.15, 0.25)
		bolt.Rate = 10
		bolt.Speed = NumberRange.new(0)
		bolt.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
		bolt.Enabled = false
		bolt.Parent = p
	end
	if k.fx ~= "fire" then
		pe.LightInfluence = if pe.LightEmission > 0.5 then 0 else 1
	end
	pe.Parent = p
end

local function makePart(k: Kind, cf: CFrame, folder: Folder, kindName: string): Part
	local p = Instance.new("Part")
	p.Name = "BossHazard_" .. kindName
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * k.size
	p.Material = if k.motion == "sit" then Enum.Material.Metal else Enum.Material.Neon
	p.Color = k.color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = cf
	local light = Instance.new("PointLight")
	light.Color = k.glow
	light.Range = 14
	light.Brightness = 2
	light.Parent = p
	hazardEmitter(k, p)
	p.Parent = folder
	return p
end

-- True while a respawn stamped at `stamp` (the player's LastRespawnClock, os.clock on the server as here) is still
-- protected. Pure; Lune-tested.
function BossRace.freshRespawn(stamp: any, now: number): boolean
	return type(stamp) == "number" and now - stamp >= 0 and now - stamp < ItemEffects.RESPAWN_IMMUNE_SECONDS
end

-- False when a hazard dropped at `pos` would land within RESPAWN_CLEAR of a protected respawn frame. Pure.
function BossRace.dropClear(pos: Vector3, frames: { Vector3 }): boolean
	for _, f in frames do
		if (pos - f).Magnitude < RESPAWN_CLEAR then
			return false
		end
	end
	return true
end

-- The item engine's own window when the boot script passes it (it holds a respawn the client asked for to the rearm
-- time, ItemEffects.RESPAWN_IMMUNE_REARM: a plane firing RequestRespawn on a loop is not boss-proof), else the stamp.
local function respawning(player: Player, now: number): boolean
	local a = slot:get()
	local immune = if a then a.immune else nil
	if immune then
		local ok, yes = pcall(immune, player)
		return ok and yes == true
	end
	return BossRace.freshRespawn(player:GetAttribute("LastRespawnClock"), now)
end

-- Respawn frames still inside their protection window (where a fresh drop must not land).
local function freshFrames(a: Active, now: number): { Vector3 }
	local out = {}
	for player, rec in a.records() do
		if respawning(player, now) and typeof(rec.lastCheckpointCF) == "CFrame" then
			table.insert(out, rec.lastCheckpointCF.Position)
		end
	end
	return out
end

local function drop(a: Active, now: number)
	local st = a.bossStation()
	local hull = a.bossHull()
	if not st or not hull then
		return
	end
	local keepClear = freshFrames(a, now)
	local kindName = if a.rematch then a.boss.rematchHazard else a.boss.hazard
	local k = KINDS[kindName] or KINDS.fireball
	local count = if a.rematch then 2 else 1
	for i = 1, count do
		local behind = st - 26 - (i - 1) * 14
		local pos, tan = SplineUtils.sampleAtStation(behind)
		local right = tan:Cross(Vector3.yAxis).Unit
		local lateral = (math.random() - 0.5) * (if a.boss.vehicle == "car" then 28 else 36)
		local lineY = hull.Position.Y - (SplineUtils.sampleAtStation(st)).Y
		local groundY = pos.Y + (if a.boss.vehicle == "car" then 4 else math.clamp(lineY, 4, 20))
		local spawnY = if k.motion == "fall" then groundY + 40 elseif k.motion == "strike" then groundY else groundY
		local at = pos + right * lateral + Vector3.new(0, spawnY - pos.Y, 0)
		if not BossRace.dropClear(Vector3.new(at.X, groundY, at.Z), keepClear) then
			continue -- a player was just set down here: this drop is skipped, the next one comes as usual
		end
		local p = makePart(k, CFrame.new(at), a.folder, kindName)
		if k.motion == "strike" then
			p.Transparency = 0.7 -- warning ring phase: visible, not yet live
		end
		table.insert(a.hazards, { part = p, kind = kindName, born = now, sim = a.sim, live = k.motion ~= "strike" and k.motion ~= "fall", station = behind, baseY = spawnY, groundY = groundY })
	end
end

local function step(a: Active, dt: number)
	local now = os.clock()
	local go = RaceAttr.here("RaceGoTime")
	local started = not (type(go) == "number" and workspace:GetServerTimeNow() < go)
	if started and now >= a.nextDrop then
		a.nextDrop = now + (if a.rematch then a.boss.rematchDropEvery else a.boss.dropEvery)
		-- Clients play the boss's attack one-shot (BossAnimator) when BossDropAt changes; the hazard itself appears
		-- RELEASE seconds later, on the clip's release frame (the tail flick, wing gust or abdomen flick).
		local hull = a.bossHull()
		local bossModel = if hull then hull.Parent else nil
		if bossModel then
			bossModel:SetAttribute("BossDropAt", workspace:GetServerTimeNow())
		end
		task.delay(RELEASE, ModeScopeRules.bind(function()
			if slot:get() == a then
				drop(a, os.clock())
			end
		end))
	end
	local records = a.records()
	local steps, stepDt = RacerViewRules.serverSteps(a.clock, dt)
	a.sim += steps * stepDt
	for i = #a.hazards, 1, -1 do
		local h = a.hazards[i]
		local age = a.sim - h.sim -- motion age on the step grid
		local k = KINDS[h.kind] or KINDS.fireball
		local p = h.part
		if now - h.born > LIFETIME or not p.Parent then
			p:Destroy()
			table.remove(a.hazards, i)
			continue
		end
		if steps == 0 then
			-- No whole step this Heartbeat: the pose stands (nothing replicates); hits below still run.
		elseif k.motion == "fall" then
			local y = math.max(h.groundY, h.baseY - 0.5 * 60 * age * age)
			p.CFrame = CFrame.new(p.Position.X, y, p.Position.Z)
			h.live = y <= h.groundY + 1
		elseif k.motion == "float" then
			p.CFrame = CFrame.new(p.Position.X, h.baseY + math.sin(age * 2.2) * 1.5, p.Position.Z)
		elseif k.motion == "roll" then
			h.station -= 38 * steps * stepDt
			local pos = SplineUtils.sampleAtStation(h.station)
			local pull = 1 - (1 - 0.2) ^ steps -- the 0.2-per-step ease, once per whole step
			p.CFrame = CFrame.new(Vector3.new(p.Position.X + (pos.X - p.Position.X) * pull, pos.Y + k.size * 0.5 + 2, p.Position.Z + (pos.Z - p.Position.Z) * pull))
		elseif k.motion == "strike" then
			if age > 1.0 and not h.live then
				h.live = true
				p.Transparency = 0
				p.Size = Vector3.new(3, 40, 3)
				p.Shape = Enum.PartType.Block
				p.CFrame = CFrame.new(p.Position + Vector3.new(0, 18, 0))
				local bolt = p:FindFirstChild("HazardBolt")
				if bolt and bolt:IsA("ParticleEmitter") then
					bolt.Enabled = true -- bolts flicker up and down the 40-stud column while it is live
				end
			elseif age > 1.7 then
				p:Destroy()
				table.remove(a.hazards, i)
				continue
			end
		end
		if h.live then
			for player, rec in records do
				local hull = rec.hull
				if hull and hull.Parent and not respawning(player, now) and (hull.Position - p.Position).Magnitude < RADIUS + k.size * 0.3 then
					a.hit(player, h.kind, p.Position)
					p:Destroy()
					table.remove(a.hazards, i)
					break
				end
			end
		end
	end
	if steps > 0 then
		RacerViewRules.publish(3, a.clock, function(): { BasePart } -- the clients' stamped pose stream (Shared.RacerStreamRules)
			local parts: { BasePart } = {}
			for _, h in a.hazards do
				if h.part.Parent then
					table.insert(parts, h.part :: BasePart)
				end
			end
			return parts
		end)
	end
end

-- Every scope's boss race, each in its own scope (the single path: the one race, as before).
function BossRace.stepAll(dt: number)
	slot:each(function(a: Active)
		step(a, dt)
	end)
end

function BossRace.stop()
	local a = slot:get()
	if a then
		if a.ownsFolder then
			a.folder:Destroy()
		else
			for _, h in a.hazards do
				h.part:Destroy()
			end
			table.clear(a.hazards)
		end
	end
	slot:set(nil)
end

function BossRace.isActive(): boolean
	return slot:get() ~= nil
end

-- The folder this race's hazards go in: its own on the single path (destroyed with the race, as before); per group the
-- one shared workspace.BossHazards (clients and the bots' ray filters look it up by name).
local function hazardFolder(): (Folder, boolean)
	if not ModeScopeRules.perGroup() then
		local folder = Instance.new("Folder")
		folder.Name = "BossHazards"
		folder.Parent = workspace
		return folder, true
	end
	local shared = workspace:FindFirstChild("BossHazards")
	if shared and shared:IsA("Folder") then
		return shared, false
	end
	local folder = Instance.new("Folder")
	folder.Name = "BossHazards"
	folder.Parent = workspace
	return folder, false
end

-- zone: ActiveZone of the boss race; hooks come from the boot script (item hit, player records, the boss bot).
function BossRace.start(zone: string, rematch: boolean, hooks: {
	hit: (Player, string, Vector3) -> (),
	records: () -> { [Player]: any },
	bossHull: () -> BasePart?,
	bossStation: () -> number?,
	immune: ((Player) -> boolean)?,
})
	BossRace.stop()
	local boss = BossConfig.forZone(zone)
	if not boss then
		return
	end
	local folder, owns = hazardFolder()
	slot:set({
		boss = boss,
		rematch = rematch,
		nextDrop = os.clock() + 2,
		hazards = {},
		sim = 0,
		clock = RacerViewRules.newServerClock(),
		folder = folder,
		ownsFolder = owns,
		hit = hooks.hit,
		records = hooks.records,
		bossHull = hooks.bossHull,
		bossStation = hooks.bossStation,
		immune = hooks.immune,
	})
	if not conn then
		conn = RunService.Heartbeat:Connect(BossRace.stepAll)
	end
	print(string.format("[SkyRally][BOSS] race %s rematch=%s hazard=%s", boss.name, tostring(rematch), if rematch then boss.rematchHazard else boss.hazard))
end

return BossRace
