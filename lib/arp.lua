-- ARP: turning an IPv4 address into the ethernet address to send it to.
--
-- The first protocol above the frame, and the one that decides the
-- shape of everything after it. Two halves that are easy to conflate
-- and are kept apart here:
--
--   the codec -- encode and decode, pure string work, no capability and
--   no clock, which is what makes it checkable against an independent
--   implementation (qemu's slirp answers these for real).
--
--   the conversation -- resolve, and answering someone else's query --
--   which needs to send, receive and wait, none of which this module
--   should decide how to do. It takes a `wire`: a table of send, recv,
--   now and yield. lib/eth.lua's message protocol is one such wire; a
--   test harness is another, and a future ip task will be a third.
--
-- Only ethernet and IPv4 are handled. ARP is defined over any pair of
-- address families, and no other pair has ever been seen in the wild
-- here; decode rejects the rest rather than pretending to be general.

local ether = require("ether")
local ip4 = require("ip4")

local arp = {}

arp.REQUEST = 1
arp.REPLY = 2

arp.HDRLEN = 28			-- for ethernet/ipv4, the only pair below

local HW_ETHERNET = 1

-- htype, ptype, hlen, plen, op, then the four addresses
local FMT = ">I2I2I1I1I2"

function arp.encode(op, sha, spa, tha, tpa)
	return string.pack(FMT, HW_ETHERNET, ether.IPV4, 6, ip4.LEN, op) ..
	    sha .. spa .. tha .. tpa
end

-- nil for anything that is not ethernet/IPv4 ARP of the right length.
-- A caller gets whatever the wire delivered, so this is a filter, not
-- an assertion.
function arp.decode(p)
	if type(p) ~= "string" or #p < arp.HDRLEN then
		return nil
	end

	local htype, ptype, hlen, plen, op = string.unpack(FMT, p)

	if htype ~= HW_ETHERNET or ptype ~= ether.IPV4 then
		return nil
	end
	if hlen ~= 6 or plen ~= ip4.LEN then
		return nil
	end

	return {
		op = op,
		sha = p:sub(9, 14),	-- sender hardware address
		spa = p:sub(15, 18),	-- sender protocol address
		tha = p:sub(19, 24),	-- target hardware address
		tpa = p:sub(25, 28),	-- target protocol address
	}
end

-- a whole frame, ready for the wire, for each of the two things anyone
-- ever sends: a question broadcast to everyone, and an answer sent back
-- to whoever asked.
function arp.request_frame(mymac, myip, target)
	return ether.encode(ether.BROADCAST, mymac, ether.ARP,
	    arp.encode(arp.REQUEST, mymac, myip, ether.ZERO, target))
end

function arp.reply_frame(mymac, myip, req)
	return ether.encode(req.sha, mymac, ether.ARP,
	    arp.encode(arp.REPLY, mymac, myip, req.sha, req.spa))
end

-- ---- the cache ----
--
-- No expiry. An entry going stale matters on a network where addresses
-- move, and the cost of being wrong is a timeout and a re-resolve --
-- which is what this would do anyway on a miss. Ageing goes in when
-- something is observed to break without it, not before.

local cache = {}

function arp.cached(ip)
	return cache[ip]
end

function arp.remember(ip, mac)
	cache[ip] = mac
end

-- Every ARP frame seen teaches something, including ones addressed to
-- other machines: a request carries its sender's mapping in the same
-- fields a reply does. Learning from both is why a host on a busy
-- segment rarely has to ask.
--
-- Returns the decoded ARP if the frame was one, so a caller can decide
-- whether it also needs to answer.
function arp.observe(frame, mac)
	local f = ether.decode(frame)

	if not f or f.type ~= ether.ARP then
		return nil
	end
	if not ether.for_us(f, mac) then
		return nil
	end

	local a = arp.decode(f.payload)

	if not a then
		return nil
	end
	if a.spa ~= ip4.ANY then
		arp.remember(a.spa, a.sha)
	end
	return a
end

-- answer a request for our own address, and only for ours. Returns the
-- frame to send, or nil if there is nothing to say.
function arp.answer(a, mymac, myip)
	if a.op ~= arp.REQUEST or a.tpa ~= myip then
		return nil
	end
	return arp.reply_frame(mymac, myip, a)
end

-- ---- resolve ----
--
-- Ask, then watch what arrives until the answer is among it. Re-asks on
-- a period rather than once: the first request can be lost, and on a
-- machine where the receive queue is polled it can also be answered
-- before anyone is looking.
--
-- `wire` is {send=f(frame), recv=f()->frame|nil, now=f()->ms,
-- yield=f()}. Returns the mac, or nil and a reason.
function arp.resolve(wire, mymac, myip, target, timeout_ms, retry_ms)
	if cache[target] then
		return cache[target]
	end

	timeout_ms = timeout_ms or 3000
	retry_ms = retry_ms or 500

	local deadline = wire.now() + timeout_ms
	local next_ask = 0

	while wire.now() < deadline do
		if wire.now() >= next_ask then
			wire.send(arp.request_frame(mymac, myip, target))
			next_ask = wire.now() + retry_ms
		end

		-- park if the wire can, poll if it cannot. Parking is what
		-- lets the machine halt between frames rather than spin
		-- asking a device that has nothing; a wire without it (a
		-- test harness, a platform with no line routed) still works,
		-- just awake.
		local frame

		if wire.recv_wait then
			frame = wire.recv_wait(retry_ms)
		else
			frame = wire.recv()
		end

		if frame then
			-- learn from everything, not just the reply we want:
			-- the answer may arrive behind other traffic, and on a
			-- bridge there is other traffic.
			arp.observe(frame, mymac)
			if cache[target] then
				return cache[target]
			end
		elseif not wire.recv_wait then
			wire.yield()
		end
	end

	return nil, "no answer for " .. ip4.str(target)
end

return arp
