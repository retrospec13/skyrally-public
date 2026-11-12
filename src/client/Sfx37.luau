--!strict
-- The v37 item and race sounds (assets/audio/sfx_v37, ElevenLabs text-to-sound, ids in shared/SfxV37Assets).
--   * Sfx37.play(name, volume?, pitch?)            2D one-shot for the local player
--   * Sfx37.at(name, position, volume?, pitch?)    3D one-shot at a world point (a short-lived Attachment on Terrain)
--   * Sfx37.loopOn(name, parent, volume, maxSeconds, range?) -> Sound?   a looped 3D Sound inside `parent` (an Attachment or
--     Part: it dies with it); fades out after maxSeconds. Owner rule: no droning, so every loop is bounded; at most MAX_LOOPS.
--   * Sfx37.fadeStop(sound, seconds?)              fades a loop out and destroys it
-- Everything goes through the EFFECTS slider (Settings.sfx). A name with no id (or a non-uploaded set) is silent: false/nil.
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ids = require(Shared:WaitForChild("SfxV37Assets")) :: { [string]: string }
local Settings = require(script.Parent:WaitForChild("Settings"))

local Sfx37 = {}

local MAX_LOOPS = 6
local loops: { Sound } = {}
local pool2D: { [string]: { Sound } } = {}
local LENGTH: { [string]: number } = {
	missile_whoosh = 1.0,
	gift_pop = 0.9,
	ice_crack = 1.2,
	rs_charge = 1.5,
	rs_burst = 1.0,
	burnt_sputter = 1.2,
	count_beep = 0.4,
	go_beep = 1.0,
	pos_gain = 0.5,
	pos_loss = 0.5,
	gp_fanfare = 2.8,
	trophy_sting = 1.8,
	tally_tick = 0.5,
	ui_big_confirm = 0.9,
	placement_slam = 0.8,
}

function Sfx37.has(name: string): boolean
	return Ids[name] ~= nil
end

local function folder(): Folder
	local f = SoundService:FindFirstChild("SkyRallySfx37")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallySfx37"
	nf.Parent = SoundService
	return nf
end

function Sfx37.play(name: string, volume: number?, pitch: number?): boolean
	local id = Ids[name]
	if not id then
		return false
	end
	local l: { Sound } = pool2D[name] or {}
	if #l == 0 then
		pool2D[name] = l
		for i = 1, 2 do
			local s = Instance.new("Sound")
			s.Name = name .. "_" .. i
			s.SoundId = id
			Settings.sfx(s)
			s.Parent = folder()
			table.insert(l, s)
		end
	end
	local s = table.remove(l, 1) :: Sound
	table.insert(l, s)
	s.Volume = volume or 0.6
	s.PlaybackSpeed = pitch or 1
	s.TimePosition = 0
	s:Play()
	return true
end

local function rollOff(s: Sound, minD: number, maxD: number)
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = minD
	s.RollOffMaxDistance = maxD
end

-- Stop every pooled 2D voice of `name` at once (v38-feel: the drift charge ends when the drift does).
function Sfx37.stop(name: string)
	local l: { Sound } = pool2D[name] or {}
	for _, s in l do
		if s.IsPlaying then
			s:Stop()
		end
	end
end

function Sfx37.at(name: string, position: Vector3, volume: number?, pitch: number?): boolean
	local id = Ids[name]
	if not id or workspace:GetAttribute("TrackSwitching") == true then
		return false
	end
	local a = Instance.new("Attachment")
	a.Name = "Sfx37At"
	a.WorldPosition = position
	a.Parent = workspace.Terrain
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	s.Volume = volume or 0.6
	s.PlaybackSpeed = pitch or 1
	rollOff(s, 14, 220)
	Settings.sfx(s)
	s.Parent = a
	s:Play()
	Debris:AddItem(a, (LENGTH[name] or 2) / (pitch or 1) + 0.5)
	return true
end

function Sfx37.fadeStop(sound: Sound, seconds: number?)
	for i = #loops, 1, -1 do
		if loops[i] == sound then
			table.remove(loops, i)
		end
	end
	if not sound.Parent then
		return
	end
	local t = TweenService:Create(sound, TweenInfo.new(seconds or 0.25), { Volume = 0 })
	t.Completed:Once(function()
		sound:Destroy()
	end)
	t:Play()
end

function Sfx37.loopOn(name: string, parent: Instance, volume: number, maxSeconds: number, range: number?): Sound?
	local id = Ids[name]
	if not id or not parent.Parent then
		return nil
	end
	for i = #loops, 1, -1 do
		if not loops[i].Parent then
			table.remove(loops, i)
		end
	end
	if #loops >= MAX_LOOPS then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "Sfx37Loop_" .. name
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	rollOff(s, 16, range or 160)
	Settings.sfx(s)
	s.Parent = parent
	s:Play()
	TweenService:Create(s, TweenInfo.new(0.2), { Volume = volume }):Play()
	table.insert(loops, s)
	task.delay(maxSeconds, function()
		if s.Parent then
			Sfx37.fadeStop(s, 0.4)
		end
	end)
	return s
end

-- Loads the files ahead of the first use so the first rocket is not silent while it downloads.
function Sfx37.preload()
	local items: { Instance } = {}
	for _, id in Ids do
		local s = Instance.new("Sound")
		s.SoundId = id
		table.insert(items, s)
	end
	task.spawn(function()
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync(items)
		end)
		for _, s in items do
			s:Destroy()
		end
	end)
end

return Sfx37
