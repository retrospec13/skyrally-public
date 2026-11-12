--!strict
-- Display copies of racers' vehicles for the Batch 2 payoffs (REMARKABLE items 23, 27, 30): the photo-finish polaroid,
-- the Garage turntable and the podium ceremony show the REAL cars (liveries, trails' owners, bots' colours) without
-- touching them. A copy is a client-only clone with every script, sound, emitter, constraint, light and GUI stripped,
-- every part anchored and non-colliding, the racer attributes cleared (nothing else on the client mistakes it for a
-- racer), levelled, sitting with its lowest point on y = 0 at the origin and facing -Z. Built once per moment, never per
-- frame. withPilot (podium, v38-flow) seats the owner's avatar in the copy (see addPilot).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DisplayCars = {}

local STRIP = {
	"BaseScript",
	"Sound",
	"ParticleEmitter",
	"Trail",
	"Beam",
	"Fire",
	"Smoke",
	"Sparkles",
	"Constraint",
	"Light",
	"BillboardGui",
	"SurfaceGui",
	"ProximityPrompt",
	"Highlight",
	"ForceField",
	"BodyMover",
	"JointInstance",
	"WeldConstraint",
	"Humanoid",
}
local CLEAR_ATTRS = { "OwnerUserId", "OwnerName", "BotName", "BotId", "IsBoss", "BossZone", "SpinningOut", "TrickSpin", "GridHop" }

local function planes(): Instance?
	return workspace:FindFirstChild("Planes")
end

-- A racer's live model by its standings name (players by Name, bots by BotName), or nil.
function DisplayCars.findRacer(name: string, isPlayer: boolean?): Model?
	local folder = planes()
	if not folder then
		return nil
	end
	local uid: number? = nil
	if isPlayer ~= false then
		local p = Players:FindFirstChild(name)
		if p and p:IsA("Player") then
			uid = p.UserId
		end
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			if uid and m:GetAttribute("OwnerUserId") == uid then
				return m
			end
			if isPlayer ~= true and m:GetAttribute("BotName") == name then
				return m
			end
		end
	end
	return nil
end

function DisplayCars.localVehicle(): Model?
	local folder = planes()
	if not folder then
		return nil
	end
	local me = Players.LocalPlayer
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == me.UserId then
			return m
		end
	end
	return nil
end

local function stripped(inst: Instance): boolean
	for _, cls in STRIP do
		if inst:IsA(cls) then
			return true
		end
	end
	return false
end


------------------------------------------------------------------------------------------------ the pilot (v38-flow)
-- A player's avatar rides welded to the hull but is NOT a child of the vehicle model (server/kit/PilotSeat), so a plain
-- clone of a player's car is an empty cockpit: the podium showed the car and no driver (owner bug, 2026-11-10). copy()
-- with withPilot clones the owner's character into the copy (bots already carry their "Pilot" child). The clone keeps
-- its Humanoid, Animator and Motor6Ds (so DisplayCars.pose can play the sit pose and a celebration on it), drops scripts,
-- sounds, effects and any weld to the live vehicle, and anchors only its root. No character, or one not loaded yet:
-- waits up to PILOT_WAIT for it, then falls back to a bot's pilot (a neutral rig) so the seat is never empty.
DisplayCars.PILOT_WAIT = 2.5
local SIT_R15 = "rbxassetid://2506281703" -- Roblox default R15 sit (client/PilotPose)
local SIT_R6 = "rbxassetid://178130996"
-- Celebrations are drawn on the pilot's own shoulder joints (no extra animation asset: only the ledgered sit pose
-- is loaded). cheer = both arms pumping overhead, wave = the right arm waving, point = a small right-arm wave.
DisplayCars.EMOTES = { cheer = true, wave = true, point = true } :: { [string]: boolean }

local PILOT_STRIP = { "BaseScript", "Sound", "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "Light",
	"BillboardGui", "SurfaceGui", "ProximityPrompt", "Highlight", "ForceField", "BodyMover", "Tool" }

local function seatPartOf(vehicle: Model): BasePart?
	local body = vehicle:FindFirstChild("BodyRoot")
	if body and body:IsA("BasePart") then
		return body
	end
	local hull = vehicle:FindFirstChild("Hull")
	return if hull and hull:IsA("BasePart") then hull else vehicle.PrimaryPart
end

local function anchorOf(vehicle: Model): (CFrame, number)
	local a = vehicle:GetAttribute("SeatAnchor")
	local sc = vehicle:GetAttribute("PilotScale")
	return (if typeof(a) == "CFrame" then a else CFrame.new(0, 1.35, 0.2)), (if type(sc) == "number" and sc > 0 then sc else 0.65)
end

