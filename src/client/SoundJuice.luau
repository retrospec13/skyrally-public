--!strict
-- Vehicle sound juice: the player's engine, boost, pickup, crash and lap cues (SoundService.SkyRallySounds).
-- REMARKABLE Batch 2 (shared/SoundscapeRules, tools/tests/soundscape_spec.luau):
--   12. The old "lava rumble" (LavaAmbienceLoop, the engine sample pitched down) used to play on every map, so SNOW
--       and SPACE rumbled like a volcano. It now sounds only on DINO, and only until DINO's real bed (amb_dino,
--       client/Soundscape) has an id; it is stopped while silent.
--   29. Engine voices: once the soundscape engines have ids, EngineHumLoop carries the vehicle's low band
--       (eng_car_low / eng_plane_low) and EngineHighLoop its high band, crossfaded by revs (equal power) and pushed
--       toward the snarl by throttle climb and boost. Without ids the original single loop plays exactly as before.
--   Soundscape.telemetry gets the speed and altitude every step (wind, backfire, the DINO bed's lava swell).
-- audio-v2 (shared/EngineMixRules, tools/tests/engine_mix_spec.luau): the engine is silent at idle (faded out within 0.5 s of
--   stopping and letting go of the throttle), a subtle low layer while driving (Mario Kart style, well under the music),
--   with short accents on throttle-up, boost and landing. The ENGINE SOUND setting (Settings.engineSound) gates all of it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local SoundscapeRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundscapeRules"))
local EngineMixRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EngineMixRules"))
local Soundscape = require(script.Parent:WaitForChild("Soundscape"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local SfxV2Audio = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SfxV2Audio")) :: any
-- Audit H13: every sound here goes through the EFFECTS slider (SoundService.SkyRallySfx).
local Settings = require(script.Parent:WaitForChild("Settings"))

local SoundJuice = {}

-- Uploaded procedural audio asset IDs (granted to Universe 0). The boost, pickup, crash and lap cues are the
-- sfx_v2 set (shared/SfxV2Audio); only the engine loop is still the first-pass sample.
SoundJuice.SOUND_IDS = {
	EngineLoop = "rbxassetid://91840597129266",
	BoostKick = SfxV2Audio.boost_kick,
	BoostOvercharge = SfxV2Audio.boost_overcharge,
	BoostLoop = SfxV2Audio.boost_loop,
	PodPickup = SfxV2Audio.pod_pickup,
	CrashHit = SfxV2Audio.crash_hit,
	LapDing = SfxV2Audio.lap_ding,
	FinishTada = SfxV2Audio.finish_tada,
}

local BOOST_LOOP_VOL = 0.36

local BASE_ENGINE_VOL = 0.28
local MIN_LAVA_VOL = 0.10
local MAX_LAVA_VOL = 0.28

local LAVA_FLOOR_Y = 14.0
local LAVA_CEIL_Y = 120.0

local MIN_SPEED_REF = 70.0
local MAX_SPEED_REF = 210.0
local MIN_ENGINE_PITCH = 0.75
local MAX_ENGINE_PITCH = 1.65

SoundJuice.folder = nil :: Folder?
local engineLoop: Sound? = nil
local lavaLoop: Sound? = nil
local boostKick: Sound? = nil
local boostOvercharge: Sound? = nil
local boostLoop: Sound? = nil
local boostLoopVol = 0.0 -- eased toward its target in step; the loop plays only while it is audible
local pickupChime: Sound? = nil
local crashHit: Sound? = nil
local lapDing: Sound? = nil
local finishTada: Sound? = nil

local engineHigh: Sound? = nil -- the high band (REMARKABLE 29), nil while the band ids are missing
local CAR_BAND_CUES = { "eng_car_low", "eng_car_high" }
local PLANE_BAND_CUES = { "eng_plane_low", "eng_plane_high" }
local engineBands: string? = nil -- "car" | "plane": which band pair EngineHumLoop/EngineHighLoop hold; nil = legacy loop
local lowTarget = BASE_ENGINE_VOL
local highTarget = 0.0
local lastSpeed: number? = nil
local climb = 0.0 -- smoothed throttle climb (studs/s^2), the band crossfade's load

local engineLevel = 0.0 -- EngineMixRules level (0 = silent), eased in step
local accentKind: string? = nil -- the running accent (EngineMixRules.ACCENTS) and its age
local accentAge = 0.0
local lastThrottle = 0.0
local sinceThrottleAccent = math.huge
local lastStepAt = 0.0 -- os.clock() of the last step; the stale watchdog fades the loops when no vehicle steps them
local staleConn: RBXScriptConnection? = nil
local currentEnginePitch = 1.0
local targetLavaVolume = 0.0 -- the stopgap: silent until a DINO step says otherwise
local duckTimer = 0.0
local activeEngineTween: Tween? = nil
local activeLavaTween: Tween? = nil

local function cancelDuckTweens()
	if activeEngineTween then
		activeEngineTween:Cancel()
		activeEngineTween = nil
	end
	if activeLavaTween then
		activeLavaTween:Cancel()
		activeLavaTween = nil
	end
end

local function getOrCreateSound(parent: Instance, name: string, soundId: string, volume: number, playbackSpeed: number, looped: boolean): Sound
	local found = parent:FindFirstChild(name)
	if found and found.ClassName ~= "Sound" then
		found:Destroy()
		found = nil
	end
	local snd: Sound
	if found then
		snd = found :: Sound
	else
		snd = Instance.new("Sound")
		snd.Name = name
		snd.Parent = parent
	end
	snd.SoundId = soundId
	snd.Volume = volume
	snd.PlaybackSpeed = playbackSpeed
	snd.Looped = looped
	Settings.sfx(snd)
	return snd
end

-- Find-or-create helpers typed without nil-narrowing (luau-lsp does not narrow a reassigned optional local; the
-- previous `if not x then x = Instance.new(...)` form reported 14 type errors, repeated once per requiring module).
local function pitchShiftOn(snd: Sound, name: string): PitchShiftSoundEffect
	local found = snd:FindFirstChildOfClass("PitchShiftSoundEffect")
	if found then
		return found
	end
	local fx = Instance.new("PitchShiftSoundEffect")
	fx.Name = name
	fx.Parent = snd
	return fx
end

local function equalizerOn(snd: Sound, name: string): EqualizerSoundEffect
	local found = snd:FindFirstChildOfClass("EqualizerSoundEffect")
	if found then
		return found
	end
	local fx = Instance.new("EqualizerSoundEffect")
	fx.Name = name
	fx.Parent = snd
	return fx
end

local function ensureLavaEffects(lavaSound: Sound)
	local pitch = pitchShiftOn(lavaSound, "LavaPitchShift")
	pitch.Octave = 0.65
	pitch.Enabled = true

	local eq = equalizerOn(lavaSound, "LavaSubterraneanEQ")
	eq.LowGain = 6
	eq.MidGain = -4
	eq.HighGain = -8
	eq.Enabled = true
end

local function ensureSounds()
	local existingFolder = SoundService:FindFirstChild("SkyRallySounds")
	if existingFolder and existingFolder.ClassName ~= "Folder" then
		existingFolder:Destroy()
		existingFolder = nil
	end
	local folder: Folder
	if existingFolder then
		folder = existingFolder :: Folder
	else
		local newFolder = Instance.new("Folder")
		newFolder.Name = "SkyRallySounds"
		newFolder.Parent = SoundService
		folder = newFolder
	end
	SoundJuice.folder = folder

	if not engineLoop or engineLoop.Parent ~= folder then
		local eng = getOrCreateSound(folder, "EngineHumLoop", SoundJuice.SOUND_IDS.EngineLoop, 0, 1.0, true)
		if not eng.IsPlaying then
			pcall(function()
				eng:Play()
			end)
		end
		engineLoop = eng
		engineBands = nil -- a fresh loop holds the legacy sample until the bands are applied below
	end
	-- REMARKABLE 29: the vehicle's two engine bands, when their ids exist (the active vehicle can change per map).
	-- (Integration: constant cue names, no string building per frame; ensureSounds runs every step.)
	local vehicle = if RaceAttr.mine("ActiveVehicle") == "car" then "car" else "plane"
	if engineBands ~= vehicle and engineLoop then
		local cues = if vehicle == "car" then CAR_BAND_CUES else PLANE_BAND_CUES
		local lowId = Soundscape.asset(cues[1])
		local highId = Soundscape.asset(cues[2])
		if lowId and highId then
			local eng = engineLoop
			eng.SoundId = lowId
			local hi = getOrCreateSound(folder, "EngineHighLoop", highId, 0, 1.0, true)
			pcall(function()
				eng:Play()
				hi:Play()
			end)
			engineHigh = hi
			engineBands = vehicle
		end
	end

	if not lavaLoop or lavaLoop.Parent ~= folder then
		-- REMARKABLE 12 stopgap: created silent and stopped; SoundJuice.step starts it only on DINO with no real bed.
		local lava = getOrCreateSound(folder, "LavaAmbienceLoop", SoundJuice.SOUND_IDS.EngineLoop, 0, 0.42, true)
		ensureLavaEffects(lava)
		lavaLoop = lava
	else
		ensureLavaEffects(lavaLoop)
	end

	if not boostKick or boostKick.Parent ~= folder then
		boostKick = getOrCreateSound(folder, "BoostWhoosh", SoundJuice.SOUND_IDS.BoostKick, 0.6, 1.0, false)
	end

	if not boostOvercharge or boostOvercharge.Parent ~= folder then
		boostOvercharge = getOrCreateSound(folder, "BoostOvercharge", SoundJuice.SOUND_IDS.BoostOvercharge, 0.65, 1.0, false)
	end

	-- The nozzle roar under the engine while a boost lasts: created silent, started and stopped in step like the lava loop.
	if not boostLoop or boostLoop.Parent ~= folder then
		boostLoop = getOrCreateSound(folder, "BoostLoop", SoundJuice.SOUND_IDS.BoostLoop, 0, 1.0, true)
		boostLoopVol = 0
	end

	if not pickupChime or pickupChime.Parent ~= folder then
		pickupChime = getOrCreateSound(folder, "PickupChime", SoundJuice.SOUND_IDS.PodPickup, 0.52, 1.0, false)
	end

	if not crashHit or crashHit.Parent ~= folder then
		crashHit = getOrCreateSound(folder, "CrashThud", SoundJuice.SOUND_IDS.CrashHit, 0.79, 1.0, false)
	end

	if not lapDing or lapDing.Parent ~= folder then
		lapDing = getOrCreateSound(folder, "LapFanfare", SoundJuice.SOUND_IDS.LapDing, 0.56, 1.0, false)
	end

	if not finishTada or finishTada.Parent ~= folder then
		finishTada = getOrCreateSound(folder, "FinishTada", SoundJuice.SOUND_IDS.FinishTada, 0.76, 1.0, false)
	end
end

local function duckBackgroundLoops(duckEngineVol: number, duckLavaVol: number?, holdDuration: number)
	ensureSounds()
	cancelDuckTweens()
	duckTimer = math.max(duckTimer, holdDuration)

	local downInfo = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local upInfo = TweenInfo.new(math.max(0.12, holdDuration - 0.05), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

	if engineLoop then
		local eng = engineLoop
		local downTween = TweenService:Create(eng, downInfo, { Volume = math.min(duckEngineVol, lowTarget) })
		activeEngineTween = downTween
		downTween:Play()
		task.delay(0.05, function()
			if activeEngineTween == downTween and eng.Parent ~= nil then
				-- Back up to the low band's share (the full BASE_ENGINE_VOL on the legacy single loop).
				local upTween = TweenService:Create(eng, upInfo, { Volume = lowTarget })
				activeEngineTween = upTween
				upTween:Play()
			end
		end)
	end

	if duckLavaVol ~= nil and lavaLoop then
		local lava = lavaLoop
		-- Never duck *up*: off DINO the stopgap holds the rumble at 0, and a crash must not raise it to the duck level.
		local downTween = TweenService:Create(lava, downInfo, { Volume = math.min(duckLavaVol, targetLavaVolume) })
		activeLavaTween = downTween
		downTween:Play()
		task.delay(0.05, function()
			if activeLavaTween == downTween and lava.Parent ~= nil then
				local upTween = TweenService:Create(lava, upInfo, { Volume = targetLavaVolume })
				activeLavaTween = upTween
				upTween:Play()
			end
		end)
	end
end

-- No vehicle stepping the engine (under the map-swap curtain, a respawn fade, a scripted ride, grid hold on autopilot, out
-- of a vehicle): the level is idle, so the loops fade to silence and stop instead of holding their last driving volume.
local function stepStale(dt: number)
	if not EngineMixRules.stale(os.clock(), lastStepAt) then
		return
	end
	local lo, hi = engineLoop, engineHigh
	if not ((lo and lo.IsPlaying) or (hi and hi.IsPlaying)) then
		return
	end
	engineLevel, accentKind, lastThrottle = 0.0, nil, 0.0
	lowTarget, highTarget = 0, 0
	cancelDuckTweens()
	duckTimer = 0.0
	local k = math.exp(-EngineMixRules.RELEASE_RATE * math.clamp(dt, 0, 0.25))
	for _, snd in { lo, hi } do
		if snd and snd.IsPlaying then
			snd.Volume *= k
			if snd.Volume < 0.002 then
				snd.Volume = 0
				pcall(function()
					snd:Stop()
				end)
			end
		end
	end
end

function SoundJuice.init()
	currentEnginePitch = 1.0
	engineLevel, accentKind, lastThrottle, sinceThrottleAccent = 0.0, nil, 0.0, math.huge
	if not staleConn then
		staleConn = RunService.Heartbeat:Connect(stepStale)
	end
	targetLavaVolume = 0
	duckTimer = 0.0
	Settings.setSfxPreview(SoundJuice.SOUND_IDS.BoostKick) -- what the EFFECTS slider plays when released
	Sfx.preload() -- the sfx_v2 cue files, loaded before the first race
	Soundscape.init() -- REMARKABLE 12 and 29 (idempotent): beds, rival voices, wind, backfire; ids before the bands
	ensureSounds()
end

-- A short engine accent ("throttle" | "boost" | "land", EngineMixRules.ACCENTS); silent with ENGINE SOUND off.
function SoundJuice.accent(kind: string)
	if EngineMixRules.ACCENTS[kind] and Settings.engineSound() then
		accentKind, accentAge = kind, 0.0
	end
end

-- throttle: the driver's gas, -1..1 (nil = unknown: a moving vehicle counts as half throttle, a stopped one as off).
-- levelSpeed: the real speed for the mix level when `speed` only carries a pitch (the grid hold passes 0: the vehicle is
-- held still while `speed` maps the revs to pitch); nil = `speed`.
function SoundJuice.step(dt: number, speed: number, altitudeY: number, boostState: string, throttle: number?, levelSpeed: number?)
	ensureSounds()
	lastStepAt = os.clock()
	local clampedDt = math.clamp(dt, 0.0, 0.25)

	-- audio-v2 engine level: silent at idle, subtle while driving, accents on throttle-up and boost.
	local enabled = Settings.engineSound()
	local mixSpeed = levelSpeed or speed
	local gas = throttle or (if math.abs(mixSpeed) > EngineMixRules.IDLE_SPEED then 0.5 else 0)
	sinceThrottleAccent += clampedDt
	if enabled and EngineMixRules.throttleUp(lastThrottle, gas, sinceThrottleAccent) then
		sinceThrottleAccent = 0
		accentKind, accentAge = "throttle", 0.0
	end
	lastThrottle = gas
	engineLevel = EngineMixRules.ease(engineLevel, EngineMixRules.target(mixSpeed, gas, boostState ~= "None", enabled), clampedDt)
	local accentLvl = 0.0
	if accentKind then
		accentAge += clampedDt
		accentLvl = EngineMixRules.accentLevel(accentKind, accentAge)
		if accentLvl <= 0 and accentAge > 0 then
			accentKind = nil
		end
	end
	local mix = EngineMixRules.final(engineLevel, accentLvl, enabled)

	-- Smoothly modulate EngineHumLoop.PlaybackSpeed (0.75 .. 1.65) with flight speed and boost state
	local speedAlpha = math.clamp((speed - MIN_SPEED_REF) / (MAX_SPEED_REF - MIN_SPEED_REF), 0.0, 1.0)
	local desiredPitch = MIN_ENGINE_PITCH + (MAX_ENGINE_PITCH - MIN_ENGINE_PITCH) * speedAlpha
	if boostState == "Overcharge" then
		desiredPitch = math.min(MAX_ENGINE_PITCH, desiredPitch + 0.10)
	elseif boostState == "Standard" then
		desiredPitch = math.min(MAX_ENGINE_PITCH, desiredPitch + 0.05)
	end
	local lerpAlpha = math.clamp(clampedDt * 8.0, 0.0, 1.0)
	currentEnginePitch = currentEnginePitch + (desiredPitch - currentEnginePitch) * lerpAlpha

	local p = math.clamp(currentEnginePitch, MIN_ENGINE_PITCH, MAX_ENGINE_PITCH)
	local hi = engineHigh
	if engineBands and hi and engineLoop then
		-- REMARKABLE 29: two bands crossfaded by revs; a throttle climb or a boost brings the snarl in early.
		if clampedDt > 0 then
			local prev = lastSpeed or speed
			climb += (math.max(0, (speed - prev) / clampedDt) - climb) * math.clamp(clampedDt * 6, 0, 1)
		end
		local load = math.clamp(climb / 60, 0, 0.6) + (if boostState == "Overcharge" then 0.6 elseif boostState == "Standard" then 0.35 else 0)
		local lowGain, highGain, lowSpeed, highSpeed = SoundscapeRules.engineBands(p, engineBands, load)
		engineLoop.PlaybackSpeed = lowSpeed
		hi.PlaybackSpeed = highSpeed
		lowTarget = BASE_ENGINE_VOL * lowGain * mix
		highTarget = BASE_ENGINE_VOL * highGain * mix
	else
		if engineLoop then
			engineLoop.PlaybackSpeed = p
		end
		lowTarget = BASE_ENGINE_VOL * mix
		highTarget = 0
	end
	lastSpeed = speed

	-- Modulate LavaAmbienceLoop.Volume (0.10 .. 0.28) based on proximity to the lava floor (Y = 14..120); REMARKABLE 12
	-- stopgap: only on DINO, and only until DINO's real ambience bed has an id.
	local proximity = 1.0 - math.clamp((altitudeY - LAVA_FLOOR_Y) / (LAVA_CEIL_Y - LAVA_FLOOR_Y), 0.0, 1.0)
	targetLavaVolume = SoundscapeRules.legacyLavaVolume(RaceAttr.mine("ActiveZone"), Soundscape.has("amb_dino"),
		MIN_LAVA_VOL + (MAX_LAVA_VOL - MIN_LAVA_VOL) * proximity)
	local lava = lavaLoop
	if lava then
		if targetLavaVolume > 0 and not lava.IsPlaying then
			pcall(function()
				lava:Play()
			end)
		elseif targetLavaVolume <= 0 and lava.IsPlaying and lava.Volume < 0.005 then
			lava.Volume = 0
			lava:Stop()
		end
	end

	-- The boost roar: fades in with the boost (x1.25 on Overcharge), out a little slower, pitched up with speed.
	local loopSound = boostLoop
	if loopSound then
		local boosting = boostState ~= "None"
		local boostTarget = if not boosting then 0 elseif boostState == "Overcharge" then BOOST_LOOP_VOL * 1.25 else BOOST_LOOP_VOL
		boostLoopVol = boostLoopVol + (boostTarget - boostLoopVol) * lerpAlpha
		loopSound.Volume = boostLoopVol
		loopSound.PlaybackSpeed = 0.92 + 0.2 * speedAlpha
		if boostLoopVol > 0.01 and not loopSound.IsPlaying then
			pcall(function()
				loopSound:Play()
			end)
		elseif boostLoopVol < 0.005 and loopSound.IsPlaying then
			loopSound.Volume = 0
			loopSound:Stop()
		end
	end

	-- Silent engine: the loops stop (no mixing cost on a phone) and restart with the next throttle.
	local lo = engineLoop
	if lo then
		if mix <= 0 and lo.Volume < 0.002 and (hi == nil or hi.Volume < 0.002) then
			if lo.IsPlaying then
				lo.Volume = 0
				pcall(function()
					lo:Stop()
					if hi then
						hi.Volume = 0
						hi:Stop()
					end
				end)
			end
		elseif mix > 0 and not lo.IsPlaying then
			pcall(function()
				lo:Play()
				if hi then
					hi:Play()
				end
			end)
		end
	end

	if duckTimer > 0 then
		duckTimer = math.max(0.0, duckTimer - clampedDt)
		if hi then
			hi.Volume = hi.Volume + (highTarget * 0.3 - hi.Volume) * lerpAlpha
		end
	else
		if lavaLoop then
			lavaLoop.Volume = lavaLoop.Volume + (targetLavaVolume - lavaLoop.Volume) * lerpAlpha
		end
		if engineLoop then
			engineLoop.Volume = engineLoop.Volume + (lowTarget - engineLoop.Volume) * lerpAlpha
		end
		if hi then
			hi.Volume = hi.Volume + (highTarget - hi.Volume) * lerpAlpha
		end
	end
	Soundscape.telemetry(clampedDt, speed, altitudeY, boostState)
end

function SoundJuice.triggerFeedback(tier: string, eventName: string)
	ensureSounds()

	if tier == "small" then
		-- "Pickup" or "Checkpoint": the pod chime, a little off pitch each time so a run of pods is not one note.
		if pickupChime then
			pickupChime.PlaybackSpeed = 0.92 + math.random() * 0.2
			pickupChime.Volume = 0.52
			pcall(function()
				pickupChime:Play()
			end)
		end
	elseif tier == "medium" then
		-- "Boost" or "Overcharge": the boost hit (Overcharge is its own bigger cue) and a brief EngineHumLoop duck.
		local hit = if eventName == "Overcharge" then boostOvercharge else boostKick
		if hit then
			hit.PlaybackSpeed = if eventName == "Overcharge" then 1.0 else 0.97 + math.random() * 0.06
			hit.Volume = if eventName == "Overcharge" then 0.65 else 0.6
			pcall(function()
				hit:Play()
			end)
		end
		SoundJuice.accent("boost")
		duckBackgroundLoops(0.11, nil, 0.25)
	elseif tier == "large" then
		-- "Crash", "Lap", or "Finish": the crash hit, the lap ding or the finish tada, and a brief duck of the loops
		if eventName == "Crash" then
			if crashHit then
				crashHit.PlaybackSpeed = 0.96 + math.random() * 0.08
				crashHit.Volume = 0.79
				pcall(function()
					crashHit:Play()
				end)
			end
			duckBackgroundLoops(0.06, 0.06, 0.45)
		else
			local fanfare = if eventName == "Finish" then finishTada else lapDing
			if fanfare then
				fanfare.PlaybackSpeed = 1.0
				fanfare.Volume = if eventName == "Finish" then 0.76 else 0.56
				pcall(function()
					fanfare:Play()
				end)
			end
			duckBackgroundLoops(0.08, 0.06, 0.55)
		end
	end
end

return SoundJuice
