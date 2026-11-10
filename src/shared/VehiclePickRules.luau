--!strict
-- Pre-race vehicle pick (economy v3 phase 6; SKYRALLY_ECONOMY_V3 section 4 "Garage tab + pre-race pick"). Pure: no
-- Instances, no clock; client/VehiclePick draws it, tools/tests/avatar_spec.luau checks it.
-- The Garage is closed before a race (GarageModel.canOpen), so the quick swap lives in the hub, where the next race is
-- joined: on an arch's apron (the paving just in front of a portal, slowed down) and, for the player who opened it,
-- while a portal lobby gathers racers (never on every hub screen: no server-wide popups for lobbies). It lists only OWNED avatars of the class the track uses, the last pick preselected; one tap swaps. The pick
-- applies at the race spawn (server AvatarSelect). Nobody is pulled anywhere by it: it only changes looks.
local VehiclePickRules = {}

VehiclePickRules.APRON_DEPTH = 70 -- studs of plaza in front of an arch's veil that count as its apron
VehiclePickRules.APRON_HALF_WIDTH = 24 -- either side of the arch axis (the veil is 24 wide)
VehiclePickRules.APRON_MAX_SPEED = 28 -- studs/s: slowed down on the apron (a drive-through never pops the strip)
VehiclePickRules.CARD_W = 112 -- px at S = 1
VehiclePickRules.CARD_H = 44 -- a 44 px touch target; the strip rect (HudLayoutRules.vehicleStrip) is this plus its padding (6 px desktop, none on touch)
VehiclePickRules.MAX_CARDS = 8 -- the strip scrolls past this many
VehiclePickRules.COLLAPSE_SECONDS = 6 -- an expanded strip folds back into the chip after this long, or at once after a pick

export type Rect = { x: number, y: number, w: number, h: number }

-- Whether a position stands on an arch's apron. archCf: the PortalShimmer frame (LookVector out of the plaza, so the
-- plaza side is negative along it).
function VehiclePickRules.onApron(pos: Vector3, archCf: CFrame): boolean
	local rel = pos - archCf.Position
	local along = rel:Dot(archCf.LookVector)
	local lateral = rel:Dot(archCf.RightVector)
	return along < 0 and along >= -VehiclePickRules.APRON_DEPTH and math.abs(lateral) <= VehiclePickRules.APRON_HALF_WIDTH
end

export type Context = {
	enabled: boolean, -- AvatarConfig.ENABLED and the profile loaded
	mode: string?, -- workspace.RaceMode
	switching: boolean, -- workspace.TrackSwitching
	lobbyClass: string?, -- the class of the lobby's track while a lobby gathers racers, else nil
	lobbyMine: boolean?, -- this player opened that lobby (workspace LobbyOpenerId); anyone else gets the apron only
	apronClass: string?, -- the class of the arch whose apron the vehicle is on, else nil
	speed: number, -- the vehicle's speed (studs/s)
	owned: number, -- owned avatars of that class
	dismissed: boolean?, -- the player closed the strip for this apron visit / lobby
	overlay: boolean?, -- the Garage is open: the chip steps aside (a lobby banner does not: own-lobby pick)
}

-- (show, class). Only in the hub; the player's own lobby wins over an apron (another player's lobby never pops it);
-- never for a class with fewer than two owned avatars (nothing to swap).
function VehiclePickRules.decide(ctx: Context): (boolean, string?)
	if not ctx.enabled or ctx.switching or ctx.dismissed or ctx.overlay then
		return false, nil
	end
	if ctx.mode ~= nil and ctx.mode ~= "" and ctx.mode ~= "hub" then
		return false, nil
	end
	local class = if ctx.lobbyMine == true then ctx.lobbyClass else nil
	if class == nil and ctx.apronClass ~= nil and ctx.speed <= VehiclePickRules.APRON_MAX_SPEED then
		class = ctx.apronClass
	end
	if class == nil or ctx.owned < 2 then
		return false, nil
	end
	return true, class
end

-- Card size inside the docked strip rect (HudLayoutRules.vehicleStrip): 44 px cards centred vertically, width scaled
-- with S but never under 88. Whether an expanded strip should fold back: after COLLAPSE_SECONDS, or when picked.
function VehiclePickRules.cardSize(strip: Rect, S: number): (number, number)
	return math.max(88, math.floor(VehiclePickRules.CARD_W * S + 0.5)), math.min(VehiclePickRules.CARD_H, strip.h)
end

function VehiclePickRules.shouldCollapse(expandedAt: number, now: number, picked: boolean): boolean
	return picked or now - expandedAt >= VehiclePickRules.COLLAPSE_SECONDS
end

return VehiclePickRules
