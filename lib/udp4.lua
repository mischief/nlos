-- UDP over IPv4, RFC 768. Eight bytes of header and one awkward
-- checksum.
--
-- Named udp4 and not udp because "udp" is the name of the message
-- protocol in lib/caps.lua, which is what a client holds a right to and
-- all it can see. This is the layer under that -- the datagram itself.
-- task/ip.lua is what serves the one in terms of the other, so
-- lib/dhcp.lua and lib/dns.lua reach the wire without knowing it.
--
-- The checksum is the awkward part, and the reason this module needs to
-- know about addresses at all. UDP's covers a pseudo-header made of the
-- IP source, destination and protocol, which is a layering violation
-- baked into the specification: it exists so a datagram delivered to
-- the wrong host cannot be silently accepted. So encode takes the
-- addresses it is about to be wrapped in.

local ip4 = require("ip4")
local buf = require("los.buf")

local udp4 = {}

udp4.HDRLEN = 8

-- src, dst, protocol and udp length, summed but never transmitted.
local function pseudo(src, dst, len)
	return src .. dst .. string.pack(">I1I1I2", 0, ip4.PROTO_UDP, len)
end

-- `out` and `off` write the datagram into a frame the caller already
-- allocated, which is where the payload is copied exactly once. The
-- pseudo-header is summed on its own and carried in as the running sum
-- rather than concatenated in front of the bytes.
function udp4.encode(sport, dport, data, src, dst, out, off)
	local len = udp4.HDRLEN + #data

	if out then
		out:setu16be(off, sport)
		out:setu16be(off + 2, dport)
		out:setu16be(off + 4, len)
		out:setu16be(off + 6, 0)
		out:copy(off + udp4.HDRLEN, data)

		local ck = ip4.checksum(out:view(off, off + len - 1),
		    (~ip4.checksum(pseudo(src, dst, len))) & 0xffff)

		if ck == 0 then
			ck = 0xffff
		end
		out:setu16be(off + 6, ck)
		return len
	end

	local hdr = string.pack(">I2I2I2I2", sport, dport, len, 0)
	local ck = ip4.checksum(pseudo(src, dst, len) .. hdr .. data)

	-- zero means "no checksum" on the wire, so a computed zero is sent
	-- as its other representation. In one's complement they are the
	-- same number; only this field distinguishes them.
	if ck == 0 then
		ck = 0xffff
	end
	return hdr:sub(1, 6) .. string.pack(">I2", ck) .. data
end

-- nil for anything that is not a whole datagram.
--
-- The checksum is verified only when the sender computed one: it is
-- optional in IPv4, and a zero field means "not computed" rather than
-- "computed as zero". src and dst are needed to check it and so are
-- required to verify -- pass them when the caller has them, which the
-- ip layer always does.
function udp4.decode(p, src, dst)
	local isbuf = buf.is(p)

	if (type(p) ~= "string" and not isbuf) or #p < udp4.HDRLEN then
		return nil
	end

	local sport, dport, len, ck

	if isbuf then
		sport, dport, len, ck = p:u16be(1), p:u16be(3), p:u16be(5),
		    p:u16be(7)
	else
		sport, dport, len, ck = string.unpack(">I2I2I2I2", p)
	end

	if len < udp4.HDRLEN or len > #p then
		return nil
	end

	local body = isbuf and p:view(1, len) or p:sub(1, len)

	if ck ~= 0 and src and dst then
		-- the pseudo-header is summed on its own and carried in,
		-- so the datagram is not copied to be checked
		if ip4.checksum(body,
		    (~ip4.checksum(pseudo(src, dst, len))) & 0xffff) ~= 0 then
			return nil
		end
	end

	return {
		sport = sport,
		dport = dport,
		data = isbuf and body:view(udp4.HDRLEN + 1, len) or
		    body:sub(udp4.HDRLEN + 1),
	}
end

return udp4
