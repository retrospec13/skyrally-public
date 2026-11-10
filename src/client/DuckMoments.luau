--!strict
-- Lost Squeaky Ducks (docs/REMARKABLE.md item 22), client half. server/DuckHunt places one rubber duck per launch map
-- (folder LostDuck under the map root) and saves the find.
-- * A duck this player already holds (player attribute DucksHeld, "DINO-4,SNOW-1") is hidden on this client only, like
--   a held key: others still see theirs.
-- * "DuckFound" (this player): the duck squeaks, hops into the air spinning, squashes and bursts into gold sparkles and
--   confetti; the zone theme drops into the Batch 1 secret stinger (Music.secret "find": chip fanfare, then 6 s of
--   the old-cartridge filter); toast "LOST DUCK n/6". The sixth: "ALL DUCKS HOME! GOLDEN QUACK HORN UNLOCKED"
--   and the Golden Quack itself honks.
-- * "DuckSqueak" (anyone's find): the squeak is heard from the duck by every client nearby.
-- * The Golden Quack horn's sound lives in SoundService.SkyRallySounds.GoldenQuack (GarageModel.HORN_CUES.goldenQuack),
--   created here from the uploaded cue so the Garage horn player can clone it like the other horn samples.
-- QA (Studio): workspace.DuckTest = n plays the find celebration as if it were duck n of 6 (6 = the Golden Quack).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SetPieceRules"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local LocalPlayer = Players.LocalPlayer

local DuckMoments = {}

local TrackFlow: any = nil
local Music: any = nil

local GOLD = Color3.fromRGB(255, 214, 60)

local function heldSet(): { [string]: boolean }
	local out = {}
	local text = LocalPlayer:GetAttribute("DucksHeld")
	if type(text) == "string" then
		for _, id in string.split(text, ",") do
			if id ~= "" then
				out[id] = true
			end
		end
	end
	return out
end

local function duckFolder(): Instance?
	local root = TrackRegistry.getRoot()
	return if root then root:FindFirstChild("LostDuck") else nil
end

local function setHidden(model: Instance, hidden: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = not hidden
		elseif d:IsA("PointLight") then
			d.Enabled = not hidden
		end
	end
end

local function refresh()
	local f = duckFolder()
	if not f then
		return
	end
	local track = f:GetAttribute("DuckTrack")
	setHidden(f, type(track) == "string" and heldSet()[track] == true)
end

-- The celebration: a local stand-in of the duck hops, spins and pops; the real one is hidden from now on.
local function celebrate(pos: Vector3, count: number, golden: boolean)
	local f = duckFolder()
	local real = f and f:FindFirstChildWhichIsA("Model")
	local proxy: Model? = nil
	if real then
		local clone = real:Clone()
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.LocalTransparencyModifier = 0
			end
		end
		clone:SetAttribute("SpinRPM", nil)
		clone.Parent = workspace.CurrentCamera or workspace
		proxy = clone
		if f then
			setHidden(f, true)
		end
	end
	Kit.sfx("duck", "duck_squeak", pos, 1, 1, 260)
	if Music and type(Music.secret) == "function" then
		pcall(Music.secret, "find")
	end
	local base = if proxy then proxy:GetPivot() else CFrame.new(pos)
	Kit.animate(0.9, function(k: number)
		if not proxy then
			return
		end
		local hop = 12 * math.sin(math.pi * math.min(k / 0.75, 1))
		local spin = 4 * math.pi * Rules.smooth(k)
		local squash = 1 + 0.25 * math.sin(k * math.pi * 6) * (1 - k)
		proxy:PivotTo(base * CFrame.new(0, hop, 0) * CFrame.Angles(0, spin, 0))
		proxy:ScaleTo(math.max(0.05, squash * (if k > 0.75 then 1 - (k - 0.75) / 0.25 else 1)))
	end, function()
		if proxy then
			Kit.burst("duck", Kit.up(proxy:GetPivot().Position), 1)
			proxy:Destroy()
		else
			Kit.burst("duck", Kit.up(pos + Vector3.yAxis * 6), 1)
		end
		Kit.sfx("duck2", "duck_squeak", pos + Vector3.yAxis * 8, 0.8, 1.25, 260)
	end)
	if TrackFlow and type(TrackFlow.toast) == "function" then
		pcall(TrackFlow.toast, string.format("LOST DUCK %d/%d", count, #Rules.DUCK_TRACKS), GOLD, 3.5)
	end
	if golden then
		task.delay(2.2, function()
			Kit.ui("quack", "golden_quack", 1, 1)
			Kit.burst("duck", Kit.up(Kit.focus() + Vector3.yAxis * 8), 2)
			if TrackFlow and type(TrackFlow.toast) == "function" then
				pcall(TrackFlow.toast, Rules.duckToast(#Rules.DUCK_TRACKS), GOLD, 5)
			end
		end)
	end
	print(string.format("[SkyRally][SETPIECE] duck found count=%d golden=%s", count, tostring(golden)))
end

-- The Golden Quack's sample, next to SoundJuice's horn samples.
local function ensureHornSound()
	local id = Kit.AUDIO.golden_quack
	if not id then
		return
	end
	task.spawn(function()
		local folder = SoundService:WaitForChild("SkyRallySounds", 30)
		if not folder or folder:FindFirstChild("GoldenQuack") then
			return
		end
		local s = Instance.new("Sound")
		s.Name = "GoldenQuack"
		s.SoundId = id
		s.Volume = 0.8
		s.Parent = folder
	end)
end

function DuckMoments.init(trackFlow: any, music: any)
	TrackFlow = trackFlow
	Music = music
	ensureHornSound()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		local ev = remotes and remotes:WaitForChild("SetPieceEvent", 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(kind: any, payload: any)
				if type(payload) ~= "table" or typeof(payload.pos) ~= "Vector3" then
					return
				end
				if kind == "DuckFound" then
					-- a find queued before the profile loaded reports the old count: never show 0/6
					local count = math.max(1, if type(payload.count) == "number" then payload.count else 1)
					celebrate(payload.pos, count, payload.golden == true)
				elseif kind == "DuckSqueak" and payload.userId ~= LocalPlayer.UserId then
					Kit.sfx("duck_other", "duck_squeak", payload.pos, 0.9, 1, 200)
				end
			end)
		end
	end)
	LocalPlayer:GetAttributeChangedSignal("DucksHeld"):Connect(refresh)
	local function later()
		-- the duck is built after the map is ready; look again a little later
		for _, t in { 1, 4, 9 } do
			task.delay(t, refresh)
		end
	end
	RaceAttr.changed("ActiveTrackId", later)
	RaceAttr.changed("RaceMode", later)
	later()
	workspace:GetAttributeChangedSignal("DuckTest"):Connect(function()
		local n = workspace:GetAttribute("DuckTest")
		if type(n) == "number" then
			workspace:SetAttribute("DuckTest", nil)
			local f = duckFolder()
			local pos = if f and typeof(f:GetAttribute("DuckPos")) == "Vector3" then f:GetAttribute("DuckPos") :: Vector3 else Kit.focus() + Vector3.new(0, 4, -20)
			celebrate(pos, n, n >= #Rules.DUCK_TRACKS)
		end
	end)
end

return DuckMoments
