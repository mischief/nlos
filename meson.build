project('lua-os', 'c',
  version: '0.1',
  license: 'MIT',
  meson_version: '>=1.1',
  default_options: [
    'c_std=gnu11',
    'warning_level=1',
    'optimization=2',
  ])

cc = meson.get_compiler('c')
objcopy = find_program('objcopy')

# every tools/*.lua and test/*.lua tool is run through this rather
# than relying on a shebang + preserved execute bit.
lua_interp = find_program('lua5.4', 'lua')

# the per-arch table, and the only place any of it is written down.
# it decides which sources build, what the esp must call the loader for
# the firmware to find it (the UEFI spec's removable-media path), and
# what machine-specific flags the compiler needs. everything downstream
# -- tools/arch.lua, test/qemuarch.lua -- is told the answer rather
# than working it out again; see the LUAOS_ARCH env below.
#
# a native build gets this from the host; a cross build gets it from
# --cross-file cross/<arch>.txt, which is the only way to build riscv64
# unless you have riscv64 hardware to build on.
arch = host_machine.cpu_family()
platform = get_option('platform')

if platform == 'microvm' and arch != 'x86_64'
  error('microvm platform is x86_64-only')
endif

# every port needs the platform layer (src/<arch>/machine.c, setjmp.S)
# plus a way to reach fw_cfg, a second serial port, and the libm floor.
# efi also needs header.S (the hand PE32+ header/entry) and reloc.c
# (self-relocation to wherever firmware loaded it) -- microvm links at
# a fixed physical address instead (see src/platform/microvm/boot.S),
# so it needs neither.
plat_src = files(
  'src' / arch / 'machine.c',
  'src' / arch / 'setjmp.S',
)
if platform == 'efi'
  plat_src += files(
    'src' / arch / 'header.S',
    'src' / arch / 'reloc.c',
  )
endif

if arch == 'x86_64'
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
    'src/x86_64/fwcfg.c',
    'src/x86_64/math.c',
  )
  if platform == 'efi'
    arch_src += files('src/x86_64/uart.c')
  else
    arch_src += files(
      'src/platform/microvm/boot.S',
      'src/platform/microvm/idt_stubs.S',
      'src/platform/microvm/idt.c',
      'src/platform/microvm/lapic.c',
      'src/platform/microvm/ioapic.c',
      'src/platform/microvm/i8259.c',
      'src/platform/microvm/i8253.c',
      'src/platform/microvm/intr.c',
      'src/platform/microvm/pci.c',
      'src/platform/microvm/tsc.c',
      'src/platform/microvm/pmm.c',
      'src/platform/microvm/uart.c',
      'src/platform/microvm/reset.c',
      'src/platform/microvm/efi_shim.c',
      'src/platform/microvm/virtio.c',
      'src/platform/microvm/virtio_mmio.c',
      'src/platform/microvm/virtio_pci.c',
      'src/platform/microvm/virtio_rng.c',
      'src/platform/microvm/virtio_9p.c',
      'src/platform/microvm/virtio_net.c',
      'src/platform/microvm/virtio_blk.c',
    )
  endif
elif arch == 'aarch64'
  # fp/simd is baseline on aarch64 and edk2 enables it before running
  # an application, so floor/ceil/sqrt are single instructions with no
  # flag. outline atomics are the one thing that would pull libgcc in.
  arch_args = ['-mno-outline-atomics']
  boot_efi = 'bootaa64.efi'
  # qemu's virt machine: fw_cfg is mmio, the wire is a pci card, and
  # there is no instruction above fsqrt.
  arch_src = plat_src + files(
    'src/libc/softmath.c',
    'src/virt/fwcfg.c',
    'src/virt/uart.c',
  )
  arch_args += '-DFWCFG_BASE=0x09020000UL'
elif arch == 'riscv64'
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
    'src/libc/softmath.c',
    'src/riscv64/math.c',
    'src/virt/fwcfg.c',
    'src/virt/uart.c',
  )
  arch_args += '-DFWCFG_BASE=0x10100000UL'
else
  error('no src/' + arch + ': x86_64, aarch64 and riscv64 are ported')
endif

# freestanding: our include/ plus only the compiler's own headers.
# pic + hidden is for the RELATIVE-relocs-only self-relocation scheme.
gccinc = run_command(cc.cmd_array() + ['-print-file-name=include'],
  check: true).stdout().strip()

freestanding_args = [
  '-ffreestanding',
  '-fpic',
  '-fvisibility=hidden',
  '-fno-stack-protector',
  '-fno-strict-aliasing',
  '-fshort-wchar',
  '-nostdinc',
  '-I' + gccinc,
  # src/coreg.h, through the hook lua provides for exactly this: it
  # redefines LUA_EXTRASPACE and the luai_userstate* macros so the
  # kernel can keep every lua_State of a proc on a list. lua/ is a
  # submodule of upstream and stays untouched.
  '-DLUA_USER_H="coreg.h"',
  '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
  '-DLUA_CPATH_DEFAULT=""',
] + arch_args

add_project_arguments(freestanding_args, language: 'c')

inc = include_directories('include', 'src', 'lua', 'src' / arch,
  'src/platform' / platform)

# dirs.c/kernel.c/linit.c are firmware-blind (the platform seam is
# platform.h + fs.h/efi.h, all resolved from the per-platform
# include dir above); everything else is the platform's own.
# The shared source lists live in tools/sources.lua, which ESP-IDF's
# cmake reads too: two build systems is the honest answer for esp32,
# and one list is what stops them drifting apart unnoticed.
sources_lua = files('tools/sources.lua')

