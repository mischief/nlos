-- eth: the sole task anywhere with los.platform.eth (raw virtio-net
-- frames). Every other proc holds, at most, a send-right to this task's
-- mailbox and talks by message:
--
--   {op="mac", reply={__right=}}              -> {mac=<6 bytes>}
--   {op="send", data=<frame>, reply=}         -> {ok=<bool>}
--   {op="recv", reply=}                       -> {data=<frame>} | {data=nil}
--   {op="irqs", reply=}                       -> {n=<count>}
--
-- Same shape as lib/tcp.lua and lib/udp.lua, and for the same reason:
-- one owner of the device, everyone else reaching it by right.
--
-- What is different is how far up it goes, which is not at all. tcp and
-- udp re-serve a stack the firmware already implements; there is no
-- such firmware here, so this task hands out frames and arp, ip, icmp
-- and udp are written above it in Lua. That is the deliberate shape --
-- C moves bytes between a queue and a string, and protocol is policy.
--
-- recv does not block. Frames arrive unasked and the device drops them
-- when its receive queue is full, so a client polls and the answer may
-- be nil. A blocking recv would need this task to park on the device,
-- which it cannot do without an interrupt to wake on -- microvm has no
-- ioapic routing yet, so there is nothing to park on.

local sys = require("los.sys")
local thread = require("los.thread")
local eth = require("los.platform.eth")

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

while true do
	local m = thread.recv(sys.SELF)

	if m.op == "mac" then
		reply(m, { mac = eth.mac() })
	elseif m.op == "send" then
		reply(m, { ok = type(m.data) == "string" and
		    eth.send(m.data) or false })
	elseif m.op == "recv" then
		reply(m, { data = eth.recv() })
	elseif m.op == "irqs" then
		reply(m, { n = eth.irqs() })
	else
		reply(m, { err = "unknown op" })
	end
end
