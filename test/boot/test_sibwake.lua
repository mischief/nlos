-- a thread parked in recv wakes on a send from a sibling.
--
-- Two threads of one proc, which is the shape a terminal has: the
-- console's keyboard pump and the shell are siblings, and the pump
-- sends the shell an interrupt on a port the shell is parked on. If
-- that wake needs an intervening yield to be seen, the interrupt is
-- delivered only when something else happens to schedule -- which on
-- hardware looked like alt-c working when the code was instrumented and
-- not working when it was not.
--
-- So the send here has nothing after it. No print, no sleep, no second
-- message: the sender's next act is to end, and the parked sibling has
-- to wake anyway.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

local target = sys.newport("test_sibwake.target")
local targeth = sys.sendright(target)
local done = sys.newport("test_sibwake.done")
local doneh = sys.sendright(done)

tap.ok(target and done, "two ports")

thread.spawn(function()
	local m = thread.recv(target)

	sys.send(doneh, { got = type(m) == "table" and m.op or tostring(m) })
end)

thread.spawn(function()
	-- long enough that the sibling is parked rather than merely
	-- spawned: a send to a thread that has not parked yet is answered
	-- by the token path, which is not what is being tested.
	thread.sleep(100)
	sys.send(targeth, { op = "poke" })
end)

-- the pump's exact shape: send to a sibling, then park again at once on
-- a port of your own. The sender is back in recv before the scheduler
-- has run anyone else, which is the case the plain one above does not
-- reach because its sender ends instead.
local t2 = sys.newport("test_sibwake.t2")
local t2h = sys.sendright(t2)
local idle = sys.newport("test_sibwake.idle")
local done2 = sys.newport("test_sibwake.done2")
local done2h = sys.sendright(done2)

thread.spawn(function()
	local m = thread.recv(t2)

	sys.send(done2h, { got = type(m) == "table" and m.op or tostring(m) })
end)

thread.spawn(function()
	thread.sleep(150)
	sys.send(t2h, { op = "poke" })
	thread.recv(idle)		-- parks with nothing between
end)

thread.spawn(function()
	local r = thread.recvtimeout(done, 3000)

	tap.ok(type(r) == "table",
	    "a sibling parked in recv wakes on a send with no yield after it")

	local r2 = thread.recvtimeout(done2, 3000)

	tap.ok(type(r2) == "table",
	    "and when the sender parks again immediately after the send")

	tap.done()
	os.exit(0)
end)

thread.run()
