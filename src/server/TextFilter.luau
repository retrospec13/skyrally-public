--!strict
-- Server adapter: every player-typed string that other players will see goes through here (TextService:FilterStringAsync,
-- shared/ChatCompat.filterText handles the sanitising and the nil-on-failure rule). Independent of the chat version.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local ChatCompat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChatCompat"))

local TextFilter = {}

-- Returns the broadcast-safe string, or nil (show nothing).
function TextFilter.forBroadcast(text: any, fromUserId: number): string?
	return ChatCompat.filterText(function(s: string): any
		local result = TextService:FilterStringAsync(s, fromUserId)
		return result:GetNonChatStringForBroadcastAsync()
	end, text)
end

return TextFilter
