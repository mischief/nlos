#!/usr/bin/env lua5.4
-- lib/protobuf and lib/meshtastic, against their firmware's own numbers.
--
-- The constants are checked rather than trusted: every one of them is
-- copied from a source tree that moves, and a preset or a slot that
-- drifts is a radio listening politely to the wrong frequency.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local pb = require("protobuf")
local mt = require("meshtastic")

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

local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- ---- the wire format ----

-- field 1 varint 150: the example from protobuf's own documentation
ok(hex(pb.encode({ { 1, "varint", 150 } })) == "089601",
    "a varint field encodes as the documented 08 96 01")
ok(pb.decode("\x08\x96\x01")[1] == 150, "and decodes back")

ok(hex(pb.encode({ { 2, "bytes", "testing" } })) == "120774657374696e67",
    "a length-delimited field is the documented 12 07 ...")

do
	local s = pb.encode({ { 1, "varint", 1 }, { 2, "bytes", "hi" },
	    { 4, "i32", 0xdeadbeef } })
	local f = pb.decode(s)

	ok(f[1] == 1 and f[2] == "hi" and f[4] == 0xdeadbeef,
	    "three kinds round trip")
end

-- a field this reader does not know is skipped, not fatal: their
-- schema grows and ours does not have to
do
	local s = pb.encode({ { 1, "varint", 3 }, { 9, "varint", 7 },
	    { 2, "bytes", "x" } })
	local f = pb.decode(s)

	ok(f[1] == 3 and f[2] == "x" and f[9] == 7,
	    "an unknown field is carried, not choked on")
end

ok(select(1, pb.decode("\x08")) ~= nil, "a truncated varint does not raise")

-- ---- their constants ----

ok(mt.SYNCWORD == 0x2b, "the sync word is 0x2b, not the chip's default")

do
	local p = mt.PRESETS.LONG_FAST

	ok(p.sf == 11 and p.bw == 250 and p.cr == 5,
	    "LongFast is sf11 bw250 cr4/5")
end

do
	local freq, ch, num = mt.slot("LongFast", mt.REGIONS.US, 250)

	ok(num == 104, "the US band holds 104 channels at 250kHz: " .. num)
	ok(ch == 19, "LongFast hashes to slot 20 (channel_num 19): " .. ch)
	ok(math.abs(freq - 906.875) < 0.0005,
	    ("and lands on 906.875MHz: %.4f"):format(freq))
end

-- an unnamed channel is hashed under the preset's display name, not
-- under the empty string. Getting this wrong is invisible between two
-- machines that agree and wrong against everybody else.
ok(mt.channelhash("LongFast", mt.DEFAULTKEY) == 0x08,
    ("the default channel hashes to 0x08: 0x%02x"):format(
    mt.channelhash("LongFast", mt.DEFAULTKEY)))

do
	local p = mt.PRESETS.MEDIUM_FAST

	ok(p.sf == 9 and p.bw == 250 and p.cr == 5,
	    "MediumFast is sf9 bw250 cr4/5")
	ok(p.name == "MediumFast", "and is named MediumFast: " .. p.name)
end

do
	local c = mt.channel({ preset = mt.PRESETS.LONG_FAST })

	ok(c.slot == 19 and math.abs(c.freq - 906.875) < 0.0005,
	    ("LongFast tunes 906.875MHz: %.4f"):format(c.freq))
	ok(c.hash == 0x08, ("and rides channel 0x08: 0x%02x"):format(c.hash))
end

do
	local c = mt.channel({ preset = mt.PRESETS.MEDIUM_FAST })

	ok(c.slot == 44 and math.abs(c.freq - 913.125) < 0.0005,
	    ("MediumFast tunes 913.125MHz: %.4f"):format(c.freq))
	ok(c.hash == 0x1f, ("and rides channel 0x1f: 0x%02x"):format(c.hash))
end

-- a channel url carries the common keys as one byte, which is what
-- psk="AQ==" in their config dump means
ok(mt.psk(1) == mt.DEFAULTKEY, "psk index 1 is the default key untouched")
ok(mt.psk(2) ~= mt.DEFAULTKEY and mt.psk(2):sub(1, 15) ==
    mt.DEFAULTKEY:sub(1, 15), "index 2 moves only the last byte")
ok(mt.psk(0) == nil, "index 0 is no encryption")

