#!/usr/bin/env lua5.4
-- lib/bitchat/packet.lua against the layout BinaryProtocol.swift states.
--
-- No peer to check against here, so what pins this is the header
-- comment in their source: big-endian throughout, 14 bytes of header,
-- and optional fields that flags decide.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" ..
    scriptdir .. "/../lib/?/init.lua;" .. package.path

local packet = require("bitchat.packet")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	io.flush()
end

-- ---- the outer packet ----

local p = {
	type = packet.MESSAGE, ttl = 7, timestamp = 0x0102030405060708,
	sender = "SENDER01", payload = "hello",
}
local raw = packet.encode(p)

ok(#raw == 14 + 8 + 5, "header, sender and payload and nothing else")
ok(raw:byte(1) == 1, "version 1")
ok(raw:byte(2) == packet.MESSAGE, "the type")
ok(raw:byte(3) == 7, "the ttl")
ok(raw:sub(4, 11) == "\1\2\3\4\5\6\7\8",
    "a big-endian timestamp, which is what differs from everything else here")
ok(raw:byte(12) == 0, "no flags without a recipient or a signature")
ok(raw:sub(13, 14) == "\0\5", "and a big-endian payload length")

local back = packet.decode(raw)

ok(back and back.type == packet.MESSAGE, "and it decodes")
ok(back.sender == "SENDER01" and back.payload == "hello", "with its fields")
ok(back.timestamp == 0x0102030405060708, "and the timestamp intact")
ok(back.recipient == nil and back.signature == nil, "neither optional field")

-- directed and signed, which the flags decide.
local d = packet.encode({ type = packet.NOISE_ENCRYPTED, ttl = 3,
    sender = "SENDER01", recipient = "RECIPNT1", payload = "x",
    signature = string.rep("s", 64) })
local dd = packet.decode(d)

ok(d:byte(12) == (packet.HAS_RECIPIENT | packet.HAS_SIGNATURE),
    "both flags set")
ok(dd.recipient == "RECIPNT1", "the recipient decodes")
ok(dd.signature == string.rep("s", 64), "and the 64-byte signature")
ok(dd.payload == "x", "with the payload between them")

-- refusals: a short packet, a version we do not know, and a payload
-- that claims to be deflate and is not.
ok(packet.decode("short") == nil, "a runt packet is refused")
ok(select(2, packet.decode(string.rep("\0", 30))):match("version"),
    "and an unknown version says so")

local comp = packet.encode(p)

comp = comp:sub(1, 11) .. string.char(packet.IS_COMPRESSED) .. comp:sub(13)
ok(select(2, packet.decode(comp)):match("inflate"),
    "a payload that is not deflate says so rather than handing up rubbish")

local trunc = raw:sub(1, #raw - 2)

ok(packet.decode(trunc) == nil, "a truncated payload is refused")

-- ---- the message inside ----

local m = packet.encodemessage({ id = "id1", sender = "nick",
    content = "hello mesh", timestamp = 42 })
local mm = packet.decodemessage(m)

ok(mm and mm.id == "id1", "a message id")
ok(mm.sender == "nick", "its sender's nickname")
ok(mm.content == "hello mesh", "and the content")
ok(mm.timestamp == 42, "with a timestamp")
ok(mm.private == false, "public by default")

local withid = packet.encodemessage({ id = "i", sender = "n",
    content = "c", peerid = "PEERID01" })

ok(packet.decodemessage(withid).peerid == "PEERID01",
    "an optional peer id round trips")

ok(packet.decodemessage("\0\0") == nil, "a runt message is refused")
ok(packet.decodemessage(m:sub(1, #m - 3)) == nil,
    "and one whose content is cut short")

-- content is a 2-byte length, so it may be longer than a byte holds.
local big = string.rep("x", 300)
local bigm = packet.decodemessage(packet.encodemessage({ id = "i",
    sender = "n", content = big }))

ok(bigm and bigm.content == big, "content longer than 255 bytes")

-- ---- padding, and what a signature covers ----

local pkt = { type = packet.ANNOUNCE, ttl = 3, timestamp = 1234567890123,
    sender = "SENDER01",
    payload = packet.encodeannounce({ nickname = "n",
	noisekey = string.rep("N", 32), signkey = string.rep("S", 32) }) }

local plain = packet.encode(pkt)
local padded = packet.encode(pkt, true)

ok(#plain < 240, "an announce is small")
ok(#padded == 256, "and pads to a whole block")
ok(padded:sub(1, #plain) == plain, "the packet is unchanged by the pad")

local n = padded:byte(#padded)

ok(padded:sub(#padded - n + 1) == string.char(n):rep(n),
    "every pad byte is the pad count")
ok(packet.decode(padded).payload == pkt.payload,
    "and the length field means a reader ignores it")

-- a frame within 16 bytes of its block cannot be padded: the count
-- would not fit in a byte, so it goes out at its own length.
local tight = ("x"):rep(250)

ok(packet.pad(tight) == tight, "a frame too close to the block is left")

local si = packet.signinput(pkt)

ok(#si == 256, "the signing input is padded too")
ok(si:byte(3) == 0, "with the ttl zeroed, so a relay cannot break it")
ok(si ~= padded, "which is not the packet as sent")
ok(packet.signinput({ type = pkt.type, ttl = 99,
    timestamp = pkt.timestamp, sender = pkt.sender,
    payload = pkt.payload }) == si, "any ttl signs the same bytes")

local an = packet.decodeannounce(pkt.payload)

ok(an.nickname == "n", "an announce carries a nickname")
ok(an.noisekey == string.rep("N", 32), "a noise key")
ok(an.signkey == string.rep("S", 32), "and a signing key")

-- ---- a compressed payload ----
--
-- Their encoder deflates a payload of 100 bytes or more that has any
-- redundancy in it, and puts the original length in front.

local deflate = require("zlib.deflate")
local body = string.rep("the mesh relays this. ", 12)
local squashed = string.pack(">I2", #body) .. deflate.compress(body)

local cpkt = string.pack(">BBBI8BI2", 1, packet.MESSAGE, 5, 99,
    packet.IS_COMPRESSED, #squashed) .. "SENDER01" .. squashed
local cp = packet.decode(cpkt)

ok(cp ~= nil, "a compressed packet decodes")
ok(cp and cp.payload == body, "and the payload is what went in")
ok(#squashed < #body, "which was smaller on the wire")

local truncated = string.pack(">BBBI8BI2", 1, packet.MESSAGE, 5, 99,
    packet.IS_COMPRESSED, 2) .. "SENDER01" .. "\0\10"

ok(packet.decode(truncated) == nil, "a compressed payload with no body")

local lying = string.pack(">BBBI8BI2", 1, packet.MESSAGE, 5, 99,
    packet.IS_COMPRESSED, #squashed) .. "SENDER01" ..
    string.pack(">I2", #body + 1) .. deflate.compress(body)

ok(packet.decode(lying) == nil, "and one whose stated size disagrees")

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
