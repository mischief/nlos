# riscv64: the flags this architecture wants and the sources only it has.
# Chosen by the single branch in the root, which descends here for
# every machine that is not a process.

# rv64gc with the hard-float abi, since lua is doubles all the way
# down. medany because we are position-independent and relocate
# ourselves to wherever the firmware put us, which medlow's
# "everything within 2GiB of zero" cannot describe. -fno-math-errno
# so __builtin_sqrt stays a bare fsqrt.d instead of keeping a call to
# sqrt() on the negative-argument path.
arch_args = [
  '-march=rv64imafdc',
  '-mabi=lp64d',
  '-mcmodel=medany',
  '-fno-math-errno',
]
boot_efi = 'bootriscv64.efi'
# same virt machine as aarch64, at a different fw_cfg address; plus
# the rounding floor D has no instruction for.
arch_src = plat_src + files(
  '../libc/softmath.c',
  'math.c',
  '../virt/fwcfg.c',
  '../virt/uart.c',
)
arch_args += '-DFWCFG_BASE=0x10100000UL'
