-- UUIDs, in the three widths bluetooth uses them.
--
-- Held as the little-endian bytes that go on the wire, 2, 4 or 16 of
-- them, because that is what every comparison and every PDU wants. The
-- 16-bit ones are the assigned numbers; the rest are somebody's own.

local M = {}

-- the base every short UUID expands into, little-endian.
local BASE = "\251\52\155\95\128\0\0\128\0\16\0\0\0\0\0\0"

-- from an assigned number, as the specification tables give it.
function M.short(n)
	return string.pack("<I2", n)
end

-- from the usual written form, whatever its length. Case and dashes
-- are ignored, and the text is big-endian where the wire is not.
function M.parse(s)
	local hex = s:gsub("-", ""):lower()

	if not hex:match("^%x+$") or (#hex ~= 4 and #hex ~= 8 and #hex ~= 32) then
		return nil, "not a uuid"
	end

	local out = {}

	for i = #hex - 1, 1, -2 do
		out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
	end
	return table.concat(out)
end

-- the written form, big-endian and dashed where it is long.
function M.tostring(u)
	local hex = {}

	for i = #u, 1, -1 do
		hex[#hex + 1] = string.format("%02x", u:byte(i))
	end
	local s = table.concat(hex)

	if #u ~= 16 then
		return s
	end
	return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) ..
	    "-" .. s:sub(17, 20) .. "-" .. s:sub(21)
end

-- a short UUID as its full 128-bit form, which is what makes two of
-- different widths comparable.
function M.expand(u)
	if #u == 16 then
		return u
	end
	if #u == 2 then
		return BASE:sub(1, 12) .. u .. BASE:sub(15)
	end
	if #u == 4 then
		return BASE:sub(1, 12) .. u
	end
	return nil, "not a uuid"
end

-- whether two name the same attribute, whatever widths they arrived in.
function M.eq(a, b)
	if a == b then
		return true
	end
	local ea, eb = M.expand(a), M.expand(b)

	return ea ~= nil and ea == eb
end

return M
