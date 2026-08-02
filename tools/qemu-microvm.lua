#!/usr/bin/env lua5.4
-- qemu-microvm.lua ELF PAYLOAD.lua -- boot the bare PVH kernel under
-- qemu's microvm machine type. no firmware and no disk, so the payload
-- is injected via fw_cfg (the same mechanism the efi platform's test
-- harness uses) -- something has to run before anything can mount a
-- filesystem. console on stdio; a deliberate triple fault
-- (src/platform/microvm/reset.c) plus -no-reboot ends the guest.
--
-- this attaches no virtio devices. tools/boottest-microvm.lua is the
-- one that does, per test, and is what the suite runs.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local q = require("arch").quote

local elf = arg[1]
local payload = arg[2]

-- ioapic2=off and acpi=on together pin where virtio-mmio lands.
-- microvm_devices_init (qemu's hw/i386/microvm.c) picks the slot count
-- from the first and the irq base from both: a second ioapic (whose
-- default varies by host/kvm state) gives 24 transports based at 24,
-- acpi alone gives 8 based at 16, neither gives 8 based at 5. Only the
-- middle one matches src/platform/microvm/microvm.h's
-- VIRTIO_MMIO_GSI_BASE, and while acpi=on is already microvm's
-- default, a default is a poor thing to rest an irq number on. Any
-- virtio-mmio -device should still be pinned with
-- bus=virtio-mmio-bus.N (N < 8) to be sure.
local cmd = table.concat({
	"qemu-system-x86_64",
	"-M microvm,pit=off,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-device virtio-rng-device,bus=virtio-mmio-bus.1",
	"-nodefaults -no-user-config -no-reboot -nographic",
	"-serial stdio",
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
