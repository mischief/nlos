#!/usr/bin/env lua5.4
-- qemu.lua IMG -- interactive run.
-- com1 = console on stdio, the 9p wire on ./9p.sock (in cwd, which for
-- `ninja qemu` is the build directory). virtio-net-pci + user-mode
-- networking gives the net task a NIC; guest gets a DHCP lease and can
-- be reached via qemu's usermode NAT (hostfwd if you need inbound).

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local img = arg[1]

if not io.open("OVMF_VARS.fd", "rb") then
	os.execute("cp " .. q(arch.FW_VARS) .. " OVMF_VARS.fd")
end

local cmd = table.concat({
	arch.QEMU, "-nographic", arch.MACHINE, arch.VIDEO, arch.RNG,
	"-netdev user,id=n0,hostfwd=tcp::7777-:7777",
	"-device " .. arch.NIC .. ",netdev=n0",
	"-serial mon:stdio",
	arch.wire_args("socket", "9p.sock"),
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=OVMF_VARS.fd",
	"-drive " .. arch.BLK .. ",file=" .. q(img),
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
