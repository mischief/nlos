# x86_64: the flags this architecture wants and the sources only it has.
# Chosen by the single branch in the root, which descends here for
# every machine that is not a process.

# no red zone (efi), sse4.1 so floor/ceil are single instructions
# (qemu wants -cpu max)
arch_args = ['-mno-red-zone', '-msse4.1']
boot_efi = 'bootx64.efi'
# a pc: fw_cfg and com2 are both at fixed io ports, and x87 has the
# transcendentals in hardware. microvm supplies its own uart.c (com1,
# not com2 -- no firmware console to share the machine with) but
# reuses fwcfg.c/math.c unchanged, since both are already plain PIO/
# x87 with no EFI dependency.
arch_src = plat_src + files(
  'fwcfg.c',
  'math.c',
)
if platform == 'microvm'
  # the only configuration with more than one cpu; everything else
  # takes lock.h's uniprocessor path.
  arch_args += '-DNCPU=8'
endif
if platform == 'efi'
  arch_src += files('uart.c')
else
  arch_src += files(
    '../platform/microvm/boot.S',
    '../platform/microvm/idt_stubs.S',
    '../platform/microvm/idt.c',
    '../platform/microvm/lapic.c',
    '../platform/microvm/ioapic.c',
    '../platform/microvm/i8259.c',
    '../platform/microvm/i8253.c',
    '../platform/microvm/intr.c',
    '../platform/microvm/pci.c',
    '../platform/microvm/tsc.c',
    '../platform/microvm/pmm.c',
    '../platform/microvm/smp.c',
    '../platform/microvm/smp_trampoline.S',
    '../platform/microvm/uart.c',
    '../platform/microvm/reset.c',
    '../platform/microvm/efi_shim.c',
    '../platform/microvm/virtio.c',
    '../platform/microvm/virtio_mmio.c',
    '../platform/microvm/virtio_pci.c',
    '../platform/microvm/virtio_rng.c',
    '../platform/microvm/virtio_9p.c',
    '../platform/microvm/virtio_net.c',
    '../platform/microvm/virtio_blk.c',
  )
endif
