#!/usr/bin/env lua5.4
-- lib/tcp4.lua on the host, with nothing booted.
--
-- This is the first test in the tree that requires a guest module
-- directly instead of driving a running system, and the reason is
-- specific to TCP: the cases most likely to be wrong are the ones a
-- real peer will not produce on request. A sequence number that laps
-- the space, a two-byte option that does not advance, a reset for a
-- segment that never had a connection -- none of these can be asked
-- for from OpenBSD, and all of them are one line here.
--
-- It does not replace a boot test. It proves the codec; it cannot prove
-- that anything is wired to anything, which is what test/boot does.
--
-- No dependency beyond lua5.4 itself: lib/tap.lua needs los.sys, so
-- TAP is emitted directly, the same way test/test_9p.lua does it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local tcp4 = require("tcp4")

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

local function is(got, want, name)
	if got ~= want then
		io.write(("# %s: got %s, want %s\n"):format(name,
		    tostring(got), tostring(want)))
	end
	return ok(got == want, name)
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

-- ---- sequence arithmetic ----
--
-- The whole point of these is the wrap, so every case is written at the
-- wrap. Comparing sequence numbers with < is the bug this module exists
-- to make impossible, and it is invisible for the first four billion
-- octets of any connection.

ok(tcp4.lt(1, 2), "1 is before 2")
ok(not tcp4.lt(2, 1), "and 2 is not before 1")
ok(not tcp4.lt(5, 5), "nothing is before itself")

ok(tcp4.lt(0xffffffff, 0), "the last sequence number is before zero")
ok(tcp4.gt(0, 0xffffffff), "and zero is after it")
ok(tcp4.lt(0xfffffffe, 5), "a comparison across the wrap works at all")

is(tcp4.add(0xffffffff, 1), 0, "adding past the end wraps to zero")
is(tcp4.add(0xfffffffe, 5), 3, "and keeps going")
is(tcp4.diff(5, 0xfffffffe), 7, "the distance across the wrap is small")
is(tcp4.diff(0xfffffffe, 5), -7, "and is signed the other way round")

-- Exactly half the space apart, both directions read "before" -- the
-- comparison is symmetric there and so means nothing at all. That is a
-- property of sign-of-difference ordering rather than a defect in it,
-- and it is the reason every function here documents the assumption
-- that its arguments are closer together than that. TCP keeps them so
-- by never advertising a window anywhere near 2^31.
--
-- Asserted rather than merely noted, because the day someone "fixes"
-- this into an asymmetry they will have invented an ordering the peer
-- does not share.
ok(tcp4.lt(0, 0x80000000) and tcp4.lt(0x80000000, 0),
    "half a space apart is symmetric, and so is not an ordering")

ok(tcp4.between(5, 1, 10), "in the window")
ok(not tcp4.between(10, 1, 10), "the right edge is exclusive")
ok(tcp4.between(1, 1, 10), "the left edge is not")
ok(tcp4.between(0, 0xffffffff, 3), "a window straddling the wrap")
ok(not tcp4.between(7, 5, 5), "a zero window contains nothing")

-- a zero window rejecting everything is not an edge case to be tidy
-- about: it is the acceptability test in 3.10.7 for a receiver that has
-- run out of buffer, and a stack that accepts an octet into it has
-- overrun something.
ok(not tcp4.between(5, 5, 5), "not even the sequence number it sits on")

-- ---- seglen ----

is(tcp4.seglen({ flags = 0, data = "hello" }), 5, "data is its own length")
is(tcp4.seglen({ flags = tcp4.SYN }), 1, "a bare SYN occupies one octet")
is(tcp4.seglen({ flags = tcp4.FIN }), 1, "so does a bare FIN")
is(tcp4.seglen({ flags = tcp4.ACK }), 0, "an ACK occupies none")
is(tcp4.seglen({ flags = tcp4.SYN | tcp4.FIN, data = "xy" }), 4,
    "and both flags count alongside data")

-- ---- flags ----

is(tcp4.flagstr(tcp4.SYN | tcp4.ACK), "SYN,ACK", "flags render for logs")
is(tcp4.flagstr(0), "-", "and no flags renders as something")

-- ---- the header, against an independent implementation ----
--
-- This vector was produced by a separate checksum written in python
-- against the same inputs, not by this module -- a round trip through
-- our own encode and decode would agree with itself whatever we had got
-- wrong about the pseudo-header. It is a SYN from 10.0.2.15:40000 to
-- 10.0.2.2:80, seq 0x12345678, window 65535, one MSS option of 1460.
local SRC = "\10\0\2\15"
local DST = "\10\0\2\2"
local SYNVECTOR =
    "9c40005012345678000000006002ffff7ad90000020405b4"

local syn = tcp4.encode({
	sport = 40000, dport = 80,
	seq = 0x12345678, ack = 0,
	flags = tcp4.SYN, wnd = 65535,
	opt = { mss = 1460 },
}, SRC, DST)

is(hex(syn), SYNVECTOR, "a SYN encodes byte for byte")

local d = tcp4.decode(syn, SRC, DST)

ok(d ~= nil, "and decodes")
is(d and d.sport, 40000, "source port")
is(d and d.dport, 80, "destination port")
is(d and d.seq, 0x12345678, "sequence number")
is(d and d.flags, tcp4.SYN, "flags")
is(d and d.wnd, 65535, "window")
is(d and d.opt.mss, 1460, "the mss option")
is(d and d.data, "", "and no payload")

