# microvm plan (parked)

the deeper redpill, recorded for another day. status: PLANNED, not
started. see DESIGN.md "bluepilled vs redpilled" — this resolves that
question as "both pills, one body": microvm becomes a second platform,
efi stays. nothing here obligates anything.

## the realization

qemu's microvm machine type has NO uefi at all: qboot/seabios, no pci,
up to eight virtio-mmio devices, fw_cfg, lapic/ioapic, optional
pic/pit/rtc/serial. so this is not "ExitBootServices someday" — it is
"firmware never existed." the PE header path is irrelevant there; we
boot as an ELF with a PVH entry note (XEN_ELFNOTE_PHYS32_ENTRY),
entering in 32-bit protected mode and setting up long mode + paging
ourselves.

key insight that kills the two scariest costs:

- **filesystem: virtio-9p-device.** virtio-mmio can host virtio-9p.
  we already speak 9P2000 — ninep.lua grows a client side (codec is
  done; T-message builders + fid tracking, ~150 lines of lua) and the
  root namespace comes straight from a host directory. no FAT driver,
  no block driver, no mkimage step: edit lua on the host, reboot guest.
- **networking: no tcp stack needed.** lwip violates the no-deps
  pillar and is not required:
  - v1: virtio-vsock-device = stream to host, 9p rides it
  - v2: virtio-net + arp/icmp/udp in lua (trivial protocols)
  - endgame: tcp in lua — tcp is pure policy, pillar 1 says it
    belongs there. slow is fine.
  - lwip: never.

## what microvm buys

- **interrupts at last**: own IDT — exception handlers with register
  dumps (no more silent hangs), lapic timer (tsc-deadline), ioapic
  routing for virtio irqs. event-driven io for real; the poll era ends.
- **real MP**: INIT-SIPI by hand, -smp N, one lua_State pinned per
  core, ports as shared-memory rings (the notes/DESIGN sketch). no
  efi mp_services middleman.
- instant boot, no ovmf spew; own pmm from the PVH memory map (bump
  allocator day one).

## costs (honest list)

- PVH entry: 32-bit entry -> gdt -> long mode -> page tables (~200
  lines of well-trodden asm in src/<arch>/)
- idt + exception handlers + lapic timer + ioapic (~400 lines)
- virtio-mmio transport + virtqueues (~300 lines; spec is friendly)
- virtio-9p glue (lua does the protocol; c moves ring buffers)
- console is serial-only (already true in practice)
- shutdown = deliberate triple fault (documented microvm way, cursed)
- two boot artifacts from one object set: PE (ovmf) + ELF w/ PVH note
  (microvm). meson handles this fine.

## structure

platform split per DESIGN pillar 7: the kernel core
(procs/ports/rights/serializer/scheduler) is already firmware-blind.

```
src/platform/efi/      current: efi glue, SimpleFS, ConIn/ConOut pumps
src/platform/microvm/  new: pvh entry, pmm, idt, lapic, ioapic,
                       virtio-mmio, virtio-9p, triple-fault reset
src/x86_64/            shared machine bits (uart, setjmp, math, fwcfg)
```

los.efi exists only on the efi platform; microvm gets los.hw (or
similar) for reset/timer. los.sys and los.thread untouched. fs.c's
narrow api (open/read/write/seek/close) is the seam: efi backs it
with SimpleFS, microvm with the 9p client.

## phases

- **A: hello microvm.** PVH ELF note + entry asm, long mode, paging,
  pmm from memory map, idt with fault register dumps, serial hello.
  qemu: -M microvm -kernel luaos.elf. tests: new platform boots, TAP
  over serial unchanged (fw_cfg works on microvm — harness carries
  over almost verbatim).
- **B: lua parity.** lapic timer tick (replaces the efi 1ms event),
  virtio-mmio discovery, virtio-9p root filesystem, port fs.c to the
  9p client, repl on serial. full test suite green on BOTH platforms
  (meson test matrix).
- **C: smp.** INIT-SIPI, per-core lua states, shared-ring ports,
  work distribution. the mach/plan9 layer should not change shape.

## open questions for future-us

- PVH vs plain multiboot2 via seabios? PVH is cleaner (qemu loads
  ELF directly); revisit if PVH support shifts.
- one binary or two? (ELF with PVH note can also carry the PE header
  bytes... probably not worth the cursedness. two artifacts.)
- does the efi platform eventually get the virtio drivers too (pci
  flavor) or stay SimpleFS forever? undecided, low stakes.
- keyboard on microvm: none (no ps/2 by default). serial console is
  the tty. fine for a 9p-serving brain in a jar.