-- A clone of a rig (a character or a bot pilot) ready to sit in a display copy, or nil.
local function rigClone(rig: Model): Model?
	local was = rig.Archivable
	rig.Archivable = true
	local ok, c = pcall(function()
		return rig:Clone()
	end)
	rig.Archivable = was
	if not ok or not c then
		return nil
	end
	local clone = c :: Model
	for _, d in clone:GetDescendants() do
		local drop = false
		for _, cls in PILOT_STRIP do
			if d:IsA(cls) then
				drop = true
				break
			end
		end
		if not drop and (d:IsA("JointInstance") or d:IsA("WeldConstraint")) then
			-- a weld to the live vehicle (PilotWeld) would drag the real car; keep only joints inside the rig
			local a, b = (d :: any).Part0, (d :: any).Part1
			drop = (a ~= nil and not a:IsDescendantOf(clone)) or (b ~= nil and not b:IsDescendantOf(clone))
		elseif not drop and d:IsA("Constraint") then
			-- the avatar joint upgrade rigs with AnimationConstraints (+ ball sockets): keep those inside the rig,
			-- drop anything tied to something outside it
			local c = d :: Constraint
			local a0, a1 = c.Attachment0, c.Attachment1
			drop = (a0 ~= nil and not a0:IsDescendantOf(clone)) or (a1 ~= nil and not a1:IsDescendantOf(clone))
		end
		if drop then
			d:Destroy()
		end
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		clone:Destroy()
		return nil
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d == root
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.LocalTransparencyModifier = 0
		end
	end
	root.Transparency = 1
	local hum = clone:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.PlatformStand = true
		hum.RequiresNeck = false
		hum.BreakJointsOnDeath = false
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		end)
		if not hum:FindFirstChildOfClass("Animator") then
			Instance.new("Animator").Parent = hum
		end
	end
	clone.PrimaryPart = root
	clone.Name = "DisplayPilot"
	return clone
end

-- The rig that should sit in `vehicle`: its owner's character (waited for briefly), else any bot's pilot.
local function pilotRig(vehicle: Model): (Model?, boolean)
	local uid = vehicle:GetAttribute("OwnerUserId")
	if type(uid) ~= "number" then
		return nil, false -- a bot: its own Pilot child came along with the vehicle clone
	end
	local p = Players:GetPlayerByUserId(uid)
	local t0 = os.clock()
	while p and os.clock() - t0 < DisplayCars.PILOT_WAIT do
		local ch = p.Character
		if ch and ch:FindFirstChild("HumanoidRootPart") and ch:FindFirstChild("Head") and ch:FindFirstChildOfClass("Humanoid") then
			return ch, true
		end
		task.wait(0.1)
	end
	local folder = planes()
	local kids: { Instance } = if folder then folder:GetChildren() else {}
	for _, m in kids do
		local pilot = m:FindFirstChild("Pilot")
		if pilot and pilot:IsA("Model") and pilot:FindFirstChild("HumanoidRootPart") then
			return pilot, false
		end
	end
	return nil, false
end

-- Puts a pilot clone into `clone` (the vehicle copy, still where the live vehicle stands). Seated pilots keep their live
-- place; anything else is set on the seat anchor at the vehicle's pilot scale.
local function addPilot(live: Model, clone: Model): boolean
	if clone:FindFirstChild("Pilot") then
		return true -- a bot: already seated
	end
	local rig, isOwner = pilotRig(live)
	if not rig then
		return false
	end
	local pc = rigClone(rig)
	if not pc then
		return false
	end
	local seat = seatPartOf(clone)
	local anchor, scale = anchorOf(live)
	local root = pc.PrimaryPart :: BasePart
	local seatedLive = isOwner and rig:GetAttribute("PilotSeated") == true and seat ~= nil
		and (root.Position - (seat :: BasePart).Position).Magnitude < 12
	if not seatedLive then
		if math.abs(pc:GetScale() - scale) > 1e-3 then
			pcall(function()
				pc:ScaleTo(scale)
			end)
		end
		if seat then
			pc:PivotTo(seat.CFrame * anchor)
		end
	end
	pc.Parent = clone
	return true
end