kernel_src = files(run_command(lua_interp, sources_lua, 'kernel', check: true)
  .stdout().strip().split('\n'))
if platform == 'efi'
  kernel_src += files(
    'src/platform/efi/blk.c',
    'src/platform/efi/console.c',
    'src/platform/efi/drivers.c',
    'src/platform/efi/fs.c',
    'src/platform/efi/gop.c',
    'src/platform/efi/los.c',
    'src/platform/efi/main.c',
    'src/platform/efi/malloc.c',
    'src/platform/efi/rng.c',
    'src/platform/efi/snp.c',
  )
else
  kernel_src += files(
    'src/platform/microvm/console.c',
    'src/platform/microvm/drivers.c',
    'src/platform/microvm/efi_shim.c',
    'src/platform/microvm/fs.c',
    'src/platform/microvm/main.c',
    'src/platform/microvm/malloc.c',
  )

  # what the microvm C loader can open before any namespace exists (see
  # src/platform/microvm/fs.c). Deliberately only the libs needed to
  # reach the point of mounting something: the driver tasks' own
  # lib/*.lua, los.thread, and the 9p client that turns virtio-9p into a
  # mount. Anything you want to edit without rebuilding belongs on that
  # mount, not in this list -- every entry here is frozen at build time.
  #
  # boot/microvm.lua is the exception in kind: not a lib but the payload
  # main.c falls back to when no fw_cfg one was injected, which is the
  # only way this image boots on a loader whose fw_cfg cannot serve
  # arbitrary files (OpenBSD vmd).
  # -Dboot_payload names what gets embedded AS /boot/microvm.lua, so
  # main.c's BOOT_PAYLOAD path stays fixed and only the contents change.
  # See meson.options for why this is worth an option: on vmd it is the
  # only program that can ever run.
  boot_payload = get_option('boot_payload')

  embed_files = [
    'lib/thread.lua',
    'lib/console.lua',
    'lib/fbcons.lua',
    'task/cons.lua',
    'task/wire.lua',
    'task/power.lua',
    'lib/stdout.lua',
    'lib/ninep.lua',
    'lib/dev.lua',
    'lib/srv.lua',
    'lib/mnt.lua',
    'lib/ns.lua',
    'lib/chan.lua',
    'lib/p9fs.lua',
    'lib/p9tcp.lua',
    'task/p9srv.lua',
    'lib/blkfs.lua',
    'task/blksrv.lua',
    # gefs: a filesystem to mount over the block device above. Frozen in
    # rather than served over a mount because the direction is to boot
    # from it, which makes it a bootstrap dependency the way blkfs is.
    # salvage.lua is left out: it is a host recovery tool, not on any
    # path the guest takes.
    'lib/gefs.lua',
    'lib/gefs/dat.lua',
    'lib/gefs/hash.lua',
    'lib/gefs/pack.lua',
    'lib/gefs/obj.lua',
    'lib/gefs/blk.lua',
    'lib/gefs/store.lua',
    'lib/gefs/tree.lua',
    'lib/gefs/snap.lua',
    'lib/gefs/fsops.lua',
    'lib/gefs/check.lua',
    'lib/gefs/vol.lua',
    'lib/gefs/ram.lua',
    'lib/gefs/io.lua',
    'lib/gefs/slice.lua',
    'lib/gefsfs.lua',
    'lib/gpt.lua',
    'lib/partfs.lua',
    'task/partsrv.lua',
    'task/gefssrv.lua',
    'task/eth.lua',
    'lib/ether.lua',
    'lib/ip4.lua',
    'lib/arp.lua',
    'lib/ethwire.lua',
    'lib/icmp.lua',
    'lib/udp4.lua',
    'lib/tcp4.lua',
    'lib/inet.lua',
    'lib/dhcp.lua',
    'lib/dhcpc.lua',
    'lib/ntp.lua',
    'lib/dns.lua',
    'lib/dnsc.lua',
    'lib/caps.lua',
    'lib/http.lua',
    'lib/crypto/chacha20.lua',
    'lib/crypto/poly1305.lua',
    'lib/crypto/hashstate.lua',
    'lib/crypto/sha256.lua',
    'lib/tcb.lua',
    'task/ip.lua',
    'task/tcp4.lua',
    'task/dhcpd.lua',
    'lib/dev.lua',
    'lib/srv.lua',
    'lib/sync/once.lua',
    'lib/sync/sema.lua',
    'lib/sync/lock.lua',
    'lib/tap.lua',
    'lib/ps.lua',
    'lib/zmodem.lua',
  ]
  embed_args = ['/boot/microvm.lua=' +
      (boot_payload.startswith('/') ? boot_payload
       : meson.current_source_dir() / boot_payload)]
  foreach f : embed_files
    embed_args += '/' + f + '=' + meson.current_source_dir() / f
  endforeach
  embedfs_src = custom_target('embedfs.c',
    output: 'embedfs.c',
    input: files(embed_files) + files(boot_payload),
    command: [lua_interp, files('tools/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
  )
  kernel_src += embedfs_src
endif

libc_src = files(run_command(lua_interp, sources_lua, 'libc', check: true)
  .stdout().strip().split('\n'))

lua_src = files(run_command(lua_interp, sources_lua, 'lua', check: true)
  .stdout().strip().split('\n'))

pe_ld = meson.current_source_dir() / 'src/platform/efi/pe.ld'
microvm_ld = meson.current_source_dir() / 'src/platform/microvm/microvm.ld'

# hardening warnings for OUR code only (the lua submodule stays
# vanilla and compiles with plain -Wall). adapted from c-template;
# checked per-flag so compiler upgrades don't break the build.
hardening_args = ['-Wextra', '-Werror']
foreach a : [
  '-Wnull-dereference',
  '-Warray-bounds',
  '-Wformat=2',
  '-Wformat-security',
  '-Wuninitialized',
  '-Wshadow',
  '-Wimplicit-fallthrough',
  '-Wswitch',
  '-Wstrict-prototypes',
  '-Wmissing-prototypes',
  '-Wmissing-declarations',
  '-Wvla',
  '-Walloca',
  '-Wshift-overflow',
  '-Wframe-larger-than=4096',
  '-Wno-unused-parameter',
  '-fsanitize-trap=all',
]
  if cc.has_argument(a)
    hardening_args += a
  endif
endforeach

# vanilla lua, warnings left to upstream
lua_lib = static_library('lua54', lua_src,
  include_directories: inc,
)

if platform == 'efi'
  # the elf intermediate: base 0, RELATIVE relocs only, self-relocated
  # at entry. gcc drives ld; -nostdlib keeps crt/libc out.
  luaos_elf = shared_library('luaos',
    kernel_src + libc_src + arch_src,
    name_prefix: '',
    include_directories: inc,
    c_args: hardening_args,
    link_with: lua_lib,
    link_args: [
      '-nostdlib',
      '-Wl,-Bsymbolic',
      '-Wl,-znocombreloc',
      # do not emit a build-id: pe.ld discards .note.* (a flat binary has
      # nowhere to keep it), and generating one only to drop it warns.
      '-Wl,--build-id=none',
      '-Wl,-T,' + pe_ld,
    ],
    link_depends: files('src/platform/efi/pe.ld'),
  )

  # flat binary; the hand PE32+ header in src/<arch>/header.S makes this
  # a valid uefi application.
  luaos_efi = custom_target('luaos.efi',
    input: luaos_elf,
    output: 'luaos.efi',
    command: [objcopy, '-O', 'binary', '@INPUT@', '@OUTPUT@'],
    build_by_default: true,
  )
else
  # plain ELF at a fixed physical address (src/platform/microvm/boot.S,
  # microvm.ld) -- qemu's -kernel loader wants this directly, no
  # objcopy step and no self-relocation.
  luaos_microvm_elf = executable('luaos-microvm.elf',
    kernel_src + libc_src + arch_src,
    include_directories: inc,
    c_args: hardening_args,
    link_with: lua_lib,
    link_args: [
      '-nostdlib',
      '-static',
      '-Wl,--build-id=none',
      '-Wl,-T,' + microvm_ld,
    ],
    link_depends: files('src/platform/microvm/microvm.ld'),
    build_by_default: true,
  )

  # boots test/boot/microvm_hello.lua via fw_cfg, the only way to run
  # code here (no filesystem yet) -- console on stdio, -no-reboot turns
  # the deliberate triple-fault shutdown into a clean qemu exit.
  run_target('qemu-microvm',
    command: [lua_interp, files('tools/qemu-microvm.lua'), luaos_microvm_elf,
      files('test/boot/microvm_hello.lua')],
  )
endif

# hostutil: the one C module backing the host-driven test clients
# (test/test_9p.lua etc) -- sockets and argv-array process spawning,
# neither of which stock Lua has. built native regardless of
# -Dplatform/cross-file, since this runs on the machine driving the
# tests, never the guest. optional like fw_network below: a host
# without lua5.4's headers just doesn't run these four tests, rather
# than failing the whole configure.
lua54_dep = dependency('lua5.4', native: true, required: false)
have_hostutil = lua54_dep.found()
if have_hostutil
  hostutil = shared_module('hostutil', 'test/hostutil.c',
    dependencies: lua54_dep,
    native: true,
    name_prefix: '',
  )
else
  warning('lua5.4 dev headers not found: skipping the host-driven ' +
          '9p/http/mcp/web-terminal tests (need liblua5.4-dev or ' +
          'equivalent for test/hostutil.c).')
endif


# tests that ask nothing of either platform's hardware, so the same file
# runs on both and is named without a platform prefix. Keeping one copy
# is the point: close() truncating everything past the send window lived
# in the shared stack, shipped on main, and was caught by one test on one
# platform -- a second copy of that test would have been a second thing
# to forget to update.
#
# [name, microvm boot flags, needs a nic]. "needs a nic" is not about the
# wire -- tcploop never reaches it -- but about the tcp task existing at
# all, since kernel.c only spawns ip and tcp4 when a card is present.
shared_tests = [
  ['tcploop', ['--net'], true],
  ['checksum', [], false],
]

if platform == 'efi'

lua_payload = files(
  'init.lua',
  # what the machine runs, and what each may touch -- see lib/svc.lua
  'etc/services.lua',
  # services, at /task/<name> -- started by init rather than by
  # replacing it. same directory as the driver tasks because the only
  # difference is who spawns them and what they are granted, and both
  # of those are said elsewhere: kernel.c for the drivers,
  # etc/services.lua for the rest.
  'task/webterm.lua',
  'task/sshd.lua',
  # programs, at /bin/<name> -- see lib/prog.lua for the ABI they run under
  'bin/cat.lua',
  'bin/ps.lua',
  # the other two repl words, and the pager. Nothing here is esp32's:
  # a shell over ssh or a browser reaches /bin rather than the repl's
  # _ENV, so these are wanted wherever a shell is. bin/wifi.lua is not
  # here, being about a radio these machines do not have.
  'bin/ports.lua',
  'bin/stats.lua',
  'bin/p.lua',
  'bin/rm.lua',
  'bin/fetch.lua',
  'bin/stack.lua',
  'bin/trace.lua',
  'bin/ls.lua',
  'bin/seq.lua',
  'bin/smiley.lua',
  # vi, and its ed/ engine and terminal (lib/ed/*). a full-screen program
  # over the tty capability -- see lib/prog.lua and lib/caps.lua.
  'bin/vi.lua',
  'lib/ed/buffer.lua',
  'lib/ed/terminfo.lua',
  'lib/caps.lua',
  'task/cons.lua',
  'lib/console.lua',
  'lib/fbcons.lua',
  'lib/chan.lua',
  'lib/dev.lua',
  # the block device and the gefs filesystem over it. blksrv is spawned
  # by the kernel when platform_have_blk() finds a disk (now true on efi
  # too, via src/platform/efi/blk.c); the rest is the same stack microvm
  # carries. salvage stays out -- a host recovery tool, off the boot path.
  'lib/blkfs.lua',
  'task/blksrv.lua',
  'lib/gpt.lua',
  'lib/gefs.lua',
  'lib/gefs/dat.lua',
  'lib/gefs/hash.lua',
  'lib/gefs/pack.lua',
  'lib/gefs/obj.lua',
  'lib/gefs/blk.lua',
  'lib/gefs/store.lua',
  'lib/gefs/tree.lua',
  'lib/gefs/snap.lua',
  'lib/gefs/fsops.lua',
  'lib/gefs/check.lua',
  'lib/gefs/vol.lua',
  'lib/gefs/ram.lua',
  'lib/gefs/io.lua',
  'lib/gefs/slice.lua',
  'lib/gefsfs.lua',
  'lib/partfs.lua',
  'task/partsrv.lua',
  'task/gefssrv.lua',
  'lib/p9serve.lua',
  'lib/nsfs.lua',
  'task/9pexport.lua',
  'lib/draw.lua',
  'lib/sync/once.lua',
  'lib/sync/sema.lua',
  'lib/sync/lock.lua',
  'lib/crypto/util.lua',
  'lib/crypto/chacha20.lua',
  'lib/crypto/poly1305.lua',
  'lib/crypto/hashstate.lua',
  'lib/crypto/sha256.lua',
  'lib/crypto/sha512.lua',
  'lib/crypto/field25519.lua',
  'lib/crypto/x25519.lua',
  'lib/crypto/ed25519.lua',
  'lib/crypto/drbg.lua',
  'lib/crypto/keccak.lua',
  'lib/crypto/mlkem768.lua',
  'lib/ssh/wire.lua',
  'lib/ssh/msg.lua',
  'lib/ssh/base64.lua',
  'lib/ssh/keys.lua',
  'lib/ssh/packet.lua',
  'lib/ssh/kex.lua',
  'lib/ssh/server.lua',
  'lib/dhcp.lua',
  'task/dhcpd.lua',
  # the ipv4 stack. On the efi image because that platform now drives
  # the nic directly through EFI_SIMPLE_NETWORK_PROTOCOL (src/platform/
  # efi/snp.c) instead of the firmware's EFI_TCP4/EFI_UDP4 -- so these
  # are the stack on both platforms rather than microvm's alone, and
  # this list mirrors the microvm embed_files above.
  'lib/ether.lua',
  'lib/ethwire.lua',
  'lib/ip4.lua',
  'lib/arp.lua',
  'lib/icmp.lua',
  'lib/udp4.lua',
  'lib/inet.lua',
  'lib/tcp4.lua',
  'lib/tcb.lua',
  'task/ip.lua',
  'task/tcp4.lua',
  'lib/dns.lua',
  'task/dns.lua',
  'lib/espfs.lua',
  'task/espsrv.lua',
  'task/fb.lua',
  'lib/http.lua',
  'task/idle.lua',
  'lib/json.lua',
  'lib/log.lua',
  'lib/mcp.lua',
  'lib/mnt.lua',
  'lib/ninep.lua',
  'lib/ns.lua',
  'lib/nsio.lua',
  'lib/srv.lua',
  'lib/stdout.lua',
  'lib/svc.lua',
  'lib/dos.lua',
  'task/power.lua',
  'lib/p9fs.lua',
  'lib/p9tcp.lua',
  'task/p9srv.lua',
  'lib/proc.lua',
  'lib/procfs.lua',
  'lib/prog.lua',
  'lib/ps.lua',
  'task/eth.lua',
  'lib/srvc.lua',
  'task/srvd.lua',
  'lib/srvfs.lua',
  'lib/tap.lua',
  'lib/thread.lua',
  'lib/webterm.lua',
  'task/wire.lua',
  'lib/zmodem.lua',
)

# a prebuilt gefs volume with one file, for the disk's second partition.
# Its size is the partition's size (mkimage reads it), so it is picked
# here rather than fixed in two places.
gefs_img = custom_target('gefs.img',
  output: 'gefs.img',
  command: [lua_interp, files('tools/mkgefs.lua'), '@OUTPUT@'],
)

# gpt disk: an esp, and a gefs partition after it holding gefs_img.
# Assembled with sfdisk + mtools + dd, no root. $GEFS_IMG is what makes
# mkimage add the second partition.
luaos_img = custom_target('luaos.img',
  input: [luaos_efi] + lua_payload,
  output: 'luaos.img',
  command: [lua_interp, files('tools/mkimage.lua'), '@OUTPUT@', '@INPUT@'],
  env: {'BOOT_EFI': boot_efi, 'GEFS_IMG': gefs_img.full_path()},
  depends: gefs_img,
  build_by_default: true,
)

# every script that boots the image needs to know which machine it is
# booting, and must not guess: with a cross build the host arch is the
# wrong answer. tools/arch.lua and test/qemuarch.lua both fall back
# to uname when this is unset, which is what a bare `qemu.lua img` gets.
archenv = {
  'LUAOS_ARCH': arch,
  # where tools/gefs.lua finds gefs.so; see its note. Without it the
  # tools only work from inside a build directory.
  'LUAOS_BUILD': meson.current_build_dir(),
}

# console on stdio, 9p wire on <builddir>/9p.sock
# mount from host: 9p -a 'unix!<builddir>/9p.sock' ls /
run_target('qemu',
  command: [lua_interp, files('tools/qemu.lua'), luaos_img],
  env: archenv,
)

# the same interactive run, plus a window to see the framebuffer in.
# the console stays on stdio, so you type at the dos prompt in this
# terminal and watch the screen next to it -- which is what running a
# graphical program from the shell needs. LUAOS_DISPLAY picks a backend
# if the default (gtk, then sdl) is not what you want.
run_target('qemu-gtk',
  command: [lua_interp, files('tools/qemu.lua'), luaos_img, 'gtk'],
  env: archenv,
)

# boots test/boot/fetch_mcp.lua instead of init.lua (single-url mcp
# fetch server), mcp reachable on host tcp/8090
run_target('fetch-mcp',
  command: [lua_interp, files('tools/fetch-mcp.lua'), luaos_img],
  env: archenv,
)

# boots test/boot/fbdraw.lua, waits for it to say it has finished
# drawing, and captures the screen to <builddir>/screenshot.png. the
# framebuffer is the one output here no serial line can carry, so this
# is how you look at it -- test/boot/test_fb.lua proves the pixels are
# what we asked for, which is a different claim from what a person
# sitting in front of the machine would see.
run_target('screenshot',
  command: [lua_interp, files('tools/screenshot.lua'), luaos_img,
    files('test/boot/fbdraw.lua'), 'screenshot.ppm'],
  env: archenv,
)

# the same framebuffer, in a window on your desktop instead of a png:
# boots test/boot/fbsmiley.lua and leaves qemu up to look at. needs a
# DISPLAY or WAYLAND_DISPLAY; on a headless box use screenshot above.
run_target('smiley',
  command: [lua_interp, files('tools/smiley.lua'), luaos_img,
    files('test/boot/fbsmiley.lua')],
  env: archenv,
)

# boots test/boot/srvweb.lua instead of init.lua: the browser shell,
# reachable at http://localhost:8080/ (WEB_PORT to change it)
run_target('website',
  command: [lua_interp, files('tools/website.lua'), luaos_img],
  env: archenv,
)

# ---- tests ----
# boot tests: the payload is injected via fw_cfg and replaces
# /init.lua; the guest emits TAP on com1 and powers off. the harness
# extracts the TAP for meson.

# test()'s program argument must be a single executable (not an argv
# list the way run_target/custom_target's command: can be), so this
# one relies on the shebang line + the execute bit, unlike every other
# tools/*.lua invocation in this file.
boottest = files('tools/boottest.lua')

boot_tests = ['spawnarg', 'nsio', 'escape', 'stdout', 'channel', 'proc', 'recovery', 'ipc', 'budget', 'memlimit',
              'math',
              'srv', 'mountcmd', 'sendwait', 'drivers', 'sched', 'json', 'timer', 'pingpong', 'readdir', 'magic', 'dev', 'ns', 'prog', 'hangup',
              'procfs', 'mnt', 'readonly', 'session', 'runq', 'ninep_selfmount', 'p9stream', 'p9flush', 'chanstress', 'torture', 'generator', 'sync', 'readline', 'mntconc',
              'ports',
              'font', 'fb', 'fbprog', 'fbcons',
              'nohook', 'preempt', 'idle', 'stack', 'broke', 'kill', 'trace', 'wakeup', 'nesting', 'rng', 'sshcrypto', 'mlkem', 'sshmem', 'layout',
              'strictglobals', 'efigefs', 'nsfs', 'vi', 'zmodem']
foreach t : boot_tests
  test('boot-' + t, boottest,
    args: [luaos_img, files('test/boot/test_' + t + '.lua')],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
    env: archenv,
  )
endforeach

foreach t : shared_tests
  if not t[2]
    test('boot-' + t[0], boottest,
      args: [luaos_img, files('test/boot/shared_' + t[0] + '.lua')],
      protocol: 'tap',
      timeout: 90,
      is_parallel: true,
      env: archenv,
    )
  endif
endforeach

hostenv = archenv
if have_hostutil
  hostenv = archenv + {'HOSTUTIL_SO': hostutil.full_path()}
endif

# does the firmware ship a network stack? this gates the net tests, and
# it dates from when ours was a binding over the firmware's own
# EFI_TCP4/EFI_UDP4. We drive the card through SNP now, which the stock
# riscv64 blob does publish, so the per-arch default below may be more
# conservative than it needs to be -- untested. see meson.options.
fw_network = get_option('fw_network')
if fw_network.auto()
  fw_network = arch != 'riscv64'
else
  fw_network = fw_network.enabled()
endif

if fw_network
  # net boot tests: same harness, but NET=1 gives the guest a real NIC
  # on qemu's usermode network. separated because dhcp costs real boot
  # seconds that the tests above have no reason to pay.
  foreach t : ['netboot', 'dns', 'dhcp', 'efiprobe']
    test('boot-' + t, boottest,
      args: [luaos_img, files('test/boot/test_' + t + '.lua')],
      protocol: 'tap',
      timeout: 120,
      is_parallel: true,
      env: archenv + {'NET': '1'},
    )
  endforeach

  foreach t : shared_tests
    if t[2]
      test('boot-' + t[0], boottest,
        args: [luaos_img, files('test/boot/shared_' + t[0] + '.lua')],
        protocol: 'tap',
        timeout: 120,
        is_parallel: true,
        env: archenv + {'NET': '1'},
      )
    endif
  endforeach

  if have_hostutil
    # host-driven http test: the guest serves on tcp/7777, forwarded to
    # a host port, driven with real HTTP/1.1. the only end-to-end cover
    # for tcp listen/accept/recv/send -- the guest can't test this
    # itself, since qemu's usermode network doesn't hairpin.
    test('http-server', lua_interp,
      args: [files('test/test_http.lua'), luaos_img, files('test/boot/srvhttp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )

    # host-driven web terminal test: drives the browser shell as its
    # own javascript would. the only cover for the full chain -- http
    # -> session port -> a spawned unprivileged dos proc -> its
    # namespace.
    test('web-terminal', lua_interp,
      args: [files('test/test_web.lua'), luaos_img, files('test/boot/srvweb.lua')],
      protocol: 'tap',
      timeout: 180,
      env: hostenv,
    )

    # host-driven mcp test: real JSON-RPC 2.0 over HTTP POST against
    # the guest. covers tcp + http + json + mcp composed together.
    test('mcp-server', lua_interp,
      args: [files('test/test_mcp.lua'), luaos_img, files('test/boot/srvmcp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )
  endif
else
  warning('firmware is built without NetworkPkg: skipping the net tests. ' +
          '-Dfw_network=enabled to try them anyway.')
endif

# ---- benchmarks ----
# not run by `meson test`; run with `meson test --benchmark` or
# `ninja benchmark`. meson runs benchmarks serially rather than in
# parallel, which is what makes the numbers worth reading.
benchmark('fb', boottest,
  args: [luaos_img, files('test/bench_fb.lua')],
  protocol: 'tap',
  timeout: 120,
  env: archenv,
)

benchmark('ipc', boottest,
  args: [luaos_img, files('test/bench_ipc.lua')],
  protocol: 'tap',
  timeout: 180,
  env: archenv + {'TIMEOUT': '150'},
)

# host-driven 9p protocol test: real 9P2000 over the com2 socket
if have_hostutil
  test('9p-protocol', lua_interp,
    args: [files('test/test_9p.lua'), luaos_img, files('test/boot/srv9p.lua')],
    protocol: 'tap',
    timeout: 90,
    env: hostenv,
    depends: hostutil,
  )
endif

endif # platform == 'efi'

if platform == 'microvm'

# the microvm tests, which are the efi boot tests' counterpart: payload
# injected via fw_cfg, TAP on com1, guest ends itself. They register
# only for this platform because a build is configured for one or the
# other, so `meson test` runs whichever suite the build can actually
# produce a guest for.
#
# see the note on `boottest` above for why this is passed as a program
# rather than an argv list.
microvm_boottest = files('tools/boottest-microvm.lua')

# every guest gets a virtio-rng. --9p additionally serves a seeded
# temporary directory over virtio-9p; only the mount test wants one,
# and it wants a private directory since it creates a file.
microvm_tests = [
  ['hello', []],
  ['rng', []],
  ['p9mount', ['--9p']],
  ['p9bench', ['--9p']],
  ['p9par', ['--9p']],
  ['blk', ['--blk']],
  ['gefs', ['--gefscommit']],
  ['gefssrv', ['--gefscommit']],
  ['gefsshutdown', ['--gefscommit']],
  ['gefsgpt', ['--gefsgpt']],
  ['gefspart', ['--gefsgpt']],
  ['eth', ['--net']],
  ['arp', ['--net']],
  ['ping', ['--net']],
  ['dhcp', ['--net']],
  ['dns', ['--net']],
  ['iptask', ['--net']],
  ['udpq', ['--net']],
  ['loopback', ['--net']],
  ['udpbench', ['--net']],
  ['autoip', ['--net']],
  ['ipraw', ['--net']],
  ['tcp', ['--netecho']],
  ['tcpbench', ['--net']],
  ['idle', []],
]

foreach t : microvm_tests
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] + t[1],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

foreach t : shared_tests
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/shared_' + t[0] + '.lua')] + t[1],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

# the same guest on a q35, where the devices are virtio-pci behind PCIe
# root ports rather than virtio-mmio in a fixed window. That is the
# machine systemd-vmspawn builds and the shape real hardware has, and it
# exercises what mmio never touches: the bridge walk, memory BARs, and
# MSI-X (src/platform/microvm/pci.c, virtio_pci.c).
#
# One test per device class rather than the whole list. What differs
# between the transports is discovery and interrupt delivery, which any
# one test of a device establishes; everything above the ring is the
# same code either way and is already covered above.
microvm_pci_tests = [
  ['hello', []],
  ['rng', []],
  ['blk', ['--blk']],
  ['p9mount', ['--9p']],
  ['eth', ['--net']],
  ['ping', ['--net']],
  ['tcp', ['--netecho']],
]

# and the same devices on the root bus, where they are transitional:
# other PCI ids, other BARs, no bridge. rng is what systemd-vmspawn
# itself attaches that way, and blk is the one whose transitional id
# (0x1001) is furthest from the formula a reader would guess.
microvm_pci0_tests = [
  ['rng', []],
  ['blk', ['--blk']],
]

foreach t : microvm_pci0_tests
  test('pci0-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] +
      t[1] + ['--pci0'],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

foreach t : microvm_pci_tests
  test('pci-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] +
      t[1] + ['--pci'],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

# http over the lua tcp stack, host-driven for the reason its own header
# gives: a guest cannot reach its own listener (slirp does not hairpin),
# so hostfwd gives the host a door in and hostutil walks through it. This
# is the test listen and accept exist for -- the guest runs lib/http.lua
# and lib/caps.lua unmodified, and the client is a separate
# implementation on the host.
if have_hostutil
  test('microvm-http', lua_interp,
    args: [files('test/microvm_http.lua'), luaos_microvm_elf,
      files('test/boot/microvm_httpd.lua')],
    protocol: 'tap',
    timeout: 90,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

# bulk transfer, with the host as the server. No forwarding needed in
# this direction: qemu proxies a guest's connection to 10.0.2.2 onto the
# host's loopback, which is where test/hostserver.lua binds. Several
# megabytes each way is thousands of segments, a receive window that
# closes and reopens continuously, and a send buffer that fills -- none
# of which a five-byte echo reaches.
if have_hostutil
  test('microvm-bulk', lua_interp,
    args: [files('test/microvm_bulk.lua'), luaos_microvm_elf,
      files('test/boot/microvm_bulk.lua')],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

# serial receive needs the port in BOTH directions, which the boottest
# harness cannot do -- it points the guest's serial at a file. This one
# drives a unix socket instead, so it is host-driven like the efi
# platform's 9p test and needs hostutil for the same reason.
# the no-fw_cfg path: nothing injected, so the guest runs the console
# repl embedded in its own image, and this types at it. Needs the port
# in both directions, so it is here with the other socket-driven test
# rather than in the boottest loop. Tested under qemu because that is
# where a test can run; it exists for vmd, which has no other way in.
if have_hostutil
  test('microvm-embedded-boot', lua_interp,
    args: [files('test/microvm_repl.lua'), luaos_microvm_elf],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

if have_hostutil
  test('microvm-serialrx', lua_interp,
    args: [files('test/microvm_serial.lua'), luaos_microvm_elf,
      files('test/boot/microvm_serialrx.lua')],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

endif # platform == 'microvm'

# ---- host-native tests ----
# src/luaheap.c is the per-lua_State allocator. It has no firmware and
# no kernel in it -- the chunk source is a pair of function pointers --
# so it is built and tested natively, on whichever host is driving the
# build, regardless of -Dplatform or any cross file. These register for
# both platforms because neither one is involved.

luaheap_test = executable('luaheap_test',
  ['test/luaheap_test.c', 'src/luaheap.c'],
  include_directories: include_directories('src'),
  native: true,
)
test('luaheap', luaheap_test, protocol: 'tap', timeout: 120)

# src/lock.h is the other file that can only be tested where there is
# more than one cpu, which the target never has enough of and the host
# always does. Built native, with NCPU forced past 1 so the real ticket
# lock compiles rather than the uniprocessor barrier, and against the
# host's own src/<arch>/machine.h for machine_relax.
host_arch = build_machine.cpu_family()
if host_arch in ['x86_64', 'aarch64', 'riscv64']
  thread_dep = dependency('threads', native: true)
  lock_test = executable('lock_test',
    ['test/lock_test.c'],
    include_directories: include_directories('src', 'src' / host_arch),
    c_args: ['-DNCPU=8'],
    dependencies: thread_dep,
    native: true,
  )
  test('lock', lock_test, protocol: 'tap', timeout: 120)
endif

# the bench needs a real lua to allocate through, which is the host's
# rather than the freestanding one this build produces.
luaheap_lua_dep = dependency('lua5.4', native: true, required: false)
if luaheap_lua_dep.found()
  luaheap_bench = executable('luaheap_bench',
    ['test/luaheap_bench.c', 'src/luaheap.c'],
    include_directories: include_directories('src'),
    dependencies: luaheap_lua_dep,
    native: true,
  )
  test('luaheap-bench', luaheap_bench, protocol: 'tap', timeout: 120)
endif

# lib/tcp4.lua is the TCP codec -- sequence arithmetic, the header and
# its options -- with no state and no I/O in it, so like luaheap it can
# be tested by the host's own lua without booting anything. That is new
# for a lua module here, and it earns its place on TCP specifically: the
# cases most likely to be wrong are the ones no real peer will produce
# on request, such as a sequence number that laps the space or an option
# whose length cannot advance the parser.
#
# It does not stand in for a boot test. It says the codec is right; only
# test/boot can say anything is wired to anything.
test('tcp4-codec', lua_interp,
  args: [files('test/host_tcp4.lua')],
  protocol: 'tap',
  timeout: 20,
)

# lib/tcb.lua is one connection's state machine, and sans-io for the
# same reason: it takes segments as tables and hands them back, so two
# of them can be wired to each other here and driven through a handshake
# with no network involved. Two agreeing with each other proves only
# that they are consistent -- they share every misreading of the RFC --
# which is what the boot tests against a real peer are for. What this
# reaches instead is everything a real peer will not do on request: a
# simultaneous open, a reset acknowledging nothing, an acknowledgment of
# a segment never sent, a SYN arriving inside an open connection.
# lib/zmodem.lua is sans-io in the same way tcb.lua is: the line is a
# pair of buffers, so a sender and a receiver can be wired to each other
# here with no port, no wire and no clock. What that buys is the cases a
# real link will not perform on request -- a byte corrupted at a chosen
# offset, a peer that stops answering, a cancel -- plus the crc check
# vectors, which is what pins the framing to zmodem.h rather than to our
# own agreement with ourselves. test/boot/test_zmodem.lua runs the same
# code between two procs over real ports.
test('zmodem-protocol', lua_interp,
  args: [files('test/host_zmodem.lua')],
  protocol: 'tap',
  timeout: 60,
)

# and against lrzsz, where there is one on the host. This is the only
# test with a peer that has never seen our code -- everything else wires
# our sender to our receiver, which proves the two agree and not that
# either is right. It earned its place immediately: ESCCTL turned out to
# be a promise about what you send rather than a preference about what
# you accept, and a peer in that mode silently discards the control
# characters you leave raw.
#
# Optional on purpose. Nothing in the guest depends on lrzsz, and socat
# is here only because lrzsz wants its stdio on a pipe pair while
# hostutil hands out sockets.
sz_prog = find_program('lsz', 'sz', required: false)
rz_prog = find_program('lrz', 'rz', required: false)
socat_prog = find_program('socat', required: false)

if have_hostutil and sz_prog.found() and rz_prog.found() and socat_prog.found()
  test('zmodem-lrzsz', lua_interp,
    args: [files('test/host_lrzsz.lua')],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

test('tcb-statemachine', lua_interp,
  args: [files('test/host_tcb.lua')],
  protocol: 'tap',
  timeout: 20,
)

# the same state machine over a link that loses, reorders, duplicates
# and delays. Every network this has ever been run against is perfect --
# slirp, the LAN across 167,000 segments, and vmd all dropped nothing --
# so its loss recovery had never once executed in a test. Congestion
# control makes that worse rather than better, being entirely loss
# recovery: slow start and fast retransmit are dead code on a perfect
# link.
#
# Deterministic, because "drop the third data segment" is debuggable
# where "5% loss" fails once a fortnight. And free: because the TCBs take
# time as an argument, two minutes of simulated network costs five
# milliseconds of wall clock.
test('tcb-lossy', lua_interp,
  args: [files('test/host_tcbloss.lua')],
  protocol: 'tap',
  timeout: 20,
)

# lib/gefs is a port of 9front's Bε-tree filesystem, and it is sans-io in
# the same way tcb.lua is: a volume is opened on a device -- any table
# answering read/write/size -- so gefs.ram drives it in memory and
# gefs.io over a real file, with no kernel underneath. That is the whole
# of it that can be tested here, and it is most of it: that the port
# loads and runs, that lib/gefs/io.lua is a working device, and that a
# commit cut anywhere leaves the disk whole -- proven both at block
# granularity and mid-block through a coroutine that yields inside a
# write and is abandoned. What this cannot say is that a served volume is
# wired to the block driver, which is test/boot/microvm_gefs.lua's job.

# src/gefs_native.c built for the host, so the host test exercises the
# SAME hash the guest does rather than a second implementation that
# merely agrees with it. lib/gefs/hash.lua has no fallback any more.
#
# Named `gefs` rather than `gefs/native` because lua's last searcher
# takes a.b to a.so and calls luaopen_a_b -- so gefs.so answers
# require("gefs.native") through luaopen_gefs_native, with no build
# subdirectory to arrange. require("gefs") itself still finds
# lib/gefs/init.lua, because the lua-path searcher runs before this one.
#
# LUA_CPATH is appended rather than set, so a caller's own is kept.
gefs_host_env = environment()
if lua54_dep.found()
  gefs_native_host = shared_module('gefs',
    ['src/gefs_native.c'],
    name_prefix: '',
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  gefs_host_env.append('LUA_CPATH',
    meson.current_build_dir() / '?.so', separator: ';')
endif

test('gefs-host', lua_interp,
  args: [files('test/host_gefs.lua')],
  protocol: 'tap',
  timeout: 120,
  env: gefs_host_env,
)

# lib/fat is the filesystem the esp32 flash partition and the microSD
# card both carry, and lib/fatfs.lua is what puts it behind a mount. The
# format itself has its own suite upstream; this covers the part that
# only exists here -- that the port loads under our loader, and that the
# dev backend over it reads, writes and lists what it should. What this
# cannot say is that a served volume is wired to the flash driver, which
# is the boot test's job.
test('fat-host', lua_interp,
  args: [files('test/host_fat.lua')],
  protocol: 'tap',
  timeout: 60,
)

# lib/p9serve.lua is the 9P server over a dev backend -- the bridge
# task/9pexport.lua serves gefs (and any other backend) to a real 9p
# client with. Pure Lua over lib/ninep's codec, so the host drives it
# with crafted 9P messages against a gefs volume; the live wire is a boot
# test's concern, this pins the message mapping.
test('p9serve-host', lua_interp,
  args: [files('test/host_p9serve.lua')],
  protocol: 'tap',
  timeout: 30,
)
