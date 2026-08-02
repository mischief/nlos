-- the machine configures itself.
--
-- Nothing in this file asks for an address. kernel.c starts eth, then
-- the ip stack on top of it, then the dhcp client on top of that, and
-- by the time a payload runs the machine already has a lease. That is
-- the difference between a stack that works when driven and a machine
-- that is on a network.
--
-- It is also the same task/dhcpd.lua the efi platform runs, which there
-- is handed tcp and udp and installs the lease through the firmware.
-- Here it is handed one right -- the ip task, which is both the udp
-- service and the thing that holds the address -- and the only part
-- that differs is where the answer is put.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local ip4 = require("ip4")

tap.plan(5)

local granted = sys.granted()

if not tap.ok(granted.ip ~= nil, "the kernel started the ip stack") then
	tap.done()
	return
end

tap.ok(granted.dhcpd ~= nil, "and a dhcp client above it")

-- dhcp is not instant and nothing here waits on it, so give it a moment
-- rather than racing the boot. A machine that takes a second to come up
-- is not a machine that failed.
local cfg
local deadline = sys.uptime_ms() + 8000

repeat
	cfg = thread.rpc(granted.ip, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

if not tap.ok(cfg and cfg.ip and cfg.ip ~= ip4.ANY,
    "the stack has an address nobody in this test asked for") then
	tap.done()
	return
end

tap.diag("configured " .. ip4.str(cfg.ip) ..
    "/" .. (cfg.mask and ip4.str(cfg.mask) or "-") ..
    " gw " .. (cfg.gw and ip4.str(cfg.gw) or "-"))

tap.ok(ip4.str(cfg.ip) == "10.0.2.15",
    "and it is the one slirp leases")

-- the route came with it, which is what makes the address usable rather
-- than merely present.
tap.ok(cfg.gw ~= nil and ip4.str(cfg.gw) == "10.0.2.2",
    "with the gateway installed too")

tap.done()
