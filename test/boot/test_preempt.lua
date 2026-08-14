-- what it takes to lose the cpu, and what it does not.
--
-- A thread is switched away from where it chose to be and nowhere
-- else: parking on a channel or port, or calling thread.yield. That is
-- plan 9 libthread's contract. The count hook still cuts a thread
-- wherever it likes -- it is the only way control reaches p->co, so it
-- is the only way the PROC can be descheduled on its quantum -- but
-- run() resumes that same thread at that same instruction rather than
-- picking someone else.
--
-- The guarantee this file used to make was the opposite one: that a
-- thread spinning forever could not starve its siblings. That is given
-- up deliberately. Defending against it is what made every multi-step
-- update in src/thread.c a critical section, and a thread that never
-- yields is a bug in the thread -- libthread has never pretended
-- otherwise. What is still guaranteed is everything below.
--
-- PARKED siblings are the older half of this and still matter: parked
-- threads were once readied only after sys.alt, which runs only
-- when the runq is empty, so anything still runnable meant a parked
-- thread never woke however long its message had been waiting.
-- thread.sleep is the smallest case, parking on a timer port that
-- fires and is never collected.
--
-- If either of the first two regresses this times out rather than
-- failing, which is the right verdict spelled inconveniently: a
-- starved scheduler cannot report on itself.

local tap = require("tap")
local thread = require("los.thread")

tap.plan(3)

-- ---- a thread that yields shares, and one that parks is woken ----
--
-- The busy thread yields rather than spinning forever, since yielding
-- is now the whole of what makes it a good citizen. It does enough
-- work between yields to be cut by the hook many times over, which is
-- the part that must not matter.
local yields, sleeps = 0, 0

thread.spawn(function()
	for _ = 1, 200 do
		local i = 0

		while i < 2000 do
			i = i + 1
		end
		thread.yield()
	end
end)

thread.spawn(function()
	for _ = 1, 20 do
		yields = yields + 1
		thread.yield()
	end
end)

thread.spawn(function()
	for _ = 1, 10 do
		sleeps = sleeps + 1
		thread.sleep(1)
	end
end)

thread.run()

tap.is(yields, 20, "a yielding sibling ran beside a busy thread")
tap.is(sleeps, 10, "a PARKED sibling woke beside a busy thread")

-- ---- and being cut is not being switched away from ----
--
-- Two threads that never park and never yield. However finely the hook
-- cuts them -- and test_torture turns that up to every instruction --
-- each runs to completion before the other starts, so neither can
-- observe the other midway through an update. One handover per thread
-- and no more is the whole of the new contract.
local last, switches = 0, { 0, 0 }

for id = 1, 2 do
	thread.spawn(function()
		for _ = 1, 400 do
			if last ~= id then
				switches[id] = switches[id] + 1
				last = id
			end
		end
	end)
end

thread.run()

tap.is(switches[1] + switches[2], 2,
    "a thread that neither parks nor yields is not switched away from")

tap.done()
