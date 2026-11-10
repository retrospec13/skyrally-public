--!strict
-- Rival bots with personalities and taunt bubbles (REMARKABLE Batch 2 item 19). Pure data and rules: no Roblox API, so
-- the Lune spec (tools/tests/getting_even_spec.luau) runs it as-is. server/AIRacers decides WHEN something happened
-- (a pass, a hit, a finish) and asks decide() whether this bot says something; client/RivalBubbles draws the bubble.
--
-- Rules for the lines: original and kind. Every bot teases, nobody insults, and every bot is a good sport at the
-- finish. No character, catchphrase or line from any other game. "{name}" is the player's DISPLAY name (never the
-- account name), shortened for the bubble; a line with no name to fill drops the placeholder cleanly.
--
-- Rate limits (so a bubble stays a surprise, never a chat log): one line per bot every BOT_GAP s (the rival every
-- RIVAL_GAP s), one line in the whole race every GLOBAL_GAP s, and "urgent" buckets (hits, revenge, finishes) skip the
-- global gap but still wait URGENT_GAP s per bot. A bot never says the same line twice in a row.
--
-- The rival: with exactly one player in a race (not a boss race), one of the three fastest bots is that player's rival
-- for the race (pickRival rotates it race by race). It talks more, wears a RIVAL tag, and AIRacers.rubberFactor holds
-- it in a tighter band around the player INSIDE the same RUBBER_BAND_MAX_BOOST / RUBBER_BAND_MAX_SLOW ceilings.

local BotPersonality = {}

export type Bucket = "start" | "pass" | "passed" | "hitBy" | "hitPlayer" | "revenge" | "finishAhead" | "finishBehind"

export type Voice = {
	botAt: { [number]: number }, -- last line time per bot id
	lastLine: { [number]: string }, -- last line per bot id (no repeats in a row)
	globalAt: number,
	count: number, -- lines said this race (log/SelfTest)
}

BotPersonality.BUCKETS = table.freeze({
	"start",
	"pass",
	"passed",
	"hitBy",
	"hitPlayer",
	"revenge",
	"finishAhead",
	"finishBehind",
}) :: { string }

-- Buckets that react to something the player did to the bot (or the bot to the player): never held back by the global
-- gap, because silence after a direct hit reads as a bug.
local URGENT: { [string]: boolean } = table.freeze({
	hitBy = true,
	hitPlayer = true,
	revenge = true,
	finishAhead = true,
	finishBehind = true,
})
BotPersonality.URGENT = URGENT

BotPersonality.BOT_GAP = 9
BotPersonality.RIVAL_GAP = 5
BotPersonality.URGENT_GAP = 3
BotPersonality.GLOBAL_GAP = 2.5

-- Chance a non-rival bot speaks when an event happens (the rival always does, rate limits permitting).
BotPersonality.CHANCE = table.freeze({
	start = 1,
	pass = 0.4,
	passed = 0.4,
	hitBy = 0.85,
	hitPlayer = 0.85,
	revenge = 1,
	finishAhead = 0.6,
	finishBehind = 0.6,
}) :: { [string]: number }

-- Roster name (PlaneConfig.AI_BOTS) -> personality.
BotPersonality.KIND_OF = table.freeze({
	["Ace Aero"] = "showboat",
	["Blaze Wing"] = "hothead",
	["Nova Sky"] = "sunny",
	["Zephyr Dash"] = "chill",
	["Indigo Comet"] = "dreamer",
	["Rosa Glide"] = "polite",
	["Sunny Rotor"] = "rookie",
}) :: { [string]: string }

-- Short title for the RIVAL tag ("RIVAL - THE SHOWBOAT").
BotPersonality.TITLE = table.freeze({
	showboat = "THE SHOWBOAT",
	hothead = "THE HOTHEAD",
	sunny = "THE SUNSHINE",
	chill = "THE CHILL ONE",
	dreamer = "THE STARGAZER",
	polite = "THE POLITE ONE",
	rookie = "THE ROOKIE",
}) :: { [string]: string }

