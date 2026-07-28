-- timers: sys.timer(ms) as a port, and the thread.lua sugar over it.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(11)

-- ---- the raw primitive ----
local t = sys.timer(50)
tap.ok(t ~= nil, "sys.timer returns a right")

local a = sys.uptime_ms()
local v = thread.recv(t)
local waited = sys.uptime_ms() - a

tap.ok(v == true, "timer delivers one message")
-- never early; late by at most a tick or two
tap.ok(waited >= 50, "did not fire early (" .. waited .. "ms >= 50ms)")
tap.ok(waited < 120, "fired within a tick or two (" .. waited .. "ms)")
sys.close(t)

-- ---- it is one-shot ----
local t2 = sys.timer(10)
thread.recv(t2)
local again = sys.tryrecv(t2)
tap.ok(not again, "timer is one-shot, no second message")
sys.close(t2)

-- ---- thread.sleep parks for real ----
local b = sys.uptime_ms()
thread.sleep(100)
local slept = sys.uptime_ms() - b

tap.ok(slept >= 100 and slept < 180, "thread.sleep(100) slept " .. slept .. "ms")

-- ---- recv timeout: the whole reason a timer is a port ----
local dead = sys.newport()
local m, why = thread.recvtimeout(dead, 50)

tap.ok(m == nil and why == "timeout",
    "recvtimeout on a silent port times out (" .. tostring(why) .. ")")

-- and returns the message when one is actually there
local live = sys.newport()
sys.send(live, "hello")
tap.ok(thread.recvtimeout(live, 1000) == "hello",
    "recvtimeout returns a waiting message")

-- ---- cancellation reclaims the slot, without needing a yield ----
-- fill the table with far-future timers and cancel them, three times
-- over. reclaiming must not depend on the caller yielding first: at the
-- moment the table is full, thread.sleep() cannot get a timer of its own
-- to yield WITH, so if sys.timer didn't reclaim on demand this would
-- deadlock on the second pass. (that is exactly how the first version of
-- both this test and the kernel side were wrong.)
local leaked = 0
for pass = 1, 3 do
	local held = {}
	for _ = 1, 32 do
		local x = sys.timer(60000)   -- a minute out; never fires here

		if not x then
			leaked = leaked + 1
		else
			held[#held + 1] = x
		end
	end
	for _, x in ipairs(held) do
		sys.close(x)
	end
end
tap.ok(leaked == 0,
    "cancelled timer slots are reclaimed on demand (" .. leaked .. " denied)")

-- ---- the whole point: waiting now PARKS, so the kernel can idle ----
-- this assertion was impossible before timers existed. the old idiom
-- (`while sys.uptime_ms() - t0 < n do sys.yield() end`) keeps the proc
-- READY, so kernel_run's `ran` flag is set every lap and it never
-- reaches WaitForEvent at all -- and any spin loop written to MEASURE
-- that is itself the thing keeping the machine busy. sleeping on a
-- timer parks for real, so sys.stats().idles advances.
local before = sys.stats().idles

thread.sleep(150)

local gained = sys.stats().idles - before

tap.ok(gained > 0,
    "kernel reaches its idle sleep while a proc sleeps (" .. gained ..
    " idles)")

-- and the contrast, on purpose: spinning gains nothing
local spin_before = sys.stats().idles
local t0 = sys.uptime_ms()

while sys.uptime_ms() - t0 < 150 do
	sys.yield()
end
tap.ok(sys.stats().idles - spin_before == 0,
    "spin-waiting the old way reaches it zero times, as it always did")

tap.done()
