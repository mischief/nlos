-- lib/sync: the coordination primitives, and the windows they close.
--
-- Each case is written against the way the hand-rolled version failed,
-- not against the API. A test that only checks "get() returns the
-- value" passes on an implementation with no coordination in it at
-- all, which is exactly the implementation lib/mnt.lua shipped with.

local sys = require("los.sys")
local thread = require("los.thread")
local once = require("sync.once")
local sema = require("sync.sema")
local lock = require("sync.lock")
local tap = require("tap")

tap.plan(12)

-- ---- once: the concurrent first use ----
--
-- The window is a PARK inside fn, not two instructions, so this needs
-- no torture and no luck: every waiter arrives while the first is
-- still blocked. The broken version ran fn once per caller.
local calls = 0
local cell = once.new()
local got = {}

local function slow()
	calls = calls + 1
	thread.sleep(2)		-- parks, which is the whole point
	return "the value"
end

for id = 1, 6 do
	thread.spawn(function()
		got[id] = cell:get(slow)
	end)
end
thread.run()

local same = 0

for id = 1, 6 do
	if got[id] == "the value" then
		same = same + 1
	end
end

tap.is(calls, 1, "six threads on a cold cell ran the work once")
tap.is(same, 6, "and all six got the value")

-- a later caller does not run it again, and does not wait
tap.is(cell:get(slow), "the value", "a later caller reuses it")
tap.is(calls, 1, "without running the work again")

-- ---- once: a failure is not remembered ----
local attempts = 0
local flaky = once.new()

local function failtwice()
	attempts = attempts + 1
	thread.sleep(1)
	if attempts < 3 then
		error("not yet", 0)
	end
	return "eventually"
end

local results = {}

for id = 1, 3 do
	thread.spawn(function()
		local ok, v = pcall(flaky.get, flaky, failtwice)

		results[id] = ok and v or "err"
	end)
end
thread.run()

tap.ok(flaky:peek() == "eventually",
    "a cell that failed twice still holds the value that worked")
tap.is(attempts, 3, "and ran the work once per attempt, not once ever")

-- nil is a legal value, which is why `done` is a separate field
local nilcell = once.new()
local nilcalls = 0

nilcell:get(function()
	nilcalls = nilcalls + 1
	return nil
end)
nilcell:get(function()
	nilcalls = nilcalls + 1
	return nil
end)

tap.is(nilcalls, 1, "a cell holding nil is still held")

-- ---- sema: the window is never exceeded ----
--
-- inside is a plain counter and that is fine here: nothing parks
-- between the increment and the check.
local slots = sema.new(3)
local inside, peak = 0, 0
local finished = 0

for _ = 1, 12 do
	thread.spawn(function()
		slots:acquire()
		inside = inside + 1
		if inside > peak then
			peak = inside
		end
		thread.sleep(1)		-- hold it across a park
		inside = inside - 1
		finished = finished + 1
		slots:release()
	end)
end

sys.set_torture(true)
thread.run()
sys.set_torture(false)

tap.is(finished, 12, "every worker finished")
tap.is(peak, 3, "and no more than the window was ever inside (" ..
    peak .. ")")
tap.is(slots:free(), 3, "every permit came back")

-- releasing what was never taken is a bug, not a wider window
tap.ok(not pcall(slots.release, slots), "release without acquire raises")

-- ---- lock: mutual exclusion across a park ----
--
-- The failure the old QLock had: two threads both fell out of `while
-- self.held do` and both took it. Each holder yields while inside, so
-- a lock that does not exclude is caught rather than hoped about.
local l = lock.new()
local owner, breach = 0, 0

for id = 1, 4 do
	thread.spawn(function()
		for _ = 1, 15 do
			l:lock()
			owner = id
			thread.yield()
			if owner ~= id then
				breach = breach + 1
			end
			l:unlock()
		end
	end)
end

sys.set_torture(true)
thread.run()
sys.set_torture(false)

tap.is(breach, 0, "no two threads were inside the lock at once")

tap.done()
