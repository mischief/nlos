-- the C checksum and the Lua one must be the same function.
--
-- Two implementations of one arithmetic is a standing invitation to
-- drift, and the drift would be invisible: a wrong checksum does not
-- crash, it makes packets vanish somewhere else, on a machine that is
-- probably not the one running the tests. src/inet.c is what a lua-os
-- proc uses; lib/ip4.lua's is what tools/arp-lan.lua uses from the
-- host. So they are checked against each other here rather than each
-- against a table of expected values, which would let both be wrong
-- together.
--
-- The awkward cases are the ones that separate implementations: an odd
-- length (the last byte is the HIGH half of a word, not the low), the
-- carry fold, and a sum that lands on zero.
--
-- A microvm test rather than an efi one because lib/ip4.lua is only
-- shipped there: the efi platform reaches the network through firmware
-- sockets and has no use for an IPv4 stack of its own, so there is no
-- Lua half to compare against on that side. src/inet.c is built into
-- both and is the same C either way.

local ip4 = require("ip4")
local tap = require("tap")

tap.plan(9)

local cinet = require("los.inet")

tap.ok(type(cinet.checksum) == "function", "los.inet.checksum exists")
tap.ok(ip4.checksum == cinet.checksum,
    "and ip4.checksum is the C one inside a proc")

local lua = ip4.luachecksum
local c = cinet.checksum

local function agree(s, what)
	local a, b = lua(s), c(s)

	return tap.ok(a == b, string.format("%s: %04x", what, a))
end

agree("", "the empty string")
agree("\0", "a single zero byte")
agree("\255", "a single 0xff -- the odd byte is the high half")
agree("\1\2\3", "an odd length")

-- every length from 0 to 64, since the odd/even split and the tail
-- handling are exactly where an off-by-one lives
local mismatch

for n = 0, 64 do
	local s = string.rep("\171", n)		-- 0xab

	if lua(s) ~= c(s) then
		mismatch = n
		break
	end
end
tap.ok(mismatch == nil,
    "every length 0..64 agrees" ..
    (mismatch and (" (differs at " .. mismatch .. ")") or ""))

-- carries: a run of 0xff is what forces the fold to run more than once
local ff = string.rep("\255", 512)

tap.ok(lua(ff) == c(ff), string.format("512 bytes of 0xff fold alike: %04x",
    c(ff)))

-- a real packet's worth, with the byte values varying so a byte-order
-- mistake cannot cancel itself out
local varied = {}

for i = 1, 1400 do
	varied[i] = string.char((i * 7) % 256)
end
varied = table.concat(varied)
tap.ok(lua(varied) == c(varied),
    string.format("1400 varied bytes agree: %04x", c(varied)))

tap.done()
