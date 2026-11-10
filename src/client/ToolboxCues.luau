--!strict
-- Plays the Creator Store sounds (shared/ToolboxAudio, mix in shared/ToolboxAudioRules): 2D one-shots, positional one-shots and
-- one named loop at a time per owner. Everything goes through the EFFECTS group (Settings.sfx). Budget for a phone: two pooled
-- 2D voices and two pooled positional voices per cue, one emitter Part pair, loops only on request. A cue without an id
-- is silent (one log line).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ids = require(Shared:WaitForChild("ToolboxAudio")) :: { [string]: string }
local Rules = require(Shared:WaitForChild("ToolboxAudioRules"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local ToolboxCues = {}

local POOL = 2
type Pool = { list: { Sound }, nextIndex: number }
local pools2D: { [string]: Pool } = {}
local emitters: { Part } = {}
local emitterNext = 1
local loops: { [string]: Sound } = {}
local loopPart: Part? = nil
local logged: { [string]: boolean } = {}

local function folder(): Folder
	local f = SoundService:FindFirstChild("SkyRallyToolbox")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "SkyRallyToolbox"
	nf.Parent = SoundService
	return nf
end

local function emitterPart(name: string): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Parent = workspace
	return p
end

local function newSound(cue: string, parent: Instance, spatial: boolean): Sound?
	local id = Ids[cue]
	if not id then
		if not logged[cue] then
			logged[cue] = true
			print("[SkyRally][TOOLBOX_AUDIO] no id for " .. cue .. " (silent)")
		end
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = cue
	s.SoundId = id
	if spatial then
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 20
		s.RollOffMaxDistance = Rules.HOLO_RANGE
	end
	Settings.sfx(s)
	s.Parent = parent
	return s
end

function ToolboxCues.has(cue: string): boolean
	return Ids[cue] ~= nil and Rules.CUES[cue] ~= nil
end

-- A 2D one-shot at the cue's mix level times `volume`. Returns whether a voice started.
function ToolboxCues.play(cue: string, pitch: number?, volume: number?): boolean
	local def = Rules.CUES[cue]
	if not def then
		return false
	end
	local pool = pools2D[cue]
	if not pool then
		local list: { Sound } = {}
		for _ = 1, POOL do
			local s = newSound(cue, folder(), false)
			if not s then
				return false
			end
			table.insert(list, s)
		end
		pool = { list = list, nextIndex = 1 }
		pools2D[cue] = pool
	end
	local p = pool :: Pool
	local s = p.list[p.nextIndex]
	p.nextIndex = p.nextIndex % #p.list + 1
	s.PlaybackSpeed = pitch or def.pitch
	s.Volume = math.min(def.vol * (volume or 1), Rules.MAX_CUE_VOL)
	s.TimePosition = 0
	s:Play()
	return true
end

-- A positional one-shot at a world point (a rumble, a geyser, a gate chime): two pooled emitter parts, each with the voices it has
-- played, so a burst never allocates after warm-up.
function ToolboxCues.playAt(cue: string, position: Vector3, pitch: number?, volume: number?): boolean
	local def = Rules.CUES[cue]
	if not def or not Ids[cue] then
		return false
	end
	if #emitters < POOL then
		table.insert(emitters, emitterPart("SkyRallyToolboxEmitter" .. tostring(#emitters + 1)))
	end
	local part = emitters[emitterNext]
	emitterNext = emitterNext % #emitters + 1
	part.Position = position
	local s = part:FindFirstChild(cue)
	if not s or not s:IsA("Sound") then
		s = newSound(cue, part, true)
	end
	if not s then
		return false
	end
	local snd = s :: Sound
	snd.PlaybackSpeed = pitch or def.pitch
	snd.Volume = math.min(def.vol * (volume or 1), Rules.MAX_CUE_VOL)
	snd.TimePosition = 0
	snd:Play()
	return true
end

-- A looped positional cue for one owner (key), moved with setLoopPosition; stopLoop silences it. One Sound per key.
function ToolboxCues.startLoop(key: string, cue: string, position: Vector3): boolean
	local def = Rules.CUES[cue]
	if not def or not Ids[cue] then
		return false
	end
	if loops[key] and loops[key].Parent then
		return true
	end
	local part = loopPart
	if not part or not part.Parent then
		part = emitterPart("SkyRallyToolboxLoop")
		loopPart = part
	end
	local p = part :: Part
	p.Position = position
	local s = newSound(cue, p, true)
	if not s then
		return false
	end
	s.Looped = true
	s.PlaybackSpeed = def.pitch
	s.Volume = math.min(def.vol, Rules.MAX_CUE_VOL)
	s:Play()
	loops[key] = s
	return true
end

function ToolboxCues.setLoopPosition(position: Vector3)
	local p = loopPart
	if p and p.Parent then
		p.Position = position
	end
end

function ToolboxCues.stopLoop(key: string)
	local s = loops[key]
	if s then
		loops[key] = nil
		s:Stop()
		s:Destroy()
	end
	if next(loops) == nil and loopPart then
		loopPart:Destroy()
		loopPart = nil
	end
end

return ToolboxCues
