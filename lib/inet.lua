-- an IPv4 host on one ethernet link: the layers above lib/eth.lua,
-- assembled.
--
-- This is a library and not yet a task, deliberately. The task split
-- this belongs to puts arp, ip and icmp in one proc -- they sit on a
-- single packet's path, and separating them would put a message round
-- trip inside the transmission of one datagram -- so this is that
-- proc's whole body, and can become it by growing a message loop
-- around it. Until then anything holding an eth right can drive it.
--
-- What it does on receive is the part worth stating: every frame is
-- offered to ARP first, because a request for our address must be
-- answered whoever else is talking, and every ARP frame teaches the
-- cache something even when it was addressed to someone else. Only
-- then is it considered as IP.

local ether = require("ether")
local ip4 = require("ip4")
local arp = require("arp")
local icmp = require("icmp")
local udp4 = require("udp4")
local buf = require("los.buf")

local inet = {}

-- how many looped packets may be waiting to be picked up. A sender that
-- never drains its own loopback queue is a bug in that proc, and this
-- is what stops it becoming a bug in the machine's memory.
local LOOP_MAX = 64

local Host = {}

Host.__index = Host

-- cfg: {mac=, ip=, mask=, gw=}. mask and gw are optional -- without
-- them every destination is treated as on-link, which is right for a
-- point-to-point link and wrong for a real segment.
function inet.new(wire, cfg)
	return setmetatable({
		wire = wire,
		mac = cfg.mac,
		ip = cfg.ip,
		mask = cfg.mask,
		gw = cfg.gw,
		id = 0,
	}, Host)
end

-- does this destination reach the wire at all, or is it us?
--
-- Two ways to be us: anything in 127/8, and our own address. The second
-- matters as much as the first -- a proc that looks up its own address
-- and sends to it must not have the packet leave and come back, which
-- on a switched segment means it never arrives.
--
-- ip4.ANY is excluded because before DHCP answers, self.ip IS ANY, and
-- treating a send to 0.0.0.0 as a send to ourselves would swallow the
-- broadcasts DHCP bootstraps with.
function Host:islocal(dst)
	if ip4.is_loopback(dst) then
		return true
	end
	return self.ip ~= nil and self.ip ~= ip4.ANY and dst == self.ip
end

-- what to put in the source field for a packet to dst.
--
-- Not always self.ip: a packet to 127.0.0.1 comes FROM 127.0.0.1, which
-- is what a caller comparing the reply's source against where it sent
-- expects. It has to agree with whatever computed the udp checksum,
-- since that covers a pseudo-header of both addresses -- disagree and
-- every loopback datagram is discarded as corrupt by its receiver.
function Host:srcfor(dst)
	if ip4.is_loopback(dst) then
		return ip4.LOOPBACK
	end
	return self.ip
end

-- which address to ARP for: the destination if it shares our link, the
-- gateway if it does not. The only routing decision there is before
-- there is a routing table.
function Host:nexthop(dst)
	if not self.mask or not self.gw then
		return dst
	end
	if ip4.same_net(dst, self.ip, self.mask) then
		return dst
	end
	return self.gw
end

