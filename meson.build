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
  if platform == 'microvm'
    # the only configuration with more than one cpu; everything else
    # takes lock.h's uniprocessor path.
    arch_args += '-DNCPU=8'
  endif
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
      'src/platform/microvm/smp.c',
      'src/platform/microvm/smp_trampoline.S',
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
    # tls, and the closure it pulls in. This machine has no disk, so a
    # guest that is to reach an https server has to carry the whole
    # stack in the image -- and being able to is what makes microvm the
    # quick way to work on anything that talks to the network.
    'lib/tlstcp.lua',
    'lib/tls/client.lua',
    'lib/tls/conn.lua',
    'lib/tls/hello.lua',
    'lib/tls/keys.lua',
    'lib/tls/record.lua',
    'lib/tls/server.lua',
    'lib/tls/tofu.lua',
    'lib/tls/wire.lua',
    'lib/x509/cert.lua',
    'lib/x509/der.lua',
    # named only through a table in tls/tofu.lua, so a dependency
    # scan does not see them: the signature algorithm picks one.
    'lib/crypto/sha384.lua',
    'lib/crypto/aead.lua',
    'lib/crypto/bignum.lua',
    'lib/crypto/ed25519.lua',
    'lib/crypto/field25519.lua',
    'lib/crypto/hkdf.lua',
    'lib/crypto/hmac.lua',
    'lib/crypto/p256.lua',
    'lib/crypto/rsa.lua',
    'lib/crypto/sha512.lua',
    'lib/crypto/util.lua',
    'lib/crypto/x25519.lua',
    'lib/json.lua',
    'lib/llm.lua',
    'lib/agent.lua',
    # a couple of programs, so the spawn path has something to run:
    # this machine has no disk, so /bin exists only if the image says.
    'lib/prog.lua',
    'lib/client/tty.lua',
    'lib/client/power.lua',
    'lib/client/udp.lua',
    'lib/draw.lua',
    'lib/mouse.lua',
    'lib/time.lua',
    'bin/ls.lua',
    'bin/cat.lua',
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
    # ns:adopt reaches nsio, and lib/proc.lua's bootstrap is what calls
    # adopt. Without both, no proc on this platform can take a namespace
    # it was handed -- which is how every service task gets one.
    'lib/nsio.lua',
    'lib/proc.lua',
    'lib/lazy.lua',
    'lib/devtree.lua',
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
    # lib/fat: the flash filesystem, frozen in so a boot test can mount
    # a FAT volume over the block device.
    'lib/fat.lua',
    'lib/fat/obj.lua',
    'lib/fat/dat.lua',
    'lib/fat/pack.lua',
    'lib/fat/vol.lua',
    'lib/fat/blk.lua',
    'lib/fat/fat.lua',
    'lib/fat/dir.lua',
    'lib/fat/fsops.lua',
    'lib/fat/check.lua',
    'lib/fatfs.lua',
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
    'lib/time.lua',
    'lib/dns.lua',
    'lib/dnsc.lua',
    'lib/client/rpc.lua',
    'lib/client/tcp.lua',
    'lib/client/udp.lua',
    'lib/draw.lua',
    'lib/client/dns.lua',
    'lib/client/tty.lua',
    'lib/client/power.lua',
    'lib/client/wire.lua',
    'lib/client/rpc.lua',
    'lib/http.lua',
    'lib/crypto/chacha20.lua',
    'lib/crypto/poly1305.lua',
    'lib/crypto/hashstate.lua',
    'lib/crypto/sha256.lua',
    # what task/tcp4.lua draws an initial sequence number from when it
    # is started as a service: a service holds no raw rng, so lib/svc.lua
    # hands it a seed and it expands that here.
    'lib/crypto/drbg.lua',
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
    # what init.lua needs before it has mounted anything. romfs is the
    # root on a machine with no disk, and is what makes the embedded
    # files above reachable by path rather than by require alone.
    'lib/romfs.lua',
    'lib/procfs.lua',
    'lib/svc.lua',
    'lib/svcarg.lua',
    'lib/dnsc.lua',
    'task/dns.lua',
  ]
  embed_args = ['/boot/microvm.lua=' +
      (boot_payload.startswith('/') ? boot_payload
       : meson.current_source_dir() / boot_payload),
    # the machine picks its own list, installed under the one name the
    # payload reads -- the same arrangement the efi and esp32 builds use.
    '/etc/services.lua=' + meson.current_source_dir() /
        'machine/microvm/services.lua']
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
  # trap rather than call a runtime, which is what makes a sanitizer
  # usable here at all: there is no libc to link one from. On its own
  # this flag does nothing -- it says how to report, not what to check
  # -- so it sat here inert until -Dubsan turned a checker on.
  '-fsanitize-trap=all',
]
  if cc.has_argument(a)
    hardening_args += a
  endif
