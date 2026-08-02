-- the ip task, and the claim that makes it worth having: a client that
-- has never heard of this platform works against it unchanged.
--
-- lib/caps.lua's udp wrapper is what every existing client uses to
-- reach the firmware's udp4 on efi. Pointed at task/ip.lua it should
-- work unchanged, and that is the entire argument for the task boundary
-- being where it is: a client cannot tell which it is talking to.
--
-- The strongest evidence for that is no longer here. task/dhcpd.lua --
-- lib/dhcp.lua's acquire, written against the firmware -- now runs
-- against this stack at every boot and configures the machine before
-- any payload starts, which microvm-autoip asserts. This test used to
-- run a second copy of that client, and stopped being able to the
-- moment the real one existed: only one thing may hold port 68, which
-- is the correct arrangement.
--
-- So what is left here is the wrapper itself, exercised over a
-- conversation the machine is not already having.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local dns = require("dns")
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

-- ---- send and receive through the wrapper ----
--
-- A dns query, because it answers promptly and proves both directions:
-- caps.udp.send reached the wire and caps.udp.recv got the answer back.
-- give the machine's own client a moment: a payload starts while dhcp
-- is still in flight, so this waits for the address rather than racing
-- the boot.
local ip4 = require("ip4")
local cfg
local deadline = sys.uptime_ms() + 8000

repeat
	cfg = thread.rpc(iph, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

tap.ok(cfg and cfg.ip and cfg.ip ~= ip4.ANY,
    "the machine is configured, by its own dhcp client")

-- warm the arp cache: the first datagram to a peer we have no mac for
-- is dropped while the request goes out (see lib/inet.lua's output).
udp.send(conn, 10, 0, 2, 3, dns.PORT, dns.build_query("example.com", 1))
thread.sleep(400)
udp.send(conn, 10, 0, 2, 3, dns.PORT, dns.build_query("example.com", 0x2a))

local r = udp.recv(conn, 4096)
local addr = r and dns.parse(r.data, 0x2a)

tap.ok(addr ~= nil,
    "a query and its answer crossed caps.udp: example.com is " ..
    tostring(addr))

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
