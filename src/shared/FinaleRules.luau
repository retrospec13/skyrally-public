--!strict
-- Finish payoffs (REMARKABLE Batch 2 items 23, 24, 27, 30): the photo finish polaroid, the podium ceremony with the
-- Participation Crate, Token Homecoming and the Garage turntable. Pure rules only (no Instances, no clock), specced in
-- tools/tests/finale_spec.luau; the moments themselves are client/Polaroid, client/PodiumCeremony,
-- client/TokenHomecoming, client/PortalWake and client/GarageTurntable, and the server half of the photo finish is
-- server/PhotoFinish. Nothing here awards anything: every number a card shows is the server's.
local FinaleRules = {}

---------------------------------------------------------------------------------------------------- photo finish (23)

FinaleRules.PHOTO_GAP = 0.5 -- s between two adjacent finishers (one of them a player) for a polaroid
FinaleRules.TAKEOVER_GAP = 0.6 -- s: the local estimate that earns the side-on photo cam before the server confirms
FinaleRules.PHOTO_MODES = { race = true, quickrace = true, boss = true, rematch = true, coin = true, stormcup = true } :: { [string]: boolean }

export type FinishEntry = { name: string, isPlayer: boolean, time: number, rank: number }
export type PhotoNotice = { name: string, rival: string, rivalIsPlayer: boolean, gap: number, won: boolean, rank: number, rivalRank: number }

-- Entry i of the finish order just landed. If it and the racer before it finished within gapMax, every PLAYER of the
-- pair gets a notice (a bot needs no polaroid). Returns {} otherwise.
function FinaleRules.photoNotices(order: { FinishEntry }, i: number, gapMax: number?): { PhotoNotice }
	local out: { PhotoNotice } = {}
	local b = order[i]
	local a = order[i - 1]
	if not a or not b then
		return out
	end
	local gap = b.time - a.time
	if gap < 0 or gap > (gapMax or FinaleRules.PHOTO_GAP) then
		return out
	end
	if a.isPlayer then
		table.insert(out, { name = a.name, rival = b.name, rivalIsPlayer = b.isPlayer, gap = gap, won = true, rank = a.rank, rivalRank = b.rank })
	end
	if b.isPlayer then
		table.insert(out, { name = b.name, rival = a.name, rivalIsPlayer = a.isPlayer, gap = gap, won = false, rank = b.rank, rivalRank = a.rank })
	end
	return out
end

-- The big word on the polaroid.
function FinaleRules.photoVerdict(gap: number): string
	if gap < 0.005 then
		return "DEAD HEAT!"
	elseif gap < 0.05 then
		return "BY A WHISKER!"
	elseif gap < 0.15 then
		return "BY A NOSE!"
	elseif gap < 0.3 then
		return "BY A BUMPER!"
	end
	return "PHOTO FINISH!"
end

local function gapText(gap: number): string
	return string.format("%.2f s", math.max(0.01, gap))
end

-- The handwritten line under the photo. Kind either way (REMARKABLE ground rules: no "loser" wording).
function FinaleRules.photoCaption(won: boolean, gap: number, rival: string): string
	local who = string.sub(rival, 1, 18)
	if gap < 0.005 then
		return if won then string.format("You and %s - the judges gave it to you!", who) else string.format("You and %s - a hair's breadth!", who)
	end
	if won then
		return string.format("You pipped %s by %s", who, gapText(gap))
	end
	return string.format("%s got there by %s - so close!", who, gapText(gap))
end

-- Studs between the two noses in the staged photo: the server gap at the finisher's speed, kept inside the frame.
function FinaleRules.photoStage(gap: number, speed: number): number
	return math.clamp(math.abs(gap) * math.max(0, speed), 0.6, 12)
end

-- The local photo cam after crossing: the racer just ahead finished within the window (the server's own times in the
-- RaceFinished standings), or a rival's car is within the window behind at the finisher's speed.
function FinaleRules.shouldTakeover(aheadGap: number?, behindDist: number?, speed: number): boolean
	if aheadGap and aheadGap >= 0 and aheadGap <= FinaleRules.TAKEOVER_GAP then
		return true
	end
	if behindDist and speed > 1 then
		return behindDist / speed <= FinaleRules.TAKEOVER_GAP
	end
	return false
end

-- The gap to the racer one place ahead in a RaceFinished standings list (server finish times), or nil.
function FinaleRules.aheadGap(standings: { any }, myRank: number): number?
	local me, ahead = nil, nil
	for _, row in standings do
		if type(row) == "table" then
			if row.rank == myRank then
				me = row
			elseif row.rank == myRank - 1 then
				ahead = row
			end
		end
	end
	if not me or not ahead or not ahead.finished or type(me.finishTime) ~= "number" or type(ahead.finishTime) ~= "number" then
		return nil
	end
	return me.finishTime - ahead.finishTime
