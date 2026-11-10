--!strict
-- Live adapter for shared/ChatCompat on the client: system lines, chat layout, chat rect, under TextChatService or
-- LegacyChatService. Nothing here flips the chat version; it reads TextChatService.ChatVersion.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local ChatCompat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChatCompat"))

local ChatCompatClient = {}

function ChatCompatClient.version(): string
	local ok, v = pcall(function()
		return TextChatService.ChatVersion.Name
	end)
	return ChatCompat.detect(if ok then v else nil)
end

function ChatCompatClient.systemMessage(text: string): boolean
	local clean = ChatCompat.cleanSystemText(text)
	if not clean then
		return false
	end
	if ChatCompatClient.version() == "legacy" then
		local c = ChatCompat.SYSTEM_COLOR
		return (pcall(function()
			StarterGui:SetCore("ChatMakeSystemMessage", { Text = clean, Color = Color3.fromRGB(c[1], c[2], c[3]) })
		end))
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		return false
	end
	local names = {}
	for _, ch in channels:GetChildren() do
		if ch:IsA("TextChannel") then
			table.insert(names, ch.Name)
		end
	end
	local pick = ChatCompat.pickChannel(names)
	local channel = if pick then channels:FindFirstChild(pick) else nil
	if channel and channel:IsA("TextChannel") then
		return (pcall(function()
			(channel :: TextChannel):DisplaySystemMessage(clean)
		end))
	end
	return false
end

-- cfg = ChatLayoutRules.compute(...). Idempotent and pcall-guarded (CoreGui may not be ready). Returns true once applied,
-- false when it could not be (legacy chat has not registered its SetCore callbacks yet, or no ChatWindowConfiguration), so
-- ChatLayout retries on its next tick. Never opens or closes the chat window (no ChatActive SetCore): the player's choice stands.
function ChatCompatClient.applyLayout(cfg: any): boolean
	local version = ChatCompatClient.version()
	local plan = ChatCompat.layoutPlan(if version == "legacy" then "legacy" else "text", cfg)
	if plan.kind == "setcore" then
		return (pcall(function()
			StarterGui:SetCore("ChatWindowPosition", UDim2.new(plan.position.xs, plan.position.xo, plan.position.ys, plan.position.yo))
			StarterGui:SetCore("ChatWindowSize", UDim2.new(plan.size.xs, plan.size.xo, plan.size.ys, plan.size.yo))
		end))
	end
	local win = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if not win then
		return false
	end
	return (pcall(function()
		local p = plan.props
		win.Enabled = true
		win.HorizontalAlignment = Enum.HorizontalAlignment.Left
		win.VerticalAlignment = if p.VerticalAlignment == "Bottom" then Enum.VerticalAlignment.Bottom else Enum.VerticalAlignment.Center
		win.WidthScale = p.WidthScale
		win.HeightScale = p.HeightScale
		win.TextSize = p.TextSize
		win.BackgroundTransparency = p.BackgroundTransparency
	end))
end

-- "x,y,w,h" of the chat window in pixels, or "none" (RaceUI HudChatRect attribute).
function ChatCompatClient.rectString(): string
	local out = "none"
	pcall(function()
		if ChatCompatClient.version() == "legacy" then
			local pos = StarterGui:GetCore("ChatWindowPosition") :: UDim2
			local size = StarterGui:GetCore("ChatWindowSize") :: UDim2
			local cam = workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(0, 0)
			out = string.format(
				"%d,%d,%d,%d",
				pos.X.Scale * vp.X + pos.X.Offset,
				pos.Y.Scale * vp.Y + pos.Y.Offset,
				size.X.Scale * vp.X + size.X.Offset,
				size.Y.Scale * vp.Y + size.Y.Offset
			)
			return
		end
		local cfg = TextChatService:FindFirstChild("ChatWindowConfiguration") :: any
		if cfg and cfg.Enabled then
			out = string.format("%d,%d,%d,%d", cfg.AbsolutePosition.X, cfg.AbsolutePosition.Y, cfg.AbsoluteSize.X, cfg.AbsoluteSize.Y)
		end
	end)
	return out
end

return ChatCompatClient
