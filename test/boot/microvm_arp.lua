-- lib/arp.lua against a real peer.
--
-- test/boot/microvm_eth.lua hand-rolls its ARP on purpose: it tests the
-- device, and a codec bug in lib/arp.lua must not be able to hide
-- behind the same codec on both sides. This is the other half -- the
-- library, checked against something that is not it. Under qemu's user
-- networking that is slirp, which answers for 10.0.2.2 and has never
-- read this repo.
--
-- What is actually being asserted is that the bytes we build are the
-- bytes an independent implementation expects: if the header were
-- packed wrong, or the address fields in the wrong order, slirp would
-- not answer at all.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local ether = require("ether")
local ip4 = require("ip4")
local arp = require("arp")
local ethwire = require("ethwire")

tap.plan(9)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

local wire = ethwire.new(caps.eth)
local mac = wire.mac()

tap.ok(type(mac) == "string" and #mac == 6, "the device has a mac")
tap.diag("mac " .. ether.mac_str(mac))

-- ---- the address helpers, before anything depends on them ----
local ME = ip4.parse("10.0.2.15")	-- what slirp leases
local GW = ip4.parse("10.0.2.2")	-- slirp itself

tap.ok(ME and GW and ip4.str(GW) == "10.0.2.2",
    "ip4 parses and formats a dotted quad")

tap.ok(ip4.parse("10.0.2.256") == nil and ip4.parse("10.0.2") == nil,
    "and rejects addresses that are not one")

-- ---- the codec, round-tripped ----
--
-- Not proof of correctness -- encode and decode can agree on the same
-- wrong layout -- but it does catch a decode that reads the wrong
-- offsets, and it costs nothing. slirp is what makes the next
-- assertion mean something.
local rt = arp.decode(arp.encode(arp.REQUEST, mac, ME, ether.ZERO, GW))

tap.ok(rt and rt.op == arp.REQUEST and rt.sha == mac and rt.spa == ME and
    rt.tpa == GW, "an arp request survives encode and decode")

-- ---- and now the part with a stranger on the other end ----
--
-- Parked, not polled: ethwire's recv_wait blocks inside the eth task
-- until the device's interrupt says a frame arrived, so this proc is
-- off the run queue in between and the machine can halt.
local gwmac, why = arp.resolve(wire, mac, ME, GW, 3000)

if not tap.ok(gwmac ~= nil, "arp.resolve got an answer for the gateway") then
	tap.diag(tostring(why))
	tap.done()
	return
end

tap.diag(ip4.str(GW) .. " is at " .. ether.mac_str(gwmac))

-- a real address, not a broadcast or an all-zero placeholder, and
-- unicast like any host's.
tap.ok(#gwmac == 6 and gwmac ~= ether.BROADCAST and gwmac ~= ether.ZERO and
    (gwmac:byte(1) & 1) == 0, "and it is a real unicast address")

-- ---- and it got there by being woken, not by asking ----
--
-- The resolve above used recv_wait throughout, so a frame reached this
-- proc only because the device raised its line, kernel.c's pump_eth
-- pushed the wakeup, and the eth task's alt answered a parked request.
-- A nonzero interrupt count is the evidence that path ran at all; until
-- the gsi was fixed it was zero on every boot.
local irqs = wire.irqs()

tap.diag("virtio interrupts taken: " .. tostring(irqs))
tap.ok(irqs and irqs > 0, "the frame arrived on an interrupt")

-- a parked receive answers when a frame turns up rather than
-- immediately, and returns nil rather than hanging when none does.
-- Nothing is talking to us now, so this is the quiet case.
local t0 = sys.uptime_ms()
local none = wire.recv_wait(300)
local waited = sys.uptime_ms() - t0

tap.diag("an unanswered wait returned after " .. waited .. " ms")
tap.ok(none == nil and waited >= 250,
    "a parked receive waits for its deadline rather than spinning")

tap.done()