-- ---- the checksum is checked, not merely computed ----
--
-- A stack that computes a correct checksum outbound and ignores it
-- inbound looks entirely healthy until the wire damages something, at
-- which point it acts on the damage. Flipping one bit of the payload
-- must lose the segment.
local withdata = tcp4.encode({
	sport = 1234, dport = 5678, seq = 100, ack = 200,
	flags = tcp4.ACK | tcp4.PSH, wnd = 4096, data = "hello",
}, SRC, DST)

ok(tcp4.decode(withdata, SRC, DST) ~= nil, "a good segment survives")
is(tcp4.decode(withdata, SRC, DST).data, "hello", "with its payload")

local corrupt = withdata:sub(1, #withdata - 1) ..
    string.char(withdata:byte(#withdata) ~ 0x01)

is(tcp4.decode(corrupt, SRC, DST), nil, "one flipped bit loses the segment")

-- and the addresses are part of it: the same bytes delivered on behalf
-- of a different host must not verify, which is the entire reason the
-- pseudo-header exists.
is(tcp4.decode(withdata, SRC, "\10\0\2\3"), nil,
    "the same segment does not verify for another destination")

-- ---- malformed input ----

is(tcp4.decode("", SRC, DST), nil, "an empty string is not a segment")
is(tcp4.decode("short", SRC, DST), nil, "nor is a runt")
is(tcp4.decode(nil, SRC, DST), nil, "nor is nil")

-- a data offset claiming more header than there is bytes. Without the
-- length check this reads options out of nothing.
local lying = tcp4.encode({
	sport = 1, dport = 2, seq = 0, ack = 0, flags = 0, wnd = 0,
}, SRC, DST)

lying = lying:sub(1, 12) .. string.char(0xf0) .. lying:sub(14)
is(tcp4.decode(lying), nil, "a data offset past the end is rejected")

-- ---- options ----

is(tcp4.decode_options("").mss, nil, "no options is not an error")

local o = tcp4.decode_options(
    string.char(1, 1) ..			-- two NOPs
    string.pack(">I1I1I2", 2, 4, 1460) ..	-- MSS
    string.pack(">I1I1I1", 3, 3, 7) ..		-- window scale
    string.char(4, 2) ..			-- SACK permitted
    string.char(0))				-- end of list

is(o.mss, 1460, "mss parses past padding")
is(o.wscale, 7, "window scale is recognised")
ok(o.sackok, "and so is sack-permitted")

-- Recognised but not offered: we parse 7323 and 2018 from the first
-- segment and advertise neither, so that turning them on later changes
-- what we send rather than adding a receive path that has never run.
local offered = tcp4.encode_options({ mss = 1460, wscale = 7, sackok = true })

is(#offered, 4, "we advertise the mss option and nothing else")
is(hex(offered), "020405b4", "and it is the option we think it is")

is(#tcp4.encode_options({}) % 4, 0, "options pad to a word")
is(tcp4.encode_options(nil), "", "and no options is no bytes")

local ts = tcp4.decode_options(string.pack(">I1I1I4I4", 8, 10, 111, 222))

ok(ts.ts and ts.ts.val == 111 and ts.ts.ecr == 222,
    "timestamps parse into both halves")

local sack = tcp4.decode_options(
    string.pack(">I1I1I4I4I4I4", 5, 18, 100, 200, 300, 400))

ok(sack.sack and #sack.sack == 2 and sack.sack[2].left == 300,
    "a two-block sack option parses")

-- The option that ends the world: a length of zero cannot advance the
-- cursor, so a parser that trusts it never terminates. This does not
-- take a hostile peer, only a damaged byte in a segment whose checksum
-- happens to survive -- and the failure is a hung stack, not a dropped
-- segment.
local stuck = tcp4.decode_options(string.char(2, 0, 0, 0))

ok(stuck ~= nil, "a zero-length option terminates the parse")
is(stuck.mss, nil, "and yields nothing")

-- a length running past the end of the options, likewise.
local over = tcp4.decode_options(string.char(2, 40, 5, 180))

is(over.mss, nil, "an option longer than the space it is in is ignored")

-- a good option before a bad one is still honoured: the parse stops, it
-- does not discard what it already understood.
local partial = tcp4.decode_options(
    string.pack(">I1I1I2", 2, 4, 1200) .. string.char(3, 0))

is(partial.mss, 1200, "options before a malformed one survive it")

-- ---- resets ----
--
-- Section 3.5.2. The two cases differ in where the sequence number
-- comes from, and getting it wrong means the peer ignores the reset and
-- keeps retransmitting into a connection that does not exist.

local r = tcp4.reset_for({
	sport = 1234, dport = 80, seq = 500, ack = 900,
	flags = tcp4.ACK, data = "",
})

is(r.sport, 80, "a reset comes from the port that was addressed")
is(r.dport, 1234, "and goes back to the sender")
is(r.seq, 900, "an acked segment's reset takes its acknowledgment number")
is(r.flags, tcp4.RST, "and carries no acknowledgment of its own")

local r2 = tcp4.reset_for({
	sport = 1234, dport = 80, seq = 500, ack = 0,
	flags = tcp4.SYN, data = "",
})

is(r2.seq, 0, "an unacked segment's reset sits at zero")
is(r2.flags, tcp4.RST | tcp4.ACK, "and must acknowledge instead")
is(r2.ack, 501, "covering the sequence space the SYN occupied")

local r3 = tcp4.reset_for({
	sport = 1234, dport = 80, seq = 500, ack = 0,
	flags = tcp4.SYN | tcp4.FIN, data = "abc",
})

is(r3.ack, 505, "data and both flags included")

is(tcp4.reset_for({ sport = 1, dport = 2, seq = 0, ack = 0,
    flags = tcp4.RST, data = "" }), nil,
    "and a reset is never answered with a reset")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
