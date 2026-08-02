-- what a udp round trip costs over loopback, and how much of it is the
-- checksum.
--
-- Loopback is the right place to ask. A round trip to a real peer is
-- mostly the peer and the wire, and neither is ours to make faster; with
-- 127.0.0.1 the device, the driver and the segment are all gone, so what
-- is left is the stack itself -- the part written in Lua.
--
-- Four checksums per round trip is the number to keep in view: udp4
-- computes one over the pseudo-header and payload when encoding and
-- verifies another when decoding, in each direction. It is linear in
-- the payload while everything else on the path is not, and the payload
-- sweep below is what separates the two.
--
-- This is what moved ip4.checksum into src/inet.c. In Lua it was a loop
-- reading a string.unpack per two bytes -- 700 of them for a full-sized
-- datagram, four times over -- and the sweep read:
--
--	    1B    38.5us   checksum   6.3us   16.5%
--	 1400B   444.6us   checksum 378.3us   85.1%
--
-- against 48.4us and 1.6% now, a 9.2x round trip at 1400B.
--
-- The floor is measured as well, because a udp round trip is also four
-- requests to the ip task and those are four port round trips whatever
-- the stack does with them. Anything at or near the floor is not the
-- checksum's to lose.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local ip4 = require("ip4")
local udp4 = require("udp4")

tap.plan(5)

local N = 200
local CYCMS = sys.stats().cycles_per_ms

local granted = sys.granted()
local iph = granted.ip

if not tap.ok(iph ~= nil, "the ip task is running") then
	tap.done()
	return
end

local udp = caps.udp(iph)
local A, B = 7101, 7102
local a, b = udp.open(A), udp.open(B)

if not tap.ok(a and b, "two loopback ports open") then
	tap.done()
	return
end

local function us(cyc, n)
	return (cyc / n) * 1000 / CYCMS
end

-- ---- the floor: four port round trips, no ip at all ----
--
-- one udp round trip is four requests to the ip task, so this is what
-- those cost before the stack does anything with them.
local echoin = sys.newport()
local echoout = sys.newport()
local toecho = sys.sendright(echoin)

sys.spawn([[
	local sys = require("los.sys")
	local m = ...

	while true do
		sys.block(m.__in.__right)
		local ok, v = sys.tryrecv(m.__in.__right)

		if ok then
			sys.send(m.__out.__right, v)
		end
	end
]], { arg = { __in = { __right = echoin },
    __out = { __right = sys.sendright(echoout) } } })

local t0 = sys.ticks()

for _ = 1, N do
	for _ = 1, 4 do
		sys.send(toecho, "x")
		sys.block(echoout)
		sys.tryrecv(echoout)
	end
end

local floorcyc = sys.ticks() - t0

tap.ok(true, "four port round trips, the ip task's own cost")
tap.diag(string.format("floor: %.1f us per udp-round-trip-equivalent",
    us(floorcyc, N)))

-- ---- the round trip, swept over payload size ----
--
-- Sizes chosen for what they separate: 1 byte is all overhead and no
-- checksum, 1400 is a full ethernet payload, and the two in between say
-- whether the cost between them is a line or a step.
local SIZES = { 1, 64, 512, 1400 }
local intact = true
local rt = {}

for _, sz in ipairs(SIZES) do
	local payload = string.rep("p", sz)
	local start = sys.ticks()

	for _ = 1, N do
		udp.send(a, 127, 0, 0, 1, B, payload)

		local got = udp.recv(b, 2048)

		if not got or got.data ~= payload then
			intact = false
			break
		end
		udp.send(b, got.a, got.b, got.c, got.d, got.port, got.data)

		local back = udp.recv(a, 2048)

		if not back or back.data ~= payload then
			intact = false
			break
		end
	end

	rt[sz] = sys.ticks() - start
	tap.diag(string.format("%5dB: %7.1f us per round trip", sz,
	    us(rt[sz], N)))
end

tap.ok(intact, "every payload came back byte for byte")

-- ---- and what the checksum alone costs at those sizes ----
--
-- Four per round trip, over the pseudo-header, the udp header and the
-- payload -- so this is timed on exactly the string udp4 hands it, not
-- on the payload alone.
local LOOPBACK = ip4.parse("127.0.0.1")

tap.diag("checksum, 4x per round trip:")

local share = {}

for _, sz in ipairs(SIZES) do
	local body = string.rep("p", sz + udp4.HDRLEN + 12)
	local start = sys.ticks()

	for _ = 1, N do
		for _ = 1, 4 do
			ip4.checksum(body)
		end
	end

	local cyc = sys.ticks() - start

	share[sz] = cyc / rt[sz]
	tap.diag(string.format("%5dB: %7.1f us, %4.1f%% of the round trip",
	    sz, us(cyc, N), share[sz] * 100))
end

-- The share at a full payload is the finding, asserted so it cannot rot
-- into a diagnostic nobody reads.
--
-- Stated as a bound and not as a direction. "Grows with the payload" was
-- the obvious assertion and is worthless: the C checksum is linear too,
-- just about 470 times faster, so that holds whichever implementation is
-- in use and would not have noticed the change it was written to
-- protect. This would -- in Lua the same figure was 85%.
local SHARE_MAX = 0.10

tap.ok(share[1400] < SHARE_MAX, string.format(
    "the checksum is a small part of a full-payload round trip (%.1f%%, limit %.0f%%)",
    share[1400] * 100, SHARE_MAX * 100))

udp.close(a)
udp.close(b)
tap.done()