local LINES: { [string]: { [string]: { string } } } = {
	showboat = {
		start = { "Cameras ready? Watch this.", "Try to keep up, {name}." },
		pass = { "And that's how it's done.", "Catch the replay, {name}.", "Ace on the inside." },
		passed = { "Okay {name}, that was stylish.", "I was setting up a pose.", "Nice move. I'll allow it." },
		hitBy = { "Not bad, {name}. Not bad.", "Careful with the paint job.", "Bold move, {name}." },
		hitPlayer = { "Clean hit. Perfect form.", "Nothing personal, {name}." },
		revenge = { "Miss me? I'm back.", "Payback, with style." },
		finishAhead = { "Another win for the highlight reel.", "Good race, {name}. I had fun." },
		finishBehind = { "You stole the spotlight, {name}.", "Fine. Next race is mine." },
	},
	hothead = {
		start = { "Engines hot. Let's go.", "I was built for this lap." },
		pass = { "Feel the heat, {name}.", "Coming through." },
		passed = { "Okay, you're fast.", "Not for long, {name}." },
		hitBy = { "Fine. I'm still in this.", "Nice shot, {name}. Last one." },
		hitPlayer = { "Direct hit. Keep going, {name}.", "Hot delivery." },
		revenge = { "Told you I'd be back.", "Payback's served." },
		finishAhead = { "That's how you finish.", "Good race, {name}. Rematch?" },
		finishBehind = { "Next time I'm faster.", "Great flying, {name}." },
	},
	sunny = {
		start = { "Good luck everyone. Let's race!", "Great day for a race." },
		pass = { "See you up front, {name}!", "Mind if I squeeze by?" },
		passed = { "Nice one, {name}! Great line.", "Wow, nice line!" },
		hitBy = { "Good shot! I'm still smiling.", "Nice hit, {name}. I'll bounce back." },
		hitPlayer = { "Sorry, {name}. Racing, right?", "Nothing personal!" },
		revenge = { "Round two, {name}.", "Even again. Let's keep going." },
		finishAhead = { "Great race, {name}!", "Fun one. Let's run it back." },
		finishBehind = { "You earned it, {name}!", "Fast finish! Rematch soon." },
	},
	chill = {
		start = { "Just ride the breeze.", "Deep breath. Then go." },
		pass = { "Smooth sailing, {name}.", "Catch you on the wind." },
		passed = { "Nice wind you caught.", "All good, {name}. Enjoy the view." },
		hitBy = { "Okay. Still cool.", "Fair enough. I felt that." },
		hitPlayer = { "No hard feelings, {name}.", "Just part of the race." },
		revenge = { "Balance restored.", "What goes around, {name}." },
		finishAhead = { "Smooth race, {name}.", "That was a sweet ride." },
		finishBehind = { "You flew that well, {name}.", "Respect. Good wind today." },
	},
	dreamer = {
		start = { "The stars are watching.", "Every lap is an orbit." },
		pass = { "Passing like a comet, {name}.", "Stardust for you, {name}." },
		passed = { "Shooting star, {name}.", "You shine when you're fast." },
		hitBy = { "I saw stars. Literally.", "Direct hit. Impressive, {name}." },
		hitPlayer = { "A meteor. That was me.", "Cosmic collision, {name}." },
		revenge = { "What goes around orbits back.", "The universe evens out." },
		finishAhead = { "Landing among the stars.", "Thanks for the orbit, {name}." },
		finishBehind = { "You outshone me, {name}.", "A stellar race." },
	},
	polite = {
		start = { "Best of luck, {name}.", "May the best pilot win." },
		pass = { "Coming through, {name}.", "Passing on your left." },
		passed = { "After you, {name}. Well flown.", "Well done, {name}." },
		hitBy = { "Fair play, {name}.", "Nicely aimed." },
		hitPlayer = { "Good racing, {name}.", "Sorry, {name}. Part of the game." },
		revenge = { "Now we're even, {name}.", "Fair is fair." },
		finishAhead = { "Thanks for the race, {name}.", "Great racing, {name}." },
		finishBehind = { "Congratulations, {name}.", "Well earned. Bravo." },
	},
	rookie = {
		start = { "Ready to learn from the best.", "Let's go. I've got this." },
		pass = { "I'm ahead of {name}!", "Passing! That felt good." },
		passed = { "How did you do that?", "Nice move, {name}. Noted." },
		hitBy = { "Got me. Lesson learned.", "Okay, I'll watch for that." },
		hitPlayer = { "It worked! Sorry, {name}.", "Direct hit. Nice." },
		revenge = { "Got you back, {name}.", "I remembered. Payback." },
		finishAhead = { "I finished strong!", "Good race, {name}." },
		finishBehind = { "Great race, {name}.", "Next time I catch you." },
	},
}
for _, buckets in LINES do
	for _, list in buckets do
		table.freeze(list)
	end
	table.freeze(buckets)
