--!strict
-- v38 (design lane, Mario Kart 8 time trial): a ghost of your best run this session. Client only, look only: it never
-- touches a hit, a time or a save (the server's bestTimes stay the record).
-- * In a time trial ("timetrial" RaceMode) the own vehicle's pivot is sampled every SAMPLE_S from GO, with the lap times
--   the server sends (RaceEventRemote "LapCompleted" / "RaceFinished").
-- * A finished run faster than the session best (same track) becomes the ghost.
-- * The next time trial on that track shows a see-through copy of the vehicle replaying that run from GO, and its lap
--   times are the reference for the HUD's lap split (RaceUI.splitRef: green when you beat the ghost's lap, red when not).
-- * A reset, a mode change or a different track clears the ghost model; the session best stays until the player leaves.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))

local LocalPlayer = Players.LocalPlayer

local TimeTrialGhost = {}

local SAMPLE_S = 0.1
local GHOST_ALPHA = 0.6

type Frame = { t: number, cf: CFrame }
type Run = { track: string, frames: { Frame }, laps: { number }, total: number }

local best: { [string]: Run } = {} -- per track, this session
local rec: Run? = nil -- the run being recorded
local recLapStart = 0
local nextSample = 0
local ghost: Model? = nil
local ghostRun: Run? = nil
local ghostIdx = 1
local runKey = ""

local function ownVehicle(): Model?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	local m = planes:FindFirstChild("Car_" .. LocalPlayer.Name) or planes:FindFirstChild("Plane_" .. LocalPlayer.Name)
	return if m and m:IsA("Model") then m else nil
end

-- Race time from the server's RaceElapsed (0.1 s steps, ~7 Hz; the same clock the lap times use), smoothed with the
-- local clock between updates. RaceGoTime is not reset by a time trial restart (Studio: 490 s into a fresh run).
local lastElapsedAttr: number? = nil
local t0 = 0
local function elapsed(): number?
	local e = LocalPlayer:GetAttribute("RaceElapsed")
	if type(e) ~= "number" or e <= 0 then
		lastElapsedAttr = nil
		return nil -- the countdown (the server publishes RaceElapsed only after GO)
	end
	if e ~= lastElapsedAttr then
		lastElapsedAttr = e
		t0 = os.clock() - e
	end
	return os.clock() - t0
end

local function clearGhost()
	if ghost then
		ghost:Destroy()
	end
	ghost = nil
	ghostRun = nil
	ghostIdx = 1
end

-- A see-through, inert copy of the own vehicle (no scripts, sounds, lights or emitters; never collides or queries).
local function buildGhost(src: Model): Model?
	local was = src.Archivable
	src.Archivable = true
	local ok, copy = pcall(function(): Model
		return src:Clone()
	end)
	src.Archivable = was
	if not ok or not copy then
		return nil
	end
	for _, d in copy:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("Light") or d:IsA("ParticleEmitter") or d:IsA("Trail")
			or d:IsA("Beam") or d:IsA("BillboardGui") or d:IsA("Highlight") or d:IsA("ProximityPrompt") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Transparency = math.max(d.Transparency, GHOST_ALPHA)
		elseif d:IsA("Decal") then -- Texture is a Decal subclass
			local dec = d :: Decal
			dec.Transparency = math.max(dec.Transparency, GHOST_ALPHA)
		end
	end
	copy.Name = "TimeTrialGhost"
	for a in copy:GetAttributes() do
		copy:SetAttribute(a :: string, nil) -- the copy is no racer: nothing reads it as one
	end
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.fromRGB(150, 220, 255)
	hl.FillTransparency = 0.75
	hl.OutlineColor = Color3.fromRGB(190, 240, 255)
	hl.OutlineTransparency = 0.3
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = copy
	copy.Parent = workspace -- client-local: nobody else sees it
	return copy
end

-- The reference lap time for completed lap n (1-based) of the ghost run, or nil (RaceUI lap split).
function TimeTrialGhost.lapRef(n: number): number?
	local r = ghostRun
	return if r then r.laps[n] else nil
end

local function startRun(track: string)
	rec = { track = track, frames = {}, laps = {}, total = 0 }
	recLapStart = 0
	nextSample = 0
	clearGhost()
	ghostRun = best[track] -- the copy is built once the own vehicle exists (it can spawn after GO is published)
	ghostIdx = 1
end

local function step()
	local mode = RaceAttr.mine("RaceMode")
	local track = RaceAttr.mine("ActiveTrackId")
	local go = RaceAttr.mine("RaceResetSeq")
	local key = tostring(mode) .. "|" .. tostring(track) .. "|" .. tostring(go)
	if key ~= runKey then
		runKey = key
		rec = nil
		clearGhost()
		if mode == "timetrial" and type(track) == "string" then
			startRun(track)
		end
	end
	if not rec then
		return
	end
	local t = elapsed()
	if not t or t < 0 then
		return
	end
	-- record
	local r = rec :: Run
	if t >= nextSample and LocalPlayer:GetAttribute("RaceFinished") ~= true then
		nextSample = t + SAMPLE_S
		local car = ownVehicle()
		if car then
			table.insert(r.frames, { t = t, cf = car:GetPivot() })
		end
	end
	-- replay
	if ghostRun and not ghost then
		local car = ownVehicle()
		if car and car.PrimaryPart then
			ghost = buildGhost(car)
			if ghost then
				print(string.format("[SkyRally][GHOST] racing your best %.2f s", (ghostRun :: Run).total))
			else
				ghostRun = nil -- the vehicle cannot be copied: no ghost this run (never a retry every frame)
			end
		end
	end
	local g, gr = ghost, ghostRun
	if g and gr and g.Parent then
		local frames = gr.frames
		while ghostIdx < #frames and frames[ghostIdx + 1].t <= t do
			ghostIdx += 1
		end
		local a = frames[ghostIdx]
		local b = frames[math.min(ghostIdx + 1, #frames)]
		if a then
			local u = if b and b.t > a.t then math.clamp((t - a.t) / (b.t - a.t), 0, 1) else 0
			g:PivotTo(a.cf:Lerp(b and b.cf or a.cf, u))
		end
	end
end

local function onRaceEvent(eventType: string, payload: any)
	local r = rec
	if not r then
		return
	end
	if eventType == "LapCompleted" and type(payload) == "table" and type(payload.lapTime) == "number" then
		table.insert(r.laps, payload.lapTime)
	elseif eventType == "RaceFinished" and type(payload) == "table" and type(payload.totalTime) == "number" then
		local done = 0
		for _, l in r.laps do
			done += l
		end
		table.insert(r.laps, math.max(0, payload.totalTime - done)) -- the last lap
		r.total = payload.totalTime
		local b = best[r.track]
		if #r.frames > 10 and (b == nil or r.total < b.total) then
			best[r.track] = r
			print(string.format("[SkyRally][GHOST] new session best track=%s total=%.2f frames=%d", r.track, r.total, #r.frames))
		end
		rec = nil
	elseif eventType == "RaceReset" then
		runKey = "" -- restart the recording (and the ghost) on the next frame
	end
end

function TimeTrialGhost.init(raceUI: any)
	if raceUI then
		raceUI.splitRef = TimeTrialGhost.lapRef
	end
	RunService.RenderStepped:Connect(step)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 30)
		local remote: Instance? = nil
		while remotes and not remote do
			remote = remotes:WaitForChild("RaceEventRemote", 10)
		end
		if remote and remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(onRaceEvent)
		end
	end)
end

return TimeTrialGhost