endforeach

# see meson.options: off by default because it costs up to 1.9x on the
# serializer, so a build measuring anything wants it off.
if get_option('ubsan')
  if cc.has_argument('-fsanitize=undefined')
    hardening_args += '-fsanitize=undefined'
  else
    error('-Dubsan=true but the compiler has no -fsanitize=undefined')
  endif
endif

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

# lrzsz and socat, for the zmodem tests on both platforms. Optional on
# purpose: nothing in the guest depends on either, and socat is here
# only because lrzsz wants its stdio on a pipe pair while hostutil hands
# out sockets.
sz_prog = find_program('lsz', 'sz', required: false)
rz_prog = find_program('lrz', 'rz', required: false)
socat_prog = find_program('socat', required: false)
# BlueZ's virtual controller, for the HCI tests. Rarely on PATH: it is
# a noinst program, built only with ./configure --enable-testing, so
# -Dbtvirt=/path/to/emulator/btvirt is the usual way to name it. Absent,
# the codec still runs and only the exchanges with a controller are lost.
btvirt_prog = find_program(get_option('btvirt'), 'btvirt', required: false)
btmon_prog = find_program('btmon', required: false)
sshd_prog = find_program('sshd', required: false,
  dirs: ['/usr/sbin', '/usr/bin', '/sbin'])
sshkeygen_prog = find_program('ssh-keygen', required: false)
ssh_prog = find_program('ssh', required: false)
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

