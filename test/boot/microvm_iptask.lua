-- the ip task, and the claim that makes it worth having: a client that
-- has never heard of this platform works against it unchanged.
--
-- lib/dhcp.lua's acquire() was written against the UEFI firmware's
-- udp4, reached through lib/caps.lua's wrapper, and is what the efi
-- platform boots with today. Nothing in it knows about ethernet frames,
-- virtio, or Lua checksums. Here it runs against task/ip.lua, and the
-- only thing that changed is which handle caps.udp was given.
--
-- That is the entire argument for the task boundary being where it is.
-- If this passes, task/dns.lua works here too, and the two platforms
-- stop having separate answers to the same question.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local dhcp = require("dhcp")
local ip4 = require("ip4")
local ether = require("ether")

tap.plan(6)

local granted = sys.granted()

if not tap.ok(granted.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

-- ---- the stack is already running ----
--
-- Not started here: kernel.c spawns it beside the other tasks and
-- grants it eth, so a booted machine has a stack whether or not
-- anything asks for one. This test used to start its own, which meant
-- it proved the code worked and not that the machine did.
local iph = granted.ip

if not tap.ok(iph ~= nil, "the kernel started the ip task") then
	tap.done()
	return
end

-- ---- it answers as a udp service ----
--
-- caps.udp is the wrapper every existing client uses, pointed at our
-- task instead of the firmware's. Nothing below this line is new code.
local udp = caps.udp(iph)
local conn = udp.open(0)

tap.ok(conn ~= nil, "caps.udp opened a port on it")

-- ---- and the firmware's own dhcp client drives it ----
--
-- It wants the mac as a hex string, which on efi comes from the nic
-- driver; here the stack itself is the only thing that knows it, so ask
-- it. That question is this task's own protocol rather than udp's --
-- the one place the client does have to know what it is talking to.
local cfg = thread.rpc(iph, { op = "config" })
local lease, err = dhcp.acquire(udp, iph, { hostname = "luaos",
    mac = cfg and ether.mac_str(cfg.mac) })

if not tap.ok(lease ~= nil, "lib/dhcp.lua got a lease through it") then
	tap.diag(tostring(err))
	tap.done()
	return
end

tap.diag("leased " .. tostring(lease.ip) .. " mask " ..
    tostring(lease.mask) .. " router " .. tostring(lease.router))

tap.ok(tostring(lease.ip) == "10.0.2.15",
    "and it is the address slirp leases")

-- ---- the stack is still serving afterwards ----
--
-- The point of a task rather than a library: it did not stop existing
-- when the exchange ended, and it is still answering while nothing is
-- driving it.
local reply = thread.rpc(iph, { op = "config" })

tap.ok(reply and reply.mac and #reply.mac == 6,
    "and the task is still there, with a mac: " ..
    (reply and ether.mac_str(reply.mac) or "?"))

tap.done()