end

---------------------------------------------------------------------------------------------------- podium (30)

FinaleRules.CEREMONY_SECONDS = 4
FinaleRules.CEREMONY_MODES = FinaleRules.PHOTO_MODES

function FinaleRules.ceremonyEligible(mode: any, standingsCount: number): boolean
	return FinaleRules.CEREMONY_MODES[tostring(mode)] == true and standingsCount >= 3
end

-- Skippable from the second ceremony on (the first one always plays: it is the payoff).
function FinaleRules.canSkip(viewsBefore: number): boolean
	return viewsBefore >= 1
end

export type PodiumPick = { first: any?, second: any?, third: any?, me: any?, meOnPodium: boolean }

-- Top three by rank and the local entry (isPlayer and name == myName).
function FinaleRules.podium(standings: { any }, myName: string): PodiumPick
	local pick: PodiumPick = { first = nil, second = nil, third = nil, me = nil, meOnPodium = false }
	for _, row in standings do
		if type(row) == "table" then
			if row.rank == 1 then
				pick.first = row
			elseif row.rank == 2 then
				pick.second = row
			elseif row.rank == 3 then
				pick.third = row
			end
			if row.isPlayer == true and row.name == myName then
				pick.me = row
			end
		end
	end
	pick.meOnPodium = pick.me ~= nil and type(pick.me.rank) == "number" and pick.me.rank <= 3
	return pick
end

local CRATE_LINES = { "GOOD EFFORT!", "NICE DRIVING!", "KEEP AT IT!", "WHAT A RIDE!", "STYLE POINTS!" }

-- What the Participation Crate holds for a finisher off the podium: the Gears the server already paid this race (when
-- the Garage shows Gears), else a cardboard medal with a kind line picked by rank (stable for a given rank).
function FinaleRules.crateContents(gears: any, garageOn: boolean, rank: number): { kind: string, text: string }
	if garageOn and type(gears) == "table" and type(gears.gears) == "number" and gears.gears > 0 then
		return { kind = "gears", text = string.format("+%d CASH", math.floor(gears.gears)) }
	end
	local i = ((math.max(1, math.floor(rank)) - 1) % #CRATE_LINES) + 1
	return { kind = "medal", text = CRATE_LINES[i] }
end

---------------------------------------------------------------------------------------------------- token flight (24)

FinaleRules.TOKEN_FLIGHT_SECONDS = 0.85
FinaleRules.TOKEN_HOLD_SECONDS = 0.45 -- the token pops and spins where it was won before it flies

-- Point on the token's arc (screen px) at k = 0..1: a quadratic curve that bows up by `lift` px, eased in so it leaves
-- slowly and lands fast.
function FinaleRules.tokenArc(x0: number, y0: number, x1: number, y1: number, k: number, lift: number): (number, number)
	local t = math.clamp(k, 0, 1)
	t = t * t * (3 - 2 * t) * 0.35 + t * t * 0.65
	local cx = (x0 + x1) * 0.5
	local cy = math.min(y0, y1) - lift
	local u = 1 - t
	return u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1
end

-- Portal wake: zones open in `states` (the server's PortalStates) that `seen` has not seen open, in board order.
function FinaleRules.newlyOpened(seen: { [string]: boolean }, states: { any }): { string }
	local out: { string } = {}
	for _, st in states do
		if type(st) == "table" and st.open == true and type(st.zone) == "string" and not seen[st.zone] then
			table.insert(out, st.zone)
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------- turntable (27)

FinaleRules.TURN_AUTO = 22 -- deg/s idle spin
FinaleRules.TURN_FRICTION = 2.2 -- 1/s decay of a flick back toward the idle spin
FinaleRules.TURN_MAX = 900 -- deg/s cap on a flick

-- One step of the turntable: a dragged table follows the finger (vel set by the caller); a released one coasts with
-- friction back toward the idle spin.
function FinaleRules.turnStep(angle: number, vel: number, dt: number, dragging: boolean): (number, number)
	local v = math.clamp(vel, -FinaleRules.TURN_MAX, FinaleRules.TURN_MAX)
	if not dragging then
		local target = if v < 0 then -FinaleRules.TURN_AUTO else FinaleRules.TURN_AUTO
		v = target + (v - target) * math.exp(-FinaleRules.TURN_FRICTION * dt)
	end
	return (angle + v * dt) % 360, v
end

-- Rev: a second REV within this window of the last one hits the limiter (wheelie + backfire).
FinaleRules.REDLINE_WINDOW = 0.6

function FinaleRules.revLevel(lastRevAt: number?, now: number, level: number): number
	if lastRevAt and now - lastRevAt <= FinaleRules.REDLINE_WINDOW then
		return math.min(3, level + 1)
	end
	return 1
end

return FinaleRules
