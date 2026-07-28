-- prove the driver-task boundary actually holds: los.platform.{cons,
-- wire,power} are each reachable from nowhere except their one owning
-- task, an ordinary proc has none of CONS/WIRE/POWER/DISK by default,
-- disk read is ambient but write is not, and the boot payload's real
-- capabilities work.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(11)

-- none of the three raw modules exist for us (we are not cons/wire/power)
tap.is((pcall(require, "los.platform.cons")), false,
    "los.platform.cons unreachable from an ordinary proc")
tap.is((pcall(require, "los.platform.wire")), false,
    "los.platform.wire unreachable from an ordinary proc")
tap.is((pcall(require, "los.platform.power")), false,
    "los.platform.power unreachable from an ordinary proc")

-- a plain spawned child gets none of CONS/WIRE/POWER/DISK by default
-- (empty by default -- only the boot payload itself gets them). read
-- is ambient regardless (it can open /init.lua for reading fine);
-- write still needs the DISK right it doesn't have. it asserts its
-- own expectations internally and dies normally only if all hold;
-- the monitor DOWN notification tells us which.
local pid, w = sys.spawn([[
	local sys = require("los.sys")
	assert(not pcall(require, "los.platform.cons"))
	assert(not pcall(function() return sys.send(sys.CONS, {}) end))
	assert(not pcall(function() return sys.send(sys.WIRE, {}) end))
	assert(not pcall(function() return sys.send(sys.POWER, {}) end))
	assert(io.open("/init.lua", "r") ~= nil,
	    "read is ambient -- a spawned child should still be able to "
	    .. "read a real esp file")
	assert(io.open("/childwrite.txt", "w") == nil,
	    "write is gated -- a spawned child with no DISK right must "
	    .. "not be able to open a file for writing")
]])

sys.monitor(pid)
local m = thread.recv(sys.SELF)
tap.is(m.normal, true,
    "spawned child confirms read-ambient/write-gated, dies normally: "
    .. tostring(m.reason))
sys.close(w)

-- proc 0 (us) DOES hold real CONS/WIRE/POWER/DISK, granted at boot
tap.ok(sys.CONS ~= nil and sys.WIRE ~= nil and sys.POWER ~= nil and
    sys.DISK ~= nil, "proc 0 holds all four well-known handles")

-- and they are real, working sends/capabilities
tap.ok(pcall(sys.send, sys.CONS, { op = "write", data = "" }),
    "proc 0's cons send does not error")
tap.ok(pcall(sys.send, sys.WIRE, { op = "write", data = "" }),
    "proc 0's wire send does not error")

-- disk read: any proc can do this, but prove it still works for us too
local f = io.open("/init.lua", "r")

tap.ok(f ~= nil, "proc 0 can read a real esp file (read is ambient)")
if f then
	f:close()
end

-- disk write: proc 0's real DISK right actually lets it write
local w2 = io.open("/testscratch.txt", "w")

tap.ok(w2 ~= nil, "proc 0's DISK right actually opens a file for write")
if w2 then
	w2:write("hello")
	w2:close()
end

-- reserved handles: this test payload boots with -net none, so 5/6
-- (TCP/UDP) were never granted. those slots must stay permanently
-- EMPTY, not get recycled by right_new's first-free-slot search --
-- otherwise the first sys.spawn child lands on handle 5 and
-- sys.send(sys.TCP, ...) silently starts naming that child's mailbox
-- instead of failing cleanly.
local _, child = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	thread.recv(sys.SELF)
]], { name = "reserve-probe" })

tap.ok(child ~= 5 and child ~= 6,
    "sys.spawn does not reuse an ungranted fixed handle (got " ..
    tostring(child) .. ")")
tap.ok(not pcall(sys.send, sys.SELF, { p = { __right = sys.TCP } }),
    "sys.TCP with no NIC is a clean hole, not some other capability")

tap.done()
