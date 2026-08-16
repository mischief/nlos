-- advertising data: the length-type-value list an advertisement carries.
--
-- Both directions, since a mesh node builds one and reads others. A
-- malformed list decodes as far as it parses rather than being
-- refused: the rest of an advertisement is still worth having.

local M = {}

M.FLAGS = 0x01
M.UUID16_SOME = 0x02
M.UUID16_ALL = 0x03
M.UUID128_SOME = 0x06
M.UUID128_ALL = 0x07
M.NAME_SHORT = 0x08
M.NAME = 0x09
M.TXPOWER = 0x0a
M.SERVICE_DATA = 0x16
M.MANUFACTURER = 0xff

-- general discoverable, and no classic radio to offer.
M.FLAG_LE_GENERAL = 0x06

-- the raw list, as {type=, data=} in the order they appeared. A field
-- whose length runs past the end stops the walk: the bytes after it
-- cannot be trusted to be a field at all.
function M.decode(bytes)
	local out = {}
	local at = 1

	while at <= #bytes do
		local len = bytes:byte(at)

		if not len or len == 0 then
			break			-- padding to 31 bytes
		end
		if at + len > #bytes then
			break
		end
		out[#out + 1] = {
			type = bytes:byte(at + 1),
			data = bytes:sub(at + 2, at + len),
		}
		at = at + len + 1
	end
	return out
end

-- what a scanner usually wants: the name, the flags, and the services
-- offered, with the uuids as wire bytes so ble.uuid can compare them.
function M.parse(bytes)
	local f = { uuids = {} }

	for _, e in ipairs(M.decode(bytes)) do
		if e.type == M.NAME or e.type == M.NAME_SHORT then
			f.name = e.data
			f.shortname = e.type == M.NAME_SHORT
		elseif e.type == M.FLAGS then
			f.flags = e.data:byte(1)
		elseif e.type == M.TXPOWER then
			local p = e.data:byte(1)

			f.txpower = p and (p > 127 and p - 256 or p) or nil
		elseif e.type == M.UUID16_SOME or e.type == M.UUID16_ALL then
			for i = 1, #e.data - 1, 2 do
				f.uuids[#f.uuids + 1] = e.data:sub(i, i + 1)
			end
		elseif e.type == M.UUID128_SOME or e.type == M.UUID128_ALL then
			for i = 1, #e.data - 15, 16 do
				f.uuids[#f.uuids + 1] = e.data:sub(i, i + 15)
			end
		elseif e.type == M.MANUFACTURER then
			f.manufacturer = e.data
		elseif e.type == M.SERVICE_DATA then
			f.servicedata = e.data
		end
	end
	return f
end

-- one field, encoded.
function M.field(t, data)
	return string.char(#data + 1, t) .. data
end

-- a whole advertisement. It is always 31 bytes on the wire whatever is
-- in it, and the caller is told when what it asked for does not fit
-- rather than having it quietly trimmed.
function M.encode(fields)
	local parts = {}

	for _, e in ipairs(fields) do
		parts[#parts + 1] = M.field(e.type, e.data)
	end

	local body = table.concat(parts)

	if #body > 31 then
		return nil, "advertisement is " .. #body .. " bytes, over 31"
	end
	return body
end

-- the usual advertisement: discoverable, named, offering a service.
function M.simple(name, service)
	local fields = {
		{ type = M.FLAGS, data = string.char(M.FLAG_LE_GENERAL) },
	}

	if service then
		fields[#fields + 1] = {
			type = #service == 2 and M.UUID16_ALL or M.UUID128_ALL,
			data = service,
		}
	end
	if name then
		fields[#fields + 1] = { type = M.NAME, data = name }
	end
	return M.encode(fields)
end

return M
