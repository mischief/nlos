-- the machine sleeps and something wakes it.
--
-- This is the timer interrupt, end to end, and it is worth its own test
-- because the failure is total and silent. kernel_run's idle path halts
-- until efi_shim's WaitForEvent sees lapic_ticks() advance, and that
-- counter only moves in the LAPIC timer's handler. With interrupts
-- masked -- which they were on this platform until an sti was added,
-- since boot.S enters with them off -- the handler never runs, the halt
-- never ends, and the guest simply stops. Measured: this test times out
-- with no output at all if the sti is removed.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

local t0 = sys.uptime_ms()
local before = sys.stats().idles or 0

thread.sleep(200)

local t1 = sys.uptime_ms()
local after = sys.stats().idles or 0

tap.diag(string.format("slept %dms of 200 asked", t1 - t0))
tap.diag(string.format("idle sleeps: %d -> %d", before, after))

tap.ok(t1 - t0 >= 190, "a 200ms sleep takes 200ms")

-- the point: it got there by halting, not by spinning through laps
tap.ok(after > before, "and the machine halted rather than spun")

tap.ok(t1 - t0 < 2000, "and woke on the timer, not on some later accident")

tap.done()
