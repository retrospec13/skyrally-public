--!strict
-- MicroProfiler labels for per-frame callbacks (docs/audits/perf_review_v21.md PF-10 step one). Prof.wrap("SR_Name", fn)
-- returns a function that runs fn(...) between debug.profilebegin("SR_Name") and debug.profileend(), so every SkyRally
-- RenderStepped / Heartbeat / BindToRenderStep callback shows by name in the MicroProfiler (Ctrl+F6) instead of an
-- anonymous script slice. The label is a static string (no per-frame allocation); debug.profilebegin is a no-op while
-- the profiler is closed. Outside Roblox (Lune specs) there is no profiler and fn is returned unchanged.
local Prof = {}

local dbg = debug :: any
local begin: ((string) -> ())? = if type(dbg.profilebegin) == "function" then dbg.profilebegin else nil
local finish: (() -> ())? = if type(dbg.profileend) == "function" then dbg.profileend else nil

function Prof.wrap<A...>(label: string, fn: (A...) -> ()): (A...) -> ()
	local b, e = begin, finish
	if not b or not e then
		return fn
	end
	return function(...: A...)
		b(label)
		-- No pcall: an error still reaches the output with its own traceback, and a label it leaves open only affects
		-- the profiler display, never the game.
		fn(...)
		e()
	end
end

return Prof
