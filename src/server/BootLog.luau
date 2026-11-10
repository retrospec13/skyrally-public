--!strict
-- QA boot-line ring buffer. Studio's console buffer truncates at its head and LogService:GetLogHistory is capped at 512
-- entries (flooded by retry lines), so a re-run of tools/map_boot_check.py lost the boot lines. This keeps the key
-- lines ([SkyRally] lines except the Store binder's, [30MAPS], errors, warnings) in a bounded ring and mirrors the
-- tail to workspace attribute "BootLog" and _G.SkyRallyBootLog, which the probe reads from any DataModel. Studio only.
local BootLog = {}

BootLog.MAX_LINES = 300
BootLog.MAX_LINE = 240
BootLog.MAX_ATTR = 15000 -- attribute strings are capped near 16k characters; the newest lines win
-- V1 D2: on a race map the ring rolls over within about 40 s of [ITEM]/[NAMES] chatter, so the boot evidence ([BOOT],
-- [MAP], [DIRECTOR], [SELFTEST]) was gone by the time tools/map_boot_check.py read it. Those lines also go to a second,
-- quiet list (workspace attribute "BootLogKey") that chatter never reaches; a line there may be longer (the
-- "[MAP] <id> steps build wait=..." timing line runs past 300 characters).
BootLog.KEY_TAGS = { "[SkyRally][BOOT]", "[SkyRally][MAP]", "[SkyRally][DIRECTOR]", "[SkyRally][SELFTEST]", "[SkyRally][LIGHTING]", "[SkyRally][MAPCACHE]", "[30MAPS] DONE", "[30MAPS] terrain bake" }
BootLog.MAX_KEY_LINES = 200
BootLog.MAX_KEY_LINE = 700

export type Ring = {
	lines: { string },
	keyLines: { string },
	push: (self: Ring, line: string, isProblem: boolean?) -> boolean,
	text: (self: Ring) -> string,
	keyText: (self: Ring) -> string,
}

function BootLog.isKey(line: string): boolean
	for _, tag in BootLog.KEY_TAGS do
		if string.find(line, tag, 1, true) then
			return true
		end
	end
	return false
end

-- True for a line worth keeping: tagged game lines, compiled-builder lines and any warning or error; Store retry
-- chatter is dropped unless it is itself a problem.
function BootLog.wanted(line: string, isProblem: boolean?): boolean
	if isProblem then
		return true
	end
	if string.find(line, "[SkyRally][Store]", 1, true) then
		return false
	end
	return string.find(line, "[SkyRally]", 1, true) ~= nil or string.find(line, "[30MAPS]", 1, true) ~= nil
end

local Ring = {}
Ring.__index = Ring

function Ring.push(self: any, line: string, isProblem: boolean?): boolean
	if not BootLog.wanted(line, isProblem) then
		return false
	end
	local keyAdded = false
	if BootLog.isKey(line) then
		local keyLine = string.sub(line, 1, BootLog.MAX_KEY_LINE)
		local kl = self.keyLines
		if kl[#kl] ~= keyLine then
			table.insert(kl, keyLine)
			keyAdded = true
			while #kl > BootLog.MAX_KEY_LINES do
				table.remove(kl, 1)
			end
		end
	end
	line = string.sub(line, 1, BootLog.MAX_LINE)
	if self.lines[#self.lines] == line then
		-- consecutive duplicate; still true when only the key list grew (a long key line whose first MAX_LINE
		-- characters repeat), so the caller republishes BootLogKey
		return keyAdded
	end
	table.insert(self.lines, line)
	while #self.lines > BootLog.MAX_LINES do
		table.remove(self.lines, 1)
	end
	return true
end

-- The newest lines that fit MAX_ATTR characters, oldest first.
local function tail(lines: { string }): string
	local out, size = {}, 0
	for i = #lines, 1, -1 do
		size += #lines[i] + 1
		if size > BootLog.MAX_ATTR then
			break
		end
		table.insert(out, 1, lines[i])
	end
	return table.concat(out, "\n")
end

function Ring.text(self: any): string
	return tail(self.lines)
end

-- The key lines (BootLog.isKey) only, same cap.
function Ring.keyText(self: any): string
	return tail(self.keyLines)
end

function BootLog.new(): Ring
	return setmetatable({ lines = {}, keyLines = {} }, Ring) :: any
end

-- Live wiring (Studio only): backfill from the log history, then follow LogService.MessageOut.
function BootLog.attach(): Ring?
	local RunService = game:GetService("RunService")
	if not RunService:IsStudio() then
		return nil
	end
	local LogService = game:GetService("LogService")
	local ring = BootLog.new()
	local dirty = false
	local function add(msg: string, mt: Enum.MessageType)
		if ring:push(msg, mt == Enum.MessageType.MessageError or mt == Enum.MessageType.MessageWarning) then
			dirty = true
		end
	end
	for _, e in LogService:GetLogHistory() do
		add(e.message, e.messageType)
	end
	LogService.MessageOut:Connect(function(msg: string, mt: Enum.MessageType)
		add(msg, mt)
	end)
	local shared = _G :: any
	shared.SkyRallyBootLog = ring.lines
	task.spawn(function()
		while true do
			if dirty then
				dirty = false
				workspace:SetAttribute("BootLog", ring:text())
				workspace:SetAttribute("BootLogKey", ring:keyText())
			end
			task.wait(0.5)
		end
	end)
	return ring
end

return BootLog
