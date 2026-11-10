--!strict
-- The avatar a player's next vehicle is built with (economy v3 phase 6). FlightServer and CarServer ask here at spawn;
-- the answer is the saved pick for that class (AvatarRules.settle keeps it owned and valid), or the class starter
-- while the profile is still loading, has no session, or the picker is off. Looks only: the builders keep the same
-- hull for every avatar.
-- Owner admin (DECISIONS D22a "all vehicles unlocked"): server/AdminService sets adminVehicles. While it answers true
-- for a player (his account only, runtime switch, default ON), effective() lays AvatarRules.overlay over his saved state:
-- every avatar owned, and a pick of an avatar his save does not own is kept HERE in server memory (runtimePick), never in
-- the save. Everyone else gets their saved state untouched.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AvatarRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AvatarRules"))
local AdminRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminRules"))

local AvatarSelect = {}

-- Set by server/AdminService: player -> his runtime "all vehicles unlocked" switch is on. nil = nobody.
AvatarSelect.adminVehicles = nil :: ((player: Player) -> boolean)?
AvatarSelect.log = function(line: string)
	print(line)
end

-- Runtime picks of not-owned avatars under the admin switch (class -> key), per player; gone when he leaves.
local runtime: { [Player]: { [string]: string } } = setmetatable({}, { __mode = "k" }) :: any

function AvatarSelect.allUnlocked(player: Player): boolean
	local hook = AvatarSelect.adminVehicles
	if hook == nil then
		return false
	end
	local ok, on = pcall(hook, player)
	return ok and on == true
end

-- The avatars state the picker, the select request and the spawn read (the saved table itself unless the admin switch
-- is on for this player).
function AvatarSelect.effective(player: Player, avatars: any): any
	if type(avatars) ~= "table" or not AvatarSelect.allUnlocked(player) then
		return avatars
	end
	return AvatarRules.overlay(avatars, true, runtime[player])
end

local function attrOf(class: string): string?
	return if class == "plane" then "AvatarPlane" elseif class == "car" then "AvatarCar" else nil
end

-- Puts the picks attribute back to the saved pick (a dropped runtime pick must not leave the cue on the runtime key).
local function restoreAttr(player: Player, avatars: any, class: string)
	local attr = attrOf(class)
	if attr and type(avatars) == "table" and type(avatars.selected) == "table" then
		player:SetAttribute(attr, avatars.selected[class])
	end
end

-- A pick under the admin switch. Returns true when it was kept at runtime (not owned in the save), false when the
-- caller should take the normal saved path (the switch is off, or the save owns the avatar: then any runtime pick for
-- the class is dropped so the saved pick shows).
function AvatarSelect.runtimePick(player: Player, avatars: any, key: string): boolean
	local row = AvatarRules.row(key)
	if not row then
		return false
	end
	local saved = type(avatars) == "table" and AvatarRules.owns(avatars, key, false)
	if saved or not AvatarSelect.allUnlocked(player) then
		local picks = runtime[player]
		if picks and picks[row.class] ~= nil then
			picks[row.class] = nil
			restoreAttr(player, avatars, row.class)
		end
		return false
	end
	local picks = runtime[player] or {}
	runtime[player] = picks
	picks[row.class] = key
	-- The picks attribute is the clients' refetch cue (Garage, pre-race strip); SaveService sets it back to the saved
	-- pick on its next republish, which only refetches the overlay view again.
	local attr = attrOf(row.class)
	if attr then
		player:SetAttribute(attr, key)
	end
	AvatarSelect.log(string.format("%s action=vehicle user=%d result=select key=%s class=%s saved=false", AdminRules.LOG, player.UserId, key, row.class))
	return true
end

function AvatarSelect.clearRuntime(player: Player)
	local picks = runtime[player]
	runtime[player] = nil
	if picks and next(picks) ~= nil then
		-- The switch went off: the picks attribute goes back to the saved picks so the Garage / pre-race strip refetch.
		local ok, profile = pcall(function(): any
			local SaveService = require(script.Parent:WaitForChild("SaveService")) :: any
			return SaveService.get(player)
		end)
		if ok and type(profile) == "table" then
			for class in picks do
				restoreAttr(player, profile.avatars, class)
			end
		end
	end
end

function AvatarSelect.forPlayer(player: Player, class: string): string?
	local starter = AvatarRules.starter(class)
	if not AvatarRules.config.ENABLED then
		return starter
	end
	-- T1-5 live kill switch "avatars": every vehicle spawns with its class starter (saved picks untouched). Fail open.
	local okLive, on = pcall(function(): boolean
		return (require(script.Parent:WaitForChild("LiveOps")) :: any).isOn("avatars")
	end)
	if okLive and on == false then
		return starter
	end
	local ok, profile = pcall(function(): any
		local SaveService = require(script.Parent:WaitForChild("SaveService")) :: any
		return SaveService.get(player)
	end)
	if not ok or type(profile) ~= "table" or type(profile.avatars) ~= "table" or type(profile.avatars.selected) ~= "table" then
		return starter
	end
	local state = AvatarSelect.effective(player, profile.avatars)
	local pick = state.selected[class]
	local row = AvatarRules.row(pick)
	if row and row.class == class and state.owned[pick] == true then
		return pick
	end
	return starter
end

return AvatarSelect