do
	-- a slot given by hand counts from one, as their config does
	local c = mt.channel({ preset = mt.PRESETS.LONG_FAST, slot = 1 })

	ok(c.slot == 0 and math.abs(c.freq - 902.125) < 0.0005,
	    ("slot 1 is the bottom of the band: %.4f"):format(c.freq))
end

-- ---- the bitfield a gateway reads ----
--
-- Their firmware will not put another node's packet on a public broker
-- unless field 9 is present and bit 0 is set. Absent means no, so a
-- message without it is seen on the gateway and nowhere further.
do
	local d = mt.data(mt.encodedata({ portnum = 1, payload = "hi" }))

	ok(d.bitfield ~= nil, "the bitfield is always written, even as zero")
	ok(d.ok_to_mqtt == false, "and says no when it was not asked for")
end

do
	local d = mt.data(mt.encodedata({ portnum = 1, payload = "hi",
	    ok_to_mqtt = true }))

	ok(d.bitfield & mt.OK_TO_MQTT ~= 0, "asking sets bit 0")
	ok(d.ok_to_mqtt == true, "which is what a gateway checks")
end

do
	local d = mt.data(mt.encodedata({ portnum = 1, payload = "hi",
	    want_response = true, ok_to_mqtt = true }))

	ok(d.bitfield == (mt.OK_TO_MQTT | mt.WANTS_RESPONSE),
	    ("both bits share the field: %d"):format(d.bitfield))
end

-- ---- the frame ----

do
	local h = { to = mt.BROADCAST, from = 0x12345678, id = 0xaabbccdd,
	    hoplimit = 3, hopstart = 3, channel = 0x02, want_ack = true }
	local frame = mt.frame(h, "payload")
	local got, rest = mt.parse(frame)

	ok(#frame == mt.HEADER + 7, "a frame is 16 bytes and its payload")
	ok(got.to == h.to and got.from == h.from and got.id == h.id,
	    "the addresses round trip")
	ok(got.hoplimit == 3 and got.hopstart == 3 and got.want_ack,
	    "and so do the flags, which share one byte")
	ok(rest == "payload", "the payload is what follows")
end

ok(select(1, mt.parse("short")) == nil, "a runt frame is refused")
ok(select(1, mt.parse(nil)) == nil, "and so is nothing at all")

-- the header is little-endian, which is what their struct is on every
-- board they build for
ok(hex(mt.frame({ to = 0x04030201, from = 0, id = 0 }, "")):sub(1, 8) ==
    "01020304", "the header is little-endian")

-- ---- the cipher ----
--
-- Skipped where the aes module is absent rather than failed: the pure
-- lua half of this library is worth testing on its own.

local haveaes = mt.decrypt(mt.DEFAULTKEY, 1, 1, "x") ~= nil

if haveaes then
	local id, from = 0xaabbccdd, 0x12345678

	ok(hex(mt.nonce(id, from)) == "ddccbbaa0000000078563412" .. "00000000",
	    "the nonce is the id then the sender, little-endian")

	local plain = "hello mesh"
	local cipher = mt.encrypt(mt.DEFAULTKEY, id, from, plain)

	ok(cipher ~= plain, "the payload is not sent in the clear")
	ok(mt.decrypt(mt.DEFAULTKEY, id, from, cipher) == plain,
	    "and comes back with the same key")
	ok(mt.decrypt(mt.DEFAULTKEY, id + 1, from, cipher) ~= plain,
	    "but not with another packet's nonce")

	-- what a receiver actually does
	local h = { to = mt.BROADCAST, from = from, id = id, hoplimit = 3,
	    channel = mt.channel({}).hash }
	local frame = mt.seal(h, { portnum = mt.PORT_TEXT,
	    payload = "hi from lua-os" })
	local gh, d = mt.open(frame)

	ok(gh and gh.from == from, "a sealed frame opens")
	ok(d and d.portnum == mt.PORT_TEXT, "the port says it is text")
	ok(d and d.payload == "hi from lua-os", "and the text survives")

	-- the wrong key is caught by the payload not parsing, which is
	-- the only check a stream cipher leaves
	local _, bad, why = mt.open(frame, string.rep("\0", 16))

	ok(bad == nil and why ~= nil, "a wrong key gives no message: " ..
	    tostring(why))
else
	print("# no crypto.native here; the cipher tests need it")
end

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