-- lay a frame on the wire for a packet whose mac we already have.
-- One buffer for the whole frame, each header written where it belongs
-- and the payload copied in once. Encoding a layer at a time made a
-- packet, then a frame around it, copying everything again per layer.
local function emit(self, mac, dst, proto, payload)
	self.id = (self.id + 1) & 0xffff

	local off = ether.HDRLEN + 1
	local f = buf.new(ether.HDRLEN + ip4.HDRLEN + #payload)

	ether.header(f, mac, self.mac, ether.IPV4)
	ip4.header(f, off, {
		src = self.ip, dst = dst, proto = proto, id = self.id,
	}, #payload)
	f:copy(off + ip4.HDRLEN, payload)
	return self.wire.send(f)
end

-- put a packet on the wire, or hold it while we ask who to send it to.
-- Never waits.
--
-- One packet per unresolved destination is kept, and sent when the
-- reply arrives. Without that the first packet to any new peer was
-- always lost, and a burst was entirely lost, since every packet in it
-- is "first" until the task returns to its loop and sees the answer.
-- That is not a theoretical cost: dhcp renewal unicasts to a server
-- only ever reached by broadcast before, so the first renewal always
-- failed and fell back to reacquiring the lease from scratch.
--
-- One and not a queue, because the point is to cover the resolution,
-- not to buffer for a peer that may not exist. A second packet to the
-- same unresolved destination displaces the first, which is what most
-- stacks do and bounds this at one packet per address being resolved.
--
-- Still never waits: arp.resolve reads the wire, and a task that owns
-- the wire cannot read it from inside a send without fighting its own
-- receive path.
function Host:output(dst, proto, payload)
	-- checked before broadcast and before arp, because a loopback
	-- destination has neither a next hop nor a mac to resolve: there is
	-- no link under it to ask on.
	if self:islocal(dst) then
		local q = self.lo

		if not q then
			q = {}
			self.lo = q
		end

		-- bounded, and the arrival is what loses. Same choice
		-- task/ip.lua makes for its receive queues and for the same
		-- reason: dropping the oldest hands a slow reader the newest
		-- datagrams and loses the ones it was waiting for, which for
		-- a request/reply protocol is precisely backwards.
		if #q >= LOOP_MAX then
			return nil, "full"
		end

		q[#q + 1] = {
			src = self:srcfor(dst), dst = dst,
			proto = proto, payload = payload,
		}
		return true, "loop"
	end

	if dst == ip4.BROADCAST then
		-- nobody to ask and nobody to ask for: a broadcast goes to
		-- the ethernet broadcast address by definition. This is also
		-- the only way to send anything before having an address at
		-- all, which is how DHCP starts.
		return emit(self, ether.BROADCAST, dst, proto, payload)
	end

	local hop = self:nexthop(dst)
	local mac = arp.cached(hop, self.wire.now())

	if mac then
		return emit(self, mac, dst, proto, payload)
	end

	self.pending = self.pending or {}
	self.pending[hop] = { dst = dst, proto = proto, payload = payload }
	self.wire.send(arp.request_frame(self.mac, self.ip, hop))

	-- accepted, not failed. The packet is held and goes out when the
	-- answer arrives, so reporting failure here would be a lie that
	-- costs something real: lib/dhcp.lua's renew unicasts to a server
	-- previously only reached by broadcast, saw a failed send on the
	-- very first attempt, and abandoned the lease to reacquire from
	-- scratch. sendto() on a unix returns success once the datagram is
	-- accepted; whether an arp was needed is not the sender's business.
	--
	-- The second return says which happened, for a caller that keeps
	-- counters.
	return true, "held"
end

-- send whatever was waiting on this address, now that we know it.
function Host:flush_pending(hop)
	local held = self.pending and self.pending[hop]

	if not held then
		return
	end
	self.pending[hop] = nil

	local mac = arp.cached(hop, self.wire.now())

	if mac then
		emit(self, mac, held.dst, held.proto, held.payload)
	end
end

-- output, but resolve first if we have to.
--
-- For a caller that owns the wire and can afford to block on it -- a
-- test, a one-shot script. A task serving several clients wants output
-- and its own retry, since this stops reading the wire for anyone else
-- while it waits.
function Host:send(dst, proto, payload)
	if dst ~= ip4.BROADCAST then
		local hop = self:nexthop(dst)

		if not arp.cached(hop, self.wire.now()) then
			if not arp.resolve(self.wire, self.mac, self.ip, hop,
			    2000) then
				return nil, "no route to " .. ip4.str(hop)
			end
		end
	end
	return self:output(dst, proto, payload)
end

-- a udp datagram, wrapped and sent. Separate from send() because udp's
-- checksum covers the addresses it is about to be wrapped in, so the
-- two layers cannot be composed blindly (see lib/udp4.lua).
function Host:udp_send(dst, sport, dport, data)
	return self:send(dst, ip4.PROTO_UDP,
	    udp4.encode(sport, dport, data, self.ip, dst))
end

-- one frame's worth of work. Returns the decoded IP packet when one
-- arrived for us, or nil. ARP is handled internally and never returned:
-- it is this layer's own business, not its caller's.
-- act on one frame someone else read. Returns the decoded IP packet
-- when one arrived for us, or nil.
--
-- Separate from pump because a task that alts between its clients and
-- its device already has the frame in hand, and must not go back to the
-- wire for it. ARP is handled here and never returned: it is this
-- layer's own business, not its caller's.
function Host:input(frame)
	local f = ether.decode(frame)

	if not f or not ether.for_us(f, self.mac) then
		return nil
	end

	if f.type == ether.ARP then
		local a = arp.observe(frame, self.mac, self.wire.now())

		if a then
			-- whatever we were holding for that address can go
			-- now. observe() learns from replies and from
			-- requests alike, so this covers a peer that arped us
			-- first as well as one that answered.
			if a.spa then
				self:flush_pending(a.spa)
			end
			-- answering is not optional: a peer that cannot
			-- resolve us cannot send us anything, so a host that
			-- only asks and never answers is reachable in one
			-- direction only.
			local ans = arp.answer(a, self.mac, self.ip)

			if ans then
				self.wire.send(ans)
			end
		end
		return nil
	end

	if f.type ~= ether.IPV4 then
		return nil
	end

	local p = ip4.decode(f.payload)

	if not p then
		return nil
	end

	-- addressed to us at one layer or the other, and the second one is
	-- not optional.
	--
	-- Matching on the IP destination is the usual test, and it is what
	-- a configured host wants. But a frame unicast to our own mac was
	-- deliberately sent to us by something that already knows who we
	-- are, and the packet inside may be about an address we do not
	-- hold yet. DHCP is exactly that case: OpenBSD vmd ignores the
	-- broadcast flag in a request and unicasts its offer to the
	-- address it is about to assign (usr.sbin/vmd/dhcp.c sets
	-- pc_dst to client_addr), so a client that insists on the IP
	-- destination being its own can never hear the offer that would
	-- give it one. It is why real clients read this off BPF rather
	-- than a socket.
	if p.dst ~= self.ip and p.dst ~= ip4.BROADCAST and f.dst ~= self.mac then
		return nil
	end

	-- answer pings ourselves, for the same reason as ARP: a host that
	-- does not is one nobody can check is alive.
	if p.proto == ip4.PROTO_ICMP then
		local m = icmp.decode(p.payload)

		if m and m.type == icmp.ECHO_REQUEST then
			self:send(p.src, ip4.PROTO_ICMP, icmp.reply_to(m))
			return nil
		end
	end

	return p
end

-- the next packet that was sent to ourselves, or nil.
--
-- Already decoded -- it never became a frame, so there is nothing to
-- parse back -- and it is returned in the same shape input() returns,
-- so a caller demultiplexes both through one path.
--
-- A task that alts rather than pumping has to drain this itself after
-- anything that may have sent, because a looped packet arrives with no
-- interrupt behind it: nothing will wake the loop to collect it.
function Host:loopnext()
	local q = self.lo

	if not q or #q == 0 then
		return nil
	end
	return table.remove(q, 1)
end

-- read one frame and act on it. The convenience for a caller that owns
-- the wire; a task uses input() on what its own loop received.
function Host:pump(ms)
	-- ours first, and without waiting: it is already here, and a wire
	-- read would block up to ms before noticing.
	local lo = self:loopnext()

	if lo then
		return lo
	end

	local frame

	if self.wire.recv_wait then
		frame = self.wire.recv_wait(ms or 100)
	else
		frame = self.wire.recv()
	end
	if not frame then
		return nil
	end
	return self:input(frame)
end

-- send a udp datagram and wait for a reply to the port it came from,
-- discarding everything else. The shape every request/reply protocol
-- above this layer wants, and the reason it is here rather than in each
-- of them.
function Host:udp_rpc(dst, sport, dport, data, timeout_ms)
	local ok, why = self:udp_send(dst, sport, dport, data)

	if not ok then
		return nil, why
	end

	local deadline = self.wire.now() + (timeout_ms or 2000)

	while self.wire.now() < deadline do
		local p = self:pump(100)

		if p and p.proto == ip4.PROTO_UDP and p.src == dst then
			local d = udp4.decode(p.payload, p.src, p.dst)

			if d and d.dport == sport then
				return d.data, p
			end
		end
	end
	return nil, "no reply from " .. ip4.str(dst)
end

-- send one echo request and wait for its reply, ignoring whatever else
-- turns up. Returns the round trip in ms, or nil and why.
function Host:ping(dst, timeout_ms, seq)
	local id = 0x4c4f		-- "LO", so a capture says who asked
	local sent = self.wire.now()
	local ok, why = self:send(dst, ip4.PROTO_ICMP,
	    icmp.echo_request(id, seq or 1, "lua-os"))

	if not ok then
		return nil, why
	end

	local deadline = sent + (timeout_ms or 2000)

	while self.wire.now() < deadline do
		local p = self:pump(100)

		if p and p.proto == ip4.PROTO_ICMP and p.src == dst then
			local m = icmp.decode(p.payload)

			if m and m.type == icmp.ECHO_REPLY and m.id == id then
				return self.wire.now() - sent
			end
		end
	end
	return nil, "no reply from " .. ip4.str(dst)
end

return inet
