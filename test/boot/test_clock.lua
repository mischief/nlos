-- the machine's wall clock: unset, set, and what reads it.

-- The clock is one number, unix seconds at boot. What this pins down
-- is that unset is distinguishable from 1970, and that the reading
-- advances with the machine rather than with the call.

local sys = require("los.sys")
local tap = require("tap")
local time = require("time")

tap.plan(14)

-- ---- unset ----

tap.ok(sys.time() == nil, "a machine nobody has told reads nil, not 0")

-- ---- set ----

local WHEN = 1754715073		-- 2025-08-09 04:51:13 UTC, a Saturday

tap.ok(sys.settime(WHEN) == WHEN, "settime answers with what it took")

local now = sys.time()

tap.ok(type(now) == "number", "and the clock reads a number after")
tap.ok(now >= WHEN and now < WHEN + 5,
    "which is the time it was given (" .. tostring(now) .. ")")

-- ---- it runs ----

-- over uptime, so it moves whether or not anyone asks. A clock that
-- only advances when read is the failure this is here for.

local t0 = sys.time()
local u0 = sys.uptime_ms()

while sys.uptime_ms() - u0 < 1100 do
	sys.yield()
end
tap.ok(sys.time() > t0, "the clock advances with the machine")

-- ---- refused ----

tap.ok(not pcall(sys.settime, 0), "settime refuses zero")
tap.ok(not pcall(sys.settime, -1), "settime refuses a time before the epoch")

-- ---- the calendar ----

-- lib/time.lua is the whole of os.date here: no strftime in this libc,
-- and no timezone database for a local time to mean anything against.

local d = time.utc(WHEN)

tap.ok(d.year == 2025 and d.month == 8 and d.day == 9,
    "unix seconds to a date")
tap.ok(d.hour == 4 and d.min == 51 and d.sec == 13, "and to a time")
tap.ok(d.wday == 7 and d.yday == 221, "with the weekday and day of year")
tap.ok(time.unix(d) == WHEN, "and back again")

tap.ok(time.date("%Y-%m-%d %H:%M:%S", WHEN) == "2025-08-09 04:51:13",
    "formatted")
tap.ok(time.date("%A %d %B %Y", WHEN) == "Saturday 09 August 2025",
    "with names")

-- carrying, which is what makes this usable for arithmetic: a clock app
-- adding a month must not have to know how long one is
tap.ok(time.date("%F", time.unix({ year = 2025, month = 13, day = 1,
    hour = 0 })) == "2026-01-01", "an out of range month carries")

tap.done()
