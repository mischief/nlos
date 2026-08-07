#!/usr/bin/env lua5.4
-- arp-lan.lua [ELF] -- resolve the host's real default gateway from a
-- guest bridged onto the host's LAN.
--
-- Not part of the test suite, and deliberately: it needs a bridge, a
-- gateway and a qemu-bridge-helper the invoking user may use, none of
-- which a build machine can be assumed to have -- and it puts frames on
-- a real network, which a `meson test` should never do behind
-- someone's back. scripts/boottest-microvm.lua's slirp is the
-- everyday check; this is the one that answers "does it work against
-- hardware that has never heard of us".
--
-- The probe carries sender IP 0.0.0.0 (RFC 5227's ARP Probe), which is
-- what a host sends before claiming an address. Two reasons: it claims
-- nothing on someone's LAN, and every correct implementation declines
-- to cache a mapping from it -- so running this leaves no trace in the
-- ARP table of any machine that hears it. lib/arp.lua's observe() skips
-- such senders for the same reason.
--
-- The gateway is read from the host's routing table rather than
-- configured here, so there is nothing to keep in step with the network
-- this happens to be run on.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local q = require("arch").quote

local elf = arg[1] or "build-mvm/luaos-microvm.elf"

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
end

local route = popen_line("ip route show default") or ""
local gw, dev = route:match("^default via (%S+) dev (%S+)")

if not gw then
	io.stderr:write("no default route; nothing to probe\n")
	os.exit(1)
end

-- the bridge to attach to has to be one the helper is allowed to use
-- (/etc/qemu/bridge.conf). The default route's device is the right
-- guess when it is itself a bridge, which is the case this is for.
local br = os.getenv("BRIDGE") or dev

print("# probing " .. gw .. " over " .. br)

local payload = os.tmpname() .. ".lua"
local f = assert(io.open(payload, "w"))

-- the target is baked in rather than passed at runtime: there is no
-- second fw_cfg channel to a payload, and a generated file is simpler
-- than inventing one for a script that is already generating a guest.
f:write(([[
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local ether = require("ether")
local ip4 = require("ip4")
local arp = require("arp")

tap.plan(2)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.done()
	return
end

local function rpc(msg)
	local reply = sys.newport("arp-lan.reply")

	msg.reply = { __right = sys.sendright(reply) }
	sys.send(caps.eth, msg)
	return thread.recv(reply)
end

local mac = rpc({ op = "mac" }).mac

tap.diag("our mac is " .. ether.mac_str(mac))

local wire = {
	send = function(frame)
		local r = rpc({ op = "send", data = frame })

		return r and r.ok
	end,
	recv = function()
		local r = rpc({ op = "recv" })

		return r and r.data
	end,
	now = sys.uptime_ms,
	yield = sys.yield,
}

local target = ip4.parse(%q)
-- ip4.ANY as the sender: an ARP probe, claiming nothing. See
-- scripts/arp-lan.lua for why this and not our own address.
local mac2, why = arp.resolve(wire, mac, ip4.ANY, target, 5000)

if mac2 then
	tap.diag(ip4.str(target) .. " is at " .. ether.mac_str(mac2))
end
tap.ok(mac2 ~= nil, "resolved " .. %q .. " on the real network")

if not mac2 then
	tap.diag(tostring(why))
end

tap.done()
]]):format(gw, gw))
f:close()

local cmd = table.concat({
	"timeout 60",
	"qemu-system-x86_64",
	"-M microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-netdev bridge,id=n0,br=" .. q(br),
	"-device virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2",
	"-nodefaults -no-user-config -no-reboot -nographic",
	"-serial stdio",
}, " ")

local ok = os.execute(cmd)

os.remove(payload)
os.exit(ok and 0 or 1)
