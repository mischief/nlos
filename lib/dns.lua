-- dns: the wire format, and nothing that carries it.
--
-- Query building and response parsing, in the string.pack/unpack style
-- lib/ninep.lua uses. Extracted from task/dns.lua, which had it as
-- local functions and could not share them: the same codec now serves
-- that task, which rides the firmware's udp4 through a capability, and
-- lib/dnsc.lua, which rides the Lua stack over raw frames. One
-- understanding of the protocol, two transports -- the same shape
-- lib/dhcp.lua and lib/dhcpc.lua already have.
--
-- Everything here is pure. That is what makes it checkable against an
-- implementation that is not ours, which for a codec is the only test
-- worth much.

local spack, sunpack = string.pack, string.unpack

local dns = {}

dns.PORT = 53

dns.TYPE_A = 1
dns.CLASS_IN = 1

local function encode_qname(name)
	local parts = {}

	for label in name:gmatch("[^.]+") do
		parts[#parts + 1] = spack("s1", label)
	end
	parts[#parts + 1] = "\0"
	return table.concat(parts)
end

function dns.build_query(name, id)
	-- header: ID, flags (0x0100 = standard query, recursion desired),
	-- QDCOUNT=1, ANCOUNT/NSCOUNT/ARCOUNT=0
	local header = spack(">I2I2I2I2I2I2", id, 0x0100, 1, 0, 0, 0)
	-- question: QNAME, QTYPE=1 (A), QCLASS=1 (IN)
	local question = encode_qname(name) ..
	    spack(">I2I2", dns.TYPE_A, dns.CLASS_IN)

	return header .. question
end

-- a NAME field in the question section is always literal labels (we
-- wrote it ourselves); in the answer section it may instead be a
-- compression pointer (top two bits of the length byte set) pointing
-- back at the question -- we only need to skip past it, never
-- resolve what it points to.
local function skip_qname(buf, off)
	while true do
		local len = buf:byte(off)

		if not len or len == 0 then
			return off + 1
		end
		off = off + 1 + len
	end
end

local function skip_name(buf, off)
	local len = buf:byte(off)

	if len and (len & 0xC0) == 0xC0 then
		return off + 2
	end
	return skip_qname(buf, off)
end

-- returns "a.b.c.d" on success, or nil + a reason on failure.
--
-- called only through dns.parse below: every sunpack here can throw on
-- a truncated buffer, and the source of these bytes is a udp datagram
-- from the network, which anything on the wire can forge and truncate.
-- an uncaught throw would take a resolver task down -- permanently, for
-- every client -- on one malformed packet.
local function parse_response(buf, expect_id)
	if #buf < 12 then
		return nil, "short reply"
	end

	local id, flags, qdcount, ancount = sunpack(">I2I2I2I2", buf)

	if id ~= expect_id then
		return nil, "id mismatch"
	end
	if (flags & 0xF) ~= 0 then
		return nil, "rcode " .. (flags & 0xF)
	end

	local off = 13	-- 1-based, right after the 12-byte header

	for _ = 1, qdcount do
		off = skip_qname(buf, off) + 4	-- +2 QTYPE, +2 QCLASS
	end
	for _ = 1, ancount do
		off = skip_name(buf, off)

		local rtype, rclass, ttl, rdlen

		rtype, rclass, ttl, rdlen, off = sunpack(">I2I2I4I2", buf, off)
		if rtype == dns.TYPE_A and rclass == dns.CLASS_IN and
		    rdlen == 4 then
			local a, b, c, d = buf:byte(off, off + 3)

			return string.format("%d.%d.%d.%d", a, b, c, d), ttl
		end
		off = off + rdlen
	end
	return nil, "no A record"
end

-- the only way in: a throw from the parser above becomes a nil, so a
-- forged packet is a failed lookup rather than a dead resolver.
function dns.parse(buf, expect_id)
	local ok, ip, why = pcall(parse_response, buf, expect_id)

	if not ok then
		return nil, "malformed reply"
	end
	return ip, why
end

return dns
