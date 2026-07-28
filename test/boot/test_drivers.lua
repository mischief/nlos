-- prove the driver-task boundary actually holds: los.platform.{cons,
-- wire,power} are each reachable from nowhere except their one owning
-- task, an ordinary proc has none of CONS/WIRE/POWER/DISK by default,
-- disk read is ambient but write is not, and the boot payload's real
-- capabilities work.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(12)

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
	-- an ordinary child is granted nothing, so its grant table is
	-- empty; there is no constant it could try to send to instead.
	local g = sys.granted()
	assert(next(g) == nil, "a spawned child is granted no capability")
	-- and it cannot reach a driver by guessing handle numbers either
	for h = 1, 12 do
		assert(not pcall(function() return sys.send(h, {}) end))
	end
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

-- proc 0 (us) DOES hold cons/wire/power/disk, granted at boot and
-- reported by name. this payload boots with -net none, so tcp/udp are
-- legitimately absent -- an absent key IS the availability test.
local g = sys.granted()

tap.ok(g.cons and g.wire and g.power and g.disk and g.sched,
    "proc 0's grant table names every capability it was given")
tap.ok(g.tcp == nil and g.udp == nil,
    "no NIC: tcp/udp are simply absent from the grant table")

-- and they are real, working sends/capabilities
tap.ok(pcall(sys.send, g.cons, { op = "write", data = "" }),
    "proc 0's cons send does not error")
tap.ok(pcall(sys.send, g.wire, { op = "write", data = "" }),
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

-- handle numbers are not an abi: a sys.spawn child may legitimately
-- land on any free slot, including one a driver would have taken on a
-- machine that had that driver. that is only safe because nothing
-- looks capabilities up by number -- the grant table above is by name,
-- and an absent capability has no number at all to collide with.
local _, child = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	thread.recv(sys.SELF)
]], { name = "slot-probe" })

tap.ok(type(child) == "number", "sys.spawn returns a handle (" ..
    tostring(child) .. ")")
tap.ok(g.tcp == nil,
    "an absent capability has no handle to be aliased by that child")

tap.done()