# src/buf.c is los.buf, which lib/ files use for anything with bytes in
# it. The host tests run those files under the host's own lua5.4, so it
# has to exist there too: the same source, built against test/hostbuf.c
# for the two things it wants from the kernel. One implementation, and
# test/boot/test_buf.lua covers it on the other side.
#
# Named los.so for the same reason gefs.so is: the C-path searcher takes
# a.b to a.so and calls luaopen_a_b, so require("los.buf") finds
# luaopen_los_buf with no build subdirectory to arrange.
#
# host_deps travels with host_env and must be passed as `depends:` by
# every test using it. `meson test` builds only what the selected tests
# declare, not `all`, so build_by_default is no help when a test names a
# subset: the module is simply absent and the test fails as a missing
# lua module. It looked like it worked because the default LUA_CPATH
# ends in ./?.so and the test's cwd is the build directory, so a stale
# copy from an earlier full build was found by accident.
host_env = environment()
host_deps = []
if lua54_dep.found()
  buf_native_host = shared_module('los',
    ['src/buf.c', 'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_env.append('LUA_CPATH',
    meson.current_build_dir() / '?.so', separator: ';')
  host_deps += buf_native_host

  # the same primitives the guest preloads, so lib/crypto and what sits
  # on it can be tested here rather than only on a board.
  crypto_native_host = shared_module('crypto',
    ['src/native_glue.c', 'test/hostcrypto.c', 'src/buf.c',
     'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_deps += crypto_native_host
endif

# src/gefs_native.c built for the host, so the host test exercises the
# same hash the guest does rather than a second implementation that
# merely agrees with it. lib/gefs/hash.lua has no fallback.
#
# Named `gefs` rather than `gefs/native` because lua's last searcher
# takes a.b to a.so and calls luaopen_a_b -- so gefs.so answers
# require("gefs.native") through luaopen_gefs_native, with no build
# subdirectory to arrange. require("gefs") itself still finds
# lib/gefs/init.lua, because the lua-path searcher runs before this one.
#
# Up here, above every platform's own section: the gefs-host test runs
# on all of them, and the efi image's gefs.img is built by running lua
# against this module.
#
# LUA_CPATH is appended rather than set, so a caller's own is kept, and
# unconditionally as well as inside the branch: the gefs host test also
# loads los.buf, which is built beside this and by the same test for
# lua5.4's headers.
#
# gefs_host_deps carries both modules, since anything reaching lib/gefs
# also reaches los.buf. See the note at host_deps for why `depends:` is
# required rather than merely tidy.
gefs_host_env = environment()
gefs_host_deps = []
gefs_host_env.append('LUA_CPATH',
  meson.current_build_dir() / '?.so', separator: ';')
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
  gefs_host_deps += [gefs_native_host, buf_native_host]
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
  'bin/reboot.lua',
  'bin/top.lua',
  'bin/xd.lua',
  # the two halves of a ZMODEM transfer over the console. Named rz and
  # sz because those are the words each end types at the other before
  # its first header, so a launcher with them in /bin completes a
  # transfer the user only started at their terminal.
  'bin/rz.lua',
  'bin/sz.lua',
  # a lua prompt as a program: the boot console is one, and a dos, ssh
  # or panel shell had no way to reach one.
  'bin/lua.lua',
  'bin/host.lua',
  'bin/date.lua',
  'lib/ntp.lua',
  'lib/time.lua',
  # the irc protocol. On the image ahead of any client for it, so a
  # session can drive it from the repl -- which is how the client is
  # debugged before there is a client.
  'lib/irc.lua',
  'lib/resolv.lua',
  'bin/irc.lua',
  'bin/stack.lua',
  'bin/trace.lua',
  # the debugger. lib/ only here and not in embed_files: nothing before
  # a mount needs it, and the microvm gets /bin off the 9p mount.
  'lib/dbg.lua',
  'bin/dbg.lua',
  'bin/ls.lua',
  'bin/seq.lua',
  'bin/smiley.lua',
  'bin/clock.lua',
  # the window system. Not started here -- platform_have_ptr is 0 on
  # efi, so no machine boots into it -- but present so a test can hand
  # dio ports of its own and drive the tray under qemu. Injecting a
  # touch needs nothing special: the pointer is a port, and a synthetic
  # record is an ordinary send to it.
  'task/dio.lua',
  'etc/dio.lua',
  'bin/dio.lua',
  'lib/mouse.lua',
  'task/fbterm.lua',
  'lib/fbsh.lua',
  'bin/scribble.lua',
  # vi, and its ed/ engine and terminal (lib/ed/*). a full-screen program
  # over the tty capability -- see lib/prog.lua and lib/caps.lua.
  'bin/vi.lua',
  'lib/ed/buffer.lua',
  'lib/ed/terminfo.lua',
  'lib/client/rpc.lua',
  'lib/client/tcp.lua',
  'lib/client/udp.lua',
  'lib/draw.lua',
  'lib/client/dns.lua',
  'lib/client/tty.lua',
  'lib/client/power.lua',
  'lib/client/wire.lua',
  'lib/client/rpc.lua',
  'task/cons.lua',
  'lib/console.lua',
  'lib/fbcons.lua',
  'lib/lazy.lua',
  'lib/devtree.lua',
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
  'lib/memdraw.lua',
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
  'lib/crypto/sha384.lua',
  'lib/crypto/hmac.lua',
  'lib/crypto/hkdf.lua',
  'lib/crypto/aead.lua',
  'lib/crypto/bignum.lua',
  'lib/crypto/p256.lua',
  'lib/crypto/rsa.lua',
  'lib/ssh/wire.lua',
  'lib/ssh/msg.lua',
  'lib/ssh/base64.lua',
  'lib/ssh/keys.lua',
  'lib/ssh/packet.lua',
  'lib/ssh/kex.lua',
  'lib/ssh/server.lua',
  'lib/ssh/client.lua',
  # the client half as a program. Named ssh because that is what it is,
  # and it reaches a machine from a shell here rather than the reverse.
  'bin/ssh.lua',
  'bin/keygen.lua',
  # tls 1.3 over the stack below, and the certificate parsing that says
  # who the peer is. Sans-io, like lib/ssh: the caller owns the socket.
  'lib/tls/wire.lua',
  'lib/tls/hello.lua',
  'lib/tls/keys.lua',
  'lib/tls/record.lua',
  'lib/tls/server.lua',
  'lib/tls/client.lua',
  'lib/tls/conn.lua',
  'lib/tls/tofu.lua',
  'lib/x509/der.lua',
  'lib/x509/cert.lua',
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
  'task/timed.lua',
  'lib/espfs.lua',
  'task/espsrv.lua',
  'task/fb.lua',
  'lib/http.lua',
  'lib/tlstcp.lua',
  'lib/tls/client.lua',
  'lib/tls/conn.lua',
  'lib/tls/hello.lua',
  'lib/tls/keys.lua',
  'lib/tls/record.lua',
  'lib/tls/server.lua',
  'lib/tls/tofu.lua',
  'lib/tls/wire.lua',
  'lib/x509/cert.lua',
  'lib/x509/der.lua',
  'lib/llm.lua',
  'lib/agent.lua',
  'task/idle.lua',
  'lib/json.lua',
  'lib/mcp.lua',
  'lib/mnt.lua',
  'lib/ninep.lua',
  'lib/ns.lua',
  'lib/nsio.lua',
  'lib/srv.lua',
  'lib/stdout.lua',
  'lib/svc.lua',
  'lib/svcarg.lua',
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
  'bin/dmesg.lua',
  'lib/tap.lua',
  'lib/webterm.lua',
  'task/wire.lua',
  'lib/zmodem.lua',
)

# a prebuilt gefs volume with one file, for the disk's second partition.
# Its size is the partition's size (mkimage reads it), so it is picked
# here rather than fixed in two places.
#
# tools/mkgefs.lua reaches gefs.so through require("gefs.native"), which
# resolves against the build directory it runs in -- a runtime
# dependency ninja cannot see in the command line, so it is declared.
# Without it the two targets are unordered and the build fails whenever
# ninja reaches this one first.
gefs_img_deps = []
if lua54_dep.found()
  gefs_img_deps += gefs_native_host
endif

gefs_img = custom_target('gefs.img',
  output: 'gefs.img',
  command: [lua_interp, files('tools/mkgefs.lua'), '@OUTPUT@'],
  depends: gefs_img_deps,
)

# gpt disk: an esp, and a gefs partition after it holding gefs_img.
# Assembled with sfdisk + mtools + dd, no root. $GEFS_IMG is what makes
# mkimage add the second partition.
# which services list this machine gets. The path on the image is
# /etc/services.lua wherever it boots, so what a machine runs is a
# build decision rather than something the boot payload knows the name
# of -- see machine/ for the lists themselves.
machine_services = files('machine/efi/services.lua')

luaos_img = custom_target('luaos.img',
  input: [luaos_efi] + lua_payload,
  output: 'luaos.img',
  command: [lua_interp, files('tools/mkimage.lua'), '@OUTPUT@', '@INPUT@',
            '--install', machine_services, '/etc/services.lua'],
  depend_files: machine_services,
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

# the same, named for what it is now: a window plus a tablet, which is
# an absolute pointer, which is what makes the machine start dio -- so
# this is the tray and the apps, driven with a real mouse. The lua repl
# stays on stdio in this terminal.
run_target('qemu-gui',
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
              'procfs', 'buf', 'mnt', 'readonly', 'session', 'runq', 'ninep_selfmount', 'p9stream', 'p9flush', 'chanstress', 'torture', 'generator', 'sync', 'readline', 'mntconc',
              'ports',
              'font', 'fb', 'fbproxy', 'fbwin', 'fbprog', 'fbcons',
              'nohook', 'preempt', 'idle', 'stack', 'broke', 'kill', 'exit', 'sshkbd',
              'replyright', 'rightsundo', 'procpriv', 'portlimit', 'trace',
              'wakeup', 'nesting', 'rng', 'sshcrypto', 'mlkem', 'sshmem', 'tls',
              'layout', 'strictglobals', 'bufout', 'bufmove', 'serialize', 'mntshare', 'althup', 'dio', 'ninepc',
              'efigefs', 'reboot', 'nsfs', 'vi', 'zmodem', 'atexit',
              'history', 'top', 'xd', 'portq', 'intr', 'intrsh', 'intrread', 'sibwake', 'reclaim', 'lazy', 'strseed',
              'clock', 'log', 'dbg', 'dbgstop', 'dbgbreak', 'dbgstep',
              'dbgread', 'dbgcap', 'dbglib', 'dbghole']
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
  foreach t : ['netboot', 'dns', 'dhcp', 'efiprobe', 'host', 'date', 'irc']
    test('boot-' + t, boottest,
      args: [luaos_img, files('test/boot/test_' + t + '.lua')] + ['--services'],
      protocol: 'tap',
      timeout: 120,
      is_parallel: true,
      env: archenv + {'NET': '1'},
    )
  endforeach

  # our ssh client against a real OpenSSH server, which the harness runs
  # on a port of its own. The second implementation is the point: our
  # two halves agreeing with each other proves neither.
  #
  # It is also what covers a full-size frame arriving from outside. A
  # KEXINIT is over one segment, and a receive buffer a frame too small
  # drops exactly that and nothing smaller -- so every other test here
  # passed while ssh took two minutes.
  if sshd_prog.found() and sshkeygen_prog.found()
    test('net-sshclient', lua_interp,
      args: [files('tools/sshclienttest.lua'), luaos_img,
        files('test/boot/net_sshclient.lua')],
      protocol: 'tap',
      timeout: 120,
      env: archenv + {'NET': '1'},
    )
  endif

  foreach t : shared_tests
    if t[2]
      test('boot-' + t[0], boottest,
        args: [luaos_img, files('test/boot/shared_' + t[0] + '.lua')] + ['--services'],
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

    # task/sshd.lua, driven by a real ssh client: the session ends when
    # the shell does, and a command reports the status it exited on.
    # Nothing else covers the server half at all.
    if ssh_prog.found() and sshkeygen_prog.found()
      test('sshd-server', lua_interp,
        args: [files('test/test_sshd.lua'), luaos_img,
          files('test/boot/srvsshd.lua')],
        protocol: 'tap',
        timeout: 15,
        env: hostenv,
      )
    endif

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

benchmark('9p', boottest,
  args: [luaos_img, files('test/bench_9p.lua')],
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
  ['gefspar', ['--gefs']],
  ['gefsshutdown', ['--gefscommit']],
  ['gefsgpt', ['--gefsgpt']],
  ['gefspart', ['--gefsgpt']],
  ['fat', ['--fat']],
  ['eth', ['--net']],
  ['arp', ['--net']],
  ['ping', ['--net']],
  ['dhcp', ['--net']],
  ['netfiles', ['--net']],
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
  ['smp', ['--smp=2']],
  ['spin', []],
  ['pairs', []],
  ['claim', []],
  ['altpending', []],
  ['bigmsg', []],
  ['sample', []],
]

# The gefs entries build their disk image at test time, in the host's
# own lua, so the harness reaches lib/gefs and needs gefs.native. Named
# for every entry rather than only those: the cost is nothing for a test
# that does not load it, and a --gefs flag added to an entry later would
# otherwise fail as a missing lua module far from this list.
# payloads that reach the ip or tcp task, and so must run under a real
# init: those are services now. A raw-ethernet test is deliberately not
# here -- it wants the wire to itself, and the ip task would take frames
# from under it.
net_service_tests = ['dhcp', 'netfiles', 'dns', 'iptask', 'udpq',
  'loopback', 'udpbench', 'autoip', 'ipraw', 'tcp', 'tcpbench',
  'tcploop', 'fetch', 'httpd']

foreach t : microvm_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] +
      tflags,
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

# the same payloads on a machine with more than one cpu. This is where
# the scheduler, the ipc lock and the reschedule ipi are actually under
# contention rather than merely present: everything above runs them on
# one cpu, which exercises the ordering and none of the racing.
#
# Two shapes because they fail differently. Two cpus is the smallest
# machine where a wakeup can cross, and four is where a proc's home is
# usually not the sender's.
microvm_smp_tests = [
  ['hello', []],
  ['rng', []],
  ['idle', []],
  ['blk', ['--blk']],
  ['p9mount', ['--9p']],
  ['p9par', ['--9p']],
  ['eth', ['--net']],
  ['tcp', ['--netecho']],
  ['gefssrv', ['--gefscommit']],
  ['gefspar', ['--gefs']],
  ['spin', []],
  ['pairs', []],
  ['claim', []],
  ['altpending', []],
  ['bigmsg', []],
  ['sample', []],
  ['spawnrace', []],
  ['dbg', []],
]

foreach n : ['2', '4']
  foreach t : microvm_smp_tests
    tflags = t[1]
    if t[0] in net_service_tests
      tflags += ['--services']
    endif
    test('smp' + n + '-' + t[0], microvm_boottest,
      args: [luaos_microvm_elf,
        files('test/boot/microvm_' + t[0] + '.lua'),
        '--smp=' + n] + tflags,
      protocol: 'tap',
      timeout: 90,
      is_parallel: true,
      env: gefs_host_env,
      depends: gefs_host_deps,
    )
  endforeach
endforeach

foreach t : shared_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/shared_' + t[0] + '.lua')] + tflags,
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
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
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

foreach t : microvm_pci_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('pci-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] +
      tflags + ['--pci'],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

# http over the lua tcp stack, host-driven for the reason its own header
# gives: a guest cannot reach its own listener (slirp does not hairpin),
# so hostfwd gives the host a door in and hostutil walks through it. This
# is the test listen and accept exist for -- the guest runs lib/http.lua
# and lib/caps.lua unmodified, and the client is a separate
# implementation on the host.
# bin/rz.lua and bin/sz.lua against real lrzsz, over a pty bridged to
# the guest console. The only zmodem test with the whole path in it:
# raw mode, the tty client's readraw, the program ABI, and the launcher
# starting rz because a sender asked for it by name.
if have_hostutil and sz_prog.found() and rz_prog.found() and \
    socat_prog.found()
  test('microvm-zmodem', lua_interp,
    args: [files('tools/zmodemtest.lua'), luaos_microvm_elf],
    protocol: 'tap',
    timeout: 400,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

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

# Whether two lua_States can share one immutable object without the
# collector touching it. Native for the same reason luaheap_test is:
# the question is about lua's collector and nothing else, so no kernel
# and no firmware are involved. It reaches lua's internal headers
# (lstate.h, lgc.h) because building an arena object by hand is exactly
# what a relocator would do, and there is no public API for it.
#
# luai_makeseed is pinned the way src/coreg.h would pin it: lstate.c
# guards it with #if !defined, so every state hashes a string to the
# same bucket and one state's intern table can be spliced with another's
# strings. In the kernel this becomes one seed per boot rather than a
# constant, so hash flooding stays as hard as lua intends.
arena_test = executable('arena_test',
  ['test/arena_test.c'] + lua_src,
  c_args: ['-Dluai_makeseed(L)=0x9e3779b9u'],
  include_directories: include_directories('lua'),
  dependencies: meson.get_compiler('c', native: true).find_library('m',
    required: false),
  native: true,
)
test('arena', arena_test, protocol: 'tap', timeout: 120)

# src/lock.h is the other file that can only be tested where there is
# more than one cpu, which the target never has enough of and the host
# always does. Built native, with NCPU forced past 1 so the real ticket
# lock compiles rather than the uniprocessor barrier, and against the
# host's own src/<arch>/machine.h for machine_relax.
host_arch = build_machine.cpu_family()
if host_arch in ['x86_64', 'aarch64', 'riscv64']
  thread_dep = dependency('threads', native: true)

  # NCPU only has to exceed 1 to select the ticket lock; the thread count
  # is separate, and belongs to the host rather than to that constant.
  # Bounded at both ends. Below two there is nothing to exclude. Above
  # eight buys no more interleaving and costs a great deal: the work is
  # NTHREAD x NITER, and the threads spin, so a 32-way host quadruples
  # the test and saturates every core -- which times out the qemu tests
  # meson is running beside it, not just this one.
  nproc = run_command('nproc', check: false)
  if nproc.returncode() != 0
    nproc = run_command('sysctl', '-n', 'hw.ncpu', check: false)
  endif
  ncpu = nproc.returncode() == 0 ? nproc.stdout().strip().to_int() : 4
  nthread = ncpu
  if nthread < 2
    nthread = 2
  elif nthread > 8
    nthread = 8
  endif

  lock_test = executable('lock_test',
    ['test/lock_test.c'],
    include_directories: include_directories('src', 'src' / host_arch),
    c_args: ['-DNCPU=8', '-DNTHREAD=@0@'.format(nthread)],
    dependencies: thread_dep,
    native: true,
  )
  test('lock', lock_test, protocol: 'tap', timeout: 120)

  # the same test under thread sanitizer, which sees the half the test
  # above cannot.
  #
  # lock_test proves that increments are not lost. It cannot prove the
  # memory order. A ticket lock with its acquire and release downgraded
  # to relaxed still passes a counting test on x86, because the
  # hardware orders stores anyway. The same lock loses updates on
  # aarch64, where it does not. The publication case has the same blind
  # spot for the same reason.
  #
  # tsan models C11 atomics. It derives happens-before from the lock's
  # own acquire and release, stays quiet when they are correct, and
  # reports the unprotected counter when they are not. That makes it a
  # test of the ordering and not of this host.
  #
  # tsan is slow, so the iteration count and the thread count are both
  # fixed low here. A race it finds is a property of the code, not of
  # how long the test runs or how many threads it runs on: it derives
  # happens-before rather than witnessing an interleaving, and reports
  # a relaxed ticket lock at two threads as readily as at eight. The
  # threads matter to the clock instead -- each turn of a spin loop is
  # an instrumented acquire, so cost per increment grows about a
  # hundredfold from four threads to eight.
  #
  # The test is skipped, not failed, where libtsan is absent. It is a
  # toolchain component, not a source dependency.
  tsan_args = ['-DNCPU=8', '-DNTHREAD=4', '-DNITER=2000',
    '-fsanitize=thread', '-g']
  if cc.has_link_argument('-fsanitize=thread')
    lock_test_tsan = executable('lock_test_tsan',
      ['test/lock_test.c'],
      include_directories: include_directories('src', 'src' / host_arch),
      c_args: tsan_args,
      link_args: ['-fsanitize=thread'],
      dependencies: thread_dep,
      native: true,
    )
    # halt_on_error so a race is a failed test rather than a warning
    # scrolling past a run that still reports ok.
    test('lock-tsan', lock_test_tsan, protocol: 'tap', timeout: 300,
      env: {'TSAN_OPTIONS': 'halt_on_error=1:exitcode=1'})
  endif
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
  env: host_env,
  depends: host_deps,
)

# lib/mouse.lua's record codec, and one client's queue driven against a
# port that refuses. "the reader stopped reading" is a function that
# returns false here, and a machine under load anywhere else.
# what a service list means, with proc.spawn replaced by a function that
# records what it was handed. An entry naming a capability the task never
# reads is the failure this catches, and it went unseen on a real machine
# because the service started and only then hung.
test('svc-start', lua_interp,
  args: [files('test/host_svc.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/frame.lua's geometry, selection and utf8 offsets. The panel it is
# for runs on a board and nothing under meson can draw, but where a
# point lands and which bytes an edit moves are arithmetic -- and that
# is where an off-by-one hides.
test('frame-text', lua_interp,
  args: [files('test/host_frame.lua')],
  protocol: 'tap',
  timeout: 20,
)

test('mouse-queue', lua_interp,
  args: [files('test/host_mouse.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/dhcp.lua's options, built by hand. A server offers what it is
# configured to offer, so the ones this machine's server does not send
# are reachable here and nowhere else.
test('dhcp-codec', lua_interp,
  args: [files('test/host_dhcp.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
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
# lib/irc.lua is sans-io for the same reason as the two above: a
# protocol whose awkward cases -- an empty trailing parameter, a tag
# holding its own separator, a user typing a newline into a message --
# are all lines of data rather than connections to arrange.
test('irc-protocol', lua_interp,
  args: [files('test/host_irc.lua')],
  protocol: 'tap',
  timeout: 20,
)

test('bitchat-packet', lua_interp,
  args: [files('test/host_bitchat.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# deflate and inflate, against what gzip wrote rather than against
# themselves. Shared with the ssh tree, where it is kept.
test('zlib', lua_interp,
  args: [files('test/host_zlib.lua')],
  protocol: 'tap',
  timeout: 60,
)

# a packet too big for a link, split and put back together.
test('bitchat-fragment', lua_interp,
  args: [files('test/host_fragment.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# what a mesh passes on, and what stops at it.
test('bitchat-relay', lua_interp,
  args: [files('test/host_relay.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# the XX handshake both ends of a private message need.
test('noise', lua_interp,
  args: [files('test/host_noise.lua')],
  protocol: 'tap',
  timeout: 60,
  env: host_env,
  depends: host_deps,
)

test('zmodem-protocol', lua_interp,
  args: [files('test/host_zmodem.lua')],
  protocol: 'tap',
  timeout: 60,
)

# lib/ble/hci.lua, sans-io like zmodem above it. The codec half needs
# nothing; the rest spawns btvirt on a port of its own and exchanges
# real packets with it, which is what checks our encoding against
# somebody else's reading of the specification.
if have_hostutil
  ble_env = {'HOSTUTIL_SO': hostutil.full_path()}
  if btvirt_prog.found()
    ble_env += {'BTVIRT': btvirt_prog.full_path()}
  endif
  # btmon is the reader the trace format exists for, so where there is
  # one it is what says whether we wrote the format or merely something
  # that looks like it.
  if btmon_prog.found()
    ble_env += {'BTMON': btmon_prog.full_path()}
  endif
  test('ble-hci', lua_interp,
    args: [files('test/host_ble.lua')],
    protocol: 'tap',
    timeout: 60,
    env: ble_env,
    depends: hostutil,
  )
endif

# a lazy require raises at first use, so a name that cannot resolve
# waits in whatever branch first touches it. This fails the build here
# instead.
test('lazy-names', lua_interp,
  args: [files('tools/checklazy.lua'), meson.project_source_root()],
  timeout: 30,
)

# and against lrzsz, where there is one on the host. This is the only
# test with a peer that has never seen our code -- everything else wires
# our sender to our receiver, which proves the two agree and not that
# either is right. It earned its place immediately: ESCCTL turned out to
# be a promise about what you send rather than a preference about what
# you accept, and a peer in that mode silently discards the control
# characters you leave raw.
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
  env: host_env,
  depends: host_deps,
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
  env: host_env,
  depends: host_deps,
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

test('gefs-host', lua_interp,
  args: [files('test/host_gefs.lua')],
  protocol: 'tap',
  timeout: 120,
  env: gefs_host_env,
  depends: gefs_host_deps,
)

# lib/fat is the filesystem the esp32 flash partition and the microSD
# card both carry, and lib/fatfs.lua is what puts it behind a mount. The
# format itself has its own suite upstream; this covers the part that
# only exists here -- that the port loads under our loader, and that the
# dev backend over it reads, writes and lists what it should. What this
# cannot say is that a served volume is wired to the flash driver, which
# is the boot test's job.
# the fat WRITE path, which is where task #47 lives: a volume built the
# way the board's is, written to a little, and then read back in full --
# plus the same with the cache thrown away, which is what a reset in the
# middle of a write leaves behind. What this cannot cover is the flash
# driver under the filesystem, where an erase that completes and a
# program that does not is a sector of 0xff.
test('fat-write', lua_interp,
  args: [files('test/host_fatwrite.lua')],
  protocol: 'tap',
  timeout: 120,
  env: host_env,
  depends: host_deps,
)

test('fat-host', lua_interp,
  args: [files('test/host_fat.lua')],
  protocol: 'tap',
  timeout: 60,
  env: host_env,
  depends: host_deps,
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
  env: gefs_host_env,
  depends: gefs_host_deps,
)
