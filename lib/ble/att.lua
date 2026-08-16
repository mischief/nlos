-- ATT: the attribute protocol, as a codec.
--
-- Sans-io and stateless: PDUs to tables and back. What holds the
-- database and decides what an answer should be is lib/ble/gatt.lua
-- above this.

local M = {}

M.OP_ERROR = 0x01
M.OP_MTU_REQ = 0x02
M.OP_MTU_RSP = 0x03
M.OP_FIND_INFO_REQ = 0x04
M.OP_FIND_INFO_RSP = 0x05
M.OP_READ_BY_TYPE_REQ = 0x08
M.OP_READ_BY_TYPE_RSP = 0x09
M.OP_READ_REQ = 0x0a
M.OP_READ_RSP = 0x0b
M.OP_READ_BLOB_REQ = 0x0c
M.OP_READ_BLOB_RSP = 0x0d
M.OP_READ_BY_GROUP_REQ = 0x10
M.OP_READ_BY_GROUP_RSP = 0x11
M.OP_WRITE_REQ = 0x12
M.OP_WRITE_RSP = 0x13
M.OP_NOTIFY = 0x1b
M.OP_INDICATE = 0x1d
M.OP_CONFIRM = 0x1e
M.OP_WRITE_CMD = 0x52

M.ERR_INVALID_HANDLE = 0x01
M.ERR_READ_NOT_PERMITTED = 0x02
M.ERR_WRITE_NOT_PERMITTED = 0x03
M.ERR_INVALID_PDU = 0x04
M.ERR_REQ_NOT_SUPPORTED = 0x06
M.ERR_INVALID_OFFSET = 0x07
M.ERR_ATTR_NOT_FOUND = 0x0a
M.ERR_UNLIKELY = 0x0e

-- the default every connection starts at, until an exchange raises it.
M.DEFAULT_MTU = 23

-- ---- decode ----

-- a PDU to a table carrying `op` and whatever that opcode defines.
-- Anything malformed comes back nil and a reason, never a partial
-- table: a caller answering a half-read request is worse than one
-- answering none.
function M.decode(pdu)
	if #pdu < 1 then
		return nil, "empty"
	end

	local op = pdu:byte(1)
	local body = pdu:sub(2)
	local m = { op = op }

	if op == M.OP_MTU_REQ or op == M.OP_MTU_RSP then
		if #body < 2 then
			return nil, "short mtu"
		end
		m.mtu = string.unpack("<I2", body)
	elseif op == M.OP_ERROR then
		if #body < 4 then
			return nil, "short error"
		end
		m.reqop, m.handle, m.err = string.unpack("<BI2B", body)
	elseif op == M.OP_FIND_INFO_REQ then
		if #body < 4 then
			return nil, "short find info"
		end
		m.start, m.last = string.unpack("<I2I2", body)
	elseif op == M.OP_READ_BY_TYPE_REQ or op == M.OP_READ_BY_GROUP_REQ then
		if #body < 6 then
			return nil, "short read by type"
		end
		m.start, m.last = string.unpack("<I2I2", body)
		m.uuid = body:sub(5)
		if #m.uuid ~= 2 and #m.uuid ~= 16 then
			return nil, "bad uuid width"
		end
	elseif op == M.OP_READ_REQ then
		if #body < 2 then
			return nil, "short read"
		end
		m.handle = string.unpack("<I2", body)
	elseif op == M.OP_READ_BLOB_REQ then
		if #body < 4 then
			return nil, "short read blob"
		end
		m.handle, m.offset = string.unpack("<I2I2", body)
	elseif op == M.OP_WRITE_REQ or op == M.OP_WRITE_CMD then
		if #body < 2 then
			return nil, "short write"
		end
		m.handle = string.unpack("<I2", body)
		m.value = body:sub(3)
	elseif op == M.OP_NOTIFY or op == M.OP_INDICATE then
		if #body < 2 then
			return nil, "short notification"
		end
		m.handle = string.unpack("<I2", body)
		m.value = body:sub(3)
	elseif op == M.OP_READ_RSP or op == M.OP_READ_BLOB_RSP then
		m.value = body
	elseif op == M.OP_WRITE_RSP or op == M.OP_CONFIRM then
		m.value = nil
	else
		m.body = body
	end
	return m
end

-- ---- encode ----

function M.error(reqop, handle, err)
	return string.pack("<BBI2B", M.OP_ERROR, reqop, handle or 0, err)
end

function M.mtureq(mtu)
	return string.pack("<BI2", M.OP_MTU_REQ, mtu)
end

function M.mtursp(mtu)
	return string.pack("<BI2", M.OP_MTU_RSP, mtu)
end

function M.readreq(handle)
	return string.pack("<BI2", M.OP_READ_REQ, handle)
end

function M.readrsp(value)
	return string.char(M.OP_READ_RSP) .. value
end

function M.writereq(handle, value)
	return string.pack("<BI2", M.OP_WRITE_REQ, handle) .. value
end

function M.writersp()
	return string.char(M.OP_WRITE_RSP)
end

function M.notify(handle, value)
	return string.pack("<BI2", M.OP_NOTIFY, handle) .. value
end

function M.indicate(handle, value)
	return string.pack("<BI2", M.OP_INDICATE, handle) .. value
end

function M.confirm()
	return string.char(M.OP_CONFIRM)
end

function M.readbytypereq(start, last, uuid)
	return string.pack("<BI2I2", M.OP_READ_BY_TYPE_REQ, start, last) .. uuid
end

-- Read By Type and Read By Group answer with a list of equal-length
-- records and say how long one is. Every entry must be the same size,
-- so a caller collects what fits and stops at the first that does not.
function M.readbytypersp(len, entries)
	return string.char(M.OP_READ_BY_TYPE_RSP, len) ..
	    table.concat(entries)
end

function M.readbygrouprsp(len, entries)
	return string.char(M.OP_READ_BY_GROUP_RSP, len) ..
	    table.concat(entries)
end

-- Find Information answers with 1 for 16-bit UUIDs and 2 for 128-bit,
-- and one response may not mix them.
function M.findinforsp(fmt, entries)
	return string.char(M.OP_FIND_INFO_RSP, fmt) .. table.concat(entries)
end

-- a response's list is bounded by the negotiated MTU, and one that
-- overruns it is dropped by the peer rather than trimmed. This is the
-- only length rule this layer enforces, because it is the only one a
-- caller cannot see from its own data.
function M.fits(mtu, sofar, add)
	return sofar + add <= mtu
end

return M
