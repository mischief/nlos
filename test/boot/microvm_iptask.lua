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

tap.plan(8)

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

-- one query, cold. No warm-up: lib/inet.lua holds a packet while it
-- arps and sends it when the answer comes, so the first datagram to a
-- peer we have never spoken to arrives like any other.
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

-- ---- a malformed request is refused, not fatal ----
--
-- The stack is shared: every proc on the machine reaches the network
-- through this one task, so a request that kills it takes everyone's
-- network with it. That has happened once already -- a send with a
-- missing octet reached string.char as a nil -- and the fix checked
-- type(v) == "number", which is not the same question. A float has
-- that type and no integer representation, so `1.5 & 0xff` raises,
-- and so does string.pack on a port of 1.5 or of 70000.
--
-- Each of these used to be fatal. The reply value matters less than
-- the config round trip after them: that is what proves the task is
-- still alive to answer at all.
local bad = {
	{ op = "send", connid = conn, data = "x", port = 1.5,
	    a = 10, b = 0, c = 0, d = 1 },
	{ op = "send", connid = conn, data = "x", port = 70000,
	    a = 10, b = 0, c = 0, d = 1 },
	{ op = "send", connid = conn, data = "x", port = 53,
	    a = 1.5, b = 0, c = 0, d = 1 },
	{ op = "open", port = 1.5 },
	{ op = "open", port = 70000 },
	{ op = "config", rcvbuf = "enormous" },
}

for _, req in ipairs(bad) do
	thread.rpc(iph, req)
end

local alive = thread.rpc(iph, { op = "config" })

tap.ok(alive and alive.mac and #alive.mac == 6,
    "the task survives malformed requests that used to kill it")

-- and a well-formed send still works afterwards, so the checks refuse
-- the bad ones rather than having wedged the conn on the way past
tap.ok(thread.rpc(iph, { op = "send", connid = conn, data = "x",
    port = 53, a = 10, b = 0, c = 0, d = 1 }) ~= nil,
    "and still sends after refusing them")

tap.done()
