-- GAP: the LE commands that find peers and connect to them, and the
-- events they answer with.
--
-- Command builders rather than a state machine, because what paces
-- scanning and connecting is the caller's business -- a mesh node does
-- both at once, and the controller's activity budget is what limits it.

local hci = require("ble.hci")

local M = {}

M.SET_ADV_PARAMS = hci.opcode(hci.OGF_LE, 0x0006)
M.SET_ADV_DATA = hci.opcode(hci.OGF_LE, 0x0008)
M.SET_SCAN_RSP_DATA = hci.opcode(hci.OGF_LE, 0x0009)
M.SET_ADV_ENABLE = hci.opcode(hci.OGF_LE, 0x000a)
M.SET_SCAN_PARAMS = hci.opcode(hci.OGF_LE, 0x000b)
M.SET_SCAN_ENABLE = hci.opcode(hci.OGF_LE, 0x000c)
M.CREATE_CONN = hci.opcode(hci.OGF_LE, 0x000d)
M.CREATE_CONN_CANCEL = hci.opcode(hci.OGF_LE, 0x000e)
M.READ_BUFFER_SIZE = hci.opcode(hci.OGF_LE, 0x0002)
M.DISCONNECT = hci.opcode(hci.OGF_LINK_CTL, 0x0006)

-- LE meta subevents.
M.SUB_CONN_COMPLETE = 0x01
M.SUB_ADV_REPORT = 0x02
M.SUB_CONN_UPDATE = 0x03
M.SUB_ENHANCED_CONN_COMPLETE = 0x0a

-- and the one plain event a connection ends with.
M.EVT_DISCONN_COMPLETE = 0x05

M.ADDR_PUBLIC = 0x00
M.ADDR_RANDOM = 0x01

-- advertising event types, as a report gives them.
M.ADV_IND = 0x00		-- connectable, undirected
M.ADV_DIRECT_IND = 0x01
M.ADV_SCAN_IND = 0x02
M.ADV_NONCONN_IND = 0x03
M.SCAN_RSP = 0x04

-- units of 0.625ms, which is how every interval here is counted.
local function units(ms)
	return math.floor(ms / 0.625)
end

M.units = units

-- Passive by default: an active scan asks each advertiser for a scan
-- response, which doubles the radio traffic and tells a room full of
-- peers that somebody is looking.
function M.scanparams(opts)
	opts = opts or {}
	return M.SET_SCAN_PARAMS, string.pack("<BI2I2BB",
	    opts.active and 0x01 or 0x00,
	    units(opts.interval_ms or 60),
	    units(opts.window_ms or 30),
	    opts.own_addr or M.ADDR_PUBLIC,
	    opts.filter or 0x00)
end

-- Duplicate filtering is the controller's, and it is off by default
-- here: a mesh wants to see a peer again to know it is still there.
function M.scanenable(on, dedup)
	return M.SET_SCAN_ENABLE, string.char(on and 1 or 0, dedup and 1 or 0)
end

function M.advparams(opts)
	opts = opts or {}
	return M.SET_ADV_PARAMS, string.pack("<I2I2BBB",
	    units(opts.min_ms or 100), units(opts.max_ms or 150),
	    opts.type or 0x00, opts.own_addr or M.ADDR_PUBLIC, 0x00) ..
	    string.rep("\0", 6) ..
	    string.char(opts.channels or 0x07, opts.filter or 0x00)
end

-- the data field is always 31 bytes however much of it means anything.
function M.advdata(bytes)
	return M.SET_ADV_DATA,
	    string.char(#bytes) .. bytes .. string.rep("\0", 31 - #bytes)
end

function M.advenable(on)
	return M.SET_ADV_ENABLE, string.char(on and 1 or 0)
end

-- Connect to one peer. The scan interval and window here are the
-- controller's own while it looks for the advertisement to connect to,
-- and are separate from a scan the caller may have running.
function M.connect(addr, opts)
	opts = opts or {}
	return M.CREATE_CONN, string.pack("<I2I2BB", units(60), units(30),
	    0x00, opts.addr_type or M.ADDR_PUBLIC) .. addr ..
	    string.pack("<BI2I2I2I2I2I2", opts.own_addr or M.ADDR_PUBLIC,
	    units(opts.min_ms or 30), units(opts.max_ms or 50),
	    opts.latency or 0, (opts.timeout_ms or 4000) // 10, 0, 0)
end

function M.disconnect(handle, reason)
	return M.DISCONNECT, string.pack("<I2B", handle, reason or 0x13)
end

-- ---- events ----

-- one LE Advertising Report meta event, which may carry several. The
-- rssi is signed and the address is little-endian, both of which read
-- as nonsense if taken at face value.
function M.advreports(params)
	local n = params:byte(1) or 0
	local out = {}
	local at = 2

	for _ = 1, n do
		if at + 8 > #params then
			break
		end
		local evtype, atype = params:byte(at), params:byte(at + 1)
		local addr = params:sub(at + 2, at + 7)
		local dlen = params:byte(at + 8)

		if at + 8 + dlen > #params then
			break
		end
		local rssi = params:byte(at + 9 + dlen)

		out[#out + 1] = {
			evtype = evtype,
			addrtype = atype,
			addr = addr,
			data = params:sub(at + 9, at + 8 + dlen),
			rssi = rssi and (rssi > 127 and rssi - 256 or rssi),
		}
		at = at + 10 + dlen
	end
	return out
end

-- an address as it is written, high byte first, which is the reverse
-- of the wire.
function M.addrstr(addr)
	local o = {}

	for i = 6, 1, -1 do
		o[#o + 1] = string.format("%02x", addr:byte(i))
	end
	return table.concat(o, ":")
end

-- and back, for a caller that was given one to dial.
function M.parseaddr(s)
	local b = {}

	for h in s:gmatch("%x%x") do
		table.insert(b, 1, string.char(tonumber(h, 16)))
	end
	if #b ~= 6 then
		return nil, "not an address"
	end
	return table.concat(b)
end

-- LE Connection Complete, in either of its two forms: the enhanced one
-- adds the local resolvable address and moves nothing before it.
function M.connreport(params)
	if #params < 18 then
		return nil
	end
	local status, handle, role, atype = string.unpack("<BI2BB", params)

	return {
		status = status,
		handle = handle,
		role = role,		-- 0 central, 1 peripheral
		addrtype = atype,
		addr = params:sub(6, 11),
	}
end

return M
