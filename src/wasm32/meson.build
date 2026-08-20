# wasm32: the flags this target wants and the sources only it has.
#
# No -march and no memory model to choose. softmath.c is here for the
# same reason the other soft-float arches take it: wasm has no
# instruction for the rounding modes lua asks for.

arch_args = ['-fno-math-errno']
boot_efi = ''
arch_src = plat_src + files(
  '../libc/softmath.c',
  'math.c',
)
