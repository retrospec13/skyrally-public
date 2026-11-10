--!strict
-- M-2 (C11, HUB-BOSS-1 "timed boosts"): while the final boss race runs on the hub loop, each pad named in
-- td.boss.timedPads switches on for `onFor` seconds of every `period`. This loop sets a PadLive attribute on the pad
-- model from workspace:GetServerTimeNow(); CarController, AIRacers and BoostPadFx read it (nil = live, so every other map
-- is unchanged). The pad is dimmed while off by darkening its Neon chevrons, never by swapping a mesh.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FidelityRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FidelityRules"))
local TrackRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TrackRegistry"))

local HubBossPads = {}

local OFF_COLOR = Color3.fromRGB(60, 56, 52)

type PadState = { def: any, model: Instance?, live: boolean?, glow: { [BasePart]: Color3? } }

local token = 0
local states: { PadState } = {}

local function findModel(name: string): Instance?
	local folder = TrackRegistry.getBoostsFolder()
	return if folder then folder:FindFirstChild(name) else nil
end

local function apply(st: PadState, live: boolean)
	local model = st.model
	if not model or not model.Parent then
		st.model = nil
		return
	end
	if st.live == live then
		return
	end
	st.live = live
	model:SetAttribute("PadLive", live)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
			if not live and st.glow[d] == nil then
				st.glow[d] = d.Color
			end
			local orig = st.glow[d]
			if orig then
				d.Color = if live then orig else OFF_COLOR
			end
		end
	end
end

function HubBossPads.stop()
	token += 1
	for _, st in states do
		if st.model and st.model.Parent then
			st.live = nil
			st.model:SetAttribute("PadLive", nil)
			for part, color in st.glow do
				if part.Parent and color then
					part.Color = color
				end
			end
		end
	end
	table.clear(states)
end

-- Starts the loop for a track's boss block; a block without timedPads does nothing.
function HubBossPads.start(td: any)
	HubBossPads.stop()
	local list = if type(td) == "table" and type(td.boss) == "table" then td.boss.timedPads else nil
	if type(list) ~= "table" or #list == 0 then
		return
	end
	for _, def in list do
		table.insert(states, { def = def, model = nil, live = nil, glow = {} })
	end
	token += 1
	local mine = token
	task.spawn(function()
		while token == mine do
			local now = workspace:GetServerTimeNow()
			for _, st in states do
				if not st.model or not st.model.Parent then
					st.model = findModel(st.def.name)
					st.live = nil
				end
				if st.model then
					apply(st, FidelityRules.padLive(now, st.def))
				end
			end
			task.wait(1 / FidelityRules.PAD_LOOP_HZ)
		end
	end)
end

return HubBossPads
