--!strict
-- Remote players' visual clone (2026-10-20 remote-clone; docs/audits/opponent_stream.md "Visual clone"). Used by
-- client/RacerView and tools/tests/remote_clone_spec.luau.
--
-- Why. Studio V5A (aa6f798) measured the in-place draw (RacerView writing another player's hull's local CFrame) and
-- found the engine did NOT re-apply its replicated pose over that write on ~30 % of drawn frames (noRestore): writing a
-- hull another client owns is not render-only. That path is now off by default (PlayerStreamRules.drawOn).
--
-- The design. While a remote player's pose stream is fresh, this client builds a client-only copy of that player's
-- vehicle and seated avatar: every visible BasePart (and the hull, the root), with only its look kept (meshes, decals,
-- textures, SurfaceAppearance) and no scripts, joints, constraints, attachments, seats that seat, or
-- collisions: anchored, CanCollide / CanQuery / CanTouch false, Massless. The avatar's classic clothing and body
-- colours ride along under a Humanoid that runs no state machine and shows no name. Each frame the clone is drawn at
-- the Hermite stream pose (the same buffer, playhead and blend as before), every clone part placed at its source part's
-- pose in the real hull's space carried onto that pose (so props, wheels, steering and the avatar's animation are
-- mirrored). The real parts are hidden on this client with LocalTransparencyModifier; visual effects riding on the real
-- vehicle (attachments that carry emitters, lights or trails, emitters and billboards straight under a part) are
-- re-parented onto the matching clone part, and so are billboards and SurfaceGuis that show on their parent part; the name label, bubbles and the minimap dot follow the clone
-- (PlayerStreamRules.visualOf). The real physics hull is never written: gameplay (hits, items, magnet, standings,
-- every server check) keeps reading it.
--
-- Lifecycle (step): a stream starts -> the clone is built at the engine's pose and swapped in (same pose: no pop), then
-- blends onto the stream over PlayerStreamRules.BLEND_TIME; the stream stops (gap, hold, out of relay range) -> the
-- clone rides the engine's pose with the last offset fading out and is handed back at weight 0 (same pose again);
-- stream and engine more than CUT apart (a respawn or teleport the two see at different times) -> handed back at once
-- and rebuilt once they agree; the switch off, the player leaving, the vehicle rebuilt -> handed back at once.
local P = require(script.Parent:WaitForChild("PlayerStreamRules"))

local R = {}

R.ATTR = "SkyRallyRemoteClone" -- workspace attribute: exactly true turns the clone on
R.DEFAULT = false -- off until Studio passes (docs/audits/opponent_stream.md, Studio recipe)
R.CUT = P.MAX_OFFSET -- studs between the stream pose and the engine's: past this the real hull shows at once

-- Children kept under a cloned part: its look only.
R.KEEP = {
	SpecialMesh = true,
	BlockMesh = true,
	CylinderMesh = true,
	Decal = true,
	Texture = true,
	SurfaceAppearance = true,
}
-- A character's appearance copied into the pilot clone (the clone's Humanoid applies it to the body parts by name).
R.CHAR_KEEP = { Shirt = true, Pants = true, ShirtGraphic = true, BodyColors = true, CharacterMesh = true }
-- An attachment that carries one of these (or that a Trail or Beam uses) is moved onto the clone while it shows.
R.EFFECTS = {
	ParticleEmitter = true,
	Beam = true,
	Fire = true,
	Smoke = true,
	Sparkles = true,
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
}
-- Parts cloned even while invisible: another client module fades them in (VehicleMotion's prop blur disc is built at
-- Transparency 1 and shown with speed); syncLook mirrors that Transparency onto the counterpart each frame.
R.ALWAYS = { PropDisc = true }
-- Effects that emit from the part they sit straight under (moved with no attachment).
R.PART_EFFECTS = { ParticleEmitter = true, Fire = true, Smoke = true, Sparkles = true }

function R.on(attr: any): boolean
	if type(attr) == "boolean" then
		return attr
	end
	return R.DEFAULT
end

------------------------------------------------------------------------------------------------------------------------
-- Lifecycle

export type State = { phase: string, w: number, offset: CFrame? }

function R.newState(): State
	return { phase = "off", w = 0, offset = nil }
end

function R.reset(st: State)
	st.phase, st.w, st.offset = "off", 0, nil
end

export type Input = {
	enabled: boolean, -- the switch (R.on)
	held: boolean, -- the real hull is anchored (a server hold): no stream is drawn, the clone hands back
	engine: CFrame, -- the real hull's pose as the engine shows it (never written)
	stream: CFrame?, -- this frame's stream pose (nil: no fresh stream)
	dt: number,
}

