-- with NET=1 the harness gives the guest a NIC on qemu's usermode
-- network, so the net task must actually spawn and be reachable.
-- without one it is never spawned at all, and sys.NET is a hole.
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

tap.plan(3)

local has_net = pcall(sys.send, sys.SELF, { probe = { __right = sys.NET } })
tap.ok(has_net, "sys.NET is a live right (NIC present)")
if has_net then
	thread.recv(sys.SELF)	-- drain the probe we sent ourselves
end

local netpid
for _, pid in ipairs(sys.procs()) do
	if sys.name(pid) == "net" then
		netpid = pid
	end
end
tap.ok(netpid ~= nil, "net task is running")

-- it should be parked in alt across its own mailbox + the raw netport,
-- not wedged or dead.
local w = sys.wchan(netpid)
tap.ok(w:sub(1, 4) == "alt[", "net task is parked in alt (wchan=" .. w .. ")")

tap.done()
