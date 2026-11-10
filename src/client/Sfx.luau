--!strict
-- The sfx_v2 cue player (assets/audio/sfx_v2, ids in shared/SfxV2Audio, rules and per-cue table in shared/SfxRules).
--   * Sfx.play(role, pitch?, volume?)           2D one-shot for the local player, a pool of POOL_SIZE Sounds per role
--   * Sfx.play3D(role, part, volume?, pitch?)   3D one-shot on a part (another racer's hull): one Sound per part and role
--   * Sfx.at(role, position, volume?, pitch?)   3D one-shot at a world point, on a small pool of Attachments on Terrain
--   * Sfx.loop3D(role, part, volume?) -> Sound? a looped 3D Sound parented to the part (dies with it); Sfx.stop(sound)
-- Every Sound goes through the EFFECTS slider (Settings.sfx). `volume` is the final Sound.Volume (default: the cue's
-- suggested volume from SfxRules); `pitch` is the base PlaybackSpeed, to which the cue's own random spread is added.
-- Bounded: at most SfxRules.MAX_VOICES one-shots at once (the lowest priority is dropped first), SfxRules.MAX_LOOPS loops,
-- a per-cue cooldown, and 3D cues beyond their roll-off or under the TrackSwitching curtain never start. A cue with no
-- uploaded id is silent and every player returns false, so a caller can keep an older sound as the fallback.
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("SfxRules"))
local Ids = require(Shared:WaitForChild("SfxV2Audio")) :: any
local Settings = require(script.Parent:WaitForChild("Settings"))

local Sfx = {}

local POOL_SIZE = 3
local ATTACHMENT_POOL = 6

local folder: Folder? = nil
local pools: { [string]: { list: { Sound }, nextIndex: number } } = {}
local voices: { Rules.Voice } = {}
local loops: { Sound } = {}
local lastAt: { [string]: number } = {}
local attachments: { Attachment } = {}
local attachmentBusy: { number } = {} -- os.clock() each attachment is free again
local nextAttachment = 1
local preloaded = false

local function idFor(role: string): string?
	local id = Ids[role]
	if type(id) == "string" and id ~= "" and Rules.ROLES[role] then
		return id
	end
	return nil
end

function Sfx.has(role: string): boolean
	return idFor(role) ~= nil
end

-- A reduced volume for a racer that is not the local player.
function Sfx.quiet(volume: number): number
	return Rules.otherVolume(volume)
end

-- Loads the cue files once, ahead of the first race, so the first boost or crash is not silent while it downloads.
function Sfx.preload()
	if preloaded then
		return
	end
	preloaded = true
	local items: { Instance } = {}
	for role in Rules.ROLES do
		local id = idFor(role)
		if id then
			local s = Instance.new("Sound")
			s.SoundId = id
			table.insert(items, s)
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(items)
		end)
		for _, s in items do
			s:Destroy()
		end
	end)
end

local function soundFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = SoundService:FindFirstChild("SkyRallySfxV2")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallySfxV2"
	nf.Parent = SoundService
	folder = nf
	return nf
end

local function cameraDistance(position: Vector3): number
	local cam = workspace.CurrentCamera
	return if cam then (cam.CFrame.Position - position).Magnitude else 0
end

-- The engine reports a finished Sound as Playing for a frame or two: hold its voice that much longer so the cap of 12
-- counts what is still audible (a 4 s flood saw 13 alive in ~2% of frames without it).
local END_MARGIN = 0.08

-- Gate for one play: cooldown, then a voice from the limiter (stopping the one it evicts). Records the voice.
local function claim(role: string, snd: Sound, pitch: number): boolean
	local now = os.clock()
	if not Rules.cooldownOk(role, now, lastAt[role]) then
		return false
	end
	local def = Rules.ROLES[role]
	-- The same Sound restarting frees its old voice.
	for i = #voices, 1, -1 do
		if voices[i].snd == snd then
			table.remove(voices, i)
		end
	end
	local ok, steal = Rules.admit(voices, now, def.priority)
	if not ok then
		return false
	end
	if steal then
		local victim = voices[steal].snd :: Sound
		table.remove(voices, steal)
		victim:Stop()
	end
	table.insert(voices, { priority = def.priority, startedAt = now, endsAt = now + Rules.duration(role, pitch) + END_MARGIN, snd = snd })
	lastAt[role] = now
	return true
end

local function setup3D(snd: Sound, role: string)
	local minDist, maxDist = Rules.rollOff(role)
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMinDistance = minDist
	snd.RollOffMaxDistance = maxDist
end

