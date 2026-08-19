# aarch64: the flags this architecture wants and the sources only it has.
# Chosen by the single branch in the root, which descends here for
# every machine that is not a process.

# fp/simd is baseline on aarch64 and edk2 enables it before running
# an application, so floor/ceil/sqrt are single instructions with no
# flag. outline atomics are the one thing that would pull libgcc in.
arch_args = ['-mno-outline-atomics']
boot_efi = 'bootaa64.efi'
# qemu's virt machine: fw_cfg is mmio, the wire is a pci card, and
# there is no instruction above fsqrt.
arch_src = plat_src + files(
  '../libc/softmath.c',
  '../virt/fwcfg.c',
  '../virt/uart.c',
)
arch_args += '-DFWCFG_BASE=0x09020000UL'
