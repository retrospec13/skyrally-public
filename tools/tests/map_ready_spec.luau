-- v37 client-ready handshake (shared/MapReadyRules): the countdown waits for every human's answer or the timeout, a
-- client holds the map at 90 percent of the server's count, a freeze restarts the smooth-frame run, and an answer counts
-- only for a token the server is still waiting on.
return function(h)
	local R = h.require("src/shared/MapReadyRules.luau")

	h.test("verdict: all answered starts at once; missing waits until the timeout; nobody to wait for is all", function()
		h.eq(R.verdict({ 1, 2 }, { [1] = true, [2] = true }, 0.2), "all")
		local v, missing = R.verdict({ 1, 2 }, { [1] = true }, 3)
		h.eq(v, "wait")
		h.eq(missing, 1)
		h.eq(R.verdict({ 1, 2 }, { [1] = true }, R.TIMEOUT), "timeout", "one bad client cannot hold the group")
		h.eq(R.verdict({}, {}, 0), "all", "no humans")
		h.eq(R.verdict({ 3 }, { [9] = true }, 1), "wait", "another player's answer does not count")
		h.ok(R.TIMEOUT >= 10 and R.TIMEOUT <= 15)
	end)

	h.test("client: count at 90 percent, a missing count is ready, a freeze restarts the smooth run", function()
		h.ok(not R.countReady(899, 1000))
		h.ok(R.countReady(900, 1000))
		h.ok(R.countReady(0, nil))
		local run = 0
		for _ = 1, 5 do
			run = R.smoothStep(run, 1 / 60)
		end
		h.eq(run, 5)
		h.eq(R.smoothStep(run, 2.4), 0, "a frozen frame starts over")
	end)

	h.test("ack: only a whole token the server still waits on", function()
		local waiting = { [4] = {} }
		h.ok(R.validAck(4, waiting))
		h.ok(not R.validAck(5, waiting), "a future token")
		h.ok(not R.validAck(4.5, waiting))
		h.ok(not R.validAck("4", waiting))
		h.ok(not R.validAck(nil, waiting))
	end)
end
