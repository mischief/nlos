-- prove the conio boundary actually holds: los.platform is reachable
-- from nowhere except conio itself, and an ordinary proc -- even one
-- that never received a conio right -- has no path to raw
-- console-write or machine power, only a message-send to whoever
-- does hold that right.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

-- los.platform doesn't exist for us at all (we are not conio)
local ok = pcall(require, "los.platform")
tap.is(ok, false, "los.platform unreachable from an ordinary proc")

-- a plain spawned child gets nothing conio-shaped by default (spawn
-- grants no device/platform rights -- empty by default). it asserts
-- its own expectations internally and dies normally only if both
-- hold; the monitor DOWN notification is how we find out (no reply
-- port needed -- a plain spawned child has no right to talk back to
-- its parent unless one is explicitly handed to it, which we don't).
local pid, w = sys.spawn([[
	local sys = require("los.sys")
	assert(not pcall(require, "los.platform"),
	    "los.platform must be unreachable")
	assert(not pcall(function() return sys.send(sys.CONIO, {}) end),
	    "CONIO send must fail with no right")
]])

sys.monitor(pid)
local m = thread.recv(sys.SELF)
tap.is(m.normal, true,
    "spawned child confirms both denials, dies normally: " ..
    tostring(m.reason))
sys.close(w)

-- meanwhile, proc 0 (us) DOES hold a real conio send-right, granted
-- at boot
tap.ok(sys.CONIO ~= nil, "proc 0 holds a well-known CONIO handle")

-- and it is a real, working send: conio receives it without erroring
-- (an empty write is a harmless no-op on the wire)
local sok = pcall(sys.send, sys.CONIO, { op = "write", data = "" })
tap.ok(sok, "proc 0's conio send does not error")

tap.done()
