--!strict
-- Roblox badge ids, the single place they are written (T1-10). Every id is nil until the OWNER creates the badge in Creator Hub
-- (docs/BADGES.md lists the ten rows). Never invent an id: a nil id means server/BadgeAwards logs the badge once per server and
-- skips it (no award, no toast, no analytics). Keys are BadgeRules.KEYS. Numbers only.
local BadgeConfig = {}

BadgeConfig.IDS = {
	first_race = nil,
	first_win = nil,
	first_boss = nil,
	all_tracks = nil,
	three_star = nil,
	storm_racer = nil,
	dragon_slayer = nil,
	dragon_hunter = nil,
	dragon_bane = nil,
	stormbreaker = nil,
} :: { [string]: number? }

return BadgeConfig
