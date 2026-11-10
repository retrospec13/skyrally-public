--!strict
-- Display copies of racers' vehicles for the Batch 2 payoffs (REMARKABLE items 23, 27, 30): the photo-finish polaroid,
-- the Garage turntable and the podium ceremony show the REAL cars (liveries, trails' owners, bots' colours) without
-- touching them. A copy is a client-only clone with every script, sound, emitter, constraint, light and GUI stripped,
-- every part anchored and non-colliding, the racer attributes cleared (nothing else on the client mistakes it for a
-- racer), levelled, sitting with its lowest point on y = 0 at the origin and facing -Z. Built once per moment, never per
-- frame.
local Players = game:GetService("Players")

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

-- A levelled display copy of `model` (see the header), scaled down when its longest side is over maxExtent.
-- Returns the copy and its bounding size, or nil when the model cannot be cloned.
function DisplayCars.copy(model: Model, maxExtent: number?): (Model?, Vector3)
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
