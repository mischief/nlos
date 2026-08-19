-- usb: a configuration descriptor, read.
--
-- A descriptor set is a flat run of length-prefixed records. What makes
-- it a tree is position: a record belongs to the interface that came
-- before it. This walks the run once and rebuilds that tree.

local M = {}

-- descriptor types
M.DEVICE = 0x01
M.CONFIG = 0x02
M.STRING = 0x03
M.INTERFACE = 0x04
M.ENDPOINT = 0x05
M.CS_INTERFACE = 0x24
M.CS_ENDPOINT = 0x25

-- classes worth naming here
M.AUDIO = 0x01
M.HID = 0x03

-- audio subclasses
M.AUDIOCONTROL = 0x01
M.AUDIOSTREAMING = 0x02

-- endpoint attributes
M.ISOCHRONOUS = 0x01

local function u8(s, i)
	return s:byte(i)
end

local function u16(s, i)
	return s:byte(i) | (s:byte(i + 1) << 8)
end

local function u24(s, i)
	return s:byte(i) | (s:byte(i + 1) << 8) | (s:byte(i + 2) << 16)
end

M.u8, M.u16, M.u24 = u8, u16, u24

-- records(bytes) -> iterator over { type, at, bytes }
--
-- A zero length record would not advance, so it ends the walk rather
-- than looping on it.
function M.records(s)
	local i = 1

	return function()
		if i + 1 > #s then
			return nil
		end

		local len = u8(s, i)

		if len < 2 or i + len - 1 > #s then
			return nil
		end

		local rec = { len = len, type = u8(s, i + 1), at = i,
		    bytes = s:sub(i, i + len - 1) }

		i = i + len
		return rec
	end
end

-- parse(bytes) -> config, or nil and why
--
-- config.interfaces is every alternate setting in order, each with its
-- own endpoints and its class-specific records. An alternate setting is
-- a separate entry: they differ in what they can do, which is the whole
-- reason to choose between them.
function M.parse(s)
	if #s < 9 or u8(s, 2) ~= M.CONFIG then
		return nil, "not a configuration descriptor"
	end

	local cfg = {
		total = u16(s, 3),
		ninterfaces = u8(s, 5),
		value = u8(s, 6),
		selfpowered = (u8(s, 8) & 0x40) ~= 0,
		maxpower = u8(s, 9) * 2,	-- milliamps
		interfaces = {},
		control = {},
	}

	local cur

	for rec in M.records(s) do
		local b = rec.bytes

		if rec.type == M.INTERFACE then
			cur = {
				number = u8(b, 3),
				alt = u8(b, 4),
				nendpoints = u8(b, 5),
				class = u8(b, 6),
				subclass = u8(b, 7),
				protocol = u8(b, 8),
				endpoints = {},
				cs = {},
			}
			cfg.interfaces[#cfg.interfaces + 1] = cur
		elseif rec.type == M.ENDPOINT and cur then
			cur.endpoints[#cur.endpoints + 1] = {
				address = u8(b, 3),
				attributes = u8(b, 4),
				maxpacket = u16(b, 5),
				interval = u8(b, 7),
				input = (u8(b, 3) & 0x80) ~= 0,
				transfer = u8(b, 4) & 0x03,
			}
		elseif rec.type == M.CS_INTERFACE or rec.type == M.CS_ENDPOINT then
			-- class records before any interface belong to the
			-- configuration; after one, to that interface.
			local into = cur and cur.cs or cfg.control

			into[#into + 1] = { type = rec.type,
			    subtype = u8(b, 3), bytes = b }
		end
	end
	return cfg
end

-- an endpoint's synchronisation, which decides who sets the pace
function M.syncof(ep)
	return (ep.attributes >> 2) & 0x03
end

M.SYNC_NONE = 0
M.SYNC_ASYNC = 1
M.SYNC_ADAPTIVE = 2
M.SYNC_SYNC = 3

return M
