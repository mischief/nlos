-- IPv4 addresses: four bytes, and the two conversions a human needs.
--
-- Only the addresses for now. The header codec belongs here too and
-- will land here when there is something to carry in it; ARP needs the
-- address type and nothing else, and inventing the rest before a packet
-- wants it would be guessing at a shape.
--
-- The wire form is the canonical one everywhere: a 4-byte string, never
-- a number and never dotted quad. Numbers reintroduce byte order, and
-- strings compare and concatenate directly into a packet.

local ip4 = {}

ip4.LEN = 4

ip4.ANY = string.rep("\0", 4)
ip4.BROADCAST = string.rep("\255", 4)

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

return ip4
