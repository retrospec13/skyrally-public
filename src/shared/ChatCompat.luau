--!strict
-- ChatCompat: one place that knows which chat system the place runs (T1-11 prep). Pure logic, no Roblox globals;
-- tools/tests/chat_compat_spec.luau runs it under Lune. Live adapters: client/ChatCompatClient, server/TextFilter,
-- and the legacy /admin hook in server/AdminService. The place must work under BOTH Enum.ChatVersion values so the owner can
-- flip the Creator Hub / Rojo setting with no code change (docs/CHAT_MIGRATION.md).
local ChatCompat = {}

export type Version = "text" | "legacy"

ChatCompat.MAX_TEXT = 200 -- longest player string we pass to the filter (Roblox chat limit)
ChatCompat.SYSTEM_CHANNELS = { "RBXSystem", "RBXGeneral" } -- TextChatService channel preference for system lines
ChatCompat.SYSTEM_COLOR = { 255, 220, 140 } -- legacy ChatMakeSystemMessage colour (cream, matches the HUD)

-- Enum.ChatVersion name (or EnumItem.Name) -> "text" | "legacy". Anything unknown is "text" (Roblox's default and the
-- migration target), never "legacy", so a new enum value cannot silently re-enable the deprecated path.
function ChatCompat.detect(versionName: any): Version
	if versionName == "LegacyChatService" then
		return "legacy"
	end
	return "text"
end

-- Where each feature lives per chat version. Admin: TextChatService has a client-local TextChatCommand (AdminPanel); legacy
-- never fires it, so the server hooks the legacy ChatService command step. Exactly one of the two is active at a time.
function ChatCompat.plan(version: Version): { adminClientCommand: boolean, adminServerHook: boolean, layoutKind: string, systemKind: string }
	if version == "legacy" then
		return { adminClientCommand = false, adminServerHook = true, layoutKind = "setcore", systemKind = "setcore" }
	end
	return { adminClientCommand = true, adminServerHook = false, layoutKind = "chatwindow", systemKind = "textchannel" }
end

-- First channel from `names` present in the available list (a set or an array of channel names); nil when none.
function ChatCompat.pickChannel(available: { string }): string?
	local have: { [string]: boolean } = {}
	for _, n in available do
		have[n] = true
	end
	for _, want in ChatCompat.SYSTEM_CHANNELS do
		if have[want] then
			return want
		end
	end
	return nil
end

ChatCompat.MAX_SYSTEM_TEXT = 2000 -- system lines are our own text (e.g. the multi-line "/admin help"); cap only runaway strings

-- A system line to show: keeps line breaks (multi-line admin replies such as "/admin help"), turns every other control
-- character into a space, trims, caps the length. nil when nothing printable remains.
function ChatCompat.cleanSystemText(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local s = string.gsub(text, "\r\n", "\n")
	s = string.gsub(s, "[^%S\n]", " ") -- whitespace other than \n -> space
	s = string.gsub(s, "[%c]", function(c: string): string
		return if c == "\n" then c else " "
	end)
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	if s == "" then
		return nil
	end
	if #s > ChatCompat.MAX_SYSTEM_TEXT then
		s = string.sub(s, 1, ChatCompat.MAX_SYSTEM_TEXT)
	end
	return s
end

-- Layout from ChatLayoutRules.compute's Config. text -> ChatWindowConfiguration properties; legacy -> the two SetCore values
-- (ChatWindowPosition / ChatWindowSize as scale+offset pairs), bottom-left or centre-left like the TextChatService window.
function ChatCompat.layoutPlan(version: Version, cfg: any): any
	if version == "legacy" then
		local ys = if cfg.vertical == "Bottom" then 1 - cfg.heightScale else (1 - cfg.heightScale) / 2
		return {
			kind = "setcore",
			position = { xs = 0, xo = 0, ys = ys, yo = 0 },
			size = { xs = cfg.widthScale, xo = 0, ys = cfg.heightScale, yo = 0 },
		}
	end
	return {
		kind = "chatwindow",
		props = {
			Enabled = true,
			HorizontalAlignment = "Left",
			VerticalAlignment = cfg.vertical,
			WidthScale = cfg.widthScale,
			HeightScale = cfg.heightScale,
			TextSize = cfg.textSize,
			BackgroundTransparency = cfg.backgroundTransparency,
		},
	}
end

-- Player-typed text must go through TextService:FilterStringAsync before anyone else sees it. `filterFn(text)` returns the
-- filtered string for broadcast (the adapter wraps FilterStringAsync + GetNonChatStringForBroadcastAsync). Returns the
-- safe string, or nil when the input is not a string, is empty, or the filter errored/returned a non-string: the caller then
-- shows nothing (never the raw text).
function ChatCompat.filterText(filterFn: (string) -> any, text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local s = string.gsub(text, "[%c]", " ")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	if s == "" then
		return nil
	end
	if #s > ChatCompat.MAX_TEXT then
		s = string.sub(s, 1, ChatCompat.MAX_TEXT)
	end
	local ok, out = pcall(filterFn, s)
	if not ok or type(out) ~= "string" then
		return nil
	end
	return out
end

return ChatCompat
