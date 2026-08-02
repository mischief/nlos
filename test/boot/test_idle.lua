-- An idle proc must still SLEEP, not spin.
--
-- thread.run wakes parked threads every 64 rounds so a runnable thread
-- cannot starve them (test_preempt). The obvious way to get that wrong
-- is to keep readying parked threads when there is nothing else to run,
-- which turns an idle proc into a busy loop and stops the kernel ever
-- reaching its own idle sleep.
--
-- sys.stats().idles counts firmware sleeps, so it advances only on a
-- machine that is genuinely idle -- which is exactly the assertion.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(2)

-- a proc whose threads all park, forever
sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.spawn(function() thread.recv(sys.newport()) end)
	thread.spawn(function() thread.recv(sys.newport()) end)
	thread.run()
]], { name = "parked" })

local before = sys.stats().idles

thread.sleep(300)

local after = sys.stats().idles

tap.diag(("idles: %d -> %d"):format(before, after))
tap.ok(after > before,
    "the machine still reaches its idle sleep with parked threads about")
tap.ok(after - before > 5,
    "and reaches it repeatedly, rather than spinning (" ..
    (after - before) .. ")")

tap.done()
