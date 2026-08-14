#!/usr/bin/env lua5.4
-- lib/mouse.lua's record codec and one client's queue, on the host.
-- Both halves are transport-free: the queue is handed a send, so a port
-- that refuses is a function that returns false rather than a machine
-- under load.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

-- what the queue sends through, and the clock a record is stamped
-- with. Named here so a test can drive both.
local sent = {}
local full = false

package.preload["los.sys"] = function()
	return {
		uptime_ms = function() return 1234 end,
		send = function(_, rec)
			if full then
				return false
			end
			sent[#sent + 1] = rec
			return true
		end,
	}
end
package.preload["los.thread"] = function() return {} end

local mouse = require("mouse")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, tostring(got),
	    tostring(want)))
end

-- ---- the record ----

local rec = mouse.format(120, 40, 1, 99)

is(#rec, 49, "a record is 49 bytes, which is the framing rule")

local x, y, b, ms = mouse.parse(rec)

is(x, 120, "x survives the round trip")
is(y, 40, "y survives the round trip")
is(b, 1, "buttons survive the round trip")
is(ms, 99, "and the clock")

is(mouse.parse("hello"), nil, "a keystroke is not a record")
is(mouse.parse({}), nil, "and neither is a table")
ok(mouse.iswheel(mouse.format(0, 0, mouse.WHEELUP, 0)),
    "a wheel record says so")
ok(not mouse.iswheel(mouse.format(0, 0, 1, 0)),
    "a click does not")

-- ---- the queue ----
--
-- Motion coalesces by replacing the tail, so a reader that is behind
-- falls behind in resolution rather than in time. A change of button
-- never coalesces, or a click nobody saw is a click that did not
-- happen.

local q = mouse.queue(1)

sent, full = {}, false
q.post(10, 10, 0)
q.post(11, 11, 0)
is(#sent, 2, "an emptying port takes every record")

-- with the port refusing, three motions must collapse to one
sent, full = {}, true
q.post(20, 20, 0)
q.post(21, 21, 0)
q.post(22, 22, 0)
is(q.pending(), 1, "motion nobody took is superseded, not queued")

full = false
ok(q.retry(), "retry offers it again once there is room")
is(#sent, 1, "one record, not three")
is(select(1, mouse.parse(sent[1])), 22, "and it is the newest position")
is(q.pending(), 0, "with nothing left owed")

-- a press and the release behind it are two events, whatever the port
-- was doing at the time
sent, full = {}, true
q.post(30, 30, 0)
q.post(30, 30, 1)
q.post(30, 30, 0)
is(q.pending(), 3, "a change of button never coalesces")

full = false
q.retry()
is(#sent, 3, "so both edges arrive")
is(select(3, mouse.parse(sent[2])), 1, "the press")
is(select(3, mouse.parse(sent[3])), 0, "and the release")

-- ---- what a queue will not grow into ----
--
-- A reader that stopped reading must not cost memory without bound.

sent, full = {}, true
local deep = mouse.queue(1)

for i = 1, 100 do
	deep.post(i, i, i % 2)		-- alternating, so nothing coalesces
end
ok(deep.pending() <= 16, "a reader that stopped is bounded (" ..
    deep.pending() .. ")")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
