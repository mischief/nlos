-- with NET=1 the harness gives the guest a NIC on qemu's usermode
-- network, so the net task must actually spawn and be reachable.
-- without one they are never spawned at all, and tcp/udp are simply
-- absent from sys.granted().
--
-- NOT covered here: whether the kernel still reaches its idle sleep
-- with a NIC present (pump_net's tick pacing). that isn't observable
-- from inside a proc -- there's no blocking sleep primitive to
-- measure across, and any spin loop doing the measuring is itself
-- what keeps the machine busy. it was verified from outside instead,
-- by qemu cpu time over a fixed window with every proc parked:
-- ~9.8s CPU per 10s wall with an unpaced ping, ~2.1s with it paced.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

-- availability is a plain table lookup now. it used to be a probe
-- send, which was never "just a check": a successful send genuinely
-- transfers the right to whoever it was aimed at.
local g = sys.granted()

tap.ok(g.tcp ~= nil, "tcp is in the grant table (NIC present)")
tap.ok(g.udp ~= nil, "udp is in the grant table (udp4 driver present)")

local byname = {}
for _, pid in ipairs(sys.procs()) do
	byname[sys.name(pid)] = pid
end
tap.ok(byname.tcp ~= nil, "tcp task is running")
tap.ok(byname.udp ~= nil, "udp task is running")

-- each should be parked in alt across its own mailbox + its raw port,
-- not wedged or dead.
for _, name in ipairs({ "tcp", "udp" }) do
	local w = sys.wchan(byname[name])
	tap.ok(w:sub(1, 4) == "alt[",
	    name .. " task is parked in alt (wchan=" .. w .. ")")
end

tap.done()
