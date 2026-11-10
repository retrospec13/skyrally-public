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

local FinishShow = {}

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
					TokenHomecoming.flyFromGui(card:FindFirstChild("OrbRewardBanner") :: GuiObject?)
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
	HudPhase.setFinishing(false)
	FinishLighting.release()
	Polaroid.reset()
	HudExtras.releaseTokenAward() -- a held count never waits for a flight that will not come
end

return FinishShow
