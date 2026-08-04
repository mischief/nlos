-- a generator has to deliver every item, however long it takes over one.
--
-- preempt_hook stops whatever state is running and yields it, and
-- lua_yield unwinds to the RESUMER of that state. For a thread that is
-- thread.run, which knows what the yield meant. For an ordinary
-- coroutine it is whoever called it, and `for v in seq(n)` reads a
-- yield of no values as the generator being finished -- so the loop
-- ends early and the caller gets short data, with no error anywhere.
--
-- It was a function of how much work an item did, which is the shape of
-- a quantum showing through. Measured before coroutine.wrap was made
-- transparent, items delivered out of 10:
--
--	work=1		10
--	work=100	10
--	work=10000	 3
--	work=200000	 0
--
-- and 0 inside a thread, 0 under torture. A generator was usable only
-- while it stayed under a quantum, and gave no sign when it did not.
--
-- The answer is not to stop preempting -- that is the only thing
-- stopping a proc that spins inside a coroutine from holding the whole
-- machine, which test_nesting pins -- but to resume again rather than
-- believe the yield. Being stopped does not disturb a coroutine, so
-- carrying on lands at the instruction it was stopped at.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(5)

-- work per item is the variable that used to decide this, so it is the
-- variable the test moves.
local function seq(n, work)
	return coroutine.wrap(function()
		for i = 1, n do
			local x = 0

			while x < work do
				x = x + 1
			end
			coroutine.yield(i)
		end
	end)
end

local function count(n, work)
	local got = 0

	for _ in seq(n, work) do
		got = got + 1
	end
	return got
end

tap.is(count(10, 100), 10, "a cheap generator delivers every item")
tap.is(count(10, 200000), 10,
    "and so does one that runs well past a quantum per item")

-- inside a thread, where the resumer is neither the kernel nor
-- thread.run but ordinary code in between.
local inthread = 0

thread.spawn(function()
	inthread = count(10, 200000)
end)
thread.run()

tap.is(inthread, 10, "a generator driven from inside a thread")

-- cut between every pair of instructions, so the hook lands inside the
-- generator over and over rather than once in a while.
local tortured = 0

sys.set_torture(true)
thread.spawn(function()
	tortured = count(10, 2000)
end)
thread.run()
sys.set_torture(false)

tap.is(tortured, 10, "and one cut between every instruction")

-- values, not just item counts: a truncated generator and a lying one
-- fail differently, and only checking the count would miss the second.
local seen = {}

for v in seq(5, 50000) do
	seen[#seen + 1] = v
end

tap.is(table.concat(seen, ","), "1,2,3,4,5", "every item arrives in order")

tap.done()
