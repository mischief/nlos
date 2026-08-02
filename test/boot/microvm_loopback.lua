-- 127.0.0.1: a datagram to ourselves, which must not reach the wire.
--
-- The point is not that it arrives -- an echo off the gateway proves
-- that much -- but that it arrives without a link under it. Loopback is
-- the one destination with no next hop, no mac to resolve and no
-- interrupt behind its delivery, so every part of the send path that
-- assumes a wire has to be bypassed rather than merely tolerated. It
-- also has to work before DHCP answers, since 127.0.0.1 is reachable on
-- a machine that has no address at all.
--
-- Checked without waiting for an address for exactly that reason: this
-- test never asks the dhcp client for anything.

local sys = require("los.sys")
local tap = require("tap")
local caps = require("caps")
local ip4 = require("ip4")

tap.plan(9)

local granted = sys.granted()
local iph = granted.ip

if not tap.ok(iph ~= nil, "the ip task is running") then
	tap.done()
	return
end

-- ---- the address predicates, before trusting them on a stack ----
tap.ok(ip4.is_loopback(ip4.parse("127.0.0.1")) and
    ip4.is_loopback(ip4.parse("127.255.255.254")),
    "the whole of 127/8 is loopback, not just 127.0.0.1")
tap.ok(not ip4.is_loopback(ip4.parse("10.0.2.15")) and
    not ip4.is_loopback(ip4.ANY),
    "and an ordinary address is not")

local udp = caps.udp(iph)

-- ---- a datagram to ourselves ----
local a = udp.open(7001)
local b = udp.open(7002)

if not tap.ok(a and b, "two udp ports open") then
	tap.done()
	return
end

local sent = udp.send(a, 127, 0, 0, 1, 7002, "hello self")

tap.ok(sent, "a datagram to 127.0.0.1 is accepted")

local got = udp.recv(b, 1024)

tap.ok(got and got.data == "hello self",
    "and arrives intact: " .. tostring(got and got.data))

-- the source must be the loopback address, not our address on the
-- wire and not 0.0.0.0. A reply goes back to where the sender says it
-- came from, so this is what makes a round trip possible at all.
tap.ok(got and got.a == 127 and got.b == 0 and got.c == 0 and got.d == 1,
    string.format("from 127.0.0.1, not the wire address (%s)",
    got and string.format("%d.%d.%d.%d", got.a, got.b, got.c, got.d) or "nil"))
tap.ok(got and got.port == 7001, "and carries the sending port")

-- ---- and back, which is the shape every protocol above this uses ----
local back = udp.send(b, got.a, got.b, got.c, got.d, got.port, "hello back")
local echo = back and udp.recv(a, 1024)

tap.ok(echo and echo.data == "hello back" and echo.port == 7002,
    "a reply returns to the sender's port")

udp.close(a)
udp.close(b)
tap.done()
