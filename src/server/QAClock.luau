--!strict
-- Studio-only QA UTC clock (TG-6, docs/VERIFY_CAMPAIGN_V33.md). QAClock.now() is the real UTC in a live server, always.
-- In Studio, workspace.QAUtcAt = <epoch seconds> makes the economy (shop windows, Daily Deal, festivals, claims) and the
-- Storm Cup schedule read UTC as that moment and let it run on from there, so a boundary (xx:29:50 for the :30 cup,
-- 23:59:50 for the Daily Deal) can be reached in seconds. Changing the attribute restarts the clock at the new value.
-- QATimingDump = true prints this server's schedule/stock signature, the thing a second Play at the same QAUtcAt must
-- reproduce byte for byte ("[SkyRally][QATIME] sig=..."); shared/QAHooksRules.signature.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QAHooksRules"))

local QAClock = {}

local studio = RunService:IsStudio()
local seenAt: any = nil
local setClock: number? = nil

local function real(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

function QAClock.now(): number
	if not studio then
		return real()
	end
	local attr = workspace:GetAttribute(Rules.UTC_ATTR)
	if attr ~= seenAt then
		seenAt = attr
		setClock = os.clock()
	end
	return Rules.utcNow(true, attr, setClock, os.clock(), real())
end

-- Integer seconds, for os.time() style callers.
function QAClock.nowSeconds(): number
	return math.floor(QAClock.now())
end

function QAClock.start()
	if not studio then
		return
	end
	local EconomyRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EconomyRules")) :: any
	workspace:GetAttributeChangedSignal(Rules.DUMP_ATTR):Connect(function()
		if workspace:GetAttribute(Rules.DUMP_ATTR) ~= true then
			return
		end
		local t = QAClock.now()
		local sig = Rules.signature(EconomyRules.default, t)
		print(string.format("[SkyRally][QATIME] utc=%d qaClock=%s sig=%s", math.floor(t), tostring(workspace:GetAttribute(Rules.UTC_ATTR) ~= nil), sig.signature))
		workspace:SetAttribute("QATimingSignature", sig.signature)
		workspace:SetAttribute(Rules.DUMP_ATTR, nil)
	end)
end

return QAClock
