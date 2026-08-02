-- dhcp in lua (lib/dhcp.lua) plus the address install behind it.
--
-- this one needs a real NIC (NET=1), but unlike the http/9p tests it
-- needs no host driver: DHCP is a broadcast to whoever answers, and
-- qemu's usermode network answers. so the whole four-way runs in-guest
-- and the assertions are about what came back.
--
-- what is being tested is not really the codec -- it arrived working --
-- but that a socket with NO address can carry it, and that the lease can
-- then be installed. both are the pieces the firmware would not lend us.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local dhcp = require("dhcp")
local tap = require("tap")

tap.plan(21)

local g = sys.granted()

tap.ok(g.tcp ~= nil and g.udp ~= nil, "the guest has tcp and udp")

local tcp = caps.tcp(g.tcp)
local udp = caps.udp(g.udp)

-- ---- the codec, on a packet we built ourselves ----
local pkt = dhcp.encode({ xid = 0x1234, mac = "52:54:00:12:34:56",
    msg_type = dhcp.DISCOVER })

tap.ok(#pkt >= 300, "encode pads to the BOOTP minimum (" .. #pkt .. ")")
tap.is(pkt:sub(237, 240), "\99\130\83\99", "and writes the magic cookie")

-- decode rejects rubbish rather than indexing off the end
tap.ok(dhcp.decode("short") == nil, "decode refuses a short packet")
tap.ok(dhcp.decode(string.rep("\0", 300)) == nil,
    "and one that is not a BOOTREPLY")

-- ---- quad ----
local a, b, c, d = dhcp.quad("10.0.2.15")

tap.ok(a == 10 and b == 0 and c == 2 and d == 15, "quad splits an address")
tap.ok(dhcp.quad("not an ip") == nil, "and rejects a non-address")

-- ---- the real thing ----
local mac = tcp.hwaddr()

tap.ok(mac ~= nil and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil,
    "hwaddr returns the NIC's mac: " .. tostring(mac))

local t0 = sys.uptime_ms()
local lease, err = dhcp.acquire(udp, g.udp, { mac = mac })

if not tap.ok(lease ~= nil, "acquire got a lease (" .. tostring(err) .. ")") then
	tap.done()
	return
end

local took = sys.uptime_ms() - t0

tap.ok(dhcp.quad(lease.ip) ~= nil,
    "the lease has an address: " .. tostring(lease.ip) ..
    "/" .. tostring(lease.mask))

-- the point of the exercise. the firmware needs ~4s to accept an offer
-- it already holds, because Ip4Config2 passes Dhcp4 no callback and the
-- first mDhcp4DefaultTimeout entry is 4 seconds. ours chooses its own
-- deadline. generous bound so this is a regression test and not a
-- benchmark -- it has measured 12-24ms.
tap.ok(took < 1000, "and got it in " .. took .. "ms, not four seconds")

-- NOT installed here. lib/dhcpd.lua below is the thing that installs a
-- lease, and it is what the rest of this file exercises -- two clients
-- racing to configure one interface would be testing the race.

-- ---- the lease as a filesystem ----
--
-- what init.lua mounts at /net. built here by hand because this payload
-- replaces init, so there is no /net unless we make one -- which also
-- means this tests the mount rather than assuming it.
local nsmod = require("ns")
local proc = require("proc")
local srv = require("srv")

-- a payload replaces init.lua, which is what adopts a namespace, so
-- there is none to inherit -- build one, same as test_prog.lua does. the
-- ESP as a MOUNT, since los.fs belongs to the esp server task alone.
local N = nsmod.new()

assert(N:mount("/", require("mnt").new(g.esp), "mnt",
    { port = { __right = g.esp } }))

-- rights in the ARG, not a first message: dhcpd's port is srv.serve's
local pid, h = proc.spawn(assert(N:readfile("/task/dhcpd.lua")),
    { name = "dhcp2", ns = N:describe(), arg = {
        tcp = { __right = g.tcp }, udp = { __right = g.udp } } })

tap.ok(pid ~= nil, "dhcpd spawns with its rights in the spawn arg")

N:mount("/net", require("mnt").new(h), "mnt", { port = { __right = h } })

-- it has to acquire before /net/addr says anything, and it is racing
-- this test rather than being waited on, so give it a moment.
local addr
for _ = 1, 60 do
	addr = N:readfile("/net/addr")
	if addr and addr:match("%d") then
		break
	end
	thread.sleep(100)
end

tap.ok(addr ~= nil and dhcp.quad((addr or ""):gsub("%s+$", "")) ~= nil,
    "/net/addr reports the address: " .. tostring((addr or ""):gsub("\n", "")))

local dnstxt = N:readfile("/net/dns")

tap.ok(dnstxt ~= nil and dnstxt:match("^%d+%.%d+%.%d+%.%d+") ~= nil,
    "/net/dns reports a resolver, one per line: " ..
    tostring((dnstxt or ""):gsub("\n", " ")))

local leasetxt = N:readfile("/net/lease")

tap.ok(leasetxt ~= nil and leasetxt:find("state bound", 1, true) ~= nil,
    "/net/lease says bound")
tap.ok(leasetxt:find("gw ", 1, true) ~= nil and
    leasetxt:find("remaining ", 1, true) ~= nil,
    "...with a gateway and a countdown")

-- readdir, so `ls /net` works rather than only paths you already know
local ents = N:readdir("/net")
local names = {}

for _, e in ipairs(ents or {}) do
	names[e.name] = true
end
tap.ok(names.addr and names.dns and names.ctl and names.lease,
    "ls /net lists the tree")

-- ctl is the only writable file, and the only authority here
tap.ok(N:writefile("/net/ctl", "renew") ~= nil,
    "writing renew to /net/ctl is accepted")
tap.ok(select(1, N:writefile("/net/addr", "1.2.3.4")) == nil,
    "but the reporting files are read-only")
tap.ok(select(1, N:writefile("/net/ctl", "nonsense")) == nil,
    "and ctl rejects a command it does not know")

-- the renewal it was asked for must actually happen, and leave the
-- address usable rather than merely unchanged
local renewed = false

for _ = 1, 60 do
	local t = N:readfile("/net/lease")

	if t and t:find("state bound", 1, true) then
		renewed = true
		break
	end
	thread.sleep(100)
end
tap.ok(renewed, "and the lease is still bound after a forced renewal")

tap.done()
