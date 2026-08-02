-- ICMP, RFC 792: echo and the errors worth recognising.
--
-- Echo is the whole point of implementing this early. It is the only
-- protocol whose correct operation is something a person can observe
-- from outside the machine -- ping it and it answers -- which makes it
-- the first end-to-end proof that the ethernet, ARP and IPv4 layers
-- underneath all agree with an implementation that is not ours.
--
-- Errors are decoded but not acted on. Knowing that a destination was
-- unreachable is useful to whatever asked; deciding what to do about it
-- belongs to that caller, not here.

local ip4 = require("ip4")

local icmp = {}

icmp.ECHO_REPLY = 0
icmp.DEST_UNREACH = 3
icmp.ECHO_REQUEST = 8
icmp.TIME_EXCEEDED = 11

icmp.HDRLEN = 8		-- type, code, checksum, and four bytes of rest

-- the checksum covers the whole message, header and data, with its own
-- field zeroed -- unlike ip's, which covers only the header.
local function with_checksum(body)
	local ck = ip4.checksum(body)

	return body:sub(1, 2) .. string.pack(">I2", ck) .. body:sub(5)
end

function icmp.echo(kind, id, seq, data)
	return with_checksum(string.pack(">I1I1I2I2I2", kind, 0, 0, id, seq) ..
	    (data or ""))
end

function icmp.echo_request(id, seq, data)
	return icmp.echo(icmp.ECHO_REQUEST, id, seq, data)
end

-- nil unless it is a whole ICMP message that adds up. The checksum is
-- checked here rather than left to the caller: an echo reply whose
-- payload was damaged is not a reply to anything.
function icmp.decode(p)
	if type(p) ~= "string" or #p < icmp.HDRLEN then
		return nil
	end
	if ip4.checksum(p) ~= 0 then
		return nil
	end

	local t = {
		type = p:byte(1),
		code = p:byte(2),
	}

	if t.type == icmp.ECHO_REQUEST or t.type == icmp.ECHO_REPLY then
		t.id = string.unpack(">I2", p, 5)
		t.seq = string.unpack(">I2", p, 7)
		t.data = p:sub(icmp.HDRLEN + 1)
	else
		-- an error carries the head of the packet that caused it,
		-- which is how a sender matches it to what it sent.
		t.quote = p:sub(icmp.HDRLEN + 1)
	end
	return t
end

-- the answer to someone else's echo request: same id, same sequence,
-- same data, which is what makes a ping round trip mean anything.
function icmp.reply_to(req)
	if req.type ~= icmp.ECHO_REQUEST then
		return nil
	end
	return icmp.echo(icmp.ECHO_REPLY, req.id, req.seq, req.data)
end

return icmp
