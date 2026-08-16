-- btsnoop: HCI traffic in the format btmon and Wireshark already read.
--
-- Sans-io: this returns bytes and never writes them. What it buys is a
-- trace nobody has to write a decoder for -- a protocol bug in L2CAP or
-- ATT is a packet somebody else's tool will name, the way a pcap named
-- the frames efi was dropping.

local M = {}

-- the datalink type. UART, not HCI, because our packets carry the H4
-- type byte: btmon reads that byte and takes the direction from flags.
local FORMAT_UART = 1002

-- microseconds from the unix epoch to btsnoop's, which counts from the
-- year zero. The two constants are bluez's own, kept apart so each can
-- be checked against it.
local EPOCH_2000 = 946684800 * 1000000
local BASE = 0x00E03AB44A676000

M.SENT = 0		-- host to controller
M.RECV = 1

-- the file header, once at the front.
function M.header()
	return "btsnoop\0" .. string.pack(">I4I4", 1, FORMAT_UART)
end

-- one packet. `pkt` carries its H4 type byte, `us` is unix microseconds
-- and `drops` the running count of what was never recorded.
--
-- A clock that has never been set gives a trace whose times are all
-- near the epoch. That is not worth guarding: the deltas are what a
-- reader uses, and they stay right.
function M.packet(pkt, dir, us, drops)
	local ts = (us or 0) - EPOCH_2000 + BASE

	return string.pack(">I4I4I4I4I8", #pkt, #pkt, dir or M.SENT,
	    drops or 0, ts) .. pkt
end

-- which direction a packet went, for a caller that has the bytes and
-- not the context: a command or ACL leaving is SENT, an event arriving
-- is RECV. ACL is the one that needs telling apart, since the same
-- type byte goes both ways.
function M.dirof(pkt, incoming)
	if incoming then
		return M.RECV
	end
	return M.SENT
end

return M
