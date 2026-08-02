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
-- Entries age out, and the machine staying up is why. A mapping is only
-- true until the address moves -- a router failing over, a replaced
-- box, a guest migrated to another host -- and an entry that never
-- expires means sending to a mac that no longer exists, forever, with
-- nothing to make us ask again. A stack that is only up for the length
-- of a test never notices; one that is meant to stay up does.
--
-- Two lifetimes, because the evidence differs. A reply to our own
-- question is a peer answering for itself. An entry learned from
-- somebody else's request is a claim we overheard and never checked --
-- it is worth having, since it saves asking, but it is worth
-- distrusting sooner.
--
-- The clock is passed in rather than read here: this module requires
-- nothing and can be exercised on the host with a fake one, which is
-- how the expiry below is tested without waiting five minutes.

arp.TTL_REPLY = 5 * 60 * 1000		-- ms
arp.TTL_OVERHEARD = 60 * 1000

local cache = {}			-- ip -> {mac=, expires=}

-- nil once the entry has aged out, which makes a stale mapping a miss
-- and a miss is already handled everywhere: lib/inet.lua's output arps
-- and drops, and the caller retries.
function arp.cached(ip, now)
	local e = cache[ip]

	if not e then
		return nil
	end
	if now and e.expires and now >= e.expires then
		cache[ip] = nil
		return nil
	end
	return e.mac
end

function arp.remember(ip, mac, now, ttl)
	cache[ip] = {
		mac = mac,
		expires = now and (now + (ttl or arp.TTL_REPLY)) or nil,
	}
end

-- for a test, and for a machine that has just changed address: every
-- mapping we hold was learned as a host we no longer are.
function arp.forget()
	cache = {}
end

-- how many live entries, for stats. Counts without expiring, since a
-- counter should not have side effects.
function arp.count()
	local n = 0

	for _ in pairs(cache) do
		n = n + 1
	end
	return n
end

-- Every ARP frame seen teaches something, including ones addressed to
-- other machines: a request carries its sender's mapping in the same
-- fields a reply does. Learning from both is why a host on a busy
-- segment rarely has to ask.
--
-- Returns the decoded ARP if the frame was one, so a caller can decide
-- whether it also needs to answer.
function arp.observe(frame, mac, now)
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
		-- an answer to a question is better evidence than a claim
		-- overheard in passing, and is trusted for longer.
		arp.remember(a.spa, a.sha, now,
		    a.op == arp.REPLY and arp.TTL_REPLY or arp.TTL_OVERHEARD)
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
	local hit = arp.cached(target, wire.now())

	if hit then
		return hit
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
			arp.observe(frame, mymac, wire.now())

			local got = arp.cached(target, wire.now())

			if got then
				return got
			end
		elseif not wire.recv_wait then
			wire.yield()
		end
	end

	return nil, "no answer for " .. ip4.str(target)
end

return arp