-- pose(copy, nil): the sit pose (looped). pose(copy, kind): adds a celebration (EMOTES key) over it.
-- Safe on a copy with no animatable pilot (bots' frozen pilots): does nothing.
function DisplayCars.pose(copy: Model, kind: string?)
	local pilot = copy:FindFirstChild("DisplayPilot")
	local hum = pilot and pilot:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not hum or not animator then
		return
	end
	local function play(id: string, prio: Enum.AnimationPriority, looped: boolean, speed: number?)
		local a = Instance.new("Animation")
		a.AnimationId = id
		local ok, t = pcall(function()
			return (animator :: Animator):LoadAnimation(a)
		end)
		if ok and t then
			t.Priority = prio
			t.Looped = looped
			t:Play(0.15, 1, speed or 1)
		end
	end
	local r6 = hum.RigType == Enum.HumanoidRigType.R6
	if not kind then
		play(if r6 then SIT_R6 else SIT_R15, Enum.AnimationPriority.Action, true)
		return
	end
	if not DisplayCars.EMOTES[kind] then
		return
	end
	-- A shoulder is a Motor6D (classic rigs: rotate C0) or, with the avatar joint upgrade, an AnimationConstraint (rotate
	-- its Attachment0, the same frame C0 was). Either way the edit composes with the playing sit pose.
	type Joint = { get: () -> CFrame, set: (CFrame) -> () }
	local function joint(name: string): Joint?
		for _, d in (pilot :: Model):GetDescendants() do
			if d.Name == name and d:IsA("Motor6D") then
				local m = d
				return { get = function() return m.C0 end, set = function(cf: CFrame) m.C0 = cf end }
			elseif d.Name == name and d:IsA("AnimationConstraint") and d.Attachment0 then
				local at = d.Attachment0 :: Attachment
				return { get = function() return at.CFrame end, set = function(cf: CFrame) at.CFrame = cf end }
			end
		end
		return nil
	end
	local right = joint(if r6 then "Right Shoulder" else "RightShoulder")
	local left = joint(if r6 then "Left Shoulder" else "LeftShoulder")
	print(string.format("[SkyRally][PODIUM] pose %s rig=%s right=%s left=%s", kind, hum.RigType.Name, tostring(right ~= nil), tostring(left ~= nil)))
	local base: { [Joint]: CFrame } = {}
	for _, m in { right, left } do
		if m then
			base[m] = m.get()
		end
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not copy.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local t = os.clock() - t0
		local up = math.min(1, t / 0.25) -- raise the arm(s) first
		local swing = math.sin(t * (if kind == "cheer" then 9 else 7))
		-- R15 shoulder: rotating about the joint's Z lifts the arm sideways; X swings it forward.
		if right and base[right] then
			local lift = up * (if kind == "point" then 1.6 else 2.6)
			local wave = if kind == "cheer" then 0.25 * swing else 0.45 * swing
			right.set(base[right] * CFrame.Angles(0, 0, lift + wave))
		end
		if left and base[left] and kind == "cheer" then
			left.set(base[left] * CFrame.Angles(0, 0, -(up * 2.6 + 0.25 * swing)))
		end
	end)
end

-- A levelled display copy of `model` (see the header), scaled down when its longest side is over maxExtent.
-- Returns the copy and its bounding size, or nil when the model cannot be cloned.
function DisplayCars.copy(model: Model, maxExtent: number?, withPilot: boolean?): (Model?, Vector3)
	local wasArchivable = model.Archivable
	model.Archivable = true
	local ok, c = pcall(function()
		return model:Clone()
	end)
	model.Archivable = wasArchivable
	if not ok or not c then
		return nil, Vector3.zero
	end
	local clone = c :: Model
	for _, d in clone:GetDescendants() do
		if stripped(d) then
			d:Destroy()
		end
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.LocalTransparencyModifier = 0
		end
	end
	if withPilot then
		addPilot(model, clone) -- before the levelling: the pilot moves and scales with the vehicle
	end
	for _, a in CLEAR_ATTRS do
		clone:SetAttribute(a, nil)
	end
	clone.Name = "Display_" .. model.Name
	-- Level the copy: the hull (the pivot) at the identity orientation is the vehicle sitting flat facing -Z, so cars
	-- lose a slope's pitch and planes their bank. (A model without a PrimaryPart keeps its own pivot.)
	clone:PivotTo(CFrame.new())
	local _, size = clone:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if maxExtent and longest > maxExtent and longest > 0 then
		pcall(function()
			clone:ScaleTo(maxExtent / longest)
		end)
	end
	local bbCf, bbSize = clone:GetBoundingBox()
	clone:PivotTo(CFrame.new(-bbCf.Position.X, bbSize.Y / 2 - bbCf.Position.Y, -bbCf.Position.Z) * clone:GetPivot())
	clone:SetAttribute("DisplayBase", clone:GetPivot())
	return clone, bbSize
end

-- Places a display copy so its base centre sits on `cf` (facing cf.LookVector).
function DisplayCars.place(copy: Model, cf: CFrame)
	local base = copy:GetAttribute("DisplayBase")
	copy:PivotTo(cf * (if typeof(base) == "CFrame" then base else CFrame.new()))
end

return DisplayCars
