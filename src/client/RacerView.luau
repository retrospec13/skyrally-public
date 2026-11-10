--!strict
-- The other racers as this client draws them (rules, numbers and the jitter diagnosis: Shared.RacerViewRules).
--   * Bots (any workspace.Planes model with a BotId whose Hull is anchored: race bots, battle bots, the zone boss) are
--     server-CFramed anchored parts, and anchored CFrames replicate without interpolation, so they stuttered against
--     the smooth chase camera. Every render frame, before the camera and every other client module, this module feeds
--     the replicated hull CFrame into a snapshot track and writes the hull's local CFrame to the interpolated pose.
--     The local write never replicates; the next server update replaces it and is told apart from this module's own
--     write by RacerViewRules.changed. Welded bodies, pilots, flames, taunt bubbles and labels follow the hull.
--     Snapshots are timed in server sim time (bots step in whole RacerViewRules.SERVER_STEP steps; 2026-10-20 residual
--     jitter fix, docs/audits/opponent_jitter.md), not by when this client happened to receive them.
--     Ground racers (IsCar / GroundRacer: bot cars, car battle bots, a boss walker on a car map) keep the server's
--     road-snapped height: the view never extrapolates them vertically (RacerViewRules.sample `ground`).
--   * Pose stream (2026-10-20 opp-smooth, Shared.RacerStreamRules): the server also sends every bot's and hazard's pose
--     at 60 Hz with its exact server sim time (SkyRallyRemotes.RacerStream). While a part has a fresh stream track it
--     is drawn from that (Catmull-Rom at a lateness-sized playhead) instead of the inferred-time property track below,
--     which stays warm as the fallback (stream remote missing, a lost burst over RacerStreamRules.STALE). Both run on
--     the RENDER clock (sum of this bind's dt, slewed onto os.clock()), the clock the chase cameras integrate on.
--   * Boss hazards (workspace.BossHazards: falling bombs, rolling boulders, floating mines) are anchored server parts
--     moved every Heartbeat too, so they get the same snapshot track (no labels).
--   * Remote players' vehicles (2026-10-20 remote-smooth, Shared.PlayerStreamRules) are unanchored and owned by their
--     clients; the engine's physics replication drew them, sampled at the owner's frame cadence and interpolated
--     linearly (Studio 2-client: fit p95 0.28 studs, 50x a bot's). Now each client also sends its own vehicle's pose,
--     stamped with its own sim time (sendOwn below, after the vehicle controllers), the server gates and relays it,
--     and this module draws every other player's hull from that stream exactly like a bot's (Hermite at a
--     lateness-sized playhead, one clock per player), blended in and out of the engine's pose over BLEND_TIME. The
--     write is the hull's LOCAL CFrame, first in the frame: render only. The engine puts its replicated pose back in
--     its next simulation step, so hit tests, items, standings and every server check keep the physics hull. A hull
--     anchored by a server hold, or with no fresh stream, is left to the engine. This player's own vehicle is never
--     written. Item missiles are smoothed by ItemClient's own local copy.
--     Since Studio V5A (noRestore ~30 %: the engine did not always put its pose back over that write) the in-place
--     write is OFF by default (workspace.SkyRallyRemoteDraw must be exactly true). Its replacement (2026-10-20
--     remote-clone, Shared.RemoteCloneRules, workspace.SkyRallyRemoteClone exactly true, off until Studio passes): a
--     client-only anchored, non-colliding copy of the vehicle and the seated avatar is drawn at the stream pose while
--     the real parts are hidden locally (LocalTransparencyModifier); effects, the label, bubbles and the minimap dot
--     follow it; the real physics hull is only read.
--   * Name labels: one BillboardGui per other racer (never this player's own vehicle, never a boss), adorned to the
--     hull once with a fixed pixel size and offset, faded in under ~55 studs and out by 70 from this player's vehicle,
--     semi-transparent text on a lighter pill. Nothing is reparented or re-offset per frame; transparency is written
--     only when it moves by more than 0.02. The seated avatars' own Humanoid name tags are off (server/kit/PilotSeat),
--     so this is the only name over a vehicle.
--   * Camera-near fade (RacerViewRules.fadeTarget): every other racer's visible parts (its BaseParts and decals, the
--     bot pilot inside the model, a remote player's seated character) fade with LocalTransparencyModifier when the
--     racer's box comes within NEAR_CLEAR of the chase camera or stands in the sightline to this player's vehicle, eased
--     (no pop). This player's own vehicle is never touched. The part list and the racer's box (visible parts, in hull
--     space) are cached per racer and rebuilt at the next scan after the model or the pilot gains or loses a part; a
--     part another module set (Cosmetics' emote stand-in hides the real mesh) is left alone while it does not hold
--     this module's last value. Its label fades with it.
-- HUD layout v2 (docs/design/HUD_LAYOUT.md 7.1): a label hides while its racer's bubble shows (RivalBubbles sets the model's
-- SpeechUp attribute; the bubble's tab carries the name), at most the 3 nearest racers show a label, and a label within
-- 24 px of a nearer one is hidden (HudLayoutRules.pickLabels). Labels are 22 px tall with 13 px text at S 0.6.
-- Cost: one Planes scan every SCAN_INTERVAL; per frame one CFrame read and write per bot, one distance and a few
-- property compares per labelled racer, and one box test per racer; parts are written only while a fade moves.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local Prof = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RacerViewRules"))
local Stream = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RacerStreamRules"))
local PStream = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerStreamRules"))
local RClone = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RemoteCloneRules"))
local HudLayoutRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HudLayoutRules"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RacerPaletteRules"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local RacerView = {}

RacerView.SCAN_INTERVAL = 0.5
RacerView.LABEL_OFFSET = Vector3.new(0, 4.4, 0) -- studs above the hull: just over the seated pilot's head
RacerView.MAX_LABELS = 3 -- the nearest racers on screen
RacerView.LABEL_GAP = 24 -- px: a label this close to a nearer one hides
-- Pixels, the same at every distance, no re-layout: 22 px tall / 13 px text at S 0.6, growing with the HUD scale.
local labelH = 22
local labelText = 13
local function scaleLabels(S: number)
	labelH = math.max(22, math.floor(34 * S + 0.5))
	labelText = math.max(13, math.floor(20 * S + 0.5))
end

local INK = Color3.fromRGB(40, 28, 22)
local PAPER = Color3.fromRGB(255, 248, 230)

type Racer = {
	model: Model,
	hull: BasePart,
	smooth: boolean,
	ground: boolean,
	track: Rules.Track,
	written: CFrame?,
	streamId: number?, -- the hull's StreamId (server/RacerStream), re-read each scan
	remote: boolean, -- another player's unanchored vehicle: drawn from his pose stream (PlayerStreamRules)
	blend: number, -- engine (0) -> stream (1) weight
	offset: CFrame?, -- the last stream pose in the engine pose's space (the hand-back)
	drawn: CFrame?, -- what stepRemote wrote to the hull last frame (nil: nothing)
	engine: CFrame?, -- the engine's pose it read that frame (PlayerStreamRules.engineOf)
	-- the visual clone (RemoteCloneRules): never the real hull's CFrame
	cstate: RClone.State,
	clone: RClone.Clone?,
	cloneMoves: { RClone.Move }, -- effects moved onto the clone (put back at the hand-back)
	cloneHidden: { [Instance]: number }, -- real parts hidden while the clone shows -> what they held before
	cloneFadeAt: number, -- the camera-near fade when they were hidden
	cloneConn: RBXScriptConnection?,
	gui: BillboardGui?,
	text: TextLabel?,
	outline: UIStroke?,
	bar: Frame?, -- the racer-colour bar at the label's left edge
	shown: number,
	appliedAlpha: number,
	-- camera-near fade
	own: boolean,
	pilot: Model?, -- a remote player's seated character (outside the vehicle model)
	parts: { Instance }, -- BaseParts, Decals and Textures of the model and the pilot
	boxOffset: CFrame, -- visible box centre in hull space
	half: Vector3,
	dirty: boolean,
	conns: { RBXScriptConnection },
	fade: number,
	fadeApplied: number,
}

local racers: { [Model]: Racer } = {}
local scanClock = 0
local initialized = false
local folder: Folder? = nil

local function holder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyRacerLabels"
	nf.Parent = pg
	folder = nf
	return nf
end

local function nameOf(userId: number): string?
	local p = Players:GetPlayerByUserId(userId)
	if p then
		return if p.DisplayName ~= "" then p.DisplayName else p.Name
	end
	return nil
end

local function attrsOf(model: Model): { [string]: any }
	return {
		BotName = model:GetAttribute("BotName"),
		OwnerUserId = model:GetAttribute("OwnerUserId"),
		OwnerName = model:GetAttribute("OwnerName"),
		IsBoss = model:GetAttribute("IsBoss"),
	}
end

local function makeLabel(hull: BasePart, text: string, racerColor: Color3?): (BillboardGui, TextLabel, UIStroke, Frame?)
	local g = Instance.new("BillboardGui")
	g.Name = "RacerName"
	g.Size = UDim2.fromOffset(180, labelH + 2)
	g.StudsOffsetWorldSpace = RacerView.LABEL_OFFSET
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.MaxDistance = Rules.LABEL_HIDE + 60 -- engine cull from the camera (it sits behind this player's vehicle)
	g.ResetOnSpawn = false
	g.Active = false
	g.ClipsDescendants = false
	g.Enabled = false
	g.Adornee = hull
	pcall(function()
		game:GetService("CollectionService"):AddTag(g, "RacerNameLabel") -- TrackFlow hides it (HudHidden) while it sits under a battle HUD element
	end)
	local l = Instance.new("TextLabel")
	l.Name = "Name"
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromOffset(0, labelH)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.BackgroundColor3 = INK
	l.BorderSizePixel = 0
	l.Font = Enum.Font.GothamBold
	l.TextSize = labelText
	-- Racer colour (RacerColor, set by server/kit/RacerPaint): the text leans into it and a bar at the left edge carries it
	-- at full strength, so a name reads as "the orange one" even when the dark mesh hides the paint.
	l.TextColor3 = if racerColor then racerColor:Lerp(PAPER, 0.35) else PAPER
	l.RichText = false -- display names are data, never markup
	l.Text = text
	l.TextTransparency = 1
	l.BackgroundTransparency = 1
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = l
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = l
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual -- outlines the text, not the pill
	s.Color = INK
	s.Thickness = 1.2
	s.Transparency = 1
	s.Parent = l
	local bar: Frame? = nil
	if racerColor then
		local b = Instance.new("Frame")
		b.Name = "RacerColorBar"
		b.AnchorPoint = Vector2.new(0, 0.5)
		b.Position = UDim2.new(0, -6, 0.5, 0) -- inside the 8 px left padding
		b.Size = UDim2.new(0, 3, 1, -10)
		b.BackgroundColor3 = racerColor
		b.BackgroundTransparency = 1
		b.BorderSizePixel = 0
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 2)
		bc.Parent = b
		b.Parent = l
		bar = b
	end
	l.Parent = g
	g.Parent = holder()
	return g, l, s, bar
end

-- ---------------------------------------------------------------- "you" marker (wide shots only)
-- A small diamond over this player's own vehicle, in the racer colour, that fades in only when the camera is more than
-- Palette.YOU_NEAR studs away (start-grid overview, podium, replays) and is gone in the chase view (~14 studs back).
local youGui: BillboardGui? = nil
local youDiamond: Frame? = nil
local youStroke: UIStroke? = nil
local youAlpha = 0
local youColor: Color3? = nil

local function ensureYou(): (BillboardGui, Frame, UIStroke)
	local og, od, os_ = youGui, youDiamond, youStroke
	if og and od and os_ and og.Parent then
		return og, od, os_
	end
	local g = Instance.new("BillboardGui")
	g.Name = "RacerYou"
	g.Size = UDim2.fromOffset(34, 34)
	g.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.ResetOnSpawn = false
	g.Active = false
	g.Enabled = false
	local d = Instance.new("Frame") -- a diamond: a square turned 45 degrees
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Position = UDim2.fromScale(0.5, 0.5)
	d.Size = UDim2.fromOffset(18, 18)
	d.Rotation = 45
	d.BackgroundColor3 = PAPER
	d.BackgroundTransparency = 1
	d.BorderSizePixel = 0
	local s = Instance.new("UIStroke")
	s.Color = INK
	s.Thickness = 2
	s.Transparency = 1
	s.Parent = d
	d.Parent = g
	g.Parent = holder()
	youGui, youDiamond, youStroke = g, d, s
	return g, d, s
end

local function stepYou(r: Racer, camPos: Vector3)
	local a = Palette.youAlpha((camPos - r.hull.Position).Magnitude)
	if math.abs(a - youAlpha) <= 0.02 and not (a == 0 and youAlpha ~= 0) and not (a == 1 and youAlpha ~= 1) then
		return
	end
	youAlpha = a
	local g, d, s = ensureYou()
	if g.Adornee ~= r.hull then
		g.Adornee = r.hull
	end
	local c = r.model:GetAttribute("RacerColor")
	if typeof(c) == "Color3" and c ~= youColor then
		youColor = c
		d.BackgroundColor3 = c
	end
	d.BackgroundTransparency = 1 - a
	s.Transparency = 1 - a
	g.Enabled = a > 0
end

-- Boss hazards: part -> its snapshot track (ground false: a falling bomb's height is the motion).
type Prop = { part: BasePart, track: Rules.Track, written: CFrame?, streamId: number? }
local props: { [BasePart]: Prop } = {}

local hazardFolder: Instance? = nil

-- Pose stream state (Shared.RacerStreamRules): a clock per source, a pose buffer per StreamId, the render clock and
-- this frame's playhead per source.
local streamTracks: { [number]: Stream.Track } = {}
local streamClocks: { [number]: Stream.Clock } = {}
local renderClock = Stream.newRenderClock()
local heads: { [number]: number } = {}
local lastFrameWall = -math.huge -- os.clock() of the last render step: a packet handled long after it sat out a client stall
local frameDt = 1 / 60 -- smoothed render step (Stream.isStall: a steady low frame rate is not a stall)

local function onStreamPacket(b: any)
	local arrival = os.clock()
	local stalled = lastFrameWall > -math.huge and Stream.isStall(arrival - lastFrameWall, frameDt)
	local source, stamp, ids, cfs = Stream.decode(b)
	if source == nil then
		return
	end
	local player = source == PStream.SOURCE
	if not player then
		Stream.stats.packets += 1 -- the bot stream's counters (the probe's "stream" row) never count player traffic
	end
	-- one clock per bot mover; a player packet carries one pose on that player's own timeline
	local ckey = PStream.clockKey(source :: number, if #ids > 0 then ids[1] else 0)
	local c: Stream.Clock? = streamClocks[ckey]
	if c == nil then
		local fresh = Stream.newClock()
		streamClocks[ckey] = fresh
		c = fresh
	end
	Stream.observe(c :: Stream.Clock, stamp, arrival, stalled)
	for i, id in ids do
		local key = PStream.clockKey(source :: number, id)
		local st: Stream.Track? = streamTracks[id]
		-- a new source, or a player's stream back after a gap (relay range, a hold, a respawn the server refused until
		-- its hull caught up): a fresh buffer, never a curve across the gap
		if st == nil or st.source ~= source or (player and arrival - st.lastArrival > PStream.RESTART_GAP) then
			local fresh = Stream.newTrack(source :: number, key, if player then PStream.SNAP_SPEED else nil)
			streamTracks[id] = fresh
			st = fresh
		end
		if player then
			PStream.stats.packets += 1
			local cuts, dropped = Stream.stats.cuts, Stream.stats.dropped
			Stream.push(st :: Stream.Track, stamp, cfs[i], arrival)
			if Stream.stats.cuts ~= cuts then
				PStream.stats.cuts += 1
			end
			Stream.stats.cuts, Stream.stats.dropped = cuts, dropped -- the bot counters stay bots-only
		else
			Stream.push(st :: Stream.Track, stamp, cfs[i], arrival)
		end
	end
end

-- Hands a remote player's hull back to the engine: no blend, no offset, no recorded engine pose. A hull the server
-- anchored right after this client's last write keeps that write (nothing replicates over an anchored part until the
-- server writes it again), so the engine pose read before it is put back once. Never on this player's own vehicle.
local function releaseRemote(r: Racer)
	local hull = r.hull
	if r.drawn and r.engine and hull.Anchored and hull.CFrame == r.drawn and hull.Parent
		and r.model:GetAttribute("OwnerUserId") ~= LocalPlayer.UserId then
		hull.CFrame = r.engine :: CFrame
	end
	r.blend, r.offset, r.drawn, r.engine = 0, nil, nil, nil
	PStream.enginePoses[hull] = nil
end

-- The stream pose for StreamId `id` this frame, or nil (no id, no fresh track: the caller falls back). `remote`: a
-- player's track, which hands back to the engine once it would only hold (it never counts in the bot counters).
local function streamPose(id: number?, now: number, ground: boolean, remote: boolean?): CFrame?
	if id == nil then
		return nil
	end
	local st = streamTracks[id]
	if not st or now - st.lastArrival > Stream.STALE or #st.snaps == 0 then
		return nil
	end
	local at = heads[st.clock]
	if at == nil then
		local c = streamClocks[st.clock]
		if not c then
			return nil
		end
		at = Stream.playhead(c, now)
		heads[st.clock] = at
	end
	if (at :: number) < st.snaps[1].t then
		return nil -- a new track: the buffer does not reach back to the playhead yet (the property track draws)
	end
	local cf = Stream.sample(st, at :: number, ground)
	if remote then
		return if st.mode == "hold" then nil else cf
	end
	if cf then
		Stream.stats.stream += 1
		if st.mode == "extrap" then
			Stream.stats.extrapolated += 1
		elseif st.mode == "hold" then
			Stream.stats.held += 1
		end
	end
	return cf
end

local function addProp(p: Instance)
	if p:IsA("BasePart") and p.Anchored and not props[p] then
		local sid = p:GetAttribute("StreamId")
		props[p] = { part = p, track = Rules.newTrack(), written = nil, streamId = if type(sid) == "number" then sid else nil }
	end
end

-- Hazards live about a second, so a new one is tracked the moment it replicates (ChildAdded), not at the next scan.
local function scanHazards()
	local folder = workspace:FindFirstChild("BossHazards")
	if folder and folder ~= hazardFolder then
		hazardFolder = folder
		folder.ChildAdded:Connect(addProp)
	end
	if folder then
		for _, p in folder:GetChildren() do
			addProp(p)
		end
	end
	for p in props do
		if p.Parent ~= folder then
			props[p] = nil
		end
	end
end

-- Writes `value` to every cached part that still holds this racer's last written fade (another module's own write,
-- e.g. Cosmetics hiding a mesh for an emote, is left alone).
local function writeFade(r: Racer, value: number)
	local last = r.fadeApplied
	local c = r.clone
	for _, d in r.parts do
		local part = d :: any
		if d.Parent and math.abs(part.LocalTransparencyModifier - last) < 1e-3 and (c == nil or r.cloneHidden[d] == nil) then
			part.LocalTransparencyModifier = value
		end
	end
	if c then
		-- the clone stands in for the hidden real parts
		for _, d in c.visuals do
			local v = d :: any
			if d.Parent and math.abs(v.LocalTransparencyModifier - last) < 1e-3 then
				v.LocalTransparencyModifier = value
			end
		end
	end
	r.fadeApplied = value
end

local function disconnectAll(r: Racer)
	for _, c in r.conns do
		c:Disconnect()
	end
	table.clear(r.conns)
end

local function isFadeable(d: Instance): boolean
	return d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture")
end

-- Rebuilds the racer's part list and visible box (hull space). Runs at creation and at a scan after a part change.
local function rebuildParts(r: Racer)
	if r.fadeApplied ~= 0 then
		writeFade(r, 0) -- parts that leave the list must not stay faded; the next frame re-applies the fade
	end
	disconnectAll(r)
	local parts: { Instance } = {}
	local hullCF = r.hull.CFrame
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	local function add(root: Instance, boxed: boolean)
		for _, d in root:GetDescendants() do
			if isFadeable(d) then
				table.insert(parts, d)
				if boxed and d:IsA("BasePart") and d.Transparency < 0.99 then
					local cf = hullCF:ToObjectSpace(d.CFrame)
					local hs = d.Size * 0.5
					for sx = -1, 1, 2 do
						for sy = -1, 1, 2 do
							for sz = -1, 1, 2 do
								local c = cf * Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz)
								lo = lo:Min(c)
								hi = hi:Max(c)
							end
						end
					end
				end
			end
		end
		local function mark(d: Instance)
			if isFadeable(d) then
				r.dirty = true
			end
		end
		table.insert(r.conns, root.DescendantAdded:Connect(mark))
		table.insert(r.conns, root.DescendantRemoving:Connect(mark))
	end
	add(r.model, true)
	local pilot = r.pilot
	if pilot then
		add(pilot, false)
	end
	r.parts = parts
	if lo.X <= hi.X then
		-- Capped so one stray far part (an item bubble, a hit marker) cannot make a racer fade from across the road.
		r.half = ((hi - lo) * 0.5):Min(Vector3.new(20, 12, 20))
		r.boxOffset = CFrame.new((hi + lo) * 0.5)
	else
		r.half = r.hull.Size * 0.5
		r.boxOffset = CFrame.identity
	end
	r.dirty = false
end

-- ---------------------------------------------------------------- visual clone (Shared.RemoteCloneRules)
-- Everything below reads the real vehicle and the seated avatar and writes only the clone, the real parts'
-- LocalTransparencyModifier (local), effect parents (local) and BillboardGui adornees. Never a real part's CFrame.
local cloneFolder: Folder? = nil

local function clonesHolder(): Folder
	local f = cloneFolder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyRemoteClones" -- client-only (never replicated), outside workspace.Planes
	nf.Parent = workspace
	cloneFolder = nf
	return nf
end

-- Re-targets this player's BillboardGuis (bubbles, the rival flag, the nemesis toast) adorned to a part in `map`.
local function readorn(map: { [any]: any })
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	for _, d in pg:GetDescendants() do
		if d:IsA("BillboardGui") then
			local a = d.Adornee
			local to = if a then map[a] else nil
			if to then
				d.Adornee = to
			end
		end
	end
end

local function clearTrails(c: RClone.Clone)
	for _, t in c.trails do
		if t.Parent and t:IsA("Trail") then
			t:Clear() -- no streak across the swap
		end
	end
end

local function applyMoves(r: Racer, moves: { RClone.Move })
	for _, mv in moves do
		local to = mv.to
		if to and mv.inst.Parent == mv.from then
			mv.inst.Parent = to
			table.insert(r.cloneMoves, mv)
		end
	end
end

local function sweepMoves(r: Racer)
	local c = r.clone
	if c then
		applyMoves(r, RClone.newMoves(c, if r.pilot then { r.model, r.pilot } else { r.model }))
	end
end

-- Hands a remote player's vehicle back to its real parts at once: effects and billboards back, real parts unhidden,
-- the clone gone. Safe on a racer whose model already left.
local function destroyClone(r: Racer)
	local c = r.clone
	if not c then
		return
	end
	r.clone = nil
	PStream.visuals[r.hull] = nil
	local conn = r.cloneConn
	if conn then
		conn:Disconnect()
		r.cloneConn = nil
	end
	for _, mv in r.cloneMoves do
		if mv.from.Parent and mv.inst.Parent == mv.to then
			pcall(function()
				mv.inst.Parent = mv.from
			end)
		end
	end
	table.clear(r.cloneMoves)
	clearTrails(c)
	local back: { [any]: any } = {}
	for src, dst in c.map do
		back[dst] = src
	end
	readorn(back)
	if r.gui then
		r.gui.Adornee = r.hull
	end
	for inst, prior in r.cloneHidden do
		local part = inst :: any
		if inst.Parent and math.abs(part.LocalTransparencyModifier - 1) < 1e-3 then
			part.LocalTransparencyModifier = RClone.restoreValue(prior, r.cloneFadeAt, r.fadeApplied)
		end
	end
	table.clear(r.cloneHidden)
	c.model:Destroy()
end

-- Builds the clone at the real parts' current poses (the caller draws it this frame) and swaps it in. False: no clone.
local function buildClone(r: Racer): boolean
	local ok, built = pcall(RClone.build, r.model, r.pilot, r.hull, function(cls: string): any
		return Instance.new(cls :: any)
	end)
	if not ok or not built then
		warn("[RacerView] remote clone failed: " .. tostring(built))
		return false
	end
	local c = built :: RClone.Clone
	local pilot = c.model:FindFirstChild("Pilot")
	local hum = if pilot then pilot:FindFirstChildOfClass("Humanoid") else nil
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	r.cloneFadeAt = r.fadeApplied
	for _, inst in r.parts do
		if inst.Parent then
			local part = inst :: any
			r.cloneHidden[inst] = part.LocalTransparencyModifier
			part.LocalTransparencyModifier = 1
		end
	end
	-- each counterpart starts at what its source showed (a mesh another module hid stays hidden)
	for _, d in c.visuals do
		local src = c.sources[d] or (if d.Parent then c.sources[d.Parent] else nil)
		local prior = if src then r.cloneHidden[src] else nil;
		(d :: any).LocalTransparencyModifier = if prior then prior else r.fadeApplied
	end
	c.model.Parent = clonesHolder()
	r.clone = c
	applyMoves(r, c.moves)
	clearTrails(c)
	readorn(c.map)
	if r.gui then
		r.gui.Adornee = c.root
	end
	PStream.visuals[r.hull] = c.root
	r.cloneConn = r.hull.ChildAdded:Connect(function()
		sweepMoves(r)
	end)
	return true
end

local function drop(model: Model)
	local r = racers[model]
	if r then
		destroyClone(r)
		if r.gui then
			r.gui:Destroy()
		end
		if r.fadeApplied ~= 0 then
			writeFade(r, 0)
		end
		disconnectAll(r)
	end
	racers[model] = nil
end

-- A remote player's seated character (PilotSeat welds it at the seat; it lives outside workspace.Planes).
local function pilotOf(m: Model): Model?
	if m:GetAttribute("BotId") ~= nil then
		return nil -- a bot's pilot is a child of the vehicle model
	end
	local owner = m:GetAttribute("OwnerUserId")
	local p = if type(owner) == "number" then Players:GetPlayerByUserId(owner) else nil
	return if p then p.Character else nil
end

local function scan()
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return
	end
	for _, m in planes:GetChildren() do
		if m:IsA("Model") then
			local hull = m.PrimaryPart or m:FindFirstChild("Hull")
			local r: Racer? = racers[m]
			if r and r.hull ~= hull then
				drop(m) -- a rebuilt vehicle: start over with its new hull
				r = nil
			end
			if not r and hull and hull:IsA("BasePart") then
				local text = Rules.labelText(attrsOf(m), LocalPlayer.UserId, nameOf)
				local nr: Racer = {
					model = m,
					hull = hull,
					smooth = false,
					ground = false,
					track = Rules.newTrack(),
					written = nil,
					streamId = nil,
					remote = false,
					blend = 0,
					offset = nil,
					drawn = nil,
					engine = nil,
					cstate = RClone.newState(),
					clone = nil,
					cloneMoves = {},
					cloneHidden = {},
					cloneFadeAt = 0,
					cloneConn = nil,
					gui = nil,
					text = nil,
					outline = nil,
					bar = nil,
					shown = 0,
					appliedAlpha = -1,
					own = m:GetAttribute("OwnerUserId") == LocalPlayer.UserId,
					pilot = nil,
					parts = {},
					boxOffset = CFrame.identity,
					half = hull.Size * 0.5,
					dirty = true,
					conns = {},
					fade = 0,
					fadeApplied = 0,
				}
				if text then
					local rc = m:GetAttribute("RacerColor")
					nr.gui, nr.text, nr.outline, nr.bar = makeLabel(hull, text, if typeof(rc) == "Color3" then rc else nil)
				end
				racers[m] = nr
				r = nr
			end
			if r then
				-- Re-read each scan: a hull anchored for a server hold is still a player's (no BotId), and a bot keeps
				-- its BotId for life.
				local isBot = m:GetAttribute("BotId") ~= nil
				-- a bot renamed in place (server/BotNamePool found its unchecked name was somebody's account): new label text
				if isBot and r.text then
					local want = Rules.labelText(attrsOf(m), LocalPlayer.UserId, nameOf)
					if want and want ~= r.text.Text then
						r.text.Text = want
					end
				end
				local smooth = isBot and r.hull.Anchored
				local sid = r.hull:GetAttribute("StreamId")
				r.streamId = if type(sid) == "number" then sid else nil
				r.ground = m:GetAttribute("IsCar") == true or m:GetAttribute("GroundRacer") == true
				if smooth ~= r.smooth then
					r.smooth = smooth
					r.track = Rules.newTrack()
					r.written = nil
				end
				local own = m:GetAttribute("OwnerUserId") == LocalPlayer.UserId
				-- another player's vehicle the engine simulates (not a bot, not ours, not held anchored by the server)
				local remote = not isBot and not own and not r.hull.Anchored
				if remote ~= r.remote then
					releaseRemote(r)
					destroyClone(r)
					RClone.reset(r.cstate)
					r.remote = remote
				end
				if own and not r.own and r.fadeApplied ~= 0 then
					writeFade(r, 0) -- now this player's vehicle (a hub exchange): never faded
				end
				r.own = own
				-- Underglow (server/kit/RacerPaint builds it disabled): on for dark maps only, never under LOW GRAPHICS.
				local glow = m:FindFirstChild("RacerGlow")
				local light = if glow then glow:FindFirstChildOfClass("PointLight") else nil
				if light then
					local want = Palette.underglowOn(RaceAttr.mine("ActiveTrackId"), Settings.lowGraphics())
					if light.Enabled ~= want then
						light.Enabled = want
					end
				end
				if own then
					r.fade = 0
				else
					local pilot = pilotOf(m)
					if pilot ~= r.pilot then
						r.pilot = pilot
						r.dirty = true
					end
					if r.dirty then
						if r.clone then
							-- a part or the pilot changed under a showing clone: rebuild it (drawn again this frame)
							destroyClone(r)
							rebuildParts(r)
							if not buildClone(r) then
								RClone.reset(r.cstate)
							end
						else
							rebuildParts(r)
						end
					elseif r.clone then
						sweepMoves(r)
					end
				end
			end
		end
	end
	for m in racers do
		if m.Parent ~= planes then
			drop(m)
		end
	end
	scanHazards()
	local wall = os.clock()
	for id, st in streamTracks do
		if wall - st.lastArrival > 3 then
			streamTracks[id] = nil -- a part that left (a finished hazard, a rebuilt bot, a player who left or is out of range)
			if st.clock >= PStream.CLOCK_BASE then
				streamClocks[st.clock] = nil -- a player's own clock goes with his track
			end
		end
	end
end

-- This player's own vehicle hull (labels measure from it; the camera stands in while there is none).
local function ownHull(): BasePart?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	local name = LocalPlayer:GetAttribute("PlaneName")
	local m = if type(name) == "string" then planes:FindFirstChild(name) else nil
	if m and m:IsA("Model") and m:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		local hull = m.PrimaryPart
		return if hull then hull else nil
	end
	return nil
end

-- Feeds `part`'s replicated CFrame into `track` and draws the interpolated pose; returns what it wrote (or `written`).
local function stepSmooth(track: Rules.Track, written: CFrame?, part: BasePart, now: number, ground: boolean, streamId: number?): CFrame?
	local current = part.CFrame
	if Rules.changed(current, written) then
		Rules.push(track, current, now) -- kept warm: the fallback when the stream is stale
	end
	local cf = streamPose(streamId, now, ground)
	if cf then
		part.CFrame = cf
		return cf
	end
	cf = Rules.sample(track, now, ground)
	if cf then
		Stream.stats.fallback += 1
	end
	if cf then
		part.CFrame = cf
		return cf
	end
	return written
end

-- Another player's vehicle: the stream pose (blended from and back to the engine's, kept within MAX_OFFSET of it),
-- written as the hull's local CFrame. Render only: the engine restores its replicated pose in its next simulation step.
-- When it has not (the hull still holds exactly last frame's write: PStream.engineOf), the engine pose read last frame
-- stands in and the hand-back offset is not re-measured, so nothing compounds. A hull held anchored by the server, or
-- drawing switched off (workspace attribute SkyRallyRemoteDraw not true: OFF by default since Studio V5A measured
-- noRestore on ~30 % of drawn frames, PlayerStreamRules.drawOn), is handed straight back to the engine.
-- The engine pose is recorded for gameplay reads (PStream.enginePosition: the magnet), never the drawn one.
-- The visual clone path (RemoteCloneRules.step): the real hull is read for the engine's pose and never written; only
-- the clone's own anchored parts move (BulkMoveTo).
local function stepClone(r: Racer, now: number, dt: number)
	local hull = r.hull
	local engineCF = hull.CFrame
	local cf = streamPose(r.streamId, now, false, true)
	local draw, action, cut = RClone.step(r.cstate, { enabled = true, held = hull.Anchored, engine = engineCF, stream = cf, dt = dt })
	if action == "destroy" then
		destroyClone(r)
		PStream.stats.cloneGone += 1
		if cut then
			PStream.stats.cloneCuts += 1
		end
	elseif action == "create" then
		if buildClone(r) then
			PStream.stats.cloneMade += 1
		else
			RClone.reset(r.cstate)
			draw = nil
		end
	end
	local c = r.clone
	if draw and c then
		workspace:BulkMoveTo(c.dsts, RClone.poses(c, engineCF, draw), Enum.BulkMoveMode.FireCFrameChanged)
		RClone.syncLook(c)
		RClone.rehide(r.cloneHidden)
		if r.cstate.w >= 1 then
			PStream.stats.cloneDrawn += 1
		else
			PStream.stats.cloneBlend += 1
		end
	else
		PStream.stats.cloneEngine += 1
	end
end

local function stepRemote(r: Racer, now: number, dt: number)
	local hull = r.hull
	if RClone.on(workspace:GetAttribute(RClone.ATTR)) then
		if r.drawn then
			-- switched from the in-place draw: undo its own last write once, then the clone takes over
			if r.engine and hull.CFrame == r.drawn and not hull.Anchored then
				hull.CFrame = r.engine :: CFrame
			end
			releaseRemote(r)
		end
		stepClone(r, now, dt)
		return
	elseif r.cstate.phase ~= "off" or r.clone then
		destroyClone(r)
		RClone.reset(r.cstate)
	end
	local engineCF, restored = PStream.engineOf(hull.CFrame, r.drawn, r.engine)
	if not restored then
		PStream.stats.noRestore += 1
	end
	if hull.Anchored or not PStream.drawOn(workspace:GetAttribute(PStream.DRAW_ATTR)) then
		if r.drawn and r.engine and hull.CFrame == r.drawn and not hull.Anchored then
			hull.CFrame = r.engine :: CFrame -- switched off mid-race: undo this client's own last write once
		end
		releaseRemote(r)
		PStream.stats.engine += 1
		return
	end
	local cf = streamPose(r.streamId, now, false, true)
	if cf then
		local clamped
		cf, clamped = PStream.clampTo(engineCF, cf)
		if clamped then
			PStream.stats.clamped += 1
		end
	end
	r.blend = PStream.stepBlend(r.blend, cf ~= nil, dt)
	local drawn = PStream.mix(engineCF, cf, r.offset, r.blend)
	if cf then
		if restored or r.offset == nil then
			r.offset = PStream.offsetOf(engineCF, cf)
		end
	elseif r.blend <= 0 then
		r.offset = nil
	end
	if drawn then
		hull.CFrame = drawn
		r.drawn = hull.CFrame
		r.engine = engineCF
		PStream.enginePoses[hull] = { cf = engineCF, at = os.clock() }
		if r.blend >= 1 then
			PStream.stats.drawn += 1
		else
			PStream.stats.blend += 1
		end
	else
		if not restored then
			hull.CFrame = engineCF -- the engine never put its pose back over the last write: leave it at the engine's
		end
		r.drawn, r.engine = nil, nil
		PStream.enginePoses[hull] = nil
		PStream.stats.engine += 1
	end
end

-- Eases the racer's camera-near fade toward its target and writes it to the cached parts when it moved enough.
local function stepFade(r: Racer, camPos: Vector3, camLook: Vector3, ownPos: Vector3?, dt: number)
	if r.own then
		return
	end
	local c = r.clone
	local base = if c then c.root.CFrame else r.hull.CFrame -- what shows: the clone while it stands in
	local target = Rules.fadeTarget(base * r.boxOffset, r.half, camPos, camLook, ownPos)
	r.fade = Rules.approachFade(r.fade, target, dt)
	if Rules.shouldWrite(r.fade, r.fadeApplied) then
		writeFade(r, r.fade)
	end
end

-- Which racers' labels may show this frame: the 3 nearest on screen, none within 24 px of a nearer one. Racers that speak
-- (SpeechUp), the rival (its own flag) and anything off screen are not candidates and take no slot.
-- Runs at LABEL_PICK_INTERVAL (not every frame) and keeps last pick's labels ahead of near-ties (HudLayoutRules.STAY_BIAS).
local LABEL_PICK_INTERVAL = 0.1
local labelClock = 0
local labelAllowed: { [Model]: boolean } = {}

local function chooseLabels(origin: Vector3, cam: Camera?): { [Model]: boolean }
	local allowed: { [Model]: boolean } = {}
	if not cam then
		return allowed
	end
	local cands: { { dist: number, rect: HudLayoutRules.Rect } } = {}
	local models: { Model } = {}
	local stay: { boolean } = {}
	for model, r in racers do
		local gui, text = r.gui, r.text
		if gui and text and not r.own and model:GetAttribute("Rival") ~= true and model:GetAttribute("SpeechUp") ~= true then
			local dist = (r.hull.Position - origin).Magnitude
			if Rules.labelAlpha(dist) * (1 - r.fade) > 0.02 then
				local vp, onScreen = cam:WorldToViewportPoint(PStream.visualOf(r.hull).Position + RacerView.LABEL_OFFSET)
				if onScreen and vp.Z > 0 then
					local w = math.max(60, text.AbsoluteSize.X)
					table.insert(cands, { dist = dist, rect = { x = vp.X - w / 2, y = vp.Y - labelH / 2, w = w, h = labelH } })
					table.insert(models, model)
					stay[#models] = labelAllowed[model] == true
				end
			end
		end
	end
	local shown = HudLayoutRules.pickLabels(cands, RacerView.MAX_LABELS, RacerView.LABEL_GAP, stay)
	for i, model in models do
		allowed[model] = shown[i] == true
	end
	return allowed
end

local function stepLabel(r: Racer, origin: Vector3, dt: number, allowed: boolean)
	local gui, text, outline = r.gui, r.text, r.outline
	if not gui or not text or not outline then
		return
	end
	-- The rival's own flag (RivalBubbles, 0.2 studs higher) already carries its name: a second tag would sit on top of it.
	-- A speaking racer's bubble tab carries the name (SpeechUp), and the label rule keeps three labels at most.
	local target = if r.model:GetAttribute("Rival") == true or r.model:GetAttribute("SpeechUp") == true or not allowed
		then 0
		else Rules.labelAlpha((r.hull.Position - origin).Magnitude) * (1 - r.fade)
	r.shown = Rules.approachAlpha(r.shown, target, dt)
	if target == 0 and r.shown < 0.01 then
		r.shown = 0
	end
	local wantOn = r.shown > 0 and gui:GetAttribute("HudHidden") ~= true -- HudHidden: TrackFlow's battle HUD overlap check
	if gui.Enabled ~= wantOn and r.appliedAlpha >= 0 then
		gui.Enabled = wantOn
	end
	if math.abs(r.shown - r.appliedAlpha) <= 0.02 and not (r.shown == 0 and r.appliedAlpha ~= 0) then
		return
	end
	r.appliedAlpha = r.shown
	local textT, backT = Rules.labelTransparency(r.shown)
	text.TextTransparency = textT
	text.BackgroundTransparency = backT
	outline.Transparency = textT
	if r.bar then
		r.bar.BackgroundTransparency = textT
	end
	gui.Enabled = r.shown > 0 and gui:GetAttribute("HudHidden") ~= true
end

local function step(dt: number)
	scanClock -= dt
	if scanClock <= 0 then
		scanClock = RacerView.SCAN_INTERVAL
		scan()
	end
	-- The render clock, not os.clock(): bots advance by exactly the dt the chase camera and the own vehicle step by.
	local wallNow = os.clock()
	lastFrameWall = wallNow
	frameDt += (math.clamp(dt, 0, 0.5) - frameDt) * 0.05
	local now = Stream.advanceRender(renderClock, dt, wallNow)
	table.clear(heads)
	local own = ownHull()
	local cam = workspace.CurrentCamera
	local origin = if own then own.Position elseif cam then cam.CFrame.Position else Vector3.zero
	-- The camera as last rendered (this step runs first in the frame, before the chase camera moves).
	local camCF = if cam then cam.CFrame else nil
	local ownPos = if own then own.Position else nil
	labelClock -= dt
	if labelClock <= 0 then
		labelClock = LABEL_PICK_INTERVAL
		labelAllowed = chooseLabels(origin, cam)
	end
	local allowed = labelAllowed
	local ownSeen = false
	for model, r in racers do
		if not model.Parent or not r.hull.Parent then
			drop(model)
		else
			if r.smooth then
				r.written = stepSmooth(r.track, r.written, r.hull, now, r.ground, r.streamId)
			elseif r.remote and not r.own then
				stepRemote(r, now, dt)
			end
			if camCF then
				stepFade(r, camCF.Position, camCF.LookVector, ownPos, dt)
			end
			stepLabel(r, origin, dt, allowed[model] ~= false)
			if r.own then
				ownSeen = true
				if youGui and youGui.Adornee ~= r.hull then
					youGui.Adornee = r.hull -- a rebuilt vehicle
				end
				if camCF then
					stepYou(r, camCF.Position)
				end
			end
		end
	end
	if not ownSeen and youGui and youGui.Enabled then
		youGui.Enabled = false
		youAlpha = 0
	end
	for part, pr in props do
		if part.Parent then
			if pr.streamId == nil then
				local sid = part:GetAttribute("StreamId")
				pr.streamId = if type(sid) == "number" then sid else nil
			end
			pr.written = stepSmooth(pr.track, pr.written, part, now, false, pr.streamId)
		end
	end
end

-- This player's own vehicle pose, sent after the vehicle controllers stepped it (RenderPriority Camera + 5: after
-- FlightController's +1 and CarController's +2), stamped with this client's sim time (the sum of the render dt the
-- controllers integrated). Read only: the hull is not touched. Nothing is sent alone on a server, while the hull is
-- anchored (a server hold) or when there is no vehicle.
local sender = PStream.newSender()
local streamRemote: UnreliableRemoteEvent? = nil
local function sendOwn(dt: number)
	local r = streamRemote
	local hull = ownHull()
	if not r or not hull or hull.Anchored or #Players:GetPlayers() < 2 then
		sender.sim += math.max(dt, 0) -- the timeline keeps running (a resumed stream is not a jump in time)
		return
	end
	local b = PStream.senderStep(sender, dt, os.clock(), hull.CFrame)
	if b then
		r:FireServer(b)
		PStream.stats.sent += 1
	end
end

function RacerView.init()
	if initialized then
		return
	end
	initialized = true
	holder()
	scaleLabels(HudMetrics.S())
	HudMetrics.onChanged(function(snap: HudMetrics.Snapshot)
		scaleLabels(snap.metrics.S)
		for _, r in racers do
			if r.gui and r.text then
				r.gui.Size = UDim2.fromOffset(180, labelH + 2)
				r.text.Size = UDim2.fromOffset(0, labelH)
				r.text.TextSize = labelText
			end
		end
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 60)
		local remote = if remotes then remotes:WaitForChild(Stream.REMOTE, 60) else nil
		if remote and remote:IsA("UnreliableRemoteEvent") then
			remote.OnClientEvent:Connect(onStreamPacket)
			streamRemote = remote
		end
	end)
	-- First in the frame: the chase camera, Vfx, bubbles and labels all see the smoothed bot poses.
	RunService:BindToRenderStep("SkyRallyRacerView", Enum.RenderPriority.First.Value, Prof.wrap("SR_RacerView", step))
	RunService:BindToRenderStep("SkyRallyPoseSend", Enum.RenderPriority.Camera.Value + 5, Prof.wrap("SR_PoseSend", sendOwn))
end

return RacerView
