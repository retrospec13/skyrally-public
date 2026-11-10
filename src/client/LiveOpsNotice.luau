--!strict
-- Server closing notices (systems audit v32 T1-5; server/LiveOps, shared/LiveOpsRules). Client only, draws nothing of its
-- own: the server's workspace attributes drive a NotifyKit banner and toasts.
--  * ServerNotice (string or nil): the soft-shutdown banner ("Update ready: finish your race, then you move to a new
--    server."). nil clears it.
--  * ServerToast ("<seq>|<text>"): one toast per new seq (the soft and the hard close lines).
-- The live kill switches need no client code: the server refuses what is paused and the board's lock lines carry the
-- reason (TrackDirector.canOpen).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LiveOpsRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveOpsRules"))
local NotifyKit = require(script.Parent:WaitForChild("NotifyKit"))

local LiveOpsNotice = {}

local BANNER_KEY = "liveops_closing"
local started = false
local lastSeq = 0

local function applyBanner()
	local text = workspace:GetAttribute(LiveOpsRules.ATTR_NOTICE)
	if type(text) == "string" and text ~= "" then
		NotifyKit.banner(BANNER_KEY, string.sub(text, 1, 120), { priority = "critical" } :: any)
	else
		NotifyKit.clearBanner(BANNER_KEY)
	end
end

local function applyToast()
	local raw = workspace:GetAttribute("ServerToast")
	if type(raw) ~= "string" then
		return
	end
	local seqText, text = string.match(raw, "^(%d+)|(.*)$")
	local seq = tonumber(seqText)
	if not seq or not text or seq <= lastSeq or text == "" then
		return
	end
	lastSeq = seq
	NotifyKit.toast(string.sub(text, 1, 120), { key = "liveops_" .. seq, priority = "critical", seconds = 6 })
end

function LiveOpsNotice.init()
	if started then
		return
	end
	started = true
	workspace:GetAttributeChangedSignal(LiveOpsRules.ATTR_NOTICE):Connect(applyBanner)
	workspace:GetAttributeChangedSignal("ServerToast"):Connect(applyToast)
	applyBanner()
	-- A toast already set before this client joined is old news: take its seq as the baseline without showing it.
	local raw = workspace:GetAttribute("ServerToast")
	local seq = if type(raw) == "string" then tonumber(string.match(raw, "^(%d+)|")) else nil
	lastSeq = seq or 0
end

return LiveOpsNotice
