#!/usr/bin/env lua5.4
-- lib/zlib against real zlib and gzip output.
--
-- A round trip only proves the two halves agree with each other. What
-- pins the format is the fixture below, which gzip -9 wrote.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" ..
    scriptdir .. "/../lib/?/init.lua;" .. package.path

local zlib = require("zlib")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function unhex(s)
	return (s:gsub("%x%x", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- ---- what gzip -9 wrote ----

local text = "the quick brown fox jumps over the lazy dog, " ..
    "and does it again and again and again."

local fixture = unhex(
    "1f8b08000000000002032bc94855282ccd4cce56482aca2fcf5348cbaf50" ..
    "c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb2824e6a50019a9" ..
    "c50a99250a89e9899979601134961e00609ab13d53000000")

local got, why = zlib.gzip.decompress(fixture)

ok(got == text, "gzip -9 output inflates to its input")
ok(got ~= nil or why, "and a failure would say why")

-- ---- both directions ----

local cases = {
	{ "", "empty" },
	{ "a", "one byte" },
	{ text, "text" },
	{ string.rep("x", 70000), "a long run past the window" },
	{ string.rep("abcdefgh", 5000), "a repeating pattern" },
}

for _, c in ipairs(cases) do
	local body, name = c[1], c[2]
	local z = zlib.compress(body)
	local back = zlib.decompress(z)

	ok(back == body, "zlib round trip: " .. name)

	local g = zlib.gzip.compress(body)

	ok(zlib.gzip.decompress(g) == body, "gzip round trip: " .. name)
end

-- compressible input must actually shrink, or the encoder is emitting
-- stored blocks and the trees are wrong.
local z = zlib.compress(string.rep("abcdefgh", 5000))

ok(#z < 1000, "a repeating pattern compresses")

-- ---- what a corrupt stream does ----

ok(zlib.decompress("\0\0\0\0\0\0") == nil, "a bad zlib header is refused")
ok(zlib.decompress("xx") == nil, "and a runt stream")

local bad = zlib.compress(text)

bad = bad:sub(1, #bad - 4) .. "\0\0\0\0"
ok(zlib.decompress(bad) == nil, "a wrong adler32 is caught")

-- ---- streaming, since a connection does not arrive whole ----

local whole = zlib.compress(text)
local raw = whole:sub(3, #whole - 4)
local dec = zlib.inflate.new()
local out = {}

for i = 1, #raw do
	local piece = dec:update(raw:sub(i, i))

	if piece and piece ~= "" then
		out[#out + 1] = piece
	end
end
ok(table.concat(out) == text, "inflate resumes a byte at a time")
ok(dec:finished(), "and knows the stream ended")

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
