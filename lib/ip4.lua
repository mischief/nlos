-- IPv4: addresses and the header, RFC 791.
--
-- No fragmentation. decode rejects a fragment rather than handing back
-- a piece of a packet as if it were one, and encode never produces
-- one -- everything here fits in an ethernet frame by construction.
--
-- The wire form is the canonical one everywhere: a 4-byte string, never
-- a number and never dotted quad. Numbers reintroduce byte order, and
-- strings compare and concatenate directly into a packet.

local buf = require("los.buf")

local ip4 = {}

-- a 16-bit big-endian field of a packet, which is a string off the wire
-- or a buffer built here. Every other read a decoder makes -- byte, sub
-- -- is spelled the same way on both.
local function u16be(p, i)
	if type(p) == "string" then
		return (string.unpack(">I2", p, i))
	end
	return p:u16be(i)
end

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
--
-- Kept in Lua as well as in src/inet.c, and this one is used whenever
-- that is absent: tools/arp-lan.lua drives these modules from the host
-- under an ordinary lua5.4, where the kernel does not exist. The two
-- are checked against each other by test/boot/test_checksum.lua, which
-- is what makes keeping both safe rather than merely convenient.
function ip4.luachecksum(s, init)
	local sum = init or 0
	local n = #s
	local i = 1

	while i + 1 <= n do
		sum = sum + u16be(s, i)
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

-- the C one when this is a lua-os proc, the Lua one on the host.
--
-- Chosen once here rather than branched per call: this runs four times
-- per udp round trip and was 85% of one at a full ethernet payload, so
-- a per-call check would be measurable in the thing being fixed.
local ok, cinet = pcall(require, "los.inet")

if ok and type(cinet) == "table" and type(cinet.checksum) == "function" then
	ip4.checksum = cinet.checksum
else
	ip4.checksum = ip4.luachecksum
end

-- id defaults to 0, which is allowed for anything that will not be
-- fragmented (RFC 6864) and is every packet this sends. ttl defaults to
-- 64, the usual unix choice.
-- the twenty bytes, written into a frame someone else allocated, with
-- the payload length given rather than the payload itself. For a sender
-- building one buffer for the whole frame.
function ip4.header(p, off, t, paylen)
	local total = ip4.HDRLEN + paylen

	p:setu8(off, VERSION_IHL)
	p:setu8(off + 1, 0)			-- dscp and ecn
	p:setu16be(off + 2, total)
	p:setu16be(off + 4, t.id or 0)
	p:setu16be(off + 6, 0)			-- flags and fragment offset
	p:setu8(off + 8, t.ttl or 64)
	p:setu8(off + 9, t.proto)
	p:setu16be(off + 10, 0)			-- summed as zero, then filled
	p:copy(off + 12, t.src)
	p:copy(off + 16, t.dst)
	p:setu16be(off + 10,
	    ip4.checksum(p:view(off, off + ip4.HDRLEN - 1)))
	return p
end

function ip4.encode(t)
	local total = ip4.HDRLEN + #t.payload
	local p = buf.new(total)

	p:setu8(1, VERSION_IHL)
	p:setu8(2, 0)			-- dscp and ecn
	p:setu16be(3, total)
	p:setu16be(5, t.id or 0)
	p:setu16be(7, 0)		-- flags and fragment offset
	p:setu8(9, t.ttl or 64)
	p:setu8(10, t.proto)
	p:setu16be(11, 0)		-- summed as zero, then filled in
	p:copy(13, t.src)
	p:copy(17, t.dst)

	-- summed over the header alone, which a view names without
	-- copying it out
	p:setu16be(11, ip4.checksum(p:view(1, ip4.HDRLEN)))
	p:copy(ip4.HDRLEN + 1, t.payload)
	return p
end

-- nil for anything that is not a whole, unfragmented IPv4 packet we can
-- act on. Like ether.decode, this is a filter: a receiver is fed
-- whatever arrives.
function ip4.decode(p)
	if (type(p) ~= "string" and not buf.is(p)) or #p < ip4.HDRLEN then
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

	local total = u16be(p, 3)
	local frag = u16be(p, 7)

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
		id = u16be(p, 5),
		src = p:sub(13, 16),
		dst = p:sub(17, 20),
		payload = p:sub(ihl + 1, total),
	}
end

return ip4
