-- sys.stack reports every coroutine of a proc, not just its main one.
--
-- The version that walked only the main coroutine was useless for
-- exactly the procs worth inspecting: anything on lib/thread reported
-- its scheduler -- alt / thread.run / entrypoint -- identically
-- whether it was idle or deadlocked.
--
-- The parked threads below are the case that matters and the case that
-- was missed first: lib/thread._parked is keyed BY COROUTINE, so a
-- parked thread appears only as a table KEY. A walk that inspected
-- values alone found nothing at all in a proc whose threads were all
-- parked, which is every proc anyone would run this on.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(6)

local _, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	-- two threads, both parked on ports nobody will ever send to, so
	-- both live in _parked as keys
	thread.spawn(function() thread.recv(sys.newport("test_stack")) end)
	thread.spawn(function() thread.recv(sys.newport("test_stack")) end)
	thread.run()
]], { name = "threads" })

local pid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "threads" then pid = p end
end

tap.ok(pid ~= nil, "the target proc is running")
if not pid then tap.done() return end

-- let it reach thread.run and park
thread.sleep(50)

local coros = sys.stack(pid)

tap.ok(type(coros) == "table", "sys.stack returns a table")
tap.ok(#coros >= 3, "main plus both threads reported (" .. #coros .. ")")

tap.ok(coros[1] and coros[1].label == "main",
    "the proc's own coroutine comes first")

local threads, framed = 0, 0

for i = 2, #coros do
	local c = coros[i]

	threads = threads + 1
	if type(c.frames) == "table" and #c.frames > 0 then
		framed = framed + 1
	end
	tap.diag(("%s (%s): %d frames"):format(c.label, tostring(c.status),
	    c.frames and #c.frames or 0))
end

tap.ok(threads >= 2, "at least two threads found beside main")
tap.ok(framed == threads, "every thread reported has frames")

-- The introspection must not have disturbed the target: it should still
-- be exactly where it was, parked, and readable a second time.
local again = sys.stack(pid)

tap.diag(("second read: %d coroutines"):format(#again))

tap.done()
