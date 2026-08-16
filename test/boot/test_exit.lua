-- sys.exit and thread.exit: the two ways out, from a thread.
--
-- The shape this exists for: a proc whose main thread waits while
-- another decides the work is over. Unwinding ends one coroutine and
-- leaves the rest parked, so without sys.exit the proc lives forever
-- and the parent's monitor never fires.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local proc = require("proc")

tap.plan(5)

tap.ok(type(sys.exit) == "function", "sys.exit is there")
tap.ok(type(thread.exit) == "function", "thread.exit is there")

-- ---- thread.exit ends one thread, not the proc ----

local reached = 0

thread.spawn(function()
	reached = reached + 1
	thread.exit()
	reached = reached + 100		-- never
end)
thread.spawn(function()
	reached = reached + 1
end)
thread.run()

tap.is(reached, 2, "thread.exit ends its own thread and no other")

-- ---- sys.exit ends the proc, from a thread, with parked siblings ----
--
-- The sibling waits on a port nothing will ever send to, which is what
-- keeps the proc alive if the exit only unwinds.
local SRC = [[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.spawn(function()
		thread.recv(sys.newport("test.parked"))
	end)
	thread.spawn(function()
		sys.exit(7)
	end)
	thread.run()
]]

local pid, h = proc.spawn(SRC, { name = "exiter" })

sys.monitor(pid)
sys.close(h)

local m = thread.recv(sys.SELF)

tap.is(m.exit, pid, "the proc died though a thread was parked")
tap.is(m.status, 7, "with the status sys.exit was given")

tap.done()
