-- DNS against a real resolver, at the end of a real lease.
--
-- Every layer at once, and each one supplying the next: DHCP gives the
-- address and names the resolver, IPv4 and UDP carry the question, and
-- something on the far side that has never heard of this codebase
-- answers it. slirp forwards to whatever the host's resolver is, so a
-- correct answer means the query left this machine intact.
--
-- The codec is lib/dns.lua, the same one task/dns.lua uses over the
-- firmware's udp4 on the efi platform. Only the transport differs.

local sys = require("los.sys")
local tap = require("tap")
local ip4 = require("ip4")
local dns = require("dns")
local inet = require("inet")
local dhcpc = require("dhcpc")
local dnsc = require("dnsc")
local ethwire = require("ethwire")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

-- ---- the codec, round-tripped against itself first ----
--
-- Cheap, and it catches an offset error before the network can blame
-- one on the wire. It proves nothing about the layout being right,
-- which is what the query below is for.
local q = dns.build_query("example.com", 0x1234)

-- 12 header, then the name as length-prefixed labels with a root byte
-- ("\7example\3com\0" is 13), then QTYPE and QCLASS.
tap.ok(#q == 12 + 13 + 4,
    "a query is a header, a name and a question")

-- a reply whose id is not ours must be refused: without that check a
-- late answer to an earlier question answers this one.
tap.ok(dns.parse(q, 0x9999) == nil, "and a reply with the wrong id is refused")

-- ---- an address, then a resolver, then a name ----
local wire = ethwire.new(caps.eth)
local host = inet.new(wire, { mac = wire.mac(), ip = ip4.ANY })
local lease, err = dhcpc.acquire(host, { hostname = "luaos" })

if not tap.ok(lease ~= nil, "dhcp gave us an address to ask from") then
	tap.diag(tostring(err))
	tap.done()
	return
end

if not tap.ok(lease.dns ~= nil, "and named a resolver") then
	tap.diag("no dns option in the lease")
	tap.done()
	return
end

tap.diag("resolver is " .. ip4.str(lease.dns))

-- example.com is the one name reserved for exactly this (RFC 2606), so
-- using it here is not borrowing somebody's production domain to run a
-- test against.
local addr, why = dnsc.resolve(host, "example.com", lease.dns)

if not tap.ok(addr ~= nil, "and it resolved example.com") then
	tap.diag(tostring(why))
	tap.done()
	return
end

tap.diag("example.com is " .. ip4.str(addr))

tap.ok(#addr == 4 and addr ~= ip4.ANY, "to a real address")

tap.done()
