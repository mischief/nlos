-- A thread that never yields must not starve its siblings, whether they
-- yield or park.
--
-- Two different guarantees, and only the first used to hold.
--
-- Yielding siblings are fine because thread.run is a fair round robin
-- and the count hook interrupts a busy thread on its own -- lua_newthread
-- copies hook, mask and count from the parent (lua/lstate.c), so no one
-- has to install anything. sys.preempt used to, pointlessly.
--
-- PARKED siblings were not fine. Parked threads were readied only after
-- sys.altblock, which runs only when the runq is empty -- so anything
-- still runnable meant a parked thread never woke, however long its
-- message had been waiting. thread.sleep below is the smallest case: it
-- parks on a timer port that fires and is never collected.
--
-- If either regresses this test times out rather than failing, which is
-- the right verdict spelled inconveniently: a starved scheduler cannot
-- report on itself.

local tap = require("tap")
local thread = require("los.thread")

tap.plan(2)

local yields, sleeps = 0, 0

thread.spawn(function()
	local i = 0

	while true do
		i = i + 1
	end
end)

thread.spawn(function()
	for _ = 1, 20 do
		yields = yields + 1
		coroutine.yield()
	end
end)

thread.spawn(function()
	for _ = 1, 10 do
		sleeps = sleeps + 1
		thread.sleep(1)
	end
	tap.ok(yields == 20, "a yielding sibling ran beside a spinner (" ..
	    yields .. "/20)")
	tap.ok(sleeps == 10, "a PARKED sibling woke beside a spinner (" ..
	    sleeps .. "/10)")
	tap.done()
end)

thread.run()
