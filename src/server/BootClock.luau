--!strict
-- Server boot timeline (TEST_LIST L42, perf pass 2026-10-19). One "[SkyRally][BOOT] phase=<name> t=<s>" line per boot
-- phase, seconds since ServerMain started (os.clock() at the first require, which is the first line of
-- init.server.luau), so a slow join can be read phase by phase from the server output. Only the boot load is timed
-- here; every map load also prints its own "[SkyRally][MAP] <id> steps ..." line (MapAdapter) and the director's total.
local BootClock = {}

local T0 = os.clock()
local marked: { [string]: number } = {}

function BootClock.now(): number
	return os.clock() - T0
end

-- Once per phase name; `extra` is appended as is ("k=v ..."). Returns the time stamped.
function BootClock.mark(phase: string, extra: string?): number
	local t = os.clock() - T0
	if marked[phase] == nil then
		marked[phase] = t
		print(string.format("[SkyRally][BOOT] phase=%s t=%.2f%s", phase, t, if extra then " " .. extra else ""))
		-- Also on Workspace (attribute BootTimeline), so QA can read the timeline from any DataModel after the output
		-- has scrolled (tools/boot_probe.py).
		local prev = workspace:GetAttribute("BootTimeline")
		workspace:SetAttribute("BootTimeline", string.format("%s%s=%.2f", if type(prev) == "string" then prev .. " " else "", phase, t))
	end
	return t
end

-- The time a phase was first marked, or nil.
function BootClock.at(phase: string): number?
	return marked[phase]
end

return BootClock