-- One frame. Returns (the pose to draw the clone's root at, or nil: the real hull shows; the action for the caller:
-- "create" build the clone and swap it in, "destroy" hand back to the real hull, "none"; cut: an instant hand-back).
function R.step(st: State, i: Input): (CFrame?, string, boolean)
	if not i.enabled then
		if st.phase == "on" then
			R.reset(st)
			return nil, "destroy", false
		end
		return nil, "none", false
	end
	local s = if i.held then nil else i.stream
	if s and (s.Position - i.engine.Position).Magnitude > R.CUT then
		if st.phase == "on" then
			R.reset(st)
			return nil, "destroy", true
		end
		return nil, "none", false
	end
	local action = "none"
	if st.phase == "off" then
		if s == nil then
			return nil, "none", false
		end
		st.phase, st.w, st.offset = "on", 0, nil
		action = "create"
	end
	st.w = P.stepBlend(st.w, s ~= nil, i.dt)
	if s then
		st.offset = P.offsetOf(i.engine, s)
	end
	local draw = P.mix(i.engine, s, st.offset, st.w)
	if draw == nil then
		R.reset(st)
		return nil, if action == "create" then "none" else "destroy", false
	end
	return draw, action, false
end

-- The real part's LocalTransparencyModifier after the hand-back: what it held before it was hidden, unless that was
-- RacerView's own camera-near fade (`fadeAtHide`), which has moved on to `fadeNow` meanwhile.
function R.restoreValue(prior: number, fadeAtHide: number, fadeNow: number): number
	if math.abs(prior - fadeAtHide) < 1e-3 then
		return fadeNow
	end
	return prior
end

------------------------------------------------------------------------------------------------------------------------
-- The clone (Instance work only: no physics, no CFrame writes to any source part)

export type Move = { inst: Instance, from: BasePart, to: BasePart? }
export type Clone = {
	model: Model,
	root: BasePart, -- the hull's counterpart (dsts[1]); labels, bubbles and the minimap read it
	srcs: { BasePart }, -- source parts (srcs[1] the real hull), never written
	dsts: { BasePart }, -- their counterparts, the only parts the clone path moves
	cfs: { CFrame }, -- this frame's poses for dsts (poses)
	map: { [Instance]: BasePart }, -- source part -> counterpart
	sources: { [Instance]: BasePart }, -- counterpart -> source part
	visuals: { Instance }, -- counterparts and their decals / textures (the camera-near fade writes these)
	moves: { Move }, -- effects to move onto the clone (to: the counterpart)
	trails: { Instance }, -- Trails whose attachments move (cleared at each swap: no streak across it)
}

-- Whether a source part gets a counterpart: the hull always (the root), never a HumanoidRootPart, else visible parts
-- and parts that carry a moving effect.
function R.cloneable(part: BasePart, hull: BasePart, hasEffects: boolean): boolean
	if part == hull then
		return true
	end
	if part.Name == "HumanoidRootPart" then
		return false
	end
	return part.Transparency < 0.99 or hasEffects or R.ALWAYS[part.Name] == true
end

-- The effects riding on `roots` (the vehicle model and the pilot) that move onto the clone: attachments under a part
-- that carry an EFFECTS child or that a Trail or Beam uses, never one a Constraint uses; PART_EFFECTS, billboards and
-- SurfaceGuis (no Adornee) straight under a part. Returns (moves without `to`, Trails / Beams that use a moving attachment).
function R.effectsOf(roots: { Instance }): ({ Move }, { Instance })
	local all: { Instance } = {}
	for _, root in roots do
		for _, d in root:GetDescendants() do
			table.insert(all, d)
		end
	end
	local users: { [Instance]: { Instance } } = {}
	local constrained: { [Instance]: boolean } = {}
	for _, d in all do
		if d:IsA("Trail") or d:IsA("Beam") then
			for _, a in { (d :: any).Attachment0, (d :: any).Attachment1 } do
				if a then
					users[a] = users[a] or {}
					table.insert(users[a], d)
				end
			end
		elseif d:IsA("Constraint") then
			local a0, a1 = (d :: any).Attachment0, (d :: any).Attachment1
			if a0 then
				constrained[a0] = true
			end
			if a1 then
				constrained[a1] = true
			end
		end
	end
	local moves: { Move } = {}
	local trails: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for _, d in all do
		local parent = d.Parent
		if parent and parent:IsA("BasePart") then
			local move = false
			if d:IsA("Attachment") then
				if not constrained[d] then
					move = users[d] ~= nil
					if not move then
						for _, c in d:GetChildren() do
							if R.EFFECTS[c.ClassName] then
								move = true
								break
							end
						end
					end
					local us = users[d]
					if move and us then
						for _, u in us do
							if not seen[u] then
								seen[u] = true
								table.insert(trails, u)
							end
						end
					end
				end
			elseif R.PART_EFFECTS[d.ClassName] then
				move = true
			elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
				move = (d :: any).Adornee == nil -- shows on its parent part, which LocalTransparencyModifier does not hide
			end
			if move then
				table.insert(moves, { inst = d, from = parent :: BasePart, to = nil })
			end
		end
	end
	return moves, trails
end

local function copy(inst: Instance): Instance
	local was = inst.Archivable
	if not was then
		inst.Archivable = true -- a local property: the Clone() needs it (characters are not archivable)
	end
	local c = inst:Clone()
	if not was then
		inst.Archivable = false
	end
	return c
end