local function fire(snd: Sound, role: string, pitch: number, volume: number?)
	snd.Volume = volume or Rules.ROLES[role].volume
	snd.PlaybackSpeed = pitch
	snd.TimePosition = 0
	snd:Play()
end

-- Finds or makes the one Sound a parent holds for a role.
local function soundOn(parent: Instance, role: string, id: string): Sound
	local name = "Sfx_" .. role
	local found = parent:FindFirstChild(name)
	if found and found:IsA("Sound") then
		return found
	end
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	setup3D(s, role)
	Settings.sfx(s)
	s.Parent = parent
	return s
end

-- A 2D cue for this player. False when the cue has no id, is cooling down or lost the voice limiter.
function Sfx.play(role: string, pitch: number?, volume: number?): boolean
	local id = idFor(role)
	if not id then
		return false
	end
	local p = pools[role]
	if not p then
		local list: { Sound } = {}
		local parent = soundFolder()
		for i = 1, POOL_SIZE do
			local snd = Instance.new("Sound")
			snd.Name = role .. "_" .. i
			snd.SoundId = id
			Settings.sfx(snd)
			snd.Parent = parent
			table.insert(list, snd)
		end
		p = { list = list, nextIndex = 1 }
		pools[role] = p
	end
	local s = p.list[p.nextIndex]
	local rate = Rules.pitch(role, pitch, math.random())
	if not claim(role, s, rate) then
		return false
	end
	p.nextIndex = p.nextIndex % #p.list + 1
	fire(s, role, rate, volume)
	return true
end

-- Whether a 3D cue at this point is worth a voice: not under the curtain, and inside its roll-off.
local function worthIt(role: string, position: Vector3): boolean
	if workspace:GetAttribute("TrackSwitching") == true then
		return false
	end
	return Rules.audible(role, cameraDistance(position))
end

-- A 3D cue on a part (another racer's hull): one Sound per part and cue, made on first use, gone with the part.
function Sfx.play3D(role: string, part: BasePart, volume: number?, pitch: number?): boolean
	local id = idFor(role)
	if not id or not worthIt(role, part.Position) then
		return false
	end
	local s = soundOn(part, role, id)
	local rate = Rules.pitch(role, pitch, math.random())
	if not claim(role, s, rate) then
		return false
	end
	fire(s, role, rate, volume)
	return true
end

-- The next Attachment on Terrain: one whose last cue has finished, else the one that has been busy longest.
local function pickAttachment(now: number): (Attachment, number)
	local choice = nil
	for i = 1, ATTACHMENT_POOL do
		local a = attachments[i]
		if not a or not a.Parent then
			local na = Instance.new("Attachment")
			na.Name = "SfxAt" .. i
			na.Parent = workspace.Terrain
			attachments[i] = na
			attachmentBusy[i] = 0
			a = na
		end
		if attachmentBusy[i] <= now then
			choice = i
			break
		end
	end
	if not choice then
		choice = nextAttachment
		nextAttachment = nextAttachment % ATTACHMENT_POOL + 1
	end
	return attachments[choice], choice
end

-- A 3D cue at a world point (a blast, a dropped trap): a pooled Attachment on Terrain carries the Sound.
function Sfx.at(role: string, position: Vector3, volume: number?, pitch: number?): boolean
	local id = idFor(role)
	if not id or not worthIt(role, position) then
		return false
	end
	local now = os.clock()
	local att, index = pickAttachment(now)
	local s = soundOn(att, role, id)
	local rate = Rules.pitch(role, pitch, math.random())
	if not claim(role, s, rate) then
		return false
	end
	att.WorldPosition = position
	attachmentBusy[index] = now + Rules.duration(role, rate)
	fire(s, role, rate, volume)
	return true
end

-- A looped 3D Sound parented to `part`, so it ends with the part. Nil when the cue has no id or the loop budget is
-- spent. The caller sets Volume to fade it and calls Sfx.stop when the thing it follows goes away early.
function Sfx.loop3D(role: string, part: BasePart, volume: number?): Sound?
	local id = idFor(role)
	if not id then
		return nil
	end
	for i = #loops, 1, -1 do
		if loops[i].Parent == nil then
			table.remove(loops, i)
		end
	end
	if #loops >= Rules.MAX_LOOPS then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "SfxLoop_" .. role
	s.SoundId = id
	s.Looped = true
	s.Volume = volume or Rules.ROLES[role].volume
	setup3D(s, role)
	Settings.sfx(s)
	s.Parent = part
	s:Play()
	table.insert(loops, s)
	return s
end

function Sfx.stop(loop: Sound?)
	if loop then
		loop:Stop()
		loop:Destroy()
	end
end

return Sfx
