-- channels under a scheduler that cuts threads everywhere.
--
-- Every value sent must arrive exactly once and every waiter must be
-- woken, however the count hook chops up the threads doing it. The
-- shapes here are the ones that have actually broken: more waiters than
-- values on one channel, a rendezvous where every send has to find a
-- receiver directly, and a ping-pong that is almost nothing but the
-- wakeup path.
--
-- This file used to be about critical sections. A thread cut mid-update
-- once handed control to thread.run, which ran somebody else over the
-- top of a half-finished structure, and lib/thread marked every such
-- update so run() would resume the cut thread and only it. That whole
-- mechanism is gone: a thread is no longer switched away from except
-- where it parks or yields, so there is no half-finished anything for a
-- sibling to see, and nothing left to mark.
--
-- What survives is this -- the wake ORDER, which preemption never
-- caused and removing it does not fix. Registering on a queue and
-- parking are still two steps with a yield between them, and a sender
-- landing in that gap still has to leave a token rather than a lost
-- wake. A lost wake shows up as a test that never finishes rather than
-- one that fails, which is why the harness timeout is part of this
-- test.
local thread = require("los.thread")
local tap = require("tap")

tap.plan(5)

-- ---- many senders and receivers over one buffered channel ----
--
-- Every value must arrive exactly once. A lost wake shows up as a
-- test that never finishes rather than one that fails, which is why
-- the harness timeout is part of this test.
local NSEND, NMSG = 5, 400

local ch = thread.chancreate(4)
local done = thread.chancreate(NSEND)
local got, sent = {}, 0

for s = 1, NSEND do
	thread.spawn(function()
		for i = 1, NMSG do
			ch:send({ from = s, seq = i })
		end
		done:send(true)
	end)
end

for _ = 1, 2 do
	thread.spawn(function()
		while true do
			local m = ch:recv()

			if m == nil then
				return
			end
			got[m.from] = (got[m.from] or 0) + 1
		end
	end)
end

thread.spawn(function()
	for _ = 1, NSEND do
		done:recv()
	end
	sent = NSEND * NMSG
	ch:close()
end)

thread.run()

tap.is(sent, NSEND * NMSG, "every sender finished")

local total, complete = 0, 0

for s = 1, NSEND do
	total = total + (got[s] or 0)
	if got[s] == NMSG then
		complete = complete + 1
	end
end
tap.is(total, NSEND * NMSG,
    ("every message arrived exactly once (%d)"):format(total))
tap.is(complete, NSEND, "and each sender's messages all arrived")

-- ---- rendezvous: no buffer to hide a lost wake ----
--
-- cap 0 means every send has to pair with a receiver directly, so the
-- deposit-and-wake path runs on every single message instead of only
-- when the buffer is full.
local rv = thread.chancreate(0)
local pairs_done = 0

thread.spawn(function()
	for i = 1, 400 do
		rv:send(i)
	end
	rv:close()
end)

thread.spawn(function()
	while true do
		local v, alive = rv:recv()

		if not alive then
			return
		end
		pairs_done = pairs_done + v - v + 1
	end
end)

thread.run()

tap.is(pairs_done, 400, "every rendezvous paired (" .. pairs_done .. ")")

-- ---- a thread cut while it is waking another ----
--
-- The ping-pong is the shape that found the original bug: a thread
-- doing nothing but waking a sibling and parking again, so that almost
-- all of its instructions are the wakeup path itself.
local a, b = thread.chancreate(1), thread.chancreate(1)
local laps = 0

thread.spawn(function()
	for _ = 1, 900 do
		a:send(true)
		b:recv()
		laps = laps + 1
	end
	a:close()
end)

thread.spawn(function()
	while true do
		local _, alive = a:recv()

		if not alive then
			return
		end
		b:send(true)
	end
end)

thread.run()

tap.is(laps, 900, "the ping-pong completed every lap (" .. laps .. ")")

tap.done()
