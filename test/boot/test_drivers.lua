-- prove the driver-task boundary actually holds: los.platform.{cons,
-- wire,power} are each reachable from nowhere except their one owning
-- task, an ordinary proc has none of CONS/WIRE/POWER/DISK by default,
-- and the boot payload's real capabilities work.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(8)

-- none of the three raw modules exist for us (we are not cons/wire/power)
tap.is((pcall(require, "los.platform.cons")), false,
    "los.platform.cons unreachable from an ordinary proc")
tap.is((pcall(require, "los.platform.wire")), false,
    "los.platform.wire unreachable from an ordinary proc")
tap.is((pcall(require, "los.platform.power")), false,
    "los.platform.power unreachable from an ordinary proc")

-- a plain spawned child gets none of CONS/WIRE/POWER/DISK by default
-- (empty by default -- only the boot payload itself gets them).
-- it asserts its own expectations internally and dies normally only
-- if all hold; the monitor DOWN notification tells us which.
local pid, w = sys.spawn([[
	local sys = require("los.sys")
	assert(not pcall(require, "los.platform.cons"))
	assert(not pcall(function() return sys.send(sys.CONS, {}) end))
	assert(not pcall(function() return sys.send(sys.WIRE, {}) end))
	assert(not pcall(function() return sys.send(sys.POWER, {}) end))
	assert(io.open("/init.lua") == nil,
	    "spawned child must not be able to open esp files")
]])

sys.monitor(pid)
local m = thread.recv(sys.SELF)
tap.is(m.normal, true,
    "spawned child confirms all four denials, dies normally: " ..
    tostring(m.reason))
sys.close(w)

-- proc 0 (us) DOES hold real CONS/WIRE/POWER/DISK, granted at boot
tap.ok(sys.CONS ~= nil and sys.WIRE ~= nil and sys.POWER ~= nil and
    sys.DISK ~= nil, "proc 0 holds all four well-known handles")

-- and they are real, working sends/capabilities
tap.ok(pcall(sys.send, sys.CONS, { op = "write", data = "" }),
    "proc 0's cons send does not error")
tap.ok(pcall(sys.send, sys.WIRE, { op = "write", data = "" }),
    "proc 0's wire send does not error")

-- disk: proc 0 really can open a real file (this very payload,
-- injected via fw_cfg, is not on the esp, so use init.lua instead --
-- present on every real boot image)
local f = io.open("/init.lua", "r")

tap.ok(f ~= nil, "proc 0's disk capability actually opens a real file")
if f then
	f:close()
end

tap.done()
