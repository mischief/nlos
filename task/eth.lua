-- eth: the sole task anywhere with los.platform.eth (raw virtio-net
-- frames). Every other proc holds, at most, a send-right to this task's
-- mailbox and talks by message:
--
--   {op="mac", reply={__right=}}              -> {mac=<6 bytes>}
--   {op="send", data=<frame>, reply=}         -> {ok=<bool>}
--   {op="recv", reply=}                       -> {data=<frame>} | {data=nil}
--   {op="recv", wait=true, reply=}            -> {data=<frame>}, when one comes
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
-- recv comes in two kinds, and the difference is the whole reason this
-- task alts rather than just receiving. Without wait, it answers with
-- whatever is there, nil included: a caller polling on its own schedule
-- keeps that. With wait, the request is parked until the device says a
-- frame arrived -- and the machine can then halt in between, which is
-- what anything above this layer actually wants. A stack that has to
-- poll for its input burns a cpu to learn that nothing happened.
--
-- Handle 1 is the wakeup, granted by the kernel at spawn: kernel.c's
-- pump_eth pushes into it when a virtio interrupt has been taken since
-- the last look. It carries no data -- the frames are still in the
-- device's queue -- so it means only "ask the device again".

local sys = require("los.sys")
local thread = require("los.thread")
local eth = require("los.platform.eth")

local RAWETH = 1

-- requests parked on a frame that has not arrived, oldest first. Rights
-- held here are closed when answered, like every other reply right (see
-- lib/wire.lua on why one arrives fresh each time).
local waiting = {}

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

-- hand out whatever the device has. Every frame goes to EVERY parked
-- receiver, not to one of them.
--
-- A wire is not a queue with an owner. Several procs can have a
-- legitimate interest in the same frame -- the ip stack, a second
-- protocol family, a capture -- and handing each frame to whichever
-- happened to ask first means none of them sees a whole conversation.
-- That is not hypothetical: the moment kernel.c started the ip task at
-- boot, every test that drove the wire directly began losing frames to
-- it, which showed up as a ping that sometimes went unanswered.
--
-- This is the ethernet driver's job in plan 9 too: /net/ether0 hands a
-- copy to every connection whose type matches, rather than electing
-- one reader. There is no type filter here yet, so everyone sees
-- everything and filters for themselves -- ether.for_us and the
-- ethertype check in lib/inet.lua are already exactly that.
--
-- The cost is a copy per extra listener, and in an ordinary boot there
-- are none: only the stack is parked, and a broadcast to one receiver
-- is a send.
local function drain()
	while #waiting > 0 do
		local frame = eth.recv()

		if not frame then
			return
		end

		local w = waiting

		waiting = {}
		for _, m in ipairs(w) do
			reply(m, { data = frame })
		end
	end
end

while true do
	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = RAWETH },
	})

	if which == 2 then
		-- the device signalled. It says nothing about how many
		-- frames are queued, so drain until the queue or the
		-- waiters run out.
		drain()
	elseif m.op == "mac" then
		reply(m, { mac = eth.mac() })
	elseif m.op == "send" then
		reply(m, { ok = type(m.data) == "string" and
		    eth.send(m.data) or false })
	elseif m.op == "recv" then
		local frame = eth.recv()

		if frame or not m.wait then
			reply(m, { data = frame })
		else
			-- nothing now, and the caller said it would wait.
			-- Answered from drain() above, whenever the device
			-- next has something.
			waiting[#waiting + 1] = m
		end
	elseif m.op == "irqs" then
		reply(m, { n = eth.irqs() })
	else
		reply(m, { err = "unknown op" })
	end
end
