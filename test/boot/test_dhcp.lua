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

tap.plan(13)

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

-- installing it is what proves Ip4Config2 accepted the policy change,
-- and listen succeeding immediately afterwards is what proves the
-- address is really live rather than merely stored.
tap.ok(dhcp.install(tcp, lease) ~= nil, "the lease installs")

local ok = false

for _ = 1, 40 do
	if tcp.listen(7777) then
		ok = true
		break
	end
	thread.sleep(50)
end
tap.ok(ok, "and tcp can listen on the installed address")

tap.done()
