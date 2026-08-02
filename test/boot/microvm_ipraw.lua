-- the ip task's raw seam: a protocol served by another proc.
--
-- This is what lets TCP live outside task/ip.lua -- a right registered
-- for one IP protocol number, packets forwarded to it, and an output op
-- to send one back. The registration rules are asserted here because
-- they are refusals, and a refusal that silently succeeds is the kind
-- of bug that surfaces as "udp stopped working" three weeks later.
--
-- The exchange at the end is deliberately a real one rather than a
-- loopback: a SYN to a port nothing listens on, and the RST that comes
-- back. Under qemu's user networking that RST is slirp's, so the whole
-- path is exercised -- arp, our IP header, a protocol number that this
-- proc does not itself serve, and the demux on the way back in. A
-- loopback test would pass with the wire unplugged.
--
-- lib/tcp4.lua builds the segment, which also makes this the first
-- thing to check the codec against something that is not us.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local ip4 = require("ip4")
local tcp4 = require("tcp4")

tap.plan(19)

local iph = sys.granted().ip

if not tap.ok(iph ~= nil, "the ip task is running") then
	tap.done()
	return
end

-- wait for the machine's own dhcp client, the same way microvm_udpq
-- does: a client wanting the network waits for the address rather than
-- going and getting its own.
local cfg
local deadline = sys.uptime_ms() + 8000

repeat
	cfg = thread.rpc(iph, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

if not tap.ok(cfg and cfg.ip and cfg.ip ~= ip4.ANY,
    "the machine configured itself") then
	tap.done()
	return
end

tap.diag("we are " .. ip4.str(cfg.ip))

-- ---- claiming a protocol ----

local rawport = sys.newport()

tap.ok(thread.rpc(iph, { op = "raw", proto = ip4.PROTO_TCP,
    port = thread.giveright(rawport) }) == true,
    "a proc can claim tcp")

-- udp and icmp are answered inside the ip task. Handing them out would
-- not move them anywhere -- it would quietly stop every udp conn the
-- task is already serving, including the dhcp client that gave us the
-- address above.
local stolen = sys.newport()

tap.ok(thread.rpc(iph, { op = "raw", proto = ip4.PROTO_UDP,
    port = thread.giveright(stolen) }) == false,
    "but udp is not on offer")
tap.ok(thread.rpc(iph, { op = "raw", proto = ip4.PROTO_ICMP,
    port = thread.giveright(stolen) }) == false,
    "and neither is icmp")

-- a protocol number is one byte. 999 is not a mistake the stack should
-- die of, and whole() is what stops it reaching string.pack.
tap.ok(thread.rpc(iph, { op = "raw", proto = 999,
    port = thread.giveright(stolen) }) == false,
    "a protocol number out of range is refused")

sys.close(stolen)

-- ---- output validates before it uses ----

-- Length is the only check there is, and that is not a weakness: every
-- four-byte string is a valid IPv4 address, so there is nothing else to
-- reject. The first draft of this test asserted that "junk" was
-- refused, which was the test being wrong rather than the stack -- it
-- is four bytes, and so it is 106.117.110.107.
tap.ok(thread.rpc(iph, { op = "output", proto = ip4.PROTO_TCP,
    dst = "abc", data = "x" }) == false,
    "an address that is not four bytes is refused")
tap.ok(thread.rpc(iph, { op = "output", proto = ip4.PROTO_TCP,
    dst = 42, data = "x" }) == false,
    "and neither is a number an address")
tap.ok(thread.rpc(iph, { op = "output", proto = ip4.PROTO_TCP,
    dst = ip4.parse("10.0.2.2") }) == false,
    "nor is a packet with no payload a packet")

-- ---- a real segment, and a real answer ----
--
-- Port 9 is discard; nothing behind slirp listens on it, which is the
-- point: the reply we want is the refusal.
local dst = ip4.parse("10.0.2.2")
local SPORT, DPORT = 40001, 9
local ISS = 0x1000

local syn = tcp4.encode({
	sport = SPORT, dport = DPORT,
	seq = ISS, ack = 0,
	flags = tcp4.SYN, wnd = 4096,
	opt = { mss = 1460 },
}, cfg.ip, dst)

tap.ok(thread.rpc(iph, { op = "output", proto = ip4.PROTO_TCP,
    dst = dst, data = syn }) == true,
    "a tcp segment goes out through the ip task")

-- The first packet to an unresolved address is held while arp runs, so
-- what is being waited for here is two round trips, not one.
local got, why = thread.recvtimeout(rawport, 5000)

if not tap.ok(got ~= nil, "a packet came back on the raw port") then
	tap.diag("nothing arrived: " .. tostring(why))
	local s = thread.rpc(iph, { op = "stats" })

	if s then
		tap.diag(string.format(
		    "frames_in=%d raw_in=%d raw_unbound=%d raw_dropped=%d " ..
		    "out_fail=%d unresolved=%d raw=%d",
		    s.frames_in, s.raw_in, s.raw_unbound, s.raw_dropped,
		    s.frames_out_fail, s.unresolved, s.raw))
	end
	tap.done()
	return
end

tap.is(got.proto, ip4.PROTO_TCP, "it is the protocol we claimed")
tap.is(got.src, dst, "from the address we sent to")

local seg = tcp4.decode(got.data, got.src, got.dst)

if not tap.ok(seg ~= nil, "and it decodes, checksum and all") then
	tap.diag("undecodable, " .. #got.data .. " bytes")
	tap.done()
	return
end

tap.diag("got " .. tcp4.flagstr(seg.flags) .. " seq " .. seg.seq ..
    " ack " .. seg.ack)

tap.ok((seg.flags & tcp4.RST) ~= 0, "a connection refused is a reset")
tap.is(seg.dport, SPORT, "addressed to the port we sent from")

-- the reset must acknowledge the sequence space our SYN occupied, which
-- is ISS+1 -- the +1 being the SYN itself. A peer that got this wrong
-- would be ignored by us, and this is the same arithmetic our own
-- reset_for does.
tap.is(seg.ack, tcp4.add(ISS, 1), "acknowledging the octet our SYN took")

local s = thread.rpc(iph, { op = "stats" })

tap.diag(string.format("raw_in=%d raw_unbound=%d raw_dropped=%d raw=%d",
    s.raw_in, s.raw_unbound, s.raw_dropped, s.raw))
tap.ok(s.raw_in >= 1, "and the ip task counted the delivery")

-- ---- re-registration ----
--
-- A restarted tcp task has to be able to take its protocol back. The
-- previous owner's right is closed rather than left behind, which is
-- the whole reason this is a replace and not a refusal.
local second = sys.newport()

tap.ok(thread.rpc(iph, { op = "raw", proto = ip4.PROTO_TCP,
    port = thread.giveright(second) }) == true,
    "and a later claim replaces the earlier one")

tap.done()
