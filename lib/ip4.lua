-- IPv4: addresses and the header, RFC 791.
--
-- No fragmentation. decode rejects a fragment rather than handing back
-- a piece of a packet as if it were one, and encode never produces
-- one -- everything here fits in an ethernet frame by construction.
--
-- The wire form is the canonical one everywhere: a 4-byte string, never
-- a number and never dotted quad. Numbers reintroduce byte order, and
-- strings compare and concatenate directly into a packet.

local ip4 = {}

ip4.LEN = 4

ip4.ANY = string.rep("\0", 4)
ip4.BROADCAST = string.rep("\255", 4)
ip4.LOOPBACK = "\127\0\0\1"

-- the whole of 127.0.0.0/8, not just 127.0.0.1: the block is reserved
-- for this and a host is required to treat all of it as its own, which
-- is what lets 127.0.0.2 be a distinct address of the same machine.
function ip4.is_loopback(a)
	return type(a) == "string" and #a == ip4.LEN and a:byte(1) == 127
end

-- "10.0.2.2" -> "\10\0\2\2", or nil for anything that is not one.
-- Strict about range because a silent truncation to a byte turns a
-- typo'd address into a valid, wrong one.
function ip4.parse(s)
	if type(s) ~= "string" then
		return nil
	end

	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end

	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then
		return nil
	end
	return string.char(a, b, c, d)
end

function ip4.str(ip)
	if type(ip) ~= "string" or #ip ~= ip4.LEN then
		return "?"
	end
	return string.format("%d.%d.%d.%d", ip:byte(1, 4))
end

-- is `ip` on the same link as `me`, given `mask`? Which is the only
-- routing decision that exists before there is a routing table: on-link
-- means arp for it, off-link means arp for the gateway instead.
function ip4.same_net(a, b, mask)
	if #a ~= ip4.LEN or #b ~= ip4.LEN or #mask ~= ip4.LEN then
		return false
	end
	for i = 1, ip4.LEN do
		if (a:byte(i) & mask:byte(i)) ~= (b:byte(i) & mask:byte(i)) then
			return false
		end
	end
	return true
end

-- ---- the header ----

ip4.HDRLEN = 20		-- no options, ever; see encode

ip4.PROTO_ICMP = 1
ip4.PROTO_TCP = 6
ip4.PROTO_UDP = 17

local VERSION_IHL = 0x45	-- version 4, 5 words of header

-- the one's complement sum every checksum in this stack is made of:
-- ip's header checksum, icmp's, udp's pseudo-header one. Sixteen bits
-- at a time, carries folded back in, then inverted.
--
-- An odd final byte is padded with a zero, which is the specification's
-- rule and not an approximation -- the padding is for the sum only and
-- never goes on the wire.
function ip4.checksum(s, init)
	local sum = init or 0
	local n = #s
	local i = 1

	while i + 1 <= n do
		sum = sum + string.unpack(">I2", s, i)
		i = i + 2
	end
	if i <= n then
		sum = sum + (s:byte(i) << 8)
	end

	while sum > 0xffff do
		sum = (sum & 0xffff) + (sum >> 16)
	end
	return (~sum) & 0xffff
end

-- id defaults to 0, which is allowed for anything that will not be
-- fragmented (RFC 6864) and is every packet this sends. ttl defaults to
-- 64, the usual unix choice.
function ip4.encode(t)
	local total = ip4.HDRLEN + #t.payload
	local hdr = string.pack(">I1I1I2I2I2I1I1I2", VERSION_IHL, 0, total,
	    t.id or 0, 0, t.ttl or 64, t.proto, 0) .. t.src .. t.dst
	local ck = ip4.checksum(hdr)

	-- the checksum is computed over the header with its own field
	-- zeroed, then written into it.
	return hdr:sub(1, 10) .. string.pack(">I2", ck) .. hdr:sub(13) ..
	    t.payload
end

-- nil for anything that is not a whole, unfragmented IPv4 packet we can
-- act on. Like ether.decode, this is a filter: a receiver is fed
-- whatever arrives.
function ip4.decode(p)
	if type(p) ~= "string" or #p < ip4.HDRLEN then
		return nil
	end

	local vihl = p:byte(1)

	if (vihl >> 4) ~= 4 then
		return nil
	end

	local ihl = (vihl & 0x0f) * 4

	if ihl < ip4.HDRLEN or #p < ihl then
		return nil
	end

	-- the header must add up. A packet with a bad checksum is one the
	-- wire damaged, and acting on its addresses would be acting on
	-- damage.
	if ip4.checksum(p:sub(1, ihl)) ~= 0 then
		return nil
	end

	local total = string.unpack(">I2", p, 3)
	local frag = string.unpack(">I2", p, 7)

	-- more-fragments set, or a nonzero offset: a piece, not a packet.
	if (frag & 0x2000) ~= 0 or (frag & 0x1fff) ~= 0 then
		return nil
	end

	-- a frame may be padded up to its minimum length, so the packet is
	-- as long as the header says and no longer.
	if total < ihl or total > #p then
		total = #p
	end

	return {
		proto = p:byte(10),
		ttl = p:byte(9),
		id = string.unpack(">I2", p, 5),
		src = p:sub(13, 16),
		dst = p:sub(17, 20),
		payload = p:sub(ihl + 1, total),
	}
end

return ip4
