--!strict
-- Pooled one-shot sounds for the Batch 2 payoffs (REMARKABLE items 20, 23, 24, 27, 30): Portal Plunge, the photo
-- finish, Token Homecoming, the Garage turntable and the podium ceremony. 2D UI-style sounds under
-- SoundService.SkyRallyPayoffs, a round-robin pool of POOL voices per cue, so a burst of triggers never stacks or
-- allocates per call after the first.
--
-- Ids: the synthesised cues (tools/audio/synth_payoffs.py, prep_payoffs.sh) land in shared/PayoffAudio when uploaded
-- (tools/vfx/upload_set.py). AudioAssets, TrickAudio and UiAudioAssets are read first, so a cue can borrow an existing
-- upload by name (hop_boing). A cue with no id is silent: nothing is created and one log line total is printed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local PayoffSound = {}

local POOL = 2
PayoffSound.VOLUMES = {
	portal_suck = 0.7,
	portal_plunge = 0.75,
	portal_spit = 0.85,
	portal_cancel = 0.55,
	iris_open = 0.5,
	portal_wake = 0.8,
	token_whoosh = 0.6,
	token_land = 0.75,
	photo_shutter = 0.9,
	photo_develop = 0.5,
	podium_drop = 0.65,
	confetti_pop = 0.6,
	crate_whistle = 0.5,
	crate_thud = 0.8,
	crate_kazoo = 0.7,
	drumroll = 0.55,
	garage_rev = 0.6,
	garage_redline = 0.65,
	garage_honk = 0.6,
	garage_paint = 0.55,
	hop_boing = 0.5,
	tier_up_sting = 0.5, -- Creator Store (shared/ToolboxAudio): NotifySpec shard_tier_up
	badge_chime = 0.5, -- Creator Store: NotifySpec badge_earned
} :: { [string]: number }

local ids: { [string]: string } = {}
local loaded = false
local warned = false
local folder: Folder? = nil
local pools: { [string]: { list: { Sound }, nextIndex: number } } = {}

local function loadIds()
	if loaded then
		return
	end
	loaded = true
	for _, name in { "AudioAssets", "TrickAudio", "UiAudioAssets", "ToolboxAudio", "PayoffAudio" } do
		local mod = Shared:FindFirstChild(name)
		if mod and mod:IsA("ModuleScript") then
			local ok, t = pcall(require, mod)
			if ok and type(t) == "table" then
				for k, v in t :: { [string]: any } do
					if type(k) == "string" and type(v) == "string" then
						ids[k] = v
					end
				end
			end
		end
	end
end

function PayoffSound.has(cue: string): boolean
	loadIds()
	return ids[cue] ~= nil
end

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = SoundService:FindFirstChild("SkyRallyPayoffs")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyPayoffs"
	nf.Parent = SoundService
	folder = nf
	return nf
end

local function voice(cue: string): Sound?
	loadIds()
	local id = ids[cue]
	if not id then
		if not warned then
			warned = true
			print("[SkyRally][PAYOFF] payoff sounds not uploaded yet (first missing: " .. cue .. "); these moments run silent")
		end
		return nil
	end
	local pool = pools[cue]
	if not pool then
		local list: { Sound } = {}
		for i = 1, POOL do
			local s = Instance.new("Sound")
			s.Name = cue .. "_" .. i
			s.SoundId = id
			s.Volume = PayoffSound.VOLUMES[cue] or 0.6
			s.Parent = ensureFolder()
			table.insert(list, s)
		end
		pool = { list = list, nextIndex = 1 }
		pools[cue] = pool
	end
	local p = pool :: { list: { Sound }, nextIndex: number }
	local s = p.list[p.nextIndex]
	p.nextIndex = p.nextIndex % #p.list + 1
	return s
end

-- Plays `cue` once (pitch = PlaybackSpeed, volume = a multiplier on the cue's mix level). Returns the Sound or nil.
function PayoffSound.play(cue: string, pitch: number?, volume: number?): Sound?
	local s = voice(cue)
	if not s then
		return nil
	end
	s.PlaybackSpeed = pitch or 1
	s.Volume = (PayoffSound.VOLUMES[cue] or 0.6) * (volume or 1)
	s.TimePosition = 0
	s:Play()
	return s
end

-- Stops every voice of `cue` (a cancelled warp cuts its suck).
function PayoffSound.stop(cue: string)
	local p = pools[cue]
	if p then
		for _, s in p.list do
			s:Stop()
		end
	end
end

return PayoffSound
