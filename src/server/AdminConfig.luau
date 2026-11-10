--!strict
-- Server-only administrator policy. Zero disables production access.
local function create(adminUserId: number)
local AdminConfig = {}

AdminConfig.ADMIN_USER_ID = adminUserId

-- Studio-only test path: with RunService:IsStudio() and this workspace attribute set to true in Edit before Play, the Studio
-- test player counts as admin (the F5 proof when the Studio account is not ADMIN_USER_ID). Live servers ignore it.
AdminConfig.STUDIO_ATTRIBUTE = "QAAdminStudio"
-- Optional (Studio only): the UserId of the one test player the Studio path makes admin; unset = the first player to join
-- the Studio session. A multi-client Local Server therefore has exactly one Studio admin.
AdminConfig.STUDIO_USER_ATTRIBUTE = "QAAdminStudioUserId"

AdminConfig.AWARD_SOURCE = "admin:grant" -- SaveService award source of every admin grant (the only source awardBypass opens)
AdminConfig.CASH_SOURCE = "admin:grant" -- Economy earn source of an admin Cash grant (not multiplied; analytics sku "admin")

-- No player attribute marks the admin (attributes replicate to every client): his client asks the AdminRequest remote for
-- "status" and shows the ADMIN button only when the server answers. Every other client gets nil and shows nothing.

function AdminConfig.isAdmin(userId: any): boolean
	return AdminConfig.ADMIN_USER_ID > 0 and type(userId) == "number" and userId == AdminConfig.ADMIN_USER_ID
end

-- The Studio test path: in Studio with the workspace attribute exactly true, ONE test player counts as admin: studioUserId,
-- which the server picks itself (workspace QAAdminStudioUserId, else the first player who joined this Studio session), so
-- a multi-client Local Server keeps every other client on the normal gates. isStudio comes from RunService:IsStudio() on
-- the server, never from a client; a live server passes false and the override is off whatever the attributes say.
function AdminConfig.studioOverride(isStudio: any, attr: any, userId: any, studioUserId: any): boolean
	return isStudio == true and attr == true and type(userId) == "number" and userId == studioUserId
end

function AdminConfig.isAdminPlayer(userId: any, isStudio: any, attr: any, studioUserId: any): boolean
	return AdminConfig.isAdmin(userId) or AdminConfig.studioOverride(isStudio, attr, userId, studioUserId)
end

-- Award gates in SaveService open only for the admin's own explicit grants ("admin:" sources, which only server/AdminService
-- writes). The map-access bypass is runtime-only: a race, key or boss he wins on a map he reached through the bypass is
-- refused by the normal gate ("not unlocked"), so the bypass never writes progression into his save. Idempotency (held =
-- noop) is checked before any gate either way. flags: the admin's AdminRules.Flags (nil = not admin).
function AdminConfig.awardBypass(flags: any, source: any): boolean
	return flags ~= nil and type(source) == "string" and string.sub(source, 1, 6) == "admin:"
end

AdminConfig.forUserId = create
return table.freeze(AdminConfig)
end

return create(0)
