#!/usr/bin/env lua5.4
-- lib/sx1262, against a wire that only remembers what it was told.
--
-- The chip is not here, so what is checked is the bytes: a radio whose
-- registers disagree with everyone else's hears its own kind and
-- nothing more, and that reads as a quiet antenna rather than a fault.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local sx = require("sx1262")

local n, fails = 0, 0

local function ok(cond, name)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, name))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, name))
	end
end

-- a wire that answers everything and keeps what it saw
local function fake()
	local sent = {}

	return {
		xfer = function(out)
			sent[#sent + 1] = out
			return string.rep("\0", #out)
		end,
	}, sent
end

local function lastop(sent, op)
	for i = #sent, 1, -1 do
		if sent[i]:byte(1) == op then
			return sent[i]
		end
	end
end

local SETMODPARAMS = 0x8b

-- ---- low data rate optimize ----
--
-- On when a symbol runs past 16ms, which at these bandwidths is only
-- the two slowest presets. Scaling the symbol time by a thousand turns
-- it on everywhere, and two radios with the same fault still talk to
-- each other: that is what makes it worth pinning.
local cases = {
	{ sf = 7, bw = 250, ldro = 0, why = "ShortFast" },
	{ sf = 9, bw = 250, ldro = 0, why = "MediumFast" },
	{ sf = 11, bw = 250, ldro = 0, why = "LongFast" },
	{ sf = 11, bw = 125, ldro = 1, why = "LongMod" },
	{ sf = 12, bw = 125, ldro = 1, why = "LongSlow" },
}

for _, c in ipairs(cases) do
	local wire, sent = fake()
	local r = sx.new(wire)

	r:modem(c.sf, c.bw, 5)

	local m = lastop(sent, SETMODPARAMS)
	local got = m and m:byte(5)

	ok(got == c.ldro, ("%s (sf%d bw%d) sets ldro %d: %s"):format(c.why,
	    c.sf, c.bw, c.ldro, tostring(got)))
end

do
	local wire, sent = fake()
	local r = sx.new(wire)

	r:modem(9, 250, 5)

	local m = lastop(sent, SETMODPARAMS)

	ok(m and m:byte(2) == 9, "the spreading factor is passed through")
	ok(m and m:byte(4) == 1, "and the coding rate is the denominator less four")
end

-- ---- the sync word ----
--
-- One byte everywhere it is quoted, two in the register: the nibbles
-- are split and 0x4 fills the rest. Meshtastic's 0x2b is 0x24 0xb4.
do
	local wire, sent = fake()
	local r = sx.new(wire)

	r:syncword(0x2b)

	local w = sent[#sent]

	ok(w and w:sub(-2) == "\x24\xb4",
	    "sync 0x2b reaches the register as 0x24 0xb4")
end

do
	local wire, sent = fake()
	local r = sx.new(wire)

	r:syncword(0x12)

	ok(sent[#sent]:sub(-2) == "\x14\x24",
	    "and the private 0x12 as 0x14 0x24")
end

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
