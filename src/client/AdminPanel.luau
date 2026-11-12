--!strict
-- Owner admin page (DECISIONS D22; server/AdminService; shared/AdminRules). The owner's account gets an ADMIN tab in the
-- normal Settings panel (client/Settings.setExtraPage; owner 2026-10-21: "my account should just have the admin settings
-- via the settings tab"): no button of its own, no hotkey, no "admin mode". Cosmetic: every button sends the same command
-- text as the /admin chat command to the AdminRequest RemoteFunction, and the server re-checks the UserId on every call.
-- The client asks "status" once at start (and once more a little later); only when the server answers
-- (AdminRules.probeSaysAdmin) does it register the page and a client-local "/admin" TextChatCommand. Every other client
-- gets nil and creates nothing, so neither the tab nor the command ever exists or autocompletes for them.
-- Works in the hub and in a race; hub-only actions (solo start) answer with the server's short reason on the reply line.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminRules = require(Shared:WaitForChild("AdminRules"))
local Progression = require(Shared:WaitForChild("Progression"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local ChatCompatClient = require(script.Parent:WaitForChild("ChatCompatClient"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local UiSkin = require(script.Parent:WaitForChild("UiSkin")) -- UI v2 theme keys (admin buttons tap like the rest)

local AdminPanel = {}

-- The Settings plaque's wood palette (client/Settings).
local CREAM = Color3.fromRGB(250, 242, 222)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local WOOD_ROW = Color3.fromRGB(82, 56, 36)
local RIM = Color3.fromRGB(188, 168, 142)
local GOLD = Color3.fromRGB(255, 214, 90)
local MUTED = Color3.fromRGB(214, 200, 180)
local DENY = Color3.fromRGB(255, 160, 130)

local remote: RemoteFunction? = nil
local replyLabel: TextLabel? = nil
local stateLabel: TextLabel? = nil
local busy = false
local registered = false

local function corner(o: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function stroke(o: Instance, color: Color3, t: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = t
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
end

-- quiet (the status ask on open): only the state line updates. A reply that only repeats the state is not shown twice.
local function showReply(r: any, quiet: boolean?)
	if type(r) ~= "table" then
		return
	end
	local st = r.state
	local stateText = if type(st) == "table" then AdminRules.describe(st) else nil
	local rl = replyLabel
	if rl then
		if quiet or (stateText ~= nil and tostring(r.text) == stateText) then
			rl.Text = ""
		else
			rl.Text = tostring(r.text)
			rl.TextColor3 = if r.ok then CREAM else DENY
		end
	end
	local sl = stateLabel
	if sl and stateText then
		sl.Text = stateText
	end
end

-- Sends one command line; returns the reply table (nil when the server did not answer).
local function send(text: string, quiet: boolean?): any
	local rf = remote
	if not rf or busy then
		return nil
	end
	busy = true
	local ok, r = pcall(rf.InvokeServer, rf, text)
	busy = false
	if ok then
		showReply(r, quiet)
		return r
	end
	return nil
end

local function systemMessage(text: string)
	ChatCompatClient.systemMessage(text)
end

local function thousands(n: number): string
	local out = string.reverse((string.gsub(string.reverse(tostring(math.floor(n))), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

------------------------------------------------------------------------------------------------ page

local function button(parent: Instance, text: string, onClick: () -> ()): TextButton
	-- UI v2: a sky theme key; the TextButton's own (hidden) text keeps sizing it (AutomaticSize X).
	local b = (UiSkin.button(parent, "sky", "  " .. text .. "  ", { size = UDim2.new(0, 0, 0, 34), maxText = 16, sound = "tap", S = 1 }) :: any) :: TextButton
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Font = Enum.Font.GothamBlack
	b.TextSize = 15
	b.Activated:Connect(onClick)
	return b
end

-- A button that cycles through `list`; returns a getter for the current value.
local function cycler(parent: Instance, list: { string }): () -> string
	local i = 1
	local b = button(parent, list[1], function() end)
	UiSkin.setVariant(b, "orange")
	b.Activated:Connect(function()
		i = (i % #list) + 1
		b.Text = "  " .. list[i] .. "  "
	end)
	return function(): string
		return list[i]
	end
end

local order = 0
local function row(parent: Instance, title: string): Frame
	order += 1
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, -10, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = order
	f.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Wraps = true
	layout.Padding = UDim.new(0, 6)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = f
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromOffset(96, 32)
	l.FontFace = UiSkin.font("button")
	l.TextSize = 15
	l.TextColor3 = GOLD
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = string.upper(title)
	local ls = Instance.new("UIStroke")
	ls.Color = Color3.fromRGB(11, 21, 51)
	ls.Thickness = 1.5
	ls.Parent = l
	l.Parent = f
	return f
end

local function awardTargets(kind: string): { string }
	if kind == "token" then
		return Progression.RACE_TRACKS
	elseif kind == "hubFind" then
		return { "ground", "wateredge", "ledge", "cove" }
	elseif kind == "finalBoss" then
		return { "HUB-0" }
	end
	return Progression.CHAIN_ZONES :: any
end

-- Fills the Settings panel's extra page (a transparent Frame under the header, placed and sized by client/Settings).
local function buildPage(page: Frame)
	local sl = Instance.new("TextLabel")
	sl.BackgroundTransparency = 1
	sl.Size = UDim2.new(1, 0, 0, 16)
	sl.Font = Enum.Font.GothamBold
	sl.TextSize = 13
	sl.TextColor3 = MUTED
	sl.TextXAlignment = Enum.TextXAlignment.Left
	sl.TextTruncate = Enum.TextTruncate.AtEnd
	sl.Text = ""
	sl.Parent = page
	stateLabel = sl
	local rl = Instance.new("TextLabel")
	rl.BackgroundTransparency = 1
	rl.Position = UDim2.fromOffset(0, 16)
	rl.Size = UDim2.new(1, 0, 0, 16)
	rl.Font = Enum.Font.GothamBold
	rl.TextSize = 13
	rl.TextColor3 = CREAM
	rl.TextXAlignment = Enum.TextXAlignment.Left
	rl.TextTruncate = Enum.TextTruncate.AtEnd
	rl.Text = ""
	rl.Parent = page
	replyLabel = rl

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "AdminRows"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, 36)
	scroll.Size = UDim2.new(1, 0, 1, -36)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = RIM
	scroll.Parent = page
	-- v29 B9: the buttons' 1.5 px border strokes sit outside their frames and the ScrollingFrame clips at its edge, so the first
	-- row lost its top (and left / right) borders on desktop. A few px of padding keeps them whole.
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 3)
	pad.PaddingRight = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = scroll
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	local r = row(scroll, "Maps")
	button(r, "ALL OPEN", function()
		send("/admin portals on")
	end)
	button(r, "MY PROGRESS", function()
		send("/admin portals off")
	end)

	r = row(scroll, "Award")
	local kinds = AdminRules.AWARD_KINDS
	local kindAt = 1
	local targetAt = 1
	local kindBtn: TextButton
	local targetBtn: TextButton
	local function paintAward()
		local targets = awardTargets(kinds[kindAt])
		targetAt = math.clamp(targetAt, 1, #targets)
		kindBtn.Text = "  " .. kinds[kindAt] .. "  "
		targetBtn.Text = "  " .. targets[targetAt] .. "  "
	end
	kindBtn = button(r, kinds[1], function()
		kindAt = (kindAt % #kinds) + 1
		targetAt = 1
		paintAward()
	end)
	kindBtn.TextColor3 = GOLD
	targetBtn = button(r, "", function()
		targetAt = (targetAt % #awardTargets(kinds[kindAt])) + 1
		paintAward()
	end)
	targetBtn.TextColor3 = GOLD
	paintAward()
	button(r, "GRANT", function()
		send(string.format("/admin award %s %s", kinds[kindAt], awardTargets(kinds[kindAt])[targetAt]))
	end)

	r = row(scroll, "Cash")
	for _, n in { 1000, 10000, 100000 } do
		button(r, "+" .. thousands(n), function()
			send("/admin cash " .. n)
		end)
	end

	r = row(scroll, "2x Cash")
	button(r, "ON", function()
		send("/admin pass x2 on")
	end)
	button(r, "OFF", function()
		send("/admin pass x2 off")
	end)

	r = row(scroll, "Win Pass")
	button(r, "RACES 20", function()
		send("/admin winpass races 20")
	end)
	button(r, "WINS 10", function()
		send("/admin winpass wins 10")
	end)
	button(r, "PREMIUM ON", function()
		send("/admin winpass premium on")
	end)
	button(r, "PREMIUM OFF", function()
		send("/admin winpass premium off")
	end)

	r = row(scroll, "Storm Cup")
	local cupTrack = cycler(r, MonetizationConfig.STORM_CUP.tracks)
	local cupMod = cycler(r, AdminRules.stormModifiers())
	button(r, "START", function()
		send(string.format("/admin storm %s %s", cupTrack(), cupMod()))
	end)

	r = row(scroll, "Lobby")
	for _, m in AdminRules.LOBBY_MODES do
		button(r, string.upper(m), function()
			send("/admin lobby " .. m)
		end)
	end

	r = row(scroll, "Cup hold")
	button(r, "OFF", function()
		send("/admin hold off")
	end)
	button(r, "ON", function()
		send("/admin hold on")
	end)

	r = row(scroll, "Vehicles")
	button(r, "ALL UNLOCKED", function()
		send("/admin vehicles on")
	end)
	button(r, "MY GARAGE", function()
		send("/admin vehicles off")
	end)

	r = row(scroll, "Solo")
	local soloTracks = table.clone(Progression.RACE_TRACKS)
	table.insert(soloTracks, Progression.HUB_TRACK)
	local soloTrack = cycler(r, soloTracks)
	local soloMode = cycler(r, Progression.MODES :: any)
	button(r, "START", function()
		local t = soloTrack()
		local m = if t == Progression.HUB_TRACK then "boss" else soloMode()
		local reply = send(string.format("/admin solo %s %s", t, m))
		if type(reply) == "table" and reply.ok then
			Settings.close() -- the race is loading
		end
	end)

	r = row(scroll, "Command")
	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(300, 32)
	box.BackgroundColor3 = WOOD_ROW
	box.TextColor3 = CREAM
	box.PlaceholderColor3 = MUTED
	box.PlaceholderText = "/admin help"
	box.Font = Enum.Font.Gotham
	box.TextSize = 14
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Parent = r
	corner(box, 8)
	stroke(box, RIM, 1.5)
	box.FocusLost:Connect(function(enter: boolean)
		if enter and box.Text ~= "" then
			send(box.Text)
		end
	end)
end

-- Registers the Settings ADMIN tab and the client-local chat command (the owner's client only).
local function register()
	if registered then
		return
	end
	registered = true
	Settings.setExtraPage(AdminRules.PAGE_TITLE, buildPage, function()
		send(AdminRules.PROBE, true) -- the state line is fresh each time the tab is picked; the reply line clears
	end)
	-- The chat equivalent: a client-local command (created only here, on the admin's client).
	-- Legacy chat: the command never fires there; the server hooks the legacy ChatService instead (ChatCompat.plan).
	if ChatCompatClient.version() == "legacy" then
		return
	end
	local cmd = Instance.new("TextChatCommand")
	cmd.Name = "SkyRallyAdminCommand"
	cmd.PrimaryAlias = AdminRules.PREFIX
	cmd.Triggered:Connect(function(_source: TextSource, text: string)
		task.spawn(function()
			local r = send(text)
			if type(r) == "table" then
				systemMessage("[Admin] " .. tostring(r.text))
			end
		end)
	end)
	cmd.Parent = TextChatService
end

function AdminPanel.init()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 60)
		local rf = remotes and remotes:WaitForChild(AdminRules.REMOTE, 60)
		if not rf or not rf:IsA("RemoteFunction") then
			return
		end
		remote = rf
		-- Ask twice (the first ask can race the server's join bookkeeping in Studio); nil both times = not admin.
		for attempt = 1, 2 do
			local ok, r = pcall((rf :: RemoteFunction).InvokeServer, rf, AdminRules.PROBE)
			if AdminRules.probeSaysAdmin(ok, r) then
				register()
				showReply(r, true)
				return
			end
			if attempt == 1 then
				task.wait(6)
			end
		end
		remote = nil
	end)
end

return AdminPanel
