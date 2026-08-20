#!/usr/bin/env lua5.4
-- lib/adpcm.lua against src/adpcm_native.c, over blocks built here.
--
-- The C one is what runs; the Lua one is the reference. Neither is
-- trusted alone, so every block goes through both and the two answers
-- must match byte for byte. A vector suite would be better and IMA
-- publishes none, so this is a differential test.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local adpcm = require("adpcm")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

io.write("1..7\n")

ok(adpcm.pure ~= nil, "the lua reference is reachable")
ok(adpcm.native, "the c decoder was loaded")

-- a block the encoder never made: every nibble value appears, and the
-- step index starts high enough that clamping is reached.
local function block(ch, align, seed)
	local t = {}
	local x = seed

	for c = 1, ch do
		t[#t + 1] = string.pack("<i2", (x % 4000) - 2000)
		t[#t + 1] = string.char((x + c * 7) % 89, 0)
		x = (x * 1103515245 + 12345) & 0x7fffffff
	end
	while #table.concat(t) < align do
		x = (x * 1103515245 + 12345) & 0x7fffffff
		t[#t + 1] = string.char((x >> 16) & 0xff)
	end
	return table.concat(t):sub(1, align)
end

for _, ch in ipairs({ 1, 2 }) do
	local same = true
	local n = 0

	for seed = 1, 200 do
		local b = block(ch, 1024, seed * 7919)
		local a = adpcm.block(b, 1, ch, 1024)
		local p = adpcm.pure(b, 1, ch, 1024)

		n = n + 1
		if a ~= p then
			same = false
			io.write(("# %d channel block %d differs\n"):format(ch, seed))
			break
		end
	end
	ok(same, ("%d channel: %d blocks, c and lua agree"):format(ch, n))
end

-- a block shorter than its own preamble is refused rather than read
do
	local short = string.rep("\0", 4)

	ok(adpcm.block(short, 1, 2, 8) == nil, "a short block is refused")
	ok(adpcm.pure(short, 1, 2, 8) == nil, "and the reference refuses it too")
end

-- the length is the block's, not the string's: a decoder that reads to
-- the end takes the next block's preamble for audio, which is the bug
-- this file was written after.
do
	local two = block(2, 1024, 11) .. block(2, 1024, 22)
	local first = adpcm.block(two, 1, 2, 1024)
	local alone = adpcm.block(two:sub(1, 1024), 1, 2, 1024)

	ok(first == alone, "a block decodes the same beside another as alone")
end

os.exit(failed > 0 and 1 or 0)
