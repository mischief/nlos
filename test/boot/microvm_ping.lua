-- IPv4 and ICMP against a real peer: ping the gateway.
--
-- Like the arp test, the value is entirely in who answers. slirp
-- implements ICMP echo for its gateway address and has never read this
-- repo, so a reply proves the whole stack underneath agrees with an
-- independent implementation: the ethernet framing, the ARP that found
-- the gateway's mac, the IPv4 header and its checksum, and ICMP's own
-- checksum over its own message. Any one of them wrong and nothing
-- comes back.
--
-- The checksums are the part that would otherwise go untested. They are
-- easy to write in a way that agrees with themselves and with nothing
-- else, and a round trip is the only cheap way to find out.

local sys = require("los.sys")
local tap = require("tap")
local ip4 = require("ip4")
local icmp = require("icmp")
local udp4 = require("udp4")
local inet = require("inet")
local ethwire = require("ethwire")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

local wire = ethwire.new(caps.eth)
local ME = ip4.parse("10.0.2.15")	-- what slirp leases
local GW = ip4.parse("10.0.2.2")	-- slirp itself

-- ---- the codecs, before trusting them on a wire ----
--
-- A round trip through our own encode/decode cannot prove the layout is
-- right -- both halves can share one misunderstanding -- but it does
-- catch a decode reading the wrong offsets, and the ping below is what
-- makes the layout question answerable.
local pkt = ip4.encode({ src = ME, dst = GW, proto = ip4.PROTO_ICMP,
    payload = "abc" })
local back = ip4.decode(pkt)

tap.ok(back and back.src == ME and back.dst == GW and back.payload == "abc",
    "an ipv4 packet survives encode and decode")

-- a header whose checksum is wrong must be refused, since that is the
-- one thing decode is there to enforce beyond shape. Flip a bit in the
-- source address and the sum no longer holds.
local bad = pkt:sub(1, 12) .. string.char(pkt:byte(13) ~ 0x01) .. pkt:sub(14)

tap.ok(ip4.decode(bad) == nil, "and one with a broken checksum is refused")

local em = icmp.decode(icmp.echo_request(7, 9, "xy"))

tap.ok(em and em.type == icmp.ECHO_REQUEST and em.id == 7 and em.seq == 9 and
    em.data == "xy", "an icmp echo request survives encode and decode")

local dg = udp4.decode(udp4.encode(1234, 53, "q", ME, GW), ME, GW)

tap.ok(dg and dg.sport == 1234 and dg.dport == 53 and dg.data == "q",
    "a udp datagram survives encode, decode and its pseudo-header sum")

-- ---- and now the stranger ----
local host = inet.new(wire, { mac = wire.mac(), ip = ME })
local rtt, why = host:ping(GW, 3000)

if not tap.ok(rtt ~= nil, "the gateway answers a ping") then
	tap.diag(tostring(why))
	tap.done()
	return
end

tap.diag(ip4.str(GW) .. " replied in " .. rtt .. " ms")

-- a reply that took no time at all would mean the clock, not the wire.
tap.ok(rtt >= 0 and rtt < 3000, "and the round trip is a plausible time")

tap.done()
