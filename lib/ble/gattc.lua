-- GATT client: the procedures a central runs against somebody's server.
--
-- Discovery is a walk: ask from a handle, take what comes back, ask
-- past it, stop when told there is no more. A characteristic here
-- holds handles as numbers, where ble.gatt's holds the attributes
-- themselves -- the field names match and the types do not.

local att = require("ble.att")
local uuid = require("ble.uuid")
local gatt = require("ble.gatt")

local M = {}

-- ---- one round trip at a time ----

function M.services(from)
	return string.pack("<BI2I2", att.OP_READ_BY_GROUP_REQ, from or 1,
	    0xffff) .. gatt.PRIMARY_SERVICE
end

-- entries, or nil and "done" where the server says there are no more.
-- Attribute Not Found is how a walk ends, so it is not an error.
local function unpackrsp(pdu, want, size)
	local m = att.decode(pdu)

	if not m then
		return nil, "undecodable"
	end
	if m.op == att.OP_ERROR then
		if m.err == att.ERR_ATTR_NOT_FOUND then
			return nil, "done"
		end
		return nil, string.format("error 0x%02x", m.err)
	end
	if m.op ~= want then
		return nil, string.format("unexpected op 0x%02x", m.op)
	end

	local elen = pdu:byte(2)

	if not elen or elen < size then
		return nil, "entry too short"
	end
	local out = {}

	for at = 3, #pdu - elen + 1, elen do
		out[#out + 1] = pdu:sub(at, at + elen - 1)
	end
	return out
end

function M.services_result(pdu)
	local raw, err = unpackrsp(pdu, att.OP_READ_BY_GROUP_RSP, 6)

	if not raw then
		return nil, err
	end

	local out = {}

	for _, e in ipairs(raw) do
		local start, last = string.unpack("<I2I2", e)

		out[#out + 1] = { start = start, last = last,
		    uuid = e:sub(5) }
	end
	return out
end

function M.characteristics(from, to)
	return string.pack("<BI2I2", att.OP_READ_BY_TYPE_REQ, from,
	    to or 0xffff) .. gatt.CHARACTERISTIC
end

function M.characteristics_result(pdu)
	local raw, err = unpackrsp(pdu, att.OP_READ_BY_TYPE_RSP, 7)

	if not raw then
		return nil, err
	end

	local out = {}

	for _, e in ipairs(raw) do
		local decl, props, vh = string.unpack("<I2BI2", e)

		out[#out + 1] = { decl = decl, props = props, value = vh,
		    uuid = e:sub(6) }
	end
	return out
end

function M.descriptors(from, to)
	return string.pack("<BI2I2", att.OP_FIND_INFO_REQ, from, to)
end

function M.descriptors_result(pdu)
	local m = att.decode(pdu)

	if not m then
		return nil, "undecodable"
	end
	if m.op == att.OP_ERROR then
		return nil, m.err == att.ERR_ATTR_NOT_FOUND and "done" or
		    string.format("error 0x%02x", m.err)
	end
	if m.op ~= att.OP_FIND_INFO_RSP then
		return nil, "unexpected op"
	end

	local fmt = pdu:byte(2)
	local w = fmt == 1 and 2 or 16
	local out = {}

	for at = 3, #pdu - w - 1, 2 + w do
		out[#out + 1] = {
			handle = string.unpack("<I2", pdu:sub(at)),
			uuid = pdu:sub(at + 2, at + 1 + w),
		}
	end
	return out
end

M.read = att.readreq
M.write = att.writereq

function M.writecmd(handle, value)
	return string.pack("<BI2", att.OP_WRITE_CMD, handle) .. value
end

-- subscribing is an ordinary write to the descriptor, which is why a
-- client has to find that descriptor first.
function M.subscribe(cccd, indicate)
	return att.writereq(cccd, string.pack("<I2",
	    indicate and gatt.CCCD_INDICATE or gatt.CCCD_NOTIFY))
end

function M.unsubscribe(cccd)
	return att.writereq(cccd, "\0\0")
end

-- an incoming notification or indication: handle and value, plus
-- whether it must be confirmed. An indication left unconfirmed stops
-- the server sending any more.
function M.update(pdu)
	local m = att.decode(pdu)

	if not m or (m.op ~= att.OP_NOTIFY and m.op ~= att.OP_INDICATE) then
		return nil
	end
	return m.handle, m.value, m.op == att.OP_INDICATE
end

-- ---- the whole walk ----

local Walk = {}

Walk.__index = Walk

-- services, then each service's characteristics, then the descriptors
-- of each. Driven by :next() for the request to send and :feed() for
-- what came back, so the caller keeps its own loop and its own timeouts.
function M.walk()
	return setmetatable({
		stage = "services",
		from = 1,
		services = {},
		at = 0,
	}, Walk)
end

function Walk:next()
	if self.stage == "services" then
		return M.services(self.from)
	elseif self.stage == "chars" then
		local s = self.services[self.at]

		return s and M.characteristics(self.from, s.last)
	elseif self.stage == "descs" then
		local s = self.services[self.at]

		return s and M.descriptors(self.from, s.last)
	end
	return nil
end

-- move to the next service, or to the stage after this one.
local function advance(w, nextstage)
	w.at = w.at + 1
	while w.at <= #w.services do
		local s = w.services[w.at]

		-- a service whose group is only its declaration has
		-- nothing inside to ask about.
		if s.last > s.start then
			w.from = s.start + 1
			return
		end
		w.at = w.at + 1
	end
	w.stage = nextstage
	w.at = 1
	if nextstage == "descs" and #w.services > 0 then
		local s = w.services[1]

		w.from = s.start + 1
		if s.last <= s.start then
			advance(w, "done")
		end
	elseif nextstage == "done" then
		w.stage = "done"
	end
end

function Walk:feed(pdu)
	if self.stage == "services" then
		local got, err = M.services_result(pdu)

		if not got then
			if err ~= "done" then
				return nil, err
			end
			self.at = 0
			self.stage = "chars"
			advance(self, "descs")
			return true
		end
		for _, s in ipairs(got) do
			s.chars = {}
			self.services[#self.services + 1] = s
		end
		self.from = got[#got].last + 1
		if self.from > 0xffff then
			self.at = 0
			self.stage = "chars"
			advance(self, "descs")
		end
		return true
	end

	local s = self.services[self.at]

	if not s then
		self.stage = "done"
		return true
	end

	if self.stage == "chars" then
		local got, err = M.characteristics_result(pdu)

		if not got then
			if err ~= "done" then
				return nil, err
			end
			advance(self, "descs")
			return true
		end
		for _, c in ipairs(got) do
			s.chars[#s.chars + 1] = c
		end
		self.from = got[#got].decl + 1
		if self.from > s.last then
			advance(self, "descs")
		end
	elseif self.stage == "descs" then
		local got, err = M.descriptors_result(pdu)

		if not got then
			if err ~= "done" then
				return nil, err
			end
			advance(self, "done")
			return true
		end
		for _, d in ipairs(got) do
			-- a descriptor belongs to the characteristic it
			-- follows, which is the one with the largest value
			-- handle below it.
			local owner

			for _, c in ipairs(s.chars) do
				if c.value < d.handle and
				    (not owner or c.value > owner.value) then
					owner = c
				end
			end
			if owner and uuid.eq(d.uuid, gatt.CCCD) then
				owner.cccd = d.handle
			end
		end
		self.from = got[#got].handle + 1
		if self.from > s.last then
			advance(self, "done")
		end
	end
	return true
end

function Walk:done()
	return self.stage == "done"
end

M.Walk = Walk

return M
