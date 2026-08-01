#!/usr/bin/env lua5.4
-- qemu-microvm.lua ELF PAYLOAD.lua -- boot the bare PVH kernel under
-- qemu's microvm machine type. no firmware, no disk: the payload is
-- injected via fw_cfg (same mechanism the efi platform's test harness
-- uses), since there is no filesystem yet (docs/microvm-plan.md).
-- console on stdio; a deliberate triple fault (src/platform/microvm/
-- reset.c) plus -no-reboot is what ends the guest.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local q = require("arch").quote

local elf = arg[1]
local payload = arg[2]

-- ioapic2=off pins virtio-mmio to the documented 8-slot/GSI-5-base
-- layout (qemu's hw/i386/microvm.c): with a second IOAPIC present (the
-- qemu default varies by host/kvm state) it silently switches to 24
-- slots at a different irq base instead, which src/platform/microvm/
-- virtio.c's fixed 8-slot scan would never see. any virtio-mmio
-- -device should still be pinned with bus=virtio-mmio-bus.N (N < 8)
-- to be sure.
local cmd = table.concat({
	"qemu-system-x86_64",
	"-M microvm,pit=off,pic=off,rtc=off,ioapic2=off",
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-nodefaults -no-user-config -no-reboot -nographic",
	"-serial stdio",
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
