--!strict
-- Client error telemetry (docs/audits/systems_audit_v32.md T1-4; rules: shared/ErrorReporterRules). Started first by
-- init.client.luau, before every other module, so boot failures are caught too.
--   * ScriptContext.Error on this client: scrubbed (no player names, no ids), fingerprinted, de-duplicated and budgeted
--     by the tracker; first sightings go to the server at once, repeat counts every FLUSH_EVERY seconds.
--   * BootRules failures arrive through ErrorReporter.bootFail as kind "boot" / "boot_core"; the names also land on the
--     LocalPlayer attribute "BootFailed" for QA probes.
--   * LogService warnings are only counted (attribute "ClientWarnCount"); they never send.
-- Reports travel on SkyRallyRemotes.ErrorRemote (server/ErrorReporter cleans them again and logs analytics). Until the
-- remote exists, up to QUEUE_MAX reports wait. Every handler is pcall-wrapped: telemetry never breaks a client.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ErrorReporterRules"))

local ErrorReporter = {}

local QUEUE_MAX = 20

local tracker: Rules.Tracker? = nil
local remote: RemoteEvent? = nil
local queue: { Rules.Report } = {}
local bootFailed: { string } = {}
local warnCount = 0
local inHandler = false

local function playerNames(): { string }
	local out = {}
	for _, p in Players:GetPlayers() do
		table.insert(out, p.Name)
		if p.DisplayName ~= p.Name then
			table.insert(out, p.DisplayName)
		end
	end
	return out
end

local function send(r: Rules.Report)
	local rem = remote
	if rem then
		pcall(function()
			rem:FireServer(r.kind, r.source, r.fp, r.count, r.msg)
		end)
	elseif #queue < QUEUE_MAX then
		table.insert(queue, r)
	end
end

local function note(kind: string, source: string, msg: any)
	local t = tracker
	if not t or inHandler then
		return
	end
	inHandler = true
	pcall(function()
		local r = t.note(kind, source, Rules.scrub(msg, playerNames()))
		if r then
			send(r)
		end
	end)
	inHandler = false
end

-- A client module that failed to start (BootRules runner report).
function ErrorReporter.bootFail(name: string, err: string, core: boolean)
	pcall(function()
		table.insert(bootFailed, name)
		Players.LocalPlayer:SetAttribute("BootFailed", table.concat(bootFailed, ","))
	end)
	note(if core then "boot_core" else "boot", Rules.sourceName(name), err)
end

function ErrorReporter.init()
	if tracker then
		return
	end
	tracker = Rules.newTracker({ now = os.clock })

	local ScriptContext = game:GetService("ScriptContext")
	ScriptContext.Error:Connect(function(message: string, _trace: string, scr: Instance?)
		local source = "unknown"
		if scr then
			pcall(function()
				source = Rules.sourceName((scr :: Instance):GetFullName())
			end)
		end
		note("error", source, message)
	end)

	local LogService = game:GetService("LogService")
	LogService.MessageOut:Connect(function(_message: string, kind: Enum.MessageType)
		if kind == Enum.MessageType.MessageWarning then
			warnCount += 1
		end
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 120)
		local rem = remotes and remotes:WaitForChild(Rules.REMOTE, 120)
		if not rem or not rem:IsA("RemoteEvent") then
			return
		end
		remote = rem
		local pending = queue
		queue = {}
		for _, r in pending do
			send(r)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Rules.FLUSH_EVERY)
			local t = tracker
			if t then
				pcall(function()
					for _, r in t.flush() do
						send(r)
					end
					Players.LocalPlayer:SetAttribute("ClientWarnCount", warnCount)
				end)
			end
		end
	end)
end

return ErrorReporter