end
table.freeze(LINES)
BotPersonality.LINES = LINES

BotPersonality.DEFAULT = "sunny"

function BotPersonality.forName(name: any): string
	if type(name) == "string" then
		local kind = BotPersonality.KIND_OF[name]
		if kind then
			return kind
		end
	end
	return BotPersonality.DEFAULT
end

function BotPersonality.newVoice(): Voice
	return { botAt = {}, lastLine = {}, globalAt = -math.huge, count = 0 }
end

-- May bot botId speak now? rival: the race's rival (shorter gap); bucket decides urgency.
function BotPersonality.canSpeak(voice: Voice, botId: number, now: number, rival: boolean, bucket: string): boolean
	local urgent = URGENT[bucket] == true
	local last = voice.botAt[botId]
	local gap = if urgent then BotPersonality.URGENT_GAP elseif rival then BotPersonality.RIVAL_GAP else BotPersonality.BOT_GAP
	if last and now - last < gap then
		return false
	end
	if not urgent and now - voice.globalAt < BotPersonality.GLOBAL_GAP then
		return false
	end
	return true
end

-- A line for this personality and bucket, never the one this bot said last. rand: () -> [0, 1).
function BotPersonality.pick(voice: Voice, botId: number, personality: string, bucket: string, rand: () -> number): string?
	local set = LINES[personality] or LINES[BotPersonality.DEFAULT]
	local list = set[bucket]
	if not list or #list == 0 then
		return nil
	end
	local last = voice.lastLine[botId]
	local i = math.clamp(math.floor(rand() * #list) + 1, 1, #list)
	if list[i] == last and #list > 1 then
		i = i % #list + 1
	end
	return list[i]
end

-- The whole decision: chance (rival always), rate limits, pick, and the bookkeeping. Returns the raw line or nil.
function BotPersonality.decide(voice: Voice, botId: number, personality: string, bucket: string, now: number, rival: boolean, rand: () -> number): string?
	if not BotPersonality.canSpeak(voice, botId, now, rival, bucket) then
		return nil
	end
	local chance = if rival then 1 else (BotPersonality.CHANCE[bucket] or 0)
	if chance < 1 and rand() >= chance then
		return nil
	end
	local line = BotPersonality.pick(voice, botId, personality, bucket, rand)
	if not line then
		return nil
	end
	voice.botAt[botId] = now
	voice.lastLine[botId] = line
	voice.globalAt = now
	voice.count += 1
	return line
end

-- Fills "{name}" with a display name cut to 12 characters; with no name the placeholder (and a comma or space that
-- led into it) goes, so "Good race, {name}!" reads "Good race!".
function BotPersonality.format(line: string, name: any): string
	if type(name) == "string" and name ~= "" then
		local short = name
		local n = utf8.len(name)
		if n and n > 12 then
			local cut = utf8.offset(name, 12)
			short = if cut then string.sub(name, 1, cut - 1) .. "." else name
		end
		-- The name is data, not a pattern: escape % so gsub never reads it as a capture reference.
		local safe = string.gsub(short, "%%", "%%%%")
		return (string.gsub(line, "{name}", safe))
	end
	local out = string.gsub(line, ",? ?{name}", "")
	out = string.gsub(out, "^%s+", "")
	return out
end

-- The rival for a race: one of the three fastest bots present (lowest roster ids), rotating with the race counter so
-- each personality gets its turn. botIds sorted or not; nil when there is no bot.
function BotPersonality.pickRival(botIds: { number }, seq: number): number?
	if #botIds == 0 then
		return nil
	end
	local ids = table.clone(botIds)
	table.sort(ids)
	local pool = math.min(3, #ids)
	return ids[(math.floor(seq) % pool) + 1]
end

return BotPersonality
