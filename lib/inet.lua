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

local inet = {}

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

function Host:send(dst, proto, payload)
	local hop = self:nexthop(dst)
	local mac = arp.cached(hop)

	if not mac then
		mac = arp.resolve(self.wire, self.mac, self.ip, hop, 2000)
		if not mac then
			return nil, "no route to " .. ip4.str(hop)
		end
	end

	self.id = (self.id + 1) & 0xffff

	local pkt = ip4.encode({
		src = self.ip, dst = dst, proto = proto,
		id = self.id, payload = payload,
	})

	return self.wire.send(ether.encode(mac, self.mac, ether.IPV4, pkt))
end

-- one frame's worth of work. Returns the decoded IP packet when one
-- arrived for us, or nil. ARP is handled internally and never returned:
-- it is this layer's own business, not its caller's.
function Host:pump(ms)
	local frame

	if self.wire.recv_wait then
		frame = self.wire.recv_wait(ms or 100)
	else
		frame = self.wire.recv()
	end
	if not frame then
		return nil
	end

	local f = ether.decode(frame)

	if not f or not ether.for_us(f, self.mac) then
		return nil
	end

	if f.type == ether.ARP then
		local a = arp.observe(frame, self.mac)

		if a then
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

	if not p or (p.dst ~= self.ip and p.dst ~= ip4.BROADCAST) then
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