-- Keeps a cloned part's look and drops everything else (scripts, joints, constraints, attachments, effects, sounds,
-- prompts, values, nested parts).
local function strip(part: Instance)
	for _, c in part:GetChildren() do
		if R.KEEP[c.ClassName] then
			for _, d in c:GetDescendants() do
				if d:IsA("LuaSourceContainer") then
					d:Destroy()
				end
			end
		else
			c:Destroy()
		end
	end
end

local function settle(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	if p:IsA("Seat") or p:IsA("VehicleSeat") then
		(p :: any).Disabled = true
	end
end

-- Builds the clone of `model` (and the seated `pilot`) around `hull`, unparented; `make` is Instance.new. Source parts
-- are read and cloned only.
function R.build(model: Instance, pilot: Instance?, hull: BasePart, make: (string) -> any): Clone
	local roots: { Instance } = { model }
	if pilot then
		table.insert(roots, pilot)
	end
	local moves, trails = R.effectsOf(roots)
	local carries: { [Instance]: boolean } = {}
	for _, mv in moves do
		carries[mv.from] = true
	end
	local out = make("Model")
	out.Name = "RemoteClone_" .. model.Name
	local c: Clone = {
		model = out,
		root = nil :: any,
		srcs = {},
		dsts = {},
		cfs = {},
		map = {},
		sources = {},
		visuals = {},
		moves = {},
		trails = trails,
	}
	local function add(src: BasePart, parent: Instance): BasePart
		local dst = copy(src) :: BasePart
		strip(dst)
		settle(dst)
		dst.Parent = parent
		table.insert(c.srcs, src)
		table.insert(c.dsts, dst)
		c.map[src] = dst
		c.sources[dst] = src
		table.insert(c.visuals, dst)
		for _, d in dst:GetDescendants() do
			if d:IsA("Decal") or d:IsA("Texture") then
				table.insert(c.visuals, d)
			end
		end
		return dst
	end
	c.root = add(hull, out)
	for _, d in model:GetDescendants() do
		if d ~= hull and d:IsA("BasePart") and R.cloneable(d, hull, carries[d] == true) then
			add(d, out)
		end
	end
	if pilot then
		local pm = make("Model")
		pm.Name = "Pilot"
		for _, ch in pilot:GetChildren() do
			if R.CHAR_KEEP[ch.ClassName] then
				copy(ch).Parent = pm
			end
		end
		if pilot:FindFirstChildOfClass("Humanoid") then
			local h = make("Humanoid")
			h.EvaluateStateMachine = false
			h.RequiresNeck = false
			h.BreakJointsOnDeath = false
			h.AutomaticScalingEnabled = false -- the parts are copied at their scaled size already
			h.Parent = pm
		end
		for _, d in pilot:GetDescendants() do
			if d:IsA("BasePart") and R.cloneable(d, hull, carries[d] == true) then
				add(d, pm)
			end
		end
		pm.Parent = out
	end
	for _, mv in moves do
		local to = c.map[mv.from]
		if to then
			table.insert(c.moves, { inst = mv.inst, from = mv.from, to = to })
		end
	end
	return c
end

-- Effects that appeared on the real parts since the clone was built (Vfx adds trails and emitters as it needs them):
-- the ones whose part has a counterpart. They are not under the clone yet.
function R.newMoves(c: Clone, roots: { Instance }): { Move }
	local moves = R.effectsOf(roots)
	local out: { Move } = {}
	for _, mv in moves do
		local to = c.map[mv.from]
		if to then
			table.insert(out, { inst = mv.inst, from = mv.from, to = to })
		end
	end
	return out
end

-- This frame's clone poses (into c.cfs): each source part's pose in the real hull's space (`hullCF`, read, never
-- written) carried onto `draw`. The root (the hull's counterpart) is `draw` itself.
function R.poses(c: Clone, hullCF: CFrame, draw: CFrame): { CFrame }
	local cfs = c.cfs
	cfs[1] = draw
	for i = 2, #c.srcs do
		cfs[i] = draw * hullCF:ToObjectSpace(c.srcs[i].CFrame)
	end
	for i = #c.srcs + 1, #cfs do
		cfs[i] = nil
	end
	return cfs
end

-- Mirrors each source part's Transparency onto its counterpart (VehicleMotion fades the prop disc with speed; a part
-- another module hides or shows by Transparency follows). Reads sources, writes only clone parts. Returns the writes.
function R.syncLook(c: Clone): number
	local n = 0
	for i, src in c.srcs do
		local dst = c.dsts[i]
		if dst and src.Transparency ~= dst.Transparency then
			dst.Transparency = src.Transparency
			n += 1
		end
	end
	return n
end

-- Keeps the real parts hidden while the clone shows: another module that put a part back (Cosmetics' emote ends with
-- LocalTransparencyModifier = 0 on the real mesh) would leave a ghost at the engine's pose. `hidden` is RacerView's
-- cloneHidden (part -> what it held before); the prior values are kept for the hand-back. Returns the parts re-hidden.
function R.rehide(hidden: { [Instance]: number }): number
	local n = 0
	for inst in hidden do
		local part = inst :: any
		if inst.Parent and part.LocalTransparencyModifier ~= 1 then
			part.LocalTransparencyModifier = 1
			n += 1
		end
	end
	return n
end

return R
