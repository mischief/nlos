-- GATT: an attribute database and the server procedures over it.
--
-- Sans-io like the layers below: a request PDU in, a response PDU out.
-- What a service looks like on the wire is entirely handles and
-- declarations, so building the database is where the shape is decided
-- and answering is mechanical.

local att = require("ble.att")
local uuid = require("ble.uuid")

local M = {}

-- the declarations a database is made of, as assigned numbers.
M.PRIMARY_SERVICE = uuid.short(0x2800)
M.SECONDARY_SERVICE = uuid.short(0x2801)
M.CHARACTERISTIC = uuid.short(0x2803)
M.CCCD = uuid.short(0x2902)

-- characteristic properties.
M.READ = 0x02
M.WRITE_NO_RSP = 0x04
M.WRITE = 0x08
M.NOTIFY = 0x10
M.INDICATE = 0x20

-- what a client wrote to a CCCD to ask for updates.
M.CCCD_NOTIFY = 0x0001
M.CCCD_INDICATE = 0x0002

local Db = {}

Db.__index = Db

function M.new()
	return setmetatable({ attrs = {}, next = 1 }, Db)
end

local function add(db, u, value, opts)
	local a = {
		handle = db.next,
		uuid = u,
		value = value or "",
		read = opts and opts.read,
		write = opts and opts.write,
	}

	db.attrs[#db.attrs + 1] = a
	db.next = db.next + 1
	return a
end

-- a service and its characteristics in one call: the handles must be
-- contiguous and the end handle is unknown until the last one has one.
-- Each is {uuid=, props=, value=, read=, write=}, and a notify or
-- indicate property adds the descriptor a client subscribes through,
-- since without one it has no way to ask.
function Db:service(u, chars)
	local decl = add(self, M.PRIMARY_SERVICE, u)
	local out = {}

	for _, c in ipairs(chars or {}) do
		local props = c.props or M.READ
		local vh = self.next + 1
		local d = add(self, M.CHARACTERISTIC,
		    string.pack("<BI2", props, vh) .. c.uuid)
		local v = add(self, c.uuid, c.value,
		    { read = c.read, write = c.write })

		v.props = props
		d.value = string.pack("<BI2", props, v.handle) .. c.uuid

		local entry = { decl = d, value = v }

		if (props & M.NOTIFY) ~= 0 or (props & M.INDICATE) ~= 0 then
			entry.cccd = add(self, M.CCCD, "\0\0")
			entry.cccd.subscribed = 0
		end
		entry.name = c.name
		out[#out + 1] = entry
	end

	decl.last = self.next - 1
	decl.service = true
	return { decl = decl, chars = out }
end

-- drop a service and everything inside it. Handles are reused only
-- when the database empties: a peer caches what it discovered, and
-- reissuing a live handle to a different attribute would answer its
-- next read with somebody else's value.
function Db:remove(svc)
	local first, last = svc.decl.handle, svc.decl.last
	local kept = {}

	for _, a in ipairs(self.attrs) do
		if a.handle < first or a.handle > last then
			kept[#kept + 1] = a
		end
	end
	self.attrs = kept
	if #kept == 0 then
		self.next = 1
	end
end

function Db:find(handle)
	for _, a in ipairs(self.attrs) do
		if a.handle == handle then
			return a
		end
	end
	return nil
end

-- ---- the procedures ----

-- Read By Group Type: which primary services are there. Entries are
-- start, end and the service uuid, all the same length in one
-- response -- so a 16-bit service and a 128-bit one cannot share it.
local function bygroup(db, m, mtu)
	local entries, elen = {}, nil

	for _, a in ipairs(db.attrs) do
		if a.service and a.handle >= m.start and a.handle <= m.last and
		    uuid.eq(a.uuid, m.uuid) then
			local e = string.pack("<I2I2", a.handle, a.last) ..
			    a.value

			if not elen then
				elen = #e
			end
			if #e ~= elen then
				break
			end
			if not att.fits(mtu, 2 + #entries * elen, elen) then
				break
			end
			entries[#entries + 1] = e
		end
	end
	if #entries == 0 then
		return att.error(m.op, m.start, att.ERR_ATTR_NOT_FOUND)
	end
	return att.readbygrouprsp(elen, entries)
end

-- Read By Type: the attributes of a type in a range. A client uses it
-- for characteristic declarations, and may use it to read a value.
local function bytype(db, m, mtu)
	local entries, elen = {}, nil

	for _, a in ipairs(db.attrs) do
		if a.handle >= m.start and a.handle <= m.last and
		    uuid.eq(a.uuid, m.uuid) then
			local v = a.read and a.read(a) or a.value
			local e = string.pack("<I2", a.handle) .. v

			if not elen then
				elen = #e
			end
			if #e ~= elen then
				break
			end
			if not att.fits(mtu, 2 + #entries * elen, elen) then
				break
			end
			entries[#entries + 1] = e
		end
	end
	if #entries == 0 then
		return att.error(m.op, m.start, att.ERR_ATTR_NOT_FOUND)
	end
	return att.readbytypersp(elen, entries)
end

-- Find Information: every handle in a range and what it is. Format 1
-- is 16-bit uuids and 2 is 128-bit, and one response may not mix them.
local function findinfo(db, m, mtu)
	local entries, fmt = {}, nil

	for _, a in ipairs(db.attrs) do
		if a.handle >= m.start and a.handle <= m.last then
			local f = #a.uuid == 2 and 1 or 2

			if not fmt then
				fmt = f
			end
			if f ~= fmt then
				break
			end
			local e = string.pack("<I2", a.handle) .. a.uuid

			if not att.fits(mtu, 2 + #entries * #e, #e) then
				break
			end
			entries[#entries + 1] = e
		end
	end
	if #entries == 0 then
		return att.error(m.op, m.start, att.ERR_ATTR_NOT_FOUND)
	end
	return att.findinforsp(fmt, entries)
end

local function readh(db, m, mtu)
	local a = db:find(m.handle)

	if not a then
		return att.error(m.op, m.handle, att.ERR_INVALID_HANDLE)
	end
	if a.props and (a.props & M.READ) == 0 then
		return att.error(m.op, m.handle, att.ERR_READ_NOT_PERMITTED)
	end

	local v = a.read and a.read(a) or a.value

	-- a value longer than the mtu is truncated here and the rest
	-- fetched with Read Blob, which is the client's move to make.
	return att.readrsp(v:sub(1, mtu - 1))
end

local function writeh(db, m)
	local a = db:find(m.handle)

	if not a then
		return att.error(m.op, m.handle, att.ERR_INVALID_HANDLE)
	end
	if a.props and (a.props & (M.WRITE | M.WRITE_NO_RSP)) == 0 and
	    not uuid.eq(a.uuid, M.CCCD) then
		return att.error(m.op, m.handle, att.ERR_WRITE_NOT_PERMITTED)
	end

	if uuid.eq(a.uuid, M.CCCD) then
		-- subscribing: two bytes saying notify, indicate or
		-- neither, kept per attribute rather than per connection
		-- because one link is all this serves.
		a.value = m.value
		a.subscribed = #m.value >= 2 and
		    string.unpack("<I2", m.value) or 0
	elseif a.write then
		a.write(a, m.value)
	else
		a.value = m.value
	end
	return nil
end

-- a request in, the response out, or nil where none is owed -- which
-- is a write command, and is not the same as having nothing to say.
function Db:request(pdu, mtu)
	local m, why = att.decode(pdu)

	mtu = mtu or att.DEFAULT_MTU

	if not m then
		return att.error(0, 0, att.ERR_INVALID_PDU), why
	end

	if m.op == att.OP_READ_BY_GROUP_REQ then
		return bygroup(self, m, mtu)
	elseif m.op == att.OP_READ_BY_TYPE_REQ then
		return bytype(self, m, mtu)
	elseif m.op == att.OP_FIND_INFO_REQ then
		return findinfo(self, m, mtu)
	elseif m.op == att.OP_READ_REQ then
		return readh(self, m, mtu)
	elseif m.op == att.OP_WRITE_REQ then
		local err = writeh(self, m)

		return err or att.writersp()
	elseif m.op == att.OP_WRITE_CMD then
		writeh(self, m)
		return nil
	elseif m.op == att.OP_MTU_REQ then
		return nil, "mtu is the caller's to answer"
	end
	return att.error(m.op, m.handle or 0, att.ERR_REQ_NOT_SUPPORTED)
end

-- a notification for a characteristic, or nil where nobody subscribed.
-- Silence is the right answer then: an unsubscribed notification is a
-- packet the client is entitled to ignore, and some will disconnect.
function M.notify(entry, value)
	if not entry.cccd or entry.cccd.subscribed == 0 then
		return nil
	end
	entry.value.value = value
	if (entry.cccd.subscribed & M.CCCD_INDICATE) ~= 0 then
		return att.indicate(entry.value.handle, value)
	end
	return att.notify(entry.value.handle, value)
end

M.Db = Db

return M
