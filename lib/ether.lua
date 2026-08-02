-- ethernet framing: the fourteen bytes at the front of a frame, and
-- nothing above them.
--
-- lib/eth.lua is the task that owns the device and moves frames as
-- opaque strings. This is the first thing that looks inside one. The
-- split matters: the driver task holds a capability and must stay the
-- only holder, while this is pure string work that any proc can do to
-- bytes it already has.
--
-- Addresses are 6-byte strings and stay that way. Formatting one for a
-- human is a separate function nobody on the wire path calls.

local ether = {}

ether.HDRLEN = 14

ether.BROADCAST = string.rep("\255", 6)
ether.ZERO = string.rep("\0", 6)

-- the two ethertypes anything here will carry
ether.ARP = 0x0806
ether.IPV4 = 0x0800

-- everything on the wire is big-endian, which is what ">" means to
-- string.pack -- so no byte order helpers appear anywhere below.
function ether.encode(dst, src, etype, payload)
	return dst .. src .. string.pack(">I2", etype) .. payload
end

-- nil for anything too short to have a header, rather than an error: a
-- receiver is fed whatever arrives, including runts, and a malformed
-- frame is an ordinary event on a wire rather than a bug in the caller.
function ether.decode(frame)
	if type(frame) ~= "string" or #frame < ether.HDRLEN then
		return nil
	end

	local etype = string.unpack(">I2", frame, 13)

	return {
		dst = frame:sub(1, 6),
		src = frame:sub(7, 12),
		type = etype,
		payload = frame:sub(ether.HDRLEN + 1),
	}
end

-- is this frame addressed to us, or to everyone?
--
-- A real nic filters this in hardware; a virtio queue hands over what
-- it was given, and under a bridge that includes traffic for other
-- machines entirely.
function ether.for_us(f, mac)
	return f.dst == mac or f.dst == ether.BROADCAST or
	    (f.dst:byte(1) & 1) == 1	-- multicast
end

function ether.mac_str(mac)
	if type(mac) ~= "string" or #mac ~= 6 then
		return "?"
	end
	return string.format("%02x:%02x:%02x:%02x:%02x:%02x", mac:byte(1, 6))
end

return ether
