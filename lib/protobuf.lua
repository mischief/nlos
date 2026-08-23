-- protobuf, as the wire format and nothing above it.
--
-- No schema, no .proto, no generated code: a field number, one of four
-- encodings, and bytes. A caller that knows which field means what -- a
-- reader of one message -- needs no more, and this way there is nothing
-- to regenerate when somebody upstream adds a field.

local M = {}

M.VARINT = 0
M.I64 = 1
M.BYTES = 2
M.I32 = 5

-- a varint from `at`, and where the next one starts. Seven bits a byte,
-- low group first, the top bit saying another follows.
function M.varint(s, at)
	local v, shift = 0, 0

	while at <= #s do
		local b = s:byte(at)

		v = v | ((b & 0x7f) << shift)
		at = at + 1
		if b < 0x80 then
			return v, at
		end
		shift = shift + 7
		if shift > 63 then
			return nil, at
		end
	end
	return nil, at
end

-- every field in order, as (number, wiretype, value). Values are an
-- integer for the numeric kinds and a string for the length-delimited
-- one, which is where a nested message or a string arrives.
function M.each(s)
	local at = 1

	return function()
		if at > #s then
			return nil
		end

		local tag

		tag, at = M.varint(s, at)
		if not tag then
			return nil
		end

		local field, wire = tag >> 3, tag & 7

		if wire == M.VARINT then
			local v

			v, at = M.varint(s, at)
			return field, wire, v
		elseif wire == M.BYTES then
			local n

			n, at = M.varint(s, at)
			if not n or at + n - 1 > #s then
				return nil
			end

			local v = s:sub(at, at + n - 1)

			at = at + n
			return field, wire, v
		elseif wire == M.I32 then
			if at + 3 > #s then
				return nil
			end

			local v = string.unpack("<I4", s, at)

			at = at + 4
			return field, wire, v
		elseif wire == M.I64 then
			if at + 7 > #s then
				return nil
			end

			local v = string.unpack("<I8", s, at)

			at = at + 8
			return field, wire, v
		end
		return nil		-- a wire type from a later protobuf
	end
end

-- field number to value, last one winning, which is what protobuf says
-- a scalar means when it appears twice.
function M.decode(s)
	local out = {}

	for f, _, v in M.each(s) do
		out[f] = v
	end
	return out
end

-- fields in the order given: {{number, kind, value}, ...} where kind is
-- "varint", "bytes" or "i32". Order is the caller's because protobuf
-- does not care and a test does.
local KIND = { varint = M.VARINT, bytes = M.BYTES, i32 = M.I32,
    i64 = M.I64 }

local function putvarint(out, v)
	repeat
		local b = v & 0x7f

		v = v >> 7
		if v ~= 0 then
			b = b | 0x80
		end
		out[#out + 1] = string.char(b)
	until v == 0
end

function M.encode(fields)
	local out = {}

	for _, f in ipairs(fields) do
		local num, kind, value = f[1], f[2], f[3]
		local wire = KIND[kind]

		if not wire then
			return nil, "no such kind: " .. tostring(kind)
		end
		putvarint(out, (num << 3) | wire)
		if wire == M.VARINT then
			putvarint(out, value)
		elseif wire == M.BYTES then
			putvarint(out, #value)
			out[#out + 1] = value
		elseif wire == M.I32 then
			out[#out + 1] = string.pack("<I4", value)
		else
			out[#out + 1] = string.pack("<I8", value)
		end
	end
	return table.concat(out)
end

return M
