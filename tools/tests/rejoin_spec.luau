-- Joining a server that is on a race map (shared/RaceFlowRules; owner 2026-10-20: "once a race has ended ... the player
-- should not be thrown back into the race"): the join decision (stay or hub), the rejoin grace record and the
-- abandoned-race end. Nothing about a race is saved in the profile; the leave record is server memory only, so a record
-- from another server, an older race, a stale time or an old/garbled shape is never a resume.
return function(h)
	local R = h.require("src/shared/RaceFlowRules.luau")
	local JOB = "job-a"

	local function ctx(over: { [string]: any }): any
		local c: { [string]: any } = { mode = "race", switching = false, ended = false, othersActive = 0, left = nil, jobId = JOB, raceId = 4, now = 1000 }
		for k, v in over do
			c[k] = v
		end
		return c
	end

	h.test("canResume: same server, same race, inside the grace window only", function()
		h.eq(R.REJOIN_GRACE, 60)
		h.ok(R.canResume({ jobId = JOB, raceId = 4, at = 990 }, JOB, 4, 1000), "10 s ago")
		h.ok(R.canResume({ jobId = JOB, raceId = 4, at = 940 }, JOB, 4, 1000), "exactly the grace")
		h.ok(not R.canResume({ jobId = JOB, raceId = 4, at = 939 }, JOB, 4, 1000), "stale timestamp")
		h.ok(not R.canResume({ jobId = JOB, raceId = 4, at = 1000 - 86400 }, JOB, 4, 1000), "a day old")
		h.ok(not R.canResume({ jobId = JOB, raceId = 4, at = 1010 }, JOB, 4, 1000), "a time in the future")
		h.ok(not R.canResume({ jobId = "job-b", raceId = 4, at = 990 }, JOB, 4, 1000), "different JobId")
		h.ok(not R.canResume({ jobId = JOB, raceId = 3, at = 990 }, JOB, 4, 1000), "an older race on this server")
	end)

	h.test("canResume: missing fields, wrong types and old save shapes are never a resume", function()
		h.ok(not R.canResume(nil, JOB, 4, 1000), "no record")
		h.ok(not R.canResume({}, JOB, 4, 1000), "empty record")
		h.ok(not R.canResume({ raceId = 4, at = 990 }, JOB, 4, 1000), "no jobId")
		h.ok(not R.canResume({ jobId = JOB, at = 990 }, JOB, 4, 1000), "no raceId")
		h.ok(not R.canResume({ jobId = JOB, raceId = 4 }, JOB, 4, 1000), "no time")
		h.ok(not R.canResume({ jobId = JOB, raceId = 4, at = 990 }, JOB, nil, 1000), "no race running")
		h.ok(not R.canResume({ jobId = "", raceId = 4, at = 990 }, "", 4, 1000), "blank JobId on both sides")
		h.ok(not R.canResume({ jobId = JOB, raceId = "4", at = "990" }, JOB, 4, 1000), "strings, not numbers")
		h.ok(not R.canResume("snow1", JOB, 4, 1000), "a bare track key")
		h.ok(not R.canResume({ currentTrack = "snow1", inRace = true, lastMap = "SNOW-1" }, JOB, 4, 1000), "legacy-style fields")
	end)

	h.test("joinStep: the hub, a load in progress and a race others play keep the map", function()
		h.eq(R.joinStep(ctx({ mode = "hub" })), "stay")
		local boot = ctx({})
		boot.mode = nil
		h.eq(R.joinStep(boot), "stay", "no mode yet (boot)")
		h.eq(R.joinStep(ctx({ switching = true })), "stay", "the load seats him")
		h.eq(R.joinStep(ctx({ othersActive = 1 })), "stay", "late join beside a human racing")
		h.eq(R.joinStep(ctx({ othersActive = 2, ended = true })), "stay", "others are on the results: their vote decides")
	end)

	h.test("joinStep: a race nobody else plays ends (old race, finished race, another server's record)", function()
		h.eq(R.joinStep(ctx({})), "hub", "fresh joiner, nobody active: never thrown into the old race")
		h.eq(R.joinStep(ctx({ ended = true })), "hub", "race ended (results shown)")
		h.eq(R.joinStep(ctx({ mode = "boss" })), "hub")
		h.eq(R.joinStep(ctx({ mode = "stormcup" })), "hub")
		h.eq(R.joinStep(ctx({ left = { jobId = "job-b", raceId = 4, at = 990 } })), "hub", "different JobId")
		h.eq(R.joinStep(ctx({ left = { jobId = JOB, raceId = 4, at = 100 } })), "hub", "stale timestamp")
		h.eq(R.joinStep(ctx({ left = { jobId = JOB, raceId = 3, at = 990 } })), "hub", "a race that was replaced")
		h.eq(R.joinStep(ctx({ left = {} })), "hub", "missing fields")
		h.eq(R.joinStep(ctx({ left = { inRace = true, lastMap = "SNOW-1" } })), "hub", "old format")
		h.eq(R.joinStep(ctx({ othersActive = "2" })), "hub", "a garbled count is nobody")
	end)

	h.test("joinStep: his own race, still running on this server, within the grace window", function()
		h.eq(R.joinStep(ctx({ left = { jobId = JOB, raceId = 4, at = 975 } })), "stay", "25 s ago: back in")
		h.eq(R.joinStep(ctx({ left = { jobId = JOB, raceId = 4, at = 975 }, ended = true })), "hub", "it ended meanwhile")
	end)

	h.test("abandoned: the field is home and no human is racing; never a battle", function()
		h.ok(R.abandoned(true, 0, false), "field done, nobody racing")
		h.ok(not R.abandoned(true, 1, false), "a human is still racing: he may finish")
		h.ok(not R.abandoned(false, 0, false), "bots still racing (or no field)")
		h.ok(not R.abandoned(true, 0, true), "a battle ends itself")
	end)
end
