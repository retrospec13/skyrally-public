--!strict
-- The local finish, in order (REMARKABLE Batch 2 items 23, 24, 30). RaceUI hands its RaceFinished payload here with
-- the function that fills and shows the results card, and this runs the moments around it:
--   1. the photo cam, when the finish was close (client/Polaroid, 1.3 s, only after the local player crossed);
--   2. the podium ceremony with the Participation Crate (client/PodiumCeremony, 4 s; skippable from the second one);
--   3. the results card (RaceUI's own populateFinishModal), with the server-confirmed polaroid pinned on its left edge
--      whenever the server's "PhotoFinish" notice arrives;
--   4. Token Homecoming: a token the server awarded this race pops out of the card's award line and flies into the HUD
--      counter (client/TokenHomecoming; HudExtras holds the count-up from the moment of the finish until it lands).
-- A replay (RaceResetSeq), a reset or a track switch ends the sequence wherever it is; the card is never shown late
-- over a new race.
local Polaroid = require(script.Parent:WaitForChild("Polaroid"))
local PodiumCeremony = require(script.Parent:WaitForChild("PodiumCeremony"))
local TokenHomecoming = require(script.Parent:WaitForChild("TokenHomecoming"))
local HudExtras = require(script.Parent:WaitForChild("HudExtras"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
local FinishLighting = require(script.Parent:WaitForChild("FinishLighting"))
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))

local RunService = game:GetService("RunService")
local CarController = require(script.Parent:WaitForChild("CarController"))
local FlightController = require(script.Parent:WaitForChild("FlightController"))
local FinaleRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FinaleRules"))

local FinishShow = {}

-- v38-feel: the finish swing (MK8). When the photo cam does not take the finish, the chase camera swings round from
-- behind to a low front three-quarter view of the local vehicle while it rolls on by itself (CarController drives a
-- finished car down the route), narrowing to a telephoto. Then the podium cuts in as before.
FinishShow.SWING_SECONDS = 2.3
local swingBound = false

local function myHull(): BasePart?
	if CarController.car and CarController.hull and CarController.hull.Parent then
		return CarController.hull
	end
	local h = FlightController.hull
	return if h and h.Parent then h else nil
end

local function stopSwing()
	if swingBound then
		swingBound = false
		RunService:UnbindFromRenderStep("SkyRallyFinishSwing")
	end
end

local function startSwing(): boolean
	local cam = workspace.CurrentCamera
	local hull = myHull()
	if not cam or not hull then
		return false
	end
	stopSwing()
	local from = cam.CFrame
	local fov0 = cam.FieldOfView
	local side = if math.random() < 0.5 then 1 else -1
	local t0 = os.clock()
	swingBound = true
	RunService:BindToRenderStep("SkyRallyFinishSwing", Enum.RenderPriority.Last.Value + 2, function()
		local h = myHull()
		local c = workspace.CurrentCamera
		if not h or not c then
			return
		end
		local u = math.clamp((os.clock() - t0) / FinishShow.SWING_SECONDS, 0, 1)
		local e = 1 - (1 - u) ^ 3 -- cubic out: a fast swing that settles
		local look = h.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
		local right = flatLook:Cross(Vector3.yAxis)
		-- angle 0 = straight behind, 150 degrees = in front, off to one side
		local ang = math.rad(150 * e) * side
		local dir = -flatLook * math.cos(ang) + right * math.sin(ang)
		local radius = 15 - 4 * e
		local height = 5.2 - 3 * e
		local pos = h.Position + dir * radius + Vector3.yAxis * height
		local goal = CFrame.lookAt(pos, h.Position + Vector3.yAxis * 1.2 + flatLook * (4 * e))
		local blend = math.clamp((os.clock() - t0) / 0.25, 0, 1) -- ease out of the chase frame, never a cut
		c.CameraType = Enum.CameraType.Scriptable
		c.CFrame = from:Lerp(goal, blend)
		c.FieldOfView = fov0 + (52 - fov0) * e
		if blend >= 1 then
			from = goal
		end
	end)
	return true
end

local seq = 0
local hooked = false

local function hook()
	if hooked then
		return
	end
	hooked = true
	for _, attr in { "RaceResetSeq", "TrackSwitching" } do
		RaceAttr.changed(attr, function()
			FinishShow.cancel()
		end)
	end
end

-- RaceUI's RaceFinished: run the sequence; show(payload) fills and shows the results card and returns the card.
function FinishShow.run(payload: any, show: (any) -> GuiObject?)
	hook()
	seq += 1
	local my = seq
	local function alive(): boolean
		return my == seq and workspace:GetAttribute("TrackSwitching") ~= true
	end
	local award = if type(payload) == "table" and type(payload.award) == "table" then payload.award else nil
	local tokenAwarded = award ~= nil and award.tokenResult == "awarded"
	if tokenAwarded then
		HudExtras.holdTokenAward(12) -- the counter waits for the token to fly home after the ceremony
	end
	HudPhase.setFinishing(true) -- HUD phase "finish": no touch pad, lap chip or return countdown over the photo cam
	task.spawn(function()
		local camSeconds = Polaroid.onFinish(payload)
		if camSeconds > 0 then
			task.wait(camSeconds)
		elseif FinaleRules.PHOTO_MODES[tostring(RaceAttr.mine("RaceMode"))] and startSwing() then
			task.wait(FinishShow.SWING_SECONDS)
			stopSwing()
		end
		if not alive() then
			return
		end
		FinishLighting.apply() -- stage lighting from the podium to the results card; restored when the card closes or the sequence ends
		PodiumCeremony.play(payload, alive)
		if not alive() then
			return
		end
		local card = show(payload)
		-- RaceUI only notices the visible card on its next step: hand over to "results" first, or the race HUD (lap chip,
		-- touch pad) shows for a frame between "finish" and "results".
		if card and card.Visible then
			HudPhase.setResultsUp(true)
		end
		HudPhase.setFinishing(false) -- the card is up (phase "results"), or there is none to show
		if card and card.Visible then
			card:GetPropertyChangedSignal("Visible"):Once(function()
				if my == seq then
					FinishLighting.release()
				end
			end)
		else
			FinishLighting.release()
		end
		if card then
			Polaroid.attachTo(card)
			if tokenAwarded then
				task.wait(0.55)
				if alive() and card.Visible then
					TokenHomecoming.flyFromGui((card:FindFirstChild("TokenChip", true) or card:FindFirstChild("OrbRewardBanner")) :: GuiObject?) -- UI v2: the "+1 SKY TOKEN" chip
				else
					HudExtras.releaseTokenAward()
				end
			end
		elseif tokenAwarded then
			HudExtras.releaseTokenAward()
		end
	end)
end

-- The server's photo-finish notice (RaceEventRemote "PhotoFinish").
function FinishShow.onPhotoFinish(data: any)
	Polaroid.onNotice(data)
end

function FinishShow.cancel()
	seq += 1
	stopSwing()
	HudPhase.setFinishing(false)
	FinishLighting.release()
	Polaroid.reset()
	HudExtras.releaseTokenAward() -- a held count never waits for a flight that will not come
end

return FinishShow
