-- with NET=1 the harness gives the guest a NIC on qemu's usermode
-- network, so the stack over it must actually spawn and be reachable.
-- without one none of it is spawned at all, and eth/ip/tcp are simply
-- absent from sys.granted().
--
-- this is the shape of the arrangement, not whether packets move --
-- boot-dns, http-server and mcp-server are the end-to-end ones.
--
-- NOT covered here: whether the kernel still reaches its idle sleep
-- with a NIC present. that isn't observable from inside a proc --
-- there's no blocking sleep primitive to measure across, and any spin
-- loop doing the measuring is itself what keeps the machine busy. it
-- has to be verified from outside, by qemu cpu time over a fixed window
-- with every proc parked.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(10)

-- availability is a plain table lookup now. it used to be a probe
-- send, which was never "just a check": a successful send genuinely
-- transfers the right to whoever it was aimed at.
local g = sys.granted()

tap.ok(g.eth ~= nil, "eth is in the grant table (NIC present)")
tap.ok(g.ip ~= nil, "ip is in the grant table (the ipv4 stack)")
tap.ok(g.tcp ~= nil, "tcp is in the grant table")

-- there is no udp capability, and that is the design rather than an
-- omission: one ip task owns the address, and udp is an op on it. the
-- clients that want a udp-shaped api wrap the ip handle -- caps.udp(g.ip)
-- -- exactly as they wrapped the firmware's udp4 driver before.
tap.ok(g.udp == nil, "and no udp capability: udp is served through ip")

local byname = {}
for _, pid in ipairs(sys.procs()) do
	byname[sys.name(pid)] = pid
end

-- eth owns the raw NIC, ip owns the address, tcp4 owns the connections,
-- dhcpd owns the lease. one device, one owner, all the way up.
for _, name in ipairs({ "eth", "ip", "tcp4", "dhcpd" }) do
	tap.ok(byname[name] ~= nil, name .. " task is running")
end

-- parked on its mailbox rather than wedged or dead. eth is left out on
-- purpose: the kernel's pump wakes it whenever the card reports a frame,
-- so catching it READY is normal and asserting otherwise would be a
-- race against the wire.
--
-- Waited for rather than sampled: these start from a service list and
-- load their libraries off the filesystem, so catching one still
-- running says it was busy, not that it is wedged. Parked is a steady
-- state, and a task that never reaches it fails this on the timeout.
local function parked(pid)
	local w = sys.wchan(pid)

	return (w:sub(1, 5) == "port#" or w:sub(1, 4) == "alt["), w
end

for _, name in ipairs({ "ip", "tcp4" }) do
	local isparked, w

	for _ = 1, 100 do
		isparked, w = parked(byname[name])
		if isparked then
			break
		end
		thread.sleep(50)
	end
	tap.ok(isparked, name .. " task is parked (wchan=" .. w .. ")")
end

tap.done()
