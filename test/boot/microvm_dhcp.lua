-- DHCP against a real server, with no address to start from.
--
-- The first thing here that needs the stack to work in both directions
-- before it can work at all: a broadcast out from 0.0.0.0, an offer
-- back, a request naming the offer, an ack. Four packets, each of which
-- has to be understood by a server that is not ours -- slirp's, under
-- qemu's user networking, which leases 10.0.2.15 and answers as
-- 10.0.2.2.
--
-- It also exercises UDP for the first time on a wire. The ping test
-- round-trips a datagram through our own codec, which proves the
-- offsets and nothing about the pseudo-header checksum; a server
-- ignoring a datagram whose checksum does not hold is what proves that.
--
-- lib/dhcp.lua's codec is the same one the efi platform uses over
-- firmware udp4. Only the transport under it is new.

local sys = require("los.sys")
local tap = require("tap")
local ip4 = require("ip4")
local ether = require("ether")
local inet = require("inet")
local dhcpc = require("dhcpc")
local ethwire = require("ethwire")

tap.plan(6)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

local wire = ethwire.new(caps.eth)

-- no address, no mask, no gateway: everything below has to come from
-- the server. Starting configured would prove nothing.
local host = inet.new(wire, { mac = wire.mac(), ip = ip4.ANY })

tap.diag("mac " .. ether.mac_str(host.mac) .. ", starting with no address")

local lease, err = dhcpc.acquire(host, { hostname = "luaos" })

if not tap.ok(lease ~= nil, "a lease came back") then
	tap.diag(tostring(err))
	tap.done()
	return
end

tap.diag("leased " .. ip4.str(lease.ip) ..
    " mask " .. (lease.mask and ip4.str(lease.mask) or "-") ..
    " gw " .. (lease.gw and ip4.str(lease.gw) or "-") ..
    (lease.dns and (" dns " .. ip4.str(lease.dns)) or "") ..
    (lease.lease_time and (" for " .. lease.lease_time .. "s") or ""))

-- slirp's lease is fixed, which makes this checkable rather than merely
-- plausible: the address it hands out is the one it documents.
tap.ok(ip4.str(lease.ip) == "10.0.2.15",
    "and it is the address slirp leases")

tap.ok(lease.gw and ip4.str(lease.gw) == "10.0.2.2",
    "with slirp itself as the router")

-- the host object is configured now, which is the point of acquiring:
-- everything above this line was sending from 0.0.0.0.
tap.ok(host.ip == lease.ip and host.gw == lease.gw,
    "and the host took the lease as its own configuration")

-- and now prove the configuration is usable rather than just stored, by
-- doing something that needs the source address to be right. A ping
-- from 0.0.0.0 would not come back.
local rtt = host:ping(lease.gw, 3000)

tap.ok(rtt ~= nil, "the leased address can reach the router it was given")

tap.done()
