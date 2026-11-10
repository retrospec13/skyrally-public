--!strict
-- The sit pose for this player's own avatar while it rides a vehicle (server/kit/PilotSeat seats it and sets the
-- character attribute PilotSeated). Played here, on the client that owns the character, so it replicates to every
-- other player; Action priority sits over the Animate script's idle. The default Roblox sit animations: R15
-- 2506281703, R6 178130996 (the rig type is read from the Humanoid). Re-checked on every respawn; a track the engine
-- stops while still seated (a rig rebuilt by a late appearance load) is started again.
local Players = game:GetService("Players")

local PilotPose = {}

PilotPose.SIT_R15 = "rbxassetid://2506281703"
PilotPose.SIT_R6 = "rbxassetid://178130996"

local LocalPlayer = Players.LocalPlayer
local initialized = false

local function watch(character: Model)
	local hum = character:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	local animator = hum:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") then
		return
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = if hum.RigType == Enum.HumanoidRigType.R6 then PilotPose.SIT_R6 else PilotPose.SIT_R15
	local track: AnimationTrack? = nil

	local function refresh()
		if character.Parent == nil then
			return
		end
		local want = character:GetAttribute("PilotSeated") == true
		if want then
			if track and track.IsPlaying then
				return
			end
			local ok, t = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			if ok and t then
				t.Priority = Enum.AnimationPriority.Action
				t.Looped = true
				t:Play(0.15)
				track = t
				t.Stopped:Connect(function()
					if track == t and character:GetAttribute("PilotSeated") == true then
						track = nil
						task.defer(refresh)
					end
				end)
			end
		elseif track then
			local t = track
			track = nil
			t:Stop(0.2)
		end
	end

	character:GetAttributeChangedSignal("PilotSeated"):Connect(refresh)
	refresh()
end

function PilotPose.init()
	if initialized then
		return
	end
	initialized = true
	LocalPlayer.CharacterAdded:Connect(function(c: Model)
		task.spawn(watch, c)
	end)
	if LocalPlayer.Character then
		task.spawn(watch, LocalPlayer.Character)
	end
end

return PilotPose
